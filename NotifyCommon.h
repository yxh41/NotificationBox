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

// ---------- 朗读（v0.0.12） ----------
// 🔴 设置键名只在这里定义一份：App 写、tweak 读，任何一边拼错就是「开了不生效」，
//    而这种错在运行时完全是静默的（读到一个不存在的键 = nil = 关）。
#define NB_KEY_SPEAK_ENABLED  @"speakEnabled"    // NSNumber(BOOL) 或 "1"/"0"
#define NB_KEY_SPEAK_APPS     @"speakApps"       // NSString "a,b"，空/缺失 = 全部 App

// 🔴🔴 朗读自毁保护用的标记文件。
//    朗读要跑 ARSpeechSynth（AVSpeechSynthesizer），运行在 SpringBoard 里 ——
//    这是整个插件里**唯一**会去碰音频子系统的动作，也是最可能把 SpringBoard 拖崩的地方。
//    一旦崩，用户看到的是连续安全模式，而「关掉朗读」这个动作本身要做进 App 里、
//    可 App 又打不开 ⇒ 死锁。
//    解法：朗读**开始前**写入 "start"，真正播出后写入 "done"。
//    下次进程启动时若看到 "start" 而没有 "done" ⇒ 上次就是崩在朗读里
//    ⇒ 直接把 speakEnabled 写成 NO 并留日志。崩溃自愈，不依赖用户操作。
#define NOTIFYBOX_SPEAK_GUARD_PATH @"/var/mobile/Library/NotifyBox/.speak_guard"

// ---------- 统一日志 ----------
// 🔴 v0.0.12：原来 Tweak.x 里有份 static NBLog，新加的 NotifySpeaker/NotifyProbe 够不着。
//    **复制一份日志函数**是最差解（两份轮转逻辑迟早走岔），所以把实现沉到 NotifyStore.m
//    （这个文件 tweak 与盒子 App 都编译），头里只留声明。
//    轮转策略不变：超过 512 KB 切成 <path>.1，覆盖上一份。
void NBSharedLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

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

// 🔴 布尔型设置值的统一解读。
//    为什么要统一：App 用 @(YES) 写进去的是 NSNumber，但手改 plist 的人常写成 "1"/"true"。
//    **两边各写一份解读逻辑**是最危险的做法 —— App 认 "true"、tweak 只认 NSNumber 时，
//    用户会看到"开关明明是开的、功能就是不生效"，而且任何保存期检查都发现不了。
static inline BOOL NBBoolValue(id v) {
    if (!v) return NO;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [[(NSString *)v lowercaseString]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return ([s isEqualToString:@"1"] || [s isEqualToString:@"yes"]
                || [s isEqualToString:@"true"] || [s isEqualToString:@"on"]);
    }
    return NO;
}

#endif /* NotifyCommon_h */
