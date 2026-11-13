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

// ================= v0.0.176：整 App 被临时静音时的视觉态 =================
// `muted` ⇒ 卡片整体压暗 + 左缘一条琥珀竖条；`animated` ⇒ 0.22s 过渡（熄灯感）。
//
// 🔴 为什么这个状态必须落在 **cell** 上，而不是"VC 给某一行的 cell 加个遮罩"：
//    静音是**按 App** 的（`NotifyFilter shouldDropForMute:` 的唯一判据就是 bundleId），
//    同屏可能有 5 行属于同一个 App。只给"刚点的那一行"做效果 ⇒ 滚出去再滚回来就没了，
//    另外 4 行还亮着，用户根本看不出"这个 App 现在不响"。
//    ⇒ 由 `cellForRow` 每次**无条件**刷（和 `setAliveTag:` 同一条纪律：
//      "凡是 setter 改过的外观，prepareForReuse 必须改回去"）。
//
// ⚠️ 只动 `cardView.alpha` 和自建的那条竖条，**不碰 `cardView.transform` / `iconBox`**
//    —— 那几样归 `nbApplyOffset:` 独占（位移的唯一出口），碰了就会出现
//    "滑到一半卡片自己变亮"这类没法解释的闪动。
- (void)nbSetMutedLook:(BOOL)muted animated:(BOOL)animated;

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

// ================= v0.0.124：自定义右滑（翻转已读态） =================
// 和左滑完全对称（同样是自绘、同样挂在 contentView、同样在 cardView 下层），
// 区别只有三点：① 方向相反（卡片往右移，按钮从左侧露出来）；② 颜色是蓝不是红；
// ③ **没有「滑到底就执行」** —— 只在点按钮时才执行。
// 🔴 为什么右滑不给全滑触发：翻转已读态是**轻操作**，而全滑（full swipe）在用户心里
//    是"我要把它弄掉"的手势。给它配全滑，列表里横向划一下就把一批标成已读了，
//    而且没有任何确认步骤 —— 这正是本项目反复吃的那个亏（破坏性动作要好滑，好滑的动作不该破坏）。
// 🔴 **文案由 cell 自己定**（按当前是否未读翻转），列表不需要知道这一行是已读还是未读：
//    `nbOnToggleRead` 只是"用户按了那个按钮"，语义由 cell 的文案决定，两者必须同源
//    （否则会出现"按钮写着标为已读、按下去却标成了未读"）。
// 🔴 捕获的仍然是 rowId 那一组的数组快照，⛔ 不是 indexPath（理由同 `nbOnDelete`）。
@property (nonatomic, copy, nullable) void (^nbOnToggleRead)(void);

// ================= v0.0.186：VoiceOver 的动作入口 =================
// 🔴 为什么需要它们：到 v0.0.185 为止，`accessibilityCustomActions` 在整个工程里
//    **零命中** —— 删记录、翻已读这两件事只有"左滑/右滑"一个入口，而 VoiceOver 下
//    横向滑动被系统拿去当"逐项浏览"了 ⇒ 这两件事对 VoiceOver 用户**根本不存在**。
//    长按菜单虽然还在，但 VoiceOver 下需要双指长按、而且不容易发现。
// ⇒ 由 cell 把已有的四个动作挂到 `accessibilityCustomActions` 上（见 .m）。
// 🔴 为什么"复制内容 / 打开 App"要由列表交进来、而"删除 / 翻已读"不用：
//    后两件 cell 手上已经有回调（`nbOnDelete` / `nbOnToggleRead`），前两件需要
//    完整正文（cell 只有截断后的显示串）和 bundle/深链（cell 根本不知道）——
//    那些都在列表那边。cell 拿到的只是"按了就叫我"，实现只有一处。
// 🔴 和 `nbOnToggleRead` 同一条纪律：语义（「标为已读」还是「标为未读」）由 cell
//    按当前状态决定，列表只负责执行 —— 否则会出现"念的是已读、按下去变未读"。
@property (nonatomic, copy, nullable) void (^nbOnCopy)(void);
@property (nonatomic, copy, nullable) void (^nbOnOpen)(void);

// ================= v0.0.118：长按卡片弹菜单 =================
// 列表把「这一行的菜单怎么拼」交进来；cell **不**知道 App 名、也不知道怎么打开 App
// （那些是列表 / Store 的事）。返回 nil ⇒ 这一行不弹菜单。
// 🔴 为什么用 `UIContextMenuInteraction` 而不是自己挂长按 + 弹 actionSheet：
//    ① 长按 → 卡片"浮起来"+ 菜单贴在卡片边上，这正是用户在系统通知里看到的那个样子
//       （打开 / 系统设置 / 更多），换成从底部滑上来的 actionSheet 就变味了；
//    ② 系统自己处理了「长按期间手指移动就取消」「菜单和滚动的互斥」这些边界，
//       自己写长按 + pan 两套手势去抢，是本项目最容易翻车的路子（点一次执行两遍那种）。
// 🔴 但**菜单内容完全不归 cell 管**：block 由列表每次 cellForRow 时现设，
//    这样"菜单里有什么动作"只有一处定义（列表），cell 复用也不会带着上一行的动作跑。
@property (nonatomic, copy, nullable) UIMenu *(^nbMenuBuilder)(void);

// ================= v0.0.98 / v0.0.106：通知中心残留标记（卡片四周一圈细线） =================
// 传 `NBAliveState`：1 = 上次清理时仍在通知中心 ⇒ 卡片四周一圈橙细线；其余（0/2）不显示。
// 🔴🔴 v0.0.106：原来是「卡片左缘一条 4pt 竖色条」，用户要求改成**整卡一圈细线**。
//    实现从"单独挂一个 aliveBar 视图"换成"直接设 `cardView.layer.borderWidth/borderColor`"：
//    ① 天然跟卡片走（左滑位移 / 圆角 14 / clipsToBounds 全部一致），不会有"无主的橙线"；
//    ② **仍然不占任何横坐标** —— border 画在卡片边框上，`appW` 的算账一个字都不用动，
//       所以"对布局的影响是 0"这条结论继续成立（本项目"数量契约"里唯一安全的那条路：
//       不改数量、只改长相）。
//    ③ 少一个视图 ⇒ 少一处复用时串色的风险。
// 🔴 它必须**能收回去**：cell 会被复用，忘了在 `setAliveTag:0` 时把 borderWidth 归零，
//    就会出现"橙框串到别的行上"——复用池里最容易串的正是这种装饰
//    （同类事故见 `pinView` 的注释；`prepareForReuse` 里也补了一道复位）。
- (void)setAliveTag:(NSInteger)state;

+ (CGFloat)height;

@end

NS_ASSUME_NONNULL_END
