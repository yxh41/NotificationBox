#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// v0.0.48：关键词规则命中后要做的动作（位掩码，一次匹配同时出两个）。
// 🔴 为什么用位掩码而不是两个 BOOL 出参 / 两个方法：
//    "总数与未读同一条 SQL 出"是同一条纪律 —— 一遍匹配、一个来源，
//    避免"标星用一套条件、折叠用另一套"两个口径互相矛盾。
typedef NS_OPTIONS(NSUInteger, NBKeywordAction) {
    NBKeywordActionNone = 0,
    NBKeywordActionStar = 1 << 0,   // 命中 ⇒ 该行显示 ★
    NBKeywordActionFold = 1 << 1,   // 命中 ⇒ 该行默认被主列表收起
};

@interface NotifyStore : NSObject

// 录制（tweak 调用）。date 传 nil 时自动用当前时间。
// v0.0.52：sysId = 系统 bulletin ID（BBBulletin.bulletinID / notificationIdentifier），
//   用于"盒子删记录时同步清系统通知中心"的精确 1:1 匹配；读不到传 nil，功能自动失效。
// v0.0.84：盒子侧重复量（只读）。返回 rows / noSys / sysGroups / sysExtra /
//   txtGroups / txtExtra 六个键，语义见 .m 里 dupStats 的注释。
// v0.0.85：多三个键，专门用来判「无 sys_id 的行到底是老记录还是新记录」——
//   noSys24h / noSysNewestAgo / noSysOldestAgo（秒，-1 = 没有这类行）。
+ (NSDictionary *)dupStats;

// v0.0.85：把这次才拿到的系统 ID 补写到「刚刚那条还没 ID 的行」上。
// 🔴 为什么需要它：同一条通知会经过 publishBulletin / publishBulletinRequest /
//   _publishBulletinRequest:forSectionID:forDestinations: 三个入口，**谁先到谁记录**。
//   先到的那个入口可能还没拿到 bulletinID（系统在 publish 过程中才分配）
//   ⇒ 那一行 sys_id 为空 ⇒ 以后永远删不掉通知中心里那条。
//   后到的入口手里有 ID，但它会被 NBClaimKey 挡在 store 之前 ⇒ 在这里补写。
// 🔴 三个调用点（v0.0.86 补了后两个）：① NBClaimKey 被挡；②③ 三个 publish 入口在 `%orig`
//   **之后**复读一次 ID（`NBPickUpAfterPublish`）—— 拿到就补，不必知道行号。
// 🔴 三条护栏（少一条就出事）：① 只改 `sys_id` 为空/NULL 的行；② 只改**最近那一行**
//   （同内容可能有历史脏行，一把 UPDATE 会连坐）；③ 必须查 `sqlite3_changes()`
//   （UPDATE 命中 0 行也返回 SQLITE_DONE）。
// 🔴 v0.0.86 窗口 600 → 1800 秒：`ts` 存的是 `date ?: now`，而重投通知的 `date`
//   可能早于插入时刻 ⇒ 600 秒会把"刚插进来的那一行"自己筛掉（补写恒 0 行）。
// 返回补上的行数（0 = 没有可补的）。
+ (NSInteger)backfillSysId:(NSString *)sysId
                    bundle:(NSString *)bundle
                     title:(nullable NSString *)title
                   message:(nullable NSString *)message;

// v0.0.133：多一个 `payload`（通知原始 `userInfo` 的 JSON 串，可为 nil）。
// 🔴 为什么要存它：长按卡片的「打开」要能尽量**直达那条内容**，而 iOS 没有
//    "跳到某条通知"的通用能力，唯一线索就是 payload 里带的链接。
//    ⚠️ 提取链接的逻辑**故意放在 App 侧**（`AppLauncher deeplinkFromPayload:`），
//    tweak 只做"哑存" —— 这样以后想扩大识别范围不用重编 tweak（和关键词规则同一个偏好）。
// 🔴 存的是**有界**的（tweak 侧截断 2048 字符）：一条通知不许把库撑大。
+ (void)recordWithBundle:(NSString *)bundle
                   title:(nullable NSString *)title
                 message:(nullable NSString *)message
               subtitle:(nullable NSString *)subtitle
                    date:(nullable NSDate *)date
                  sysId:(nullable NSString *)sysId
                 payload:(nullable NSString *)payload;

// 旧签名：**薄封装**，转调上面那个 `payload:nil`。
// 🔴 保留它不是为了兼容，而是"同一个语义不许有两份实现"——已有调用点不必改语义，
//    但插入逻辑只写一遍（照抄一份改个参数，以后加列必然漏一处）。
+ (void)recordWithBundle:(NSString *)bundle
                   title:(nullable NSString *)title
                 message:(nullable NSString *)message
               subtitle:(nullable NSString *)subtitle
                    date:(nullable NSDate *)date
                  sysId:(nullable NSString *)sysId;

// 查询（盒子 App 调用）
// v0.0.36：加 `unreadOnly`（只看未读）。四种筛选是**独立叠加**的
// （App / 时间 / 搜索 / 未读），和之前三个参数的组合方式一致。
// v0.0.42：加 `searchBundles` —— **搜索从此也匹配 App 名**。
// 🔴 为什么 App 名要由外面传进来：「微信」「招商银行」这些字**不在库里**
//    （库里只有 `com.tencent.xin` / `cmb.pb`），tweak 侧写记录时也没有 App 显示名可存。
//    ⇒ 只有界面层能拿到 `InstalledApps` 的显示名表，先把搜索词匹配成 bundle 列表再传下来。
//    好处是**不用改 schema**：对库里已有的老记录立即生效，不需要迁移、不需要重装重记。
// 🔴 调用方约定：`search` 为空时 `searchBundles` 一律传 nil（两者是同一个括号组里的 OR，
//    只传 bundles 不传 search 没有意义）。
+ (NSArray<NSDictionary *> *)queryWithBundle:(nullable NSString *)bundle
                                       since:(NSTimeInterval)since   // 0 = 不限
                                      search:(nullable NSString *)q  // nil = 不限
                              searchBundles:(nullable NSArray<NSString *> *)searchBundles
                                  unreadOnly:(BOOL)unreadOnly;        // YES = 只回 read=0
// v0.0.44：**导出专用**的查询 —— 和 `queryWithBundle:` 唯一的区别是**没有 LIMIT**。
// 🔴 别拿带 LIMIT 的那个去导出：会"刚好少掉最旧的几千条"，而用户拿到文件时看不出来。
//    WHERE 条件仍然走同一个 `NBPrepareScope`（导出的 = 看到的那批）。
+ (NSArray<NSDictionary *> *)exportRowsWithBundle:(nullable NSString *)bundle
                                            since:(NSTimeInterval)since
                                           search:(nullable NSString *)q
                                    searchBundles:(nullable NSArray<NSString *> *)searchBundles
                                       unreadOnly:(BOOL)unreadOnly;
// v0.0.42：列表一次最多取多少条（`queryWithBundle:` 的 LIMIT）。
// 🔴 底部「还有 N 条更早记录（列表上限 N）」要把它写进文案里 ——
//    界面里另写一个字面量，这个数以后一改就会对不上。
+ (NSInteger)listLimit;
+ (NSArray<NSString *> *)distinctBundles;          // 顶部 App 图标栏
// v0.0.36：**有未读记录的 App 集合**，给图标栏红点用。
// 🔴 只回"有没有"，不回条数 —— 红点不显示数字，查询越轻越好。
// 🔴 别拿 `bundleCounts` 兼职：它数的是**全部**条数（v0.0.13 给 App 选择器排序用的），
//    拿它判未读会"所有 App 永远都有红点"。
// v0.0.37：带时间窗的版本 —— 红点必须和列表**看同一个范围**。
// 🔴 v0.0.36 的真机 bug：红点用的是全库口径，列表却只查 `now-86400` 之后，
//    结果「有红点 → 点进去暂无记录 → 红点永远消不掉」。用户看到的是一个
//    自己清不掉的提示，比不打红点更糟。
//    ⇒ 红点语义改成「**当前时间窗内**有未读」，永远点得进去、清得掉。
//    `since <= 0` 等价于全库。
// 🔴 v0.0.39：**不带参的 `bundlesWithUnread` 已删除**（死的公开 API）。
//    它唯一的调用者是空列表提示，而那个提示现在改问「更早还有**多少条**」——
//    要条数就得用 `unreadCountWithBundle:since:`（它连"某个 App + 某段时间"都能算，
//    是这套查询的超集）。留着它就是留一条谁都可能误用的老路。
+ (NSSet<NSString *> *)bundlesWithUnreadSince:(NSTimeInterval)since;
// v0.0.13：bundle -> 通知条数。App 选择器用它把「经常来通知的」排前面。
+ (NSDictionary<NSString *, NSNumber *> *)bundleCounts;
+ (NSInteger)maxRecords;                           // 从 prefs 读上限

// 维护
// v0.0.124：把一行的已读态设成**任意值**（`read` 写 1 或 0）。
// 🔴 为什么要新开一个而不是改 `markRead:`：v0.0.123 及以前 `markRead:` 的 SQL 里
//    `read=1` 是**硬编码**的 —— 右滑「标为未读」要的是 `read=0`，照抄一份改个数字，
//    就成了两处 SQL 各写一遍（各自看都对，以后加列/加条件必然漏一处）。
//    ⇒ 只留一个写入口，`markRead:` 退化成 `setRead:YES`（调用点不动，签名不变）。
// 🔴 `rowId <= 0` 直接返回：库里 id 从 1 开始，0/负数是"没拿到 id"的哨兵
//    （`d[@"id"]` 取不到时是 0），拿它去 UPDATE 会命中 0 行且**不报错**。
+ (void)setRead:(BOOL)read rowId:(NSInteger)rowId;
+ (void)markRead:(NSInteger)rowId;
// v0.0.38：把「当前筛选范围内」的未读**批量**标为已读，返回真正改动的行数
// （-1 = DB 打不开）。不删记录，只把 read 从 0 改成 1。
// 🔴 参数只有 bundle + since，**故意不含搜索词**。为什么和 `unreadCountWithBundle:since:`
//    配成一对：界面上的确认文案必须报「将要改多少条」，而那个数只能由同一套条件算出来。
//    v0.0.35 的 `onClear:` 已经买过一次教训 —— 确认框报列表条数（3）、实际清整张表（2000）。
//    这里两边共用同一组 WHERE 条件，搜索框只在「列表显示什么」上生效，不参与标记范围，
//    并在文案里写清楚这件事。
+ (NSInteger)markAllReadWithBundle:(nullable NSString *)bundle
                             since:(NSTimeInterval)since;   // 0 = 不限
// v0.0.38：上面那个方法的「先算一遍」版本 —— 给确认框报数字用。
// 🔴 不能拿 `queryWithBundle:...unreadOnly:YES].count` 代替：那个会真的 SELECT 出行来
//    （2000 行的完整字段），而且它带搜索词 ⇒ 和标记范围不同口径。
+ (NSInteger)unreadCountWithBundle:(nullable NSString *)bundle
                             since:(NSTimeInterval)since;
// v0.0.40：带搜索词版本。**只给「当前筛选之外还有多少未读」这个计算用**。
// 🔴 为什么要加它：顶部提示条要回答的是「全库未读 − 当前筛选下的未读」，
//    而"当前筛选"包含 App 图标 + 时间 + **搜索**三项。搜索只在
//    `queryWithBundle:` 里生效、计数那边没有的话，两边永远对不上 ——
//    症状是"列表里明明都读完了，顶部还在喊还有 3 条"。
// 🔴 与 `markAllReadWithBundle:since:` 的分工：**标记永远不带搜索词**
//    （搜索只决定列表显示什么，不缩小标记范围，v0.0.38 的确认文案里对用户承诺过）。
+ (NSInteger)unreadCountWithBundle:(nullable NSString *)bundle
                             since:(NSTimeInterval)since
                            search:(nullable NSString *)search;
// v0.0.42：再带一层 App 名匹配。**`updateHiddenUnread` 必须用这个版本**。
// 🔴 为什么不能省：搜索现在能命中 App 名，列表里因此多显示了若干条。
//    如果计数还用不带 `searchBundles` 的版本，「筛选内未读」就偏小 ⇒
//    `hiddenUnread` 偏大 ⇒ 顶部又变成"列表里都读完了还在喊还有 N 条"。
//    这条坑 v0.0.40 已经花整版买过一次，别再犯。
+ (NSInteger)unreadCountWithBundle:(nullable NSString *)bundle
                             since:(NSTimeInterval)since
                            search:(nullable NSString *)search
                     searchBundles:(nullable NSArray<NSString *> *)searchBundles;
// v0.0.42：**当前筛选下的总条数**（-1 = DB 打不开）。
// 🔴 和 `count`（全库、不分筛选）是两件事，别混用。
// 唯一用途：底部「还有 N 条更早记录」= 本方法 − `queryWithBundle:` 实际返回的条数。
// ⇒ 它必须和查询走**同一个** `NBPrepareScope`，否则会出现"列表已经到底了、
//    底部还在说还有 3 条"。为什么会有条数差：列表是 `LIMIT listLimit`（默认 2000），
//    而 `maxRecords` 允许用户填到 99999 ⇒ 库里 5000 条时，后 3000 条列表里根本没有。
// v0.0.43：加 `unreadOnly` —— **这个参数不是可选的礼貌，是必须的**。
// 🔴 v0.0.42 的真机 bug：`unreadOnly` 模式下列表只装了未读（比如 50 条），
//    计数却按"不分已读"算（比如 500 条）⇒ 底部报「下面还有 450 条更早的记录」，
//    而那 450 条**全是已读**、和用户当下要看的东西无关。
//    「底部说的数」和「列表里的东西」必须是同一个集合，这才是这条提示可信的前提。
+ (NSInteger)countWithBundle:(nullable NSString *)bundle
                       since:(NSTimeInterval)since
                      search:(nullable NSString *)search
               searchBundles:(nullable NSArray<NSString *> *)searchBundles
                  unreadOnly:(BOOL)unreadOnly;
// v0.0.35：**清空整张表**，返回真正删掉的条数（-1 = DB 打不开）。
// 🔴 返回条数不是"花式" —— 是沿用 v0.0.33 `deleteRow:` 的同一条纪律：
//    "没动到账本"和"动了但条数是 0"必须能分辨。`DELETE FROM` 命中 0 行照样
//    返回 SQLITE_OK，所以界面那边不能假设"点了就清掉了"。
// 🔴 调用方注意：清的是**整张表**，不是当前筛选结果。在搜索/App 筛选状态下
//    看到的 3 条和会被删掉的 2000 条是两个数，确认文案必须用 `count`（总数）。
+ (NSInteger)clearAll;
// v0.0.33：删**单条**。返回 YES 表示真的删掉了（id 不存在时返回 NO）。
// 🔴 界面那边删完必须**重新 query**，不能只从内存数组里 removeObjectAtIndex: ——
//    在「搜索 / 顶部 App 筛选 / 时间段」这三种状态下，内存下标和数据库根本对不上，
//    只改内存就等于"只改账本的读数、不改账本"（本项目数量契约三问的第 2 问）。
//    症状具体是：删完那一行仍然在（重进又有），或者删了 A 却少了一条 B。
// ---------- v0.0.84：删除后「到底会不会去清通知中心」交给界面 ----------
// 🔴 为什么要有这个出参：用户反馈「有些能删、有些不行」。查下来不是刀坏了，而是
//    **删除这一侧本来就有三道闸**，任何一道不过就静默什么都不做：
//      ① 记录没有 `sys_id`（v0.0.52 才加这一列 ⇒ 更早记下的老记录全是 NULL）；
//      ② 设置里「删除时同步清通知中心」是关的；
//      ③ 记录里缺 `bundle`（sectionID 必须和 bulletinID 成对，不然清除 API 无效）。
//    静默的后果是用户只会说"删了没反应"，而日志里连一行都没有。
//    ⇒ 把结论交出去，由界面用一句人话讲清楚。
typedef NS_ENUM(NSInteger, NBSyncClearOutcome) {
    NBSyncClearRequested  =  1,   // 已写请求文件 + post，tweak 会去尝试清 NC
    NBSyncClearNoSysId    =  0,   // 记录没有 sys_id（老记录）⇒ 无从精确匹配
    NBSyncClearOff        = -1,   // 设置里这一项是关的
    NBSyncClearNoBundle   = -2,   // 缺 bundle
    NBSyncClearDeleteFail = -3,   // 记录根本没删掉（id 不存在）
};

// 带 outcome 的版本。`outcome` 可为 NULL。
// 🔴 保留 `deleteRow:` 作为薄封装：已有两处调用点不必改语义，
//    但**同一个语义不许有两份实现**（所以它只是转调，不复制 DELETE 逻辑）。
+ (BOOL)deleteRow:(NSInteger)rowId outcome:(NBSyncClearOutcome *)outcome;

// ---------- v0.0.84：历史重复一次性合并 ----------
// 🔴 只合并「`sys_id` 非空且完全相同」的行 —— 同一个系统通知标识 = 同一条通知，
//    多留几行没有信息量。**sys_id 为空的行一律不碰**（空串相同 ≠ 同一条通知，
//    拿空串当键会把整个库合并成一条）。
// 返回值 = 被删掉的多余行数（0 表示库里本来就干净）。
+ (NSInteger)dedupeBySysId;

+ (BOOL)deleteRow:(NSInteger)rowId;
// v0.0.45：**批量删除**（真账本级）。四个条件都是"可空 = 不限"，独立叠加。
//   bundle     nil = 所有 App
//   beforeTs   0   = 不限时间；否则删**严格早于**它的
//   readOnly   NO  = 连未读一起删；YES = 只删已读（read=1）
// 🔴 返回真正删掉的条数（-1 = DB 打不开）。
//    🔴🔴 为什么必须返回条数：`DELETE` 命中 0 行照样返回 SQLITE_DONE，
//    不查 `sqlite3_changes()` 的话，"条件写错了删了个空"和"删掉了 800 条"
//    在界面上是同一个"操作成功" —— 本项目数量契约三问的第 2 问。
// 🔴 调用方约定：删完必须**整表重查**（`loadData`），
//    不许 `deleteRowsAtIndexPaths:` / `removeObjectAtIndex:` ——
//    搜索态/筛选态下内存下标和库 id 根本对不上（v0.0.33 的老教训）。
+ (NSInteger)deleteWithBundle:(nullable NSString *)bundle
                     beforeTs:(NSTimeInterval)beforeTs
                     readOnly:(BOOL)readOnly;
// 上面那个的"先算一遍"版本 —— 给确认框报数字用。
// 🔴 不能拿列表条数代替：列表带 `LIMIT 2000`，筛选态下还会被搜索词再切一刀。
+ (NSInteger)countForDeleteWithBundle:(nullable NSString *)bundle
                             beforeTs:(NSTimeInterval)beforeTs
                             readOnly:(BOOL)readOnly;
// v0.0.45：App 显示名表（**tweak 写 / App 读**，理由见 NBAppName.h）。
// 🔴 盒子 App 沙盒读不到 /var/containers/Bundle/Application/<UUID>/Xxx.app，
//    所以"读 bundle 里本地化的 CFBundleDisplayName"这条最权威的路，
//    只能由注入 SpringBoard（有权限）的 tweak 走一遍，把结果写进这张表。
+ (void)saveAppName:(NSString *)name forBundle:(NSString *)bundle;
+ (NSInteger)saveAppNames:(NSDictionary<NSString *, NSString *> *)names;   // 批量，只开一次库
+ (NSDictionary<NSString *, NSString *> *)appNames;
+ (nullable NSString *)appNameForBundle:(NSString *)bundle;

#pragma mark - v0.0.46 统计

// 按 App 分组。返回 @[@{@"bundle":…, @"total":@N, @"unread":@N}]，按 total 降序。
// 🔴 总数和未读**一条 SQL 同时出**（`SUM(CASE WHEN read=0 …)`），
//    不分成两条查 —— 两条就有可能出现"A 口径的总数 + B 口径的未读"，
//    而本项目最贵的那次事故（v0.0.37 红点永远消不掉）正是两个指标不同口径。
// 🔴 `since` 与列表同一口径（`ts >= since`），0 = 全库。
// 🔴 `beforeTs` 是**自定义时间窗的上界**（`ts < beforeTs`），0 = 不限（配合 `since`）。
// 🔴 `limit` <= 0 表示不限制。
+ (NSArray<NSDictionary *> *)statsBundlesSince:(NSTimeInterval)since
                                       beforeTs:(NSTimeInterval)beforeTs
                                          limit:(NSInteger)limit;
// 按时间桶分组。`byHour` = YES 时返回 **24 个桶（含 0 条的）**，key 是 @"hour"（0~23）；
// NO 时按天，key 是 @"day"（yyyy-MM-dd）。
// 🔴 用 `localtime`：库里存的是 unix 时间戳，**不转换会得到 UTC 的小时**
//    ⇒ 用户看到"我明明晚上收到的，却算在凌晨"。
// 🔴🔴 v0.0.181：按天**也补齐空白日**（原来只回有记录的天）。不补的话，
//    选「30 天」而中间空了 12 天时柱状图只剩 18 根、横轴被压缩成连续的 18 格
//    ⇒ 图上看起来"天天都有"。「没有」和「这一格不存在」必须是两种信息。
// 🔴 `maxFill`：按天时只保留**最近 maxFill 天**（≤0 = 不补齐，返回有记录的天）。
//    护栏的意义是把"全库 200 天"挡在列表外 —— 200 行没人看得下去。
//    `byHour` 忽略这个参数（恒补 24）。
+ (NSArray<NSDictionary *> *)statsBucketsSince:(NSTimeInterval)since
                                     beforeTs:(NSTimeInterval)beforeTs
                                       byHour:(BOOL)byHour
                                      maxFill:(NSInteger)maxFill;
// 统计页顶部 KPI：总条数、未读、覆盖多少个 App、**最早 / 最晚**一条、有正文的条数。
// 🔴 返回字典的 key 固定为 total / unread / apps / withBody（都恒有），
//    以及 earliest / latest（NSDate，空表时**这两个键不存在**，不是 nil 值）。
// 🔴 六个值全在**同一条 SQL** 里出：KPI 卡上「总条数」和「有正文 78%」并排摆着，
//    分两条查就可能出现两个口径，加起来超过 100%。
+ (NSDictionary *)statsSummarySince:(NSTimeInterval)since beforeTs:(NSTimeInterval)beforeTs;

// 设置（App 侧的**唯一**读写入口；tweak 侧读走 NotifyCommon.h 的 NBLoadSettings）
// 🔴 统一在这里写，别让每个 VC 各写一遍 writeToFile: —— 写入点一多，
//    "某个页面写了、另一个页面没写" 这类 bug 就必然出现。
+ (NSDictionary *)settings;
+ (BOOL)saveSettings:(NSDictionary *)settings;
// v0.0.47：自动清理「保留最近 N 天」。`days` = 0 表示关闭（默认）。
// 🔴 读取/写入都走 settings.plist（和 maxRecords 同一个入口）。
// 🔴 `runAutoClean` 在 App 启动时调一次：days>0 时把**早于 `now-days*86400`**的记录整批删掉
//    （连未读一起，因为"保留最近 N 天"的语义就是"更老的都不要了"）。
//    复用 v0.0.45 的 `deleteWithBundle:beforeTs:readOnly:`（bundle=nil=所有 App，readOnly=NO=全删）。
+ (NSInteger)autoCleanDays;
+ (void)setAutoCleanDays:(NSInteger)days;
+ (NSInteger)runAutoClean;

// v0.0.48：关键词自动规则（**展示时生效、纯盒子 App 端**，tweak 侧零改动）。
// 🔴 为什么"展示时"而不是"写入时"：规则改动要**即时生效**、老记录不用重录、
//    也就不用把规则同步给 tweak（tweak 零改动是本项目一贯的低风险偏好）。
// 存储键：settings.plist 的 keywordRules = @[@{@"keyword":…, @"star":@BOOL, @"fold":@BOOL}]。
// 🔴 上限 20 条：每条规则要对 4 个字段做大小写不敏感子串匹配，条数不设限会拖慢每次刷新。
// 🔴 `keywordActionForTitle:…` 一次遍历同时出 star/fold 两个动作（见 NBKeywordAction）。
+ (NSArray<NSDictionary *> *)keywordRules;
+ (BOOL)saveKeywordRules:(NSArray<NSDictionary *> *)rules;
+ (NBKeywordAction)keywordActionForTitle:(nullable NSString *)title
                                 message:(nullable NSString *)message
                                subtitle:(nullable NSString *)subtitle
                                 appName:(nullable NSString *)appName;

// 自检（盒子 App 空列表时直接显示，用来判断沙盒可达性）
+ (NSInteger)count;
// v0.0.38：库里最大的行 id（空表返回 0），给「列表要不要重新查」当探针。
// 🔴 为什么不能只看 `count`：记录数到达上限之后，tweak 每来一条新通知都会先裁掉
//    一条最旧的 ⇒ **条数恒定不变**。只看条数的话，"最需要刷新的场景"恰好检测不到
//    （库满 2000 条时后台每来一条通知，列表都不会自己更新）。
//    id 是自增的，新记录一定让 MAX(id) 变大 ⇒ 两个数一起看才盖得住新增和删除。
+ (NSInteger)maxRowId;
+ (NSString *)debugSummary;
+ (NSString *)logText:(NSUInteger)maxBytes;   // 读 tweak.log 尾部，给 App 内查看

// 🔴 关键判据：盒子 App 启动时也往同一个日志文件写一行。
//    日志里若只有 [APP-ALIVE] 而没有 [SpringBoard] 的 loaded 行
//    ⇒ 说明路径可写、但 tweak 没注入（而不是写不进）。
+ (void)markAppAlive;

// 🔴 环境自检：**完全不依赖日志文件**，直接实测路径可写性 + DB 记录数 + dylib 安装位置。
//    日志文件不存在时（连 App 都没写成功），这份数据是唯一能定位的现场。
+ (NSString *)envCheck;

#pragma mark - v0.0.98/99 通知中心状态（只读）

// 「这条记录现在还在不在通知中心里」—— 三态。
// 🔴🔴 为什么是**三**态而不是两态：快照里没有它，可能是"已经不在 NC 了"，
//    也可能是"这次根本没扫到 / 没扫过"。只看精确匹配的实现**原理上产不出第三态**，
//    而这两种在真机上完全不同（v0.0.97 的 `nc_diag(3).txt` 62 次米家删除里有 14 次
//    属于"从来没见到"）。混成一个"已消失"就是在编数据。
typedef NS_ENUM(NSInteger, NBAliveState) {
    NBAliveUnknown = 0,   // 没有快照 / 快照过期 / 这条没有 sys_id ⇒ **不许**当"已消失"
    NBAliveStill   = 1,   // 快照里命中 ⇒ **此刻仍在**通知中心（唯一能下结论的那一态）
    NBAliveGone    = 2,   // 快照新鲜且没命中 ⇒ 此刻不在通知中心
};

// ---------- v0.0.99：请求 tweak 扫一次「通知中心现状」 ----------
// 🔴 为什么必须请求而不是自己读：`uuidsToRequests` 在 SpringBoard 进程里，盒子 App 没有权限。
// 🔴 `seq` 由调用方给（用时间戳即可）。tweak 会把它原样写进快照表头 ⇒ App 能判断
//    "手上这份是不是我刚要的那次扫描"，而不是拿上一份旧数据当新结论。
+ (void)requestNCSnapshotWithSeq:(NSString *)seq;

// 读一次快照。返回 @{@"scan": NSNumber(NSTimeInterval),   // 0 = 没有可用快照
//                  @"nc":   NSNumber(NSInteger),          // 扫描时 NC **账本**总条数
//                  @"cse":  NSNumber(NSInteger),          // 扫描时**界面严格认**的条数（v0.0.103）
//                  @"csemn":NSNumber(NSInteger),          // >0 才可量；0 = 量不了（⛔ 不许当 0 条）
//                  @"csm":  NSNumber(NSInteger),          // 1 = CS dispatcher 已被捕获
//                  @"seq":  NSString,                     // tweak 回写的那次请求序号
//                  @"keys": NSSet<NSString *>}。          // 此刻 NC 里所有通知的**唯一标识**
// 🔴 匹配键只有 `bulletinID` / `notificationIdentifier` / `uuid` 三把（都是唯一的）。
//    快照里**故意不含** `recordID` / `publisherBulletinID` —— 这两个对某些 publisher 是常量，
//    写进来会让"同 publisher 的所有通知"全部误命中（见 Tweak.x 里 NBDumpNCSnapshot 的注释）。
// 🔴🔴🔴 `nc` 和 `cse` 是**两个口径**，而且**都不等于眼睛**（v0.0.102/v0.0.103 真机量的）：
//    · `nc`（`uuidsToRequests`）= NC source 的**历史账本**，一次返 637 条，手机挂不了那么多；
//    · `cs`（v0.0.102 那档，"返回非 nil 就算认"）= **672 条**，比账本还大
//      ⇒ 那个方法对几乎任何 uuid 都回一个对象，"返回了"根本区分不出真假。**这一档已废**。
//    · `cse`（v0.0.103）= 回来的对象 uuid **必须等于**问的 uuid，只在能读到 uuid 时计入
//      `csemn`；两者相除才是"界面真的有这条"的近似值。
//    ⚠️ v0.0.102 曾把日志里的「是 16 / 否 74」当成"界面只有 16 条" —— 那是**删除后逐条读回**
//       的局部口径，不是全库条数。教训：**局部口径的数不许说全库的话**。
+ (NSDictionary *)ncSnapshot;

// 某条记录（`sys_id`）此刻在不在通知中心。
// 🔴🔴 **必须按 `|` 拆开逐段匹配**：库里的 `sys_id` 存的是 `bulletinID|notificationIdentifier`
//    （两个候选键拼起来的，见 Tweak.x 的 sysId 拼装处），而快照里每个键都是**单独一个**。
//    拿整串 `"bID|nID"` 去查只有 `"bID"` 的集合 ⇒ **一条也命中不了**。
//    v0.0.98 就是栽在这里：功能看着装好了，屏幕上一条都没有。
+ (NBAliveState)aliveStateOfSysId:(nullable NSString *)sysId
                       inSnapshot:(NSDictionary *)snap;

// ---------- v0.0.100：全库口径「此刻还在通知中心」的行数 ----------
// 🔴🔴 为什么必须和列表口径分开：`aliveStillCount`（App 侧）是**当前列表**的数，
//    受时间窗 / App 筛选 / 未读 / LIMIT 2000 影响。拿它说「盒子里的消息都不在通知中心了」
//    就是**用局部数做全库断言** —— 记录明明还在，只是被筛选挡住，那句话就是假的。
// ⇒ 规矩：**全库 0 才准说"都不在"**；全库 >0 而列表 0 必须说"被当前筛选挡住了"。
// 🔴 匹配规则只认 `aliveStateOfSysId:inSnapshot:` 一份实现（本方法逐行调它）。
// ⚠️ 快照不可用（`scan <= 0` / 过期）时返回 0 —— 调用方**不许**把它当"都不在"，
//    那两个分支必须在文案里先被挡掉。
+ (NSInteger)countStillInDBWithSnapshot:(NSDictionary *)snap;

@end

NS_ASSUME_NONNULL_END
