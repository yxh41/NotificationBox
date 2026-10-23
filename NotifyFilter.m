#import "NotifyFilter.h"
#import "NotifyCommon.h"
// 🔴 v0.0.23：造完 BBSound 之后要把它的字段实值打出来（落盘）。
//    NotifyFilter.m **也被盒子 App 编译**，所以 NotifySoundDiag.m 必须一起进 App 的 FILES，
//    否则链接期就是 undefined symbol（这种错看着像代码问题，其实是构建配置）。
#import "NotifySoundDiag.h"
#import <objc/runtime.h>       // v0.0.16 起为探针引入；v0.0.19 删掉延迟后本文件已不用 objc_* 函数，
                              // 但保留这个 import 无害，且省得下次要加探针时又忘

// 🔴 v0.0.22：换提示音「该不该生效」的判定**只写这一处**。
//    刀（applySoundForBundle）和诊断（isSoundTargetBundle）都调它。
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

// 🔴 v0.0.22：把 BBSound 上几个关键字段的**当前值**写成一小段文本，塞进 SOUND# 行。
//
// 为什么非要这个：我们造完对象、填了两个字段，但从外面**看不到值到底进去了没有**。
// 写进去但被 setter 忽略（比如 setSoundType: 存在但语义不是我想的那个）时，
// 现象和"完全没写"一模一样 ⇒ 上一轮就是这样卡住的。
// 把 src / tone / type / sid 四个值直接打在留痕里，一次就能分清
// 「没填进去」和「填进去了但不生效」——这两条路的修法完全不同。
//
// 🔴 每个字段**单独 @try**：一个字段抛异常不能带走其余的，
//    否则"没读到"会被误判成"没这个字段"。
// 🔴 键名用短名（src/tone/type/sid）：单条日志有 200 字硬上限，
//    这一行本身还要带 bundle 和 tag。
static NSString *NBSoundFieldSummary(id snd) {
    if (!snd) return @"snd=nil";
    // 🔴🔴 v0.0.24：字段名改对了，而且**换了一批**。
    //    v0.0.23 追的是 rep(=repetitions，根本不存在) / dur(=maxDuration)，
    //    真机数据证明这两个跟出不出声无关（能响的样本也是 0/0）。
    //    现在真正要看的是：type / sid / alertCfg / tone / song / ringtone ——
    //    其中 `alertCfg` 是唯一还没被排除的差异（能响的有值，我们的空壳是 nil）。
    //    短名控制在 7 字符以内：单个字段一行，日志有 200 字上限。
    NSArray *pairs = @[@[@"type", @"soundType"], @[@"sid", @"systemSoundID"],
                       @[@"repeat", @"repeats"], @[@"maxDur", @"maxDuration"],
                       @[@"tone", @"toneIdentifier"], @[@"song", @"songPath"],
                       @[@"ring", @"ringtoneName"], @[@"alertCfg", @"alertConfiguration"]];
    NSMutableString *m = [NSMutableString string];
    for (NSArray *pair in pairs) {
        NSString *shortName = pair[0];
        NSString *key = pair[1];
        NSString *val = @"!";
        @try {
            id v = [snd valueForKey:key];
            if (!v) val = @"nil";
            else if ([v isKindOfClass:[NSNumber class]]) val = [(NSNumber *)v stringValue];
            else if ([v isKindOfClass:[NSString class]]) val = (NSString *)v;
            else val = NSStringFromClass([v class]);
        } @catch (__unused NSException *e) {
            val = @"!抛";
        }
        [m appendFormat:@"%@=%@ ", shortName, val];
    }
    return m;
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

+ (BOOL)applySoundForBundle:(NSString *)bundle
                 toBulletin:(id)bulletin
                  forResult:(NSString **)result {
    if (result) *result = nil;
    if (!bulletin) return NO;

    @try {
        // 🔴 判定走唯一实现（见 soundVerdictForBundle）。这里只负责"按原因给说法"。
        NSInteger sid = 0;
        NBSoundVerdict verdict = [self soundVerdictForBundle:bundle soundID:&sid];
        if (verdict == NBSoundVerdictOff || verdict == NBSoundVerdictNotListed) return NO;
        if (verdict == NBSoundVerdictBadID) {
            static BOOL onceBadID = NO;
            NBWarnSoundMisconfig(&onceBadID, @"!!! 换提示音的 ID 不在 1000~1035"
                                             @"（当前值取不到或越界）⇒ 不生效，通知按原声播放");
            return NO;
        }
        if (verdict == NBSoundVerdictEmptyApps) {
            static BOOL onceEmpty = NO;
            NBWarnSoundMisconfig(&onceEmpty, @"!!! 换提示音开着但 App 名单是空的"
                                             @" ⇒ 不生效（故意的：实验功能不许全量改掉整机通知音）");
            return NO;
        }

        if (![bulletin respondsToSelector:@selector(setSound:)]) {
            if (result) *result = @"这个对象没有 setSound:（不是 bulletin？）";
            return YES;
        }

        Class c = NSClassFromString(@"BBSound");
        if (!c) {
            if (result) *result = @"拿不到 BBSound 类";
            return YES;
        }

        // 崩溃自愈：动手前写 start，做完写 done。**两件事在同一个函数里配对**，
        // 这是 v0.0.15 那个教训的直接修正（那版只写不读 ⇒ 永久假警报）。
        NBWriteSoundGuard(kNBGuardStart);

        id snd = [[c alloc] init];
        if (!snd) {
            NBWriteSoundGuard(kNBGuardDone);
            if (result) *result = @"BBSound alloc 失败";
            return YES;
        }
        // 🔴 v0.0.23 起：**设之前**先记一次默认值，设完再记一次（见下面「设后」）。
        //    v0.0.24 备注：这两条一对比，能分清"值真的写进去了"和"setter 收下了但没存"。
        //    注意它只证明"写没写进去"，**不能**证明"会不会响" ——
        //    v0.0.23 就是拿这批字段当病因，结果被真机数据否掉了。
        [NBSoundDiag probeCreatedSound:snd stage:@"设前"];

        BOOL setType = NO, setID = NO, setRep = NO, setDur = NO;
        if ([snd respondsToSelector:NSSelectorFromString(@"setSoundType:")]) {
            [snd setValue:@(1) forKey:@"soundType"];     // 1 = Alert（按可写字段名推的，见上面注释）
            setType = YES;
        }
        if ([snd respondsToSelector:NSSelectorFromString(@"setSystemSoundID:")]) {
            [snd setValue:@((int)sid) forKey:@"systemSoundID"];
            setID = YES;
        }

        // 🔴🔴 v0.0.23 补过这两个字段，**v0.0.24 把键名和结论都改了**。
        //
        // ⚠️ 先摆事实：v0.0.23 的推断被真机数据**正面否掉了**。
        //    v0.0.23 说 `repetitions` / `maxDuration` 是 0 ⇒ 播 0 次 / 0 秒 ⇒ 一声不出。
        //    真机上系统自己给的、**能正常出声**的那个 BBSound：
        //        maxDuration=0  repeats=0  soundType=2  systemSoundID=0
        //        alertConfiguration=<TLAlertConfiguration>
        //    ⇒ 0/0 是**正常**的，跟出不出声没关系。
        //    而且 `repetitions` 这个键根本不存在（真机 `rep=!无键`）——
        //    正确的是 `repeats`（{TB,N,GisRepeating,V_repeats}，BOOL，"要不要重复"）。
        //    病根：我照着上一版的 PROBE 截图**凭印象转写**了一个意思相近的名字。
        //
        //    所以这两个字段现在**只写不看**：写它们是为了让 SD#/SOUND# 行能对照，
        //    **不再当闸门**。别再拿它们判"能不能响"。
        if ([snd respondsToSelector:NSSelectorFromString(@"setRepeats:")]) {
            [snd setValue:@(NO) forKey:@"repeats"];   // 与真机能响的样本一致（repeats=0）
            setRep = YES;
        }
        if ([snd respondsToSelector:NSSelectorFromString(@"setMaxDuration:")]) {
            [snd setValue:@(30) forKey:@"maxDuration"];
            setDur = YES;
        }

        if (!setType && !setID) {
            NBWriteSoundGuard(kNBGuardDone);
            if (result) *result = @"BBSound 上没有可写的 soundType/systemSoundID";
            return YES;
        }

        // 🔴🔴🔴 v0.0.24：本版**故意不挂**。闸门 = 这个对象上有没有 `alertConfiguration`。
        //
        // 为什么是这一项：
        //   把真机两份数据摊开对比，唯一还没被排除的差异就是它 ——
        //      能正常响的： soundType=2  systemSoundID=0  alertConfiguration=<非 nil>
        //      我们的空壳： soundType=1  systemSoundID=1009 alertConfiguration=nil
        //   iOS 16 的通知音走 **TonesLibrary（TLAlert + TLAlertConfiguration）**，
        //   `systemSoundID` 是 AudioServices 的老 ID，BulletinBoard 已经不看它了。
        //   （这也解释了设置页"试听"为什么是响的：试听走 AudioServices 播放，
        //     和系统投递通知是两条完全不同的路 —— 试听能响≠通知能响。）
        //
        // 为什么宁可不换也不能挂：
        //   v0.0.21 已经实测过 —— 挂一个空壳，通知变成**完全没声音**，
        //   用户会漏消息。而"没换成"只是功能没生效。两者量级差得远。
        //
        // 🔴 闸门刻意写成"这一项必须有值"，而不是"v0.0.24 先关掉"：
        //    这样下一版**一旦会造 alertConfiguration，这条闸门自动打开**，
        //    不用再回来改一行 if —— 少一处"改了忘了开"的机会。
        id alertCfg = nil;
        @try {
            alertCfg = [snd valueForKey:@"alertConfiguration"];
        } @catch (__unused NSException *e) {
            alertCfg = nil;
        }
        if (!alertCfg) {
            NBWriteSoundGuard(kNBGuardDone);
            if (result) *result = [NSString stringWithFormat:
                                   @"!!! 本版不挂（侦察轮）：alertConfiguration 造不出来"
                                   @" ⇒ iOS 16 靠 TonesLibrary 出声，空壳挂上必然静音。%@",
                                   NBSoundFieldSummary(snd)];
            return YES;
        }
        // 🔴 v0.0.23：**设之后**再记一次。和上面那条一对比就知道：
        //    值是"从 0 变成 1/30"（真的写进去了）还是"压根没动"（setter 吞了）。
        [NBSoundDiag probeCreatedSound:snd stage:@"设后"];

        [bulletin setValue:snd forKey:@"sound"];

        // 🔴 回读验证：分不清"我改了"和"改上了"是这类功能最常见的假象。
        NSString *cls = @"nil";
        @try {
            id back = [bulletin valueForKey:@"sound"];
            if (!back) {
                NBWriteSoundGuard(kNBGuardDone);
                if (result) *result = [NSString stringWithFormat:
                                       @"写完回读是 nil（id=%ld，setType=%d setID=%d rep=%d dur=%d）",
                                       (long)sid, (int)setType, (int)setID,
                                       (int)setRep, (int)setDur];
                return YES;
            }
            cls = NSStringFromClass([back class]);
        } @catch (__unused NSException *e) {
            cls = @"回读抛异常";
        }

        NBWriteSoundGuard(kNBGuardDone);
        if (result) {
            // 🔴 v0.0.22：附带 snd 的字段实值 —— 见 NBSoundFieldSummary 上面那段说明。
            //    v0.0.23 起再加 rep/dur 两个标志位。
            // 🔴 `set=` 后面保留 `/` 分隔：用户上一版截图里就是 `set=1/1`，
            //    连写成 `set=%d%d` 会变成 `set=11` —— 能读但一眼看不出是两个字段（别为了省一个字符牺牲可读性）。
            *result = [NSString stringWithFormat:
                       @"id=%ld 已挂上 cls=%@ set=%d/%d rep=%d dur=%d %@",
                       (long)sid, cls, (int)setType, (int)setID,
                       (int)setRep, (int)setDur, NBSoundFieldSummary(snd)];
        }
        return YES;
    } @catch (NSException *e) {
        NBWriteSoundGuard(kNBGuardDone);     // 抛异常也要收尾，否则下次启动误判成崩溃
        if (result) *result = [NSString stringWithFormat:@"throw:%@", e.name ?: @"?"];
        return YES;      // 已经试过了，得留痕
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
