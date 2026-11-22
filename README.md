# RemoteDebug —— 把 iOS app 变成可远程读写的工作台

注入一个 dylib，app 启动后在设备上开一个 HTTP 服务。**我（AI）在同网的电脑上直接 curl 你的手机**：看日志、看界面、找方法、改返回值。

改完的东西落盘，你**退出重开 app 就生效** —— 不用每次重新注入。

---

## 整体闭环

```
我 curl → 手机上的 dylib → 直接操作运行中的 app
                ↓
        hooks.json 落盘
                ↓
        你杀掉 app 重开 → dylib 启动时读回规则 → 功能还在
```

验证通过的改动，再用 `ipa_tool.py` 落到 IPA 文件里，做成永久版本。

---

## 一、编译 dylib

本机（Windows）没有 iOS 编译链，走 GitHub Actions。

```bash
cd 这个目录
git init && git add . && git commit -m init
git remote add origin git@github.com:你的账号/随便一个仓库.git
git push -u origin main
```

仓库 → **Actions** → `build-dylib` → 跑完在 Artifacts 下 `RemoteDebug-dylib`，解压得 `RemoteDebug.dylib`（arm64 / iOS 14+）。

有 Mac 的话：`cd RemoteDebug && ./build.sh`。

---

## 二、注入

**方式 A（推荐）**：手机装 **TrollFools**，把 dylib 传进手机，选中目标 app → 注入 → 选这个 dylib。自动重签，重启 app 生效。

**方式 B**：改 IPA

```bash
python tools/inject_ipa.py 你的app.ipa -d RemoteDebug.dylib -o app-debug.ipa
```

改完的包用 **TrollStore 安装**（它会二次签名）。

先看一眼空间够不够：

```bash
python tools/inject_ipa.py 你的app.ipa --check
```

---

## 三、我这边怎么用

启动 app 后，你先告诉我手机 IP（设置 → 无线局域网 → ⓘ），我就能开始：

```bash
# 活着没
curl http://192.168.1.20:8899/api/info

# 看最近日志
curl -s 'http://192.168.1.20:8899/api/logs?since=0'

# 看当前界面结构
curl -s http://192.168.1.20:8899/api/ui

# 截个图
curl -s -o shot.jpg http://192.168.1.20:8899/api/screenshot.jpg

# 执行任意 ObjC 表达式
curl -s -X POST --data-binary 'UIApplication.sharedApplication.keyWindow.frame' \
     http://192.168.1.20:8899/api/eval
```

你自己也能用浏览器打开 `http://手机IP:8899`，界面是黑底终端风，能看日志、执行表达式、点按钮截图/看 UI 树。

---

## 四、工具：点一下就执行

dylib 里注册了一张工具表，和 MCP 的 tools 一个思路 —— 有名字、有参数、有执行体。浏览器里是按钮，我这边是 HTTP 调用。

```bash
# 看有哪些工具
curl -s http://192.168.1.20:8899/api/tools

# 列出界面上所有可点元素（序号、类型、文字、中心坐标）
curl -s 'http://192.168.1.20:8899/api/tool?name=ui.tree'

# 点文字包含"确定"的按钮
curl -s 'http://192.168.1.20:8899/api/tool?name=ui.tapText&text=确定'

# 按坐标点
curl -s 'http://192.168.1.20:8899/api/tool?name=ui.tap&x=200&y=760'

# 填输入框
curl -s -X POST -d '{"name":"ui.setText","args":{"text":"13800138000","index":0}}' \
     http://192.168.1.20:8899/api/tool
```

内置工具：

| 组 | 工具 | 作用 |
|---|---|---|
| 看 | `ui.tree` | 可交互元素表（AI 找按钮主要靠这个） |
| 看 | `ui.dump` / `ui.vc` | 完整视图树 / 控制器栈 |
| 看 | `ui.shot` | 截图，返回 base64 |
| 看 | `screen.size` | 屏幕尺寸、缩放、安全区 |
| 点 | `ui.tap` / `ui.tapRatio` | 坐标点 / 相对坐标点 |
| 点 | `ui.tapText` / `ui.tapId` | 按文字 / 按 identifier 点 |
| 点 | `ui.swipe` | 滑动 |
| 点 | `ui.setText` / `ui.commit` | 填输入框 / 提交 |
| 点 | `ui.back` / `ui.dismissKeyboard` | 返回 / 收键盘 |
| 系统 | `device.vibrate` | 震动 |
| 系统 | `pasteboard.get` / `set` | 剪贴板 |
| 系统 | `app.openURL` / `app.restart` | 打开链接 / 退出进程 |
| 系统 | `alert.show` | 弹提示 |

**点击怎么实现的**：两条路。优先 `UIControl sendActionsForControlEvents`（精确、无私有 API），同时用 `IOHIDEventSystemClientDispatchEvent` 注入真实触摸（对 WebView、游戏、自定义手势有效）。IOKit 符号是 dlopen 拿的，拿不到就自动降级，不影响 dylib 加载。

**自定义工具**：现场写一个，注册完立刻出现在按钮列表里，而且落盘到 `tools.json`，重启还在。

```bash
curl -s -X POST --data-binary '{
  "name": "demo.hello",
  "title": "弹个提示",
  "desc": "演示自定义工具",
  "group": "自定义",
  "params": [{"name":"msg","type":"string","required":true,"desc":"内容"}],
  "code": "_rd.tool(\"alert.show\", {title: \"自定义\", msg: args.msg}); return \"已弹出\";"
}' http://192.168.1.20:8899/api/tooldef
```

`code` 里能直接写 JS + 调其它工具（`_rd.tool` / `_rd.hook` / `_rd.call` / `_rd.inst`），`args` 是参数对象。删掉用 `/api/toolrm?name=demo.hello`。

---

## 五、动态 hook（核心）

改功能不用改包，一条命令把方法换掉，**重启后还在**。

```bash
# 让 isVip 永远返回 YES
curl -s 'http://192.168.1.20:8899/api/hook?cls=UserManager&sel=isVip&mode=force&value=1'

# 让某个检查方法什么都不做
curl -s 'http://192.168.1.20:8899/api/hook?cls=Foo&sel=checkLicense&mode=skip'

# 只记录调用和参数，不改行为
curl -s 'http://192.168.1.20:8899/api/hook?cls=Foo&sel=doSomething:&mode=log'

# 看当前所有规则和命中次数
curl -s http://192.168.1.20:8899/api/hooks

# 撤掉一条
curl -s 'http://192.168.1.20:8899/api/unhook?cls=Foo&sel=isVip'

# 全部撤掉
curl -s http://192.168.1.20:8899/api/hookclear
```

四种模式：

| mode | 行为 | 典型用途 |
|---|---|---|
| `log` | 记一笔，原样转发 | 摸清调用时机和参数 |
| `skip` | 不调原实现，返回 0/nil/NO | 关掉校验、去掉弹窗 |
| `force` | 不调原实现，返回 `value` | 解锁开关、改数值 |
| `after` | 调原实现，把返回值改成 `value` | 改返回结果但保留副作用 |

`value` 写法：数字 `1`、布尔 `true`/`false`、字符串加前缀 `s:文本`、`nil`。

浏览器里也能直接写：

```js
_rd.hook('UserManager', 'isVip', 'force', 1)     // 立即生效并落盘
_rd.hooks()                                      // 看列表
_rd.unhook('UserManager', 'isVip')
```

**持久化**：每次 hook 成功都会写 `hooks.json`，dylib 启动时自动重新安装。所以你杀掉 app 再打开，改动还在。文件位置：

```
/var/mobile/Library/RemoteDebug/<bundle-id>/hooks.json
```

（写不进去时退回沙盒 `Documents/RemoteDebug/`）

---

## 六、找目标（不知道该 hook 谁的时候）

```bash
# 列出类的所有方法和类型编码
curl -s 'http://192.168.1.20:8899/api/methods?cls=LoginViewController'
curl -s 'http://192.168.1.20:8899/api/methods?cls=LoginViewController&all=1'   # 含父类

# 看属性
curl -s 'http://192.168.1.20:8899/api/props?cls=LoginViewController'

# 看成员变量
curl -s 'http://192.168.1.20:8899/api/ivars?cls=LoginViewController'

# 按关键字找类
curl -s 'http://192.168.1.20:8899/api/classes?q=Vip'

# 在当前界面树里找某个类的活实例（拿到指针）
curl -s 'http://192.168.1.20:8899/api/find?cls=UIButton&limit=20'
```

拿到指针后可以直接操作那个对象：

```js
var btn = _rd.ptr('0x10a2c4d80');
_rd.inst(btn, 'setHidden:', [true]);
_rd.desc(btn)
```

---

## 七、运行时的通用操作

点语法受限于 JSC 自己的桥接，调不动就用 `_rd.call` / `_rd.inst`（走 NSInvocation，最稳）：

```js
// 类方法
_rd.call('NSBundle', 'mainBundle', []).bundleIdentifier
_rd.call('UIDevice', 'currentDevice', []).systemVersion

// 实例方法，selector 写标准形式
_rd.inst(_rd.keyWindow(), 'endEditing:', [true])

// 弹框
var ac = _rd.call('UIAlertController',
                  'alertControllerWithTitle:message:preferredStyle:', ['标题','内容',1]);
_rd.inst(_rd.keyWindow().rootViewController,
         'presentViewController:animated:completion:', [ac, true, null]);

// 遍历视图树改东西
var w = _rd.keyWindow();
(function walk(v){
  if (v.isKindOfClass(UILabel)) v.text = '改过了';
  for (var i = 0; i < v.subviews.count; i++) walk(v.subviews.objectAtIndex(i));
})(w);
```

返回值：对象给对象，数字/布尔装箱成 Number/Boolean，void 给 `undefined`，结构体返回拿不到（用 `_rd.uiDump()` 看 frame）。

---

## 八、改 IPA（永久生效）

运行时 hook 适合试探，确定之后落到包里做成永久版。

```bash
# 看包信息
python tools/ipa_tool.py app.ipa info

# 看文件
python tools/ipa_tool.py app.ipa list Payload/

# 导出 / 替换文件（换图标、换配置、换脚本）
python tools/ipa_tool.py app.ipa get Payload/App.app/Assets.car -o a.car
python tools/ipa_tool.py app.ipa replace Payload/App.app/Assets.car 新.car -o out.ipa

# 改 Info.plist（类型自动推断）
python tools/ipa_tool.py app.ipa plist-set CFBundleDisplayName 新名字 -o out.ipa
python tools/ipa_tool.py app.ipa plist-set UIFileSharingEnabled true -o out.ipa

# 二进制字节替换（等长替换，不破坏结构）
python tools/ipa_tool.py app.ipa hexpatch Payload/App.app/App 4885c0 31c0c3 -o out.ipa

# 删文件
python tools/ipa_tool.py app.ipa rm Payload/App.app/某个文件 -o out.ipa

# 注入调试 dylib
python tools/ipa_tool.py app.ipa inject RemoteDebug.dylib -o out.ipa
```

改过的包用 **TrollStore 安装**，它会重签。`hexpatch` 只做等长替换，会校验长度，不会挪动数据。

---

## 九、HTTP 接口全表

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/info` | 包名/版本/机型/系统/pid/端口/沙盒路径 |
| GET | `/api/logs?since=N` | 增量日志，返回 `next` 作为下次 since |
| GET | `/api/clear` | 清日志缓冲 |
| POST | `/api/eval` | body 为 JS，返回 `{ok,result}` |
| GET | `/api/ui` | 视图层级；`?vc=1` 换成控制器栈 |
| GET | `/api/screenshot.jpg?q=0.7` | 截图 |
| GET | `/api/classes?q=` | 类名搜索 |
| GET | `/api/methods?cls=&all=1` | 方法列表 |
| GET | `/api/props?cls=&all=1` | 属性列表 |
| GET | `/api/ivars?cls=` | 成员变量 |
| GET | `/api/find?cls=&limit=` | 界面树里找活实例 |
| GET | `/api/hook?cls=&sel=&mode=&value=` | 装 hook 并落盘 |
| GET | `/api/unhook?cls=&sel=` | 卸一条 |
| GET | `/api/hooks` | 当前规则 + 命中次数 |
| GET | `/api/hookclear` | 全卸 |
| GET | `/api/tools` | 工具列表（名字/说明/参数） |
| GET | `/api/tool?name=&...` | 调用工具，query 当参数 |
| POST | `/api/tool` | 调工具，body 为 `{name,args}` |
| POST | `/api/tooldef` | 注册自定义 JS 工具 |
| GET | `/api/toolrm?name=` | 删除自定义工具 |
| GET | `/api/fs?path=` | 列目录 |
| GET | `/api/file?path=` | 下载文件 |
| POST | `/api/defaults` | body 为 suite 名，返回 plist JSON |
| POST | `/api/write?path=` | 写沙盒文件 |

---

## 十、改配置

`RemoteDebug/src/RemoteDebug.m` 顶部：

```c
#define RD_DEFAULT_PORT   8899      // 被占用自动 +1，最多试 10 个
#define RD_TOKEN          ""        // 填上后必须 /?k=口令
```

改完重跑 CI。

⚠️ 不设口令时，同网任何人都能访问这个后门级接口。只在自己信任的网络里用，用完把 app 杀掉。

---

## 十一、排错

**打不开**：app 得在跑；手机 VPN 关掉；路由器 AP 隔离关掉；端口换了看日志里的实际端口。

**闪退**：dylib 架构不对（`file` 看是不是 arm64）；注入后没重签；换 TrollFools 试。

**hook 没反应**：先 `mode=log` 确认方法真的被调用；方法可能在子类上重写了，hook 子类；返回结构体的方法不支持（会拒绝）。

**日志空**：有些 app 用 `os_log` 不走 stderr，这种情况用 UI 树和 eval。

---

## 文件结构

```
.
├── .github/workflows/build.yml   CI 编译 dylib
├── RemoteDebug/
│   ├── src/RD.h                  内部共享声明
│   ├── src/RemoteDebug.m         HTTP 服务 / 日志 / UI / 截图 / JSC
│   ├── src/RDHook.m              hook 引擎 / 反射 / 持久化
│   ├── src/RDAutomation.m        触摸注入 / 控件定位 / 元素表
│   ├── src/RDTool.m              工具注册表 / 内置工具
│   ├── src/RDIndexHTML.m         内嵌网页控制台
│   ├── build.sh                  macOS 本地编译
│   ├── Makefile                  macOS make
│   └── preview.html              界面静态预览
└── tools/
    ├── inject_ipa.py             dylib 注入
    ├── ipa_tool.py               IPA 编辑（plist / 文件 / 字节）
    └── macho_info.py             dylib 静态分析（依赖/符号/字符串）
```
