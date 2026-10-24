#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// v0.0.46：统计页 —— 回答「哪个 App 最烦人」和「一天里什么时候最吵」。
//
// 🔴 为什么值得单开一页：库里已经攒了几百上千条，却只能一条条往下翻。
//    "攒了数据却看不出规律"是这类记录工具最常见的缺口，
//    而答案其实都在库里 —— 差的只是一个 GROUP BY 和一个看法。
// 🔴 三个维度（按 App / 按小时 / 按天）共用**同一个**时间窗，
//    且时间窗和列表的口径一致（`ts >= since`）——
//    否则又会出现"顶部说 100 条、下面加起来是 60 条"这种两个指标打架的老毛病。
@interface NotifyStatsViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
