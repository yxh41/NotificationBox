#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// App 图标加载（v0.0.10）
// 为什么要专门一个类：取图标在越狱环境下**没有任何一条保证成功的路**，
// 而且失败时是静默的（返回 nil ⇒ 退化成首字母色块），根本看不出是"没权限"
// 还是"参数填错"还是"这个方法在本版不存在"。
// 所以这里做三件事：多策略依次尝试 + 结果缓存 + **把每条策略的成败记下来**给诊断页看。
@interface AppIconLoader : NSObject

// 拿图标；失败返回 nil（调用方自己退化）
+ (nullable UIImage *)iconForBundle:(nullable NSString *)bundleId;

// 诊断报告：每条策略成/败的原因，一行人话
+ (NSString *)diagReport;

// 清空缓存（诊断页「重新取」用）
+ (void)clearCache;

@end

NS_ASSUME_NONNULL_END
