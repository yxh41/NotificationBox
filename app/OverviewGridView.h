//
//  OverviewGridView.h
//  NotifyBox
//
//  v0.0.164：列表顶部的「双列总览网格」。
//
//  🔴 它解决的是一件列表本身答不了的事：列表按时间倒序排，**一屏只能看到 5~6 行**，
//     而"今天到底有几个 App 在吵我、各自几条"这件事要翻十几屏才能拼出来。
//     图标栏（`reloadIconBar`）只给图标 + 红点，不给**条数**和**最新那条是什么**。
//
//  🔴 边界：这个视图**只负责画**。聚合、排序、时间文案、App 显示名全部由调用方算好
//     塞进 `NBOverviewCard` —— 这里不碰 `NotifyStore`、不碰 `self.items`。
//     理由：一旦这里也读一遍库/数组，就会出现"网格数的是 47 条、列表装的是 43 条"
//     这种两个来源各说各话（本项目反复栽的一类）。
//
//  🔴 它不是一个独立的筛选器：点一张卡片就是调用方去设 `filterBundle`，
//     和点顶部图标**走同一条路**。不许在这里再写一份过滤逻辑。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 一张卡片要显示的全部内容。**全部字段都要调用方填好**（本类不做兜底计算）。
@interface NBOverviewCard : NSObject

/// 点卡片时回传的 bundle id（也是图标来源）
@property (nonatomic, copy) NSString *bundleId;
/// App 显示名（调用方用 `appNameForBundle:` 算）
@property (nonatomic, copy) NSString *name;
/// 最新一条的摘要，单行、超出由本类截断
@property (nonatomic, copy) NSString *line;
/// 时间短文案（"14:32" / "昨天" / "11/2"），**由调用方格式化**
/// 🔴 为什么不在这里格式化：列表 cell 里已经有一套同样的时分判断，
///    两处各写一份必然有一天对不上（"网格说昨天、列表说 11-02"）。
@property (nonatomic, copy) NSString *timeText;
/// 条数。**是组内真实条数之和**（折叠行的 `nbGroupCount` 累加），不是行数
@property (nonatomic, assign) NSInteger total;

@end

@interface NBOverviewGridView : UIView

/// 点某张卡片。调用方在这里设 `filterBundle` 并重查。
@property (nonatomic, copy, nullable) void (^onSelectBundle)(NSString *bundleId);

/// 当前范围内**一共有多少个 App**（可能大于 `cards.count`，超出部分只在脚注里报数）
@property (nonatomic, assign) NSInteger totalApps;
/// 当前范围内**一共有多少条**（同样按 `nbGroupCount` 累加）
@property (nonatomic, assign) NSInteger totalCount;

/// 一次把所有卡片交进来（内部自己建/复用子视图）。
- (void)setCards:(NSArray<NBOverviewCard *> *)cards;

/// 最多显示几张卡片。超过的部分不画，但 `totalApps`/`totalCount` 仍按全量报。
+ (NSInteger)maxCards;

/// 给定卡片数时本视图**应该**多高。调用方拿它定 `tableHeaderView.frame`
/// 🔴 高度只由卡片数决定，**与宽度无关**（列数恒为 2）——
///    这样即使调用时屏幕宽度还是 0（首屏早于布局），也能算出一个正确的高度。
+ (CGFloat)heightForCardCount:(NSInteger)count;

@end

NS_ASSUME_NONNULL_END
