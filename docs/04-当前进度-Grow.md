# 04 当前进度：Grow

## 目标 app

| 项 | 值 |
|---|---|
| 名称 | **Grow** |
| Bundle ID | `com.floatingislandapps.grow` |
| 版本 | 2.2.8（build 1167） |
| 类型 | 专注 / 习惯养成（种树类，类似 Forest） |
| 界面 | **SwiftUI**（`_TtGC7SwiftUI14_UIHostingViewVS_7AnyView_`） |
| 设备 | iPhone 14 Pro / iOS 16.6 |
| 调试地址 | `http://<手机IP>:8899`（点悬浮球复制） |

---

## 界面结构（已探明）

```
Grow.GrowTabBarController
└─ Grow.GrowNavigationController
   └─ Grow.PerfectDayViewController      ← 启动落在这一页

底部 Tab：今天 / 身体 / 关心 / 挑战 / 洞悉
```

「今天」页包含：

- `JTAppleCalendar.JTACMonthView` —— 横向日期条（1~7）
- 3 个 `SwiftUI.HostingScrollView` —— 内容区
- `Grow.ConfettiView` —— 撒花特效
- `Grow.SpringButton` —— 主按钮（隐藏状态）
- 底部 `UITabBar`（5 个 `UITabBarButton`）
- 顶部有「新版本现已上线！」横幅（`Grow.GradientView` + `UILabel`）

屏幕：393 × 852（点）；TabBar 在 y≈794；横幅在 y≈749。

---

## 已经拿到的线索

### UserDefaults（72 个键）

```bash
curl -s -X POST --data-binary @js.txt http://IP:8899/api/eval
# js.txt: var u=_rd.call('NSUserDefaults','standardUserDefaults',[]);
#         var d=_rd.inst(u,'dictionaryRepresentation',[]);
#         Object.keys(d).join(',')
```

会员相关的键：

| 键 | 当前值 | 判断 |
|---|---|---|
| `premium` | **false** | 主会员标志，最可能 |
| `alternativePro` | false | 备用 Pro 标志 |
| `premiumMaxRetryCount` | 3 | 说明有校验重试逻辑 |
| `subscriberLifetimeOffClosed2024` | ？ | 2024 年买断关闭标记 |
| `didLogin` | true | 已登录 |
| `userDetail` | NSData | 用户资料（序列化后被转成 `<data N bytes>`） |
| `authUser` | ？ | 登录态 |

其他值得注意：`GrowDBMigrationCompleted_V5`（Realm 迁移）、
`iCloudSyncOn`、`lastChangeToken_GRDBCloudKitDefaultZone`（用了 CloudKit 同步）。

### `Grow.GrowUser` —— Realm 数据模型

```bash
curl -s 'http://IP:8899/api/methods?cls=Grow.GrowUser'
curl -s 'http://IP:8899/api/props?cls=Grow.GrowUser&all=1'
```

属性（**没有会员字段**）：`id` `name` `birthday` `growStart` `quote` `gender`
`weight` `weightIn...` `centimeter` `inches` `feet` `bmr` `customMaxHR`
`heightUnitType` `weightUnitType` `motionImage` `avatar` `isDeleted`

方法 43 个，基本都是 getter/setter + `+primaryKey`。
父类链走到 `RLMObject`。

**结论**：会员状态不存在 Realm 里，只存在 UserDefaults。

### 已尝试过、不要重复的

| 尝试 | 结果 |
|---|---|
| 写 `premium=1` 到 UserDefaults + synchronize | 写入成功、读回 true，但**界面无变化** —— app 内存里有缓存，没重读 |
| hook `NSUserDefaults boolForKey:`（log 模式） | **app 崩溃**，且因为持久化造成崩溃循环。已用版本迁移机制清理 |
| 猜类名 `Grow.UserManager` / `SubscriptionManager` / `StoreManager` / `PurchManager` / `PremiumManager` / `AccountManager` / `MemberManager` / `VipManager` / `ProManager` / `IAPManager` / `PayManager` / `PremiumService` / `GrowUser` / `Settings` | 只有 `Grow.GrowUser` 存在，其余都不存在 |
| `/api/classes` 模糊搜索 | **必崩**，见坑 2。已改成 image 枚举但未验证 |

---

## 下一步该怎么做

### 路线 A（推荐）：从界面找入口

SwiftUI 的视图层级没有类名可用，但**文字能找到**。

```bash
# 1. 逐个 tab 点过去，看有哪些页
curl -s 'http://IP:8899/api/tool?name=ui.tapText&text=%E8%BA%AB%E4%BD%93'   # 身体
curl -s 'http://IP:8899/api/tool?name=ui.tapText&text=%E5%85%B3%E5%BF%83'   # 关心
curl -s 'http://IP:8899/api/tool?name=ui.tapText&text=%E6%8C%91%E6%88%98'   # 挑战
curl -s 'http://IP:8899/api/tool?name=ui.tapText&text=%E6%B4%9E%E6%82%89'   # 洞悉

# 2. 每个页面 dump 元素表，找带「升级 / Pro / 会员 / 订阅 / Premium」的文字
curl -s 'http://IP:8899/api/tool?name=ui.tree' | grep -iE "Pro|会员|升级|订阅|Premium"

# 3. 找到就点进去，然后看控制器栈是否弹出新的 VC
curl -s 'http://IP:8899/api/tool?name=ui.tapText&text=升级'
curl -s 'http://IP:8899/api/ui?vc=1'
```

拿到新 VC 的类名后，用 `methods?cls=` / `props?cls=` 看它有什么，
通常能在里面找到 `isPremium` / `hasPurchased` 之类的属性或方法。

### 路线 B：找读 premium 的代码

不要 hook `NSUserDefaults`（会崩）。换个思路：

1. 用 `ui.tree` 确认界面上哪些东西是「会员专属」（比如带锁图标的元素）
2. 那些元素的渲染逻辑所在 VC / View 就是目标
3. 对目标类用 `methods?cls=` 找死方法

### 路线 C：找 Grow 自己的 Store 类

`/api/classes` 修好后（换了 image 枚举），可以搜：

```bash
python tools/selftest.py <IP> --danger      # 先确认 classes 不崩了
curl -s 'http://IP:8899/api/classes?q=Store'
curl -s 'http://IP:8899/api/classes?q=Pay'
curl -s 'http://IP:8899/api/classes?q=IAP'
curl -s 'http://IP:8899/api/classes?q=Revenue'
curl -s 'http://IP:8899/api/classes?q=Purchase'
```

Grow 用了 StoreKit（UserDefaults 里有 `PKLogNotificationServiceResponsesKey`、
`PKKeychainVersionKey`），可能也有 RevenueCat（类名含 `RC` / `Purchases`）。

---

## 已验证可用的事实

- 截图正常：`curl -s -o s.jpg 'http://IP:8899/api/screenshot.jpg?q=0.8'`
- 点击有效：`ui.tapText` 点 tab 成功（返回
  `{"cls":"UITabBarButtonLabel","ok":true}`）
- 读 UserDefaults 正常（走 `_rd.call` + `_rd.inst`）
- 写 UserDefaults 正常（走 KVC `setValue:forKey:`）
- `methods` / `props` / `ivars` / `find` 都正常，不崩

## 未验证

- `classes` 的 image 枚举版本（换了 dylib 还没试）
- hook 业务类（只试过系统类，崩了）

---

## 交互习惯备注

- 用户希望「改完重启 app 就生效」，所以验证通过后要 `persist=1` 落盘
- 用户不喜欢反复折腾，改完先自己用 selftest 验一遍再让他换包
- 用户会截图反馈，注意看他截图里的报错文案（坑 1 就是靠截图定位的）

---

## 「睡眠时心率」等卡片带锁 —— 定位结论（2026-11-22 14:27）

「身体」页四张卡片：静息心率（无锁）、**睡眠时心率（锁）**、呼吸频率（锁）、
最大摄氧量（锁）。目标是解开锁。

### 已确认的事实

1. **卡片的锁判断在 SwiftUI 层，没有 ObjC 类可 hook。**
   - `Grow.BodyViewController` 只有 5 个方法：`viewDidLoad` `viewWillAppear:`
     `initWithNibName:bundle:` `initWithCoder:` `.cxx_destruct`
   - 它的 ivar 只有 `cancellables`（Combine 订阅）和 `$__lazy_storage_$_topBar`
   - 属性全是父类/广告 SDK 分类的，没有任何业务字段
   - 说明这个 VC 只是个壳，界面完全由 SwiftUI 绘制

2. **卡片不是 UIControl，`ui.tapText` 找不到它。**
   - `ui.tree` 里根本没有卡片对应的元素（只有 HostingView / ScrollView）
   - `ui.tapText?text=睡眠时心率` 返回 `{"ok":false,"error":"没找到"}`

3. **`ui.tap`（IOHID 真实触摸）当前无效。**
   - 用 `ui.tap&x=353&y=810` 点「洞悉」tab，VC 没变（应该切页）
   - 而 `ui.tapText&text=洞悉` 能切 —— 因为它走的是 `UIControl sendActions`
   - 说明 IOHID 注入这一路没生效，而 SwiftUI 卡片只能靠它

4. **JS 侧调不动 NSArray 的方法。**
   `_rd.inst(subviews,'count',[])` 返回 `undefined`，
   `v.subviews.count` 报 `undefined is not an object`。
   JSC 的 ObjC 桥对 NSArray/NSDictionary 的方法派发不可靠，
   遍历类操作必须在 ObjC 侧做成工具，不能写在 JS 里。

### 结论

解锁必须走 **真实触摸注入**（点进详情页看真实限制），或者
**改掉 SwiftUI 依赖的那个数据源**（`premium`）。

所以下一步是：先修 IOHID（已加 `hid.status` / `hid.tap` 诊断工具），
修好后点进卡片，看弹出的是付费墙还是详情页。

### 已加的诊断工具

| 工具 | 作用 |
|---|---|
| `hid.status` | 返回 IOHID dlopen / 符号 / client 是否就绪 |
| `hid.tap` | 带 `scale`（1=点 / 3=像素）和 `integrated` 开关的原始注入 |

诊断顺序：
```bash
curl -s 'http://IP:8899/api/tool?name=hid.status'
# 如果 ready=false，看 error
# 如果 ready=true，试：
curl -s 'http://IP:8899/api/tool?name=hid.tap&x=353&y=810&scale=1'
curl -s 'http://IP:8899/api/tool?name=hid.tap&x=353&y=810&scale=3'
curl -s 'http://IP:8899/api/tool?name=hid.tap&x=353&y=810&scale=1&integrated=true'
# 每次点完看 /api/ui?vc=1 是否切到洞悉
```
