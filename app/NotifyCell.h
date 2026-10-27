#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 列表 cell（v0.0.10）
// 🔴🔴 之前「只有标题、没有内容」的根因：
//    列表用 `registerClass:[UITableViewCell class]` 注册，它建出来的是 **Default 样式**，
//    而 Default 样式里 **`detailTextLabel` 压根不显示**（它是 nil 或不可见）。
//    代码一直在往 detailTextLabel 上写正文 ⇒ 写了但永远看不见。
//    ⇒ 要么在 dequeue 返回 nil 时自己 `initWithStyle:UITableViewCellStyleSubtitle`，
//      要么干脆自定义 cell（本类，还能顺手放图标）。
@interface NotifyCell : UITableViewCell

// 图标：传 nil 时显示首字母色块（退化态，不能什么都不显示）
- (void)setIcon:(nullable UIImage *)icon letter:(nullable NSString *)letter;

- (void)setTitleText:(nullable NSString *)title
             message:(nullable NSString *)message
            subtitle:(nullable NSString *)subtitle;

- (void)setTimeText:(nullable NSString *)text;

// v0.0.42：这条记录的 App 名（小字，标题上面一行）。
// 🔴 为什么必须有：以前整行只有图标 + 标题 + 正文 + 时间，**没有一个字说这是哪个 App**。
//    图标加载失败时退化成一个首字母（「b」「m」这种），十几个 App 混在一列里根本分辨不出来。
//    而"谁在打扰我"恰恰是这个盒子最该回答的问题。
// 🔴 传 nil / 空串时整行高度**不变**（只是这一行空出来）—— 行高是常量，
//    不能因为某个 App 的名字取不到就参差不齐。
- (void)setAppName:(nullable NSString *)name;

// v0.0.44：搜索命中高亮。传当前搜索词（nil / 空串 = 不高亮）。
// 🔴 为什么必须有：搜索现在能命中**标题 / 正文 / 副标题 / App 名**四处，
//    列表里却一个字都不标 ⇒ 用户看到一条"标题里根本没有这个词"的记录，
//    第一反应是"搜索坏了"，而它其实是被正文或 App 名命中的。
// 🔴 调用顺序无关：`setHighlightQuery:` 和 `setTitleText:`/`setAppName:` 谁先谁后都一样
//    —— 它们都只存原始串，真正的渲染统一在 `nbRender` 里做。
- (void)setHighlightQuery:(nullable NSString *)query;

// v0.0.72：未读标记 = 卡片**右上角的书签**（带未读数）。v0.0.35~71 的「左侧 8pt 蓝点」已删除。
// 🔴 为什么换掉蓝点：它在图标左边，为了让它有位置，整块内容被往右推了 20pt，
//    于是卡片里**没有一个统一的左缘** —— 图标 20、标题 78、正文 78，
//    乍看还行，一屏十几张卡片叠起来"边缘参差"非常明显。
//    书签挂在卡片的角上、完全不占正文的横向空间，左边一整列就对齐了。
// 🔴 为什么书签上要带数字：蓝点只能回答"这条读过没"，回答不了
//    "这个 App 一共压了几条没看"。`count` 由**当前列表**里数出来（不查库）——
//    🔴 拿全库数来讲当前列表，就会出现"书签写 12、列表里只有 1 条"这种自相矛盾
//    （本项目栽过同构的坑：红点按全库算、列表按时间窗查）。
// 🔴 已读时书签必须**真的消失**（hidden），不能只改颜色 —— 未读要能"数出来"。
- (void)setUnread:(BOOL)unread count:(NSInteger)count;

// v0.0.48：关键词"标星"动作（v0.0.72 起在**右下角** ★，展示时派生、不落库）。
// 🔴 为什么从右上角挪走：右上角现在是未读书签的位置，两个都挤在那里必然重叠。
//    挪到「时间」那一行的右端正好对称：时间在左、★ 在右，同一行基线。
// 🔴 传 NO 时 ★ 必须真的消失（hidden）—— 和未读书签同一条纪律。
- (void)setStarred:(BOOL)starred;

+ (CGFloat)height;

@end

NS_ASSUME_NONNULL_END
