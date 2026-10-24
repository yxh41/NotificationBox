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
+ (NSArray<NSDictionary *> *)queryWithBundle:(nullable NSString *)bundle
                                       since:(NSTimeInterval)since   // 0 = 不限
                                      search:(nullable NSString *)q; // nil = 不限
+ (NSArray<NSString *> *)distinctBundles;          // 顶部 App 图标栏
// v0.0.13：bundle -> 通知条数。App 选择器用它把「经常来通知的」排前面。
+ (NSDictionary<NSString *, NSNumber *> *)bundleCounts;
+ (NSInteger)maxRecords;                           // 从 prefs 读上限

// 维护
+ (void)markRead:(NSInteger)rowId;
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
