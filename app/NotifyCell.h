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

// 未读标记 = 卡片**右下角的圆形角标**（带未读数）。
// 历史：v0.0.35 左侧蓝点 → v0.0.72 右上角 V 形书签 → **v0.0.88 右下角圆形角标**。
// 🔴 为什么这次又要挪：v0.0.88 起「时间」搬到了**第一行右端**（对齐 HyperOS 的排法），
//    而右上角正是书签的位置 —— 两个都要右上角必然打架。挪到右下角后，
//    第一行右端只剩时间，正文右下角留给计数，各占一角互不相干。
// 🔴 为什么角标上要带数字：蓝点只能回答"这条读过没"，回答不了
//    "这个 App 一共压了几条没看"。`count` 由**当前列表**里数出来（不查库）——
//    🔴 拿全库数来讲当前列表，就会出现"角标写 12、列表里只有 1 条"这种自相矛盾
//    （本项目栽过同构的坑：红点按全库算、列表按时间窗查）。
// 🔴 已读时角标必须**真的消失**（hidden），不能只改颜色 —— 未读要能"数出来"。
- (void)setUnread:(BOOL)unread count:(NSInteger)count;

// v0.0.48：关键词"标星"动作。v0.0.72 在右下角；**v0.0.88 起在第一行右端、紧挨时间左边**。
// 🔴 为什么又挪：右下角这次让给了未读圆形角标（见上）。
//    放第一行右端是"不占正文空间"的位置 —— 正文最多两行、本来就紧。
// 🔴 传 NO 时 ★ 必须真的消失（hidden）—— 和未读角标同一条纪律。
- (void)setStarred:(BOOL)starred;

// ================= v0.0.95：同内容归并的「×N」徽章 =================
// 传这一组有几条。**count < 2 ⇒ 徽章不占位**（宽度回 0，App 名补回那 40pt）。
// 🔴 它会改布局（App 名起点 + 宽度），所以 cell 内部会 `setNeedsLayout` ——
//    和 ★ 那种"位置固定、只切 hidden"的标记不是一类东西，别照抄 ★ 的写法。
- (void)setGroupCount:(NSInteger)count;

// v0.0.88：该 App 的**品牌色**（卡片淡染 + 未读角标底色都由它派生）。传 nil = 中性卡片底。
// 🔴 由 `AppIconLoader brandColorForBundle:` 给出，**cell 自己不去查图标**：
//    那样"取色"会散落在布局阶段，第一次滚到某行时现场算、第二次走缓存 ⇒
//    同一屏里颜色对不对完全取决于滚动顺序，出了问题没法复现。
// 🔴 必须在 `setTitleText:`/`setUnread:` **之前**调：它会顺手把角标底色也刷一遍，
//    调晚了角标会先用着默认蓝、再被刷掉（表现为角标闪一下颜色）。
- (void)setBrandColor:(nullable UIColor *)brand;

// ================= v0.0.92：自定义左滑删除 =================
// 🔴 为什么不用系统的 `trailingSwipeActionsConfigurationForRowAtIndexPath:`：
//    它把**整个 cell**（含 `contentView`）一起左移，而图标就挂在 `contentView` 上
//    ⇒ 图标必然跟着卡片一起走。用户要的是「卡片动、图标原地缩小渐隐」，
//    系统 API 做不到这件事 —— 它只给"整行位移 + 一个铺满整行高、直角的红块"。
//    ⇒ 自己画：卡片单独位移（`cardView.transform`）、图标单独缩放渐隐（`iconBox`）、
//      红色删除按钮自己做一个与卡片**同高同圆角**的。
// 🔴 点删除时回调。**捕获的必须是 rowId，不是 indexPath** ——
//    cell 会被复用，indexPath 随时会变，捕获它就是"删错行"的定时炸弹。
@property (nonatomic, copy, nullable) void (^nbOnDelete)(void);
// 开始左滑时通知列表：同一时刻只允许一行是打开的 ⇒ 列表用它关掉别的那行。
@property (nonatomic, copy, nullable) void (^nbOnSwipeBegin)(void);
// 当前是否处于"打开"状态（列表在 didSelectRow 里据此判断"该收起还是该进详情"）。
@property (nonatomic, readonly) BOOL nbIsSwiped;
// 收起。滚动开始时列表调它（否则一边滚一边有一行歪着，看着像渲染错位）。
- (void)nbCloseSwipeAnimated:(BOOL)animated;

+ (CGFloat)height;

@end

NS_ASSUME_NONNULL_END
