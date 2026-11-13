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

// ================= v0.0.186：点排行某一行 ⇒ 去记录页看这个 App =================
// 🔴 为什么用 block 而不是让这一页直接去调 `ViewController`：
//    那会让两个页面互相 import 头文件，以后任何一页改名都牵连另一页。
//    这里只声明"我要出去"这件事，**由容器（`NBHomeTabBarController`）决定接到哪儿** ——
//    统计页至今不知道记录页是个什么类，这也让它可以被单独 push 而不崩。
// 参数：`bundle` 目标 App；`days` 时间窗多少天 —— 0 = 全部、7 = 7 天、
//       **负数 = 这一档在记录页没有对应档，别动时间窗**（见点按处的映射表）。
@property (nonatomic, copy, nullable) void (^drilldownHandler)(NSString *bundle, NSInteger days);

@end

NS_ASSUME_NONNULL_END
