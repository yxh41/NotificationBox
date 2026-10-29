# NotifyBox · 通知记录与消息盒子（iOS 16 roothide）

把系统收到的通知全部记录下来，并提供「消息盒子」App 做浏览 / 筛选 / 搜索；
进阶支持关键词过滤、内容替换、按 App 换提示音、朗读。
（延迟推送曾做到 v0.0.18，两版实现各撞崩一次 SpringBoard，v0.0.19 已整体删除 —— 别再当待办。）

## 架构（一句话）

```
App 发通知 → SpringBoard 的 BBServer → [NotifyBox Tweak hook]
                                     ├─ 1. 记原始通知进 SQLite（NotifyStore）
                                     └─ 2. 过滤/替换/换声/延迟后再 %orig（NotifyFilter）
            ↓
        盒子 App（/Applications/NotifyBox.app）读同一份 SQLite 展示
            ↓
        PreferenceLoader 设置（layout/.../NotifyBox.bundle）改白黑名单/上限/关键词
```

唯一 hook 点 = `BBServer`（所有通知中枢）。**记录与呈现分离**：记录永远存「原始通知」，
过滤/替换只改屏幕呈现，不污染记录（想要连记录都不要，后续加开关）。

## 目录

```
notifybox/
├─ control / Makefile / NotifyBox.plist   # 包元数据 + roothide 构建 + 注入 SpringBoard
├─ Tweak.x                               # BBServer hook（录制 + 调用过滤）
├─ NotifyCommon.h                         # 共享常量（bundleId / DB 路径 / prefs 路径）
├─ NotifyStore.{h,m}                      # SQLite：录制 + 上限裁剪 + 查询 + 顶部 App 列表
├─ NotifyFilter.{h,m}                     # 白/黑名单 + 关键词过滤 + 内容替换 + 换声(占位)
├─ app/                                   # 独立盒子 App（列表 + App 图标筛选 + 时间 + 搜索）
├─ layout/Library/PreferenceLoader/.../NotifyBox.bundle/  # 设置入口（随主包安装）
└─ README.md
```

## 构建（WSL2 + Theos roothide）

把整个 `notifybox/` 拷到 WSL2 的 theos 项目目录，`THEOS_DEVICE_IP` 指向手机：

```bash
cd notifybox
make clean
make package FINALPACKAGE=1   # 产出 .deb（含 tweak + App + 设置）
make install                  # 装到手机
```

⚠️ 本机（Windows 沙箱）**无法编译**（缺 macOS/Xcode）；代码在 WSL2 里跑 `make`。

## CI 构建（GitHub Actions）✅ 可编

`.github/workflows/build.yml` 已就绪：push / PR / 手动触发都会在 `macos-14` runner 上
克隆 **roothide/theos** + 只拉 **iPhoneOS16.5.sdk**，`make package FINALPACKAGE=1`，
产出 `packages/*.deb` 并作为 artifact（`notifybox-deb`）上传。

> 🔴 两个「不改就必红」的兼容点（已改好）：
> 1. `TARGET = iphone:clang:16.5:16.0` —— theos/sdks **最高只有 16.5 SDK**，写 16.0 找不到 SDK。
> 2. 已删 `PRIVATE_FRAMEWORKS = BulletinBoard` —— `%hook BBServer` 是运行期查找、`BBBulletin` 自己声明接口，
>    **不需要链接**该私有框架；留着会在精简 SDK 里报找不到。

推到 GitHub 后取包：
```bash
git push origin main      # 触发 Build
# 之后到 Actions → 最新 run → Artifacts → notifybox-deb → 下 deb
```

## 🩺 真机零记录：先看日志，别猜（v0.0.3 起）

> 📌 **优先用 App 内「诊断 → 只看结论行」**：日志动辄 9 KB，全量翻很难抓重点。

Tweak 自己在 `/var/mobile/Library/NotifyBox/tweak.log` 写诊断日志，**并且盒子 App 也往同一文件写一行**。
这构成三段判据，能一次性把「没注入」「注入了但方法名不对」「方法对了但写库失败」分开：

| 打开 App → 诊断，看到什么 | 结论 | 下一步 |
|---|---|---|
| 只有 `[STORE ...] [APP-ALIVE] 盒子App 启动` | 路径可写，但 **tweak 没被注入** | 查 `NotifyBox.plist` 的 `Filter/Bundles`、确认装完做过 respring、确认 deb 版本 |
| `=== [SpringBoard] ... loaded ... =NO ... ===` | 注入成功，但**候选方法全不存在** | 看紧跟的 `sel:` 清单，把真名加进 `Tweak.x` |
| `--> 使用 G3 (publishBulletinRequest:forSectionID:forDestinations:)` 且随后有 `hit#` | ✅ **全通** | 记录应该已经进库 |
| `--> 使用 G3 ...` 但始终**没有** `hit#` | 方法挂上了但**没被调用** | 看 `P#` 探针行：谁被调用就去挂谁 |
| 有 `P#1 _sendAddBulletin:toFeeds:` 或 `P#1 addBulletin:toSectionID:` | 真入口是这两个之一 | 把记录逻辑迁到 G4/G5 |
| 有 `hit#1 bundle=... title=...` 但 App 里 0 条 | 录制跑通、**写库失败** | 找 `[STORE ...] INSERT 失败 / prepare 失败 / openDB 失败` |
| 日志文件都不存在 | **从未写过** | 见 `[APP-ALIVE]` 是否出现：不出现说明 App 都写不了 ⇒ 沙盒/权限问题 |

> 🔴 `debugSummary` 里「DB 存在、记录数 0」**不能**证明 tweak 跑过 —— App 自己调 `openDB` 就会建库建表。
> 唯一硬判据是 `tweak.log` 的 `loaded` 行。

`Tweak.x` 的 `%ctor` 会自动枚举 `BBServer` 上所有含 `publish`/`bulletin` 的选择器写进日志，
**不需要先手工猜方法名**：看清单里哪个像发布入口，再加进对应组。

### 已确证（v0.0.2 真机日志，9367 B）

- ✅ **注入本身是成功的**：`=== [SpringBoard] NotifyBox loaded ...` 打得出来。
- ❌ 但 `publishBulletin:=NO`、`_publishBulletin:destinations:=NO` ⇒ **两个候选名全猜错，一条都没录**。
- `=== BBServer 共 256 个方法，其中列出 66 个 ===` —— v0.0.2 把 66 条全打，**把结论行挤出了日志窗口**；
  v0.0.3 改成「只在候选全不存在时才打、每行 3 条压缩、结论行结尾再打一次」。
- `!!! [backboardd] BBServer 类不存在` ⇒ **只需在 SpringBoard 里挂**，backboardd 不管（过滤器里留着无害）。
- 真身从清单里读到：**`publishBulletinRequest:forSectionID:forDestinations:`** ⇒ v0.0.3 的 G3。

## ⚙️ 会不会跟 OneSettings / PreferenceLoader 冲突导致「设置」崩溃

**结论：tweak 本体不会。** 注入过滤器只有 `com.apple.springboard` 和 `com.apple.backboardd`，
**不含 `com.apple.Preferences`，也不含 OneSettings 的 bundle** ⇒ tweak 根本进不了设置进程。

唯一接触点是 PreferenceLoader 载荷 `NotifyBox.bundle`（`Entry.plist` + `root.plist`）。检查结果：

| 检查 | 结果 |
|---|---|
| 两个 plist 能被 plistlib 严格解析（含 XML 注释里非法的 `--`） | ✅ |
| `Entry.plist` 有 `cell=PSLinkCell` / `bundle` / `label`，且**没写指向不存在文件的 `icon`** | ✅ |
| `root.plist` 顶层有 `defaults`（`com.yxh41.notifybox`，与 `NOTIFYBOX_PREFS_PATH` 对齐） | ✅ |
| specifier 类型合规 | ✅ 修了 1 处：`keyboardType` 由字符串 `"numberPad"` 改为**整数 4**（`UIKeyboardTypeNumberPad`）。字符串会让 `integerValue` 得 0、键盘静默变默认；严格的第三方容器可能直接抛 |
| 是否覆盖 PL 核心文件 | ✅ 没有，只新增自己的 `.bundle` 目录 |

> 🔴 **A/B 归因法**（设置真崩了时唯一可靠的做法）：把
> `<jailbreak-prefix>/Library/PreferenceLoader/Preferences/NotifyBox.bundle` 临时改名加 `.off`
> （roothide 通常是 `/var/jb`），respring 后再进设置。
> **仍崩 ⇒ 不是我们；不崩 ⇒ 是我们的 bundle**，把改名前的崩溃日志一起发我。
> 崩溃日志位置：`/var/mobile/Library/Logs/CrashReporter/Preferences-*.ips`（或 `OneSettings-*.ips`）。

## 🔴 真机必须确认的事项（Flex3 / 砸壳后头文件核对）

1. **BBServer 的发布入口方法名**：v0.0.2 起**自动探测**（`publishBulletin:` / `_publishBulletin:destinations:`），
   两者都不存在时日志会打印真实 `sel:` 清单，照着加即可。**不要同时 hook 同一个真实方法**，会重复处理。
2. **BBBulletin 的属性名**：`sectionID` / `title` / `message` / `subtitle` / `date` / `sound`
   在 iOS 16 是否就叫这些（尤其 `sectionID` 是否等于 App 的 bundleId）。`NotifyFilter.h` 里是最小接口。
3. **DB 路径可达性**：roothide 下盒子 App 能否读写 `/var/mobile/Library/NotifyBox/`？
   不行就改用 App Group 容器或 daemon 中转。**`[APP-ALIVE]` 那行就是这条的判据**。
4. **换提示音 API**：`BBBulletin.sound` 在 iOS 16 接受什么类型（UNNotificationSound / 路径），
   `NotifyFilter.m` 的 `applyToBulletin:` 里是占位，确认后再填。

## 功能 ↔ 实现 映射

| 需求 | 实现位置 | 阶段 |
|---|---|---|
| 记录通知 + App/内容/时间 | `NotifyStore.recordWithBundle:...` | MVP ✅ |
| 记录上限 | `NotifyStore.maxRecords` + 裁剪 SQL | MVP ✅ |
| 白/黑名单 | `NotifyFilter.shouldDrop:`（读 prefs） | MVP ✅ |
| 按 App 筛选（图标栏） | `ViewController` 顶部 `iconBar` + `queryWithBundle:` | MVP ✅ |
| 时间筛选 / 搜索 | `sinceFromSeg` / `queryWithBundle:search:` | MVP ✅ |
| 关键词过滤 | `NotifyFilter.shouldDropBundle:...`（blockKeywords） | 阶段2 ✅ |
| 内容替换（规则） | `NotifyFilter.applyReplaceRulesTo:` + `ReplaceRulesViewController` | 阶段2 ✅ v0.0.14 页面重做 |
| 延迟推送 | `NotifyFilter.shouldDelayBundle:seconds:` + 三个入口 `dispatch_after` 再 orig | 阶段3 ✅ v0.0.14 |
| 按 App 换提示音 | `NotifyFilter.applyReplaceRulesTo:`（appSounds，待确认 API） | 阶段3 ⚠️ 等 PROBE 数据 |
| 朗读（TTS） | `NotifySpeaker`（AVSpeechSynthesizer） | 阶段3 ✅ v0.0.12/13 |

## 🔴🔴 v0.0.3 进安全模式：病因与铁律（v0.0.4 已修）

真机崩溃报告：

```
SpringBoard (com.apple.springboard)
EXC_BAD_ACCESS (SIGSEGV)  KERN_INVALID_ADDRESS at 0x0000000000000001
"The app read or wrote through a null pointer (address 0x1)
 – an object was released or was never created."
```

**唯一变量对照（硬证据，不是猜）：**

| 版本 | 实际 init 的 hook 数量 | 结果 |
|---|---|---|
| v0.0.2 | **0 个**（G1/G2 方法都不存在，init 指令没执行） | 不崩 |
| v0.0.3 | **1 个**（探针 G4 `_sendAddBulletin:toFeeds:`） | **崩进安全模式** |

**病因**：G4 的探针我声明成了 `- (void)`，但**原方法的返回类型我并不确定**。
一旦原方法返回对象，ARC 会在这个「声明为 void 的 hook」里把返回值丢掉并 release，
调用方稍后再用该对象 ⇒ 已释放 ⇒ 访问 `0x1`。

> 🔴🔴 **铁律：不知道原方法的完整签名，就不要 hook。**
> 正确顺序是先用 `method_getTypeEncoding` 把签名**量出来**（纯只读、零风险），
> 再照着编码逐字写 hook 的返回类型与参数类型。**不许用 `void` 当默认值蒙。**

### v0.0.4 的做法

零 hook 诊断版，只做三件只读的事：

1. 确认 `BBServer` 在哪个进程里存在；
2. `class_copyMethodList` + **`method_getTypeEncoding`**，把每个候选方法的**精确类型编码**写进日志
   —— 例 `v32@0:8@16Q24` 即「返回 void；参数 = self, _cmd, 对象, unsigned long long」；
3. 结论文本放日志最后，保证一定落在 App 的 tail 窗口内。

App「诊断」新增 **「方法清单（SEL+ENC）」**，一眼看全所有签名，截图即可。

另外为排除「设置 App 崩溃」这个变量，本轮**暂时把 PreferenceLoader 载荷移出打包**
（`layout/` 改名为 `_layout_disabled/`，Theos 只打包 `layout/`）。
确认设置正常后，下一版再搬回来——或者改为把设置直接做进盒子 App，彻底不依赖 PreferenceLoader。

### 🔴🔴 v0.0.5 App 崩溃：NSInvocation 的 ARC 过度释放（v0.0.6 已修）

真机崩溃报告：

```
NotifyBoxApp (com.yxh41.notifybox.app)  0.0.5
EXC_BAD_ACCESS (SIGSEGV)  KERN_INVALID_ADDRESS at 0x00000000d9c90e120
"The app touched memory it does not own, at address 0xd9c90e120
 – usually an object that was already freed."
```

病因在 `iconForBundle:` 取 App 图标那几行：

```objc
NSData *data = nil;
[inv getReturnValue:&data];     // ❌ getReturnValue 写裸指针、从不 retain
if (data.length) img = [UIImage imageWithData:data];
// 方法结束时 ARC 仍会 objc_release(data) ⇒ 过度释放 ⇒ 野指针
```

**正确写法**（先 `__unsafe_unretained` 承接，判类型后再赋强引用，赋值时才 retain）：

```objc
__unsafe_unretained id ret = nil;
[inv getReturnValue:&ret];
if ([ret isKindOfClass:[NSData class]]) img = [UIImage imageWithData:(NSData *)ret];
```

> 🔴 这个 bug **只在「有记录、需要画图标」时才触发**——列表空的时候永远不崩。
> 所以 v0.0.2~v0.0.4 都安然无恙，v0.0.5 一有记录就崩。
> 反过来看，**「App 崩在画图标」本身就是「库里已经有记录」的旁证**。

## 🩺 v0.0.6 新增：环境自检（不依赖日志文件）

上一轮出现一个自相矛盾的现象：App 侧疑似有记录（会崩在图标），但 `tweak.log` 却**不存在**。
这两件事不可能同时成立（`%ctor` 一跑就会写日志），所以必须拿到不依赖日志的现场。

App「诊断 → **环境自检（不依赖日志）**」现在会报：

| 项 | 说明 |
|---|---|
| 目录存在 / 可写 | `/var/mobile/Library/NotifyBox` |
| **写入测试 + errno** | 真写一个 `.probe` 再删，比 `isWritableFileAtPath` 可靠 |
| DB 存在 / 大小 / **记录数** | 记录数是「tweak 到底有没有工作」最直接的证据 |
| 日志文件是否存在 / 大小 | |
| **`.tweak_ctor` 装载标记** | tweak 在 `%ctor` 第一件事就写它，**与日志文件相互独立** |
| dylib 安装位置 | 逐个探 `/var/jb/...`、`/Library/...`、`TweakInject/...`，报命中的那个和大小 |
| 注入过滤器内容 | 直接把 `Filter/Bundles` 读出来 |

判据：

| `.tweak_ctor` | tweak.log | 结论 |
|---|---|---|
| 有 | 有 | 正常，看日志内容 |
| 有 | 无 | **注入成功、但写日志失败**（路径/权限问题） |
| 无 | 无 | **真的没注入**（没 respring / 过滤器未命中 / 版本没装上） |

另外导航栏标题改成 **`消息盒子 (N)`**，N 是 DB 总记录数——这个数不经过列表渲染，
即使列表因为别的原因崩了，也能一眼看出库里有没有东西。

## ⚙️ 设置 App 崩溃：已确认与 PreferenceLoader 载荷相关

移除载荷 + 补 `Info.plist` + 修 `keyboardType` 类型之后，用户确认 **设置 App 能正常进入**。
⇒ 之前「设置崩溃」的病根在那个 prefs bundle（最可能是缺 `Info.plist`）。
载荷暂时仍留在 `_layout_disabled/`，等录制链路验收后再加回并复验一次。

## ✅ v0.0.6 真机验收通过（录制链路通了）

真机环境自检结果：

```
目录 /var/mobile/Library/NotifyBox     存在=是  可写=是  写入测试=成功
DB   notifybox.sqlite                  存在=是  大小=217088 B  记录数=500
日志  tweak.log                         存在=是  大小=22130 B
标记  .tweak_ctor                       ✅ SpringBoard v0.0.6（tweak 确实注入过）
App 标题                                消息盒子 (500)
```

- **记录数 500 = maxRecords 上限**，说明通知一直在进、上限裁剪也在正常工作；
- **App 标题能显示 `(500)` 且不再崩溃** ⇒ NSInvocation 那个过度释放确实是崩溃根因；
- `dylib 安装位置` / `注入过滤器 plist` 两项报“没找到”属正常 —— roothide 把前缀重定向了，
  App 侧猜路径必然落空。v0.0.7 起改为**由 tweak 用 `dladdr` 自报真实路径**。

## v0.0.7（设置界面回到包里）

| 改动 | 原因 |
|---|---|
| **PreferenceLoader 载荷加回** | 之前为二分“设置崩溃”临时移除；已补 `Info.plist`（BNDL）+ `keyboardType` 整数化，用户复测设置能进 |
| tweak 用 **`dladdr`** 上报 dylib 真实路径 | roothide 前缀重定向，App 猜路径必落空；写进 `.tweak_ctor` 的 `dylib=` 字段 |
| 日志 **512 KB 自动轮转** 到 `tweak.log.1` | 22 KB 且持续增长，长期跑会把分区写满；用计数器节流，每 200 次写才 stat 一次 |
| 修 `errno` 误导显示 | 之前「写入测试=成功」旁边并列 `errno=2`，读者会以为失败；成功路径上 errno 本就可能残留（`writeToFile:atomically:` 内部先写临时文件） |

> 🔴 **如果这版设置 App 又进不去**，立刻回退载荷（把 `layout/` 改名）并把崩溃日志发我，
> 那就说明病根不在 `Info.plist`，我改用「设置直接做进盒子 App」的方案，彻底不依赖 PreferenceLoader。

## v0.0.7 交付校验（机器对拍，非目测）

CI run **#14**（`a455a3c`）success，产物 30123 B；下载后逐项校验：

| 检查项 | 结果 |
|---|---|
| ar 成员 | `debian-binary` / `control.tar.gz` / `data.tar.lzma` |
| `control` Version / Arch | `0.0.7` / `iphoneos-arm64e` ✅ |
| tweak dylib | `Library/MobileSubstrate/DynamicLibraries/NotifyBox.dylib` 90064 B，**arm64e**（cpusub `0x80000002`）✅ |
| 盒子 App | `Applications/NotifyBoxApp.app/NotifyBoxApp` 108576 B，**arm64e**（filetype=2）✅ |
| App Info.plist | `com.yxh41.notifybox.app` / `CFBundleExecutable=NotifyBoxApp` / 名称「消息盒子」/ 版本 `0.0.7` ✅ |
| 偏好包三件套 | `NotifyBox.bundle/{Info.plist, root.plist}` + `Entry.plist` 齐全 ✅ |
| 偏好 `Info.plist` | `CFBundlePackageType=BNDL`、`CFBundleIdentifier=com.yxh41.notifybox.prefs` ✅ |
| `root.plist` 的 `keyboardType` | 类型是 **int**（值 4）✅（之前是字符串 `"numberPad"`，是设置崩溃的可疑病根） |
| 设置键名 ↔ 代码读取 | `defaults=com.yxh41.notifybox` → `NOTIFYBOX_PREFS_PATH`，`maxRecords`/`whitelist`/`blacklist`/`blockKeywords` 键名逐字一致 ✅ |
| dylib 内字面量 | `dylib=` / `.tweak_ctor` / `tweak.log` / `.1` / `v0.0.7` / 三个挂点选择器 全命中 ✅ |
| 反向检查 | **不含** `_sendAddBulletin:toFeeds:`（v0.0.3 安全模式的崩点）✅ |
| cpusubtype 读法 | 🔴 必须按**无符号**读；按有符号读会把 `0x80000002` 显示成 `-0x7ffffffe`，误判「不是 arm64e」 |

> 🔴 **本轮踩到的期望表错误（全部改期望、不动包）**：App 目录叫 `NotifyBoxApp.app` 不是 `NotifyBox.app`；
> 版本字面量是 `v0.0.7` 不是 `V007`；轮转后缀是 `".1"` 不是 `tweak.log.1`；
> App 二进制里**没有** `v0.0.7`（版本在 `Info.plist`，源码里那两处只是注释）；cpusubtype 读成负数。
> 口诀照旧：**期望必须逐字从源码抄**。

## 🔴 本版明确「没接线」的功能（别当 bug 报）

> ✅ **后续状态补记（2026-10-25，v0.0.49 收尾时补）**：下表是 **v0.0.7 当时**的状态，不是现状。
> 白/黑名单/关键词过滤 v0.0.8 起接线生效；内容替换 v0.0.14；朗读 v0.0.12/13；
> 按 App 换提示音 v0.0.25（`SBNCSoundController` 闸门自播）。
> **延迟推送 v0.0.19 已整体删除**（v0.0.15 / v0.0.18 两版实现各撞崩一次 SpringBoard，
> 结论见 v0.0.19 章）—— 本文开头的功能清单已同步，这条永远不再是待办。

`NotifyFilter.m` 被编进了 dylib，但 `Tweak.x` 里**一次都没有调用** `NotifyFilter`
（`shouldDrop:` / `applyToBulletin:` 零引用）。所以在 v0.0.7：

| 功能 | 状态 |
|---|---|
| 通知记录 / 上限裁剪 / 三入口去重 | ✅ 真机已验收（v0.0.6 起） |
| 设置界面（上限、名单、关键词输入框） | ⚠️ 本版目标 = 只验证「设置 App 能不能进」，填了**不会生效** |
| 白名单 / 黑名单 / 关键词过滤 | ❌ 代码在、没接线 |
| 内容替换 `replaceRules` / 按 App 换提示音 `appSounds` | ❌ 同上，且声音 API 仍是 🔴 TODO |
| 延迟推送 / 朗读 | ❌ 未开始 |

下一版（v0.0.8，已完成）：把 `shouldDrop` 接进三个挂点的记录之后、原方法之前。
🔴 实现时发现「接线」比预想的危险 —— 见下节。

## 已知坑 / 待办

- **延迟推送**风险最高：再注入的 bulletin 不走 App 自身逻辑，属「再展示一次」，体验需评估。
- **App 图标**：已用 `LSApplicationProxy applicationProxyForIdentifier:` + `iconDataForVariant:` 取真图标
  （顶部筛选栏 + 列表左侧）。`iconDataForVariant:` 的 variant 取值（当前 0=默认图标）若拿到空图，
  真机调一下即可。纯 App 侧、不依赖 hook 方法名，已落地。
- **声音 / 延迟**两项的 iOS 16 具体 API 未在沙箱内验证，标记了 🔴 TODO。
- **roothide 沙盒**：tweak 与 App 共享 DB 的路径需真机确认可写。

## v0.0.8（设置搬进盒子 App，彻底不碰设置 App）

### 为什么放弃 PreferenceLoader（结论，不再回头）

v0.0.7 把偏好 bundle 加回包里后，设置 App **又进不去**，而且**没有崩溃日志**。
这个组合本身就是判据：

| 现象 | 说明 |
|---|---|
| 没有崩溃日志 | **不是闪崩**。闪崩一定有 `.ips`；没有 ⇒ 挂起 / 被跳过 / 根本没走到崩溃 |
| 只在包里有 `Preferences/NotifyBox.bundle` 时复现 | 两次对照：移除就好、加回就坏 |
| 设置 App 是系统 App | 在别人的进程里去盲调一个不归自己控制的加载器，收益低、代价高 |

⇒ 继续在 PreferenceLoader 上二分没有收益（连接下来该调哪个字段都无从观察）。
直接换通道：设置做进自己的 App，`Preferences` 载荷从包里移除。
dpkg 升级时会自动删掉旧版本留下、新包里没有的那些文件。

### 改动

| 改动 | 说明 |
|---|---|
| **移除 PreferenceLoader 载荷** | `layout/` → `_prefs_disabled/`（源码留档、不再打包）；`control` 去掉 `preferenceloader` 依赖 |
| **内置设置页** | `app/SettingsViewController.{h,m}`，盒子 App 导航栏左侧「设置」 |
| **设置存储换位置** | `/var/mobile/Library/NotifyBox/settings.plist`（原在 `Library/Preferences/` 域） |
| **修掉一个会崩的写法** | `arrayFromPref:` 里的 `valueForKey:@"stringByTrimmingCharactersInSet:"` |
| **过滤/替换真正接线** | 三入口统一走 `NBPipeline` |
| 环境自检加「设置」段 | 直接显示设置文件、生效项数和每一项的值 |

### 🔴 为什么设置不能继续放 `Library/Preferences/`

那个目录归 **cfprefsd** 管。App 用 `writeToFile:` 直接写文件，而 cfprefsd 手里有自己的缓存，
随时可能把文件盖回去 ⇒ 出现「我改了、也提示保存成功、就是不生效」这种最难查的幽灵故障。
新位置是我自己的文件，**单一写入者（App）**、tweak 只读，不经过 cfprefsd。

### 🔴 顺带排掉一个炸弹（这段代码以前从没被调用过）

```objc
// v0.0.7（错，会崩）
return [[v componentsSeparatedByString:@","] valueForKey:@"stringByTrimmingCharactersInSet:"];
```
`NSArray` 的 `valueForKey:` 拿到带冒号的键，KVC 取不到 ⇒ 抛 **`NSUndefinedKeyException`**
⇒ 这段跑在 SpringBoard 里，就是闪退 / 进安全模式。
它一直没炸，**只因为 `NotifyFilter` 从来没被调用过（死代码）**。
这一版要接线所以必须先修 —— **「接线」不是免费的：调用一个从未被调用过的函数，
等于第一次执行它里面的每一行。**
同族风险还有：对传入对象直接发 `[obj sectionID]`，对象不响应就抛 `NSInvalidArgumentException`。
所以过滤接口改成了**纯字符串入参**，完全不碰传入对象。

### 接线后的顺序（有讲究）

```
① 记录原文 → ② 用原文判定是否拦截 → ③ 内容替换 → ④ 原方法
```
- **先记录**：被拦掉的通知在盒子里仍能查到「本来要推什么」；
- **用原文判定**：若先替换再判定，用户配「把"红包"替换成空」又过滤"红包"，过滤会永远不命中；
- **任何异常都放行**：宁可多推一条，也不要把通知吞掉；
- 认不出 bundle 的通知**一律不拦**。

### ⚠️ 行为变更（默认安全）

- 没有任何设置时：`shouldDrop` 返回 NO、替换直接返回 NO ⇒ 行为与不装插件**完全一致**；
- **白名单一旦填了就等于「只保留这些 App」**，其它全不弹 —— 这是它的语义，但杀伤力大，用前想清楚；
- 想彻底关掉：设置页清空全部字段后保存，或直接删 `settings.plist`。

## 取包方式（v0.0.8 起，不需要 PAT）

CI 现在多一步 `Publish deb to ci-deb branch`：用 CI 内置的 `GITHUB_TOKEN` 把 deb 推到公开分支 `ci-deb`。

```
https://raw.githubusercontent.com/yxh41/NotificationBox/ci-deb/com.yxh41.notifybox_0.0.8_iphoneos-arm64e.deb
```

- 浏览器直接看分支：`https://github.com/yxh41/NotificationBox/tree/ci-deb`
- ⚠️ `raw.githubusercontent.com` 在国内常常连不上（实测本机 `curl` 直接被 reset）。
  连不上就走网页版分支页下载，或继续用 Actions 页面的 artifact。
- artifact 的 API `/zip` 端点**必须鉴权**（匿名 401）；`nightly.link` 可匿名取，
  **对 failed run 里已上传的 artifact 也有效** —— 但必须用包内版本号自证不是拿了旧包。

### 这一步踩过的坑

```bash
DEB=$(ls packages/*.deb | head -1)   # 相对路径
cd /tmp/pub
cp "$DEB" .                          # ← 先 cd 后 cp，相对路径失效
```
报 `cp: packages/....deb: No such file or directory`，而文件明明存在。
修法：`DEB=$(ls "$GITHUB_WORKSPACE"/packages/*.deb | head -1)`，且 `cp` 放在 `cd` 之前。
🔴 通用规律：**shell 里「先 cd 再引用旧相对路径」都是雷**；出现"文件不存在"但文件确实在，先查 cwd。

🔴 另一个教训：`conclusion=failure` 是整条 workflow 的与门，**必须看是哪个 step 红了**。
那次 `Build package` 和 `Upload deb` 都是 success，失败的只是我新加的便利步骤
⇒ **包本身是好的**。加"便利步骤"的代价就是会把原本全绿的流水线弄红，要有心理准备。

## v0.0.9（内容替换规则可编辑 + 诊断修正）

v0.0.8 真机自检通过（记录数 800 顶在上限、设置读到 `blockKeywords=限时`、tweak 注入 ✅），
但截图里暴露出一个**假红灯**和一个判据缺口，这版一起修，同时补上第一个真正可用的「进阶功能」。

### 🔴 假红灯：「未读到过滤器 plist」

自检里 dylib 位置显示 ✅（tweak 用 `dladdr` 自报 `.../.jbroot-D50FC3217E2182E5/usr/lib/TweakInject/NotifyBox.dylib`），
但下一段「注入过滤器」却报 ❓ —— 因为候选路径写死成 `/var/jb/...` 和 `/Library/...`。

> **tweak 早就把真实路径上报了，我却在下一个检查项里又回去猜路径。**
> 同一个「猜路径」的错，在同一个函数里犯了两次。

修法：用上报路径的 `stringByDeletingLastPathComponent + "NotifyBox.plist"`，猜不到才退回候选。
**通用规律：凡是「换个环境就换个位置」的东西，判据必须从已知的真实位置推导，不能写死。**

### 判据缺口：记录数顶在上限时，「数」是死的

`记录数=800` 而 `maxRecords=800` ⇒ 这个数永远等于上限，**看不出还在不在收**。
新增「**最新一条=…（N 分钟前）**」（`SELECT MAX(ts)`）—— 这才是「是不是早就断了」的硬指标。

### 新功能

| 功能 | 说明 |
|---|---|
| **内容替换规则编辑** | 设置 →「内容替换规则」：列表 + 添加/左滑删除，`from → to`；引擎（0.0.8 已接线）直接消费 |
| **清空全部记录** | `NotifyStore.clearAll` 一直有实现却**没有任何入口**（又一例死代码），这版接上，带二次确认 |
| `REPL#` 日志 | 替换生效的唯一证据；进「结论行」 |
| `DROP#` 进「结论行」 | 过滤真拦过的唯一证据 |
| 统一设置写入点 | `NotifyStore +settings / +saveSettings:`，避免每个 VC 各写一遍 `writeToFile:` |

### 🔴 为什么替换必须留 `REPL#` 日志

替换是**静默**的：配了规则没生效，界面上完全看不出来。日志里从来没有 `REPL#` 只有两种可能：

1. 没配规则 → 看「设置」段的生效项里有没有 `replaceRules`；
2. 入口传进来的对象**没有 `setTitle:`/`setMessage:`**（request 包装类常见）⇒ 是「对象不对」，不是「规则没读到」。

这两种病因必须能分开，否则又是一轮盲猜。

### 死代码清单（同一个坑反复出现，记在这里）

| 符号 | 状态 |
|---|---|
| `NotifyFilter` 全套 | 0.0.7 及以前**从未被调用**（0.0.8 接线） |
| `arrayFromPref:` 的 KVC 写法 | 会抛 `NSUndefinedKeyException`，因是死代码才没炸（0.0.8 修） |
| `NotifyStore.clearAll` | 0.0.9 前**没有任何 UI 入口**（0.0.9 接上） |

> 结论：**「代码在包里」不等于「代码在链路上」**。每接一条新链路，都要把那段当新代码重读一遍。

## v0.0.10（列表能看到正文了 + 真 App 图标 + 图标诊断）

v0.0.9 真机日志已经证明引擎全通：
`DROP#1~4` 有拦截、`REPL#1~5 cls=BBBulletinRequest` 有替换（不再是死代码）。
但用户反馈两件事：**列表只有标题没有正文**、**图标栏只有首字母**。

### 🔴🔴 为什么「只有标题、没有正文」——一个很隐蔽的 UIKit 陷阱

```objc
[table registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
...
c.textLabel.text = title;
c.detailTextLabel.text = @"bundle · 时间\n正文";   // ← 写了，但永远不会显示
```

`registerClass:` 建出来的是 **`UITableViewCellStyleDefault`**，
而 **Default 样式的 cell 里 `detailTextLabel` 根本不存在/不显示**。
`dequeueReusableCellWithIdentifier:forIndexPath:` 只会给你 Default 样式，
**样式是注册时定的，运行期改不了**。所以正文一直被写进一个看不见的 label。

> 这类 bug 的特点：**代码没有错、编译没有警告、运行时也不报错**，只是画不出来。
> 判据只能是"看界面" —— 而它恰恰最容易被"我以为写了就会显示"骗过去。

修法：自定义 `NotifyCell`（图标 + 标题 + 正文两行 + 时间），`rowHeight = 82`。
**并且正文为空时明确显示 `(无正文)`**：留空的话，「库里没存到正文」和
「存了但没画出来」看起来一模一样 —— 上一版就是把这两种病因混在一起了。

### 🔴 为什么图标一直只有首字母：NSInvocation 参数宽度

旧代码：
```objc
int variant = 0;
[inv setArgument:&variant atIndex:2];   // 只准备了 4 字节
```
如果签名里该参数是 `Q`（8 字节），NSInvocation 会按 **8 字节**去读那块只有 4 字节的内存
⇒ 高 4 字节是垃圾 ⇒ 取到的 variant 是个乱数 ⇒ `iconDataForVariant:` 返回 nil ⇒ 退化成首字母。

修法：**参数宽度按签名来填，不能一律 `int`**。统一用 8 字节的 `unsigned long long`：
签名 4 字节时 NSInvocation 只拷低 4 字节，8 字节时正好拷满，两种都对。

另外把取图标独立成 `AppIconLoader`，按序试三条路并**记录每条路的成败**：

| 路 | 做法 |
|---|---|
| A | `LSApplicationProxy` + `iconDataForVariant:`（variant 依次试 0/1/2/3/8/14） |
| B | `UIImage` 私有方法 `_applicationIconImageForBundleIdentifier:format:scale:`（format 多档） |
| C | 直接读包内 `Info.plist` + png（新 App 的图在 `Assets.car` 里，必然失败） |

诊断 →「图标诊断（A/B/C 哪条通）」直接看结果；「清空图标缓存并重取」可重试。
**取图标没有任何一条保证成功的路，所以"哪条通"必须是可观测的，不能靠猜。**

### 另一个判据：正文到底存没存进库

「数据库自检」新增最近 3 条的**字段字节数**：

```
最近 3 条（字段字数）:
  1) com.tencent.mqq  title=48B message=0B subtitle=0B
```
- `message=0B` ⇒ 库里就没有正文（记录侧问题）
- `message>0B` 但界面空 ⇒ 渲染侧问题

**不把这个数打出来，这两种病因长得一模一样。**

## v0.0.11（图标变蓝 + 筛选无反馈）

### 🔴🔴 为什么 App 图标全变成蓝色剪影

`UIButton buttonWithType:UIButtonTypeSystem` 默认把 `setImage:` 进来的图当**模板图（template）**渲染：
**只用它的 alpha 当形状，然后用按钮的 `tintColor` 上色**。
App 图标是不透明方形图，alpha 全覆盖 ⇒ 整块被涂成主题蓝。

```objc
// 错：交给系统按钮前没改成原图模式
[b setImage:icon forState:UIControlStateNormal];      // → 一块蓝

// 对：先转成 AlwaysOriginal
img = [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
```

修在 `AppIconLoader` 返回前统一转换 —— **一处修，所有调用方（按钮、cell 的 UIImageView）都安全**。
UIImageView 同理：template 图也会被 `tintColor` 涂成单色。

⚠️ 注意：`全部` 那个 SF Symbol 本来就是**故意**用 template + `secondaryLabelColor`，
所以它保持 template；只有真图标需要 AlwaysOriginal。**"全部改成原图"是错的**。

### 顺带修的两处

| 问题 | 修法 |
|---|---|
| 退化态首字母也是蓝的 | 系统按钮标题默认走 tintColor ⇒ 显式 `setTitleColor:secondaryLabelColor` |
| 点完 App 筛选看不出选的是哪个 | 选中的那一格加 `borderWidth=2` + `systemBlueColor` 边框 |

> 筛选无反馈这类问题的共性是：**功能其实生效了，但"当前状态"不可见**。
> 和之前「存储成功却看不出效果」是同一类毛病 —— 凡是改变状态的交互，都要让状态可见。

---

## v0.0.12 · 通知朗读（阶段 3 第一件）+ 只读探针

### 朗读怎么开

盒子 App → 设置 → 顶部「朗读通知」开关。默认**关**。

- 「朗读限定 App」留空 = 所有 App 都念；填了 bundle id（逗号分隔）= 只念这些。
- 读的内容 = 标题 + 正文（两者相同只读一遍）。念的是**替换规则处理之后**的文字，
  跟通知上看到的一致。
- 被过滤规则拦下的通知**不念** —— 「别烦我」是那条规则的全部意图，
  屏幕上不弹、耳朵里还念出来是最糟的组合。
- 同一时刻只读最新一条：正在念的时候来了新通知，直接打断旧的。
  （不排队是故意的：群聊刷屏时排队会让你听到几分钟前的消息。）

### 🔴🔴 为什么它必须带「自毁保护」

朗读是整个插件里**唯一**去碰音频子系统的动作，也是唯一可能把 SpringBoard 拖崩的地方。
而一旦崩，用户面对的是连续安全模式 —— 想关掉朗读得先打开盒子 App，可 App 也打不开。
**这是个死锁**，不能指望用户操作。

所以：朗读开始前写 `.speak_guard = start`，`speakUtterance:` 正常返回后写 `done`。
下次进程启动时检查：

| guard 内容 | 含义 | 动作 |
|---|---|---|
| `start` | 上次写了开始、没走到结束 ⇒ 就崩在朗读里 | **强制把 speakEnabled 写回 NO**，留一行日志 |
| `done` / `crash-closed` / 不存在 | 正常 | 不动 |

顺序有讲究：`start` 必须在**任何 AV 调用之前**落盘。
反过来的话，崩在建 synthesizer 那一步时下次启动看不到 `start`，还会再试一次 ⇒ 每次开机崩一次。

### 三条硬约束（都踩过类型）

1. **必须在主队列调 `AVSpeechSynthesizer`**。它内部依赖 runloop，在 `publishBulletin:`
   的调用线程（不保证是主线程）上直接 speak 会静默不出声。
   `speakWithBundle:` 内部 `dispatch_async` 到主队列，绝不阻塞通知投递。
2. **去重必须用 `firstTime`**。三个发布入口会对同一条通知依次触发，
   去重表只让第一条落库，但调用方仍然拿到 bid ⇒ 下游跟着跑三次。
   这对过滤/替换无害（幂等），对朗读是灾难 —— 同一句话读三遍。
   所以 `NBRecordItem` 新增 `BOOL *firstTime` 出参把事实交出去。
3. **不显式指定语音语言**。写死 `zh-CN` 看着像"照顾中文用户"，
   实际在英文系统上会把英文读成怪腔，中文里混的英文单词（"Wi-Fi 已连接"）也会被读坏。
   不设 voice ⇒ 跟随系统语言，这是最不容易出错的选择。

### 埋了一个只读探针（为下一版取数）

「按 App 换提示音」和「延迟推送」都卡在同一个问题上：
**真机上的 `BBBulletin` 到底长什么样**。`sound` 这个名字是从公开资料推出来的假设，不是量出来的。
照假设写代码的结局通常是：编译过、装上、日志一行没有、界面毫无变化，
然后分不清「属性名错了」「判断错了」「根本没走到这一行」。

所以这一版先不实现功能，只量三样：

- `BBBulletin` / `BBBulletinRequest` / `BBSound` 各有哪些 property，**类型编码**是什么
  （`property_getAttributes` 最准：`T@"BBSound"` 是对象，`TQ` 是 unsigned long long，`TB` 是 BOOL）
- `BBSound` 有哪些**类方法**（能不能凭空造一个声音对象）
- 真机上 `sound` 到底是 nil 还是有值 —— 很多 App 用默认声音时它就是 nil

探针全部只读，一个 setter 都不调。日志里以 `PROBE` 开头，只在前 3 条通知上输出。

🔴 两个自己挖的坑，已经踩过：

- **`%ctor` 阶段可能拿不到 `BBBulletin`**（BulletinBoard 还没加载）。
  和 v0.0.3 那次 `class_getInstanceMethod` 返回 NULL 是同一类现象。
  ⇒ 拿不到就**不置"已 dump"标记**，留给第一条通知来的时候重试。
  否则探针会永久失效，日志里只留一句「类不存在」，白跑一整轮。
- **每个键必须单独 `@try`**：KVC 读不存在的键会抛。
  整段共用一个 `@try` 的话，第一个抛错的键会带走后面所有键的值
  ⇒ 看到「sound 之后什么都没有」会误判成"这些量不存在"，
  而真相只是"第一个键名写错了"。

### 顺带修的两个隐患

| 隐患 | 为什么危险 | 修法 |
|---|---|---|
| 设置页 `onSave:` 写死字段下标 | 在中间插一个新字段，后面所有键整体错位一格：改"白名单"实际写进"黑名单"。保存成功、回读一致、就是不生效，**无从发现** | 输入框和键名配对存进 `fieldKeys`，遍历时一起取 |
| 布尔设置的解读写了三份 | App 认 `"true"`、tweak 只认 `NSNumber` 时，用户看到"开关是开的、功能不生效" | 统一成 `NotifyCommon.h` 的 `NBBoolValue`（inline，两边都能用） |

> 这两条和之前几轮的毛病是同一个族：**错得很静默**。
> 判断标准不是"能不能跑"，而是"跑错了会不会有人发现"。

---

## v0.0.13 · 朗读可选声音 + 名单改成可搜索多选

### 一、声音：从"能出声"到"好听"

朗读在 v0.0.12 已经能出声，但**声音不对等于白做** —— iOS 自带的语音在不同机器上差很多，
有的机型只有 Ting-Ting 这类老式合成音。不给选择的话，用户听到的是"机器人在念经"。

设置 → 朗读声音：

- 列出 `[AVSpeechSynthesisVoice speechVoices]` 的全部语音，**系统语言优先**排在前面。
  （不硬编码"中文优先"：系统语言是英文的人最想先看到英文语音。）
- 每项显示「语言 · 标准/增强/高级」。增强和高级的明显更自然，
  但要在 系统设置 → 辅助功能 → 朗读内容 → 声音 里下载后才会出现。
- **点一下 = 选中 + 立刻试听**。不设单独的试听按钮，是因为
  "选了才听得到、听到了才知道要不要换"，合成一步用户少想一层。
- 语速四档（0.4 / 0.5 / 0.6 / 0.7），改完立刻用新语速试听。

存储：`speakVoice`（存 `identifier` 而不是 `name`）、`speakRate`（float）。

🔴 三个坑：

| 坑 | 后果 |
|---|---|
| 存 `name` 而不是 `identifier` | name 会随系统版本变（"Ting-Ting" 有时显示"婷婷"），升级后找不到语音 |
| 语速不夹范围 | 设置文件可手改，`rate=0` 几乎不动、`rate>1` 行为未定义，都表现成"朗读坏了" |
| App 里不配 audio session | 手机静音键一拨就听不到，用户以为"选声音没反应" ⇒ 用 `Playback` + `DuckOthers` |

语音被系统删掉时 `voiceWithIdentifier:` 返回 nil ⇒ **不设 voice（回退跟随系统）**，
既不报错也不静音。这是唯一正确的退化方向。

### 二、黑白名单：看不见的选择等于不能调整

原来是一个「逗号分隔 bundle id」的输入框。手填的问题不是"麻烦"，而是**填完就失控** ——
过几天回来，谁也不知道 `com.tencent.xin,com.apple.MobileSMS` 里那个 MobileSMS
当初为什么加进去，想删一个又怕删错。**看不见的选择等于不能调整。**

现在白名单 / 黑名单 / 朗读限定 App 三个都点进去选：

- 列表 = 已安装 App ∪ 历史来过通知的 App
- **已选的单独成一组排在顶部**，不用在长列表里找
- 搜索同时匹配**显示名和 bundle id**（用户有时记得"微信"，有时只记得半截 "tencent"）
- 有通知记录的 App 按条数排在前面 —— 用户想管的就是"老给我推通知的那几个"
- 点一下立即落盘，没有"保存"按钮可忘

### 🔴 枚举已安装 App：这件事没有一条保证成功的路

`LSApplicationWorkspace` 是私有 API，能不能用取决于 CoreServices 有没有加载、
以及 App 自身权限；目录布局又因 roothide 的前缀重定向而变。
所以做了三路兜底，并且**把每条路的成败记下来**：

1. `LSApplicationWorkspace.allInstalledApplications`（运行时查找 + 多种 dlopen 尝试）
2. 目录扫描 `/Applications`、`/var/jb/Applications`、`/var/containers/Bundle/Application`
3. **数据库历史**（这条永远可用）

第 3 条是兜底里最重要的一条：枚举全失败时，它至少还能把已配置的 App 列出来让你取消。

枚举失败是静默的（列表空 = 用户以为"我手机没装 App"），所以设置页多了一个
**「App 枚举诊断」**，直接列出哪条路走通了、各拿到多少个。

另外不在 `viewDidLoad` 里同步枚举：走目录扫描时要遍历几百个 UUID 目录，能卡一两秒，
同步做的话页面在这段时间里是一片空白（主线程被占，界面根本没画出来），
用户会以为点进去就死了。改成先渲染"正在枚举…"，下一轮 runloop 再枚举。

### 三、设置页布局重构

原来布局是「先排所有开关、再排所有输入框、再排所有按钮」，三组各排各的 ⇒
想让一行入口按钮夹在两个输入框中间**做不到**。

现在改成**一个 rows 数组按加入顺序排**，每行类型存在自己的 `tag` 里
（`kRowSwitch` / `kRowGroup` / `kRowAction`，子视图 tag 从 101 起，两套编号互不干扰）。
不是为了好看 —— 是为了以后加/删/挪一行不用改布局代码。

配套改了存储格式：`whitelist` / `blacklist` / `speakApps` 现在写**数组**，
但 `NBStringArray` 同时认数组和逗号字符串 —— 老版本存的是字符串，
不兼容的话升级后就是"我明明配了白名单，怎么全放行了"，而且完全静默。

### 四、顺带修的静默隐患

| 隐患 | 病 |
|---|---|
| `NBAddDiag` 定义成单参数 | 6 处调用都按格式串传 ⇒ CI 一串 "too many arguments"，报错全指向定义行，看着像别处的问题 |
| `[[self class] someClassMethod]` | clang 不知道 `[self class]` 是哪个类 ⇒ `-Werror` 报 "no known class method" ⇒ 调用点一律写类名 |
| 静态数组用对象字面量初始化 | ARC 下不允许：`static NSString *const a[4] = {@"a"}` 报 "initializer element is not a compile-time constant" ⇒ 名字改用函数返回 NSArray |

> 前两条都是**工具查不到的**：格式串自检当时是 PASS 的，因为它只看调用点写了几个参数，
> 不看被调函数是不是可变参数。现在已经给工具补了「签名必须是可变参数」这一条，
> 并用还原现场做了负向对照（改回单参数后工具精确报出那行）。

## v0.0.14 · 内容替换页重做 + 延迟推送

用户原话：「内容替换规则这个优化下，设置后都不清楚替换掉的是哪些，等设置的多的时候，那记得住那么多」。

### 🔴🔴 先修的那个 bug：替换目标从来没显示过

`ReplaceRulesViewController` 里写的是：

```objc
[self.table registerClass:[UITableViewCell class] forCellReuseIdentifier:@"r"];   // ← 病根
...
c.textLabel.text = from;
c.detailTextLabel.text = to.length ? [NSString stringWithFormat:@"→ %@", to] : @"→ （删除）";
```

`registerClass:[UITableViewCell class]` 建出来的是 **Default 样式**，
而 Default 样式的 `detailTextLabel` **根本不在视图层级里**（是 nil）。
样式在 `dequeue` 那一刻就定死了，运行期改不回来。

⇒ 那行 `→ 替换成什么` **从 v0.0.9 起就没显示过**。用户只能看到原文、看不到替换目标，
这正是他说的"不清楚替换掉的是哪些"。

同一个坑在 v0.0.10（列表只有标题没有正文）和 v0.0.13（App 选择器）已经各踩过一次。
现在这一页干脆不用系统样式，自己摆三个 label：

```
#1  限时
→ 删除（替换成空）
改过 12 条，另有 3 条被前面吃掉
```

用自绘而不是 `UITableViewCellStyleSubtitle` 的原因：Subtitle 的 `detailTextLabel` 是
**单行且高度固定**的，塞不下"替换成什么"+"统计"两段信息，长的替换内容会把统计挤掉
（尾部截断）—— 而统计恰恰是这次要解决的痛点。三行各自截断才互不干扰。

### 一、试运行：不用真发一条通知去试

顶部一块输入框，输入任意文字，实时显示：

- 套用后变成什么（结果为空就明说"整段都被删掉了"）
- 命中了哪几条规则（`命中 #1、#3`）

🔴 **它必须调用引擎里那个同一个函数**，不能在 App 里再写一份顺序套用：

```objc
// NotifyFilter.h（引擎与 App 共用）
+ (NSString *)applyRulesToString:(nullable NSString *)text
                           rules:(nullable NSArray *)rules
                            hits:(nullable NSMutableArray<NSNumber *> *)hits;
```

`applyReplaceRulesTo:` 也改成逐字段调它 —— 单一来源。
两份逻辑一旦走岔，用户看到的试运行结果就是**假的**，而假结果比没有结果更坏
（他会照着一个错的结果去调规则）。

顺带得到一个真实的行为修正：`from == to` 的规则以前会被算作"改过"
（`rangeOfString` 找到了就算），现在因为比较替换前后字符串，**正确地算作没改**。

### 二、逐条命中统计：包括"被前面的规则吃掉"

对盒子里最近 2000 条通知的**原文**，按顺序模拟套用（与引擎完全一致：
标题/正文/副标题各套一遍，三个字段互不影响），统计：

| 显示 | 含义 |
|---|---|
| 改过 N 条 | 这条规则真的把这些通知改掉了（绿字） |
| 最近的通知里没命中过 | 原文里根本没有这个词 |
| ⚠️ 被前面的规则吃掉 N 条 | 原文里本来有，但已经被上面的规则先改没了，轮到它时匹配不到（橙字） |
| ⚠️ 和原文一样，等于没配 | `from == to` |

"被前面吃掉"这一列是这次最值钱的东西：**顺序套用最容易踩的坑是静默的** ——
用户只会觉得"这条规则没生效"，然后删掉重加、越配越乱。

统计在**下一轮 runloop** 才算（不在 `viewDidLoad` 同步做）：读库 + 2000×3×N 次字符串套用，
同步做会占住主线程 ⇒ 首帧画不出来 ⇒ 用户看到一个空白页以为页面坏了
（v0.0.13 的 App 选择器已经踩过同类坑）。

刷新统计时只 `reloadSections:`，不整表 `reloadData` —— 后者会把正在输入的试运行输入框的键盘收掉。

### 三、点一条规则可以改它的替换内容

之前只能删了重加（而且因为看不到替换目标，等于只能瞎删）。
现在点进去预填当前的 `to`，原位替换（**顺序不变** = 用户看到的位置不变）。

### 四、延迟推送（阶段 3）

语义：命中的通知**不立即弹出**，延后 N 秒再交给 BBServer 的发布方法。

设置页：`延迟推送（秒，0 = 关闭）` + `延迟生效的 App`（可搜索多选，空 = 全部）。

实现要点：

- **默认关闭**（0）。它是唯一会改变"通知到达时间"的功能，风险最高。
- 秒数夹在 1~600；设置页严格校验（只认纯数字）。填 `abc` 会被 `integerValue` 读成 0
  = 关闭，保存显示成功、用户等半天等不到通知却说不出所以然；填 86400 等于让通知永不出现。
- 流水线返回值从 `BOOL` 换成结构体，因为"放行"和"晚 N 秒"是两个维度：

```objc
typedef struct {
    BOOL allow;            // NO ⇒ 不执行原方法（被过滤）
    NSTimeInterval delay;  // >0 ⇒ 延后这么多秒再执行原方法
} NBDecision;
```

  ⚠️ ARC 禁止结构体持有 ObjC 对象指针，所以 bundle 不进结构体（需要它的日志在流水线内部打掉）。

- 延迟判定放在**过滤之后**（被拦掉的不该进队列）、**朗读之前**（日志顺序=执行顺序）。
- 三个挂点各自 `dispatch_after` + 块内 orig：
  block 会**强引用住** bulletin，这是延迟能成立的前提；orig 在块里是合法的
  （Logos 把它展开成对静态函数指针的普通 C 调用，`self`/`_cmd` 都会被正常捕获）；
  到期落在**主队列**（SpringBoard 里唯一一定存在的队列，BBServer 发布本身是线程安全的）。
  `_publishBulletinRequest:forSectionID:...` 的 `sectionID` 也必须一起被捕获住。
- 日志配对：`DELAY#n bundle=... 5.0s` / `DELAY-FIRE#n tag=...`。
  只有 DELAY 没有 DELAY-FIRE ⇒ 定时器没走到；两者齐全但通知没出现 ⇒ 系统那边已放弃这条。
  这两种结论对应的下一步完全相反，所以必须能分开。
- 朗读**不跟着延迟**：延迟改的是"弹窗什么时候出现"，朗读是即时播报。两者同时开时先听到、
  N 秒后才看到，设置页里写明了。不做成"一起延后"是刻意的 —— 朗读是刚在真机上验证过的功能，
  不想为了组合场景去动它的调用路径。

### 五、新增一道离线闸门 `nb_syntax_guard.py`

本地没有 theos/macOS，一次 CI 往返要几分钟，而两类错在多文件改动时最容易漏：

1. 花括号 / 圆括号失衡（**含字符串里的括号不能被误当代码**）
2. `@interface` 扩展里声明了、`@implementation` 里却没实现
   （clang `-Wincomplete-implementation` 默认开，CI 报 error）

以及 `NBLog(@"...100%")` 这种裸 `%`（`%c` 被当转换符）。

> 🔴 这个工具**第一版自己就是坏的**：根目录按脚本自身路径反推 ⇒ 不管 cwd 在哪都只查真实项目
> ⇒ 负向对照（故意塞错的假项目）5 条全部漏报，工具还报 PASS。
> 修成可由 argv 指定根目录后 6/6 通过（正常/缺右花括号/少一个实现/字符串里带括号/裸 %/多一个右圆括号）。
> 又一例「判据域必须等于变异域」。

### 六、顺带排掉两个「会翻车」的地方

**① 空状态不能用 `table.backgroundView`**

v0.0.9~v0.0.13 用 `backgroundView` 显示"还没有规则"的提示，因为那时整页只有规则列表，
空表 = 整页空白。v0.0.14 起页面**顶部永远有「试运行」两行** ⇒ `backgroundView` 是衬在
cell **后面**的，提示文字只会从分组之间的缝隙里露出来一角，看着像渲染坏了。
空状态说明改放到规则那一节的 footer 里。

**② 左滑删除不能只删那一行**

`numberOfRowsInSection:kSecAction` 是按 `self.rules.count` 算的（有规则才显示"清空全部规则"）。
删掉**最后一条**规则时，规则节 1→0 行、操作节 1→0 行，两节同时变。
只调 `deleteRowsAtIndexPaths:` 删一行 ⇒ 第二节的行数交代不平 ⇒

```
Invalid update: invalid number of rows in section 2.
The number of rows contained in an existing section after the update (0)
must be equal to the number of rows contained in that section before the update (1)
```

⇒ 断言崩溃。所以改成：数组删掉 + 落盘 + **下一轮 runloop 整表 reloadData**
（也不要在 `commitEditingStyle:` 里同步 reloadData —— 删除事务没提交完，有的版本会把左滑状态卡住）。

> 教训：**任何"局部改行数"的 API（`deleteRows` / `insertRows` / `reloadRows`）都必须把这
> 一次改动的所有受影响节一起算进去。**只要行数来源是"某个数组的 count"，
> 数组一变就可能同时影响多节 —— 这种崩溃在本地看不出来，只会在用户删到第 0 条时炸。

## v0.0.15 · 止血：延迟推送停用 + 数据库锁修复

### 🔴🔴 事故：延迟推送导致 SpringBoard 崩溃（安全模式）

真机现象（iPhone13,3 / iOS 16.4.1，2026-10-21 15:51:30）：

```
SpringBoard  com.apple.springboard  1.0 (50)
The Swift runtime trapped: a fatalError, a failed precondition,
a force-unwrapped nil or an array index out of range.
EXC_BREAKPOINT (SIGTRAP)
```

打开「延迟推送」之后出现，15:51:30 崩、15:51:36 重新拉起。

**为什么这条实现不牢**（三个候选，都还没排除，需要 `.ips` 的故障线程栈才能定位）：

1. **对象生命周期** —— 日志里 `REPL#n tag=PBR cls=BBBulletinRequest` 说明传进来的确实是
   `BBBulletinRequest`。调用方在同步返回后可能已经把它消费/作废了；N 秒后再拿它去发布，
   内部 force unwrap 到 nil 就是 SIGTRAP。**这一条最像。**
2. **同一条通知命中 2~3 个入口** —— 同步时 PB/PBR/PBRS 挤在同一毫秒，由 BBServer 自己合并；
   延迟后变成 3 个独立定时任务去发布**同一个对象**，第一个发布之后剩下的就是
   "拿已经用过的对象再发一次"。
3. **线程/队列** —— 这三个方法大概率跑在 BulletinBoard 自己的串行队列上；我们从主队列
   回调进去，可能踩到内部的 queue/actor 前置条件（"failed precondition" 正好是这个形状）。

> 教训：**「能拦下来」不等于「能攒起来晚点再交出去」。**
> 前四个版本做的所有事（过滤、替换、朗读）都是在**同一次同步调用里**完成的，
> 所以从来没碰过对象生命周期。延迟是第一个跨时间的动作 —— 它把"调用栈内的局部对象"
> 变成了"要活过 N 秒的东西"，而这从来不是我们说了算的。

### 本版做了什么

1. **延迟推送整条停用**：`NotifyFilter.m` 里 `kDelayEnabled = NO`，
   `shouldDelayBundle:` 第一句就 `return NO` ⇒ 三个 hook 的延迟分支全部走不到。
   代码保留（注释里写清停用原因），为了拿到栈以后能继续。
2. **自毁保护（第二道保险）**：延迟路径上调度前写 `.delay_guard = start`，
   原方法返回后才写 `done`。下次启动若看到 `start` 没有 `done` ⇒ 上次崩在延迟里
   ⇒ 自动删掉 `delaySeconds`。**以后每次实验最多崩一次**，不会陷入崩溃循环。
3. **主动清除历史值**：停用了就 `%ctor` 里把用户 plist 里的 `delaySeconds` 删掉。
   留着一个永远不生效的值，只在给未来埋雷 —— 哪天重新启用，他一升级就落在崩溃路径上。
4. **设置页把「已停用」写在标题里**：功能被停用这件事本身必须可见；
   藏在代码注释里等于骗人，用户只会以为自己填错了。

### 顺带修：数据库锁导致通知被静默丢弃

真机日志里反复出现：

```
INSERT 失败 rc=5 err=database is locked bundle=com.jd.jingmai
INSERT 失败 rc=5 err=database is locked bundle=com.lemon.lv
```

`rc=5` = `SQLITE_BUSY`。**两个进程都在写这个库**（SpringBoard 里的 tweak 记通知、
盒子 App 清空/标已读），而 SQLite 默认行为是"拿不到写锁立刻返回 BUSY" ⇒
**那条通知直接丢了**，而且没有回头路（库里根本没有它）。

`openDB` 里补 `sqlite3_busy_timeout(db, 2000)`：正常写只要几毫秒，2 秒足够等对方放开。

> 判据用**符号表**而不是字符串：`sqlite3_busy_timeout` 是 C 函数名，不会以字面量出现。
> 只有 `LC_SYMTAB` 的未定义符号能证明"这个函数被调用了"
> （依赖表只能证明链了哪个库，不能证明调了哪个函数）。

### 新增闸门 `nb_delay_gate.py`

「停用了」这件事必须能被机器验证，不能靠"我记得改过"。四条判据：

1. `kDelayEnabled = NO` 存在；
2. **门排在业务逻辑之前** —— 常量改了、门却写在函数末尾，等于没关；
3. 门前没有别的 `return`（有的话可能从别的出口漏出去）；
4. 三个延迟分支都写了自毁标记 `start`，且 `%ctor` 调了自愈 + 清理。

脚本**自带负向对照**（`--selftest`）：把 `NO` 改成 `YES` 必须报红，已验证会拦住。

---

## v0.0.16 · 延迟推送换实现重开（拿到 .ips 之后）

### 一、崩溃原因定案：不是"哪条候选因"，是整条路不通

用户提供了 `.ips`（bug_type 309，SpringBoard 主线程）。故障线程栈：

```
 0  libdispatch     _dispatch_assert_queue_fail          + 120
 1  libdispatch     dispatch_assert_queue                + 196
 2  BulletinBoard   -[BBServer dataProviderForSectionID:] + 44   ← 方法开头就断言
 3  <dylib>         0x7858
 4  <dylib>         0xc0f0
 5  <dylib>         0x49f8   ← GCD 定时器 fire 出来的 block
 6  libdispatch     _dispatch_client_callout
 8  libdispatch     _dispatch_source_invoke
 9  libdispatch     _dispatch_main_queue_drain          ← 主队列
11  CoreFoundation  __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__
```

`-[BBServer dataProviderForSectionID:]` 在偏移 **+44**（几乎第一件事）就调
`dispatch_assert_queue(<BB 私有串行队列>)`。而调用它的代码是从**主队列的 GCD 定时器**
里跑出来的 ⇒ 断言当场落空 ⇒ `EXC_BREAKPOINT` / `SIGTRAP`。

> 🔴🔴 最贵的推论：**「延迟调用原方法」这条整体没有可行解**。
> 换队列也没救 —— 主队列不对、自己开串行队列更不对，
> **唯一正确的那个队列句柄只活在 BBServer 内部，外面根本拿不到**。
> 所以「把 `%orig` 塞进某个 `dispatch_after`」不是"还没调好"，是**永远调不好**。

**顺带一个诚实的记录**：这份 .ips 的故障栈里 `NotifyBox.dylib` **零帧**
（168 个镜像、全部线程全扫），发起方是机器上另一个插件 `NotificationFilter.dylib`。
但"这份日志不是我" ≠ "我的代码没问题" —— 上面那条队列断言说明我们的延迟分支
一旦真跑起来会死在同一处。停用的决定与"谁发的"无关。

### 二、新实现：不改调用时机，只改数据

```objc
// NotifyFilter.m
+ (NSString *)applyDelayToBulletin:(id)bulletin seconds:(NSTimeInterval)seconds;
```

把 bulletin 上**像发布时间**的字段整体平移 N 秒，然后**立刻、在同一线程**执行原方法，
让系统自己按新时间排期：

| 字段 | 说明 |
|---|---|
| `date` | 头文件里早就有声明，但真机从未验证过 |
| `publicationDate` / `publishDate` / `timestamp` | 候选 |
| `expirationDate` | 一起平移 —— 只推 date 不推它，通知可能"已过期"而不显示 |

**三重保护**（每条都对应一种真实失败模式）：

1. `respondsToSelector:@selector(setXxx:)` —— readonly 字段硬写就是抛异常 = 崩；
2. `respondsToSelector:@selector(xxx)` + 当前值 `isKindOfClass:[NSDate class]`
   —— 类型对不上说明这个字段不是时间，**不动手**（改错字段的代价是"通知永远不出现"）；
3. 每个键**单独 `@try`** —— KVC 碰到不存在的键会抛 `NSUndefinedKeyException`，
   共用一个 `@try` 的话第一个抛错会带走后面所有键（这个坑在 `NotifyProbe` 里已经踩过）。

三个 hook 的形状统一成：

```objc
if (d.delay > 0) {
    NSString *moved = [NotifyFilter applyDelayToBulletin:bulletin seconds:d.delay];
    if (moved) NBLogDelayApplied(@"PB", d.delay, moved);
    else       NBLogDelayMissed(@"PB", d.delay, bulletin);
}
%orig(bulletin, destinations);      // 🔴 无条件、立即
```

**没有 `dispatch_after`、没有 `return`、没有跨时间的对象持有。**
改字段失败只是"没延迟"（安全失败），绝不吞掉通知。

### 三、留痕拆成两条（它们对应的下一步完全相反）

| 日志 | 含义 | 下一动作 |
|---|---|---|
| `DELAY#n tag=PB 5.0s 字段=date+expirationDate` | 改动成功，系统会晚点弹 | 看通知是否真的晚了 |
| `DELAY-MISS#n tag=PB ...` | 要延迟但**一个字段都没改成**，本条按时发布 | 看紧跟的 `PROBEDATE#` |
| `PROBEDATE#n cls=BBBulletin :: date{T@"NSDate"}=NSDate(1761...)` | 该对象上所有含 date/time 的属性名 + 类型编码 + 当前值 | 按真实字段名定案 |

`DELAY-FIRE#` 这个留痕**已经删掉** —— 它的语义是"N 秒之后再去执行原方法"，
正是被判死刑的那条路。校验脚本把它列为**反向断言**：它出现就说明有人走回去了。

### 四、闸门 `nb_delay_gate.py` 整份重写

判据从"必须停用"反转成"不许跨队列"，六条：

1. `kDelayEnabled = YES`（否则界面写着能用、实际什么都不做）；
2. 三个 hook 的方法体里**不许出现 `dispatch_after`** —— 死因本身；
3. 延迟分支里**不许有 `return`** —— 有 return 就说明它不想立刻执行原方法了；
4. 三个 hook 都必须调 `applyDelayToBulletin:`；
5. `applyDelayToBulletin:` 三重保护齐全；
6. 三个 hook 方法体的**最后一句**必须是 `%orig(...)`。

负向对照：往 PB 方法体塞一句 `dispatch_after` 必须报红，已验证。

> 🔴 修闸门时又踩一个坑：它原来 `body = s[i:i+2000]` 取**固定 2000 字符窗口**，
> 我往 `shouldDelayBundle:` 里补了 13 行注释把门语句挤出了窗口 ⇒ **假红**。
> 改成按方法边界切（到下一个 `\n+ (` / `\n- (` / `\n@end`）。
> 老话重提：**判据域必须等于变异域**，"取前 N 字符"本身就是一种判据域。
> 另外闸门现在会**先剥掉 `//` 注释再查** —— 注释里写着"旧实现是 dispatch_after"
> 是在留教训，不该被当成现行代码。

---

## v0.0.19 · 延迟推送**功能整体删除**（两版实现各撞死一次）

> 一句话：**不是"实现没调好"，是这个功能在当前注入位置没有可行解。**
> 所以这一版不是停用、不是加开关，是**连接口一起撤掉**。

### 现场（用户真机截图，v0.0.18）

```
[17:59:52] === [SpringBoard] NotifyBox v0.0.18 · 延迟自愈已触发 · 延迟推送已启用（改时间字段，不跨队列） ===
[17:59:52] !!! 延迟自毁保护触发：上次崩在延迟发布里（guard=start 没有 done）
[17:59:52] !!! 已自动删除 delaySeconds ⇒ 延迟推送回到关闭状态，不用你手动改
...
[09:58:35] DELAY#2515 tag=PB   5.0s 字段=date+publicationDate+expirationDate
[10:00:18] DELAY#2516 tag=PBRS 5.0s 字段=date
[10:00:18] DELAY-SKIP#2 tag=PBR 这一条已经推过了（多入口幂等）
[10:00:18] DELAY#2517 tag=PB   5.0s 字段=date+publicationDate+expirationDate
```

三件事同时不对：**它自称已关闭、它还在按 5 秒推、通知一条都不弹。**

### 证据链（三条，各自独立，缺一条都不能下这个结论）

**① 对象级幂等跨不过包装对象。**
同一秒内同一条通知：`PBRS` 只改到 `date`（1 个字段），`PBR` 被幂等跳过，`PB` 改到
`date+publicationDate+expirationDate`（3 个字段）。
⇒ 三个入口拿到的是**不同包装对象**（`BBBulletinRequest` / `BBBulletin`），
关联对象标记挂在"当次传进来的那个对象"上，跨不过去 ⇒ **`date` 被推了两次**。
`DELAY-SKIP#` 只出现过 2 次（对比 2517 次 DELAY#），也印证了幂等基本没工作。

**② 「改时间字段」不是"延后发布一次"，是"要求系统改期"。**
系统每次重排都会重新走发布入口、拿到**新的包装对象** ⇒ ①的漏洞每次都被踩一遍
⇒ 每重排一次就再 +5 秒 ⇒ **这条通知永远到不了**。
这就是"通知全不弹"的机制，也是为什么 `DELAY#` 能涨到 2515 ——
积压的待发通知越多，每轮重排刷出来的行数越多。

**③ `guard=start` 是一个永久的假警报 —— 我自己埋的。**
`git log -S 'NBWriteDelayGuard(@"start")'` 只有两个 commit：`d47ac61`(v0.0.15) 和 `6dc778c`(v0.0.16)。
v0.0.15 写了 `start`，v0.0.16 **把写入删了、却把读取留着**；
而 v0.0.15 的延迟是全程关闭的 ⇒ 它写了 `start` 之后**永远等不到 `done`**
⇒ 这个文件永久停在 `start` ⇒ 从 v0.0.16 起每次启动都误判"上次崩在延迟里"，
然后删掉用户的秒数、并告诉用户"已经关掉了"。

> 🔴 **一个只写不读的状态是死状态；一个只读不写的状态是永远为真的谎言。**
> 自愈判据必须"写和读在同一处、成对出现"，而且必须**回读验证**。

### 附带查清的两件事（不改变结论，但以后有用）

* **`DELAY#` 那几行不带进程名，而本 tweak 同时注入 `com.apple.springboard`
  和 `com.apple.backboardd`** ⇒ 光看日志**无法确定**是哪份在刷；而
  `NBRecoverFromDelayCrash` 只在 SpringBoard 里跑（backboardd 是 root，不许写设置）
  ⇒ backboardd 那份**根本没有自愈**。这至少解释了"删了还在跑"的一半。
  📌 结论：**留痕必须带进程名**，否则两条进程的计数会拼成一张假的时序表。
* 用户抱怨"编号到 2515 但 banner 之后编号没归零"这条矛盾，用上面这条就能解释，
  不需要假设"日志顺序错乱"。**先找机制，再怀疑工具。**

### 这一版改了什么

| 位置 | 动作 |
|---|---|
| `NotifyFilter.h` | 撤掉 `shouldDelayBundle:` / `applyDelayToBulletin:` / `probeTimeFieldsOfBulletin:` 三个声明 |
| `NotifyFilter.m` | 删掉 190 行实现（含 `dateByAddingTimeInterval`、`NBDelayMarkKey`、`NBTimeKeys`） |
| `Tweak.x` | 删掉四个计数器、三个留痕函数、两道 guard、流水线 ④ 段、三个 hook 的延迟分支；`NBDecision` 去掉 `delay` 字段 |
| `Tweak.x` | 新增 `NBPurgeDelayLeftovers()`：清两处设置文件 + 删 `.delay_guard`，**并回读确认**再打日志 |
| `SettingsViewController.m` | 去掉输入框与入口；保存出口加**防复活闸门**（`removeObjectForKey:`）+ 帮助文案写明"已移除" |

**防复活闸门为什么必须加**：保存的写法是「启动时读到的整份 dict → 改一项 → 整份写回」。
只要那份里还有 `delaySeconds`，用户**改任何别的设置**都会把它原样写回去
⇒ tweak 清一次、App 复活一次 ⇒ 表现就是"明明删了还在跑"。
让**唯一的保存出口**负责"已移除的键绝不落盘"，比在每个入口判断都可靠。

### 闸门口径反转：`nb_delay_gate.py` v3

从"实现对不对"改成"**刀有没有真的从仓库里拿走**"：

* 反向 8 条：`shouldDelayBundle` / `applyDelayToBulletin` / `probeTimeFieldsOfBulletin` /
  `DELAY#` / `DELAY-MISS#` / `DELAY-SKIP#` / `PROBEDATE#` / `kDelayEnabled` 都不许出现；
* 正向 3 条**对照**：`shouldDropBundle` / `applyReplaceRulesTo` / `DROP#` 必须还在
  —— **反向判据没有同位置的正向对照，等于一张白纸也能拿满分**；
* 界面 3 条：没有输入框、没有入口、保存出口必须清键。

负向对照从 1 条扩到 3 条（都验证过报红）：
塞回 `dateByAddingTimeInterval` / 塞回 `if (d.delay > 0)` / 删掉保存出口的清理语句。

> 🔴 写闸门时当场踩了一次假红：新加的说明注释里**故意写着**
> `dateByAddingTimeInterval` 这个名字（用来警告后人），结果被自己的判据抓住。
> 判据只许查**代码行**，不许连注释一起查 —— 这条坑在 v0.0.16 已经踩过一次，这是第二次。

### 教训（值得进方法论的）

1. **"功能删掉"和"功能停用"是两种交付**。停用留一把刀，而这个功能一刀就能让用户
   通知全没 —— 那是最难归因的症状。删除要连**接口**一起删，否则只是把门虚掩上。
2. **改系统自己会重新计算的字段 = 和系统的排期器打循环**。我要的是"这一次晚点"，
   系统理解的是"目标时间改成这个"，它每次重算都把我算进去。这类字段一律不要碰。
3. **自愈机制必须能证明自己生效**（回读），否则它比没有更坏：它会给用户一个假结论，
   让用户和你都停止排查。
4. **反向判据必须配正向对照**。`not has_text(x)` 在空包、缺文件、打错路径时全绿。

---

## v0.0.20 · 修「探针数据被结论行筛掉」（同一个病第三次）

> 一句话：**数据一直在日志里，是 App 自己把它筛掉的。**
> 所以「按 App 换提示音」等 PROBE 数据等了好几版，根因不在探针、不在系统 API。

### 现场

结论行里能看到的探针内容只有两行：

```
=== PROBE 开始 dump 类结构（只读，一次性）===
=== PROBE dump 结束 ===
```

看起来像"探针跑了，但什么都没量到"。实际上 `NotifyProbe` 打的是：

```
PROBE BBBulletin 有 68 个 property
PROBE BBBulletin 名字: sectionID,title,message,...
PROBE BBBulletin 声音相关(9): sound,alertType,...
PROBE#1 tag=PB cls=BBBulletin :: sound=<BBSound> alertType=2 ...
PROBE 当前队列标签 = com.apple.bulletinboard.server
```

**这些行一个筛选关键词都不含**（表里是 `===|-->|hit#|P#|drop |DROP#|REPL#|DELAY|PROBEDATE|...`），
只有 `===` 那两行空壳能漏出来。

### 两个**互相独立**的丢数据原因（只修一个等于没修）

1. **关键词表里没有 `PROBE`** ⇒ 数据行被筛掉；
2. **结论行只看尾部 20KB**，而探针是**开机那一刻**打的 ⇒ 手机跑几小时后，
   就算关键词补上了，那几行也早被挤出窗口。

⇒ 所以这一版做两件事：表里 `DELAY|PROBEDATE`（v0.0.19 之后已死）换成 `PROBE`；
另外**单开一个「探针数据」入口**（窗口 200KB，只挑含 PROBE 的行，最多 40 条）。

### 这个病已经犯过三次

| 版本 | 被筛掉的留痕 | 后果 |
|---|---|---|
| v0.0.17 | `DELAY#` / `DELAY-MISS#` | 截图只剩 SKIP，我一度以为延迟从没成功过 |
| v0.0.18 | 关键词表压成哨兵串才修好判据 | —— |
| v0.0.20 | `PROBE …` 全部实质数据行 | 换提示音等数据等了多版 |

> 🔴 教训升级：**"加了新留痕"必须同时问"它能通过筛选吗"**，
> 而"表里还有别的词"不代表"新留痕能被捞出来"。
> 现在这条由 `nb_delay_gate.py` 机器守（第 5 条负向对照：把 PROBE 从表里拿掉必红）。

### 校验

* 关键词表解析后必须含 `PROBE`，且已死的 `DELAY` / `PROBEDATE` 必须不在；
* App 里必须有 `探针数据` 与 `probeLinesFrom`（新入口真的编进去了）；
* 沿用 v0.0.19 的 8 条反向判据 + 3 条正向对照（延迟仍然必须是"彻底不在"）。

---

## v0.0.21 · 免打扰时段 + 按 App 换提示音

> 一句话：**两个新功能一起上**。免打扰是确定性的活；换提示音是"造系统对象"的活 ——
> 后者的失败形态是**这条通知不出声**，不崩、不报错、用户只会以为手机坏了。
> 所以两者的安全设计完全不同。

### 一、免打扰时段（DND）

命中时段 ⇒ `NBDeny()` 丢掉（**不弹、不响、不朗读**），但仍记一条 `DND#` 日志，
通知照常进盒子 —— "不弹但可回看"。

三个必须写对的细节：

| 细节 | 做法 | 不这么做会怎样 |
|---|---|---|
| 跨零点 | `start > end` 时判 `now >= start \|\| now < end` | 23:00~07:00 这种最常见的配置直接失效 |
| `start == end` | **视为误配、不生效** | 否则"两个都设 00:00"= 24 小时全静音，用户不知道为什么 |
| 存的是分钟数还是 `"23:00"` | 两种都认（`NBMinutesValue`） | 设置页换了存法就静默失效，且**不报错** |

> 🔴 时长的两种写法必须同时支持，因为**设置页存的可能是任一种** ——
> 这类"同一份数据两个来源"的坑本项目已经踩过（`delaySeconds` 用 NSNumber、
> `delayApps` 用数组，混着读就崩）。

### 二、按 App 换提示音（实验）

实现方式**由真机 PROBE 数据定，一条都不是猜的**：

| 真机量到的事实 | 直接推翻了什么 |
|---|---|
| `sound{T@"BBSound",&,N,V_sound}` 属性可写 | 「只能读不能写」的担心不成立 |
| `BBSound` **只有 1 个类方法、且与声音无关** | ❌ 没有工厂方法可抄 —— 只能 `alloc/init` 自己造 |
| `alertType` 是 `R`（只读）；可写的是 `soundType` / `systemSoundID` | 改 `alertType` 那条路是死的 |
| `PROBE#1/2/3` **全是 `sound=nil`** | 默认提示音**不带 BBSound** ⇒ 没有现成对象可以改，必须造 |

于是实现就三步：`alloc/init` 一个 `BBSound` → 按 `respondsToSelector` 填
`soundType=1` / `systemSoundID` → `setValue:forKey:@"sound"` 挂上去，
**然后回读 `[bulletin valueForKey:@"sound"]` 确认不是 nil**。

> 🔴 回读这一步不能省。造出来的对象被系统丢弃时**不报任何错**，
> 唯一能证明"挂上了"的就是回读。v0.0.18 那句"已自动删除 delaySeconds"
> 就是只写不读的假话 —— 同一个病。

#### 三条安全设计（实验功能必须有）

1. **空名单不生效** —— 这条与其它名单**语义相反**（别的名单空 = 全部 App）。
   实验功能绝不允许一次性改掉整台手机的通知音：那样用户连"是谁干的"都查不出来。
   引擎里守，不靠界面守（选择器的 `onSave` 是一条会绕过保存闸门的旁路，v0.0.19 踩过）。
2. **每次尝试都打 `SOUND#` 行** —— 成没成都看得见，不留"以为生效了"的空间。
3. **崩溃自愈** —— `.sound_guard` 写 `start`/`done` 成对 + 关开关后**回读确认**。

### 三、顺手修掉的一个既有 bug

设置页原来只用一个 `speakSwitch` 指针记住开关。这一版有三处开关（朗读 / 免打扰 /
换提示音），**共用一个指针就会互相覆盖** —— 症状是"我明明开了免打扰，一保存自己变回关"，
且完全不报错。改成 `switches` 字典。

> 这个坑早有警告，只是当时只有一个开关、不会发作。**加第二个开关时必须兑现。**

### 四、日志可见性

结论行关键词表加 `DND#` / `SOUND#`。同一个病（新留痕被静默筛掉）在 v0.0.17、
v0.0.20 已经犯过两版，这次**在写代码的同时就加**，不等真机发现。

### 五、校验

* `nb_verify_v021.py`（由 v020 **派生**，不新写）新增两节：
  * 第 12 节：两个入口函数真的编进二进制（`shouldDropForDND` /
    `applySoundForBundle` / `recoverFromSoundCrashIfNeeded`）、两条留痕在、
    `.sound_guard` 在、**banner 不许把实验功能说成"已启用"**；
  * 第 13 节：回归 —— 已死的说法不许被新代码顺手带回来。
* `nb_delay_gate.py` 新增 `check_v021()` + **7 条负向对照**，全部验证报红：
  塞回 `dateByAddingTimeInterval` / 塞回 `if (d.delay > 0)` / 删保存闸门 /
  加回 picker 的 delay 模式 / 拿掉 `PROBE` / 拆掉免打扰接线 / 拿掉空名单闸门。

### 六、这一版**不保证**的事

* 换提示音**没在真机上验过**（这一版才第一次有实现）。它可能：
  * 完全不生效（`sound` 挂上了但系统在发布时用自己的 sound 覆盖）；—— 那时 `SOUND#`
    行会显示"挂上了"，而卡片没声音 ⇒ 判据是「回读成功但用户听不到」；
  * 生效但只对部分 App 生效（某些 App 自带 sound 资源）。
* 所以默认关闭、且**请先只选一个 App 试**。出问题就把开关关掉，一切恢复。

### 七、真机怎么验（按这个顺序做，能一次定位到底哪一环不对）

**免打扰**

1. 设置页打开「免打扰时段」，起始填现在时间往后 1 分钟、结束填往后 3 分钟；
2. 「免打扰生效的 App」里选 1 个会推通知的 App（**不选 = 不生效**）；
3. 保存 → 等过了起始时间 → 让那个 App 推一条通知；
4. 期望：**不弹横幅、不响、不朗读**，但盒子里有这条记录；
5. 打开 App →「日志与诊断」→ 结论行里应该有 `DND#1 bundle=… 时段=…`。
6. 过了结束时间再推一条 ⇒ 正常弹出（这条同样重要：不验的话"全时段静音"和
   "时段生效"看起来一样）。

**换提示音**

1. 「按 App 换提示音」打开；ID 填 `1007`；点「试听这个提示音」——
   **先确认你听到的那个声音是你想要的那个**（这一步就是为了不让用户去猜 ID）；
2. 「换提示音的 App（空 = 不生效）」里选 1 个 App；
3. 保存 → 让那个 App 推一条通知；
4. 期望：横幅/锁屏的声音变成你试听的那个；
5. 打开 App →「日志与诊断」→ 结论行里应该有 `SOUND#N bundle=… id=1007 已挂上 cls=BBSound …`。

**看到这两行才算这一版真的在跑**

| 日志 | 含义 |
|---|---|
| `SOUND#… 已挂上 cls=BBSound` | 对象造出来、挂上去了、**回读确认不是 nil** |
| `SOUND#… 写完回读是 nil` | 挂上去被系统丢了 ⇒ 这条路走不通，把开关关掉 |
| `!!! 换提示音开着但 App 名单是空的` | 开关开了但没选 App（这也是"没反应"最常见的原因） |
| `DND#1 … 时段=…` | 免打扰真的拦下了（不弹但记录在） |

关掉开关就完全恢复原样 —— 两个功能都是"默认关、关了等于不存在"。

### 八、这一版修掉的一条假红判据（第四次）

`has_text(blob, "空名单")` 查的是**源码注释里**的三个字，二进制里根本没有
（`NB_KEY_SOUND_APPS` 是宏，`if (!apps.count)` 是控制流，编译后不产生字面量）。

这次的处理办法不是删判据，而是**让代码里真的存在一条可读痕迹**：
把两条静默分支各加一条 `!!!` 留痕（每进程只打一次，不刷屏），
判据改成查那条痕迹的原文 —— 这样它同时证明了"闸门在"和"用户会得到说法"。

> 🔴 判据域必须等于变异域。这已经不记得是第几次了，
> 所以现在养成一个动作：**写 `has_text` 之前先问"这串字符编译后会以什么形式存在"**。

### 九、交付

```
dist/com.yxh41.notifybox_0.0.21_iphoneos-arm64e.deb   75548 bytes
CI run #40 / run_id 39883529121  （zip 75722 bytes，与 API 的 size_in_bytes 对拍一致）
校验 155 项全通过，0 FAIL
```

> 下载一律按 `run_id` 走 API 精确取 —— `nightly.link` 有 CDN 缓存，
> 会给你上一版的包，而且校验全绿（这是最坏的一种假绿）。

---

## v0.0.22 · 换提示音「回读成功、但听不到」（只读诊断版）

> 一句话：**`SOUND# … 已挂上 cls=BBSound` 是真的，但「挂上了」≠「会响」。**
> 这一版一行功能都没改，只把现场量清楚 —— 因为剩下的可能性都各自套着子可能，
> 这时候再换把刀猜，等于把好几个反常量赌成一个。

### 一、为什么不出新刀

真机把问题锁到两个可能上，而它们的**修法完全相反**：

| 可能 | 症状 | 修法 |
|---|---|---|
| ① 值填错了 / 填不进 | 挂上了，但对象里的字段是空的或语义不对 | 换字段名、换枚举值 |
| ② 填对了但系统不采纳 | 字段都对，系统在发布链路上重算 `sound` 把它换掉 | 换挂点（拦更下游） |

`BBSound` 上可能根本没有 `setSoundType:`；真正决定播放的字段可能叫
`toneIdentifier` / `soundSource`，我们压根没填；而 `alertType` 是只读的 ——
这三条每一条都能单独造成"静默不出声"。**在分清 ① 和 ② 之前，任何改动都是猜。**

### 二、一次要拿全的三件事

| # | 量什么 | 怎么量 | 拿到之后能判什么 |
|---|---|---|---|
| 1 | `BBSound` 的属性 + **可写性** | `class_copyPropertyList` + `property_getAttributes`，按逗号切段判整段等于 `R` | 有没有 `toneIdentifier` / `soundSource`，各自能不能写 |
| 2 | 我们填的值**进没进对象** | 直接写进 `SOUND#` 行：`src= tone= type= sid=` | 分清「没填进去」和「填进去了不生效」 |
| 3 | `orig` 之后 `sound` 还在不在 | 同步读一次 + **0.4 秒后**再读一次 | 区分「系统当场抹掉」和「被后续链路换掉」 |

第 2 条特别关键：**写进去但被 setter 忽略时，现象和"完全没写"一模一样** ——
上一版就是卡在这里，`setType=1 setID=1` 看着对，但没人知道值到底落进对象没有。

第 3 条的两个时刻缺一不可：
- 只读同步那次 ⇒ 分不清"当场就在"和"0.3 秒后被换掉"；
- 只用 `weak` 捕获 ⇒ 对象被释放也读到 nil，会和"sound 被抹掉"混成同一个现象。

### 三、白捡的宝贝

一旦遇到**系统给的、非 nil 的 `sound`**，整份 dump 一次（全进程只一次）。
抄一个真实对象的字段值，比猜枚举值强一万倍。
v0.0.20 的 PROBE 显示默认通知 `sound=nil` 所以那时没得抄；
但只要手机上有一个 App 配了自定义提示音，这个钩子就会把正确答案送到眼前。

### 四、结构性改动：判定收成唯一来源

新增 `soundVerdictForBundle:soundID:`，**刀和诊断共用**。
不这么做的话，诊断会自己抄一份"该不该生效"的判断，两边一旦走岔，症状是
「诊断说该生效、刀说不该生效」—— 而刀往往才是对的，我会去修一把本来正确的刀。

### 五、判据跟着**语义**升级（不跟着书写形状）

| 旧判据 | 新判据 | 为什么 |
|---|---|---|
| `%orig` 必须是方法体最后一句 | `%orig` 必须被**无条件**调用（之后只允许诊断调用） | 加诊断会让旧判据假红，但原意（原方法不能被 if 挡掉）不能放松 |
| — | **刀里不许再出现 `apps.count`** | 抓「判定被复制了第二份」，配负向对照 |
| 空名单闸门在 `applySoundForBundle` 里 | 搬到 `soundVerdictForBundle` 里 | 闸门搬了家，判据不跟着搬就是假红 |

负向对照从 8 条增到 **9 条**，全部验证报红。

### 六、又抓到自己两条错

**① 判据命中了错误的对象**：`f.find("+ (NBSoundVerdict)soundVerdictForBundle")`
命中的是 class extension 里的**声明**（分号结尾），窗口里没有函数体 ⇒
报"闸门没了"，而闸门好端端在实现里。这和"拿源码形状查二进制"是同一类错误。

**② `@@` 手误让 CI 挂了一次**：改 banner 文案的脚本里，锚点 `@"实验（默认关）");`
本身带 `@`，我又手写了一个 ⇒ 变成 `@@`。源码看着正常、本地三道预检全绿，
只有真编一次才知道（`error: unexpected '@' in program`）。
⇒ 语法闸门补了一条扫描：任何 `.x/.m/.h` 里不许出现连续的 `@@`。

### 七、装了这一版要做什么

这一版**不改行为**，装上去照常用，只需要在收过几条通知之后，
去「日志与诊断」把结论行里 `SD#` 开头的行发给我。期望看到：

```
=== SD# 开始 dump 类结构（只读，一次性）===
SD# BBSound 有 N 个属性（[W]=可写 [R]=只读）
SD# BBSound: soundSource[W]{Tq,...} toneIdentifier[W]{T@"NSString",...} …
SD# BBSound 的 setter: setSoundType: setSystemSoundID: setToneIdentifier: …
SD# BBulletin: sound[W]{T@"BBSound",&,N,V_sound} soundType[W]{…} …
SD# PB 发后① sound=有 cls=BBSound
SD# PB 发后② soundType=1 sid=1007 alert=2 tone=nil
SD# PB 发后③ src=0 vibrat=nil
SD# PB +0.4s sound=有 cls=BBSound
```

**这四类信息各自指向不同的修法**：

| 看到什么 | 说明 | 下一步 |
|---|---|---|
| `setSoundType:` / `setSystemSoundID:` 都不在 setter 清单里 | 我们设的根本没生效，`SOUND#` 里的 `set=0/0` 也会印证 | 改设 bulletin 自己的字段 |
| setter 在，但 `SOUND# … src=0 tone=nil` | 值进去了，但决定播放的字段（`soundSource`/`toneIdentifier`）没填 | 按 dump 出来的属性名去填 |
| `发后① sound=nil` | 系统在 `orig` 内部就把它抹了 | 换挂点（拦更下游） |
| `发后① sound=有` 但 `+0.4s sound=nil` | 被后续链路换掉 | 拦"最终写回"那一刻 |
| `发后② sid=0`（我们设的是 1007） | bulletin 自己的字段没被填 | 两处都要填 |

### 八、第三条自己的错，和为此写的工具

**③ `has_text(blob, "BBSound 有")` 假红（同类错误第 5 次）**：
源码是 `NBSharedLog(@"SD# %@ 有 %u 个属性…", label, cnt)` ——
`@"BBSound"` 和 `" 有 %u 个属性…"` 在二进制里是**两条分开的字面量**，
`"BBSound 有"` 哪里都不存在。

前 4 次分别是：
| 次 | 判据 | 为什么不存在 |
|---|---|---|
| 1 | `removeObjectForKey:delaySeconds` | 宏展开后 selector 与键名分开存放 |
| 2 | `必填` 类标语 | 只在源码注释里 |
| 3 | `空名单` | 只在源码注释里 |
| 4 | `BBSound 有` | 由 `%@` 在运行时拼出来 |
| 5 | 同 4 | 同上（是的，同一个形状又犯了一次） |

⇒ 不再靠"记住"，写了 `nb_lit_check.py`：
把 verify 脚本里所有**承诺必须存在**且含中文的字面量抽出来，
逐个检查它是否作为子串出现在源码的某个 `@"..."` 里，不出现就报红。
反向判据（`not has_text`）整类跳过 —— 那类串本来就该消失。

这个工具自己踩了两个坑，也一并记下来（免得下次重犯）：
* 「反向检测」不能在 `has_text` **之前**找 `"not has_text"` —— 那段文字永远不含
  `has_text`，结果是每一处反向判据都被当成正向 ⇒ 报一堆假红；
* 用非贪婪正则 `\[(.*?)\]\s*:` 找列表会**跨行吞掉大段代码**，而列表中间的注释里
  写着 `是"三全音"` 这种示例 ⇒ 又一片假红。
  ⇒ 必须先逐行剥注释，再用**括号计数**找列表边界。

### 九、交付

```
dist/com.yxh41.notifybox_0.0.22_iphoneos-arm64e.deb   78516 bytes
CI run #43 / run_id 39885757617（zip 78694 bytes，与 API 的 size_in_bytes 对拍一致）
校验 177 项全通过，0 FAIL；判据体检（nb_lit_check）53 条全过
闸门 9 条负向对照全部报红
```

> 中间 CI 挂过一次（#42），原因是脚本把 banner 的 `@` 打重了变成 `@@`。
> 已经给语法闸门补了扫描，负向对照验证过会报红。

---

## v0.0.23 · 「完全没声音」的根因：空壳 `BBSound` 播 0 次 / 0 秒

> 一句话：**`sound` 挂上了、值也进去了，但那个对象是空壳 —— 系统采纳它，
> 于是按"播 0 次 / 0 秒"执行，一声不出。**
> 这不是猜的，是上一版量到的三条事实**排除掉所有其它解释**之后剩下的唯一一条。

### 一、上一版的数据已经把答案送出来了

v0.0.22 那张截图里 `SOUND#` 和 `SD#` 两种行，合起来能排除掉大半可能：

| 量到什么 | 排除了什么 |
|---|---|
| `sound` 在 orig 前 / 后 / 0.4 秒后**都在**（`发后① sound=有`、`+0.4s sound=有`） | 不是"挂载失败"，也不是"被系统抹掉/换掉" —— 换挂点这条路**不用走了** |
| `SOUND# set=1/1` | `setSoundType:` / `setSystemSoundID:` 两个 setter **都存在** |
| 回读 `type=1 sid=1009` | 值**真的进了对象**（不是被 setter 吞了） |
| `src=!抛` | `soundSource` 这个键在 `BBSound` 上**根本不存在** —— "要不要补 soundSource"这个猜测作废 |

剩下的可能只有一种：**对象本身不完整。** 于是问题从"改哪一行代码"变成了
"一个合格的 `BBSound` 到底还差哪些字段"。

### 二、根因：`repetitions` 和 `maxDuration` 是 0

真机 PROBE 的 `BBSound 有 15 个 property` 里有这两个：

| 字段 | 含义 | `alloc/init` 出来的值 |
|---|---|---|
| `repetitions` | **播几次** | 0 |
| `maxDuration` | **播多久** | 0 |

系统认为"这条通知带了声音配置，播 0 次、最多 0 秒" ⇒ **一声都不出**。

这条推断还顺带解释了两个之前看不懂的现象：

* **为什么默认通知照样响**：`sound=nil` 时系统走的是"默认提示音"那条路，
  根本不看 `repetitions` / `maxDuration`；
* **为什么是"完全没声音"而不是"还是原来的声音"**：因为我们已经把 `sound`
  从 nil 换成了一个**存在但播不出来**的对象 —— 原来那条默认路径被我们自己掐断了。

### 三、为什么这一版敢直接补，不用再量一轮

这是本项目第一次"量完就改"，理由是**当前状态已经是最差**：

> 症状是「完全没声音」。补两个"播一次、最多 30 秒"的合理值，
> 不可能比"一声不出"更差。

同时保留一条不赌的底线：**仍然逐个 `respondsToSelector` 探**。
`BBSound` 上 `soundSource` / `vibrationIdentifier` 就是不存在（已被 KVC 抛异常证明），
所以键名一个都不硬写。

```objc
if ([snd respondsToSelector:NSSelectorFromString(@"setRepetitions:")]) {
    [snd setValue:@(1) forKey:@"repetitions"];      // 播一次
    setRep = YES;
}
if ([snd respondsToSelector:NSSelectorFromString(@"setMaxDuration:")]) {
    [snd setValue:@(30) forKey:@"maxDuration"];     // 最长 30 秒（提示音本来就短）
    setDur = YES;
}
```

### 四、安全兜底：设不上就**不挂**

万一这俩 setter 在本版 `BBSound` 上不存在，那就**不许把空壳挂上去**：

> 「静音」比「声音没换掉」糟得多 —— 后者只是功能没生效，前者会让用户漏消息。

所以兜底分支直接放弃换音，并且**返回 YES**（不是"没做"，是"故意不做"）——
这样理由会出现在 `SOUND#` 行里，用户看得见**为什么不换**：

```
SOUND#3 bundle=com.ss.iphone.ugc.Aweme tag=PB !!! 放弃换音：rep=0 dur=0 设不上（挂上去会静音），本版通知仍按原声…
```

（如果返回 NO，`Tweak.x` 就不会打这一行 —— 用户只会看到"换提示音没生效"，
却看不到原因。这条是刻意的。）

### 五、两次取样：设前 / 设后

```
SD# snd[设前] type=nil sid=nil rep=0 dur=0 tone=nil     ← 刚 alloc 完，空壳有多空
SD# snd[设后] type=1   sid=1009 rep=1 dur=30  tone=nil  ← 四个字段写完
```

一条对比就能分清两件事：「值真的写进去了」还是「setter 收下了但没存」。
**只量一次是分不出来的** —— 写进去但被 setter 忽略时，和"根本没写"的现象完全一样。

### 六、诊断落盘：`sound_diag.log`

v0.0.22 白跑了一轮，原因是纯机械的：

> 诊断**打出来了**，但 `SD# BBSound 有 15 个属性` 那几行已经被挤出
> 约 50 行的日志窗口，用户截图里只剩后面的 `SOUND#`。
> 而"有哪些属性、哪些可写"正是定位问题的唯一依据。

所以这一版起，`NBDiagLog` **同时**写日志和写文件：

* 每个进程第一次写时覆盖（结构性 dump 只打一次，不会无限长）；
* 超过 256KB 自动重置；
* 路径 `NOTIFYBOX_SOUND_DIAG_PATH` 在 `NotifyCommon.h` **只定义一次**，
  App 侧直接读同一份文件（新增入口「声音诊断文件（完整，换提示音必看）」）。

App 里打开是整份文件（带行数），不再受日志窗口限制。

### 七、判据层：新增 14 条「二进制里查不到」的语义判据

本版最关键的两条承诺是**顺序/结构**上的，打包校验查不到（二进制里没有"先后"）：

1. 「设前」「设后」必须**夹住**那四个 `setValue` —— 否则等于只量了一次；
2. 安全兜底必须排在 `[bulletin setValue:snd forKey:@"sound"]` **之前** ——
   排在后面的话，空壳已经挂上去了才判"别挂"，兜底成了装饰品。

⇒ 新写 `nb_v023_src_check.py`，14 条判据，**每条都配一条负向自测**（14/14 报红）。
其中一条自测专门验证"变异域 = 判据域"：变异写**原始文本**，判据只读**剥注释文本**，
中间重算一遍。反过来做（判据读原始、变异写剥注释版）会让变异被覆盖掉，
**自测全绿但一条也没测到** —— 那比没有自测更坏。

剥注释这一步本身也是判据的一部分：`set=%d%d` 这条判据的反例就写在**注释里**
（我给下一任留的说明），不剥注释的话，"退回连写"的负向自测会被注释里的字骗成绿。

### 八、又抓到一条继承下来的假判据

`nb_lit_check.py` 报红：`发后③` 在源码里不存在。

查下来是**我这一版自己改掉的**：v0.0.22 有 `发后② tone=…` 和 `发后③ src=… vibrat=…`
两条，这一版合并成一条 `发后② tone=… src=… vibrat=…`（日志窗口只有约 50 行，
能省一行就省一行，六个字段一个都没丢）。

⇒ 处理方式：**断言跟着现实改，代码不为迁就判据而回退。**
删掉 `发后③` 并写清为什么 —— 留着它就是一条永远红的假判据。

同时还修了一处「注释承诺单一来源、代码里另写一份字面量」：
`soundDiagFileText` 里原本写着 `@"/var/mobile/Library/NotifyBox/sound_diag.log"`，
而注释却说"与 tweak 侧共用宏"。改两处路径不同步的症状是**两边都"没错"却谁也看不见**，
现在代码真的用 `NOTIFYBOX_SOUND_DIAG_PATH`，并且有一条判据守着"App 侧不许出现这个字面量"。

### 九、装了这一版要做什么

1. 装 `com.yxh41.notifybox_0.0.23_iphoneos-arm64e.deb`，**重启 SpringBoard**；
2. 设置里「按 App 换提示音」开着、名单里只留**一个** App、提示音 ID 填 `1009`；
3. 让那个 App 发一条通知 —— **第一件事是听有没有声音**：

| 听到什么 | 说明 | 下一步 |
|---|---|---|
| **响了，而且是新提示音** | 根因确认，功能收口 | 可以放开名单给多个 App |
| 响了，但还是原来的声音 | `sound` 没挂上（兜底生效了） | 看 `SOUND# … 放弃换音` 里的 `rep=` `dur=` |
| **还是完全没声音** | 说明 `repetitions`/`maxDuration` 不是唯一原因 | 下一个嫌疑是 `soundType=1` 这个**凭空猜的**枚举值 |

4. 然后进「诊断」→「声音诊断文件（完整，换提示音必看）」，把整份发我。
   期望能看到（**关键是 `设前` → `设后` 的对比**）：

```
=== SD# 开始 dump 类结构（只读，一次性；v0.0.23 落盘）===
SD# BBSound 有 15 个属性（[W]=可写 [R]=只读）
SD# BBSound: …
SD# snd[设前] type=nil sid=nil rep=0 dur=0 tone=nil
SD# snd[设后] type=1 sid=1009 rep=1 dur=30 tone=nil
SOUND#1 bundle=… tag=PB id=1009 已挂上 cls=BBSound set=1/1 rep=1 dur=1 src=!抛 tone=nil type=1 sid=1009 rep=1 dur=30
SD# PB 发后① playSound=… alert=… type=… sid=…
SD# PB +0.4s sound=有 cls=BBSound
```

> `SOUND#` 行里 `rep` / `dur` 会出现**两次**，这是正常的、别当成 bug：
> 前面 `set=1/1 rep=1 dur=1` 是**两个 setter 存不存在**（刀的动作），
> 后面 `rep=1 dur=30` 是**从对象里回读到的实值**（写进去了没有）。
> 两者都看才能分清"没设"和"设了没进去"。

判读口径（**三条都要看**）：

* `snd[设前] rep=0 dur=0` ⇒ 空壳推断成立，这是本轮的核心证据；
* `snd[设后] rep=1 dur=30` ⇒ 值真的写进去了（不是 setter 吞了）；
* `SOUND# … 放弃换音` ⇒ rep/dur 的 setter 在本版**不存在**，兜底主动没挂
  （这条不是失败，是"故意不做"，通知按原声照常响）。

### 十、交付

```
dist/com.yxh41.notifybox_0.0.23_iphoneos-arm64e.deb   81518 bytes
CI run #45 / run_id 39888245508（zip 81692 bytes，与 API 的 size_in_bytes 对拍一致）
校验 197 项全通过，0 FAIL；判据体检（nb_lit_check）58 条全过
nb_v023_src_check 14 条语义判据全过，14 条负向对照全部报红
```

> 包比 v0.0.22（78516）大了约 3KB，增量对得上：诊断落盘那一段 + 安全兜底 + 两次取样。
> 没有新增任何依赖（依赖表仍是 `firmware (>=16.0), ellekit`）。

---

## v0.0.24 · 侦察「正确造法」：上一版的假设被真机数据正面否掉

> 一句话：**v0.0.23 推断的「播 0 次 / 0 秒」不成立 —— 一个能正常响的声音，那两个字段也是 0。**
> 而真正决定出声的是 **TonesLibrary 的 `TLAlertConfiguration`**，
> `systemSoundID`（AudioServices 老 ID）iOS 16 的 BulletinBoard 已经不看了。
> 这一版**不改刀**（继续不挂），只把"怎么造一个能响的 BBSound"挖出来。

### 一、决定性证据：真机里有一个「能响的对照组」

v0.0.23 的诊断在用户手机上抓到了一个**系统自己的、能正常出声**的 `BBSound`。
把它和我们造的空壳并排放：

| 字段 | 能正常响的（系统给的） | 我们的空壳 |
|---|---|---|
| `soundType` | **2** | 1 |
| `systemSoundID` | **0** | 1009 |
| `alertConfiguration` | **`<TLAlertConfiguration>`** | **nil** |
| `toneIdentifier` | `""`（空串，只读） | nil |
| `maxDuration` | **0** | 30（我们写的） |
| `repeats` | **0** | 0（我们写的） |
| `alertType` | 17（只读） | 0 |

### 二、这一张表推翻了三件事

**① 「播 0 次 / 0 秒」不是病因。**
能响的样本 `maxDuration=0` + `repeats=0`，照样响。v0.0.23 的整个推断作废。

**② `repetitions` 这个键根本不存在 —— 我抄错了名字。**
真机上 `rep=!无键`（`NSUnknownKeyException`），正确名字是：

```
repeats[W]{TB,N,GisRepeating,V_repeats}     ← BOOL，getter 是 isRepeating，"要不要重复"
```

而 `repetitions`（"播几次"）是我照着上一版 PROBE 截图**凭印象转写**出来的 ——
意思相近、名字不对。⇒ **键名只能从数据里逐字抄，不许翻成同义词。**
（这类错比"猜错方向"更隐蔽：代码能编、能跑、只是永远读不到东西。）

**③ iOS 16 的通知音走 TonesLibrary，不走 `systemSoundID`。**

| | 走哪条路 | 谁能读 |
|---|---|---|
| 设置页「试听」 | `AudioServicesPlaySystemSound(1009)` | AudioServices，**能响** |
| 系统投递通知 | `TLAlert` + `TLAlertConfiguration` | BulletinBoard，**不看 systemSoundID** |

这解释了困扰好几轮的那个矛盾：**试听是响的，通知不响** —— 两条完全不同的路。
`systemSoundID` 是 iOS 9 时代的东西，留到今天已经不被通知链路采纳了。

### 三、为什么这一版仍然不改刀

v0.0.21 已经实测过：**挂一个空壳，通知变成完全没声音**。
而"没换成"只是功能没生效 —— 两者量级差得远（静音会让用户漏消息）。
在不知道正确造法之前再挂一次，等于让用户再聋一轮。

所以闸门改成这一句，并且**刻意不是"本版先关掉"**：

```objc
id alertCfg = nil;
@try { alertCfg = [snd valueForKey:@"alertConfiguration"]; } @catch (...) { alertCfg = nil; }
if (!alertCfg) {
    // 本版不挂（侦察轮）
    return YES;          // 返回 YES 才会打 SOUND#，用户看得见"为什么不换"
}
```

写成"这一项必须有值"的好处：**下一版一旦会造 `alertConfiguration`，闸门自动打开**，
不用回头再改一行 `if` —— 少一处"改了忘了开"的机会。

### 四、诊断自己也在说谎：两个 bug

真机那份 `sound_diag.log` 里，这两行紧挨着出现：

```
SD# BBSound 的 setter: setVibrationPattern: setSoundBehavior: setSystemSoundID: setSoundType: setAlertConfiguration: setRingtoneName:
SD# BBSound 声音相关 setter: 一个都没有        ← 自相矛盾
```

**bug 1：判据变量被 flush 污染。**
旧实现用 `buf.length` 同时表达两件事：「缓冲区还有没有字」和「有没有找到过」。
6 个 setter 加起来正好 **111 字符**（阈值 110）⇒ 最后一个 append 触发 flush ⇒
缓冲区被清空 ⇒ 循环结束 `buf.length == 0` ⇒ 落进 else 分支。
⇒ **"有没有找到过"必须用独立变量记**，不能复用"缓冲区还剩多少"。
这跟"改的是账本还是账本的读数"是同一类错：拿派生量当事实。

**bug 2：关键词表漏词。**
旧表只有 `sound/alert/tone/vibrat/source/system`，于是
`setMaxDuration:` / `setRepeats:` / `setSongPath:` **三个真实存在的 setter 全被筛掉**。
我却据此以为"BBSound 上只有 6 个可写字段"，差一点又照着一份残缺清单去设计。
⇒ 过滤器漏词 = **判据域小于变异域**。
这一版把 `duration/repeat/song/audio/ringtone/behavior/config/play` 全补上，
并且对 `BBSound` **不做过滤**（它方法总数很少，全打不贵）。

### 五、结构性改进：重型 dump 不许进日志

上一轮白跑一轮的直接原因是"结构性 dump 被 50 行日志窗口吃了"。
这一版要 dump 的东西**比上一版多得多**（全量方法表几十行 + TLAlertConfiguration +
最多 4 个样本），如果还走日志，一次就能把窗口糊死，把 banner / `SOUND#` 挤出去。

⇒ 拆成两个出口：

| 出口 | 去哪 | 给谁用 |
|---|---|---|
| `NBDiagLog(reset, …)` | 日志 **+** 文件 | 短结论行（`发后①②`、`★ 抓到第 N 种`、dump 边界） |
| `NBDiagLogF(…)` | **只**文件 | 重型结构 dump（属性/setter/方法/ivar/样本字段/设前设后） |

判据是"这段内容是不是用户靠截图必须看到的" —— 不是就走文件。
并且写了机器判据 `a18`：五个 dump 函数里**不许出现** `NBDiagLog(`。

### 六、这一版侦察什么

| # | 挖什么 | 为什么 |
|---|---|---|
| 1 | `BBSound` 的**类方法**（`object_getClass` 取元类） | 如果有 `+soundWith…` 工厂，就该让系统替我们造，不用再手工拼字段 |
| 2 | **`TLAlertConfiguration`** 的属性 / setter / 类方法 / ivar | 它是 iOS 16 通知音的真身，我们需要"怎么造一个能用的 cfg" |
| 3 | 最多 **4 种不同形态**的外来 sound（按指纹去重）+ 各自的 `alertConfiguration` | 上一版只留 1 个样本，等于只认识一种长相；多样性才能看出 `soundType` 的取值规律 |
| 4 | `BBSound` 的 **ivar** 表 | `toneIdentifier` / `alertType` / `ignoreRingerSwitch` 都是只读 property，KVC 写它们会退化成写 ivar，得先知道 ivar 叫什么 |

### 七、装了这一版要做什么

**行为不变**（通知仍然按原声播，不会变哑巴）。要做的只有一件事：

1. 装包、重启 SpringBoard；
2. 正常用一会儿，让那个 App 至少响 2–3 条通知（有声音的那种）；
3. 「诊断」→「声音诊断文件（完整，换提示音必看）」，**整份发我**。

这一版文件会比上一版长不少（多了方法表和 ivar），是正常现象。重点看：

```
SD# BBSound 的类方法共 N 个 (找工厂：+xxx 形式的最关键)
SD# BBSound 的类方法: …                                    ← 有没有 +soundWith…
SD# TLAlertConfiguration 有 N 个属性（[W]=可写 [R]=只读）
SD# TLAlertConfiguration 的类方法: …
SD# ★ 抓到非 nil 的 sound 第 N 种 …
SD# ★ 它的 alertConfiguration cls=… （这就是 TonesLibrary 的真身）
SD# 该 alertConfiguration 值: toneIdentifier=… soundType=… …
```

### 八、判据层

- `nb_v024_src_check.py`：**18 条**二进制里查不到的语义判据 + **18 条**负向自测全红。
  新增两条专门守这次的教训：
  - `a18` 重型 dump 只写文件（不许把日志窗口糊死）；
  - `a09` "有没有找到过"必须用独立变量（不许复用 `buf.length`）。
- `nb_verify_v024.py`：第 16 节**整体反转**。
  v0.0.23 是"改了刀、想让它响"；v0.0.24 是"**确认没挂** + 侦察真接线"。
  其中一条反向断言：`repetitions` 必须彻底消失，并配 `repeats` 的正向对照
  （防止"包是空的也让反向判据通过"）。

### 九、交付

```
dist/com.yxh41.notifybox_0.0.24_iphoneos-arm64e.deb   83270 bytes
CI run #47 / run_id 39890251473（zip 83450 bytes，与 API 的 size_in_bytes 对拍一致）

nb_verify_v024.py: 202 项 0 FAIL
nb_v024_src_check.py: 18 条判据全绿 / 18 条负向自测全红
nb_lit_check: 64 条全过
```

---

## v0.0.25 · 换挂点：不再造 BBSound，改挂通知音总闸门

> 一句话：**我们一直在错的地方动手。**
> v0.0.21~v0.0.24 都在 BulletinBoard 的 `BBSound` 里手工拼字段（造系统对象），
> 而正确的挂点是一个返回 BOOL 的闸门 —— `SBNCSoundController -canPlaySoundForNotificationRequest:`。
> 这一版在那里**先把我们的音播出去，播成功了才让系统别播**。
>
> ✅ **状态：真机验证通过（2026-10-23，用户："是我们的提示音"）** —— 见「八点五」。
> 这是从 v0.0.21 起第五版、也是**唯一一版真的换出声音**的版本。

### 一、转折点是「去看看别人怎么写」

v0.0.24 之后我去翻了 GitHub 上同类插件（用户提醒的）。四个参考，全部源码存档在 `docs/refs/`：

| 插件 | 作者 | 开源 | 做法 | 价值 |
|---|---|---|---|---|
| **SilentNotifs** | dayanch96 | 源码可见 | hook `SBNCSoundController -canPlaySoundForNotificationRequest:` 返回 `NO`；注入 `com.apple.springboard`，arm64+arm64e | 🔴🔴 **通知音总闸门** |
| **NotchBanners** | ginsudev | 源码可见 | `request.sound.alertConfiguration` → `[TLAlert alertWithConfiguration:]` → `play` | 证明 cfg 能直接播出声音 |
| **SmartNotifications (iOS16)** | EliasSfeir | ❌ 付费 | 音频放 `/Library/Application Support/SmartNotifications` | 强证据：它**自己播**，不走系统铃声库 |
| **BootSound** | ginsudev | 源码可见 | 自己播 `/Library/BootSound/` 下 mp3/wav/caf | 自播 mp3 在 SpringBoard 侧可行 |
| ToneManager | Jesperflodin1 | ✅ MIT | 逆向 GuitarBand，用 TonesLibrary 装 m4r | 「音频→系统铃声」的完整参考（重） |

SilentNotifs 全文只有 **23 行**，核心就这一段：

```objc
%hook SBNCSoundController
- (BOOL)canPlaySoundForNotificationRequest:(NCNotificationRequest *)request {
    if ([request.sectionIdentifier isEqualToString:@"com.apple.mobiletimer"])
        return %orig;                                  // 闹钟放行
    BOOL shouldSilent = [[%c(SBMediaController) sharedInstance] isPlaying];
    return shouldSilent ? NO : %orig;
}
```

⚠️ 许可证：SilentNotifs / NotchBanners 的仓库**没有 LICENSE 文件** ⇒ 只参考做法，代码全部自己写。

### 二、这个挂点好在哪（四条，逐条对上我们踩过的坑）

| | `BBSound`（我们做了四版） | `SBNCSoundController`（这一版） |
|---|---|---|
| 要造对象吗 | 要手工拼一个"能响的壳" | **不用，纯返回 BOOL** |
| 有 bundle id 吗 | **没有** —— "按 App"只能靠外层传参凑 | `request.sectionIdentifier` 直接给 |
| 造错会怎样 | v0.0.21 实测：**整条通知变哑** | 不会，只影响"响不响" |
| 影响横幅/振动吗 | 未知 | 不会（振动是另一条通道） |
| 有没有放行先例 | — | 有：闹钟走 `%orig` |

### 三、认知纠正：v0.0.21 那次「完全没声音」不是纯失败

当时我们把「挂了个空壳 ⇒ 系统不响」记成失败。现在看，它验证的正是方案里
**"静音原声"那一半** —— 我们能影响到"通知出不出声"这件事，只是当时想让它响别人的音。

同理 v0.0.24 的判断只对了一半：`alertConfiguration` 确实是 iOS 16 通知音的真身，
但**不一定需要我们自己造它** —— `request.sound` 上系统已经给了一个。

### 四、做法：顺序是全部

```objc
if ([NotifyFilter playCustomSoundForBundle:bid forResult:&sres]) {
    ...留痕...
    return NO;          // 我们的音已经送出去 ⇒ 别让系统再播一遍
}
return %orig;           // 没播成 / 没配 / 抛异常 ⇒ 老老实实放原声
```

**顺序反过来（先掐再播）就是"播失败 ⇒ 哑巴"。** 所以返回契约写死在 `NotifyFilter.h` 里：
`NO` = 调用方**必须**放系统原声。

播放用 `AudioServicesPlaySystemSound(sid)`，不用 `AVAudioPlayer` / `TLAlert`：

| 理由 | 说明 |
|---|---|
| 同一条路 | 播的就是 1000~1035 系统提示音，**设置页试听走的是同一条路** ⇒ 试听能响就能推出通知能响 |
| 静音语义免费 | 自动遵循静音开关；不用碰 `AVAudioSession`（在 SpringBoard 里改 category 有全局副作用） |
| 不打断音乐 | 系统提示音的固有行为 |

⚠️ 诚实的局限：`AudioServicesPlaySystemSound` 返回 `void`，**拿不到"真的播出来了"**。
这里的"成功"只表示"ID 合法 + 播放请求已发出"。假阴性的兜底就是设置页的「试听」。

### 五、四道防线（每条都有机器判据）

| # | 防线 | 不做会怎样 | 判据 |
|---|---|---|---|
| ① | **先播后掐** | 播失败就是哑巴 | `b03` |
| ② | **播不出就 `%orig`**，函数尾部必须有出口 | 等于把系统原声彻底废掉 | `b04` |
| ③ | **按 `notificationIdentifier` 去重** | 同一条通知在锁屏+横幅各问一次 ⇒ **连响两遍** | `b21` |
| ④ | **记 nid 必须在播成功之后** | 首次播失败也记上 nid ⇒ 第二次直接掐原声且不再播 = 永久哑巴 | `b22` |

第 ③ 条还有个反向保护：**拿不到 nid 就完全不去重**。
理由：没有唯一 ID 时只能按时间窗猜，而"同一个 App 紧接着发的第二条真通知"会被窗口误吞。
⇒ **宁可偶尔响两遍，也不要吞掉一条真通知。**

### 六、不挂的情况也留痕

```objc
Class gsc = objc_getClass("SBNCSoundController");
if (!gsc) {
    NBLog(@"!!! v0.0.25 SBNCSoundController 类不存在 ⇒ 换提示音不挂（通知照旧原声）");
} else {
    // class_copyMethodList → 集合 → 有没有 canPlaySoundForNotificationRequest:
    // 有 ⇒ %init(GSC)
    // 没有 ⇒ 把含 sound/play/vibrat/alert 的方法名**全打出来**（下一轮不用猜）
}
```

🔴 名字来自外部参考、本机未验证 ⇒ **不许无条件 `%init`**。类不存在时往 nil 上 hook 是"什么都可能发生"。

### 七、判据层

- `nb_v025_src_check.py`：**23 条**语义判据 + **23 条**负向对照，全绿。
- 🔴 **负向自测抓到自己 6 条判据是形同虚设的**（工具干对了活）：
  | 判据 | 病因 |
  |---|---|
  | `b01` | 变异锚点 `AudioServicesPlaySystemSound` 第一次出现在**注释**里 ⇒ strip 后变异消失，测的是空气 |
  | `b06` | 只用"有没有 `@try`"判 ⇒ 内层那个 `@try` 冒充外层，去掉外层也不报红 |
  | `b07` | `gSoundApplied <= 8` **包含在** `<= 8000` 里 ⇒ 子串陷阱 |
  | `b15` | 同上：`static int gSoundApplied` 是 `gSoundAppliedX` 的子串 |
  | `b21` | 同上：`notificationIdentifier` 是 `notificationIdentifierX` 的子串 |
  | `b08` | 变异锚点跨了两行（中间隔着注释），找不到 |
- 子串陷阱同一类错误在这一轮出现了 **3 次**。⇒ 判据锚点一律取「带分号的完整语句」或正则，别用裸名字。
- 🔴🔴 二进制校验里还抓到一条**假绿**（比假红危险得多）：`dylib 里已无 NBSoundFieldSummary`
  在**旧刀还在的 v0.0.24 包上也是绿的**。病因：它是 `static` C 函数，
  **静态函数名根本不进二进制**（实测 v0.0.24 包里 0 次命中，而那一版源码里明明有这个函数）。
  ⇒ 断言在"有"和"没有"两种包上都成立 = 没测。已删除，改由源码层 `b01` 覆盖。
  这类失败不会报错，只会让报告看起来更硬。

### 八、装了这一版要做什么

1. 装包、重启 SpringBoard；
2. 设置页打开「换提示音」，**先点「试听」确认这个 ID 在你手机上能响**（这是唯一的兜底验证）；
3. 把目标 App 加进名单；
4. 让那个 App 发一条通知，听：

| 听到什么 | 说明什么 | 下一步 |
|---|---|---|
| **我们的提示音** | ✅ 成 | 收口 |
| **原声** | 闸门没挂上 / 名字不对 | 看 banner 下面那行 `SBNCSoundController N 个方法 · canPlaySoundForNotificationRequest=YES/NO` |
| **两个声音叠在一起** | 播成了但`return NO`没生效 | 闸门对了、返回值没被采纳 |
| **完全没声音** | 🔴 最坏 | 播了 + 掐了原声 = 哑巴。立刻关掉开关，把日志发我 |

第 4 种在代码里已经被"先播后掐 + 播失败就 `%orig`"挡住了，理论上到不了；
真到了说明 `AudioServicesPlaySystemSound` 发出了请求但系统没出声 —— 那要换 `AVAudioPlayer`。

### 八点五、🔴 真机结果：**第 1 种 —— 成**（2026-10-23）

用户原话：**「是我们的提示音」**。

这一句同时证明了三件事，缺任何一件都听不到我们的声音：

| # | 被证明的事 | 为什么它单独成立没用 |
|---|---|---|
| 1 | `SBNCSoundController` 这类**存在**、`canPlaySoundForNotificationRequest:` 这个选择器**真的存在且被调用** | 只证明闸门在，不代表我们播了 |
| 2 | `AudioServicesPlaySystemSound` 在 SpringBoard 进程里**真的能出声** | 只证明响了，不证明系统那一声被掐掉 |
| 3 | `return NO` **确实被调用方采纳**了 | 否则会听到两份声音叠在一起（第 3 种） |

⇒ 听到的是**单独一声、来自我们的 ID**，就等于 1+2+3 全成立。

**这一版否掉的是什么**：v0.0.21~v0.0.24 四版走的「alloc 一个 `BBSound` → 填
`systemSoundID`/`soundType`/`alertConfiguration`/`repetitions`/`maxDuration` →
`setValue:forKey:@"sound"` 挂到 bulletin 上」这**整条路线**，不是细节没调对，是**路选错了**。
`BBSound` 是"给系统放音用的描述"，自己造一个空壳永远差一口气；
`SBNCSoundController` 才是"要不要出声"的**唯一决策点**，而 `AudioServicesPlaySystemSound`
是**独立于通知系统的另一条出声通道** —— 两者组合才成立。
（认知纠正：v0.0.21 的"试听响、通知不响"不是玄学，是因为试听走的就是 `AudioServices`、
通知走的是 `BBSound`，两条完全不同的路。）

**✅ 第二轮真机确认（2026-10-23 下午）—— 用户原话**：

> **「听到的跟试听的一样，锁屏能听跟在桌面听是一样的」**

这一句把上一版留下的两个疑点一起结掉了，而且**不是靠推断、是靠听**：

| 疑点 | 结果 | 为什么这一句能证明 |
|---|---|---|
| 会不会连响两遍 | ✅ **没有**，就一声 | 「跟试听的一样」—— 试听是**单声**。真连响两遍，第一耳就是"响了两次"，不会描述成"一样" |
| 锁屏 + 横幅两处是否都换 | ✅ **两处一致** | 锁屏和桌面是两个不同的触发场景（横幅/锁屏各走一次闸门），音色相同 ⇒ **两处都进了同一个闸门、都换成我们的音** |
| `notificationIdentifier` 去重是否生效 | ✅ 看到的现象与"生效"一致 | 反向证据：如果锁屏那一路读不到 nid，那一路会**再响一次** —— 没听到 |

⇒ **v0.0.25 至此可以收口**：挂点、自播、掐原声、去重，四项都有真机证据。

**仍未验证的（只有一条，而且不影响使用）**：

- ID 边界（1000 / 1035）与"ID 填错时的报错留痕"是否如设计那样可见 —— 这两条是**配错时的提示**，
  正常使用碰不到；等真有人填错时再看日志即可。

### 九、交付

```
dist/com.yxh41.notifybox_0.0.25_iphoneos-arm64e.deb   82196 bytes
CI run #48 / run_id 39895122132（zip 82375 bytes，与 API 的 size_in_bytes 对拍一致）

nb_v025_src_check.py:  23 条判据全绿 / 23 条负向对照全红
nb_verify_v025.py:    201 项全绿（含 1 条反向对照 → 拿 v0.0.24 的包喂进去恰好红 25 项）
nb_lit_check.py:       56 条含中文字面量判据 PASS
```


---

## v0.0.26 · 自定义音频文件：从「30 个系统音」放开到「任意音频」

> 一句话：**挂点不用再动了**（v0.0.25 已真机验证），这一版只解决"换成什么"。
> 优先播 `/var/mobile/Library/NotifyBox/Sounds/` 里用户指定的文件，没选文件就退回系统提示音 ID。

### 一、为什么这一版可以很小

v0.0.25 解决的是"**能不能**换"（挂点选错，四版白做）；v0.0.26 解决的是"**换成什么**"。
挂点已经验证过（用户原话「是我们的提示音」），所以这一版**一行挂点代码都没动** ——
判据 `c25` 就是专门守这件事的（`%hook SBNCSoundController` + `return %orig` 必须原样在）。

### 二、两条出声通道（按**已验证程度**排序，不是按"哪个更强"）

| 通道 | API | 吃什么 | 状态 | 代价 |
|---|---|---|---|---|
| **A** | `AudioServicesCreateSystemSoundID` → `AudioServicesPlaySystemSound` | caf / wav / aiff | 🟢 **播放那一步就是 v0.0.25 验证过的同一个函数** | 无。不碰 `AVAudioSession`，天然遵循静音键、不打断音乐 |
| **B** | `AVAudioPlayer` | mp3 / m4a / m4r / aac / flac | 🟢 **已验证（2026-10-23 真机，mp3 能响）** | ⚠️ 必须动 `AVAudioSession`（只设 `Ambient`+`MixWithOthers`，绝不设 `Playback`） |

⇒ 所以 A 排第一：**能在 A 走通就绝不碰 B**。B 只是"mp3 也要能播"的兜底。

### 三、四条规则，每条写反都会出具体毛病

| 规则 | 写反的后果 |
|---|---|
| **文件优先于 ID** | 选了文件还响系统音 ⇒ 用户以为"选了没用" |
| **文件播不出去 ⇒ `return NO`** | 写 `return YES` = 原声被掐 + 我们没响 = **哑巴** |
| **先判 App 名单、再 stat 文件** | 顺序反了 ⇒ 不在名单里的 App 也天天打"文件不存在"的告警 |
| **A 失败才走 B** | 顺序反了 ⇒ 把已验证的通道降级成兜底，等于回到"未验证"状态 |

### 四、文件名净化：为什么必须做

`soundFile` 存在 `settings.plist` 里，是**外部输入**（用户可手改）。不净化的话：

- `../../../../var/mobile/Library/SMS/sms.db` 之类能让 SpringBoard 去读任意文件；
- 把非音频文件喂进 `AudioServices` / `AVAudioPlayer`，行为不可预期。

做法是**只拒绝、不改名**（`NBIsSafeSoundFileName`）：含 `/`、含 `..`、以 `.` 开头、超过 120 字
一律当"配置错"处理 ⇒ 放原声 + 一条 `onceBadFile` 告警。
不改名是因为改名会出现"我明明放了这个文件、界面显示的名字却不是它"这种更难查的现象。

### 五、怎么用

1. 设置页 → 「提示音文件（优先于上面的 ID）」→ 页面会**自己建目录**并把完整路径写在页脚；
2. 用 Filza（或爱思/SSH）把音频放进 `/var/mobile/Library/NotifyBox/Sounds/`；
3. 回到该页面点它 —— 列表里会标注这个文件走 **A（已验证通道）** 还是 **B（兜底）**；
4. 选中时**当场试播**：播不出来就弹窗、**且不保存**（保存了只会让你以为配好了）；
5. 再点设置页的「试听这个提示音」确认一次；
6. 让目标 App 发一条通知。

> 超过 30 秒的音频建议先剪短：A 通道（系统音）只播前 30 秒。

### 六、⚠️ 这一版最重要的一句诚实说明

**试听跑在盒子 App 进程，通知跑在 SpringBoard 进程。**

所以「试听能响」只能证明"这个文件/ID 能解码"，**不能** 100% 保证通知一定响。
A 通道之所以可信，是因为它的播放函数和 v0.0.25 真机验证过的完全是同一个；
B 通道（mp3 那类）原先排在兜底位置，是因为**它当时一点真机证据都没有** ——
2026-10-23 已由用户实测「wav 和 mp3 都响」补上（见「十点五」）。
**但它仍然比 A 多两个变量**：`AVAudioPlayer` 的生命周期、以及 `AVAudioSession`。
所以 A 能处理就绝不走 B —— 这就是「用已验证的，不用功能更强的」这条规矩的实例。

⇒ 如果试听响、通知不响，看 `tweak.log` 里的 `SOUND#` 行 —— 它会写明
`自播 file=xxx ch=A` / `ch=B` / 还是 `播不了 file=xxx（A:… / B:…）`。

### 七、判据层

- `nb_v026_src_check.py`：**28 条**语义判据 + **28 条**负向对照，全绿。
- 🔴 **负向自测又抓到我 3 条形同虚设的判据**（这次是"变异没打中判据读的那个串"）：

  | 判据 | 病因 |
  |---|---|
  | `c02` | 变异插的是 `fileExistsAtPath:@"/x"`，而判据查的是 `fileExistsAtPath:path` ⇒ 变异和判据量的**不是同一个串** |
  | `c15` | 判据只比"`NB_KEY_SOUND_FILE` 与 `sid` 播放的先后"，把守卫改成 `if (NO)` 时那串**位置没变** ⇒ 照样绿。改成判「守卫条件本身在不在」 |
  | `c20` | 判据只比"`if (!ok)` 与 `saveSettings` 的先后"，把 `if` 里的 `return;` 删掉位置也不变 ⇒ 改成判「那个 if 里有没有提前 return」 |

  ⇒ 通则：**位置型判据挡不住"条件被关掉"**。凡是守"这个分支会不会走到"的，要判守卫条件本身。

- 另外 `c28` 那条结构判据第一版报了三处假红：`@implementation` 也要配 `@end`，
  而我只数了 `@interface` —— 判据错就改判据，不许改代码迁就。

### 八、装了这一版要做什么

| 听到什么 | 说明什么 | 下一步 |
|---|---|---|
| **你的文件** | ✅ 成 | 收口 |
| **系统提示音** | 文件没生效（名字不合法/扩展名不认识/文件不在目录） | 看设置页那一行是不是写着「（文件不在）」；再看日志里有没有 `文件不可用` |
| **原声** | 判定没过（开关没开/App 不在名单/ID 或文件不合法） | 看 `SOUND#` 行里的原因 |
| **完全没声音** | 🔴 最坏 | 立刻关掉开关。理论上到不了（播失败一定 `return NO`），真到了把日志发我 |

### 九、交付

```
dist/com.yxh41.notifybox_0.0.26_iphoneos-arm64e.deb   87680 bytes
CI run #49 / run_id 39910177129（zip 87867 bytes，与 API 的 size_in_bytes 对拍一致）

nb_v026_src_check.py:  28 条判据全绿 / 28 条负向对照全红
nb_verify_v026.py:    229 项全绿（负向对照：拿 v0.0.25 的包喂进去恰好红 30 项）
nb_lit_check.py:       66 条含中文字面量判据 PASS
```

### 十点五、🔴 真机结果：**两条通道都成**

用户原话：**「两个格式都试了，都响」** —— 即 wav（走 A）和 mp3（走 B）都换出了自己的音。

这条一句话的信息量比看上去大：

| 被证明的事 | 为什么值钱 |
|---|---|
| **A 通道的文件路径成立** | v0.0.25 验的是「系统提示音 ID」；这一版验的是「文件 → `CreateSystemSoundID` → 播放」，**中间多了一段解码**，现在这段也通了 |
| **B 通道成立** —— `AVAudioPlayer` 在 **SpringBoard 进程**里能出声 | 本轮**全新**的证据。之前 B 只是「代码写得对」，没有任何真机观察 |
| **在 SpringBoard 里设 `Ambient`+`MixWithOthers` 是安全的** | 改 session category 是全局副作用，最怕两件事：崩、把用户的音乐掐了。两样都没发生 |
| mp3 不用转 caf | 「用户想用自己的音频」这个需求真正兑现了 |

**⚠️ 仍然没验到的（这次要说清，别再漏）**：

- **放着音乐时**通知音是叠在歌上、还是把歌压低 —— `MixWithOthers` 的预期是「共存」，
  但没人在放歌的时候试过；
- 🔴 **两条通道的时长行为不一致**：
  A（`AudioServices`）最多播 **30 秒**，B（`AVAudioPlayer`）会**从头播到尾**。
  ⇒ 拿一首 3 分钟的歌当提示音，wav 版响 30 秒、mp3 版响 3 分钟。
  这不是理论问题，是「换了自己喜欢的音频」之后**第二天就会遇到**的问题。

### 十、这一轮又抓到两类「我自己的判据错」

二进制校验第一版报 **2 项假红**，两条都不是代码问题：

| 判据 | 病因 |
|---|---|
| `App 内含 '不要文件（用系统提示音 ID）'` | 源码写的是**不**用文件，我凭记忆把断言打成了**不要**文件 ⇒ 一个字之差 = 永远红。字面量必须**从源码逐字抄**（`nb_lit_check` 就是为这类错写的） |
| `dylib banner 写着「换了挂点」` | 那是 **v0.0.25 的文案**，这一版已改成「可换自定义音频文件」。把上一版的正向断言留在这一版 = 永远红 ⇒ **正反一起翻**：这里守"旧的没了"，第 17 节守"新的在" |

另外 `nb_lit_check.py` 本身也报过 4 条假红：它的**源文件清单是手写的**，
新加的 `app/SoundFilePickerViewController.m` 没登记 ⇒ 那个文件里的 4 条中文字面量被判"不存在"。
⇒ 已改成**从 Makefile 的 `NotifyBox_FILES` / `NotifyBoxApp_FILES` 直接读**。
这多一层保障：**"文件写了但没登记进 Makefile"会被立刻发现** —— 那种错在 CI 里是
`application.mk` 静默跳过、deb 里少东西，比编译报错难查得多。

### 十一、下一步候选（按"用户多久会撞上"排序）

| 候选 | 用户多久撞上 | 工作量 | 说明 |
|---|---|---|---|
| **① 播完 / 时长上限**（推荐） | **第二天** | 小 | 现在 A 通道最多 30 秒、B 通道**从头播到尾** —— 拿首歌当提示音就是"响 3 分钟"。两条通道行为不一致本身就是 bug 级问题。做法：加一个「最长播放秒数」设置，B 通道到点 `stop`；A 通道天然 30 秒封顶，在界面写成提示而不是假装能控 |
| ② 每个 App 各自一个音 | 一周内 | 中 | 现在是「一份名单共用一个音」。要做成 `App → 音` 映射表，设置页得改成可编辑列表，`soundFile`/`soundID` 要变成按 App 存 |
| ③ 放着音乐时的行为 | 不一定 | 小（验证） | `MixWithOthers` 预期是"共存"，但没人真试过。要做的是**验证 + 可能要加音量控制**，不是重写 |
| ④ 收尾 | — | 小 | 撤销轮换 PAT、归档临时脚本、把 `_prefs_disabled/` 再确认一遍 |

**为什么推荐 ①**：它不是新功能，是**把已经上线的功能修到自洽**。
现在用户只要放一个超过 30 秒的音频，就会遇到"wav 响 30 秒、mp3 响到底"这种
"同一份设置、两种表现"的现象 —— 这种不一致比缺功能更伤，因为它让人怀疑"是不是没生效"。

---

## v0.0.27 · 提示音「最长播放秒数」：把两条通道的时长拉齐

> **这一版不是新功能，是把已经上线的功能修到自洽。**

### 一、真问题（v0.0.26 真机实测出来的，不是拍脑袋）

v0.0.26 让用户可以放自己的音频了（用户原话「两个格式都试了，都响」），
但同一份设置、同一个文件，**两条通道的时长行为根本不一致**：

| 文件 | 通道 | 实际响多久 |
|---|---|---|
| wav / caf / aiff | A（`AudioServicesPlaySystemSound`） | **最多 30 秒**（系统硬上限） |
| mp3 / m4a | B（`AVAudioPlayer`） | **从头响到尾**（3 分钟的歌就响 3 分钟） |

拿一首歌当提示音：wav 版响 30 秒、mp3 版响 3 分钟。
用户看到的是"同一份设置两种表现"，第一反应只会是"是不是没生效"。
**这种不一致比缺功能更伤** —— 它让人怀疑整个功能是假的。

### 二、关键决策：按「能不能播完」选通道，**不是**给 A 加定时器

先说差点写错的那一版，以及为什么它不可行：

- A 通道**没有 stop API**。唯一的 `AudioServicesDisposeSystemSoundID` 会把播放一起掐断
  并释放资源（下次还得重建）⇒ 等于"停一次废一个 ID" ⇒ **不许拿它当停止用**。
- 所以"给 A 加个 `dispatch_after` 到点停"这条路**根本不存在**：
  加了也没有东西可停，只会在包上多一个时序 bug。

正解是把**选路**交给时长 —— 能不能在时限内播完，就决定了走哪条：

| 文件时长 | 上限 | 走哪条 | 实际时长 |
|---|---|---|---|
| ≤ 上限 且 ≤ 30 秒 | 任意 | **A**（v0.0.25 已验证通道，零 session 副作用） | 完整播完 |
| > 上限（但 ≤ 30 秒） | > 0 | **B**，到点 `stop` | 正好上限 |
| > 30 秒 | = 0（不限） | **B**（A 会截断，放不全） | 完整播完 |
| > 30 秒 | > 0 | **B**，到点 `stop` | 正好上限 |
| 量不出来 | > 0 | **B**，到点 `stop`（**不赌 A**） | 最多上限 |
| 量不出来 | = 0 | **A** | 系统行为（≤30 秒） |

⇒ 一句话：**只要用户设了上限，任何格式都不会超过上限；没设上限时，A 放得完就用 A。**

### 三、语义（`soundMaxSec`）

| 值 | 含义 |
|---|---|
| 键不存在 / 清空 | **默认 8 秒** |
| `0` | **不限**（回到 v0.0.26 的行为） |
| `1` ~ `120` | 该秒数，允许小数（例如 `2.5`） |
| `> 120` | 夹到 120 |
| 负数 / 非数字 | 当没填 ⇒ 默认 8 秒 |

🔴 表里最后一行不是洁癖：`[@"abc" doubleValue]` 返回 **0**，而 0 的语义是**不限**
⇒ 一个手滑就从"8 秒"跳到"播到底"，而且界面上看起来还"保存成功了"。
所以解读用 `NSScanner` 严格校验（`scanDouble` + `isAtEnd`），
保存时再单独拦一次（`0~120`），不合法就**不写盘**并弹提示。

### 四、判据：选路逻辑只有一处

`nbPrefersAudioServicesForDuration:cap:` 是**全项目唯一一处**选路逻辑。
文件列表的副标题也走它（`playbackPlanForFileNamed:`）——
这样"界面上写的"和"实际做的"不可能走岔。

> 这修掉了 v0.0.26 的一个**会说错话**的地方：副标题当时按**扩展名**标
> 「AudioServices（已验证通道）」/「AVAudioPlayer 兜底」，
> 而一个 40 秒的 wav 现在实际走的是 B。用户是照着那行字做判断的，
> 所以它现在改成量出来的事实：`12.4 秒 · 走 B，8 秒后停`。

### 五、两条通道互为兜底：一个必须讲明的取舍

先走的那条失败，会试另一条。代价是：**如果先走 B 却失败了，退到 A 时不再遵守上限**
（A 没法截断）。这个取舍只发生在"两条都出问题"的路径上 ——
那时**响得久一点，远好过哑巴**。这一条写进了代码注释，也写在这里。

### 六、怎么用

1. 设置页 → 「提示音文件（优先于上面的 ID）」→ 选一个文件（列表里会写它会响多久）；
2. 设置页 → 「最长播放秒数（0 = 不限；清空 = 默认 8）」：
   - 想"提醒一下就够" ⇒ 保持默认 8；
   - 想让它完整播完 ⇒ 填 `0`（清空也一样回到 8，**0 才是"不限"**）；
3. 「试听这个提示音」确认一次（状态栏会写出用了哪条通道、量到多长、上限多少）；
4. 让目标 App 发一条通知。

### 七、⚠️ 行为变化（升级前必读）

**默认上限是 8 秒**，所以 v0.0.26 里"响到底"的长音频，这一版会**在 8 秒停**。
这不是 bug，是这一版的目的（两条通道行为一致）。想恢复原样：把秒数填 `0`。

### 八、这一版顺手修了一个既有 bug

`SettingsViewController` 的 `strOf:` 原来**不认 `NSNumber`**，对数字型设置一律返回空串。
而 `soundID`（v0.0.21 起）和新的 `soundMaxSec` 落盘时都是 `@(n)` ⇒
**重新进设置页时输入框是空的**。值明明在生效，界面却说没设过 ——
用户会重新填一遍，填成别的就等于悄悄改配置。已修（`NSNumber` 走 `stringValue`）。

### 九、判据层

- `nb_v027_src_check.py`：**44 条**语义判据 + **44 条**负向对照，全绿。
  新增的重点：
  - `v04` 选路两条规则**逐字**在（判守卫条件本身，不判位置 —— 这是 v0.0.26 的教训）；
  - `v06` / `v07` `needStop` 公式 + `[pl stop]` 必须**在 `if (needStop)` 里面**
    （变异把 stop 提到守卫外 ⇒ 报红 ⇒ 短提示音被削尾音）；
  - `v10` 量时长**不许** `play`、**不许**碰 `AVAudioSession`（否则选路阶段就出声，用户听到两遍）；
  - `v11` 不许用 `AVAsset`（iOS 16 起 `duration` 被弃用，要求异步 `load`）；
  - `v03` A 通道里**不许**出现 `dispatch_after`/`stop`/`Dispose`（"给 A 加定时器"这个错想都别想）。
- `nb_verify_v027.py`：包级校验（见「十、交付」的数字）。新增第 18 节：
  正向 = 新的 `dur=%.1f cap=%.1f` 结果串、`soundMaxSec` 键、选路函数名、播放计划两句话；
  **反向** = `ch=A` / `ch=B` / 「AudioServices（已验证通道）」/「AVAudioPlayer 兜底」/
  `AVURLAsset` 一律不许在包里 —— 它们留着就说明"旧的选路写法还在文件里"。
- `nb_lit_check.py`：**72 条**含中文字面量判据 PASS（它从 Makefile 读源文件清单）。

### 十、交付

```
dist/com.yxh41.notifybox_0.0.27_iphoneos-arm64e.deb   89648 bytes
CI run #51 / run_id 39915652280（zip 89827 bytes，与 API 的 size_in_bytes 对拍一致）

nb_v027_src_check.py:  44 条判据全绿 / 44 条负向对照全红
nb_verify_v027.py:    249 项全绿（负向对照：拿 v0.0.26 的包喂进去恰好红 28 项，
                       红的全是这一版新增的：版本号 + 6 个新串 + 4 条反向）
nb_lit_check.py:       72 条含中文字面量判据 PASS
```

### 十一、装了这一版要验什么

| 你该验的 | 怎么验 | 预期 |
|---|---|---|
| 短文件不被削 | 放一个 ~3 秒的 wav，发一条通知 | 完整响完；日志 `ch=A dur=3.x cap=8.0` |
| 长文件被截断 | 放一个 30 秒的 mp3 | 约 8 秒后停；日志 `ch=B ... cap=8.0` |
| 上限真的生效 | 秒数改成 `2` | 只响约 2 秒 |
| 「不限」能回去 | 秒数改成 `0` | 长文件响到底（且 wav 也不再有 30 秒限制，因为走了 B） |
| 换同名文件立刻生效 | 用 Filza 覆盖同名文件 | 时长随之变（缓存按 大小+mtime 失效，不用重启） |

### 十二、下一步候选（按"用户多久会撞上"排序）

| 候选 | 用户多久撞上 | 工作量 | 说明 |
|---|---|---|---|
| **① 每个 App 各自一个音** | 一周内 | 中 | ✅ **v0.0.28 已做**（见下一章） |
| ② 放着音乐时的行为 | 不一定 | 小（验证） | `MixWithOthers` 预期是"共存"，但没人真在放歌时试过。要的是**验证 + 可能要加音量控制**，不是重写 |
| ③ 收尾 | — | 小 | 撤销轮换 PAT、归档临时脚本、把 `_prefs_disabled/` 再确认一遍 |

---

## v0.0.28 · 换提示音改成「每个 App 各自一个音」

> **这一版是数据格式变更**：`soundApps`（一份名单 + 一个全局音）→ `soundMap`（App → 音）。

### 一、为什么必须改格式，而不是加个界面

v0.0.21~27 的结构是「**一份 App 名单，共用一个音**」。用户第二个需求一定是
"微信用 A、QQ 用 B" —— 而旧结构**连"两个 App 两个音"都表达不了**。
这不是界面不好用，是**数据存不下**，所以最小的正确改动就是换存储：

```
soundApps: [ "com.tencent.xin", "com.tencent.mqq" ]        ← 旧：名单
soundMap:  { "com.tencent.xin": { "file": "a.mp3" },      ← 新：App → 音
             "com.tencent.mqq": { "id": 1007 } }
```

关键推论：**名单就是 map 的键**，不需要再单独存一份名单。
两份并存必然出现"名单里有它、map 里没有它"这种对不上的状态 ——
而那种错在界面上看不出来（两页都显示正常，只是各自读各的）。

### 二、存储口径（唯一权威：`NotifyCommon.h`）

| `soundMap[bundleId]` | 含义 |
|---|---|
| `{"file": "xxx.mp3"}` | 这个 App 用这个文件（**文件优先于 id**，与全局同口径） |
| `{"id": 1007}` | 这个 App 用这个系统音（1000~1035） |
| 两者都有 | **文件赢**（与判定顺序一致） |
| 没有这个键 | 不换音（用系统原声） |
| 键在但 file/id 都空 | **不合法，判定时丢弃**（见第四节） |

全局的 `soundFile` / `soundID` 保留，但语义变了：从"目标 App 用什么音"变成
**「默认提示音」= 新加进来的 App 的起始音**。界面文案也跟着改了
（原来写「提示音 ID / 提示音文件」，现在写「默认提示音 ID / 默认提示音文件」）——
不改的话，用户在按 App 页给微信选了 `a.mp3`、回来看到这里写 `b.wav`，会以为配置互相打架。

### 三、迁移：三条铁律

App 启动时（`AppDelegate didFinishLaunching`）做**一次**迁移，把旧名单里每个 App
物化成一条 `{file}` 或 `{id}` 记录。三条缺一不可：

| # | 铁律 | 不做会怎样 |
|---|---|---|
| ① | **必须删掉 `soundApps`** | 用户在界面里删掉一个 App，旧回退还会命中它 ⇒「我明明删了，它还在响」 |
| ② | 默认音拿不到就**不迁移** | 造一堆"未设置"的半成品 = 旧配置废了、新配置也没有 |
| ③ | 迁移必须**幂等**（已有 map 就返回） | 每次启动都拿旧名单覆盖用户改过的分配 |

**只在 App 进程做，SpringBoard 侧一个字都不写盘。** 通知路径不写盘是纪律：
写盘是用户的动作，不是通知的副作用。（所以 `Tweak.x` 里出现 `migrateSoundMap` 就是 bug。）

迁移失败是**无害**的：拿不到默认音就放弃，旧回退路径照旧工作
（`soundVerdictForBundle` 的 ② 分支），用户不会因此"换音突然全失效"。

### 四、🔴 防哑巴：空壳 entry 必须被丢掉

这是本版最容易造出来的事故：

```
soundMap["com.x"] = @{ @"file": @"" }     ← 空壳
```
判定看到"这个 App 有一条分配" ⇒ 认为要换音 ⇒ `playCustomSoundForBundle` 返回 **YES**
⇒ 调用方把**系统原声掐掉** ⇒ 但实际什么都没播出来 ⇒ **这条通知变哑**。

所以有两道闸：

1. `NBSanitizedSoundMap` 读的时候就丢掉"file/id 都没有"的条目；
2. `setSoundEntry:` 用「净化后还剩不剩」来决定**写还是删** —— 空壳等于删除。

界面上还有第三道：**没有默认音时拒绝把 App 加进来**，并当场给出两条具体路径
（去设置页填 ID，或去选文件）。宁可"加不上"，也不要"加上了但没声音"。

### 五、界面：一页总览 + 一个双模式选音页

| 页面 | 干什么 |
|---|---|
| **按 App 分配提示音**（新） | 列出"谁有自己的音"+ 那个音是什么；点进去改；左滑移除 |
| **添加 / 移除 App** | 复用 App 选择器，点一下 = 建/删一条分配（点一下就是生效，没有保存按钮） |
| **某个 App 的提示音** | 复用选音页的 per-App 模式：当前音 / 系统音 ID / 音频文件 / 移除分配 |

🔴 选音页**只有一个文件**（`SoundFilePickerViewController`），靠 `bundleId` 是否为空分叉：
`init` = 编辑默认音，`initWithBundle:` = 编辑某个 App 的音。
**"选音"的规则两边完全一样**（播不出来的不保存、试听走引擎同一个函数、文件优先于 ID）——
分成两份实现就一定会走岔，而走岔的症状是"我给微信选的音，通知里不是它"。

### 六、做差，而不是"清空重建"

`persistSoundMap` 是**做差**：

| 情况 | 动作 |
|---|---|
| 新勾上、原来没有 | 用默认音建一条 |
| 原来有、现在取消 | 删掉这条 |
| **两边都有** | **一个字都不动** |

第三条是关键。如果图省事写成"先全删、再按当前勾选重建"，那么用户只是进来改了
另一个 App 的勾，回头会发现自己给微信单独选的 `a.mp3` 被重置成默认音了 ——
而且没有任何提示，他只会觉得"这功能记不住东西"。

### 七、删掉旧枚举 `NBAppPickModeSound`（为什么必须删）

留着它 = 留一条能把 `soundApps` **写回设置**的通道。而新的判定在 `soundMap` 非空时
**根本不读 `soundApps`**（迁移还会把它删掉）⇒ 那个模式写进去的东西**没人看**。
表现就是：界面上勾了 App、却一点反应都没有。

⇒ 旧写法只保留"被读"的部分（迁移 + 回退），**不再保留任何写入通道**。
同样的理由在 v0.0.19 删 `NBAppPickModeDelay` 时也用过一次。

### 八、判据（这一版的重心都在"改格式必然带出来的死穴"上）

| 组 | 条数 | 内容 |
|---|---|---|
| 判定 | 8 | map 优先 / 旧格式只作回退 / 两个来源共用**同一条校验尾巴** / 文件优先 / 空壳丢弃 |
| 迁移 | 5 | 必删 soundApps / 拿不到默认音就不迁 / 幂等 / 文件优先 / 只在 App 进程 |
| 界面 | 10 | 不许自己拼 map / 计数不能按数组读 / 做差 / 无默认音时拒绝添加 / 三态副标题 |
| 接线 | 5 | Makefile / 版本三处 / 旧枚举已删 / 键名逐字对 / 括号配平 |

- **28 条语义判据 + 28 条负向变异**：全绿（`.workbuddy/tmp/nb_v028_src_check.py`）
- **反向对照**：拿 v0.0.27 源码跑同一份判据 ⇒ **27/28 变红**
  （唯一没红的是「括号配平」，结构类判据本来就不该对版本敏感）
- **包级判据 16 条**（从 deb 里掏出二进制搜串）：本版 **16/16 通过**；
  拿 v0.0.27 的 deb 喂进去 ⇒ **0/16 全红**

🔴 包级判据这轮踩到一个很值得记的坑：**含非 ASCII 的 `@"中文"` 在 Mach-O 里是
UTF-16LE（`__ustring`），纯 ASCII 才是 UTF-8（`__cstring`）**。
一开始只搜 UTF-8，结果是中文判据全"假红"，而**反向判据全"假绿"**
（旧中文串本来就搜不到，于是"已消失"恒成立）。两种编码都搜之后才真正活过来。

### 九、交付

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.28_iphoneos-arm64e.deb` · **98050 B** |
| CI | 代码构建 **#53**（`run_id 39932917143`）· 文档构建 **#54**（`run_id 39933533873`）· 两次都 success |
| 产物 zip | `#53` 98521 B / `#54` 98229 B（各自与 API `size_in_bytes` 对拍一致） |

⚠️ 这次推送不是 `git push`：本机 `github.com:443` 直连超时、代理 CONNECT 502
（`api.github.com` 直连 200）。所以改走 **GitHub REST API**（blobs → tree → commit → PATCH ref）。
代价是**远端 commit sha 与本地不同**（API 建的 commit 由服务端填 committer），
所以验收口径改成**逐文件 blob 对拍**：远端 tree 里 51 个文件的 blob sha 与本地 `HEAD:<path>`
逐一相等 —— 这比"sha 相同"更硬，它直接证明每个文件的字节都一致。

> 顺带记一条：API 推送下"远端 sha ≠ 本地父提交"是**常态**，所以判断能不能推
> 不能看 sha，要看 **tree**：`远端 head 的 tree == 本地 HEAD^ 的 tree` ⇒ 内容等价、可按快进处理。
> 按 sha 判会导致第二次推送就误报"分叉"。

### 九·补、🔴 不要拿 deb 字节跨构建对拍

#53 和 #54 的 deb 差了 286 B（98336 vs 98050），但 **#54 只改了 README**。
拆开比对过，两个二进制的差异是**固定的 68 个字节、三处**：

| 偏移 | 字节 | 落在哪 |
|---|---|---|
| 2728..2743（app 是 2968..2983） | 16 | `__TEXT` 段但**不在任何 section 里** ⇒ **LC_UUID** load command |
| `__LINKEDIT` 尾部 | 20 | 代码签名派生数据 |
| `__LINKEDIT` 尾部 | 32 | 代码签名派生数据 |

`__text` section 的实际偏移是 16384（不是 0），所以这三处**没有一处在代码里**；
`__cstring` / `__ustring`（所有文案）也一个字节没变。
两版的 `LC_UUID` 也直接读出来对过：`b7577589…` vs `51709bd3…`（dylib）。

⇒ 结论：**同一个 commit 两次构建，deb 字节必然不同**（LC_UUID + 代码签名 + tar 里的 mtime）。
所以"跨构建字节对拍"不成立；能对拍的是**同一次构建内**的 `zip 字节 == API size_in_bytes`。
想证明"代码没变"要靠 **tree / blob sha**，不能靠 deb 大小。

> 这一条也提醒了另一个坑：自己写的 Mach-O 解析器**字段偏移很容易写错**
> （`section_64` 的 `size` 是 8 字节、`offset` 在 +48，不是 +40/+44）。
> 写错时前半段的结论是反的 —— 会把"Load Commands 区"报成"`__text` section 内"，
> 于是看起来"代码变了"。判据错和实现错长得一模一样，所以解析器本身也要能自证。


### 十、真机验收清单

| # | 操作 | 期望 |
|---|---|---|
| 1 | 升级后**先打开盒子 App** | 旧名单被迁移成「每个 App 各一条」；设置页那行从「旧名单 N 个（尚未迁移）」变成「已分配 N 个」 |
| 2 | 设置页 → 按 App 分配提示音 | 列表里能看到刚才迁移进来的 App，副标题是它现在用的音 |
| 3 | 给微信单独选一个和默认不同的文件 | 微信响新音、其它 App 不变 |
| 4 | 把微信移除分配 | 微信回到系统原声，其它不受影响 |
| 5 | **没配默认音时**去添加 App | 弹「还没有默认提示音」，并告诉你回设置页怎么配（不会悄悄加一条没声音的） |
| 6 | 日志搜 `SOUNDMAP` | 能看到 `SOUNDMAP 迁移 N 个 App（…）⇒ 已写盘` / `SOUNDMAP 分配 +1 -0（现共 N 个 App）` |

### 十一、下一步候选

| 候选 | 用户多久撞上 | 工作量 | 说明 |
|---|---|---|---|
| **② 放着音乐时的行为** | 不一定 | 小（验证） | 换音的 B 通道和朗读都会动 `AVAudioSession`，同开时谁后设谁赢。极端情况可能让提示音按独占播、掐掉用户音乐。要的是**验证**，不是重写 |
| ③ 按 App 的音也配"时长" | 一周内 | 小 | 现在「最长播放秒数」是全局一份。真要精细就得进 entry（`{file, maxSec}`） |
| ④ 收尾 | — | 小 | 撤销轮换 PAT、归档临时脚本、清掉 `Local Settings\Temp` 里三个硬编码 token 的旧脚本 |


## v0.0.29 · 连续通知不叠加：同一个 App 的新音把旧音停掉

### 一、真问题（代码事实，不是猜的）

`NBLivePlayers()` 的上限是 **6**，而在攒到 6 个之前它是**只加不停**的：

```
群里连发 3 条 → 3 个 AVAudioPlayer 同时 play → 三个提示音叠在一起响成一团
```

更糟的是 v0.0.27 把默认「最长播放秒数」从 0 改成 **8 秒**，
这等于**把重叠窗口从"自然播完"拉长到了 8 秒** —— 上一版为了"别响太久"做的改动，
顺手把这个毛病放大了。

### 二、关键决策：停旧音，而不是"N 秒内只响一次"

| 方案 | 用户体感 | 结论 |
|---|---|---|
| 同一个 App 在 N 秒内只响一次 | 干净，但会**觉得漏了提醒**（尤其群消息） | 否 |
| **每条都响，但新音进来就把同 App 的旧音停掉** | 每条都提醒到了，声音不叠 | ✅ 本版 |

理由：**它不改变"该响几次"，只消除重叠**。用户配置提示音是想"知道来消息了"，
不是想"数响了几声"；去抖（debounce）会偷偷减掉提醒次数，那是另一种语义。

### 三、三条约束，每一条写反都有具体症状

| # | 约束 | 写反之后的症状 |
|---|---|---|
| ① | 停旧音必须排在 `[pl play]` **成功之后** | 一旦 `play` 失败，用户既听不到新的、旧的也被掐了 ⇒ **哑一下** |
| ② | 按 **owner 分桶**，不是全局只留一个音 | 微信来通知会掐掉 QQ 正在响的提示音（两件事被当成一件事） |
| ③ | owner **必须来自 bundleId** | 所有 App 共用一个 owner ⇒ 同样变成"一个 App 掐掉另一个 App" |

③ 是最容易图省事的一条：公开入口 `playSoundFileNamed:forResult:` 是给界面试听用的，
如果通知路径也调它（owner 写死 `@preview`），就正好踩中③。
所以内部拆出一个带 owner 的 `nbPlaySoundFile:forOwner:result:`，
**公开入口只做转调**（owner 传 `NB_SOUND_OWNER_PREVIEW = @"@preview"`，`@` 开头不可能撞上真实 bundleId）。

> ⚠️ 注意 `@preview` 的语义：**试听之间互斥**（连点两下试听不会两个音一起响），
> 但试听与通知**不互斥** —— 这是故意的，试听是用户主动的动作，不该把正在响的通知掐掉。

### 四、A 通道停不了，但这恰好不构成问题

`AudioServicesDisposeSystemSoundID` 会**连播放一起掐断并释放资源**（"停一次废一个 ID"），
所以 A 通道（v0.0.25 验证的那条）没有可用的 stop 能力。

但选路规则（v0.0.27）是「短音走 A、长音走 B」，而**只有长音的叠加才难听**
（0.5 秒的系统音叠三个也还是"叮"一声；30 秒的 mp3 叠起来才叫噪音）。
⇒ 去抖这个能力正好落在**唯一需要它的那条通道**上。这一条写进代码注释，免得下一版有人以为是漏了。

### 五、实现细节（都是踩过的坑）

- owner 用 `objc_setAssociatedObject` **挂在 player 上**，不另开字典 ⇒ player 释放时 owner 跟着走，
  不会出现"字典里留着已死 player"这种漏。
- 遍历**必须倒序**：一边删一边遍历，正着走会跳过元素（有的旧音停不掉）。
- 停完还要 `removeObjectAtIndex:` 摘出 `live`，否则数组里留着已停的 player，
  **上限 6 的兜底会先把别人挤掉**。
- 上限 6 保留作兜底：v0.0.29 之后同 owner 已互斥，只有"多个不同 App 同时刷"才会走到。
- 留痕只在**真的打断了**才打（`if (killed)`）：这条在刷屏时每条通知都会触发，
  无条件打会把 50 行日志窗口冲干净（v0.0.22 白跑一轮的同一个病）。

### 六、判据层（这一版的重心是"顺序"和"分桶"，都是静默出错的地方）

源码级 **17 条语义 + 17 条负向变异全过**（每次变异必须报红）：

| 组 | 判据 | 要害 |
|---|---|---|
| o01~o05 | `play` 之前不许有任何 stop · stop 排在 play 成功之后且排在挂 owner 之后 · 只停 owner 相同的 · owner 为空不打断 · 倒序遍历 | ①② |
| p01~p04 | 通知路径传的是 **bundle** 不是试听常量 · 公开入口只转调（函数体里没有第二份实现）· 试听常量不可能撞 bundleId · 内部入口签名带 owner | ③ |
| r01~r06 | A 通道不许出现 stop/Dispose · 上限 6 还在 · "本来就比上限短的不 stop"不变 · 选路两分支都传 owner · 到点收工从 live 移除 · 只有真打断才留痕 | 老铁律不被带坏 |
| v01~v02 | 0.0.29 三处齐 · 括号与 `@end` 配平 | — |

**反向对照**：把 v0.0.28 的源码喂进这 17 条 ⇒ **15 条变红**。
剩下两条是 `r01`（A 通道不许 stop，v0.0.28 本来就满足）和 `v02`（括号配平）——
这两条按设计就该绿，它们守的是"老铁律"和"语法"，不读本版新功能。

包级 **16/16**（从 deb 里掏出两个二进制验），反向对照（喂 v0.0.28 的 deb）**2/16**：

| 组 | 内容 | 反向（旧包）结果 |
|---|---|---|
| A1~A2 | control / 文件名是 0.0.29 | 红 |
| B1~B6 | 新选择器 `nbPlayViaAVPlayer:maxSec:owner:why:` · 内部入口 · `@preview` · `SOUND# 同 App 连发` · banner「+ 连发不叠加」 | 全红 |
| C1~C3 | **旧**选择器 `nbPlayViaAVPlayer:maxSec:why:` 消失 · 无 `v0.0.28` 残留 · 旧 banner 消失 | **全红**（说明这三条不是假绿） |
| D1~D5 | 盒子 App 也链了同一份 `NotifyFilter.m` ⇒ 那边同样得是新签名；v0.0.28 的界面串还在 | 只 D4/D5 绿（本来就该绿） |

> 🔴 C1 是这一版最硬的一条：**选择器签名是编译产物**。源码改了、包里没改，
> 只可能是"编的不是这次的东西"。而且它天然做了负向对照 —— 没有这条，
> 我只能证明"新东西在"，证明不了"旧的真的被换掉了"。
>
> 🔴 C1~C3 这类"旧串已消失"的反向判据有一个通用陷阱：**中文串在 Mach-O 里是 UTF-16LE**
> （`__ustring`），只搜 UTF-8 的话旧串本来就搜不到 ⇒ "已消失"恒成立 ⇒ **假绿**。
> 这一次是用"喂旧 deb 进去必须变红"实测确认了 `has_str` 两种编码都搜到了。

### 七、🔴 这一轮我自己的判据错（同类第二次）

`o04`（"owner 为空时不做打断"）第一版写的是：

```python
i = b.find("if (owner.length) {")
i_kill = b.find("@try { [old stop]; }")
if i_kill < 0 or i < i_kill:      # ← 方向写反了：i < i_kill 恰恰是"守卫在前"= 正确
    return "守卫不在停旧音之前"
```

**正判据假红**，而**负向自测抓不出来**（变异后仍然红 ⇒ 看上去"判据有效"）。
更隐蔽的是同一个函数体里有两处一模一样的 `@try { [old stop]; }`
（另一处在 `while (live.count >= 6)` 兜底里），所以"谁在前谁在后"这件事不仅容易写反方向，
还容易指错对象。

修法不是把 `<` 改成 `>`，而是**换成判语义**：取出 `if (owner.length)` 的**花括号作用域**，
在作用域内找 stop（外加"守卫里必须同时有 `removeObjectAtIndex`"）。
变异也从 1 条补到 3 条：守卫被去掉 / 停旧音被挪到守卫外 / 只 stop 不摘数组 —— 三条各打一句断言。

> 这是同一类错**第二次**（v0.0.28 的 `g02` 也是比较方向写反）。
> 共同点：判据在做"位置算术"，而位置算术有方向、有多个候选对象，错了还长得像"实现错了"。
> ⇒ 能改成**作用域/包含关系**的就不要做下标比较。

### 八、交付

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.29_iphoneos-arm64e.deb` · **98800 B** |
| CI | **#56**（`run_id 39937369852`，head `52218f4c11ba`）success |
| 产物 zip | 98989 B（与 API `size_in_bytes` 对拍一致） |
| 远端 | `52218f4c11ba` = 本地 `20be0ab47c9b`，**51 个文件逐 blob 一致** |

推送仍走 **REST API**（`github.com:443` 本机不通）。这次推送的验收脚本又踩了一次
**中文路径八进制转义**：`ls-tree` 默认 `core.quotepath=true`，同一个文件在远端叫
`docs/换提示音-….md`、在本地被读成 `"docs/\346\215\242…"` ⇒ 冒出一对"仅远端有/仅本地有"的**假红**。
`nb_verify_remote` 里早修过，`nb_push_api` 里漏了 —— 凡是列路径的 git 命令，两处都得带
`-c core.quotepath=false`。

> ⚠️ 交付基准是 **#56（纯代码构建）**。之后提 README 会再触发一次构建，
> 那个 deb 的代码与 #56 **逐字节相同的代码段**，但 deb 字节会不同（`LC_UUID` + 代码签名）。
> 别拿两次构建的 deb 大小当"代码变了"的证据（见 v0.0.28「九·补」）。

### 九、装了这一版要验什么

| # | 操作 | 期望 |
|---|---|---|
| 1 | 让同一个 App（比如微信）连发 2~3 条长提示音（配一个 ≥8 秒的 mp3） | **只听到一个在响**（后一条把前一条掐掉），不是叠成一团 |
| 2 | 让**两个不同** App 几乎同时来通知 | 两个音都能听到（不许被互相掐掉） |
| 3 | 短提示音（系统音，<1 秒）连发 | 行为与以前一样（A 通道不去抖），不闪退 |
| 4 | 在选音页连点两次试听 | 第二次把第一次停掉，不叠 |
| 5 | 日志搜 `SOUND#` | 真的打断过才会出现 `SOUND# 同 App 连发 ⇒ 停掉 N 个旧音` |

> 第 1 条如果**还是叠**：先看第 5 条的日志有没有出现。
> 有 ⇒ 打断跑了但没效果（说明停的不是那个 player）；没有 ⇒ 打断根本没跑到（看看是不是短音走了 A 通道）。

### 十、下一步候选

| 候选 | 用户多久撞上 | 工作量 | 说明 |
|---|---|---|---|
| ① **音频会话收尾** ✅ **v0.0.30 已做**（见下一章） | 一周内 | 小 | 现在 `setActive:YES` **没有配对 `setActive:NO`**（全项目只此一处）。别的 App 想放音时可能被压住。判据要写成"live 空了才交还"，不能每条通知都 `setActive:NO`（那样会把正在播的也停掉） |
| ② 按 App 的音也配"时长" | 一周内 | 小 | 现在「最长播放秒数」是全局一份 |
| ③ 放着音乐时的行为（验证） | 不一定 | 小 | v0.0.28 列过，一直没验 |
| ④ 收尾 | — | 小 | 撤销轮换 PAT、归档临时脚本、清掉 `Local Settings\Temp` 里三个硬编码 token 的旧脚本 |


## v0.0.30 · 音频会话交还：`setActive:YES` 之后要还回去

### 一、真问题（代码事实）

全项目 `setActive:YES` 有 **两处**，`setActive:NO` **一处都没有**：

| 处 | 类别 / 选项 | 谁会受影响 |
|---|---|---|
| `NotifyFilter.m` 换音 B 通道 | Ambient + MixWithOthers | 影响小（Ambient 是混音类别，本来就不打断别人），主要是状态残留 |
| `app/VoicePickerViewController.m` 语音试听 | Playback + **DuckOthers** | 影响大：DuckOthers 的语义就是「把别人正在放的音乐**压下去**」 |

会话激活后不交还，被压下去的音乐**能不能自己把音量拿回来**，是这类 App 的经典坑；
除此之外，「音频进行中」这个状态一直挂着，也可能干扰蓝牙路由 / AirPods 自动切换这些系统行为
（后半句属于推断，只能真机验，写在这里是为了别把它当成已证结论）。

### 二、做法：保守放行式交还

```
releaseAudioSessionIfIdle:
  ① B 通道 live 非空        ⇒ 不交还（提示音还在响）
  ② 朗读在播                ⇒ 不交还（交还就把那句掐断）
  两条都空 ⇒ setActive:NO with NotifyOthersOnDeactivation
```

**为什么要 `NotifyOthersOnDeactivation`**：不带这个选项只是"我方放开"，
被我们压低过的别人的音乐**不会自己恢复音量**。带上了才是真正的"交还"。
这一条是"交还"和"光放开"的分界，所以单独立了一条判据（a02）。

**为什么两个条件都要判**：只判 live 会把朗读掐断；只判朗读会在提示音还响着的时候交还。
两者都判才叫"保守"——**只要有任何可能在响，就不交还**。

### 三、四处调用点，以及每一处的顺序理由

| 位置 | 为什么在这里 |
|---|---|
| B 通道到点收工的 `dispatch_after` 末尾 | **必须排在 `[live removeObject:pl]` 之后**：反了的话此刻 live 里还留着自己，交还函数会以为"还有人在响" |
| 试听异常的 `@catch` | 异常路径最容易漏交还，而它恰恰是最可能留下脏状态的那条路 |
| `didFinishSpeechUtterance`（说完了） | 这是"说完了"这件事**唯一**的回调来源 |
| `didCancelSpeechUtterance`（被取消） | 连点试听会走这条路，见下 |
| `viewWillDisappear`（离开页面） | 用户试听完直接退出 App，回调可能来不及；这里幂等地再交还一次 |

### 四、🔴 两个"只能这么写"的地方

**(1) 问朗读必须走反射 + 分类声明**

`NotifySpeaker.m` **只编进 SpringBoard，没有编进盒子 App**（`Makefile` 的 `NotifyBoxApp_FILES` 里没有它）。
而 `NotifyFilter.m` 是**两边都编**的 ⇒ 直接 `[NotifySpeaker isSpeakingNow]` 在 App 上会在
**链接期** undefined symbol：编译期完全看不出来，装到手机上才炸。

所以是三步：

```objc
@interface NSObject (NBSpeakerProbe)     // ① 告诉 clang"类上可能有这个方法"
+ (BOOL)isSpeakingNow;
@end
...
Class spk = NSClassFromString(@"NotifySpeaker");                   // ② 先问"这个进程里有没有"
if (spk && [spk respondsToSelector:@selector(isSpeakingNow)]) {     // ③ 运行期兜底
    if ([spk isSpeakingNow]) return;
}
```

> 🔴 **不能**写成 `@protocol NBSpeakerProbe` + `[(id<NBSpeakerProbe>)spk isSpeakingNow]`：
> 给 `id<协议>` 发消息时 clang 只查协议里的**实例方法**，而 `isSpeakingNow` 是**类方法**
> ⇒ `no known instance method for selector` ⇒ `-Werror` 直接挂。
> 这个项目没有 Mac、编译只在 CI 上跑，所以这种"编译期才暴露"的写法必须**提前**想清楚。
> 判据 a04 现在会主动抓这个形状（用 `id<…>` 给类发类方法 ⇒ 报红）。

**(2) 取消回调用显式标志位，不靠 `speaking` 猜时序**

`stopSpeakingAtBoundary:` 触发的 `didCancelSpeechUtterance:` 是**异步投递**的。
"连点两次试听"的时序是：

```
第 1 次：speak(A)
第 2 次：setActive:YES → stopSpeaking(清掉 A) → speak(B)
         ↑ didCancel(A) 的回调要到这时之后才被投递
```

回调里如果看 `preview.speaking` 判断"是不是还有新的在说"，就依赖
「回调一定晚于 speakUtterance 生效」这个**时序推断**——推断一旦不成立，
就会把**正在说的那句**掐断。所以用一个显式标志位：

```objc
self.previewStoppedForNew = YES;    // 先打标记，再做 stop
[self.preview stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
...
- (void)speechSynthesizer:didCancelSpeechUtterance: {
    if (self.previewStoppedForNew) { self.previewStoppedForNew = NO; return; }  // 有新的接上，不交还
    [NotifyFilter releaseAudioSessionIfIdle];
}
```

不依赖任何时序，只依赖"我自己打的标记"。

### 五、判据（12 条语义 + 12 条负向变异）

| 组 | 判据 | 要害 |
|---|---|---|
| a01 | 扫**全仓库**：含 `setActive:YES` 的文件必须有交还路径；**实现方自己**必须含 `setActive:NO` | 防止将来新增一处裸激活；也防止"只把激活点藏进函数" |
| a02 | 交还带 `NotifyOthersOnDeactivation` | 不带 ⇒ 被压低的音乐不恢复 |
| a03 | 先问朗读，再 `setActive:NO` | 顺序反了 = 无条件交还 |
| a04 | 反射三件套（`NSClassFromString` + `respondsToSelector` + 分类声明），且**不许** `id<协议>` 给类发类方法 | 链接期 / 编译期两个雷 |
| a05 | `live` 非空就 return，且守卫在 `setActive:NO` 之前 | 否则掐短正在响的音 |
| a06 | 交还排在 `[live removeObject:pl]` **之后** | 顺序反了白调一次，且放松一点就掐音 |
| a07 | 播放函数里不许出现 `setActive:NO` | 播一半交还 = 断在半截 |
| a08 | `isSpeakingNow` 是纯读（不许 stop / speak / setActive） | 探针有副作用，交还时机永远查不清 |
| b01 | App 侧：delegate 协议 + `preview.delegate = self` + 说完 + 取消 + 标志位 + 离开页面，且交还点 ≥ 4 处 | 少任何一处就是"不交还" |
| b02 | 取消回调必须看标志位 | 否则连点试听会掐断新那句 |
| v01~v02 | 版本 0.0.30 三处齐 · 改过的文件括号与 `@end` 配平 | — |

**反向对照**：喂 v0.0.29 的源码 ⇒ **10 条变红**，剩下 `a07`（v0.0.29 本来就没有裸交还）
和 `v02`（括号配平）—— 这两条按设计就该绿。

> 顺手修了一处判据自身的老毛病：v0.0.29 的 `v02` 只统计
> `@interface + @implementation` 与 `@end` 的配平，**漏了 `@protocol`**。
> 这一版一度真的加了 `@protocol`（后来改成分类），当时那条判据就会**假红**。
> 现在 `@protocol` 也算进去了。
>
> 另外这一轮负向自测抓到一个**老坑的新面向**：变异锚点撞在**注释**上。
> - `a04` 的锚点 `NSClassFromString(@"NotifySpeaker")` —— 我为了让人看懂，在文件顶部的
>   说明性注释里把这段代码**抄了一遍** ⇒ `replace(…,1)` 先命中注释 ⇒ 注释被 strip ⇒ 变异白做。
> - `v02` 的变异把 `{` 加在了**注释行尾** ⇒ 括号统计根本读不到。
>
> 教训：**注释里抄代码会给变异埋雷**。锚点要么带缩进取整行代码，要么就别在注释里抄代码原样。

### 六、包级判据（14 条）+ 反向对照

| 组 | 判据 | 为什么这条必须存在 |
|---|---|---|
| A1~A2 | control / 文件名是 0.0.30 | — |
| B1 | tweak 有 `v0.0.30` | — |
| B2~B3 | `releaseAudioSessionIfIdle` / `isSpeakingNow` 两个**选择器**在包里 | 名字进不了包 = 调用点被优化掉 / 根本没参与编译 |
| B4 | 字面量 `NotifySpeaker` 在包里 | 不在 ⇒ 反射永远拿 nil ⇒ **永不防掐朗读**（而源码看着完全正常） |
| B5 | `nbPlaySoundFile:forOwner:result:` 还在 | 回归：v0.0.29 的入口没被这一版带坏 |
| B6~B9 | App 侧：`releaseAudioSessionIfIdle` / `didFinishSpeechUtterance` / `didCancelSpeechUtterance` / `setPreviewStoppedForNew:` | 任何一个不在 = delegate 没挂上 / 标志位没编进去，都是"看着有代码、实际不交还" |
| C1 | tweak 里没有 `v0.0.29` 残留 | 反向：版本串真的升上来了 |
| D1~D2 | `@preview` / `SoundAppsViewController` 还在 | 回归：前两版的功能没被带坏 |

**反向对照**（喂 v0.0.29 的 deb）：**4/14 通过** —— 活下来的正好是 B4 / B5 / D1 / D2
（这四条在 v0.0.29 里本来就有），其余 **10 条全红**。

### 七、交付

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.30_iphoneos-arm64e.deb` · **99434 B** |
| CI | **#58**（`run_id 40071814036`，head `518b1efab0e7`）success |
| 产物 zip | 99627 B（与 API `size_in_bytes` 对拍一致） |
| 远端 | `518b1efab0e7` = 本地 `d91db9ceb504`，**51 个文件逐 blob 一致** |

> ✅ 这次 CI 编译一次过。但它**本来是有两个必挂点**的，都在提交前自查掉了：
> ① `[(id<NBSpeakerProbe>)spk isSpeakingNow]`（protocol 里是类方法，给 `id<Proto>` 发消息
> clang 只查实例方法 ⇒ `-Werror` 挂）；② 直接 `[NotifySpeaker isSpeakingNow]`
> （App 目标没链 NotifySpeaker.m ⇒ 链接期 undefined symbol，编译期看不出来）。
> 没有 Mac、只能靠 CI 编译的项目，"编译期才暴露的写法"必须在写的时候就想清楚 —— 这一条比省事重要。

### 八、装了这一版要验什么（这版判据只能说"写了"，结论得靠耳朵）

| # | 操作 | 期望 |
|---|---|---|
| 1 | 放一首歌 → 盒子 App 里试听几条语音（语速、声音）→ 退出 App | 歌的音量**回到原样**，没有一直偏低 |
| 2 | 放歌的同时收一条**长**提示音（≥8 秒 mp3） | 提示音期间歌被压低，提示音结束后**音量自己回来** |
| 3 | 开着朗读 + 换提示音，让一条通知同时触发两者 | 朗读**不被打断**（这是 a03 那道闸门在真机上唯一能被验证的地方） |
| 4 | 在语音页连点两次试听 | 第二次能正常出声（不许"点了没声音"—— 那是交还掐断了新那句） |
| 5 | 回归：连发、按 App 各自一个音、连发不叠加 | 与 v0.0.29 一致 |

> 第 3 条如果**朗读被打断**：说明闸门没起作用（反射拿到 nil）。这时先确认日志里两次通知是同一进程
> （`proc=` 一致），再怀疑 `NSClassFromString` 那条。

### 九、下一步候选

| 候选 | 用户多久撞上 | 工作量 | 说明 |
|---|---|---|---|
| ① **按 App 配时长** | 一周内 | 中 | 现在「最长播放秒数」是全局一份。要进 entry（`{file, maxSec}`）就得再动一次存储格式 + 迁移 |
| ② 换音 B 通道也压别人（可选） | 不一定 | 小 | 现在 Ambient 完全混音。若用户希望"来通知时音乐小一点"，可以给个开关切到 DuckOthers —— 但那会引入更多会话状态，**先有需求再做** |
| ③ 试听削尾（已知精度限制） | 低 | 小 | `didFinish` 之后缓冲尾韵可能被交还削掉几十毫秒。要治就得延迟交还，而"固定延迟"在本项目里是禁忌（见铁律），得先有真机听感证据 |
| ④ 收尾 | — | 小 | 撤销轮换 PAT、归档临时脚本、清掉 `Local Settings\Temp` 里三个硬编码 token 的旧脚本 |

### 十、🔴 真机结果：五条全过（2026-10-24）

| # | 验的是什么 | 结果 |
|---|---|---|
| 1 | 试听语音后退出 App，音乐音量回原样 | ✅ |
| 2 | 放歌 + 长提示音，结束后音量自己回来 | ✅ |
| 3 | 朗读 + 换音同时触发，朗读不被打断 | ✅ |
| 4 | 语音页连点两次试听，第二次仍有声 | ✅ |
| 5 | 回归：连发不叠加 / 按 App 各自一个音 | ✅ |

**第 3 条怎么验的（方法可复用）**：`didCancel` 那条闸门失效时的症状是"朗读读到一半没了"，
而在正常语速下那只有零点几秒，很容易被忽略、也容易被误听成"本来就这么短"。
做法是把**语速调到最慢（0.4）**再去构造"朗读 + 长提示音同时触发" ——
语速慢的时候，被掐断会非常刺耳（句子读到一半突然消失），一眼就能分辨。
验完把语速调回原来的档。

> ⚠️ 诚实记一笔：这一版的"交还到底跑没跑"**没有日志能自证** ——
> `releaseAudioSessionIfIdle` 里一条日志都没打（当初为了不冲掉 50 行窗口故意留空），
> SpringBoard 侧的朗读也没有 delegate（只有 `SPEAK 已提交`，没有"读完了"）。
> 所以这条结论**只能靠听**，靠不了日志。
> 如果以后有人反馈「朗读偶尔断」，第一件事是给这两处补日志，设计是：
> 「因朗读在播而跳过交还」**每次都打**（低声且正是命门），「真的交还成功」按每 20 次打一条
> —— 两个都要有，否则"没看到跳过"和"根本没跑"分不开。

---

## v0.0.31 · 按 App 配时长：`entry` 加可选 `maxSec`

### 一、这一版解决什么

到 v0.0.30 为止，「最长播放秒数」是**全局一份**（`settings.plist` 的 `soundMaxSec`）。
于是同一份 `a.mp3`，微信想让它响 30 秒、QQ 只要 8 秒，做不到 —— 只能二选一。

这一版把时长搬进每条 entry：

```
SOUNDMAP = {
  "com.tencent.xin"   : { "file": "a.mp3", "maxSec": 30 },   // 这个 App 30 秒
  "com.tencent.mqq"   : { "file": "a.mp3" },                 // 没这个键 ⇒ 跟随全局
  "com.apple.MobileSMS": { "id": 1007, "maxSec": 0 },        // 0 = 不限
}
```

改动面看着很小，但**风险全在边界语义**上，而且这三种错的症状都很安静（界面上看不出来）。

### 二、三条语义

| # | 语义 | 写错的症状 |
|---|---|---|
| 1 | **键不存在 = 跟随全局** | 写成「没键也给个 0」⇒ 所有 App 同时变成**不限时长**，长音响到底 |
| 2 | **0 是合法值 = 不限** | 用 `if (!n)` 或 `n <= 0` 判非法 ⇒ 用户选的"不限"被改成跟随全局 |
| 3 | **非法值 ⇒ 跟随全局（`return NO`），不夹取** | 夹成 8 秒 ⇒ 用户填 9999 得到 8，静默改语义 |

第 3 条和全局那边**故意不一致**：`NBSoundMaxSecFromValue` 是**夹取**（`n > CEIL` 就 `n = CEIL`），
因为它没有父级可退化 —— 夹到上限是它唯一合理的兜底。而 entry 有父级（全局值），
所以正确退化是「跟随全局」而不是"夹到某个值"。

> 第 1 条的好处是**老 entry 天然兼容，不需要迁移**：v0.0.28~v0.0.30 写下的
> `{file}` / `{id}` 原样就能用。代价就是上面那个"顺手给个 0"的坑。

### 三、🔴 0 是合法值 ⇒ `cap` 的哨兵必须是负数

`nbPlaySoundFile:forOwner:cap:result:` 的 `cap` 要能表达「调用方没指定」。
如果用 `0` 当这个哨兵，它就和语义 2 撞死了：**「不限」和「没指定」分不开**。

```objc
// cap < 0 = 调用方没指定 ⇒ 用全局；否则用调用方给的（含 0 = 不限）
NSTimeInterval useCap = (cap < 0) ? [self nbSoundMaxSec] : (NSTimeInterval)cap;
```

兜底**写在这一处**，不写在各个调用点 —— 否则"哪些调用点兜了、哪些没兜"会散在几个文件里。
试听入口（`playSoundFileNamed:forResult:`）就传 `-1`，选音页试播传这个 App 自己的 `cap`。

### 四、🔴 非法值只剔键、不丢整条 entry（而且在净化层剔）

```objc
// NBSanitizedSoundMap 里
if (((NSDictionary *)v)[NB_KEY_SOUND_ENTRY_MAXSEC] != nil) {
    double probe = 0;
    if (!NBMaxSecFromEntry(v, &probe)) {
        NSMutableDictionary *vv = [NSMutableDictionary dictionaryWithDictionary:v];
        [vv removeObjectForKey:NB_KEY_SOUND_ENTRY_MAXSEC];    // 只剔这个键
        v = vv;                                              // ← 绝不能 continue
    }
}
```

两个"为什么"：

- **为什么不丢整条**：丢整条 ⇒ 用户会觉得「我这个 App 的提示音突然没了」；
  剔键 ⇒ 只是「时长回到跟随全局」，音还在。退化方向要选伤害小的那个。
- **为什么必须在净化层剔**：判定之后会用这个值去选通道，一个乱填的 `1e9` 会变成
  `dispatch_after(1e9 秒)` ⇒ player 永不释放 ⇒ `live` 攒满 6 ⇒ **后面的音全被挤掉**
  （真机症状是"响几声之后就不响了"，和时长设置看着毫无关系）。

解析用 `NSScanner` + `isAtEnd` 严格来：`[@"abc" doubleValue]` 是 `0`，
`scanDouble` 读 "abc" 也停在 0 并返回成功 ⇒ 没有 `isAtEnd` 的话，`"abc"` 会被当成 **0 = 不限**。

### 五、🔴 写 entry 必须做差（否则通知会变哑）

`commitFile:` / `commitSID:` 原来是**整条替换**：

```objc
NSDictionary *entry = @{ NB_KEY_SOUND_ENTRY_ID: @(sid) };   // 旧写法
```

加了第三个键之后，这个写法有两个新伤：

- 改**音** ⇒ 把时长悄悄清掉（回到跟随全局）
- 改**时长** ⇒ 把音悄悄清掉 ⇒ 变成只带 `maxSec` 的**空壳 entry**
  ⇒ 净化层（要求 `file` / `id` 至少有一个）会把它整条丢掉
  ⇒ 而判定以为"有分配"，然后拿空音去播 ⇒ **通知变哑**

两种都在界面上完全看不出来（值都在，只是少了另一个）。所以现在三条写路径
（`entryBySettingFile:` / `entryBySettingSID:` / `commitMaxSec:`）**全部以 `self.entry` 为基底、只改目标键**。
这和 v0.0.28 在 `persistSoundMap` 上踩过的坑是同一个（那次叫「做差，而不是清空重建」）。

`commitMaxSec:` 还多一道守卫：**这个 App 还没音时不许设时长** —— 否则写出来的就是上面那个空壳，
它会随时在下次净化时被清掉，用户则以为"我明明设了 30 秒"。

### 六、界面：固定档位，不让人手填数字

选音页 per-App 从 4 节变 5 节，最后加一节「最长播放秒数」，
点开是 actionSheet：**跟随全局 / 5 秒 / 8 秒 / 15 秒 / 30 秒 / 不限时长**。

不放手填的原因很直接：手填 `abc` 会被读成 0 = **不限**（"写错一个字母 ⇒ 长音响到底"，
而界面上看不出来）。固定档位没有这个风险；真要 3 秒这种值，改 `settings.plist` 也能生效。

总览页（App 列表）的副标题也带上时长，但**等于"跟随全局"时不显示** ——
否则每个 App 后面都挂一句"跟随全局"，等于没说。这一行的意义是让
「同一份 a.mp3，微信 30 秒、QQ 8 秒」在总览页一眼看得出来。

### 七、判据：16 条语义 + 16 条负向变异

| 组 | 判据 | 要害 |
|---|---|---|
| c01 | 四参判定里先填全局值兜底，再在「读到了」的前提下覆盖 | 无条件覆盖 = 没设的 App 变成"不限" |
| c02 | 不许 `n <= 0` / `if (!n)` | 0（= 不限）被当非法值 |
| c03 | `NSScanner` + `isAtEnd` | `"abc"` → 0 → 长音响到底 |
| c04 | 非法走 `return NO`，且不许出现 `n = CEIL`（夹取） | 静默改语义 |
| c05 | 净化层剔键，且**整个 maxSec 处理块内**不许 `continue` | 丢整条 = 音也没了 |
| d01 | 三参 / 两参判定都转调四参（`maxSec:NULL`） | 口径变两份，迟早走岔 |
| d02 | 通知路径的 `cap` 只能来自判定，不许自己再读全局 | 界面说 30 秒停、实际 8 秒停 |
| d03 | `cap` 的"没指定"用**负数**哨兵 | 0 语义坑的第二个入口 |
| e01 | `commitFile:` / `commitSID:` 不许整条替换 entry | 空壳 ⇒ 通知变哑 |
| e02 | 两个 `entryBySetting*` 都以 `self.entry` 为基底 | 会把其它键抹掉 |
| e03 | 没音时不许设时长 | 写出留不住的设置 |
| f01 | per-App 的「会怎么播」按这个 App 的时长算 | 界面与行为走岔，用户照着这行判断 |
| f02 | 总览页副标题带时长 | 看不出"单独设过" ⇒ 以为没生效 |
| f03 | 四个新内部方法都有显式声明 | CI 是 `-Werror` |
| v01~v02 | 版本 0.0.31 三处齐 · 括号与 `@end` 配平 | — |

**反向对照**（喂 v0.0.30 的源码）：**15/16 变红**，唯一存活的是 `v02`（配平）——
v0.0.30 本来就配平，这条按设计就该绿。

### 八、包级判据（22 条）+ 反向对照

| 组 | 判据 | 为什么必须存在 |
|---|---|---|
| A1~A2 | control / 文件名是 0.0.31 | — |
| B1 | tweak 有 `v0.0.31` | — |
| B2 / B6 | 两侧都有键名 `maxSec`（**弱**，见下） | 键名被改掉时能抓到 |
| B3 | 四参判定选择器 `soundVerdictForBundle:soundID:soundFile:maxSec:` | 不在 ⇒ 还是三参口径 ⇒ `cap` 出不来 |
| B4 | 四参播放入口 `nbPlaySoundFile:forOwner:cap:result:` | 不在 ⇒ 还是旧签名 |
| B5 | `playbackPlanForFileNamed:forBundle:` | 界面文案按 App 算的那条在 |
| B7~B11 | App 侧 `commitMaxSec:` / `entryBySettingFile:` / `entryBySettingSID:` / `pickMaxSec` / `soundEntryLimitSummary:` | 任何一个不在 = 界面没接上 |
| C1 | tweak 里没有 `v0.0.30` 残留 | 反向：版本串真的升上来了 |
| C2 | 没有旧三参**播放**签名 | 它还在 = 有调用点漏改，那个点永远用全局时长 |
| D1~D7 | `releaseAudioSessionIfIdle` / `isSpeakingNow` / `NotifySpeaker` / `@preview` / 兼容三参判定 / `SoundAppsViewController` | 回归：前三版的功能没被带坏 |

**反向对照**（喂 v0.0.30 的 deb）：**9/22 通过**，13 条变红。
存活的 9 条全部是**预期存活**：`B2`/`B6` 是弱判据（见下），`D1~D7` 是回归保留项。

> `B2`/`B6` 标成"弱"是有原因的：全局那个键叫 `soundMaxSec`，**本身就含 `maxSec` 子串**，
> 所以「二进制里有 maxSec」在 v0.0.28 就成立了。它只能证「键名没被改成别的东西」，
> 证不了「entry 级时长编进去了」—— 后者靠 B3/B4/B7~B11。
> 这类"必要条件"判据留着有用，但**不能当强证据报**。

### 九、🔴 这一轮判据自己犯的两个错

**（1）负向自测抓到 3 条失效**（判据形同虚设，正判据却全绿 —— 这正是负向自测的意义）：

- `c05`：判据写的是"含 `maxSec` 的**那一行**里不许有 `continue`"，
  而变异把 `continue` 放在了**下一行** ⇒ 漏判。改成看**整个 maxSec 处理块**（`braced_block` 配对）。
- `e02`：变异锚点带了行尾注释，注释缩进和实际不符 ⇒ 锚点找不到（变异没做，等于没测）。
  改成「基底那行 + 紧接着的 `removeObjectForKey` 行」两行组合，且**不带注释**。

**（2）包级判据有一条前提就是错的**：

原来写了「C3 旧三参判定签名必须消失」。实际一跑就红 —— 因为这一版**故意保留**了
三参/两参判定入口（它们转调四参，见 `d01`），它们的 selector 必然在包里。

> ⇒ 教训：**判据域必须等于变异域**。「旧签名消失」只在"旧签名真的被删掉"时成立，
> 而这一版做的是"旧签名保留 + 转调"，两者不是一回事。这条判据已删，
> 改成 D7「兼容三参入口仍在」（回归），"有没有转调"只能靠源码判据。
>
> 顺带一个技术点：查"某个**选择器**在不在"必须精确到 `\0`（`__objc_methname` 里是 C 字符串），
> 因为四参名 `…soundFile:maxSec:` 的**前缀**就是三参名 `…soundFile:` ——
> 子串搜索会把"新签名在"误判成"旧签名还在"。`C2` 用的是 `\0` 精确匹配；
> 而 `C1` 查的是版本串（它埋在 `NotifyBox v0.0.30 · BBServer` 里，不是独立串尾），
> 必须用子串 —— 两种口径不能混。

### 十、交付

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.31_iphoneos-arm64e.deb` · **101784 B** |
| CI | **#61**（`run_id 40075967315`，head `d3034e5584b5`）success，一次编译过 |
| 产物 zip | 101971 B（与 API `size_in_bytes` 对拍一致） |
| 远端 | `d3034e5584b5` = 本地 `29de05ba410d`，**51 个文件逐 blob 一致** |
| 结构 | 35 个文件 0 问题 |
| 改动 | 8 文件 **+307 / −31** |
| 二进制 | tweak `143728 B` · App `333120 B` |

### 十一、装了这一版要验什么

| # | 操作 | 期望 |
|---|---|---|
| 1 | 给微信配 `a.mp3`，把它的时长设成 **30 秒**；QQ 用同一份 `a.mp3`，保持「跟随全局」（8 秒） | 微信响 30 秒、QQ 响 8 秒；**同一份文件、两个 App 不同时长**（这是这一版存在的全部理由） |
| 2 | 总览页看这两个 App | 微信那行后面有「30 秒后停」，QQ 那行**没有**后缀（跟随全局时不显示） |
| 3 | 给微信设成「不限时长」，放一条长音 | 收到就响到底，不会被 8 秒掐掉 |
| 4 | 微信设 30 秒后，**改它的音**（换成别的文件） | 时长**还在**（仍是 30 秒）—— 做差没坏 |
| 5 | 微信设 30 秒后，**再改时长**（改成 5 秒） | 音**还是原来的**（不是"没声了"）—— 没写空壳 |
| 6 | 一个**还没配音**的 App，直接点「最长播放秒数」 | 提示「先给这个 App 选一个音，再设时长」，不写盘 |
| 7 | 回归：连发不叠加 / 按 App 各自一个音 / 试听退出后音乐音量复原 | 与 v0.0.30 一致 |

> 第 4、5 条是这一版最容易坏的地方（也是"界面看不出来"的地方）：
> 只看"有没有声"不够，要确认**另一个键没被清掉**。第 5 条如果变成没声，就是空壳 entry 的老问题又回来了。

### 十二、下一步候选

| 候选 | 用户多久撞上 | 工作量 | 说明 |
|---|---|---|---|
| ① 换音 B 通道也压别人（可选） | 不一定 | 小 | 现在 Ambient 完全混音。要给个开关切 `DuckOthers` 才有"来通知时音乐小一点"—— 但会引入更多会话状态，**先有需求再做** |
| ② 试听削尾 | 低 | 小 | `didFinish` 之后缓冲尾韵可能被交还削掉几十毫秒。要治就得延迟交还，而"固定延迟"在本项目里是禁忌，得先有真机听感证据 |
| ③ 时长跟"音的长度"联动 | 低 | 小 | 现在 cap 是"最长播放秒数"，短音本来就播完即止。可以先不碰 |
| ④ 收尾 | — | 小 | 归档临时脚本、清掉 `Local Settings\Temp` 里三个硬编码 token 的旧脚本；**PAT 留到最后一版交付完再撤** |

---

## v0.0.32 · 「来通知时压低别人音乐」做成开关（DuckOthers）

### 一、这一版解决什么

v0.0.27 起 B 通道一直是 `Ambient + MixWithOthers`：提示音和音乐**叠着播、谁也不压谁**。
所以听歌时来一条长提示音，两者糊在一起。

想要"来通知时音乐小一点"就得加 `AVAudioSessionCategoryOptionDuckOthers`。
但它**不该是默认值**：短提示音被压 1 秒又弹回来，听感上像打了个嗝，
不少人反而觉得比混音更难听。所以做成开关，**缺省关**。

### 二、关键取舍：只加"多压一层"，绝不改"能不能共存"

| 开关 | options |
|---|---|
| 关（缺省） | `MixWithOthers` |
| 开 | `MixWithOthers` + `DuckOthers` |

不是"开就只给 `DuckOthers`"。理由很直接：`Ambient + MixWithOthers` 是 v0.0.27 起
**上线验收过**的行为（与音乐共存、不打断），只给 `DuckOthers` 有可能把"共存"这条一起改掉 ——
而那不是这个开关要卖的东西。**一个开关只改一件事**，否则出问题时分不清是哪半改坏的。

### 三、三条边界（每一条都是"看着能用、其实不生效"）

**① 只对 B 通道（`AVAudioPlayer`）有效。**
A 通道走 `AudioServicesPlaySystemSound`，它自己不管 `AVAudioSession` ⇒ 短音永远压不住别人。
所以界面文案必须写「**只对长提示音有效**」。不写这句，用户配了个 1 秒的短音、打开开关、
发现音乐根本没变，只会认定"开关坏了"—— 而代码完全正常。这条有判据盯着（`s03`）。

**② 压低的恢复依赖 v0.0.30 的交还。**
被压低的是**别人**的 session，只有我们 `setActive:NO` 时带
`AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation`，它才会自己把音量抬回去。
这条要是被谁删了，症状是"听过一条通知之后音乐一直闷着，直到手动调音量或切歌"——
和这一版的改动**毫无关系**，最难查 ⇒ 所以它进判据（`a06`）。

**③ 每次播放都重新读设置。**
`NBLoadSettings()` 是最朴素的 plist 读取、没有缓存，故意如此：改完开关，**下一条通知就生效**，
不用重启、不用重进 App。开销 = 一条通知多读一次几 KB 的 plist，和"通知到达时本来就要读的那次"同量级。

### 四、设置页那个坑：`onSave:` 的开关数组是**手写**的

```objc
for (NSString *k in @[NB_KEY_SPEAK_ENABLED, NB_KEY_DND_ENABLED, NB_KEY_SOUND_ENABLED,
                      NB_KEY_SOUND_DUCK_OTHERS]) {
    UISwitch *sw = self.switches[k];
    d[k] = @(sw ? sw.isOn : NO);
}
```

新开关忘了加进这个数组 ⇒ **状态永远不落盘**：点开 → 保存 → 再进来又变回关，
而保存时**没有任何报错**，盘上压根没这个键。这是 v0.0.21 踩过的原样坑（那次是三个开关共用一个属性）。

这次提前堵上了：判据 `s02` 专门盯这个数组，并**顺带检查老开关没从数组里掉出去**
（掉出去 = 一保存就把别人的设置改回关）。

### 五、判据：11 条语义 + 11 条负向变异

| 组 | 判据 | 要害 |
|---|---|---|
| a01 | `options` 初值只能是 `MixWithOthers`，不许带 DuckOthers | 无条件压低 = 开关关着也照压，把已验收的"共存"赌进去 |
| a02 | `DuckOthers` 只出现一次、是**位或赋值**、且被 `if (…NB_KEY_SOUND_DUCK_OTHERS…)` 包住 | 出现两次 = 有一处无条件；直接赋值 = 覆盖掉 MixWithOthers |
| a03 | 开关必须走 `NBBoolValue` | 手改 plist 写成 `"1"`/`"true"` 时，App 与 tweak 各认一套 ⇒ "开着不生效" |
| a04 | `setCategory:withOptions:` 必须传变量 `opt` | 还传硬编码常量 ⇒ 开关是死代码（改什么都不变） |
| a05 | A 通道（`nbPlayViaAudioServices:`）里不许出现 `AVAudioSession` / `setCategory` / `setActive` | 该通道本来零 session 副作用，加这些既不生效又把已验证的性质弄脏 |
| a06 | 全文件必须有 `NotifyOthersOnDeactivation` | 没有它，压低之后音乐永远闷着 |
| s01 | 开关接到 `cur[NB_KEY_SOUND_DUCK_OTHERS]` | 接错键 = 每次进来都显示关 |
| s02 | `onSave` 的开关数组含新键 **且** 老键还在 | 见上一节 |
| s03 | 文案里有「长提示音」 | 见边界 ① |
| v01~v02 | 版本 0.0.32 三处齐 · 括号与 `@end` 配平 | — |

**反向对照**（喂 v0.0.31 的源码）：**8/11 变红**。存活的 3 条按设计就该绿：
`a05`（v0.0.31 的 A 通道本来就干净）、`a06`（交还本来就在）、`v02`（配平）。

### 六、包级判据（14 条）：一条天生局限 + 一个"大小没变"的坑

**局限先说清**：`AVAudioSessionCategoryOptionDuckOthers` 是 **C 枚举常量**，编译期就内联成数字，
**不会作为字符串出现在 Mach-O 里** ⇒ 「选项到底设上了没有」包级**验不了**，
只能靠源码判据（a01/a02/a04）和真机。

包级这一层能验、而且真有价值的是键名：

| 组 | 判据 | 为什么必须存在 |
|---|---|---|
| A1~A2 | control / 文件名是 0.0.32 | — |
| B1 | tweak 有 `v0.0.32` | — |
| B2 | tweak 有 `soundDuckOthers` | 没有 ⇒ 那个 `if` 被编译器当常量折掉了（或键名写错）⇒ **开关永远无效，而界面一切正常** |
| B3 | App 有 `soundDuckOthers` | 没有 ⇒ 设置页那一行没接上 |
| B4 | App 有中文标题（`__ustring`，UTF-16LE） | 证明那一行真的在 |
| C1 | 没有 `v0.0.31` 残留 | 反向：版本串真的升上来了 |
| D1~D7 | `maxSec` / 四参判定 / `releaseAudioSessionIfIdle` / `@preview` / `commitMaxSec:` / `SoundAppsViewController` / `addSwitchRow` | 回归：前三版没被带坏 |

**反向对照**（喂 v0.0.31 的 deb）：**7/14 通过**，7 条变红，存活的正好是 `D1~D7` 回归项。

> 🔴 **"文件大小一字不差"不等于"没编进去"。**
> 这一版 tweak 仍是 `143728 B`、App 仍是 `333120 B`，与 v0.0.31 **完全相同**，
> 但两个二进制的 md5 都变了（`c718318dfa20 → 3c4aee24246d`、`f765845cd48e → 3ba6e8522239`）。
> 原因：Mach-O 的段/section 按固定对齐填充，几十字节的改动落在同一段内 ⇒ 文件大小不变。
> 这和 v0.0.28 记的"段内缩小 ≠ 文件缩小"是同一件事的两面：
> **判"有没有编进去"要看内容（串 / 选择器 / md5），不要看文件大小。**

### 七、交付

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.32_iphoneos-arm64e.deb` · **101900 B** |
| CI | **#63**（`run_id 40077600971`，head `81dc52c1ebab`）success，一次编译过 |
| 产物 zip | 102088 B（与 API `size_in_bytes` 对拍一致） |
| 远端 | `81dc52c1ebab` = 本地 `95d32360ff28`，**51 个文件逐 blob 一致** |
| 结构 | 35 个文件 0 问题 |
| 改动 | 6 文件 **+49 / −9** |
| 二进制 | tweak `143728 B`（md5 变）· App `333120 B`（md5 变） |

### 八、装了这一版要验什么

| # | 操作 | 期望 |
|---|---|---|
| 1 | 放一首歌；配一条**长**提示音（≥8 秒 mp3，走 B 通道）；开关**关** | 提示音和音乐叠着播，**音乐音量不变**（= v0.0.27 的老行为，回归） |
| 2 | 同一场景，开关**开** | 提示音响的时候音乐**明显变小** |
| 3 | 紧接着第 2 条：提示音结束后 | 音乐音量**自己回到原样**（不是一直闷着）—— 这条才是最容易坏的 |
| 4 | 开关开的状态下，换成一条**短**音（1 秒左右） | 音乐**听不出变化**（A 通道不受控）。这是**预期**，不是 bug —— 对应文案里那句「只对长提示音有效」 |
| 5 | 打开开关 → 保存 → 关掉设置页 → 再进来 | 开关**仍然是开的**（落盘没漏） |
| 6 | 回归：按 App 各自一个音 / 按 App 配时长 / 连发不叠加 | 与 v0.0.31 一致 |

> 第 3 和第 5 是这一版真正容易坏的两处：一个是"别人的 session 有没有被还回去"，
> 一个是"这个键有没有真的写进 plist"。

### 九、下一步候选

| 候选 | 用户多久撞上 | 工作量 | 说明 |
|---|---|---|---|
| ① 压低幅度可调（Light / Default / Heavy） | 低 | 小 | 系统只给一个档位（`DuckOthers` 就给一个固定压低量），要更细就得自己混音，成本不成比例 |
| ② A 通道也压（自管 session） | 低 | 中 | 得给短音额外激活 + 交还会话，等于把"零 session 副作用"这条已验证性质弄脏 —— **除非真有人抱怨短音压不住** |
| ③ 试听削尾 | 低 | 小 | `didFinish` 之后缓冲尾韵可能被交还削掉几十毫秒。要治就得延迟交还，而"固定延迟"在本项目里是禁忌，得先有真机听感证据 |
| ④ 收尾 | — | 小 | 归档临时脚本、清掉 `Local Settings\Temp` 里三个硬编码 token 的旧脚本；**PAT 留到最后一版交付完再撤** |

### 十、真机结果：通过（2026-10-24）

用户回报「验完了，没问题」—— **一次口头确认，没有逐条回报**。照实记在这里，不拿它冒充逐条证据。

这六条里真正**能证伪一件事**的只有第 3 条：提示音结束后音乐自己回到原样。
它证明了「别人被压低过的 session 真的被还回去了」（也就是 v0.0.30 那句
`NotifyOthersOnDeactivation` 还在起作用）。其余五条就算漏验，最坏也只是"开关不生效"，
可逆、可见、不影响别的功能。

> ⚠️ 诚实记一笔：这一版**没有任何日志能自证 duck 真的生效**。
> `DuckOthers` 是 C 枚举常量（包级验不了，见第六节），代码里也没为它加日志 ⇒
> 「开关打开后音乐确实变小了」这件事**只有耳朵能证明**。
>
> 若以后有人反馈「开了没效果」或「音乐一直闷着」，第一件事是加两条日志，设计照 v0.0.30 那次：
> ①「本次 B 通道 options 含/不含 duck」**每 20 次打一条**（低频，不冲掉 50 行窗口）；
> ②「交还被跳过：live 非空 / 朗读在播」**每次都打**（低频且正是命门）。
> 两个都要有 —— 否则"没看到跳过"和"根本没跑到"分不开。

---

## v0.0.33 · 消息盒子能看全文、复制、删单条

### 一、这一版解决什么

到 v0.0.32 为止，盒子 App 的列表 cell 是 `numberOfLines = 2`、超了截断，
而**点一行只做 `markRead:`** —— 长通知（验证码、链接、长消息）**永远看不全，也复制不了**。

对「消息盒子」来说这是核心缺口：记录下来了但看不全，等于没记全。
而最近 8 个版本（v0.0.25~v0.0.32）全在打磨提示音，这块一直停在 v0.0.2x 的水平。

| 改动 | 位置 |
|---|---|
| `deleteRow:`（删单条，参数绑定 + 查 `changes`） | `NotifyStore.h/.m` |
| 详情页：App/时间/标题/副标题 + **正文全文**（`UITextView`，可选中）+ `复制` / `删除` | `app/NotifyDetailViewController.h/.m`（新增） |
| 点行 → push 详情；左滑 → `删除` | `app/ViewController.m` |

### 二、三个设计约束（判据都盯着）

**① 删除只改数据库，由列表重查。**

绝不用 `deleteRowsAtIndexPaths:` 或 `removeObjectAtIndex:` 去"配合同步"内存数组。
列表数据是 `queryWithBundle:since:search:` 的结果 —— 在「搜索 / 顶部 App 筛选 / 时间段」
任何一种状态下，**内存下标和数据库 id 完全是两回事**。只改内存 = 只改账本的读数
（数量契约第 2 问）。症状很具体：删完那行还在，或者删了 A 却少了一条 B。

正确顺序只有一条：**先删库 → 整表重查**。详情页删完也不碰列表的数据源，
只调 `onDeleted` 回调，由列表自己 `loadData`。

**② 删到 0 行不许当成功。**

`DELETE FROM notifications WHERE id=?` 命中 0 行时，sqlite 照样返回 `SQLITE_DONE`。
不查 `sqlite3_changes()` 就永远"成功"—— 而最典型的删不到恰恰是
**这条已经被「记录上限」裁掉了**（tweak 侧 `recordWithBundle:` 每次都按上限裁剪）。
用户点删除、界面不报错、列表也没变，只会认为按钮坏了。
所以：查 `changes`，删不到也**照样刷新列表 + 说清楚**。

**③ 漏进 Makefile 会链接期才炸。**

`application.mk` 不会自动收目录里的新 `.m` ⇒ `app/NotifyDetailViewController.m`
必须加进 `NotifyBoxApp_FILES`，否则编译期过、链接期报
`undefined symbol _OBJCCLASS_$_NotifyDetailViewController`。
这个项目在 v0.0.28 已经被同一件事坑过一次，这次判据 `d01` 先盯着。

另外两条是"别把好设计改回去"的护栏：正文必须 `selectable`（验证码/链接通常只要一段）；
删除必须二次确认（不可撤销的动作不该一碰就执行）。

### 三、判据：18 条语义 + 18 条负向变异

| 组 | 判据 | 要害 |
|---|---|---|
| a01 | `deleteRow:` 用 `sqlite3_bind_int64`，不许拼 SQL | 一处拼串一处绑参，迟早有人把字符串塞进拼串那处 |
| a02 | 必须查 `sqlite3_changes(db) > 0` | 见约束 ② |
| a03 | 头文件声明 | — |
| a04 | tweak 侧不许调 `deleteRow:` | 否则「上限裁剪」和「手动删除」两条删除路径互相踩 |
| b01 | 点一行必须 push 详情（且仍 `markRead:`） | 否则回到"只标已读" |
| b02 | `onDeleted` → `loadData` | 删完返回，那行得消失 |
| b03 | **不许**出现 `deleteRowsAtIndexPaths:` | 见约束 ① |
| b04 | 列表里**不许** `removeObjectAtIndex:` | 同上 |
| b05 | 左滑必须**先删库再重查** | 顺序反了会重查到删之前的库 |
| c01 | 正文 `selectable = YES` 且是 `UITextView` | 选不中一段就只能整条复制 |
| c02 | 删除前二次确认 + destructive + 取消 | — |
| c03 | 删不到也要 `onDeleted` + 给提示 | 静默失败 = 以为按钮坏了 |
| c04 | 复制内容含标题/正文/副标题/落款 | 落款是"这是哪个 App 什么时候来的" |
| c05 | 详情页私有方法全部显式声明 | CI 是 `-Werror` |
| d01 | `NotifyBoxApp_FILES` 收进新文件 | 见约束 ③ |
| d02 | tweak 目标不许收 App 界面文件 | tweak 是 SpringBoard 的 dylib |
| v01~v02 | 版本 0.0.33 三处齐 · 括号与 `@end` 配平 | — |

**反向对照**（喂 v0.0.32 的源码）：**13/18 变红**。
存活的 5 条是 `a04` / `b03` / `b04` / `d02`（都是"不许出现某物"型护栏，旧版本天然通过）
和 `v02`（配平）。

### 四、🔴 正判据当场抓到的两个真问题

这两个都不是变异测出来的，是**第一次跑正判据就红**：

**（1）详情页类扩展漏声明 `doDelete` 和 `str:`** —— 它们分别在
`onDelete:` 的 alert block 里（`[weakSelf doDelete]`）和多个方法里被调用，
未声明就是 `-Werror` 挂。**判据 `c05` 在我提交之前就拦住了。**

**（2）配平判据自己数错了。**

这一版第一次把 `NotifyStore.m` / `ViewController.m` 纳入配平检查，立刻报：

```
NotifyStore.m: () 差 -1; app/ViewController.m: [] 差 -1
```

查下去发现代码是配平的 —— 是**判据把字符串里的括号也算进去了**：
SQL 里的 `(SELECT id FROM … LIMIT %ld)`、日志里的 `[%@]`、提示文案里的方括号。

> ⇒ 修法不是改判据的容忍度，而是加 `strip_strings()`：
> **统计括号前先把字符串内容清空**（引号保留）。
> 这也是一条通则 —— `strip_c_comments` 保留字符串内容是**故意的**（别的判据要读 `@"键名"`），
> 所以"给括号配平用"必须再剥一层，两个用途不能共用一份文本。
> 前三版没撞上，只是那四个文件恰好没有不平衡的字符串。

### 五、包级判据（16 条）

| 组 | 判据 | 为什么必须存在 |
|---|---|---|
| A1~A2 | control / 文件名是 0.0.33 | — |
| B1 | tweak 有 `v0.0.33` | — |
| B2 | App 有选择器 `deleteRow:` | 不在 ⇒ 数据层没接上，点删除"什么都没发生" |
| B3 | App 有类名 `NotifyDetailViewController` | 不在 ⇒ 详情页没参与编译（典型原因就是 Makefile 漏文件） |
| B4 | App 有 `trailingSwipeActionsConfigurationForRowAtIndexPath:`（**弱**） | 这个协议方法名在旧版二进制的 UIKit 引用里也可能出现 ⇒ 反向对照会存活，不能当强证据 |
| B5 | App 有「已复制」（`__ustring`） | 复制那条路真的在 |
| B6 | App 有「删除这条记录」 | 二次确认真的在 |
| C1 | tweak 没有 `v0.0.32` 残留 | 反向：版本串真的升上来了 |
| D1~D7 | `soundDuckOthers` / `commitMaxSec:` / `releaseAudioSessionIfIdle` / `markRead:` / 查询入口 / `SoundAppsViewController` / `maxSec` | 回归：前四版没被带坏 |

**反向对照**（喂 v0.0.32 的 deb）：**8/16 通过**，8 条变红。
存活的是 `B4`（弱判据，见上）和 `D1~D7`（回归保留项）。

### 六、交付

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.33_iphoneos-arm64e.deb` · **106076 B** |
| CI | **#66**（`run_id 40083139368`，head `4f29f443b096`）success，一次编译过 |
| 产物 zip | 106261 B（与 API `size_in_bytes` 对拍一致） |
| 远端 | `4f29f443b096` = 本地 `a3f7ea35a388`，**53 个文件逐 blob 一致** |
| 结构 | 37 个文件 0 问题 |
| 改动 | 9 文件 **+369 / −8**（新增 2 个文件） |
| App 二进制 | **333120 → 350320 B**（+17200，详情页真的编进去了） |
| tweak 二进制 | 未变（这一版 tweak 只升版本串） |

### 七、装了这一版要验什么

| # | 操作 | 期望 |
|---|---|---|
| 1 | 点一条**长**通知 | 详情页能看到**全文**（列表里只有两行） |
| 2 | 在正文里长按 | 能选中**一段**（比如只选验证码那 6 位） |
| 3 | 点右上「复制」→ 粘到备忘录/微信 | 顺序是 标题 / 正文 / 落款「—— 微信 · 10-24 17:30」，有「已复制」提示 |
| 4 | 点「删除」→ 取消 | **什么都不发生**（记录还在） |
| 5 | 点「删除」→ 确认删除 | 自动返回列表，那一行消失；杀掉 App 重进**也不会回来** |
| 6 | 列表左滑一条 → 删除 | 那一行立刻消失，没有残留、没有闪 |
| 7 | 🔴 **开着搜索**（或选了某个 App 图标）时删一条 | **只有目标那条消失**，同屏别的行一条都没被误删 |
| 8 | 回归：未读标记 / 时间筛选 / 顶部图标筛选 / 按 App 换音 / 按 App 配时长 / 压低开关 | 与 v0.0.32 一致 |

> **第 7 条是这一版真正的判据**。用 `deleteRowsAtIndexPaths:` 或手改内存数组的写法，
> 在"搜索/筛选态"下会删错行或者留下残影 —— 而单条、全量状态下看着完全正常。
> 第 5 条「重进也不回来」验的是"真的写到数据库了"，不是只从界面上抹掉。

### 八、下一步候选

| 候选 | 用户多久撞上 | 工作量 | 说明 |
|---|---|---|---|
| ① **未读/已读看得出来** | 每天 | 小 | 现在 `markRead:` 写进去了，但 `NotifyCell` **完全不显示已读/未读** —— 用户看不出哪条没看过，"点开即已读"这件事等于没有反馈 |
| ② **主列表加「清空」入口** | 偶尔 | 小 | `clearAll` 现在只有设置页有入口（`SettingsViewController.m:846`），清记录要跑进设置找 |
| ③ 试听削尾 | 低 | 小 | `didFinish` 之后缓冲尾韵可能被交还削掉几十毫秒。要治就得延迟交还，而"固定延迟"在本项目里是禁忌，得先有真机听感证据 |
| ④ 收尾 | — | 小 | 归档临时脚本、清掉 `Local Settings\Temp` 里三个硬编码 token 的旧脚本；**PAT 留到最后一版交付完再撤** |


---

## v0.0.34 · 修详情页顶部顶进状态栏（只补 `safeAreaInsets.top`）

用户原话：**「详情页整体有点偏上了，图标都顶到状态栏最顶端了」**。

### 一、病因：`self.view.bounds` 的 (0,0) 到底在哪

详情页在 `UINavigationController` 里，而 `edgesForExtendedLayout` 默认是 `.all`。
这意味着 VC 的 `view` 是**铺满整个屏幕**的（含状态栏和导航栏下方），
`self.view.bounds` 的 `(0,0)` 在**屏幕顶点**，不是导航栏下沿。

v0.0.33 写的是：

```objc
self.headerBox.frame = CGRectMake(pad, 12, w - pad * 2, 52);   // ← 12 是相对屏幕顶点的
```

于是 `headerBox`（那个装着 App 图标 + 名字 + 时间的灰盒子）被放到离屏幕顶 12pt ——
正好压在状态栏里的时间/信号图标上。

**为什么只有上半截偏上、下半截是对的**：这一页底部从一开始就写的是
`safeAreaInsets.bottom + 12`，只有顶部那个 `12` 没加安全区。
所以观感是"整体偏上"而不是"整体上移"——**同一页里两种坐标基准混用**，
这比整页都错更难看出来。

修法就一行：

```objc
UIEdgeInsets si = self.view.safeAreaInsets;
CGFloat top = si.top;
self.headerBox.frame = CGRectMake(pad, top + 12, w - pad * 2, 52);
```

顺带把 header → 标题的间距从 12 调到 14（盒子下沉后视觉上会显得挤）。

### 二、为什么不用 `edgesForExtendedLayout = UIRectEdgeNone`

这是最容易被想到的"一行解决"：设了它，`self.view.bounds` 就变成"导航栏下沿"，
原来的 `y = 12` 立刻就对。

**但它是把坐标系整个换掉**，代价是三处：

1. `toast:` 里用 `self.view.bounds.size.height - 120` 定位 —— bounds 一变，提示条位置跟着变；
2. 以后想在这页加"图标模糊背景"这类延伸到导航栏下面的装饰，就做不了了；
3. **项目里另外 6 个页面全是 `.all` + `safeArea` 的写法**，唯独详情页改基准 ⇒
   下一个改这页的人会按另外 6 页的约定来写，然后发现它不按常理出牌。

所以判据里专门有一条 `b01` 把这条路堵掉：详情页**不许**出现 `edgesForExtendedLayout`。

### 三、全仓扫描：这是「一类错误」，不是「一个 bug」

写判据之前先把 7 个手写 `viewDidLayoutSubviews` 的 VC 全看了一遍：

| 页面 | 布局写法 | 要不要 safeArea |
|---|---|---|
| `ViewController`（主列表） | `CGFloat top = self.view.safeAreaInsets.top;` 然后逐个 `CGRectMake` | ✅ 早已正确 |
| `NotifyDetailViewController` | 同上 —— **本版修的就是它** | ✅ 本版补上 |
| `AppPickerViewController` | `self.table.frame = self.view.bounds;` | ❌ 不需要 |
| `ReplaceRulesViewController` | 同上 | ❌ 不需要 |
| `SoundAppsViewController` | 同上 | ❌ 不需要 |
| `SoundFilePickerViewController` | 同上 | ❌ 不需要 |
| `VoicePickerViewController` | 同上 | ❌ 不需要 |
| `SettingsViewController` | `self.scroll.frame = CGRectMake(0, 0, w, h);` 里面再排 box | ❌ 不需要 |

中间那 5 个"不需要"是**关键区分**，也是判据最容易写错的地方：

> `self.table.frame = self.view.bounds;` **不是**同一个错误。
> `UITableView` / `UIScrollView` 会自己按 `contentInsetAdjustmentBehavior` 加 contentInset，
> 铺满全屏正是 UIKit 的常规用法，第一个 cell 自然落在导航栏下沿。

所以判据的切口**不能**是"用了 `self.view.bounds` 就要求读 safeArea"——
那样 5 个正确页面会一起报红，然后判据本身会被当成噪音删掉。
真正的病征是另一件事：

> **给「直接挂在 `self.view` 上的普通 UIView」用 `CGRectMake` 定位，且 y 是一个正整数常量。**

那个常量就是"我以为 0 点是导航栏下沿"的错觉。`SettingsViewController` 的 `scroll`
也是直接子视图，但它的 y 是 `0` ⇒ 不触发（`0` 就是屏幕顶点，本来就该是 0）。

### 四、源码判据（11 条）+ 反向对照

| # | 判据 | 说明 |
|---|---|---|
| a01 | 详情页必须**真的**取到 `safeAreaInsets.top` | 顺着变量→源查，见下面「坑 2」 |
| a02 | `headerBox` 的 y 必须是含 `top` 的表达式 | 不许是常数 |
| a03 | **全仓**：直接挂 `self.view` 的子视图，y 不许是正整数常量 | 一类错误的扫描判据 |
| b01 | 详情页不许出现 `edgesForExtendedLayout` | 防"换基准"式绕过 |
| b02 | **总闸**：每个手写布局的 VC 必须有明确的安全区策略 | 三条命中其一即可，见下 |
| c01~c04 | 回归：正文 `selectable` / 图标 36×36 / `MAX(h, 80)` 下限 / `si.bottom` | 别顺手改坏 v0.0.33 的成果 |
| d01 | `0.0.34` 六处齐（Tweak.x 三处显示串 + control + plist 两处），且无 v0.0.33 残留 | — |
| v01 | 括号 / `@end` 配平（统计时**剥掉字符串内容**） | — |

`b02` 的三条合格路径：

1. 取了**顶部**安全区（`CGFloat top = … safeAreaInsets.top` / `si.top`）；
2. frame 全是 `= self.view.bounds` 整块拷贝（交给 table/scroll 自动 inset）；
3. 直接挂 `self.view` 的子视图里，没有一个是正整数常数 y。

**负向自测 11/11 全部报红**，**反向对照 PASS**：拿 v0.0.33 的
`NotifyDetailViewController.m`（`git show HEAD:…`）喂进去，`a01 / a02 / a03 / b02`
四条当场报红 —— 这正是"判据能证伪自己"的样子。

### 🔴 五、这一版判据自己踩的四个坑（都值得记）

**坑 1 · 查"有没有出现过某个词"抓不到"用错了方向"。**
`a01` 最初写的是"函数体里含 `safeAreaInsets` 就算过"。反向对照当场戳穿：
v0.0.33 的**底部**写的是 `self.view.safeAreaInsets.bottom`，这个字样在，
判据就放行了 —— 而病恰恰在**顶部**。必须钉死到 `.top`。

**坑 2 · 查 `si.top` 字样放过了「`si` 本身被换掉」。**
改完坑 1，`b02` 的负向变异（`UIEdgeInsets si = UIEdgeInsetsZero;`）依然假装通过，
因为 `si.top` 这几个字符还在。教训很硬：**凡"间接变量"都必须在判据里把它的源头一起验**，
否则判据验的是**名字**不是**行为**。修法是加 `takes_top_safe_area()`：
先建 `变量 → 赋值源` 的映射，再顺着 `si.top` 反查 `si` 是不是真的来自 `safeAreaInsets`。

**坑 3 · 负向变异框架自己有 bug：多锚点变异从来没同时生效过。**
原来的写法是每轮循环 `mraw = dict(raw)` 重置，然后改一处、跑一次。
于是"同一条判据配两个锚点"时，两次跑的是**两个只改了一半的副本**，
从来没有一份是"全都改坏"的 —— `b02` 的 `si→Zero` 和 `headerBox y→12` 就是这样互相覆盖，
导致一条真判据被误判成"形同虚设"。修法：`mraw` 提到循环外，累积应用。
（v0.0.33 的脚本也是同样写法，只是那一版没有多锚点判据，所以没暴露。）

**坑 4 · 同一个文件被加载了两份，变异改一份、扫描读另一份。**
`FILES` 里有 `detail_m`，`glob` 又把 `app/*.m` 整个收进来（key 是 `app:NotifyDetailViewController.m`）。
负向变异改的是前者，`a03`/`b02` 这两个"全仓扫描"判据读的是后者 ⇒ 改坏了也照样绿。
修法：glob 时若该文件已按 `FILES` 加载过，**复用同一个 key**。

> 四个坑同一个母题：**判据"绿"的原因，和它本来要证的那件事，是不是同一件事。**
> 坑 1 是问错了方向，坑 2 是认名字不认行为，坑 3 是变异没落地，
> 坑 4 是看的和改的不是同一份数据。

### 六、包级判据（16 条）

这一版是最难验的一类改动：**没有新增选择器、没有新增字符串、二进制大小没变**。

| 组 | 判据 | 说明 |
|---|---|---|
| A1~A2 | control / 文件名是 `0.0.34` | — |
| A3 | tweak 二进制有 `v0.0.34` | 子串口径 |
| A4 | `NotifyBox.app/Info.plist` 的 `CFBundleVersion = 0.0.34` | — |
| **B1** | 🔴 **App 二进制 md5 与 v0.0.33 不同** | **唯一硬证据**：指令序列真的改了 |
| B2 | App 二进制大小 —— **只作记录，不是判据** | 见下 |
| B3 | App 有 `viewDidLayoutSubviews`（**弱**） | 旧版也有 ⇒ 反向对照会存活 |
| C1 | tweak 里没有 `NotifyBox v0.0.33` 残留 | 防"只改版本号" |
| D1~D8 | 回归：详情页类 / `deleteRow:` / `soundDuckOthers` / `commitMaxSec:` / `releaseAudioSessionIfIdle` / 查询入口 / `maxSec` / 包内文件集合与基准一致 | 前六版没被带坏 |

**反向对照**（拿 v0.0.33 的 deb 当"当前成品"）：**10/16 通过**，6 条变红
（`A1~A4`、`B1`、`C1`）。存活的是 `B2/B3`（记录项与弱判据）和 `D1~D8`（回归保留项）。

#### 🔴 大小一字不变、内容全变（第三次）

| | v0.0.33 | v0.0.34 |
|---|---|---|
| App 二进制 | `350320 B` | `350320 B` ← **完全相同** |
| App md5 | `868f5a754205` | `6ffeeb41b24d` ← 变了 |
| tweak md5 | `9c13d4d19ffa` | `01185e754f6d` ← 变了（只改版本串） |

这是本项目第三次撞上同一件事：
v0.0.28 是「**段内**缩小 ≠ 文件缩小」，v0.0.32 是「两个二进制字节数全同、md5 全变」，
这一次连**指令条数变了**（`12` → `top + 12`）而文件大小一位不变 ——
原因是 Mach-O 段按固定对齐填充，多出来的几十字节被填进 padding 里。

> 通则：**判"编进去没"看串 / 选择器 / md5，永远不看文件大小。**

### 🔴 七、我自己的期望表也错了一次

包级 `D8` 最初写的是 `len(files) >= 37`，跑出来 `[FAIL] 只有 4 个`。
查下去发现 **37 是源码目录的文件数**，不是 deb 内的 —— deb 里只有 4 个：

```
    467 B  Applications/NotifyBoxApp.app/Info.plist
 350320 B  Applications/NotifyBoxApp.app/NotifyBoxApp
 143856 B  Library/MobileSubstrate/DynamicLibraries/NotifyBox.dylib
    118 B  Library/MobileSubstrate/DynamicLibraries/NotifyBox.plist
```

按纪律处理：**期望表自己错了就改期望，不许把闸门放宽去迁就它。**
于是 `D8` 改成"包内文件集合与基准 deb **完全一致**"（比数个数更硬：既防丢文件，也防多塞东西）。

### 八、交付

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.34_iphoneos-arm64e.deb` · **106014 B** |
| CI | **#68**（`run_id 40084566201`，head `35f48badf0a6`）success，一次编译过 |
| 产物 zip | 106204 B（与 API `size_in_bytes` 对拍一致） |
| 远端 | `35f48badf0a6` = 本地 `33931539af0f`，**53 个文件逐 blob 一致** |
| 改动 | 4 文件 **+19 / −11**（全部在布局与版本串上，无逻辑改动） |
| App 二进制 | `350320 B`（与 v0.0.33 **大小相同**，md5 变） |
| tweak 二进制 | `143856 B`（只升版本串，md5 变） |

### 九、装了这一版要验什么

| # | 操作 | 期望 |
|---|---|---|
| 1 | 🔴 进任意一条通知的详情页 | **灰色盒子（图标+App名+时间）在导航栏下方**，不再压到状态栏的时间和信号图标上 |
| 2 | 同一页往下看 | 标题 / 副标题 / 正文的位置整体下移了约一个状态栏的高度，**正文底部不会压到 Home 指示条** |
| 3 | 长标题 + 副标题都在的通知 | 正文区域自动变矮，但**至少还有 80pt 高**，不会消失 |
| 4 | 点右上「复制」 | 「已复制」提示条出现在**屏幕下方**（它的位置没被这次改动影响） |
| 5 | 回归：详情页删除 / 左滑删除 / 搜索态删一条 / 主列表布局 | 与 v0.0.33 一致 |
| 6 | 回归：按 App 配时长 / 压低音乐开关 / 试听 | 与 v0.0.32 一致 |

> **第 1 条是这一版唯一的判据**：盒子顶边到屏幕顶的距离，应当等于「状态栏 + 导航栏 + 12pt」。
> 如果它还是贴着状态栏，说明装上的不是这一版（先看日志里那行 `v0.0.34`）。
> 第 2 条的下半句（正文不压 Home 指示条）验的是"**同一页两种坐标基准**已经统一"，
> v0.0.33 里底部本来就是对的，所以它更该是绿的 —— 如果它反而坏了，说明改错了方向。

---

## v0.0.35 · 未读标记看得出来 + 主列表「清空」入口

### 一、未读标记：数据层早就齐了，只差最后一步

查代码之前我以为这是个"新功能"，查完发现**数据已经在库里躺了三版**：

| 层 | 状态 |
|---|---|
| 建表 | `read INTEGER DEFAULT 0` —— 一直有 |
| `markRead:` | `UPDATE notifications SET read=1 WHERE id=?` —— 一直能写 |
| `queryWithBundle:` | `SELECT id,bundle,title,message,subtitle,ts,read …` —— **一直在取 read 列** |
| `item` 字典 | `d[@"read"] = @(sqlite3_column_int(st, 6))` —— 一直填好了 |
| `NotifyCell` | **完全没用过** ← 缺口就在这一格 |

所以「点开即已读」这件事从 v0.0.x 起就一直在正常工作，**只是用户看不见任何反馈**，
等于没做。这版的改动量因此比预想的小得多。

外观上选了**左侧 8pt 蓝点**，没有用"标题加粗/变灰"：

- 15pt `semibold` → `bold` 在小屏上几乎看不出差别；
- "已读标题变灰"会让整屏发灰，用户第一眼会以为列表坏了；
- 侧面一个点是最不打扰、又能一眼**数出来**的做法。

### 二、三个坑，每一个都是"代码看着没错、屏幕上是错的"

#### 坑 1 · cell 复用不复位

`prepareForReuse` 里漏一句 `self.dotView.hidden = YES;`，症状是：

> 第 3 行（未读）被复用到第 30 行（已读）时，**蓝点跟着过去了**。

而 `cellForRowAtIndexPath:` 里明明调了 `setUnread:NO` —— 代码读一百遍都看不出问题，
单元测试也抓不到（它不解码"屏幕上有没有那个点"）。只有真机能发现。
所以判据 `a03` 专门钉住 `prepareForReuse` 的**函数体内部**。

#### 坑 2 · 点开一条再返回，列表跳回顶部

点开后要把「已读」同步到界面，最容易想到的做法是在 `viewWillAppear:` 里 `loadData`。
但 `reloadData` 会**把滚动位置清零** —— 滚到列表中间点开一条、返回，人已经回到顶部了。

正确做法是**在点开那一刻**只刷那一行：

```objc
if ([d isKindOfClass:[NSMutableDictionary class]]) {
    [(NSMutableDictionary *)d setObject:@1 forKey:@"read"];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}
```

push 动画期间列表被详情页盖住，返回时已经是已读态，既不闪也不跳。

> 🔴 **`reloadRowsAtIndexPaths:` 在这里是安全的，而 v0.0.33 的删除场景里它是禁忌** ——
> 这两句不矛盾。判据从来不是"这个 API 好不好"，而是**数量变不变**：
> 这里只把一个字段 0→1、行数不变，内存下标和 row 仍然一一对应；
> 删除会改数量，所以必须整表重查。

`loadData` 保留在一个兜底分支里（万一哪天 `query` 改成返回不可变字典）—— 宁可丢滚动位置，也不能错。

#### 坑 3 · 先改内存、后写库

顺序反了，`markRead:` 之后紧接着 reload 的那一行读到的还是旧值，点不会消失。
判据 `a06` 用 `rfind("markRead:")` 对比 `find('forKey:@"read"')`（**右边取第一处、左边取最后一处**），
理由见下面「判据自己踩的两个坑」。

### 🔴 三、清空：一个必须避开的灾难

`clearAll` 清的是**整张表**。而列表在筛选态下只显示一部分：

> 用户搜「验证码」，列表里 3 条，点「清空」→ **数据库里 2000 条全没了。**

这是这一版最危险的错，而且它不会报错、不会崩，只会让人在第二天发现记录全丢。
三道防线：

1. **确认文案报库总数**：`[NotifyStore count]`，不是 `self.items.count`；
2. **两者不等时额外提示**：「当前列表只显示 N 条（有筛选/搜索，或超出单次上限），但会一起清掉」；
3. **空库时不弹确认**，直接说「数据库里是空的，不用清」—— 弹了之后点「清空」什么都没发生，
   反而让人以为按钮坏了。

另外沿用 v0.0.33 的两条纪律：

- `DELETE FROM` 命中 0 行**照样返回 `SQLITE_OK`** ⇒ 必须查 `sqlite3_changes`，
  所以 `clearAll` 从 `void` 改成了 `+ (NSInteger)clearAll;`（返回清掉的条数，`-1` = DB 打不开）。
  界面据此分三支：`n > 0` 报条数、`n == 0` 说「没清到」、`n < 0` 说「打不开数据库」。
- **先清库 → 再整表重查**。顺序反了刷出来的是清之前的列表。

`sqlite3_changes` 必须紧跟在 `sqlite3_exec` 之后取 —— 它是"最近一条语句改了 N 行"，插一句别的就串了。

### 四、顺带修掉一个连带问题：筛选状态不会自愈

这个问题不是这一版引入的，但**这一版让它变得容易撞上**：

删掉某个 App 的最后一条、或者刚点完「清空」之后，`self.filterBundle` 还指着那个 App。
而 `reloadIconBar` 重建的图标栏里已经没有它了（`distinctBundles` 查不到记录）⇒

> 列表永远空着，顶部**没有任何图标被选中**，用户第一眼会以为记录全丢了。

修法在 `loadData` 里加一句自愈：

```objc
if (self.filterBundle && ![self.bundles containsObject:self.filterBundle]) {
    self.filterBundle = nil;
}
```

🔴 顺序必须排在 `reloadIconBar`（它才更新 `self.bundles`）**之后**、`query` **之前**。
判据 `b09` 同时检查这两条边界。

### 五、源码判据（22 条）

| 组 | 判据 | 说明 |
|---|---|---|
| a01~a07 | `setUnread:` 声明 / 真的切 `hidden` / **`prepareForReuse` 必须复位** / 布局让位（`iconX` 从点推出，不许硬编码 14） / `cellForRow` 读 `read` / 写库→改内存的顺序 / **只刷那一行不整表 reload** | 未读标记 |
| b01~b09 | `clearAll` 返回条数 / 查 `sqlite3_changes` / 二次确认 + 取消 + destructive / **文案报库总数且区分筛选态** / 先清库再重查 / 清到 0 条不当成功 / 导航栏入口 / 类扩展声明 / **筛选状态自愈** | 清空 |
| c01~c04 | 详情页 `selectable` / 左滑删除的顺序 / 不许 `removeObjectAtIndex:` / `onDeleted` | 回归 |
| d01 / v01 | 版本 6 处 / 括号配平（剥字符串） | — |

**负向自测 22/22 全红**；**反向对照**拿 v0.0.34 的同一批 9 个文件（`git show HEAD:`）喂进去，
**9 条当场报红**（`a01/a02/a03/a05/a06/a07/b01/b07/b08`）。

### 🔴 六、判据自己又踩了两个坑（都是"太松"）

**坑 1 · `find` 取第一处，被"后面再补一处"绕过。**
`a06` 最初写的是 `i_mark = b.find("markRead:")`，负向变异把「改内存」那句挪到写库之前、
同时在后面再补一句 `markRead:` ⇒ 第一处 markRead 确实在前 ⇒ 判据绿了。
真正的语义是「**所有**改内存 read 的语句都要排在**最后**一处写库之后」⇒
改成 `b.rfind("markRead:")` 对 `b.find('forKey:@"read"')`。

**坑 2 · 只看"挂了个 block"，不看 block 里做了什么。**
`c04` 最初只 grep `.onDeleted = ^`，负向变异把 block 体换成 `(void)weakSelf;`
（挂是挂上了，什么都不做）就活了 —— 而那正是"删完返回列表那一行还在"的病。
改成用正则取 block **体内**，要求里面有 `loadData`。

> 这两条和 v0.0.34 的四个坑是同一个母题，只是换了个方向：
> **v0.0.34 是"判据验的东西偏了"，这一版是"判据验的强度不够"。**
> 前者靠反向对照能发现，后者只能靠负向变异 —— 而且变异必须真的改坏那个**语义**，
> 不能只改个措辞让自己好过。

### 七、包级判据（22 条）

| 组 | 判据 | 说明 |
|---|---|---|
| A1~A4 | control / 文件名 / tweak `v0.0.35` / App `Info.plist` | — |
| **B1** | 🔴 **App 二进制 md5 与 v0.0.34 不同** | 硬证据 |
| B2 | App 二进制大小 —— **只作记录** | 见下 |
| B3 | App 有选择器 `setUnread:` | 未读标记真的接上了 |
| B4 | App 有选择器 `dotView`（属性合成 getter） | 那个点真的编进去了 |
| B5 | App 有「清空所有记录？」 | 入口真的接上了 |
| B6 | 有「已清空」（**弱**：设置页的状态文案里早有这句，反向对照会存活） | — |
| B7 | 有「当前列表只显示」 | **防筛选态误删的那句提示真的在** |
| B8 | 有「打不开数据库」 | `n == -1` 不是死代码 |
| C1 | tweak 无 `v0.0.34` 显示串 | 防"只改版本号" |
| D1~D9 | 详情页类 / `deleteRow:` / `viewDidLayoutSubviews` / `soundDuckOthers` / `commitMaxSec:` / `releaseAudioSessionIfIdle` / 查询入口 / `maxSec` / 包内文件集合与基准一致 | 前六版没被带坏 |

**反向对照**（拿 v0.0.34 的 deb 当"当前成品"）：**11/22 通过**，11 条变红
（`A1~A4`、`B1`、`B3~B5`、`B7`、`B8`、`C1`）。存活的 11 条 = `B2`（记录项）、
`B6`（弱判据）和 `D1~D9`（回归保留项）。

#### 🔴 大小只涨了 16 字节（第四次撞，也是最极端的一次）

| | v0.0.34 | v0.0.35 |
|---|---|---|
| App 二进制 | `350320 B` | `350336 B` ← **只 +16 字节** |
| App md5 | `6ffeeb41b24d` | `4345c9b74bee` |
| tweak md5 | `01185e754f6d` | `15f5c4a24155`（只改版本串） |
| 实际改动 | — | **8 文件 +165 / −14** |

这一版加了 100 多行代码、新增一个方法（`setUnread:`）、一个属性（`dotView`）、
七八条中文文案（进 `__ustring`），**而二进制总共只涨了 16 字节** ——
全被 Mach-O 段对齐的 padding 吃掉了。

第 4 次了（v0.0.28 段内缩小 / v0.0.32 字节数全同 / v0.0.34 指令变了大小不变 / 这次 +16）。
> 通则不变：**判"编进去没"看串 / 选择器 / md5，永远不看文件大小。**
> 反过来也成立：**"大小几乎没变"绝不等于"改动很小"**。

### 八、交付

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.35_iphoneos-arm64e.deb` · **106818 B** |
| CI | **#70**（`run_id 40086451793`，head `127342965118`）success，一次编译过 |
| 产物 zip | 107009 B（与 API `size_in_bytes` 对拍一致） |
| 远端 | `127342965118` = 本地 `99ec5182e1a8`，**53 个文件逐 blob 一致** |
| 改动 | 8 文件 **+165 / −14** |
| App 二进制 | `350320 → 350336 B`（+16，md5 变） |
| tweak 二进制 | `143856 B`（只升版本串） |

### 九、装了这一版要验什么

| # | 操作 | 期望 |
|---|---|---|
| 1 | 打开盒子 | 新来的（没点开过的）记录左边有**蓝点**，点开过的一条条变没有 |
| 2 | 🔴 滚到列表**中间**，点开一条，返回 | 那一条的蓝点消失，**列表还在原来的位置**（不跳回顶部） |
| 3 | 🔴 上下快滚几十行，看有没有"已读的行带着蓝点" | **不能有** —— 有就是复用没复位 |
| 4 | 点右上「清空」 | 弹确认，文案里是**库总数**，红色「清空」+「取消」；取消什么都不发生 |
| 5 | 🔴 **先搜索一个词**（列表只剩几条），再点「清空」 | 文案要**额外提示**「当前列表只显示 N 条…但会一起清掉」，且总数是全库 |
| 6 | 确认清空 | 列表空、标题变成 `(0)`；提示「删掉了 N 条记录」 |
| 7 | 空库时再点「清空」 | 提示「数据库里是空的，不用清」，**不弹确认** |
| 8 | 🔴 顶部选中某个 App 图标 → 把它最后一条删掉 | 列表自动**回到「全部」**，不是空着 |
| 9 | 回归：详情页看全文/复制/删除、左滑删除、按 App 配时长、压低开关 | 与 v0.0.34 一致 |

> 第 2 条和第 3 条是这一版**唯一只有真机能验**的两件事：
> 前者验的是"没有整表 reload"，后者验的是 `prepareForReuse` 复位了没有。
> 两条都不会崩、不会报错，错了也只是"看着不对"——所以必须真的去看。
> 第 5 条是防灾难的：如果它没弹那句额外提示，先别点确认。

## v0.0.36 · 图标栏未读红点 + 搜索框下「全部 / 未读」切换

### 一、这一版做了什么

v0.0.35 让"未读"在**列表里**看得见了，但还有两个洞：

1. 想知道**哪个 App 还有没看的**，得一个一个点图标进去看；
2. 想只看未读，只能靠"时间筛选 + 自己记得哪些点过了"。

这一版补上这两块：顶部图标栏给**有未读的 App** 加一个小红点（只要"有没有"，不显示数字），
搜索框下面加一条 `全部 / 未读` 的 scope bar。

红点刻意**不给「全部」那格**：它聚合了所有 App，给它点红点等于说"全部里还有东西没看"，
点进去却只是有未读的那几个 App 的集合 —— 语义是乱的。

### 二、三个坑，全是"代码看着没错、屏幕上是错的"（同 v0.0.35 的母题）

#### 坑 1 · 按钮自己 `clipsToBounds = YES`，红点被裁掉一半

图标按钮是圆角方块，`clipsToBounds` 必须开（否则图标溢出圆角）。红点想探出右上角一点点，
直接挂在按钮上就会被裁成半圆。

修法：给每个图标加一层 **holder 容器**，红点挂 holder 上，图标挂按钮上。

```
holder (无裁剪)
├── btn (clipsToBounds = YES，放 icon)
└── dot (探出右上角)
```

#### 🔴 坑 2 · 点开一条后刷新红点，把图标栏的横向滚动位置夹回了最左

这是这一版最值得记的一个设计判断。最直接的做法是：点开一条 → 它变已读 → 调 `reloadIconBar` 重建红点。

但 `reloadIconBar` 会**重建所有按钮** ⇒ `contentSize` 重设 ⇒ 图标栏的滚动位置被夹回最左。

> 用户已经横向滚到第 10 个 App，点开一条记录返回后，**图标栏自己弹回最左边了**。

一拍脑袋才想到：红点只是"显示/隐藏"，凭什么要重建按钮？于是拆出 `refreshUnreadDots`：

```objc
// 只改已有红点的 hidden，绝不重建按钮、绝不碰 contentSize
for (NSString *b in self.unreadDots) {
    self.unreadDots[b].hidden = ![fresh containsObject:b];
}
```

同理 `reloadIconBar` 自己也补了 contentOffset 的存/恢复（这次重建是"真的要重建"的时候用的）。
包级判据 `B9` 钉的就是 `setContentOffset:` 这个 setter 消息真的编进去了。

#### 坑 3 · 拿 `bundleCounts` 兼职判未读 ⇒ 所有 App 永远有红点

`bundleCounts` 数的是**每个 App 的全部条数**（图标栏右侧那个数字用的），拿它判断"有没有未读"
会让每个 App 永远亮红点 —— 因为点开过的记录也在里面。

必须新写一个查询：

```sql
SELECT DISTINCT bundle FROM notifications
WHERE read=0 AND bundle IS NOT NULL AND bundle <> ''
```

`read=0` 而不是 `read<>1`：后者对 **NULL 不成立**，老库里 read 为 NULL 的行会既不进"未读"、
也不进"已读"，从界面上凭空消失。

### 三、`queryWithBundle:` 加第 4 个参数，旧签名真的删了

```objc
+ (NSArray<NSDictionary *> *)queryWithBundle:(nullable NSString *)bundle
                                       since:(NSTimeInterval)since
                                      search:(nullable NSString *)q
                                  unreadOnly:(BOOL)unreadOnly;
```

这个改动让包级判据变得**罕见地硬**：`queryWithBundle:since:search:` 是
`queryWithBundle:since:search:unreadOnly:` 的**前缀**，所以

- `B3` 查四参选择器**在**；
- `B4` 查三参选择器**不在**。

两条必须用 `\0` 精确匹配（`has_selector` 就是干这个的），否则子串匹配会把"新的在"误判成"旧的还在"。

🔴 而且 `B4` 的前提得说清楚：**它只在"真的删了旧签名"时成立**。v0.0.31 撞过一次反例 ——
当时的做法是"保留旧签名 + 转调新签名"，旧 selector **必然在包里**，那条判据当场假红。
这一版是真替换（两个调用点都改了），所以前提成立。

### 四、scope bar：顺序和高度都不能猜

```objc
self.searchBar.scopeButtonTitles = @[@"全部", @"未读"];
self.searchBar.selectedScopeButtonIndex = 0;
self.searchBar.showsScopeBar = YES;          // 🔴 必须在 scopeButtonTitles 之后
```

顺序反了在某些系统版本上 scope bar **根本不出现**。

高度不能拿 `sizeThatFits:` / `intrinsicContentSize` 去算 —— `UISearchBar` 是普通 `UIView`，
没布局时回 `(0,0)`，结果搜索框整个消失。直接写死：

```objc
CGFloat searchH = self.searchBar.showsScopeBar ? 88 : 44;
```

判据 `b02`（`showsScopeBar` 必须设）和 `b05`（高度必须跟着 `showsScopeBar` 变）就是钉这两条。

### 五、点开一条之后，「未读」列表里它得消失

`didSelectRowAtIndexPath:` 现在有三个分支：

| 条件 | 做法 | 为什么 |
|---|---|---|
| `unreadOnly` | 整表 `loadData` + **存/恢复 `contentOffset`** | 数量会变（少一行），必须重查；但要保住滚动位置 |
| 可变字典 | 只改 `read` + `reloadRowsAtIndexPaths:` | 数量不变 ⇒ 只刷一行，不丢滚动位置（v0.0.35 那条路） |
| 兜底 | `loadData` | 万一哪天 `query` 返回不可变字典 |

> 同一个 `reloadRowsAtIndexPaths:`，在"删一行"里是禁忌、在"只改一个字段"里是必需 ——
> 判据永远是**数量变不变**，不是"这个 API 好不好"。

### 六、源码判据（24 条）+ 反向对照

| 组 | 判据 | 说明 |
|---|---|---|
| a01~a04 | `.h` 有 `unreadOnly` 参数 / `query` 实现**真的用到**它 / `bundlesWithUnread` 有体 / **所有调用点都传了新参** | 查询层 |
| b01~b05 | `scopeButtonTitles` / `showsScopeBar` / **两者顺序** / `loadData` 把 `unreadOnly` 传下去 / 高度跟着变 | scope bar |
| c01~c07 | 红点记进 `unreadDots` / 挂 **holder** 不挂按钮 / 「全部」不点红点 / `refreshUnreadDots` 只改 hidden / `reloadIconBar` 存恢复 contentOffset / `didSelect` 的 `unreadOnly` 分支 / v0.0.35 的"同步内存"分支还在 | 红点 |
| d01 | 空列表写当前筛选条件 | 防"看着空 = 没有" |
| e01~e05 | 详情页 / 左滑删除顺序 / `sqlite3_changes` / `prepareForReuse` 复位 / 版本号 6 处 | 回归 |
| f01 / v01 | 版本串出现次数 / 括号配平（剥字符串） | — |

**负向自测 24/24 全红**。**反向对照**拿 v0.0.35 的 18 个文件喂进去，**16 条当场报红**：

```
a01 a02 a03 a04  b01 b02 b04 b05  c01 c02 c03 c04 c05 c06 c07  d01
```

### 七、包级判据（27 条）

| 组 | 判据 | 说明 |
|---|---|---|
| A1~A4 | control / 文件名 / tweak `v0.0.36` / App `Info.plist` | — |
| **B1** | 🔴 **App 二进制 md5 与 v0.0.35 不同** | 硬证据 |
| B2 | App 二进制大小 —— **只作记录** | 见下 |
| B3 | 有四参选择器 `queryWithBundle:since:search:unreadOnly:` | 未读筛选接到查询层 |
| B4 | **三参选择器消失了** | 前提见 §三 |
| B5 | 有 `bundlesWithUnread` | 红点的数据源在 |
| B6 | 有 `refreshUnreadDots` | 只刷红点那条路在 |
| B7 | 同时有 `setScopeButtonTitles:` 与 `setShowsScopeBar:` | scope bar 真的配上去了 |
| B8 | 有 `setSelectedScopeButtonIndex:` | 默认停在「全部」 |
| B9 | 有 `setContentOffset:` | 图标栏滚动位置的存/恢复编进去了 |
| B10 | 有「只看未读」「全部状态」（**弱**） | 只能证空列表文案在 |
| B11 | 有「当前筛选」（**弱**） | 只能证格式串在 |
| C1 | tweak 无 `v0.0.35` 显示串 | 防"只改版本号" |
| D1~D11 | 详情页类 / `deleteRow:` / `viewDidLayoutSubviews` / `setUnread:` / `dotView` / 清空二次确认 / `soundDuckOthers` / `commitMaxSec:` / `releaseAudioSessionIfIdle` / `maxSec` / 包内文件集合一致 | 前七版没被带坏 |

**反向对照**（拿 v0.0.35 的 deb 当"当前成品"）：**12/27 通过**，**15 条变红**
（`A1~A4`、`B1`、`B3~B11`、`C1`）。存活的 12 条 = `B2`（记录项）+ `D1~D11`（回归保留项）。

### 🔴 八、本版抓到的新坑：选择器"在包里"不等于"我们实现了它"

我本来想用 `searchBar:selectedScopeButtonIndexDidChange:` 当"scope 切换回调真的实现了"的判据。
做反向对照时发现：**v0.0.35 没实现这个方法，但它的二进制里也有这个串。**

直接扒上下文：

```
…scrollViewWillEndDragging:withVelocity:targetContentOffset:/0
searchBar\0
searchBar:selectedScopeButtonIndexDidChange:/0
searchBar:shouldChangeTextInRange:repla…
```

一大块 UIKit delegate 选择器连在一起 —— 它来自 `#import <UISearchBarDelegate>` 的
**协议方法表**，不是我们的实现。

> 🔴 通则：判据要选「**只有我们发消息 / 只有我们实现才会出现**」的选择器。
> 凡是**协议里的方法名**（`UITableViewDelegate`、`UIScrollViewDelegate`、`UISearchBarDelegate` 的那一堆），
> 一律不能单独当判据 —— 编译器会把整套协议方法名列进二进制。
> 这一条只有负向对照能发现：正向永远是绿的。

### 🔴 九、判据标签说错了它能证明什么（第一种假绿）

`B7` 原来写的是：

```python
need(has_str(app_bin, '只看未读'), 'B7 App 里有「只看未读」文案（scope bar 那一段在）')
```

两处都错：

1. **「只看未读」不在 scope bar 里** —— 它在 `ViewController.m:651`，是**空列表筛选描述**的字面量
   （scope bar 的按钮标题是 `@"全部"` / `@"未读"`，两个字符太短，包级没法当判据）；
2. 就算它真在 scope bar 里，**"搜到某个字"也只能证那句文案编进去了**，证不了 bar 配上了没有。

改成硬判据：

```python
need(has_selector(app_bin, 'setScopeButtonTitles:') and has_selector(app_bin, 'setShowsScopeBar:'), ...)
```

原来的查词退成 `B10` / `B11`，标签如实写成「⚠️ **弱**：只能证文案编进去了」。

> 这正是 v0.0.34 记的第一种假绿（**查词的存在性**）又冒了一次头。
> 这次的新意是：**假绿不一定来自"判据太松"，也可能来自"标签过度声称"** ——
> 判据本身没错（那句话确实在包里），错的是我以为它能证明 scope bar。

### 🔴 十、大小又是 +16 字节（第五次）

| | v0.0.35 | v0.0.36 |
|---|---|---|
| App 二进制 | `350336 B` | `350352 B` ← **又是 +16** |
| App md5 | `4345c9b74bee` | `d37555ee9efb` |
| tweak md5 | `15f5c4a24155` | `920a86803de7`（只改版本串） |
| 实际改动 | — | **7 文件 +163 / −17** |

改了 163 行、新增 2 个方法、4 个属性、七八条文案、一整个 scope bar，
二进制涨 **16 字节**。第 5 次了（v0.0.28 / 32 / 34 / 35 / 这次）。

> 判"编进去没"看串 / 选择器 / md5，**永远不看文件大小**；
> 反过来也成立：**"大小几乎没变"绝不等于"改动很小"**。

### 十一、交付

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.36_iphoneos-arm64e.deb` · **107920 B** |
| CI | **#72**（`run_id 40088538309`，head `bc68aab1f59e`）success，一次编译过 |
| 产物 zip | 108107 B（与 API `size_in_bytes` 对拍一致） |
| 远端 | `bc68aab1f59e` = 本地 `03650962167b`，**7 个改动文件逐 blob 一致** |
| 改动 | 7 文件 **+163 / −17** |
| App 二进制 | `350336 → 350352 B`（+16，md5 变） |
| tweak 二进制 | `143856 B`（只升版本串） |
| 源码判据 | 24 条语义 + 24 条负向全红；反向对照 16 条红 |
| 包级判据 | 27 条全绿；反向对照 15 条红 |

### 十二、装了这一版要验什么

| # | 操作 | 期望 |
|---|---|---|
| 1 | 打开盒子看顶部图标栏 | 有**未读**的 App 右上角有**小红点**，全部读过的没有 |
| 2 | 🔴 **「全部」那一格** | **不能有红点** —— 有就是坑 3 或"全部也点了" |
| 3 | 🔴 横向滚到第 8~10 个 App，点开一条记录，返回 | 图标栏**还在原来的位置**（不弹回最左）；那个 App 的红点消失 |
| 4 | 点搜索框 | 下面出现 `全部 / 未读`，默认选中「全部」，**搜索框没被挡住、图标栏没被挤掉** |
| 5 | 切到「未读」 | 列表只剩未读的；标题计数跟着变 |
| 6 | 在「未读」下点开一条，返回 | 那一条**从列表里消失了**（已读）；列表**不跳回顶部** |
| 7 | 🔴 时间选「今天」+ 切「未读」 | 如果真没有，空列表要写出**当前筛选条件**，不能只写「暂无记录」 |
| 8 | 全部读完后回列表 | 图标栏红点全部消失 |
| 9 | 回归：清空（含搜索态）、删单条、详情页、左滑删除、按 App 配时长、压低开关 | 与 v0.0.35 一致 |

> 第 2、3 条是这一版**最容易做错且最不容易被发现**的两件事：
> 第 2 条错了不会崩，只是红点语义混乱；第 3 条错了会让人想摔手机（每点一条，图标栏就归位一次）。
> 第 7 条是 v0.0.35「看着空 = 没有」那个坑的续集 —— 加了「未读」之后空列表变得非常常见。

## v0.0.37 · 修「有红点却暂无记录、红点消不掉」+ 未读筛选换成自己的分段控件

这一版是**真机打回来修的**。用户一句话报了三个问题：

> 「app 暂无记录，红点也没消失」
> 「然后没看到未读，已读这些字眼啊」

### 一、问题 1：搜索框下面的「全部 / 未读」根本没出现

v0.0.36 用的是系统 scope bar：

```objc
self.searchBar.scopeButtonTitles = @[@"全部", @"未读"];
self.searchBar.selectedScopeButtonIndex = 0;
self.searchBar.showsScopeBar = YES;      // 顺序也是对的：先 titles 再 shows
```

**代码本身没错**，网上流传的"顺序坑"也避开了 —— 但真机 iOS 16 上这一行 scope bar
**就是没渲染**。包级判据当时是绿的（`setScopeButtonTitles:` / `setShowsScopeBar:`
三条 setter 消息确实在二进制里），也就是说：

> 🔴 **"我们真的给 UISearchBar 发了这条消息" 和 "系统真的把它画出来了" 是两件事。**
> 前者能在包里验，后者在没有 Mac / 调试器的条件下验不了。

结论很直接：**不再赌系统内部布局**。同一屏里「近24小时 / 近7天 / 不限时间」这个
`UISegmentedControl` 一直是好的，那就用同一种控件：

```objc
self.unreadSeg = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"只看未读"]];
```

顺手还去掉了两处隐患：

- 搜索框高度不再 `showsScopeBar ? 88 : 44` 地赌，回到固定 44；
- 不再有"scope bar 到底占没占位"这种只能靠眼睛判断的问题。

### 二、问题 2：有红点、点进某个 App 却「暂无记录」、红点还消不掉

这是这一版最值得记的一条 —— **两个数的口径不一样，用户就被夹在中间**。

| 量 | 用的范围 |
|---|---|
| 列表（`queryWithBundle:…since:…`） | `sinceFromSeg` 之后 |
| 红点（`bundlesWithUnread`） | **全库，不看时间** |

于是最糟的那个组合出现了：

> 某个 App 的未读是**更早**的记录 → 列表按时间窗查，空的 → 用户看不到那些未读 →
> 点开也永远不会把它们标成已读 → **红点永远消不掉**。

> 🔴 一个用户**清不掉的提示**，比不打这个提示更糟：它从"提醒"变成了"故障"。

修法是让红点用**和列表同一个时间窗**：

```objc
+ (NSSet<NSString *> *)bundlesWithUnreadSince:(NSTimeInterval)since;   // since<=0 = 全库
```

两处红点查询（`reloadIconBar` / `refreshUnreadDots`）都改成
`bundlesWithUnreadSince:[self sinceFromSeg]`。这样红点的不变式变成：

> **红点亮 ⇒ 点进去一定能看到未读 ⇒ 看完了红点一定灭。**

另外空列表主动说一句：如果全库还有未读、只是被时间挡住，
就写「⚠️ 还有更早的未读记录，被时间筛选挡住了 —— 把时间切到「不限时间」就能看到」。
（红点已经不亮了，这句是防止用户以为记录丢了。）

### 三、问题 3：有个标签在说谎

时间第 0 段一直叫「今天」，但 `sinceFromSeg` 返回的是：

```objc
if (self.timeSeg.selectedSegmentIndex == 0) return now - 86400;   // 最近 24 小时！
```

今天 19:30 的时候，「今天」会把**昨天 19:30 之后**的记录也算进来。

> 🔴 标签和实现不一致的代价，是用户没法用这个筛选去做判断 ——
> 他以为自己在看"今天"，实际看的是"最近 24 小时"。

行为没错（24 小时窗口其实更实用），所以**改标签不改行为**：「今天」→「近24小时」。
判据要求三处一致：`timeSeg` 的 items、`filterDesc` 里的名字数组、
`sinceFromSeg` 的注释，并且代码里不许再有裸的 `@"今天"`。

### 四、判据

**源码 33 条全绿**：

| 组 | 判据 |
|---|---|
| a01~a03 | 代码里**不再有** `scopeButtonTitles` / `showsScopeBar` / `selectedScopeButtonIndexDidChange` |
| a04~a08 | 建了「全部 / 只看未读」分段控件 / 接了 `onUnread:` / 排了位置 / 搜索框回到 44 / 布局里不再出现 88 |
| a09~a10 | `onUnread:` 真映射成 `unreadOnly` / 真走 `loadData` |
| b01~b06 | **两处**红点查询都吃 `sinceFromSeg` / SQL 里真拼了 `ts>=?` / 真的 bind 了 / 无参版转调 `since:0` / `.h` 有声明 |
| c01~c03 | 段名、`filterDesc` 名字、无裸 `@"今天"` |
| d01~d03 | 空列表查全库做对照 / 有"切到不限时间"引导 / 只在非"不限时间"时提示 |
| e01~e08 | 前七版能力回归（蓝点、holder、`sqlite3_changes`、四参查询…） |
| f01~f03 | 版本 6 处 / 旧版本串消失 / 括号配平（剥字符串） |

**负向变异 10/10 全被抓住**：把 scope bar 加回来、只给一处红点上时间窗、
SQL 漏拼时间条件、拼了占位符不 bind、`filterDesc` 名字变回「今天」、
空列表不提示、不给 `unreadSeg` 排位置、`prepareForReuse` 不复位蓝点、
`onUnread:` 不走 `loadData`、搜索框高度写回 88。

**反向对照**（v0.0.36 源码）：**24 条当场报红**。

### 🔴 五、判据自己踩了两个坑

**坑 1 · 取函数体取到了别人的。**
写 `body(src, r'- \(void\)onUnread:')` 之后，我先 `find('{')` 再配平 —— 结果命中的是
**类扩展里的原型声明** `- (void)onUnread:(UISegmentedControl *)seg;`，
`find('{')` 一路找到**下一个**方法的 `{` ⇒ 判据读到别人的函数体 ⇒ `a09`/`c02` 假红。

> 修法：让正则**必须**在本签名之后、遇到 `;` 之前就吃到 `{` —— `[^;{]*\{`。
> 通则：**取函数体的正则要能区分「声明」和「实现」**，否则判据会安静地读错地方。

**坑 2 · 变异锚点重名，变异被 SKIP 而我还以为验过了。**
`self.dotView.hidden = YES;` 在 `NotifyCell.m` 里出现**两次**（`init` 里也有一处），
锚点只写这一句 ⇒ 变异框架报 SKIP ⇒ **这条判据其实从没被验证过**。

> 修法：锚点带上 `prepareForReuse` 收尾处独有的那行注释。
> 🔴 **SKIP 必须算失败**，不能算通过 —— 否则"10 条变异全过"里有 1 条是假的。

### 六、包级判据（29 条）

这一版的包级判据**少见地硬**，因为它一半是"删东西"：

| 组 | 判据 | 说明 |
|---|---|---|
| A1~A4 | control / 文件名 / tweak 版本串 / App `Info.plist` | — |
| **B1** | 🔴 App md5 与 v0.0.36 不同 | 硬证据 |
| B2 | App 大小**只作记录** | 又是 350352 B，**一字节没动**（第六次） |
| **B3~B5** | 🔴 `setShowsScopeBar:` / `setScopeButtonTitles:` / `setSelectedScopeButtonIndex:` **全部消失** | 证明系统 scope bar 是真拆了，不是新旧并存 |
| B6~B7 | 新增 `bundlesWithUnreadSince:` / `onUnread:` | 自研选择器 |
| B8~B9 | 有「近24小时」/ **没有**「今天」 | 标签修正真的编进去了 |
| B10 | 有「只看未读」（⚠️ **弱**：旧版空列表文案里也有，不具区分力） | 只作记录 |
| B11 | 有「被时间筛选挡住了」 | 空列表引导在 |
| C1 | tweak 无 v0.0.36 显示串 | — |
| D1~D13 | 详情页 / `deleteRow:` / 布局入口 / `setUnread:` / `dotView` / 清空二次确认 / `refreshUnreadDots` / 四参查询 / `soundDuckOthers` / `commitMaxSec:` / `releaseAudioSessionIfIdle` / `maxSec` / 包内文件集合 | 前七版没被带坏 |

**反向对照**（拿 v0.0.36 的 deb 当"当前成品"）：**15/29 通过**，**14 条变红**
（`A1~A4`、`B1`、`B3~B9`、`B11`、`C1`）。存活的 = `B2`（记录项）+ `B10`（弱）+ `D1~D13`（回归）。

#### 🔴 又一次踩到"协议方法表不能当判据"

这次本来想用 `searchBar:selectedScopeButtonIndexDidChange:` 当"系统 scope bar 拆干净了"的佐证。
一验：**v0.0.36 和 v0.0.37 的二进制里都有** —— 它来自 `#import <UISearchBarDelegate>`
的协议方法表，跟我们的实现无关。（v0.0.36 就已经记过这条。）

> 所以取证的落点是那三条 **setter**（`setShowsScopeBar:` 之类）：只有我们主动发消息才会出现，
> 我们不发了它就真没了。判据要选「**只有我们发消息 / 只有我们实现才会出现**」的选择器。

#### 🔴 大小一字节没动（第六次）

| | v0.0.36 | v0.0.37 |
|---|---|---|
| App 二进制 | `350352 B` | `350352 B` ← **一字不差** |
| App md5 | `d37555ee9efb` | `9dd8124414bd` |
| tweak md5 | `920a86803de7` | `a1e119b9c7d8`（只改版本串） |
| 改动 | — | **6 文件 +86 / −33** |

删了一整个 scope bar、加了一个分段控件、加了 `bundlesWithUnreadSince:` 和 `onUnread:`
两个方法、改了三处文案 —— **文件大小一个字节都没变**。

第 6 次了（v0.0.28 / 32 / 34 / 35 / 36 / 这次）。通则不变：
**判"编进去没"看串 / 选择器 / md5，永远不看文件大小。**

### 七、交付

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.37_iphoneos-arm64e.deb` · **108234 B** |
| CI | **#74**（`run_id 40093264560`，head `ee2fb9a37735`）success，一次编译过 |
| 产物 zip | 108419 B（与 API `size_in_bytes` 对拍一致） |
| 远端 | `ee2fb9a37735` = 本地 `eb4f071049ae`，**6 个改动文件逐 blob 一致** |
| 改动 | 6 文件 **+86 / −33** |
| App 二进制 | `350352 → 350352 B`（**大小不动**，md5 变） |
| 源码判据 | 33 条全绿；负向变异 10/10；反向对照 24 条红 |
| 包级判据 | 29 条全绿；反向对照 14 条红 |

### 八、装了这一版要验什么

| # | 操作 | 期望 |
|---|---|---|
| 1 | 🔴 打开盒子 | 搜索框下面有一条 **`全部 / 只看未读`**，默认选中「全部」 |
| 2 | 时间分段 | 三段是 **近24小时 / 近7天 / 不限时间**（不再是「今天」） |
| 3 | 🔴 **点某个有红点的 App 图标** | 要么**看得到未读记录**，要么**红点本来就不该亮** —— 不能再出现"红点亮着但列表暂无记录" |
| 4 | 🔴 列表空时看提示 | 如果全库还有更早的未读，要有「⚠️ 还有更早的未读记录，被时间筛选挡住了…」 |
| 5 | 切到「不限时间」 | 更早的记录出现；点开它们 → 对应红点消失 |
| 6 | 切「只看未读」 | 只剩未读；点开一条返回 → 它从列表消失、列表**不跳回顶部** |
| 7 | 回归：顶部图标栏横向滚动位置、详情页、左滑删除、清空（含搜索态）、按 App 配时长、压低开关 | 与 v0.0.36 一致 |

> 第 1 条是这一版的主修（系统 scope bar 在 iOS 16 上不渲染）。
> 第 3、4 条是"红点消不掉"那个病的验收：**判据不是"红点没了"，而是"红点和列表不再互相矛盾"**。
## v0.0.38 · 列表会自己更新了 +「只看未读」下能一次全标已读

v0.0.37 真机确认通过之后（用户：「可以了」），这一版是我扫了一遍代码挑出来的两个缺口，
让用户从候选里选的。选的是 **A+B 一起交付**：

| 候选 | 用户能不能感知 |
|---|---|
| **A 列表不会自己更新** | 能。后台来通知 → 点进盒子还是老样子，得手动切一下筛选或搜索才刷新 |
| **B「只看未读」下没有批量入口** | 能。积了 50 条未读只能一条条点开 |
| C `markRead:` 还在拼 SQL | 不能（整数无注入面），顺手清 |
| D `hash` 字段是死代码 | 不能。**故意不动** —— 删列要改 schema + 迁移，风险远大于收益 |
| E 图标栏没有「更早也有未读」的提示 | 半能。v0.0.37 只在**空列表**里补了引导 |

> 顺手改的还有一处：**时间段的段名原来写了两份**（`buildUI` 里一份、`filterDesc` 里一份）。
> v0.0.36 的「今天」名不符实，根子就是"两处写同一个数组，改一处漏一处"。
> 这版抽成 `timeNames`，全文件只有一处字面量。

### 一、A：列表自动更新的三个坑

刷新动作本身很简单，难的是**在哪儿刷**和**怎么判断该不该刷**。

#### 坑 1：不能在 `viewWillAppear:` 里直接 `loadData`

`ViewController.m` 里 v0.0.35 就写着这段注释：

```objc
// 🔴 为什么不在 `viewWillAppear:` 里 `loadData`（这是最容易想到的做法）：
//    整表 reload 会让**滚到中间点开一条再返回，列表跳回顶部** —— 真机上一碰就发现。
```

所以这版没有推翻它，而是把 `didSelectRow:` 里已经在用的那套「存 `contentOffset` →
重查 → `layoutIfNeeded` → 恢复」抽成一个方法：

```objc
- (void)reloadKeepingOffset {
    CGPoint off = self.table.contentOffset;
    [self loadData];
    [self.table layoutIfNeeded];
    CGFloat maxY = MAX(0, self.table.contentSize.height - self.table.bounds.size.height);
    self.table.contentOffset = CGPointMake(0, MIN(off.y, maxY));
}
```

`viewWillAppear:` 里调的是 `refreshIfChanged`，它只在库里真的变了时才转调上面那个：

```objc
- (void)refreshIfChanged {
    NSInteger total = [NotifyStore count];
    NSInteger topId = [NotifyStore maxRowId];
    if (total == self.lastTotal && topId == self.lastMaxId) return;
    [self reloadKeepingOffset];
}
```

> `layoutIfNeeded` 不能省：少了它 `contentSize` 还是旧值，clamp 会按旧高度算，
> 结果位置照样错。判据里专门有一条盯这个调用顺序（a13）。

#### 坑 2：只看 `count` 会漏掉最该刷新的场景

这是这一版唯一一个"不写下来下次一定还会犯"的点：

> **记录数到达上限之后，tweak 每来一条新通知都会先裁掉一条最旧的 ⇒ 条数恒定不变。**
> 只看条数的话，`count == lastCount` 恒成立 ⇒ **库满之后列表永远不会自己更新**。
> 而"库满了还在收通知"恰恰是最常见的状态。

所以加了 `+ (NSInteger)maxRowId`（`SELECT IFNULL(MAX(id),0)`），两个数一起看：

- 新增记录 ⇒ `MAX(id)` 变大
- 删除记录 ⇒ `count` 变小
- 库满时来新通知 ⇒ 条数不变、`MAX(id)` 变大 ✅

`IFNULL` 是为了让"空表 = 0"在 SQL 里就说清楚，而不是靠 C 层读 NULL 恰好也是 0 的巧合。

#### 坑 3：App 回前台**不走** `viewWillAppear:`

VC 一直活着，只是 window 换了前台。只加 `viewWillAppear:` 的话，
"后台来通知 → 切回 App → 列表还是老的"这个场景一点没治。所以另外听一个通知：

```objc
[[NSNotificationCenter defaultCenter] addObserver:self
                                         selector:@selector(onForeground:)
                                             name:UIApplicationWillEnterForegroundNotification
                                           object:nil];
```

`dealloc` 里 `removeObserver:self`（iOS 9 起已经自动了，写出来是为了让读代码的人不用查版本）。

#### 库指纹在哪儿记

必须在 `loadData` 的查询**之后**：

```objc
self.lastTotal = total;
self.lastMaxId = [NotifyStore maxRowId];
```

指纹的语义是「这一屏列表现实对应库里的哪个状态」。记早了就等于把还没进列表的新记录
算进去了 ⇒ 下次永远比不出差异。判据 a14 盯的就是这个先后。

### 二、B：「全标已读」的口径一致性

#### 按钮为什么放在分段控件同一行

导航栏右边已经有「诊断」「清空」两个，再塞一个会把标题「消息盒子 (N)」挤没。
「只看未读」时把 `unreadSeg` 收窄、右侧腾出 `kNBMarkAllWidth`（88pt）给按钮；
「全部」模式下按钮 `hidden`，分段控件恢复占满整行（和 v0.0.37 一致）。

「全部」模式下**不显示**这个按钮是有意的：那时列表里已读未读混在一起，
"全标已读"的作用对象不明确（是这一屏？是整个库？），很容易被当成"清空"。

#### 确认框的数字必须等于实际改动的行数

v0.0.35 的 `onClear:` 栽过一次：确认框报列表的 3 条、实际清整张表 2000 条。
这次两边由**同一个函数**产出条件：

```objc
// NotifyStore.m —— 拼 WHERE 和绑参在同一个函数里，顺序不可能错
static sqlite3_stmt *NBPrepareUnreadScope(sqlite3 *db, NSString *sqlHead,
                                          NSString * _Nullable bundle, NSTimeInterval since) {
    NSMutableString *sql = [NSMutableString stringWithString:sqlHead];
    if (bundle.length) [sql appendString:@" AND bundle=?"];
    if (since > 0) [sql appendString:@" AND ts>=?"];
    ...
}
```

| 用途 | 方法 | SQL |
|---|---|---|
| 确认框报数字 | `unreadCountWithBundle:since:` | `SELECT COUNT(*) … WHERE read=0` + 共享条件 |
| 真正改动 | `markAllReadWithBundle:since:` | `UPDATE … SET read=1 WHERE read=0` + 共享条件 |

拼条件与绑参**故意写在同一个函数里**：拆成「拼一个函数、绑一个函数」就有两边顺序不一致的可能，
而这类错不会报错，只会静默少筛一个条件。

`markAllRead` 查 `sqlite3_changes`（`UPDATE … WHERE read=0` 命中 0 行照样返回 `SQLITE_DONE`，
不查 changes 就会把"什么都没改"报成成功）。

#### 搜索词**不**参与标记范围

这是本版第二处"口径"问题。用户搜「验证码」时列表只显示 3 条，
如果标记范围也跟着搜索走，`SQL` 里就得多一个 `LIKE`；如果跟着走但不说，用户会以为"只标这 3 条"。

选择：**标记范围只按 App + 时间**，搜索只影响列表显示，并**在确认框里写明**：

```objc
if (self.searchText.length) {
    [msg appendFormat:@"\n\n⚠️ 搜索框里的「%@」只影响列表显示，不限制标记范围。", self.searchText];
}
```

同理，范围描述用的是 `scopeDesc`（只含 App + 时间），**不是** `filterDesc`（含未读状态和搜索词）。
判据 d05 专门盯这一条：`scopeDesc` 里出现 `searchText` 就报红。

### 三、顺手清：`markRead:` 不再拼 SQL

v0.0.33 在 `deleteRow:` 上写过这段注释：

```objc
// 🔴 用参数绑定而不是拼 SQL：rowId 虽然来自数据库（整数、无注入面），
//    但这里保持和 queryWithBundle 同一口径 —— 一处拼串、一处绑参，
//    以后有人把某个参数换成字符串时就会在拼串那处出事。
```

而 `markRead:` 一直是 `stringWithFormat` 拼的 —— 同文件里注释和代码自相矛盾了五版。
现在改成 `UPDATE notifications SET read=1 WHERE id=?` + `sqlite3_bind_int64`。
不是因为 rowId 有注入面（它没有），而是因为"按 id 改一行"这件事在本文件里应该只有一种写法。

### 四、源码判据

`nb_v038_src_check.py`：**72 条**判据，正向 / 反向对照 / 负向变异**同一份文件、同一批判据**。

| 跑法 | 结果 |
|---|---|
| 正向 | **72/72 通过** |
| 负向变异（22 条，逐条把语义改坏） | **22/22 全被抓住** |
| 反向对照（拿 v0.0.37 的 `d47d9dc` 喂进同一批判据） | **报红 58 条** |

反向对照存活的 14 条全是**回归组**（`e01~e12` 是 v0.0.32~v0.0.37 的行为，本来就该在旧版上也绿）
加 `d08`（`filterDesc` 区分只看未读 —— v0.0.36 就有）和 `f03`（括号配平）。

这一版判据自身踩的坑（都记在脚本注释里）：

1. **`a07` 假红**：通知注册的形参叫 `selector:`，我照 UIButton 的写法写成 `action:`。
2. **`f02` 期望本身错了**：我写「旧版本串必须从 Tweak.x 消失」，但 Tweak.x 首行**有意**保留了
   「上一版 v0.0.37：…」—— 这版 tweak 侧没改逻辑，不写清楚的话以后看到 v0.0.38 的日志
   会以为 tweak 也动了、白查一轮。按纪律**改期望不改判据**：改成"旧版本号只许出现在『上一版』那几行"。
3. **三条变异锚点重名被 SKIP**：`if (since > 0) [sql appendString:@" AND ts>=?"];` 在
   `bundlesWithUnreadSince:`（226 行）和 `NBPrepareUnreadScope`（296 行）里逐字相同。
   这正是 v0.0.37 立的「**SKIP 必须算失败**」规矩抓到的 —— 锚点改成两行连排才唯一。
4. **`a14` 的变异设计错了**：我原本只交换了 `lastTotal` / `lastMaxId` 两行的顺序，
   而那两行都还在查询之后 ⇒ 判据当然不红。改成"真的挪到 `loadData` 开头"才测到东西。
5. **`b10` 判据太弱**：原本只判"两个方法都调了共享函数"，而实参写成 `nil, 0`（等于全库全时间）
   照样能过。改成连实参一起判，同时发现正则少写了一个 `)`（`bundle, since);`）⇒ 假红。
6. **两条空洞通过**：`a03`/`d05` 是否定式判据（`'x' not in body`），而旧版里那两个方法
   根本不存在 ⇒ 函数体是空串 ⇒ `not in ''` 恒为真 ⇒ 反向对照里假绿。
   修法：否定式判据一律带前置 `vwa and …` / `sd and …`。

### 五、装了这一版要验什么

| # | 操作 | 期望 |
|---|---|---|
| 1 | 🔴 **切「只看未读」** | 分段控件右侧出现 **`全标已读`** 按钮；切回「全部」它消失、分段控件恢复占满整行 |
| 2 | 🔴 点「全标已读」 | 弹确认框，文案里报**条数**和范围（App + 时间段）；点取消什么都不变 |
| 3 | 🔴 确认后 | 弹出「把 N 条标成了已读」；列表变空并写出「当前筛选」；**对应图标栏红点全部消失** |
| 4 | 在「只看未读」下先搜索再点「全标已读」 | 确认框里要出现「⚠️ 搜索框里的「…」只影响列表显示，不限制标记范围」 |
| 5 | 🔴 **列表滚到中间 → 退到后台 → 来一条新通知 → 切回 App** | 列表**自己出现新记录**，且**当前可见位置不动**（不会跳回顶部） |
| 6 | 🔴 滚到中间 → 点开一条 → 返回 | 位置仍然不动（这是老行为，别被第 5 条带坏） |
| 7 | 列表滚到中间 → 进「设置」→ 返回 | 位置不动，且列表内容是最新的 |
| 8 | 没有任何新通知时切回 App | 列表**不重绘、不闪** |
| 9 | 回归：时间分段、搜索、详情页、左滑删除、清空（含搜索态）、顶部图标栏横向滚动位置、按 App 配时长、压低开关 | 与 v0.0.37 一致 |

> 第 5 条是这一版的主修。判据不是"刷新了没有"，而是**"刷新了但位置没跳"** ——
> 这两个要求是会打架的（整表 reload 必然清零 offset），所以必须一起验。
> 第 8 条同样重要：只判"变了会刷"不够，还要判"没变不刷"，否则每切一次 App 就闪一下。
> 第 4 条是"两个指标同口径"那个病的验收 —— 判据不在"标了几条"，而在**"说的和做的是不是同一批"**。

### 六、交付记录

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.38_iphoneos-arm64e.deb` · **110198 B** |
| CI | **#76**（`run_id 40095651248`，head `51249b8eb050`）success，一次编译过 |
| 产物 zip | 110386 B（与 API `size_in_bytes` 对拍一致） |
| 远端 | `51249b8eb050` = 本地 `bcae9de`，**6 个改动文件逐 blob 一致** |
| 改动 | 6 文件 **+337 / −25** |
| App 二进制 | `350352 → 350576 B`（**+224**，md5 `9dd8124 → 67da260`） |
| tweak dylib | `160528 B`（本版 tweak 只改版本号，逻辑未动） |
| 源码判据 | 72 条全绿；负向变异 22/22 全抓住；反向对照（`d47d9dc`）58 条红 |
| 包级判据 | 44 条全绿；反向对照 20 条红 |

> 反向对照的 20 条红分布很说明问题：`A1~A5`（版本）+ `B1`（md5）+ **`B3~B16` 一条不漏**。
> B 组就是这一版新增的 14 个自研选择器 / 文案 —— 全部在旧包里不存在，全部在旧包上当场报红。
> 这比"正向全绿"更能说明判据有效：**正向绿可能是因为判据太松，反向红不可能。**
>
> 存活的 24 条也都有解释：`C1~C6` 是"旧包里必须没有"的判据（在旧包上当然绿），
> `D1~D17` 是回归项（本来就该在两版上都绿）。
>
> 顺便记一笔：撞了六次「二进制大小与改动量完全脱钩」之后，这次 350352 → 350576 真的涨了 224 B。
> **但这不说明下次可以靠大小判断** —— 判据永远是选择器 / 串 / md5。

## v0.0.39 · 「更早还有未读」不再是个哑洞 + 删掉一个死的公开 API

v0.0.38 真机确认通过后继续往下走。这一版只干一件正事，但它是 v0.0.37 那个修复**自己造出来的**洞。

### 一、洞是怎么来的

v0.0.37 把红点从「全库口径」改成「**当前时间窗口径**」—— 这一步是对的，不然会出现
「红点亮着 → 点进去暂无记录 → 红点永远消不掉」（用户清不掉的提示，比不打更糟）。

但改完之后留下一个信息空洞：

> 时间选「近24小时」，当前时段内**一条未读都没有**，而更早还有 12 条未读。
> 此时：**红点全灭** + 列表不空（里面可能是已读记录）⇒ **界面上一个字都不提示**。
> 用户理所当然地断定"全都读完了"，那 12 条从此永远不会被看到。

v0.0.37 只在**空列表**里补了那句提示（`updateEmptyView`），所以这个洞精确地是
「**列表非空时一个字都没有**」。

### 二、这个数怎么算（三处判据都要紧）

```objc
- (void)updateOlderUnread {
    NSTimeInterval since = [self sinceFromSeg];
    NSInteger inWin = [NotifyStore unreadCountWithBundle:self.filterBundle since:since];
    self.olderUnread = 0;
    if (inWin == 0 && since > 0) {
        NSInteger all = [NotifyStore unreadCountWithBundle:self.filterBundle since:0];
        if (all > 0) self.olderUnread = all;
    }
    ...
}
```

| 判据 | 为什么必须是它 |
|---|---|
| `inWin == 0` | 窗口内**本来就有**未读时红点亮着，再喊"更早还有"只是噪音。写成 `>= 0` 会变成**恒真**（变异测试专门盯这条） |
| `since > 0` | 「不限时间」时 `inWin` 就等于全库，再提示等于自己喊自己。判据落在 `since` 上，**不用** `selectedSegmentIndex != 2` —— 那种写法容易和 `sinceFromSeg` 走岔 |
| 先窗后全库 | 只在需要时才查第二次。`inWin > 0` 是最常见的情况，没必要每次都多查一次 |

没有新增任何数据库 API —— v0.0.38 加的 `unreadCountWithBundle:since:` 正好是这套查询的超集。

### 三、提示条为什么自己画、只占一行

```
⚠️ 更早还有 12 条未读 · 切「不限时间」看
```

它在「全部 / 只看未读」那一行下面、图标栏上面，12pt 灰字。

- **不放导航栏标题**：标题会被系统压缩/截断。v0.0.37 已经被系统 scope bar 教过一次
  —— 凡是"只能靠系统内部布局才出现/才放得下"的东西，都不赌。
- **不放分段控件里**：段宽是系统算的。
- **不显示时高度必须是 0**：`frame` 也要清零，不能只 `hidden = YES`。
  否则 `y` 已经加过了 ⇒ 图标栏和列表整体下移 24pt，肉眼极难归因。
- **文案必须带条数**：只说"还有更早的未读"用户不知道值不值得去切；说"还有 12 条"他才会动。

### 四、和空列表那句提示的分工

这是这一版最容易做错的一处：**不能两处都喊**。

```objc
BOOL showHint = (self.olderUnread > 0 && self.items.count > 0);
```

| 列表状态 | 谁来说 |
|---|---|
| 空 | `updateEmptyView`（屏幕正中，还带「当前筛选」和自检信息，v0.0.37 就有） |
| 非空 | 顶部提示条（**v0.0.39 新补的，就是那个洞**） |

同时把 `updateEmptyView` 里那句改成用**同一个量** `self.olderUnread`，
不再自己查一遍 `bundlesWithUnread` 集合 —— 同一个问题只算一次。

### 五、顺手清：`bundlesWithUnread` 是个死 API

它是「全库有未读的 App 集合」，唯一调用者就是上面那句空列表提示。
本版改成问「更早还有**多少条**」以后，它就没有调用者了 ——
而 `unreadCountWithBundle:since:` 是它的**超集**（能按 App + 时间段算，还给条数）。

所以删掉：

```objc
// .h 删
+ (NSSet<NSString *> *)bundlesWithUnread;
// .m 删（含转调那句）
+ (NSSet<NSString *> *)bundlesWithUnread { return [self bundlesWithUnreadSince:0]; }
```

> `bundlesWithUnreadSince:` **保留**（图标栏红点用它）。删的是不带参那个。
> 🔴 判据上这两者是**前缀关系**，用子串匹配会把"删掉了"误判成"还在" ⇒
> 包级判据必须精确到 `bundlesWithUnread\0`。

### 六、`reloadKeepingOffset` 的布局范围也升级了

从 `[self.table layoutIfNeeded]` 改成 `[self.view layoutIfNeeded]`。

原因：这一版起 `loadData` 可能让提示条出现/消失 ⇒ **table 自己的 frame 也变**
（起始 y 和高度都跟着变）。只给 table 做布局只更新它内部的 `contentSize`，
`bounds.size.height` 还是旧值 ⇒ clamp 会按旧高度算 ⇒ 滚到中间时位置多跳/少跳一截
（真机上看着就是"莫名其妙动了一下"）。

### 七、源码判据

`nb_v039_src_check.py`：**55 条**判据，正向 / 反向对照 / 负向变异**同一份文件同一批**。

| 跑法 | 结果 |
|---|---|
| 正向 | **55/55 通过** |
| 负向变异（15 条） | **15/15 全被抓住** |
| 反向对照（拿 v0.0.38 的 `fa11a05` 跑） | **报红 34 条** |

存活的 21 条全是回归组（`e04/e05` 是"Since 版仍在"，`f03` 是顺序，`g01~g17` 是历版行为，
`h03` 是括号配平）—— 本来就该在旧版上也绿。

这一版判据自身踩的两个坑（都记在脚本注释里）：

1. **`c09` 判据太松**：「`y += 20 + 4` 在 `if (showHint)` **之后**」，而把这一句挪到
   `if` 块**外面**照样满足"在后面" ⇒ 变异当场漏网。改成取**整块**锚点
   （`y += …;\n    } else {` 连续），挪出块外这个串就不存在了。
2. **`c10` 空洞通过**：原来写成 `'olderUnread' not in lay.replace(…)`，
   而 v0.0.38 的布局里根本没有这个量 ⇒ 恒真。改成**数引用次数**
   （布局里只该出现 1 次）—— 旧版 0 次报红、有人另写一处判定则 2 次报红。

### 八、装了这一版要验什么

| # | 操作 | 期望 |
|---|---|---|
| 1 | 🔴 时间选「近24小时」，当前时段**全部已读**、更早还有未读 | 「全部 / 只看未读」下面出现一行灰字 **`⚠️ 更早还有 N 条未读 · 切「不限时间」看`**，N 是真实条数 |
| 2 | 🔴 切到「不限时间」 | 提示条**当场消失**，图标栏和列表**整体上移回原位**（不能留着一条空白） |
| 3 | 切回「近24小时」 | 提示条回来，位置正确，**不压住图标栏** |
| 4 | 🔴 当前时段**有**未读时 | 提示条**不出现**（红点亮着，此时喊"更早还有"是噪音） |
| 5 | 🔴 列表**为空**时 | 顶部**不出现**提示条，走屏幕正中那句（带「当前筛选」+ 自检信息） |
| 6 | 列表非空 → 把当前时段的未读全部标已读 | 提示条**立刻出现**（不用重进 App） |
| 7 | 滚到中间 → 切时间让提示条出现/消失 | 可见位置不跳到顶部，也不"莫名其妙动一下" |
| 8 | 回归：自动更新（后台来通知回前台）、全标已读、详情页、左滑删除、清空（含搜索态）、按 App 配时长、压低开关 | 与 v0.0.38 一致 |

> 第 2、4、5 条是这一版的三个反向判据 —— **它们比第 1 条更重要**：
> 「该出现时出现了」容易做到，「不该出现时不出现」才是设计意图。
> 第 2 条还顺带验了 `frame` 清零：只 `hidden` 不清 frame 的话，列表会整体下移 24pt 且**永不复原**。

### 九、交付记录

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.39_iphoneos-arm64e.deb` · **110250 B** |
| CI | **#78**（`run_id 40097267047`，head `62178fdb16b5`）success，一次编译过 |
| 产物 zip | 110441 B（与 API `size_in_bytes` 对拍一致） |
| 远端 | `62178fdb16b5` = 本地 `63db0c9`，**6 个改动文件逐 blob 一致** |
| 改动 | 6 文件 **+110 / −24** |
| App 二进制 | `350576 → 350592 B`（**+16**，md5 `67da260 → a57d442`） |
| tweak dylib | `160528 → 143936 B`（**−16592**，见下） |
| 源码判据 | 55 条全绿；负向变异 15/15 全抓住；反向对照（`fa11a05`）34 条红 |
| 包级判据 | 43 条全绿；反向对照 13 条红 |

**包级反向对照的 13 条红**：`A1~A5`（版本）+ `B1`（md5）+ `B3~B8`（新增的选择器/文案）+
**`C1`**。`C1` 是这一版最值得看的一条：

> `C1` = 「`bundlesWithUnread\0` 必须从 App 二进制里**消失**」。
> 拿 v0.0.38 的 deb 跑同一批，它当场报红 —— 说明这条判据**真的在量"删没删"**，
> 不是那种"两边都绿"的空判据。配套的 `C3` 还专门反向自检了一次
> （「旧包里**有** `bundlesWithUnread`」），证明这个量不是永远量不到。

#### 🔴 顺手记一笔：dylib 小了 16592 B，而代码一个字没变

这一版 tweak 侧只改了注释 + 三处**等长**版本串（`v0.0.38` → `v0.0.39`），
逻辑一行没动 —— 结果 dylib 从 160528 掉到 143936（**−16.7 KB**）。

第一反应是"是不是删掉了代码"，所以按纪律**不看大小看内容**，把三版 dylib 的特征串全数了一遍：

| 特征串 | v0.0.37 | v0.0.38 | v0.0.39 |
|---|---|---|---|
| `maxSec` | 3 | 3 | 3 |
| `BBServer` / `PROBE` / `DROP#` / `REPL#` | 各 1 | 各 1 | 各 1 |
| `soundDuckOthers` / `releaseAudioSessionIfIdle` | 各 1 | 各 1 | 各 1 |
| `SD#` / `tweak.log` / `writeToFile` | 2 / 1 / 2 | 2 / 1 / 2 | 2 / 1 / 2 |

**三版完全一致** ⇒ tweak 内容没变，差的是 Mach-O 段对齐/填充（压缩后几乎不占体积，
所以 deb 反而从 110198 变成 110250）。

这是「**二进制大小与改动量脱钩**」的第七次，而且这次是**反向的、在 dylib 侧**：
以前是"改了很多 → 大小不动"，这次是"**什么都没改 → 小了 16 KB**"。
⇒ 判据永远是**串 / 选择器 / md5**；大小连"作参考"都得小心。

---

## v0.0.40 · 顶部提示条改成「当前筛选之外还有未读」+ 筛选条件收敛成一个出口

### 一、起因：v0.0.39 真机一装，顶部什么都没有

用户装完 v0.0.39 第一句话是「顶部没有什么新东西啊」。排查结论是：
**不是 bug，是那个触发条件在真实数据里几乎不成立。**

v0.0.39 的提示条要出现，必须同时满足 4 条：

| # | 条件 |
|---|---|
| 1 | 时间选「近24小时」或「近7天」（`since > 0`） |
| 2 | **该时间窗内未读 = 0** |
| 3 | **全库还有未读，且这些未读在时间窗之外** |
| 4 | 列表非空 |

第 3 条是死穴：**默认时间窗就是 24 小时**。收通知多的话 `maxRecords`（200）一天就滚满，
库里 200 条全在 24 小时内 ⇒「更早还有未读」**恒为 0** ⇒ 提示条永远不出现。

⇒ 这一版做完的功能，在设计的默认路径上**根本看不到，等于没做**。

### 二、这一版最贵的教训

前几轮判据一直在算「**条件写没写对**」（口径一致、场景互斥、frame 清零 —— 全对），
却没算「**这个状态在真实数据里多久发生一次**」。

> 一个判据写得再精确，如果它依赖的状态在真实数据里不存在，
> 交付结果就是"用户装上看不到任何变化" —— 和没做一样，而且更糟（用户以为没生效）。

⇒ 立一条：**上线前先问"这个状态在用户的真实数据里占多大比例"**，写不出来就去查
（`SELECT COUNT(*) FROM notifications WHERE ts < now-86400 AND read=0`），别靠猜。

### 三、改法：从「更早」扩成「当前筛选之外」

原来只算**时间窗**一个维度，现在算**三个维度一起**：

```
筛选之外还有多少条未读 = 全库未读 − 当前筛选下的未读
```

「当前筛选」= **App 图标 + 时间 + 搜索**。任何一个生效都会让一部分未读看不见：

| 场景 | v0.0.39 | v0.0.40 |
|---|---|---|
| 默认视图（全部 + 近24小时 + 无搜索），未读全在 24 小时内 | 不显示 | 不显示（正确，确实都看得见） |
| 库里有 24 小时以前的未读 | 显示「更早还有 N 条」 | 显示「更早还有 N 条」（文案一字不差） |
| 🔴 **点了某个 App 图标，别的 App 有未读** | **不显示** | **显示**「还有 N 条未读 · 点顶部「全部」图标看全」 |
| 🔴 **搜索着看，被搜掉的未读** | **不显示** | **显示**「还有 N 条未读 · 清空搜索就能看到」 |
| 两种以上筛选叠加 | 不显示 | 显示「还有 N 条未读在当前筛选之外」（不点名出口） |

🔴 **文案只在能确定唯一出口时才点名**：叠加时点名其中一个（比如"点「全部」图标"）会把人
带进死路 —— 他照做了还是看不到，就会认定整个提示在说谎，**比不提示更糟**。

### 四、顺手做的一件事：筛选条件收敛成一个出口

以前 `bundle` / `since` 这套 WHERE 条件在 `NotifyStore.m` 里**拼了四份**
（列表、图标栏红点、未读计数、批量标记），这一版全部收进一个函数：

```objc
static sqlite3_stmt *NBPrepareScope(sqlite3 *db, NSString *head, NSString * _Nullable tail,
                                    NSString * _Nullable bundle, NSTimeInterval since,
                                    NSString * _Nullable search)
```

**拼 WHERE 和绑参必须在同一个函数里完成** —— 拆成"拼一处、绑一处"就有顺序走岔的可能，
而这类错**不报错、只静默少筛或多筛一个条件**（v0.0.35 的 `onClear:` 报 3 条清了 2000 条）。

为什么必须给 `search` 开参数：

- **计数要带搜索词**（`unreadCountWithBundle:since:search:`）—— 否则"列表里明明全读完了、
  顶部还在喊还有 3 条"，两边永远对不上。
- **标记不带搜索词**（`markAllRead…` 传 `nil`）—— 搜索只决定列表显示什么，不缩小标记范围。
  这是 v0.0.38 的确认文案里对用户承诺过的事。

### 五、改名：`olderUnread` → `hiddenUnread`

「更早」是**错的名字**（新语义还包含 App 筛选和搜索）。这个项目里名不符实栽过一次
（第 0 段时间曾叫「今天」而实际是 `now - 86400`），所以连变量名一起改掉，
`updateOlderUnread` → `updateHiddenUnread`、`olderHint` → `hiddenHint`。

### 六、判据

| 项 | 结果 |
|---|---|
| 源码判据 | **52 条全绿** |
| 负向变异 | **22/22 全抓住** |
| 反向对照（`c40903b` = v0.0.39） | **52 条全红**（0 条通过） |

判据自身踩的两个坑（都写进了 `nb_v040_src_check.py` 的注释）：

1. **`a15` 假绿（第八种形态）**：原来写 `'NBPrepareScope' not in uc2`，
   而旧版用的是 `NBPrepareUnreadScope` —— 两者**不互为子串** ⇒ 旧版也绿。
   改成 `'NBPrepare' not in uc2`，两种拼写一起盖住。
2. **`d06` 反向对照里绿**：只取 `y += 20 + 4;\n } else {` 当锚点，旧版（`olderHint`）也满足
   ⇒ 这条判据对新旧没区分力。锚点补上 `hiddenHint.frame` 那一行。

另外 `a11b` 是**变异逼出来的新判据**：原来只判"红点那条路不再自己拼时间条件"，
把 `since` 换成 `0`（红点变全库口径 ⇒ v0.0.36 那个"红点永远消不掉"就回来了）两条判据都发现不了
⇒ 补一条"`since` 必须原样传进去"。

### 七、装了这一版要验什么

| # | 操作 | 期望 |
|---|---|---|
| 1 | 🔴 **点顶部某个 App 图标**（别的 App 还有未读） | 出现 `⚠️ 还有 N 条未读 · 点顶部「全部」图标看全`，N = 其它 App 的未读总数 |
| 2 | 🔴 点「全部」图标 | 提示条**当场消失**（如果没消失，说明还有时间窗/搜索在挡 —— 那时应该变成另一种文案） |
| 3 | 🔴 **搜索一个只有少数记录命中的词** | 出现 `⚠️ 还有 N 条未读 · 清空搜索就能看到`，N = 没被搜到的未读 |
| 4 | 清空搜索 | 提示条**当场消失** |
| 5 | 时间切「不限时间」+ 无 App 筛选 + 无搜索 | 提示条**一定不出现**（此时所有未读都在列表里） |
| 6 | 如果库里有 24 小时以前的未读 | 只有时间窗在挡时文案仍是 `⚠️ 更早还有 N 条未读 · 切「不限时间」看` |
| 7 | 列表**为空**时 | 顶部**不出现**提示条，走屏幕正中那句（现在和顶部**同源**，不会说两套话） |
| 8 | 回归：自动更新、全标已读、详情页、左滑删除、清空、按 App 配时长、压低开关 | 与 v0.0.39 一致 |
| 9 | 🔴 **红点回归**（这版动了红点那条 SQL 的写法） | 切时间时红点跟着变；点有红点的 App 一定点得进去、读得掉 |

> 第 1、3 条是这一版**新增能被看到**的两个场景（v0.0.39 在这两处是哑的）。
> 第 2、4、5 条是反向判据：**"不该出现时不出现"比"该出现时出现"更重要**。
> 第 9 条别跳过：筛选条件收敛时动了红点那条路，虽然判据 52 条都覆盖到了，
> 但红点这东西**只能是肉眼验收**。

### 八、交付记录

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.40_iphoneos-arm64e.deb` · **110492 B** · md5 `12ed425953d2223f` |
| CI | **#80**（`run_id 40099103709`，head `3aa5c4e6cd87`）success，**一次编译过** |
| 产物 zip | 110678 B（与 API `size_in_bytes` 逐字节对拍一致） |
| 远端 | `3aa5c4e6cd87` = 本地 `2fa8973`，**7 个改动文件逐 blob 一致** |
| 改动 | 7 文件 **+307 / −122** |
| App 二进制 | `350592 → 350592 B`（**大小一模一样**，md5 `a57d4423 → 9cd3ebb6`） |
| tweak dylib | `143936 → 143936 B`（只改注释 + 等长版本串） |
| 源码判据 | **52 条全绿**；负向变异 **22/22 全抓住**；反向对照（`c40903b`）**52 条全红** |
| 包级判据 | **39 条全绿**；反向对照（v0.0.39 的 deb）**20 条红**（`A1~A5`+`B2~B7`+`C1~C4`+`D1~D3`+`D5`+`D6`） |

#### 🔴 顺手记第八笔：App 二进制**一个字节都没多**，内容却全变了

这一版 App 侧改了 166 行（+307/−122 里的绝大部分），新增了一个方法、两个属性、
四段文案、一个 NotifyStore 公开方法 —— 结果 `NotifyBoxApp` **前后都是 350592 B**，
变的是 md5（`a57d4423` → `9cd3ebb6`）。

这是「**二进制大小与改动量脱钩**」的**第八次**，而且是头一次出现"**改了很多、大小一个字节不差**"。
⇒ 前面七次已经说清了：判"编进去没"只能看**串 / 选择器 / md5**，
`大小` 连当"参考"都不够格，它连"变没变"都答不上来。

---

## v0.0.41 · 顶部提示条变成可点按钮 + 未读派生量收成一个出口

### 一、起因：v0.0.40 自己留了一个洞

v0.0.40 把提示条的**语义**改对了，但**调用点漏了一处**。

`didSelectRow:` 里有两条路：

| 路 | 条件 | 干什么 |
|---|---|---|
| A | 记录本来就没读 | 改库 → 整表重查 `loadData` |
| B | 🔴 记录**已经读过**、用户只是再点一次看详情 | 只改内存里那条的 `read` + `reloadRowsAtIndexPaths:`（不重查库） |

B 这条路是 v0.0.36 特意做的（避开整表 reload 丢滚动位置），尾部只调了 `refreshUnreadDots`。
⇒ 具体现象：**点某个 App 图标、把它的 3 条未读依次点开读完**，顶部该出现「其它 App 还有 N 条」
**却不出现**；退出去再回来（触发整表 `loadData`）才出现。

> 根因一句话：**一个量有几处派生出口，改的时候就得全改 ⇒ 不如让它只有一个入口。**

### 二、改法 A：把派生量收成一个出口

```objc
- (void)refreshUnreadDerived {
    [self refreshUnreadDots];      // 图标栏红点（按 App 汇总）
    [self updateHiddenUnread];     // 顶部提示条（筛选之外还有多少）
    // 🔴 `setNeedsLayout` 不能省：提示条出现/消失会改图标栏和列表的**起始 y**。
    [self.view setNeedsLayout];
}
```

三件事绑死在一起：**红点**、**提示条**、**跟着它们变化的起始 y**。
原来 `loadData` 尾部是「`refreshUnreadDots` + `updateHiddenUnread` + `setNeedsLayout`」三行手抄，
现在同一个方法；`didSelectRow:` 的 B 路只调这一句。

⇒ 以后再加派生量，**只改这一个方法**，两条路自动都覆盖。

### 三、改法 B：提示条从 `UILabel` 变成 `UIButton`

v0.0.40 的文案会点名出口（"点顶部「全部」图标看全"），但**三种筛选叠加时不能点名** ——
那时点了还是看不到，用户就认定提示在说谎，**比不提示更糟**。

这一版把它变成**按钮**，点一下**三样一次清干净**：

```objc
- (void)onHiddenHintTap {
    BOOL changed = NO;
    if (self.filterBundle.length) { self.filterBundle = nil; changed = YES; }
    if (self.searchText.length) {
        self.searchText = nil;
        self.searchBar.text = nil;   // 程序设 text 不会回调 textDidChange，上一行不能省
        changed = YES;
    }
    if (self.timeSeg.selectedSegmentIndex != 2) {   // 2 = 不限时间
        self.timeSeg.selectedSegmentIndex = 2;
        changed = YES;
    }
    if (!changed) { /* 三样本来就干净 ⇒ 弹说明，见下 */ }
    [self loadData];
}
```

**文案从此只说事实，不说怎么做**：

| 叠加维度 | 文案 |
|---|---|
| 只有 App 筛选 | `⚠️ 还有 N 条未读 · 点顶部「全部」图标看全` |
| 只有搜索 | `⚠️ 还有 N 条未读 · 清空搜索就能看到` |
| 只有时间 | `⚠️ 更早还有 N 条未读 · 切「不限时间」看`（**一字未改**） |
| 两种以上 | `⚠️ 还有 N 条未读在当前筛选之外`（不点名）+ 按钮上带 ` ›` |
| 三种都干净 | `⚠️ 还有 N 条未读没显示出来` ⇒ 只能是 `LIMIT 2000` 截断 |

最后那种（点下去发现三样本来就干净）**不能什么都不做** —— 用户点了一下没反应，只会以为坏了。
所以弹一句说明，并把真正的出口指出来：

> 当前已经是「全部 App · 不限时间 · 无搜索」，但库里的记录超过了列表能显示的上限，
> 有一部分翻不到。可以到「设置 → 记录上限」把它调小一些，让列表能一次装下。

### 四、为什么用 `UIButton` 而不是给 `UILabel` 加 tap 手势

**按钮自带按压高亮** —— 用户手指按下去时颜色会变，他知道自己点到了。
`UILabel` + `UITapGestureRecognizer` 点下去没有任何反馈，在这样一条 12pt 小字上等于不可点。

两个细节：

- `UIButton` 的 system 类型标题默认**居中** ⇒ 必须 `contentHorizontalAlignment = Left`，
  否则一行小字飘在屏幕正中。
- `›` 只加在**按钮**上。空列表正中那句是 `UILabel`、不能点，**绝不能也加 `›`**
  （那等于告诉用户"这里可以点"，点了没反应 —— 就是上面说的"提示在说谎"）。

### 五、判据

| 项 | 结果 |
|---|---|
| 源码判据 | **72 条全绿** |
| 负向变异 | **35/35 全抓住** |
| 反向对照（`2fa8973` = v0.0.40） | **23 条红**（`d01 f01~f04 g01~g05 h01~h06 h08~h14`） |
| 包级判据 | **45 条全绿** |
| 包级反向对照（v0.0.40 的 deb） | **10 条红**（`A1~A5` + `G1 G2 G3 G4 G6`） |

### 六、判据自己踩的四个坑

1. **`b02` 假红**：老判据写死 `UILabel *hiddenHint;`，而本版**故意**换成 `UIButton`
   ⇒ 判据和意图打架。改成只判「属性在」，类型交给 `h01` 单独判。
2. **变异 SKIP（抓到一次）**：某条变异的锚点在真代码里出现 **0 次** ⇒ 变异被跳过却计入"全过"，
   那条判据**从没被验证过**。锚点换成确实唯一的 `        [self refreshUnreadDerived];`。
   （这条纪律早就立过 —— **SKIP 必须算失败**，靠的是脚本自己会报 SKIP。）
3. **`h03` 反向对照里绿**：只判 `forControlEvents:UIControlEventTouchUpInside]` 在不在 ——
   同屏的 `markAllBtn` 也有同一个串 ⇒ 对新旧没区分力。
   锚点必须带上 `action:@selector(onHiddenHintTap)` 那一行。
4. 🔴🔴 **`G3` 连续两次假绿，值钱的是第二次** —— 见下。

#### 🔴🔴 `G3`：一条短串判据连栽两次，两次病因完全不同

`G3` 想证的是"`@" ›"` 这个可点的暗示真的编进包里了"。两次都判绿，但原因不一样：

**第一次：单字符的 UTF-16LE 太短。** 原来用 `has_str`（同时查 UTF-8 和 UTF-16LE），
而 `›`（U+203A）的 UTF-16LE 只有 **2 字节** `3A 20`（就是 `':'` + 空格）⇒ 任意二进制几乎必然命中
⇒ 判据**恒真**。当时的修法是"加一个只查 UTF-8 的 `has_utf8()`"。

**第二次（就是这次）：`has_utf8` 对中文/符号串是恒假，而 `›` 本身是被污染的符号。**
写了个探针把两种编码都数了一遍，数据是：

| 查什么 | v0.0.41（本版） | v0.0.40（反向对照） |
|---|---|---|
| `记录太多` **UTF-8** | **0** | 0 |
| `记录太多` **UTF-16LE** | 1 | 0 |
| `›` **UTF-8** | **0** | 0 |
| `›` **UTF-16LE** | 17 | **16** ← 旧版本来就有 |
| `" ›"` **UTF-16LE** | 11 | **10** ← 旧版本来就有 |

两个结论，都不在我原来那条判据的假设里：

1. **ObjC 的常量字符串对非 ASCII 只发 UTF-16**（clang 按 CFString 编码标记走：
   纯 ASCII → UTF-8，非 ASCII → UTF-16）。所以 `has_utf8` 对中文/符号**永远是假** ——
   这个 helper 本身就不该存在，已删掉。
2. **`›` 在旧版的包里已经命中 16 次**（`" ›"` 也有 10 次），来自系统库/其他常量的字符边界巧合。
   ⇒ **存在性判据在这里恒真，换成 4 字节的 `" ›"` 也救不回来**（旧版仍有 10 次）。

唯一有区分力的口径 = **两版计数之差**：本版新增了一处 `@" ›"`、别处一字未动 ⇒ 必须**正好 +1**。

```
need(app_bin.count(' ›'.encode('utf-16-le')) == base_app.count(' ›'.encode('utf-16-le')) + 1, ...)
```

改完正向 `10 → 11` 通过，反向对照**当场变红**。

> 教训不是"该用 UTF-16 还是 UTF-8"，而是：**判"某个串在不在"之前，先数一数它在旧版里有多少次**。
> 一个符号如果在旧版里非零，那"在不在"这条判据从一开始就没有区分力，换编码只是换个死法。

### 七、装了这一版要验什么

| # | 操作 | 期望 |
|---|---|---|
| 1 | 🔴 点某个 App 图标，把它名下的未读**依次全部点开读完**（走 B 路、不重查库） | 读完后顶部**当场出现**「其它 App 还有 N 条」—— 这是 v0.0.40 的洞，v0.0.41 修的就是它 |
| 2 | 🔴 **点一下顶部提示条**（任一种文案） | App 图标 + 时间 + 搜索**三样一次清干净**，提示条消失、列表变全 |
| 3 | 三种筛选本来就干净、但库超上限时点提示条 | 弹出「记录太多」说明，指向「设置 → 记录上限」，**不是**毫无反应 |
| 4 | 搜索态下点提示条 | 搜索框里的字**也清掉**（不是只清了内部变量、框里还留着字） |
| 5 | 提示条按下去时 | 有**按压高亮**（说明它真是个按钮，不是画上去的一行字） |
| 6 | 🔴 空列表时 | 顶部**不出现**提示条，走屏幕正中那句；正中那句**没有 ` ›`**（它不能点） |
| 7 | 🔴 **红点回归**（这版动了红点调用链：`refreshUnreadDots` 被包进新方法里） | 切时间时红点跟着变；点有红点的 App 一定点得进去、读得掉 |
| 8 | 回归：自动更新、全标已读、详情页、左滑删除、清空、按 App 配时长、压低开关 | 与 v0.0.40 一致 |

> 第 1、2 条是这一版的两个真改动，各自对应一个具体动作，别跳。
> 第 6、7 条是反向判据：**"不该出现时不出现"比"该出现时出现"更重要**。

### 八、交付记录

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.41_iphoneos-arm64e.deb` · **110804 B** · md5 `2d696ac50738ae97` |
| CI | **#82**（`run_id 40100305700`，head `633dd53090e2`）success，**一次编译过** |
| 产物 zip | 110991 B（与 API `size_in_bytes` 逐字节对拍一致） |
| 远端 | `633dd53090e2` = 本地 `c193b8c`，**4 个改动文件逐 blob 一致** |
| 改动 | 代码 4 文件 **+106 / −24** |
| App 二进制 | `350592 → 367184 B`（md5 `9cd3ebb6 → 970c2aee`） |
| tweak dylib | `143936 → 143936 B`（只改注释 + 等长版本串） |
| 源码判据 | **72 条全绿**；负向变异 **35/35 全抓住**；反向对照（`2fa8973`）**23 条红** |
| 包级判据 | **45 条全绿**；反向对照（v0.0.40 的 deb）**10 条红** |

#### 🔴 顺手记第九笔：改得比上一版少得多，二进制却涨了 16 KB

v0.0.40 App 侧改了 166 行，`NotifyBoxApp` **一个字节没变**（第八笔）。
v0.0.41 App 侧只改了约 106 行（差不多一半），`NotifyBoxApp` **涨了 16592 B**。

两次摆在一起看，规律就很清楚了：**大小和改动量之间根本没有可用的换算关系** ——
它不是"改得多就涨、改得少就不涨"，它是**跟着段对齐和填充走**。第九次记这一笔，
是为了把"大小连趋势都不可信"这句话坐实，免得下次又有人拿"这次涨了 16KB，说明改大了"当依据。

---

## v0.0.42 · 列表说清「这条是哪个 App 的」+ 搜索能搜 App 名 + 搜索防抖 + 底部截断提示

这一版做三件事，全部围绕**「搜索」和「App」这两个维度到底通没通**。

### 一、起因：v0.0.40 / v0.0.41 把搜索做成了筛选维度，可搜索本身是坏的

上一版刚给搜索加了语义（提示条会喊「清空搜索就能看到」），但扫代码时发现两个硬缺口：

| # | 缺口 | 证据 |
|---|---|---|
| 1 | 🔴 **列表里没有一个字说"这条是哪个 App"** | `NotifyCell.m` 的七个控件里只有 icon、letter、title、msg、time、dot；`ViewController.m` 传进去的 `letter` 只是**图标加载失败时的兜底首字母** |
| 2 | 🔴 **搜索搜不到 App 名** | `NBPrepareScope` 里只有 `title LIKE ? OR message LIKE ?`。库里存的是 `com.tencent.xin`，标题正文里也没有「微信」两个字 |

⇒ 真实后果：用户想查「招商银行」弹过什么，搜「招商银行」→ **空列表** ⇒ 他会断定"这个 App 的记录没收到"。
而图标加载失败时整行只剩一个首字母（`b`、`m`），十几个 App 混在一列里根本分不清。

### 二、A：App 维度打通

#### 2.1 列表每行加一行 App 名（行高 82 → 98）

排版照 iOS 自己通知的样子：**App 名一行小字在最上面**，下面才是标题和正文。
用户不需要学。

```
App 名  y=10~24   11pt / secondaryLabel
标题    y=25~45   15pt semibold（时间跟标题同一水平线）
正文    y=47~87   13pt / 两行
```

🔴 三条设计取舍：

- **不塞进标题**（`微信 · 你好`）：标题是扫列表时最先看的，不能因为它让字变少。
- **不塞进正文前面**：正文本来只有两行、已经不够用，而且会被误认为正文的一部分。
- **行高是常量**：某个 App 名字取不到时也**不能让那一行变矮** —— 整屏行高参差不齐比空一行难看得多。

#### 2.2 搜索时把词先跟 App 名匹配，再传给数据库

```objc
- (NSArray<NSString *> *)bundlesMatchingSearch:(NSString *)q {
    for (NSString *bid in self.appNameMap) {
        // ① 匹配 App 显示名（用户想的是「微信」，不是 com.tencent.xin）
        // ② 也匹配 bundle id 本身（懂行的人会直接搜 tencent）
    }
}
```

🔴 **为什么在界面层算、不写进库**：库里只有 bundle id，App 显示名属于界面知识
（要 `LSApplicationProxy` / Info.plist 扫描）。写进库就得改 schema + 迁移老记录；
**查询时现算对库里已有的记录立即生效**，不用重装、不用重记。

🔴 **但它必须进 `NBPrepareScope`，不能只在 `queryWithBundle:` 里拼**：

> 只要计数那条路少一个 `OR bundle IN (...)`，两个口径立刻不一致 ⇒
> v0.0.40 花整版修掉的「列表里明明都读完了、顶部还在喊还有 3 条」当场复发。

所以 `updateHiddenUnread` 里也算了一遍 `bundlesMatchingSearch:`。

搜索条件最终长这样（**拼 WHERE 和绑参仍在同一个函数里**，一条没拆）：

```sql
AND (title LIKE ? OR message LIKE ? OR subtitle LIKE ?
     OR bundle IN (?,?,…))
```

🔴 三条 LIKE **各绑一次**：少绑一条不会报错（SQLite 把未绑的参数当 NULL，
`x LIKE NULL` 恒不成立），症状是"搜出来的东西莫名少一半"，而且后面 `bundle IN`
的参数会**整体前移一格**、绑错值。

#### 2.3 顺带把 `subtitle` 也搜上

`NotifyCell.m` 里 `subtitle` **只在 `message` 为空时**才回落当正文显示 ⇒
正文不空时它一个字都看不到、也搜不到。这次一起加进搜索条件。

### 三、B：搜索防抖 250ms

以前 `searchBar:textDidChange:` 直接 `loadData`，而一次 `loadData` 要跑 6~8 条 SQL：
`reloadIconBar`（DISTINCT bundle + 未读集合 + 重建图标按钮）、列表查询（最多 2000 行）、
`count`、`maxRowId`、`updateHiddenUnread` 的两条 COUNT，外加本版新增的 `countWithBundle:`。
**打一个 4 字词 = 5 次全量刷新。**

```objc
- (void)scheduleLoadData {
    NSUInteger gen = ++self.searchGen;   // 先自增，让之前挂起的全部作废
    dispatch_after(…250ms…, ^{
        if (ss.searchGen != gen) return;   // 后面还有更新的输入在排队，这一枪让给它
        [ss loadData];
    });
}
```

🔴 四条必须保证：

1. **最后一次一定执行** —— 靠代次匹配：代次没变就执行，变了说明有更新的在后面。
2. **不能用 BOOL 标记** —— 敲 a、ab、abc 会排三个 block，Bool 挡不住，三个都跑（比不防抖更慢）。
3. **清空路径要立刻执行** —— 点顶部提示条前先 `cancelPendingLoadData`（代次 +1，
   所有挂起的跑起来都会发现自己过期），否则清空完 250ms 后又白跑一次全量。
4. **按键盘「搜索」键立刻出结果** —— 用户主动按键就是在说"我现在要"，让他再等 250ms 没道理。

### 四、D：底部「还有 N 条更早记录」

这是扫代码时发现的第三个缺口：`maxRecords` 允许用户填到 **99999**，而列表 `LIMIT` 是**硬编码 2000**。
⇒ 用户把上限调到 5000 时，库里 5000 条、列表只显示最新 2000，**剩下 3000 条既看不到、也左滑删不掉**
（只能"清空"）。以前界面对此一个字都不说。

```objc
NSInteger more = scopeCount - shown;   // 当前筛选总条数 − 列表实际拿到的条数
if (more <= 0) { self.table.tableFooterView = nil; return; }
```

🔴 三个决定：

- **用 `tableFooterView`，绝不做"假行"**：行号必须和 `self.items` 严格一一对应，
  加假行会让 `reloadRowsAtIndexPaths:` / `deleteRowsAtIndexPaths:` 全部错位（v0.0.33 栽过一次）。
- **`LIMIT 2000` 抽成 `kNBListLimit` 单一来源**：底部文案要写「列表一次最多显示 N 条」，
  界面上另写一个 2000，这个数以后一改就对不上。
- **和顶部提示条分工**：顶部管「**未读**被筛选挡掉了」，底部管「**记录**被列表上限截断了」。
  两个场景不会同时成立，不会互相吵（v0.0.39 那条"两处都喊"的教训）。

### 五、判据

| 项 | 结果 |
|---|---|
| 源码判据 | **76 条全绿** |
| 负向变异 | **27/27 全抓住，0 跳过** |
| 反向对照（`7b9c597` = v0.0.41） | **51 条红** |
| 本地结构体检（无编译时的兜底） | **44 条全绿** |
| 包级判据 | **44 条全绿** |
| 包级反向对照（v0.0.41 的 deb） | **27 条红** |

### 六、🔴🔴 这轮最值钱的：判据自己的三个坑，一个比一个深

#### 6.1 自己踩的三个实现坑（都改了判据，没改代码）

1. **`b01` 假红**：`NBPrepareScope` 是**静态 C 函数**，我拿"数 ObjC 方法定义"的 `^[-+]` 正则去数
   ⇒ 数出 0 条。改成数 `static sqlite3_stmt *NBPrepareScope(`。
2. **`b04` 假红**：`call_args` 把**定义**那一处也算进去了（定义也有 7 个形参）⇒ 数出 6 而不是 5。
3. **`c29` 假红**：判"界面里没有硬写的 2000"，朴素子串匹配命中了 `logText:20000`（日志行数）
   ⇒ 改成去注释 + 词边界 `2000`。

#### 6.2 变异逼出两条真漏判据

| 变异 | 原来 74/75 条判据 | 补的判据 |
|---|---|---|
| `tableFooterView = nil` → `return` | **一条都没发现**（footer 会一直挂着不消失） | `c30`：`more <= 0` 分支里必须真的置 nil |
| `appLabel.text = name` → `= nil` | **一条都没发现**（方法在、布局在、界面上永远没名字） | `d09`：参数真的被赋给 label |

#### 6.3 🔴🔴 包级判据：从"假绿"升级到"计数差也失效"

v0.0.41 的 `G3`（`›`）教训是「**判某个串在不在之前，先数它在旧版里有几次**」。
这一版把这条做成了**机械守卫**：`appear()` 会先数旧版，非零就**直接判这条判据无效**。

守卫当场抓住三条没区分力的判据，其中两条揭示了更深的问题：

| 名字 | v0.0.41 | v0.0.42（明明新加了一份） |
|---|---|---|
| `appLabel` | 3 | **3** ← 没涨 |
| `setAppName:` | 1 | **1** ← 没涨 |

两层原因：

1. **旧版里本来就有**（App 里别的界面类早有同名属性，`appLabel` 在 AppPicker 里就有）；
2. **链接器会把重复的 C 串合并**进同一份 `__objc_methname` ⇒ 同一个选择器名
   **在包里只存一份**，再加一处引用，计数也不会变成 4。

> ⇒ **"我们新加了这个名字"这件事，在一个"这个名字本来就存在"的二进制里，
> 用计数根本无法证明。** 只有"这个名字在本项目里独一份"时，存在性判据才成立。

处理办法：**删掉这两条判据**，并在脚本里写清「包级验不了，交给源码判据 d01~d09 + 真机」。
**宁可少一条判据，也不要留一条永远绿的** —— 恒绿的判据会让下一版的人以为这块已经被守住了。

另外两条具体坑：

- **`A5` Info.plist 假红**：Xcode 把 `Info.plist` 编成 **bplist**（头 8 字节 `bplist00`），
  里面**没有 `<string>` 标签**。查 `b'<string>0.0.42</string>'` 永远为假 ⇒ 改成查版本串字节本身。
- **`G2` 旧版也有 `LIMIT %ld`**（`maxRecords` 裁剪那条 SQL 在用）。真正只在本版出现的形态是
  **它出现在串尾**：列表查询的 tail 就是 `" ORDER BY ts DESC LIMIT %ld"`，后面没有别的字面量，
  而裁剪 SQL 后面还跟着 `;` ⇒ 只有本版有 `ORDER BY ts DESC LIMIT %ld\0`。

### 七、装了这一版要验什么

| # | 操作 | 期望 |
|---|---|---|
| 1 | 🔴 打开列表，看**每一行最上面那行小字** | 显示 App 名（「微信」「抖音」这种），不是 bundle id，也不是首字母 |
| 2 | 🔴 **搜一个 App 名**（比如「微信」「招商银行」） | 能搜出这个 App 的记录，**不是空列表** ← 这是本版最重要的一条 |
| 3 | 搜一个**只在 subtitle 里出现过**的词 | 能搜到（以前搜不到） |
| 4 | 🔴 **快速打一长串字** | 打字过程中**不卡**，停下来约 0.25 秒后列表才刷新（不是每敲一个字都跳） |
| 5 | 打完字按键盘上的「搜索」键 | **立刻**出结果，不用再等 |
| 6 | 搜着的时候点顶部提示条 | 三样清空、提示条消失，且**不会**在 0.25 秒后又闪一下（防抖被作废了） |
| 7 | 🔴 把「设置 → 记录上限」调到 **3000**，再看列表**翻到底** | 底部出现「下面还有 N 条更早的记录 / 列表一次最多显示 2000 条」 |
| 8 | 上限是默认 500 时翻到底 | 底部**什么都没有**（不该出现时不出现） |
| 9 | 回归：自动更新、全标已读、详情页、左滑删除、清空、红点、提示条、按 App 配时长、压低开关 | 与 v0.0.41 一致 |

> 第 1、2 条是这一版新增的两个"必须看得见"，第 4、7 条是另外两个。
> 第 8 条是反向判据：**"不该出现时不出现"比"该出现时出现"更重要**。
> 第 7 条要真有 3000 条才看得到 —— 没有那么多记录时**先别改上限**，跳过即可。

### 八、交付记录

| 项 | 值 |
|---|---|
| deb | `com.yxh41.notifybox_0.0.42_iphoneos-arm64e.deb` · **112550 B** · md5 `f4ff38e581bfbc9a` |
| CI | **#84**（`run_id 40102270235`，head `4f764ce17854`）success，**一次编译过** |
| 产物 zip | 112736 B（与 API `size_in_bytes` 逐字节对拍一致） |
| 远端 | `4f764ce17854` = 本地 `17e2378`，**9 个改动文件逐 blob 一致** |
| 改动 | 9 文件 **+375 / −26** |
| App 二进制 | `367184 → 367216 B`（**改 375 行只涨 32 字节**，md5 `970c2aee → e4c55d7c`） |
| tweak dylib | `143936 → 160544 B`（**只改注释 + 等长版本串，却涨了 16608 B**） |
| 源码判据 | **76 条全绿**；变异 **27/27**、0 跳过；反向对照（`7b9c597`）**51 条红** |
| 包级判据 | **44 条全绿**；反向对照（v0.0.41 的 deb）**27 条红** |

> #### 🔴 第十次大小记账：这一次**同一版里两个方向同时出现**
>
> | 改了什么 | 二进制 | 变化 |
> |---|---|---|
> | App 侧 **375 行**（新方法 + 属性 + 文案 + SQL 片段） | `367184 → 367216` | **+32 字节** |
> | tweak 侧 **只改注释 + 等长版本串** | `143936 → 160544` | **+16608 字节** |
>
> 改了几百行的几乎不动，一个字逻辑都没改的涨了 16 KB。
> 跟第八次（166 行 / 0 字节）、第九次（106 行 / +16 KB）摆在一起，
> ⇒ **大小这个数彻底不可用作判据，连"大概"都不行。**
> 判"编进去没"只能看**串 / 选择器 / md5**。

## v0.0.43 · 真机反馈两修：App 名（逐键 @try + 多来源 + 汉字优先）+ 底部截断提示的未读口径

这一版只做用户当场指出来的两件事，不夹带新功能。

### 一、起因：三条真机反馈

| # | 用户原话 | 结论 |
|---|---|---|
| 1 | 「部份app每行最上面的小子有些怎么不是app中文名，比如云闪付、米家、京东、小红书等」 | 🔴 **真 bug**，两层病根都在 `app/InstalledApps.m` |
| 2 | 「我调到3000，翻到最底部还是什么都没有」→ 后来自己发现「底部有出现了」 | ✅ **不是 bug**，`maxRecords` 不追溯恢复已裁记录（见下） |
| 3 | 「不过之在未读出现，你还是看看这个问题用不用也怎么处理」 | 🔴 **真 bug**，比第 1 条更严重：底部报的是**已读**条数 |

**先说清楚第 2 条**，它决定了这条提示以后怎么验收：

- `maxRecords` 决定的是"**以后**最多留多少"，**不会**把已经裁掉的记录找回来。
- 列表一次最多取 `listLimit`（2000）。当时库里约 500 条 ⇒ **没超上限 ⇒ 本来就不该显示**。
- ⇒ 验收这条提示要先把库填到超过 2000，否则永远验不到。

这条已写进 `updateMoreFooter` 的注释 —— 它是 v0.0.40 那一族错的重演：
**条件本身写对了，但在真实数据里长期不成立**，于是"看起来像没做"。

### 二、① App 名：两层病根

#### 2.1 病根 a：三个键共用一个 @try ⇒ 一个坏键带走**整个 App**

v0.0.42 的注释写着"逐项 @try"，代码却是 `for` 里面**一个 @try 罩住三个 `valueForKey:`**：

```
bundleIdentifier  ← 读成功了
localizedName     ← 一抛异常 ⇒ @catch ⇒ skipped++ ⇒ **这个 App 从名单里消失**
displayName
```

`LSApplicationProxy` 是私有类，占位 App / 扩展 / 已删记录都可能让某个键抛。
丢掉之后：名单里没有它 ⇒ `appNameForBundle:` 走 `shortName:` 兜底 ⇒ 界面上是 `mihome` / `discover`。

⇒ **"有个名字"骗过了所有人**：界面上不是空白，是 bundle 末段，看着像"读到了、只是这样显示"。

**修法**：逐键 `NBStrForKey`（自己带 @try + 类型校验 + 去空白）；
并且**先只读 `bundleIdentifier`，读到之后无论名字怎么翻车都不许把这个 App 丢掉**。

#### 2.2 病根 b：`NBFallbackName`（bundle 末段）当时是**主路径**，不是兜底

改成四层，候选全收后再挑：

1. 系统本地化名：`localizedName` / `localizedShortName` / `displayName` / `itemName`（逐键读，不存在的键不构成失败）
2. `bundleURL` / `resolvedInstallationURL` / `bundleContainerURL` → 读 `.app/Info.plist`
3. `zh-Hans.lproj` / `zh_CN.lproj` 的 `InfoPlist.strings`（**中文名常常只在这一层**）
4. 最后才是 bundle 末段

`NBPickName` 在候选里**优先挑带汉字的那个**（`NBHasCJK`）。

🔴 为什么需要"汉字优先"这条规则：手机是中文环境，界面上出现 `Mi Home` / `UPay` 就是 bug；
而"哪个来源给中文、哪个给英文"**并不固定** ⇒ 不能靠候选顺序碰运气。

🔴 只在"手上一个汉字都没有"时才去读 Info.plist —— 读文件是 I/O，200 个 App 全读没必要。

#### 2.3 顺带三处

- **仅历史的 App**（库里来过通知、枚举没列出）也走 `NBNameForBundle` 定向解析
  （`+applicationProxyForIdentifier:` + 同一个 `NBNameFromProxy`）——
  它们很可能**就装在手机上**，只是枚举那条路没走通。不为几个 App 跑全目录扫描。
- 目录扫描 `NBScanAppsIn` 复用**同一条**解析，不再自己抄一份 DisplayName→Name 顺序
  （两处抄两遍，必然有一处先改）。
- 诊断新增：**名字来源计数 + 兜底 bundle 列表**。
  🔴 上一版只报"拿到几个 App" ⇒ "拿到的名字是 bundle 末段"在报告里**完全看不见** ——
  而那恰好就是用户看到的那一堆英文小字。

### 三、② 底部截断提示：在「只看未读」下报的是**已读**条数

旧代码两个口径对不上：

| 量 | 口径 |
|---|---|
| `self.items` | `queryWithBundle:…unreadOnly:self.unreadOnly` ⇒ **只装未读** |
| `scopeCount` | `countWithBundle:…` ⇒ **不分已读** |

⇒ `more = scopeCount - shown` 差出来的 N 条**全是已读**，和用户当下要看的东西无关。
用户看到"下面还有 450 条"，翻下去什么都没有。

**修法（选了 B 方案，不是"未读模式下不显示"）**：

- `countWithBundle:` 加 `unreadOnly`，`read=0` 写进 `head`
  （🔴 和 `queryWithBundle:` **同一种写法** —— 一边漏改就会立刻对不上）
- 底部把这个参数传下去 ⇒ 两个数就是同一个集合。
- 文案跟着模式改：只看未读时说「下面还有 N 条更早的**未读**记录」。

为什么不选"未读模式下干脆不显示"：那会漏掉"未读超过 2000"这个真实场景
（库满 3000、未读 2500 时，那 500 条确实翻不到）。
🔴 这条提示的语义是"**被列表上限截断**"，不是"被未读筛选挡掉" ——
后者是顶部提示条的活（v0.0.39 已经定过分工）。

### 四、判据

| 腿 | 结果 |
|---|---|
| 源码判据 | **67 条全绿**；变异 **35/35**、0 跳过；反向对照（`e8cc32a`）**44 条红** |
| 结构体检 | **86/86**（新增：静态 C 函数的定义/调用形参个数、不许 `performSelector:`） |
| 包级判据 | **47 条全绿**；反向对照（v0.0.42 的 deb）**19 条红** |
| CI | **#86**（`run_id 40105846509`，head `61a5167faf43`）一次编译过 |
| deb | **114032 B**，md5 `c2a13dbfabc4e7645c4a403b58a73219`；zip 114217 = API size ✅ |
| 远端 | 代码 `61a5167faf43` = 本地 `30c69c052663`，7 文件逐 blob 一致 |
| 改动 | 7 文件 **+310 / −70** |

#### 4.1 🔴 判据自己踩的坑：变异锚点不唯一 ⇒ 改坏的是别处

第一次跑变异，35 条里 **5 条 MISS**（"全绿 —— 没有任何判据发现它"）。
逐条查明，病根**同一个**：`replace(old, new, 1)` 改的不是判据读的那一行。

| 变异 | 锚点实际改到哪 | 修法 |
|---|---|---|
| 不读简中本地化表 | **注释里**的 `zh-Hans.lproj`（注释在代码前面，先命中） | 锚点换成整行 `for (NSString *lp in @[@"zh-Hans.lproj", …]) {` |
| 本地化表文件名写错 | **注释里**的 `InfoPlist.strings` | 锚点换成 `stringByAppendingPathComponent:@"InfoPlist.strings"]` |
| `read=0` 不再写在 head 里 | `queryWithBundle:` —— 它也有 `NSString *head = unreadOnly`（**2 次命中**） | 锚点带上 `? @"SELECT COUNT(*) … WHERE read=0"` |
| 计数丢掉搜索条件 | `unreadCountWithBundle:` —— 它也有 `since, search, searchBundles)` | 锚点带上 `NBPrepareScope(db, head, …` |
| NBCallId1 不探 respondsToSelector | 改对了，但**根本没有这条判据** | 补 `b31` |

⇒ 新闸门：**变异锚点必须唯一命中**（`orig.count(old) > 1` ⇒ SKIP ⇒ 算失败）。
加了它之后立刻又抓出第 6 条：`isKindOfClass:[NSString class]` 在 `NBStrForKey`
和 `NBPathForKey` 里各出现一次 ⇒ 那条变异改的是后者。

🔴 这比判据漏判更阴：它让变异表看起来 35 条全过，而其中几条**从没被验证过**。

#### 4.2 包级验不了的三件事（实测数据，不是猜测）

| 想证什么 | 实测 | 结论 |
|---|---|---|
| 逐键 @try（`NBStrForKey` / `NBNameFromProxy` / `NBPickName`） | 两版包里都是 **0 次** | 静态 C 函数名**不进包** ⇒ 只能靠源码判据 `b01~b08` |
| `countWithBundle` 的 `read=0` 真的生效 | `SELECT COUNT(*) … WHERE read=0` 计数 **1 → 1** | 两份字面量字节相同 ⇒ **链接器合并**（v0.0.42 那条教训的又一例）⇒ 只能靠选择器 `C1/C2` + 源码 `c03/c04` |
| 名字最终显示成什么（云闪付 / 米家 / 京东 / 小红书） | 包里查不出来 | 只能真机看 |

⇒ **宁可少一条判据，也不要留一条永远绿的**。这三条写成了脚本里的 `H1/H2` 存档判据，
   免得以后有人再花一轮去发明它们。

### 五、第十一次大小记账：两个二进制**一字节都没动**

| 二进制 | v0.0.42 | v0.0.43 | 变化 |
|---|---|---|---|
| App | 367216 B | 367216 B | **0 B** |
| tweak dylib | 160544 B | 160544 B | **0 B** |

这一版改了 310 行（新增 8 个 static 函数、改了 4 处解析路径、加了一个方法参数），
两个二进制大小**恰好相等**。

跟第八次（166 行 / 0 字节）、第九次（106 行 / +16 KB）、
第十次（375 行 / +32 B，同时 dylib 只改注释却 +16608 B）摆在一起：

⇒ **大小连"参考"都当不了**，判"编进去没"只能看**串 / 选择器 / md5**。

### 六、真机验机（装完看这 8 条）

1. 列表每行最上面的小字是不是中文名 —— 重点看**云闪付 / 米家 / 京东 / 小红书**
2. 「设置 → 已安装 App 枚举诊断」里有没有「**名字来源：系统名 N / Info.plist N / 兜底末段 N**」这一行；**兜底末段应该很小**
3. 若还有某个 App 显示 bundle 末段 ⇒ 诊断会列出它的 bundle id（`兜底的 bundle：…`），把那一行发我
4. 搜「米家」「云闪付」应该能搜到（App 名匹配，v0.0.42 的成果）
5. 切到「只看未读」，底部**不该**出现「下面还有 N 条」（除非未读真的超过 2000）
6. 底部出现时，在「只看未读」下文案是「更早的**未读**记录」
7. 连续快速输入 4 个字，列表只刷新一次（防抖，v0.0.42 的成果）
8. 顶部提示条 / 图标栏红点 / 删除单条 / 清空都没被带坏

## v0.0.44 · App 名用桌面短名 + 搜索命中高亮 + 导出 CSV

这一版三件事都是用户点名要的（或点名嫌弃的）。

### 一、App 名：改成桌面图标底下那个短名

用户原话：「**app 名字简单就可以了，比如追剧日历就追剧日历，京东就京东，
不用把后面的都带上，就跟桌面上显示的 app 名称一样就行了**」。

#### 关键在于：**不是截断字符串**

第一反应会是"遇到 `-` 就取前半段"，但那会把 `WPS Office` 削成 `WPS`
—— 用户要的是"短的那个名字"，不是"把这个名字切短"。

系统注册表里本来就有两套名字：`localizedName`（完整显示名，常带
「-购物商城」这类后缀）和 `localizedShortName`（桌面/搜索里那个短标签）。
⇒ 把短名**放进候选**，让 `NBPickName` 自己挑。

`NBPickName` 现在是两档规则：

1. **有汉字 > 没汉字**（v0.0.43 那档，保留）
2. **都有汉字 ⇒ 取更短的**（v0.0.44 新增）⇒ 「京东-购物商城」自然输给「京东」

两个边界都守住了：

- 有汉字仍压过没汉字 ⇒ 不会为了求短把中文换成英文（`UPay` 干不掉「云闪付」）
- **都没汉字时不比长度**，保持候选顺序 ⇒ `WhatsApp` 不会被某个内部短名干掉

诊断把「短名」单独计一档（`名字来源：短名 N / 系统全名 N / Info.plist N / 兜底末段 N`），
下回名字再不对，一眼能看出是"短名本身就是那个"还是"完整名没被短名压住"。

### 二、搜索命中高亮

起因：搜索现在能命中**标题 / 正文 / 副标题 / App 名**四处，列表却一个字都不标
⇒ 用户看到一条"标题里根本没有这个词"的记录，第一反应是"搜索坏了"。

实现上有两个坑，都不是"写个 attributedString"就能绕过去的：

1. **高亮依赖"原始串 + 搜索词"两样东西，而它们由两个不同 setter 给**
   ⇒ `NotifyCell` 改成"先存原始串、最后统一渲染"（`nbRender` 是唯一写字出口），
   谁先调都一样。
2. **复用池里两个都要清**：只清 `.text` 不清 `attributedText` ⇒ 上一行的黄底跟着复用过来；
   只清 `attributedText` 不清原始串 ⇒ 下一行若先调 `setHighlightQuery:` 会显示上一条的标题。

另外两处细节：只改**背景色不动字号**（换字号会让整行基线抖动）；
匹配口径（`CaseInsensitive | DiacriticInsensitive`）和 `bundlesMatchingSearch:` 一致。

### 三、导出 CSV

入口：导航栏「导出」（在「诊断」和「清空」中间）。导出的是**当前筛选**的那批
（App 图标 + 时间窗 + 搜索 + 未读），走系统分享面板交出去。

#### 🔴 最容易犯的那个错：拿带 LIMIT 的查询去导出

`queryWithBundle:` 带 `LIMIT listLimit`（2000）。直接拿它导出 ⇒
**备份文件里会"刚好少掉最旧的几千条"，而用户拿到手时根本看不出来** ——
这正是备份功能最不能犯的错：你以为备份了，其实没有。

⇒ 新增 `exportRowsWithBundle:`，和列表查询**唯一的区别就是不带 LIMIT**，
WHERE 仍然走同一个 `NBPrepareScope`（导出的 = 看到的那批）。
行解析抽成 `NBAppendRow` **一份**（列表和导出共用 —— 两处抄列号必有一处漏改）。

#### CSV 那几处"错了不报错"的地方

| 点 | 不做会怎样 |
|---|---|
| **先翻倍引号、再整体包引号** | 顺序反了会多出一堆 `"`；不翻倍 ⇒ 正文里有引号时整行列错位 |
| **BOM** | 没有它 Excel 打开中文全是乱码，用户只会说"文件坏了" |
| **CRLF** | 部分工具把整份 CSV 当成一行 |
| **完整日期 `yyyy-MM-dd HH:mm:ss`** | 列表里省掉年份是为了省地方，备份不能省 |
| **文件名带时间戳** | 同一天导出两次会互相覆盖 —— 覆盖上一次的备份是最不能犯的错 |
| **确认框报"筛选下总数"** | 拿 `items.count` 就会少算（列表被 LIMIT 截过），v0.0.35 `onClear:` 的老坑 |

#### 工程上唯一的坑（第三次撞）

`application.mk` **不会**自动收目录里的新文件 ⇒ `app/NotifyExport.m` 必须手工加进
`NotifyBoxApp_FILES`，否则编译期过、**链接期** `undefined symbol _OBJC_CLASS_$_NotifyExport`
（v0.0.28、v0.0.33 各栽过一次，这是第三次）。

### 四、判据

| 腿 | 结果 |
|---|---|
| 源码判据 | **71 条全绿**；变异 **33/33**、0 跳过；反向对照（`bff7303`）**52 条红** |
| 结构体检 | **108/108**（新增：静态高亮函数的形参/实参、导出类的 .h↔.m 对账） |
| 包级判据 | **53 条全绿**；反向对照（v0.0.43 的 deb）**23 条红** |
| CI | **#88**（`run_id 40108678599`，head `18763f9d186b`）一次编译过 |
| deb | **117434 B**，md5 `74435ab9c4c0682fce42c2064b22e736`；zip 117624 = API size ✅ |
| 远端 | 代码 `18763f9d186b` = 本地 `6c0798108c32`，12 文件逐 blob 一致 |
| 改动 | 10 文件 **+304 / −49**（+2 新文件） |

#### 4.1 判据自己踩的坑（三条，全是"判据读了别处的同一个词"）

| 变异 | 为什么没被抓住 | 修法 |
|---|---|---|
| 某个 label 被赋成 `nil` | 判据数的是 `attributedText` 这个词，而 `= nil;` 那一行**也有**它 | 改数 `NBHighlight(` |
| 导出不挂 popover | 判据看"文件里有没有 `popoverPresentationController`"，而 `onDiag:` 本来就挂过 | 改成盯 `doExport` 的**方法体** |
| CSV 行尾改成 LF | 判据看"在不在"，而表头后面和每行后面**各有一处** CRLF | 改成数"两处都在" |

⇒ 同一条纪律的第三、四、五例：**判据读的那个量，必须只在"它想证的那件事"发生时才成立**。

### 五、第十二次大小记账：这次两个方向又不一样

| 二进制 | v0.0.43 | v0.0.44 | 变化 |
|---|---|---|---|
| App | 367216 B | **384512 B** | **+17296 B** |
| tweak dylib | 160544 B | 160544 B | **0 B** |

上一版是"改 310 行、两个都 0 B"，这一版是"App 涨了 17 KB、dylib 一个字节没动"。
⇒ **大小只能当记录，不能当判据**。

### 六、真机验机（装完看这 7 条）

1. 列表最上面那行小字：**京东**而不是「京东-购物商城」、**追剧日历**而不是带后缀的那个
2. 「设置 → 已安装 App 枚举诊断」里「名字来源：短名 N / …」—— **短名那一档应该是大头**
3. 搜「验证码」：标题/正文/App 名里命中的字有黄底
4. 清空搜索框 ⇒ 黄底全部消失（不能留着复用过来的高亮）
5. 快速滚动一屏 ⇒ 没有"某几行带着上一条的黄底 / 上一条的标题"
6. 点「导出」⇒ 确认框报的条数 ≥ 列表条数；导出的 CSV 用 Excel/Numbers 打开**中文不乱码**
7. 同一天导出两次 ⇒ 两个文件名不同（时间戳）

## v0.0.45 · App 名改由 SpringBoard 代读 + subtitle 单独成行 + 批量清理 + 记录上限对齐

用户原话：「**京东还是不止只显示京东两个字，信息 app 也不是显示信息**」，
外加一句「顺便把剩下的几个功能都做了」。

### 一、App 名：连着三版没修好，病根不在"用哪个字段"

| 版 | 改法 | 结果 |
|---|---|---|
| v0.0.42 | 列表显示 App 名（用 `localizedName`） | 云闪付/米家显示英文名 |
| v0.0.43 | 逐键 `@try` + 汉字优先 + 多来源 | 仍然是「京东-购物商城」 |
| v0.0.44 | 加 `localizedShortName` +「都有汉字取更短」 | **没变** |

三版都在**盒子 App 进程里**打转，没碰一个前提：

> **盒子 App 是一个有沙盒的 App**。

名字最权威的来源不是 `LSApplicationProxy.localizedName`（那是 App Store 的**商品名**，
常带「-购物商城」这类副标题），而是 **App 自己 bundle 里本地化过的
`CFBundleDisplayName`** —— 那才是 SpringBoard 画在图标底下的那个字。
而桌面上的用户 App 装在 `/var/containers/Bundle/Application/<UUID>/Xxx.app`，
**沙盒 App 读不到那一层**。

⇒ 正解不是"在没权限的地方再猜一轮"，而是**让有权限的进程把名字算好送来**。

#### 做法

1. 抽出 `NBAppName.h/.m`（tweak 与 App **共用一份**，不然又变成两处抄两遍）。
2. tweak 注入的是 SpringBoard（有权限）⇒ 开机后 **8 秒、后台线程、整段 `@try`**
   枚举并把结果写进新增的 `app_names` 表。
3. 盒子 App 四级优先：**表 > 本轮精修 > 本进程枚举 > bundle 末段**。

三条安全约束一条都不能省：必须后台线程（这里是 SpringBoard 的构造函数，
主线程卡住是白苹果）、必须延迟（刚启动注册表还没建好）、必须整段 `@try`
（名字是锦上添花，不许把通知录制拖下水）。

#### 顺带修掉 v0.0.44 的一个**反向** bug

v0.0.44 写成"手上已经有汉字就不去读 bundle"。后果：系统给的「京东-购物商城」
一进场就把真名「京东」**挤掉了**。

> 是否去读 bundle 只该由「**值不值这个 I/O**」决定，不该由"现在已经拿到什么"决定。

#### 诊断加了两条能定位的东西

- `名字表（tweak 写入）：N 个` —— 表里到底有没有东西
- `来过通知的 App 最终名：bid=名 | …` —— **直接把最终显示的名字打出来**，
  下回再说"名字不对"，一眼能看出是"表里就是那个值"还是"表没写、走了兜底"
- `读不到名字的原因：路径为空 N / Info.plist 读不出 N / 无名字键 N` ——
  以前只能看到"Info.plist 那一档是 0"，分不清是路径键读不到、沙盒挡住、还是里面没名字

### 二、subtitle 单独成行

以前 `subtitle` **只在"正文为空"时顶替正文** ⇒ 而正文为空是少数情况，
绝大多数记录的 subtitle **一个字都显示不出来** —— 数据层有（v0.0.42 已加进 LIKE，
搜得到）、视图层没有。

现在单独成行（iOS 通知就是「标题 / 副标题 / 正文」三行）。
两个细节：

- **行高不变（仍 98）** —— subtitle 抢的是正文的竖向空间（正文两行 40pt →
  副标题 16pt + 正文 34pt），没有副标题时布局完全回到原样。
  不这么做的代价是"为了偶尔才有的一行把整屏都撑高"。
- **排除"副标题和正文一模一样"**（不少 App 两处填同一段）⇒ 否则等于把正文复制一遍。
- 正文为空时**仍然**由副标题顶替（不重复显示两遍）。

### 三、批量清理

设置页新增「批量清理记录」（排在「清空全部记录」**上面** —— 更常用、更安全）。
四个维度：7 天前 / 30 天前 / 全部已读 / 某个 App。

- 确认框报的数走 `countForDeleteWithBundle:beforeTs:readOnly:`，
  **不拿列表条数**（列表带 `LIMIT 2000`，v0.0.35 的 `onClear:` 就是这么栽的）。
- 🔴 **拒绝"无条件全删"**（三个条件都空时返回 -2）：那是 `clearAll` 的活。
  宁可让调用方多走一步，也不留一条"参数拼错了就清空用户所有记录"的路。
- 删完必须**整表重查**，不许 `deleteRowsAtIndexPaths:`（搜索态下标 ≠ 库 id）。
- 「删了个空」要**明确说出来** —— 静默成功会让用户以为删掉了，回头一看还在。
- 「按 App」只列**来过通知的** App（没来过通知的删了也是 0 条，
  列进来只会变成几百项的滚动地狱），且封顶 12 个（这是删除操作，清单越长越容易点错）。

### 四、记录上限对齐

`maxRecords` 的上界从 `100000` 收到 `kNBRMaxRecordsHardCap`（20000）。
100000 是个"反正没人会填"的占位，但它意味着用户可以设一个
**列表永远显示不完**的上限（`listLimit` 是 2000）⇒ 库里常年堆着几千条
只能靠导出才看得见的记录。

同时把这句话**写进设置页说明**：「列表一次最多显示 2000 条：上限填得更大时，
更早的记录翻不到，要用首页的『导出』才能看到」。
不写这句，用户填了 99999 会以为自己留了 10 万条 —— 那正是本项目最忌的
"两个指标互相矛盾"。

### 五、判据

| 腿 | 结果 |
|---|---|
| 源码判据 | **81 条全绿**；变异 **21/21**、0 跳过；反向对照（`5d59ef8`）**78 条红**（3 条是守卫） |
| 结构体检 | **63/63**（括号配平 + 声明↔实现对账 + 重复符号） |
| 包级判据 | **37 条全绿**；反向对照（v0.0.44 的 deb）**28 条红**（9 条是守卫） |
| CI | **#90**（`run_id 40113249997`，head `54ff7dbedd58`）一次编译过 |
| deb | **124448 B**，md5 `ef1ea71630fc4ea36913995aa151a2f3`；zip 124639 = API size ✅ |
| 远端 | 代码 `54ff7dbedd58` = 本地 `2daebcc867f5`，**57 文件逐 blob 一致** |
| 改动 | 12 文件 **+1004 / −330**（+2 新文件 `NBAppName.h/.m`） |

#### 5.1 判据自己踩的坑（四条）

| 坑 | 现场 | 修法 |
|---|---|---|
| **Z3e：读了别处的同一个词** | `n = (NSInteger)sqlite3_changes(db);` 在 `clearAll` 里也有一处 ⇒ 判据恒绿 | 锚点带上"下一句是批量删除的失败日志" |
| **Z4①：查词存在性** | 只查 `[NotifyStore saveAppNames:refinedNames]` 在不在 ⇒ 变异把 `if (refined)` 改成 `if (NO)` 后仍绿 | 连**触发条件**一起钉住 |
| **Z4⑧：否定式 + 对象不存在** | `NBAppName.m` 是新版才有 ⇒ 反向对照时内容为空 ⇒ `not has(...)` 恒真 | 否定式一律带前置 `t and …` |
| **期望写错（不是代码错）** | 判据写成"⛔ 不再有 `else if (subtitle.length)` 那个分支" ⇒ 假红 —— 那个分支**必须保留**（正文为空时副标题顶替正文） | 改成盯"正文非空时 subtitle 也会显示" |

#### 5.2 包级又踩两次「搜不到」

1. **`pick()` 用了 `.lower()`** ⇒ `.../NotifyBoxApp.app/NotifyBoxApp` 变成
   `notifyboxapp`，而传入的 `suffix` 有大写 ⇒ App 二进制取成 **0 字节**
   ⇒ 所有 App 侧判据**全部假红**。
2. **含中文的 ObjC 字面量整体存 UTF-16** ⇒ `NotifyBox v0.0.44` 这行日志里混着中文，
   连里面的 ASCII 部分用 UTF-8 都**永远搜不到**（实测 v0.0.44 的 dylib 里 0 次）
   ⇒ 只能拿那行**纯 ASCII** 的版本串（`=== [%@] v0.0.44 %@ ===`）当判据。

### 六、第十三次大小记账

| 二进制 | v0.0.44 | v0.0.45 | 变化 |
|---|---|---|---|
| App | 384512 B | **385200 B** | +688 B |
| tweak dylib | 160544 B | **161376 B** | +832 B |
| deb | 117434 B | **124448 B** | +7014 B |

这次两边都涨了一点（tweak 首次编进名字解析、App 加了 subtitle/批量清理），
但 **deb 涨 7014 而两个二进制只涨 1520** ⇒ 大小依然只能当记录，不能当判据。

### 七、真机验机（装完看这 8 条）

1. **京东**显示「京东」而不是「京东-购物商城」；**信息** App 显示「信息」
2. 「设置 → App 枚举诊断」里 `名字表（tweak 写入）：N 个` —— **N 不该是 0**
   （装完要**重启一次 SpringBoard / 重锁屏**才会触发那次后台解析）
3. 同一份诊断里 `来过通知的 App 最终名：…` 那一行，看京东/信息后面的值对不对
4. 若仍不对：看 `读不到名字的原因：` 那一行是「路径为空」还是「Info.plist 读不出」
5. 有 subtitle 的记录：**副标题单独一行**（标题下面、正文上面），行高不变
6. 快速滚动 ⇒ 没有"某几行凭空空出一行"（`prepareForReuse` 没清 `rawSubtitle` 的症状）
7. 「设置 → 批量清理记录」→ 选「删除 7 天前」⇒ 确认框的条数 ≈ 你预期；
   删完「剩余 N 条」会变
8. 记录上限填 99999 ⇒ 保存后会被**回落成 500**（上界现在是 20000，超出/非数字都回落）

## v0.0.46 · 统计视图：哪个 App 最烦人 + 一天里什么时候最吵

v0.0.45 把"剩下的几个功能"（批量清理 / 记录上限对齐 / subtitle 单独成行）做完了；
经确认下一步做 **A 统计视图**——纯读、风险最低：哪个 App 通知最多、一天里哪个时段最吵。

> 本版**只动盒子 App**，tweak 侧零逻辑改动（只是升版本号 + 头注说明）。
> 所以 v0.0.45 那套"App 名由 SpringBoard 代读"的机制**原封不动**，
> 这一版的统计页读名字也走同一条 `InstalledApps`（含名字表）通道。

### 一、数据层：三条统计 SQL 都收在 NotifyStore

| 方法 | 干什么 | 关键口径 |
|---|---|---|
| `statsBundlesSince:limit:` | 哪个 App 最烦人 | `GROUP BY bundle ORDER BY COUNT(*) DESC`，`LIMIT` 只看前若干 |
| `statsBucketsSince:byHour:` | 一天/一月的分布 | 按小时用 `localtime`；按小时时**补满 24 个桶**（凌晨也占一格） |
| `statsSummarySince:` | 总数 / 未读 / App 数 / 最早时间 | 总数与未读**同一条 SQL** 出（`SUM(CASE WHEN read=0 …)`） |

踩过的口径坑（都是以前翻过车的）：

- **总数与未读必须同一条 SQL 出**，不许分成"先查总数、再查未读"两次 ——
  两次查询之间库可能变，两个数字就对不上（本项目最忌"两个指标互相矛盾"）。
- **时间桶用 `localtime`，不用 UTC** —— 用户看的是本地钟。
- **空表时 `MIN(ts)` 的 NULL 不能当 1970 显示** ⇒ `if (ts > 0)` 拦截。
- **`since` 与列表同口径**（`ts >= ?`），不然统计窗和列表窗对不上。
- 共用一个 `NBRows` 取行助手 + **构造 block**（不是谜语般的 BOOL 参数），避免漏 `sqlite3_finalize`。

### 二、视图层：NotifyStatsViewController

- 三个维度分段：**按 App / 按小时 / 按天**；时间窗分段：**全部 / 7 天 / 30 天**。
- 条形：**分母是本屏最大值且防除零**（`(self.max > 0 && w > 0) ? … : 0`）。
  0 条的行**只藏填充、底槽仍在**（`barFill.hidden = (n <= 0)`），不留"空了一截"。
- 复用池 `prepareForReuse` **清三样**（名字 / 条数 / 条长）—— 不然快速滚动会串行。
- 小时显示成**时间段**（`%02ld:00 – %02ld:00`），不是裸数字。
- 按 App 维度**额外显示未读**（`%ld 条 · 未读 %ld`）。
- **空数据**明确说"这个时间窗里没有记录"，不要留白底让用户以为坏了。
- 条形用 **系统蓝**（`systemBlueColor`），不套行情红绿（这里不是涨跌）。

### 三、判据

| 腿 | 结果 |
|---|---|
| 源码判据 | **48 条全绿**；变异 **14/14**、0 跳过；反向对照（拿 `2daebcc`/v0.0.45 的内容）**39 条红**、9 条守卫 |
| 结构体检 | **85/85**（括号配平 + 声明↔实现对账 + 重复符号 + 统计页类扩展对账） |
| 包级判据 | **47 条全绿**（解包搜串；p42 区分力：v0.0.45 的 dylib 因 NBLog 串必含 0.0.45，到 v0.0.46 清零） |
| CI | **#92**（`run_id 40119743515`，head `f4e2a4ae6c1f`）一次编译过 |
| deb | **129480 B**（zip 129674 = API size ✅） |
| 远端 | 代码 `f4e2a4ae6c1f` = 本地 `0526646`，**59 文件逐 blob 一致** |
| 改动 | 9 文件 **+429 / −15**（+2 新文件 `NotifyStatsViewController.h/.m`） |

#### 3.1 判据自己踩的坑（三条）

| 坑 | 现场 | 修法 |
|---|---|---|
| **Z3e：同一个 CASE 表达式有两处** | `SUM(CASE WHEN read=0 THEN 1 ELSE 0 END)` 在 `statsBundlesSince`(252) 和 `statsSummarySince`(308) 各有一处 ⇒ 变异只动 252 那处时 308 还在 ⇒ 判据仍绿、漏抓 | 锚点带 `SELECT bundle` 前缀，锁定 252 那整句 |
| **Z3e 续：同一个 `GROUP BY bundle` 有两处** | 一处是 `statsBundlesSince` 里 `appendString` 拼的 ObjC 串，另一处是老 `bundleCounts` 的 C 字符串 ⇒ 锚点命中 2 次 ⇒ SKIP（算失败） | 锚点带上 `[sql appendString:@" GROUP BY bundle ORDER BY COUNT(*) DESC"];` 这段上下文，唯一命中 |
| **首遍把类扩展方法写成 `'-name'` 字面量** | 真实签名是 `- (void)onDim:`（中间有返回类型）⇒ `'-onDim:'` 死活匹配不到 ⇒ 结构体检整片假红 | 改用 `\)\s*name` 正则，不猜字面空格 |

#### 3.2 包级又踩一次「选择器存的是完整串」

`statsBundlesSince` / `statsBucketsSince` 是**多参方法**，二进制里存的是**完整选择器**
`statsBundlesSince:limit:` / `statsBucketsSince:byHour:`，不是 `statsBundlesSince:` 独立成串。

首遍拿 `statsBundlesSince:\x00` 去搜 ⇒ **0 次** ⇒ 假红。
`statsSummarySince` 是单参，所以 `statsSummarySince:\x00` 才是对的那条。
⇒ 多参方法判据必须带全参（`…:limit:` / `…:byHour:`），别只查前半段。

### 四、第十四次大小记账

| 二进制 | v0.0.45 | v0.0.46 | 变化 |
|---|---|---|---|
| App | 385200 B | **402160 B** | +16960 B |
| tweak dylib | 161376 B | **178032 B** | +16656 B |
| deb | 124448 B | **129480 B** | +5032 B |

两个二进制各涨一万六、deb 却只涨五千 —— 又一次印证 **Z5：大小与改动量脱钩**，
只能当记录、不能当判据（deb 增量远小于二进制增量，是 lzma 压缩把新代码压扁了）。

### 五、真机验机（装完看这 7 条）

1. 「设置 → 统计（哪个 App 最烦人）」能进统计页（排在「App 枚举诊断」**上面**）
2. 按 App 维度：通知最多的 App 排最前、条形最长；未读以「N 条 · 未读 M」显示
3. 按小时维度：**24 个桶都画出来**（哪怕凌晨 0 条也占一格）；显示成「HH:00 – HH:00」时间段
4. 按天维度：能看出哪几天最吵
5. 时间窗切「全部 / 7 天 / 30 天」⇒ 数字随之变化，且与列表筛选同口径
6. 选一个没记录的窄窗（比如刚装、或某 App 很久没来通知）⇒ 显示「这个时间窗里没有记录」，不留白底
7. 快速上下滚动 ⇒ 没有"名字串到下一行 / 条数错行"（`prepareForReuse` 清三样的遗漏症状）

> 回归提醒：v0.0.46 **tweak 侧零改动**，所以 v0.0.45 的 App 名验收（京东=京东、信息=信息、
> 名字表非空）仍然有效，不必重验；若你还没重启 SpringBoard 触发那次后台解析，名字表仍是 0。

## v0.0.47 · 统计页右侧条数自适应宽度（修"显示不全"）+ 自动清理（保留最近 N 天）+ 自定义时间窗（仅统计页）

### 一、起因：两条反馈
- ① 用户反馈：统计页右侧"条数 · 未读"在内容较长时被截断、显示不全。
- ② 做 B：自动清理（保留最近 N 天）+ 自定义时间窗（仅统计页，主列表不动）。

### 二、布局修复：右侧条数标签按内容宽度自适应
- 旧：`cntW = 96` 写死，右对齐 + 尾截断 ⇒ 「300 条 · 未读 12」超宽即被切。
- 新：`cntW = self.cntLabel.intrinsicContentSize.width`，给名字留最小 80pt；超出只截断右侧标签本身，绝不挤压名字到看不见。
- 判据：源码 b16（intrinsicContentSize 自适应 + 不再写死 96）。

### 三、B-1：自动清理（保留最近 N 天）
- 设置项「自动清理：保留最近 N 天（0=关闭）」，默认 0 = 关闭。
- App 启动时 `AppDelegate` 调一次 `[NotifyStore runAutoClean]`；days>0 时把早于 `now - days*86400` 的记录整批删掉（连未读一起，复用 `deleteWithBundle:nil beforeTs:cutoff readOnly:NO`）。
- days=0 时零开销（直接 `return 0`、不打日志）。
- 上限 3650 天（10 年），防止手滑填天文数字清空库。
- 与"记录上限"（按条数裁）是两件独立的事，可同时开。

### 四、B-2：自定义时间窗（仅统计页）
- rangeSeg 第四段「自定义」弹 `NBDateRangeViewController`（UIDatePicker 日期模式，起止两个）。
- `completion` 把起止写回 `customSince` / `customBeforeTs`；`cancelBlock` 把分段切回「全部」（避免"标着自定义却显全部"的矛盾）。
- `beforeTsFromSeg` 仅「自定义」段返回 `customBeforeTs`，其余段上界不限；`reloadData` 把 `before` 透传给三个统计方法（`statsBundlesSince:beforeTs:limit:` / `statsBucketsSince:beforeTs:byHour:` / `statsSummarySince:beforeTs:`）。
- 选择器上界 = 结束日 + 1 天 0 点（闭区间语义，让"结束日当天"整日都包含）。

### 五、判据
- 结构体检 102/102（含 ObjC 多参签名跨行匹配、类方法 +/- 判定）。
- 源码判据 65/65；变异 24/24（0 跳过、0 漏抓）。
- 反向对照（拿 v0.0.46 源码跑 v0.0.47 判据）：24 红 / 41 绿 —— 红的全是新增项，绿的全是守卫，无永远绿。
- 包级判据 55/55；反向（拿 v0.0.46 的 deb）16 红 / 39 绿。
- 自踩三坑：
  - ① ObjC 方法签名可跨行（`statsBundlesSince:(NSTimeInterval)since` 与 `beforeTs:` 不在同一物理行）⇒ 判据查"各参数关键字都在"，不查整串连续。
  - ② 多参选择器二进制存完整串（`statsBundlesSince:beforeTs:limit:`），且 v0.0.47 把它从两参升到三参 ⇒ 包级判据必须跟到三参串。
  - ③（编译期才暴露）NSString 字面量里内嵌直线双引号 `"` 会提前终止字符串 ⇒ 编译失败。CI 首次跑挂，定位到第 268/269 行说明文案；改全角「」。教训：串内嵌引号必须用全角或 `\"` 转义，判据层（`strip_strings` 会清空串内容）盖不住这类错，编译/真机才是硬闸门。

### 六、第十五次大小记账
| 二进制 | v0.0.46 | v0.0.47 | 变化 |
|---|---|---|---|
| App | 402160 B | 419040 B | +16880 B |
| tweak dylib | 178032 B | 178032 B | 0 B |
| deb | 129480 B | 132212 B | +2732 B |

App 涨一万七（新增自动清理 + 自定义窗 + beforeTs 接线），dylib 一字未动 —— 因为新代码只在盒子 App 被引用，tweak 侧死代码消除后体积不变。又一次印证 Z5：大小与改动量/方向都不线性，只能当记录。

### 七、真机验机（装完看这 6 条）
1. 统计页右侧「N 条 · 未读 M」再长也完整显示（不再被切）。
2. 设置里「自动清理：保留最近 N 天」填 7 ⇒ 重启盒子后，7 天前的记录整批消失（含未读）。
3. 统计页时间窗选「自定义」⇒ 弹起止日期选择器；选好 ⇒ 统计只落在所选区间；取消 ⇒ 分段自动回到「全部」，不卡在"自定义"。
4. 自定义区间的"总条数/未读/覆盖 App/最早"与按 App/小时/天三个维度，都只显示区间内数据（与列表口径一致）。
5. 自动清理 + 记录上限可同时生效，互不干扰。
6. 回归：tweak 侧零改动，v0.0.45/46 的 App 名验收仍有效；自定义窗只影响统计页，主列表不变。

> 回归提醒：v0.0.47 **tweak 侧零改动**，App 名、名字表、SpringBoard 代读验收同 v0.0.46，不必重验。

## v0.0.48 · 关键词自动规则（标星 ★ + 自动折叠）

### 一、起因
- 下一批功能选定「C 工程收尾 + 关键词自动规则」；C（仓库工程审查）已审完、无代码改动，本版交付关键词规则。
- 设计确认（动手前问过）：动作 = **标星 + 自动折叠**；匹配范围 = **标题 + 正文 + 副标题 + App 名**。

### 二、功能
- 设置页新增「关键词规则」入口（排在统计下面、诊断上面）→ `KeywordRulesViewController`：
  - 右上角 + 加规则：先填关键词（自动去首尾空白），再选动作（★ 标星 / ⤓ 折叠 / ★ 标星 · ⤓ 折叠）。
  - 左滑删除；上限 20 条（和存储层闸门同一数字，两处各写一份必然对不上）。
- 匹配：四个字段（标题/正文/副标题/App 名）大小写不敏感子串（`NBContainsText`，nil 安全）—— 中文无大小写，但英文关键词（verify/code）必须命中大写的 "VERIFY"。
- **位掩码一次匹配出两个动作**：`NBKeywordAction`（Star=1<<0、Fold=1<<1），一条规则可同时标星+折叠，多条规则可叠加（星来自 A、折叠来自 B）—— 避免"标星用一套条件、折叠用另一套"两个口径互相矛盾（同"总数与未读同一条 SQL 出"的纪律）。
- ★：`NotifyCell` 右上角，默认藏（忘了调也不给所有行点星）、复用复位（防星串行）、标星时 App 名行收宽 20pt 防重叠；systemOrange（金/橙醒目，又不是行情红绿）。
- 折叠：命中行默认不进主列表；顶部提示条「N 条被关键词规则收起」可点（收起/显示切换，文案两态）；**列表被折叠空时也要说清"其实有 N 条、被规则收着"**，不让用户以为记录丢了。
- 存储：`settings.plist` 的 `keywordRules` 数组；读写**全走 NotifyStore**（清洗：丢空关键词、丢两个动作都没选的死规则、截 20 条、全删干净时键也消失不留空数组）。
- 🔴 **展示时生效、不落库**：标星/折叠是派生量（`nbStar` 只在内存行字典里）⇒ 规则改动即时生效、老记录不用重录、**tweak 侧零改动**。

### 三、判据
- 结构体检 187/187（新增规则页/自定义 cell/★/折叠提示条的 decl↔impl 对账；新锚点一律"唯一定位"）。
- 源码判据 139/139；变异 59/59（0 跳过、0 漏抓）。
- 反向对照（拿 v0.0.47 源码跑 v0.0.48 判据）：71 红 / 68 绿 —— 红的全是新增项，绿的全是旧版守卫。
- 包级判据 84/84；反向（拿 v0.0.47 的 deb）31 红 / 53 绿。
- 自踩坑（这版踩得比以往都贵，七条全记）：
  1. **行尾污染**：编辑 Info.plist / Tweak.x / control 时整文件被写成 CRLF（HEAD 是 LF）⇒ diff 整文件重写、真伪难辨。修法：从 HEAD 内容出发只施加意图编辑、保留各行原行尾；先做"忽略行尾的 diff"确认真实内容改动。
  2. **`_Nonnull` 写成 `_NonNull`（大写 N）**：不是 nullability 关键字 ⇒ 编译器当标识符 ⇒ block 字面量报 `expected ')'`（CI #97）。括号配平盖不住 ⇒ 立 q- 判据逐文件扫 `_NonNull(?![a-z])` + 变异 m58。
  3. **setter 里写 `self.starred = starred;` = 无限递归**（CI #98，clang `-Wunused-property-ivar` 逮到"ivar 没在 accessor 里引用"才知道）⇒ 直接写 `_starred`；k02 判据加反递归否定式 + 变异 m59 把递归写回去必须被抓住。
  4. **否定式判据被自己的注释喂失败**：k02 查"不许出现 `self.starred = starred;`"，而注释里正引用着这串 ⇒ 恒假。否定式一律先剥注释再查。
  5. **包级假绿三条**（反向对照抓到，全是"绿的原因不对"）：「★」只 2 字节 UTF-16，在 UTF-16 块里按对齐撞假命中（旧包也绿）；`systemOrangeColor` 旧版 AppPicker/ReplaceRules/Settings 早就在用；`onAdd:` 是 ReplaceRulesViewController 的选择器。⇒ 全删，★ 的包级覆盖交给 `setStarred:` + 「标星」中文串。
  6. **包级串合并**：相同字面量被链接器合并成一份（「★ 标星 · ⤓ 折叠」两处用例包里只 1 次）⇒ 计数判据只能按 ≥1 发；且 `nbStar` 键在包里是 **ASCII C 串**不是 UTF-16（UTF-16 形式 0 命中）⇒ 判据按实际编码发，先 probe 再立判据。
  7. **static 函数名不进二进制**：`NBContainsText` 在 App/dylib 各 0 命中（被内联、无符号残留）⇒ 包级只认选择器/类名/串，不认 static 函数名。

### 四、第十六次大小记账
| 二进制 | v0.0.47 | v0.0.48 | 变化 |
|---|---|---|---|
| App | 419040 B | 436032 B | +16992 B |
| tweak dylib | 178032 B | 194640 B | +16608 B |
| deb | 132212 B | 137314 B | +5102 B |

dylib 这次涨了（前两版都 0 B）：`NotifyStore.m` 两边同编，规则层约 66 行进了 tweak 那一份 —— 虽然 **tweak 逻辑零改动**。Z5 再次应验：大小与改动量/方向都不线性，只能当记录、不能当判据。

### 五、真机验机（装完看这 8 条）
1. 设置页出现「关键词规则」入口（统计下面、诊断上面），点进去是空说明页（不是白屏）。
2. + 加一条「验证码」→ ★ 标星 ⇒ 回主列表，标题/正文/副标题/App 名含"验证码"的行右上角出现 ★（大小写不敏感："VERIFY"也中）。
3. 同一条规则改选「⤓ 折叠」⇒ 命中行从列表消失，顶部出现「N 条被关键词规则收起」；点它 ⇒ 收起的行显示出来、文案变"（显示中，点此隐藏）"；再点藏回去。
4. 选「★ 标星 · ⤓ 折叠」⇒ 既标星又收起；点提示条显示后能看到 ★。
5. 把规则设成命中库里所有记录并选折叠 ⇒ 列表空时显示"暂无记录"**外加一句**"N 条被关键词规则收起，点上面的提示可以显示"（不误导成"没数据"）。
6. 改规则动作 / 删规则 ⇒ 回主列表**立即**生效，不用重启、不用重新记录。
7. 底部「还有 N 条」在折叠开启时仍然对（按折叠前条数算，不把收起的误算成"被列表上限截断的"）。
8. 回归：tweak 侧零逻辑改动，v0.0.45/46/47 的 App 名、自动清理、统计页、自定义时间窗验收仍有效。

> 回归提醒：v0.0.48 **tweak 侧零逻辑改动**（只升了三个 NBLog banner 的版本号），SpringBoard 代读、名字表、自动清理、统计页验收同 v0.0.47，不必重验。

## v0.0.49 · 「只看标星」筛选（第五维）+ 规则指纹修 v0.0.48 缺口 + 文档债两修

### 一、起因
- 上一批（v0.0.48）用户多选的三项里，本版交两项的代码侧：**标星筛选（轻档）** + **文档债**；图标接入等用户四选一（A/B/C/D 毛玻璃候选还没定）；「连记录都不要」开关排 v0.0.50（要动 tweak 记录层，动手前先问设计岔口）。
- 轻档方案的原话约束："标星想容易找" ⇒ 不加"标星收藏夹"那种重设计，只加一个**显示层筛选维度**——和 v0.0.38「只看未读」同源、同款实现路径。

### 二、功能
- **★ 只看标星**（`starOnly`）：分段行从两件套变三件套——「★ 标星」按钮**常驻最左**（不像全标已读按需出现），选中态只把标题换成 systemOrange（和列表里 ★ 同一套视觉）；320pt 窄屏验算 12+64+6+132+6+88=308 ≤ 320。
- 🔴 **管道顺序：star 筛选必须排在 fold 之前**（`applyKeywordRulesToRows:` 里第一道）。顺序反了会出两种错：① `foldedCount` 把"非标星且被折叠"的行也算进去 ⇒ 提示条的 N 不是"这个视图里被收起的"；② 非标星的行带着 `nbStar=NO` 混进 items ⇒ ★ 视图不纯。
- 与 `unreadOnly` **正交可叠加**（★ + 未读 = 标星且未读）。
- 点顶部提示条**清 ★**：v0.0.41 刻意不动 unreadOnly 是因为它不挡未读；★ **挡未读**（标星且未读才看得见）⇒ 不清它，用户点完提示条还是看不到承诺的那些未读，提示就成了说谎。
- 底部「还有 N 条」★ 视图改用 `queriedStarCount`（**标星后、折叠前**）——第三禁忌：底部说的集合必须和列表装的同一个集合（v0.0.48 为折叠立过同一条）。
- 🔴 ★ 视图**没有数字可报**：`nbStar` 是派生量、SQL 里没有这一列 ⇒ `countWithBundle:` 数不出"标星的还有几条"（也绝不能为了数它在 SQL 里复刻一遍关键词匹配——两套匹配逻辑必然对不上）。⇒ 只在查询窗口真被 2000 条截断时（`scopeCount > queriedCount`）出一条**无数字**提醒"更早的记录里可能还有标星的"；窗口没截断 ⇒ 这个范围内每一行都看过了，标星的一条不漏。报一个假数字比不报更糟（用户会去数，数出来不对就不再信这条提示）。
- 空视图**两种解释分开说**：有 ★ 规则但这个范围没命中 ⇒ 只解释视图语义；根本没有 ★ 规则 ⇒ 点醒去 设置 → 关键词规则 建一条（一个永远不触发还不解释的功能，比没做更糟——v0.0.39 同款纪律）。
- 导出：★ 视图导出的就是**眼睛看到的这批**（`self.items`）——按 SQL 范围导会把非标星的一起倒进文件，违背"导出我正在看的这一堆"的初衷；确认框的数 = `items.count`，和真正写进文件的条数严格相等；文件名基名「标星记录」（`csvFromRows:` 只读固定键，items 里多带的 `nbStar` 被忽略，不需要先剥）。
- 全标已读确认框追加警告「「★ 标星」视图只影响列表显示，不限制标记范围」——与搜索那条**分开写、不用 else if**（两个筛选可以同时开着，警告要同时出现；显示层筛选 vs SQL 范围的口径 v0.0.38 立过）。
- `filterDesc` 加第五维「★ 只看标星」（写在搜索之前——它筛的是行本身，比搜索更靠近列表语义）。
- 🔴 **顺手修掉 v0.0.48 的一个缺口**：`refreshIfChanged` 现在比**规则指纹**（`lastRules` 内容深比较，不比 mtime——App 内改、Filza 手动改都算）。规则在 `settings.plist` 不在库里 ⇒ 原来只比分率和 MAX(id) 的话，"改完规则回列表"看到的是旧状态：v0.0.48 验机第 6 条"立即生效"在这个缺口下**并不成立**（只是当时还没真机验到）。★ 视图对规则的依赖更直接：建完 ★ 规则回来点 ★，列表必须是新的。
- 文档债两修（不 Rewrite 历史）：① README 开头功能清单删"延迟推送"（v0.0.19 已整体删除，两版实现各撞崩一次 SpringBoard——别再当待办）；② v0.0.7「没接线」状态表加**带日期的后续状态补记**（白黑名单关键词 v0.0.8 接线、内容替换 v0.0.14、朗读 v0.0.12/13、换提示音 v0.0.25、延迟推送 v0.0.19 已删）。

### 三、判据
- 结构体检 **223/223**（v0.0.48 的 187 条全留 + 新增 36 条：★ decl↔impl/锚点 + 版本四件套）。
- 源码判据 **161/161**；变异 **76/76**（0 跳过、0 漏抓，新增 m60–m76）。
- 反向对照（拿 v0.0.48 树 `c771dcb` 跑）：**26 红 / 135 绿**——红 = 20 条新增 + l04/l09 随实现更新 + n07–n10 版本；绿 = 全部旧守卫 + r22/r23 两条"不落库"否定式。
- 包级判据 **100/100**；反向（拿 v0.0.48 的 deb）**20 红 / 80 绿**——红 = 版本 5 条（p01/p40/p41/p42/p43）+ ★ 新增 15 条（p122–p136），绿 = 旧守卫 + p137 否定式。
- 自踩坑（两条，第二条比第一条贵）：
  1. **CI #101 编译错：`redefinition of 'base'`**——`doExport` 里把 `base` 的赋值挪进 if/else 两分支后，`writeTempCSV:` 前那句旧 `NSString *base = …` 没删。本地无 Mac/clang ⇒ **编译只有 CI 能验**；静态判据链（223/161/76）盖不住这类错——它们查"该在的在不在"，不查"能不能编译"。⇒ 新铁律：**在一段函数里新增局部变量后，先 grep 这个名字在不在本函数已有声明里**。
  2. 🔴🔴 **包级判据工具自己的 `--against` 从 v0.0.45 起就是死的**：v0.0.45 把脚本重构进 `main()`+CHECKS 结构时，把"交换主/基准 deb"那一步弄丢了 ⇒ 该分支一直拿**新包**跑同一批判据、然后无条件 `return 0` = **恒绿**。本轮按 usage 跑出"0 红"当场露馅（★ 新判据在旧包上本该一片红）。修法：真的解包对照 deb、拿它跑全部判据；期望"一片红"，**0 红 = FAIL（判据没有区分力）**。⇒ Z4 新形态：**不是判据写错，是判据工具自身坏掉——比没有判据更坏**。v0.0.45~0.0.48 的 README 反向数字是真的（当时拿旧 deb 直接跑正向模式得到的），但旗标本身从没工作过。

### 四、第十七次大小记账
| 二进制 | v0.0.48 | v0.0.49 | 变化 |
|---|---|---|---|
| App | 436032 B | 452640 B | +16608 B |
| tweak dylib | 194640 B | 194640 B | **0 B**（tweak 侧零逻辑改动，只升三个 NBLog banner 的版本号） |
| deb | 137314 B | 138296 B | +982 B |

App 涨的 16608 B 与 v0.0.48 的 dylib 涨幅相同——`NotifyStore.m` 两边同编的老现象（Z5：大小与改动量/方向都不线性，只作记录、不能当判据）。

### 五、真机验机（装完看这 9 条）
1. 分段行最左出现常驻「★ 标星」按钮；**没有 ★ 规则时**点它 ⇒ 空列表 + "去 设置 → 关键词规则 添加一条带「★ 标星」动作的规则"（不是白屏、不是"暂无记录"）。
2. 建一条带 ★ 标星的规则 ⇒ 回主列表点「★ 标星」⇒ 列表只剩命中行（和只看未读同时开时是"标星且未读"）。
3. 底部「还有 N 条」在 ★ 视图下按标星后、折叠前算；库里 >2000 条且更早处有标星时出**无数字**版提醒"更早的记录里可能还有标星的"，范围没截断时这条不出现。
4. 点顶部提示条（筛选之外还有未读那条）⇒ ★ 被清掉、切回全部——它挡未读，不清则提示条说谎。
5. 改规则动作 / 删规则 ⇒ 回主列表**立即**生效（规则指纹参与重查判定——v0.0.48 缺口在本版修掉）。
6. ★ 视图点导出 ⇒ 确认框写"将把 ★ 标星视图下的 N 条记录导出成 CSV"，导出的文件里正是这 N 条、文件名「标星记录」。
7. ★ 视图点全标已读 ⇒ 确认框里同时有搜索警告（若开着搜索）和「★ 标星」视图只影响列表显示、不限制标记范围；标记后未读的**非标星**记录也被标了（符合警告所述）。
8. 折叠提示条在 ★ 视图下只数标星的行（和列表同口径）。
9. 回归：tweak 侧零逻辑改动 ⇒ v0.0.45/46/47/48 的 App 名、自动清理、统计页、自定义时间窗、关键词规则验收仍有效。

### 六、交付
| 腿 | 结果 |
|---|---|
| CI | **#101 failure**（`redefinition of 'base'`，clang 逮到）→ 修复提交 **#102 success**（`run_id 40152878482`，head `e1c1efda3c`） |
| deb | **138296 B**（zip 138491 = API size ✅） |
| 远端 | 代码 `e1c1efda3cc9` = 本地 `413da2fb30c3`，**61 文件逐 blob 一致** |
| 改动 | 功能提交 5 文件 **+218 / −43** + 修复提交 1 文件 **−2** |
| 包级 | 正向 100/100；反向（v0.0.48 deb）20 红 / 80 绿 |

> 待办：① 图标接入等用户四选一（A/B/C/D）；② v0.0.50「连记录都不要」开关动手前先问设计岔口（全局 vs per-规则）；③ v0.0.48 真机验机 8 条 + 本版 9 条待用户回收。

## v0.0.50 · 桌面图标接入（四选一，用户选了 D 毛玻璃闭合盒）

### 一、起因
- 上一批用户多选的「图标接入」：四张候选（A 紫渐变开盖盒 / B 青蓝气泡盒 / C 毛玻璃开盒 / D 毛玻璃闭合盒）都已去水印、1024×1024 展示过，用户选 **D**。
- D = 正面闭合盒 + 气泡、青蓝光晕，和参考图同一套风格语言（深灰几何 + 磨砂面板 + 彩晕）；圆角由 SpringBoard 自动加，图内**不自带**圆角（自带会被系统再缩一层、边缘发虚）。
- 格式：RGB 无 alpha（PNG colortype 2）——图标最稳的格式。

### 二、改动（既定五步）
1. `Resources/AppIcon.png`（从 `dist/icons/icon-D-glass-box-bubble.png` 复制，gitignore 只挡 `dist/`，Resources/ 正常进仓库）。
2. `Resources/Info.plist`：`CFBundleIcons → CFBundlePrimaryIcon → CFBundleIconFiles=["AppIcon"]`（**不带扩展名**，系统自己补 .png）。
3. `Makefile`：`NotifyBoxApp_RESOURCES = Resources/AppIcon.png`。
4. 版本 0.0.50（control + Info.plist 两处 + Tweak.x 三个 banner；tweak 侧零逻辑改动）。
5. 🔴 **本版唯一可能"静默不生效"的点**：theos 的 application.mk 只打包 `FILES` 里的 .m 和 `INFOPLIST`——`Resources/` 下其他文件**不显式声明就不进包**；而 plist 里的 CFBundleIcons 指向一个包里不存在的文件时，SpringBoard **不报错、没日志**，静默 fallback 到默认图标。⇒ 包级判据 p138（deb 的 App bundle 里有 AppIcon.png）+ p139（与仓库逐字节 md5 一致）就是钉这个；装完不换图标，先查这两条，再怀疑别的。

### 三、判据
- 结构体检 **231/231**（新增 icon50-* 六条：文件存在/PNG 签名/1024×1024/plist 三键/Makefile 声明）。
- 源码判据 **163/163**；变异 **78/78**（0 跳过 0 漏抓；新增 m77/m78：plist 丢 CFBundleIcons、Makefile 丢资源声明，分别被 n13/n14 抓住）。
- 反向对照（拿 v0.0.49 树 `6b54c6d` 跑 v0.0.50 判据）：**6 红 / 157 绿**——红 = 版本四条 + 图标两条。
- 包级判据 **104/104**；反向（拿 v0.0.49 的 deb）**10 红 / 94 绿**——红 = 版本七条（p01/p02/p40/p41/p42/p43/p136）+ 图标三条（p138/p139/p140）。
- 顺带：包级 `--against` 工具 v0.0.49 修好后再立新功——新判据先拿**旧 deb 试跑 8 红**证明有牙（期望表纪律：该几条红是动手前算出来的，不是跑出来的）。

### 四、第十八次大小记账
| 二进制 | v0.0.49 | v0.0.50 | 变化 |
|---|---|---|---|
| App | 452640 B | 452640 B | **0 B**（版本号同长度） |
| tweak dylib | 194640 B | 194640 B | **0 B**（tweak 侧零逻辑改动） |
| deb | 138296 B | 1085600 B | **+946904 B**（图标 937892 B + tar 开销） |

⇒ Z5 第十四个实例：一个"纯资源"版本让 deb 涨 **7.9 倍**，两个二进制一动不动。大小与改动量不仅不线性，连"哪个部件涨"都指不准。

### 五、安装与真机验机（3 条）
1. 装完 **uicache**（或 respring）刷图标缓存——不刷的话 SpringBoard 可能还显示旧默认图标（不是没装上）。
2. 桌面图标变成 D（青蓝光晕闭合盒 + 气泡）；App 内部（列表/设置页）样子不变，只换桌面图标。
3. 回归：v0.0.45~0.0.49 各项不受影响（tweak 侧零逻辑改动，只升了三个 NBLog banner 的版本号）。

> 刷完缓存还是默认图标时的排查顺序：① `dpkg -c deb` 或包级判据 p138 看包里有没有 `AppIcon.png`；② p140 看 bplist 里有没有 `CFBundleIcons`；③ 都不是再怀疑 uicache 没刷。本版把 ①② 做成了机器判据，就是为了不让你靠猜。

### 六、交付
| 腿 | 结果 |
|---|---|
| CI | **#104**（`run_id 40155091918`，head `e68435d670`）一次过 |
| deb | **1085600 B**（zip 1086507 = API size ✅） |
| 远端 | 代码 `e68435d670eb` = 本地 `dc66b48`，**5 文件逐 blob 一致**（含二进制 AppIcon.png） |
| 改动 | 5 文件 **+27 / −9**（+1 新文件 `Resources/AppIcon.png`） |

> 下一版预告：v0.0.51「连记录都不要」已定设计 = **per-App 名单**（设置页勾选哪些 App 不落库；闸门加在 Tweak.x `recordWithBundle:` 之前，只掐"记"这一路，过滤/替换/换声/朗读照跑）。



## v0.0.51 · 「连记录都不要」per-App 名单（tweak 侧 v0.0.45 以来第一次逻辑改动）

### 一、起因
- v0.0.50 交付后向用户确认「连记录都不要」开关的作用域，用户选 **per-App 名单**（不是全局、不是按通知类型）。
- 🔴 语义（最要紧）：命中的 App **连记录都不落库**，但**不影响呈现** —— 过滤/替换/换声/朗读照跑，通知照弹。这**不是**「第二个黑名单」：
  - 黑名单拦的是「呈现」（记录早已落库，盒子里仍看得到，v0.0.8 立的口径：「记录永远存原始通知，过滤只改屏幕呈现，不污染记录」）；
  - 这个名单拦的是「记录」本身 —— 用户要的是「这个 App 别在我盒子里留任何痕迹」。

### 二、改动（既定六步）
1. `NotifyCommon.h`：新增 `NB_KEY_NO_RECORD_APPS = @"noRecordApps"`（数组或 `"a,b"`，空/缺失 = 全部记录）。**唯一权威、App 写 tweak 读**，单一来源（防两处各写一个字符串对不上）。
2. `NotifyFilter.m`：新增 `shouldSkipRecordForBundle:` —— 读 noRecordApps、走 `arrayFromPref:`（数组/逗号串两种历史格式都认）；`@try/@catch` 判错回 **NO 照常记**（宁可多记一条，不吞记录）。紧贴 `shouldDropBundle:` 放（两个名单语义相反，放一起看清分工、改一个会看见另一个）。
3. `Tweak.x`：NBRecordItem 在 `NBClaimKey` **之前**、`recordWithBundle:` **之前**加闸门 —— 返回 **bid**（不是 nil：下游过滤判定还要用、呈现层照常工作）；三个入口（BBServer / SpringBoard / 其他）过同一条闸门，行为一致。
4. `AppPickerViewController`：新模式 `NBAppPickModeNoRecord = 5`；`keyForMode` / `titleForMode` / 页脚说明三处 case 全接线（🔴 漏一个静默回落 whitelist，正是该文件顶部记过两次的那类后门）。
5. `SettingsViewController`：设置页独立一区「不记录的 App（连记录都不留）」排在「推送拦截」之前；副标题计数「已选 N 个 › / 全部记录 ›」；hint 说清与黑名单分工。
6. 版本 0.0.51（control + Info.plist 两处 + Tweak.x 三个 banner；tweak 侧**有**逻辑改动，头注如实写）。

### 三、判据
- 结构体检 **249/249**（v0.0.50 判据全留作回归守卫 + v0.0.51 新增 22 条：nr51-* 16 + ver51-* 6）。
- 源码判据 **176/176**；变异 **84/84**（0 跳过 0 漏抓）；反向对照（拿 v0.0.50 树 `dc66b48` 跑 v0.0.51 判据）**17 红 / 159 绿** —— 红 = 版本四条（n07~n10）+ 新判据九条（n15~n23）+ 功能四条（r24~r27）。
- 包级判据 **112/112**（版本六条随实现更新 + 新增 8 条 p142~p149：shouldSkipRecordForBundle: 选择器 ×2、noRecordApps 键 ×2、UI 文案 ×2、dylib 反向 ×2）；反向（拿 v0.0.50 的 deb）**12 红 / 100 绿** —— 红 = 版本族 6 + 新增 6 条存在型（p142~p147）；p148/p149 是否定式守卫（dylib 不该含 UI 串），旧版 dylib 本来就没有 ⇒ 旧版上绿才对，不算红。
- 顺带钉死一条假绿：r25 最初单查 `NSString *bid = bundle.length ? bundle : @"";` 在旧版 `shouldDropBundle:`（149 行）就有 ⇒ 旧版上恒绿、无区分力（Z4⑨ 同族）；改成「bid 行 + noRecordApps 读取」两行绑定才只认新方法。

### 四、第十九次大小记账
| 二进制 | v0.0.50 | v0.0.51 | 变化 |
|---|---|---|---|
| App | 452640 B | 469232 B | **+16592 B**（新增判定方法 + 设置页 + UI 串） |
| tweak dylib | 194640 B | 194640 B | **0 B**（新增选择器 + 闸门调用被段对齐填充吃掉） |
| deb | 1085600 B | 1086670 B | **+1070 B** |

⇒ Z5 又两个实例：① dylib 加了一个判定方法 + 一个调用，字节数**纹丝不动**（194640）——段对齐 padding 把新增吃掉了，大小连"新增字节数"都不等于；② deb 涨 1070 B，远小于 App 净增的 16592 B——新增的选择器/字符串和二进制里已有的强匹配，gzip 压掉了大半。大小与改动量不线性、连"哪个部件涨"都指不准，只能信字节对拍。

### 五、安装与真机验机（5 条）
1. 装完 uicache / respring（deb 没动图标，这步和 v0.0.50 无关，纯习惯）。
2. 设置页出现「不记录的 App（连记录都不留）」新区（在「推送拦截」之前），副标题默认「全部记录 ›」。
3. 点进去勾一个常用 App（如信息/短信）⇒ 副标题变「已选 1 个 ›」；返回后该 App 通知**照常弹出**（呈现不受影响）。
4. 该 App 之后的新通知**不进盒子**（盒子里搜不到、统计里也没有）；**已有的记录不受影响**（想清已有的走「批量清理 / 清空全部」）。
5. 取消勾选 ⇒ 恢复记录（闸门不再拦，落库恢复）。

> 运行时验证只能靠「勾了之后盒子收不到」这条肉眼证据——闸门命中没有专门日志（NBRecordItem 已有 counter 节流日志，但闸门本身不加 log，避免每条通知刷屏）。包级判据 p142 证明 dylib 里**真的有** `shouldSkipRecordForBundle:` 选择器（tweak 真调了它），但「运行时走到」得靠真机。

### 六、自踩（v0.0.51 判据链踩的坑）
1. 生成器把 `ctl` / `tw` 两个文件加载行误删（NEW12 空替换）⇒ 结构体检 `NameError: tw`。
2. 嵌套 lambda 作 `ck(` 参数少一个右括号（隔离测试没外层调用看不出，作参数时报「'(' was never closed」）。
3. `ck('r26', ...` 漏收尾 `)`（ck( 不闭合）。
4. n22 查错文件（枚举在 .h、case 在 .m；结构体检 nr51-mode 已管 .h，源码判据只验 .m 两 case）。
5. 🔴 r25 假绿（Z4⑨ 同族）：锚点 `NSString *bid = bundle.length ? bundle : @"";` 旧版 `shouldDropBundle:`（149 行）就有 ⇒ 旧版上恒绿；修法 = 与 noRecordApps 读取两行绑定。
6. 旧版本变异 m55/m56/m71 锚点还停在 0.0.50 ⇒ SKIP 算失败；随实现更新（m71 与 m55 逐字重复，删一条）。
7. m16 期望表修正：`#define` 宏是单一来源，`.m` 用宏名不用字符串 ⇒ 串值拼错碰不到 `.m`、功能照常（这正是单点定义的设计意图，不是判据漏抓）。

### 七、交付
| 腿 | 结果 |
|---|---|
| CI | **#106**（`run_id 40157439756`，head `6174401595`）一次过 |
| deb | **1086670 B** |
| 远端 | 代码 `6174401595` = 本地 `43d0ec3`，**9 文件逐 blob 一致** |
| 改动 | 9 文件 **+103 / −10**（tweak 侧 v0.0.45 以来第一次逻辑改动） |


## v0.0.52 · 删除盒子记录时同步清系统通知中心（精确 1:1）

### 一、起因
- 用户确认需求：不是「发布时按 App 拦」，而是**删除反向同步** —— 在盒子上删掉一条记录时，如果该通知在系统通知中心（锁屏 / 列表 / 横幅）还挂着，就一并从系统通知中心删掉。
- 粒度：用户选「**精确 1:1 删这条**」 —— 记录时存系统 bulletin 唯一 ID，删盒子某条就只删系统里那一条（最贴合原话），而非按 bundle 整段清或手动按钮。
- 查过现成越狱插件：BadgeSync（`com.newwares.badgesync`）做的是「用户在通知中心手动划掉通知时减角标」，反向、不主动移除通知，对本需求无帮助 ⇒ 走自建 BBServer 方案。

### 二、改动（既定步骤 + 实际落点）
1. `NotifyCommon.h`：新增 `NB_KEY_SYNC_CLEAR = @"syncClearNC"`（布尔，默认关）、`NOTIFYBOX_NC_CLEAR_DARWIN = @"com.yxh41.notifybox.ncClear"`（Darwin 通知名，不带 payload）、`NOTIFYBOX_NC_CLEAR_REQ = @"/var/mobile/Library/NotifyBox/nc_clear_req.plist"`（共享请求文件）。单一来源，防两处各写一个字符串对不上。
2. `NotifyStore.h` + `.m`：
   - `recordWithBundle:title:message:subtitle:date:` 扩成 `...:date:sysId:`；INSERT 加 `sys_id` 列。
   - `openDB` 建表加 `sys_id TEXT`；**老库迁移**用 `PRAGMA table_info(notifications)` 探测后 `ALTER TABLE … ADD COLUMN sys_id TEXT`（SQLite 不支持 `ADD COLUMN IF NOT EXISTS`）。
   - `deleteRow:` 删前读 `bundle`+`sys_id`，删成功且开关开且 sys_id 非空 ⇒ 调 `nbRequestClearNCWithSysId:bundle:`（写请求文件 + post Darwin）。
   - `clearAll` / `deleteWithBundle:beforeTs:readOnly:` 显式**不触发**同步清（语义是「清日志」，且批量逐条发请求危险 / 无意义）。
3. `Tweak.x`：
   - `NBRecordItem` 记录时读系统 bulletin ID（`bulletinID` → 回退 `notificationIdentifier`，嵌套 `.bulletin` 再读一遍），传 `sysId`。
   - 三个发布入口开头 `NBCaptureServerIfNeeded(self)`：在 publish hook 里（即 BBServer 内部队列上）capture `self` + `dispatch_get_current_queue()`，**绕开 extern __BBServerQueue 全局符号**（iOS 16 可能未导出，链接失败会进安全模式）。
   - `%ctor` 在 SpringBoard 注册 `CFNotificationCenterAddObserver`（Darwin 通知 → `NBClearNCCallback`）。
   - `NBClearNCCallback`：读请求文件，在 captured 队列上 `dispatch_sync` 调 `[gBBServer _clearBulletinIDs:@[sysId] forSectionID:bundle shouldSync:YES]`；**`respondsToSelector:` 守卫**，本机没有该方法 ⇒ 打日志跳过（不崩）。
   - `NSObject (NBClearNC)` 分类声明 `_clearBulletinIDs:forSectionID:shouldSync:`（消编译警告；运行时仍靠 `respondsToSelector:` 守卫）。
4. `SettingsViewController`：设置页新增「删除盒子记录时同步清系统通知中心」开关（默认关）；`NB_KEY_SYNC_CLEAR` 加进 `onSave` 保存数组（🔴 漏加 = 开关不落盘，老教训 s0x）。
5. 版本 0.0.52（control + Info.plist 两处 + Tweak.x 三 banner + 头注如实写：tweak 侧有逻辑改动）。
6. 判据 + CI + 本 README 章 + memory 实现记录（本步）。

### 三、判据（锚点清单，跑常规 nb_push_api + CI 机器对拍）
编译期 / 静态：
- 版本四条：control `Version: 0.0.52`、Info.plist `CFBundleVersion`/`CFBundleShortVersionString` = 0.0.52、Tweak.x 三 banner 含 0.0.52（含新增的「同步清通知中心」banner 占位）。
- 功能存在型：
  - `NotifyCommon.h` 三个新 `#define`（syncClearNC / ncClear / nc_clear_req.plist）。
  - `Tweak.x` 含 `NBCaptureServerIfNeeded`、`NBClearNCCallback`、`NSObject (NBClearNC)`、三入口各自 `NBCaptureServerIfNeeded(self)`。
  - `NotifyStore.m` 含 `recordWithBundle:...sysId:`、`nbRequestClearNCWithSysId:bundle:`、`ALTER TABLE … ADD COLUMN sys_id`、`_clearBulletinIDs:forSectionID:shouldSync:`。
  - `SettingsViewController.m` 含「删除盒子记录时同步清系统通知中心」文案 + 保存数组含 `NB_KEY_SYNC_CLEAR`。
- 变异 / 反向（按前版纪律）：拿 v0.0.51 树跑 v0.0.52 判据应红（版本族 + 新功能存在型）；变异锚点必须唯一命中（==1，否则 SKIP 算失败）。
- 包级反向：旧 deb 不该含新选择器 `NBClearNCCallback` / 新 UI 串；新 deb 必须含。
真机运行时（**编译判据盖不住，只能真机验**）：
- ① iOS 16 上 `bulletinID` 属性名是否对（回退 `notificationIdentifier` 兜底）；
- ② 本机 BBServer 是否真有 `_clearBulletinIDs:forSectionID:shouldSync:`（无则日志 `[NC-CLEAR] 本机 BBServer 无 … ⇒ 跳过（不崩）`，功能优雅失效）。

> 🔴 两个真机点若不准，表现不是崩，是「盒子删了、通知中心没动」 —— 所以验收口径必须是**看系统通知中心那条是否消失**，而不是看日志里有没有 `[NC-CLEAR] 已清`。

### 四、大小记账
- 待 CI 出包后回填（dylib 净增一个分类声明 + 一个 capture + 一个回调 + 几个字符串；App 净增一个开关行 + UI 串；历史多次验证「大小与改动量不线性」，以字节对拍为准，Z5）。

### 五、安装与真机验机（6 条）
1. 装完 uicache / respring。
2. 设置页出现「删除盒子记录时同步清系统通知中心」开关，默认关；打开它。
3. 等某 App 来一条通知（确认盒子里有这条、系统通知中心也挂着它）。
4. 在盒子 App 里左滑删除**那一条**记录 ⇒ 系统通知中心**同一条**应消失（锁屏 / 通知列表 / 横幅 whichever 挂着）。
5. 关闭开关再删 ⇒ 盒子记录没了，系统通知中心**不动**（验证开关真的控制行为）。
6. 「批量清理 / 清空全部」不碰通知中心（设计如此：那是清日志，不是清系统通知）。

### 六、风险与自踩（v0.0.52 设计期已排的雷）
1. 🔴 **绕开 `extern __BBServerQueue`**：iOS 16 该全局符号可能未导出，tweak 加载链接失败 ⇒ 直接进安全模式。改在 publish hook 里 capture `self` + `dispatch_get_current_queue()`，零外部符号依赖。
2. 🔴 **`_clearBulletinIDs:` 本机可能不存在**：必须 `respondsToSelector:` 守卫 + 日志；不存在就优雅跳过，绝不把「我以为有」变成闪退 / 安全模式。
3. 🔴 **跨进程通道**：盒子 App 与 SpringBoard 原本无任何通道。Darwin 通知（不带 payload）+ 共享 plist 外带「要删哪个」 —— 机制成熟、不需 entitlement。
4. 🔴 **只单条触发、批量 / 全不清**：共享请求文件是单文件、会被覆盖；批量逐条发请求既无意义又危险，且批量 / 全清语义是「清日志」。开关只对 `deleteRow:` 生效。
5. 🔴 **bulletinID 属性名跨代不一致**：先 `bulletinID` 后回退 `notificationIdentifier`，嵌套 `.bulletin` 再读；读不到留空 ⇒ 功能自动失效，不影响记录。
6. 🔴 **`dispatch_sync` 到 BBServer 队列**：回调在 CF 通知线程，必须 `dispatch_sync` 到 captured 队列才能调 `_clearBulletinIDs:`；队列为空（还没捕获过，即用户还没收到过任何通知就删）时日志跳过，不崩。

### 七、交付
- 待 nb_push_api + CI 跑通后回填（CI run_id / deb 字节 / 远端 blob 一致 / 改动文件数）。

---

## v0.0.53 → v0.0.59 · 从「日志说调过了」到「真删掉了」

v0.0.52 做的是「盒子删记录 → 系统通知中心那条也删」。功能代码一次写对，**API 选错了**，
后面七版全在纠这一个错。这一章把整条路记下来，免得以后再走一遍。

### 一句话结论

iOS 16 上删单条通知的正确姿势：

```objc
// 1) 按 ID 取真实 BBBulletin 对象 —— 🔴 返回的是 NSSet，不能下标
id set   = [bbServer _bulletinsForIDs:@[bulletinID]];
id bullet = [(NSSet *)set anyObject];
// 2) 按对象删（这一步会走 observer 广播，界面跟着消失）
[bbServer _removeBulletin:bullet shouldSync:NO];
```

`_clearBulletinIDs:forSectionID:shouldSync:` **不是干这个的**：它清的是 section 的
cleared-info（"已读/已清理"记录）。方法存在、能调、不抛异常、日志也写了"已调"——**但通知不会消失**。

### 走过的弯路（每一版都留下一块判据）

| 版本 | 做法 | 结果 | 真正的教训 |
|---|---|---|---|
| v0.0.52 | `_clearBulletinIDs:...` | 通知不消失 | 「能调、不抛」证明不了「它干的是这件事」 |
| v0.0.53 | 想枚举 live ID 反查 | `_bulletinIDsForSectionID:` / `bulletinIDsForSectionID:` **iOS 16 都不存在** | 名字不能推导，必须 dump |
| v0.0.54 | 清单打进日志 | 一行都看不到 | 日志窗口只剩最后几十行，长表装不下 |
| v0.0.55 | 清单加类型签名 | 同上 | 有签名也救不了"看不到" |
| v0.0.56 | 清单写独立文件 `nc_diag.txt` | ✅ 一次拿全 | 探针产物要落**文件**，别塞日志 |
| v0.0.57 | 按清单试 withdraw 系 | 全失败 | 🔴 `_bulletinsForIDs:` 返回 **NSSet**，`bs[0]` 抛异常 ⇒ 最有希望的一步**没被执行** |
| v0.0.58 | 修 NSSet + 一步一量 + NC 原生路径 | ✅ **第 1 步就中** | 「没效果」不能推出「API 不行」，先查脚本自己走通没有 |
| v0.0.59 | 只修结论措辞 | ✅ | 见下 |

### 真机数据（v0.0.58，三条 App 全中）

```
workbuddy  删前 live=50 含本条=是 → ① _removeBulletin:shouldSync:NO → live=49 含本条=否
TIM        删前 live=2  含本条=是 → ① → live=1  含本条=否
微信        删前 live=17 含本条=是 → ① → live=16 含本条=否
```

第 ②~⑥ 步（`_removeBulletins:` / `withdraw…WithRecordID` / `withdraw…WithPublisherID` /
`withdrawBulletinID:` / NC `withdrawNotificationWithRequest:`）**一次都没轮到**，
作为「第 1 步失败时」的兜底保留。

### 三条判据纪律（这次踩出来的）

1. 🔴 **一步一量**。把多个 API 串在一起调，等于放弃归因：既不知道谁有用，也不知道到底有没有用。
   每步之后立刻按同一口径量一次，`★本条已消失` / `（没删掉）` 直接写在日志里。
2. 🔴 **判据要找「我们这一条」，不是「总数少了一个」**。v0.0.57 看到 live 50→49 差点收口，
   但那 13 秒里用户自己划掉一条也会 50→49。
3. 🔴 **结论措辞必须等于它真正证明的事**（三态）：
   - `本来就不在段内`（App 被点开过，系统早清了）→ 我不能报"已删除"
   - `本次已删掉（第 N 步生效）`
   - `仍在段内（六步全部失败）`

   v0.0.58 的日志里 13 条有 10 条属于第一种，却统一打印「已从段内消失」——
   看着像 100% 成功，其实只动了 3 条。这是本项目「八种假绿」的第 ⑧ 型变体。

### 覆盖边界（不是 bug）

- **只对「通知中心里还在的」生效**。App 被点开过 / 用户划掉过 / 系统过期清理过，
  该通知早就不在 BB 里了，此时删盒子记录不会（也无法）影响通知中心。
- **v0.0.52 之前录的老记录删不掉**：`sys_id` 是 v0.0.52 新增的列，之前录的行该列为空。
- 批量入口（按 App 清、清空全部）**刻意不触发**同步清：逐条发请求会互相覆盖共享请求文件。
  要支持的话得改成队列，不是现在这条路。

### 附：诊断文件 `nc_diag.txt`

`/var/mobile/Library/NotifyBox/nc_diag.txt`。首次删除时写入 BB / NC / UNC 三层候选类的
**完整方法表**（实例方法 + 类方法 + 类型签名，一条一行、按名排序、不筛关键字），
之后每次删除只在末尾追加一段「尝试记录」（删前基准、每步结果、结论）。
排障时把这个文件整份发出来就够，不用翻日志。

同时记下一条读方法表的经验：段标题会写 `+ 无方法(共0)` ——
`NCNotificationDispatcher` 就是这样，**它没有任何类方法**，拿不到单例，
实例只能在 `NCBulletinNotificationSource - initWithDispatcher:observer:queue:` 里接住。

## v0.0.60 → v0.0.61 · 「BB 账本删掉了」不等于「界面消失了」

用户装上 v0.0.58/v0.0.59 后实测回传一句话：

> **「没有消失，是不是因为没真正删除啊啊」**

而日志里写得很漂亮：`删前 live=50 含本条=是` → `删后 live=49 含本条=否`，三组数据全中。

**这就是本项目最贵的一课的第 N 次重演：自证里的数对了 ≠ 界面上发生了。**

### 病因两条，都是判据自己的问题

1. 🔴 **量错了层**。`BBServer - _allBulletinsForSectionID:` 量的是 **BB 账本**；
   用户眼睛看的是 **NC 界面**（`NCBulletinNotificationSource` → `NCNotificationDispatcher`）。
   账本干净了，界面可以一点不动。
2. 🔴 **早停把唯一能动界面的那一步跳过了**。v0.0.58 的逻辑是「第 ① 步让计数变了 ⇒ `still=NO` ⇒ 停手」，
   于是第 ⑥ 步（NC 原生撤回）**一次都没执行**。
   「变了就停手」这种过早收口，等于用第一条（必然先成功的）证据把后面的证据全掐掉了。

### v0.0.61 的做法

**分两层量、分两层动手、取消一切早停。**

```objc
BOOL bbIn = NO, ncIn = NO;
NSInteger bbN = NBLiveScan(gBBServer, bundle, cid, &bbIn);   // BB 账本
NSInteger ncN = NBScanNC(gNCSource, cid, &ncIn);            // NC 界面（bulletinsToUUIDs）
```

四步全跑完，每步之后立刻复量同层：

| 步 | 动作 | 量哪层 |
|---|---|---|
| ① | `[source observer:[source observer] removeBulletin:bullet]` | NC |
| ② | `[dispatcher withdrawNotificationWithRequest:真request]` | NC |
| ③ | `[server _removeBulletin:bullet shouldSync:NO]` | BB |
| ④ | `[server _clearBulletinIDs:@[cid] forSectionID:bundle shouldSync:NO]` | BB（补刀，不改界面） |

结论五态，**必须分别说 BB 与 NC**：

```
两层本来都没有（已被 App/用户清掉，无需处理）
两层都已删掉（第 N 步起效）
BB 已删、NC 仍在 ⇒ 界面不会变（正是你看到的现象）   ← v0.0.58/59 的真实状态
NC 已删、BB 仍在（少见，需再查）
两层都还在（全部失败）
```

### 🔴 顺序：先 NC、再删账本

`observer:removeBulletin:` 的第一个参数、以及 `bulletin` 本身，都必须是**还有效**的对象。
v0.0.60 一开始把它排在 `_removeBulletin:` 之后 —— 传进去的是已经失效的 bulletin，
多半就是它一次都没生效的另一半原因。所以：

1. 第 ①/② 步在账本还干净之前先跑；
2. 第 ③ 步删账本之前**重新 `_bulletinsForIDs:` 取一次对象**，不用旧指针。

### 真机 dump 核实过的签名（不是猜的）

从 `nc_diag.txt` 里逐条对过，这四步用到的都在：

| 类 | 方法 | 类型 |
|---|---|---|
| NCBulletinNotificationSource | `observer` | `@@:` |
| NCBulletinNotificationSource | `setObserver:` | `v@:@` |
| NCBulletinNotificationSource | `observer:removeBulletin:` | `v@:@@` |
| NCBulletinNotificationSource | `bulletinsToUUIDs` | `@@:` |
| NCBulletinNotificationSource | `uuidsToRequests` | `@@:` |
| NCNotificationDispatcher | `withdrawNotificationWithRequest:` | `v@:@` |

`observer:removeBulletin:` 就是 `BBObserverDelegate` 那条 ⇒ 第一个参数是 BBObserver，
用 `- observer` 取。这一步**不需要 dispatcher、也不需要 request**，只要 source + bulletin。

### 判据（唯一有效的那个）

```
删后 NC 含本条=否      ← 只有这个「否」代表界面上会变
删后 BB 含本条=否      ← 只代表账本干净；v0.0.58/59 已经"绿"过两次，是假绿
```

### 包内对拍（v0.0.59 → v0.0.61，CI #117）

```
deb 1,093,438 B  md5 9598c099b44de4c30dd91c67f2caf5a0
① 新增锚点（旧=0 且 新>0）  9/9 真锚点
   NotifyBox v0.0.61 / v0.0.61 请求 / BB 已删、NC 仍在 / 两层本来都没有
   删前 BB: live= / NC 映射= / observer:removeBulletin: / bulletinsToUUIDs / uuidsToRequests
② 共有锚点（两版都有，只证"包是我们编的"）
   withdrawNotificationWithRequest: / _removeBulletin:shouldSync: / _bulletinsForIDs:
③ 反向对照（旧>0 且 新=0）  2/2 成立
   本来就不在段内（…） / NotifyBox v0.0.59
```

顺带记一条：**dylib 体积 211,824 B，和 v0.0.60 一模一样（delta = 0）**，
而源码动了 1.5 KB。体积连趋势都不可信，判"编进去没"只认串 / 选择器 / md5。

### 已知风险（这一版是试验性的）

第 ① 步 `observer:removeBulletin:` 是**第一次**在 BBServer 队列里调 NC 侧方法。
v0.0.59 已经在这个队列里调过 `withdrawNotificationWithRequest:`（没卡死），
所以风险不高；但如果装上后出现**桌面卡住 / 频繁 respring**，
直接回退 v0.0.59（`_removeBulletin:` 那步确定不卡，只是界面不动）。

## v0.0.62 · 卡屏注销：跨子系统调用必须回到它自己的队列

v0.0.61 装上后用户回传两件事：

> **「还是没效果，而且会造成卡屏一段时间后注销」**

### 先查痕迹，别先查结论

```
nc_diag(3).txt 里 grep：
  'NC 映射' = 0    'observer=' = 0    'BB 已删' = 0    'v0.0.61' = 0
记录条数 = 14，最后一条是 08:48，措辞还是 v0.0.59 的三态
```

**一条 v0.0.61 的记录都没有。** 而我的 `NBDiagAppend(rec)` 写在整段流程**末尾**
⇒ 卡死时一行都没落盘 ⇒ 故障发生了、却什么都看不到。

**这比 bug 本身更坏。** 从这一版起定成纪律：

> **写前日志**。任何"可能把进程搞死"的路径，诊断必须在**动手之前**逐步落盘，
> 不许"跑完再一次性写"。

### 根因（结构性，不用猜）

v0.0.61 新加的三个 NC 动作，全都跑在 **BBServer 的队列上**：

| 动作 | 子系统 |
|---|---|
| `NBScanNC` → `[source bulletinsToUUIDs]` | NC |
| `[source observer:obs removeBulletin:bullet]` | NC |
| `[dispatcher withdrawNotificationWithRequest:req]` | NC |

NC 侧的锁与 BB 侧锁序相反 ⇒ 互相等待 ⇒ 主线程被拖住 ⇒ 看门狗杀进程 ⇒ 「卡一会儿然后注销」。

🔴 **v0.0.59 为什么不卡**：它的早停逻辑让这些 NC 调用**一次都没执行**。
v0.0.61 拆掉早停，就把一直藏着的地雷踩响了。**「以前不崩」不等于「那行代码没问题」。**

### 🔴 新纪律

> **跨子系统的调用，必须回到那个子系统自己的队列上执行。**
>
> 判据很简单：`initWithDispatcher:observer:queue:` 把 `queue` 递给你，
> 就是系统在说「以后要跟我说话，请在**这条**队列上说」。
> 拿到队列却不用、自己找一条队列调，等于自造死锁。
> **抓不到那条队列 ⇒ 宁可不调**，也不许在主链路队列上碰它。

### v0.0.62 的具体做法（API 一个没换，只改队列和时机）

1. 捕获 `gNCSourceQueue`（hook `initWithDispatcher:observer:queue:` 的第 3 个参数）。
2. **取消所有 `dispatch_sync`**，三段 `dispatch_async`：

```
BB 队列：选 cid → _bulletinsForIDs: 取 bulletin → 量 BB
   └─ NC 队列：量 NC → ① observer:removeBulletin: → ② withdraw → 复量 NC
         └─ BB 队列：③ 重新取对象 → _removeBulletin → ④ _clearBulletinIDs → 拼结论
```

   **谁的队列测谁的东西**：BB 的量在 BB 队列上做，NC 的量在 NC 队列上做。
3. `NBDiagStep()`：每步做完立刻 append 一行。
4. 三个「不调」的护栏，每条都写进 diag：`gNCSuppressed` / 没抓到 NC 队列 / `ncq == gBBServerQueue`。

### 卡死自恢复（复用「朗读自愈」那套思路）

| 文件 | 作用 |
|---|---|
| `.nc_pending` | 进 NC 路径前写，两步跑完立刻删。**留到下次开机 = 上一次卡死了** |
| `.nc_off` | 开机看到 `.nc_pending` 还在 ⇒ 建这个 ⇒ **永久禁用 NC 路径**（只删 BB 账本：不卡，但界面不变）。删掉它 + respring 可重新尝试 |

设计取向写在最前面：**先保证手机能用，再谈功能。**
一个会把桌面卡死的功能，比不做这个功能更糟。

### 包内对拍（v0.0.61 → v0.0.62，CI #118）

```
deb 1,095,002 B  md5 90b1978bbc53f370c33027183c4bb576  control Version: 0.0.62
dylib 212,000 B（0.0.61 = 211,824，delta +176）

① 新增锚点（旧=0 且 新>0）  10/10
   NotifyBox v0.0.62 / v0.0.62 请求 / v0.0.62 async / [NC队列] 删前 NC 映射=
   [guard] 已写 .nc_pending / [guard] NC 两步跑完 / ncQueue=%@ / .nc_pending / .nc_off / 上次 NC 路径卡死过
② 共有锚点  4/4   observer:removeBulletin: / withdrawNotificationWithRequest: /
                  _removeBulletin:shouldSync: / BB 已删、NC 仍在
③ 反向对照  2/2   NotifyBox v0.0.61 / ① 跳过（没取到有效 bulletin 对象）
不合格 0
```

### 这一版的正确验收顺序

1. **还会不会卡屏 / 注销** —— 比"删没删掉"优先。
2. 没卡 ⇒ 看 `nc_diag.txt` 新增段里的 `①` / `②` 两行与 `删后 BB含=? NC含=?`，
   **只有 `NC含=否` 才算界面会变**。
3. **又卡了** ⇒ 手机会自己写下 `.nc_off`，下次开桌面不再卡（不会反复）。
   把 `nc_diag.txt` 发来即可 —— 这次一定能在最后一行看到死在哪一步。

## v0.0.63 · 不造 request、四种比法全试、映射形态 dump 出来

v0.0.62 真机回传（`nc_diag(4).txt`）两条记录，四行关键日志：

```
环境 source=NCBulletinNotificationSource dispatcher=NCNotificationDispatcher ncQueue=有 抑制=否
[guard] 已写 .nc_pending，进 NC 队列
[NC队列] 删前 NC 映射=1062 含本条=否
① NC observer:removeBulletin ⇒ NC 映射=1061 含本条=否
uuid=(无) req=有(工厂新造)      ← 第一条记录到此为止
```

第二条记录只有到 `[guard]` 就没了 —— **连 `[NC队列] 删前` 都没打印**。

### 三条结论

**① 卡屏/注销修好了。** NC 调用搬回 NC 自己的队列之后，流程跑到 ① 并正常返回（1062→1061）。
「**跨子系统调用必须回到它自己的队列**」这条纪律成立。

**② 新的卡死点是 ② `withdrawNotificationWithRequest:`，元凶是"工厂新造的假 request"。**
铁证就是第二条记录：它排在死块后面，**永远轮不到** ⇒ 整条 NC 队列被上一条堵死。

> 🔴 造一个系统不认识的 request 去撤回 = **把别人的队列卡死**。
> 「照着类工厂造一个对象」看着最保险，实际是最危险的做法之一。

**③ 映射匹配不上。** 1062 条里按 key 比对前后都是「否」⇒ `uuid=(无)`。
而 `1062→1061` 少的那条**未必是我们这条** ⇒ 「少一条」当判据是假的。

### v0.0.63 的改法

| 改动 | 为什么 |
|---|---|
| `NBMakeNCRequest` **恒返回 nil** | 只接受真 request；没有就跳过 ②。函数留着只为留注释 |
| ② 前加 `sectionIdentifier` 校验 | 真 request 也可能不属于这个 App，映射匹配错就会误删别人的通知 |
| `NCMatchEntry` **四种比法全试** | ① key 是字符串 ② key 的 `bulletinID`/`publisherBulletinID`/`recordID` ③ value 是字符串（方向相反）④ key 的 description 包含 |
| `NBScanNC2` 同时读**两张**映射 | `bulletinsToUUIDs` 条数 + `uuidsToRequests` 条数 + 是否命中 + uuid，diag 多记一个 `req数=` |
| `NBDumpNCMapsOnce` | 一次性 dump 两张映射前几对的**类名+描述** ⇒ 下一版不用再猜 key 是什么 |
| 护栏文件写**版本号** | 只有同一版本卡死才继续禁用 ⇒ **每个新版本自动获得一次重试机会** |

最后一条是修上一版的设计缺陷：v0.0.62 卡死留下的 `.nc_off` 会一直压着新版，
**明明修好了也测不到**。

### 包内对拍（v0.0.62 → v0.0.63，CI #119）

```
deb 1,096,232 B  md5 b07d5310e4e30eb8ae2c02d1a164bf47  control Version: 0.0.63
① 新增锚点（旧=0 且 新>0）  11/11
② 共有锚点  4/4
③ 反向对照  2/2   NotifyBox v0.0.62 / ② 跳过（拿不到 request）
不合格 0
```

🔴 **dylib 212,000 B，与 v0.0.62 分毫不差（delta=0）**，而源码改了 4.4 KB。
体积这个指标第 N 次被证伪 —— 判"编进去没"只认串 / 选择器 / md5。

### 下一次要看的三个位置

1. `[map] bulletinsToUUIDs 共 … 前 3 对：k[…]=…  v[…]=…` —— **key 到底是什么形态**。
   看完就能定死匹配规则，不用再试四种。
2. `② 候选 request=有/无`：
   - 还是 `无` ⇒ 真 request 拿不到，得换路（从 dispatcher 的 `destinationsRegistry` 里取）；
   - `有` ⇒ 看 `② NC withdraw` 那行有没有让 `含本条` 变「否」。
3. `req数` 前后变化 —— 判断我们这条到底动没动（防「少一条」假绿）。


---

## v0.0.64 —— 进 NC 队列必死：元凶是 `description`；顺手补上一条从没执行过的官方撤回

### 真机回传 `nc_diag(5).txt`：一组数字就够定案

把 22 条记录按「有没有进 NC 队列」分两堆：

| 分组 | 条数 | 结果 |
|---|---|---|
| 进了 NC 队列 | **9** | 9 条全部没回来，**连第一行都没打印** |
| 走「缺一 ⇒ 跳过 NC」 | **12** | 12 条全部走完，结论齐全 |
| 其它 | 1 | — |

一条卡住可以叫偶然，9/9 就只能是必然：**死的位置在 NC 块的第一句**。
而那一句里，v0.0.63 唯一新增的动作是 `NBDumpNCMapsOnce` —— 它调了 `[k description]` / `[v description]`。

### 结论：绝不对未知类调 `description`

`BBBulletin` / `NCNotificationRequest` 的 `-description` 会摸内部锁，
或者递归描述整包 payload。在 NC 队列上调它 = 当场自杀。

> 🔴 这和「不要在别人的队列上同步调用别的子系统」是同一个教训的两面：
> **未知对象不只是"方法不能乱调"，连"把它打印出来"都不行。**
> 我加 dump 的初衷是「少猜一点」，结果把一个本来能跑的版本整死
> —— **观测方法本身是头号风险源**（这条已经是第三次踩）。

v0.0.64 新增 `NBStringish`：只认 `NSString` / `NSNumber`，其余一律返回 nil。
`NBSafeStr` / `NBKVCStr` / `NBClip` 全部改走它。
**少显示一个字段，远好过把手机卡死。**

### 🔴 顺手发现的真问题：官方撤回一次都没执行过

翻 README 对账时发现，跟 description 无关，但更值得修：

| 版本 | 发生了什么 | 后果 |
|---|---|---|
| v0.0.57 | 按清单试 withdraw 系 | 死在 `_bulletinsForIDs:` 返回 **NSSet**、`bs[0]` 抛异常 |
| v0.0.58 | 修好 NSSet，第 1 步 `_removeBulletin:shouldSync:NO` 就成功 | **早停** ⇒ ②~⑥ 全部没轮到 |
| v0.0.61 | 重写成 async、全部重排 | **忘了把 withdraw 放回去** |

⇒ `withdrawBulletinRequestsWithRecordID:forSectionID:` 这条 iOS 16 的正规撤回，
**真机上一次都没跑过**。而它跑在 BBServer **自己的队列**上（我们本来就在这条队列上），
没有跨子系统风险，是成本最低的一刀。本版把它放在**最前面（⓪）**，每调一个立刻量一次 BB。

### 还有一个「白等了两版」的闸门

② `withdrawNotificationWithRequest:` 的前置条件里带了 `ncUUID.length`，
而真机上 uuid **一直是「无」** ⇒ **② 一次都没进过**。
换句话说：v0.0.62 起我一直在调 ①，② 从来没被真正测过。

修法不是"再找一个换 uuid 的 API"，而是**把前置条件去掉**。
现在 ② 的取法有两条，拿到的**都是系统造的真对象**：

- (a) `uuid` → `uuidsToRequests[uuid]`
- (b) **post 那一刻我们自己缓存的 request**
  （`NCNotificationDispatcher -postNotificationWithRequest:` 里存下来的）

两条都没有就跳过，**绝不自己造**（v0.0.62 的假 request 把整条 NC 队列堵死过）。

### v0.0.64 的九条改动

| 改动 | 为什么 |
|---|---|
| 新增 `NBStringish`，三个取值函数改走它 | 绝不对未知类调 description（本轮根因） |
| 删 `NCMatchEntry` 第 ④ 种比法 | 它就是那个 description 调用 |
| 删 `NBDumpNCMapsOnce` 整个函数 | 同上 |
| 写前日志：先写「将要调用 X」，再调 X，再写结果 | v0.0.63 是调完才写 ⇒ 第一句死掉就零落盘 |
| `gNCBusy` 闸门 | 上次 NC 块没回来 ⇒ 本进程再也不进（v0.0.63 是 9 条排队陪葬） |
| ⓪ 官方撤回（recordID + publisherBulletinID 两把钥匙） | 从没执行过的正规路，且无跨子系统风险 |
| ① 挪到 uuid 查询**之前** | ① 是唯一被证明「会返回」的 NC 调用，先让它结果落盘 |
| ② 去掉 uuid 前置条件 + 加「post 时缓存」后备 | 真机 uuid 一直是「无」⇒ ② 一次都没进过 |
| 删两处死分支 | `winStep=1` 从没赋值；`if(!winStep) winStep=2` 永远进不了 2 |

### 编译期撞了两次墙（CI #120 / #121）

都是 `-Werror` 把「删了调用方没删定义」直接变成编译失败：

```
Tweak.x:830:27: error: variable 'ncAfter' set but not used [-Werror,-Wunused-but-set-variable]
Tweak.x:458:11: error: unused function 'NBStashedNCRequest' [-Werror,-Wunused-function]
```

🔴 值得记的是第二个。我本来打算加 `__attribute__((unused))` 糊过去，
转念一想 —— **它正好是「② 拿不到真 request」的现成解**：
`postNotificationWithRequest:` 那一刻我们就缓存了系统造的真 request，
按 cid / recordID / publisherID 三个键去捞，比"遍历 1062 条映射"稳得多。
⇒ **编译器的 unused 警告，有时是在说「你还有一条线没接上」。**

### 包内对拍（v0.0.63 → v0.0.64，CI #122）

```
deb 1,096,486 B  md5 2299431e90962decec92977fca0c3725  control Version: 0.0.64
① 新增锚点（旧=0 且 新>0）  15/15
② 共有锚点  3/3
③ 反向对照  5/5   [map] bulletinsToUUIDs 共 / [map] uuidsToRequests 共 / NotifyBox v0.0.63
不合格 0
```

🔴 **dylib 两个版本都是 212,000 B，delta = +0**，而源码改了 5 KB 出头。
体积与改动量脱钩这件事已经撞了第 N 次 —— **判「编进去没」只认串 / 选择器 / md5。**

### 这一轮要看的四行

1. `⓪ 将要调用 withdrawBulletinRequestsWithRecordID:…` → `⓪ …WithRecordID 已返回` → `⓪ 之后 BB live=… 含本条=…`
   - 「已返回」+「含本条=否」⇒ **官方撤回升效**（本轮最大收获），直接看界面消没消。
   - 「已返回」+「含本条=是」⇒ 这条 API 不动账本，往下看。
2. `[NC] 进入 NC 队列` —— **这行有没有出现**
   - 没出现 ⇒ 连块都没进，看上面那道闸的日志。
   - 出现了 ⇒ **description 这个根因成立**，v0.0.63 的 9/9 全灭问题解决。
3. `[NC] ② uuid=… ⇒ request=…（来源 …）`
   - 来源是 `缓存键=…` ⇒ 缓存这条路走通了，说明 uuid 映射根本指望不上。
   - 还是「无」⇒ 两条都断了，下一版只能从 dispatcher 的 destinations 里找。
4. `[NC] ② withdraw 已返回` + `② 之后 req数=…` —— req数 前后变化才算真撤掉。


---

## v0.0.65 —— ⓪ 官方撤回落地；NC 队列“投了不跑”；闸门必须带超时

### 真机回传 `nc_diag(6).txt`：一个好消息、一个坏消息

**好消息：⓪ 官方撤回真的生效了。**

| App | recordID | ⓪ 之前 | ⓪ 之后 |
|---|---|---|---|
| workbuddy | `6ae01ad7_…` | live=4 含本条=是 | **live=3 含本条=否** |
| 微信 | `localPush: 6673278…` | live=10 含本条=是 | **live=9 含本条=否** |
| 钉钉 | `IM_166878479_27540897512650` | live=6 含本条=是 | **live=5 含本条=否** |
| 钉钉 | `IM_166878479_27515648910611` | live=5 含本条=是 | **live=4 含本条=否** |
| 京东 | `4860_6ae01a5b1dbbe8021368f5aa` | live=45 含本条=是 | **live=44 含本条=否** |

5 次尝试 5 次成功，`withdrawBulletinRequestsWithRecordID:forSectionID:` 这条
**三个版本都没被执行过**的路，这次通了。它是 v0.0.57（死于 NSSet）、
v0.0.58（第 1 步成功就早停）、v0.0.61（重写时漏放回去）连续三次错过的 API。

**坏消息：NC 块一次都没执行。**

日志里该有的和不该有的对照得很清楚：

```
写了 [guard] 已写 .nc_pending，进 NC 队列     ← 有
[NC] 进入 NC 队列                              ← 0 命中（30 秒窗口、5 次尝试）
```

`dispatch_async` 返回了、`.nc_pending` 也写了，但块的**第一行**从没打印。
同一条 dispatch 在 v0.0.62 是能跑起来的 ⇒ 这次那条队列没被服务。

### 🔴 我自己造的第二个坑：闸门没有超时 = 一次没跑成就永久禁用

`gNCBusy` 在块尾才清。块没跑 ⇒ 标记永远清不掉 ⇒ **后面 4 次尝试全被挡**
（日志里 4 条「上一次 NC 尝试还没回来（本进程）」）。

这和前一版「`.nc_off` 一写就永久压制新版」是**同一个设计缺陷**，我犯了两遍。
共同点：**护栏的解除条件依赖“那次操作成功返回”**，而失败恰恰是它永远不返回。

> 🔴 纪律：**任何“防重入/熔断”标记都必须带超时或版本戳**，否则它就把一次偶发失败
> 升级成永久禁用 —— 而永久禁用比不设防更难查（日志看起来像“没触发”）。

### v0.0.65 的四条改动

| 改动 | 为什么 |
|---|---|
| ⓪ 之后**直接**调 `bbRemove()`，不再投 NC 队列 | 投了不跑，不如不投；⓪ 已把账本清干净 |
| `gNCBusy` 加 8 秒超时 | 修上一版自己造成的永久禁用 |
| 新增观测 hook `observer:removeBulletin:` | 回答「系统有没有把 BB 撤回传给 NC」 |
| 新增 **[GQ] 实验通道** | 从全局队列直接调 `withdrawNotificationWithRequest:` |

**观测 hook 的巧处**：它跑在 **NC 自己的队列**上（系统调它就在那条队列）。
我们投不进那条队列，那就让**系统自己**在正确的队列上把现场打出来。
日志里每条都带「此时⓪已成功 k 次」做时间对齐：

- ⓪ 成功很多次、`[BB→NC]` 一条都没有 ⇒ **BB 的撤回根本没到 NC**，必须换路；
- 每次 ⓪ 之后紧跟一条 ⇒ **链路是通的，界面本该变**，问题在别处。

**[GQ] 为什么敢试**：v0.0.61 那次卡屏/注销的直接原因是「**在 BB 队列上**同步调 NC」⇒ 锁序成环。
全局队列上我们**手里不持任何锁**，形不成环，最坏情况只是卡住一个工作线程。
一个进程只试一次，只 withdraw、只接受 post 时缓存的**系统真 request**，调前校验 `sectionIdentifier`。

### 包内对拍（v0.0.64 → v0.0.65，CI #125）

```
deb 1,095,012 B  md5 6aaf3a1cc70a6146249bb36a42e37098  control Version: 0.0.65
① 新增锚点（旧=0 且 新>0）  12/12
② 共有锚点  4/4
③ 反向对照  5/5   [NC] 进入 NC 队列 / 永久闸门措辞 / v0.0.64 三条版本串
④ 死代码消除（旧=0 且 新=0）  2/2
不合格 0
```

🔴 **第 ④ 组是这次新加的判据类型，值得记下来。**

有两条锚点「源码里写了、包里没有」：`上一次 NC 尝试已超时 …` 和 `[NC] 队列身份 …`。
第一次跑报「新版没有 ⇒ 判据恒假」，我差点以为是漏编 —— 实际原因是：

```
static BOOL gNCUseQueuePath = NO;     // 全文件没有任何赋值
if (!gNCUseQueuePath) { … return; }   // 编译器证明它恒为 true ⇒ 门后整段是死代码
```

⇒ **锚点不该要求「新>0」，而该要求「旧=0 且 新=0」**。
这是「判据没绿先怀疑自己的期望表」的又一个实例：
**不是判据错了，是我写的期望不符合编译器会做的事。**

### 这一轮要看的三个地方

1. `⓪ 之后 BB live=… 含本条=否` —— 账本清没清（上一版已证会清，这里只确认没回退）
2. `[BB→NC] 系统自己调用 observer:removeBulletin: 第 N 次 …（此时⓪已成功 k 次）`
   - **有**（且 k 递增）⇒ 系统自己把撤回传给了 NC ⇒ **界面本该变**，问题不在链路
   - **没有** ⇒ BB 的撤回根本没到 NC ⇒ 下一版只能死磕 [GQ] 那条路
3. `[GQ] 进入全局队列` → `[GQ] withdraw 已返回`
   - 「已返回」⇒ 我们这条路也通了（和 2 对照，就知道界面为什么不动）
   - 进入后没有「已返回」⇒ 卡在 `withdrawNotificationWithRequest:` 内部，
     **但这次只卡一个工作线程，不会再卡屏注销**（手里没锁）
   - `[GQ] 跳过：post 缓存里没捞到真 request` ⇒ 缓存的键和 sysId 对不上，下一版换键

### 顺手修的一处「假死分支」

`winStep = 1`（① 撤回广播跑过）以前**从来没被赋值过**，那个结论分支是死的。
本版 ① 成功即置 1，② 改成**无条件覆盖**为 2 —— 原来写的是 `if (!winStep) winStep = 2`，
而 ① 已经把 winStep 置成 1 ⇒ **永远进不了 2**。死分支从「不可达」变成「可达且正确」。


---

## v0.0.66 —— 我盯错了方向：`observer:removeBulletin:` 是反向广播

### 一个非常有价值的对照实验

用户这轮做了一件关键的事：**手动从通知中心滑掉一条**，专门用来对照。

结果两边都没触发：

| 观测点 | 期望 | 实际 |
|---|---|---|
| ⓪ 之后 BB 账本 | 清掉 | ✅ 4/4 清掉（5→4 / 13→12 / 100→99 / 14→13） |
| 通知中心里那条 | 消失 | ❌ **还在**（用户实测） |
| `observer:removeBulletin:` | 应该响 | ❌ **0 次**（连手动滑都没响） |

### 🔴 结论：方向反了

`NCBulletinNotificationSource - observer:removeBulletin:` 是 **BBServer → NC 的反向广播**
——“BB 那边删掉了，通知你一声”。它不是“谁把这条清掉”的入口。

盯反向广播的代价是：**整整一轮真机实验什么都没看到**（4 次尝试、0 次触发）。
这和前面「名字像 ≠ 会被调用」是同一条纪律的又一次验证。

### 真正的入口在另一侧（这次不是猜，是从真机方法清单里读出来的）

`### NCNotificationDispatcher -方法 67 个` 里和“清掉”直接相关的只有这几条：

| 选择器 | 方向 | 含义 |
|---|---|---|
| `destination:requestsClearingNotificationRequests:` | 目的地 → dispatcher | **NC 界面“请求清除”** |
| `withdrawNotificationWithRequest:` | dispatcher | 真正执行撤回 |
| `_clearUnsafeNotification:` / `_didRemoveNotificationRequest:` | dispatcher 内部 | 清掉 / 清完回调 |
| `dispatcher:requestsClearingNotificationRequests:` | dispatcher → source | 把 NC request 翻成 bulletin 交给 BBServer |

> 🔴 判断方向的方法：**看谁是参数**。`observer:removeBulletin:` 的第一个参数是 `observer`——
> 是“BBServer 在通知它的观察者”；`destination:requestsClearing…` 的第一个参数是 `destination`——
> 是“某个目的地（NC 界面）在请求 dispatcher 清东西”。
> **参数名就是调用方向的路牌**，比方法名里的动词可靠。

### v0.0.66 的四条改动

| 改动 | 为什么 |
|---|---|
| 观测改挂“请求清除”这一侧（3 条） | 上一版挂的是反向广播，0 次触发 |
| 取 request 加**按内容扫** | 上一版只按 key 精确 ⇒ 缓存 43~100 条**一条都没中** |
| [GQ] 不再空烧机会 | 上一版无条件置 `gNCGlobalTried = YES`，没 request 也照样烧掉 |
| 一次性 dump 缓存键形态 | 缓存键到底是什么，下一版不用再猜 |

**为什么"按内容扫"重要**：日志里 `缓存=43 / 63 / 69 / 100` 一直在长，
说明 `postNotificationWithRequest:` 那条路一直在正常缓存，但 `cid` 一条都匹配不上
⇒ **缓存键不是 cid**。现在再按 request 自己的
`notificationIdentifier` / `bulletinID` / `recordID` / `publisherBulletinID` 比一遍
（只读 KVC、每键单独 `@try`，缺键会抛）。

### 包内对拍（v0.0.65 → v0.0.66，CI #127）

```
deb 1,096,616 B  md5 853894603e5dc6afc801655b1d7459f8  control Version: 0.0.66
① 新增锚点（旧=0 且 新>0）  11/11
② 共有锚点  4/4
③ 反向对照  5/5   [GQ] 两条旧措辞 / v0.0.65 三条版本串
不合格 0
```

🔴 dylib **211,984 → 212,000，只差 16 字节**，而源码改了 4 KB 多（新增一个函数 + 3 个 hook）。
体积这条指标又一次被证伪 —— 判「编进去没」只认串 / 选择器 / md5。

🔴 顺带记一笔：第一次跑对拍报 `内容键 %@` 不合格，原因是**我写锚点时多打了一个前导空格**
（源码里是 `@"内容键 %@"`，没有前导空格）。又一次「判据没绿先怀疑自己的期望表」。

### 这一轮请这样做（很重要）

1. 装好后**先删一条盒子记录**（触发一次 [尝试]）
2. 然后**手动从通知中心滑掉一条别的通知**
3. 回传 `nc_diag.txt`

看这一行：

```
观测计数: 目的地请求清除=N / dispatcher 撤回=M / source 请求清除=K
```

- 手动滑一条之后 **这三个数有任何一个变大** ⇒ 那就是系统真正走的路，
  下一版直接照着它调（`withdrawNotificationWithRequest:` 已经有真 request 了就差这一步）；
- 三个数**全都不动** ⇒ 手动清除根本不经过这三条，得往
  `_clearUnsafeNotification:` / `_didRemoveNotificationRequest:` / 目的地注册表 那一层再挖。

另外会多出一段 `[cache] 共 N 条，前 5 个键：…`，这段直接告诉我们缓存键长什么样，
不用再靠猜。

---

## v0.0.67 —— 拿到系统那条路了；同时承认上一版**押错了刀**

### 一条日志定案两件事

`nc_diag(8).txt` 里最有价值的不是那 24 行流程，而是两组数字：

```
[OBS] dispatcher destination:<CSNotificationDispatcher> requestsClearing…（第 1 次，2 条）
[OBS] source dispatcher:requestsClearing…（第 1 次，2 条）
        …（中间是我的 [尝试]）…
观测计数: 目的地请求清除=1 / dispatcher 撤回=0 / source 请求清除=1
[OBS] dispatcher destination:<CSNotificationDispatcher> requestsClearing…（第 2 次，2 条）
[OBS] source dispatcher:requestsClearing…（第 2 次，2 条）
```

**① 方向终于对上了。** 这两条 hook **成对触发、条数一模一样（都是 2 条）** ⇒
它们就是同一次清除的上下游：
`NCNotificationDispatcher` 收到「目的地请求清除」→ 转给 `NCBulletinNotificationSource`
→ 由它把 NC 的 request 翻成 bulletin 交给 BBServer。这是我上一版猜的那条链，现在有实测了。

**② 🔴🔴 但 `dispatcher 撤回 = 0`。** 也就是说：系统自己清通知的时候，
`withdrawNotificationWithRequest:` **一次都不走**。

> 这是本轮最该记住的一句：**方向对了，不等于刀也对了。**
> v0.0.65 / v0.0.66 我把全部希望押在 `withdrawNotificationWithRequest:` 上，
> 而系统自己根本不用它 —— 押错的是**这一条**，不是挂点。

### 还有一件被 `[cache]` 揭穿的事：按 id 找 request 是**结构性**无效

```
[cache] 共 114 条，前 5 个键：
  key=7700421581079711010 | section=com.ss.iphone.ugc.Aweme nid=7700421581079711010
  key=7700452016686199290 | section=com.ss.iphone.ugc.Aweme nid=7700452016686199290
  …
```

缓存键是**纯数字 nid**。而我们手里，`cid` 是 `135B469A-DCA7-4BF7-9466-1795B02A3BF0`（UUID）、
`recordID` 是 `f__-XoQCXfP67C4A`。**两套命名体系，永远对不上。**

⇒ 所以 v0.0.65「按 key 精确查」、v0.0.66「按内容扫四个键」全都白做 ——
不是比法不够多，是**这个方向本身就没有解**。

### v0.0.67 的四条改法

| 改动 | 为什么 |
|---|---|
| **按 `sectionIdentifier` 找 request** | 不再按 id。`uuidsToRequests` 的 value 侧扫一遍，命中本 App 的就是**真系统对象**。`sectionIdentifier` 是系统必写、我们必知的字段 —— 两边唯一对得上的那一个 |
| **照着系统那条路动手** | 在 OBS 里抓住**真的** `destination` 实例（`CSNotificationDispatcher`），调 `[dispatcher destination:dest requestsClearingNotificationRequests:{那条 request}]`。这是系统清通知走的路，第一次照抄 |
| **读映射不投 NC 队列，借系统的手进去** | OBS hook 本来就跑在 NC 自己的队列上 ⇒ 在那里顺手做映射普查与查找。绕开 v0.0.64「投进去块从没被执行」的死结，也避开了「在错误的队列上读别人的可变字典」 |
| **一次看清 `NCNotificationRequest` 的构造器** | 按关键字把 5 个类的方法表追加进 diag 文件。造不出 request 是这一路的死结，看清楚下一版才能一次写对 |

顺带删掉旧的 `[GQ]` 通道 —— 它只会调 `withdrawNotificationWithRequest:`，已证不是系统的路。

### 顺手把「映射长什么样」安全地打出来

v0.0.62 / v0.0.63 两次想 dump 映射，都死在 `description`（9/9 卡死）。
这次改成**只碰 `NSString` / `NSNumber` / 类名**，输出长这样：

```
[map] bulletinsToUUIDs=1062  uuidsToRequests=N（-1=读不到）
  b2u #0 k=…  v=…
  u2r #0 k=…  v=<NCNotificationRequest> section=… nid=…
```

`1062` 这个数是 v0.0.62 量到的（`bulletinsToUUIDs`），但 `uuidsToRequests` 的条数
**从来没读到过**（v0.0.63 之后就再没进过 NC 块）。这次一并给出来。

### 包内对拍（v0.0.66 → v0.0.67，CI #129）

```
deb 1,099,874 B  md5 7ff543686f1a5fc8b23785af6dbba786  control Version: 0.0.67
① 新增锚点（旧=0 且 新>0）  20/20
   [map] bulletinsToUUIDs=… uuidsToRequests=… / u2r #%lu k=%@ v=<%@> section=%@ nid=%@
   [拿] 已捕获 destination 实例 / uuidsToRequests 扫 %lu 条 ⇒ **命中本 App 的真 request**
   [清] 将要调用 destination:<%@> requestsClearing…（1 条） / [清] 完成 ok=%@ want=%@
   [api] 方法表已追加 %lu 行 / v0.0.67 方法表（关键字筛 …
② 共有锚点（两版都有，只证"包是我们编的"）  6/6
   ⓪ withdrawBulletinRequestsWithRecordID: / destination:requestsClearing… /
   dispatcher:requestsClearing… / observer:removeBulletin: / withdrawNotificationWithRequest:
③ 反向对照（旧>0 且 新=0）  5/5
   [GQ] 将要投全局队列 / [GQ] 跳过：缓存 %lu 条里没找到本条 / NotifyBox v0.0.66 / …
不合格 0
```

🔴 对拍第一次跑是 `不合格 1`：`v0.0.67 捕获 NC source` 报「新版没有」。
查源码发现字符串是 `@"=== [v0.0.67] 捕获 NC source，…"` —— **中间隔着 `]`**，
是我期望表里多写了一个空格。又一次「判据没绿先怀疑自己的期望表」。

顺带记一条工具坑：这个 deb 的成员是 `control.tar.gz` + **`data.tar.lzma`**（不是 `.xz`），
我第一次的校验脚本写死了 `.xz`，直接 KeyError。**别把压缩格式当常量。**

### 这一轮请这样做

1. 装好后**删一条盒子记录**（触发一次 `[尝试]`）
2. 立刻去通知中心看**那一条**还在不在（这次真的会去动界面了）
3. 回传 `nc_diag.txt`

这次文件里会多两段以前没有的内容：

- `# ---- v0.0.67 方法表（关键字筛…）----` 开头的方法表（几十行）
- `[map]` / `u2r #0 …` 开头的映射形态样本

### 三层判据（缺一层都不算成）

```
① [找] … 命中本 App 的真 request            ← 说明按 section 找这条路通了
② [清] destination:requestsClearing… 已返回  ← 说明刀发得出去
③ 人眼：通知中心那条消失                      ← 只有这个才算数
```

**前两层绿了第三层没绿，就是又一种假绿。** 前两层也绿不了，日志会明确说是哪一种：
`扫 N 条没找到 section=…`（映射里没有这个 App）、
`跳过 destination（实例=(nil)）`（没抓到 destination）、
或者 `[api]` 里那些行告诉我们构造器叫什么 —— 换成自己造。

### 风险与回退

这一版第一次**从主队列**调 NC 的派发器（v0.0.61 那次卡屏是在 **BB 队列**上同步调 NC，
锁序环；主队列上我们手里不持任何锁，形不成环）。
护栏沿用原来那套：调之前写 `.nc_pending`、返回后删掉；万一真卡住了，
手机自己会写下 `.nc_off`，下次开桌面不再重复。

真出现卡屏/注销 ⇒ 装回 v0.0.66（`⓪` 仍然会把账本清干净，只是界面不动）。

## v0.0.68 —— 那一刀从来没发出去过：我把「必须拿到的东西」挂在「可能不发生的事件」上

### 一条日志，两个数字，一个结论

`nc_diag(9).txt` 里这一轮只剩两行有用：

```
[清] 跳过 destination（实例=(nil) 方法=有）
观测计数: 目的地请求清除=0 / dispatcher 撤回=0 / source 请求清除=0
```

**「实例=(nil)」是结果，「计数全 0」是原因。** 上一版我把 destination 实例的唯一来源
押在 `dispatcher:destination:requestsClearingNotificationRequests:` 这个观测 hook 上 ——
它只要被触发一次，就能顺手把 `destination` 参数存下来。可这一轮它**一次都没被触发**
（用户删的是别的东西，系统没走清除路径），于是 `gCSDestination` 永远是 `nil`，
于是唯一能驱动界面的那一刀**从头到尾没有发出去过**。

> 🔴 这是和「押错了刀」同一族错误的另一面：
> **我把一个「必须拿到手的东西」，挂在一个「可能不发生的事件」上。**
> 判据不应该是「它发生过吗」，而应该是**「它一定会发生吗」**。
> 换了刀却忘了换「刀从哪来」—— 等于换了枪没换子弹。

### 第二个错：只按 section 匹配，会撤错条

上一版拿到的那次成功，日志是这样：

```
[找] NC 队列(OBS)：扫 176 条 request，同段 1 条 ⇒ 选中 section=com.apple.mobilephone nid=E18CDC81-…
```

看着像成功，其实只对了一半 —— 我们手里是：

| 我们持有的 | 值 |
| --- | --- |
| `bulletinID` | `D29F20AB…` |
| `recordID` | `F5C756A8…` |
| 命中的 `nid` | `E18CDC81…` |

**三个全不一样。** 而且同一段里 `BB live=2`（不止一条）。
「同段只有 1 条」是撞运气，不是判据。正解在方法表里一直躺着：
`NCNotificationRequest - bulletin`（返回类型 `@@:`）—— **request 自己带着它对应的 BBBulletin**，
拿它的 `bulletinID` / `recordID` / `publisherBulletinID` 和手里的三个 ID 比，
才是这条 request 「是不是我那条」的硬证据。

### 这一版做了四件事

**① 同步补抓 destination（不再等事件）**

```objc
static void NBProbeDestinations(id req) {
    // ① [dispatcher destinationsRegistry] —— 方法表里 `@@:`，同步就能拿到
    // ② 退而求其次 [req requestDestinations] —— request 自己知道它被投给了谁
}
```

**② 注册期就接住实例**

```objc
- (void)registerDestination:(id)destination {
    if (destination && NBIsCSDest(destination)) { gCSDestination = destination; gCSDestFromHook = YES; }
    %orig;
}
- (void)_registerDestination:(id)destination { /* 同上 */ %orig; }
```

destination 是 `NCNotificationDispatcher` 启动时**注册**进去的 —— 那是「一定会发生」的时刻。
挂在那里，比等一次未必出现的清除事件可靠得多。

**③ 用 `request.bulletin` 精确锁定本条**

```objc
static BOOL NBReqIsOurs(id req, NSArray *ids) {
    for (NSString *k in @[@"notificationIdentifier", @"uuid"]) { … }
    id b = NBSafeValue(req, @"bulletin");          // 🔴 request 自带 BB bulletin
    if (b) for (NSString *k in @[@"bulletinID", @"recordID", @"publisherBulletinID"]) { … }
}
```

匹配分成两支，日志会明说走了哪支：`精确（request.bulletin 命中）` 或
`仅 section 命中（**可能撤错条**）` —— 后者是退回分支，出现即代表**没有硬证据**。

**④ 三把刀，按「离界面由近到远」排**

| 顺序 | 刀 | 依据 |
| --- | --- | --- |
| ① | `[CSNotificationDispatcher withdrawNotificationRequest:]` | CoverSheet 就是通知中心列表本身，这是**界面层** |
| ② | `[dispatcher destination:CSDest requestsClearing…]` | v0.0.66 实测 = 系统自己清通知时真走的那条 |
| ③ | `[dispatcher withdrawNotificationWithRequest:]` | 兜底；v0.0.59 已证「会返回」，但单独用过两版界面都没变 |

全部投**主队列**执行（`CSNotificationDispatcher` 是 UI 派发器，主线程是它的自然队列）。

### 删掉的死路

`NBFindCachedRequest` 整个删除。它干的活是「拿 cid / recordID / publisherBulletinID
去 `uuidsToRequests` 那个字典里找 request」，而那个字典的键是**纯数字 nid**
（`7700421581079711010`）或 App 自造串（`com.huaye.Drinking-2026-10-25-15-01`）——
和我们手里的 UUID 属于**两套永远对不上的命名体系**。
留着它只会让下一轮又多一条「看起来像在找、其实结构性无解」的日志。

> 同一个判断的另一半：**锚点选错，不是比法不够。** 上一版试了四种键去比，
> 全都比不中，因为那些键本来就不该出现在那个字典里。

### 四层判据（装好后请这样验）

| 层 | 日志锚点 | 它证明什么 |
| --- | --- | --- |
| ① 锁对那条 | `[找] … 匹配=精确` | 找到的是**我们那条**，不是同段的别人 |
| ② 拿到 destination | `[dest] ✅ 已有实例 <CSNotificationDispatcher>（来源：注册期 hook）` | 刀有子弹了 |
| ③ 刀发出去了 | `[清] ① withdrawNotificationRequest 已返回` | 调用真到达、没抛异常 |
| ④ **人眼** | 那条通知**消失** | 🔴 只有这一层算数 |

如果 ② 还是红的，日志会给：

```
[dest] registry=<类名> 条数=N
  reg #0 <XXX>
  reg #1 <YYY>
  …
[dest] req.requestDestinations=<类名> 条数=N
[dest] ⛔ 两条来源都没拿到 CSNotificationDispatcher
```

**那就是「到底有哪些 destination 可用」的完整答案**，下一版照着挑，不用再猜。

### 三个期望表错误（这一轮的自省）

包级对拍第一次跑出 **4 条不合格**，四条全是**我自己的期望表写错**，没有一条是代码问题：

| 判据 | 我写的 | 真相 | 修法 |
| --- | --- | --- | --- |
| `精确（request.bulletin 命中）` | 带前导空格 | 源码是 `*howOut = @"精确…"`，空格来自 `匹配=%@` | 逐字取自源码字面量 |
| `bulletin` 选择器 | 当「新增」判据 | v0.0.67 包里本来就有 `bulletin\0`（BB 侧同名选择器） | 降级为**非判别性**共有项 |
| `NBFindCachedRequest` | 旧=有、新=0 | **static C 函数名根本不进二进制** ⇒ 两版都 0 ⇒ 恒绿 | 改用函数体里唯一格式串 `内容键 %@` |
| `NBStashedNCRequest` | 应该也没了 | 它是**故意保留**的老 `[NC] ②` 兜底（带 section 复核） | 期望改成「定义 1 + 调用 1 = 2」 |

> 🔴 三次都栽在同一件事上：**判据串取自「我记得 / 它打印出来长什么样」，而不是「源码里的字面量」。**
> 记忆里已经写着「期望值必须取自被测对象本身」，这一轮又犯了三遍。

### 包级对拍结果

| 项 | v0.0.67 | v0.0.68 |
| --- | --- | --- |
| deb 体积 | 1,099,874 B | 1,101,246 B |
| deb md5 | `7ff543686f1a5fc8b23785af6dbba786` | `3e4b50fd8cb06c439ff1a6deaa86f273` |
| dylib 体积 | 228,608 B | **228,608 B（delta 0）** |
| control Version | 0.0.67 | 0.0.68 |

判据：**A 新增 20 条 / B 共有 5 条 / C 反向 2 条 = 27 条，不合格 0**，且每一条都验过「有区分力」
（新增项在旧包里必须为 0，反向项在新包里必须为 0）。

> ⚠️ `dylib 228,608 = 228,608`，而源码改了 21 KB+ —— **体积和改动量脱钩**这件事已经撞了十几次，
> 判「编进去没」只认串 / 选择器 / md5，体积连趋势都不可信。

### 风险与回退

新增的两处 hook（`registerDestination:` / `_registerDestination:`）都只是**读参数存指针**，
不改变返回值、不吞掉原实现（`%orig` 照常调用），风险极低。
三把刀里 ① 是**新调用**的私有方法，若它内部状态不对，最坏表现是「通知没消失」，
不至于影响其他通知 —— 因为它每次只处理**一条** request，且调用前已经用 `sectionIdentifier` 复核过归属。

真出现卡屏/注销 ⇒ 装回 v0.0.67（`⓪` 仍会把账本清干净，只是界面不动），
并在 `nc_diag.txt` 里找 `[清] ①` 那一行有没有 `抛:` 后缀。

## v0.0.69 —— 顺序反了：我先把 NC 要用的那块砖自己拆了

**现象**：`nc_diag(10).txt` 里**四层判据全绿，通知中心那条却纹丝不动**。

```
[找] … 匹配=精确（request.bulletin 命中）      ← 锁对了那条
[dest] ✅ 已有实例（注册期 hook 接住的）        ← 刀有子弹
[清] ① CSNotificationDispatcher … 已返回        ← 没抛错
[清] ② destination:requestsClearing… 已返回     ← 没抛错
[OBS-src] …                                    ← 系统确实收到通知了
```

**四层全绿而界面不动，这件事本身就是最强线索** —— 说明问题不在链条任何一环，
而在「链条的**次序**」，或者「判据缺了一条」。

**定案**：NC 那条驱动界面的清除，要求 `NCBulletinNotificationSource`
把 `NCNotificationRequest` **翻回 `BBBulletin`**，再让 BB 自己撤一次
（`_bulletinsToClearPerSectionIdForNotificationRequests:removingDestinations:`）。
而我把 ⓪（`withdrawBulletinRequestsWithRecordID:`）和 ③（`_removeBulletin:`）
**排在了 NC 之前** ⇒ 轮到 NC 时 BB 里早就没有本条了 ⇒ 它翻不出东西 ⇒ **静默什么都不做**。
砖是我自己先拆掉的。

这解释了那个一直对不上的现象：**账本每次都清得干干净净，界面十几版纹丝不动**。

### 改法：把顺序落成代码结构，不写在注释里

```objc
// ⓪ + ③ 打包成块，**这里只定义、不执行**
void (^bbCleanup)(void) = ^{
    if (bullet && bbIn) { ⓪ withdrawBulletinRequestsWithRecordID: … }
    bbRemove();
};

// NC 先走；等它**返回**再清账本
NBFindAndForwardClear(@"主队列", ^{
    dispatch_async(gBBServerQueue, ^{ bbCleanup(); });   // ← 补 ⓪ / ③
});
```

- `NBForwardClearAsync` 新增 `done` 完成回调，`NBFindAndForwardClear` 的
  **每一条早退分支**都必须把 `done` 交回去（否则 NC 那边一失败，账本永远不清）。
- 没有 NC dispatcher / bulletin 的兜底路径才就地 `bbCleanup()`。

> 🔴 **这条教训 v0.0.61 就写在 `Tweak.x` 文件头里了**（"先 NC 两步、再删 BB 账本"），
> v0.0.65 重写流程时被我**亲手推翻**（把 ⓪ 提到最前，理由写着"不跨子系统、最安全"）。
> ⇒ **写下来的教训没人守着，就会在下一次重构里静悄悄失效。注释守不住顺序，只有「块 + 完成回调」守得住。**

### 顺手修掉的护栏缺陷（不修的话这次修复根本测不出来）

`gActClearTried`（全进程 ≤2）与函数内 `static int tries`（全进程 ≤4）**从不重置** ⇒
第 3 次删除之后，NC 那条路**永远不再尝试**，日志看起来就像"什么都没发生"。
改为：每次 `[尝试]` 开头归零。

> 🔴 **上限要按「每次操作」算，不能按「每个进程」算。**
> 这是第三次犯同类错（`.nc_off`、`gNCBusy` 各一次）。永久禁用比不设防更难查。

### 新增的唯一一条判据（只读）

```
[验] 清后 NC：扫 N 条，还能找到本条=是 / 否
```

- **否** ⇒ NC 模型真删了，界面若还不动就是**视图层没刷新**；
- **是** ⇒ 是**刀不够狠**（系统只收到通知、没真删）。

在这一行出现之前，「刀不够狠」和「视图没刷新」这两种完全不同的病因，
在日志里长得一模一样。

### 判据（真机五层）

```
[序] v0.0.69：先走 NC 清除（BB 里本条仍活着）   ← 顺序对了
[找] … 匹配=精确                                ← 锁对那条
[dest] ✅ 已有实例（注册期 hook）                ← 刀有子弹
[清] ② destination:requestsClearing… 已返回
[验] 清后 NC：还能找到本条=否                     ← 「否」= 真删了
```

### 包级对拍（v0.0.68 → v0.0.69）

dylib 228,608 → 228,688（**+80**），源码改了 3 KB+。
⇒ 再次印证「体积和改动量脱钩」，判「编进去没」只认串 / 选择器 / md5。

### 风险与回退

新增的只有**顺序**和一个完成回调，没有新增 hook、没有新增刀。
最坏表现仍是「通知没消失」，不会影响其他通知。
真出问题 ⇒ 装回 v0.0.68，并在 `nc_diag.txt` 里看 `[序]` 那一行有没有打印。

---

## v0.0.70 —— 只改界面：卡片化 + 顶部控件统一 + 详情页配色对齐

> 🔴 **这一版 `Tweak.x` 一字未动**，`tweak 侧` 沿用 v0.0.69 的全部逻辑。
> **故意拆成两个版本**：v0.0.69 验的是「通知中心那条会不会消失」，
> v0.0.70 验的是「界面好不好看」。两件事混在一个包里，出问题时说不清是谁干的。

### 1. 卡片化（`app/NotifyCell.m`）

```objc
static const CGFloat kNBCardInsetX = 12.0;   // 卡片左右内缩
static const CGFloat kNBCardInsetY = 4.0;    // 上下留白（行距）
+ (CGFloat)height { return 98.0 + kNBCardInsetY * 2; }   // 98 → 106
```

- `init` 里建 `self.cardView`（`secondarySystemGroupedBackgroundColor` + 12pt 圆角 +
  `kCACornerCurveContinuous`），**8 个子视图全部改挂到 `cardView`**；
  cell 本身与 `contentView` 都设 `clearColor`。
- `layoutSubviews` 全部改成**相对卡片原点**（`ox` / `oy` / `card.size`）。
- 新增 `setHighlighted:animated:` ⇒ 按下时卡片换 `tertiarySystemFillColor`，松手恢复；
  `prepareForReuse` 开头复位（否则复用的 cell 会带着上一次的按下色）。

### 2. 顶部控件统一规格（`app/ViewController.m`）

原来 `12 / 30 / 6 / 7` 各写各的，现在收敛成 5 个常量：

```objc
kNBTopMargin = 12;   // 左右边距
kNBTopH      = 32;   // 分段 / 按钮 / 标星 的统一高度
kNBTopGap    = 8;    // 行与行的竖向间距
kNBTopRadius = 8;    // 按钮圆角（原来 2 处写 7）
kNBHintH     = 20;   // 两条小字提示的统一高度
```

列表侧：`separatorStyle = None`（卡片之间靠留白分行）、底色
`systemGroupedBackgroundColor`、`estimatedRowHeight = 0`（不许自动估高，否则卡片会被压扁）；
搜索框 `UISearchBarStyleMinimal` + `backgroundImage = [[UIImage alloc] init]`（去掉那条 1px 分隔线）。

### 3. 详情页配色对齐（`app/NotifyDetailViewController.m`）

底色 → `systemGroupedBackgroundColor`；`headerBox` / `bodyView` → `secondarySystemGroupedBackgroundColor`。
与列表页同一套配色，进详情页不再"突然变白"。

### 🔴 一个会让卡片直接消失的坑

第一版我把卡片设成 `secondarySystemBackgroundColor`、底色设成 `systemGroupedBackgroundColor` ——
**浅色模式下两者同为 `#F2F2F7`** ⇒ 卡片和底色一样 ⇒ 卡片"消失"，圆角当然也看不见。

正确配对：**`secondarySystemGroupedBackgroundColor`（白）压 `systemGroupedBackgroundColor`（灰）**，
**这一对必须一起换**，换一半就等于没做。

### 包级对拍（v0.0.69 → v0.0.70，14 条判据全绿）

| 组 | 判据 | 结果 |
|---|---|---|
| A 新增 | `setSeparatorStyle:` / `setEstimatedRowHeight:` / `setSearchBarStyle:` / `setBackgroundImage:` / `setHighlighted:animated:` / `setCardView:` / `cardView` / `kCACornerCurveContinuous` | 69=0 → 70≥1 ✅ |
| B 共有 | `secondarySystemGroupedBackgroundColor` / `tertiarySystemFillColor` / … | 两版都 1，无判别力，只记录 |
| C 反向 | `secondarySystemBackgroundColor` | 69=1 → 70=0 ✅（旧色彻底不用了） |
| D 逻辑未动 | 归一化版本串后，dylib 差异**只落在 `LC_UUID` + 代码签名区** | ✅ |
| E 版本戳 | `v0.0.70` 新增；旧串残留恰好 1 处 | ✅ |

**D 组是这一版最值钱的一条**：App 二进制 469,552 → 469,680（+128），
dylib **228,688 → 228,688（完全同大小）**。但大小不可信，所以解析了 Mach-O：

```
差异 291 B = LC_UUID 16 + 版本串 16 + 代码签名 259        ← 分毫不差
归一化版本串后剩 275 B，8 段，全部落在 LC_UUID(2728~2744) 与签名区(225264~228688)
```

⇒ 版本串之外，两个 dylib **逐字节相同** —— 这是"`Tweak.x` 一字未动"的硬证据，
不是"我觉得我没改"。

### 两个自己踩的坑（都写进判据纪律了）

1. 🔴 **probe 用了错误的串**：查 `separatorStyle`（小写 s）匹配不到二进制里的
   `setSeparatorStyle:`（大写 S）⇒ 四条明明编进去的改动全报「两版都 0」。
   差点把"编进去了"误判成"漏编"。**查选择器要么查 setter 全名，要么大小写两种都查。**
2. 🔴 **「逐字节相同」是错期望**：第一次跑就红。版本串改了 ⇒ `ld64` 必重算
   `LC_UUID`、必重签 ⇒ 这两块**必然**变。**期望写错就改期望，不许改闸门迁就** ——
   正确判据是"归一化后除这两类白名单外零差异"。

> 另外 7 个新常量名（`kNBTopMargin` / `kNBTopH` / … / `kNBCardInsetX/Y`）probe 下来
> **两版都 0** —— C 常量被内联后名字根本不进二进制。
> 这类锚点**直接从判据表里删掉**，不留着当"恒绿"（留着就是假绿）。

### 风险与回退

只动 App 的界面代码，不碰 tweak、不碰数据库、不碰 hook。
真出问题（比如某块文字被卡片挡住）⇒ 装回 v0.0.69，通知中心那条的修复仍然在。
## v0.0.71 —— UI 现代化：建统一视觉层 `NBTheme` + 设置页重排 7 组 + 说明搬独立页

> 用户原话：**「然后 ui 再重新设计下，更具现代化，设置也整理一下，都要更合理，整洁」**。
> 这一版主体全在盒子 App 侧；`Tweak.x` 只做一件事 —— **把写死的版本串全部改用 `NB_VER_STR`**（见第 5 节）。

### 1. 先建视觉层，再改页面（`app/NBTheme.h` / `NBTheme.m`，新增）

v0.0.70 之前每页各写各的：圆角 7 / 10 / 12 混用、边距 12 / 14 / 16 混用、字号 12~15 混用。
**单看每一页都还行，连起来像三个 App** —— 这就是"不够现代化"的真实来源，不是缺动效。

所以这一版先建 `NBTheme`（全站唯一一份颜色/尺寸/字体 + 构件工厂），页面只许引用、不许再写字面量：

| 类别 | token |
|---|---|
| 尺寸 | `NBInset 16` / `NBRowH 50` / `NBRowHSwitch 56` / `NBRowHSub 64` / `NBFieldH 34` / `NBIconBox 28` / `NBCardRadius 12` / `NBSepInset 60` |
| 颜色 | `NBPageBG()` 分组灰 / `NBCardBG()` 卡片白 / `NBValueColor()` / `NBSubColor()` / `NBSepColor()` |
| 字体 | `NBFontTitle 16` / `NBFontSub 12` / `NBFontValue 15` / `NBFontHeader 13sb` / `NBFontField 16` |
| 构件 | `NBNewCard` / `NBNewIconBox`（SF Symbol）/ `NBNewChevron` / `NBNewSeparator` / `NBNewHeaderLabel` / `NBNewFooterLabel` |

🔴 **颜色配对纪律**（v0.0.70 踩过一次）：浅色模式下 `secondarySystemBackground` 与
`systemGroupedBackground` **同为 `#F2F2F7`** ⇒ 拿前者当卡片、后者当底，**卡片会消失**。
正确配对是 **`secondarySystemGroupedBackground`（白）压 `systemGroupedBackground`（灰）**，一对必须一起换。

`NBNewIconBox` 显式容忍图标名写错：`systemImageNamed:` 返回 `nil` 时**只留一个纯色圆角方块**，
不崩、也不留空白。

### 2. 设置页重排：18 行平铺 → 7 组卡片

| 组 | 内容 |
|---|---|
| 朗读 | 开关 / 朗读声音 / 朗读限定 App |
| 免打扰 | 开关 / 开始时间 / 结束时间 / 生效 App |
| 提示音 | 按 App 换音 / 默认音 ID / 默认音文件 / 最长秒数 / 按 App 分配 / 试听 / 压低音乐 |
| 记录与清理 | 记录上限 / 自动清理天数 / 删记录时同步清通知中心 |
| 拦截与过滤 | 不记录的 App / 白名单 / 黑名单 / 过滤关键词 |
| 工具 | 内容替换 / 关键词规则 / 统计 / 批量清理 / 清空全部（红）/ App 枚举诊断 |
| 关于 | 使用说明（独立页面） |

行类型固定三种，不再每个设置项各写一套：

```objc
static const NSInteger kRowSwitch = 1;   // 图标 + 标题(+副标题) + UISwitch
static const NSInteger kRowField  = 2;   // 图标 + 标题 + 右侧输入框
static const NSInteger kRowAction = 3;   // 图标 + 标题(+副标题) + 取值 + chevron
```

- 右侧改**真 chevron 图标**（`chevron.right`），取值文字里手写的 `"›"` 在
  `setActionValue:forKey:` 里**统一剥掉**（改十几处字面量不如在唯一出口剥一次，防双箭头）。
- 🔴 **行高不写死**：标题允许 2 行（"删记录时同步清通知中心"在 320pt 窄屏要换行），
  写死 50 会把第二行裁掉，而界面上**看不出来"被裁了"、只像少了一句话** ⇒ 用 `sizeThatFits:` 算。
- 组内行间分隔线**懒建**（`viewWithTag:` 找回，只建一次）—— builder 那一刻还不知道自己是不是最后一行。
- 属性结构从"平铺行数组"改成 `secRows / secTitles / secFooters / secCards / secHeaderLabels / secFooterLabels`；
  老的 `hintLabel` / `kRowGroup` / `addGroup:` **全部删除**（包级对拍确认选择器已从二进制消失）。

### 3. 使用说明搬进独立页面

原来这段文字叫 `hintLabel`、**压在整个设置页最底部**，比所有设置项加起来还长 ——
想改设置得先滑过一整屏说明，想查说明又得先滑过所有设置。

现在点「关于 → 使用说明」进独立页（`UITextView`，可选中复制，方便贴回来问）。
文字**一个字没删**（29 行字面量从 `git HEAD` 原样取出，逐行核对缺失 0 行），只是从"堆在页尾"改成"点进去看"。

### 4. 主界面：顶部控件收进一张卡片 + 导航栏换图标

- 5 个控件（时间段 / 搜索 / 全部-未读 / ★标星 / 全标已读）原来各自飘在灰色背景上，
  现在收进一张白卡片：统一内边距 10、竖直节奏 10，两个按钮改**胶囊**（`cornerRadius = kNBTopH / 2`）。
- 导航栏右侧 3 个中文文字按钮（设置 / 诊断 / 导出 / 清空）窄屏上会把标题挤掉，全换 SF Symbol：
  `gearshape`（左）/ `waveform.path.ecg` / `square.and.arrow.up` / `trash`（红）。
- 底色一律走 `NBPageBG()`：`ViewController` / `NotifyStatsViewController` / `NotifyDetailViewController`
  三处不再各自写 `[UIColor systemGroupedBackgroundColor]`。

🔴 **视图层级顺序 = z 序**：`topCard` **必须第一个 `addSubview`**。晚加的话白卡片会把分段/搜索/按钮
盖住（白底盖白字，看着像"控件没了"）。

### 5. tweak 侧唯一的改动：诊断文件不再自称旧版本

用户回传的 `nc_diag(11).txt` 头部写着 `# NotifyBox v0.0.56 · 通知中心可用 API 清单`，
而实际装的是 **v0.0.70** —— 因为那句在源码里是**写死的字面量**。

⇒ **诊断文件不能用来判断"装的是哪一版"**，这会把人带偏。本版把 9 处写死版本串全部改用 `NB_VER_STR`：

```
# NotifyBox v0.0.56              →  # NotifyBox v%@
# ---- v0.0.70 方法表            →  # ---- v%@ 方法表
=== [v0.0.52] 已捕获 BBServer    →  === [v%@] 已捕获 BBServer
=== [v0.0.52] 已注册 Darwin      →  === [v%@] 已注册 Darwin
=== [NC-CLEAR] v0.0.70 …        →  === [NC-CLEAR] v%@ …
=== [v0.0.70] 捕获 NC source     →  === [v%@] 捕获 NC source
=== [尝试 %@ @%@] v0.0.70 …      →  === [尝试 %@ @%@] v%@ …
=== [%@] NotifyBox v0.0.70 · %@ · 朗读自愈…  →  === [%@] NotifyBox v%@ · %@ …
=== [%@] NotifyBox v0.0.70 · BBServer %u …   →  === [%@] NotifyBox v%@ · BBServer %u …
```

🔴 顺带踩到一个**只有真编译才抓得到**的坑：`#define NB_VER_STR` 原来躺在第 452 行的护栏常量堆里，
而本版新改的引用在第 424 行 ⇒ **引用在定义之前** ⇒ `error: use of undeclared identifier 'NB_VER_STR'`。
我上一轮跑的五道源码级自检（括号配平 / `_NonNull` / setter 自递归 / 版本四处一致 / 行尾）**全是文本层判据，
没有一条能发现"符号可达性"问题**，四道全绿包却编不出来。
⇒ 新增第 6 道判据：**逐个 `#define` 比行号，首次引用必须严格大于定义行**。

### 6. 包级对拍（v0.0.70 → v0.0.71）

体积：App `469,680 → 470,896`（+1216）；**dylib `228,688 → 228,688`（同大小但 md5 不同 ⇒ 又一次"大小不可信"）**。

| 组 | 判据 | 结果 |
|---|---|---|
| A 新增（19 条） | `NBNewCard` / `NBNewIconBox` / `NBNewChevron` / `NBNewSeparator` / `NBNewHeaderLabel` / `NBNewFooterLabel` / `NBPageBG` / `NBFontHeader`（**非 static 函数名会进符号表**）、`layoutRow:width:height:` / `rowHeight:width:` / `usageText` / `onUsage:` / `addSection:footer:`、`secHeaderLabels` / `secFooterLabels`、`waveform.path.ecg` / `square.and.arrow.up` / `chevron.right` / `gearshape` | 70=0 → 71≥1 ✅ |
| B 共有（7 条） | `setSeparatorStyle:` / `setEstimatedRowHeight:` / `setSearchBarStyle:` / `secondarySystemGroupedBackgroundColor` / `systemGroupedBackgroundColor` / `kCACornerCurveContinuous` / `setActionValue:forKey:` | 两版同值，无判别力，只记录 |
| C 反向（3 条） | `addGroup:` 70=1→71=0、`setHintLabel:` 70=1→71=0、`hintLabel` 70=3→71=0 | ✅ 旧实现真的没了 |
| D1（`__cstring`） | 版本号归一化为 `v#` 后，两版串多重集**完全相同**（234 类） | ✅ |
| D2（`__ustring`） | 含中文的 `NSString` 字面量同样是 UTF-16、存在 `__TEXT,__ustring`；归一化后两版 **290 条完全相同** | ✅ |
| E 版本戳 | `App/Info.plist` ShortVersion+BundleVersion `0.0.70 → 0.0.71`；dylib 含 `0.0.71` 1 处、旧串 0 处 | ✅ |

🔴 **两组判据本身出过错，都是"判据域 ≠ 变异域"**，记在这里免得重犯：

1. **D1 第一版直接对整个 dylib 跑 `[\x20-\x7e]{6,}`** ⇒ 差异里冒出 `98=2j3u` / `>SgD6Jbbd` / `{<IF/J`
   这种"根本不是我写的字符串" —— 那是**代码签名区（`__LINKEDIT` 尾部）的二进制碰巧全是可打印字节**。
   正解 = 先解析 Mach-O 段表，**只量 `__cstring`**。
2. **只改 D1 还不够**：含中文的 `@"..."` 是 UTF-16 存在 `__ustring` 里的，`__cstring` 只装 ASCII 部分 ——
   而本版改的两处正好是含中文的格式串 ⇒ **只查 `__cstring` 等于这两处改动完全看不见**。
   ⇒ 补 D2。教训：**"某一组差异为空"要先问"这个域装得下这次改动吗"。**
3. 判据写法也从"差异串里含 `0.0.7x` 就放行"改成**归一化后必须完全相同** ——
   允许清单法天生漏项（旧串里的 `v0.0.52`、`v0.0.56` 不匹配清单，立刻误报 3 条）。
4. E 组第一版拿 **App 二进制**查 `0.0.71`，两版都是 0 —— **App 的版本号在 `Info.plist` 里，二进制里根本没有**
   ⇒ 那是期望写错，不是包不对。**期望值必须取自被测对象本身。**

### 7. CI 两轮失败（都是编译期硬错，值得记）

| 轮 | 报错 | 根因 |
|---|---|---|
| 1 | `Tweak.x:424:97: error: use of undeclared identifier 'NB_VER_STR'` | 宏定义在第 452 行，引用在 424 行 |
| 2 | `app/SettingsViewController.m:162:49: error: use of undeclared identifier 'UILargeTitleDisplayModeNever'` | 正确名是 **`UINavigationItemLargeTitleDisplayModeNever`**，漏了 `UINavigationItem` 前缀 |

⇒ 结论写死：**编译期是硬闸门，文本判据只能挡掉一部分。** 新增 API 常量名一律先查全名，
不要凭"看着像"写。

## v0.0.72 —— 主页卡片改版（左对齐 / 去蓝点 / 右上角未读书签 / 时间下移）+ 押新刀 `removeBulletinID`

> 用户原话：**「好，开这一版，然后顺便主页ui调整一下，哪些信息卡片里的，可以左对齐，
> 未读的不要用蓝色圆点了，未读在卡片右上角像书签一样显示未读数，然后时间放内容下面」**。
> 这一版是**两条线并行**：①主页 cell 按用户要求重排；②`Tweak.x` 押下一把新刀。

### 1. 主页 cell：左缘对齐（先把"歪"的原因找出来）

看起来只是"去掉一个蓝点"，实际上去掉的是**整块内容被右推的那 20pt**：

| | 图标左缘 | 文字左缘 | 卡片内边距 |
|---|---|---|---|
| v0.0.35~71（有蓝点） | 20 | 78 | 14 |
| v0.0.72（无蓝点） | **14** | **72** | 14 |

蓝点在 `dotX(10) + dotD(8) + 2 = 20`，而卡片的 14pt 内边距被它压过去了 ⇒
图标比内边距还多缩 6pt，文字又从 78 起，**三个左缘互不相等**。
单看一张卡片看不出来，一屏十几张叠起来边缘就"毛"了 —— 这才是"没有对齐感"的真实来源。

### 2. 未读：蓝点 → 右上角书签（带数字）

- 形状：`CAShapeLayer` 画矩形 + 底部 **V 形缺口**（圆角矩形做不出书签，只能叫标签）。
- 位置：卡片右上角、贴卡片顶边，右缩进 14（比卡片圆角 12 多让 2 —— 卡片是 `clipsToBounds`，
  贴到圆角切的地方会被削掉一个角）。
- 宽度**按数字位数算**：一位 18 / 两位 24 / 三位 30，`>99` 显示 `99+`。
  🔴 写死宽度的话，99 条未读时数字会被挤出书签外 —— 这种"只在少数数据下翻车"的 bug 最难被发现。
- 底色层和数字分两层：缺口只裁**底色**。如果把 shape 当 `pinView.layer.mask`，
  里面的数字会被一起裁 —— 这次恰好看不出来，但"碰巧没露馅"的写法迟早翻车。

🔴 **书签上的数是「这个 App 在当前列表里还有几条未读」，不是全库数。**
从 `self.items` 数出来（`nbUnreadByBundle`），不查库。理由是本项目栽过的同构坑：
**同一个界面里"互相解释"的两个指标必须同口径** —— 红点按全库算、列表按时间窗查，
用户就会看到「有红点 → 点进去暂无记录 → 红点永远消不掉」。

计数只在两处重建，别的地方不碰：
| 时机 | 为什么 |
|---|---|
| `loadData`（整表重查后、`reloadData` 之前） | 顺序反了第一屏拿到的是上一批的计数 |
| 点开一条变已读（"只刷一行"那条路） | 这条路不重查库，不手动重建就会停在旧数 |

🔴 后者还多一步：**同一个 App 的其它可见行也一起 `reloadRows`**。书签上的数是该 App 的，
不刷就会出现「这行书签没了、旁边同 App 的卡片还写着 5」的矛盾。
仍然不用整表 `reloadData` —— **数量没变**，`reloadRows` 能保住滚动位置（"数量变不变"才这个 API 的判据）。

### 3. 时间挪到内容下面：行高必须跟着涨，代价写在明面上

| | v0.0.71 | v0.0.72 |
|---|---|---|
| 行高 | 106（卡片内部 98） | **120（卡片内部 112）** |
| 时间 | 与标题同一水平线、右对齐 | **内容下方、贴底、左对齐** |
| 标题宽度 | 要让出 78pt 给时间 | **独占整行** |
| ★ | 右上角 | **右下角**（右上角让给书签），与时间同一行右端 |

🔴 为什么非加高不可：时间原来不占竖向空间，挪到下面凭空多出 **一行 15pt + 间距**。
能不能不加高、靠压正文腾地方？**不能** —— 有副标题时正文只剩 34pt，而两行 13pt 正文本身要 ≈31pt，
再压就是把正文截成一行半，用户看到的是"正文显示不全"，比多占 14pt 难受得多。
代价讲清楚：**每屏少看约 1 条**（≈700pt 可视区：106 时 6.6 条 → 120 时 5.8 条）。

🔴 时间用「**贴底**」而不是「接在正文后面」：接在正文后面的话，有没有副标题会差 16pt
⇒ 同一屏里的时间上下错位，滚动时看着像在跳。贴底让所有行的时间落在同一条水平线上。

顺手接入 `NBTheme`（`NBCardRadius` / `NBCardBG()`），cell 里不再写颜色/圆角字面量。

### 4. tweak 侧：全量 dump 重挖，锁定这一把新刀

上一轮我**只用了 `nc_diag(11).txt` 的后半段**（关键字筛选子集），这一轮把前半段
（第 1~645 行的**全量方法表**：BBServer 253 / BBObserver 55 / NCNotificationRequest 74+48 /
NCNotificationDispatcher 67 / NCBulletinNotificationSource 55 …）重挖了一遍，
结论：**76 条候选 / 31 条已试 / 45 条未试**，而已试的 31 条失败原因只收敛到四类：

| # | 失败原因 | 代表方法 |
|---|---|---|
| ① | 押错刀：系统自己清通知时**根本不走它** | `withdrawNotificationWithRequest:`（实测 0 次） |
| ② | 真入口，但首参要 **destination 实例** | `destination:requestsClearingNotificationRequests:` |
| ③ | 方向反了（首参是 observer ⇒ 是**反向广播**） | `observer:removeBulletin:` |
| ④ | 就地删账本 ⇒ 账本干净、界面不动 | `_removeBulletin:shouldSync:` / `_clearBulletinIDs:…` |

`removeBulletinID:…` 这一族**一次绕开其中两个**：

- 不需要 `destination` 实例（绕开 ②）；
- 锚点精确到 **bulletinID（个体）**，不是 section —— v0.0.67 的教训是
  「同一段可以有 `BB live=2`，命中 nid 与我们的 bulletinID/recordID 三个全不一样」
  ⇒ 只按 section 匹配**会撤错条**（绕开 ③④ 之外那个"锚点选错"的坑）。

本轮落地的三条（都在 `bbCleanup` 最前面，⓪ 官方撤回之前）：

| 标记 | 方法 | 说明 |
|---|---|---|
| ⑤K1 | `removeBulletinID:fromNoticesSection:` `v@:@@` | 两个参数，语义最干净 |
| ⑤K2 | `removeBulletinID:fromSection:inFeed:` `v@:@@Q` | 第 3 参是 **位掩码不是 BOOL**，先给 0 |
| ⑤K2b | 同上 `inFeed:1` | 只有前两条都摘不掉才试 |

🔴 每条都**立即读回 BB 账本**（`NBLiveScan`）确认。这三个方法全返回 `void`，
"没抛异常"根本不等于"删掉了" —— 用返回值当判据就是假绿。
摘不掉就退回原来的 ⓪，链一点没变（⓪ 的 else 文案也改了：原来只写"本来就没有对象"，
新刀插在前面之后，走到那个分支的绝大多数情况是"刚被 ⑤ 摘掉了"，照旧写就是假绿第 ⑧ 型）。

新增只读观测 `GOBSREM`：`BBServer - _sendRemoveBulletin:toFeeds:shouldSync:` `v@:@QB`。
🔴 **这才是"把删除广播给 observer（NC）"的那一跳** —— 老刀和 ⓪ 的实质差别全在这里：
账本干净了但没广播 ⇒ 界面永远不动。日志限 20 条（`NBDiagStep` 是**无条件追加**文件的，
而这个方法系统自己也会频繁调用，不限量就等于拿诊断文件刷屏）。

判据链（四问，日志里逐个数）：
`[删]` 返回 → `⑤新刀成功` 涨 → `_sendRemove` 涨 → `BB→NC` 涨 → **人眼消失**。

### 5. 🔴🔴 这一版最贵的一课：八道自检全绿，CI 照样编不过

CI 第一轮（#143）三条错误，同一个病因：

```
Tweak.x:1601:36: error: no known instance method for selector 'removeBulletinID:fromNoticesSection:'
Tweak.x:1618:36: error: no known instance method for selector 'removeBulletinID:fromSection:inFeed:'
Tweak.x:1636:32: error: no known instance method for selector 'removeBulletinID:fromSection:inFeed:'
```

`gBBServer` 的类型是 `id`，往 `id` 上发一个**整份文件里从没声明过**的选择器，
clang **编译期**就报错 —— 这不是"运行时会不会崩"，是根本编不过。
而当时八道文本自检全绿：括号配平对、宏可达性对、行尾对、版本四处一致对。
因为「**选择器有没有声明**」根本不在那八道的**判据域**里。
⇒ **判据域必须等于变异域**，这是本项目第 N 次撞到同一条：新增了调用，就要新增检查调用的判据。

修法：在已有的 `@interface NSObject (NBClearNC)` 私有声明区照 dump 的方法表逐字抄三条
（`v@:@@` / `v@:@@Q` / `v@:@QB`）。
`Q` 是 `unsigned long long`，也就是**位掩码**不是 `BOOL` —— 名字里那个 `inFeed`
看着像开关，实际不是（"名字像"≠"语义是"，又一次）。

新增 **`tools/check_selectors.py`（第 ⑨ 道自检）**：

1. 收集整份 TU 里**已声明**的选择器（`@interface ... (分类)` 块 + `%hook` 定义）；
2. 收集所有对「**声明类型是 `id` 的全局对象**」的消息发送，取出选择器逐条比对；
3. 未声明的按行号报出来，退出码 1。

🔴 **反向对照做了**（否则"全绿"只证明这个脚本什么都没做）：
拿修之前的 `Tweak.x` 跑，它精确报出上面那三行、退出码 1；修之后退出码 0。
🔴 只查 `id` 型接收者：`gRecent` / `gNCRequestByID` 是 `NSMutableDictionary *`，
编译器认识这个类型，把它们算进来就是**假红** —— 判据域必须等于变异域。

### 6. 判据域补漏：`NotifyCell.h/.m` 之前不在自检表里

`nb_check71.py` 的 `FILES` 表里**没有 `app/NotifyCell.h` / `app/NotifyCell.m`**，
而这一版改的正是它们 ⇒ 括号配平 / `_NonNull` 对这两个文件**零覆盖**。
已纳入（纳入后立刻生效，两个文件都是纯 LF、括号全配平）。

### 7. 包级对拍（对**实际交付的那个 deb**）

> 🔴 同源码两次 CI 构建的 md5 也不同（`LC_UUID` 16 B + 签名 52 B，`ldid` 带时间戳），
> 所以对拍必须对"这一次要给人装的那个 deb"跑，不能拿上一次 CI 的产物当证据。

对交付件 `com.yxh41.notifybox_0.0.72_iphoneos-arm64e.deb`（1,108,668 B，CI #144）跑，**20 条判据全过**：

| 组 | 判据 | 旧 v0.0.71 | 新 v0.0.72 |
|---|---|---|---|
| A | `removeBulletinID:fromNoticesSection:` | 0 | **2** |
| A | `removeBulletinID:fromSection:inFeed:` | 0 | **2** |
| A | `_sendRemoveBulletin:toFeeds:shouldSync:` | 0 | **2** |
| A | dylib 版本串 `0.0.72` | 0 | 1 |
| B | dylib 旧版本串 `0.0.71` | 1 | **0** |
| A | `[OBS-rem]` / `⑤K1 将要调用` / `_sendRemove 累计` / `新刀K1=%@`（UTF-16） | 0 | 1 / 1 / 3 / 1 |
| A | App `setUnread:count:` | 0 | 1 |
| B | App 旧接口 `setUnread:` | 1 | **0** |
| B | App 旧未读点 `dotView` | 3 | **0** |
| A | App `pinView` / `pinShape` / `pinLabel` / `isUnread` / `unreadCount` | 0 | 各 1 |
| A | App `nbUpdatePin` / `rebuildBundleUnread` / `nbUnreadByBundle` | 0 | 1 / 1 / 3 |
| C | Info.plist（App 版本号只在这里，二进制里没有） | 0.0.71 | **0.0.72** |

🔴 **反向判据第一版是假红**：用**纯子串**比 `setUnread:`，新包里"命中 1 次" ——
那一次其实是 **`setUnread:count:` 的前缀**。选择器在 `__objc_methname` 里是紧邻存放的 C 串，
长的必然包含短的 ⇒ 反向判据（旧的必须消失）永远不可能通过。
改成**精确到 `\0`** 才对。这是"选择器口径"同一个坑的第 N 次变体。

🔴 段级字节数（**只记录，不当判据**）：

| | __text | __cstring | __ustring | __objc_methname | 文件总大小 |
|---|---|---|---|---|---|
| dylib 旧 → 新 | 90,476 → **92,388** | 6,369 → **6,483** | 19,024 → **20,814** | 5,750 → **5,864** | 228,688 → **228,688（+0！）** |
| App 旧 → 新 | 196,152 → 198,440 | 6,409 → 6,413 | 25,710 → 25,710 | 27,313 → **27,820** | 470,896 → 487,632（+16,736） |

**dylib 四个段全都变大了，而文件总大小一模一样** —— 这正好又是「大小与改动量脱钩」的
活标本：拿总大小当判据，这一版会被判成"什么都没改"。

### 8. CI 两轮

| 轮 | 结果 | 病因 |
|---|---|---|
| #143 | ❌ 编译失败 | 三处「选择器没有声明」（见第 5 节）；八道文本自检全绿也挡不住 |
| #144 | ✅ 成功 | 补 `@interface` 声明 + 新增第 ⑨ 道自检 |

### 9. 这一版没做的事（明确写出来，免得下次以为已做）

- 主页 cell **没有**做"按 App 分组"：书签上的数是"该 App 在当前列表里还有几条未读"，
  仍然是**一条记录一张卡片**。分组是另一个量级的需求（数量契约、段内布局全要重做）。
- 新刀**只在 `bbCleanup` 里**（即"用户删记录 → 清通知中心"那条链），**没有**用在别处。
- `inFeed:` 的位掩码仍然是试出来的（0 → 1），不是查到的文档。下一轮靠日志定。

## v0.0.73 —— 链路被切成三段，每段都有实测数；换顺序 + 让系统自己说出答案

> 用户反馈：装 v0.0.72 后回传 `nc_diag(12).txt` —— **「没有消失」**。
> 这一版不含"我已经修好了"的断言：它是**一次实验**，判据写在下面。

### 1. `nc_diag(12).txt` 把链路切成三段，每段都能单独判死

| 段 | 实测（原文数字） | 结论 |
|---|---|---|
| ⑤ 新刀 | `_sendRemoveBulletin` 计数 1→2→3→4，`⑤新刀成功=0`，`BB live` 恒 =2 | **广播发出去了，账本没动** |
| ⓪ 官方撤回 | `BB live 2→1`、`含本条=否`；`_sendRemoveBulletin` feeds=**15871** sync=1 | 账本**清干净了** |
| BB→NC | `系统自己传给 NC 共 0 次` | **账本→界面这一跳不走 observer 广播** |
| NC 侧 ①② | `[验] 清后 NC：扫 502 条，还能找到本条=是` | NC 模型**仍持有**，界面自然不掉 |

三个数一起看，只有一个结论：**`NCBulletinNotificationSource - observer:removeBulletin:`
这条路在这台机器上根本不会因为 BB 账本变化而被调用**。之前所有"把 BB 侧弄干净"的努力
（32 条候选）注定只改账本 —— 这解释了为什么每一版日志都"全绿"而界面不动。

### 2. 这一版的第一个改动：**顺序**（同一个 API，方向相反）

v0.0.69 定的顺序是「NC 的**请求清除**要在账本之前」，因为 source 要把 request 翻回
`BBBulletin`，账本先空了它就翻不出东西。

但 `withdrawNotificationRequest:` 是**界面侧**的刀，不是数据侧的：
账本里那条还活着时叫它，CoverSheet 完全可以照账本**立刻把它重新显示出来**。
v0.0.72 恰好在账本还活着时调的它 —— 日志里「① 已返回、界面纹丝不动」。

⇒ ⑥ 挪到 ⓪ 之后（那一刻 `BB live=1`、`含本条=否`），并且**只在 `bbIn == NO` 时才动手**：

| 步 | 调用 | 说明 |
|---|---|---|
| ⑥a | `[CS withdrawNotificationRequest:req]` | 同一把刀，换时机 |
| ⑥b | `[CS destination:<dispatcher> clearNotificationRequests:{req}]` | CS 侧第一次试 |
| ⑥c | `[CS destination:<dispatcher> clearNotificationRequestsInSections:{bundle}]` | 最后手段，会清掉同 App 全部，日志明写 |

🔴 ⑥b 的首参给**发送方 dispatcher**，不是 destination 自己 ——
v0.0.72 的 ② 把 destination 填进去，那一跳的语义是"目的地**请求**清除"，
和这里"派发器**让**目的地清"不是一回事。
🔴 每步之后都用 `NBFindOurRequest` **读回 NC 模型**：判据是模型里还有没有它，
不是"方法返回了没"（这个教训 v0.0.65 就有：返回 void 的删方法，"没抛"不等于"删掉了"）。

### 3. 这一版的第二个改动：让系统自己说出答案（GCSD，6 条只读观测）

`CSNotificationDispatcher` 的方法表在这一轮才第一次被看见（52 个），里面有现成的 clear 语义。
但**"看起来对"已经骗过我很多次**，所以这一版不押它，而是先量：

| 观测点 | 它回答什么 |
|---|---|
| `postNotificationRequest:` | **存活对照**：它一定频繁触发，计数涨 = 这组 hook 真的挂上了（不是"没触发"） |
| `withdrawNotificationRequest:` | 手动清一条时系统会不会调它 |
| `destination:clearNotificationRequests:` | 同上（最像"清一条"的那把） |
| `destination:clearNotificationRequestsInSections:` | 同上（按段清） |
| `destination:clearNotificationRequestsFromDate:toDate:inSections:` | 同上（按时间段清） |
| `_clearNotificationRequestsFromIncomingSection:` | 同上（来件段清） |
| `dismissNotificationInLongLookAnimated:` | 同上（长按预览里的清）。ENC 是 `B@:B` ⇒ **返回 BOOL**，声明别写成 void |

全部只读：计数 + 有限行日志，`%orig` 原样透传。
⇒ 用户**手动在通知中心清掉一条**之后，哪几条计数涨，就说明系统真路是哪一把 ——
下一版直接抄它。（本项目铁律：判据 = 系统自己走的时候调了哪一把。）

### 4. 顺手补的两个坑

1. 🔴🔴 **观测日志会把方法表永久弄丢**：`NBDiagAppend` 在文件不存在时会**自己新建**它，
   而「方法表只写一次」的判据正是 `!fileExists`。系统级观测 hook（用户划掉任何通知都可能触发）
   完全可能在**首次删除之前**把文件建出来 ⇒ 之后那次删除认为"已经写过" ⇒ **整份方法表丢失**，
   而且表现成"这次文件里没有方法表"，根本不会联想到是几行观测日志干的。
   ⇒ 新增 `NBDiagReady()`，所有观测日志先问文件在不在（**计数照常累加**，日志没了数还在）。
2. `CSNotificationDispatcher` **全量**方法表（52 个）单独 dump 一份：
   v0.0.72 的关键发现是在**关键字筛**结果里看到的，而筛子是按上一版猜的关键字织的 ⇒
   漏掉哪条取决于我猜得对不对。52 个方法全量打出来，下一轮不再碰运气。

### 5. 交付与判据

- CI #146 成功；deb `com.yxh41.notifybox_0.0.73_iphoneos-arm64e.deb`（1,111,284 B）。
- 包级对拍 13 条全过（含反向：旧版本串 `0.0.72` 已 0 次）。
- 🔴 段级字节数：dylib 228,688 → 245,296（`__text` +4,324 / `__ustring` +2,638 /
  `__objc_methname` +297），**App 一个字节没变**（这一版没动 App）—— 两边都对得上。

**下一轮要看的四个数**（装 v0.0.73 后）：
① `⑥a/⑥b` 之后 `还能找到本条=?`，② `⑥` 结束那行的 CS 观测计数，
③ 用户**手动清一条**之后这六条计数涨哪几个，④ 人眼。

## v0.0.74 —— ⑤ 判死整块删除；界面侧改押「系统自己那条路」；按段清加闸门

> 依据 `nc_diag(13).txt`（v0.0.73 装完两轮实测）。这一版仍然**不做"已经修好了"的断言**：
> 它把上一版的 4 把刀收回 3 把，只把"系统自己真在用"的那把提到第一位，并给唯一确认有效的
> 那把加了**连带保护闸门**。

### 1. `nc_diag(13).txt` 的三个新事实

| # | 实测（原文数字） | 结论 |
|---|---|---|
| ① | ⑤ K1 / K2(inFeed:0) / K2b(inFeed:1) 三条各广播一次 `_sendRemoveBulletin`（feeds=1/0/1，sync 全 0），读回 `BB live` **一个没少**、`含本条=是`，`⑤新刀成功=0` | `removeBulletinID:*` 家族**只广播、不删账本** ⇒ 整族作废 |
| ② | ⑥a `withdrawNotificationRequest:` 已返回，`⑥ 读回：扫 1421 条，还能找到本条=是` | CS 自己的撤回**空转** |
| ③ | ⑥b `destination:gNCDispatcher clearNotificationRequests:`（1 条）→ `[OBS] dispatcher destination:<CSNotificationDispatcher> requestsClearing…` + `[OBS-dst] #0` 就是本条 → 仍 `还能找到本条=是` | 请求**到了**、模型**没动** ⇒ **首参填 dispatcher 是错的** |

### 2. 本轮最重要的新线索：系统自己清一条，走的是「多个 With」那一把

上一版按段清之后，同一秒内出现了 **9 条真删除**，每一条都是这个组合：

```
[OBS] dispatcher withdrawNotificationWithRequest:（第 N 次）nid=…
[BB→NC] 系统自己调用 observer:removeBulletin: 第 N 次 … recordID=…
[OBS-rem] _sendRemoveBulletin 第 N 次 feeds=15871 sync=1 …
```

也就是说：**真删除**走的是 `NCNotificationDispatcher -withdrawNotificationWithRequest:`
（多个 `With`），而不是我们一直在试的 `CSNotificationDispatcher -withdrawNotificationRequest:`。

> 🔴 这条同时**推翻**了 v0.0.66 写死的「系统根本不走 withdraw」——
> 那个 0 次只对「用户手动清一条」成立。源码里 5 处旧注释已就地标注被推翻
> （原文保留，只补边界），因为**留一条与实测矛盾的注释，比留一段死代码更贵**。

### 3. 这一版的 ⑦：三把刀 + 三步读回，按段清加闸门

```
⓪ 账本清干净（withdrawBulletinRequestsWithRecordID:forSectionID:，实测稳定生效）
   ↓ 投主队列
⑦a [gNCDispatcher withdrawNotificationWithRequest:req]      ← 系统自己那条路
   ↓ 读回（扫 N 条 / 同段 M 条 ⇒ 还能找到本条=?）
⑦b [gCSDestination destination:gCSDestination clearNotificationRequests:{1 条}]   ← 首参纠正
   ↓ 读回
⑦c destination:clearNotificationRequestsInSections:{bundle}  ← 仅当「同段 M <= 1」
   ↓ 读回
```

**⑦c 的闸门是本版唯一的新判据**：它确认**有效**（两次独立实测都清掉了整段），
但用户实测「**有些通知没了，但不是我要删的那条**」⇒ 它就是一把整段清的刀。
把「同段还剩几条」这个**已经量到的数**当开关：只剩 1 条时，「清整段」和「清这一条」
是同一件事，零连带；剩 2 条以上就**跳过**，日志明写「会连带清掉别人的通知」。

### 4. 顺手收回的东西

- ⑤ 三条刀**整块删除**（连带 `%ctor` 里的 h4/h5 探测、启动日志的 `新刀K1/K2` 两栏、
  以及 `@interface` 里两条 `removeBulletinID:*` 死声明）。
  > 死声明的害处不是"多几字节"：它留在 `__objc_methname` 里，会让
  > 包级反向判据「旧选择器必须消失」**永远过不了**，下一轮看包里还有这名字会误判成"还在用"。
- verdict 里「✅ ⑤ 新刀摘掉了本条」那条分支就地标注**本版起已不可达**（假绿第 ⑧ 型）。
- 日志上限放宽，免得数据被截断：`_sendRemove` 20→40、`BB→NC` 40→60、
  `dispatcher withdraw` 15→40、`dispatcher requestsClearing` 6→12。

### 5. 交付与对拍

| 项 | 值 |
|---|---|
| CI | #148（首轮，反向判据命中 1 次）+ **#149**（收尾，成功） |
| deb | `com.yxh41.notifybox_0.0.74_iphoneos-arm64e.deb`，1,110,666 B |
| md5 | `cb35b78211edaa919e7aeda20d581976` |
| dylib | 245,296 → 245,296（**+0**），而 `__text` −776 / `__ustring` −1096 / `__cfstring` −320 / `__methname` −74 |
| App | 487,632 → 487,632，**区外零差异**（只差 `LC_UUID[2968,2984)` + `LC_CODE_SIGNATURE[480960,487632)`） |

包级对拍 19 条全过：A 正向 7（⑦a/⑦b/⑦c 的调用与三处读回都在包里）/
B 反向 9（⑤K1/K2/K2b、⑥a/⑥b/⑥c 日志 + 两条 `removeBulletinID:*` 选择器，全部 0）/
C 版本 3 / D 段级 + 元数据白名单。

> 🔴 这一版的 `+0` 又是一次活标本：**总大小一模一样，四个段各减几百字节**。
> 「大小没变」不能当"没改动"的证据。

### 6. 下一轮要看的数

装 v0.0.74 后删一条，看 ⑦ 那几行：

1. `⑦a 读回：扫 N 条 / 同段 M 条 ⇒ 还能找到本条=?` —— 系统自己那条路奏不奏效
2. 若 ⑦a 没奏效，`⑦b 读回` 是否变了（首参从 dispatcher 改成 CS 自己，是这一版唯一的变量）
3. `⑦c 同段只剩 M 条` 或 `⑦c 跳过（同段还有 M 条 > 1）` —— 闸门开没开
4. 人眼：这一条掉了没有？旁边同 App 的通知有没有被带走？

判据口径：**只认 ⑦ 的三次读回**，不认"已返回"。

## v0.0.75 —— 判据是假的：删掉 loose 兜底（不再撤错条）；⑦c 首参回滚；新增 ⑦d clearAction

> 依据 `nc_diag(14).txt`（v0.0.74 装完 23 次尝试）。
> 这一版不是"又换一把刀"，而是**先承认我们的量法错了**，再修两个真 bug。

### 1. 头号问题：读回是个恒真的假判据

`nb_diag(14)` 里 **19 次读回全「是」、0 次「否」**。而同一份文件里同时存在：

```
⓪ 之后 BB live=1 含本条=否
[OBS-rem] _sendRemoveBulletin 第 1 次 feeds=15871 sync=1 …recordID=本条
[BB→NC] 系统自己调用 observer:removeBulletin: …recordID=本条
```

该发生的都发生了，读回却雷打不动 ⇒ 问题不在刀，在**判据**。

根因在 `NBFindOurRequest`：精确匹配不到时它会退回「**同段第一条**」。于是只要这个 App
在 NC 里还有任何一条通知，读回永远是「还能找到本条=是」。

> 🔴 这是「判据绿的原因 ≠ 它本来要证的那件事」的又一例。判据读的不是"目标在不在"，
> 而是"这个 App 还有没有别的通知"。

**修法**：把 loose 兜底整个删掉 —— 匹配不到精确的就返回 `nil`，调用方一律不动手。

### 2. 同一个 bug 还有个用户能看见的后果：撤错条

`nc_diag(14)` 里确实出现过一次 `选中 匹配=仅 section 命中（**可能撤错条**）`
（`com.jd.jingmai`，同段 82 条，一条都没精确命中 ⇒ 拿了同段第一条去撤）。

这正好解释用户那句「**有些通知没了，但不是我要删的那条**」——
不是"删不干净"，是**删了别人的**。

现在 `[找]` 的 else 分支把两种"没找到"分开写：

```
[找] …：扫 N 条 request，section=X 同段 M 条 ⇒ 都不是目标（目标已不在 NC）⇒ 不动手
[找] …：扫 N 条 request，section=X 同段 0 条 ⇒ 该段在 NC 里一条都没有
```

### 3. ⑦a / ⑦b 判死（各 4 次全空）

| 刀 | 实测 | 处置 |
|---|---|---|
| ⑦a `NCNotificationDispatcher -withdrawNotificationWithRequest:` | 4 次「已返回」，4 次读回目标还在 | 删 |
| ⑦b `destination:<CS 自己> clearNotificationRequests:` | 4 次全空 | 删 |

> 🔴 ⑦a 在 v0.0.73 里看着"有戏"，其实那是**系统自己**调的（14 次），不是我们调它就有效。
> 「观测到某个 API 被调用」≠「我调它也会有效」—— 这一条又撞了一次。

### 4. ⑦c 首参回滚：那处是我改坏的

v0.0.73 用 `destination:gNCDispatcher clearNotificationRequestsInSections:` 时，
同一秒内出现 **9 条 BB→NC 回调 + 9 次 `_sendRemoveBulletin feeds=15871 sync=1`**
⇒ 系统真的逐条删了。

v0.0.74 把首参"纠正"成 CS 自己之后 —— `nc_diag(14)` 里这次调用**一点动静都没有**
（`[OBS-cs] …InSections:` 之后没有任何后续）。

⇒ 回滚成 dispatcher。闸门保留：只有「该段在 NC 里只剩这 1 条」时才允许按段清
（那一刻整段清 ≡ 单条清）。

### 5. 新增 ⑦d：让列表目的地执行 request 自带的 clearAction

这是「用户点清除」在 UI 上真正走的那条：

```objc
[gCSDestination destination:<listDestination>
               performAction:<request.clearAction>
        forNotificationRequest:request
       requestAuthentication:NO
             withParameters:nil
                 completion:^(BOOL ok){ … }];
```

动作对象**直接从 request 上取**（方法表里 `NCNotificationRequest - clearAction`，`@@:`），
不自己造 —— 造动作对象这条路一次都没走通过。

> `completion` 给**真 block**而不是 `nil`：若实现体无条件回调这个 block，传 nil 就是崩；
> 多一个参数最多被忽略。

`listDestination` 在 v0.0.73 就已经探出来了：`CSMainPageContentViewController`。

### 6. 读回全部带上"读到的是哪一条"

以后每一处读回都打 `同段 N 条` + `匹配方式`，⑦ 结束行带 `nid=` ——
一眼能看出读到的是不是同一条，不用再猜。

### 7. 交付与对拍

| 项 | 值 |
|---|---|
| CI | **#151**（首轮成功） |
| deb | `com.yxh41.notifybox_0.0.75_iphoneos-arm64e.deb`，1,110,948 B |
| md5 | `519a9c22073744a43b4f58469e86b325` |
| dylib | 245,296 → 245,232（**−64**），`__text` +308 / `__ustring` −100 / `__methname` +110（新增两条声明） |
| App | 487,632 → 487,632，**区外零差异** |

包级对拍 14 条全过：A 正向 7（⑦d 探针 / 完成回调 / 读回 / 基线 / 严格匹配文案）/
B 反向 4（⑦a、⑦b、loose 兜底文案、旧 ⑦ 标题）/ C 版本 3。

> 🔴 顺手删掉了两条**恒绿判据**：`removeBulletinID:*` 的反向判据在 74→75 两侧都是 0，
> 留着只会在结果里恒绿 —— 它们在 73→74 那一版已经把该证的证完了。

### 8. 下一轮看什么

1. `[找]` 那行：是不是经常出现「都不是目标（目标已不在 NC）⇒ 不动手」
   —— 如果是，说明**这些通知本来就已经不在 NC 模型里**，问题在别处（不是我们没删掉）
2. `⑦ 基线 … 本条还在=? nid=?` —— 终于是一个可信的起点
3. `⑦d clearAction=<…> 列表目的地=<…> 方法=…` —— `clearAction` 到底有没有值
4. `⑦d 完成回调 ok=?` 与 `⑦d 读回`
5. 人眼：这一条掉了没有？**有没有别的通知被误删**（这条最重要）
## v0.0.76 —— 找到了真删除链路的第一跳：⑧ 冒充系统投递 `observer:removeBulletin:`

> 依据 `nc_diag(15).txt`（v0.0.75 装完，6 次尝试 / 4 段 ⑦）。
> 这一版的结论**不是推断**，是同一份日志里"系统自己走了一遍"的全过程记录。

### 1. 本轮唯一的新事实：系统在 07:02:43 自己走完了整条链路

```
07:01:28  ⓪ withdrawBulletinRequestsWithRecordID:6ae2ea2d_…   ← 我们撤回第 1 条
07:01:38  ⓪ withdrawBulletinRequestsWithRecordID:6ae2e85e_…   ← 我们撤回第 2 条
          … 中间 65 秒，NC 侧一点动静都没有 …
07:02:43  [BB→NC] observer:removeBulletin: × 8 条（同一秒，含上面两条 + 一条陌生的 6ae1ca5e）
07:02:43  [OBS] dispatcher withdrawNotificationWithRequest: 第 2/3/4/5 次
07:02:43  [OBS-cs] withdrawNotificationRequest: 第 4/5/6 次
```

⇒ 真删除的链路顺序是：

```
BB 账本（_sendRemoveBulletin）
  → NCBulletinNotificationSource - observer:removeBulletin:      ← 第一跳，我们从来没走过
  → NCNotificationDispatcher - withdrawNotificationWithRequest:  ← ⑦a 试过，空转
  → CSNotificationDispatcher - withdrawNotificationRequest:      ← [清]① 试过，空转
```

**后面两把我们各自单独试过（⑦a 在 v0.0.74 试 4 次、[清]① 在 v0.0.75 试 4 次），
一律「已返回 + 读回不变」**。缺的不是刀，是**第一跳**。

### 2. 第一跳为什么以前没走：投错了队列

v0.0.64 的代码里其实已经有这一句，但它被投进了 `gNCSourceQueue`：

```objc
dispatch_async(ncq, ^{
    [gNCSource observer:obs removeBulletin:bullet];   // 块从没被执行过
});
```

日志里 9 条「进入 NC 队列」的块全部有去无回 ⇒ 那一版之后整条 NC 队列路径被关掉，
这句也跟着休眠了两个版本。

**本版改投主队列**（⑦ 本来就在主队列上，这一段实测每次都跑得到），并且：

- 顺序必须是 **⓪ 之后** —— 系统的回调本来就在 BB 撤完之后才到，source 的处理体也按
  「BB 里已经没有了」设计；
- `bullet` 必须**在 ⓪ 之前抓下来**存好：⓪ 之后 BB 里已经没有它，`_bulletinsForIDs:` 取不回来；
- 调用前置位 `.nc_pending` 护栏、返回后立刻删除（带版本号，留到下次开机就是这一步卡死的）。

### 3. 区分「我方投递」和「系统自己转过来」

⑧ 调用的正是我们挂着观测 hook 的那个方法。不区分的话，日志里那句
`[BB→NC] 系统自己调用 …` 会把「我们自己调通了」写成「系统终于转过来了」——
这正是本项目吃过好几次的假绿。

```objc
if (gSelfPostingRemove) {
    NBDiagStep(@"  [BB→NC] ← **我方 ⑧ 投递** recordID=%@\n", …);
} else if (gBBToNCSeen <= 60) {
    NBDiagStep(@"  [BB→NC] 系统自己调用 observer:removeBulletin: 第 %d 次 …\n", …);
}
```

顺带在 hook 里接住系统递过来的那个**真** `BBObserver`（`gBBObserver`），
作 ⑧ 在 `[gNCSource observer]` 取不到时的退路。⛔ 绝不自己造 observer ——
v0.0.62 造过假 request，代价是整条队列被堵死。

### 4. 读回跨两域 + 延迟复量

| 域 | 读什么 | 它证明什么 |
|---|---|---|
| 域A | `source.uuidsToRequests`（原有 `NBFindOurRequest`） | request 还在不在 source 的账上 |
| 域B | `source.bulletinsToUUIDs` 里这条 `bulletinID` 的键 | 第一跳的**第一步**有没有发生 |

域B 是给下一轮留的定位：**键消失但 request 还在** ⇒ ⑧ 确实跑进去了，断点在下游
（dispatcher / destination），下一轮就不用再怀疑第一跳。

另外补一个 **+3s 延迟复量**。理由是硬的：系统的传播本身就有延迟（本轮铁证 8 条挤在
65 秒后同一秒到达），而我们**所有**读回都在同一秒内做完 —— 这等于默认「立即生效」，
这个默认本身可能就是继 loose 兜底之后的**第二个假判据**。

### 5. 就地补一条「域」说明：⑦c / ⑦d 的读回不能当它们失败的证据

⑦c（按段清）和 ⑦d（`performAction:` 执行 `clearAction`）作用在
**destination（CoverSheet 列表）** 这一层，而我们的读回量的是
**source 的 `uuidsToRequests`**。两者不是同一个存储。

> 🔴 判据域必须等于变异域。`⑦c 读回：本条还在=是` 只能说明"source 的账上还有它"，
> 不能说明"界面上还看得见"。本版**不动**这两把刀的逻辑，只把这句写在代码里，
> 免得下一轮又拿同一个读回把它们判死（或者反过来判活）。

### 6. 新增一条只读观测：复数版 `_sendRemoveBulletins:toFeeds:shouldSync:`

用来回答「那 8 条为什么挤在同一秒」。若复数版被调 ⇒ BB 把多个 removal 攒成一批再投；
全程 0 次 ⇒ 是别的节流。两种结果都能把下一步钉死。只读、限 10 行、`%orig` 原样透传。

### 7. 交付校验（机器对拍，非目测）

| 项 | 结果 |
|---|---|
| CI | run `40833866671` **首轮 success** |
| deb | `com.yxh41.notifybox_0.0.76_iphoneos-arm64e.deb` |
| deb 大小 / md5 | 1,112,136 B / `003c570f8d9559e0e9371880647492af` |
| dylib 大小 / md5 | 245,232 → 245,248（**+16**）/ `10cc5e4a85cadcfd923a27326edd37e1` |
| 包级串级对拍 | 14 条全过（11 条正向 ⑧ 相关 + 2 条存活对照 + 1 条负向对照） |
| 选择器 | `_sendRemoveBulletins:toFeeds:shouldSync:` 旧=0 新=1；`observer:removeBulletin:` 旧=1 新=1 |
| 版本 | Info.plist 两处 = 0.0.76；dylib 内 `0.0.75` 残留 **0** |
| App 二进制 | 487,632 → 487,632，**区外零差异**（只差 `LC_UUID[2968,2984)` + `LC_CODE_SIGNATURE[480960,487632)`） |

段级体积（大小与改动量脱钩，只看内容）：

```
__text      96244 -> 98100  (+1856)
__ustring   22256 -> 23102  (+846)
__cfstring  21280 -> 21760  (+480)
__methname   6197 ->  6238  (+41)
__cstring    6593 ->  6593  (+0)      ← 新增串全含中文/⑧ ⇒ 都进 __ustring
总大小     245232 -> 245248 (+16)     ← 又撞一次「+7.5KB 源码只长 16 字节」
```

### 8. 本版没有做的事（别当 bug 报）

- ⑦c / ⑦d 逻辑一字未改（域说明只是注释 + 日志措辞）。
- 没有新增第二把刀 —— 本项目纪律：**两个以上"没跑过"的新挂点不能同轮**。
- 没有碰盒子 App 的界面。

### 9. 下一轮看什么（只要三个数）

1. `⑧ 入口 observer=<…> 方法=有 bulletin=<BBBulletin>` —— 三样齐了它才发得出去
2. `⑧ 读回：… 本条还在=否（已删）` —— **这是本版成败的唯一判据**；配合 `⑧ 域B … 键=已消失`
   一起看：域B 消失而域A 还在 = ⑧ 跑进去了、断点在下游（dispatcher / destination），
   下一轮直接往下游走，不用再怀疑第一跳
3. `⑧ +3s 复量：… 本条还在=?` —— 同秒读回是「是」、3 秒后变「否」也**算成功**
   （系统的传播本来就是延迟的，这正是本版要量清的东西）

若 `⑧ 跳过（observer=nil …）` ⇒ 两条取 observer 的路都没通：`[gNCSource observer]` 返回 nil，
且本次进程里系统还没调过一次 `observer:removeBulletin:`（`gBBObserver` 也是 nil）。
那种情况下一轮改成"从 `initWithDispatcher:observer:queue:` 那一跳接住 observer"。

## v0.0.77 —— 队选错了：⑧ 搬离主队列（不再卡屏注销）+ 修「抑制后连账本都不清」的死分支

> 依据 `nc_diag(17).txt` 与一句最关键的口述：
> **「刚开始滑了菜鸟两次就卡屏注销了，之后都不会卡屏注销了，不过好像没效果了」**。
> 这三件事不是三个 bug，是**一条链**。

### 1. 一句话病因：⑧ 在主队列上同步调用了一个「内部可能要主线程」的方法

v0.0.76 的 ⑧ 是这么写的：

```objc
dispatch_async(dispatch_get_main_queue(), ^{        // ← 错在这里
    [gNCSource observer:obs8 removeBulletin:bullet8];
});
```

系统自己调这个方法时，是在 `NCBulletinNotificationSource` **自己的 queue（后台）** 上。
我们从**主队列**调它，只要它的实现体里有任何 `dispatch_sync(main)` 或需要主线程的东西
⇒ **必然自死锁** ⇒ 主线程永久被拖住 ⇒ 看门狗杀进程。

这正好解释症状：**「卡屏一会儿然后注销」**，不是闪退。而且**只发生了两次**，
因为第三次之前 `.nc_pending` 已经留到了下次开机。

### 2. 然后就是你以为的「不卡了」，其实是「彻底不做了」

开机时看到 `.nc_pending` 还在 ⇒ 写 `.nc_off`（日志里 `抑制=是`）。到这里都符合设计。
真正的问题在下一步：

```objc
// v0.0.76
if (gNCSuppressed) {
    NBDiagStep(@"  [清] 跳过（上次卡死过 …）\n");
    return;                       // ← 🔴🔴 没有调 done()
}
```

`done` 是「界面这一刀已经结束了，**现在可以去清 BB 账本了**」的信号。
它不调 ⇒ 调用方那句「清完再清账本」**永远等不到** ⇒ 连 ⓪（唯一真正改得动账本的刀）都不跑。

`nc_diag(17).txt` 里 20 次尝试全是这个形状，后面**一行都没有**：

```
[序] v0.0.69：先走 NC 清除…
[找] 进入主队列
[找] 主队列：扫 447 条 request，同段 5 条 ⇒ 选中 匹配=精确…
[清] 跳过（上次卡死过 ⇒ gNCSuppressed，删 …/.nc_off 可恢复）
                                    ← 到此为止：没有 ⓪、没有 删后 BB、没有 ⑦
```

> 🔴 这就是本项目第 11 条铁律的又一次应验：**防重入/熔断的解除条件，不能挂在「会失败」
> 的那条路上**。这里的熔断本身没写错，错在熔断之后把正常流程也一起短路了 ——
> 表现不是「少了界面特效」，而是「整个功能看起来没装」。

### 3. 本版四条改动

#### ① ⑧ 移到自建后台串行队列

```objc
gNC8Queue = dispatch_queue_create("com.yxh41.notifybox.nc8", DISPATCH_QUEUE_SERIAL);
```

- **块一定被执行**：v0.0.64 曾把这一句投进 `gNCSourceQueue`，块**从没被执行**
  （那一轮整条路径因此被关掉）⇒ 不能拿系统队列当唯一通路。
- **永不占主线程**：就算它卡，卡的只是这条队列，主线程照常跑 ⇒ **不会卡屏注销**。

#### ② `.nc_pending` 从「护栏」升级成**投递闸门**

投之前先看它还在不在：在 ⇒ 上一次投递没回来 ⇒ **本次不投**。
不再往一条已经卡住的队列里堆任务（这是 v0.0.63 那 9 条「一条条排在同一条队列后面全部陪葬」的教训）。

#### ③ 修死分支：抑制时只跳过 ⑧，**账本照清**

```objc
if (gNCSuppressed) { NBDiagStep(@"  [清] 界面侧被 .nc_off 压制 … ⇒ 只清 BB 账本\n"); }
if (done) { done(); }          // ← 无条件交回
```

于是最坏情况退回 v0.0.68 的"安全档"：BB 账本清干净，界面等系统自己跟（它会跟，只是慢）。

#### ④ 删掉 [清]①②③ + [验] 与 ⑦c/⑦d 全部四把

| 删掉的 | 实测 | 为什么要删 |
|---|---|---|
| `[清]①` CS `withdrawNotificationRequest:` | v0.0.75 4 次全空转 | **都在主队列上调用未知 NC 方法** —— 本轮卡屏最可疑的另一类 |
| `[清]②` `destination:<CS> requestsClearing…` | 同上 | 同上 |
| `[清]③` 兜底 `withdrawNotificationWithRequest:` | v0.0.74 4 次全空转 | 同上 |
| `[验]` 读回 | 判据域是 source，这些刀动的是 destination | 域对不上，读回本来就无效 |
| `⑦c` `…clearNotificationRequestsInSections:` | 各 1 次，`已返回` + 读回没变 | 连带风险最大（整段清会带走别人的通知） |
| `⑦d` `performAction:` + `request.clearAction` | 2 次 `完成回调 ok=是`，零可观测变化 | 它**执行一个 UI 动作**，副作用面最大 |

连同声明删掉 `clearAction` 与 `destination:performAction:forNotificationRequest:…`
—— 死声明留在 `__objc_methname` 会让包级反向判据「旧选择器必须消失」永远过不了。

**净效果：主队列上从此不再有任何未知 NC 调用。** 路径变成三步：

```
找 request（主队列，只读） → ⓪ + ③ 清 BB 账本（BB 队列） → ⑧ 冒充系统投递（后台队列）
```

### 4. 顺带量到的两件硬事实

1. **`_sendRemoveBulletins:toFeeds:shouldSync:`（复数版）确实被系统调用**
   —— `条数=1`，`feeds=15871`、`sync=0`。所以 v0.0.75 那 8 条同秒到达，
   是 BB 用复数版在一次投递里连发，不是我们删多少条的问题。
2. **BB → NC 的传播是「分钟级」的**：同一条（`com.lemon.lv`，recordID `7411801838594329880`）
   在 `07:41` 前后就被 `_sendRemoveBulletin` 撤了，`[BB→NC] removeBulletin` 直到
   **`07:45:56`** 才到 NC（约 4.5 分钟）。⇒ 所有「同秒读回」都不可能看到变化，
   这正是 v0.0.76 加 +3s 复量的理由，而 +3s 可能都还不够。

### 5. 交付校验（机器对拍，非目测）

| 项 | 结果 |
|---|---|
| CI | run `40838206446` **首轮 success** |
| deb | `com.yxh41.notifybox_0.0.77_iphoneos-arm64e.deb`，1,110,226 B |
| md5 | `237a1813826217a6d83e744339249583` |
| dylib | 245,248 → 245,264（**+16**）/ md5 `c61c61f845c9d8a39d780b65edcdb20c` |
| 包级对拍 | **28 条全过**（A 正向 9 / B 反向 9 + 存活对照 2 + 负向对照 1 / 选择器 4 / C 3） |
| 反向判据 | `[清]①②`、`[验]`、`⑦c`、`⑦d` 的日志串 **旧=1 新=0**（一个字不剩） |
| 死选择器 | `clearAction` / `performAction:…completion:` **旧=1 新=0** |
| 版本 | Info.plist 两处 = 0.0.77；dylib 内 `0.0.76` 残留 **0** |
| App 二进制 | 487,632 → 487,632，**区外零差异** |

段级体积（这一版是**真缩水**，与总大小无关）：

```
__text      98100 -> 95572  (-2528)
__ustring   23102 -> 21386  (-1716)
__cfstring  21760 -> 20832   (-928)
__gcc_except 5652 ->  5404   (-248)
__objc_stubs 7168 ->  6944   (-224)
__methname   6238 ->  6113   (-125)
总大小     245248 -> 245264   (+16)   ← 删了 7KB 源码，包还是长 16 字节
```

### 6. 装上后会自动解锁 —— 不用手删文件

护栏文件里写的是**版本号**：`.nc_off` 里记的是 `0.0.76`，本版启动判定「不是本版」⇒
**自动删掉**并重新试一次。同理 `.nc_pending` 也会被清。
如果你因为别的原因需要手动恢复，删这两个即可：

```
/var/mobile/Library/NotifyBox/.nc_off
/var/mobile/Library/NotifyBox/.nc_pending
```

### 7. 本版的风险要说清楚

⑧ 从主队列挪到了**我们自己的后台队列**。好处是「再卡也不会卡屏注销」，
代价是：如果 `observer:removeBulletin:` 的实现体要求「必须在 NC 自己的队列上」，
那么从别的线程调它可能**崩**（不是卡）。真出现这种情况，症状会是**闪退**而不是卡屏，
届时下一版改投 `gNCSourceQueue`（系统的原生队列）并先验证它的类名。

### 8. 下一轮只看四个数

1. `⑧ 投递到后台队列（不占主线程）bulletinID=…` + `⑧ 进入后台队列` —— 块真的跑了
2. `⑧ 已返回` —— **没卡**（这条没出现但进程还活着 = 卡住了，`.nc_pending` 会留在盘上）
3. `⑧ 读回：… 本条还在=否（已删）` —— 成败判据；配 `⑧ 域B … 键=已消失` 定位断点
4. `⑧ +3s 复量：… 本条还在=?` —— 结合上面「传播是分钟级」这个事实来读：
   3 秒还是「是」并不代表失败

## v0.0.78 —— ⑧ 实测卡死整段删除；`&& bullet` 丢掉了 77% 的尝试；⑦r 用时间窗破局

> 依据 `nc_diag(18).txt`（v0.0.77 真机，**30 次尝试**，08:05:18 ~ 08:07:15）。
> 用户这次只给了文件，没有口述 —— 但日志自己把话说全了。

### 1. 先回答上一版留下的四个问题

| 上一版要看的 | 实测 | 结论 |
| --- | --- | --- |
| 还卡不卡屏注销 | 30 次尝试、进程全程在写日志、**一次都没卡** | ✅ 队列搬家是对的 |
| `⑧ 投递到后台队列` | **1 次**（30 次里只有 1 次） | ❌ 后面 29 次连投都没投 |
| `⑧ 已返回` | **0 次** | ❌ 块进去了，**再没回来** |
| `⑧ 读回 / 域B / +3s 复量` | 全 **0 次** | ❌ 那三行代码一行都没执行到 |

### 2. ⑧ 到底死在哪一步（日志逐行）

第一次尝试（08:05:18）的最后五行，按时间顺序：

```
  ⑦ 基线：扫 105 条 / 同段 9 条 ⇒ 本条还在=是 nid=2555795157568987628（匹配=精确）
  ⑧ 投递到后台队列（不占主线程）bulletinID=DA7EBE87-A01E-4554-8821-6920B8C7DE51
  ⑦ 结束：本条还在=是 nid=2555795157568987628 ｜ CS 侧观测计数 撤回=0 清=0 段清=0 …
  ⑧ observer=<BBObserver> 方法=有            ← 块真的跑了（在后台上）
  [BB→NC] ← **我方 ⑧ 投递** recordID=2555795157568987628
                                            ← 然后就没了
```

`⑧ 进入后台队列` 这一行**根本没打印**，但 `⑧ observer=…` 打印了 ——
顺序反了，因为前者是 `NBDiagStep` 里带 shell 转义的那条（日志窗口滚动时被挤掉），
后者是块里第二句。**真正关键的是它后面什么都没有**：

- 没有 `⑧ 已返回` ⇒ `[gNCSource observer:obs8 removeBulletin:bullet8]` **没返回**
- 没有 `⑧ 读回` ⇒ 后面的代码一行没跑
- `.nc_pending` 从 08:05:18 一直留到 08:07:15（**近 2 分钟**）

⇒ **刀本身在方法内部等一个永远不来的东西。** 队列选对了，刀选错了。

### 3. 🔴🔴 比 ⑧ 更狠的那个 bug：一个 `&& bullet` 丢掉 77% 的尝试

把 30 次尝试按「有没有进入 NC 侧」分类：

| 情况 | 次数 | 日志特征 |
| --- | --- | --- |
| `BB live=… 含本条=是 对象=BBBulletin` | **7** | 走到 `⑦ 基线`，界面侧有一次机会 |
| `BB live=… 含本条=否 对象=(没取到)` | **23** | 直接 `[序] 没有 NC dispatcher/bulletin ⇒ 就地清账本` |

那 23 次的完整日志只有七行，界面侧**一个字都没动**：

```
  cid=5403D39A-460F-4B91-8761-AA313A8C135D
  BB live=44 含本条=否 对象=(没取到)
  [序] 没有 NC dispatcher/bulletin ⇒ 就地清账本（界面可能不变）
  ⓪ 跳过（BB 里本来就没有对象）
  ⇒ 两层都没动（BB 本来就没有，NC 也没进）
```

原因是这一行：

```objc
if (gNCDispatcher && bullet) {      // ← v0.0.78 删掉了 && bullet
```

`bullet` 是 **BB 账本里**的那个对象。而「BB 账本里没有」**不等于**「NC 里没有」：

- 系统自己撤通知时**先清 BB**，我们的删除请求往往晚一步到达 ⇒ `含本条=否` 是常态
- NC 的 `NCNotificationRequest` **自带一份 bulletin**（日志里 `[找] req.bulletin=<BBBulletin>`），
  精确匹配 `NBReqIsOurs` 读的就是它，跟 BB 账本毫无关系

⇒ 本版把 gate 改成 `if (gNCDispatcher)`。
**这条改动的量级比换刀大得多**：它把 77% 的空转变成真尝试。

### 4. ⑦r：`clearNotificationRequestsFromDate:toDate:inSections:`（⑦c 的带时间窗版）

方法表里这一族有三兄弟，只差参数：

| 选择器 | 编码 | 语义 |
| --- | --- | --- |
| `- destination:clearNotificationRequests:` | `v@:@@` | 清**整个** destination（最狠） |
| `- destination:clearNotificationRequestsInSections:` | `v@:@@` | 按段清 = ⑦c |
| `- destination:clearNotificationRequestsFromDate:toDate:inSections:` | `v@:@@@@` | **按「时间段 + 段」清 = ⑦r** |

选它的三条理由：

1. **同族**：跟 ⑦c 只多两个 `NSDate`，走的是同一条实现路径 ——
   而 ⑦c 是唯一被真机证实「系统自己清一条时就是这么走」的那把
   （v0.0.66 实测：手动清一条 ⇒ `destination:…requestsClearing…` 与
   `dispatcher:…requestsClearing…` **成对**出现、条数一致）。
2. **⑦c 的死结只有时间窗能解**：⑦c 的闸门是「同段 ≤ 1 条」，而实测同段条数是
   **9 / 19 / 30 / 37 / 39 / 45 / 99** —— 一次都不满足 ⇒ 那把刀等于没装。
   时间窗把精度从「整个段」收窄到「±0.4 秒内的那一条」。
3. **NC 侧还有一个孪生**：`- destination:requestsClearingNotificationRequestsFromDate:toDate:inSections:`
   名字只差一个词、在**另一个类**上 ⇒ 本版先只打 CS 侧，不同轮上两把（§「两个以上没跑过的新挂点不能同轮」）。

**两道闸门，都基于当场量出来的真实数**：

```objc
int winHits = NBCountInWindow(gNCSource, want7, ts7, 0.4);   // 同段 + ts±0.4s 内有几条
if      (!ts7)          { … 跳过（不传 nil 时间窗）… }
else if (winHits != 1)  { … 跳过（要么打不中、要么连带）… }
else                    { … 动刀 … }
```

- ① `req.timestamp` 必须**真是 NSDate**。传 `nil` 给这个 API 极可能等价于「不限时间」
  ⇒ 退化成整段清 ⇒ **连带清掉同段几十条别人的通知**。宁可不打。
- ② 窗口内同段只能有 1 条。返回 `-1`（读不到）按「不许动刀」处理，**不是**「0 条」。

**护栏**（§1.11：防重入/熔断标记必须带超时或版本戳）：

```
调用前写 .cs_ws（内容带 NB_VER_STR + 时间）→ 返回立刻删
留到下次开机 ⇒ 说明这把刀把主队列卡死过 ⇒ 写 .nc_off，本次永久压制界面侧
换新版本号 ⇒ 自动获得一次重试机会
```

同时保留两条**彼此独立**的判据：

- `[OBS-cs] destination:<…> clearNotificationRequestsFromDate:toDate:inSections: 第 N 次 M 个段`
  —— 证明**调用发生了**（v0.0.73 就有的观测 hook，顺带验证「首参必须是 dispatcher」）
- `⑦r 读回：… 本条还在=否` + `⑦r +20s 复量：… 否` —— 证明**它真的做了**
  （+20s 量的是 CS destination 有没有生效，不是 BB→NC 传播，那要分钟级）

### 5. [寿] 旧删台账 —— 这一轮真正的核心取证

在再赌一把刀之前，有个**更根本的问题**一直没量过：

> **⓪ 把 BB 账本清干净之后，NC 里那条到底会不会自己消失？多久消失？**

之前所有读回都是「删完同秒读回」，等于默认「立即生效」。而实测 BB→NC 传播是
**65 秒 ~ 4.5 分钟**（`nc_diag(17).txt`：07:41 撤、07:45:56 才到 NC）
⇒ **同秒读回必然读到「还在」，它不是判据，是噪声。**

做法：

- `⓪` 真的撤掉那条时（`f0 == NO`），把 `时间戳|bundle|cid` 写进
  `/var/mobile/Library/NotifyBox/.nb_deleted`（最多留 24 条，同一 cid 只留最新）
- 每次进 NC 侧时**一次扫描比对多条**旧 cid（不是每条各扫一遍，省一个数量级），打：

```
  [寿] 台账 12 条 × 扫 NC 636 条 ⇒ NC 里已消失 7 / 仍在 5
  [寿]   已消失：最老 412s 最新 38s
  [寿]   仍在  ：最老 96s 最新 11s              ← >600s 仍在时会直接标「**不会自己消失**」
  [寿]   仍在 com.ss.iphone.ugc.Aweme 7701945581899418890（96s 前）
```

**这一行决定了下一版要不要继续赌刀**：

- 若「最老已 >10 分钟仍在」⇒ 等是没用的，必须靠 ⑦r
- 若「最早 4~5 分钟前的都消失了」⇒ ⓪ 本来就够，问题只是用户等不了，
  该做的是**删完给个提示**而不是再打刀

### 6. 本版改了什么（一次列全）

| # | 改动 | 性质 |
| --- | --- | --- |
| 1 | ⑧ 整段删除（含 `gNC8Queue` / `gTry8Busy` / `NBEnsure8Queue` / `gBBObserver` / `gSelfPostingRemove` / `bullet8`） | 删刀 |
| 2 | gate `if (gNCDispatcher && bullet)` → `if (gNCDispatcher)` | 🔴 结构性，量级最大 |
| 3 | 新增 ⑦r + `NBCountInWindow` 闸门 | 新刀（1 把） |
| 4 | 新增 `[寿]` 台账（`NBDeletedRemember` / `NBCheckDeletedAlive`） | 取证 |
| 5 | 新增 `.cs_ws` 护栏 + 开机检查 | 护栏 |

### 7. 下一轮只看五个数

1. `[寿] 台账 N 条 … 已消失 X / 仍在 Y` + 两行年龄 —— **最重要的一行**，决定下一版方向
2. `⑦r 闸门：timestamp=… 窗口(±0.4s)内同段=? 段内总=? 方法=? 压制=?` —— 闸门通不通
3. `⑦r 已返回` + `[OBS-cs] … 第 N 次` —— 调用发生了
4. `⑦r 读回：… 本条还在=?` 与 `⑦r +20s 复量：… =?` —— 成败
5. `[序] 没有 NC dispatcher/bulletin ⇒ 就地清账本` 这一行的**出现次数应当接近 0**
   （v0.0.78 之前它占 23/30）

> 🔴 读日志时注意一点：`⑦ 基线 … 本条还在=是` **不是失败**。
> 它量的是「刚删的那条此刻还在不在 NC」，而 BB→NC 传播要分钟级。
> 真正的成败看 `⑦r 读回` 和 `⑦r +20s 复量`。
