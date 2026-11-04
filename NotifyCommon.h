#ifndef NotifyCommon_h
#define NotifyCommon_h

#import <Foundation/Foundation.h>

// 🔴 共享常量：tweak 与盒子 App 必须一致（别各写一份）
#define NOTIFYBOX_BUNDLE_ID   @"com.yxh41.notifybox"
#define NOTIFYBOX_APP_BUNDLE  @"com.yxh41.notifybox.app"

// ---------- v0.0.137：数据目录回到**编译期常量**，不再运行时解析 ----------
// 三版三次反复，把结论钉在这里：
//   v0.0.135 及以前：写死 `/var/mobile/Library/NotifyBox`，能跑，但属主偶尔被 root 占掉。
//   v0.0.136：改成「App 容器优先」的运行时解析 —— **撤掉，因为它建立在一个错假设上**：
//       假设「tweak 有 root 权限，能写进 App 容器」。
//       事实：被注入的两个进程里，**只有 backboardd 是 root**；SpringBoard 是 mobile、
//       而且**受沙箱约束**。它既列不出 `/var/mobile/Containers/Data/Application`
//       （读不了别的 App 容器的父目录），更写不进别人的容器 —— 那是**那个 App 的**
//       沙箱 profile 才放行的东西。
//     ⇒ 后果（2026-11-04 真机自检实测到的形状）：
//          App 这边：目录=自己的容器，可写、写入成功、DB/设置都在，**记录数 0**；
//          SpringBoard 这边：扫不到容器 ⇒ 落回老路径 ⇒ **记到别处去了**；
//          而 App 只在**自己的**目录里找 `.tweak_ctor` ⇒ 显示「tweak 从未注入」。
//       也就是：两个进程各算各的路径（split-brain），加上一个**说得比证据宽**的判据。
//   v0.0.137：**路径必须是常量** —— 常量不可能被两个进程算出两个答案。
//     老路径唯一的真问题是**属主**，而属主**只有 root 能改** ⇒ 交给 backboardd 的 ctor
//     做 chown(501:501)，并且 root 一律不许 createDirectory（见 NBCanWriteSharedFiles）。
//
// ⚠️ 这三个宏是**编译期字面量**，不许再写成 `[NBDataDir() …]` 之类的运行时表达式：
//    路径一旦能在运行时变，就一定会出现「写在一个地方、读在另一个地方」，而那种 bug
//    在日志里长得和「功能没生效」一模一样（本次查了整整两天）。
#define NOTIFYBOX_LEGACY_DIR  @"/var/mobile/Library/NotifyBox"
#define NOTIFYBOX_DB_NAME     @"notifybox.sqlite"
#define NOTIFYBOX_LOG_NAME    @"tweak.log"
#define NOTIFYBOX_SETTINGS_NAME @"settings.plist"

// 数据目录 = 常量。保留这个函数只为一个用途：**打日志/诊断时打印它**，
// 以及让"目录只有一个"这件事在代码里有名字。它不许参与任何决策。
NSString *NBDataDir(void);
// 盒子 App 的容器 Documents —— **只给诊断看，绝不当写入路径**（理由见上方长注释）。
// App 进程里是直接问系统拿到的自己的容器；其它进程扫容器 metadata 得到（扫不到返回 nil）。
NSString *NBAltDataDir(void);
// 🔴🔴 **uid==0 的进程一律不许碰共享数据目录**（本 tweak 同时注入 backboardd，它以 root 跑）。
//    root 一旦执行 createDirectoryAtPath:，目录就归 root 所有 ⇒ 盒子 App(mobile) 从此
//    读不进也写不进 —— 现场是「记录全没了 / 设置存不住」，而 errno 只给一个 EPERM。
//    这里是那条规定**唯一的实现**，Tweak.x 的 ctor 与两个日志函数都调它。
BOOL     NBCanWriteSharedFiles(void);
// 属主自愈的**非 root 那条腿**：目录存在但当前身份写不进、且目录**为空**时，删掉重建。
//   能改属主的只有 root（Tweak.x 的 ctor），这条是不依赖 root 注入的兜底。
//   返回 YES = 真的动手且成功了。**非空目录绝不动**（里面有记录就是用户的全部历史）。
BOOL     NBHealDataDirOwnership(void);

#define NOTIFYBOX_DB_PATH       [NOTIFYBOX_LEGACY_DIR stringByAppendingPathComponent:NOTIFYBOX_DB_NAME]
#define NOTIFYBOX_LOG_PATH      [NOTIFYBOX_LEGACY_DIR stringByAppendingPathComponent:NOTIFYBOX_LOG_NAME]

// ---------- 设置存储 ----------
// 🔴🔴 v0.0.8 起：设置的**唯一权威位置**是下面这个文件，不再用 Preferences 域。
//   两条理由，都是踩出来的：
//   ① PreferenceLoader 一装进包，设置 App 就进不去（两次复现），而且**没有崩溃日志**
//      ⇒ 不是闪崩，是挂起/被跳过 ⇒ 在这条路上盲调没有意义，已彻底弃用该通道。
//   ② /var/mobile/Library/Preferences/<id>.plist 归 cfprefsd 管：
//      App 直接写文件，cfprefsd 可能拿自己的缓存盖回去，出现「改了没生效」的幽灵现象。
//   新方案：盒子 App 写、tweak 读，**单一写入者、不经过 cfprefsd**。
// 🔴 v0.0.137：位置跟库一起回到老路径（同一个后端，同一个字符串）。
//   "单一写入者"这条规则从头到尾没变，变的只是位置 —— 而位置必须是常量，理由见上。
#define NOTIFYBOX_SETTINGS_PATH [NOTIFYBOX_LEGACY_DIR stringByAppendingPathComponent:NOTIFYBOX_SETTINGS_NAME]

// 旧路径：只为兼容 v0.0.7 及以前已经填过的值（只读兜底，不再写）
#define NOTIFYBOX_PREFS_PATH  @"/var/mobile/Library/Preferences/com.yxh41.notifybox.plist"

// ---------- 记录上限（v0.0.45） ----------
// 🔴🔴 这两个数和 `listLimit`（列表一次最多取 2000 条）必须**能放在一起解释**：
//    用户填的上限决定"库里最多留多少"，列表决定"一屏能翻到多少"。
//    旧代码的上界是 100000 —— 一个"反正没人会填"的占位，后果是用户可以设一个
//    **列表永远显示不完**的上限，库里常年堆着几千条只能靠导出才看得见的记录。
//    ⇒ 上界改成 20000：仍然远大于列表上限（有存档价值），但填大了能在界面上说清代价。
#define kNBRMinRecords        100
#define kNBRMaxRecordsHardCap 20000

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

// v0.0.32：来通知时把**别人正在播的音乐压低**（AVAudioSessionCategoryOptionDuckOthers）。
//
// 🔴 只对 B 通道（AVAudioPlayer，长音）有效。A 通道走 AudioServicesPlaySystemSound，
//    它自己不管 AVAudioSession，所以短音永远是"混着播、不压别人"。这一条必须写在界面上，
//    否则用户打开开关后短音照旧（因为他配的就是短音），只会得出"开关没用"的结论。
//
// 🔴 缺省 = **关**：默认仍是 v0.0.27~v0.0.31 验收过的 Ambient + MixWithOthers（与音乐共存、互不打扰）。
//    这个开关只负责"多压一层"，**绝不改"能不能共存"** —— 共存那条已经上线验收过，不能赌。
//
// 🔴 压低的恢复**依赖 v0.0.30 的交还**：`releaseAudioSessionIfIdle` 里那句
//    `setActive:NO withOptions:NotifyOthersOnDeactivation`。没有那条，被压低的音乐永远不会自己回来
//    （症状：听歌时来一条通知，之后音乐一直闷着，直到用户手动调音量或切歌）。
//    ⇒ 动这个开关之前先确认交还那条路还在（源码判据 a02/a06 覆盖）。
#define NB_KEY_SOUND_DUCK_OTHERS @"soundDuckOthers"   // NSNumber(BOOL) 或 "1"/"0"，缺省 = 关

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
// v0.0.31：entry 里**可选**的「这个 App 最长播多少秒」。
//
// 🔴 三条语义，写错任何一条都会静默改变行为：
//   ① **键不存在 = 跟随全局 soundMaxSec**（不是 0）。所以老 entry 天然兼容，不需要迁移。
//   ② **0 是合法值 = 不限**。⇒ 判「有没有设」只能看「键在不在」，绝不能看「值是否为 0」。
//   ③ 值非法（负数 / 非数字 / 超 NB_SOUND_MAX_SEC_CEIL）⇒ 退化方向是**跟随全局**，
//      不是夹到默认 8 秒 —— 因为 entry 的父级（全局）已经有值了，
//      夹成 8 会把"我明明全局配了 30 秒"改成 8，属于**静默改语义**。
//      （对比：全局那个 NBSoundMaxSecFromValue 是"夹取"，因为它没有父级可退化。）
#define NB_KEY_SOUND_ENTRY_MAXSEC @"maxSec"

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

// ---------- v0.0.51：连记录都不要（per-App 名单） ----------
// 语义：命中的 App **连记录都不落库**（闸门加在 Tweak.x 的 recordWithBundle: 之前），
//   但**不影响呈现** —— 过滤/替换/换声/朗读照跑，通知照弹。
// 🔴 它和黑名单（blacklist）是两件事，**不要合并**：
//    黑名单拦的是"呈现"——记录早已落库，盒子里仍看得到（v0.0.8 立的口径：
//    「记录永远存原始通知，过滤只改屏幕呈现，不污染记录」）；
//    这个名单拦的是"记录"本身，用户要的是"这个 App 别在我盒子里留任何痕迹"。
// 🔴 空/缺失 = 全部记录（与 speakApps/dndApps 同族：不填就不生效）。
// 🔴 只有 App 侧写（设置页选择器）、tweak 侧读——和所有名单一样，别让 SpringBoard 写。
#define NB_KEY_NO_RECORD_APPS @"noRecordApps"   // 数组或 "a,b"，空/缺失 = 全部记录

// ---------- v0.0.52：删除盒子记录时同步清系统通知中心（精确 1:1） ----------
// 语义：盒子上删某一条记录时，如果该通知在系统通知中心（锁屏 / 列表 / 横幅）还挂着，
//   就用 BBServer._clearBulletinIDs:forSectionID:shouldSync: 把**那一条**从通知中心也删掉。
//   只删那一条（按记录时存下来的系统 bulletin ID 精确匹配），不是整段清、不是按 bundle 清。
// 🔴 跨进程通道：盒子 App（com.yxh41.notifybox）和 tweak（跑在 SpringBoard）之间
//   原本没有任何通道。这里用 Darwin notification（不带 payload，机制成熟、不需 entitlement），
//   "要删哪个"走外带共享文件（下面那个路径）。
// 🔴 只有 App 侧写（删除时）、tweak 侧读（收到通知后执行）—— 和所有名单同族。
#define NB_KEY_SYNC_CLEAR @"syncClearNC"   // 布尔，默认关
// 🔴 v0.0.85：精确 ID 匹配不到时的「按内容兜底」开关（默认开）。
//    背景（`nc_diag(24).txt`）：34 次删除里 28 次是「同段有它条、但 ID 都不是目标」——
//    也就是**系统把同一条通知重投过一次、给了新 ID**，而盒子里那行的 sys_id 是旧的
//    ⇒ 精确匹配永远落空 ⇒ 用户看到「删了没反应」。
//    兜底判据故意收得很紧：**同段 + 同 title + 同 message 且只命中 1 条**才动手；
//    命中 ≥2 条一律不动（分不清是哪个，宁可不动也不许撤错）。
#define NB_KEY_CONTENT_FALLBACK @"contentFallbackNC"   // 布尔，默认开
// 🔴 Darwin 通知名（不带 payload）：App 删完一条、写完请求文件后 post 它。
#define NOTIFYBOX_NC_CLEAR_DARWIN @"com.yxh41.notifybox.ncClear"
// 🔴 共享请求文件：App 写 {sysId, bundle, title, message}，tweak 读后执行清除。
//   🔴 v0.0.85 起多了 title / message 两个键（按内容兜底用）。
//   单条删除用单文件足够（手动逐条删几乎不会竞态）；批量清理 / 清空全部不触发本通道。
#define NOTIFYBOX_NC_CLEAR_REQ @"/var/mobile/Library/NotifyBox/nc_clear_req.plist"

// ---------- v0.0.108：自动清「通知中心里超过 N 小时」的通知 ----------
// 语义：扫描 NC 时，把 age > N 小时的那些**从通知中心撤掉**。`0` / 缺失 = 关（**默认关**）。
// 🔴 为什么需要它（v0.0.107 真机定案）：NC 会堆到 **762 条 / 2.6 天**，而且是**真实通知、不是虚胖**
//    （`nc = 去重uuid = 字典键 = 762`，零重复）。界面看着少只是因为通知中心**按 App 分组**显示。
//    ⇒ 想控制堆积只能**真去撤**，改标记口径是错的（别把"数看着多"误诊成"尺子坏了"）。
// 🔴 撤法：`destination:clearNotificationRequests:` 传**超时那一批 request 的数组**，
//    **一次调用**。绝不逐条撤 —— 762 条逐条调会把主队列堵死（v0.0.73 的教训）。
// 🔴 只有 App 侧写（设置页）、tweak 侧读 —— 和所有名单同族。
#define NB_KEY_AUTO_CLEAR_HOURS @"autoClearNCHours"   // 整数，小时；0/缺失 = 关

// ---------- v0.0.56 诊断产物（独立文件，不写日志） ----------
// 🔴 为什么要单开一个文件：iOS 16 上到底有哪些「能删通知」的方法，必须一次性看全。
//    tweak.log 只能看最后几十行（用户还得在几百 KB 里翻），长行会被折成好几行、极易漏读；
//    而文件没有人眼窗口限制 ⇒ 这里把**整个类的方法表（实例 + 类方法，带类型签名）**全写进去，
//    一条一行、按名字排序，可以直接 grep，也可以整份发出来。
// 🔴 只读类结构，**不调用任何未知方法**（零崩溃风险）。
#define NOTIFYBOX_NC_DIAG_PATH @"/var/mobile/Library/NotifyBox/nc_diag.txt"

// ---------- v0.0.98：通知中心存活快照（供盒子 App 打「仍在」标记） ----------
// 🔴🔴 为什么这件事只能由 tweak 做：盒子 App 没有权限读 `NCBulletinNotificationSource.uuidsToRequests`
//    （那是 SpringBoard 进程里的对象）。按"读不到就问权限、换有权限的进程代做"这条纪律，
//    唯一正解是 **tweak 扫、落盘、App 读** —— 不能让 App 自己去猜。
// 🔴 文件由 tweak 在**每次删除结束时**覆盖写（`NBCheckDeletedAlive` 尾部，唯一写入点）。
//    格式：
//      首行 `#scan=<epoch>|nc=<NC总条数>`   ← 本次扫描时刻，**判断"新/旧"的基准**
//      其后每条 `<cid>|<lastSeenTs>|<ncTotal>`
//    语义：
//      · `lastSeenTs ≈ scan` ⇒ 这一条**本次扫描还见到** ⇒ 通知中心仍在；
//      · `lastSeenTs < scan` 且 > 0 ⇒ 上次见到是那个时候，**这一轮没了** ⇒ 已消失；
//      · 文件里没有这个 cid ⇒ **从未见到**（多半 ⓪ 之后系统秒撤，本来就不需要界面刀）。
// 🔴 三种状态里**只有第一种能下"仍在"的结论**，另外两种都不能反推"界面干净了"——
//    v0.0.97 真机已经证伪过："账本干净"推不出"界面干净"。所以 App 里的标记文案必须写成
//    「上次清理时仍在」，⛔ 不许写成「通知中心还在」—— 后者是没量过的断言。
#define NOTIFYBOX_ALIVE_SNAPSHOT @"/var/mobile/Library/NotifyBox/.nb_deleted_seen"
// 判定"本次扫描见到过"的容差（秒）。写文件时 `lastSeenTs` 直接取 `now`、表头也取 `now`，
// 两者本来相等；留 2 秒是为跨进程读到的浮点/取整差异兜底，不参与任何业务判断。
#define NB_ALIVE_SAME_SCAN_TOL 2.0
// 🔴🔴 快照的**保鲜期**（秒）。超过它就**一条标记都不打**，只在提示条上如实报"上次扫描是多久前"。
//    为什么必须有这道闸：这份快照只在 **tweak 删掉一条记录之后**才重写一次。
//    用户三天前删的那批、三天后才打开盒子 App，屏幕上照样会飘一排"仍在"的橙条 ——
//    而那时他早就手动把通知中心清空了。**标记说的是一件过去时刻的事，不是现在的事**，
//    所以要么新鲜到能当现状用，要么就别装成现状。
// 🔴 1 小时这个数不是拍的：`NBCheckDeletedAlive` 在每次删除结束时都跑（含 +5s/+30s/+90s
//    的延迟复量），用户"删完就来看"的窗口远小于它。真正过期的场景是"很久以前删的" ——
//    那种情况本来就不该有标记。
#define NB_ALIVE_FRESH_SEC 3600.0

// ================= v0.0.99：通知中心「现状」快照 =================
// 🔴🔴 为什么 v0.0.98 那套必须换掉（用户原话：「我只是想看消息盒子里的哪些消息还有在通知中心中显示」）：
//    v0.0.98 读的是**删除台账**（`.nb_deleted_seen`），它回答的是「上次清理时哪些还在」。
//    两个致命问题：
//      ① **语义不对**：只在**删记录之后**才刷新。用户不删就永远没有数据 ⇒ 满屏空白；
//      ② **键对不上**（硬 bug）：库里的 `sys_id` 存的是 `bulletinID|notificationIdentifier`
//         （两个键用 `|` 拼起来，见 NotifyStore 写入侧），而台账里的 cid 是**单个** ID
//         ⇒ 拿整串去查单个键，**一条也命中不了**。
//    ⇒ 这一版改成：tweak 扫一遍**当前 NC 里所有 request 的全部标识**，落盘成"现状"；
//      App 把 `sys_id` 按 `|` 拆开逐段匹配。谁在、谁不在，说的是**此刻**的事。
// 🔴 谁来触发扫描：**App 主动请求**（打开列表 / 下拉刷新 / 回前台时）。
//    不能让用户"先删一条才能看" —— 那不是功能，那是副作用。
#define NOTIFYBOX_NC_SCAN_REQ  @"/var/mobile/Library/NotifyBox/nc_scan_req.txt"
#define NOTIFYBOX_NC_SNAPSHOT  @"/var/mobile/Library/NotifyBox/.nb_nc_snapshot"
// Darwin 通知名（App → tweak：「请扫一次」）
#define NB_NC_SCAN_NOTIFY_NAME "com.yxh41.notifybox.ncScan"
// 快照超过这么久就不打标记，只报"扫描于多久前"并给一个重新扫描的入口。
// 🔴 10 分钟：通知中心是**随时会变**的东西（用户手动划掉、系统自动清理），
//    拿十分钟前的结论当现状，性质和"拿删除台账当现状"是一样的。
#define NB_NC_SNAPSHOT_FRESH_SEC 600.0
// v0.0.121：**自动**触发扫描的最小间隔（秒）。
// 🔴 为什么需要它：v0.0.121 起多了 `UIApplicationDidBecomeActiveNotification` 这第四个触发点
//    —— 下拉通知中心/控制中心再收起，状态是 background/inactive → active，
//    **不发 `WillEnterForeground`** ⇒ 那条路以前根本不重扫（用户只能杀掉 App 重进）。
//    但 `DidBecomeActive` 还会被"来电横幅消失 / 从 App 切换器回来 / 解锁"等等触发，
//    密集时一分钟十几次 ⇒ 每次都遍历一遍全部 NC request（真机 637 条）是纯浪费。
// 🔴 只挡**自动**触发：用户手动点提示条要求「重新扫描」时不许节流（点了不动 = 按钮像坏的）。
#define NB_NC_SCAN_MIN_GAP 2.0
// v0.0.122：`[刷新]` 状态行的最小间隔（秒）。
// 🔴 为什么需要它：v0.0.121 的两条新路径（节流挡 / 快照内容没变）**完全静默** ——
//    真机上只能看到 `[扫]` 一直在刷，"到底刷新了没有、为什么没刷新"一个字都读不出来。
//    「该发生的没发生的理由，也必须打出来」；但没有节流的话这行自己就会变成噪音
//    （`DidBecomeActive` 密集时一分钟十几次）。
// 🔴 60 秒：一次真机验证的手动操作节奏大致是 10~20 秒一次动作 ⇒ 一分钟一条既能看出
//    动作序列，又不会把日志窗口（~50 行）占满。
#define NB_REF_LOG_GAP 60.0
// v0.0.122：tweak 侧 `[扫]` 汇总行的最小间隔（秒）。v0.0.123 起语义变为：
// **内容变了之后**，两条汇总行之间至少隔这么久（防 NC 重投时每 2 秒抖一条）。
// 🔴 血账 1（v0.0.121）：`[扫]` 行**每次扫描都打**，79 秒写了 60 行，把 `[残]`
//    那几条一次性诊断（一个进程只打一次）整个挤出窗口 —— 那不是"没生效"，
//    是**被后来的行挤掉了**，而现象和"没生效"一模一样。
// 🔴 血账 2（v0.0.122 真机复量）：只按时间节流到 30 秒**还是不够** ——
//    30 秒一条 = 一小时 120 行，而窗口只有 ~50 行 ⇒ 静止时两分钟就滚完一轮。
//    「按时间节流」挡的是频率，挡不住"内容一个字没变也照打"。
// 🔴 例外：写入失败 / 快照写入保护跳过 —— 这两种必须**立刻打**，不参与任何节流
//    （异常信息比统计信息值钱）。
#define NB_SCAN_LOG_GAP 10.0
// v0.0.123：`[扫]` 汇总行的**保底**间隔（秒）—— 内容一直不变也要这么久打一条。
// 🔴 为什么必须有保底：完全没有日志会被读成"扫描停了"，那比噪音更贵
//    （本项目「没看到日志 ≠ 没生效」的反面：**该打的没打，同样会被误读**）。
// 🔴 为什么是 300 秒：静止时一小时 12 行，窗口（~50 行）够装 4 小时；
//    而真有变化时走 `NB_SCAN_LOG_GAP` 那条路，不会漏事。
#define NB_SCAN_LOG_GAP_IDLE 300.0
// `sys_id` 里两个候选 ID 的分隔符（写入侧 `bID|nID`，见 Tweak.x 的 sysId 拼装处）。
// 🔴 App 侧匹配**必须按它拆开逐段查** —— 拿整串去查单个键是这个功能最大的坑。
#define NB_SYSID_SEP @"|"

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

// ---------- v0.0.112：这里曾经有过一个「内容哈希」，已删除，**不要再加回来** ----------
// 🔴 为什么删（真机证伪，2026-11-02）：
//   ① **前提是假的**。当初加它是因为「全库残留 2 条 / 带ID行 2141」看着像 ID 完全不重叠。
//      但那个 2 条是在 **respring 后 40 秒**量的 —— 那时通知中心只加载出 4 条。
//      换成重启前那份快照，同一个指标是 **254 / 2154**，而当时通知中心总共才 296 条
//      ⇒ ID 匹配率 ≈ 86%，**ID 这条路本来就是好的**。
//   ② **它在扫描侧恒等于 `bundle||`**。真机日志：
//        [哈希] 样本 #1 section=com.apple.MobileSMS hash=772f6a0790a4a733 ｜title=(nil) ｜msg=(nil)
//        [哈希] 样本 #2 section=com.apple.MobileSMS hash=772f6a0790a4a733 ｜title=(nil) ｜msg=(nil)
//      `NCNotificationRequest` 上 `title`/`message` 取不到（正确路径是 `req.content.*`），
//      于是同一个 App 的**所有**通知算出来是同一个哈希。
//      🔴🔴 这种字段比没有更危险：一旦拿它当匹配依据，同一个 App 的任意两条会互相"命中"
//      ⇒ 橙框标错（把 A 标成还在、把 B 也标成还在），而且**不报错**。
//   ③ 它还复刻了一个老坑：`[NC-ID#]` 里 `nID=(nil)` 是 **BBBulletinRequest**（发布时那个对象），
//      而 `[扫][诊]` 里 `nid=__NSCFString` 是 **NCNotificationRequest**（扫描时那个对象）。
//      两个不同对象，前者的结论不能套到后者身上。
// ⇒ 真要重做，必须先把「扫描时那个对象上内容到底怎么读」量清楚，再动匹配。
//
// 判据侧的血账也记一句：v0.0.111 的 `[残]` 诊断取的是「库里最新 5 条」，而快照比它们旧
//   ⇒ 那 5 行**结构上永远不可能命中**，恒为"否"。它是把上面①的错误结论坐实的主因。
//   v0.0.112 已改成 `ts <= 快照时刻`。**凡是"拿最新数据比旧快照"的判据，天生恒否。**

#endif /* NotifyCommon_h */
