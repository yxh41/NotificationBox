#ifndef NotifyCommon_h
#define NotifyCommon_h

// 🔴 共享常量：tweak 与盒子 App 必须一致（别各写一份）
#define NOTIFYBOX_BUNDLE_ID   @"com.yxh41.notifybox"
#define NOTIFYBOX_APP_BUNDLE  @"com.yxh41.notifybox.app"
// 🔴 roothide 沙盒特殊：tweak(跑在 SpringBoard) 与 App 都要能读写的路径。
//    真机确认：roothide App 默认能访问 /var/mobile/... 吗？不能就用 App Group 容器。
#define NOTIFYBOX_DB_PATH     @"/var/mobile/Library/NotifyBox/notifybox.sqlite"
#define NOTIFYBOX_PREFS_PATH  @"/var/mobile/Library/Preferences/com.yxh41.notifybox.plist"

#endif /* NotifyCommon_h */
