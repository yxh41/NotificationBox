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
