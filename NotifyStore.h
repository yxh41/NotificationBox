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
+ (NSArray<NSDictionary *> *)queryWithBundle:(nullable NSString *)bundle
                                       since:(NSTimeInterval)since   // 0 = 不限
                                      search:(nullable NSString *)q  // nil = 不限
                                  unreadOnly:(BOOL)unreadOnly;        // YES = 只回 read=0
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

// 设置（App 侧的**唯一**读写入口；tweak 侧读走 NotifyCommon.h 的 NBLoadSettings）
// 🔴 统一在这里写，别让每个 VC 各写一遍 writeToFile: —— 写入点一多，
//    "某个页面写了、另一个页面没写" 这类 bug 就必然出现。
+ (NSDictionary *)settings;
+ (BOOL)saveSettings:(NSDictionary *)settings;

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
