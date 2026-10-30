#import "ViewController.h"
#import "NotifyStore.h"
#import "NotifyCommon.h"
#import "SettingsViewController.h"
#import "NotifyCell.h"
#import "AppIconLoader.h"
// v0.0.33：点开看全文 + 复制 + 删单条
#import "NotifyDetailViewController.h"
// v0.0.42：App 显示名（bundle -> 名字）。列表要显示它，搜索也要用它匹配。
#import "InstalledApps.h"
#import "NotifyExport.h"     // v0.0.44 导出
// v0.0.71：统一视觉层（颜色 / 圆角 / 图标 / 分组卡片的唯一来源）
#import "NBTheme.h"

// v0.0.38：「全标已读」按钮的固定宽度。「全标已读」4 个汉字 @14pt ≈ 56pt，
// 加左右各 16pt 内边距 ⇒ 88 够宽裕。写常量是因为布局里要拿它算分段控件的宽度，
// 两处各写一个数字的话，改了其中一个就会出现"按钮压住分段控件"。
static const CGFloat kNBMarkAllWidth = 88;

// 🔴🔴 v0.0.70：顶部控件的**统一规格**。
//    以前每个控件各写各的数字：分段 30、按钮 30、圆角 7、上下间距 6、左右边距 12。
//    改一个尺寸就得记住另外四处，漏一处就是"某一排比别的排高 2pt"——
//    这种 2pt 的错位肉眼说不出来，但整屏就是不整齐。
//    ⇒ 现在高度 / 圆角 / 间距 / 边距各自只有**一处**定义，`viewDidLayoutSubviews` 全用它。
static const CGFloat kNBTopMargin = 12;   // 左右边距
static const CGFloat kNBTopH      = 32;   // 分段 / 按钮 / 标星 的统一高度
static const CGFloat kNBTopGap    = 8;    // 行与行之间的竖向间距
static const CGFloat kNBTopRadius = 8;    // 按钮圆角（与卡片 12 形成层级：小的更小）
static const CGFloat kNBHintH     = 20;   // 两条小字提示的统一高度

// v0.0.42：搜索防抖窗口。
// 250ms 的依据：真人连续打字的间隔通常在 100~200ms，250ms 能吃掉整串输入；
// 再长（比如 500ms）用户会觉得"我打完了它还没反应"。
static const NSTimeInterval kNBAutoSearchDelay = 0.25;

// 🔴 盒子 App：读 NotifyStore 的 SQLite，展示通知列表
//    - 顶部横向 App 图标栏（抖音聊天页那种）：点击筛选对应 bundle
//    - 时间分段：近24小时 / 近7天 / 不限时间（v0.0.37 起如实命名）
//    - 搜索框：标题/正文模糊搜
//    - 列表：图标占位 + 标题 + 正文 + 时间
//
// ⚠️ TODO（真机）：App 图标用 LSApplicationProxy 取
//    `[[LSApplicationProxy applicationProxyForIdentifier:bid] iconDataForVariant:...]`
//    这里先用「bundle 末段首字母 + 色块」占位。

@interface ViewController ()
@property (nonatomic, strong) UIScrollView *iconBar;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UISegmentedControl *timeSeg;
// v0.0.37：全部 / 只看未读。**自己画一个分段控件**，不用 UISearchBar 的 scope bar。
// 🔴 v0.0.36 用的是 `searchBar.showsScopeBar = YES`，代码没错（顺序也是先 titles 后 shows），
//    但真机 iOS 16 上 scope bar 根本没渲染出来 —— 用户反馈"没看到未读这些字眼"。
//    没有 Mac/调试器的情况下，去赌系统的内部布局行为不划算：
//    同一屏里「今天/近7天/全部」这个 UISegmentedControl 一直是好的，
//    那就用同一种控件，行为 100% 可预期，也顺手去掉 88/44 的高度赌博。
@property (nonatomic, strong) UISegmentedControl *unreadSeg;
// v0.0.71：顶部控制区的那张白卡片（时间分段/搜索/★+未读/两条提示都装在里面）
@property (nonatomic, strong) UIView *topCard;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, strong) NSArray<NSString *> *bundles;
@property (nonatomic, copy)   NSString *filterBundle;   // nil = 全部
@property (nonatomic, copy)   NSString *searchText;
// v0.0.36：只看未读（搜索框下的 scope bar 第 2 段）
@property (nonatomic, assign) BOOL unreadOnly;
// v0.0.36：每个 App 图标右上角那个红点，key = bundle。
// 🔴 存引用是为了**只刷新红点、不重建按钮** —— 重建会让 `contentSize` 重设，
//    把图标栏的滚动位置重置到最左（选了第 10 个 App，点开一条就跳回开头）。
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *unreadDots;
// v0.0.72：每个 App 在**当前列表里**还有几条未读（key = bundle），给 cell 的未读书签用。
// 🔴 为什么从 `self.items` 数、而不是查库：书签和列表是**互相解释的两个数**
//    （本项目栽过：红点按全库算、列表按时间窗查 ⇒ 用户看到「有红点 → 点进去暂无记录」）。
//    `items` 就是眼睛看到的这一批，从它数出来的数永远不会和列表打架。
// 🔴 为什么不在 cellForRow 里现算：那是 O(列表长度) × 每次滚动重排，
//    而它只在「整表重查」和「点开一条变已读」这两处才会变 ⇒ 在这两处重建一次就够。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *nbUnreadByBundle;
// v0.0.38：「只看未读」时右侧多一个「全标已读」。
// 🔴 为什么放在分段控件同一行、而不是导航栏：右边已经有「诊断」「清空」两个，
//    再塞一个会把标题「消息盒子 (N)」挤没 —— iPhone 竖屏导航栏就只有那么宽。
//    这一行是我们自己布局的（v0.0.37 起 unreadSeg 是自绘的），加宽加窄都说了算。
@property (nonatomic, strong) UIButton *markAllBtn;
// v0.0.38：上一次刷新时的**库指纹**（条数 + 最大行 id）。
// 🔴 为什么不能只看条数：记录数到达上限以后，tweak 每来一条新通知都会先裁掉一条
//    最旧的 ⇒ 条数恒定。只看条数的话，"库满了以后每次来通知"这个最常见的场景
//    恰好检测不到 —— 而它正是用户最需要列表自己更新的场景。
//    id 是自增的，新记录一定让 MAX(id) 变大；删除只会让条数变小。
//    两个数一起看，新增和删除都盖得住。
@property (nonatomic, assign) NSInteger lastTotal;
@property (nonatomic, assign) NSInteger lastMaxId;
// v0.0.40：**当前筛选之外还有多少条未读**（= 全库未读 − 当前筛选下的未读）。
// 🔴 为什么非要有这个数：红点从 v0.0.37 起是「App + 时间窗」口径（和列表同口径，才清得掉）。
//    于是出现一个信息缺口 —— 当前筛选下一条未读都没有、而筛选之外还有 12 条未读时：
//    **红点全灭 + 列表可能不空（有已读记录）⇒ 界面上一个字都不提示**，
//    用户会断定"全都读完了"，然后那 12 条永远不会被看到。
// 🔴🔴 v0.0.39 的第一版把范围写成"比时间窗更早"，真机上一装就发现**永远看不到**：
//    默认时间窗就是 24 小时，库里记录都在 24 小时内时"更早"恒为 0。
//    ⇒ 改成算**三个筛选维度一起**（App 图标 + 时间 + 搜索），因为这三个任何一项
//    都会让一部分未读看不见，而用户只关心"还有没有我没看到的"。
// ⇒ 所以名字从 `olderUnread` 改成 `hiddenUnread`：「更早」是错的名字，
//    名不符实在这个项目里栽过（第 0 段时间曾叫「今天」而实际是 now-86400）。
@property (nonatomic, assign) NSInteger hiddenUnread;
// v0.0.40：上面那个数的常驻出口（一行小字，`hiddenUnread > 0` 才占位）。
// v0.0.41：**从 UILabel 改成 UIButton** —— 提示条现在可点。
// 🔴 为什么可点：它说的是"还有 N 条未读你看不到"，那就必须给一条一步到位的路。
//    原来只在文案里点名出口（"点顶部「全部」图标"），用户还得自己去找那个图标、
//    还要记得把时间和搜索也清掉 —— 三个筛选叠加时文案甚至不能点名。
//    改成点一下就**三样一次清干净**，文案就可以只说事实、不教操作。
// 🔴 为什么不用"给 UILabel 加 tap 手势"：按钮自带按压高亮，用户按下去知道点到了；
//    UILabel 加手势按下去毫无反馈，用户第二次就不点了。
// 🔴 为什么不在文案里写"点这里"：文案已经 20 来字，再塞就换行。
//    统一在末尾加 `›` 当"可以点"的暗示 —— `hiddenHintText` 只产**纯文案**，
//    `›` 是 UI 装饰，只加在按钮上（空列表正中那句是 UILabel、不能点，不能加）。
// 🔴 位置照旧是自己画、自己在 `viewDidLayoutSubviews` 里算 y ——
//    不放导航栏标题、也不放分段控件里：那两处都要**赌系统怎么排**（标题会被压缩/截断，
//    分段控件段宽是系统算的）。v0.0.37 已经被系统 scope bar 教过一次。
@property (nonatomic, strong) UIButton *hiddenHint;
// v0.0.48：关键词"折叠"动作 —— 被规则收起的条数 + 常驻提示条（点一下在"收起/显示"间切换）。
// 🔴 和 hiddenHint 是**两条独立的提示**：hiddenHint 管「未读被筛选挡掉了」，
//    这条管「记录被关键词规则收起了」。两个数不会互相吵（一个是未读口径、一个是全量口径）。
@property (nonatomic, strong) UIButton *foldedHint;
@property (nonatomic, assign) NSInteger foldedCount;   // 被 fold 规则命中的条数（与 showFolded 无关）
@property (nonatomic, assign) BOOL showFolded;          // YES = 把收起的记录也显示出来
// 🔴 折叠**前**的查询条数，专给 `updateMoreFooter` 用（第三禁忌：不能拿折叠后的
//    items.count 去算"还有几条更早"，否则折叠掉的会被误算成"被列表上限截断的"）。
@property (nonatomic, assign) NSInteger queriedCount;
// v0.0.49：★ 只看标星（第五个筛选维度）。和折叠同源：**纯派生、不落库** ——
//    nbStar 由关键词规则现算，SQL 里没有这一列 ⇒ 筛选只能在内存里做
//    （见 applyKeywordRulesToRows:，star 必须先于 fold）。
// 🔴 它和 unreadOnly **正交**：★ 只看标星 + 只看未读 = 标星且未读，两者可叠加。
@property (nonatomic, assign) BOOL starOnly;
// v0.0.49：★ 筛选**之后、折叠之前**的条数。专给 updateMoreFooter 当"当前视图的条数" ——
//    queriedCount 在 ★ 视图下混着非标星的行，直接拿去算差就是"底部说的数和列表
//    装的不是同一个集合"（第三禁忌同款，v0.0.48 为折叠立过同一条）。
@property (nonatomic, assign) NSInteger queriedStarCount;
// v0.0.49：★ 开关按钮（常驻，不随 unreadOnly 进出）。
@property (nonatomic, strong) UIButton *starBtn;
// v0.0.49：关键词规则指纹（settings.plist 派生，不进数据库）—— 见 refreshIfChanged。
@property (nonatomic, copy)   NSArray<NSDictionary *> *lastRules;
// v0.0.42：bundle -> App 显示名。**同时给两件事用**：
//   ① 列表每一行显示「这条是哪个 App 的」—— 以前只有图标，图标加载失败就只剩一个字母；
//   ② 搜索时把「微信」「招商银行」这种词匹配成 bundle 列表，再传给 NotifyStore。
// 🔴 为什么放在界面层算、不放进 NotifyStore：库里只有 bundle id，App 显示名属于
//    界面知识（要 LSApplicationProxy / Info.plist 扫描）。把它写进库就得改 schema +
//    迁移老记录；而**查询时现算**对库里已有的记录**立即生效**，不用重装、不用重记。
// 🔴 `reloadIconBar` 尾部重建 —— `InstalledApps +all` 自己有缓存（`gCache`），
//    所以每次 `loadData` 只是"遍历一个数组塞进字典"，没有 I/O。
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *appNameMap;
// v0.0.42：搜索防抖的**代次**。每敲一个字 +1，挂起的 block 只有代次没变才执行。
// 🔴 为什么必须有这个数：只用一个 BOOL 标记的话，"敲 a、敲 ab、敲 abc" 会排三个
//    250ms 后执行的 block，三个都会跑 ⇒ 一次输入跑三次 `loadData`，比不防抖更慢。
@property (nonatomic, assign) NSUInteger searchGen;
// v0.0.42：列表底部「下面还有 N 条更早记录」。
// 🔴 用 `table.tableFooterView`，**绝不做"假行"** —— 行号必须和 `self.items` 严格一一对应，
//    否则 `reloadRowsAtIndexPaths:` / `deleteRowsAtIndexPaths:` 会错位
//    （v0.0.33 删除场景已经栽过一次）。
// 🔴 和顶部提示条的分工：顶部管「**未读**被筛选掉了」，底部管「**已读**被列表上限截断了」。
//    两个场景互斥，不会同时喊同一件事。
@property (nonatomic, strong) UILabel *moreFooter;

- (void)onDiag:(id)sender;
- (void)onSettings:(id)sender;
// v0.0.35：清空整张表。两个都必须在这里声明 ——
// 🔴 `onClear:` 要用于 `@selector(...)`，`doClear` 在 alert 的 block 里被 `[weakSelf ...]` 调用。
//    未声明 ⇒ ARC 下返回类型被推断成 `id` ⇒ 警告 ⇒ CI 的 `-Werror` 直接挂
//    （v0.0.33 的 `doDelete`/`str:` 就是这么挂过一次）。
- (void)onClear:(id)sender;
- (void)doClear;
// v0.0.44：导出当前筛选的记录成 CSV（`onExport:` 挂按钮，`doExport` 在确认框之后跑）
- (void)onExport:(id)sender;
- (void)doExport;
// v0.0.36：只刷新图标栏红点（不重建按钮，避免图标栏滚动位置被重置）
- (void)refreshUnreadDots;
// v0.0.72：重建"每个 App 在当前列表里还有几条未读"（未读书签的唯一数据源）。
- (void)rebuildBundleUnread;
// v0.0.37：全部 / 只看未读（自己的分段控件，替掉没渲染出来的系统 scope bar）
- (void)onUnread:(UISegmentedControl *)seg;
// v0.0.49：★ 只看标星开关；以及"有没有任何规则带 ★ 动作"（★ 视图为空时区分
//    "这个范围没有标星的" 和 "根本没有任何规则会标星"，后者必须点醒用户去建规则）。
- (void)onStar:(id)sender;
- (BOOL)anyStarRule;
// v0.0.38：批量把当前筛选范围内的未读标成已读
- (void)onMarkAllRead:(id)sender;
- (void)doMarkAllRead;
// v0.0.38：库里变了才重查（保住滚动位置）；以及那个"保住滚动位置的重查"本身
- (void)refreshIfChanged;
- (void)reloadKeepingOffset;
- (void)onForeground:(NSNotification *)note;
// v0.0.40：筛选之外未读的条数（`loadData` 里算，`viewDidLayoutSubviews` 用它决定占不占位）
- (void)updateHiddenUnread;
// v0.0.40：提示文案的**唯一来源**（顶部提示条 + 空列表正中那句都用它产出）
- (NSString *)hiddenHintText;
// v0.0.41：所有**由未读数派生**的界面元素只准从这一个函数更新
// 🔴 为什么必须有它：v0.0.40 把顶部提示条只接在 `loadData` 里，而"点开一条记录"
//    走的是「只刷一行」那条路（不重查库）⇒ 筛选内未读少一条、筛选外那个数变大，
//    提示条却不动。真机复现：点某个 App 图标 → 把它 3 条未读依次读完 →
//    顶部该出现"其它 App 还有 N 条"却不出现。
- (void)refreshUnreadDerived;
// v0.0.41：点顶部提示条 ⇒ 三个筛选一次清干净
- (void)onHiddenHintTap;
// v0.0.48：关键词折叠提示条的点击 / 刷新 / 文案，以及"给查询结果套关键词规则"的唯一出口。
- (void)onFoldedHintTap;
- (void)updateFoldedHint;
- (NSString *)foldedHintText;
- (NSArray<NSDictionary *> *)applyKeywordRulesToRows:(NSArray<NSDictionary *> *)rows;
// v0.0.42：重建 bundle -> App 显示名 映射（`reloadIconBar` 尾部调一次）
- (void)rebuildAppNames;
// v0.0.42：单条查 App 名（查不到退回 bundle 末段，不要显示成空白）
- (NSString *)appNameForBundle:(NSString *)bid;
// v0.0.42：把搜索词匹配成 bundle 列表（匹配 App 显示名**或** bundle id 本身）
- (NSArray<NSString *> *)bundlesMatchingSearch:(NSString *)q;
// v0.0.42：搜索防抖。250ms 内连续输入只跑最后一次
- (void)scheduleLoadData;
// v0.0.42：作废挂起的防抖（"清空筛选"这类动作要立刻执行，不能让挂起的再补一刀）
- (void)cancelPendingLoadData;
// v0.0.42：底部「还有 N 条更早记录」的显隐与文案
- (void)updateMoreFooter;
// v0.0.38：时间段的显示名 / 「App + 时间」两维的范围描述
// 🔴 抽出来是因为确认框文案和空列表文案都用到它，字面量写两处就会不一致
- (NSArray<NSString *> *)timeNames;
- (NSString *)timeName;
- (NSString *)scopeDesc;
// v0.0.36：当前筛选条件的一行文字描述（空列表时写出来，避免"看着空 = 没有"的误判）
- (NSString *)filterDesc;
- (void)showText:(NSString *)text title:(NSString *)title;
// v0.0.33：轻量一行提示（左滑删除失败时用）。
// 不走 showText: —— 那个是"长文本可滚动页"，弹一句"这条已经没了"太重。
- (void)alertTitle:(NSString *)title text:(NSString *)text;
- (NSString *)keyLinesFrom:(NSString *)text;
- (NSString *)selLinesFrom:(NSString *)text;
- (NSString *)probeLinesFrom:(NSString *)text;
- (NSString *)soundDiagFileText;
@end

@implementation ViewController

- (void)dealloc {
    // 🔴 显式移除。iOS 9 起 target-action 形式的观察者已经不会被野指针调用了，
    //    但"读代码的人不用去查这条规则"本身有价值 —— 而且 `removeObserver:` 是幂等的。
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"消息盒子";
    // v0.0.70：卡片化之后，底色必须是**分组灰**（不是 systemBackground 的白）。
    // 🔴 v0.0.71 更正：卡片用的是 `secondarySystemGroupedBackground`（白），
    //    不是 `secondarySystemBackground` —— 浅色模式下后者与分组灰**同为 #F2F2F7**，
    //    卡片会"消失"。这一对必须一起换（见 NBTheme.h 顶部的颜色配对纪律）。
    self.view.backgroundColor = NBPageBG();
    // 在同一日志里打一条「App 活着」，用来和 tweak 的日志对照（见 NotifyStore.h 注释）
    [NotifyStore markAppAlive];
    // ---------- v0.0.71 导航栏改成图标按钮 ----------
    // 🔴 原来是 4 个纯文字按钮（设置 / 诊断 / 导出 / 清空），右侧并排三个中文词
    //    在窄屏上会把中间的标题挤掉，而且"清空"这个不可撤销的动作和"诊断"一样大、
    //    一样显眼。改成图标 + 保留语义顺序：
    //      · 最右（最显眼）= 诊断，最常用；
    //      · 中间 = 导出；
    //      · 最左 = 清空，红色，且它是三个里最不常用的。
    //    `rightBarButtonItems` 里**第一个在最右**，所以数组顺序 = 诊断、导出、清空。
    UIBarButtonItem *diag =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"waveform.path.ecg"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onDiag:)];
    UIBarButtonItem *export =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onExport:)];
    UIBarButtonItem *clear =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"trash"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onClear:)];
    clear.tintColor = [UIColor systemRedColor];   // 不可撤销 ⇒ 和详情页的「删除」同一套视觉
    self.navigationItem.rightBarButtonItems = @[diag, export, clear];
    // 🔴 v0.0.8：设置留在自己 App 里，不再往设置 App 装 PreferenceLoader 载荷
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onSettings:)];

    [self buildUI];
    [self loadData];

    // v0.0.38：App 从后台回前台时**不会**走 `viewWillAppear:` —— VC 一直活着，
    //    只是 window 换了前台。不单独听这个通知的话，"后台来了新通知 → 切回来 →
    //    列表还是老样子"就一直存在，用户只能靠切筛选/搜索来手动触发重查。
    // 🔴 通知回在主线程，可以随便碰 UI。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
}

// v0.0.38：从详情页/设置页返回。`viewWillAppear:` 在**首次显示**时也会调用，
// 那时 `viewDidLoad` 里的 `loadData` 刚跑过、库指纹没变 ⇒ `refreshIfChanged` 直接返回，
// 不会白 reload 一次（否则每次进入 App 都闪一下）。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshIfChanged];
}

- (void)onForeground:(NSNotification *)note {
    [self refreshIfChanged];
}

- (void)onSettings:(id)sender {
    SettingsViewController *vc = [[SettingsViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - 清空（v0.0.35）

// 之前「清空」只有设置页有入口（SettingsViewController.m），要清记录得跑进设置里找。
- (void)onClear:(id)sender {
    NSInteger total = [NotifyStore count];
    if (total == 0) {
        // 空库时**不弹确认**：弹了用户点"清空"，结果什么都没发生，反而以为坏了。
        [self alertTitle:@"没有记录" text:@"数据库里是空的，不用清。"];
        return;
    }

    // 🔴 文案必须报**数据库总数**，不是 `self.items.count`。
    //    这是这一版最容易做错的一处：搜索「验证码」时列表只有 3 条，
    //    而 `clearAll` 清的是整张表。拿列表条数写确认文案 ⇒ 用户以为只删这 3 条。
    NSMutableString *msg = [NSMutableString stringWithFormat:
        @"将删除全部 %ld 条记录，删了不能恢复。", (long)total];
    if ((NSInteger)self.items.count != total) {
        [msg appendFormat:@"\n\n当前列表只显示 %ld 条（有筛选/搜索，或超出单次上限），但会一起清掉。",
         (long)self.items.count];
    }

    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"清空所有记录？"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [al addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        [weakSelf doClear];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)doClear {
    NSInteger n = [NotifyStore clearAll];
    // 🔴 先清库 → 再整表重查。和 v0.0.33 的删除是同一条纪律：
    //    列表的数据只有一个来源（数据库），内存数组永远是从它重建出来的。
    [self loadData];

    if (n > 0) {
        [self alertTitle:@"已清空"
                    text:[NSString stringWithFormat:@"删掉了 %ld 条记录。", (long)n]];
    } else if (n == 0) {
        // `DELETE FROM` 命中 0 行照样返回 SQLITE_OK ⇒ 不能当成功。
        // 最常见的原因是清之前已经被「记录上限」裁光了。
        [self alertTitle:@"没清到"
                    text:@"库里没有可删的记录（可能已被「记录上限」自动清掉）。列表已刷新。"];
    } else {
        [self alertTitle:@"清空失败"
                    text:@"打不开数据库。列表已刷新，可以重启 App 再试。"];
    }
}

#pragma mark - 导出（v0.0.44）

// 🔴 导出的是**当前筛选**的那批记录（App 图标 + 时间窗 + 搜索 + 未读），不是整库。
//    为什么：用户要备份的通常是"我正在看的这一堆"（比如某个 App 的验证码历史），
//    而全量导出他没法用 —— 几万行塞进一个 CSV，打开就卡死。
//    🔴 当前筛选为空 = 没有限定条件 ⇒ 那就是整库，和"全量"不冲突。
// v0.0.49：★ 视图下导出的就是**眼睛看到的这批**（self.items）—— nbStar 是派生量、
//    SQL 导不出"只要标星的"，而按 SQL 范围导会把非标星的一起倒进文件，
//    恰恰违背"导出我正在看的这一堆"这个初衷。确认框的数 = items.count，
//    和真正写进文件的条数严格相等（v0.0.44 立过的纪律）。
- (void)onExport:(id)sender {
    NSInteger n;
    if (self.starOnly) {
        n = (NSInteger)self.items.count;
    } else {
        NSArray<NSString *> *searchBundles = [self bundlesMatchingSearch:self.searchText];
        n = [NotifyStore countWithBundle:self.filterBundle
                                  since:[self sinceFromSeg]
                                 search:self.searchText
                          searchBundles:searchBundles
                             unreadOnly:self.unreadOnly];
    }
    if (n <= 0) {
        // 和 `onClear:` 同一条纪律：没有可导出的东西就别弹确认框。
        [self alertTitle:@"没有可导出的记录"
                    text:@"当前筛选下一条记录都没有。把筛选调宽（或清空搜索框）再试。"];
        return;
    }

    NSMutableString *msg;
    if (self.starOnly) {
        // ★ 视图：导出的就是列表这批，不存在"列表只显示了一部分"的差。
        msg = [NSMutableString stringWithFormat:
            @"将把 ★ 标星视图下的 %ld 条记录导出成 CSV。", (long)n];
    } else {
        // 🔴 确认框里的数必须就是**这次真正会写进文件的条数**：
        //    它来自同一个 `NBPrepareScope`（`countWithBundle:`），和下面 `doExport` 查的是一批数据。
        //    这里如果拿 `self.items.count` 就会少算 —— 列表被 `LIMIT 2000` 截断过，
        //    而导出**不带** LIMIT（v0.0.35 的 `onClear:` 已经为"报列表条数、实际动全表"买过一次单）。
        msg = [NSMutableString stringWithFormat:
            @"将把当前筛选下的 %ld 条记录导出成 CSV。", (long)n];
        if ((NSInteger)self.items.count != n) {
            [msg appendFormat:@"\n\n（列表里只显示了 %ld 条 —— 它一次最多显示 %ld 条，"
                               "导出的文件里是完整的 %ld 条。）",
             (long)self.items.count, (long)[NotifyStore listLimit], (long)n];
        }
    }

    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"导出记录"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [al addAction:[UIAlertAction actionWithTitle:@"导出" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        [weakSelf doExport];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)doExport {
    // v0.0.49：★ 视图导出内存里这批（和 onExport 报的数严格同源）；其余走 SQL 全量范围。
    // 🔴 csvFromRows: 只读固定键（bundle/ts/title/subtitle/message/read），
    //    items 里多带的 nbStar 键被忽略 —— 不需要先剥掉。
    NSArray<NSDictionary *> *rows;
    NSString *base;
    if (self.starOnly) {
        rows = self.items;
        base = @"标星记录";
    } else {
        NSArray<NSString *> *searchBundles = [self bundlesMatchingSearch:self.searchText];
        rows = [NotifyStore exportRowsWithBundle:self.filterBundle
                                           since:[self sinceFromSeg]
                                          search:self.searchText
                                   searchBundles:searchBundles
                                      unreadOnly:self.unreadOnly];
        base = self.filterBundle.length ? [self appNameForBundle:self.filterBundle]
                                        : @"消息盒子";
    }
    if (!rows.count) {
        [self alertTitle:@"导出失败" text:@"一条记录都没读到。列表已刷新，可以再试一次。"];
        [self loadData];
        return;
    }

    // App 显示名只有界面层有（库里存的是 bundle id）⇒ 把映射传进去
    NSString *csv = [NotifyExport csvFromRows:rows appNames:self.appNameMap];
    NSURL *url = [NotifyExport writeTempCSV:csv baseName:base];
    if (!url) {
        [self alertTitle:@"导出失败" text:@"写临时文件失败。可以重启 App 再试。"];
        return;
    }

    UIActivityViewController *act =
        [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                          applicationActivities:nil];
    // 🔴 iPad 上 `UIActivityViewController` 必须挂 popover，不挂就是**直接崩**。
    act.popoverPresentationController.barButtonItem =
        self.navigationItem.rightBarButtonItems.count > 1
            ? self.navigationItem.rightBarButtonItems[1]     // 「导出」那个按钮
            : self.navigationItem.rightBarButtonItem;
    __weak typeof(self) weakSelf = self;
    act.completionWithItemsHandler = ^(UIActivityType type, BOOL done,
                                       NSArray *items, NSError *err) {
        // 分享完把临时文件删掉 —— 里面是一整份通知记录，不该留在临时目录里
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        if (done) {
            [weakSelf alertTitle:@"已导出"
                            text:[NSString stringWithFormat:@"%ld 条记录已导出。",
                                  (long)rows.count]];
        }
    };
    [self presentViewController:act animated:YES completion:nil];
}

#pragma mark - 全标已读（v0.0.38）

// 为什么只在「只看未读」时出现：见 `buildUI` 里 `markAllBtn` 的注释。
- (void)onMarkAllRead:(id)sender {
    NSTimeInterval since = [self sinceFromSeg];
    // 🔴 先算一遍再问 —— 和 `onClear:` 同一条纪律：确认框里的数字必须是**这次真正会改的
    //    行数**，不能拿 `self.items.count`（那是列表显示了几条，受搜索和单次上限影响）。
    //    这个数由 `unreadCountWithBundle:since:` 算，和后面 `markAllReadWithBundle:since:`
    //    共用同一套 WHERE 条件（见 NotifyStore.m 里 `NBPrepareScope`）。
    NSInteger n = [NotifyStore unreadCountWithBundle:self.filterBundle since:since];
    if (n == 0) {
        [self alertTitle:@"没有未读" text:@"这个范围里已经没有未读记录了。"];
        return;
    }
    if (n < 0) {
        [self alertTitle:@"读不到数据库" text:@"打不开数据库，没法统计未读条数。"];
        return;
    }

    NSMutableString *msg = [NSMutableString stringWithFormat:
        @"将把「%@」范围内的 %ld 条未读标成已读。\n\n只改「已读」标记，不会删除记录。",
        [self scopeDesc], (long)n];
    // v0.0.49：★ 视图下的警告，和搜索同款口径 —— ★ 是**显示层**筛选（nbStar 派生、
    //    不在库里），标记范围仍是 SQL 的「App + 时间」。不说清楚就会出现
    //    "我在 ★ 视图里点全标已读，结果未读的非标星记录也被标了"。
    // 🔴 和搜索那条分开写（不用 else if）：两个筛选可以同时开着，警告要同时出现。
    if (self.starOnly) {
        [msg appendFormat:@"\n\n⚠️ 「★ 标星」视图只影响列表显示，不限制标记范围。"];
    }
    // 🔴 搜索词只影响**列表显示**，不参与标记范围。不说清楚就会出现
    //    "我搜了验证码、只看到 3 条，一点却全标了" —— 和 v0.0.35 `onClear:` 的坑同源。
    if (self.searchText.length) {
        [msg appendFormat:@"\n\n⚠️ 搜索框里的「%@」只影响列表显示，不限制标记范围。",
         self.searchText];
    } else if ((NSInteger)self.items.count < n) {
        [msg appendFormat:@"\n\n当前列表只显示 %ld 条（超出单次上限），标记范围仍是上面说的 %ld 条。",
         (long)self.items.count, (long)n];
    }

    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"全部标为已读？"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    // 不用 `UIAlertActionStyleDestructive`：不删数据，红字会让人以为要清库。
    [al addAction:[UIAlertAction actionWithTitle:@"标为已读" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        [weakSelf doMarkAllRead];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)doMarkAllRead {
    NSInteger n = [NotifyStore markAllReadWithBundle:self.filterBundle
                                               since:[self sinceFromSeg]];
    // 🔴 先改库 → 再整表重查。和 `doClear` / 左滑删除是同一条纪律：
    //    列表的数据只有一个来源（数据库），内存数组永远从它重建。
    //    这一句同时会把图标栏红点重算一遍（`loadData` 里先调 `reloadIconBar`）。
    [self loadData];

    if (n > 0) {
        [self alertTitle:@"已标记"
                    text:[NSString stringWithFormat:@"把 %ld 条标成了已读。", (long)n]];
    } else if (n == 0) {
        // `UPDATE ... WHERE read=0` 命中 0 行照样返回 SQLITE_DONE ⇒ 不能当成功。
        [self alertTitle:@"没有变化"
                    text:@"这个范围里已经没有未读了（可能刚被标过）。列表已刷新。"];
    } else {
        [self alertTitle:@"标记失败"
                    text:@"打不开数据库。列表已刷新，可以重启 App 再试。"];
    }
}

#pragma mark - 诊断

- (void)onDiag:(id)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"诊断"
                                                                  message:@"选择要查看的内容"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    // 结论行优先：日志动辄 9KB，全量截图很难抓重点
    [sheet addAction:[UIAlertAction actionWithTitle:@"环境自检（不依赖日志）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[NotifyStore envCheck] title:@"环境自检"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"只看结论行（推荐）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[self keyLinesFrom:[NotifyStore logText:20000]] title:@"结论行"];
    }]];
    // 🔴 v0.0.20：探针数据单独开一个入口。
    //    为什么不能只靠结论行：
    //      ① 结论行只看**尾部 20KB**，而探针是**开机那一刻**打的 —— 手机跑几个小时后
    //         那几行早被挤出窗口了，改了关键词也照样看不到（这是"两个独立的丢数据原因"，
    //         只修关键词等于只修了一半）；
    //      ② 探针行很长（几十个属性名 + 类型编码），混在结论行里会把别的判据挤出去。
    //    窗口取 200KB（日志轮转阈值 512KB，足够覆盖一次开机到现在的全部内容）。
    [sheet addAction:[UIAlertAction actionWithTitle:@"探针数据（PROBE，换提示音要用）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[self probeLinesFrom:[NotifyStore logText:200000]] title:@"探针数据"];
    }]];
    // 🔴🔴 v0.0.23：换提示音的诊断**落盘**了，这里直接读文件。
    //    为什么单开一个入口、而不是从日志里捞：
    //      · 日志只有约 50 行窗口，结构性 dump 一小时前就滚没了
    //        （v0.0.22 就是这么白跑一轮的）；
    //      · 文件不受窗口/轮转影响，且是"上一个进程完整的一次 dump"。
    //    路径与 tweak 侧共用 NotifyCommon.h 里的宏 —— 不另写一份字面量。
    [sheet addAction:[UIAlertAction actionWithTitle:@"声音诊断文件（完整，换提示音必看）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[self soundDiagFileText] title:@"声音诊断"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"方法清单（SEL+ENC）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[self selLinesFrom:[NotifyStore logText:60000]] title:@"方法清单"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"tweak 日志（尾部 20KB）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[NotifyStore logText:20000] title:@"tweak 日志"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"数据库自检"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[NotifyStore debugSummary] title:@"数据库自检"];
    }]];
    // 🔴 取图标在越狱环境里没有保证成功的路，失败又是静默的（退化成首字母）。
    //    这一项直接告诉你：A/B/C 哪条路走通了、哪条为什么没通。
    [sheet addAction:[UIAlertAction actionWithTitle:@"图标诊断（A/B/C 哪条通）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[AppIconLoader diagReport] title:@"图标诊断"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"清空图标缓存并重取"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [AppIconLoader clearCache];
        [self loadData];
        [self showText:@"缓存已清空，列表已重取。\n再看一次「图标诊断」。" title:@"图标缓存"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    // iPad 上 actionSheet 必须给 popover 锚点
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

// 只挑 SEL/ENC 行：这就是 v0.0.4 要量回来的「精确方法签名」
- (NSString *)selLinesFrom:(NSString *)text {
    if (!text.length) return @"(空)";
    NSArray *all = [text componentsSeparatedByString:@"\n"];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *line in all) {
        if ([line containsString:@"SEL "] || [line containsString:@"候选"] ||
            [line containsString:@"BBServer 共"]) {
            // 去掉时间戳前缀，截图更省宽度
            NSRange r = [line rangeOfString:@"]"];
            if (r.location != NSNotFound && r.location + 1 < line.length) {
                [keep addObject:[line substringFromIndex:r.location + 1]];
            } else {
                [keep addObject:line];
            }
        }
    }
    if (!keep.count) {
        return @"没有 SEL 行 —— 要么日志被截断，要么 BBServer 不在这个进程。\n先看「只看结论行」。";
    }
    return [NSString stringWithFormat:@"共 %lu 条（ENC 里 v=void 返回，@=对象，Q=unsigned long long，B=BOOL）\n\n%@",
            (unsigned long)keep.count, [keep componentsJoinedByString:@"\n"]];
}

// 🔴🔴 v0.0.17：关键词表压成**一条带哨兵前缀的字面量**，不再用数组字面量。
//
// 为什么非改不可：校验脚本只能"在 App 二进制里找子串"，它要判的是
// 「DELAY 在不在筛选表里」，但实际能判的只有「App 里有没有出现过 DELAY 这个词」。
// 而设置页的帮助文案里早就写着「如果日志里出现 DELAY-MISS…我按 PROBEDATE 那行…」
// ⇒ **在完全没有筛选词的 v0.0.16 上，这条判据也是绿的（假通过）**。
// 假通过比没判据更坏：它会让我以为已经修好了。
// 加成哨兵前缀后，脚本能精确定位"表里有哪些词"，判据才等于变异域。
//
// 额外好处：全部关键词集中一处，以后加新留痕只改这一行，不会漏。
//
// 🔴🔴 v0.0.20：把已经死掉的 DELAY / PROBEDATE 换成 PROBE。
//   这一条又是"留痕被自己筛掉"，和 v0.0.17 的 DELAY# 是**同一个病，第三次了**：
//   探针所有实质数据都以 PROBE 开头（`PROBE BBBulletin 名字: …` /
//   `PROBE#1 tag=PB :: sound=<BBSound> …` / `PROBE 当前队列标签 = …`），
//   而表里一个能匹配它们的词都没有 ⇒ 结论行里只剩
//   `=== PROBE 开始 dump 类结构 ===` 和 `=== PROBE dump 结束 ===` 两行，
//   **这两行恰好不含任何数据**。
//   现场看起来就是"探针跑了、什么都没量到"，实际数据一直在日志里。
//   ⇒ 「按 App 换提示音」等 PROBE 数据等了好几版，根因在这里。
//   🔴 教训升级版：**加了新留痕，必须同时问"它能通过筛选吗"**；
//      而"筛选表里有旧词"不等于"新留痕能被捞出来"。
static NSString * const kNBKeyLineTable =
    @"NBKEYLINES|===|-->|hit#|P#|drop |DROP#|REPL#|PROBE|DND#|SOUND#|SD#|APP-ALIVE|G3 首次|失败|!!!|探针";

static NSArray<NSString *> *NBKeyLineKeywords(void) {
    return [kNBKeyLineTable componentsSeparatedByString:@"|"];
}

// v0.0.23：把落盘的诊断整份读出来。
// 文件不存在时给"三种可能"，而不是干巴巴一句"没有"——
// 用户看到空白时必须能自己判断是"没跑过"还是"跑了但没写进去"。
- (NSString *)soundDiagFileText {
    // 🔴 路径必须用 NotifyCommon.h 里的宏，**不许在这里再写一遍字面量**。
    //    上一版我差点写成字面量、注释还写着"共用宏"——注释和代码走岔是本项目
    //    反复付学费的那类错（改了 tweak 侧路径、App 侧还读老路径，两边都"没错"却谁也看不见）。
    NSString *path = NOTIFYBOX_SOUND_DIAG_PATH;
    NSString *body = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (!body.length) {
        return [NSString stringWithFormat:
                @"(%@ 是空的或不存在)\n\n"
                @"常见原因（按可能性排）：\n"
                @"① SpringBoard 起来之后还没收到过通知 —— 诊断要等第一条通知到达才写；\n"
                @"② 换提示音的开关/名单没配好 → 诊断只在**目标 App** 上输出（这是故意的，避免刷屏）；\n"
                @"③ tweak 没注入 —— 先去「结论行」看有没有 banner 那两行。",
                path];
    }
    NSArray *lines = [body componentsSeparatedByString:@"\n"];
    NSString *head = [NSString stringWithFormat:@"%@\n共 %lu 行\n",
                      path, (unsigned long)lines.count];
    return [head stringByAppendingFormat:@"\n%@", body];
}

// v0.0.20：只挑探针行。
// 判据域 = 含 "PROBE"（v0.0.23 起加 "SD#"）的行；变异域 = 探针的全部输出。
// ⇒ 两者必须严格对齐。这正是上一版"关键词表漏词"要买的课。
// 单独开入口、而不是塞进结论行，有两个**互相独立**的原因：
//   ① 结论行只看尾部 20KB，而探针是**开机那一刻**打的 —— 手机跑几小时后早被挤出窗口，
//      光把关键词补进表里也照样看不见（只修一半 = 还是看不到）；
//   ② 探针行很长（几十个属性名 + 类型编码），混进结论行会把 DROP#/REPL# 这些判据挤掉。
- (NSString *)probeLinesFrom:(NSString *)text {
    if (!text.length) return @"(空)";
    NSArray *all = [text componentsSeparatedByString:@"\n"];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *line in all) {
        // 🔴 v0.0.23：把 SD#（换提示音诊断）也收进来。
        //    同一个病已经犯过三次：加了新留痕、却忘了它能被筛出来。
        //    这次是"加了 SD#、但入口只认 PROBE"，等于白打。
        if ([line containsString:@"PROBE"] || [line containsString:@"SD#"]) {
            [keep addObject:line];
        }
    }
    NSUInteger total = keep.count;
    if (!total) {
        return @"(没找到 PROBE / SD# 行)\n\n"
                "常见原因（按可能性排）：\n"
                "① SpringBoard 起来之后还没收到过通知 —— 探针要等第一条通知到达才跑；\n"
                "② 日志轮转过了（超过 512KB 切到 .1），开机那几条不在当前文件里；\n"
                "③ tweak 没注入 —— 先去「只看结论行」看有没有 banner 那两行。";
    }
    // 只留最后 40 行：单行可能上千字，多了翻不动
    if (keep.count > 40) {
        keep = [[keep subarrayWithRange:NSMakeRange(keep.count - 40, 40)] mutableCopy];
    }
    NSString *head = [NSString stringWithFormat:@"PROBE 行 %lu 条 / 全文 %lu 行%@",
                      (unsigned long)total, (unsigned long)all.count,
                      (total > keep.count
                       ? [NSString stringWithFormat:@"（只显示最后 %lu 条）", (unsigned long)keep.count]
                       : @"")];
    return [head stringByAppendingFormat:@"\n\n%@", [keep componentsJoinedByString:@"\n"]];
}

// 从全量日志里挑出「能下结论」的行：装载/挂了哪组/命中/探针/丢弃/写库失败
- (NSString *)keyLinesFrom:(NSString *)text {
    if (!text.length) return @"(空)";
    NSArray *all = [text componentsSeparatedByString:@"\n"];
    NSMutableArray *keep = [NSMutableArray array];
    // 这些是判据行；不含它们的（比如 sel 清单）不在这里显示
    // 🔴 DROP# / REPL# 是「过滤真的拦了」「替换真的改了」的唯一证据，必须进结论行
    //
    // 🔴🔴 v0.0.17 修一个很隐蔽的漏判：`DELAY` / `PROBEDATE` 必须显式加进表里。
    //    之前只有 `P#` 这个关键词，于是：
    //      `DELAY-SKIP#1`  刚好含 "SKIP#" 里的 "P#"  ⇒ 侥幸显示
    //      `DELAY#1`       D,E,L,A,Y,#             ⇒ 一个关键词都不含 ⇒ **被筛掉**
    //      `DELAY-MISS#1`  同上                    ⇒ 也被筛掉
    //    结果就是用户截图上只看到 SKIP、看不到 DELAY# —— 而 DELAY# 恰恰带着
    //    「我改的是哪个字段」这个最关键的信息。查这个问题时我一度以为延迟根本没生效。
    //    ⇒ 教训：**新增一种日志行，必须同时检查它能不能通过"结论行"筛选**。
    //      判据写出来了但看不见，等于没写。
    NSArray *keys = NBKeyLineKeywords();
    for (NSString *line in all) {
        if (!line.length) continue;
        for (NSString *k in keys) {
            if ([line containsString:k]) { [keep addObject:line]; break; }
        }
    }
    NSString *head = [NSString stringWithFormat:@"命中 %lu 行 / 全文 %lu 行",
                      (unsigned long)keep.count, (unsigned long)all.count];
    if (!keep.count) {
        // 日志都没有时，附上「不依赖日志」的环境自检，否则这一屏毫无信息量
        return [head stringByAppendingFormat:
                @"\n\n没有任何结论行 —— 日志文件里没有装载记录。\n\n"
                @"【环境自检】\n%@\n\n【日志原文前 800 字】\n%@",
                [NotifyStore envCheck],
                text.length > 800 ? [text substringToIndex:800] : text];
    }
    return [head stringByAppendingFormat:@"\n\n%@", [keep componentsJoinedByString:@"\n"]];
}

// 长文本用可滚动 VC 展示：UIAlertController 的 message 太长会被截断，且不能复制
- (void)showText:(NSString *)text title:(NSString *)title {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = title;
    vc.view.backgroundColor = NBPageBG();   // v0.0.71 与全站统一

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
    tv.editable = NO;
    tv.selectable = YES;                 // 可全选复制，方便发回给我
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.text = text ?: @"(空)";
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor],
    ]];
    [self.navigationController pushViewController:vc animated:YES];
}

// v0.0.33：轻量提示（左滑删除"删不到"时用）。不用 showText: —— 那是长文本页，太重。
- (void)alertTitle:(NSString *)title text:(NSString *)text {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:title
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)buildUI {
    // v0.0.71：**第一个**加进 view 的子视图 ⇒ 永远在所有控件下面。
    // 🔴 顺序是有意义的：晚加的话它会把分段/搜索/按钮盖住（白色卡片盖白字，看着像控件没了）。
    self.topCard = [[UIView alloc] init];
    self.topCard.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.topCard.layer.cornerRadius = NBCardRadius;   // 与列表卡片同一圆角
    self.topCard.layer.cornerCurve = kCACornerCurveContinuous;
    self.topCard.clipsToBounds = YES;
    [self.view addSubview:self.topCard];

    // 时间分段
    // v0.0.37：第 0 段原名「今天」，但它实际返回的是 `now - 86400`（最近 24 小时），
    //    不是今天 00:00 —— 名不符实。今天 19:30 时，「今天」会把昨天 19:30 之后的
    //    记录也算进来。改成如实写「近24小时」，行为不变、标签不再说谎。
    // v0.0.38：段名改从 `timeNames` 取，不再在这里写字面量。
    self.timeSeg = [[UISegmentedControl alloc] initWithItems:[self timeNames]];
    self.timeSeg.selectedSegmentIndex = 0;
    [self.timeSeg addTarget:self action:@selector(onTime:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.timeSeg];

    // 搜索
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索标题或正文";
    // 🔴 v0.0.70：底色已经是分组灰，搜索框还用默认样式的话会叠出一块**同色灰**，
    //    整条搜索栏看起来像"糊在背景上"、边界不清。Minimal 样式只画里面那个圆角输入框，
    //    和外层的灰底有明确的层次。
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.backgroundImage = [[UIImage alloc] init];   // 去掉那条 1px 分隔线
    [self.view addSubview:self.searchBar];

    // v0.0.37：全部 / 只看未读。
    // 🔴 不用 `searchBar.showsScopeBar` 了 —— v0.0.36 实测 iOS 16 上不显示（见属性注释）。
    //    用和上面时间分段同款控件，看得见摸得着。
    self.unreadSeg = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"只看未读"]];
    self.unreadSeg.selectedSegmentIndex = 0;
    [self.unreadSeg addTarget:self action:@selector(onUnread:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.unreadSeg];

    // v0.0.49：★ 只看标星开关。创建方式对齐 markAllBtn（同屏已有的按钮写法：
    //    UIButtonTypeSystem + 手动设字体/圆角/底色），不引第二套。
    // 🔴 选中态只换标题颜色（secondaryLabel → systemOrange），不换底色 ——
    //    和列表里 ★ 的 systemOrange 同一套视觉，用户把"橙色的 ★"和"开着的筛选"联系起来。
    // 🔴 常驻可见（不像 markAllBtn 随 unreadOnly 进出）：★ 是这一版的核心入口，
    //    而且它随时可点 —— 没有规则时点它，空列表会告诉用户去建什么规则。
    self.starBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.starBtn setTitle:@"★ 标星" forState:UIControlStateNormal];
    self.starBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    // v0.0.71：胶囊形（高度的一半），和分段控件同一套圆角语言
    self.starBtn.layer.cornerRadius = kNBTopH / 2.0;
    self.starBtn.backgroundColor = [UIColor secondarySystemFillColor];
    [self.starBtn setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [self.starBtn setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateSelected];
    [self.starBtn addTarget:self action:@selector(onStar:)
              forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.starBtn];

    // v0.0.38：「只看未读」时才出现的批量入口。
    // 🔴 为什么默认隐藏、而不是常驻：在「全部」模式下，列表里已读未读混在一起，
    //    「全标已读」的作用对象不明确（是这一屏？是整个库？），容易被当成"清空"。
    //    只在"只看未读"时出现，范围就是眼睛看到的这一批。
    self.markAllBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.markAllBtn setTitle:@"全标已读" forState:UIControlStateNormal];
    self.markAllBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    self.markAllBtn.layer.cornerRadius = kNBTopH / 2.0;   // v0.0.71 胶囊
    self.markAllBtn.backgroundColor = [UIColor secondarySystemFillColor];
    [self.markAllBtn addTarget:self action:@selector(onMarkAllRead:)
              forControlEvents:UIControlEventTouchUpInside];
    self.markAllBtn.hidden = YES;
    [self.view addSubview:self.markAllBtn];

    // v0.0.40：筛选之外还有未读的常驻提示（`hiddenUnread > 0` 才显示，见属性注释）。
    // v0.0.41：改成按钮（可点）。创建方式对齐同屏已有的 `markAllBtn`：
    //    一样是 `UIButtonTypeSystem` + 手动设字体/颜色，不引第二套写法。
    // 🔴 用 `secondaryLabelColor` + 12pt：它是"补充说明"，不该比列表本身更抢眼。
    //    但前面带 ⚠️，因为不说的话用户会当成"全都读完了"。
    self.hiddenHint = [UIButton buttonWithType:UIButtonTypeSystem];
    self.hiddenHint.titleLabel.font = [UIFont systemFontOfSize:12];
    self.hiddenHint.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.hiddenHint.titleLabel.minimumScaleFactor = 0.85;
    // 🔴 system 按钮的标题默认**居中**；不改成左对齐的话，一行小字会飘在屏幕中间，
    //    看起来像个孤立标签、而不是"挂在列表上方的一条说明"。
    self.hiddenHint.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [self.hiddenHint setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    self.hiddenHint.hidden = YES;
    [self.hiddenHint addTarget:self action:@selector(onHiddenHintTap)
              forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.hiddenHint];

    // v0.0.48：被关键词规则收起的条数提示（foldedCount>0 才显示，见 viewDidLayoutSubviews）。
    // 🔴 创建方式对齐 hiddenHint：同一套 UIButtonTypeSystem + 手动设字体/颜色 + 左对齐，
    //    不引第二套写法（本项目"同一个东西只留一份实现"的纪律）。
    self.foldedHint = [UIButton buttonWithType:UIButtonTypeSystem];
    self.foldedHint.titleLabel.font = [UIFont systemFontOfSize:12];
    self.foldedHint.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.foldedHint.titleLabel.minimumScaleFactor = 0.85;
    self.foldedHint.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [self.foldedHint setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    self.foldedHint.hidden = YES;
    [self.foldedHint addTarget:self action:@selector(onFoldedHintTap)
              forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.foldedHint];

    // 顶部 App 图标栏（横向滚动）
    self.iconBar = [[UIScrollView alloc] init];
    self.iconBar.showsHorizontalScrollIndicator = NO;
    [self.view addSubview:self.iconBar];

    // 列表
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.delegate = self;
    self.table.dataSource = self;
    // 🔴 v0.0.70 卡片化：分行靠**留白**，不再靠分隔线。
    //    留着分隔线会出现"卡片里还画了一条线"的双线效果，比不做卡片更难看。
    self.table.separatorStyle = UITableViewCellSeparatorStyleNone;
    // 🔴 灰色大底必须由 tableView 出（cell 和卡片都是透明的/半透的）：
    //    这是"分层"的唯一来源。少了这一句，卡片和背景同色 ⇒ 看起来只是"行高变大了"。
    self.table.backgroundColor = NBPageBG();
    // 自重算高度会关闭行高缓存，本表行高是常量 ⇒ 明确关掉，省掉一次没必要的测量
    self.table.estimatedRowHeight = 0;
    // 🔴 自定义 cell：Default 样式的 UITableViewCell **不显示 detailTextLabel**，
    //    以前正文全写在那上面 ⇒ 只有标题、没有正文。见 NotifyCell.h 注释。
    [self.table registerClass:[NotifyCell class] forCellReuseIdentifier:@"c"];
    self.table.rowHeight = [NotifyCell height];
    [self.view addSubview:self.table];
}

// 统一在 safeArea 里排版，避免和导航栏/搜索框互相压字
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat top = self.view.safeAreaInsets.top;
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat safeBottom = self.view.safeAreaInsets.bottom;
    CGFloat y = top + 8;

    // =====================================================================
    // v0.0.71：顶部控制区收进**一张白卡片**。
    // 🔴 原来这 5 行控件（时间分段 / 搜索 / ★+未读+全标已读 / 两条提示）各自浮在灰底上，
    //    横向边距还不统一（分段用 12、搜索框用 0）⇒ 看起来像"几个不相干的东西掉在上方"。
    //    现在统一：一张卡片、一个内边距（10）、一条竖直节奏（10pt）。
    // 🔴 两条提示的可见性判据必须和 `cy` 的累加用**同一个** BOOL 变量：
    //    一处写 `> 0`、另一处写 `!= 0`，这种不一致不报错、只让布局悄悄错位。
    // =====================================================================
    BOOL showHint = (self.hiddenUnread > 0 && self.items.count > 0);
    BOOL showFoldedHint = (self.foldedCount > 0);

    CGFloat cardX = NBInset;
    CGFloat cardW = w - NBInset * 2;
    CGFloat inX = cardX + 10;
    CGFloat inW = cardW - 20;
    CGFloat cy = y + 10;

    // 时间分段
    self.timeSeg.frame = CGRectMake(inX, cy, inW, kNBTopH);
    cy += kNBTopH + 10;

    // 搜索框：UISearchBar 自带左右内边距，往外放 4 才不会看起来陷进去
    // 🔴 别用 `sizeThatFits:` / `intrinsicContentSize` 去"自动算"：
    //    UISearchBar 是普通 UIView，未布局时回 (0,0) ⇒ 搜索框直接消失。
    self.searchBar.frame = CGRectMake(inX - 4, cy - 4, inW + 8, 40);
    cy += 40;

    // v0.0.49：三件套 —— ★ 标星（常驻，最左）+ 全部/只看未读 +（未读时）全标已读。
    // 🔴 320pt 窄屏验算：卡片内宽 320-32-20=268；★68 + 8 + 分段(110) = 186 ≤ 268 ✓，
    //    再加「全标已读」88 + 8 ⇒ 282 > 268 ⇒ 所以分段用 MAX(110, …) 兜底前先减。
    CGFloat starW = 68;
    CGFloat markW = kNBMarkAllWidth;
    self.markAllBtn.hidden = !self.unreadOnly;
    CGFloat segW = inW - starW - kNBTopGap - (self.unreadOnly ? (markW + kNBTopGap) : 0);
    segW = MAX(100, segW);
    self.starBtn.frame = CGRectMake(inX, cy, starW, kNBTopH);
    self.unreadSeg.frame = CGRectMake(inX + starW + kNBTopGap, cy, segW, kNBTopH);
    self.markAllBtn.frame = CGRectMake(inX + starW + kNBTopGap + segW + kNBTopGap,
                                       cy, markW, kNBTopH);
    cy += kNBTopH;

    // v0.0.40：筛选之外还有未读的常驻提示。
    // 🔴 不显示时高度必须是 **0**，而且要把 frame 也清零 ——
    //    只 `hidden = YES` 而保留 frame 的话，卡片底部会凭空多一截空白。
    // 🔴🔴 为什么要串上 `self.items.count > 0`：**列表为空时 `updateEmptyView`
    //    已经在屏幕正中说了同一件事**（还带「当前筛选」）。
    //    这边再飘一条，同一句话就占了两处屏幕。
    self.hiddenHint.hidden = !showHint;
    if (showHint) {
        cy += 8;
        self.hiddenHint.frame = CGRectMake(inX, cy, inW, kNBHintH);
        cy += kNBHintH;
    } else {
        self.hiddenHint.frame = CGRectZero;
    }

    // v0.0.48：被关键词规则收起的条数提示。
    // 🔴 可见性判据**故意不串 `items.count`**（和 hiddenHint 相反）：列表被折叠空时
    //    **更要显示**，否则用户看到"暂无记录"以为没数据，其实有 N 条被规则收着。
    self.foldedHint.hidden = !showFoldedHint;
    if (showFoldedHint) {
        cy += showHint ? 2 : 8;
        self.foldedHint.frame = CGRectMake(inX, cy, inW, kNBHintH);
        cy += kNBHintH;
    } else {
        self.foldedHint.frame = CGRectZero;
    }

    cy += 10;   // 卡片下内边距
    self.topCard.frame = CGRectMake(cardX, y, cardW, cy - y);
    y = cy + 8;

    // v0.0.70：图标栏上下各留 6pt，让它和列表之间也有一条"呼吸缝"
    // v0.0.71：卡片化之后它自己也收进一张白底，和下面的列表卡片、上面的控制卡片同一套层次
    y += 6;
    self.iconBar.backgroundColor = [UIColor clearColor];
    self.iconBar.frame = CGRectMake(0, y, w, 56);
    y += 56 + 6;

    self.table.frame = CGRectMake(0, y, w, h - y - safeBottom);
}

- (void)reloadIconBar {
    // 🔴 v0.0.36：重建按钮会动 `contentSize`，而图标栏是横向滚动的 ——
    //    不清醒地保住 offset 的话，用户滚到右边选了第 10 个 App、点开一条通知，
    //    一返回图标栏就跳回最左。这里手动存、算完再夹回去。
    CGPoint barOff = self.iconBar.contentOffset;

    [self.iconBar.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.bundles = [NotifyStore distinctBundles];
    // v0.0.36：一次查出来，下面建每个图标时直接用（别在循环里一个个查库）
    // v0.0.37：红点只算**当前时间窗内**的未读 —— 和列表同口径，点得进去也清得掉。
    NSSet *unread = [NotifyStore bundlesWithUnreadSince:[self sinceFromSeg]];
    self.unreadDots = [NSMutableDictionary dictionary];

    CGFloat x = 8;
    CGFloat size = 44;
    NSArray *list = [@[@"全部"] arrayByAddingObjectsFromArray:self.bundles];
    for (NSString *bid in list) {
        // 🔴 v0.0.36：按钮外面套一层容器。
        //    按钮自己要 `clipsToBounds`（圆角得把图标裁进去），红点如果挂在按钮上、
        //    又想压在角上探出一点，就会被裁掉一半。容器不裁剪，红点挂容器。
        UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(x, 6, size, size)];
        [self.iconBar addSubview:holder];

        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(0, 0, size, size);   // ← 相对容器
        b.layer.cornerRadius = 8;
        b.clipsToBounds = YES;
        b.backgroundColor = [UIColor secondarySystemFillColor];
        b.tag = [list indexOfObject:bid];
        [b addTarget:self action:@selector(onIcon:) forControlEvents:UIControlEventTouchUpInside];
        // 真图标（LSApplicationProxy）；「全部」用 SF Symbol
        if ([bid isEqualToString:@"全部"]) {
            [b setImage:[[UIImage systemImageNamed:@"tray.full"]
                imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                       forState:UIControlStateNormal];
            b.tintColor = [UIColor secondaryLabelColor];
        } else {
            UIImage *ic = [AppIconLoader iconForBundle:bid];
            if (ic) {
                [b setImage:ic forState:UIControlStateNormal];
            } else {
                // 退化态：只放**首字母**。之前放的是 bundle 末段全名（如 "bijia"），
                // 44pt 的方块里根本显示不下，看起来像坏掉。
                NSString *last = [self shortName:bid];
                NSString *ch = last.length ? [[last substringToIndex:1] uppercaseString] : @"?";
                [b setTitle:ch forState:UIControlStateNormal];
                b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
                // 系统按钮的标题默认走 tintColor（蓝），退化态用灰色更克制
                [b setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
            }
        }

        // 🔴 当前筛选的 App 必须看得出来：以前点完毫无视觉反馈，
        //    用户没法判断"现在到底筛的是哪个"。
        BOOL selected = [bid isEqualToString:@"全部"] ? (self.filterBundle.length == 0)
                                                     : [bid isEqualToString:self.filterBundle];
        if (selected) {
            b.layer.borderWidth = 2.0;
            b.layer.borderColor = [UIColor systemBlueColor].CGColor;
        }
        b.imageView.contentMode = UIViewContentModeScaleAspectFit;
        [holder addSubview:b];

        // v0.0.36：有未读就在右上角点一个红点。「全部」不点 —— 它不是某个 App，
        // 而且"全部"聚合了所有 App，「红点 = 全部还有未读」会让人以为没有。
        if (![bid isEqualToString:@"全部"]) {
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(size - 9, -1, 9, 9)];
            dot.backgroundColor = [UIColor systemRedColor];
            dot.layer.cornerRadius = 4.5;
            // 描边用页面底色：红点压在图标上时轮廓更清楚
            dot.layer.borderWidth = 1.5;
            dot.layer.borderColor = [UIColor systemBackgroundColor].CGColor;
            dot.hidden = ![unread containsObject:bid];
            [holder addSubview:dot];
            self.unreadDots[bid] = dot;
        }
        x += size + 8;
    }
    self.iconBar.contentSize = CGSizeMake(x, 56);
    // 夹回滚动位置（内容变短时也安全）
    CGFloat maxX = MAX(0, x - self.iconBar.bounds.size.width);
    self.iconBar.contentOffset = CGPointMake(MIN(barOff.x, maxX), barOff.y);

    // v0.0.42：App 名映射跟着图标栏一起重建。
    // 🔴 为什么挂在这里：新 App 第一次来通知时 `self.bundles` 会变长，
    //    这时列表里马上就会出现它的记录。映射若只建一次，那一行就没名字。
    // 🔴 成本可忽略：`InstalledApps +all` 自己有 `gCache`，这里只是把数组塞进字典。
    [self rebuildAppNames];
}

#pragma mark - v0.0.42 App 名（列表显示 + 搜索匹配）

- (void)rebuildAppNames {
    NSMutableDictionary<NSString *, NSString *> *m = [NSMutableDictionary dictionary];
    for (InstalledApp *a in [InstalledApps all]) {
        if (!a.bundleId.length) continue;
        m[a.bundleId] = a.name.length ? a.name : a.bundleId;
    }
    self.appNameMap = m;
}

- (NSString *)appNameForBundle:(NSString *)bid {
    if (!bid.length) return nil;
    NSString *n = self.appNameMap[bid];
    if (n.length) return n;
    // 兜底：菜单里还没出现过这个 App（比如刚装上、还没重建过映射）。
    // 🔴 不要返回 nil / 空串 —— 列表里那一行就没有名字，看起来像"这个 App 叫空"。
    return [self shortName:bid];
}

- (NSArray<NSString *> *)bundlesMatchingSearch:(NSString *)q {
    if (!q.length) return nil;
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *bid in self.appNameMap) {
        NSString *name = self.appNameMap[bid];
        // ① 匹配 App 显示名（用户想的是「微信」，不是 com.tencent.xin）
        NSRange r1 = [name rangeOfString:q
                                 options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch];
        // ② 也匹配 bundle id 本身（懂行的人会直接搜 `tencent`）
        NSRange r2 = [bid rangeOfString:q options:NSCaseInsensitiveSearch];
        if (r1.location != NSNotFound || r2.location != NSNotFound) {
            [out addObject:bid];
        }
    }
    return out.count ? out : nil;
}

// v0.0.36：只刷新红点，**不重建按钮**。
// 🔴 为什么点开一条通知后不能直接 `reloadIconBar`：那会让 `contentSize` 重设，
//    图标栏的滚动位置被夹回最左 —— 用户滚到第 10 个 App、点开一条、返回，位置没了。
//    这里只改已有红点的 hidden，按钮和 contentSize 都不碰。
- (void)refreshUnreadDots {
    NSSet *unread = [NotifyStore bundlesWithUnreadSince:[self sinceFromSeg]];
    for (NSString *bid in self.unreadDots) {
        self.unreadDots[bid].hidden = ![unread containsObject:bid];
    }
}

// v0.0.72：从 `self.items` 数出每个 App 的未读条数（不查库，见属性注释）。
// 🔴 必须在 `self.items` **赋值之后**、`reloadData` 调 cellForRow **之前**调用；
//    顺序反了的话第一屏拿到的是上一批的计数 —— 症状是"刚删完/刚标已读，书签上的数还是旧的"。
- (void)rebuildBundleUnread {
    NSMutableDictionary<NSString *, NSNumber *> *m = [NSMutableDictionary dictionary];
    for (NSDictionary *d in self.items) {
        // 0 = 未读（建表默认值），非 0 = 已读，和 cellForRow 的口径一致。
        if ([d[@"read"] integerValue] != 0) continue;
        NSString *bid = d[@"bundle"];
        if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
        m[bid] = @([m[bid] integerValue] + 1);
    }
    self.nbUnreadByBundle = m;
}

- (NSString *)shortName:(NSString *)bid {
    if ([bid isEqualToString:@"全部"]) return @"全部";
    NSArray *parts = [bid componentsSeparatedByString:@"."];
    return [parts lastObject];
}

// 图标统一由 AppIconLoader 负责（多策略 + 诊断 + 缓存），这里不再自己实现。
// 🔴 历史：v0.0.5 的崩溃（NSInvocation getReturnValue: 的 ARC 过度释放）就发生在这段，
//    已经搬进 AppIconLoader 并保留了 __unsafe_unretained 的正确写法。

- (void)onIcon:(UIButton *)sender {
    NSArray *list = [@[@"全部"] arrayByAddingObjectsFromArray:self.bundles];
    NSString *bid = list[sender.tag];
    self.filterBundle = [bid isEqualToString:@"全部"] ? nil : bid;
    [self loadData];
}

- (void)onTime:(UISegmentedControl *)seg {
    [self loadData];
}

- (NSTimeInterval)sinceFromSeg {
    // 🔴 第 0 段是「近24小时」= now-86400，**不是**今天 00:00。
    //    v0.0.36 之前它叫「今天」（名不符实），v0.0.37 改了标签没改行为。
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (self.timeSeg.selectedSegmentIndex == 0) return now - 86400;
    if (self.timeSeg.selectedSegmentIndex == 1) return now - 7 * 86400;
    return 0;
}

- (void)loadData {
    [self reloadIconBar];

    // v0.0.35：当前筛选的 App 可能已经一条记录都不剩了（删掉它的最后一条、
    // 或者刚点了「清空」）。此时 `reloadIconBar` 重建的图标栏里已经没有它，
    // 而 `filterBundle` 还指着它 ⇒ 列表永远是空的，用户看着"空列表 + 顶部没有任何
    // 图标被选中"，第一反应是"记录全丢了"。这里让它自愈回「全部」。
    // 🔴 顺序：必须排在 `reloadIconBar`（它才更新 self.bundles）之后、query 之前。
    if (self.filterBundle && ![self.bundles containsObject:self.filterBundle]) {
        self.filterBundle = nil;
    }

    // v0.0.42：搜索也要匹配 App 名。**匹配在界面层做**（库里没有 App 显示名），
    // 算好的 bundle 列表作为参数传下去。`searchBundles` 只在 `search` 非空时才有意义。
    NSArray<NSString *> *searchBundles = [self bundlesMatchingSearch:self.searchText];

    NSArray<NSDictionary *> *queried = [NotifyStore queryWithBundle:self.filterBundle
                                        since:[self sinceFromSeg]
                                       search:self.searchText
                               searchBundles:searchBundles
                                   unreadOnly:self.unreadOnly];
    // v0.0.48：给查询结果套关键词规则（标星 + 折叠）。**无规则时原样返回 ⇒ 行为零变化。**
    self.items = [self applyKeywordRulesToRows:queried];
    // v0.0.72：未读书签的计数必须紧跟 `self.items` 重建（见方法注释里的顺序要求）。
    [self rebuildBundleUnread];
    [self.table reloadData];
    [self updateEmptyView];

    // 🔴 标题里直接报 DB 总记录数：这个数不依赖列表渲染，
    //    即使列表因为取图标崩了，用户也能从标题看出「库里到底有没有东西」。
    NSInteger total = [NotifyStore count];
    self.title = [NSString stringWithFormat:@"消息盒子 (%ld)", (long)total];

    // v0.0.38：记下这次刷新对应的**库指纹**，给 `refreshIfChanged` 比对。
    // 🔴 必须放在上面那些查询**之后**：指纹的语义是"这一屏列表现实对应库里的哪个状态"。
    //    放在查询之前取，就等于把还没进列表的新记录算了进去 ⇒ 下次永远比不出差异。
    // 🔴 `maxRowId` 是一次 `SELECT MAX(id)`，很便宜；但它不可省（见 NotifyStore.h 的注释：
    //    库满之后条数恒定，只看条数会漏掉"最该刷新"的场景）。
    self.lastTotal = total;
    self.lastMaxId = [NotifyStore maxRowId];
    // v0.0.49：规则指纹和库指纹一起记（见 refreshIfChanged：规则不在库里，得单独比）。
    self.lastRules = [NotifyStore keywordRules];

    // v0.0.42：底部「还有 N 条更早记录」。必须排在 `reloadData` 之后（那时 items 才定）。
    [self updateMoreFooter];

    // v0.0.40：筛选之外未读的条数在这里算（`loadData` 是唯一的刷新入口 ⇒ 不会被漏）。
    // 🔴 后面那句 `setNeedsLayout` 不能省：提示条出现/消失会改变图标栏和列表的**起始 y**，
    //    而那个 y 只在 `viewDidLayoutSubviews` 里算。不触发重布局的话，
    //    切完时间段、`hiddenUnread` 从 12 变成 0，提示条会**继续留在屏幕上**。
    [self updateHiddenUnread];
    // v0.0.48：折叠提示条紧随其后刷新（它出现/消失同样改变起始 y，靠下面那句 setNeedsLayout）。
    [self updateFoldedHint];
    [self.view setNeedsLayout];
}

// v0.0.42：底部「下面还有 N 条更早记录」。
// 🔴 为什么会有这个差：列表是 `LIMIT listLimit`（2000），而 `maxRecords` 允许用户填到 99999。
//    用户把上限调到 5000 时，库里 5000 条、列表只显示最新 2000 —— 剩下 3000 条
//    **既看不到、也左滑删不掉**（只能"清空"）。以前界面对此一个字都不说。
// 🔴 数从哪来：`countWithBundle:…`（当前筛选下的总条数）− `self.items.count`。
//    两者必须走同一个 `NBPrepareScope`，否则会出现"列表已经到底了、底部还在说还有 3 条"。
// 🔴 为什么用 `tableFooterView` 而不是"最后多加一行"：行号必须和 `self.items` 严格对应，
//    加假行会让 `reloadRowsAtIndexPaths:` / `deleteRowsAtIndexPaths:` 全部错位
//    （v0.0.33 删除场景栽过一次）。
// 🔴 和顶部提示条的分工：顶部管「**未读**被筛选挡掉了」，这里管「**记录**被列表上限截断了」。
//    两个场景不会同时成立（顶部说的是未读、这里说的是条数），不会互相吵。
// v0.0.43：这条提示必须在「只看未读」下也说得通 —— 详见方法体第一段。
// 🔴 还有个更基本的事实（v0.0.42 真机反馈时澄清过）：`maxRecords` 决定"**以后**最多留多少"，
//    它**不会**把已经裁掉的记录找回来。用户把上限从 2000 调到 3000、翻到底却什么都没看到，
//    不是 bug —— 当时库里只有约 500 条，没超列表上限，本来就不该有这条提示。
//    ⇒ 验收这条提示要先把库填到超过 `listLimit`，否则永远验不到。
- (void)updateMoreFooter {
    // v0.0.43：**`unreadOnly` 必须一起传**。
    // 🔴 v0.0.42 的真机 bug：这个计数当时不分已读未读，而 `self.items` 是带
    //    `unreadOnly` 查出来的。在「只看未读」模式下，`items.count`=未读条数、
    //    `scopeCount`=全部条数 ⇒ 底部会报「下面还有 450 条更早的记录」，
    //    而那 450 条**全是已读的**，和用户此刻要看的完全无关。
    //    ⇒ 底部说的那个数，必须和列表装的是**同一个集合**，否则它不值得信。
    NSInteger scopeCount = [NotifyStore countWithBundle:self.filterBundle
                                                  since:[self sinceFromSeg]
                                                 search:self.searchText
                                          searchBundles:[self bundlesMatchingSearch:self.searchText]
                                             unreadOnly:self.unreadOnly];
    // v0.0.48：用**折叠前**的 queriedCount，不用 self.items.count —— 后者已被关键词
    //   折叠/过滤改小，会把"被规则收起的"误算成"被列表上限截断的"（第三禁忌）。
    // v0.0.49：★ 视图换成 queriedStarCount（标星后、折叠前）—— 视图里只有标星的行，
    //    queriedCount 混着非标星的，拿它算差就是"底部说的数和列表装的不是同一个集合"。
    NSInteger shown = self.starOnly ? self.queriedStarCount : self.queriedCount;
    // v0.0.49：★ 视图下**没有数字可报** —— nbStar 是派生量，SQL 里没有这一列，
    //    countWithBundle: 数不出"标星的还有几条"（也绝不能为了数它在 SQL 里复刻一遍
    //    关键词匹配 —— 两套匹配逻辑必然对不上，v0.0.48 刚立过这条纪律）。
    //    ⇒ 只在查询窗口真被截断时（scopeCount > 实际查回来的条数）提醒"更早的可能还有"，
    //    不报数；窗口没截断 ⇒ 这个范围内每一行都看过了，标星的一条不漏。
    BOOL starSaturated = self.starOnly && (scopeCount >= 0 && scopeCount > self.queriedCount);
    // scopeCount < 0 ⇒ DB 打不开，宁可不提示（跟 `updateHiddenUnread` 的处理一致）
    NSInteger more = starSaturated ? 1
                                   : ((scopeCount >= 0) ? (scopeCount - shown) : 0);

    if (more <= 0) {
        self.table.tableFooterView = nil;
        return;
    }

    if (!self.moreFooter) {
        UILabel *l = [[UILabel alloc] init];
        l.font = [UIFont systemFontOfSize:12];
        l.textColor = [UIColor secondaryLabelColor];
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 2;
        self.moreFooter = l;
    }
    // 🔴 「列表上限」这个数字从 `NotifyStore` 取，**不要**在界面里另写一个 2000
    // v0.0.43：文案跟着模式改一个字。只改数字不改文案的话，用户会去库里数
    //    「怎么还有 450 条我看不到」—— 而它们其实是他自己选了"只看未读"挡掉的。
    // v0.0.49：★ 视图的文案**不带数字**（数不出，见上），只说"可能还有"——
    //    报一个假数字比不报更糟（用户会去数，数出来不对就不再信这条提示）。
    if (starSaturated) {
        self.moreFooter.text = [NSString stringWithFormat:
            @"更早的记录里可能还有标星的\n★ 视图一次最多查 %ld 条记录，更早的在库里翻不到",
            (long)[NotifyStore listLimit]];
    } else {
    self.moreFooter.text = [NSString stringWithFormat:
        @"下面还有 %ld 条更早的%@记录\n列表一次最多显示 %ld 条，更早的在库里、这里翻不到",
        (long)more, self.unreadOnly ? @"未读" : @"", (long)[NotifyStore listLimit]];
    }

    CGFloat w = self.table.bounds.size.width;
    if (w <= 0) w = [UIScreen mainScreen].bounds.size.width;
    CGSize fit = [self.moreFooter sizeThatFits:CGSizeMake(w - 24, CGFLOAT_MAX)];
    self.moreFooter.frame = CGRectMake(12, 0, w - 24, MAX(48, fit.height + 20));
    self.table.tableFooterView = self.moreFooter;
}

// v0.0.40：算「当前筛选之外还有多少条未读」，顺手把提示文案写好。
// 🔴 为什么是"全库未读 − 当前筛选下的未读"，而不是只算时间窗：
//    会让未读看不见的筛选有**三个**（App 图标 / 时间 / 搜索），任何一个生效都算。
//    只算时间窗的写法（v0.0.39）在真机上永远看不到 —— 默认窗口就是 24 小时。
// 🔴🔴 两个数必须走**同一条 SQL 条件**（`NBPrepareScope`）：如果这里用内存遍历
//    `items` 里 `d[@"read"]` 去数"可见未读"，和 SQL 的 `read=0` 口径就会差在
//    `read IS NULL` 的老行上（`sqlite3_column_int` 把 NULL 读成 0、SQL 里 `read=0` 不成立）
//    ⇒ 差值被算小 ⇒ 提示条该出现时不出现。这类错**不报错、只静默少一条**。
// 🔴 两次查询：第一次全库（不限任何条件），第二次带当前筛选。
//    第一次的结果是 0 就不用查第二次了（回到最常见的"全读完了"状态，省一次查询）。
- (void)updateHiddenUnread {
    self.hiddenUnread = 0;
    NSInteger all = [NotifyStore unreadCountWithBundle:nil since:0 search:nil];
    if (all > 0) {
        // v0.0.42：**必须带 `searchBundles`**。搜索现在能命中 App 名，
        // 列表因此多显示了若干条 ⇒ 如果这里还按"只匹配标题正文"算筛选内未读，
        // 那个数就偏小、`hiddenUnread` 偏大 ⇒ 顶部又变成"列表里都读完了还在喊还有 N 条"。
        // 这条坑 v0.0.40 花整版买过一次，所以把 `bundlesMatchingSearch:` 这里也调一遍
        // （返回 nil 时传 nil，和 `loadData` 完全同一条路）。
        NSInteger inScope = [NotifyStore unreadCountWithBundle:self.filterBundle
                                                        since:[self sinceFromSeg]
                                                       search:self.searchText
                                                searchBundles:[self bundlesMatchingSearch:self.searchText]];
        // 🔴 `inScope < 0`（DB 打不开）时宁可不提示，也不显示一个可能是瞎猜的数。
        if (inScope >= 0) self.hiddenUnread = MAX(0, all - inScope);
    }
    // v0.0.41：按钮用 `setTitle:forState:`，不再设 `.text`（UIButton 没有 text 属性）。
    // `›` 是"可以点"的暗示，只加在按钮上 —— 空列表正中那句是 UILabel、点不了，不能加。
    NSString *hint = [self hiddenHintText];
    [self.hiddenHint setTitle:(hint ? [hint stringByAppendingString:@" ›"] : nil)
                     forState:UIControlStateNormal];
}

// v0.0.41：**所有由"未读数"派生出来的界面元素，只准从这里更新**。
// 🔴 为什么必须收成一个出口：v0.0.40 只把顶部提示条接在 `loadData` 里，
//    而"点开一条记录"走的是「只刷一行」那条路（`reloadRowsAtIndexPaths:`，不重查库）——
//    那条路上筛选内的未读少了一条、筛选之外那个数可能变大，提示条却纹丝不动。
//    真机复现：点某个 App 图标 → 把它 3 条未读依次读完 → 顶部该出现
//    「其它 App 还有 N 条」却不出现，要切个时间才冒出来。
// 🔴 这是"同一个量只算一次"的反面纪律：**一个量有几处派生出口，改的时候就得全改**。
//    与其每次都记得，不如让它只有一个入口。
- (void)refreshUnreadDerived {
    [self refreshUnreadDots];      // 图标栏红点（按 App 汇总）
    [self updateHiddenUnread];     // 顶部提示条（筛选之外还有多少）
    // 🔴 `setNeedsLayout` 不能省：提示条出现/消失会改图标栏和列表的**起始 y**。
    [self.view setNeedsLayout];
}

// v0.0.41：点顶部提示条 ⇒ 把三个筛选一次清干净，直接看到全部未读。
// 🔴 为什么清三样而不是只清文案里点名的那个：三种筛选任意叠加时，
//    只清一样还是看不到（这也正是 v0.0.40 在叠加时不点名出口的原因）。
//    点一下全清，文案就永远不需要教用户"点哪里"。
// 🔴 为什么连着 `searchBar.text` 一起清：只清 `self.searchText` 的话搜索框里还留着字，
//    用户会以为"还在搜"，然后自己再清一次。程序设 `text` **不会**回调
//    `searchBar:textDidChange:`，所以 `self.searchText = nil` 那一行不能省。
// 🔴 为什么不动 `unreadOnly`：提示条说的是"未读"，用户本来就在看未读时，
//    跳过去仍然只看未读才符合他的意图；强行切回「全部」等于替他改了个无关的选择。
- (void)onHiddenHintTap {
    BOOL changed = NO;
    // v0.0.49：★ 筛选也清。
    // 🔴 为什么它和 unreadOnly 待遇不同（v0.0.41 刻意不动 unreadOnly）：
    //    unreadOnly **不挡未读**（它挡的是已读），提示条承诺"看到未读"时它不妨碍；
    //    而 starOnly **挡未读**（标星且未读才看得见）⇒ 不清它，用户点完提示条
    //    还是看不到承诺的那些未读，提示就成了说谎。
    if (self.starOnly) {
        self.starOnly = NO;
        self.starBtn.selected = NO;
        changed = YES;
    }
    if (self.filterBundle.length) {
        self.filterBundle = nil;
        changed = YES;
    }
    if (self.searchText.length) {
        self.searchText = nil;
        self.searchBar.text = nil;
        changed = YES;
    }
    if (self.timeSeg.selectedSegmentIndex != 2) {   // 2 = 不限时间（见 timeNames / sinceFromSeg）
        self.timeSeg.selectedSegmentIndex = 2;
        changed = YES;
    }
    if (!changed) {
        // 四个筛选本来都是开的（App/时间/搜索/★，v0.0.49 起）⇒ 这个数只可能是
        // "库里条数超过列表能显示的上限"造成的，点它没有地方可跳。如实说明，
        // 别让用户白点一下还以为坏了。
        [self alertTitle:@"记录太多"
                    text:@"当前已经是「全部 App · 不限时间 · 无搜索」，"
                         @"但库里的记录超过了列表能显示的上限，有一部分翻不到。"
                         @"可以到「设置 → 记录上限」把它调小一些，让列表能一次装下。"];
        return;
    }
    // v0.0.42：作废挂起的搜索防抖。
    // 🔴 不清的话，"刚敲完字、防抖还没到点就点了提示条"会这样：
    //    提示条把筛选全清干净 → 立刻 `loadData`（列表变全）→ 250ms 后挂起的那个
    //    再跑一次 `loadData`。结果虽然一样、用户看不出来，但白跑一次全量查询
    //    （6~8 条 SQL + 重建图标栏 + 重载 2000 行）—— 正是这版要省掉的那笔开销。
    [self cancelPendingLoadData];
    [self loadData];
}

#pragma mark - v0.0.48 关键词规则（标星 + 折叠）

// 给查询结果套关键词规则的**唯一出口**。
// 🔴 无规则时原样返回 rows ⇒ 行为/性能零变化（keywordActionForTitle: 里也早退，
//    这里再挡一道是双保险，也保证 items 保持 queryWithBundle: 原样返回的类型）。
// 🔴 foldedCount 在这里算（**与 showFolded 无关**）：它是"被 fold 规则命中的总条数"，
//    提示条据此决定显隐和文案；showFolded 只决定这些行"显不显示"，不改变这个数。
// 🔴 queriedCount 存**折叠前**的条数，专给 updateMoreFooter（第三禁忌，见属性注释）。
// v0.0.49：★ 筛选（starOnly）加进来，**必须排在折叠之前**：
//    🔴 顺序反了会出两种错 —— ① foldedCount 把"非标星且被折叠"的行也算进去，
//       提示条的 N 就不是"这个视图里被收起的"了；② 非标星的行会带着 nbStar=NO
//       混进 items，★ 视图就不纯。
//    🔴 另一个后果：★ 视图下 foldedCount / queriedStarCount 都只数**标星的行**，
//       这是刻意的 —— 提示条和底部条数必须和"用户眼前这个视图"同口径。
- (NSArray<NSDictionary *> *)applyKeywordRulesToRows:(NSArray<NSDictionary *> *)rows {
    self.queriedCount = (NSInteger)rows.count;
    self.queriedStarCount = 0;
    self.foldedCount = 0;
    if (![NotifyStore keywordRules].count) {
        // v0.0.49：没有规则 ⇒ 没有任何行可能被标星 ⇒ ★ 视图必然是空的。
        //    原样返回（非 ★ 视图行为零变化），★ 视图给空数组，空列表里解释原因。
        return self.starOnly ? @[] : rows;
    }

    NSMutableArray *visible = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NBKeywordAction act = [NotifyStore keywordActionForTitle:row[@"title"]
                                                         message:row[@"message"]
                                                        subtitle:row[@"subtitle"]
                                                         appName:[self appNameForBundle:row[@"bundle"]]];
        BOOL star = (act & NBKeywordActionStar) != 0;
        BOOL fold = (act & NBKeywordActionFold) != 0;
        // v0.0.49：★ 筛选第一道。非标星的行不进当前视图，也**不计入**任何计数。
        if (self.starOnly && !star) continue;
        self.queriedStarCount += 1;
        if (fold) self.foldedCount += 1;
        // 被折叠、且当前不在"显示收起的"模式 ⇒ 不进列表（但仍计入 foldedCount）
        if (fold && !self.showFolded) continue;
        // 🔴 mutableCopy：didSelect 的"只刷一行"那条路要求 items 是可变字典（就地改 read）。
        NSMutableDictionary *m = [row mutableCopy];
        m[@"nbStar"] = @(star);
        [visible addObject:m];
    }
    return visible;
}

// 点折叠提示条 ⇒ 在"收起/显示"之间切换，然后整表重查（数量会变 ⇒ 必须重查，见 v0.0.33 纪律）。
- (void)onFoldedHintTap {
    self.showFolded = !self.showFolded;
    [self loadData];
}

// 刷新折叠提示条（loadData 里调一次）。foldedCount<=0 时 title 置空 ⇒ viewDidLayoutSubviews 藏掉。
- (void)updateFoldedHint {
    NSString *t = (self.foldedCount > 0) ? [[self foldedHintText] stringByAppendingString:@" ›"] : nil;
    [self.foldedHint setTitle:t forState:UIControlStateNormal];
}

// 折叠提示文案的唯一来源（和 hiddenHintText 同规矩：只产纯文案，`›` 由 updateFoldedHint 加）。
- (NSString *)foldedHintText {
    if (self.showFolded) {
        return [NSString stringWithFormat:@"%ld 条被规则收起（显示中，点此隐藏）", (long)self.foldedCount];
    }
    return [NSString stringWithFormat:@"%ld 条被关键词规则收起", (long)self.foldedCount];
}
// 🔴 文案必须说清「被什么挡住了」，否则用户不知道往哪一步退。
//    **但只在能确定唯一出口时才点名**：三种筛选叠加时点名其中一个（比如
//    "点「全部」图标看全"）会把人带进死路 —— 他照做了还是看不到，就会认定
//    整个提示在说谎，比不提示更糟。
- (NSString *)hiddenHintText {
    if (self.hiddenUnread <= 0) return nil;
    NSInteger n = self.hiddenUnread;
    BOOL byApp = (self.filterBundle.length > 0);   // 顶部点了某个 App 图标
    BOOL bySearch = (self.searchText.length > 0);
    BOOL byTime = ([self sinceFromSeg] > 0);       // 第 2 段「不限时间」时是 0
    NSInteger dims = (byApp ? 1 : 0) + (bySearch ? 1 : 0) + (byTime ? 1 : 0);
    if (dims == 1) {
        if (byApp) {
            return [NSString stringWithFormat:@"⚠️ 还有 %ld 条未读 · 点顶部「全部」图标看全",
                                             (long)n];
        }
        if (bySearch) {
            return [NSString stringWithFormat:@"⚠️ 还有 %ld 条未读 · 清空搜索就能看到",
                                             (long)n];
        }
        // 只有时间窗在挡：和 v0.0.39 一字不差（这一种情况语义没变、出口唯一）
        return [NSString stringWithFormat:@"⚠️ 更早还有 %ld 条未读 · 切「不限时间」看",
                                         (long)n];
    }
    if (dims == 0) {
        // 三个筛选都没生效却还有没显示的 —— 只可能是 `queryWithBundle` 的 LIMIT 2000
        // 截断了。这时点不出任何"出口"，如实说"没显示出来"。
        return [NSString stringWithFormat:@"⚠️ 还有 %ld 条未读没显示出来", (long)n];
    }
    // 两种以上筛选叠加：出口不止一个，笼统说，不点名。
    return [NSString stringWithFormat:@"⚠️ 还有 %ld 条未读在当前筛选之外", (long)n];
}

// v0.0.38：库里变了才重查一次。给「从详情页/设置页返回」和「App 回前台」用。
- (void)refreshIfChanged {
    NSInteger total = [NotifyStore count];
    NSInteger topId = [NotifyStore maxRowId];
    // v0.0.49：关键词规则的指纹也参与"要不要重查"的判定。
    // 🔴🔴 为什么必须加：v0.0.48 起折叠/标星由 settings.plist 里的规则**派生**，
    //    而规则改动**不走数据库** ⇒ 只比分率和 MAX(id) 的话，"改完规则回列表"
    //    看到的是旧状态（v0.0.48 验机第 6 条"立即生效"在这个缺口下并不成立，
    //    只是当时还没真机验到）。★ 视图对规则的依赖更直接：建完 ★ 规则回来
    //    点 ★，列表必须是新的。
    // 🔴 比**内容**不比 mtime：App 内改、Filza 手动改都算；NSArray/NSDictionary 的
    //    isEqual: 是深比较，≤20 条规则的成本可以忽略（比一次 SQL 便宜得多）。
    NSArray<NSDictionary *> *rulesNow = [NotifyStore keywordRules];
    BOOL rulesChanged = ![rulesNow isEqual:self.lastRules];
    // 🔴 两个都得比：库满之后新增记录不会让条数变大（tweak 先裁掉一条最旧的），
    //    只有 `MAX(id)` 会变；反过来，删记录通常只让条数变小。
    if (total == self.lastTotal && topId == self.lastMaxId && !rulesChanged) return;
    self.lastRules = rulesNow;
    // 🔴 DB 打不开时 `count` / `maxRowId` 双双回 -1，和上一次的 -1 相等 ⇒ 这里直接返回，
    //    列表保持原样。这是**故意的**：打不开库的时候"刷新"只会把好数据换成空列表。
    [self reloadKeepingOffset];
}

// v0.0.38：整表重查，但保住滚动位置。
// 🔴 为什么必须有它：本项目一条硬规矩是「改完数据库必须整表重查」（内存数组永远从
//    数据库重建，只改内存 = 只改账本的读数）。而整表 reload 会把 `contentOffset`
//    清零 —— v0.0.35 的注释里已经写明"滚到中间点开一条再返回，列表跳回顶部"。
//    这段逻辑原来只写在 `didSelectRow:` 的「只看未读」分支里，现在抽出来当**唯一来源**：
//    `refreshIfChanged` 和它共用一份。
// 🔴 顺序不能换：存 offset → 重查 → `layoutIfNeeded` → 写回。
//    少了 `layoutIfNeeded`，`contentSize` 还是旧值，clamp 会按旧高度算 ⇒ 位置仍然错。
// 🔴 这里**保持 `off.y` 不变**是有意的：新记录插在最前面，用户会看到内容整体下移一行、
//    新行出现在原来的位置 —— 这比"位置纹丝不动、新行藏在上面要自己往上滚"更符合直觉。
- (void)reloadKeepingOffset {
    CGPoint off = self.table.contentOffset;
    [self loadData];
    // 🔴 v0.0.39：从 `[self.table layoutIfNeeded]` 改成 `[self.view layoutIfNeeded]`。
    //    原因：这一版起 `loadData` 可能让「更早未读提示条」出现/消失 ⇒ **table 自己的
    //    frame 也会变**（起始 y 和高度都跟着变）。只给 table 做 layoutIfNeeded
    //    只更新它内部的 contentSize，`bounds.size.height` 还是旧值 ⇒ clamp 会按旧高度
    //    算 ⇒ 滚到中间时位置多跳/少跳一截（这种偏差真机上看着就是"莫名其妙动了一下"）。
    [self.view layoutIfNeeded];
    CGFloat maxY = MAX(0, self.table.contentSize.height - self.table.bounds.size.height);
    self.table.contentOffset = CGPointMake(0, MIN(off.y, maxY));
}

// 空列表时直接把自检信息打在屏幕上（判断 tweak 有没有写库、App 能不能读到）
- (void)updateEmptyView {
    if (self.items.count) {
        self.table.backgroundView = nil;
        return;
    }
    UILabel *l = [[UILabel alloc] init];
    l.numberOfLines = 0;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:13];
    l.textColor = [UIColor secondaryLabelColor];
    // v0.0.36：多写一行「当前筛选」。
    // 🔴 加了「只看未读」之后空列表变得很常见：时间选「今天」+ 只看未读 是空的，
    //    而昨天有未读。不把条件写出来的话，用户会直接断定"没有未读"。
    NSMutableString *t = [NSMutableString stringWithFormat:@"暂无记录\n\n当前筛选：%@",
                          [self filterDesc]];
    // 🔴 v0.0.37：真机上用户卡在这里过 —— 红点（当时是全库口径）亮着，点进某个 App
    //    却是空的，于是"红点永远消不掉"。现在红点已经改成同口径了，但筛选之外的未读
    //    仍然存在。不说清楚的话，用户会以为记录丢了。
    // v0.0.39：这里原来自己再查一遍 `bundlesWithUnread`（全库 App 集合），
    //    现在直接用 `loadData` 算好的那个数 —— **同一个量只算一次**。
    // v0.0.40：文案改成和顶部提示条**同源**（`hiddenHintText`）。
    //    以前这里自己写一句"被时间筛选挡住了 —— 把时间切到「不限时间」"，
    //    而 v0.0.40 起那个数还包含"被 App 图标挡住"和"被搜索挡住"的情况 ⇒
    //    那句话在搜索态下就是错的（照它切时间什么也不会变）。
    if (self.hiddenUnread > 0) {
        [t appendFormat:@"\n\n%@", [self hiddenHintText]];
    }
    if (self.unreadOnly) {
        [t appendString:@"\n\n（当前是「只看未读」，切上面「全部」可以看所有记录）"];
    }
    // v0.0.49：★ 视图空时必须说清"它为什么空" —— 否则用户以为记录丢了。
    //    两种空分开说：有 ★ 规则但这个范围没命中 ⇒ 只解释视图语义；
    //    根本没有 ★ 规则 ⇒ 点醒去建规则（否则这个视图永远空着，比没做更糟）。
    if (self.starOnly) {
        if ([self anyStarRule]) {
            [t appendString:@"\n\n（★ 视图只显示命中「★ 标星」规则的记录，"
                              @"当前范围里没有）"];
        } else {
            [t appendString:@"\n\n（★ 视图还没有可显示的内容：去 设置 → 关键词规则 "
                              @"添加一条带「★ 标星」动作的规则）"];
        }
    }
    // v0.0.48：列表被关键词规则折叠空时，**必须说清"其实有 N 条、被规则收着"** ——
    //    否则屏幕只剩"暂无记录"，用户会以为记录丢了（而它们是被自己设的规则收起的）。
    //    上面那条可点的 foldedHint 提示条是同一个事实的"可操作版"，这里补一句解释，不矛盾。
    if (self.foldedCount > 0) {
        [t appendFormat:@"\n\n%ld 条被关键词规则收起，点上面的提示可以显示", (long)self.foldedCount];
    }
    [t appendFormat:@"\n\n%@", [NotifyStore debugSummary]];
    l.text = t;
    self.table.backgroundView = l;
}

// v0.0.38：时间段的段名 —— **唯一来源**。
// 🔴 v0.0.36 之前 `buildUI` 里写一份 `@[@"今天", …]`、`filterDesc` 里又写一份，
//    结果"标签改了、另一处没改"（更糟的是当时的标签本身就说谎：叫「今天」、实际
//    `now-86400`）。现在只有这一处字面量，`timeSeg` 的 items 和所有文案都从它取。
// 🔴 顺序必须和 `sinceFromSeg` 的分支顺序严格对应（0=24小时、1=7天、2=不限）。
- (NSArray<NSString *> *)timeNames {
    return @[@"近24小时", @"近7天", @"不限时间"];
}

// v0.0.38：时间段的显示名。
// 🔴 必须和 `sinceFromSeg` 的实现一致：第 0 段实际是 `now - 86400` ⇒ 叫「近24小时」，
//    不叫「今天」（v0.0.36 就是这么名不符实的，v0.0.37 改掉了）。
- (NSString *)timeName {
    NSArray<NSString *> *times = [self timeNames];
    NSInteger ti = self.timeSeg.selectedSegmentIndex;
    return (ti >= 0 && ti < (NSInteger)times.count) ? times[ti] : @"时间?";
}

// v0.0.38：「App + 时间」两维的范围描述 = 「全标已读」的**作用范围**。
// 🔴 **故意不含**未读状态和搜索词：标记用的 SQL 只按 bundle + since 过滤。
//    把搜索词写进这句里，用户就会以为"只标搜索出来的那几条"，而实际标的是整个范围。
- (NSString *)scopeDesc {
    NSString *app = self.filterBundle.length ? [self shortName:self.filterBundle] : @"全部 App";
    return [NSString stringWithFormat:@"%@ · %@", app, [self timeName]];
}

// v0.0.36：把当前筛选维度拼成一行（v0.0.49 起是五个：App / 时间 / 已读状态 / ★ / 搜索）。
- (NSString *)filterDesc {
    NSMutableArray *a = [NSMutableArray array];
    [a addObject:[self scopeDesc]];
    [a addObject:(self.unreadOnly ? @"只看未读" : @"全部状态")];
    // v0.0.49：★ 维度。写在搜索之前 —— 它比搜索"更靠近列表语义"（筛的是行本身）。
    if (self.starOnly) {
        [a addObject:@"★ 只看标星"];
    }
    if (self.searchText.length) {
        [a addObject:[NSString stringWithFormat:@"搜索「%@」", self.searchText]];
    }
    return [a componentsJoinedByString:@" · "];
}

#pragma mark - UISearchBarDelegate
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.searchText = searchText.length ? searchText : nil;
    // v0.0.42：**防抖**，不再每敲一个字就全量重查。
    // 🔴 以前这里是直接 `[self loadData]`，而一次 `loadData` 要跑 6~8 条 SQL：
    //    `reloadIconBar`（DISTINCT bundle + 未读集合 + 重建图标按钮）、列表查询（最多 2000 行）、
    //    `count`、`maxRowId`、`updateHiddenUnread` 的两条 COUNT，外加 v0.0.42 新增的
    //    `countWithBundle:…`。打一个 4 字词 = 5 次全量刷新，量级到 500 条以上就能感觉到卡。
    // 🔴 为什么用 `searchGen` 代次而不是一个 BOOL 标记：BOOLean 标记挡不住"排了三个 block"
    //    （敲 a、ab、abc 各排一个）⇒ 三个都会跑，比不防抖更慢。
    [self scheduleLoadData];
}

- (void)scheduleLoadData {
    NSUInteger gen = ++self.searchGen;   // 先自增，让之前挂起的那些全部作废
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNBAutoSearchDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        // 代次变了 ⇒ 后面还有更新的输入在排队，这一枪让给它
        if (ss.searchGen != gen) return;
        [ss loadData];
    });
}

- (void)cancelPendingLoadData {
    // 只把代次推进一格：所有挂起的 block 跑起来都会发现自己过期了，直接返回。
    // 🔴 比"再维护一个 dispatch_block_cancel"简单，也不会漏掉已经进队列的那些。
    self.searchGen++;
}

// v0.0.42：按键盘上的「搜索」键 ⇒ **立刻**出结果，不等防抖。
// 🔴 防抖是为了省掉"打字中的中间态"，但用户主动按了搜索键就是在说"我现在要结果"。
//    让他再等 250ms 是没道理的，而且他会以为按了没反应、再按一次。
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [self cancelPendingLoadData];
    [self loadData];
}

// v0.0.36：scope 切换（全部 / 未读）。
// 🔴 走 `loadData` 而不是自己过滤 `self.items` —— 后者只能过滤"已经查出来的 2000 条"，
//    而"只看未读"应该是在数据库层筛（数量完全不同的两类查询）。
// v0.0.37：改由自己的 `unreadSeg` 驱动（系统 scope bar 在 iOS 16 上没渲染出来）。
- (void)onUnread:(UISegmentedControl *)seg {
    self.unreadOnly = (seg.selectedSegmentIndex == 1);
    // v0.0.38：「全标已读」跟着这一段进出。
    // 🔴 必须 `setNeedsLayout`：分段控件的宽度在「只看未读」时要收窄
    //    （给按钮腾位置），而宽度只在 `viewDidLayoutSubviews` 里算。
    //    只改 hidden 不重布局的话，按钮会压在分段控件上。
    self.markAllBtn.hidden = !self.unreadOnly;
    [self.view setNeedsLayout];
    [self loadData];
}

// v0.0.49：★ 只看标星开关。
// 🔴 走 `loadData` 整表重查，不自己过滤 `self.items` —— 和 `onUnread:` 同一条纪律：
//    内存过滤只能过滤"已经查出来的 2000 条"，而 ★ 视图的语义是"这个范围内所有标星的"。
// 🔴 不需要 `setNeedsLayout`：starBtn 常驻、分段行宽度不随 starOnly 变
//    （布局分支只认 unreadOnly）—— 提示条的出现/消失由 loadData 末尾统一触发。
- (void)onStar:(id)sender {
    self.starOnly = !self.starOnly;
    self.starBtn.selected = self.starOnly;
    [self loadData];
}

// v0.0.49：有没有任何规则带 ★ 动作。
// 🔴 为什么要有这个判断：★ 视图为空时分两种——"这个范围里没有标星的"和
//    "根本没有任何规则会标星"。后者不说清楚，用户会以为功能坏了
//    （v0.0.39 同款纪律：一个永远不触发还不解释的功能，比没做更糟）。
- (BOOL)anyStarRule {
    for (NSDictionary *r in [NotifyStore keywordRules]) {
        if ([r[@"star"] boolValue]) return YES;
    }
    return NO;
}

#pragma mark - UITableView
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NotifyCell *c = [tableView dequeueReusableCellWithIdentifier:@"c" forIndexPath:indexPath];
    NSDictionary *d = self.items[indexPath.row];
    NSString *bid = d[@"bundle"];
    NSString *title = d[@"title"];
    NSString *msg = d[@"message"];
    NSString *sub = d[@"subtitle"];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[d[@"ts"] doubleValue]];

    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm";
    });

    UIImage *ic = [AppIconLoader iconForBundle:bid];
    [c setIcon:ic letter:[self shortName:bid]];
    // v0.0.42：一行小字报出「这条是哪个 App 的」。
    // 🔴 以前只有图标 —— 图标加载失败就只剩一个首字母，而「b」「m」这种字母
    //    在十几个 App 的列表里分辨不出来。而"这条到底是哪个 App 弹的"
    //    恰恰是这个盒子最需要回答的问题（用户来查的就是"谁在打扰我"）。
    [c setAppName:[self appNameForBundle:bid]];
    [c setTitleText:title message:msg subtitle:sub];
    // v0.0.44：搜索命中高亮。**必须传当前搜索词**，且放在两个 set 之后也不影响
    // （cell 内部是"先存后渲"，顺序无关）。传 nil 时不高亮 —— 正常浏览不该有黄底。
    [c setHighlightQuery:self.searchText];
    [c setTimeText:[fmt stringFromDate:date]];
    // v0.0.72：`read` 字段数据层早就有了（`queryWithBundle:` 的 SELECT 里一直带着），
    // 只是 cell 从来没用过 ⇒ `markRead:` 写了等于没写，用户看不出哪条看过。
    // 0 = 未读（建表默认值），非 0 = 已读。
    // 🔴 v0.0.72：从「左侧蓝点」改成「右上角带数字的书签」，所以要把**该 App 在
    //    当前列表里的未读条数**一起传下去。数取自 `nbUnreadByBundle`（与列表同口径），
    //    ⛔ 不许在这里查库（每次 cellForRow 都查 = 滚动时几十次 SQL）。
    [c setUnread:([d[@"read"] integerValue] == 0)
           count:[self.nbUnreadByBundle[bid] integerValue]];
    // v0.0.48：关键词"标星"动作（★ 展示时派生，nil ⇒ NO ⇒ 不显示，无规则时走这条）。
    [c setStarred:[d[@"nbStar"] boolValue]];
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = self.items[indexPath.row];
    [NotifyStore markRead:[d[@"id"] integerValue]];

    // v0.0.35：把「已读」同步回内存并只刷这一行。
    // 🔴 为什么不在 `viewWillAppear:` 里 `loadData`（这是最容易想到的做法）：
    //    整表 reload 会让**滚到中间点开一条再返回，列表跳回顶部** —— 真机上一碰就发现。
    // 🔴 为什么这里用 `reloadRowsAtIndexPaths:` 是安全的（v0.0.33 删除场景里它是禁忌）：
    //    判据从来不是"这个 API 好不好"，而是**数量变不变**。这里只把一个字段 0→1，
    //    行数不变 ⇒ 内存下标和 row 仍然一一对应；而删除会改数量 ⇒ 必须整表重查。
    // 🔴 顺序不能反：先 markRead（写库），再改内存，再刷新 —— 反了刷出来的还是旧值。
    if (self.unreadOnly) {
        // 🔴 v0.0.36：「只看未读」模式下点开一条，它变已读后**不该再出现在列表里**。
        //    这是**数量会变**的场景 ⇒ 禁用 `reloadRowsAtIndexPaths:`（它要求内存下标
        //    与行严格对应，少一行之后就对不上了），必须整表重查。
        // v0.0.38：那套「存 offset → 重查 → 恢复」抽成了 `reloadKeepingOffset`，
        //    这里改成调它 —— 同一个动作只留一份实现（原来有两处，改一处必然漏另一处）。
        [self reloadKeepingOffset];
    } else if ([d isKindOfClass:[NSMutableDictionary class]]) {
        [(NSMutableDictionary *)d setObject:@1 forKey:@"read"];
        // v0.0.72：这一步只改一行、**不重查库**，所以未读计数必须在这里手动重建，
        // 否则整屏的未读书签会停在"标已读之前"的数 —— 而那条记录的书签明明已经消失了，
        // 剩下的同 App 卡片却还写着同一个数（同一个界面里两个数互相矛盾）。
        // 🔴 顺序：改内存 → 重建计数 → reloadRows（cellForRow 读的是重建后的字典）。
        [self rebuildBundleUnread];
        // 🔴 v0.0.72：书签上的数是**该 App** 的未读条数 ⇒ 同一个 App 的**其它可见行**
        //    也得一起刷，否则读掉一条之后，屏幕上同 App 的另外几张卡片还写着旧数。
        //    仍然用 `reloadRows` 而不是整表 `reloadData`：**数量没变**，
        //    它只重排这几行、滚动位置不动（"数量变不变"才是这个 API 的判据，见删除场景）。
        NSString *bid = d[@"bundle"];
        NSMutableArray<NSIndexPath *> *paths = [NSMutableArray arrayWithObject:indexPath];
        for (NSIndexPath *ip in [tableView indexPathsForVisibleRows]) {
            if (ip.section != indexPath.section || ip.row == indexPath.row) continue;
            if (ip.row >= (NSInteger)self.items.count) continue;   // 越界就当没有这一行
            NSString *other = self.items[ip.row][@"bundle"];
            if ([other isEqualToString:bid]) [paths addObject:ip];
        }
        [tableView reloadRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationNone];
        // v0.0.41：红点**和顶部提示条**一起重算。
        // 🔴 原来这里只调了 `refreshUnreadDots` —— 红点跟着变了，提示条没变。
        //    "这行刚变已读"影响的正是**两个**派生量：该 App 的未读数（红点）、
        //    以及"筛选之外还有多少"（提示条，筛选内的未读少了一条）。
        [self refreshUnreadDerived];
    } else {
        // 兜底：万一哪天 query 改成返回不可变字典，退回整表重查（会丢滚动位置，但不会错）
        [self loadData];
    }

    // v0.0.33：点开看**全文**。列表 cell 的正文 `numberOfLines = 2`、超了截断，
    // 而在这之前点一行只做 markRead ⇒ 长通知永远看不全、也复制不了。
    // 对「消息盒子」来说这是核心缺口：验证码、链接、长消息都看不全，等于记录没记全。
    NotifyDetailViewController *vc = [[NotifyDetailViewController alloc] init];
    vc.item = d;
    __weak typeof(self) weakSelf = self;
    // 🔴 删除后由**列表**重查数据库。详情页绝不直接改 self.items ——
    //    在「搜索 / App 筛选 / 时间段」状态下，内存下标和数据库 id 完全是两回事。
    vc.onDeleted = ^{ [weakSelf loadData]; };
    [self.navigationController pushViewController:vc animated:YES];
}

// v0.0.33：左滑删除。
// 🔴 刻意**不用** `deleteRowsAtIndexPaths:` —— 它要求"内存数组与即将删的行严格同步"，
//    而我们删的是数据库。正确顺序是「先删库 → 整表重查」，让两边从同一个来源重建。
//    只改内存 = 只改账本的读数（数量契约第 2 问）：症状是删完那一行还在，
//    或者删了 A 却少了一条 B（搜索/筛选态下标错位）。
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
        trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= (NSInteger)self.items.count) return nil;
    NSDictionary *d = self.items[indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *del = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"删除"
                          handler:^(UIContextualAction *action, UIView *src, void (^done)(BOOL)) {
        NSInteger rowId = [d[@"id"] integerValue];
        NBSyncClearOutcome outc = NBSyncClearDeleteFail;
        BOOL ok = (rowId > 0) && [NotifyStore deleteRow:rowId outcome:&outc];
        // 先重查（数据源变了），再告诉系统动作完成 —— 顺序反了会"删完还留着"。
        [weakSelf loadData];
        done(YES);
        if (!ok) {
            // 删不到也要说：最常见的原因是 tweak 按「记录上限」把它裁掉了，
            // 而列表还显示着。静默失败会让人以为删除按钮坏了。
            [weakSelf alertTitle:@"没删掉"
                            text:@"这条记录已经不在了（可能被「记录上限」自动清掉了）。列表已刷新。"];
        } else if (outc == NBSyncClearNoSysId) {
            // 🔴 v0.0.84：这是「有些能删、有些不行」最常见的那一半 ——
            //    记录里没有 sys_id，删它**没有任何东西可匹配**，通知中心当然纹丝不动。
            //    以前这里是静默的，用户只会说"删了没反应"。
            // 🔴 v0.0.85 改口径：上一版这里写「（是旧版本记下的）」，那是**没量过的断言**——
            //    用户明确说「有些**刚推送**的也会这样」（`nc_diag(24).txt`）。
            //    所以只陈述事实（没有 ID、因此定位不到），不猜原因。
            [weakSelf alertTitle:@"通知中心不会变"
                            text:@"这条记录没有系统通知 ID，无法定位通知中心里的那一条，"
                                  "所以只能删掉盒子里的记录。"];
        } else if (outc == NBSyncClearOff) {
            [weakSelf alertTitle:@"已删除（未同步通知中心）"
                            text:@"设置里「删除时同步清通知中心」是关的。"
                                  "打开后删记录才会把通知中心里那一条也一起清掉。"];
        }
    }];
    del.backgroundColor = [UIColor systemRedColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end
