#import "NotifyFilter.h"
#import "NotifyCommon.h"
// 🔴 v0.0.28：按 App 分配提示音的**写盘**走 NotifyStore（与其它页面同一条写路径）。
//    NotifyStore.m 在 tweak 与 App 两个 FILES 里都有，所以两边都链得到。
#import "NotifyStore.h"
#import <AudioToolbox/AudioToolbox.h>   // v0.0.25：AudioServicesPlaySystemSound（换提示音改成「自己播」）
// 🔴 v0.0.26：播自定义音频文件。mp3/m4a 走不了 AudioServices（它只吃 caf/wav/aiff 这类），
//    必须用 AVAudioPlayer 兜底。AVFoundation 在 Makefile 里两个目标都已链接
//    （朗读早就在用），所以这里只管 import。
#import <AVFoundation/AVFoundation.h>
// 🔴 v0.0.23：造完 BBSound 之后要把它的字段实值打出来（落盘）。
//    NotifyFilter.m **也被盒子 App 编译**，所以 NotifySoundDiag.m 必须一起进 App 的 FILES，
//    否则链接期就是 undefined symbol（这种错看着像代码问题，其实是构建配置）。
#import "NotifySoundDiag.h"
// 🔴 v0.0.29：把"这一声归谁"挂在 AVAudioPlayer 上（objc_setAssociatedObject）。
//    显式 import 而不是靠 Foundation 间接带进来 —— 后者随 SDK 版本变，不值得赌。
#import <objc/runtime.h>
#import <objc/runtime.h>       // v0.0.16 起为探针引入；v0.0.19 删掉延迟后本文件已不用 objc_* 函数，
                              // 但保留这个 import 无害，且省得下次要加探针时又忘

// 🔴 v0.0.22：换提示音「该不该生效」的判定**只写这一处**。
//    刀（v0.0.25 起是 playCustomSoundForBundle）和诊断（isSoundTargetBundle）都调它。
//    理由见本文件顶部那一版说明：两处各写一份，一旦走岔就是
//    "诊断说该生效、刀说不该生效"，而刀往往才是对的 —— 那一轮直接白跑。
typedef NS_ENUM(NSInteger, NBSoundVerdict) {
    NBSoundVerdictOK = 0,      // 该生效
    NBSoundVerdictOff,         // 功能没开 / 设置读不到 / 读的时候抛异常
    NBSoundVerdictBadID,       // ID 不在 1000~1035（且没有选文件）
    NBSoundVerdictEmptyApps,   // App 名单为空（语义与其它名单相反：空 = 不生效）
    NBSoundVerdictNotListed,   // 这个 App 不在名单里
    NBSoundVerdictBadFile,     // v0.0.26：选了文件，但文件名不合法 / 文件不存在
};

// v0.0.30：**跨模块探针的"接口声明"**。
//
// 为什么要绕这么一圈：交给音频会话之前必须问"朗读在播吗"，而朗读在 NotifySpeaker 里；
// 可 NotifySpeaker.m **只编进 SpringBoard，没有编进盒子 App**（Makefile 的 App_FILES 里没有它）。
// ⇒ 直接 `[NotifySpeaker isSpeakingNow]` 在 App 上会在**链接期** undefined symbol，
//   编译期看不出来、真机装上去才炸。
//
// 正确姿势是三步：
//   ① `NSClassFromString(@"NotifySpeaker")` 查"这个进程里有没有这个类"（App 里没有 ⇒ nil）；
//   ② 下面这个 **NSObject 的分类**告诉 clang "任何类都可能响应 +isSpeakingNow"
//      —— 拿裸 Class 变量发类方法消息，clang 会说 "no known class method"，-Werror 直接挂；
//   ③ 运行期 `respondsToSelector:` 兜底，声明与实现不一致时也不会崩。
//
// 🔴🔴 这里**不能**写成 `@protocol NBSpeakerProbe` + `[(id<NBSpeakerProbe>)spk isSpeakingNow]`：
//    给 `id<协议>` 发消息时 clang 只查协议里的**实例方法**，而 isSpeakingNow 是**类方法**
//    ⇒ 报 `no known instance method for selector` ⇒ -Werror 挂。
//    （这个项目没有 Mac、编译只能在 CI 上跑，所以这种"编译期才暴露"的写法必须提前想清楚。）
//    分类声明 + `Class` 变量才是对的路子：给 Class 发消息，clang 查的是类方法。
//    声明与实现分离也不违规 —— 只有 `@interface` 的分类是合法的"informal protocol"写法。
@interface NSObject (NBSpeakerProbe)
+ (BOOL)isSpeakingNow;
@end

@interface NotifyFilter ()
// outSID / outFile / outMaxSec 都可为 NULL。任何异常都返回 NBSoundVerdictOff ——
// 这个功能的失效方式必须是"什么都不做"，绝不能影响通知本身。
//
// 🔴 v0.0.26：多了一个 outFile。**判定口径仍然只有这一个函数** ——
//    两个输出的关系是「outFile 非空 ⇒ 播文件（优先）；否则看 outSID」。
//    旧的两参版本留作包装（诊断在用），内部转调这一个。
// 🔴 v0.0.31：多了 outMaxSec —— **算出的是最终生效的秒数**（entry 有就用 entry 的，
//    否则用全局），不是一个"可能还要兜底"的半成品。理由同上面那条：
//    如果让调用方自己再兜一次底，就等于"兜底逻辑两份"，迟早走岔
//    （症状是"界面说 30 秒停、实际 8 秒就停"，这种几乎没法自证）。
+ (NBSoundVerdict)soundVerdictForBundle:(nullable NSString *)bundle
                                soundID:(NSInteger *)outSID
                              soundFile:(NSString * _Nullable * _Nullable)outFile
                                 maxSec:(double *)outMaxSec;
+ (NBSoundVerdict)soundVerdictForBundle:(nullable NSString *)bundle
                                soundID:(NSInteger *)outSID
                              soundFile:(NSString * _Nullable * _Nullable)outFile;
+ (NBSoundVerdict)soundVerdictForBundle:(nullable NSString *)bundle soundID:(NSInteger *)outSID;

// v0.0.26：文件播放的两条通道（只在内部用）
+ (BOOL)nbPlayViaAudioServices:(NSString *)path why:(NSString **)why;
// v0.0.27：maxSec > 0 时到点 stop（0 = 不限）。只有 B 通道能截断，A 通道做不到。
// v0.0.29：owner 是"这一声归谁"（通知 = bundleId；试听 = @preview）。
//          **同一个 owner 的新音会把旧音停掉**，不同 owner 互不影响 —— 见实现处的注释。
+ (BOOL)nbPlayViaAVPlayer:(NSString *)path
                   maxSec:(NSTimeInterval)maxSec
                    owner:(NSString *)owner
                      why:(NSString **)why;

// v0.0.29：内部真正干活的播放入口（公开的 playSoundFileNamed: 转调它，owner 传 @preview）
// v0.0.31：多了 cap —— 这个 App 自己的「最长播放秒数」。
//          🔴 **负数 = 调用方没指定，用全局**。为什么不用 0 当哨兵：0 在这套语义里是合法值（不限），
//          让它兼职"没指定"就分不开"不限"和"忘了传"（而这两者行为差得远）。
+ (BOOL)nbPlaySoundFile:(NSString *)name
               forOwner:(NSString *)owner
                    cap:(double)cap
                 result:(NSString **)result;

// v0.0.27：时长上限相关（都只在内部用）
+ (NSTimeInterval)nbDurationOfFile:(NSString *)path;   // -1 = 量不出来
+ (NSTimeInterval)nbSoundMaxSec;                       // 0 = 不限
// v0.0.31：选路 + 文案的唯一实现（cap < 0 = 跟随全局）。
// 🔴 必须在这里声明：C 类方法不声明就调用，clang 报 "no known class method for selector"
//    ⇒ 本工程开着 -Werror ⇒ 编译直接挂。（同类坑：tweak 侧 %new 方法也必须在顶部声明。）
+ (NSString *)nbPlaybackPlanForFile:(NSString *)name cap:(double)cap;
// 通道优先级：YES = 先试 A（已验证通道），NO = 先走 B。**选路逻辑只写在这一处。**
+ (BOOL)nbPrefersAudioServicesForDuration:(NSTimeInterval)dur cap:(NSTimeInterval)cap;
@end

@implementation NotifyFilter

+ (NSDictionary *)prefs {
    return NBLoadSettings();          // 新文件优先，旧 Preferences 域只作只读兜底
}

// 偏好里可能是数组(多值)也可能是逗号分隔字符串(文本框)，统一成**去空白、去空项**的字符串数组。
//
// 🔴🔴 v0.0.7 这里写的是：
//        return [[v componentsSeparatedByString:@","]
//                 valueForKey:@"stringByTrimmingCharactersInSet:"];
//    这是**会崩的写法**：NSArray 的 valueForKey: 拿到带冒号的键，KVC 找不到对应 key
//    ⇒ 抛 NSUndefinedKeyException ⇒ 在 SpringBoard 里就是闪退 / 进安全模式。
//    它之所以一直没炸，只因为 NotifyFilter 从来没被调用过（死代码）。
//    接线（v0.0.8）之前必须先修掉 —— 这正是「接线不是免费的」最典型的例子。
+ (NSArray<NSString *> *)arrayFromPref:(nullable id)v {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    if ([v isKindOfClass:[NSArray class]]) {
        for (id e in (NSArray *)v) {
            if (![e isKindOfClass:[NSString class]]) continue;   // 数组里可能是 NSNumber
            NSString *t = [(NSString *)e stringByTrimmingCharactersInSet:ws];
            if (t.length) [out addObject:t];
        }
    } else if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) {
        for (NSString *part in [(NSString *)v componentsSeparatedByString:@","]) {
            NSString *t = [part stringByTrimmingCharactersInSet:ws];
            if (t.length) [out addObject:t];
        }
    }
    return out;
}

+ (BOOL)shouldDropBundle:(NSString *)bundle
                   title:(NSString *)title
                 message:(NSString *)message
                subtitle:(NSString *)subtitle {
    @try {
        NSDictionary *p = [self prefs];
        if (!p.count) return NO;                 // 没有任何设置 ⇒ 绝不改变任何行为

        NSString *bid = bundle.length ? bundle : @"";

        // 黑名单：直接拦
        if ([[self arrayFromPref:p[@"blacklist"]] containsObject:bid]) return YES;

        // 白名单：只有**填了**才生效；不在名单里的都拦
        // 🔴 这是有杀伤力的语义（等于「只留这几个 App」），所以只在 white.count>0 时动手
        NSArray *white = [self arrayFromPref:p[@"whitelist"]];
        if (white.count && ![white containsObject:bid]) return YES;

        // 关键词过滤：标题+正文+副标题 里出现就拦（记录已在此之前完成，盒子里仍能看到）
        NSArray *kw = [self arrayFromPref:p[@"blockKeywords"]];
        if (kw.count) {
            NSString *text = [NSString stringWithFormat:@"%@ %@ %@",
                              title ?: @"", message ?: @"", subtitle ?: @""];
            for (NSString *k in kw) {
                if ([text rangeOfString:k].location != NSNotFound) return YES;
            }
        }
    } @catch (__unused NSException *e) {
        return NO;      // 判错就放行：宁可多推一条，也不要把通知吞掉
    }
    return NO;
}

+ (NSArray<NSDictionary *> *)normalizedRules:(id)raw {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    if (![raw isKindOfClass:[NSArray class]]) return out;      // 缺失 / 脏数据 ⇒ 空表，不是崩溃
    for (id e in (NSArray *)raw) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        id fromObj = ((NSDictionary *)e)[@"from"];
        // from 为空 ⇒ 这条规则什么都不做。真要让它跑，stringByReplacingOccurrencesOfString:
        // 拿到空 from 的行为是未定义的（可能无限/异常），直接丢。
        if (![fromObj isKindOfClass:[NSString class]] || ![(NSString *)fromObj length]) continue;
        id toObj = ((NSDictionary *)e)[@"to"];
        NSString *to = [toObj isKindOfClass:[NSString class]] ? (NSString *)toObj : @"";
        [out addObject:@{@"from": (NSString *)fromObj, @"to": to}];
    }
    return out;
}

+ (NSString *)applyRulesToString:(NSString *)text rules:(NSArray *)rules hits:(NSMutableArray<NSNumber *> *)hits {
    if (![text isKindOfClass:[NSString class]] || ![(NSString *)text length]) return text ?: @"";
    if (![rules isKindOfClass:[NSArray class]] || ![(NSArray *)rules count]) return text;

    NSString *cur = text;
    NSUInteger n = [(NSArray *)rules count];
    @try {
        for (NSUInteger i = 0; i < n; i++) {
            id r = ((NSArray *)rules)[i];
            if (![r isKindOfClass:[NSDictionary class]]) continue;
            id fromObj = ((NSDictionary *)r)[@"from"];
            if (![fromObj isKindOfClass:[NSString class]] || ![(NSString *)fromObj length]) continue;
            id toObj = ((NSDictionary *)r)[@"to"];
            NSString *from = (NSString *)fromObj;
            NSString *to   = [toObj isKindOfClass:[NSString class]] ? (NSString *)toObj : @"";

            if ([cur rangeOfString:from].location == NSNotFound) continue;
            // stringByReplacingOccurrencesOfString: 是**全部替换**（不是只换第一个）。
            // 引擎和界面的口径必须一致 ⇒ 都走这一行，别在别处再写一次替换。
            cur = [cur stringByReplacingOccurrencesOfString:from withString:to];
            if (hits && i < hits.count) {
                hits[i] = @(hits[i].unsignedIntegerValue + 1);
            }
        }
    } @catch (__unused NSException *e) {
        return text ?: @"";        // 替换出错就当没配，原样返回
    }
    return cur;
}

// 🔴🔴 v0.0.19：延迟推送的整段实现（shouldDelayBundle: / applyDelayToBulletin: /
//    probeTimeFieldsOfBulletin:）已从本文件删除，接口也从头文件撤掉。
//
// 为什么是"删除"而不是"留一个常量门"：
//   v0.0.15 的做法是 `static const BOOL kDelayEnabled = NO;` —— 那是**编译期常量**，
//   整段会被 DCE 掉，看起来"删掉了"。但它的实际效果是**把刀留在抽屉里**：
//   谁改一个字（NO→YES）就能重新打开，而打开之后的症状是"通知全不弹/闪退"，
//   属于最难归因的那一类。两次真机事故（SIGTRAP 进安全模式、通知全不弹）都是这么来的。
//   ⇒ 要恢复这个功能，必须先推翻 README「v0.0.19」那一章里的两条真机证据，
//     而不是改一个字符。
//
// 判据（.workbuddy/tmp/nb_delay_gate.py，负向对照必红）：
//   ① 本文件里不许出现 dateByAddingTimeInterval / NB_KEY_DELAY_SECONDS；
//   ② 头文件里不许声明 shouldDelayBundle: / applyDelayToBulletin:；
//   ③ Tweak.x 里不许出现 dispatch_after / d.delay 分支；
//   ④ 反方向的哨兵：shouldDropBundle: / applyReplaceRulesTo: 必须还在
//      —— 否则"删干净了"可能是"整个文件被删了"。


+ (BOOL)applyReplaceRulesTo:(id)bulletin {
    if (!bulletin) return NO;
    @try {
        NSDictionary *p = [self prefs];
        // 规则格式：[{from, to}, ...]；没配就直接返回，零开销零行为变化
        NSArray *rules = [self normalizedRules:p[@"replaceRules"]];
        if (!rules.count) return NO;

        BBBulletin *b = (BBBulletin *)bulletin;
        BOOL changed = NO;

        // 🔴 三个字段**各自独立**套用整串规则（字段之间互不影响），这与 v0.0.8 的行为一致。
        // 🔴 用**属性访问**而不是 performSelector: ——
        //    传变量 SEL 给 performSelector: 会触发 -Warc-performSelector-leaks（本项目开 -Werror）。
        //    每个 getter/setter 都单独 respondsToSelector 探一次：
        //    request 包装类通常没有 setTitle:，探不到就跳过，绝不硬写。
        if ([b respondsToSelector:@selector(title)] && [b respondsToSelector:@selector(setTitle:)]) {
            NSString *t = b.title;
            if ([t isKindOfClass:[NSString class]]) {
                NSString *n = [self applyRulesToString:t rules:rules hits:nil];
                if (![n isEqualToString:t]) { b.title = n; changed = YES; }
            }
        }
        if ([b respondsToSelector:@selector(message)] && [b respondsToSelector:@selector(setMessage:)]) {
            NSString *t = b.message;
            if ([t isKindOfClass:[NSString class]]) {
                NSString *n = [self applyRulesToString:t rules:rules hits:nil];
                if (![n isEqualToString:t]) { b.message = n; changed = YES; }
            }
        }
        if ([b respondsToSelector:@selector(subtitle)] && [b respondsToSelector:@selector(setSubtitle:)]) {
            NSString *t = b.subtitle;
            if ([t isKindOfClass:[NSString class]]) {
                NSString *n = [self applyRulesToString:t rules:rules hits:nil];
                if (![n isEqualToString:t]) { b.subtitle = n; changed = YES; }
            }
        }
        return changed;
    } @catch (__unused NSException *e) {
        return NO;      // 替换失败就当没配，原样放行
    }
}

// ══════════════════════════════════════════════════════════════════
// v0.0.21 · 免打扰时段 + 按 App 换提示音（实验）
// ══════════════════════════════════════════════════════════════════

// 把设置里的"时间"读成分钟数（0~1439）。读不出来返回 -1。
// 🔴 两种形态都认：NSNumber（App 写的）和 "23:00"（手改 plist 的人会这么写）。
//    只认一种的结果是"我明明填了却不生效"，而且完全静默 —— 这个坑项目里踩过。
static NSInteger NBMinutesValue(id v) {
    if ([v isKindOfClass:[NSNumber class]]) {
        NSInteger n = [(NSNumber *)v integerValue];
        return (n >= 0 && n < 24 * 60) ? n : -1;
    }
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray *parts = [s componentsSeparatedByString:@":"];
        if (parts.count != 2) {
            // 纯数字也当分钟数接受（避免"我填 1380 它说格式不对"）
            NSInteger n = [s integerValue];
            return (n >= 0 && n < 24 * 60) ? n : -1;
        }
        NSInteger h = [parts[0] integerValue];
        NSInteger m = [parts[1] integerValue];
        if (h < 0 || h > 23 || m < 0 || m > 59) return -1;
        return h * 60 + m;
    }
    return -1;
}

static NSString *NBClockText(NSInteger minutes) {
    if (minutes < 0) return @"?";
    return [NSString stringWithFormat:@"%02ld:%02ld",
            (long)(minutes / 60), (long)(minutes % 60)];
}

+ (BOOL)shouldDropForDND:(NSString *)bundle
                     now:(NSDate *)now
                  reason:(NSString **)reason {
    if (reason) *reason = nil;
    @try {
        NSDictionary *p = [self prefs];
        if (!p.count) return NO;
        if (!NBBoolValue(p[NB_KEY_DND_ENABLED])) return NO;

        NSInteger start = NBMinutesValue(p[NB_KEY_DND_START]);
        NSInteger end   = NBMinutesValue(p[NB_KEY_DND_END]);
        // 🔴 没配全 / 配错 / 开始==结束 ⇒ 一律不生效。
        //    开始==结束如果按"窗口"算就是 24 小时全静音，用户会以为通知坏了。
        if (start < 0 || end < 0 || start == end) return NO;

        NSArray *apps = [self arrayFromPref:p[NB_KEY_DND_APPS]];
        if (apps.count && ![apps containsObject:(bundle.length ? bundle : @"")]) return NO;

        NSDateComponents *c = [[NSCalendar currentCalendar]
                               components:(NSCalendarUnitHour | NSCalendarUnitMinute)
                                 fromDate:(now ?: [NSDate date])];
        NSInteger m = c.hour * 60 + c.minute;

        // 跨零点是常态（23:00~07:00），必须分两种情况算。
        // 🔴 这是这个功能唯一真正容易写错的地方，写错的症状是"早上七点后还是不弹"。
        BOOL inWindow = (start < end) ? (m >= start && m < end)
                                      : (m >= start || m < end);
        if (!inWindow) return NO;

        if (reason) {
            *reason = [NSString stringWithFormat:@"%@~%@", NBClockText(start), NBClockText(end)];
        }
        return YES;
    } @catch (__unused NSException *e) {
        return NO;      // 判错就不拦：宁可吵一下，绝不能莫名其妙全都不弹
    }
}

// ---------- 按 App 换提示音（实验） ----------
//
// 真机 PROBE 数据（2026-10-23，v0.0.20）决定了这里的写法，一条都不能凭猜：
//   · `PROBE#1/2/3` 全部 `sound=nil` ⇒ 默认提示音**不带 BBSound 对象**，
//     想换就必须自己造一个；
//   · `PROBE BBSound 类方法共 1 个，其中相关 0 个` ⇒ **没有工厂方法**可用；
//   · `sound{T@"BBSound",&,N,V_sound}` ⇒ 属性可写，`setValue:forKey:@"sound"` 能挂上；
//   · `alertType` 是只读（R），可写的只有 `soundType` / `systemSoundID` / `vibrationIdentifier`。
// ⇒ 所以是"alloc + init + 填两个可写字段"，**没有任何官方保证**。
//   失败/造坏的结果是"这条通知不出声"（不是崩溃）⇒ 所以默认关闭 + 必须点名 App。

static NSString *const kNBGuardStart = @"start";
static NSString *const kNBGuardDone  = @"done";

static void NBWriteSoundGuard(NSString *state) {
    if (![state isKindOfClass:[NSString class]]) return;
    @try {
        NSString *dir = [NOTIFYBOX_SOUND_GUARD_PATH stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        [state writeToFile:NOTIFYBOX_SOUND_GUARD_PATH
                atomically:YES
                  encoding:NSUTF8StringEncoding
                     error:nil];
    } @catch (__unused NSException *e) { }
}

// 🔴 v0.0.21：换提示音有两条「开关开了但配置不完整」的分支（名单空 / ID 越界）。
//    原来两条都是静默 `return NO;` ⇒ 用户的观感是「我把开关打开了，一切照旧」，
//    必然当成「功能坏了」报回来。这里各留一条痕迹。
// 🔴 **每个进程只打一次**：这个函数每条通知都会走到，不去重就是刷屏 ——
//    而日志窗口只有最后 50 条，刷屏等于没有日志。
// 🔴 用 static BOOL 而不是集合：跨队列调用时最坏情况是多打一条，不会有竞态崩溃。
static void NBWarnSoundMisconfig(BOOL *flag, NSString *msg) {
    if (*flag) return;
    *flag = YES;
    NBSharedLog(@"%@", msg);
}

// ================== v0.0.28：按 App 分配提示音 ==================

static inline NSString *NBTrimText(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    return [(NSString *)s stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

// 从设置里取一份**只含合法条目**的映射（脏数据一律丢掉，绝不让它把功能带崩）。
//
// 合法性口径：
//   · 键 = 非空字符串（bundle id）；
//   · 值 = 字典，且 file / id 至少有一个"看起来能用"（file 是非空字符串 / id 是数字或数字串）。
//   · 两样都没有的条目不合法 —— 🔴 这类条目**不能留**：
//     留着它会让判定以为"这个 App 有分配"，然后拿一个空音去播
//     ⇒ `playCustomSoundForBundle` 返回 YES 却没出声 ⇒ **把系统原声掐掉 = 哑巴**。
//     （这是本项目最贵的一类错：宁可不换音，也绝不哑巴。）
// 🔴 这里**故意不 stat 文件**：那是判定阶段的事，而且必须排在这个 App 到底要不要换音之后。

// v0.0.31：entry 里的 maxSec。**返回 NO = "没有可用值，请跟随全局"**。
//
// 与全局那个 `NBSoundMaxSecFromValue` 的**关键区别**（不是笔误，是刻意的）：
//   · 全局版：非法值 **夹取**成默认值（8 秒）—— 它没有父级可退化，必须给个能用的数；
//   · 本函数：非法值 **拒绝**（返回 NO，调用方退回全局）——
//     它上面已经有全局值了，夹成 8 会把"我全局配了 30 秒"悄悄改成 8，属于静默改语义。
//
// 🔴 严格解析的理由：`[@"abc" doubleValue]` 返回 0，而 0 的语义是「不限」⇒
//    手改文件写错一个字母就变成"长音响到底"，且界面上看不出任何异常。
//    （这个坑全局那个函数里已经踩过一次，注释在 NotifyCommon.h 的 NBSoundMaxSecFromValue。）
static BOOL NBMaxSecFromEntry(NSDictionary *entry, double *out) {
    if (![entry isKindOfClass:[NSDictionary class]]) return NO;
    id v = entry[NB_KEY_SOUND_ENTRY_MAXSEC];
    if (!v) return NO;                       // 键不存在 ⇒ 跟随全局（①）
    double n = 0;
    if ([v isKindOfClass:[NSNumber class]]) {
        n = [(NSNumber *)v doubleValue];
    } else if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!s.length) return NO;
        NSScanner *sc = [NSScanner scannerWithString:s];
        if (![sc scanDouble:&n] || !sc.isAtEnd) return NO;      // "abc" ⇒ 跟随全局，不是"不限"
    } else {
        return NO;
    }
    if (n < 0 || n > NB_SOUND_MAX_SEC_CEIL) return NO;          // 乱填 ⇒ 跟随全局
    if (out) *out = n;                                          // 0 是合法值 = 不限（②）
    return YES;
}

static NSDictionary<NSString *, NSDictionary *> *NBSanitizedSoundMap(id raw) {
    if (![raw isKindOfClass:[NSDictionary class]]) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (id k in (NSDictionary *)raw) {
        if (![k isKindOfClass:[NSString class]] || ![(NSString *)k length]) continue;
        id v = ((NSDictionary *)raw)[k];
        if (![v isKindOfClass:[NSDictionary class]]) continue;
        NSString *f = NBTrimText(((NSDictionary *)v)[NB_KEY_SOUND_ENTRY_FILE]);
        id iv = ((NSDictionary *)v)[NB_KEY_SOUND_ENTRY_ID];
        BOOL hasI = [iv isKindOfClass:[NSNumber class]] ||
                    ([iv isKindOfClass:[NSString class]] && [(NSString *)iv length] > 0);
        if (!f.length && !hasI) continue;
        // v0.0.31：maxSec 非法 ⇒ **只剔掉这个键**，绝不丢整条 entry。
        //   丢整条 ⇒ 用户会觉得"我这个 App 的提示音突然没了"；
        //   剔键   ⇒ 只是"时长回到跟随全局"，退化方向是安全的（音还在）。
        //   而且必须在这里剔：判定之后的 `nbPrefersAudioServicesForDuration:cap:` 会拿它去选通道，
        //   一个乱填的 1e9 会变成 `dispatch_after(1e9 秒)` ⇒ player 永不释放 ⇒
        //   live 攒满 6 ⇒ 后面的音全被挤掉（真机表现为"响几声之后就不响了"）。
        if (((NSDictionary *)v)[NB_KEY_SOUND_ENTRY_MAXSEC] != nil) {
            double probe = 0;
            if (!NBMaxSecFromEntry(v, &probe)) {
                NSMutableDictionary *vv = [NSMutableDictionary dictionaryWithDictionary:v];
                [vv removeObjectForKey:NB_KEY_SOUND_ENTRY_MAXSEC];
                v = vv;
            }
        }
        out[k] = v;
    }
    return out;
}

// entry 一行人话（界面显示用）。只用于显示，**不做判定** ——
// 判定只认 soundVerdictForBundle + playCustomSoundForBundle 那一套。
+ (NSString *)soundEntrySummary:(NSDictionary *)entry {
    if (![entry isKindOfClass:[NSDictionary class]]) return @"未设置";
    NSString *f = NBTrimText(entry[NB_KEY_SOUND_ENTRY_FILE]);
    if (f.length) return f;
    id iv = entry[NB_KEY_SOUND_ENTRY_ID];
    NSInteger sid = 0;
    if ([iv isKindOfClass:[NSNumber class]])      sid = [(NSNumber *)iv integerValue];
    else if ([iv isKindOfClass:[NSString class]]) sid = [(NSString *)iv integerValue];
    if (sid >= 1000 && sid <= 1035) return [NSString stringWithFormat:@"系统音 %ld", (long)sid];
    return @"未设置";
}

// 🔴 增删改的唯一实现。所有界面都调它，不许在页面里自己拼字典 ——
//    "哪里少删了一个键"这种错在界面上看不出来（值在，只是对不上）。
+ (BOOL)setSoundEntry:(NSDictionary *)entry forBundle:(NSString *)bundle {
    @try {
        NSString *key = NBTrimText(bundle);
        if (!key.length) return NO;
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:NBLoadSettings() ?: @{}];
        NSMutableDictionary *map = [NSMutableDictionary dictionaryWithDictionary:
                                    NBSanitizedSoundMap(d[NB_KEY_SOUND_MAP])];
        // 🔴 用"净化后还剩不剩"来判断要不要写：entry 写了 file=@"" 这种空壳，
        //    如果直接 map[key] = entry，就留下一条"有分配但没音"的记录 ⇒ 哑巴风险（见上面注释）。
        if (entry && [NBSanitizedSoundMap(@{key: entry}) count]) map[key] = entry;
        else [map removeObjectForKey:key];                 // entry = nil ⇒ 删除分配
        if (map.count) d[NB_KEY_SOUND_MAP] = map;
        else [d removeObjectForKey:NB_KEY_SOUND_MAP];      // 空就删键，别留空字典（与别处一致）
        return [NotifyStore saveSettings:d];
    } @catch (__unused NSException *e) {
        return NO;
    }
}

+ (NSDictionary<NSString *, NSDictionary *> *)soundMap {
    @try {
        return NBSanitizedSoundMap([self prefs][NB_KEY_SOUND_MAP]);
    } @catch (__unused NSException *e) {
        return @{};
    }
}

// 旧格式 → soundMap 的一次性迁移。**只在 App 启动时调**。
//
// 三个必须做对的地方（每一个错了都会静默）：
//   ① **必须删 soundApps**：否则用户在界面里删掉一个 App，旧回退还会命中它
//      ⇒ "我明明删了，它还在响"（这种鬼最难解释）；
//   ② 默认音拿不到就**不迁移**：造一堆"未设置"的半成品，等于把旧配置废掉但没有新配置；
//   ③ 迁移是**幂等**的：已经有 map 就什么都不做（否则用户改过的分配会被旧名单覆盖）。
+ (BOOL)migrateSoundMapIfNeeded {
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:NBLoadSettings() ?: @{}];
        if (NBSanitizedSoundMap(d[NB_KEY_SOUND_MAP]).count) return NO;      // ③ 已经在新格式上
        NSArray *legacy = [self arrayFromPref:d[NB_KEY_SOUND_APPS]];
        if (!legacy.count) return NO;                                      // 没有旧配置

        // ② 物化一条 entry：文件优先，其次 ID；都没有 ⇒ 放弃迁移（旧回退继续可用）
        NSString *fname = NBTrimText(d[NB_KEY_SOUND_FILE]);
        NSInteger sid = 0;
        id iv = d[NB_KEY_SOUND_ID];
        if ([iv isKindOfClass:[NSNumber class]])      sid = [(NSNumber *)iv integerValue];
        else if ([iv isKindOfClass:[NSString class]]) sid = [(NSString *)iv integerValue];
        NSDictionary *entry = nil;
        if (fname.length) entry = @{NB_KEY_SOUND_ENTRY_FILE: fname};
        else if (sid >= 1000 && sid <= 1035) entry = @{NB_KEY_SOUND_ENTRY_ID: @(sid)};
        if (!entry) return NO;

        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSString *b in legacy) {
            NSString *k = NBTrimText(b);
            if (k.length) map[k] = entry;
        }
        if (!map.count) return NO;
        d[NB_KEY_SOUND_MAP] = map;
        [d removeObjectForKey:NB_KEY_SOUND_APPS];                           // ① 必须删
        BOOL ok = [NotifyStore saveSettings:d];
        NBSharedLog(@"SOUNDMAP 迁移 %lu 个 App（%@）⇒ %@", (unsigned long)map.count,
                    entry[NB_KEY_SOUND_ENTRY_FILE] ? @"文件" : @"系统音 ID",
                    ok ? @"已写盘" : @"写盘失败");
        return ok;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

// 判定口径的唯一实现。见文件顶部的 NBSoundVerdict。
//
// 🔴 v0.0.26 起两个输出（优先级：**文件 > ID**）：
//    · outFile 非空 ⇒ 播这个文件，**完全不看 outSID**（用户选了文件就该听到文件）；
//    · outFile 为 nil ⇒ 才去校验 outSID（1000~1035 系统音区段）。
//    这样"没选文件"的老配置行为一个字节都没变（v0.0.25 已验证通过的那条路）。
//
// 🔴🔴 v0.0.28：**先查「App → 音」映射，查不到才回退旧格式**。
//    "这一次该用哪个音"仍然是**两个来源、一条校验尾巴**：
//      · 来源① = soundMap[bundle]（新格式，每个 App 各自一个音）
//      · 来源② = soundApps 名单 + 全局 soundFile/soundID（v0.0.21~27 的老配置）
//    两个来源都只产出 (fname, sid) 两个值，**后面的净化/冒号/stat/区段校验只有一份**。
//    这样"新格式有校验、旧格式没校验"这种分叉从结构上就不存在。
+ (NBSoundVerdict)soundVerdictForBundle:(NSString *)bundle
                                soundID:(NSInteger *)outSID
                              soundFile:(NSString * _Nullable * _Nullable)outFile
                                 maxSec:(double *)outMaxSec {
    if (outSID) *outSID = 0;
    if (outFile) *outFile = nil;
    @try {
        NSDictionary *p = [self prefs];
        // v0.0.31：先给"跟随全局"的值 —— 后续任何一条路不覆盖它，就等于跟随全局。
        // 🔴 用 p 里已读到的字典算，不再调 nbSoundMaxSec 二次读盘：判定在每条通知上都会跑。
        if (outMaxSec) *outMaxSec = NBSoundMaxSecFromValue(p[NB_KEY_SOUND_MAX_SEC]);
        if (!p.count) return NBSoundVerdictOff;
        if (!NBBoolValue(p[NB_KEY_SOUND_ENABLED])) return NBSoundVerdictOff;

        NSString *key = bundle.length ? bundle : @"";
        NSString *fname = nil;
        NSInteger sid = 0;

        // ---- ① 新格式：这个 App 有没有单独分配的音 ----
        NSDictionary *map = NBSanitizedSoundMap(p[NB_KEY_SOUND_MAP]);
        NSDictionary *entry = map[key];
        BOOL fromMap = (entry != nil);

        if (fromMap) {
            id fv = entry[NB_KEY_SOUND_ENTRY_FILE];
            if ([fv isKindOfClass:[NSString class]]) fname = NBTrimText((NSString *)fv);
            id iv = entry[NB_KEY_SOUND_ENTRY_ID];
            if ([iv isKindOfClass:[NSNumber class]])      sid = [(NSNumber *)iv integerValue];
            else if ([iv isKindOfClass:[NSString class]]) sid = [(NSString *)iv integerValue];
            if (outSID) *outSID = sid;
            // v0.0.31：这个 App 自己的时长（键不存在 / 值非法 ⇒ 保持上面的全局值）
            double entryCap = 0;
            if (outMaxSec && NBMaxSecFromEntry(entry, &entryCap)) *outMaxSec = entryCap;
        } else {
            // ---- ② 旧格式回退：名单 + 全局音 ----
            // 🔴 保留它只为**升级不炸**：用户刚装上这版的那一刻，设置文件还是旧格式，
            //    而 SpringBoard 不会去迁移（通知路径不写盘）⇒ 必须还能读旧格式。
            //    迁移完成后 soundApps 会被删掉，这条路自然失效（不是被关掉的，是没有输入了）。
            NSArray *apps = [self arrayFromPref:p[NB_KEY_SOUND_APPS]];
            if (!apps.count) {
                // 新格式为空、旧名单也为空 ⇒ 用户确实什么都没配（而不是"这个 App 不在名单里"）
                return map.count ? NBSoundVerdictNotListed : NBSoundVerdictEmptyApps;
            }
            if (![apps containsObject:key]) return NBSoundVerdictNotListed;

            id fv = p[NB_KEY_SOUND_FILE];
            if ([fv isKindOfClass:[NSString class]]) fname = NBTrimText((NSString *)fv);
            if (!fname.length) {
                id iv = p[NB_KEY_SOUND_ID];
                if ([iv isKindOfClass:[NSNumber class]])      sid = [(NSNumber *)iv integerValue];
                else if ([iv isKindOfClass:[NSString class]]) sid = [(NSString *)iv integerValue];
                if (outSID) *outSID = sid;
                if (sid < 1000 || sid > 1035) return NBSoundVerdictBadID;
            }
        }

        // ---- ③ 到这里这个 App 确实要换音 ⇒ 才去认真校验文件 ----
        // 🔴 顺序讲究：**先判"这个 App 要不要换音"、再判文件是否存在**。
        //    反过来会给用户一堆"文件不存在"的告警，而那些 App 本来就没分配。
        if (fname.length) {
            // 文件名不合法（含 / 或 ..）不报错，直接当"配置错"处理 ⇒ 放原声。
            NSString *path = NBSoundFilePath(fname);
            if (!path) return NBSoundVerdictBadFile;
            if (!NBIsSoundFileExt(fname)) return NBSoundVerdictBadFile;
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return NBSoundVerdictBadFile;
            if (outFile) *outFile = fname;
            return NBSoundVerdictOK;
        }

        // ---- ④ 只剩 ID 这条路：新格式的 entry 也得过区段校验 ----
        // 🔴 v0.0.28 之前这里只有旧格式会走到（旧格式在上面已经校验过），
        //    新格式的 entry 如果写了 id=0/9999，必须同样拦下来 ——
        //    否则 `playCustomSoundForBundle` 会拿 sid=0 去播"什么都没有"，
        //    然后 return YES 把系统原声掐掉 ⇒ **通知变哑**（v0.0.21 那个症状）。
        if (sid < 1000 || sid > 1035) return NBSoundVerdictBadID;
        return NBSoundVerdictOK;
    } @catch (__unused NSException *e) {
        return NBSoundVerdictOff;
    }
}

// 旧三参版本：诊断（NotifySoundDiag）与 isSoundTargetBundle 还在用。
// 🔴 必须是**转调**而不是复制一份实现 —— 否则口径又变成两份。
+ (NBSoundVerdict)soundVerdictForBundle:(NSString *)bundle
                                soundID:(NSInteger *)outSID
                              soundFile:(NSString * _Nullable * _Nullable)outFile {
    return [self soundVerdictForBundle:bundle soundID:outSID soundFile:outFile maxSec:NULL];
}

// 旧两参版本：诊断（NotifySoundDiag）还在用，保持签名不变。
// 🔴 必须是**转调**而不是复制一份实现 —— 否则口径又变成两份。
+ (NBSoundVerdict)soundVerdictForBundle:(NSString *)bundle soundID:(NSInteger *)outSID {
    return [self soundVerdictForBundle:bundle soundID:outSID soundFile:NULL maxSec:NULL];
}

// 给诊断（NotifySoundDiag）用：这个 App 是不是该换音。
//
// 🔴 v0.0.26 修了一个**只有换文件之后才会暴露**的洞：
//    原来这里调的是两参版本，而两参版本在"选了文件、ID 没填"时会判 BadID ⇒
//    诊断会说"不是目标"，刀却照样换了音。两边口径一岔，下一轮排查就会被自己的日志骗。
//    ⇒ 现在两参版本内部已经转调三参版本（文件优先），所以这里天然一致。
//      留着这行注释是为了记住：**加输出的同时必须检查"所有消费者是否还看同一份判定"**。
+ (BOOL)isSoundTargetBundle:(NSString *)bundle {
    return [self soundVerdictForBundle:bundle soundID:NULL soundFile:NULL] == NBSoundVerdictOK;
}

// ================== v0.0.26：播自定义音频文件 ==================
//
// 两条通道，**按"已验证程度"排序**，不是按"哪个更强"：
//
//   A) AudioServicesCreateSystemSoundID + AudioServicesPlaySystemSound
//      · 播放那一步就是 v0.0.25 真机验证过的那个函数（用户："是我们的提示音"）；
//      · 只吃 caf / wav / aiff 这类（本质是线性 PCM / IMA4），**mp3 会 create 失败**；
//      · 零 session 副作用，天然遵循静音开关、不打断音乐。
//      ⇒ 所以它排第一：能在 A 走通就绝不碰 B。
//
//   B) AVAudioPlayer
//      · 为了 mp3/m4a/aac/flac —— A 吃不下的格式全落在这；
//      · ⚠️ 代价是**必须动 AVAudioSession**。在 SpringBoard 进程里改 session category
//        是全局副作用，所以只设 Ambient + MixWithOthers（最温和的一档：与别的音频混播、
//        不抢焦点），绝不设 Playback（那会把用户正在听的歌掐掉）。
//      ⇒ 只有 A 失败才走这里。
//
// ⚠️ 两条都是"发出请求"而不是"真播出来了"：
//    AudioServicesPlaySystemSound 返回 void；AVAudioPlayer 的 play 返回 BOOL 只代表
//    "开始播了"。假阴性的兜底仍然是设置页「试听」—— App 进程里能响，不代表
//    SpringBoard 里能响（**两个进程**），这一点必须对用户讲清楚。

// A 通道的 SystemSoundID 缓存：绝对路径 → SystemSoundID。
// 🔴 **不 Dispose**：AudioServices 的播放是异步的，create 完立刻 Dispose 会把声音掐断；
//    而"播完再 Dispose"要么得挂回调、要么得猜时长，两条都比"留着"更容易出错。
//    代价是每个用过的文件占一个 SystemSoundID（系统资源里很轻的一项），
//    而用户实际会用到的文件是**个位数** ⇒ 用可控的常驻换掉一整类时序 bug。
static NSMutableDictionary<NSString *, NSNumber *> *NBSidCache(void) {
    static NSMutableDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

// B 通道的"在播"列表：AVAudioPlayer 被释放就等于停止播放，
// 所以必须有人持有到播完（ARC 下这是最容易漏的一步）。
static NSMutableArray<AVAudioPlayer *> *NBLivePlayers(void) {
    static NSMutableArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ a = [NSMutableArray array]; });
    return a;
}

// v0.0.29：「这一声归谁」的关联键。
//   · 通知 ⇒ owner = bundleId（同一个 App 连发时新的停掉旧的）
//   · 试听 ⇒ owner = NB_SOUND_OWNER_PREVIEW（试听之间也互斥，避免连点两次两个一起响）
//   · owner 为空 ⇒ 不做打断（只在内部路径可能出现，保守放行）
static char kNBPlayerOwnerKeyStorage;
static void *kNBPlayerOwnerKey = &kNBPlayerOwnerKeyStorage;

// ---------- v0.0.27：时长上限 ----------
//
// 这一节只回答两个问题：**这个文件有多长**、**这一次该走哪条通道**。
//
// 🔴 为什么需要"选通道"而不是"给 A 加个定时器"：
//    A 通道（AudioServicesPlaySystemSound）**没有 stop API** —— 唯一的
//    `AudioServicesDisposeSystemSoundID` 会把播放一起掐断并释放资源（等于"停一次废一个 ID"）。
//    所以 A 能响多久我们**控制不了**（系统硬上限见 NotifyCommon.h 的 NB_A_CHANNEL_MAX_SEC）。
//    ⇒ 上限只能靠"能不能在时限内播完"来选路：短的走 A，长的走 B。

// 量出来的时长缓存。key 里带文件大小与 mtime ⇒ 用户换掉同名文件后自动失效
// （不失效的后果：把 3 秒的 wav 换成 3 分钟的 wav，仍然按"A 放得完"选路 ⇒ 实际只响 30 秒，
//   而排错时看到的日志全是"选了 A"，跟真因隔着两层）。
static NSMutableDictionary<NSString *, NSNumber *> *NBDurCache(void) {
    static NSMutableDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

// 文件时长（秒）。**负数 = 量不出来**，调用方据此按"未知"处理（未知就不赌 A）。
+ (NSTimeInterval)nbDurationOfFile:(NSString *)path {
    if (!path.length) return -1;

    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    id sz = attr[NSFileSize];
    id mt = attr[NSFileModificationDate];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%.0f", path,
                     [sz isKindOfClass:[NSNumber class]] ? sz : @(-1),
                     [mt isKindOfClass:[NSDate class]] ? [(NSDate *)mt timeIntervalSince1970] : -1.0];

    NSMutableDictionary *cache = NBDurCache();
    @synchronized (cache) {
        NSNumber *c = cache[key];
        if (c) return (NSTimeInterval)[c doubleValue];
    }

    NSTimeInterval dur = -1;
    @try {
        // 🔴 用 AVAudioPlayer 量，**不用 AVURLAsset**：
        //    `AVAsset.duration` 从 iOS 16 起被标记弃用（要求改成异步 load(.duration)），
        //    而 `AVAudioPlayer.duration` 没有弃用；而且它和 B 通道是**同一个解码器** ⇒
        //    "它说多长"就是 B 通道实际会播多长，两者不会打架。
        // 🔴 这里只是建一个 player 读属性：**不 play、不碰 AVAudioSession**
        //    （改 session 是有全局副作用的动作，只允许在真要播的时候做，见 nbPlayViaAVPlayer）。
        NSError *e = nil;
        AVAudioPlayer *pl = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                                  error:&e];
        if (pl) dur = pl.duration;
        pl = nil;                                   // 只为量时长，立刻放掉
    } @catch (__unused NSException *e) { }

    if (dur <= 0 || dur > 3600) dur = -1;           // 量不出来 / 明显不可信 ⇒ 未知

    @synchronized (cache) { cache[key] = @(dur); }
    return dur;
}

// 读"最长播放秒数"。**0 = 不限**；键缺失 = 默认 8 秒（解读口径只有 NBSoundMaxSecFromValue 一份）。
+ (NSTimeInterval)nbSoundMaxSec {
    id v = nil;
    @try {
        NSDictionary *p = [self prefs];
        if ([p isKindOfClass:[NSDictionary class]]) v = p[NB_KEY_SOUND_MAX_SEC];
    } @catch (__unused NSException *e) { }
    return NBSoundMaxSecFromValue(v);
}

// **选路逻辑只写在这一处**（播放和界面提示都调它，否则"界面上说的"和"实际做的"会走岔）。
// YES = 先试 A（v0.0.25 已验证的那条通道）；NO = 先走 B（只有它能截断）。
+ (BOOL)nbPrefersAudioServicesForDuration:(NSTimeInterval)dur cap:(NSTimeInterval)cap {
    // ① 比 A 的系统上限还长 ⇒ A 放不全，别选它。
    if (dur > 0 && dur > NB_A_CHANNEL_MAX_SEC) return NO;
    // ② 开了上限、但不保证能播完（时长未知 或 超上限）⇒ 只有 B 能截断。
    if (cap > 0 && (dur < 0 || dur > cap)) return NO;
    return YES;
}

+ (BOOL)nbPlayViaAudioServices:(NSString *)path why:(NSString **)why {
    NSMutableDictionary *cache = NBSidCache();
    SystemSoundID sid = 0;
    @synchronized (cache) {
        NSNumber *c = cache[path];
        if (c) sid = (SystemSoundID)[c unsignedIntValue];
    }
    if (sid == 0) {
        CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:path];
        OSStatus st = AudioServicesCreateSystemSoundID(url, &sid);
        if (st != kAudioServicesNoError || sid == 0) {
            if (why) *why = [NSString stringWithFormat:@"create=%d", (int)st];
            return NO;
        }
        @synchronized (cache) {
            cache[path] = @((unsigned int)sid);
        }
    }
    AudioServicesPlaySystemSound(sid);
    return YES;
}

+ (BOOL)nbPlayViaAVPlayer:(NSString *)path
                   maxSec:(NSTimeInterval)maxSec
                    owner:(NSString *)owner
                      why:(NSString **)why {
    NSError *err = nil;
    AVAudioPlayer *pl = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                              error:&err];
    if (!pl) {
        if (why) *why = err.localizedDescription ?: @"init 失败";
        return NO;
    }

    // 🔴 只在真的要用 B 的时候才动 session。Ambient + MixWithOthers = 与别的音频共存。
    //    设置失败也继续播：宁可"可能打断音乐"，也不要"用户配了提示音却听不到"。
    @try {
        AVAudioSession *ses = [AVAudioSession sharedInstance];
        [ses setCategory:AVAudioSessionCategoryAmbient
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:NULL];
        [ses setActive:YES error:NULL];
    } @catch (__unused NSException *e) { }

    pl.volume = 1.0f;
    [pl prepareToPlay];
    if (![pl play]) {
        if (why) *why = @"play 返回 NO";
        return NO;
    }

    // 🔴🔴 v0.0.29：**同一个 owner 的旧音在这里被停掉** —— 修的就是"群里连发三条，
    //    三个提示音同时响成一团"。
    //
    // 三条设计约束，每条都不是随便定的：
    //
    // ① **必须排 `play` 成功之后**。反过来的话，一旦 `play` 返回 NO，
    //    用户既听不到新的、旧的也被掐掉了 ⇒ **哑一下**。先保住"至少有一个在响"。
    //
    // ② **按 owner 分桶，不是全局只留一个**。微信和 QQ 同时来通知是两件事，
    //    两个音都该听到；只有"同一个 App 连发"才是噪音。
    //
    // ③ **只对 B 通道有效** —— A 通道没有 stop API（`AudioServicesDisposeSystemSoundID`
    //    会连播放一起掐断并释放资源，等于"停一次废一个 ID"），所以 A 通道的旧音停不了。
    //    但这恰好不构成问题：**短音走 A、长音走 B**，只有长音叠加才难听，
    //    而长音正好是能停的那条。能力落在唯一需要它的地方。
    NSMutableArray *live = NBLivePlayers();
    NSUInteger killed = 0;
    @synchronized (live) {
        if (owner.length) {
            // owner 挂在 player 上（associated object）而不是另开字典：
            // player 被释放时它跟着走，不存在"字典里留着已死 player"这种漏。
            objc_setAssociatedObject(pl, kNBPlayerOwnerKey, owner, OBJC_ASSOCIATION_COPY_NONATOMIC);
            // 倒着遍历：一边删一边遍历，正着走会跳元素
            for (NSInteger i = (NSInteger)live.count - 1; i >= 0; i--) {
                AVAudioPlayer *old = live[(NSUInteger)i];
                NSString *ob = objc_getAssociatedObject(old, kNBPlayerOwnerKey);
                if (![ob isEqualToString:owner]) continue;
                @try { [old stop]; } @catch (__unused NSException *e) { }
                [live removeObjectAtIndex:(NSUInteger)i];
                killed++;
            }
        }
        // 🔴 上限 6 保留作兜底：连环通知（比如群里刷屏）时不能无上限地攒 player。
        //    v0.0.29 之后正常路径不会走到这里（同 owner 已经互斥），
        //    只有"多个不同 App 同时刷"才会触发。
        while (live.count >= 6) {
            AVAudioPlayer *old = live.firstObject;
            @try { [old stop]; } @catch (__unused NSException *e) { }
            [live removeObjectAtIndex:0];
        }
        [live addObject:pl];
    }
    // 🔴 只在真的打断了才留痕：这条在刷屏时每条通知都会触发，无条件打会把 50 行日志窗口冲干净
    //    （v0.0.22 白跑一轮的同一个病）。不带 bundleId，省字数。
    if (killed) NBSharedLog(@"SOUND# 同 App 连发 ⇒ 停掉 %lu 个旧音（不叠加）", (unsigned long)killed);

    // 到点收工。duration 不可信时给个短兜底，绝不能出现"永久持有"。
    //
    // 🔴 v0.0.27：只有"文件本来就更长"（或时长量不出来、上限又开着）才 `stop`。
    //    本来就比上限短的**必须让它自然播完** —— `stop` 会削掉尾音，
    //    听感上就是"这提示音怎么断在半截"，用户只会怀疑是插件坏了。
    NSTimeInterval dur = pl.duration;
    BOOL known = (dur > 0 && dur <= 3600);
    BOOL needStop = (maxSec > 0) && (!known || dur > maxSec);
    NSTimeInterval after = needStop ? maxSec : (known ? dur + 0.5 : 3.0);
    if (after < 0.05) after = 0.05;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (needStop) {
            @try { [pl stop]; } @catch (__unused NSException *e) { }
        }
        @synchronized (live) { [live removeObject:pl]; }
        // 🔴 v0.0.30：交还音频会话**必须排在从 live 摘掉之后**。
        //    反过来的话，此刻 `live` 里还留着自己这一个 ⇒ 交还函数会以为"还有人在响"，
        //    于是白调一次；更糟的是如果哪天判据改成"live 非空才不交还"的宽松版，
        //    顺序一反就会在自己还在响的时候交还 ⇒ 声音断在半截。
        //    收紧到"摘掉之后再问"，两种写法都安全。
        [NotifyFilter releaseAudioSessionIfIdle];
    });
    return YES;
}

// v0.0.30：音频会话交还。**保守放行**：只要还有任何东西可能在响，就不交还。
//
// 两个条件必须同时满足：
//   ① B 通道在播列表为空（A 通道走 AudioServices，不占我们的会话，所以不用管它）
//   ② 朗读没在播 —— 朗读自己从不碰 AVAudioSession，靠 AVSpeechSynthesizer 内部激活；
//      我们要是在它说话时 `setActive:NO`，**会把那句掐断**。
//
// 🔴 为什么用 NSClassFromString 问而不是直接发消息：见文件顶部 NBSpeakerProbe 的注释 ——
//    本文件同时编进盒子 App，而 App 目标没有链接 NotifySpeaker.m。
//    在 App 里 `NSClassFromString` 返回 nil ⇒ 条件②自然放行，正是我们要的行为。
//
// 🔴 为什么交还要带 NotifyOthersOnDeactivation：不带的话，"被我们压低过的别人的音乐"
//    不会自己恢复音量（尤其 App 内试听那条 Playback+DuckOthers）。带了才是"交还"，不带只是"放开"。
+ (void)releaseAudioSessionIfIdle {
    @try {
        // ① B 通道还有 player 在响 ⇒ 绝不交还
        NSMutableArray *live = NBLivePlayers();
        @synchronized (live) {
            if (live.count) return;
        }

        // ② 朗读在播 ⇒ 绝不交还
        Class spk = NSClassFromString(@"NotifySpeaker");
        if (spk && [spk respondsToSelector:@selector(isSpeakingNow)]) {
            if ([spk isSpeakingNow]) return;
        }

        AVAudioSession *ses = [AVAudioSession sharedInstance];
        if (!ses) return;
        [ses setActive:NO
           withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                 error:NULL];
    } @catch (__unused NSException *e) {
        // 交还失败不影响任何功能：下一次播放还会重新 setActive:YES。
        // 这一路故意不留日志 —— 它可能在每条通知收尾时都跑一次，打日志会冲掉 50 行窗口。
    }
}

// 公开入口（盒子 App 的「试听」直接调它；tweak 侧由 playCustomSoundForBundle 调）。
//
// 🔴 这个函数**不做判定**（不管开关、不管名单）——
//    它只管"把这一份文件播出去"。判定在 soundVerdictForBundle 里，唯一口径。
//    分开的好处：试听可以无视名单（用户就是想先听听是不是这个音）。
+ (BOOL)playSoundFileNamed:(NSString *)name forResult:(NSString **)result {
    // 🔴 v0.0.29：公开入口一律按「试听」的身份播。
    //    为什么不在签名上加 owner 参数：这个函数**已经被三处界面在用**
    //    （设置页试听 / 选音页试听 / 选音页选完试播），改签名等于三处一起动，
    //    而它们本来就都该是"试听"这个语义 ⇒ 默认值就写在转调这一行，一处都说清。
    //    ⚠️ 通知路径**不许**调这个函数（那会让所有 App 共用一个 owner，又变回全局只留一个音）。
    // 🔴 v0.0.31：cap 传 -1 = 跟随全局。试听是"预览这一份文件"，用全局的上限最符合直觉；
    //    真要按某个 App 的时长试听，那是选音页的事（它有自己的预览文案）。
    return [self nbPlaySoundFile:name forOwner:NB_SOUND_OWNER_PREVIEW cap:-1 result:result];
}

// 内部真正干活的入口。owner 决定"跟谁互斥"，其余逻辑与 v0.0.27 完全一致。
+ (BOOL)nbPlaySoundFile:(NSString *)name
               forOwner:(NSString *)owner
                    cap:(double)cap
                 result:(NSString **)result {
    if (result) *result = nil;
    @try {
        NSString *path = NBSoundFilePath(name);
        if (!path) {
            if (result) *result = @"文件名不合法（含 / 或 .. 或以 . 开头）";
            return NO;
        }
        if (!NBIsSoundFileExt(name)) {
            if (result) *result = [NSString stringWithFormat:@"扩展名不认识（.%@）",
                                   [name pathExtension] ?: @"?"];
            return NO;
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            if (result) *result = @"文件不存在";
            return NO;
        }

        // ---- v0.0.27：按"能不能在时限内播完"选通道 ----
        // 上限 0 = 不限 ⇒ 仍然走 A（已验证通道，零 session 副作用）。
        // v0.0.31：cap 负数 = 调用方没指定 ⇒ 用全局。**必须在这里兜底而不是在调用方**，
        //          否则"哪些调用点兜了、哪些没兜"会散在几个文件里。
        NSTimeInterval useCap = (cap < 0) ? [self nbSoundMaxSec] : (NSTimeInterval)cap;
        NSTimeInterval dur = [self nbDurationOfFile:path];          // 负数 = 量不出来
        BOOL aFirst = [self nbPrefersAudioServicesForDuration:dur cap:useCap];

        NSString *whyA = nil;
        NSString *whyB = nil;
        BOOL okA = NO;
        BOOL okB = NO;
        // 🔴 两条通道**互为兜底**：先走的那条失败就试另一条。
        //    代价是 A 不遵守上限（它没有 stop），但那只发生在"B 也播不出来"的双失败路径上 ——
        //    那时响得久一点，远好过哑巴。这个取舍要写进 README，不能只在代码里。
        if (aFirst) {
            okA = [self nbPlayViaAudioServices:path why:&whyA];
            if (!okA) okB = [self nbPlayViaAVPlayer:path maxSec:useCap owner:owner why:&whyB];
        } else {
            okB = [self nbPlayViaAVPlayer:path maxSec:useCap owner:owner why:&whyB];
            if (!okB) okA = [self nbPlayViaAudioServices:path why:&whyA];
        }
        if (okA || okB) {
            if (result) {
                // dur=-1.0 表示"时长没量出来"（不是播了 -1 秒）；cap=0.0 表示不限。
                *result = [NSString stringWithFormat:@"自播 file=%@ ch=%@ dur=%.1f cap=%.1f",
                           name, okA ? @"A" : @"B", dur, useCap];
            }
            return YES;
        }
        // 两条都失败 ⇒ 一定要把两条的原因都带出去，否则下一轮只能猜。
        if (result) *result = [NSString stringWithFormat:@"播不了 file=%@（A:%@ / B:%@）",
                               name, whyA ?: @"?", whyB ?: @"?"];
        return NO;
    } @catch (NSException *e) {
        if (result) *result = [NSString stringWithFormat:@"throw:%@", e.name ?: @"?"];
        return NO;
    }
}

// v0.0.27：给界面用的"这个文件会怎么播"（时长 + 走哪条通道 + 会不会被截断）。
// **只用于显示，不做判定** —— 判定仍然只在 soundVerdictForBundle 里。
// 🔴 放在引擎里而不是界面里：这样"界面写的"和"实际做的"用**同一份选路逻辑**。
//    两份必走岔，而走岔的症状（界面说会截断、实际没截断）几乎没法自证。
//
// v0.0.31：拆成两层。cap < 0 = 跟随全局。
// 🔴 为什么必须拆：v0.0.31 之后"同一个文件"在不同 App 下会有**不同上限**，
//    界面若还只读全局，就会在"给微信配了 30 秒"时显示「8 秒后停」——
//    正是上面那条注释警告的走岔。所以多一个 forBundle: 版本去问判定要最终 cap。
+ (NSString *)nbPlaybackPlanForFile:(NSString *)name cap:(double)cap {
    @try {
        NSString *path = NBSoundFilePath(name);
        if (!path) return @"文件名不合法";
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return @"文件不在";

        NSTimeInterval dur = [self nbDurationOfFile:path];
        NSTimeInterval useCap = (cap < 0) ? [self nbSoundMaxSec] : (NSTimeInterval)cap;
        BOOL aFirst = [self nbPrefersAudioServicesForDuration:dur cap:useCap];
        NSString *durText = (dur < 0) ? @"时长未知" : [NSString stringWithFormat:@"%.1f 秒", dur];

        NSString *how = @"走 A";
        if (!aFirst) {
            if (useCap > 0 && (dur < 0 || dur > useCap)) {
                how = [NSString stringWithFormat:@"走 B，%.0f 秒后停", useCap];
            } else {
                how = [NSString stringWithFormat:@"走 B（超 %.0f 秒，A 放不全）", NB_A_CHANNEL_MAX_SEC];
            }
        }
        return [NSString stringWithFormat:@"%@ · %@", durText, how];
    } @catch (NSException *e) {
        return @"?";
    }
}

+ (NSString *)playbackPlanForFileNamed:(NSString *)name {
    return [self nbPlaybackPlanForFile:name cap:-1];      // -1 = 跟随全局
}

// v0.0.31：给某个 App 配的这个文件会怎么播（用这个 App 自己的时长）。
+ (NSString *)playbackPlanForFileNamed:(NSString *)name forBundle:(NSString *)bundle {
    // 🔴 cap 从判定里取，不自己读设置 —— "界面"和"刀"必须是同一份计算。
    //    判定在"功能没开 / 不在名单"时会提前 return，但 outMaxSec 在最前面就填好了全局值，
    //    所以这里永远拿到一个可用值（-1 只在判定抛异常时出现）。
    double cap = -1;
    [self soundVerdictForBundle:bundle soundID:NULL soundFile:NULL maxSec:&cap];
    return [self nbPlaybackPlanForFile:name cap:(cap < 0 ? -1 : cap)];
}

// v0.0.31：entry 的「最长播放秒数」一行人话（界面显示用，**不做判定**）。
+ (NSString *)soundEntryLimitSummary:(NSDictionary *)entry {
    double v = 0;
    if (!NBMaxSecFromEntry(entry, &v)) return @"跟随全局";
    if (v <= 0) return @"不限时长";
    return [NSString stringWithFormat:@"%.0f 秒后停", v];
}

// ---------- v0.0.25：换提示音的**新刀** ----------
//
// 🔴🔴 这一版的全部价值：**换挂点**。
//    旧刀（v0.0.21~v0.0.24 的 applySoundForBundle）是「alloc 一个 BBSound、填字段、
//    setValue:forKey:@"sound"」，实测**造错就整条通知变哑**，而且 BBSound 上连 bundle id
//    都没有。现在改由 Tweak.x 的 GSC 组挂在
//    `SBNCSoundController -canPlaySoundForNotificationRequest:`（返回 BOOL 的总闸门）上。
//    本函数只负责两件事：判定（走 soundVerdictForBundle）＋ 把声音送出去。
//
// 为什么用 AudioServices 而不是 AVAudioPlayer / TLAlert：
//   · `AudioServicesPlaySystemSound` 播的就是 1000~1035 这段系统提示音，
//     正好等于用户在设置页里选的那个 ID ⇒ **试听和通知走同一条路**，
//     所以「试听能响」就能推出「通知也能响」。
//     这正是 v0.0.21 那个矛盾的解药：当时试听走 AudioServices、通知走 BulletinBoard，
//     两条路根本不是一回事，我却拿试听的结果去推断通知。
//   · 它**自动遵循静音开关**，不需要碰 AVAudioSession
//     （在 SpringBoard 里改 session category 有全局副作用，能不动就不动）。
//   · 它不打断正在播的音乐 —— 这是系统提示音的固有行为。
//
// ⚠️ 诚实的局限：`AudioServicesPlaySystemSound` 返回 void，**拿不到「真播出来了」**。
//   所以这里返回 YES 只表示「ID 合法 + 播放请求已发出」。
//   假阴性（发了请求但没声音）的唯一兜底是设置页那个「试听」按钮 ——
//   两者同一条路，试听能响，通知就能响。这条依赖关系写在这里，别以后忘了。
+ (BOOL)playCustomSoundForBundle:(NSString *)bundle forResult:(NSString **)result {
    if (result) *result = nil;
    @try {
        NSInteger sid = 0;
        NSString *srcFile = nil;
        // v0.0.31：cap 由判定一起给出（entry 有就用 entry 的，否则全局），
        // 🔴 这里**不许**再自己读一次 nbSoundMaxSec：兜底逻辑两份迟早走岔，
        //    症状是"界面说 30 秒停、实际 8 秒就停"，而两边看着都对。
        double cap = -1;
        NBSoundVerdict verdict = [self soundVerdictForBundle:bundle soundID:&sid
                                                    soundFile:&srcFile maxSec:&cap];

        // 两种「不适用」静默返回：开关没开 / 这个 App 不在名单。
        // 这是绝大多数通知的结局 —— 每条都留痕会把约 50 行的日志窗口冲干净（v0.0.22 白跑一轮的同一个病）。
        if (verdict == NBSoundVerdictOff || verdict == NBSoundVerdictNotListed) return NO;

        if (verdict == NBSoundVerdictBadID) {
            static BOOL onceBadID = NO;
            NBWarnSoundMisconfig(&onceBadID, @"!!! 换提示音的 ID 不在 1000~1035"
                                             @"（当前值取不到或越界）⇒ 不生效，通知按原声播放");
            if (result) *result = @"ID 越界 ⇒ 放原声";
            return NO;
        }
        if (verdict == NBSoundVerdictEmptyApps) {
            static BOOL onceEmpty = NO;
            NBWarnSoundMisconfig(&onceEmpty, @"!!! 换提示音开着但 App 名单是空的"
                                             @" ⇒ 不生效（故意的：实验功能不许全量改掉整机通知音）");
            if (result) *result = @"名单空 ⇒ 放原声";
            return NO;
        }
        if (verdict == NBSoundVerdictBadFile) {
            // v0.0.26。这条必须留痕：用户"明明把文件放进去了"却听不到原声以外的任何东西，
            // 而原因（名字带 /、扩展名不认识、路径不对）在界面上看不出来。
            static BOOL onceBadFile = NO;
            NBWarnSoundMisconfig(&onceBadFile,
                                 @"!!! 换提示音选的文件不可用（文件名含 / 或 ..、扩展名不认识、"
                                 @"或者文件不在 /var/mobile/Library/NotifyBox/Sounds/）"
                                 @"⇒ 不生效，通知按原声播放");
            if (result) *result = @"文件不可用 ⇒ 放原声";
            return NO;
        }

        // 到这里 verdict == OK：这个 App 确实要换音。
        // 🔴 先把声音送出去，再返回 YES —— 调用方拿到 YES 才会去掐系统原声。
        //    顺序写反（先掐再播）就是「播失败 ⇒ 哑巴」，见 NotifyFilter.h 里那段返回契约。
        // 🔴 v0.0.26：**文件优先**。选了文件就只播文件，不播 ID（否则会同时响两个声音）。
        // 🔴🔴 v0.0.29：这里**必须**走内部入口并把 bundleId 当 owner 传下去，
        //    ⛔ 不能图省事调公开的 playSoundFileNamed:（它写死了 owner=@preview）——
        //    那样所有 App 会共用同一个 owner，一个 App 来通知就会掐掉另一个 App 正在响的音，
        //    而症状（"QQ 把我微信的提示音停了"）几乎没法从日志看出来。
        if (srcFile.length) {
            NSString *d = nil;
            BOOL ok = [self nbPlaySoundFile:srcFile forOwner:bundle cap:cap result:&d];
            if (result) *result = d;
            return ok;              // 播不出去 ⇒ NO ⇒ 调用方放原声（绝不哑巴）
        }
        AudioServicesPlaySystemSound((SystemSoundID)sid);
        if (result) *result = [NSString stringWithFormat:@"自播 sid=%ld 已发出", (long)sid];
        return YES;
    } @catch (NSException *e) {
        // 任何异常都退回原声：宁可「没换成」，也绝不能让用户漏消息。
        if (result) *result = [NSString stringWithFormat:@"throw:%@ ⇒ 放原声", e.name ?: @"?"];
        return NO;
    }
}

+ (BOOL)recoverFromSoundCrashIfNeeded {
    @try {
        NSString *s = [NSString stringWithContentsOfFile:NOTIFYBOX_SOUND_GUARD_PATH
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![s isEqualToString:kNBGuardStart]) return NO;

        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:NBLoadSettings()];
        [d setObject:@(NO) forKey:NB_KEY_SOUND_ENABLED];
        // 直接写文件，不另立一个 helper：tweak 侧只能自己写这个路径（见 NotifyCommon.h）。
        // 🔴 也避免"类方法定义在调用点之后、头文件又没声明" ⇒ -Werror 直接挂。
        BOOL wrote = [d writeToFile:NOTIFYBOX_SETTINGS_PATH atomically:YES];
        NBWriteSoundGuard(@"crash-closed");

        // 🔴 回读：v0.0.18 那句"已自动删除 delaySeconds"就是没回读才成了假话。
        NSDictionary *back = NBLoadSettings();
        BOOL off = !NBBoolValue(back[NB_KEY_SOUND_ENABLED]);
        if (wrote && off) {
            NBSharedLog(@"!!! 换提示音自毁保护触发：上次崩在这里，已关闭 soundEnabled（回读确认=关）");
        } else {
            NBSharedLog(@"!!! 换提示音自毁保护触发，但**没关掉**（write=%d 回读值=%@）"
                        @"⇒ 请手动去设置页关掉，否则可能再崩一次",
                        (int)wrote, back[NB_KEY_SOUND_ENABLED] ?: @"(无)");
        }
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

// 写设置的统一出口：tweak 侧只能自己写这个文件（路径与单一写入者的理由见 NotifyCommon.h）。
// 🔴 不单独做成方法：类方法若定义在调用点之后、头文件又没声明，-Werror 会直接挂。

@end
