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
+ (NSInteger)maxRecords;                           // 从 prefs 读上限

// 维护
+ (void)markRead:(NSInteger)rowId;
+ (void)clearAll;

// 自检（盒子 App 空列表时直接显示，用来判断沙盒可达性）
+ (NSInteger)count;
+ (NSString *)debugSummary;
+ (NSString *)logText:(NSUInteger)maxBytes;   // 读 tweak.log 尾部，给 App 内查看

// 🔴 关键判据：盒子 App 启动时也往同一个日志文件写一行。
//    日志里若只有 [APP-ALIVE] 而没有 [SpringBoard] 的 loaded 行
//    ⇒ 说明路径可写、但 tweak 没注入（而不是写不进）。
+ (void)markAppAlive;

@end

NS_ASSUME_NONNULL_END
