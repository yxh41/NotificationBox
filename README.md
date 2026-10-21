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

## 已知坑 / 待办

- **延迟推送**风险最高：再注入的 bulletin 不走 App 自身逻辑，属「再展示一次」，体验需评估。
- **App 图标**：已用 `LSApplicationProxy applicationProxyForIdentifier:` + `iconDataForVariant:` 取真图标
  （顶部筛选栏 + 列表左侧）。`iconDataForVariant:` 的 variant 取值（当前 0=默认图标）若拿到空图，
  真机调一下即可。纯 App 侧、不依赖 hook 方法名，已落地。
- **声音 / 延迟**两项的 iOS 16 具体 API 未在沙箱内验证，标记了 🔴 TODO。
- **roothide 沙盒**：tweak 与 App 共享 DB 的路径需真机确认可写。
