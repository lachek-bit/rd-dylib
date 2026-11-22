---

## 越狱 tweak 逆向分析（2026-11-22 15:00-15:25）

用户提供了两个 deb：`20871.deb`（破解 tweak）和 `ellekit_1.2`（注入框架）。
分析结论如下，**以下内容是不需要再重复走的路**。

### 包结构

```
20871.deb (18KB, data.tar.lzma)
└── var/jb/Library/MobileSubstrate/DynamicLibraries/
    ├── GrowCrack.dylib   84768 字节
    └── GrowCrack.plist   99 字节

GrowCrack.plist:
    Filter → Bundles → ["com.floatingislandapps.grow"]   # 只注入 Grow

ellekit_1.2 (330KB, data.tar.xz)
└── var/jb/usr/lib/{libellekit,libsubstrate,TweakInject,TweakLoader}.dylib
    var/jb/usr/libexec/ellekit/loader
    var/jb/usr/lib/ellekit/{pspawn,MobileSafety,libinjector}.dylib
```

ellekit 是 Substrate 替代品（越狱环境的 tweak 注入框架）。**TrollStore 环境不需要它，
也用不了它** —— 它依赖越狱的 dyld 注入路径。

### GrowCrack.dylib 的关键特征

**依赖只有 4 个**：libobjc / Foundation / CoreFoundation / libc++。
**没有 StoreKit、没有 RevenueCat、没有任何 hook 框架**。

**导入的方法（`__objc_methname`，全部 14 条）**：

```
stringByAppendingPathComponent:      appendBytes:length:
containerURLForSecurityApplicationGroupIdentifier:
defaultManager                       initWithContentsOfFile:
length                               objectForKey:
path                                 removeObjectForKey:
scanHexInt:                          scannerWithString:
setObject:forKeyedSubscript:         substringWithRange:
writeToFile:atomically:
```

**结论**：它**不 hook 任何方法**，而是**直接读写 plist 文件**。

### 它操作的文件

```objc
[[NSFileManager defaultManager]
    containerURLForSecurityApplicationGroupIdentifier:@"group.com.floatingislandapps.grow"]
→ /var/mobile/Containers/Shared/AppGroup/<UUID>/
→ Library/Preferences/group.com.floatingislandapps.grow.plist    （522 KB，44 个 key）
```

**这是 App Group 的 UserDefaults，不是 app 自己的标准 UserDefaults。**
Grow 的 UI 读的是这一份。这个发现本身很有价值 —— 见下方「两套 UserDefaults」。

### 关键 key

| key | 类型 | 值 |
|---|---|---|
| `growPremium` | NSData | `6e 75 6c 6c` = **字符串 "null"**（4 字节） |
| `user` | NSData | 1077 字节 JSON，含 `isPremium:false` `premiumType`(缺失) |
| `userDetail` | NSData | 455 字节 JSON，含 `vip:false` `vipLevel:0` |
| `com.revenuecat.userdefaults.purchaserInfo.*` | NSData | entitlements 为空 `{}` |

### 它到底改了什么（未完全解出）

`0x52C4` / `0x52D8` / `0x52E4` 三个调用紧邻：

```asm
ldr  x8, [x8, #0xa0]   ; substringWithRange:
ldr  x8, [x8, #0x80]   ; scanHexInt:
ldr  x8, [x8, #0x40]   ; appendBytes:length:
```

**说明**：从某个字符串截取一段 → `scanHexInt:` 转成整数 → `appendBytes:` 拼成
**4 字节 NSData** → 写进 `growPremium`。

**所以 `growPremium` 不是布尔标志，是「凭证」**。
`"null"` 表示未购买，购买后是 4 字节的派生值。

`objectForKey:`(0x49FC) 和 `removeObjectForKey:`(0x4BE4) 用的是**同一个 key**
（运行时地址 0x10560），即先读后删。

### 为什么静态分析到此为止

`0x4290`~`0x53A0` 整段是 **OLLVM 控制流平坦化**：

```asm
mov  w13, #0x359e
movk w13, #0x3a5c, lsl #16    ; 拼常量
orn  w13, w13, w12
add  w12, w12, w13
add  w12, w12, #1
mov  w13, #0x5994
movk w13, #0xb373, lsl #16
and  w12, w12, w13
cmp  w12, w13
cset w12, hi
ldr  x13, [x21, #0x430]
ldr  x12, [x13, w12, uxtw #3]
br   x12                      ; 跳转表分发
```

- selector 被拆散、乱序压栈
- `NSRange` 结构体参数看不到
- 每个基本块用跳转表分发，无法线性跟踪

**没有 unicorn/qemu 的情况下，纯静态还原这个算法不现实。**
（这台机器 `pip` 不可用，装不了 unicorn。）

### 已确认失败的路径（不要再试）

| 尝试 | 结果 |
|---|---|
| 改 `user.isPremium = true` | 不生效（数据未乱，说明字段被接受但不足以解锁） |
| 补全 `premiumType:"lifetime"` 等 5 个字段 | 不生效 |
| 改 `growPremium` = `"true"` | 不生效（不是合法凭证） |
| **删除** `growPremium`（模拟 tweak 的 removeObjectForKey） | 不生效 |
| 改 App Group 的 `userDetail.vip = true, vipLevel = 3` | 不生效 |
| 改标准 UserDefaults 的 `premium` / `userDetail` | 不生效（UI 不读这套） |

### 两套 UserDefaults（重要认知）

| 位置 | 路径 | UI 是否读取 |
|---|---|---|
| 标准域 | `<container>/Library/Preferences/com.floatingislandapps.grow.plist` | **否** |
| **App Group** | `Shared/AppGroup/<UUID>/Library/Preferences/group.com.floatingislandapps.grow.plist` | **是** |

之前所有失败，很大一部分是因为一直在改标准域。

**怎么拿到 App Group 容器**：

```js
var fm = _rd.call('NSFileManager','defaultManager',[]);
var url = _rd.inst(fm,'containerURLForSecurityApplicationGroupIdentifier:',
                   ['group.com.floatingislandapps.grow']);
_rd.inst(url,'path',[])
```

沙盒不允许列 `/var/mobile/Containers/Shared/AppGroup` 的父目录（返回空），
必须用上面这个 API 直接取。

### 结论与后续

**客户端数据改写这条路已经走到底**（到第 3 层 `user` JSON 都不行）。
`growPremium` 是从 token 派生的凭证，需要逆向 OLLVM 混淆的算法才能伪造。

如果还要继续，只有两个方向：

1. **动态调试越狱设备**：在真越狱机上用 lldb attach，在 `writeToFile:atomically:`
   下断点，dump 出 tweak 算出来的 `growPremium` 真实值。拿到值就能直接填。
2. **MITM**：拦 RevenueCat 的 `api.revenuecat.com` 响应（前提是 app 没 pin 证书）。

**注意**：`GrowCrack.dylib` 的字符串是加密的（`__data` 前 826 字节，
逐字节不同 mask 的 XOR，被混淆成 `orr/orn/and/mvn/sub/add` 序列），
所以静态看不到 key 名和类名。这一点也解释了为什么 `strings` 只能抓到 3 条。
