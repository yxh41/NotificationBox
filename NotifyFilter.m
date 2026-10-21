#import "NotifyFilter.h"
#import "NotifyCommon.h"

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

+ (BOOL)shouldDelayBundle:(NSString *)bundle seconds:(NSTimeInterval *)seconds {
    if (seconds) *seconds = 0;
    @try {
        NSDictionary *p = [self prefs];
        if (!p.count) return NO;                       // 没有任何设置 ⇒ 绝不改变任何行为

        // 秒数：NSNumber 或 "5" 两种都认（手改 plist 的人常写成字符串）
        double sec = 0;
        id v = p[NB_KEY_DELAY_SECONDS];
        if ([v isKindOfClass:[NSNumber class]])        sec = [(NSNumber *)v doubleValue];
        else if ([v isKindOfClass:[NSString class]])   sec = [(NSString *)v doubleValue];
        if (!(sec >= 1.0)) return NO;                  // 0 / 负数 / 非数字 ⇒ 关闭
        // 🔴 夹上限：填 86400 等于让通知永远不出现。用户不会知道自己填错了，
        //    只会觉得"开了延迟之后通知全没了"。
        if (sec > 600.0) sec = 600.0;

        NSArray<NSString *> *apps = [self arrayFromPref:p[NB_KEY_DELAY_APPS]];
        if (apps.count && ![apps containsObject:(bundle.length ? bundle : @"")]) return NO;

        if (seconds) *seconds = sec;
        return YES;
    } @catch (__unused NSException *e) {
        return NO;      // 判错就不延迟：宁可准时到，也不要莫名其妙迟到
    }
}

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
