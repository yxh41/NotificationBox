#import "NotifySoundDiag.h"
#import "NotifyCommon.h"
#import "NotifyFilter.h"
#import <objc/runtime.h>

// ============ v0.0.22：换提示音「听不到」的只读诊断 ============
//
// 上一版（v0.0.21）按真机 PROBE 数据走了「自己 alloc 一个 BBSound 挂到 bulletin 上」
// 这条路，真机结果是**回读成功、但听不到**。
// 这把问题锁到两个可能上，而它们的修法完全相反：
//   ① 值填错了 / 填不进（BBSound 上根本没有 setSoundType: 这类 setter，
//      或者真正决定播放的字段叫 toneIdentifier / soundSource，我们压根没填）；
//   ② 填对了但系统不采纳（系统在发布链路上重算 sound，把我们的对象换掉）。
// 这一轮不出新刀，只把这两条一起量掉 —— 一轮定生死，别再猜。
//
// 🔴 日志纪律（本项目已经因为"观测把留痕挤掉"白跑过好几轮）：
//    · 单条 200 字上限 ⇒ 攒到约 110 字就发一条，宁可多几行也别被截断；
//    · 一次性（static BOOL）⇒ 类结构只打一次，别按通知条数刷屏；
//    · **只对目标 App 输出**（开关开 + 名单里有它 + ID 合法），否则每条通知都打，
//      真正有用的 DROP#/REPL# 全被挤掉；
//    · 前缀统一 `SD#`，并且**必须同时加进 App 的结论行关键词表** ——
//      "加了新留痕却忘了能被捞出来"这个病在 v0.0.17 / v0.0.20 已经犯过两次。

static BOOL gClsDone = NO;
static BOOL gClsMissLogged = NO;
static BOOL gForeignDone = NO;

#define NB_DIAG_FLUSH_AT 110

// 这些名字一旦出现，就是"换提示音"相关的量。
// 🔴 比 NotifyProbe 那份过滤器更宽：多收 tone / source / system。
//    因为真正决定播放的字段很可能**不叫 sound**（iOS 13+ 的声音走 toneIdentifier）。
static BOOL NBDiagWanted(NSString *name) {
    NSString *low = [name lowercaseString];
    return ([low containsString:@"sound"] || [low containsString:@"alert"]
            || [low containsString:@"tone"] || [low containsString:@"vibrat"]
            || [low containsString:@"source"] || [low containsString:@"system"]);
}

// 🔴 判"能不能改"的第一道门，判错了后面全白干。
//    不能用 [attr containsString:@"R"] —— 类型名里就可能有大写 R（CGRect / NSError）。
//    必须按逗号切成段，再判**整段等于 "R"**。
static BOOL NBDiagPropIsReadonly(NSString *attr) {
    NSArray *parts = [attr componentsSeparatedByString:@","];
    return [parts containsObject:@"R"];
}

static NSString *NBDiagShortAttr(NSString *attr) {
    return attr.length > 34 ? [[attr substringToIndex:34] stringByAppendingString:@"…"] : attr;
}

// 🔴 每个字段**单独 @try**，而不是把整条表达式包一个 @try。
//    一个字段抛异常不能带走其余字段 —— 否则"没读到"会被误判成"没跑到"，白跑一轮。
static NSString *NBDiagGet(id obj, NSString *key) {
    if (!obj) return @"-";
    @try {
        id v = [obj valueForKey:key];
        if (!v) return @"nil";
        if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
        if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
        // 对象只打类名：description 可能很长，也可能自己抛异常
        return [NSString stringWithFormat:@"<%@>", NSStringFromClass([v class])];
    } @catch (__unused NSException *e) {
        return @"!抛";
    }
}

// dump 一个类的属性表。onlyInteresting=YES 时只打声音相关的
// （BBBulletin 有 68 个属性，全打会把日志窗口吃光）。
static void NBDiagDumpProps(Class c, NSString *label, BOOL onlyInteresting) {
    if (!c) {
        NBSharedLog(@"SD# %@ 类不存在", label);
        return;
    }
    unsigned int cnt = 0;
    objc_property_t *ps = class_copyPropertyList(c, &cnt);
    if (!ps) {
        NBSharedLog(@"SD# %@ 属性表拿不到", label);
        return;
    }
    NBSharedLog(@"SD# %@ 有 %u 个属性（[W]=可写 [R]=只读）", label, cnt);
    NSMutableString *buf = [NSMutableString string];
    for (unsigned i = 0; i < cnt; i++) {
        const char *n = property_getName(ps[i]);
        const char *a = property_getAttributes(ps[i]);
        if (!n) continue;
        NSString *name = [NSString stringWithUTF8String:n];
        NSString *attr = a ? [NSString stringWithUTF8String:a] : @"";
        if (onlyInteresting && !NBDiagWanted(name)) continue;
        [buf appendFormat:@"%@%@{%@} ",
                          name, NBDiagPropIsReadonly(attr) ? @"[R]" : @"[W]", NBDiagShortAttr(attr)];
        if (buf.length >= NB_DIAG_FLUSH_AT) {
            NBSharedLog(@"SD# %@: %@", label, buf);
            [buf setString:@""];
        }
    }
    free(ps);
    if (buf.length) NBSharedLog(@"SD# %@: %@", label, buf);
}

// dump 一个类的声音相关 setter —— "能不能填进去"的直接答案。
static void NBDiagDumpSetters(Class c, NSString *label) {
    if (!c) return;
    unsigned int cnt = 0;
    Method *ms = class_copyMethodList(c, &cnt);
    if (!ms) return;
    NSMutableString *buf = [NSMutableString string];
    for (unsigned i = 0; i < cnt; i++) {
        NSString *n = NSStringFromSelector(method_getName(ms[i]));
        if (![n hasPrefix:@"set"] || !NBDiagWanted(n)) continue;
        [buf appendFormat:@"%@ ", n];
        if (buf.length >= NB_DIAG_FLUSH_AT) {
            NBSharedLog(@"SD# %@ 的 setter: %@", label, buf);
            [buf setString:@""];
        }
    }
    free(ms);
    if (buf.length) {
        NBSharedLog(@"SD# %@ 的 setter: %@", label, buf);
    } else {
        NBSharedLog(@"SD# %@ 声音相关 setter: 一个都没有", label);
    }
}

// 把一个对象的属性名逐个读值打出来。这是"抄真实对象"的核心动作。
static void NBDiagDumpValues(id obj, NSString *label) {
    if (!obj) return;
    unsigned int cnt = 0;
    objc_property_t *ps = class_copyPropertyList([obj class], &cnt);
    if (!ps) return;
    NSMutableString *buf = [NSMutableString string];
    for (unsigned i = 0; i < cnt; i++) {
        const char *n = property_getName(ps[i]);
        if (!n) continue;
        NSString *name = [NSString stringWithUTF8String:n];
        [buf appendFormat:@"%@=%@ ", name, NBDiagGet(obj, name)];
        if (buf.length >= NB_DIAG_FLUSH_AT) {
            NBSharedLog(@"SD# %@ 值: %@", label, buf);
            [buf setString:@""];
        }
    }
    free(ps);
    if (buf.length) NBSharedLog(@"SD# %@ 值: %@", label, buf);
}

@implementation NBSoundDiag

+ (void)dumpClassOnce {
    if (gClsDone) return;
    Class snd = objc_getClass("BBSound");
    Class bul = objc_getClass("BBBulletin");
    // 🔴 与 NotifyProbe 同一条纪律：现在拿不到 ≠ 以后拿不到。
    //    %ctor 阶段框架可能还没加载，这时置位会让探针**永久失效**，
    //    而且日志里只留一句"类不存在"，下一条通知明明能拿到却再也不试了。
    //    ⇒ 拿不到就不置位，留给第一条通知重试；但"拿不到"这句话只打一次，别刷屏。
    if (!snd && !bul) {
        if (!gClsMissLogged) {
            gClsMissLogged = YES;
            NBSharedLog(@"SD# 现在拿不到 BBSound/BBBulletin（大概率 %%ctor 阶段还没加载），"
                        @"等第一条通知再试");
        }
        return;
    }
    gClsDone = YES;
    @try {
        NBSharedLog(@"=== SD# 开始 dump 类结构（只读，一次性）===");
        // BBSound 全量：它本来就是个声音对象，每个字段都相关
        NBDiagDumpProps(snd, @"BBSound", NO);
        NBDiagDumpSetters(snd, @"BBSound");
        // BBBulletin 只挑相关的：68 个属性全打会把日志窗口吃光
        NBDiagDumpProps(bul, @"BBBulletin", YES);
        NBSharedLog(@"=== SD# dump 结束 ===");
    } @catch (__unused NSException *e) {
        NBSharedLog(@"!!! SD# dump 抛异常（已忽略，不影响功能）");
    }
}

+ (void)noteForeignSoundIfAny:(id)obj stage:(NSString *)stage {
    if (!obj) return;
    // 每次顺手催一下类结构 dump（幂等）：%ctor 那次很可能没加载完，
    // 而这里是"第一条通知"的位置，框架一定已经在了。
    [self dumpClassOnce];
    if (gForeignDone) return;

    id s = nil;
    @try {
        s = [obj valueForKey:@"sound"];
    } @catch (__unused NSException *e) {
        return;
    }
    if (!s) return;              // 绝大多数通知都是 nil（v0.0.20 PROBE 已量到）
    gForeignDone = YES;
    @try {
        NBSharedLog(@"SD# ★ 抓到非 nil 的 sound（这是最好的对照）stage=%@ cls=%@",
                    stage ?: @"?", NSStringFromClass([s class]));
        NBDiagDumpValues(s, @"该 sound 对象");
    } @catch (__unused NSException *e) {
        NBSharedLog(@"!!! SD# dump sound 对象抛异常（已忽略）");
    }
}

+ (void)probeAfterPublish:(id)obj stage:(NSString *)stage {
    if (!obj) return;
    [self dumpClassOnce];
    NSString *st = stage.length ? stage : @"?";

    // 只对目标 App 输出。判断口径来自 NotifyFilter（单一来源），
    // 否则会出现"诊断说该生效、刀说不该生效"这种自相矛盾，白白浪费一轮。
    NSString *bid = NBDiagGet(obj, @"sectionID");
    if ([bid isEqualToString:@"nil"] || [bid isEqualToString:@"!抛"]
        || [bid isEqualToString:@"-"]) {
        bid = nil;
    }
    if (![NotifyFilter isSoundTargetBundle:bid]) return;

    id s = nil;
    @try {
        s = [obj valueForKey:@"sound"];
    } @catch (__unused NSException *e) {
        s = nil;
    }

    // 🔴 三个入口的详细程度**故意不同**：日志窗口只有约 50 行。
    //    最终交给系统的是 PB 那个 bulletin，所以完整观测只放它那儿；
    //    PBRS / PBR 只打一行"sound 在不在"，用来对比"哪个对象才是最终对象"。
    if (![st isEqualToString:@"PB"]) {
        NBSharedLog(@"SD# %@ 发后 sound=%@ cls=%@", st,
                    s ? @"有" : @"nil", s ? NSStringFromClass([s class]) : @"-");
        return;
    }

    // ① 我们挂的那个对象还在不在（在 = 没被系统当场抹掉）
    NBSharedLog(@"SD# %@ 发后① sound=%@ cls=%@", st,
                s ? @"有" : @"nil", s ? NSStringFromClass([s class]) : @"-");
    // ② 决定播放的可能是 bulletin 自己的字段，而不是 BBSound 内部
    NBSharedLog(@"SD# %@ 发后② soundType=%@ sid=%@ alert=%@ tone=%@", st,
                NBDiagGet(obj, @"soundType"), NBDiagGet(obj, @"systemSoundID"),
                NBDiagGet(obj, @"alertType"), NBDiagGet(obj, @"toneIdentifier"));
    NBSharedLog(@"SD# %@ 发后③ src=%@ vibrat=%@", st,
                NBDiagGet(obj, @"soundSource"), NBDiagGet(obj, @"vibrationIdentifier"));

    // ③ 0.4 秒后再看一次 —— 这是唯一能区分"当场就在"和"被后续链路换掉"的观测。
    //    🔴 故意用**强引用**捕获：用 weak 的话对象被释放也会读到 nil，
    //       那会和"sound 被抹掉"混成同一个现象，等于没区分。
    //       持 0.4 秒对内存没有实质影响（bulletin 本身很短命）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id later = nil;
        @try {
            later = [obj valueForKey:@"sound"];
        } @catch (__unused NSException *e) {
            later = nil;
        }
        NBSharedLog(@"SD# %@ +0.4s sound=%@ cls=%@", st,
                    later ? @"有" : @"nil",
                    later ? NSStringFromClass([later class]) : @"-");
    });
}

@end
