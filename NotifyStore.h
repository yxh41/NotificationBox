#import <Foundation/Foundation.h>

@interface NotifyStore : NSObject

// 录制（tweak 调用）
+ (void)recordWithBundle:(NSString *)bundle
                   title:(NSString *)title
                 message:(NSString *)message
               subtitle:(NSString *)subtitle
                    date:(NSDate *)date;

// 查询（盒子 App 调用）
+ (NSArray<NSDictionary *> *)queryWithBundle:(nullable NSString *)bundle
                                       since:(NSTimeInterval)since   // 0 = 不限
                                      search:(nullable NSString *)q; // nil = 不限
+ (NSArray<NSString *> *)distinctBundles;          // 顶部 App 图标栏
+ (NSInteger)maxRecords;                           // 从 prefs 读上限

// 维护
+ (void)markRead:(NSInteger)rowId;
+ (void)clearAll;

@end
