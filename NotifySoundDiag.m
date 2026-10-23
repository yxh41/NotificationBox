#import "NotifySoundDiag.h"
#import "NotifyCommon.h"
#import "NotifyFilter.h"
#import <objc/runtime.h>

// ============ v0.0.24：换提示音的诊断（侦察「正确的造法」） ============
//
// 🔴🔴 v0.0.23 的假设被真机数据**正面否掉**了，先把这事记清楚，
//     免得下次又从同一个地方开始猜：
//
//   v0.0.23 的推断：`repetitions` / `maxDuration` 在 alloc 出来的空壳里是 0
//                    ⇒ 系统按"播 0 次 / 0 秒"执行 ⇒ 一声不出。
//   真机数据（v0.0.23 落盘的 sound_diag.log）反驳：
//     系统自己给的、**能正常出声**的那个 BBSound：
//        maxDuration=0  repeats=0  soundType=2  systemSoundID=0
//        alertConfiguration=<TLAlertConfiguration>   toneIdentifier=""  alertType=17
//     ⇒ `maxDuration/repeats 为 0` 是**正常**的，跟出不出声没关系。
//     ⇒ 而且 `repetitions` 这个键**根本不存在**（真机 `rep=!无键`）——
//        正确的是 `repeats`（{TB,N,GisRepeating,V_repeats}，BOOL，是"要不要重复"）。
//        病根：我照着上一版 PROBE 截图**凭印象转写**了一个意思相近的名字。
//        ⇒ 键名只能从数据里逐字抄，不能翻成同义词。
//
//   把两边的字段摊开对比，唯一还没被排除的差异是：
//       能响的： soundType=2   systemSoundID=0   alertConfiguration=<非 nil>
//       我们的： soundType=1   systemSoundID=1009 alertConfiguration=nil
//     ⇒ iOS 16 的通知音走 **TonesLibrary（TLAlert + TLAlertConfiguration）**，
//        `systemSoundID` 是 AudioServices 的老 ID，BulletinBoard 已经不看它了。
//        （这也能解释为什么设置页里"试听"是响的：试听走的是 AudioServices 播放，
//          跟系统投递通知是两条完全不同的路。）
//
//   所以这一版**不改刀**（刀继续保持"造不出能响的对象就不挂"，手机停在
//   "能响原声"这个安全状态），只做一件事：
//     **把"怎么造一个能响的 BBSound"挖出来。**
//   具体三个动作：
//     ① dump BBSound 的**类方法** —— 如果本来就有 +soundWith… 这样的工厂方法，
//        那就该让系统替我们造，而不是继续手工拼字段（这是最理想的路）；
//     ② dump **TLAlertConfiguration** 的属性/类方法/ivar —— 它是 iOS 16 通知音的真身；
//     ③ 抓到系统给的 sound 时不再只留一个样本，按"长相"去重最多留 4 个，
//        并把它们的 alertConfiguration 一起 dump —— 只有多样性才能看出
//        soundType 有哪几个取值、各形态分别靠哪个字段发声。
//
// 🔴🔴 为什么这一版仍然只读：v0.0.21 已经实测过"挂一个空壳 ⇒ 通知完全没声音"。
//    在不知道正确造法之前再挂一次，只会让用户再聋一轮。宁可这一轮慢，下一轮一次改对。
//
// 另外修掉两处**诊断自己在说谎**的 bug（真机输出里已经发生了）：
//   · `NBDiagDumpSetters` 用 `buf.length` 同时表示"缓冲区还有字"和"有没有找到过"，
//     而 flush 会清空缓冲区 ⇒ 刚好凑满 110 字时打出
//     "6 个 setter 都在" + "一个都没有" 两行自相矛盾的话；
//   · 关键词过滤漏了 duration / repeat / song / audio，
//     把真实存在的 setMaxDuration: / setRepeats: / setSongPath: 全筛掉了。

static BOOL gClsDone = NO;
static BOOL gClsMissLogged = NO;
static BOOL gFileReset = NO;

#define NB_DIAG_FLUSH_AT 110

// 诊断有两个出口，**必须分开**：
//   NBDiagLog  —— 同时写日志 + 写文件。只给"短结论行"用（每通知几条）。
//   NBDiagLogF —— **只写文件**，不进日志。给"重型结构 dump"用。
//
// 🔴🔴 v0.0.24 为什么必须把它们分开（这条是 v0.0.22 白跑一轮的同一个病）：
//    日志窗口只有约 50 行、还是全局滚动的。这一版要 dump 的东西比上一版多得多 ——
//    BBSound 的**全量实例方法**（带类型编码，几十行）、TLAlertConfiguration 的
//    属性/setter/方法/ivar、以及最多 4 个外来 sound 的字段。
//    如果这些也走 NBSharedLog，一次 dump 就能把日志窗口糊死，
//    用户之后截的"结论行"里只剩下我们自己的结构 dump ——
//    真正的判据（banner / DROP# / SOUND# / 发后①②）全被挤出去。
//    ⇒ **重型只读观测只进文件**；文件不受窗口限制，App 里能整份读。
//
// reset=YES 时覆盖旧文件 —— 只给"每个进程一次"的结构性 dump 用。
//
// 🔴 为什么这里要挂 NS_FORMAT_FUNCTION：诊断行最怕的不是崩，而是
//    "格式符数量和参数数量差一个" ⇒ 多出来的那个读进垃圾栈内存，
//    运气好打出乱码、运气不好直接崩在诊断里（而这正是最不该崩的地方）。
//    挂上属性以后，编译器会把每一处调用的 %@ / %u 全对一遍，
//    这类错从"真机上才发现"变成"编译期就红"。
//    参数位置：fmt 是第 2 个参数，第一个可变参数是第 3 个。
//    ⚠️ 新加的 NBDiagLogF 参数位置是 (1, 2) —— 它没有 reset 那个参数。
static void NBDiagLog(BOOL reset, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void NBDiagLogF(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

// 真正落盘的地方。两个出口共用，避免"两条写文件逻辑走岔"。
static void NBDiagWriteFile(NSString *line, BOOL reset) {
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

// 短结论行：日志 + 文件都要有（用户截图看日志，完整内容进文件）。
static void NBDiagLog(BOOL reset, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!line.length) return;
    NBSharedLog(@"%@", line);
    NBDiagWriteFile(line, reset);
}

// 重型结构 dump：**只写文件**，一个字都不进日志。
// 🔴 判据：这段内容"是不是用户靠截图必须看到的" —— 不是，就走这里。
//    走错的后果不是崩溃，是**把真正的判据挤出日志窗口**，比崩溃更难查。
static void NBDiagLogF(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!line.length) return;
    NBDiagWriteFile(line, NO);
}

// 这些名字一旦出现，就是"换提示音"相关的量。
// 🔴 比 NotifyProbe 那份过滤器更宽：多收 tone / source / system。
//
// 🔴🔴 v0.0.24：关键词表必须补齐 —— v0.0.23 真机数据证明了漏词的代价：
//    `setMaxDuration:` / `setRepeats:` / `setSongPath:` 三个 setter **存在**，
//    却没出现在"setter 清单"里，因为旧表只有 sound/alert/tone/vibrat/source/system，
//    `duration`、`repeat`、`song`、`audio`、`config` 一个都没收。
//    后果：我据此以为"BBSound 上只有 6 个可写 setter"，
//    而实际上能写声音的字段比这多 —— 差一点又照着一份残缺清单去设计。
//    ⇒ 过滤器漏词 = 判据域小于变异域，这类错在本项目已经是第 N 次。
static BOOL NBDiagWanted(NSString *name) {
    static NSArray *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"sound", @"alert", @"tone", @"vibrat", @"source", @"system",
                 // v0.0.24 补：这些都是 BBSound 上的真实字段名
                 @"duration", @"repeat", @"song", @"audio", @"ringtone",
                 @"behavior", @"config", @"play"];
    });
    NSString *low = [name lowercaseString];
    for (NSString *k in keys) {
        if ([low containsString:k]) return YES;
    }
    return NO;
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
        NBDiagLogF(@"SD# %@ 类不存在", label);
        return;
    }
    unsigned int cnt = 0;
    objc_property_t *ps = class_copyPropertyList(c, &cnt);
    if (!ps) {
        NBDiagLogF(@"SD# %@ 属性表拿不到", label);
        return;
    }
    NBDiagLogF(@"SD# %@ 有 %u 个属性（[W]=可写 [R]=只读）", label, cnt);
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
            NBDiagLogF(@"SD# %@: %@", label, buf);
            [buf setString:@""];
        }
    }
    free(ps);
    if (buf.length) NBDiagLogF(@"SD# %@: %@", label, buf);
}

// dump 一个类的 setter —— "能不能填进去"的直接答案。
//
// 🔴🔴 v0.0.24 修一个会让判据说谎的 bug（上一版真机输出里就发生了）：
//    旧实现用 `buf.length` 同时表达两件事：「现在缓冲区还有没有字」和「有没有找到过」。
//    而 flush 会 `[buf setString:@""]` —— 于是「刚好在最后一个 setter 处凑满 110 字」时，
//    循环结束时 buf 是空的 ⇒ 落进 else 分支 ⇒ 打出
//        `SD# BBSound 的 setter: setVibrationPattern: … setRingtoneName:`
//        `SD# BBSound 声音相关 setter: 一个都没有`      ← 两行自相矛盾
//    真机就是这么打的（6 个 setter 加起来正好 111 字符）。
//    ⇒ **"有没有找到过"必须用独立变量记**，不能复用"缓冲区还剩多少"。
//      这和"改的是账本还是账本的读数"是同一类错：拿一个派生量当事实。
//
// onlyInteresting=NO ⇒ 不做关键词过滤，把**全部** set* 都打出来。
//    v0.0.24 起对 BBSound 用 NO：它的方法总数很少，而"漏看一个 setter"
//    的代价是一整个真机轮次（v0.0.23 就是因为过滤器漏了 duration/repeat/song，
//    误以为只有 6 个可写字段）。
static void NBDiagDumpSetters(Class c, NSString *label, BOOL onlyInteresting) {
    if (!c) return;
    unsigned int cnt = 0;
    Method *ms = class_copyMethodList(c, &cnt);
    if (!ms) return;
    NSMutableString *buf = [NSMutableString string];
    BOOL found = NO;                       // 🔴 事实变量，与 buf 无关
    for (unsigned i = 0; i < cnt; i++) {
        NSString *n = NSStringFromSelector(method_getName(ms[i]));
        if (![n hasPrefix:@"set"] || n.length < 5) continue;
        if (onlyInteresting && !NBDiagWanted(n)) continue;
        found = YES;
        [buf appendFormat:@"%@ ", n];
        if (buf.length >= NB_DIAG_FLUSH_AT) {
            NBDiagLogF(@"SD# %@ 的 setter: %@", label, buf);
            [buf setString:@""];
        }
    }
    free(ms);
    if (buf.length) NBDiagLogF(@"SD# %@ 的 setter: %@", label, buf);
    if (!found) NBDiagLogF(@"SD# %@ 的 setter: 一个都没有", label);
}

// dump 一个类的**全部方法名**。
//
// 🔴🔴 v0.0.24 新增，目的是找「工厂方法」。这一条是这一版的核心动作。
//    起因：v0.0.21/0.0.23 都是我们自己 alloc/init 一个空壳 BBSound 再手工填字段，
//    两版都失败。而真机数据里有一个**能正常响**的样本（系统自己的 BBSound），
//    它带着 `alertConfiguration=<TLAlertConfiguration>`，我们造不出来。
//    ⇒ 如果 BBSound 上本来就有 +soundWith… 之类的工厂，就该让系统替我们造，
//      而不是继续猜字段。**先看有没有工厂，再决定要不要继续手拼。**
//
// 🔴 两个容易忘的点：
//    ① 类方法必须用元类取：`class_copyMethodList(object_getClass(c), &n)`。
//       直接传 c 只会拿到实例方法，然后得出"没有工厂方法"的错结论 ——
//       这类"查法本身有 bug ⇒ 结论反向"的坑本项目管理已经踩过好几次。
//    ② 方法名一律用 NSStringFromSelector + method_getTypeEncoding 一起打：
//       只看名字不知道参数个数/类型，看不出"它接不接受一个 NSUInteger"。
static void NBDiagDumpMethods(Class c, NSString *label, BOOL classMethods) {
    if (!c) return;
    Class target = classMethods ? object_getClass(c) : c;
    if (!target) return;
    unsigned int cnt = 0;
    Method *ms = class_copyMethodList(target, &cnt);
    if (!ms) return;
    NBDiagLogF(@"SD# %@ 的%@方法共 %u 个 %@", label,
              classMethods ? @"类" : @"实例", cnt,
              classMethods ? @"(找工厂：+xxx 形式的最关键)" : @"");
    NSMutableString *buf = [NSMutableString string];
    for (unsigned i = 0; i < cnt; i++) {
        const char *tn = method_getTypeEncoding(ms[i]);
        [buf appendFormat:@"%c%@{%@} ",
                          classMethods ? '+' : '-',
                          NSStringFromSelector(method_getName(ms[i])),
                          tn ? [NSString stringWithUTF8String:tn] : @"?"];
        if (buf.length >= NB_DIAG_FLUSH_AT - 20) {
            NBDiagLogF(@"SD# %@ 的%@方法: %@", label,
                      classMethods ? @"类" : @"实例", buf);
            [buf setString:@""];
        }
    }
    free(ms);
    if (buf.length) {
        NBDiagLogF(@"SD# %@ 的%@方法: %@", label, classMethods ? @"类" : @"实例", buf);
    }
}

// dump ivars。
// 🔴 为什么要它：真机数据里 `alertType` / `toneIdentifier` / `ignoreRingerSwitch` 都是
//    只读 property（{…,R,…}）。KVC 写只读 property 时，会退化成**直接写 ivar**
//    （accessInstanceVariablesDirectly 默认 YES）。所以要写 toneIdentifier 这条路，
//    前提是能确认 ivar 名叫 `_toneIdentifier`。
//    另外，property 表不一定覆盖全部状态 —— 有些字段只在 ivar 里。
static void NBDiagDumpIvars(Class c, NSString *label) {
    if (!c) return;
    unsigned int cnt = 0;
    Ivar *ivs = class_copyIvarList(c, &cnt);
    if (!ivs) return;
    NBDiagLogF(@"SD# %@ 有 %u 个 ivar", label, cnt);
    NSMutableString *buf = [NSMutableString string];
    for (unsigned i = 0; i < cnt; i++) {
        const char *n = ivar_getName(ivs[i]);
        const char *t = ivar_getTypeEncoding(ivs[i]);
        [buf appendFormat:@"%@:%@ ", n ? [NSString stringWithUTF8String:n] : @"?",
                          t ? [NSString stringWithUTF8String:t] : @"?"];
        if (buf.length >= NB_DIAG_FLUSH_AT) {
            NBDiagLogF(@"SD# %@ 的 ivar: %@", label, buf);
            [buf setString:@""];
        }
    }
    free(ivs);
    if (buf.length) NBDiagLogF(@"SD# %@ 的 ivar: %@", label, buf);
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
            NBDiagLogF(@"SD# %@ 值: %@", label, buf);
            [buf setString:@""];
        }
    }
    free(ps);
    if (buf.length) NBDiagLogF(@"SD# %@ 值: %@", label, buf);
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
        NBDiagLog(YES, @"=== SD# 开始 dump 类结构（只读，一次性；v0.0.24 侦察造法）===");
        // BBSound 全量：它本来就是个声音对象，15 个属性每个都相关。
        // 🔴 上一版这几行被日志窗口吃了 —— 现在进文件，不会再丢。
        NBDiagDumpProps(snd, @"BBSound", NO);
        // 🔴 v0.0.24：setter 改成**不过滤**（onlyInteresting=NO）。
        //    v0.0.23 因为关键词表漏了 duration/repeat/song，
        //    把真实存在的 setMaxDuration:/setRepeats:/setSongPath: 全筛掉了，
        //    我却据此以为"只有一个都没有 / 只有 6 个"。BBSound 方法总数很少，全打不贵。
        NBDiagDumpSetters(snd, @"BBSound", NO);
        // 🔴 v0.0.24 的核心：找工厂方法。见 NBDiagDumpMethods 上面那段说明。
        NBDiagDumpMethods(snd, @"BBSound", YES);    // 类方法：+soundWith… 这类工厂
        NBDiagDumpMethods(snd, @"BBSound", NO);     // 实例方法：看有没有 copy/encode 之类
        NBDiagDumpIvars(snd, @"BBSound");
        NBDiagDumpProps(bul, @"BBBulletin", YES);

        // 🔴 v0.0.24：TonesLibrary 的 TLAlertConfiguration 才是 iOS 16 通知音的真身。
        //    真机样本：一个能正常响的 BBSound 带 `alertConfiguration=<TLAlertConfiguration>`，
        //    而我们的空壳这一项是 nil —— 这是目前唯一还没被排除的差异。
        //    ⇒ 必须把这个类的**属性 + 类方法 + ivar** 都摸清，才知道怎么造一个出来。
        //    类拿不到也无所谓（不链 TonesLibrary，只靠 NSClassFromString），打了就说明情况。
        Class tlc = objc_getClass("TLAlertConfiguration");
        if (!tlc) {
            NBDiagLog(NO, @"!!! SD# 拿不到 TLAlertConfiguration 类（TonesLibrary 没加载？）");
        } else {
            NBDiagDumpProps(tlc, @"TLAlertConfiguration", NO);
            NBDiagDumpSetters(tlc, @"TLAlertConfiguration", NO);
            NBDiagDumpMethods(tlc, @"TLAlertConfiguration", YES);
            NBDiagDumpIvars(tlc, @"TLAlertConfiguration");
        }
        NBDiagLog(NO, @"=== SD# dump 结束 ===");
    } @catch (__unused NSException *e) {
        NBDiagLog(NO, @"!!! SD# dump 抛异常（已忽略，不影响功能）");
    }
}

+ (void)noteForeignSoundIfAny:(id)obj stage:(NSString *)stage {
    if (!obj) return;
    [self dumpClassOnce];

    id s = nil;
    @try {
        s = [obj valueForKey:@"sound"];
    } @catch (__unused NSException *e) {
        return;
    }
    if (!s) return;              // 绝大多数通知都是 nil（v0.0.20 PROBE 已量到）

    // 🔴🔴 v0.0.24：不再只抓**第一个**，改成按"长相"去重、最多收 4 个**不同**的样本。
    //    上一版只抓一次，结果抓到的那一个恰好是我们唯一见过的形态，
    //    "别的形态长什么样"完全没数据 —— 而这一版最需要的正是**多样性**：
    //    soundType 到底有哪几个取值、songPath / ringtone / alertConfiguration
    //    各在什么情况下被用到。只有一个样本就判不了这些。
    //    为什么不在每个通知上都打：日志/文件空间有限，且同一种形态重复打没有增量信息。
    static NSMutableSet *seen = nil;
    static NSUInteger kept = 0;
    if (!seen) seen = [NSMutableSet set];
    if (kept >= 4) return;

    // 用"关键字段组合"当指纹 —— 不能只用类名（同一个类会覆盖所有形态）。
    NSString *sig = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@",
                     NBDiagGet(s, @"soundType"), NBDiagGet(s, @"systemSoundID"),
                     NBDiagGet(s, @"toneIdentifier"), NBDiagGet(s, @"songPath"),
                     NBDiagGet(s, @"ringtoneName"), NBDiagGet(s, @"alertType")];
    if ([seen containsObject:sig]) return;
    [seen addObject:sig];
    kept++;

    @try {
        NBDiagLog(NO, @"SD# ★ 抓到非 nil 的 sound 第 %lu 种（这是最好的对照）stage=%@ cls=%@",
                  (unsigned long)kept, stage ?: @"?", NSStringFromClass([s class]));
        NBDiagDumpValues(s, @"该 sound 对象");
        // 🔴 关键：把它的 alertConfiguration 也整份 dump 出来。
        //    真机样本里，能正常响的那个 BBSound 这一项非 nil，我们的空壳是 nil
        //    ⇒ 这是目前唯一还没被排除的差异，必须看清它里面到底装了什么。
        id cfg = nil;
        @try {
            cfg = [s valueForKey:@"alertConfiguration"];
        } @catch (__unused NSException *e) {
            cfg = nil;
        }
        if (cfg) {
            NBDiagLogF(@"SD# ★ 它的 alertConfiguration cls=%@（这就是 TonesLibrary 的真身）",
                      NSStringFromClass([cfg class]));
            NBDiagDumpValues(cfg, @"该 alertConfiguration");
        } else {
            NBDiagLogF(@"SD# 这个 sound 的 alertConfiguration 也是 nil"
                          @"（说明还有别的形态能响，不能只盯着它）");
        }
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
    // 🔴🔴 v0.0.24：①②两行**改从 sound 对象读**，不再从 bulletin 读。
    //    真机数据说明上一版这里全是废读数：`alert=!无键 type=!无键 sid=!无键` ——
    //    soundType / systemSoundID / alertType 这三个键在 BBBulletin 上**根本不存在**
    //    （它们属于 BBSound）。我当时以为是"值没读出来"，白占了两行日志的位置。
    //    ⇒ 判据要读"那个字段真正属于谁"，不是"我手上正好有哪个对象"。
    // ⚠️ playSound 保留，但结论已经变了：真机上**连能正常响的通知**也是 playSound=0
    //    （用户明确听到原声的那几条也在内）⇒ 它**不是**出声的闸门，只是一条参考量。
    NBDiagLog(NO, @"SD# %@ 发后① playSound=%@（实测非闸门）", st,
              NBDiagGet(obj, @"playSound"));
    if (s) {
        NBDiagLog(NO, @"SD# %@ 发后② sound: type=%@ sid=%@ tone=%@ alertType=%@ cfg=%@", st,
                  NBDiagGet(s, @"soundType"), NBDiagGet(s, @"systemSoundID"),
                  NBDiagGet(s, @"toneIdentifier"), NBDiagGet(s, @"alertType"),
                  NBDiagGet(s, @"alertConfiguration"));
    } else {
        NBDiagLog(NO, @"SD# %@ 发后② sound=nil（这条通知本来就没声音）", st);
    }

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
