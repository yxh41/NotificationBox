#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 🔴 BBBulletin 最小接口（只声明我们用到的属性；真机用 Flex3 核对 iOS 16 实际属性名）
@interface BBBulletin : NSObject
@property (nonatomic, copy) NSString *sectionID;   // 通常是 App 的 bundleId
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, strong, nullable) NSDate *date;   // 通知时间
@property (nonatomic, retain, nullable) id sound;       // 换提示音用（见 applyReplaceRulesTo）
@end

// 形如 "1 小时" / "8 小时" / "到明早 9:00"。菜单标题与真正算出来的时间**同源**，
// 避免"菜单说 8 小时、实际存了 8 分钟"这种只有到点才发现的分歧。
// 🔴 枚举必须声明在 `@interface` **外面**（我第一版把它写在方法声明中间，
//    `@interface` 体内只接受方法/属性声明，clang 会在这里直接报错）。
//    放在这里的另一个原因是调用方（App 的菜单）只用 kind 这个数，不需要类本身。
typedef NS_ENUM(NSInteger, NBMuteKind) {
    NBMuteKind1Hour = 0,
    NBMuteKind8Hours,
    NBMuteKindTomorrow9,
};

@interface NotifyFilter : NSObject

// 🔴 v0.0.8：改成**纯字符串**接口。
//    原因：三个挂点里传进来的对象不一定是 BBBulletin（有的版本是 request 包装类），
//    直接对它发 `[obj sectionID]` 一旦它不响应就是 NSInvalidArgumentException ⇒
//    在 SpringBoard 里等于闪退。字符串接口完全不碰传入对象，从根上没有这个风险。
//    判定口径：命中黑名单 / 白名单不符 / 命中过滤关键词 ⇒ YES（拦掉呈现）。
//    任何异常都返回 NO —— **宁可多推一条，不可把通知吞了**。
+ (BOOL)shouldDropBundle:(nullable NSString *)bundle
                   title:(nullable NSString *)title
                 message:(nullable NSString *)message
                subtitle:(nullable NSString *)subtitle;

// ---------- v0.0.162：把「为什么拦」暴露出来（App 侧「规则测试器」用） ----------
// 🔴🔴 这是 `shouldDropBundle:` 的**唯一实现**，那个 BOOL 接口只是它的一层包装
//      （`reason != nil`）。这样 App 里显示的拦截原因与引擎真正的判定是同一份代码 ——
//      项目铁律：两份判定必走岔，而走岔的试运行结果比没有结果更坏。
// 返回 nil = 放行；非 nil = 拦，且返回的这句话就是原因（形如「命中黑名单」）。
// 任何异常一律返回 nil（= 放行）：宁可多推一条，不可把通知吞了。
+ (nullable NSString *)dropReasonForBundle:(nullable NSString *)bundle
                                     title:(nullable NSString *)title
                                   message:(nullable NSString *)message
                                  subtitle:(nullable NSString *)subtitle;

// v0.0.51：连记录都不要（per-App 名单 NB_KEY_NO_RECORD_APPS）。
// 判定口径：命中的 App **不落库**（闸门在 Tweak.x 的 recordWithBundle: 之前），
//   但**不碰呈现**——通知照弹、过滤/替换/换声/朗读照跑。
// 🔴 与 shouldDropBundle: 的分工：那个拦"呈现"（记录已落库、盒子里仍看得到），
//    这个拦"记录"本身。两个名单独立、互不影响，别试图合并成一个。
// 任何异常都返回 NO —— **宁可多记一条，不可因为读设置出错把记录全吞了**。
+ (BOOL)shouldSkipRecordForBundle:(nullable NSString *)bundle;

// 内容替换（预设规则）：只对**真正响应 getter+setter** 的对象动手，逐个探。
// 返回 YES 表示真的改过。默认无规则 ⇒ 直接返回 NO，行为与不装插件一致。
+ (BOOL)applyReplaceRulesTo:(nullable id)bulletin;

// v0.0.14：把「把一堆规则按顺序套到一段文字上」抽成**纯函数**，给 App 侧复用
//           （内容替换页的「试运行」和「这条规则真的改过几条通知」都用它）。
//
// 🔴🔴 为什么必须是同一个函数：如果 App 自己再写一份顺序套用，两边一旦有一点点不一样，
//       用户看到的试运行结果就是**假的** —— 假结果比没有结果更坏（他会照着一个错的结果去调规则）。
//
// rules：形如 @[@{@"from": 原文, @"to": 替换成}]，允许有非法项（会被跳过）。
// hits ：可为 nil；不为 nil 时**必须与 rules 等长**，某条规则真的把文字改动了就 +1。
//        传进来的数组必须是可变的、且已经预填好足够的 @0（本函数不负责扩数组）。
+ (NSString *)applyRulesToString:(nullable NSString *)text
                           rules:(nullable NSArray *)rules
                            hits:(nullable NSMutableArray<NSNumber *> *)hits;

// v0.0.14：把 settings 里的 replaceRules（可能是任意脏数据）归一成 @[{from,to}]。
//          引擎与 App 都用这一份口径 ⇒ 不会出现「界面认为有 5 条、引擎只认 4 条」。
+ (NSArray<NSDictionary *> *)normalizedRules:(nullable id)raw;

// 🔴🔴 延迟推送：v0.0.19 **功能整体删除**（连接口一起撤掉，不是停用）。
//
// 两版实现各撞死一次，且死法不同 —— 结论是「延迟」这件事在当前注入位置做不到：
//   ① v0.0.14「攒进 dispatch_after 再调原方法」⇒ SIGTRAP。
//      栈：_dispatch_assert_queue_fail ← dispatch_assert_queue
//          ← -[BBServer dataProviderForSectionID:] +44 ← tweak ← GCD 定时器 ← 主队列
//      ⇒ BBServer 的方法内部要求「必须在 BB 自己的私有串行队列上」，那个队列句柄
//        只活在 BBServer 内部、外面拿不到 ⇒ 换哪个队列都不对。**跨队列这条路无解。**
//   ② v0.0.16「只把时间字段往后写，让系统自己改期」⇒ 通知全不弹。
//      真机日志：PBRS 只改到 date、PBR 被幂等跳过、PB 却改到 date+publicationDate+
//      expirationDate —— 同一秒内同一条通知。⇒ 三个入口拿到的是**不同包装对象**
//      （request / bulletin），对象级关联标记跨不过去。
//      更致命的是：**改排期字段不是"延后发布一次"，是"要求系统改期"**。系统每次重排
//      都会重新走发布入口、拿到新包装对象 ⇒ 对象级幂等永远失效 ⇒ 每重排一次再 +5 秒
//      ⇒ 这条通知永远到不了。用户的真实现场就是"一条都不弹"。
//
// ⇒ 接口在这里全部撤掉（不是加一个常量门）。留着带 `dateByAddingTimeInterval` 的死代码
//   等于把一把已经伤过两次的刀留在抽屉里 —— 谁改一个字就能再打开，而它一旦打开
//   用户是"通知全没"这种最难归因的症状。要恢复必须先推翻上面两条真机证据。
//   校验脚本 nb_delay_gate.py 会把「二进制里不许出现改时间字段」当成硬判据。

// ---------- v0.0.21：免打扰时段 ----------
// 命中的通知**不弹**（同黑名单语义），但照常记进盒子。
// 返回 YES 表示"当前时间落在免打扰时段内，且这条通知的 App 在范围内"。
// reason 非空时写入一段人话（形如 "23:00~07:00"），供调用方留痕。
//
// 🔴 任何异常、任何"设置没配全"的情况一律返回 NO ——
//    这个功能的失效方式必须是"照常弹"，绝不能是"莫名其妙全都不弹"。
//    （开始时间 == 结束时间也按 NO 处理：那本来会等价于"全天不弹"，是个灾难性误配。）
+ (BOOL)shouldDropForDND:(nullable NSString *)bundle
                     now:(nullable NSDate *)now
                  reason:(NSString * _Nullable * _Nullable)reason;

// ---------- v0.0.168：临时静音 ----------
// 语义与免打扰**完全一致**（不弹、但照常记进盒子），区别只是"什么时候结束"：
// 免打扰是每天固定时段，临时静音是"从现在起 N 小时"、单次、自己过期。
// 之所以不塞进 shouldDropForDND：那个函数里有一条防呆「开始==结束 ⇒ 关闭」，
// 而绝对时间戳进来之后这条防呆的语境就错了。两个语义混进一个函数，最后一个也说不清。
//
// 返回 YES = 这个 App 此刻被临时静音，调用方应当不弹（并 return NBDeny()）。
// reason（可为 NULL）= 人话，形如 "到 11-09 09:00（剩 47 分）"。
// problem（可为 NULL）= **配了但没能生效**的原因。这是本函数刻意留的第二条输出：
//   静音表存在却读不出/超上限时，返回 NO（照常弹）——那是一个"什么都没发生"的状态，
//   如果不单独报一句，现场就只有"我明明静音了却还在响"，无从下手。
//   🔴 两条输出必须分开：把它们合成一个 reason，就等于把"生效了"和"没生效"写成同一句话。
+ (BOOL)shouldDropForMute:(nullable NSString *)bundle
                      now:(nullable NSDate *)now
                   reason:(NSString * _Nullable * _Nullable)reason
                  problem:(NSString * _Nullable * _Nullable)problem;

// 菜单标题与真正算出来的时间**同源**，避免"菜单说 8 小时、实际存了 8 分钟"
// 这种只有到点才发现的分歧。枚举本身声明在 `@interface` 外面（见文件上方）。
+ (NSString *)menuTitleForMuteKind:(NBMuteKind)kind;
+ (NSDate *)endDateForMuteKind:(NBMuteKind)kind now:(nullable NSDate *)now;
// 到期时刻的人话（"11-09 09:00 · 剩 47 分"）。now 由调用方传，便于判据用固定时刻复算。
+ (NSString *)describeMuteEnd:(NSTimeInterval)until now:(nullable NSDate *)now;

// ---------- 「明早 9:00」的唯一口径（v0.0.168）----------
// 「稍后提醒」(v0.0.167) 和「临时静音」(v0.0.168) 的菜单里都有这一档，两处必须算出**同一个时刻**：
// 同一个长按菜单里两个都写着「明早 9:00」、行为却不同，是没法向用户解释的。
// 规则：先取「今天的 9:00」；若距那一刻已不足 30 分钟（或已过去），顺延到「明天 9:00」。
//   🔴 为什么不一律明天 9:00：凌晨 3 点说「明早」指的是**今天早上**，一律明天 = 静音/提醒 30 小时。
//   🔴 为什么不一律今天 9:00：晚上 23 点选「明早」只能是明天；而 `dateBySettingHour:` 在
//      已过时刻上会给出**今天早上那个过去时间** ⇒ 静音立刻到期，看起来像「点了没反应」。
+ (NSDate *)nextMorningNineFrom:(nullable NSDate *)now;

// 当前生效的静音条目（已过期的不算）。每项：@{@"bundle":…, @"until":@(epoch), @"text":…}。
// 排序 = 先按到期时间升序、再按 bundle。"*" 单列在最前（它影响所有 App，最该先看到）。
+ (NSArray<NSDictionary *> *)activeMutesAt:(nullable NSDate *)now;

// ---------- v0.0.189：冷却期 ----------
// 语义：**同一个 App 在 N 秒内只弹第一条**（N = 设置里的 `cooldownSeconds`，0/缺失 = 关闭），
// 其余的同 App 通知**不弹**，但照常记进盒子（与免打扰/静音同一条"不弹但仍记录"的口径）。
//
// 🔴🔴 这个函数**有副作用**：它会写入"这个 App 上一次被放行的时刻"。
//    ⇒ ⛔ 绝不许在试运行 / 诊断 / 设置预览这类"只是想看看会怎样"的地方调它。
//      在那些地方调一次，就会把用户真实的冷却窗口开起来 —— 症状是
//      "我什么都没做，某个 App 突然不弹了"。要只读地看，用 `activeMutesAt:` 那种只读接口的思路：
//      本函数只给 NB 流水线（Tweak.x）用，判据会盯着"App 侧一次都不许出现"。
//
// 🔴 为什么必须带 title/message：三个入口（PB / PBR / PBRS）会先后对**同一条通知**走这条流水线。
//    冷却是有状态的判定，若每个入口都独立算，第一个入口放行并记下时刻之后，
//    第二、第三个入口就会"落在窗口内"⇒ 被拦。而真正负责呈现的到底是哪个入口，
//    在 iOS 16 上并没有稳定结论（系统版本/App 都可能不同）。
//    ⇒ 同一条通知的结论必须**复用**：本函数内部按 (bundle|title|message) 缓存结论
//      （`NB_COOLDOWN_NOTE_TTL` 秒内有效），三个入口拿到的一定是同一个答案。
//    ⛔ 不许把这件事交给调用方做"我只在首次调" —— 首次标记（firstTime）是**记录**那条链的
//      概念，它的键（bundle|title|message）与呈现链要的东西是同一个，但两处各算一次就是
//      两份口径。宁可在这个唯一的判定点里算。
//
// reason（可为 NULL）= 人话，形如 "60 秒内第 2 条（首条 12 秒前）"。
// problem（可为 NULL）= **配了但没能生效**的原因（值读不出/被上限截断），reason 为 nil 时才可能有值：
//   与静音的 problem 同一条纪律 —— "生效了"和"没生效"绝不能写成同一句话。
// 任何异常一律返回 NO（照常弹）：宁可多吵一声，也不能把通知吞了。
+ (BOOL)shouldDropForCooldownForBundle:(nullable NSString *)bundle
                                 title:(nullable NSString *)title
                               message:(nullable NSString *)message
                                   now:(nullable NSDate *)now
                                reason:(NSString * _Nullable * _Nullable)reason
                               problem:(NSString * _Nullable * _Nullable)problem;


// ---------- v0.0.25：按 App 换提示音（实验）—— **换挂点重写** ----------
//
// 🔴🔴 为什么整段换掉 v0.0.21~v0.0.24 的做法：
//   那四版走的是「alloc 一个 BBSound、填字段、`setValue:forKey:@"sound"` 挂到 bulletin 上」。
//   代价已经实测到了：**造错就整条通知变哑**（v0.0.21），而且 BBSound 上**连 bundle id 都没有**，
//   "按 App" 这件事只能靠外层传参凑。
//   v0.0.25 改挂 `SBNCSoundController -canPlaySoundForNotificationRequest:`
//   —— 一个**返回 BOOL 的总闸门**，参数就是通知请求（自带 sectionIdentifier）。
//   做法反过来：**先把我们的音播出去，播成功了才让系统别播**。
//   参考实现见 docs/换提示音-外部插件调研.md（SilentNotifs 就是这么掐原声的）。
//
// 返回契约（调用方必须严格照此执行，否则会把用户的通知变成哑巴）：
//   YES = 这条该换音，**而且我们的声音已经送出去了** ⇒ 调用方 return NO 掐掉系统原声；
//   NO  = 不适用 / 没配 / 播不出去 ⇒ 调用方**必须**放系统原声。
// result 非空时写入"发生了什么"，调用方要原样打进日志。
+ (BOOL)playCustomSoundForBundle:(nullable NSString *)bundle
                       forResult:(NSString * _Nullable * _Nullable)result;

// v0.0.22：这个 App 是不是「该换提示音」（开关开 + 名单里有它 + ID 合法 / 或选了可用文件）。
// 🔴 给诊断用。判定口径与 applySoundForBundle **同源**（都走 soundVerdictForBundle），
//    不允许在诊断里另写一份 —— 两边走岔的后果见 notifybox/README.md v0.0.22 章。
+ (BOOL)isSoundTargetBundle:(nullable NSString *)bundle;

// ---------- v0.0.26：播一个自定义音频文件 ----------
//
// 🔴 这个函数**不做任何判定**（不看开关、不看 App 名单）——
//    它只管"把这一份文件播出去"。为什么这样切：
//    设置页的「试听」需要无视名单（用户就是想先听听是不是这个音），
//    而通知路径必须先判定。两者共用"播"这一步，判定各走各的入口。
//
// 返回契约与 playCustomSoundForBundle 一致：YES = 播放请求已发出；NO = 播不出去，调用方回退。
// result 非空时写入走了哪条通道与量到的时长，形如
// `自播 file=xx.wav ch=A dur=3.2 cap=8.0`（dur=-1.0 = 时长没量出来，cap=0.0 = 不限）。
+ (BOOL)playSoundFileNamed:(nullable NSString *)name
                 forResult:(NSString * _Nullable * _Nullable)result;

// ---------- v0.0.27：播放计划（只给界面显示用）----------
// 返回人话，形如 `3.2 秒 · 走 A` / `42.0 秒 · 走 B，8 秒后停`。
// 🔴 **不做判定**（不管开关、不管名单），也**不改任何设置**。
//   放在引擎里是为了让"界面写的"和"实际做的"共用同一份选路逻辑：
//   两份一旦走岔，症状是"界面说会截断、实际没截断"，几乎没法自证。
+ (NSString *)playbackPlanForFileNamed:(nullable NSString *)name;

// ---------- v0.0.31：按 App 配「最长播放秒数」 ----------
//
// 存储口径见 NotifyCommon.h 的 NB_KEY_SOUND_ENTRY_MAXSEC（三句话：键不存在 = 跟随全局 /
// 0 = 不限 / 非法值 ⇒ 跟随全局而不是夹成默认值）。
//
// 同一个文件在不同 App 下可以有不同上限，所以"界面显示的计划"必须按 App 问一次 ——
// 否则会出现「给微信配了 30 秒，界面却写着 8 秒后停」这种界面与行为走岔。
+ (NSString *)playbackPlanForFileNamed:(nullable NSString *)name
                             forBundle:(nullable NSString *)bundle;

// entry 的时长一行人话：`跟随全局` / `不限时长` / `30 秒后停`。只用于显示。
+ (NSString *)soundEntryLimitSummary:(nullable NSDictionary *)entry;

// ---------- v0.0.28：按 App 分配提示音 ----------
//
// 存储口径（唯一权威）见 NotifyCommon.h 的 NB_KEY_SOUND_MAP。
// 🔴 增删改**全部走下面这三个方法**，不要在界面里直接改字典：
//    界面各处各写一份"改 map + 落盘"的逻辑，迟早出现「页面 A 写对了、页面 B 少删了一个键」，
//    而那种错在界面上看不出来（值在、只是对不上）。
//
// entry 的形态：@{NB_KEY_SOUND_ENTRY_FILE: 文件名} 或 @{NB_KEY_SOUND_ENTRY_ID: @(1007)}，
// 两者都给时**文件优先**（与判定口径一致）。entry = nil ⇒ 删除这个 App 的分配。
+ (NSDictionary<NSString *, NSDictionary *> *)soundMap;

// 返回 YES 表示**已经落盘成功**。写盘失败也返回 NO（界面据此提示，不许假装成功）。
+ (BOOL)setSoundEntry:(nullable NSDictionary *)entry forBundle:(nullable NSString *)bundle;

// 一行给人看的音名（文件名 / "系统音 1007" / "未设置"）。只用于显示。
+ (NSString *)soundEntrySummary:(nullable NSDictionary *)entry;

// 旧格式 → soundMap 的一次性迁移（**只在 App 启动时调**，SpringBoard 不写盘）。
// 返回 YES 表示这次真的迁移并写盘了。
// 🔴 默认音（全局 soundFile/soundID）拿不到时**不迁移**：与其造一堆"未设置"的半成品，
//    不如让旧回退继续工作 —— 回退是代码里写着的，不需要用户配合。
+ (BOOL)migrateSoundMapIfNeeded;

// v0.0.21：换提示音的崩溃自愈（只在 SpringBoard 的构造函数里调一次）。
// 返回 YES 表示"上次就是崩在换提示音里，已经把这个开关关掉了"，**并且已回读确认**。
+ (BOOL)recoverFromSoundCrashIfNeeded;

// ---------- v0.0.30：音频会话交还 ----------
//
// 背景（代码事实）：全项目 `setActive:YES` 有两处、`setActive:NO` **一处都没有** ——
// B 通道（Ambient+MixWithOthers）和 App 内语音试听（Playback+DuckOthers）都把会话激活后就不管了。
// 后果最实在的是 DuckOthers 那条：它的语义是"把别人正在放的音乐压下去"，
// 会话不交还时别人的音量能不能恢复，是这类 App 里的经典坑。
//
// 这个方法的语义是**保守放行**：只要还有任何东西可能在响，就**不交还**。两个条件都满足才放行：
//   ① B 通道在播列表 `NBLivePlayers()` 为空
//   ② 朗读没在播（`NotifySpeaker isSpeakingNow`，用 NSClassFromString 问，见下）
//
// 🔴 幂等：连调两次只是让第二次 `setActive:NO` 返回一个错误码（已忽略），不会炸、不会出声。
// 🔴 **不许在 play 路径上调它** —— 播一半交还就是"声音断在半截"，
//    那正是 v0.0.27 花了整版才修掉的东西。调用点只有两处：B 通道到点收工之后、语音试听结束之后。
+ (void)releaseAudioSessionIfIdle;

@end

NS_ASSUME_NONNULL_END
