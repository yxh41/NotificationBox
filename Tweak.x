// Tweak.x —— v0.0.32（当前）：可选「来通知时压低别人音乐」（DuckOthers，只对 B 通道长音有效；缺省关 = 老行为）
//
// 🔴🔴 先认账：v0.0.23 的假设被真机数据**正面否掉了**。
//
// v0.0.23 的推断：`repetitions` / `maxDuration` 在空壳里是 0 ⇒ 播 0 次 / 0 秒 ⇒ 没声音。
// v0.0.23 落盘的 sound_diag.log 反驳（用户手机实测）：
//   系统自己给的、**能正常出声**的那个 BBSound：
//       maxDuration=0   repeats=0   soundType=2   systemSoundID=0
//       alertConfiguration=<TLAlertConfiguration>   toneIdentifier=""   alertType=17
// ⇒ 0/0 是正常的，与出不出声无关。
// ⇒ 而且 `repetitions` 这个键**根本不存在**（真机 `rep=!无键`）；
//    正确的名字是 `repeats`（{TB,N,GisRepeating,V_repeats}，BOOL，是"要不要重复"）。
//    病根：我照着上一版 PROBE 截图**凭印象转写**了一个意思相近的名字，
//    没有逐字抄。⇒ 以后键名只能从数据里逐字抄，不许"翻成同义词"。
//
// 把两边摊开对比，唯一还没被排除的差异：
//     能响的：   soundType=2   systemSoundID=0     alertConfiguration=<非 nil>
//     我们的：   soundType=1   systemSoundID=1009  alertConfiguration=nil
// ⇒ iOS 16 的通知音走 **TonesLibrary（TLAlert + TLAlertConfiguration）**；
//    `systemSoundID` 是 AudioServices 的老 ID，BulletinBoard 已经不看它了。
//    这同时解释了设置页"试听"为什么是响的 —— 试听走 AudioServices 播放，
//    跟系统投递通知是两条完全不同的路。**试听能响 ≠ 通知能响。**
//
// ⇒ 这一版**不改刀**。刀继续"造不出能响的对象就不挂"，手机停在"能响原声"这个安全状态
//    （v0.0.21 已实测：挂空壳 = 通知彻底没声音 = 用户漏消息，比"没换成"糟得多）。
//
// 这一版只做一件事：**把"怎么造一个能响的 BBSound"挖出来。**
//   ① dump BBSound 的**类方法** —— 找 +soundWith… 这类工厂。
//      ⚠️ v0.0.20 的 PROBE 曾记过"只有 1 个类方法且与声音无关"，
//         但当时那份 dump 是否真的取到了元类（object_getClass）无法确认，
//         所以再确认一次；有工厂就让它替我们造，不要在字段里继续摸。
//   ② dump **TLAlertConfiguration** 的属性 + 类方法 + ivar —— iOS 16 通知音的真身。
//      `alertConfiguration` 是 BBSound 上标 [W] 的字段，我们需要的只是"造一个能用的 cfg"。
//   ③ 抓到系统给的 sound 时不再只留 1 个样本：按"长相"去重最多留 4 个，
//      并把它们的 alertConfiguration 一起 dump。
//      只有多样性才能看出 soundType 有哪几个取值、各形态分别靠哪个字段发声 ——
//      上一版只留一个样本，等于只认识了一种长相。
//
// 另外修掉两处**诊断自己在说谎**的 bug（真机输出里已经出现了，都是判据类错误）：
//   · `NBDiagDumpSetters` 拿 `buf.length` 同时当"缓冲区还剩多少"和"有没有找到过"，
//     而 flush 会清空缓冲区 ⇒ 6 个 setter 加起来正好 111 字触发 flush，
//     于是打出「setter: setVibrationPattern: … setRingtoneName:」紧跟着
//     「声音相关 setter: 一个都没有」—— 两行自相矛盾。判据变量必须独立记事实。
//   · 关键词过滤漏了 duration / repeat / song / audio，把真实存在的
//     setMaxDuration: / setRepeats: / setSongPath: 全筛掉了 ⇒ 我以为"只有 6 个可写字段"。
//
// ⚠️ 顺带记录两条已被数据证伪的猜测，别再回头捡：
//   · `playSound` **不是**出声的闸门 —— 用户明确听到原声的那几条也是 playSound=0；
//   · `soundSource` 在 BBSound 上不存在（KVC 抛 NSUnknownKeyException）。
//
// 更早一版的白捡经验仍然成立：遇到系统给的、非 nil 的 sound 就整份 dump ——
// 抄一个真实对象的字段值，比猜枚举值强一万倍。（这一版把它从"一次"扩到"按形态最多 4 次"。）
//
// 依据真机 PROBE 数据（v0.0.20 采）定下换提示音的实现方式，一条都不凭猜：
//   sound{T@"BBSound",&,N,V_sound} 可写；BBSound **只有 1 个类方法且与声音无关 ⇒ 没有工厂方法**；
//   alertType 是 R（只读），可写的是 soundType / systemSoundID / vibrationIdentifier；
//   PROBE#1/2/3 全是 sound=nil ⇒ 默认提示音**不带 BBSound**，必须自己 alloc/init 造一个再挂。
//   挂完必须回读验证（造出来的对象被系统丢弃 = 静默无效，不报错）。
//
// 免打扰：命中时段就 NBDeny() 丢掉，仍记一条日志（DND#），保证"不弹但可回看"。
// 换提示音：**空名单不生效** —— 实验性功能，绝不允许一次性改掉整台手机的通知音。
//
// 上一版（v0.0.20）修的是「探针数据被结论行筛掉」：
//
//   探针（PROBE）的实质数据行里一个筛选关键词都不含 ⇒ 结论行只剩「开始/结束」两行空壳，
//   看起来像「探针跑了但什么都没量到」，实际数据一直在日志里。
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
#import "NotifySoundDiag.h"


static int gHit1 = 0;   // publishBulletin:destinations:
static int gHit2 = 0;   // publishBulletinRequest:destinations:
static int gHit3 = 0;   // _publishBulletinRequest:forSectionID:forDestinations:
static int gDropped = 0;    // 被过滤掉（没有交给原方法）的条数
static int gReplaced = 0;   // 内容替换真正改过字段的次数
static int gDndDropped = 0; // v0.0.21：免打扰时段拦下的条数
static int gSoundApplied = 0; // v0.0.21：尝试过换提示音的条数（成没成看 SOUND# 那行）
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

// ---------- 延迟推送的残留清理（v0.0.19） ----------
//
// 🔴🔴 为什么这一版把"自愈"整个换掉 —— v0.0.16~v0.0.18 的自愈会**骗人**：
//
//   真机现场（用户 v0.0.18 截图）：
//       17:59:52  延迟自愈已触发 / 已自动删除 delaySeconds ⇒ 延迟推送回到关闭状态
//       18:00:18  DELAY#2516 tag=PBRS 5.0s 字段=date          ← 26 秒后还在推
//       18:00:18  DELAY#2517 tag=PB   5.0s 字段=date+...
//   ⇒ 它说"删了"，实际上延迟还在按 5 秒跑。用户看到的是"功能明明关掉了，通知还是不弹"。
//
//   病因查清了，而且是我自己埋的：
//     `NBWriteDelayGuard(@"start")` 只在 **v0.0.15** 那个 commit 里被调用过；
//     v0.0.16 把"写 start"删了、却把"读 start"留着。而 v0.0.15 的延迟是全程关闭的，
//     所以它写下 start 之后**永远等不到 done** ⇒ 这个文件永久停在 start
//     ⇒ 从 v0.0.16 起每次启动都误判成"上次崩在延迟里"。
//     （git log -S 'NBWriteDelayGuard(@"start")' 只有 d47ac61 / 6dc778c 两个 commit。）
//
//   ⇒ 教训：**一个只写不读的状态是死状态，一个只读不写的状态是永远为真的谎言。**
//     自愈判据必须"写和读在同一处、成对出现"，且**回读验证**。
//
// 现在的做法只有一件事：把残留的键**真的**清掉，然后把**回读结果**打出来。
//   不判断、不自愈、不猜测 —— 因为功能已经整个删除了，没有"开着"这个状态。
static void NBPurgeDelayLeftovers(void) {
    @try {
        // 两处都要清：NBLoadSettings() 是「新文件优先，旧 Preferences 域兜底」，
        // 只清一个的话，另一个会把键"复活"回来。这就是"删了还在跑"的第二个可能来源。
        NSArray *paths = @[NOTIFYBOX_SETTINGS_PATH, NOTIFYBOX_PREFS_PATH];
        BOOL purged = NO;

        for (NSString *path in paths) {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
            if (![d isKindOfClass:[NSDictionary class]] || !d.count) continue;
            if (!d[NB_KEY_DELAY_SECONDS] && !d[NB_KEY_DELAY_APPS]) continue;

            NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:d];
            [m removeObjectForKey:NB_KEY_DELAY_SECONDS];
            [m removeObjectForKey:NB_KEY_DELAY_APPS];
            if ([m writeToFile:path atomically:YES]) purged = YES;
            else NBLog(@"!!! 清理延迟残留失败（写不进去）：%@", path);
        }

        // 🔴 回读验证：把"我以为的结果"换成"实际读到的结果"。
        //    上面那句 v0.0.18 的假话就是这么来的 —— 只有写、没有回读。
        NSDictionary *back = NBLoadSettings();
        BOOL gone = (back[NB_KEY_DELAY_SECONDS] == nil && back[NB_KEY_DELAY_APPS] == nil);
        if (!gone) {
            NBLog(@"!!! 延迟残留还在：回读 settings 仍有 delaySeconds=%@ delayApps=%@",
                  back[NB_KEY_DELAY_SECONDS] ?: @"(无)", back[NB_KEY_DELAY_APPS] ?: @"(无)");
        } else if (purged) {
            NBLog(@"已清除延迟推送的历史残留（回读确认已无 delaySeconds / delayApps）");
        }

        // 老版本留下的 guard 文件同样是垃圾（它停在 start 上，会让旧版误判）。
        // 顺手删掉：万一用户回退到旧版，也不会再被这个死状态骗到。
        [[NSFileManager defaultManager] removeItemAtPath:NOTIFYBOX_DELAY_GUARD_PATH error:nil];
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
// 🔴 v0.0.19：删掉了 delay 字段。理由见 NotifyFilter.h 顶部那条长注释 ——
//    延迟这件事两次撞死（跨队列 SIGTRAP / 改时间字段导致通知全不弹），
//    功能已整体删除。**结构体里留一个永远为 0 的字段是最坏的做法**：
//    它会让后来的人以为"这条链路是通的，只是没启用"。
typedef struct {
    BOOL allow;              // NO ⇒ 调用点不要执行原方法（被过滤掉）
} NBDecision;

static NBDecision NBAllowNow(void) { NBDecision d; d.allow = YES; return d; }
static NBDecision NBDeny(void)     { NBDecision d; d.allow = NO;  return d; }

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
        // ②.5 免打扰时段（v0.0.21）
        //
        // 这是 v0.0.19 删掉「延迟推送」之后给的安全替代：
        // 延迟要达成的是"别在这个时间吵我"，而它必须**改系统发布时间**才能实现
        // （两次撞死：跨队列 SIGTRAP / 通知永远到不了）；这里只是**我们自己不弹**，
        // 不碰 BB 内部、不改任何系统字段 ⇒ 从根上没有那两类风险。
        //
        // 🔴 被免打扰拦下的通知**不朗读、不换音**（和黑名单同一个语义）：
        //    「别吵我」是用户配这条规则的全部意图，屏幕上不弹、耳朵里却念出来是最糟的组合。
        NSString *dndWhy = nil;
        if ([NotifyFilter shouldDropForDND:bid now:nil reason:&dndWhy]) {
            gDndDropped++;
            if (gDndDropped <= 8 || (gDndDropped % 50) == 0) {
                NBLog(@"DND#%d bundle=%@ tag=%@ 时段=%@ ⇒ 不弹（仍记进盒子）",
                      gDndDropped, bid, tag, dndWhy ?: @"?");
            }
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

        // ④.4 v0.0.22 只读诊断：如果这个对象身上已经带了一个**系统给的** sound，
        //     立刻整份 dump（全进程只一次）。
        //     🔴 必须在 ④.5 **之前**：挂完之后再看，就分不清是"系统给的"还是"我们挂的"，
        //        而这两者的字段值正是这一轮唯一能抄到正确答案的来源。
        [NBSoundDiag noteForeignSoundIfAny:obj stage:tag];

        // ④.5 按 App 换提示音 —— 🔴 v0.0.25 起**不在这里做了**。
        //
        //    这里原来干的是「alloc 一个 BBSound、填字段、setValue:forKey:@"sound"」，
        //    也就是**造系统对象**。v0.0.21~v0.0.24 四个版本下来确认了三件事：
        //      · 造对了不一定响（字段都对，仍然一声不出）；
        //      · 造错了**整条通知变哑**（v0.0.21 实测，用户直接漏消息）；
        //      · `BBSound` 上**连 bundle id 都没有** ——"按 App 换音"这件事在这里无从下手。
        //    v0.0.25 把动手的位置搬到 `SBNCSoundController -canPlaySoundForNotificationRequest:`
        //    （通知音的**总闸门**，见本文件末尾的 GSC 组）。
        //
        //    ⇒ 这段说明留着而不是删干净，是因为「为什么不在 publish 点动手」本身是结论：
        //      **拦在"要播声音"的那一刻，比拦在"造声音对象"的那一刻更靠下游**，
        //      而下游 = 更接近最终判定 = 更不容易被后续链路覆盖（本项目吃过太多次亏）。

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
    %orig(bulletin, destinations);
    // 🔴 v0.0.22：必须在 orig **之后**读 —— 要看的正是"系统处理完之后 sound 还在不在"。
    //    只在目标 App 输出（内部判），不会刷屏。
    [NBSoundDiag probeAfterPublish:bulletin stage:@"PB"];
}
%end
%end

// ---------- 入口 2：- publishBulletinRequest:destinations: ----------
%group GPBR
%hook BBServer
- (void)publishBulletinRequest:(id)request destinations:(unsigned long long)destinations {
    NBDecision d = NBPipeline(request, nil, @"PBR", &gHit2);
    if (!d.allow) return;
    %orig(request, destinations);
    [NBSoundDiag probeAfterPublish:request stage:@"PBR"];
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
    %orig(request, sectionID, destinations);
    [NBSoundDiag probeAfterPublish:request stage:@"PBRS"];
}
%end
%end


// 🔴 v0.0.25：SBNCSoundController 的**前向声明**。
//
// 为什么写它：Logos 在 %hook 里生成的函数签名，self 的类型取决于 Logos 版本/配置
// （本项目 `%hook BBServer` 一直不声明也能编过，说明走的是 id）。
// 多一个纯声明是零成本的：编过了就等于保险，编不过就说明这个类名得让编译器知道 ——
// 而"unknown type name"这种报错一轮 CI 就没了，不值得赌。
// ⚠️ 这个类**可能根本不存在**（名字来自外部参考）。声明只是编译期的东西，
//    运行时能不能拿到由 %ctor 里的 objc_getClass 决定，拿不到就不 %init。
@interface SBNCSoundController : NSObject
- (BOOL)canPlaySoundForNotificationRequest:(id)request;
@end

// ---------- v0.0.25：按 App 换提示音 · **新挂点** ----------
//
// 🔴🔴 为什么整段换掉旧做法：
//    v0.0.21~v0.0.24 一直在 BulletinBoard 的 `BBSound` 上手工拼字段 ——
//    那是"造系统对象"，实测造错就**整条通知变哑**，而且 BBSound 上**连 bundle id 都没有**，
//    "按 App" 只能靠外层传参凑。
//    `SBNCSoundController -canPlaySoundForNotificationRequest:` 是通知音的**总闸门**
//    （返回 BOOL 的最终判定），参数就是通知请求，自带 sectionIdentifier。
//    参考实现见 docs/换提示音-外部插件调研.md（SilentNotifs 就挂这同一个方法实现"静音通知音"）。
//
// 流程一句话：**先把我们的声音送出去，送成功了才让系统别播**。
// 顺序反过来（先掐再播）就是"播失败 ⇒ 哑巴"，所以返回契约在 NotifyFilter.h 里写死了。
//
// ⚠️ 这个类/方法名来自外部参考（iOS 14.8 / 16.4.1 实测可用），**本机还没验证**。
//    所以 %ctor 里先用 class_copyMethodList 确认它存在、名字对得上，再 %init ——
//    不存在就一个 hook 都不挂，通知照旧原声（绝不因为"我以为有"而变哑）。
%group GSC
%hook SBNCSoundController
- (BOOL)canPlaySoundForNotificationRequest:(id)request {
    // 🔴 这是系统最热的一条路之一，**任何异常都必须吃掉**：
    //    抛出去轻则这条通知不出声，重则崩 SpringBoard。
    @try {
        // 用 KVC 而不是点语法：这个类是靠 objc_getClass 拿的，没有编译期类型可依赖。
        NSString *bid = nil;
        @try {
            id s = [request valueForKey:@"sectionIdentifier"];
            if ([s isKindOfClass:[NSString class]]) bid = (NSString *)s;
        } @catch (__unused NSException *e) {
            bid = nil;          // 读不到 bundle id 就当"没配"，放原声
        }

        // 🔴🔴 去重：同一条通知可能在**锁屏 + 横幅**两处各问一次"要不要出声"。
        //    不判重就是同一个音**连响两遍** —— 用户的第一句反馈必然是"响两次"。
        //    只在能拿到 notificationIdentifier 时才去重：拿不到就**不去重**。
        //    理由：没有唯一 ID 时只能按时间窗猜，而"同一个 App 紧接着发的第二条真通知"
        //    会被那个窗误吞（少响一次）。⇒ **宁可偶尔响两遍，也不要吞掉一条真通知。**
        NSString *nid = nil;
        @try {
            id v = [request valueForKey:@"notificationIdentifier"];
            if ([v isKindOfClass:[NSString class]]) nid = (NSString *)v;
        } @catch (__unused NSException *e) {
            nid = nil;
        }

        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        static NSString *gLastNid = nil;
        static NSTimeInterval gLastNidAt = 0;
        if (nid.length && gLastNid.length
            && [nid isEqualToString:gLastNid] && (now - gLastNidAt) < 2.0) {
            return NO;          // 这条已经响过了 ⇒ 只掐原声，不再播第二遍
        }

        NSString *sres = nil;
        if ([NotifyFilter playCustomSoundForBundle:bid forResult:&sres]) {
            // 🔴 记 nid 必须在**播成功之后**。写在播之前的话，第一次播失败时
            //    这条 nid 也会被记上 ⇒ 第二次调用就直接 return NO ⇒ 原声被掐 + 我们没响
            //    = **哑巴**。这个顺序和"先播再掐"是同一条道理的另一面。
            if (nid.length) {
                gLastNid = nid;
                gLastNidAt = now;
            }
            gSoundApplied++;
            // 限流：前 8 次 + 每 50 次一条。日志窗口约 50 行、全局滚动，不许刷屏。
            if (gSoundApplied <= 8 || (gSoundApplied % 50) == 0) {
                NBLog(@"SOUND#%d 闸门掐掉原声 bundle=%@ %@",
                      gSoundApplied, bid ?: @"?", sres ?: @"?");
            }
            return NO;          // 🔴 我们的音已经送出去了 ⇒ 别让系统再播一遍（否则双响）
        }
    } @catch (__unused NSException *e) {
        // 我们自己出错 ⇒ 一律退回系统判断。绝不因为我的 bug 让用户漏消息。
    }
    @try {
        return %orig;
    } @catch (__unused NSException *e) {
        return YES;             // 系统自己抛 ⇒ 放行（默认允许播，比静音安全）
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
                          [NSDate date], NBProc(), @"v0.0.25", selfPath];
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

    // 🔴🔴 这两件事**只让 SpringBoard 做**（本 tweak 同时注入 backboardd，见 NotifyBox.plist）：
    //    ① 两个进程同时改 settings.plist 会互相覆盖（后写的赢，可能把用户的改动冲掉）；
    //    ② backboardd 以 **root** 运行 —— 它写出来的文件/目录会变成 root 所有，
    //       之后盒子 App（mobile）就写不动了，表现是「设置保存失败 / 存不住」，
    //       而且现场看起来完全不像是权限问题。这种坑不能留。
    BOOL soundRecovered = NO;
    if ([NBProc() isEqualToString:@"SpringBoard"]) {
        // 🔴 v0.0.19：延迟功能已整体删除 ⇒ 这里不再有"自愈"，只有**残留清理**。
        //    只在 SpringBoard 里做，理由同上一段（backboardd 是 root）。
        NBPurgeDelayLeftovers();
        // 🔴 v0.0.21：换提示音是本版唯一的"造系统对象"操作，必须有自愈兜底。
        //    和 v0.0.15 那个坏掉的 guard 的区别：这里的 start/done 是**配对写**的
        //    （都在 NotifyFilter 的同一个函数里），而且关开关之后会**回读确认**。
        soundRecovered = [NotifyFilter recoverFromSoundCrashIfNeeded];
    }

    // 🔴 v0.0.19：banner 里**不许再出现"延迟"的"已启用/已触发"字样**。
    //    用户是靠这一行判断功能状态的；功能没了却还在说"已启用"，就是 v0.0.18 那种假现场。
    // 🔴 banner 必须如实：用户是靠这一行判断"我改的功能到底有没有上线"。
    //    换提示音是实验功能，所以这里写「实验」，不写「已启用」。
    NBLog(@"=== [%@] NotifyBox v0.0.32 · %@ · 朗读自愈%@ · 换提示音自愈%@ · 免打扰时段%@ · 换提示音%@ · 延迟推送已移除 ===",
          NBProc(), [NotifySpeaker diagnosticLine],
          recovered ? @"已触发" : @"无异常",
          soundRecovered ? @"已触发" : @"无异常",
          @"可用",
          @"实验（默认关，按 App 各自一个音 + 时长上限 + 连发不叠加）");

    // 只读探针：dump 一次 BBBulletin / BBSound 的类结构（内部自己保证只做一次）
    [NotifyProbe dumpClassesOnce];
    // 🔴 v0.0.22：换提示音听不到 ⇒ 必须知道 BBSound 到底有哪些属性、哪些**可写**。
    //    和上面那份的分工：NotifyProbe 打的是"名字 + 类型"，
    //    这份额外标注 [R]/[W]，并且把 BBSound 的声音相关 setter 全列出来 ——
    //    "能不能填进去"看的就是 setter 在不在。
    [NBSoundDiag dumpClassOnce];

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

    NBLog(@"=== [%@] NotifyBox v0.0.32 · BBServer %u 个方法 · PB=%@ PBR=%@ PBRS=%@ ===",
          NBProc(), cnt, h1 ? @"YES" : @"NO", h2 ? @"YES" : @"NO", h3 ? @"YES" : @"NO");

    if (h1) { NBLog(@"--> 挂 GPB (publishBulletin:destinations:)");  %init(GPB); }
    if (h2) { NBLog(@"--> 挂 GPBR (publishBulletinRequest:destinations:)"); %init(GPBR); }
    if (h3) { NBLog(@"--> 挂 GPBRS (_publishBulletinRequest:forSectionID:forDestinations:)"); %init(GPBRS); }

    // ---------- v0.0.25：换提示音的新挂点 ----------
    //
    // 🔴 先**确认类和闸门存在**再 %init。理由见 GSC 组上面的注释：
    //    这个名字来自外部参考，本机未验证；类不存在时往 nil 上 hook 是"什么都可能发生"。
    // 🔴 名字对不上时把含 sound/play/vibrat/alert 的方法名**全打出来** ——
    //    这是"下一轮不用猜"的唯一来源（本项目因为"名字像"已经白跑过好几轮）。
    {
        Class gsc = objc_getClass("SBNCSoundController");
        if (!gsc) {
            NBLog(@"!!! v0.0.25 SBNCSoundController 类不存在 ⇒ 换提示音不挂（通知照旧原声）");
        } else {
            NSMutableSet *gn = [NSMutableSet set];
            unsigned int gcnt = 0;
            Method *gms = class_copyMethodList(gsc, &gcnt);
            if (gms) {
                for (unsigned i = 0; i < gcnt; i++) {
                    [gn addObject:NSStringFromSelector(method_getName(gms[i]))];
                }
                free(gms);
            }
            BOOL hs = [gn containsObject:@"canPlaySoundForNotificationRequest:"];
            NBLog(@"=== [%@] SBNCSoundController %u 个方法 · canPlaySoundForNotificationRequest=%@ ===",
                  NBProc(), gcnt, hs ? @"YES" : @"NO");
            if (hs) {
                NBLog(@"--> 挂 GSC (canPlaySoundForNotificationRequest:)");
                %init(GSC);
            } else {
                NSMutableArray *hits = [NSMutableArray array];
                for (NSString *n in gn) {
                    NSString *low = [n lowercaseString];
                    if ([low containsString:@"sound"] || [low containsString:@"play"]
                        || [low containsString:@"vibrat"] || [low containsString:@"alert"]) {
                        [hits addObject:n];
                    }
                }
                NBLog(@"!!! 没有 canPlaySoundForNotificationRequest:；"
                      @"含 sound/play/vibrat/alert 的共 %lu 条：%@",
                      (unsigned long)hits.count,
                      [[hits sortedArrayUsingSelector:@selector(compare:)]
                          componentsJoinedByString:@" , "]);
            }
        }
    }

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

    NBLog(@"=== [%@] v0.0.32 %@ ===", NBProc(),
          (h1 || h2 || h3) ? @"已挂发布入口，等通知（看 PB/PBR/PBRS 开头的命中行）"
                           : @"没挂上任何入口");
}
