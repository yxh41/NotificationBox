#import "NotifyFilter.h"
#import "NotifyCommon.h"
#import <AudioToolbox/AudioToolbox.h>   // v0.0.25：AudioServicesPlaySystemSound（换提示音改成「自己播」）
// 🔴 v0.0.23：造完 BBSound 之后要把它的字段实值打出来（落盘）。
//    NotifyFilter.m **也被盒子 App 编译**，所以 NotifySoundDiag.m 必须一起进 App 的 FILES，
//    否则链接期就是 undefined symbol（这种错看着像代码问题，其实是构建配置）。
#import "NotifySoundDiag.h"
#import <objc/runtime.h>       // v0.0.16 起为探针引入；v0.0.19 删掉延迟后本文件已不用 objc_* 函数，
                              // 但保留这个 import 无害，且省得下次要加探针时又忘

// 🔴 v0.0.22：换提示音「该不该生效」的判定**只写这一处**。
//    刀（v0.0.25 起是 playCustomSoundForBundle）和诊断（isSoundTargetBundle）都调它。
//    理由见本文件顶部那一版说明：两处各写一份，一旦走岔就是
//    "诊断说该生效、刀说不该生效"，而刀往往才是对的 —— 那一轮直接白跑。
typedef NS_ENUM(NSInteger, NBSoundVerdict) {
    NBSoundVerdictOK = 0,      // 该生效
    NBSoundVerdictOff,         // 功能没开 / 设置读不到 / 读的时候抛异常
    NBSoundVerdictBadID,       // ID 不在 1000~1035
    NBSoundVerdictEmptyApps,   // App 名单为空（语义与其它名单相反：空 = 不生效）
    NBSoundVerdictNotListed,   // 这个 App 不在名单里
};

@interface NotifyFilter ()
// outSID 可为 NULL。任何异常都返回 NBSoundVerdictOff ——
// 这个功能的失效方式必须是"什么都不做"，绝不能影响通知本身。
+ (NBSoundVerdict)soundVerdictForBundle:(nullable NSString *)bundle soundID:(NSInteger *)outSID;
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

// 判定口径的唯一实现。见文件顶部的 NBSoundVerdict。
+ (NBSoundVerdict)soundVerdictForBundle:(NSString *)bundle soundID:(NSInteger *)outSID {
    if (outSID) *outSID = 0;
    @try {
        NSDictionary *p = [self prefs];
        if (!p.count) return NBSoundVerdictOff;
        if (!NBBoolValue(p[NB_KEY_SOUND_ENABLED])) return NBSoundVerdictOff;

        NSInteger sid = 0;
        id v = p[NB_KEY_SOUND_ID];
        if ([v isKindOfClass:[NSNumber class]])      sid = [(NSNumber *)v integerValue];
        else if ([v isKindOfClass:[NSString class]]) sid = [(NSString *)v integerValue];
        if (outSID) *outSID = sid;
        // 只接受系统提示音区段。填错就什么都不做 —— 造一个 id=0 的 BBSound 只会让它变哑。
        if (sid < 1000 || sid > 1035) return NBSoundVerdictBadID;

        // 🔴 与 speakApps/dndApps 语义**相反**：这里空名单 = 不生效。
        //    实验功能默认绝不能"全部 App 都改"，那等于一次性把整台手机的通知声音变掉。
        NSArray *apps = [self arrayFromPref:p[NB_KEY_SOUND_APPS]];
        if (!apps.count) return NBSoundVerdictEmptyApps;
        if (![apps containsObject:(bundle.length ? bundle : @"")]) return NBSoundVerdictNotListed;
        return NBSoundVerdictOK;
    } @catch (__unused NSException *e) {
        return NBSoundVerdictOff;
    }
}

// 给诊断（NotifySoundDiag）用：这个 App 是不是该换音。
+ (BOOL)isSoundTargetBundle:(NSString *)bundle {
    return [self soundVerdictForBundle:bundle soundID:NULL] == NBSoundVerdictOK;
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
        NBSoundVerdict verdict = [self soundVerdictForBundle:bundle soundID:&sid];

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

        // 到这里 verdict == OK：ID 合法且这个 App 在名单里。
        // 🔴 先把声音送出去，再返回 YES —— 调用方拿到 YES 才会去掐系统原声。
        //    顺序写反（先掐再播）就是「播失败 ⇒ 哑巴」，见 NotifyFilter.h 里那段返回契约。
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
