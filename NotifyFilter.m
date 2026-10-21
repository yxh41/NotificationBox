#import "NotifyFilter.h"
#import "NotifyCommon.h"
#import <objc/runtime.h>       // v0.0.16：probeTimeFieldsOfBulletin 要用 class_copyPropertyList

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

    // 🔴🔴🔴 v0.0.15：延迟推送**暂停接线**。这里直接返回 NO —— 这是本轮唯一的出口，
    //   三个 hook 的延迟分支都靠它把关 ⇒ 就算 settings.plist 里还留着 delaySeconds，
    //   也不会有任何一条通知被攒进 block。
    //
    //   停用原因（真机实测，2026-10-21 15:51:27）：SpringBoard 崩在
    //     EXC_BREAKPOINT (SIGTRAP)，系统报 "The Swift runtime trapped:
    //     fatalError / failed precondition / force-unwrapped nil /
    //     array index out of range" ⇒ 进安全模式。
    //
    //   🔴🔴🔴 2026-10-21 16:10 拿到 .ips 后的定论 ——
    //     不是"上面某一条候选因成立"，而是「**延迟调用原方法**」这一类做法**整体走不通**。
    //
    //   故障线程栈（真实 .ips，主线程 com.apple.main-thread）：
    //      0  libdispatch   _dispatch_assert_queue_fail         + 120
    //      1  libdispatch   dispatch_assert_queue                + 196
    //      2  BulletinBoard -[BBServer dataProviderForSectionID:] + 44  ← 方法开头就断言
    //      3  <dylib>       0x7858
    //      4  <dylib>       0xc0f0
    //      5  <dylib>       0x49f8   ← GCD 定时器 fire 出来的 block
    //      6  libdispatch   _dispatch_client_callout
    //      8  libdispatch   _dispatch_source_invoke
    //      9  libdispatch   _dispatch_main_queue_drain          ← 主队列
    //
    //   ⇒ 病因 = **队列前置条件**。BBServer 的方法在动手前会
    //     dispatch_assert_queue(<BB 私有串行队列>)，而那个队列句柄只活在 BBServer 内部，
    //     外面拿不到。把原方法搬到 dispatch_get_main_queue() 上执行 ⇒ 断言落空 ⇒ SIGTRAP。
    //   ⇒ 最贵的推论：**换队列也没救**。主队列不对，自己开串行队列更不对，
    //     唯一正确的那个队列我们拿不到 ⇒ 不要再试图"把原方法塞进某个 dispatch_after"。
    //   ⇒ 正确方向：**不延迟调用，只把通知的发布时间往后写** ——
    //     照常在**同一线程、同一次调用**里执行原方法，只把 bulletin 上的时间字段
    //     （date / publicationDate 之类，具体名字待 PROBE 探针确认）改成 now+N，
    //     让**系统自己**在 N 秒后弹。纯数据修改：不跨队列、不持有对象、不重复发布。
    //   ⇒ 顺带记一笔：这份 .ips 的故障栈里 **NotifyBox.dylib 一帧都没有**
    //     （168 个镜像、全部线程全扫），发起方是另一个插件 NotificationFilter.dylib。
    //     但"这份日志不是我" ≠ "我的代码没问题" —— 上面那条队列断言说明我的延迟分支
    //     一旦真跑起来会死在同一处。停用的决定与"谁发的"无关。
    //
    //   🔴 v0.0.16：**重新启用**，但执行方式整个换掉了（见 applyDelayToBulletin:seconds:）。
    //     本函数现在只回答"要不要延迟"，不再回答"怎么延迟" —— 判定逻辑从来没崩过，
    //     崩的一直是执行方式（跨队列调原方法）。
    //     保留这个常量作为**紧急停用开关**：真出问题改一个字就能整条关掉。
    static const BOOL kDelayEnabled = YES;
    if (!kDelayEnabled) return NO;

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

// ---------- v0.0.16：延迟的新执行方式（改时间字段，不延迟调用） ----------

// 哪些字段"像发布时间"。顺序 = 猜测的可信度降序。
// 🔴 故意**不含** expirationDate 之外任何语义不明的字段：改错字段的代价是
//    "通知永远不出现"，比"没延迟"坏得多。
static NSArray<NSString *> *NBTimeKeys(void) {
    return @[@"date", @"publicationDate", @"publishDate", @"timestamp", @"expirationDate"];
}

// "date" → "setDate:"。⚠️ 首字母必须大写，否则 respondsToSelector 一律 NO。
static NSString *NBSetterNameFor(NSString *key) {
    if (!key.length) return nil;
    return [NSString stringWithFormat:@"set%@%@:",
            [[key substringToIndex:1] uppercaseString],
            [key substringFromIndex:1]];
}

// 🔴🔴 v0.0.16 幂等标记：同一条通知会命中 2~3 个入口（PB / PBR / PBRS）。
//    这是本项目的常识（日志里同一条通知往往有 PB + PBR 两行），但它在这里的后果是
//    **延迟时间被乘了几倍**：每个入口都平移一次时间 ⇒ 填 5 秒实际会晚 10~15 秒，
//    而用户完全看不出为什么（他会以为"延迟不准"，而不是"被推了三次"）。
//    v0.0.14 的旧实现也有同一个问题（3 个定时器），当时列在候选因②里 —— 现在确认成立。
//
//    解：用**关联对象**打标记。选它的理由：
//      ① 跟着对象生命周期走 —— 对象没了标记自动没，不会泄漏；
//      ② 不需要额外的锁或全局表（这张表还要考虑线程安全，而 BB 的方法不一定在主线程）；
//      ③ 不需要 weak 引用容器（NSHashTable 那种要自己管清理）。
static const void *NBDelayMarkKey = &NBDelayMarkKey;

// 返回：非空 = 真正改了哪些字段（幂等：同一对象只生效一次）
//       空串  = 这一条**已经推过了**，本次跳过（不是失败，调用方照常执行原方法）
//       nil   = 一个时间字段都没找到（也是安全失败）
+ (NSString *)applyDelayToBulletin:(id)bulletin seconds:(NSTimeInterval)seconds {
    if (!bulletin || !(seconds > 0)) return nil;

    // 🔴 幂等闸门必须排在**所有写入之前**。
    if (objc_getAssociatedObject(bulletin, NBDelayMarkKey)) return @"";

    NSMutableArray<NSString *> *done = [NSMutableArray array];

    // 🔴 每个键**单独 @try**。理由同 NotifyProbe：KVC 碰到不存在的键会抛
    //    NSUndefinedKeyException，共用一个 @try 的话第一个抛错会带走后面所有键
    //    ⇒ 明明 date 能改，却因为前面的键名猜错而整个放弃。这类误判已经烧过一整轮。
    for (NSString *key in NBTimeKeys()) {
        @try {
            NSString *setterName = NBSetterNameFor(key);
            if (!setterName) continue;
            // ① 没有 setter ⇒ 这个字段是 readonly，跳过（硬写就是抛异常 = 崩）
            if (![bulletin respondsToSelector:NSSelectorFromString(setterName)]) continue;
            // ② 没有 getter 就无法确认类型 ⇒ 跳过（不冒险写一个不知道类型的键）
            if (![bulletin respondsToSelector:NSSelectorFromString(key)]) continue;

            id cur = [bulletin valueForKey:key];
            // ③ 当前值不是 NSDate ⇒ 这个字段不是时间（可能是数字时间戳或别的），跳过。
            //    这一条把"改错字段"挡在门外：类型对不上就绝不动手。
            if (![cur isKindOfClass:[NSDate class]]) continue;

            NSDate *moved = [(NSDate *)cur dateByAddingTimeInterval:seconds];
            [bulletin setValue:moved forKey:key];
            [done addObject:key];
        } @catch (__unused NSException *e) {
            // 单个键失败不影响其它键，也不影响调用方（它会照常立即执行原方法）
        }
    }

    // 🔴 只有真的改成功才打标记；一个字段都没改成 ⇒ 不打标记（让后面的入口再试一次，
    //    它们传进来的对象可能已经不是同一个包装类了）。
    if (done.count) {
        objc_setAssociatedObject(bulletin, NBDelayMarkKey, @(seconds),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return [done componentsJoinedByString:@"+"];
    }
    return nil;
}

+ (NSString *)probeTimeFieldsOfBulletin:(id)bulletin {
    if (!bulletin) return nil;
    @try {
        Class c = [bulletin class];
        unsigned int cnt = 0;
        objc_property_t *ps = class_copyPropertyList(c, &cnt);
        if (!ps) return [NSString stringWithFormat:@"%@ 没有 property 列表", NSStringFromClass(c)];

        NSMutableArray<NSString *> *hits = [NSMutableArray array];
        for (unsigned i = 0; i < cnt; i++) {
            const char *n = property_getName(ps[i]);
            const char *a = property_getAttributes(ps[i]);
            if (!n) continue;
            NSString *name = [NSString stringWithUTF8String:n];
            NSString *attr = a ? [NSString stringWithUTF8String:a] : @"";
            NSString *low = [name lowercaseString];
            if (!([low containsString:@"date"] || [low containsString:@"time"])) continue;

            // 类型编码放在名字后面：T@"NSDate" 才能写，Td/Tq 是标量（写不了对象）
            NSString *cell = [NSString stringWithFormat:@"%@{%@}", name, attr];
            @try {
                id v = [bulletin valueForKey:name];
                if ([v isKindOfClass:[NSDate class]]) {
                    cell = [cell stringByAppendingFormat:@"=NSDate(%.0f)", [(NSDate *)v timeIntervalSince1970]];
                } else if (!v) {
                    cell = [cell stringByAppendingString:@"=nil"];
                } else {
                    cell = [cell stringByAppendingFormat:@"=<%@>", NSStringFromClass([v class])];
                }
            } @catch (__unused NSException *e) {
                cell = [cell stringByAppendingString:@"=THROW"];
            }
            [hits addObject:cell];
        }
        free(ps);

        if (!hits.count) {
            return [NSString stringWithFormat:@"%@ 里没有名字含 date/time 的属性", NSStringFromClass(c)];
        }
        return [hits componentsJoinedByString:@" "];
    } @catch (__unused NSException *e) {
        return @"探针自己抛异常了（已忽略）";
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
