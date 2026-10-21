// Tweak.x —— v0.0.17（当前）：延迟推送走「改时间字段」；本版修的是**判据行看不见**的问题
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
static int gDelayMissed = 0; // v0.0.16：判定要延迟但没找到可写时间字段的条数
static int gDelaySkipped = 0; // v0.0.16：多入口幂等跳过的条数（同一条通知命中 2~3 个入口）

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

// v0.0.16：延迟的留痕拆成两条，**必须能分开**——它们对应的下一步完全相反。
//   DELAY#      = 延迟真的生效了（时间字段已改写，系统会晚点弹）
//                 后面带字段名：这正是"我改的是不是系统读的那个字段"的直接证据
//   DELAY-MISS# = 判定要延迟，但**一个时间字段都没改成** ⇒ 本条会按时发布。
//                 这是安全失败（不崩、不吞），但功能没生效，必须能看见。
//                 下一版要看的就是这条后面 PROBEDATE# 打出来的真实字段名。
static void NBLogDelayApplied(NSString *tag, NSTimeInterval sec, NSString *fields) {
    gDelayFired++;
    NBLog(@"DELAY#%d tag=%@ %.1fs 字段=%@", gDelayFired, tag, (double)sec, fields ?: @"?");
}
static void NBLogDelayMissed(NSString *tag, NSTimeInterval sec, id bulletin) {
    gDelayMissed++;
    NBLog(@"DELAY-MISS#%d tag=%@ 想要 %.1fs，但找不到可写的时间字段 ⇒ 本条按时发布",
          gDelayMissed, tag, (double)sec);

    // 🔴 失败时才 dump 字段名，而且只 dump 前 2 次 —— 日志窗口 ≈ 50 条且全局滚动，
    //    刷多了会把紧接着要看的 DROP#/REPL# 挤出去。
    //    成功时不用 dump：DELAY# 那行已经带着"我改的是哪个字段"了。
    if (gDelayMissed > 2) return;
    @try {
        NSString *desc = [NotifyFilter probeTimeFieldsOfBulletin:bulletin];
        if (!desc.length) return;
        // 🔴 单条日志 200 字上限。属性清单很容易超，先截断再打 ——
        //    超长会被日志层截掉，而"截断"和"本来就没有"在事后是分不开的。
        if (desc.length > 150) {
            desc = [[desc substringToIndex:150] stringByAppendingString:@"…(截断)"];
        }
        NBLog(@"PROBEDATE#%d cls=%@ :: %@", gDelayMissed,
              bulletin ? NSStringFromClass([bulletin class]) : @"nil", desc);
    } @catch (__unused NSException *e) { }
}

// v0.0.16：同一条通知命中多个入口时，第 2、3 个入口会拿到"已经推过了"的空串。
// 这条日志的价值：**证明幂等真的生效了**。
// 反过来说，如果填 5 秒实际晚了 10 秒，这里一定缺 SKIP 行 —— 一眼就能分开
// 「幂等没生效」和「系统自己又拖了」。
static void NBLogDelaySkipped(NSString *tag) {
    gDelaySkipped++;
    NBLog(@"DELAY-SKIP#%d tag=%@ 这一条已经推过了（多入口幂等）", gDelaySkipped, tag);
}

// ---------- 延迟推送的崩溃自愈（v0.0.15） ----------
// 与朗读那套「自毁保护」同一个思路：崩溃前必须留下可判读的痕迹，
// 因为崩的是 SpringBoard —— 用户连设置页都进不去，只能靠下一次启动自己恢复。

static void NBWriteDelayGuard(NSString *state) {
    if (![state isKindOfClass:[NSString class]]) return;
    @try {
        NSString *dir = [NOTIFYBOX_DELAY_GUARD_PATH stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        [[state dataUsingEncoding:NSUTF8StringEncoding] writeToFile:NOTIFYBOX_DELAY_GUARD_PATH
                                                        atomically:YES];
    } @catch (__unused NSException *e) { }
}

// 返回 YES 表示"上次就是崩在延迟发布里"，已经自动把 delaySeconds 清掉了。
static BOOL NBRecoverFromDelayCrash(void) {
    @try {
        NSString *s = [NSString stringWithContentsOfFile:NOTIFYBOX_DELAY_GUARD_PATH
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![s isEqualToString:@"start"]) return NO;

        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:NBLoadSettings()];
        [d removeObjectForKey:NB_KEY_DELAY_SECONDS];
        [NotifyStore saveSettings:d];
        NBWriteDelayGuard(@"crash-closed");
        NBLog(@"!!! 延迟自毁保护触发：上次崩在延迟发布里（guard=start 没有 done）");
        NBLog(@"!!! 已自动删除 delaySeconds ⇒ 延迟推送回到关闭状态，不用你手动改");
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

// 🔴 v0.0.15 引入、v0.0.16 起**不再调用**。
//    v0.0.15 停用延迟时，"主动清掉历史 delaySeconds"是对的：那版的值只有坏处。
//    v0.0.16 延迟重新启用了，还无条件删就等于**每次都把用户的设置抹掉** ——
//    他会觉得"我明明设了 5 秒，一升级就没了"，这比崩溃更难解释。
//    所以改成：只在"确实崩过"（guard=start）时才清，见 NBRecoverFromDelayCrash。
//    函数本体先留着（现场排障时可能还要手工清），但不许在构造函数里调用。
static void NBClearStaleDelaySetting(void) __attribute__((unused));
static void NBClearStaleDelaySetting(void) {
    @try {
        NSDictionary *cur = NBLoadSettings();
        if (!cur[NB_KEY_DELAY_SECONDS]) return;         // 没有就什么都不做（绝大多数情况）
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:cur];
        [d removeObjectForKey:NB_KEY_DELAY_SECONDS];
        [NotifyStore saveSettings:d];
        NBLog(@"已清除历史 delaySeconds（仅在确实崩过时才会走到这里）");
    } @catch (__unused NSException *e) { }
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

        // ①.6 v0.0.16：BBServer 队列情报，只跑一次（只读）。
        //     🔴 必须放在**这里**而不是构造函数里：构造阶段 BulletinBoard 还没加载，
        //        objc_getClass("BBServer") 拿到 nil。放这里才能拿到真实数据，
        //        而且此刻我们正站在 BB 的调用队列上 —— 队列标签才有意义。
        [NotifyProbe dumpServerQueueOnce];

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
        // 🔴🔴 v0.0.16：延迟的执行方式**整体换掉**了 —— 不再延迟调用原方法。
        //
        // 旧实现（v0.0.14，已判死刑）：
        //     dispatch_after(..., main_queue, ^{ orig(bulletin, destinations); });
        // 真机崩溃栈：
        //     _dispatch_assert_queue_fail ← dispatch_assert_queue
        //     ← -[BBServer dataProviderForSectionID:] +44 ← tweak ← GCD 定时器 ← 主队列
        // ⇒ BBServer 的方法内部要求"必须在 BB 自己的私有串行队列上"，那个队列句柄
        //   只活在 BBServer 内部、外面拿不到 ⇒ 换哪个队列都不对，必然 SIGTRAP。
        //
        // 新实现：只把 bulletin 上的**时间字段**往后平移 d.delay 秒，
        // 然后**立刻、在同一个线程上调 orig**，让系统自己按新时间排期。
        // ⇒ 没有跨队列、没有跨时间的对象持有、没有重复发布。这三件事一个都不做了。
        //
        // 🔴 关键：下面的 orig 是**无条件、立即**执行的（不 return、不等待）。
        //    改字段失败也只是"没延迟"，绝不能因此吞掉通知。
        NSString *moved = [NotifyFilter applyDelayToBulletin:bulletin seconds:d.delay];
        if (moved.length) {
            NBLogDelayApplied(@"PB", d.delay, moved);
        } else if (moved) {
            NBLogDelaySkipped(@"PB");        // 空串 = 多入口幂等跳过（不是失败）
        } else {
            NBLogDelayMissed(@"PB", d.delay, bulletin);
        }
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
        // 见入口 1 的说明：改时间字段 + 立即调原方法，绝不 dispatch_after
        NSString *moved = [NotifyFilter applyDelayToBulletin:request seconds:d.delay];
        if (moved.length) {
            NBLogDelayApplied(@"PBR", d.delay, moved);
        } else if (moved) {
            NBLogDelaySkipped(@"PBR");        // 空串 = 多入口幂等跳过（不是失败）
        } else {
            NBLogDelayMissed(@"PBR", d.delay, request);
        }
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
        // 见入口 1 的说明：改时间字段 + 立即调原方法，绝不 dispatch_after
        NSString *moved = [NotifyFilter applyDelayToBulletin:request seconds:d.delay];
        if (moved.length) {
            NBLogDelayApplied(@"PBRS", d.delay, moved);
        } else if (moved) {
            NBLogDelaySkipped(@"PBRS");        // 空串 = 多入口幂等跳过（不是失败）
        } else {
            NBLogDelayMissed(@"PBRS", d.delay, request);
        }
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
                          [NSDate date], NBProc(), @"v0.0.17", selfPath];
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

    // 🔴🔴 v0.0.15：延迟推送自毁保护，同样排在任何 hook 之前。
    //    延迟推送已整体停用（NotifyFilter 的 kDelayEnabled = NO），这里是第二道保险：
    //    万一哪天有人把那个常量打开、又崩了，下次开机会自动把 delaySeconds 清掉。
    //
    // 🔴🔴 这两件事**只让 SpringBoard 做**（本 tweak 同时注入 backboardd，见 NotifyBox.plist）：
    //    ① 两个进程同时改 settings.plist 会互相覆盖（后写的赢，可能把用户的改动冲掉）；
    //    ② backboardd 以 **root** 运行 —— 它写出来的文件/目录会变成 root 所有，
    //       之后盒子 App（mobile）就写不动了，表现是「设置保存失败 / 存不住」，
    //       而且现场看起来完全不像是权限问题。这种坑不能留。
    BOOL delayRecovered = NO;
    if ([NBProc() isEqualToString:@"SpringBoard"]) {
        delayRecovered = NBRecoverFromDelayCrash();
        // 🔴 v0.0.16：**不再**调用 NBClearStaleDelaySetting()。
        //    v0.0.15 停用期间无条件删除是对的，现在延迟重新启用了，
        //    再无条件删就等于每次都抹掉用户的设置。改成只在 guard=start 时清。
    }

    // 🔴 v0.0.16：延迟推送**重新启用**，执行方式换成"改时间字段"。
    //    这行必须如实写出来 —— 上一版这里写的是「已停用」，用户是靠这行判断
    //    功能到底能不能用。功能状态变了而日志没变，等于给用户一个假现场。
    NBLog(@"=== [%@] NotifyBox v0.0.17 · %@ · 朗读自愈%@ · 延迟自愈%@ · 延迟推送%@ ===",
          NBProc(), [NotifySpeaker diagnosticLine],
          recovered ? @"已触发" : @"无异常",
          delayRecovered ? @"已触发" : @"无异常",
          @"已启用（改时间字段，不跨队列）");

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

    NBLog(@"=== [%@] NotifyBox v0.0.17 · BBServer %u 个方法 · PB=%@ PBR=%@ PBRS=%@ ===",
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

    NBLog(@"=== [%@] v0.0.17 %@ ===", NBProc(),
          (h1 || h2 || h3) ? @"已挂发布入口，等通知（看 PB/PBR/PBRS 开头的命中行）"
                           : @"没挂上任何入口");
}
