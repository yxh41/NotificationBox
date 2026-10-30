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

// v0.0.88：该 App 的「品牌色」—— 首页卡片淡染用。
// 🔴 系统**没有**任何 API 能给出"某 App 的主题色"，唯一稳定可得的品牌信息就是图标，
//    所以这里是从图标像素里统计主色（去白/去黑/去灰后按饱和度加权取最大色相簇）。
// 🔴 三条退化链，缺一条就会在真机上出现"一片卡片没有颜色"或"随机变色"：
//    ① 图标本身取不到 ⇒ ② 图标是纯白/纯灰（没有主色）⇒ 都退到
//    `NBBrandFallback()`（按 bundle 稳定哈希取调色板，同一 App 永远同一色）。
//    ③ 连 bundleId 都没有 ⇒ 返回 nil，调用方用中性卡片底（绝不硬造一个颜色）。
+ (nullable UIColor *)brandColorForBundle:(nullable NSString *)bundleId;

// 诊断报告：每条策略成/败的原因，一行人话
+ (NSString *)diagReport;

// 清空缓存（诊断页「重新取」用）
+ (void)clearCache;

@end

NS_ASSUME_NONNULL_END
