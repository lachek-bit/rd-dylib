# RemoteDebug —— iOS 局域网调试 dylib（交接文档）

> 给下一个接手的人 / AI：先读这一页，然后按顺序看 `docs/` 里的四份文档。
> 这个包是自包含的，不需要之前的对话记录。

---

## 这是什么

一个注入到 iOS app 里的 dylib。app 启动后在内网开一个 HTTP 服务（默认 8899），
你可以从电脑上用 curl 或浏览器直接操作**运行中的 app**：

- 看实时日志（NSLog / printf / stderr 全收）
- 看界面结构（完整视图树 / 可交互元素表 / 控制器栈）
- 截图
- 执行任意 ObjC 表达式（JavaScriptCore 桥 + NSInvocation）
- **点击**（真实触摸注入，走 IOHIDEvent）
- **动态 hook 方法**（改返回值、空实现、只记录）
- 读写 UserDefaults、浏览沙盒文件
- 悬浮球：点一下把调试地址复制到剪贴板

改完的东西能落盘，**重启 app 依然生效**（默认不落盘，需显式开）。

---

## 当前状态（2026-11-22）

| 项 | 值 |
|---|---|
| 设备 | iPhone 14 Pro（iPhone15,2）/ iOS 16.6 / TrollStore |
| 目标 app | **Grow 2.2.8**（`com.floatingislandapps.grow`）—— 专注种树类 |
| 手机 IP | `10.4.37.156`（会变，用悬浮球取） |
| 端口 | 8899 |
| dylib | `dist/RemoteDebug.dylib`（260 KB，arm64，iOS 14+，已 ldid 签名） |
| 自检 | **29 项全绿**（`python tools/selftest.py <IP>`） |
| GitHub | `github.com/lachek-bit/rd-dylib`（CI 用 `macos-15-intel`） |

**未完成**：Grow 的会员解锁还在定位阶段，详见 `docs/04-当前进度-Grow.md`。

---

## 5 分钟上手

### 1. 连上设备

```bash
python tools/selftest.py 10.4.37.156
```

全绿说明服务正常。IP 变了就让用户点一下手机上的悬浮球（会自动复制地址）。

> 注意：手机和电脑必须同一个 WiFi。iOS 的「私有 Wi-Fi 地址」不影响，但路由器的
> AP 隔离会挡。手机开了 VPN / 代理也要关掉。

### 2. 看他在哪个界面

```bash
curl -s http://10.4.37.156:8899/api/ui?vc=1          # 控制器栈
curl -s 'http://10.4.37.156:8899/api/tool?name=ui.tree'   # 可交互元素 + 坐标
curl -s -o shot.jpg http://10.4.37.156:8899/api/screenshot.jpg
```

### 3. 点它

```bash
# 按文字点
curl -s 'http://10.4.37.156:8899/api/tool?name=ui.tapText&text=%E6%B4%9E%E6%82%89'

# 按坐标点
curl -s 'http://10.4.37.156:8899/api/tool?name=ui.tap&x=200&y=760'
```

### 4. 执行任意 ObjC

```bash
# 内容长的 JS 一定写成文件再传，别直接拼在命令行里（转义会炸）
cat > /tmp/js.txt <<'EOF'
var u = _rd.call('NSUserDefaults','standardUserDefaults',[]);
'premium = ' + _rd.inst(u,'boolForKey:',['premium'])
EOF
curl -s -X POST --data-binary @/tmp/js.txt http://10.4.37.156:8899/api/eval
```

### 5. 改代码后重新出包

改 `RemoteDebug/src/*.m` → commit → push → GitHub Actions 自动编译 →
下载 artifact 覆盖 `dist/RemoteDebug.dylib` → 让用户 TrollFools 重新注入。

详见 `docs/05-复刻与出包.md`。

---

## 文档索引

| 文件 | 什么时候看 |
|---|---|
| `docs/01-架构与原理.md` | 想知道内部怎么实现的、要改核心逻辑 |
| `docs/02-API与工具手册.md` | 日常查接口、查工具参数 |
| `docs/03-踩坑记录.md` | **动手前必读** —— 10 个坑，每个都能让你卡半天 |
| `docs/04-当前进度-Grow.md` | 接着调 Grow，看这里接着做 |
| `docs/05-复刻与出包.md` | 换机器、重建仓库、改编译参数 |

---

## 目录结构

```
E:\zm\dylib\
├── README.md                    ← 你正在看的
├── docs\                        交接文档
├── RemoteDebug\
│   ├── src\
│   │   ├── RD.h                 共享声明（所有导出函数）
│   │   ├── RemoteDebug.m        HTTP 服务 / 日志 / 截图 / JSC / 路由
│   │   ├── RDHook.m             hook 引擎 / 反射 / 持久化
│   │   ├── RDAutomation.m       触摸注入 / 控件定位 / 元素表
│   │   ├── RDTool.m             工具注册表 + 20 个内置工具
│   │   ├── RDFloat.m            悬浮球
│   │   ├── RDIndexHTML.m        内嵌网页控制台
│   │   └── RDIcon.h             悬浮球图标（PNG base64，自动生成）
│   ├── build.sh                 macOS 本地编译
│   ├── Makefile                 同上
│   └── preview.html             网页控制台静态预览
├── tools\
│   ├── selftest.py              全接口自检（改完必跑）
│   ├── inject_ipa.py            给 IPA 注入 dylib
│   ├── ipa_tool.py              改 IPA（plist / 替换文件 / 字节 patch）
│   └── macho_info.py            分析 dylib（依赖 / 符号 / 字符串）
├── dist\RemoteDebug.dylib       当前可用产物
└── .github\workflows\build.yml  CI 编译配置
```

---

## 三条铁律

1. **改完必须跑 `selftest.py`** —— 29 项全绿才算改对了。历史上每次「小改动」都崩过。
2. **不要用 `objc_getClassList` / `objc_copyClassList`** —— 在 Swift app 里必崩，见坑 2。
3. **调试期的 hook 不要落盘** —— 落盘 + 崩溃 = 崩溃循环，见坑 5。
