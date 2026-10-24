# NotifyBox · 通知记录与消息盒子（iOS 16 roothide）

把系统收到的通知全部记录下来，并提供「消息盒子」App 做浏览 / 筛选 / 搜索；
进阶支持关键词过滤、内容替换、延迟推送、按 App 换提示音、朗读。

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

