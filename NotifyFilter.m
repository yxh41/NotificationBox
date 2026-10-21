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

@end
