#import "NotifyFilter.h"
#import "NotifyCommon.h"
#import <objc/runtime.h>       // v0.0.16 起为探针引入；v0.0.19 删掉延迟后本文件已不用 objc_* 函数，
                              // 但保留这个 import 无害，且省得下次要加探针时又忘

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

+ (BOOL)applySoundForBundle:(NSString *)bundle
                 toBulletin:(id)bulletin
                  forResult:(NSString **)result {
    if (result) *result = nil;
    if (!bulletin) return NO;

    @try {
        NSDictionary *p = [self prefs];
        if (!p.count) return NO;
        if (!NBBoolValue(p[NB_KEY_SOUND_ENABLED])) return NO;

        NSInteger sid = 0;
        id v = p[NB_KEY_SOUND_ID];
        if ([v isKindOfClass:[NSNumber class]])      sid = [(NSNumber *)v integerValue];
        else if ([v isKindOfClass:[NSString class]]) sid = [(NSString *)v integerValue];
        // 只接受系统提示音区段。填错就什么都不做 —— 造一个 id=0 的 BBSound 只会让它变哑。
        if (sid < 1000 || sid > 1035) return NO;

        // 🔴 与 speakApps/dndApps 语义**相反**：这里空名单 = 不生效。
        //    实验功能默认绝不能"全部 App 都改"，那等于一次性把整台手机的通知声音变掉。
        NSArray *apps = [self arrayFromPref:p[NB_KEY_SOUND_APPS]];
        if (!apps.count) return NO;
        if (![apps containsObject:(bundle.length ? bundle : @"")]) return NO;

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

        BOOL setType = NO, setID = NO;
        if ([snd respondsToSelector:NSSelectorFromString(@"setSoundType:")]) {
            [snd setValue:@(1) forKey:@"soundType"];     // 1 = Alert（按可写字段名推的，见上面注释）
            setType = YES;
        }
        if ([snd respondsToSelector:NSSelectorFromString(@"setSystemSoundID:")]) {
            [snd setValue:@((int)sid) forKey:@"systemSoundID"];
            setID = YES;
        }
        if (!setType && !setID) {
            NBWriteSoundGuard(kNBGuardDone);
            if (result) *result = @"BBSound 上没有可写的 soundType/systemSoundID";
            return YES;
        }

        [bulletin setValue:snd forKey:@"sound"];

        // 🔴 回读验证：分不清"我改了"和"改上了"是这类功能最常见的假象。
        NSString *cls = @"nil";
        @try {
            id back = [bulletin valueForKey:@"sound"];
            if (!back) {
                NBWriteSoundGuard(kNBGuardDone);
                if (result) *result = [NSString stringWithFormat:
                                       @"写完回读是 nil（id=%ld，setType=%d setID=%d）",
                                       (long)sid, (int)setType, (int)setID];
                return YES;
            }
            cls = NSStringFromClass([back class]);
        } @catch (__unused NSException *e) {
            cls = @"回读抛异常";
        }

        NBWriteSoundGuard(kNBGuardDone);
        if (result) {
            *result = [NSString stringWithFormat:@"id=%ld 已挂上 cls=%@ setType=%d setID=%d",
                       (long)sid, cls, (int)setType, (int)setID];
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
