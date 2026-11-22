# 02 API 与工具手册

所有接口都是 `http://<手机IP>:8899`。GET 返回值统一是
`{"ok": true, "result": ...}` 或 `{"ok": false, "error": "..."}`。

---

## 一、HTTP 接口总表

### 基础

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/` | 网页控制台（浏览器打开） |
| GET | `/api/ping` | 存活探测，返回 pid |
| GET | `/api/info` | 包名/版本/机型/系统/pid/端口/home/沙盒路径 |
| GET | `/api/logs?since=N` | 增量日志，返回 `next` 作为下次 since |
| GET | `/api/clear` | 清内存日志缓冲（不影响 last.log） |

### 界面

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/ui` | 完整视图树；加 `?vc=1` 换成控制器栈 |
| GET | `/api/screenshot.jpg?q=0.7` | 截图（JPEG 二进制） |

### JS 执行

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/eval` | body 是 JS 源码，返回执行结果字符串 |

> **body 长一定要写文件再传**：`curl --data-binary @js.txt`。
> 直接拼在命令行里，括号、引号、`$` 会被 shell 吃掉，你会收到
> `{"ok":false,"error":"empty code"}`。

### 反射

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/classes?q=关键字` | 类名搜索（**见坑 2，谨慎使用**） |
| GET | `/api/methods?cls=X&all=1` | 方法列表（`all=1` 含父类） |
| GET | `/api/props?cls=X&all=1` | 属性列表（带类型编码） |
| GET | `/api/ivars?cls=X` | 成员变量 |
| GET | `/api/find?cls=X&limit=20` | 在界面树里找活实例，返回指针 |

### hook

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/hook?cls=X&sel=y&mode=Z&value=V` | 装 hook（默认不落盘） |
| GET | `/api/hook?...&persist=1` | 同上，但写进 hooks.json |
| GET | `/api/unhook?cls=X&sel=y` | 卸载一条 |
| GET | `/api/hooks` | 当前规则 + 命中次数 |
| GET | `/api/hookclear` | 全部卸载 |

`mode` 四种：

| mode | 行为 |
|---|---|
| `log` | 记一笔日志，原样转发 |
| `skip` | 不调原实现，返回 0/nil/NO |
| `force` | 不调原实现，返回 `value` |
| `after` | 调原实现，把返回值改成 `value` |

`value` 写法：`1` / `true` / `false` / `s:字符串` / `nil`。

### 工具

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/tools` | 全部工具（名字/说明/参数） |
| GET | `/api/tool?name=X&...` | 调工具，query 当参数 |
| POST | `/api/tool` | body 是 `{"name":"X","args":{...}}` |
| POST | `/api/tooldef` | 注册自定义 JS 工具（body 是 JSON） |
| GET | `/api/toolrm?name=X` | 删除自定义工具 |

### 文件

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/fs?path=/` | 列目录 |
| GET | `/api/file?path=...` | 下载文件 |
| POST | `/api/defaults` | body 是 suite 名（空则标准域），返回 JSON |
| POST | `/api/write?path=...` | body 直接写成文件 |

---

## 二、内置工具（21 个）

### 看

| 工具 | 参数 | 说明 |
|---|---|---|
| `ui.tree` | — | **最常用**。可交互元素表：序号、类名、文字、中心坐标 |
| `ui.dump` | — | 完整视图树（含 frame / tag / hidden） |
| `ui.vc` | — | 控制器链 |
| `ui.shot` | `q` | 截图，返回 `data:image/jpeg;base64,...` |
| `screen.size` | — | 屏幕尺寸 / 缩放 / 安全区 |
| `app.paths` | — | 日志/配置的实际路径（排查用） |

`ui.tree` 返回示例：

```json
{"count":57,"items":[
  {"i":38,"cls":"UIButton","tap":true,"cx":373,"cy":749,"w":30,"h":30},
  {"i":42,"cls":"UITabBarButton","tap":true,"cx":40,"cy":794,"text":"今天"},
  {"i":56,"cls":"UITabBarButtonLabel","tap":false,"cx":353,"cy":810,"text":"洞悉"}
]}
```

### 点

| 工具 | 参数 | 说明 |
|---|---|---|
| `ui.tap` | `x`,`y` | 屏幕坐标点击（真实触摸） |
| `ui.tapRatio` | `rx`,`ry` | 0-1 相对坐标点击，适配机型 |
| `ui.tapText` | `text`,`index` | 按文字找元素并点击 |
| `ui.tapId` | `id`,`index` | 按 accessibilityIdentifier 点击 |
| `ui.swipe` | `x1`,`y1`,`x2`,`y2`,`duration` | 滑动 |
| `ui.setText` | `text`,`index` | 给第 n 个输入框填字（自动聚焦） |
| `ui.commit` | — | 当前输入框触发 return |
| `ui.back` | — | 导航栈 pop / 点返回 |
| `ui.dismissKeyboard` | — | 收键盘 |

### 系统

| 工具 | 参数 | 说明 |
|---|---|---|
| `device.vibrate` | — | 震动 |
| `pasteboard.get` / `set` | — / `text` | 剪贴板 |
| `app.openURL` | `url` | 打开链接 |
| `app.restart` | `confirm=true` | 0.4 秒后退出进程（重开即恢复落盘的 hook） |
| `alert.show` | `title`,`msg` | 弹 alert |

---

## 三、JS 环境（`_rd` 对象）

`/api/eval` 里可直接用的全局类：`UIApplication` `UIWindow` `UIView`
`UIViewController` `UILabel` `UIButton` `UIAlertController` `NSUserDefaults`
`NSBundle` `NSFileManager` `NSNotificationCenter` 等。

`_rd` 提供：

| 方法 | 说明 |
|---|---|
| `_rd.app()` | UIApplication 单例 |
| `_rd.keyWindow()` | 当前 keyWindow |
| `_rd.uiDump()` | 视图树文本 |
| `_rd.classes()` | 全部类名（**危险，见坑 2**） |
| `_rd.cls('名字')` | 按名字取 Class，没有返回 null |
| `_rd.call('类名','sel:','参数数组')` | 调类方法（NSInvocation） |
| `_rd.inst(对象,'sel:','参数数组')` | 调实例方法（NSInvocation） |
| `_rd.ptr('0x123...')` | 十六进制指针转对象 |
| `_rd.desc(obj)` | 类名 + 指针 + description |
| `_rd.hook(cls,sel,mode,value)` | 装 hook（不落盘） |
| `_rd.unhook(cls,sel)` / `_rd.hooks()` | 卸载 / 列表 |
| `_rd.tools()` / `_rd.tool(name,args)` | 工具列表 / 调用工具 |
| `_rd.log(s)` | 写一条日志 |

### 重要限制：`_rd.call` / `_rd.inst` 只支持对象参数

NSInvocation 那层只会给 `@` 类型的参数赋值。**BOOL / int / float 参数会被跳过（当成 0）**。

遇到基本类型参数，用 KVC 绕：

```js
// ✗ 不行：setBool: 的第一个参数是 BOOL，会被丢
_rd.inst(u, 'setBool:forKey:', [true, 'premium'])

// ✓ 用 KVC，setValue:forKey: 两个参数都是对象
_rd.inst(u, 'setValue:forKey:', [1, 'premium'])
_rd.inst(u, 'synchronize', [])
```

### 常用表达式

```js
// 取 UserDefaults 全部键
var u = _rd.call('NSUserDefaults','standardUserDefaults',[]);
var d = _rd.inst(u,'dictionaryRepresentation',[]);
Object.keys(d).join(',')

// 读某个值
_rd.inst(u,'boolForKey:',['premium'])
_rd.inst(u,'objectForKey:',['userDetail'])

// 遍历界面改文字
var w = _rd.keyWindow();
(function walk(v){
  if (v.isKindOfClass(UILabel)) v.text = 'x';
  for (var i=0;i<v.subviews.count;i++) walk(v.subviews.objectAtIndex(i));
})(w);

// 弹框
var ac = _rd.call('UIAlertController',
                  'alertControllerWithTitle:message:preferredStyle:', ['标题','内容',1]);
_rd.inst(_rd.keyWindow().rootViewController,
         'presentViewController:animated:completion:', [ac,true,null]);

// 列出窗口层级（调试用）
var ws=_rd.inst(_rd.app(),'windows',[]); var n=_rd.inst(ws,'count',[]);
var o=[]; for(var i=0;i<n;i++){var x=_rd.inst(ws,'objectAtIndex:',[i]);
  o.push(i+':lv'+_rd.inst(x,'windowLevel',[]));} o.join(' ')
```

---

## 四、自定义工具

注册一个 JS 工具，会立刻出现在工具表和网页按钮里，并落盘到 `tools.json`：

```bash
curl -s -X POST --data-binary '{
  "name": "demo.hello",
  "title": "弹个提示",
  "desc": "演示",
  "group": "自定义",
  "params": [{"name":"msg","type":"string","required":true,"desc":"内容"}],
  "code": "_rd.tool(\"alert.show\",{title:\"自定义\",msg:args.msg}); return \"已弹出\";"
}' http://10.4.37.156:8899/api/tooldef
```

`code` 里能调别的工具、能 hook、能执行任意 ObjC，`args` 是参数对象，`return` 的值
就是工具返回值。

删除：`curl 'http://IP:8899/api/toolrm?name=demo.hello'`

---

## 五、返回格式踩坑

- `RDCallTool` 的返回值如果是字符串，会包成 `{"result":"..."}`；
  如果是字典/数组，直接嵌进 `result`。
- `/api/defaults` 会把 `NSData` 显示成 `<data N bytes>`，`NSDate` 显示成
  `<date 时间戳>` —— 因为直接序列化会抛异常。
- `/api/screenshot.jpg` 和 `/api/file` 返回二进制，别用 json 解析。
