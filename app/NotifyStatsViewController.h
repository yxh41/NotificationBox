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

// ================= v0.0.187：统计页行内行动 =================
// 「微信 18 条」这一行的下一步不只是"看看那 18 条"，也可能是"别再吵了"。
// 这一页是全 App 唯一把"哪个 App 最烦人"排好序的地方，把行动放在这里，
// 用户就不用记着名字再跑去设置页找一遍。
//
// 🔴 只做**两个**动作，第三个（只看这个 App）走上面的 `drilldownHandler` ——
//    它需要一个时间窗参数，和这两个的语义不同，⛔ 不要为了"凑一个三选一菜单"
//    把它塞进这个 block 里（那样就得在这里也编一份时间窗映射表，两份必走岔）。
//
// 🔴 这一页依然**不知道**写入是怎么实现的、提示贴在哪儿：它只喊一声"对这个 App 做这件事"。
//    真正落盘的是记录页（那边才有回读纪律和 App 名字），提示由容器贴 ——
//    因为它同时罩着两个页签，贴在它上面无论当前在哪一页都看得见。
//
// 🔴🔴 枚举必须写在 `@interface` **外面**：`@interface` 体内只接受属性/方法声明，
//    在里面写 `typedef` 会被 clang 直接报错（本项目在 NotifyFilter.h 上已经栽过
//    一模一样的跟头，那次是把枚举塞进了方法声明中间）。
typedef NS_ENUM(NSInteger, NBStatAppAction) {
    /// 临时静音 1 小时（复用记录页那套写入 + 回读；固定 1 小时，见 ViewController.h 的说明）
    NBStatAppActionMuteOneHour = 0,
    /// 加进「不记录」名单：以后不再落库，**已有记录保留**
    NBStatAppActionSkipRecord  = 1,
};

@interface NotifyStatsViewController : UIViewController

// ================= v0.0.186：点排行某一行 ⇒ 去记录页看这个 App =================
// 🔴 为什么用 block 而不是让这一页直接去调 `ViewController`：
//    那会让两个页面互相 import 头文件，以后任何一页改名都牵连另一页。
//    这里只声明"我要出去"这件事，**由容器（`NBHomeTabBarController`）决定接到哪儿** ——
//    统计页至今不知道记录页是个什么类，这也让它可以被单独 push 而不崩。
// 参数：`bundle` 目标 App；`days` 时间窗多少天 —— 0 = 全部、7 = 7 天、
//       **负数 = 这一档在记录页没有对应档，别动时间窗**（见点按处的映射表）。
@property (nonatomic, copy, nullable) void (^drilldownHandler)(NSString *bundle, NSInteger days);

/// `bundle` 一定非空（空的行在统计页根本不会挂动作）。
@property (nonatomic, copy, nullable) void (^appActionHandler)(NSString *bundle, NBStatAppAction action);

@end

NS_ASSUME_NONNULL_END
