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

# ---------- Tweak（SpringBoard 录制 + 过滤引擎） ----------
TWEAK_NAME = NotifyBox
NotifyBox_FILES = Tweak.x NotifyStore.m NotifyFilter.m
NotifyBox_FRAMEWORKS = Foundation CoreFoundation
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
NotifyBoxApp_FILES = app/main.m app/AppDelegate.m app/ViewController.m NotifyStore.m
NotifyBoxApp_INFOPLIST = Resources/Info.plist
NotifyBoxApp_FRAMEWORKS = UIKit Foundation MobileCoreServices
NotifyBoxApp_CFLAGS = -fobjc-arc -Wno-unused-parameter -Wno-unused-variable -Wno-deprecated-declarations
NotifyBoxApp_LIBRARIES = sqlite3
NotifyBoxApp_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

# 🔴 偏好包已通过 layout/Library/PreferenceLoader/Preferences/NotifyBox.bundle/ 随主包安装，
#    一条 make package install 即装 tweak + 盒子 App + 设置入口。
