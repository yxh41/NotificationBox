// Tweak.x —— v0.0.9（当前）：过滤/替换已接线（0.0.8 起）+ 设置存 NotifyBox/settings.plist
//
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 📌 真机量回来的签名（v0.0.4 零 hook 诊断，SpringBoard / iOS 16.4.1）：
//
//   SEL publishBulletin:destinations:
//       ENC v32@0:8@16Q24   ⇒ - (void)xxx:(id) destinations:(unsigned long long)
//   SEL publishBulletinRequest:destinations:
//       ENC v32@0:8@16Q24   ⇒ - (void)xxx:(id) destinations:(unsigned long long)
//   SEL _publishBulletinRequest:forSectionID:forDestinations:
//       ENC v40@0:8@16@24Q32 ⇒ - (void)xxx:(id) forSectionID:(id) forDestinations:(unsigned long long)
//
// 🔴 v0.0.3 为什么三个候选全 "NO"：我把名字抄成了
//    `publishBulletinRequest:forSectionID:forDestinations:`（**漏了前导下划线**），
//    真名是 `_publishBulletinRequest:...`。缩略图读串丢了细节。
//    ⇒ 定签名只认 ENC 输出，不认截图。
//
// 🔴 v0.0.3 为什么进安全模式：挂了一个签名不明的探针并声明成 void。
//    现在三个目标全部确认返回 void，签名逐字照抄，才敢挂。
//
// 🔴 三个入口可能都被调用（一个通知走完整链路），所以必须**去重**，
//    否则同一条通知会被记 3 次。去重键 = bundle|title|message，窗口 2 秒。
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
// 🔴 Logos 坑：注释里绝不出现以百分号开头的 Logos 关键字（nb_precheck.py 把关）。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "NotifyStore.h"
#import "NotifyCommon.h"
#import "NotifyFilter.h"

static NSString *const kNBLogPath = @"/var/mobile/Library/NotifyBox/tweak.log";

static int gHit1 = 0;   // publishBulletin:destinations:
static int gHit2 = 0;   // publishBulletinRequest:destinations:
static int gHit3 = 0;   // _publishBulletinRequest:forSectionID:forDestinations:
static int gDropped = 0;    // 被过滤掉（没有交给原方法）的条数
static int gReplaced = 0;   // 内容替换真正改过字段的次数

// 去重表：key -> 最后一次记录的时间戳
static NSMutableDictionary *gRecent = nil;

static NSString *NBProc(void) {
    NSString *p = [NSProcessInfo processInfo].processName;
    return p.length ? p : @"?";
}

// 日志超过 512 KB 就切成 .1（覆盖上一份），避免长期运行把分区写满。
// 用计数器节流：不是每次写都 stat，每 200 次看一眼。
static void NBRotateIfNeeded(void) {
    static int tick = 0;
    tick++;
    if (tick % 200 != 1) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *a = [fm attributesOfItemAtPath:kNBLogPath error:nil];
    if ([a[NSFileSize] unsignedLongLongValue] < 512 * 1024) return;
    NSString *old = [kNBLogPath stringByAppendingString:@".1"];
    [fm removeItemAtPath:old error:nil];
    [fm moveItemAtPath:kNBLogPath toPath:old error:nil];
}

static void NBLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[kNBLogPath stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];
    NBRotateIfNeeded();
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kNBLogPath];
    if (fh) {
        @try { [fh seekToEndOfFile]; [fh writeData:d]; }
        @finally { [fh closeFile]; }
    } else {
        [d writeToFile:kNBLogPath atomically:YES];
    }
}

// ---------- 防御式取值：SpringBoard 里抛异常就等于崩，全部包 @try ----------

static id NBSafeValue(id obj, NSString *key) {
    if (!obj) return nil;
    if (![obj respondsToSelector:@selector(valueForKey:)]) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *NBSafeStr(id obj, NSString *key) {
    id v = NBSafeValue(obj, key);
    if (!v) return nil;
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    @try {
        return [v description];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSDate *NBSafeDate(id obj, NSString *key) {
    id v = NBSafeValue(obj, key);
    return [v isKindOfClass:[NSDate class]] ? (NSDate *)v : nil;
}

static NSString *NBClassName(id obj) {
    if (!obj) return @"nil";
    @try {
        return NSStringFromClass([obj class]);
    } @catch (__unused NSException *e) {
        return @"?";
    }
}

// ---------- 去重 ----------
// 三个发布入口可能依次都被调用，同一条通知不能记三遍。
// 窗口取 2 秒：足够覆盖同一次发布的多个入口，又不至于吃掉用户连发的两条相同通知。
static BOOL NBClaimKey(NSString *key) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    @synchronized (gRecent) {
        if (!gRecent) return YES;
        NSNumber *t = gRecent[key];
        if (t && (now - t.doubleValue) < 2.0) return NO;
        gRecent[key] = @(now);
        if (gRecent.count > 300) {
            NSMutableArray *dead = [NSMutableArray array];
            for (NSString *k in gRecent) {
                if (now - [gRecent[k] doubleValue] > 15.0) [dead addObject:k];
            }
            // 🔴 NSMutableDictionary 的方法是 removeObjectsForKeys:（复数 Keys）
            if (dead.count) [gRecent removeObjectsForKeys:dead];
        }
        return YES;
    }
}

// ---------- 录制 ----------
// sectionHint：能从参数直接拿到 sectionID 时优先用（最可靠）
// 🔴 v0.0.8：返回**真正用来记录的那个 bundle**（可能是从 .bulletin 里兜出来的）。
//    这样下游过滤判定用的 bundle 和库里存的是同一个值，不会出现「记的 A、判的 B」错位。
static NSString *NBRecordItem(id obj, NSString *sectionHint, NSString *tag, int *counter) {
    if (!obj) return nil;

    NSString *bid   = sectionHint.length ? sectionHint : NBSafeStr(obj, @"sectionID");
    NSString *title = NBSafeStr(obj, @"title");
    NSString *msg   = NBSafeStr(obj, @"message");
    NSString *sub   = NBSafeStr(obj, @"subtitle");
    NSDate   *date  = NBSafeDate(obj, @"date");

    // 有的版本 packing 了一层，真正内容在 .bulletin 里
    if (!bid.length || (title.length == 0 && msg.length == 0)) {
        id inner = NBSafeValue(obj, @"bulletin");
        if (inner && inner != obj) {
            if (!bid.length)   bid   = NBSafeStr(inner, @"sectionID");
            if (!title.length) title = NBSafeStr(inner, @"title");
            if (!msg.length)   msg   = NBSafeStr(inner, @"message");
            if (!sub.length)   sub   = NBSafeStr(inner, @"subtitle");
            if (!date)         date  = NBSafeDate(inner, @"date");
        }
    }
    // 有些 wrapper 用 bulletinID / requestID 之类的键放 section；读不到就只报诊断
    if (!bid.length) {
        if (*counter < 6) {
            (*counter)++;
            NBLog(@"%@#%d 没有 bundle，cls=%@ title=%@", tag, *counter, NBClassName(obj),
                  title.length ? title : @"(nil)");
        }
        return nil;
    }

    NSString *key = [NSString stringWithFormat:@"%@|%@|%@", bid, title ?: @"", msg ?: @""];
    if (!NBClaimKey(key)) return bid;      // 已被另一个入口记过；bundle 仍有效

    if (*counter < 10) {
        (*counter)++;
        NBLog(@"%@#%d bundle=%@ title=%@ msg=%@",
              tag, *counter, bid,
              title.length ? title : @"(nil)",
              msg.length ? (msg.length > 40 ? [[msg substringToIndex:40] stringByAppendingString:@"..."] : msg) : @"(nil)");
    }
    [NotifyStore recordWithBundle:bid title:title message:msg subtitle:sub date:date];
    return bid;
}

// ---------- 记录 + 过滤流水线（三入口共用） ----------
// 返回 NO ⇒ 调用点**不要执行原方法**，等于把这条通知拦下来（盒子里仍然查得到）。
// 🔴 整段 @try：这段跑在 SpringBoard 里，抛一个异常就是用户眼里的闪退 / 进安全模式。
// 🔴 顺序讲究：**先记录原文 → 再判定过滤（用原文判）→ 最后才做内容替换**。
//    若先替换再判定，用户配了「把"红包"替换成空」又同时过滤"红包"时，过滤会永远不命中。
static BOOL NBPipeline(id obj, NSString *sectionHint, NSString *tag, int *counter) {
    // ① 记录（原文；被过滤也留档，方便回头查「本来要推什么」）
    NSString *bid = NBRecordItem(obj, sectionHint, tag, counter);
    if (!bid.length) return YES;            // 认不出是哪个 App ⇒ 绝不拦

    @try {
        NSString *t = NBSafeStr(obj, @"title");
        NSString *m = NBSafeStr(obj, @"message");
        NSString *s = NBSafeStr(obj, @"subtitle");

        // ② 拦截判定（用原文）
        if ([NotifyFilter shouldDropBundle:bid title:t message:m subtitle:s]) {
            gDropped++;
            // 前 8 条全记（方便确认到底拦了什么），之后每 50 条记一次（不刷爆日志）
            if (gDropped <= 8 || (gDropped % 50) == 0) {
                NBLog(@"DROP#%d bundle=%@ tag=%@ title=%@",
                      gDropped, bid, tag, t.length ? t : @"(nil)");
            }
            return NO;
        }
        // ③ 内容替换（只改呈现，库里留着原文）
        //
        // 🔴 这里必须留痕：替换是"静默"的 —— 配了规则没生效，界面上完全看不出来。
        //    若日志里从来没有 REPL 行，只有两种可能：①没配规则 ②入口传进来的对象
        //    没有 setTitle:/setMessage:（request 包装类常见）⇒ 是"对象不对"，不是"规则没读到"。
        //    这两种病因必须能分开，否则又是一轮盲猜。
        if ([NotifyFilter applyReplaceRulesTo:obj]) {
            gReplaced++;
            if (gReplaced <= 8 || (gReplaced % 50) == 0) {
                NBLog(@"REPL#%d bundle=%@ tag=%@ cls=%@",
                      gReplaced, bid, tag, NBClassName(obj));
            }
        }
    } @catch (__unused NSException *e) {
        // 兜底一律放行：宁可多推一条，也不要把通知吞掉
    }
    return YES;
}

// ---------- 入口 1：- publishBulletin:destinations: ----------
%group GPB
%hook BBServer
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations {
    if (NBPipeline(bulletin, nil, @"PB", &gHit1)) {
        %orig(bulletin, destinations);
    }
}
%end
%end

// ---------- 入口 2：- publishBulletinRequest:destinations: ----------
%group GPBR
%hook BBServer
- (void)publishBulletinRequest:(id)request destinations:(unsigned long long)destinations {
    if (NBPipeline(request, nil, @"PBR", &gHit2)) {
        %orig(request, destinations);
    }
}
%end
%end

// ---------- 入口 3：- _publishBulletinRequest:forSectionID:forDestinations: ----------
// 🔴 注意前导下划线，v0.0.3 就是漏了它才判 NO
%group GPBRS
%hook BBServer
- (void)_publishBulletinRequest:(id)request
                   forSectionID:(id)sectionID
                forDestinations:(unsigned long long)destinations {
    // 第二个参数按 ENC 是 @（对象），本身就是 sectionID，直接当 bundle 用最可靠
    NSString *sid = [sectionID isKindOfClass:[NSString class]] ? (NSString *)sectionID : nil;
    if (NBPipeline(request, sid, @"PBRS", &gHit3)) {
        %orig(request, sectionID, destinations);
    }
}
%end
%end

%ctor {
    gRecent = [NSMutableDictionary dictionary];   // 单线程时机初始化，之后只读引用

    // 🔴 与 tweak.log 独立的「我跑过」证据：
    //    上一轮出现「日志文件不存在」，但 App 侧又疑似有记录 ⇒ 无法区分
    //    「tweak 没注入」与「日志写不进去」。这个标记文件把两者分开：
    //      .tweak_ctor 存在 + tweak.log 不存在 ⇒ 注入成功、但写日志失败
    //      两个都不存在                      ⇒ 真的没注入
    {
        NSString *mark = @"/var/mobile/Library/NotifyBox/.tweak_ctor";
        // 🔴 用 dladdr 拿到 dylib 自己的真实路径：roothide 会把前缀重定向，
        //    App 侧探测那几个写死的候选路径通常都落空，只有 tweak 自己知道它被装在哪。
        NSString *selfPath = @"?";
        Dl_info dli;
        if (dladdr((const void *)&NBProc, &dli) && dli.dli_fname) {
            selfPath = [NSString stringWithUTF8String:dli.dli_fname];
        }
        NSString *body = [NSString stringWithFormat:@"%@ %@ %@ dylib=%@",
                          [NSDate date], NBProc(), @"v0.0.9", selfPath];
        NSData *md = [body dataUsingEncoding:NSUTF8StringEncoding];
        [[NSFileManager defaultManager] createDirectoryAtPath:
            [mark stringByDeletingLastPathComponent]
                                 withIntermediateDirectories:YES attributes:nil error:nil];
        [md writeToFile:mark atomically:YES];
    }

    Class c = objc_getClass("BBServer");
    if (!c) {
        NBLog(@"!!! [%@] BBServer 类不存在（该进程里没有公告板服务）", NBProc());
        return;
    }

    // 🔴 用 class_copyMethodList 建名字集合来判断存在性。
    //    v0.0.3 用 class_getInstanceMethod 在 constructor 阶段对本机 BBServer 会返回 NULL
    //    （同一时刻 class_copyMethodList 却能列出该方法），所以这条路径更可靠。
    NSMutableSet *names = [NSMutableSet set];
    unsigned int cnt = 0;
    Method *ms = class_copyMethodList(c, &cnt);
    if (ms) {
        for (unsigned i = 0; i < cnt; i++) {
            [names addObject:NSStringFromSelector(method_getName(ms[i]))];
        }
        free(ms);
    }

    BOOL h1 = [names containsObject:@"publishBulletin:destinations:"];
    BOOL h2 = [names containsObject:@"publishBulletinRequest:destinations:"];
    BOOL h3 = [names containsObject:@"_publishBulletinRequest:forSectionID:forDestinations:"];

    NBLog(@"=== [%@] NotifyBox v0.0.9 · BBServer %u 个方法 · PB=%@ PBR=%@ PBRS=%@ ===",
          NBProc(), cnt, h1 ? @"YES" : @"NO", h2 ? @"YES" : @"NO", h3 ? @"YES" : @"NO");

    if (h1) { NBLog(@"--> 挂 GPB (publishBulletin:destinations:)");  %init(GPB); }
    if (h2) { NBLog(@"--> 挂 GPBR (publishBulletinRequest:destinations:)"); %init(GPBR); }
    if (h3) { NBLog(@"--> 挂 GPBRS (_publishBulletinRequest:forSectionID:forDestinations:)"); %init(GPBRS); }

    if (!h1 && !h2 && !h3) {
        // 全不存在时把相关名字打出来（只打名字，省日志）
        NSMutableArray *hits = [NSMutableArray array];
        for (NSString *n in names) {
            NSString *low = [n lowercaseString];
            if ([low containsString:@"publish"] || [low containsString:@"addbulletin"]) {
                [hits addObject:n];
            }
        }
        NBLog(@"!!! 三个入口都不存在；BBServer 上含 publish/addBulletin 的共 %lu 条：%@",
              (unsigned long)hits.count,
              [[hits sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" , "]);
    }

    NBLog(@"=== [%@] v0.0.9 %@ ===", NBProc(),
          (h1 || h2 || h3) ? @"已挂发布入口，等通知（看 PB/PBR/PBRS 开头的命中行）"
                           : @"没挂上任何入口");
}
