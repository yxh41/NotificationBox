#import "NotifyProbe.h"
#import "NotifyCommon.h"
#import <objc/runtime.h>

// 探针实现。设计口径：**一次说清楚，而不是每条都刷**。
//
// 🔴 日志窗口 ≈ 最后 50 条，且是全局滚动 —— 探针刷 30 行就等于把
//    紧接着要看的 DROP#/REPL#/SPEAK 全挤出去了。
//    所以：类结构只 dump 一次（约 4~6 行），实例只量前 3 条（每条 1 行）。

static int gProbed = 0;
static BOOL gDumped = NO;

// 这些名字一旦出现，就是"换提示音"要用的量
static BOOL NBIsSoundRelated(NSString *name) {
    NSString *low = [name lowercaseString];
    return ([low containsString:@"sound"] || [low containsString:@"alert"]
            || [low containsString:@"vibrat"] || [low containsString:@"interrupt"]
            || [low containsString:@"priority"] || [low containsString:@"importance"]);
}

static NSString *NBClassNameOf(id obj) {
    if (!obj) return @"nil";
    @try {
        return NSStringFromClass([obj class]);
    } @catch (__unused NSException *e) {
        return @"?";
    }
}

// dump 一个类的 property：总数一行 + 名字全列表一行 + 声音相关（带类型编码）一行
static void NBDumpProps(Class c, NSString *label) {
    if (!c) {
        NBSharedLog(@"PROBE %@ 类不存在", label);
        return;
    }
    unsigned int cnt = 0;
    objc_property_t *ps = class_copyPropertyList(c, &cnt);
    NBSharedLog(@"PROBE %@ 有 %u 个 property", label, cnt);
    if (!ps) return;

    NSMutableArray *all = [NSMutableArray array];
    NSMutableArray *key = [NSMutableArray array];
    for (unsigned i = 0; i < cnt; i++) {
        const char *n = property_getName(ps[i]);
        const char *a = property_getAttributes(ps[i]);
        // 🔴 不能写 @(n)：那是把 char* 装箱成 NSValue（指针），不是 NSString。
        NSString *name = n ? [NSString stringWithUTF8String:n] : @"?";
        NSString *attr = a ? [NSString stringWithUTF8String:a] : @"";
        [all addObject:name];
        // 🔴 类型编码是这里的核心产出：T@"BBSound" 表示是个对象，
        //    TQ 表示 unsigned long long，Tc/TB 表示标量/BOOL。
        //    下一版要判"能不能改"，看的就是这一位 —— 猜没用。
        if (NBIsSoundRelated(name)) {
            [key addObject:[NSString stringWithFormat:@"%@{%@}", name, attr]];
        }
    }
    free(ps);

    NBSharedLog(@"PROBE %@ 名字: %@", label, [all componentsJoinedByString:@","]);
    if (key.count) {
        NBSharedLog(@"PROBE %@ 声音相关(%lu): %@", label,
                    (unsigned long)key.count, [key componentsJoinedByString:@" "]);
    } else {
        NBSharedLog(@"PROBE %@ 声音相关: 无（说明名字猜错了，得看上面的名字表）", label);
    }
}

// dump 一个类的**类方法**（元类上就是类方法）。用来看能不能凭空造声音对象。
static void NBDumpClassMethods(Class c, NSString *label) {
    if (!c) return;
    Class meta = object_getClass(c);
    if (!meta) return;
    unsigned int cnt = 0;
    Method *ms = class_copyMethodList(meta, &cnt);
    NSMutableArray *hits = [NSMutableArray array];
    if (ms) {
        for (unsigned i = 0; i < cnt; i++) {
            NSString *n = NSStringFromSelector(method_getName(ms[i]));
            NSString *low = [n lowercaseString];
            if ([low containsString:@"sound"] || [low containsString:@"alert"]
                || [low containsString:@"system"] || [low containsString:@"default"]) {
                [hits addObject:n];
            }
        }
        free(ms);
    }
    NBSharedLog(@"PROBE %@ 类方法共 %u 个，其中相关 %lu 个: %@", label, cnt,
                (unsigned long)hits.count,
                hits.count ? [hits componentsJoinedByString:@" , "] : @"无");
}

@implementation NotifyProbe

+ (void)dumpClassesOnce {
    if (gDumped) return;

    // 🔴🔴 必须容忍「现在是 %ctor，BulletinBoard 还没加载」这种情况。
    //    v0.0.3 已经踩过一次同类坑：constructor 阶段对 BBServer 调
    //    class_getInstanceMethod 返回 NULL，而同一时刻 class_copyMethodList 却正常。
    //    这里如果 objc_getClass("BBBulletin") 拿到 nil 就把 gDumped 置真，
    //    探针会永久失效 —— 而且日志里只会留一句「类不存在」，
    //    下一条通知来的时候明明能拿到，却再也不试了。白跑一整轮。
    //    ⇒ 找不到就**不置位**，留给第一条通知来的时候重试。
    if (!objc_getClass("BBBulletin")) {
        // 🔴 日志文案里出现 "%ctor" 必须写成 "%%ctor"：
        //    NBSharedLog 带 NS_FORMAT_FUNCTION 标注，编译器会把 %c 当成 char 转换符，
        //    然后报 "more '%' conversions than data arguments" —— -Werror 直接挂。
        //    （ObjC 字符串字面量里 % 本身不需要转义，只有**格式串语义**要求写成 %%）
        //    任何裸 % 在格式串里都是雷，写 % 一律双写。
        NBSharedLog(@"PROBE 现在拿不到 BBBulletin（大概率是 %%ctor 阶段框架还没加载），等第一条通知再试");
        return;
    }
    gDumped = YES;

    @try {
        NBSharedLog(@"=== PROBE 开始 dump 类结构（只读，一次性）===");
        NBDumpProps(objc_getClass("BBBulletin"), @"BBBulletin");
        NBDumpProps(objc_getClass("BBBulletinRequest"), @"BBBulletinRequest");
        NBDumpProps(objc_getClass("BBSound"), @"BBSound");
        NBDumpClassMethods(objc_getClass("BBSound"), @"BBSound");
        NBDumpClassMethods(objc_getClass("BBBulletin"), @"BBBulletin");
        NBSharedLog(@"=== PROBE dump 结束 ===");
    } @catch (__unused NSException *e) {
        NBSharedLog(@"!!! PROBE dump 抛异常（已忽略）");
    }
}

+ (void)probeBulletin:(id)obj tag:(NSString *)tag {
    if (!obj) return;
    // 兜底重试：%ctor 那次可能因为框架没加载而没 dump 成
    if (!gDumped) [self dumpClassesOnce];
    if (gProbed >= 3) return;          // 只量前 3 条，别挤爆日志窗口
    gProbed++;
    int idx = gProbed;

    @try {
        // 🔴 每个键**单独 @try**：KVC 读一个不存在的键会抛 NSUndefinedKeyException。
        //    整段共用一个 @try 的话，第一个抛错的键会带走后面所有键的值
        //    ⇒ 看到 "sound 之后什么都没有"，会误判成"这些量不存在"，
        //       而真相只是"第一个键名写错了"。这类误判白烧过一整轮。
        NSArray *keys = @[@"sound", @"playSound", @"alertType", @"importance",
                          @"priority", @"bulletinID", @"sectionID", @"hasSound"];
        NSMutableArray *cells = [NSMutableArray array];
        for (NSString *k in keys) {
            NSString *cell = nil;
            @try {
                id v = [obj valueForKey:k];
                if (!v) {
                    cell = [NSString stringWithFormat:@"%@=nil", k];
                } else if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) {
                    cell = [NSString stringWithFormat:@"%@=%@", k, v];
                } else {
                    // 是对象但内容不可读 ⇒ 只报类名（真正的信息在这里：
                    // sound 若是 BBSound，下一版就得去造 BBSound）
                    cell = [NSString stringWithFormat:@"%@=<%@>", k, NBClassNameOf(v)];
                }
            } @catch (__unused NSException *e) {
                cell = [NSString stringWithFormat:@"%@=THROW", k];
            }
            [cells addObject:cell];
        }
        NBSharedLog(@"PROBE#%d tag=%@ cls=%@ :: %@", idx, tag ?: @"?",
                    NBClassNameOf(obj), [cells componentsJoinedByString:@" "]);
    } @catch (__unused NSException *e) {
        NBSharedLog(@"!!! PROBE#%d 抛异常（已忽略）", idx);
    }
}

+ (void)dumpServerQueueOnce {
    static BOOL done = NO;
    if (done) return;
    // 同 dumpClassesOnce 的教训：%ctor 阶段 BulletinBoard 可能还没加载，
    // 拿不到类就**不置位**，留给第一次 hook 命中时重试。
    Class c = objc_getClass("BBServer");
    if (!c) return;
    done = YES;

    @try {
        unsigned int cnt = 0;
        objc_property_t *ps = class_copyPropertyList(c, &cnt);
        NSMutableArray *hits = [NSMutableArray array];
        if (ps) {
            for (unsigned i = 0; i < cnt; i++) {
                const char *n = property_getName(ps[i]);
                if (!n) continue;
                NSString *name = [NSString stringWithUTF8String:n];
                NSString *low = [name lowercaseString];
                if ([low containsString:@"queue"] || [low containsString:@"serial"]
                    || [low containsString:@"dispatch"] || [low containsString:@"thread"]) {
                    [hits addObject:name];
                }
            }
            free(ps);
        }
        NBSharedLog(@"PROBE BBServer property 共 %u 个，队列相关 %lu 个: %@", cnt,
                    (unsigned long)hits.count,
                    hits.count ? [hits componentsJoinedByString:@","] : @"无");
    } @catch (__unused NSException *e) {
        NBSharedLog(@"!!! PROBE BBServer property dump 抛异常（已忽略）");
    }

    // 我们自己此刻在哪个队列上 —— 这决定了"延迟后还能不能回到这个队列"。
    // dispatch_queue_get_label 是线程安全的只读 API，不会阻塞。
    @try {
        const char *label = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
        NBSharedLog(@"PROBE 当前队列标签 = %s", label ? label : "?");
    } @catch (__unused NSException *e) { }
}

+ (int)probedCount {
    return gProbed;
}

@end
