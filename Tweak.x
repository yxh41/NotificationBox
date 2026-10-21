// Tweak.x —— v0.0.14（当前）：过滤/替换/朗读已接线；本版新增**延迟推送**
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
#import "NotifySpeaker.h"
#import "NotifyProbe.h"


static int gHit1 = 0;   // publishBulletin:destinations:
static int gHit2 = 0;   // publishBulletinRequest:destinations:
static int gHit3 = 0;   // _publishBulletinRequest:forSectionID:forDestinations:
static int gDropped = 0;    // 被过滤掉（没有交给原方法）的条数
static int gReplaced = 0;   // 内容替换真正改过字段的次数
static int gDelayed = 0;    // 被延后发布的条数（v0.0.14）
static int gDelayFired = 0; // 真的到点执行了原方法的条数（v0.0.14）

// 去重表：key -> 最后一次记录的时间戳
static NSMutableDictionary *gRecent = nil;

static NSString *NBProc(void) {
    NSString *p = [NSProcessInfo processInfo].processName;
    return p.length ? p : @"?";
}

// 🔴 v0.0.13：日志实现搬到 NotifyStore.m 的 NBSharedLog（那个文件 tweak 与 App 都编），
//    这里只留一个别名，全部调用点不用改。
//    为什么不各留一份：Tweak.x 原来是 static NBLog，新加的 NotifySpeaker/NotifyProbe
//    够不着它。复制一份日志函数是最差解 —— 两份轮转逻辑迟早走岔。
#define NBLog NBSharedLog

// v0.0.14：延迟到期那一刀必须**单独留痕**。
// 判据价值：日志里只有 DELAY 没有 DELAY-FIRE ⇒ 定时器没走到（或进程被杀了）；
//            两者配对齐全但通知没出现 ⇒ 不是我们的定时器问题，是系统那边已经放弃了这条。
//            这两种结论对应的下一步完全相反，所以必须能分开。
static void NBLogDelayFired(NSString *tag) {
    gDelayFired++;
    NBLog(@"DELAY-FIRE#%d tag=%@", gDelayFired, tag);
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
//
// 🔴 v0.0.13 新增 firstTime 出参（可为 NULL）：
//    三个入口可能对同一条通知依次触发，去重表只会让**第一条**真正落库。
//    但调用方仍然拿到 bid ⇒ 下游会跟着跑三次。
//    这对「过滤/替换」无害（幂等：判三次、替换三次结果一样），
//    对**朗读**是灾难 —— 用户会听见同一句话被读三遍。
//    所以必须把"是不是首次"这个事实交出去，而不是让每个下游自己再猜一遍。
static NSString *NBRecordItem(id obj, NSString *sectionHint, NSString *tag,
                              int *counter, BOOL *firstTime) {
    if (firstTime) *firstTime = NO;
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

    if (firstTime) *firstTime = YES;       // 🔴 只有走到这里才算"首次"

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

// ---------- 流水线结论 ----------
// 🔴 v0.0.14：原来返回 BOOL，只能表达「拦不拦」。延迟推送要表达「放行，但晚 N 秒」，
//    一件事变两个维度 ⇒ 换成结构体。
//    ⚠️ ARC 禁止结构体持有 ObjC 对象指针，所以 bundle **不进结构体**；
//    需要 bundle 的日志一律在 NBPipeline 内部就打掉。
typedef struct {
    BOOL allow;              // NO ⇒ 调用点不要执行原方法（被过滤掉）
    NSTimeInterval delay;    // >0 ⇒ 延后这么多秒再执行原方法
} NBDecision;

static NBDecision NBAllowNow(void) { NBDecision d; d.allow = YES; d.delay = 0; return d; }
static NBDecision NBDeny(void)     { NBDecision d; d.allow = NO;  d.delay = 0; return d; }

// ---------- 记录 + 过滤流水线（三入口共用） ----------
// 返回 allow=NO ⇒ 调用点**不要执行原方法**，等于把这条通知拦下来（盒子里仍然查得到）。
// 返回 delay>0 ⇒ 调用点延后这么久再执行原方法。
// 🔴 整段 @try：这段跑在 SpringBoard 里，抛一个异常就是用户眼里的闪退 / 进安全模式。
// 🔴 顺序讲究：**先记录原文 → 再判定过滤（用原文判）→ 最后才做内容替换**。
//    若先替换再判定，用户配了「把"红包"替换成空」又同时过滤"红包"时，过滤会永远不命中。
static NBDecision NBPipeline(id obj, NSString *sectionHint, NSString *tag, int *counter) {
    // ① 记录（原文；被过滤也留档，方便回头查「本来要推什么」）
    BOOL firstTime = NO;
    NSString *bid = NBRecordItem(obj, sectionHint, tag, counter, &firstTime);
    if (!bid.length) return NBAllowNow();   // 认不出是哪个 App ⇒ 绝不拦

    NBDecision out = NBAllowNow();          // 🔴 初值就是"立即放行"：异常兜底 = 不改变行为

    @try {
        // ①.5 只读探针（v0.0.13）：量 BBBulletin 的 sound/alertType 等量，
        //     为下一版「按 App 换提示音」取数。内部自己限流（只前 3 条、且只 dump 一次）。
        //     🔴 放在过滤判定**之前**：我要的是"原始对象长什么样"，
        //        不能等替换改过字段之后再量。
        if (firstTime) [NotifyProbe probeBulletin:obj tag:tag];

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
            // 🔴🔴 被拦下的通知**不朗读**。
            //    「别烦我」是用户配这条规则的全部意图 —— 屏幕上不弹、耳朵里却念出来，
            //    那是最糟的组合：既没躲开，还更吵。所以朗读只能在 drop 判定之后。
            return NBDeny();
        }
        // ③ 内容替换（只改呈现，库里留着原文）
        //
        // 🔴 这里必须留痕：替换是"静默"的 —— 配了规则没生效，界面上完全看不出来。
        //    若日志里从来没有 REPL 行，只有两种可能：①没配规则 ②入口传进来的对象
        //    没有 setTitle:/setMessage:（request 包装类常见）⇒ 是"对象不对"，不是"规则没读到"。
        //    这两种病因必须能分开，否则又是一轮盲猜。
        BOOL replaced = [NotifyFilter applyReplaceRulesTo:obj];
        if (replaced) {
            gReplaced++;
            if (gReplaced <= 8 || (gReplaced % 50) == 0) {
                NBLog(@"REPL#%d bundle=%@ tag=%@ cls=%@",
                      gReplaced, bid, tag, NBClassName(obj));
            }
        }

        // ④ 延迟推送（v0.0.14）
        //
        // 🔴 放在过滤**之后**：被拦掉的通知根本不该被排进任何队列。
        // 🔴 放在朗读**之前**：日志顺序就是执行顺序（DELAY → SPEAK），看日志不会错位。
        // 🔴 替换必须在延迟之前做完：对象是**原地改写**的，N 秒后才发布 ⇒
        //    如果先排延迟再改字段，改的仍是同一个对象，结果一样；但日志会看不懂。
        NSTimeInterval ds = 0;
        if ([NotifyFilter shouldDelayBundle:bid seconds:&ds]) {
            gDelayed++;
            out.delay = ds;
            // ⚠️ 这里数的是**调用次数**，不是通知条数：同一条通知可能命中 2~3 个入口，
            //    所以 DELAY 行会比"实际延后的通知"多。看 DELAY-FIRE 的配对更有意义。
            if (gDelayed <= 8 || (gDelayed % 20) == 0) {
                NBLog(@"DELAY#%d bundle=%@ tag=%@ %.1fs", gDelayed, bid, tag, ds);
            }
        }

        // ⑤ 朗读（v0.0.13）
        //
        // 🔴 只在 firstTime 做：三个入口会依次触发，不判首次就会把同一句话读三遍。
        // 🔴 读**替换后**的文字：替换规则的意义就是"让这条通知说人话"，
        //    屏幕上改干净了、耳朵里还在念原来的骚扰词，等于只做了一半。
        //    替换失败时退回原文（replaced==NO 就不重读，省两次 KVC）。
        // 🔴 朗读**不跟着延迟**：延迟改的是"弹窗什么时候出现"，朗读是即时播报。
        //    两者同时开着时，用户会先听到、N 秒后才看到。设置页里写明了这一点。
        //    不做成"一起延后"是刻意的：朗读是刚在真机上验证过的功能，
        //    不想为了组合场景去动它的调用路径。
        if (firstTime) {
            NSString *st = t;
            NSString *sm = m;
            if (replaced) {
                NSString *x = NBSafeStr(obj, @"title");
                NSString *y = NBSafeStr(obj, @"message");
                if (x) st = x;
                if (y) sm = y;
            }
            if ([NotifySpeaker shouldSpeakBundle:bid title:st message:sm]) {
                [NotifySpeaker speakWithBundle:bid title:st message:sm];
            }
        }
    } @catch (__unused NSException *e) {
        // 兜底一律放行：宁可多推一条，也不要把通知吞掉
        return NBAllowNow();
    }
    return out;
}

// ---------- 入口 1：- publishBulletin:destinations: ----------
%group GPB
%hook BBServer
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations {
    NBDecision d = NBPipeline(bulletin, nil, @"PB", &gHit1);
    if (!d.allow) return;
    if (d.delay > 0) {
        // 🔴 延迟分支。三条都踩过点，别随手改：
        //  ① block 会**强引用住** bulletin（ARC 捕获），所以对象在 N 秒后仍然活着 ——
        //     这是延迟能成立的前提。若哪天改成 __weak 捕获，到点就是给 nil 发消息。
        //  ② 「orig」这个宏在 block 里是合法用法：Logos 把它展开成对静态函数指针的普通 C 调用
        //     `_logos_orig$...(self, _cmd, 参数...)`，self 与 _cmd 都会被 block 正常捕获。
        //  ③ 落在**主队列**：延迟到期时必须落在某个队列上，SpringBoard 里唯一一定存在的
        //     就是主队列；BBServer 的发布本身是线程安全的。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.delay * (double)NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NBLogDelayFired(@"PB");
            %orig(bulletin, destinations);
        });
        return;
    }
    %orig(bulletin, destinations);
}
%end
%end

// ---------- 入口 2：- publishBulletinRequest:destinations: ----------
%group GPBR
%hook BBServer
- (void)publishBulletinRequest:(id)request destinations:(unsigned long long)destinations {
    NBDecision d = NBPipeline(request, nil, @"PBR", &gHit2);
    if (!d.allow) return;
    if (d.delay > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.delay * (double)NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NBLogDelayFired(@"PBR");
            %orig(request, destinations);
        });
        return;
    }
    %orig(request, destinations);
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
    NBDecision d = NBPipeline(request, sid, @"PBRS", &gHit3);
    if (!d.allow) return;
    if (d.delay > 0) {
        // 🔴 sectionID 也要一起被 block 捕获住：延迟到点时要把它当参数传回原方法，
        //    它可能是个 autorelease 的 NSString，不捕获就可能已经死了。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.delay * (double)NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NBLogDelayFired(@"PBRS");
            %orig(request, sectionID, destinations);
        });
        return;
    }
    %orig(request, sectionID, destinations);
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
                          [NSDate date], NBProc(), @"v0.0.14", selfPath];
        NSData *md = [body dataUsingEncoding:NSUTF8StringEncoding];
        [[NSFileManager defaultManager] createDirectoryAtPath:
            [mark stringByDeletingLastPathComponent]
                                 withIntermediateDirectories:YES attributes:nil error:nil];
        [md writeToFile:mark atomically:YES];
    }

    // 🔴🔴 v0.0.13：朗读自毁保护，必须排在任何 hook 之前。
    //    如果上次是崩在朗读里，先把开关关掉再干别的 —— 否则这一轮开机又会崩一次，
    //    用户陷入「开机→崩→安全模式→开机」的循环，连盒子 App 都进不去改设置。
    BOOL recovered = [NotifySpeaker recoverFromCrashIfNeeded];

    NBLog(@"=== [%@] NotifyBox v0.0.14 · %@ · 朗读自愈%@ ===",
          NBProc(), [NotifySpeaker diagnosticLine],
          recovered ? @"已触发" : @"无异常");

    // 只读探针：dump 一次 BBBulletin / BBSound 的类结构（内部自己保证只做一次）
    [NotifyProbe dumpClassesOnce];

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

    NBLog(@"=== [%@] NotifyBox v0.0.14 · BBServer %u 个方法 · PB=%@ PBR=%@ PBRS=%@ ===",
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

    NBLog(@"=== [%@] v0.0.14 %@ ===", NBProc(),
          (h1 || h2 || h3) ? @"已挂发布入口，等通知（看 PB/PBR/PBRS 开头的命中行）"
                           : @"没挂上任何入口");
}
