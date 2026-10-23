#import "NotifySoundDiag.h"
#import "NotifyCommon.h"
#import "NotifyFilter.h"
#import <objc/runtime.h>

// ============ v0.0.23：换提示音的诊断（落盘版） ============
//
// 上一版（v0.0.22）已经量出三件硬事实：
//   · `sound` 在 orig 前/后、0.4 秒后都在 ⇒ 不是挂载失败、也没被系统抹掉；
//   · `set=1/1` ⇒ setter 存在；
//   · 回读 `type=1 sid=1009` ⇒ 值真的进了对象。
// 而用户的实际症状是**完全没声音**（不是"还是原来的声音"）。
//
// ⇒ 这个组合只有一种解释：**我们挂的是个空壳，系统采纳了它，但它播不出声。**
//    真机 PROBE 的 `BBSound 有 15 个 property` 里有两个要命的字段：
//        repetitions（播几次）、maxDuration（播多久）
//    alloc/init 出来的对象里它们大概是 0 ⇒ 播 0 次 / 0 秒 ⇒ 一声不出。
//    而 sound=nil 时系统走"默认提示音"路径，所以默认通知照样响。
//
// 这一版做两件事：
//   ① 刀上补 repetitions=1 / maxDuration=30（见 NotifyFilter.m 里的长注释）；
//   ② 诊断**写到文件**，把"设之前/设之后"的字段实值全量留下来。
//
// 🔴🔴 为什么必须落盘（这一条是 v0.0.22 白跑一轮换来的）：
//    日志窗口只有约 50 行、还是全局滚动的 ⇒ 结构性 dump 早就滚没了，
//    而它恰恰是定位问题的唯一依据。用户截图里只剩后面的 SOUND# 行。
//    文件不受这个限制，App 里能整份读。

static BOOL gClsDone = NO;
static BOOL gClsMissLogged = NO;
static BOOL gForeignDone = NO;
static BOOL gFileReset = NO;

#define NB_DIAG_FLUSH_AT 110

// 诊断统一出口：**同时**打日志（App 结论行照旧看得到）和写文件（不受窗口限制）。
// reset=YES 时覆盖旧文件 —— 只给"每个进程一次"的结构性 dump 用。
//
// 🔴 为什么这里要挂 NS_FORMAT_FUNCTION：诊断行最怕的不是崩，而是
//    "格式符数量和参数数量差一个" ⇒ 多出来的那个读进垃圾栈内存，
//    运气好打出乱码、运气不好直接崩在诊断里（而这正是最不该崩的地方）。
//    挂上属性以后，编译器会把 22 处调用的 %@ / %u 全对一遍，
//    这类错从"真机上才发现"变成"编译期就红"。
//    参数位置：fmt 是第 2 个参数，第一个可变参数是第 3 个。
static void NBDiagLog(BOOL reset, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void NBDiagLog(BOOL reset, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!line.length) return;

    NBSharedLog(@"%@", line);

    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [NOTIFYBOX_SOUND_DIAG_PATH stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
        NSString *out = [NSString stringWithFormat:@"[%@] %@\n",
                         [df stringFromDate:[NSDate date]], line];
        NSData *data = [out dataUsingEncoding:NSUTF8StringEncoding];

        // 结构性 dump 只在每个进程的第一次写，用来覆盖旧文件；
        // 另外加 256KB 上限，防止进程长期不重启把文件撑大。
        if (!reset && !gFileReset) reset = YES;
        gFileReset = YES;
        if (!reset) {
            NSDictionary *attr = [fm attributesOfItemAtPath:NOTIFYBOX_SOUND_DIAG_PATH error:nil];
            if ([[attr objectForKey:NSFileSize] unsignedLongLongValue] > 256 * 1024) reset = YES;
        }

        if (reset || ![fm fileExistsAtPath:NOTIFYBOX_SOUND_DIAG_PATH]) {
            [data writeToFile:NOTIFYBOX_SOUND_DIAG_PATH atomically:YES];
            return;
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:NOTIFYBOX_SOUND_DIAG_PATH];
        if (!fh) {
            [data writeToFile:NOTIFYBOX_SOUND_DIAG_PATH atomically:YES];
            return;
        }
        @try {
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        } @catch (__unused NSException *e) { }
    } @catch (__unused NSException *e) { }
}

// 这些名字一旦出现，就是"换提示音"相关的量。
// 🔴 比 NotifyProbe 那份过滤器更宽：多收 tone / source / system。
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

// 🔴 每个字段**单独 @try**：一个字段抛异常不能带走其余的，
//    否则"没读到"会被误判成"没这个字段"。
//
// 🔴🔴 v0.0.23：必须区分**两种**读不到 —— 这是上一版最误导人的地方。
//    NSUnknownKeyException ⇒ **这个键根本不存在**（BBSound 上的 soundSource 就是这种）；
//    别的异常           ⇒ 键存在，但 getter 自己抛了。
//    上一版一律打成 "!抛"，我自己都分不清是"没这个字段"还是"读它出事了"，
//    差点据此去改一个正确的方向。
static NSString *NBDiagGet(id obj, NSString *key) {
    if (!obj) return @"-";
    @try {
        id v = [obj valueForKey:key];
        if (!v) return @"nil";
        if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
        if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
        return [NSString stringWithFormat:@"<%@>", NSStringFromClass([v class])];
    } @catch (NSException *e) {
        if ([e.name isEqualToString:NSUndefinedKeyException]) return @"!无键";
        return [NSString stringWithFormat:@"!抛:%@", e.name ?: @"?"];
    }
}

// dump 一个类的属性表。onlyInteresting=YES 时只打关键词相关的
// （BBBulletin 有 68 个属性，全打会把日志吃光；BBSound 只有 15 个，全打正合适）。
static void NBDiagDumpProps(Class c, NSString *label, BOOL onlyInteresting) {
    if (!c) {
        NBDiagLog(NO, @"SD# %@ 类不存在", label);
        return;
    }
    unsigned int cnt = 0;
    objc_property_t *ps = class_copyPropertyList(c, &cnt);
    if (!ps) {
        NBDiagLog(NO, @"SD# %@ 属性表拿不到", label);
        return;
    }
    NBDiagLog(NO, @"SD# %@ 有 %u 个属性（[W]=可写 [R]=只读）", label, cnt);
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
            NBDiagLog(NO, @"SD# %@: %@", label, buf);
            [buf setString:@""];
        }
    }
    free(ps);
    if (buf.length) NBDiagLog(NO, @"SD# %@: %@", label, buf);
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
            NBDiagLog(NO, @"SD# %@ 的 setter: %@", label, buf);
            [buf setString:@""];
        }
    }
    free(ms);
    if (buf.length) {
        NBDiagLog(NO, @"SD# %@ 的 setter: %@", label, buf);
    } else {
        NBDiagLog(NO, @"SD# %@ 声音相关 setter: 一个都没有", label);
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
            NBDiagLog(NO, @"SD# %@ 值: %@", label, buf);
            [buf setString:@""];
        }
    }
    free(ps);
    if (buf.length) NBDiagLog(NO, @"SD# %@ 值: %@", label, buf);
}

@implementation NBSoundDiag

+ (void)dumpClassOnce {
    if (gClsDone) return;
    Class snd = objc_getClass("BBSound");
    Class bul = objc_getClass("BBBulletin");
    // 🔴 现在拿不到 ≠ 以后拿不到。%ctor 阶段框架可能还没加载，这时置位会让探针永久失效。
    if (!snd && !bul) {
        if (!gClsMissLogged) {
            gClsMissLogged = YES;
            NBDiagLog(NO, @"SD# 现在拿不到 BBSound/BBBulletin（大概率 %%ctor 阶段还没加载），"
                          @"等第一条通知再试");
        }
        return;
    }
    gClsDone = YES;
    @try {
        // 这一条 reset=YES：覆盖上一份文件，保证"类结构"永远在最前面。
        NBDiagLog(YES, @"=== SD# 开始 dump 类结构（只读，一次性；v0.0.23 落盘）===");
        // BBSound 全量：它本来就是个声音对象，15 个属性每个都相关。
        // 🔴 上一版这几行被日志窗口吃了 —— 现在进文件，不会再丢。
        NBDiagDumpProps(snd, @"BBSound", NO);
        NBDiagDumpSetters(snd, @"BBSound");
        NBDiagDumpProps(bul, @"BBBulletin", YES);
        NBDiagLog(NO, @"=== SD# dump 结束 ===");
    } @catch (__unused NSException *e) {
        NBDiagLog(NO, @"!!! SD# dump 抛异常（已忽略，不影响功能）");
    }
}

+ (void)probeCreatedSound:(id)snd stage:(NSString *)stage {
    if (!snd) return;
    [self dumpClassOnce];
    // 只打关键字段：15 个属性全量太占行，而 rep/dur/type/sid/tone 才是嫌疑犯。
    NBDiagLog(NO, @"SD# snd[%@] type=%@ sid=%@ rep=%@ dur=%@ tone=%@",
              stage ?: @"?",
              NBDiagGet(snd, @"soundType"), NBDiagGet(snd, @"systemSoundID"),
              NBDiagGet(snd, @"repetitions"), NBDiagGet(snd, @"maxDuration"),
              NBDiagGet(snd, @"toneIdentifier"));
}

+ (void)noteForeignSoundIfAny:(id)obj stage:(NSString *)stage {
    if (!obj) return;
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
        NBDiagLog(NO, @"SD# ★ 抓到非 nil 的 sound（这是最好的对照）stage=%@ cls=%@",
                  stage ?: @"?", NSStringFromClass([s class]));
        NBDiagDumpValues(s, @"该 sound 对象");
    } @catch (__unused NSException *e) {
        NBDiagLog(NO, @"!!! SD# dump sound 对象抛异常（已忽略）");
    }
}

+ (void)probeAfterPublish:(id)obj stage:(NSString *)stage {
    if (!obj) return;
    [self dumpClassOnce];
    NSString *st = stage.length ? stage : @"?";

    // 只对目标 App 输出。判断口径来自 NotifyFilter（单一来源），
    // 否则会出现"诊断说该生效、刀说不该生效"这种自相矛盾，白白浪费一轮。
    NSString *bid = NBDiagGet(obj, @"sectionID");
    if ([bid isEqualToString:@"nil"] || [bid hasPrefix:@"!"] || [bid isEqualToString:@"-"]) {
        bid = nil;
    }
    if (![NotifyFilter isSoundTargetBundle:bid]) return;

    id s = nil;
    @try {
        s = [obj valueForKey:@"sound"];
    } @catch (__unused NSException *e) {
        s = nil;
    }

    // 🔴 三个入口的详细程度**故意不同**：日志/文件空间有限。
    //    最终交给系统的是 PB 那个 bulletin，完整观测只放它那儿。
    if (![st isEqualToString:@"PB"]) {
        NBDiagLog(NO, @"SD# %@ 发后 sound=%@ cls=%@", st,
                  s ? @"有" : @"nil", s ? NSStringFromClass([s class]) : @"-");
        return;
    }

    // 🔴 v0.0.23：必须打**对象自己的类名**。
    //    上一版只打了 sound 的类名，结果"对象上 soundType 读不到"这件事
    //    连"它到底是不是 BBBulletin"都说不清 —— 一半的信息就这么丢了。
    NBDiagLog(NO, @"SD# %@ 发后⓪ objCls=%@ sound=%@ cls=%@", st,
              NSStringFromClass([obj class]),
              s ? @"有" : @"nil", s ? NSStringFromClass([s class]) : @"-");
    // playSound 是"这条通知要不要出声"的开关级字段，和 sound 是两个东西。
    // 只挂 sound 而 playSound=0 的话，系统照样一声不出。
    NBDiagLog(NO, @"SD# %@ 发后① playSound=%@ alert=%@ type=%@ sid=%@", st,
              NBDiagGet(obj, @"playSound"), NBDiagGet(obj, @"alertType"),
              NBDiagGet(obj, @"soundType"), NBDiagGet(obj, @"systemSoundID"));
    NBDiagLog(NO, @"SD# %@ 发后② tone=%@ src=%@ vibrat=%@", st,
              NBDiagGet(obj, @"toneIdentifier"), NBDiagGet(obj, @"soundSource"),
              NBDiagGet(obj, @"vibrationIdentifier"));

    // ③ 0.4 秒后再看一次 —— 唯一能区分"当场就在"和"被后续链路换掉"的观测。
    //    🔴 故意用**强引用**捕获：weak 会把"对象被释放"也读成 nil，
    //       那和"sound 被抹掉"就成了同一个现象，等于没区分。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id later = nil;
        @try {
            later = [obj valueForKey:@"sound"];
        } @catch (__unused NSException *e) {
            later = nil;
        }
        NBDiagLog(NO, @"SD# %@ +0.4s sound=%@ cls=%@", st,
                  later ? @"有" : @"nil",
                  later ? NSStringFromClass([later class]) : @"-");
    });
}

@end
