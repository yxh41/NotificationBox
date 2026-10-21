#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 内容替换规则编辑（v0.0.9）
// 引擎侧（NotifyFilter 的 applyReplaceRulesTo）在 v0.0.8 就已接线，这里只补 UI。
// 存储键：settings.plist 里的 replaceRules = [{from, to}, ...]
@interface ReplaceRulesViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
