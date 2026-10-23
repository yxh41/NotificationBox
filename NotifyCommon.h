#ifndef NotifyCommon_h
#define NotifyCommon_h

#import <Foundation/Foundation.h>

// 🔴 共享常量：tweak 与盒子 App 必须一致（别各写一份）
#define NOTIFYBOX_BUNDLE_ID   @"com.yxh41.notifybox"
#define NOTIFYBOX_APP_BUNDLE  @"com.yxh41.notifybox.app"
// 🔴 roothide 沙盒特殊：tweak(跑在 SpringBoard) 与 App 都要能读写的路径。
//    真机已确认：盒子 App 能在 /var/mobile/Library/NotifyBox/ 建目录、写探针文件、读 sqlite。
#define NOTIFYBOX_DB_PATH     @"/var/mobile/Library/NotifyBox/notifybox.sqlite"
#define NOTIFYBOX_LOG_PATH    @"/var/mobile/Library/NotifyBox/tweak.log"

// ---------- 设置存储 ----------
// 🔴🔴 v0.0.8 起：设置的**唯一权威位置**是下面这个文件，不再用 Preferences 域。
//   两条理由，都是踩出来的：
//   ① PreferenceLoader 一装进包，设置 App 就进不去（两次复现），而且**没有崩溃日志**
//      ⇒ 不是闪崩，是挂起/被跳过 ⇒ 在这条路上盲调没有意义，已彻底弃用该通道。
//   ② /var/mobile/Library/Preferences/<id>.plist 归 cfprefsd 管：
//      App 直接写文件，cfprefsd 可能拿自己的缓存盖回去，出现「改了没生效」的幽灵现象。
//   新方案：盒子 App 写、tweak 读，**单一写入者、不经过 cfprefsd**。
#define NOTIFYBOX_SETTINGS_PATH @"/var/mobile/Library/NotifyBox/settings.plist"

// 旧路径：只为兼容 v0.0.7 及以前已经填过的值（只读兜底，不再写）
#define NOTIFYBOX_PREFS_PATH  @"/var/mobile/Library/Preferences/com.yxh41.notifybox.plist"

// ---------- 朗读（v0.0.12） ----------
// 🔴 设置键名只在这里定义一份：App 写、tweak 读，任何一边拼错就是「开了不生效」，
//    而这种错在运行时完全是静默的（读到一个不存在的键 = nil = 关）。
#define NB_KEY_SPEAK_ENABLED  @"speakEnabled"    // NSNumber(BOOL) 或 "1"/"0"
#define NB_KEY_SPEAK_APPS     @"speakApps"       // 数组或 "a,b"，空/缺失 = 全部 App
#define NB_KEY_SPEAK_VOICE    @"speakVoice"      // AVSpeechSynthesisVoice.identifier，空 = 跟随系统
#define NB_KEY_SPEAK_RATE     @"speakRate"       // NSNumber(float)，缺失 = 系统默认语速

// ---------- 延迟推送（v0.0.14） ----------
// 语义：命中的通知**不立即弹出**，延后 N 秒再交给 BBServer 的发布方法。
// 🔴 0 / 缺失 = 关闭（默认关闭，因为它是唯一会**改变通知到达时间**的功能，风险最高）。
// 🔴 秒数上限在主判定函数里夹到 600 秒：用户手填个 86400 就等于让通知永远不出现。
#define NB_KEY_DELAY_SECONDS  @"delaySeconds"    // NSNumber 或 "5"，0/缺失 = 关闭
#define NB_KEY_DELAY_APPS     @"delayApps"       // 数组或 "a,b"，空/缺失 = 全部 App

// 🔴🔴 延迟推送的崩溃自愈标记（v0.0.15）。
//    延迟实现是"把 bulletin/request 攒在 block 里，N 秒后再调原发布方法"。
//    这条路上有两个我们控制不了的前提：
//      ① 那个对象在 N 秒后还能不能被安全使用（调用方可能已经把它作废/消费掉了）
//      ② 从别的队列/线程再去调一次发布，是否违反 SpringBoard 内部的前置条件
//    2026-10-21 15:51:30 实测：开了延迟之后 SpringBoard 直接
//        EXC_BREAKPOINT (SIGTRAP) + "Swift runtime trapped"（force-unwrapped nil /
//        array index out of range / failed precondition）⇒ 安全模式。
//    所以在延迟路径上复用「朗读自毁保护」那套：调度前写 start，原方法返回后写 done。
//    下次进程启动看到 start 而没有 done ⇒ 上次就是崩在延迟里 ⇒ 自动把 delaySeconds 清掉。
//    这样**以后每次实验最多崩一次**，不会陷入崩溃循环。
#define NOTIFYBOX_DELAY_GUARD_PATH @"/var/mobile/Library/NotifyBox/.delay_guard"

// ---------- 免打扰时段（v0.0.21）----------
// 语义：命中的通知**不弹**（同黑名单），但照常记进盒子。
// 这是 v0.0.19 删掉「延迟推送」之后给用户的**安全替代品** ——
// 延迟想解决的其实是"别在这个时间点吵我"，而"延迟"必须改系统的发布时间才能实现
// （两次撞死：跨队列 SIGTRAP / 通知永远到不了）；"这个时段直接不弹"则是**我们自己的判断**，
// 不碰 BB 内部、不改任何系统字段 ⇒ 从根上没有那两类风险。
// 🔴 时间一律存**分钟数**（0~1439），不存 "23:00" 字符串：
//    字符串要靠 App 和 tweak 各自解析一遍，两边只要差一点就是"填了不生效"，
//    而这种错完全静默（读到 nil = 关闭）。
#define NB_KEY_DND_ENABLED  @"dndEnabled"    // NSNumber(BOOL) 或 "1"/"0"
#define NB_KEY_DND_START    @"dndStart"      // NSNumber 分钟，例如 23*60=1380
#define NB_KEY_DND_END      @"dndEnd"        // NSNumber 分钟，可以小于 start（跨零点）
#define NB_KEY_DND_APPS     @"dndApps"       // 数组或 "a,b"，空/缺失 = 全部 App

// ---------- 按 App 换提示音（v0.0.21，实验）----------
// 🔴 实验性质，默认关闭，而且**必须显式选 App 才生效**。
//    原因（真机 PROBE 数据，2026-10-23）：
//      · `PROBE#1/2/3` 全是 `sound=nil` ⇒ 默认提示音根本不带 BBSound 对象；
//      · `BBSound 类方法共 1 个，其中相关 0 个` ⇒ **没有工厂方法**，只能自己 alloc/init 再填字段；
//      · `alertType` 是只读（R），可写的只有 `soundType` / `systemSoundID` / `vibrationIdentifier`。
//    ⇒ 也就是说这个功能在**造一个系统对象**，造坏了的结果是"这条通知不出声"（不是崩溃）。
//    所以：默认关、必须点名 App、每次尝试都留 SOUND# 留痕、失败自动回退到默认声音。
#define NB_KEY_SOUND_ENABLED @"soundEnabled"  // NSNumber(BOOL)
#define NB_KEY_SOUND_ID      @"soundID"       // NSNumber(int)，1000~1035 是系统提示音区段（v0.0.28 起 = **默认音**）
// 🔴🔴 v0.0.28：`soundApps` 降级为**只读的历史格式**。现在的权威存储是下面的 NB_KEY_SOUND_MAP。
//    这个键只剩三个读点、**零个写点**：
//      ① App 启动时的迁移（migrateSoundMapIfNeeded，读完会把它删掉）；
//      ② SpringBoard 侧的旧格式回退（soundVerdictForBundle 的 ② 分支，只在 map 为空时走）；
//      ③ 设置页副标题（用来显示"旧名单 N 个，尚未迁移"）。
//    ⛔ 不要再给它加任何写入通道 —— 判定在 map 非空时根本不读它，
//    写进去的东西没人看，表现就是"界面上选了 App，却一点反应都没有"。
#define NB_KEY_SOUND_APPS    @"soundApps"     // 数组或 "a,b"；**空 = 不生效**（与其它名单语义相反）

// 换提示音的崩溃自愈标记。
// 🔴 v0.0.21 这一版**写法和 v0.0.15 的延迟 guard 不同**，因为那个写法骗过人：
//    v0.0.15 只写 start、从不写 done（那版延迟是关的），于是文件永久停在 start，
//    从 v0.0.16 起每次启动都误报"上次崩在延迟里"，还谎称"已自动删掉设置"。
//    ⇒ 这一次 write(start) / write(done) **配对出现在同一个函数里**（NotifyFilter），
//      读取侧必须**回读确认**自己真的把开关关掉了，再打日志。
#define NOTIFYBOX_SOUND_GUARD_PATH @"/var/mobile/Library/NotifyBox/.sound_guard"

// 🔴 v0.0.23：换提示音的诊断**落盘**。
//
// 为什么必须落盘，而不是继续用日志：v0.0.22 那一轮，
//   `=== SD# 开始 dump 类结构 ===` 和 `SD# BBSound: …` 这几行**已经被挤出 50 行窗口**，
//   用户截图里只剩后面的 `SOUND#` / `发后①②` / `+0.4s`。
//   而"BBSound 上到底有哪些属性、哪些可写"正是定位问题的唯一依据 ——
//   结果数据打出来了、却已经滚没了，等于白跑一轮。
//
// 口径：
//   · 这个文件**每次进程启动覆盖一次**（结构性 dump 只打一次），不做追加，
//     否则会无限长；每次通知级的诊断行追加在同一份里，App 里能整份看到。
//   · 路径与 settings.plist 同目录，App 侧直接读，不用 Filza。
#define NOTIFYBOX_SOUND_DIAG_PATH @"/var/mobile/Library/NotifyBox/sound_diag.log"

// ---------- 自定义音频文件（v0.0.26）----------
// 语义：`soundFile` 非空 ⇒ 播**这个文件**；为空 ⇒ 退回上面的 `soundID`（1000~1035 系统音）。
// 🔴 为什么加这一条：v0.0.25 真机验证通过之后（用户："是我们的提示音"），
//    整条链路（闸门自播 + return NO 掐原声）已经被证明是对的，
//    剩下的唯一硬限制是 **只能从 30 来个系统提示音里挑**。用户想用自己的音频。
//
// 🔴 存的是**纯文件名**，不是路径。理由：
//   ① 目录是我们定的（下面那个常量），存路径等于让用户在设置里能指定任意路径；
//   ② `soundFile` 是从 settings.plist 读进来的**外部输入**，一旦含 `../` 就能让
//      SpringBoard 去读/播任意文件 —— 净化（NBIsSafeSoundFileName）必须做在这里。
#define NB_KEY_SOUND_FILE @"soundFile"

// 音频目录。tweak（SpringBoard 进程）和盒子 App 都要能读，所以放在数据区。
// 🔴 不能放 /var/jb/...：那是 roothide 的**代码/框架**前缀，不是数据；
//    而 /var/mobile/Library/NotifyBox/ 已被真机确认两个进程都能读写（settings.plist 就在这）。
// 🔴 目录**不由我们自动创建**：App 侧负责建（它一定能写），tweak 侧只读。
//    SpringBoard 里偷偷建目录是没必要的副作用，而且失败时很吵。
#define NOTIFYBOX_SOUND_DIR  @"/var/mobile/Library/NotifyBox/Sounds"

// 认哪些扩展名。判断一律**大小写不敏感**（用户从别处拷来的可能是 .MP3）。
// 🔴 AudioServices 那条路（已验证的出声通道）原生支持 caf/wav/aiff；
//    mp3/m4a/aac 要靠 AVAudioPlayer 兜底 —— 两条路的区别见 NotifyFilter.m。
#define NOTIFYBOX_SOUND_EXTS @[@"caf", @"wav", @"aiff", @"aif", @"mp3", @"m4a", @"m4r", @"aac", @"flac", @"ogg"]

// 🔴🔴 文件名净化：只做"拒绝"，不做"改名"。
//    改名会让"我明明放了这个文件、界面里显示的名字却不是它"这种诡异现象出现；
//    拒绝 + 留痕才能让人知道为什么没生效。
static inline BOOL NBIsSafeSoundFileName(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) return NO;
    NSString *t = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return NO;
    if (t.length > 120) return NO;                        // 文件名长过 120 基本就是异常数据
    if ([t containsString:@"/"]) return NO;                // 路径分隔符
    if ([t containsString:@"\\"]) return NO;               // Windows 习惯，也挡一下
    if ([t containsString:@".."]) return NO;               // 相对路径穿越
    if ([t hasPrefix:@"."]) return NO;                     // 隐藏文件 / "." ".."
    if ([t containsString:@"\0"]) return NO;
    return YES;
}

// 文件名 → 绝对路径。名字不合法时返回 nil（调用方据此判"配置错"）。
static inline NSString *NBSoundFilePath(NSString *name) {
    if (!NBIsSafeSoundFileName(name)) return nil;
    NSString *t = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return nil;
    return [NOTIFYBOX_SOUND_DIR stringByAppendingPathComponent:t];
}

// 扩展名是不是我们认的音频格式（大小写不敏感）。
static inline BOOL NBIsSoundFileExt(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || !name.length) return NO;
    NSString *e = [[name pathExtension] lowercaseString];
    if (!e.length) return NO;
    return [NOTIFYBOX_SOUND_EXTS containsObject:e];
}

// ---------- 提示音最长播放秒数（v0.0.27）----------
// 语义：**0 = 不限**；键缺失 = 默认 8 秒。
//
// 🔴 为什么要加这个（实测出来的不一致，不是拍脑袋）：
//   · A 通道（`AudioServicesPlaySystemSound`）**没有 stop API** —— 只有
//     `AudioServicesDisposeSystemSoundID` 能停，而那会把资源一起释放掉（下次还得重建），
//     所以 A 通道的时长**我们控制不了**，硬上限是系统给的 **30 秒**；
//   · B 通道（`AVAudioPlayer`）能 `stop`，想播多久播多久。
//   ⇒ 同一份设置、同一个文件，wav 响 30 秒、mp3 响到底 —— 用户只会觉得"是不是没生效"。
//
// 解法不是"给 A 加个定时器"（做不到），而是**按能不能播完来选通道**：
//   文件时长 ≤ 上限 ⇒ 走 A（已验证通道，零 session 副作用）；
//   文件时长 > 上限 ⇒ 走 B（因为只有它能截断）。
// 这样"最多响 N 秒"对所有格式都成立，而绝大多数短提示音仍然走那条验证过的路。
#define NB_KEY_SOUND_MAX_SEC    @"soundMaxSec"   // NSNumber 或 "8"，0 = 不限
#define NB_DEFAULT_SOUND_MAX_SEC 8.0             // 键缺失时的默认
#define NB_SOUND_MAX_SEC_CEIL   120.0            // 手填上限，防止有人写 86400

// A 通道（AudioServicesPlaySystemSound）的系统硬上限：超过 30 秒的音频它只播前 30 秒。
// 🔴 v0.0.27 起这个数**不再是一个要跟用户解释的局限**，而是一条选路依据：
//    时长 > 30 秒一律不走 A（走 B，B 想播多久播多久）⇒ 界面上不会出现"我设了 60 秒只响 30 秒"。
//    ⚠️ 30 这个数来自 AudioServices 的文档行为，本机没有单独验证过 ——
//    真机若发现更短，第一个症状会是"长 wav 只响一小段"，那时把这里调小即可（选路逻辑不用动）。
#define NB_A_CHANNEL_MAX_SEC    30.0

// 「最长播放秒数」的**唯一**解读口径（App 与 tweak 两边都编进各自的二进制）。
// 🔴 与 NBBoolValue 同一个道理：两边各写一份解读，就会出现"界面显示 8 秒、tweak 当成不限"
//    这种任何保存期检查都发现不了的错。
// 语义：缺失/空/负数/不是数 ⇒ 默认 8 秒；0 ⇒ **不限**；> 120 ⇒ 夹到 120。
static inline double NBSoundMaxSecFromValue(id v) {
    if (!v) return NB_DEFAULT_SOUND_MAX_SEC;
    double n = 0;
    if ([v isKindOfClass:[NSNumber class]]) {
        n = [(NSNumber *)v doubleValue];
    } else if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!s.length) return NB_DEFAULT_SOUND_MAX_SEC;
        // 🔴 手填的值必须**严格**校验：`[s doubleValue]` 对 "abc" 返回 0，
        //    而 0 的语义是"不限" ⇒ 一个手滑就会变成"播到底"。宁可用默认值。
        NSScanner *sc = [NSScanner scannerWithString:s];
        if (![sc scanDouble:&n] || !sc.isAtEnd) return NB_DEFAULT_SOUND_MAX_SEC;
    } else {
        return NB_DEFAULT_SOUND_MAX_SEC;
    }
    if (n < 0) return NB_DEFAULT_SOUND_MAX_SEC;           // 负数当没填
    if (n > NB_SOUND_MAX_SEC_CEIL) return NB_SOUND_MAX_SEC_CEIL;
    return n;                                            // 0 = 不限
}

// ---------- v0.0.28：按 App 分配提示音 ----------
// 语义：`soundMap` = { bundleId : { "file": 文件名 } 或 { "id": 1000~1035 } }
//   · **有记录 ⇒ 这个 App 换音**，用记录里的那个音（文件优先于 id，与全局同口径）；
//   · 没有记录 ⇒ 不换音。⇒ **名单就是 map 的键**，`soundApps` 不再需要。
//
// 🔴 为什么不再用「一份名单 + 一个全局音」：
//    那是"要么全换、要么不换"。用户第二个需求一定是"微信用 A、QQ 用 B"，
//    而现有结构连"两个 App 两个音"都表达不了 —— 这才是真正缺的东西。
//
// 🔴 旧格式（`soundApps` 名单 + 全局 `soundFile`/`soundID`）**仍然认**，作为回退：
//    · App 侧：打开时做一次迁移（把名单里每个 App 物化成一条记录，然后**删掉 `soundApps`**）；
//    · SpringBoard 侧：**只读、不迁移** —— 通知路径上不写盘（写盘是用户的动作，不是通知的副作用）。
//    迁移必须删 `soundApps`，否则"我在界面上删了这个 App，它还在响"这种鬼会一直存在。
#define NB_KEY_SOUND_MAP        @"soundMap"
#define NB_KEY_SOUND_ENTRY_FILE @"file"
#define NB_KEY_SOUND_ENTRY_ID   @"id"

// ---------- v0.0.29：连续通知不叠加 ----------
// 「这一声归谁」的标识：通知用 bundleId，试听用这个常量。
//
// 🔴 为什么试听要单独一个 owner、而不复用 bundleId：
//    ① 试听**没有** bundleId（设置页试听是全局的）；
//    ② 试听之间也要互斥 —— 连点两次"试听"，两个长音一起放会很难听；
//    ③ 试听与通知**不**互斥是故意的：用户在配置时不该因为来了条通知就听不到自己在听的那个音。
//    前缀用 `@` 是因为 bundleId 不可能以 `@` 开头，撞不上真实 App。
#define NB_SOUND_OWNER_PREVIEW  @"@preview"

// 🔴 「一组 bundle id」的读法只在这里写一份。
//    历史数据是**逗号分隔字符串**（v0.0.12 及以前是输入框），
//    新数据是**数组**（v0.0.13 的选择器写）。
//    两种都必须认 —— 否则老用户升级后就是「我明明配了白名单，怎么全放行了」，
//    而且这种错完全静默：设置文件在、内容在，就是解析不出来。
static inline NSArray<NSString *> *NBStringArray(id v) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    if ([v isKindOfClass:[NSArray class]]) {
        for (id e in (NSArray *)v) {
            if (![e isKindOfClass:[NSString class]]) continue;
            NSString *t = [(NSString *)e stringByTrimmingCharactersInSet:ws];
            if (t.length) [out addObject:t];
        }
    } else if ([v isKindOfClass:[NSString class]]) {
        for (NSString *p in [(NSString *)v componentsSeparatedByString:@","]) {
            NSString *t = [p stringByTrimmingCharactersInSet:ws];
            if (t.length) [out addObject:t];
        }
    }
    return out;
}

// 🔴🔴 朗读自毁保护用的标记文件。
//    朗读要跑 ARSpeechSynth（AVSpeechSynthesizer），运行在 SpringBoard 里 ——
//    这是整个插件里**唯一**会去碰音频子系统的动作，也是最可能把 SpringBoard 拖崩的地方。
//    一旦崩，用户看到的是连续安全模式，而「关掉朗读」这个动作本身要做进 App 里、
//    可 App 又打不开 ⇒ 死锁。
//    解法：朗读**开始前**写入 "start"，真正播出后写入 "done"。
//    下次进程启动时若看到 "start" 而没有 "done" ⇒ 上次就是崩在朗读里
//    ⇒ 直接把 speakEnabled 写成 NO 并留日志。崩溃自愈，不依赖用户操作。
#define NOTIFYBOX_SPEAK_GUARD_PATH @"/var/mobile/Library/NotifyBox/.speak_guard"

// ---------- 统一日志 ----------
// 🔴 v0.0.12：原来 Tweak.x 里有份 static NBLog，新加的 NotifySpeaker/NotifyProbe 够不着。
//    **复制一份日志函数**是最差解（两份轮转逻辑迟早走岔），所以把实现沉到 NotifyStore.m
//    （这个文件 tweak 与盒子 App 都编译），头里只留声明。
//    轮转策略不变：超过 512 KB 切成 <path>.1，覆盖上一份。
void NBSharedLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

// 🔴 统一读入口：两个进程（SpringBoard 里的 tweak、盒子 App）都用它，避免各写一份逻辑。
//    判定口径 = **文件存在即权威**（哪怕内容是空字典）。
//    否则用户在设置页把选项全清空后，这里会因为 d.count==0 回落到旧 Preferences 域，
//    出现「我明明清了，怎么又生效了」——清空必须是能生效的动作。
static inline NSDictionary *NBLoadSettings(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:NOTIFYBOX_SETTINGS_PATH];
    if ([d isKindOfClass:[NSDictionary class]] && d) return d;
    d = [NSDictionary dictionaryWithContentsOfFile:NOTIFYBOX_PREFS_PATH];
    if ([d isKindOfClass:[NSDictionary class]] && d) return d;
    return @{};
}

// 🔴 布尔型设置值的统一解读。
//    为什么要统一：App 用 @(YES) 写进去的是 NSNumber，但手改 plist 的人常写成 "1"/"true"。
//    **两边各写一份解读逻辑**是最危险的做法 —— App 认 "true"、tweak 只认 NSNumber 时，
//    用户会看到"开关明明是开的、功能就是不生效"，而且任何保存期检查都发现不了。
static inline BOOL NBBoolValue(id v) {
    if (!v) return NO;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [[(NSString *)v lowercaseString]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return ([s isEqualToString:@"1"] || [s isEqualToString:@"yes"]
                || [s isEqualToString:@"true"] || [s isEqualToString:@"on"]);
    }
    return NO;
}

#endif /* NotifyCommon_h */
