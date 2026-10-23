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
#define NB_KEY_SPEAK_APPS     @"speakApps"       // 数组或 "a,b"，空/缺失 = 全部 App
#define NB_KEY_SPEAK_VOICE    @"speakVoice"      // AVSpeechSynthesisVoice.identifier，空 = 跟随系统
#define NB_KEY_SPEAK_RATE     @"speakRate"       // NSNumber(float)，缺失 = 系统默认语速

// ---------- 延迟推送（v0.0.14） ----------
// 语义：命中的通知**不立即弹出**，延后 N 秒再交给 BBServer 的发布方法。
// 🔴 0 / 缺失 = 关闭（默认关闭，因为它是唯一会**改变通知到达时间**的功能，风险最高）。
// 🔴 秒数上限在主判定函数里夹到 600 秒：用户手填个 86400 就等于让通知永远不出现。
#define NB_KEY_DELAY_SECONDS  @"delaySeconds"    // NSNumber 或 "5"，0/缺失 = 关闭
#define NB_KEY_DELAY_APPS     @"delayApps"       // 数组或 "a,b"，空/缺失 = 全部 App

// 🔴🔴 延迟推送的崩溃自愈标记（v0.0.15）。
//    延迟实现是"把 bulletin/request 攒在 block 里，N 秒后再调原发布方法"。
//    这条路上有两个我们控制不了的前提：
//      ① 那个对象在 N 秒后还能不能被安全使用（调用方可能已经把它作废/消费掉了）
//      ② 从别的队列/线程再去调一次发布，是否违反 SpringBoard 内部的前置条件
//    2026-10-21 15:51:30 实测：开了延迟之后 SpringBoard 直接
//        EXC_BREAKPOINT (SIGTRAP) + "Swift runtime trapped"（force-unwrapped nil /
//        array index out of range / failed precondition）⇒ 安全模式。
//    所以在延迟路径上复用「朗读自毁保护」那套：调度前写 start，原方法返回后写 done。
//    下次进程启动看到 start 而没有 done ⇒ 上次就是崩在延迟里 ⇒ 自动把 delaySeconds 清掉。
//    这样**以后每次实验最多崩一次**，不会陷入崩溃循环。
#define NOTIFYBOX_DELAY_GUARD_PATH @"/var/mobile/Library/NotifyBox/.delay_guard"

// ---------- 免打扰时段（v0.0.21）----------
// 语义：命中的通知**不弹**（同黑名单），但照常记进盒子。
// 这是 v0.0.19 删掉「延迟推送」之后给用户的**安全替代品** ——
// 延迟想解决的其实是"别在这个时间点吵我"，而"延迟"必须改系统的发布时间才能实现
// （两次撞死：跨队列 SIGTRAP / 通知永远到不了）；"这个时段直接不弹"则是**我们自己的判断**，
// 不碰 BB 内部、不改任何系统字段 ⇒ 从根上没有那两类风险。
// 🔴 时间一律存**分钟数**（0~1439），不存 "23:00" 字符串：
//    字符串要靠 App 和 tweak 各自解析一遍，两边只要差一点就是"填了不生效"，
//    而这种错完全静默（读到 nil = 关闭）。
#define NB_KEY_DND_ENABLED  @"dndEnabled"    // NSNumber(BOOL) 或 "1"/"0"
#define NB_KEY_DND_START    @"dndStart"      // NSNumber 分钟，例如 23*60=1380
#define NB_KEY_DND_END      @"dndEnd"        // NSNumber 分钟，可以小于 start（跨零点）
#define NB_KEY_DND_APPS     @"dndApps"       // 数组或 "a,b"，空/缺失 = 全部 App

// ---------- 按 App 换提示音（v0.0.21，实验）----------
// 🔴 实验性质，默认关闭，而且**必须显式选 App 才生效**。
//    原因（真机 PROBE 数据，2026-10-23）：
//      · `PROBE#1/2/3` 全是 `sound=nil` ⇒ 默认提示音根本不带 BBSound 对象；
//      · `BBSound 类方法共 1 个，其中相关 0 个` ⇒ **没有工厂方法**，只能自己 alloc/init 再填字段；
//      · `alertType` 是只读（R），可写的只有 `soundType` / `systemSoundID` / `vibrationIdentifier`。
//    ⇒ 也就是说这个功能在**造一个系统对象**，造坏了的结果是"这条通知不出声"（不是崩溃）。
//    所以：默认关、必须点名 App、每次尝试都留 SOUND# 留痕、失败自动回退到默认声音。
#define NB_KEY_SOUND_ENABLED @"soundEnabled"  // NSNumber(BOOL)
#define NB_KEY_SOUND_ID      @"soundID"       // NSNumber(int)，1000~1035 是系统提示音区段
#define NB_KEY_SOUND_APPS    @"soundApps"     // 数组或 "a,b"；**空 = 不生效**（与其它名单语义相反）

// 换提示音的崩溃自愈标记。
// 🔴 v0.0.21 这一版**写法和 v0.0.15 的延迟 guard 不同**，因为那个写法骗过人：
//    v0.0.15 只写 start、从不写 done（那版延迟是关的），于是文件永久停在 start，
//    从 v0.0.16 起每次启动都误报"上次崩在延迟里"，还谎称"已自动删掉设置"。
//    ⇒ 这一次 write(start) / write(done) **配对出现在同一个函数里**（NotifyFilter），
//      读取侧必须**回读确认**自己真的把开关关掉了，再打日志。
#define NOTIFYBOX_SOUND_GUARD_PATH @"/var/mobile/Library/NotifyBox/.sound_guard"

// 🔴 「一组 bundle id」的读法只在这里写一份。
//    历史数据是**逗号分隔字符串**（v0.0.12 及以前是输入框），
//    新数据是**数组**（v0.0.13 的选择器写）。
//    两种都必须认 —— 否则老用户升级后就是「我明明配了白名单，怎么全放行了」，
//    而且这种错完全静默：设置文件在、内容在，就是解析不出来。
static inline NSArray<NSString *> *NBStringArray(id v) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    if ([v isKindOfClass:[NSArray class]]) {
        for (id e in (NSArray *)v) {
            if (![e isKindOfClass:[NSString class]]) continue;
            NSString *t = [(NSString *)e stringByTrimmingCharactersInSet:ws];
            if (t.length) [out addObject:t];
        }
    } else if ([v isKindOfClass:[NSString class]]) {
        for (NSString *p in [(NSString *)v componentsSeparatedByString:@","]) {
            NSString *t = [p stringByTrimmingCharactersInSet:ws];
            if (t.length) [out addObject:t];
        }
    }
    return out;
}

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
