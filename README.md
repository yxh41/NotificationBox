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
| 关键词过滤 | `NotifyFilter.shouldDrop:`（blockKeywords） | 阶段2 |
| 内容替换（规则） | `NotifyFilter.applyToBulletin:`（replaceRules） | 阶段2 |
| 延迟推送 | `Tweak.x` TODO：return + `dispatch_after` 再 `%orig` | 阶段3 ⚠️ |
| 按 App 换提示音 | `NotifyFilter.applyToBulletin:`（appSounds，待确认 API） | 阶段3 ⚠️ |
| 朗读（TTS） | `AVSpeechSynthesizer`（待加，黑白名单/关键词） | 阶段3（可选） |

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
