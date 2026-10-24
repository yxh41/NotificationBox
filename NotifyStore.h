#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NotifyStore : NSObject

// 录制（tweak 调用）。date 传 nil 时自动用当前时间。
+ (void)recordWithBundle:(NSString *)bundle
                   title:(nullable NSString *)title
                 message:(nullable NSString *)message
               subtitle:(nullable NSString *)subtitle
                    date:(nullable NSDate *)date;

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
// NO 时按天，key 是 @"day"（yyyy-MM-dd），只回有记录的天。
// 🔴 用 `localtime`：库里存的是 unix 时间戳，**不转换会得到 UTC 的小时**
//    ⇒ 用户看到"我明明晚上收到的，却算在凌晨"。
+ (NSArray<NSDictionary *> *)statsBucketsSince:(NSTimeInterval)since
                                     beforeTs:(NSTimeInterval)beforeTs
                                       byHour:(BOOL)byHour;
// 统计页顶部那一行：总条数、未读、覆盖多少个 App、最早一条的时间。
// 🔴 返回的字典里 key 固定为 total / unread / apps / earliest（earliest 是 NSDate 或 nil）。
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

@end

NS_ASSUME_NONNULL_END
