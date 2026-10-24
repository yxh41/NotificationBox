#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// v0.0.48：关键词自动规则编辑（**展示时生效、纯盒子 App 端**，tweak 侧零改动）。
// 存储键：settings.plist 的 keywordRules = @[@{@"keyword":…, @"star":@BOOL, @"fold":@BOOL}]，
// 读写**全走 NotifyStore**（`keywordRules` / `saveKeywordRules:`），这里不自己碰 settings.plist。
// 上限 20 条（闸门和 NotifyStore 同一数字）。
@interface KeywordRulesViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
