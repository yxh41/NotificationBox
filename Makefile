# ===== NotifyBox · roothide Theos 构建（iOS 16，arm64e） =====
# 🔴 TARGET 必须是 16.5：theos/sdks 仓库最高只有 iPhoneOS16.5.sdk，
#    写 16.0 会在 GitHub Actions / 干净 Theos 里「找不到 SDK」。
#    16.5 SDK 编出来、最低部署 16.0，在 iOS 16.0–16.7 都能跑。
ARCHS = arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = roothide
FINALPACKAGE = 1
DEBUG = 0

include $(THEOS)/makefiles/common.mk

# ---------- Tweak（SpringBoard 录制 + 过滤引擎 + 朗读） ----------
TWEAK_NAME = NotifyBox
# 🔴 v0.0.12 新增两件：NotifySpeaker（朗读 + 崩溃自愈）、NotifyProbe（BB 侧只读探针）
# 🔴 v0.0.22 新增 NotifySoundDiag：换提示音「听不到」的只读诊断。
#    **只进 tweak，不进 App** —— 它要 objc runtime 反射 BB 的私有类，
#    在盒子 App 进程里那些类根本不存在，编进去也是死代码。
#    也**不要**塞进 NotifyFilter.m：重型只读观测和"刀"必须分开，
#    否则刀被观测代码拖出异常时，两个都成了嫌疑犯，一轮下来解释不清。
NotifyBox_FILES = Tweak.x NotifyStore.m NotifyFilter.m NotifySpeaker.m NotifyProbe.m NotifySoundDiag.m
# 🔴 AVFoundation 必须显式链接，否则 AVSpeechSynthesizer 的符号在加载期解析不到
#    ⇒ 整条 dylib 加载失败 ⇒ 表面上"tweak 没注入"，实际是链接问题。
#    SpringBoard 本身就用 AVFoundation（系统提示音），所以链接是安全的；
#    但**调用**仍然先用 NSClassFromString 探一次（见 NotifySpeaker.m）。
# 🔴 AVFAudio 也要链：iOS 14 起 AVSpeechSynthesizer 本体搬到了 AVFAudio，
#    AVFoundation 只是 re-export。只靠 re-export 能过，但一旦 SDK 变了就是
#    "undefined symbol _OBJC_CLASS_$_AVSpeechSynthesizer" —— 那种报错看着像代码问题，
#    其实是链接配置问题，很费一轮。
# 🔴 v0.0.25 加 AudioToolbox：换提示音改成「自己播系统提示音」
#    （NotifyFilter.m 里的 AudioServicesPlaySystemSound）。
#    ⚠️ **两个目标都要链** —— NotifyFilter.m 是 tweak 和盒子 App **两边都编**的，
#    只在 tweak 侧链的话，App 侧就是链接期 undefined symbol
#    `_AudioServicesPlaySystemSound`（这种报错看着像代码问题，其实是构建配置）。
NotifyBox_FRAMEWORKS = Foundation CoreFoundation AVFoundation AVFAudio AudioToolbox
# 🔴 不链 BulletinBoard 私有框架：`%hook BBServer` 是运行期 objc_getClass 查找，
#    BBBulletin 由我们自己声明接口 ⇒ 无需链接，留着反而在精简 SDK 里找不到而报错。
NotifyBox_CFLAGS = -fobjc-arc -Wno-unused-parameter -Wno-unused-variable -Wno-deprecated-declarations
NotifyBox_LIBRARIES = sqlite3

include $(THEOS_MAKE_PATH)/tweak.mk

# ---------- 独立盒子 App（读库展示） ----------
# Info.plist 走 Theos 约定：项目根 Resources/Info.plist（自动成为 app bundle 的 Info.plist）
# 🔴🔴 应用目标的变量是 APPLICATION_NAME（不是 APP_NAME —— 那是 Xcode 的概念）。
#      写错时 application.mk 拿不到实例 ⇒ **静默跳过、不报错**，deb 里就没有 App。
APPLICATION_NAME = NotifyBoxApp
# 🔴 盒子 App 也要编进 NotifyStore.m（ViewController 调它），否则链接时全是 undefined symbols
# 🔴 v0.0.13 新增三个：AppPicker（可搜索多选）、VoicePicker（选声音+试听）、InstalledApps（枚举）
# 🔴🔴 v0.0.14 新增 NotifyFilter.m：内容替换页的「试运行」与「命中统计」必须调用
#      **引擎里那个同一个函数**（applyRulesToString），不能在 App 里再写一份顺序套用 ——
#      两份逻辑一旦走岔，用户看到的试运行结果就是假的。
#      只加 .m 不加 .h 是够的（头文件已 import）；注意它不链 BulletinBoard，只用自己声明的 BBBulletin 接口。
# 🔴🔴 v0.0.23 把 NotifySoundDiag.m 加进 App 的 FILES。
#      ⚠️ v0.0.25 更正：当初的理由（"NotifyFilter.m 里要调诊断"）**记错了对象** ——
#      `probeAfterPublish:` / `noteForeignSoundIfAny:` 一直是 **Tweak.x** 调的，
#      而 v0.0.25 把 NotifyFilter.m 里最后一处诊断调用（probeCreatedSound）也删了，
#      所以**现在 App 侧其实已经不需要 NotifySoundDiag.m**。
#      仍然留着不删：它编得过、不产生行为，而"少动一处构建配置"比"少一个文件"值钱
#      （构建配置出错的表现是 undefined symbol，最像代码 bug、最费轮次）。
#      真要瘦身的话可以删，删之前先确认 App 侧没有任何 NBSoundDiag 引用。
# 🔴🔴 v0.0.26 新增 app/SoundFilePickerViewController.m：选自定义提示音文件。
#      ⚠️ 必须同时把 .h 写好并 import，否则 application.mk 编译期报
#      "cannot find interface declaration"（看着像代码问题，其实是漏了文件）。
# 🔴🔴 v0.0.28 新增 app/SoundAppsViewController.m：按 App 分配提示音的总览页。
#      ⚠️ 这一条**必须加**，而且失败得很安静：SettingsViewController 里 import 了它、
#      也 new 了它，但 application.mk 不会自动去收目录里的新文件 ⇒
#      编译期过、**链接期**报 `undefined symbol _OBJCCLASS_$_SoundAppsViewController`。
#      看到这个符号名先查这里，不要去查代码。
NotifyBoxApp_FILES = app/main.m app/AppDelegate.m app/ViewController.m app/SettingsViewController.m app/ReplaceRulesViewController.m app/NotifyCell.m app/AppIconLoader.m app/AppPickerViewController.m app/VoicePickerViewController.m app/SoundFilePickerViewController.m app/SoundAppsViewController.m app/InstalledApps.m NotifyStore.m NotifyFilter.m NotifySoundDiag.m
NotifyBoxApp_INFOPLIST = Resources/Info.plist
# 🔴 App 侧也要 AVFoundation/AVFAudio：声音选择页要**试听**，那是在 App 里跑的 TTS。
#    不链的话编译期就找不到 AVSpeechSynthesizer，而 tweak 侧那份救不了 App。
NotifyBoxApp_FRAMEWORKS = UIKit Foundation MobileCoreServices AVFoundation AVFAudio AudioToolbox
NotifyBoxApp_CFLAGS = -fobjc-arc -Wno-unused-parameter -Wno-unused-variable -Wno-deprecated-declarations
NotifyBoxApp_LIBRARIES = sqlite3
NotifyBoxApp_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

# 🔴🔴 v0.0.8：**不再往包里放 PreferenceLoader 载荷**。
#    事实（两次复现）：只要 layout/ 下有 Preferences/NotifyBox.bundle，设置 App 就进不去，
#    而且**没有崩溃日志** ⇒ 不是闪崩，是挂起/被跳过 ⇒ 在这条通道上盲调没有收益。
#    设置已改为内置在盒子 App 的「设置」页里（写 /var/mobile/Library/NotifyBox/settings.plist）。
#    偏好包源码保留在 _prefs_disabled/ 仅供备查，**不要**再挪回 layout/ 除非有新证据。
