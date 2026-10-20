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

## 🔴 真机必须确认的事项（Flex3 / 砸壳后头文件核对）

1. **BBServer 的发布入口方法名**：默认 hook `- [BBServer publishBulletin:]`。
   用 Flex3 看 iOS 16 实际是 `publishBulletin:` 还是 `_publishBulletin:destinations:`（或别的），
   不对就改 `Tweak.x` 里的方法名（逻辑不变）。**不要同时 hook 同一个真实方法**，会重复处理。
2. **BBBulletin 的属性名**：`sectionID` / `title` / `message` / `subtitle` / `date` / `sound`
   在 iOS 16 是否就叫这些（尤其 `sectionID` 是否等于 App 的 bundleId）。`NotifyFilter.h` 里是最小接口。
3. **DB 路径可达性**：roothide 下盒子 App 能否读写 `/var/mobile/Library/NotifyBox/`？
   不行就改用 App Group 容器或 daemon 中转。
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

## 已知坑 / 待办

- **延迟推送**风险最高：再注入的 bulletin 不走 App 自身逻辑，属「再展示一次」，体验需评估。
- **App 图标**：已用 `LSApplicationProxy applicationProxyForIdentifier:` + `iconDataForVariant:` 取真图标
  （顶部筛选栏 + 列表左侧）。`iconDataForVariant:` 的 variant 取值（当前 0=默认图标）若拿到空图，
  真机调一下即可。纯 App 侧、不依赖 hook 方法名，已落地。
- **声音 / 延迟**两项的 iOS 16 具体 API 未在沙箱内验证，标记了 🔴 TODO。
- **roothide 沙盒**：tweak 与 App 共享 DB 的路径需真机确认可写。
