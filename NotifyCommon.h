#ifndef NotifyCommon_h
#define NotifyCommon_h

#import <Foundation/Foundation.h>

// 🔴 共享常量：tweak 与盒子 App 必须一致（别各写一份）
#define NOTIFYBOX_BUNDLE_ID   @"com.yxh41.notifybox"
#define NOTIFYBOX_APP_BUNDLE  @"com.yxh41.notifybox.app"
// 🔴 roothide 沙盒特殊：tweak(跑在 SpringBoard) 与 App 都要能读写的路径。
//    真机已确认：盒子 App 能在 /var/mobile/Library/NotifyBox/ 建目录、写探针文件、读 sqlite。
#define NOTIFYBOX_DB_PATH     @"/var/mobile/Library/NotifyBox/notifybox.sqlite"
#define NOTIFYBOX_LOG_PATH    @"/var/mobile/Library/NotifyBox/tweak.log"

// ---------- 设置存储 ----------
// 🔴🔴 v0.0.8 起：设置的**唯一权威位置**是下面这个文件，不再用 Preferences 域。
//   两条理由，都是踩出来的：
//   ① PreferenceLoader 一装进包，设置 App 就进不去（两次复现），而且**没有崩溃日志**
//      ⇒ 不是闪崩，是挂起/被跳过 ⇒ 在这条路上盲调没有意义，已彻底弃用该通道。
//   ② /var/mobile/Library/Preferences/<id>.plist 归 cfprefsd 管：
//      App 直接写文件，cfprefsd 可能拿自己的缓存盖回去，出现「改了没生效」的幽灵现象。
//   新方案：盒子 App 写、tweak 读，**单一写入者、不经过 cfprefsd**。
#define NOTIFYBOX_SETTINGS_PATH @"/var/mobile/Library/NotifyBox/settings.plist"

// 旧路径：只为兼容 v0.0.7 及以前已经填过的值（只读兜底，不再写）
#define NOTIFYBOX_PREFS_PATH  @"/var/mobile/Library/Preferences/com.yxh41.notifybox.plist"

// 🔴 统一读入口：两个进程（SpringBoard 里的 tweak、盒子 App）都用它，避免各写一份逻辑。
//    判定口径 = **文件存在即权威**（哪怕内容是空字典）。
//    否则用户在设置页把选项全清空后，这里会因为 d.count==0 回落到旧 Preferences 域，
//    出现「我明明清了，怎么又生效了」——清空必须是能生效的动作。
static inline NSDictionary *NBLoadSettings(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:NOTIFYBOX_SETTINGS_PATH];
    if ([d isKindOfClass:[NSDictionary class]] && d) return d;
    d = [NSDictionary dictionaryWithContentsOfFile:NOTIFYBOX_PREFS_PATH];
    if ([d isKindOfClass:[NSDictionary class]] && d) return d;
    return @{};
}

#endif /* NotifyCommon_h */
