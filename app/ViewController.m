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
// v0.0.178：触觉反馈的唯一实现（原来是 NotifyCell.m 里的 static 函数，本文件调不到）
#import "NBHaptic.h"
// v0.0.118：长按菜单里的「打开」⇒ 按 bundleId 打开对应 App（两条路 + 失败留痕都在那个模块里）
#import "AppLauncher.h"
// v0.0.164：列表顶部的双列总览网格（只负责画，聚合与取值都在本文件里算）
#import "OverviewGridView.h"
// v0.0.166：长按菜单里的「打开链接 / 复制验证码」（纯本地正则，抽不到就不显示）
#import "NBTextExtract.h"
// v0.0.175：「稍后提醒」已整个删除（越狱 App 拿不到通知授权，真机实测见
// NBDiagnostics.h 文件头），这个头文件现在只剩**只读诊断** + dylib 版本对齐。
#import "NBDiagnostics.h"
// v0.0.168：临时静音。判定逻辑在 NotifyFilter 里 —— **tweak 与 App 编的是同一份**，
// 不能在 App 里再写一份"这个 App 现在静音了没"，否则两边口径会各走一路。
#import "NotifyFilter.h"
// v0.0.187：浮层提示的唯一实现。搬到共享文件是因为统计页的行内行动要贴在**容器**上
// （写入发生在记录页，而记录页那一刻在另一个页签、不可见）。
#import "NBToast.h"

// v0.0.38 的 `kNBMarkAllWidth`（「全标已读」按钮固定宽度）在 v0.0.131 删掉了：
// 那个按钮已经搬进筛选菜单，布局里不再需要算它的宽度 —— 连声明一起去掉，
// 免得后来的人照着注释去算一条早就不存在的布局。

// ============================================================================
// v0.0.122：`[刷新]` 状态行 —— 「为什么刷 / 为什么没刷」必须能在日志里读出来
// ============================================================================
// 🔴 为什么非要有它（v0.0.121 的真机日志账）：
//    v0.0.121 给刷新链路加了两条新路径：**节流挡掉**、**快照内容没变**。两条都是
//    "提前 return"，一个字的日志都不留 ⇒ 日志里只能看到 `[扫]` 一直在刷，
//    而"App 到底有没有刷新、为什么没刷新"完全读不出来。
//    ⇒ 「该发生的没发生的理由，也必须打出来」—— 静默的提前返回，在日志上
//      和"根本没触发"长得**一模一样**，这是本项目反复栽的一类（探针没弹 ≠ 没生效）。
// 🔴 为什么是五个计数而不是一行流水：
//    每次动作打一行会在密集触发时把日志窗口（~50 行）占满，反而更看不清；
//    而按分钟汇总的五个数，能同时回答"有没有被叫醒"和"叫醒后走了哪条路"。
//    计数清零 = 这一行说的是**上一个区间**。
// 🔴 v0.0.123：**首次**（进程启动后第一次）单独一种文案，不是"区间 -1"。
//    因为首行必然长成「叫醒≥1、其余多为 0」（就是它自己触发的打印），
//    混在区间行里会被它自己的读法判成 bug —— 那是 v0.0.122 真机日志暴露的。
// 🔴 ⛔ 不许在这里写「叫醒 = 节流挡 + 快照没变 + 轻路 + 完整」这种等式：
//    `完整重查` 除了扫描链路，还会被 `onBecameActive` 里的库指纹变化**单独**触发
//    （那条根本不经过扫描），两边不同步 ⇒ 这个等式是假的，写上去就是一条恒假的判据。
typedef NS_ENUM(NSInteger, NBRefKind) {
    NBRefKindTrigger = 0,    // 被叫醒：`viewWillAppear` / `onForeground` / `onBecameActive`
    NBRefKindBlocked,        // 被节流挡掉（没有真的请求扫描）
    NBRefKindNoSnapChange,   // 扫描回来了、快照内容没变 ⇒ 只轻刷提示条，不重查
    NBRefKindLight,          // 快照变了、库没变 ⇒ 只重算残留层（轻路）
    NBRefKindFull,           // 完整重查（SQL + 规则 + 归并）
    NBRefKindCount
};

static NSTimeInterval sNBRefLogTs = 0;
static NSInteger sNBRefCnt[NBRefKindCount] = {0};

static void NBRefNote(NBRefKind kind) {
    if ((NSInteger)kind >= 0 && (NSInteger)kind < (NSInteger)NBRefKindCount) sNBRefCnt[kind]++;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    double span = (sNBRefLogTs > 0) ? (now - sNBRefLogTs) : -1.0;
    // `span < 0`（首次）必须立刻打，否则第一分钟的读数永远看不到。
    if (span >= 0 && span < NB_REF_LOG_GAP) return;
    sNBRefLogTs = now;

    NSInteger trig = sNBRefCnt[NBRefKindTrigger];
    NSInteger blk  = sNBRefCnt[NBRefKindBlocked];
    NSInteger light = sNBRefCnt[NBRefKindLight];
    NSInteger full = sNBRefCnt[NBRefKindFull];
    NSInteger noChg = sNBRefCnt[NBRefKindNoSnapChange];

    // ---------- v0.0.123：把「自动请求扫描」算出来，并处理 off-by-one ----------
    // 🔴 恒等式：`requestNCSnapshotIfDue` 是**唯一**自动出口，每次调用只走三条路之一
    //    （被节流挡 / 通过节流去请求 / 就是触发本次打印的正这一次）。
    //    触发本次打印的那一次**还没走到 `requestNCSnapshot`** ⇒
    //      **自动请求扫描 = 叫醒 − 节流挡 − 1**
    // 🔴 为什么非要把这个数打出来：v0.0.122 的真机日志里 `叫醒 10 ｜ 节流挡 5`，
    //    读日志的人只能自己算出 "5 次执行"，还要自己去数 `已请求扫描` 有几行才敢确认。
    //    「能自己算」不等于「该让读的人算」 —— 那正是这个字段存在的理由。
    // 🔴 负数**不许**当普通数值打（本项目 `-1` 的约定是"没算出来"）⇒ 单独给一句话。
    NSInteger req = trig - blk - 1;
    NSString *reqStr = (req >= 0)
        ? [NSString stringWithFormat:@"%ld", (long)req]
        : @"不成立（叫醒−节流挡<1，说明有 requestNCSnapshot 绕过了 IfDue）";

    if (span < 0) {
        // ---------- 首次：**单独一句**，且不带任何"读法" ----------
        // 🔴🔴 v0.0.123 修的真 bug：v0.0.122 首行必然长成 `叫醒 1 ｜ 其余全 0`
        //    （那次叫醒就是触发本行打印的这一次），而同一行里写着
        //    「叫醒>0 而后面全 0 ⇒ 链路在某个提前返回处死掉了」
        //    ⇒ **一个必然出现的正常形态，被它自己的读法判成了 bug**。
        //    这是"读法与判定分居"的又一个实例，而且我刚在上一版总结过这一条。
        //    ⇒ 首次改成专门文案，把"必然如此"写在数字旁边，读法留到区间行之后一次性打。
        NBSharedLog(@"=== [刷新] 首次（进程启动以来累计，**不是**区间）：叫醒 %ld ｜ 节流挡 %ld ｜ 自动请求扫描 %@ ｜ 快照没变 %ld ｜ 轻路 %ld ｜ 完整 %ld ｜ ⚠️ 这一行**必然**是「叫醒≥1、其余多为 0」—— 那次叫醒就是触发本行打印的这一次；它不是异常，也不许拿它判「链路死掉了」",
                   (long)trig, (long)blk, reqStr, (long)noChg, (long)light, (long)full);
    } else {
        NBSharedLog(@"=== [刷新] 区间 %.0f 秒：叫醒 %ld ｜ 节流挡 %ld ｜ 自动请求扫描 %@ ｜ 快照没变 %ld ｜ 轻路 %ld ｜ 完整 %ld",
                   span, (long)trig, (long)blk, reqStr, (long)noChg, (long)light, (long)full);
    }

    // ---------- 读法：**一个进程只打一次** ----------
    // 🔴 v0.0.123：以前它跟在每一个区间行后面 —— 那段字每个区间一个字都不变，
    //    重复打就是纯噪音。刚在 tweak 侧为"每次都打的行"付过代价（`[扫][诊]` 77 秒 18 行
    //    把 `[残]` 挤出窗口），同一类问题不许在 App 侧再犯一次。
    // 🔴 一次性的代价：日志窗口滚过去就看不到了。可它的出现点固定在**进程启动后的第一行之后**，
    //    而用户拉日志的时机正是"刚出问题/刚启动" ⇒ 位置合理。
    static BOOL sRefReadmeDone = NO;
    if (!sRefReadmeDone) {
        sRefReadmeDone = YES;
        NBSharedLog(@"=== [刷新] 读法：①叫醒>0 而「自动请求扫描」=0 且后面三个也全 0 ⇒ 链路死在某个提前返回处；②后三个数**不构成等式** —— 完整重查还会被库指纹变化单独触发（根本不经过扫描），且上一次扫描的完成回调排在 0.45 秒后、可能落进**这个**区间 ⇒ 计数与请求**跨窗口**，别指望它们相加相等；③节流挡占多数 ⇒ 2 秒闸门在正常工作（真机密集时 12 次/79 秒）");
    }

    for (NSInteger i = 0; i < (NSInteger)NBRefKindCount; i++) sNBRefCnt[i] = 0;
}

// 🔴🔴 v0.0.70：顶部控件的**统一规格**。
//    以前每个控件各写各的数字：分段 30、按钮 30、圆角 7、上下间距 6、左右边距 12。
//    改一个尺寸就得记住另外四处，漏一处就是"某一排比别的排高 2pt"——
//    这种 2pt 的错位肉眼说不出来，但整屏就是不整齐。
//    ⇒ 现在高度 / 圆角 / 间距 / 边距各自只有**一处**定义，`viewDidLayoutSubviews` 全用它。
static const CGFloat kNBTopMargin = 12;   // 左右边距
static const CGFloat kNBTopH      = 32;   // 分段 / 按钮 / 标星 的统一高度
// v0.0.131：`kNBTopGap`（行与行之间的竖向间距）删掉了 —— 那三行常驻控件已经不在，
// 现在的竖直节奏由 `viewDidLayoutSubviews` 里逐段 `y +=` 显式表达。
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

// ================= v0.0.176：列表动效（A 入场错落 / B 筛选横滑）=================
//
// 🔴🔴 为什么用「时间窗」而不是布尔开关来限制动画范围 —— 这是本节唯一需要解释的设计：
//    `reloadData` **不同步**建 cell。它只把列表标记成"要重载"，真正的 `cellForRow` /
//    `willDisplayCell` 发生在**之后某一次布局**里。于是：
//      · 用 BOOL 开关 ⇒ 要么在 reloadData 后立刻清掉（cell 还没建，动画永远不播），
//        要么不清（以后每次滚动进来的 cell 都播一遍，列表看起来一直在抖）。
//      · `dispatch_async` 清标志也不行：主队列块的执行时机和 CA 提交/布局的先后
//        没有保证（有时块先跑，动画就又没了）。
//    ⇒ 给一个 **0.30s 的窗口**：窗口内进入屏幕的 cell 播动画，之后的不播。
//      这段窗口刚好覆盖 `reloadData` 后那一次布局，而人手滚一屏远不止 0.30s，
//      所以不会出现"滚动时一路抖"。这是**有意的、有界的**取舍，不是凑数。
@property (nonatomic) CFAbsoluteTime nbEntranceUntil;   // 入场错落的截止时刻
@property (nonatomic) CFAbsoluteTime nbSlideUntil;      // 筛选横滑的截止时刻
@property (nonatomic) CGFloat nbSlideDX;                // 横滑方向（±26pt，0 = 不滑）
// 上一次的段号 —— 用来判断用户是"往左换档"还是"往右换档"，决定内容从哪一侧进来。
// 🔴 不能用 `timeSeg.selectedSegmentIndex` 自己跟自己比：`onTime:` 被调用时段号**已经改完了**。
@property (nonatomic) NSInteger nbPrevTimeIdx;
@property (nonatomic) NSInteger nbPrevUnreadIdx;
// 入场错落是否已经播过（本次进程内只播一次，见 viewWillAppear:）。
@property (nonatomic) BOOL nbEntranceDone;

// ================= v0.0.178：下拉刷新 =================
// 🔴 三个量，每一个都有用，别合并：
//   · `nbRefresh`     —— 控件本身。收尾必须用**同一个实例**调 `endRefreshing`，
//                        临时 `self.table.refreshControl` 去取在重建后可能已经是别的对象。
//   · `nbPullBusy`    —— 重入闸门。连拉两下时第二次直接忽略：否则会有两个"等待轮次"
//                        同时在跑，先回来的那个把转圈收掉，后回来的那个再收一次 ⇒
//                        "转圈莫名提前消失"，而且日志里看着像刷新做了两遍。
//   · `nbPullBeginAt` —— 起始时刻。只为一件事：**最短可见时长**（见 `nbEndPullRefresh`）。
@property (nonatomic, strong) UIRefreshControl *nbRefresh;
@property (nonatomic) BOOL nbPullBusy;
@property (nonatomic) CFAbsoluteTime nbPullBeginAt;

@property (nonatomic, strong) NSArray<NSDictionary *> *items;
// 🔴 v0.0.163：按天分组的**唯一**数据源 —— 每项 `@{@"title": 日期标题, @"items": 这一天的行}`。
//    标题与行**一对一捆在同一个字典里**，不另存一份平行的 titles 数组：
//    两个数组一旦长度不同（改一处漏一处），屏幕就会"标题说 11月5日、内容是 11月4日"，
//    而且这种错**不会报错**，只能靠肉眼发现。
@property (nonatomic, strong) NSArray<NSDictionary *> *sectionModels;
// v0.0.164：列表顶部的双列总览网格（挂在 `table.tableHeaderView` 上）。
// 🔴 为什么挂 tableHeaderView 而不是做成第 0 段的一行/一张卡：
//    ① 它是"总览"，滚下去就该消失，不能永久占着屏幕（挂在 topCard 里会挤掉列表一屏的 1/4）；
//    ② 做成第 0 段会**改所有行号**，而 `sectionModels` / `nbIndexPathForRowId:` /
//       左滑删除 / 批量已读全都按行号定位 —— 加一段假 section 等于给每一个按行号取值的地方
//       埋一颗定时炸弹（v0.0.33 删除错位就是这么来的）。
//    挂 header 则**完全不动行号**，列表的数据源一个字都不用改。
@property (nonatomic, strong) NBOverviewGridView *overviewGrid;
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

// ================= v0.0.98：通知中心残留标记 =================
// 🔴🔴 这个功能回答的是用户的原话：「还在通知中心显示的信息卡片，我们能打上标签吗」。
//    侦察结论：**数据侧本来就够用** —— tweak 的 `[寿]` 台账早就算出了三态并落盘，
//    缺的只是 App 从来没读过（全仓 0 处引用）。所以这一版**不碰系统通知中心的视图层**
//    （那是最贵、最容易连带的一条路），只在盒子自己的列表上做标记。
// 🔴 一次刷新只读**一份**快照（`aliveSnap`）：`aliveStateOfSysId:inSnapshot:` 要求调用方
//    把快照传进去，就是为了不让"一行读一次文件"变成"扫描时刻和状态不是同一次"。
@property (nonatomic, strong) NSDictionary *aliveSnap;
// 上次扫描时刻（0 = 没有可用快照）。提示条要把它报出来 ——
// 🔴 标记说的是**过去某个时刻**的事，不报时刻就是让用户把它当现状。
@property (nonatomic, assign) NSTimeInterval aliveScanTs;
// 扫描时的 NC 总条数（0 = 没记到）。只用于诊断，不参与任何显示判断。
@property (nonatomic, assign) NSInteger aliveNC;
// ---------- v0.0.102/103：界面口径（和 aliveNC 是两个不同的账本）----------
// 🔴🔴🔴 v0.0.102 装出来后真机提示条写的是「账本 637 · **界面 672**」——
//    界面数**不小于**账本数，一个量级。说明 v0.0.102 那个判据（"CS 返回非 nil 就算认"）
//    对几乎任何 uuid 都成立，"返回了"区分不出真假 ⇒ **那一档已废**。
// ⚠️ 当时的推断错在哪：把日志里「尺子(NC 账本侧读回): 是 16 / 否 74」当成了
//    "界面里一共 16 条"。那是**删除后逐条读回**的比例（问 90 次：16 次还在），
//    是局部口径。⇒ 教训：**局部口径的数不许说全库的话**。
// 🔴 v0.0.103 换成严格口径（`cse`）：回来的对象 uuid 必须**等于**问的 uuid 才算。
//    读不到 uuid 的条目单独计进 `csemn`，`csemn=0` 才算"量不到"。
//    ⛔ 本版**仍不**改橙条判据（橙条还按账本 `aliveSnap` 算）—— 先把尺子校出来，再动行为。
@property (nonatomic, assign) NSInteger aliveCS;
// 1 = 界面严格口径可量（`csemn > 0`）；0 = 量不了（tweak 还没捕获 CS dispatcher、或读不到 uuid）。
// 🔴 量不了时**不许**显示成 0 条 —— 那是"读不到"冒充"没有"。
@property (nonatomic, assign) BOOL aliveCSMeasurable;
// 当前列表里「此刻仍在通知中心」的条数。口径 = **其它筛选都算完之后、只差 aliveOnly 那一步**，
// 和 `foldedCount` 同一个位置（"提示条和眼前这个视图同口径"）。
// ⚠️ 只是**列表**口径，不是全库 —— 全库那个数是 `aliveAllCount`（v0.0.100）。
@property (nonatomic, assign) NSInteger aliveStillCount;
// YES = 只看残留（第七个筛选维度，纯内存派生、不落库）。
@property (nonatomic, assign) BOOL aliveOnly;
// YES = 快照存在但已过期（超过 `NB_NC_SNAPSHOT_FRESH_SEC`）⇒ 一条橙条都不打，只报"扫描于多久前"。
// 🔴 为什么不"过期也照打"：这份快照只在**删掉一条记录之后**重写，用户三天前删的那批，
//    三天后才打开盒子 —— 那时他早已手动清空通知中心了。打上去就是拿旧结论冒充现状。
@property (nonatomic, assign) BOOL aliveStale;
// ---------- v0.0.100：全库口径的残留条数 ----------
// 🔴🔴 `aliveStillCount` 是**当前列表**口径（受时间窗 / App / 未读 / LIMIT 2000 影响）。
//    拿它去说「盒子里的消息都不在通知中心了」，就是用局部数做**全库**断言 ——
//    记录明明还在、只是被筛选挡在列表外，那句话就是假的。
//    规矩：**全库 0 才准说"都不在"**；全库 >0 而列表 0 必须说"被当前筛选挡住了"。
// 🔴 `-1` = **没算**（列表里已经有残留，不需要这个数）。⛔ 不许拿 0 表示"没算"——
//    0 和"全库真的没有"是两件事，混起来就是又一次"读不到 ≠ 不存在"。
@property (nonatomic, assign) NSInteger aliveAllCount;
@property (nonatomic, strong) UIButton *aliveHint;
// v0.0.99：本次扫描请求的序号 + 是否还在等结果。
// 🔴 用 seq 而不是一个 BOOL：BOOL 挡不住"这次的结果到了、其实是上一次请求的"。
//    和 `searchGen`（防抖代次）同一条理由。
@property (nonatomic, copy)   NSString *ncScanSeq;
@property (nonatomic, assign) BOOL ncScanPending;
// v0.0.121：上次读到的快照**内容**，以及自动触发扫描的节流时刻。
// 🔴 为什么必须比内容：v0.0.120 及以前 `ncWaitAndReload:` 的判据是
//    `got > aliveScanTs + 0.5`，而 `got` 是**这次扫描新写的时间戳** ⇒ 这个条件恒真
//    ⇒ **每扫一次就整表 `loadData` 一次**（6~8 条 SQL + 2000 行重建），哪怕通知中心一条都没变。
//    现在改成剔掉 `scan`（扫描时刻）/ `seq`（请求序号）这两个必然变的字段，比剩下的内容。
// 🔴 存的是**已经剔掉那两个字段的那份**，下次直接 `isEqual:`（`keys` 是 NSSet，深比较很便宜）。
@property (nonatomic, strong) NSDictionary *lastSnapContent;
@property (nonatomic, assign) NSTimeInterval lastNCSnapReqTs;
// v0.0.121：`applyAliveFilter:` 的**输入**（关键词规则 + 同内容归并之后、残留筛选之前）。
// 🔴 为什么要单独留一份：残留筛选的结果只取决于「快照 + 这一份 items」。
//    库没变、只有通知中心变了的时候，前面那一大串（图标栏重建 / 最高 2000 行主查询 /
//    关键词规则 / 同内容归并 / 三条未读计数）结果**一定相同** ⇒ 不必重跑，
//    直接从这一份再筛一遍就行。这是本版省掉的主要开销。
@property (nonatomic, strong) NSArray<NSDictionary *> *itemsBeforeAlive;
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

// ================= v0.0.131：顶部改成「一行到底」（方案 B） =================
// 🔴🔴 为什么改：v0.0.71 起顶部是一张装了三行**常驻**控件的白卡片
//    （时间分段 / 搜索框 / ★+未读+全标已读），下面还有最多三条提示 ⇒
//    常态就吃掉 230pt 左右，小屏上列表只剩半屏。
// 🔴🔴 **本次一个字都不改逻辑**，只换呈现：
//    `timeSeg` / `unreadSeg` / `starBtn` / `markAllBtn` 四个对象**全部保留**，
//    只是不再 `addSubview` —— 它们从"看得见的控件"退化成"状态容器"。
//    这样 `sinceFromSeg`（读 `timeSeg.selectedSegmentIndex`）、`onUnread:`、
//    `onStar:`、`onMarkAllRead:`，以及所有读 `unreadOnly` / `starOnly` 的地方
//    **一行都不用改**。这是这次改造最重要的取舍：把风险全部关在视图层。
// 🔴 筛选入口合并成右上角一个 `filterBtn`，菜单用 `UIMenu` 的 `state` 表达选中态。
//    ⛔ 菜单项**不许**直接写 `self.unreadOnly = ...`：一律调原来那几个 setter
//    （`onTime:` / `onUnread:` / `onStar:` / `onMarkAllRead:`），
//    否则同一条状态就有了两条赋值路径，迟早走岔（本项目"一个量只算一次"同款纪律）。
@property (nonatomic, strong) UILabel *bigTitleLabel;     // 自绘大标题「消息盒子」
@property (nonatomic, strong) UILabel *bigSubLabel;       // 副标题「128 条 · 7 条未读」
@property (nonatomic, strong) UIButton *filterBtn;        // 筛选入口（右上，带激活数角标）
@property (nonatomic, strong) UILabel *filterBadge;       // 角标数字（0 ⇒ hidden）
@property (nonatomic, strong) UIButton *summaryBtn;       // 「未读 · 标星   清除」（有筛选时显示）
// v0.0.132（方案 B）：时间范围**提到明面**做成常驻胶囊行，不再只藏在筛选菜单里。
//   `timePillRow` 是容器，`timePills` 是 N 个胶囊（与 `timeNames` 一一对应）。
//   🔴 它只反映 `timeSeg.selectedSegmentIndex` 并调用 `onTime:`；状态仍由 `timeSeg` 持有，
//      不引第二份"当前时间档"状态（和 v0.0.131 把 timeSeg 当状态容器同一条理由）。
@property (nonatomic, strong) UIView *timePillRow;
@property (nonatomic, strong) NSArray<UIButton *> *timePills;
// v0.0.131：全库未读数（-1 = 读不到）。副标题要用它，但**不许再查一次库** ——
// 它由 `updateHiddenUnread` 顺手带出来（那里本来就要算"全库未读"这个数）。
// 🔴 为什么存**原始值**、不在写入时就 `MAX(0, …)`：`-1` 是"读不到"，
//    和"真的 0 条未读"必须分开（本项目"读不到 ≠ 不存在"那条最贵的教训），
//    在这里混起来的表现就是"库打不开时副标题写全部已读"。
@property (nonatomic, assign) NSInteger allUnreadCount;
- (void)updateTimePills;
- (void)onTimePillTapped:(UIButton *)sender;
- (UIMenu *)buildFilterMenu;
- (NSArray<UIMenuElement *> *)filterMenuElements;
- (NSArray<NSString *> *)activeFilterNames;
- (void)updateHeaderSub;
- (void)updateSummaryRow;
- (NSInteger)activeFilterCount;
- (void)onClearFilters;

// v0.0.178：下拉刷新。
// 🔴 `nbOnPullRefresh:` 必须在这里声明：它要用于 `@selector(...)`。
//    不声明 ⇒ ARC 下返回类型被推断成 `id` ⇒ CI 的 `-Werror` 直接挂
//    （v0.0.33 的 `doDelete`/`str:`、v0.0.35 的 `onClear:` 都是这么挂过一次的）。
// 🔴 `nbEndPullRefresh` 也要声明：它被 `ncWaitAndReload:` 的 block 里以
//    `[self2 nbEndPullRefresh]` 调用，而那块代码在本文件里位置**更靠后**
//    —— 同一个类里靠后的代码看得见靠前的声明，看不见靠后的定义。
- (void)nbOnPullRefresh:(UIRefreshControl *)rc;
- (void)nbEndPullRefresh;

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
// ================= v0.0.124：已读态的唯一执行入口 =================
// 点击卡片（标已读）和右滑蓝块（翻转）共用这一份实现。
- (void)nbSetRead:(BOOL)read forRowIds:(NSArray<NSNumber *> *)ids;
// 按 rowId 现查它在当前 items 里的行号（找不到返回 nil）。
- (NSIndexPath *)nbIndexPathForRowId:(NSInteger)rowId;
// v0.0.163：按天分组 —— 从 `self.items` 重建 `sectionModels`；以及按 indexPath 取行。
// 🔴 分组**只在这一处**产生，任何读行的地方都必须走 `nbItemAtIndexPath:`，
//    不许再写 `self.items[...row]` —— 那会把"第几行"当成"全表第几条"，分组一开就错位。
- (void)nbRebuildDaySections;
- (nullable NSDictionary *)nbItemAtIndexPath:(nullable NSIndexPath *)ip;
// v0.0.164：总览网格 —— 从 `self.items` 聚合出「每个 App 几条 + 最新那条是什么」，
// 再交给 `OverviewGridView` 画。**只在「全部 App」这一层显示**（筛到单个 App 时撤掉）。
- (void)nbRebuildOverview;
// 点总览里的某张卡片 ⇒ 和点顶部图标**走同一条路**（设 `filterBundle` + 重查）。
- (void)nbOverviewSelectBundle:(nullable NSString *)bid;
// v0.0.37：全部 / 只看未读（自己的分段控件，替掉没渲染出来的系统 scope bar）
- (void)onUnread:(UISegmentedControl *)seg;
// v0.0.176：动效布防。两个入口分开写而不是合成一个带 flag 的 —— 它们的**触发条件不同**：
//   入场错落只跟"整屏重建"有关，横滑只跟"用户换了哪一档"有关，
//   合成一个就得在里面判断"这次是哪一种"，那种判断最容易在新增入口时漏掉一个分支。
- (void)nbArmEntrance;
- (void)nbArmSlideFromIndex:(NSInteger)from toIndex:(NSInteger)to;
// v0.0.49：★ 只看标星开关；以及"有没有任何规则带 ★ 动作"（★ 视图为空时区分
//    "这个范围没有标星的" 和 "根本没有任何规则会标星"，后者必须点醒用户去建规则）。
- (void)onStar:(id)sender;
- (BOOL)anyStarRule;
// v0.0.38：批量把当前筛选范围内的未读标成已读
- (void)onMarkAllRead:(id)sender;
- (void)doMarkAllRead;
// v0.0.38：库里变了才重查（保住滚动位置）；以及那个"保住滚动位置的重查"本身
- (void)refreshIfChanged;
// v0.0.121：把「库/规则变没变」这一条判据单独抽出来 —— `refreshIfChanged`
// 和 `ncWaitAndReload:` 都要问同一个问题，而它们的动作完全不同
// （一个自己重查、一个决定走完整路还是轻路）⇒ 判据必须只有一份。
- (BOOL)dbFingerprintChanged;
- (void)reloadKeepingOffset;
// v0.0.121：库没变、只有通知中心现状变了时走的**轻路**（不跑主查询/规则/归并/未读计数）。
- (void)refreshItemsKeepingOffset;
// v0.0.121：完整路与轻路的**共用尾部**（items → 残留筛选 → 未读书签 → 列表 → 空视图 → 橙条）。
// 🔴 抽出来是为了让"两条路做的事一定一样"落成**代码结构**，而不是靠注释提醒。
- (void)applyItemsAndRefreshUI;
// 重查之后按原 offset 归位（两条路共用，原来这段只写在 `reloadKeepingOffset` 里）。
- (void)clampContentOffset:(CGPoint)off;
- (void)onForeground:(NSNotification *)note;
// v0.0.121：inactive → active（下拉通知中心/控制中心收起走的就是这条）
- (void)onBecameActive:(NSNotification *)note;
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
// v0.0.95：同内容同日的行归并成一条（组内条数 >=2 才显示 ×N）。
// 🔴 必须排在 `applyKeywordRulesToRows:` **之后**、`rebuildBundleUnread` **之前**：
//    前者决定哪些行进列表（它自己也在算 foldedCount），后者要按**最终可见的 items**数未读。
//    顺序反了 ⇒ 未读书签按折叠前的行数算，收起一组之后数字还在喊 —— 本项目栽过同构的坑。
- (NSArray<NSDictionary *> *)applyGroupCollapse:(NSArray<NSDictionary *> *)rows;
// v0.0.98：通知中心残留标记五件套。
// 🔴 声明顺序 = 调用顺序（`loadAliveSnapshot` → `applyAliveFilter` → `updateAliveHint`），
//    项目开 -Werror，靠"定义在前面"解析选择器太脆（v0.0.48 setStarred 那次就是这么炸的）。
- (void)loadAliveSnapshot;
// v0.0.121：`loadAliveSnapshot` 拆成两半 —— 只负责"取哪份快照"和"用这份快照"。
// 🔴 为什么：`ncWaitAndReload:` 手上已经有一份 `ncSnapshot` 了，再读一次等于
//    把 55 KB / 637 行的快照文件读+解析两遍。两处必须用**同一份**才是同一个时刻的数。
- (void)applyAliveSnapshot:(NSDictionary *)snap;
// v0.0.121：这份快照和上次读到的**内容**是不是一样（剔掉 `scan`/`seq` 后比）。
- (BOOL)snapshotContentChanged:(NSDictionary *)snap;
- (void)requestNCSnapshot;
// v0.0.121：**自动**触发扫描的唯一出口（带 `NB_NC_SCAN_MIN_GAP` 节流）。
- (void)requestNCSnapshotIfDue;
- (void)ncWaitAndReload:(NSInteger)left;
- (NBAliveState)aliveStateForRow:(NSDictionary *)row;
- (NSArray<NSDictionary *> *)applyAliveFilter:(NSArray<NSDictionary *> *)rows;
- (void)onAliveHintTap;
- (void)updateAliveHint;
- (NSString *)aliveHintText;
- (NSString *)aliveAgeText;
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
// v0.0.173：tweak dylib 版本不一致时提醒"还差一次重启"。
// 🔴 只在**读出来的版本和本 App 不同**（或读不到）时弹，一致时什么都不做 ——
//    这个提示的目的是把「装了没重启」和「代码写错了」分开，不是每次打开都报一次平安。
- (void)nbWarnIfTweakOutdated;
- (NSString *)keyLinesFrom:(NSString *)text;
- (NSString *)selLinesFrom:(NSString *)text;
- (NSString *)probeLinesFrom:(NSString *)text;
- (NSString *)soundDiagFileText;

// ================= v0.0.92：左滑删除改成自绘（见 NotifyCell.h 顶部注释） =================
// 🔴 全列表只允许一行处于"左滑打开"状态，这里记住是哪一行。
//    用 weak：cell 进了复用池就该自动失效，持有强引用会把整个 cell 焊死在内存里，
//    而且"已经滚出屏幕的那一行"还会被当成"当前打开的那一行"。
@property (nonatomic, weak) NotifyCell *nbOpenCell;
// 关掉除 `keep` 以外的所有左滑（传 nil = 全关）。
// 判据：传的是**当前正在滑的 cell**，不是 indexPath —— cell 会被复用，indexPath 会变。
- (void)nbCloseOtherSwipesExcept:(NotifyCell *)keep;
// 按 rowId 删一条。🔴 参数是 rowId 而不是 indexPath：
//    删除会改数量 ⇒ 内存下标和行号立刻错位（v0.0.33 栽过），而 rowId 是库里的事实。
- (void)nbDeleteRowId:(NSInteger)rowId;
// v0.0.95：整组删（×N 那一行）。单条删仍走上面那个，两者共用一套提示口径。
- (void)nbDeleteRowIds:(NSArray<NSNumber *> *)rowIds;

// ================= v0.0.118：长按卡片的菜单（打开 App / 复制） =================
// 🔴 菜单内容**只在这里定义**：cell 只负责"长按了 ⇒ 问你"，不知道菜单里有什么。
//    这样加/减动作只有一处要改，cell 复用也不会带着上一行的动作跑。
- (UIMenu *)nbMenuForRow:(NSDictionary *)row;
// v0.0.166：这一条通知的「可读正文」—— 标题 / 正文 / 副标题按顺序拼，空的跳过。
// 🔴 抽出来是因为现在有**两个**消费者：菜单里的「复制内容」，以及链接/验证码提取。
//    各拼一份的话，某天改了顺序就会出现"复制出来的内容和识别用的内容不是同一串"。
- (NSString *)nbBodyTextForRow:(NSDictionary *)row;
// v0.0.166：打开外部链接（正文里抽到的 http/https）。
// 和 `nbOpenAppWithBundle:` 分开：那个是"切到某个 App"，这个是"交给系统打开"。
- (void)nbOpenExternalLink:(NSString *)link;
// v0.0.168：把这个 App 的临时静音写到到期时刻 / 取消它。
// 🔴 写完之后**必须回读一次**（`shouldDropForMute:`），不许拿"我写了"当"它生效了"：
//    写盘失败、条目超上限、值超上限——三条路都返回 YES 给保存函数但在判定侧是"不生效"。
- (void)nbMuteRow:(NSDictionary *)row kind:(NBMuteKind)kind;
- (void)nbUnmuteRow:(NSDictionary *)row;
// v0.0.176：把某个 App 的静音态动画铺到所有可见行（见实现里的注释：为什么不是只动一行）。
- (void)nbAnimateMuteLookForBundle:(nullable NSString *)bid muted:(BOOL)muted;
// 「打开」的落点。🔴 只发请求 + toast，**绝不 present** ——
//    这个动作是在菜单正在收起的瞬间执行的，此时 present 会被系统静默丢掉。
- (void)nbOpenAppWithBundle:(NSString *)bundleId;
// v0.0.133：带深链版本。`deeplink` 为 nil/不可用时**同一个方法内部**退回只打开 App
// （契约见 AppLauncher.h：永不比 openBundle: 更差）。
- (void)nbOpenAppWithBundle:(NSString *)bundleId deeplink:(NSString *)deeplink;
// ================= v0.0.186：长按菜单与无障碍动作共用的两个动作 =================
// 🔴 为什么要把这两件事抽成方法：v0.0.186 之前它们是写在菜单 handler 里的**内联 block**，
//    只有长按一个入口。现在无障碍的 `accessibilityCustomActions` 也要用同一件事
//    ⇒ 抽成方法，两个入口共用一份实现。
//    ⛔ 不许在 cell 那边再写一份"复制到剪贴板"：正文口径（`nbBodyTextForRow:`）
//       和"没有内容时提示什么"必须只有一处，否则拖一段时间两边说法就会不一样。
- (void)nbCopyRowText:(NSDictionary *)row;
- (void)nbOpenRowInApp:(NSDictionary *)row;
// v0.0.118：浮层提示（1.4 秒淡出）。不走 `alertTitle:`：
//    那个是 alert（要 present），而这里最常发生的时刻正是"菜单刚收起"，
//    两条 present 撞在一起就是"点了没反应"。浮层只往视图上贴一个 label，不涉及 present。
- (void)nbToast:(NSString *)text;
// ================= v0.0.187：写入核心（静音 / 不记录）=================
// 🔴 为什么要把"写盘 + 回读"从 `nbMuteRow:kind:` 里抽出来：
//    v0.0.187 的统计页行内行动也要静音某个 App，而它的入口在**另一个页签**。
//    不抽的话只有两条路 —— ①在统计页再抄一份写入逻辑（两份必走岔，
//    而且回读那三条纪律必然会在抄的时候丢一条）②只能从长按菜单里点（等于没做）。
// 🔴 这两个方法**只负责写与回读，不负责提示/触觉**：
//    提示贴哪个 view 是调用方才知道的事（见 NBToast.h 文件头）。
//    返回值 = 回读结果（YES 才算真的生效），`outMessage` = 已经拼好的整句人话。
- (BOOL)nbWriteMuteForBundle:(NSString *)bid kind:(NBMuteKind)kind message:(NSString **)outMessage;
- (BOOL)nbWriteSkipRecordForBundle:(NSString *)bid message:(NSString **)outMessage;
@end

// 🔴 v0.0.161：诊断长文本页用的独立 VC（**文件级**，不能嵌进 @implementation ViewController 里，
//    Objective-C 不允许在 @implementation 内再写 @interface/@implementation）。
//    关掉系统长按选择（避免越狱环境闪退），复制走 nav「复制全文」按钮（直接写 UIPasteboard）。
@interface NBTextViewController : UIViewController
@property (nonatomic, copy) NSString *fullText;
@property (nonatomic, strong) UITextView *textView;
- (void)nbCopyFull:(UIButton *)sender;
@end

@implementation NBTextViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = NBPageBG();   // v0.0.71 与全站统一

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
    tv.editable = NO;
    tv.selectable = NO;                 // v0.0.161：关掉系统长按选择，避免越狱环境闪退
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.text = self.fullText ?: @"(空)";
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:tv];
    self.textView = tv;
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyBtn setTitle:@"复制全文" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [copyBtn addTarget:self action:@selector(nbCopyFull:) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:copyBtn];
}

// 直接写剪贴板，不触发 UIMenuController ⇒ 不闪退
- (void)nbCopyFull:(UIButton *)sender {
    UIPasteboard.generalPasteboard.string = self.fullText ?: @"";
    NSString *old = [sender titleForState:UIControlStateNormal];
    [sender setTitle:@"已复制 ✓" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [sender setTitle:old forState:UIControlStateNormal];
    });
}
@end

@implementation ViewController

- (void)dealloc {
    // 🔴 显式移除。iOS 9 起 target-action 形式的观察者已经不会被野指针调用了，
    //    但"读代码的人不用去查这条规则"本身有价值 —— 而且 `removeObserver:` 是幂等的。
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // v0.0.131：系统导航栏标题**置空** —— 标题改成内容区自绘的大标题
    // （`bigTitleLabel`），两处同时存在会出现"消息盒子"写两遍。
    // 🔴 置空的只是标题，左上「设置」和右上「诊断/导出/清空」三个按钮**一个都没动**，
    //    所以这一版没有任何功能入口消失（"重写前先清点它原来顺手做的事"）。
    self.navigationItem.title = @"";
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
    // v0.0.121：下拉通知中心 / 控制中心再收起，**不走** `WillEnterForeground` ——
    //    那条路的状态是 active → inactive → active，只有 `DidBecomeActive` 会发。
    //    不接这个通知的话，"在通知中心里划掉几条 → 收起 → 回到盒子"标记不刷新，
    //    用户只能杀掉 App 重进才看得到变化。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onBecameActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

// v0.0.38：从详情页/设置页返回。`viewWillAppear:` 在**首次显示**时也会调用，
// 那时 `viewDidLoad` 里的 `loadData` 刚跑过、库指纹没变 ⇒ `refreshIfChanged` 直接返回，
// 不会白 reload 一次（否则每次进入 App 都闪一下）。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // v0.0.176：入场错落**只在本次启动的第一次出现播一次**。
    // 🔴 为什么不挂在 `loadData` 里：`refreshIfChanged`（前台回前台、库变了）、
    //    删除、标已读、批量操作全都走 `loadData` —— 那样每次回到这一页、
    //    甚至从详情页返回，列表都会重新飞一遍。那不叫动效，那叫抖。
    //    ⇒ 布防点只放在**用户主动换内容**的入口（onIcon / 总览卡片 / ★）和这里一次。
    if (!self.nbEntranceDone) {
        self.nbEntranceDone = YES;
        [self nbArmEntrance];
    }
    [self refreshIfChanged];
    // v0.0.99：每次进列表都请 tweak 扫一次通知中心现状。
    // 🔴 放在 `refreshIfChanged` **之后**：那个只在库变了才重查，而"通知中心变了"
    //    跟库一点关系都没有（用户手动划掉几条，库里的记录一条没少）。
    //    ⇒ 这两个刷新是**正交**的，谁也不能替谁。
    // v0.0.121：改走 `IfDue` —— 从详情页返回也会走这里，而 `DidBecomeActive` 那条路
    //    常常紧跟其后，两条叠在几百毫秒内发两次请求没有任何意义。
    [self requestNCSnapshotIfDue];
    // v0.0.173：进来先看"跑的是不是新版"。
    [self nbWarnIfTweakOutdated];
}

// v0.0.173：dylib 版本不一致 ⇒ 告诉用户"还差一次重启"。
//
// 🔴🔴 为什么这个提示必须存在（它是"不自动重启"的对价）：
//    v0.0.173 起 postinst 不再 kill SpringBoard（用户要求手动操作），
//    于是「装了新版但没重启」变成**必然经过的一个状态**：
//        盒子 App = 新版（有静音菜单、能写静音表）
//        SpringBoard 里跑的 dylib = 旧版（没有 shouldDropForMute 那段）
//    用户看到「静音设好了，通知照样弹」—— 和"代码写错了"一模一样。
//    这一条把那个状态变成**屏幕上的一句话**，而不是让他去自检页里翻。
//
// 🔴 进程内只弹一次：`warned` 是 static，杀进程才会重置。
//    用户点「知道了」但不重启、又切回前台 —— 不该再弹一遍烦他；
//    而他下次冷启动 App 时会再看到（那时候他多半还没重启）。
- (void)nbWarnIfTweakOutdated {
    static BOOL warned = NO;
    if (warned) return;

    NSString *notice = [NBDiagnostics tweakVersionMismatchNotice];
    if (!notice.length) return;      // 一致 ⇒ 不打扰

    // 🔴 已经有弹窗在上面（长按菜单/设置页）就先不动：在别人 present 的瞬间再 present
    //    会被系统静默丢掉，而"丢了"和"不需要提示"在证据上同形。留到下次启动再说。
    if (self.presentedViewController) return;

    warned = YES;
    __weak typeof(self) weakSelf = self;
    // 延迟一点：`viewWillAppear:` 时视图还没上屏，直接 present 会失败（日志里报
    // "whose view is not in the window hierarchy"），而这个失败不会体现在界面上。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (weakSelf.presentedViewController) return;   // 这 0.45 秒里又有人弹了
        UIAlertController *a = [UIAlertController
                                alertControllerWithTitle:@"还差一次重启"
                                                 message:notice
                                          preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
        [weakSelf presentViewController:a animated:YES completion:nil];
    });
}

- (void)onForeground:(NSNotification *)note {
    [self refreshIfChanged];
    // v0.0.99：回前台同样要重扫（用户在通知中心里划掉了几条，这里必须跟上）。
    [self requestNCSnapshotIfDue];
}

// v0.0.121：App 从 inactive 回到 active。
// 🔴 什么时候会来：下拉通知中心/控制中心收起、Siri 关掉、来电横幅消失、
//    从 App 切换器返回、锁屏解锁后回到这个 App……**最需要它的就是第一个**。
- (void)onBecameActive:(NSNotification *)note {
    // 🔴 先 `refreshIfChanged`：tweak 写库是**另一个进程**干的，App 收不到任何通知，
    //    库里真变了只能靠这种时机补上；而"通知中心变没变"是另一件事，两者正交。
    [self refreshIfChanged];
    [self requestNCSnapshotIfDue];
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
        // v0.0.178：标已读是"确定的动作"，给稍实一档（和左滑删除同一个分量）。
        NBHapticFire(NBHapticKindLight);
        [self alertTitle:@"已标记"
                    text:[NSString stringWithFormat:@"把 %ld 条标成了已读。", (long)n]];
    } else if (n == 0) {
        // `UPDATE ... WHERE read=0` 命中 0 行照样返回 SQLITE_DONE ⇒ 不能当成功。
        // v0.0.178：既不是成功也不是失败 ⇒ 最轻档。**不能**静音不震：
        // 那样"点了没反应"和"点了但确实没有未读"手感一样，用户会连点。
        NBHapticFire(NBHapticKindSoft);
        [self alertTitle:@"没有变化"
                    text:@"这个范围里已经没有未读了（可能刚被标过）。列表已刷新。"];
    } else {
        NBHapticFire(NBHapticKindWarning);
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
// v0.0.144：补两个词 —— `payload`（长按直达的现场/统计/样本行）与 `降级`
// （v0.0.141 加的「INSERT 降级 7 列」「SELECT 降级」两条保命日志）。
// 🔴 又是同一个病：那几条留痕 v0.0.141 就打出来了，但**过不了这张筛子**
//    ⇒ 界面上「只看结论行」永远是干净的，等于没打。这病本项目已经犯过三次。
// v0.0.149：补 `直达` / `直开` —— AppLauncher 新打的 `[直达] 候选 N 条 ｜ 拆 JSON M 次 ｜ 选中(…)`
// 正是「长按到底认了哪条链接」的唯一证据，而表里没有任何词能匹配它（`直开` 那条从 v0.0.118
// 起也一直被筛掉）。若不加，验证长按时会看到"一条都没有"，误判成"压根没走直达"。**第四次。**
// 🔴🔴 v0.0.157：补 `路径` —— **第六次**（第五次是 `[打开]`，见 v0.0.154）。
//   `app/AppDelegate.m:27` 打的 `[路径] 盒子App 数据目录=… 自愈=… DB存在=…` 是
//   「App 到底把数据放哪、DB 在不在」的唯一一行历史，而表里没有任何词能匹配 `[路径]`
//   ⇒ 这一行从写下来那天起就一直被筛掉，等于没打。
//   ⚠️ **这次不是靠人眼发现的**：把「发出侧所有 NBSharedLog 标签 ↔ 这张表」做成机械对拍
//   （`checks/nb_lint.py` 的 E1）之后它当场变红。⇒ 人眼扫表已经失败六次，
//   这类病只能靠机械对拍守，所以那张判据现在**入库并挂在 CI 上**，每次编译都会跑。
//
// 🔴🔴 v0.0.168：补 `[源]` `[自动清]` `NC-ID` `补ID` —— **第七次**，而且是四次一块。
//   这次的原因不是我又忘了加，而是**E1 自己只覆盖了一半**：
//   `Tweak.x:225` 有 `#define NBLog NBSharedLog`，而 E1 的锚点写的是字面
//   `NBSharedLog(@"\[` ⇒ Tweak.x 里那 11 行 `NBLog(@"[…` 从写下那天起
//   一次也没被这条判据看过。判据一直绿，绿的理由是"没看见"。
//   ⇒ 把锚点改成动态解析宏别名、并把方括号留住（App 是整行 `containsString:` 比，
//     判据剥掉括号就与 App 不同口径）之后，这 4 条当场变红，一个不多一个不少。
//   🔴 这四条里最贵的是 `[源]`：`nc=… 有ts=…` 是「盒子到底从通知中心读到了几条」
//     的唯一一线证据，一直静默消失在筛子里 —— 查「记录变少」时看不见它，
//     就会去怀疑别的地方（已经怀疑过两次）。
//     教训升级：**判据「绿」要先问它到底看见了几条**。看不见的绿比红更贵。
//
// 🔴 v0.0.168 同轮还补了 `[残]`（`NotifyStore.m:2977` 起的 5 行去重/残留诊断）。
//   它只在手动触发那一趟打，不会淹屏幕；而它承载的「段= / 精确= / 忽略大小写=」
//   正是判断「这条记录到底是不是同一条」的唯一读数。
static NSString * const kNBKeyLineTable =
    @"NBKEYLINES|===|-->|hit#|P#|drop |DROP#|REPL#|PROBE|DND#|SOUND#|SD#|APP-ALIVE|G3 首次|失败|!!!|探针|payload|降级|直达|直开|打开|路径|[源]|[自动清]|NC-ID|补ID|[残]|MUTE|COOL#|COOL-BAD#";

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

// 长文本用可滚动 VC 展示：UIAlertController 的 message 太长会被截断，且不能复制。
// 🔴 v0.0.161：改用文件级 `NBTextViewController`（见文件顶部），关掉系统长按选择避免越狱环境闪退，
//    复制走 nav「复制全文」按钮（直接写 UIPasteboard，不碰系统选择 UI）。
- (void)showText:(NSString *)text title:(NSString *)title {
    NBTextViewController *vc = [[NBTextViewController alloc] init];
    vc.title = title;
    vc.fullText = text ?: @"(空)";
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
    // v0.0.131：这张卡片换了职责 —— 现在是**头像栏的底**（v0.0.71 那三行常驻控件已搬走）。
    //    🔴 图标栏作为它的**子视图**，所以 `reloadIconBar` 里的坐标全都不用改
    //    （`holder` 的 x/y 本来就是相对 iconBar 的），只改布局里那一处 frame。
    self.topCard = [[UIView alloc] init];
    self.topCard.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.topCard.layer.cornerRadius = NBCardRadius;   // 与列表卡片同一圆角
    self.topCard.layer.cornerCurve = kCACornerCurveContinuous;
    self.topCard.clipsToBounds = YES;
    [self.view addSubview:self.topCard];

    // ---------- v0.0.131：自绘大标题行（原系统导航栏标题已置空） ----------
    // 🔴 为什么自己画、不用 `prefersLargeTitles`：系统大标题在「滚动时收起」那套行为
    //    我们控制不了，而这一行的存在与否直接决定头像栏的起始 y（本项目最忌讳
    //    "位置靠系统猜"）。自绘 ⇒ y 全部由 `viewDidLayoutSubviews` 说了算。
    self.bigTitleLabel = [[UILabel alloc] init];
    self.bigTitleLabel.text = @"消息盒子";
    self.bigTitleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    self.bigTitleLabel.textColor = [UIColor labelColor];
    [self.view addSubview:self.bigTitleLabel];

    self.bigSubLabel = [[UILabel alloc] init];
    self.bigSubLabel.text = @"— 条";       // 真实值由 `updateHeaderSub` 填（避免闪一个假 0）
    self.bigSubLabel.font = [UIFont systemFontOfSize:12];
    self.bigSubLabel.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:self.bigSubLabel];

    // v0.0.132：放大镜开关已移除 —— 搜索框改为**常驻**（见下方 searchBar），不再有展开/收起状态机。

    // 筛选入口：时间 / 未读 / ★ / 全标已读 / 只看残留，全进这一个菜单。
    // 🔴 用 `showsMenuAsPrimaryAction` 而不是自己 present sheet：UIMenu 的
    //    `state = UIMenuElementStateOn` 天然能表达"哪几项开着"，而且点击即关、
    //    点外面即取消 —— 自己写 sheet 要重造这三件事，还要多一条"打开时状态不同步"的坑。
    self.filterBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.filterBtn setImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease"]
                    forState:UIControlStateNormal];
    self.filterBtn.tintColor = [UIColor secondaryLabelColor];
    self.filterBtn.backgroundColor = [UIColor secondarySystemFillColor];
    self.filterBtn.layer.cornerRadius = 15;
    self.filterBtn.showsMenuAsPrimaryAction = YES;
    self.filterBtn.menu = [self buildFilterMenu];
    [self.view addSubview:self.filterBtn];

    // 激活筛选数的角标。🔴 它是**唯一**告诉用户"现在列表被筛过"的常驻信号
    //    （摘要行只在有筛选时出现，而角标跟着菜单按钮永远在）。
    self.filterBadge = [[UILabel alloc] init];
    self.filterBadge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    self.filterBadge.textColor = [UIColor whiteColor];
    self.filterBadge.backgroundColor = [UIColor systemBlueColor];
    self.filterBadge.textAlignment = NSTextAlignmentCenter;
    self.filterBadge.layer.cornerRadius = 8;
    self.filterBadge.clipsToBounds = YES;
    self.filterBadge.hidden = YES;
    [self.view addSubview:self.filterBadge];

    // 筛选摘要行：只在有筛选时占位，点一下全清。
    // 🔴 为什么不把它做成纯 UILabel：它说的是"你现在看到的是被筛过的"，那就必须
    //    给一条一步回到全部的路（和 v0.0.41 把 hiddenHint 从 UILabel 改成 UIButton 同一条理由）。
    self.summaryBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.summaryBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    self.summaryBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.summaryBtn.titleLabel.minimumScaleFactor = 0.85;
    self.summaryBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.summaryBtn.backgroundColor = [UIColor secondarySystemFillColor];
    self.summaryBtn.layer.cornerRadius = 7;
    self.summaryBtn.contentEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 8);
    [self.summaryBtn setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    self.summaryBtn.hidden = YES;
    [self.summaryBtn addTarget:self action:@selector(onClearFilters)
              forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.summaryBtn];


    // 时间分段
    // v0.0.37：第 0 段原名「今天」，但它实际返回的是 `now - 86400`（最近 24 小时），
    //    不是今天 00:00 —— 名不符实。今天 19:30 时，「今天」会把昨天 19:30 之后的
    //    记录也算进来。改成如实写「近24小时」，行为不变、标签不再说谎。
    // v0.0.38：段名改从 `timeNames` 取，不再在这里写字面量。
    self.timeSeg = [[UISegmentedControl alloc] initWithItems:[self timeNames]];
    self.timeSeg.selectedSegmentIndex = 0;
    [self.timeSeg addTarget:self action:@selector(onTime:) forControlEvents:UIControlEventValueChanged];
    // 🔴🔴 v0.0.131：**故意不 addSubview**。它现在只是「时间窗」这个状态的持有者 ——
    //    `sinceFromSeg` 读的就是 `self.timeSeg.selectedSegmentIndex`。
    //    把它留在视图里（哪怕 hidden）会多一处"看得见却不该被点"的东西；
    //    而删掉它就要改 `sinceFromSeg` / 判据 / 变异一大堆 ⇒ 保留对象、摘掉视图最省风险。
    //    ⚠️ 代价：程序改 `selectedSegmentIndex` **不会**触发 ValueChanged ⇒
    //    筛选菜单里必须手动调 `onTime:`（见 `buildFilterMenu`）。

    // 搜索
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜标题/正文/App　-排除　\"短语\"";
    // 🔴 v0.0.70：底色已经是分组灰，搜索框还用默认样式的话会叠出一块**同色灰**，
    //    整条搜索栏看起来像"糊在背景上"、边界不清。Minimal 样式只画里面那个圆角输入框，
    //    和外层的灰底有明确的层次。
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.backgroundImage = [[UIImage alloc] init];   // 去掉那条 1px 分隔线
    // v0.0.132：搜索框**常驻**显示，不再 hidden（去掉放大镜开关后它始终占位）。
    [self.view addSubview:self.searchBar];

    // v0.0.132（方案 B）：时间胶囊行。
    // 🔴 容器 + N 个胶囊用 `timeNames` 动态生成（和分段控件、sinceFromSeg 同一份段名）。
    //    胶囊只当"看得见的时间档"，状态仍由 `timeSeg` 持有（见属性注释）。
    self.timePillRow = [[UIView alloc] init];
    [self.view addSubview:self.timePillRow];
    NSArray<NSString *> *tn = [self timeNames];
    NSMutableArray<UIButton *> *pills = [NSMutableArray arrayWithCapacity:tn.count];
    for (NSUInteger i = 0; i < tn.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.tag = (NSInteger)i;                                 // tag = 时间档序号
        [b setTitle:tn[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13];
        b.layer.cornerRadius = 15;                            // 30pt 胶囊形
        [b addTarget:self action:@selector(onTimePillTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.timePillRow addSubview:b];
        [pills addObject:b];
    }
    self.timePills = pills;

    // v0.0.37：全部 / 只看未读。
    // 🔴 不用 `searchBar.showsScopeBar` 了 —— v0.0.36 实测 iOS 16 上不显示（见属性注释）。
    //    用和上面时间分段同款控件，看得见摸得着。
    self.unreadSeg = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"只看未读"]];
    self.unreadSeg.selectedSegmentIndex = 0;
    [self.unreadSeg addTarget:self action:@selector(onUnread:) forControlEvents:UIControlEventValueChanged];
    // v0.0.131：同 `timeSeg` —— 只当状态容器，不上视图。`onUnread:` 仍然靠它取段号。

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
    // v0.0.131：★ 变成筛选菜单里的一项 ⇒ 按钮本身不上视图。
    // 🔴 `onStar:` 里的 `self.starBtn.selected = self.starOnly` 一行都不用改，
    //    它只是没人看得见了而已（且菜单的 state 由 `starOnly` 现算，不读这个 selected）。

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
    // v0.0.131：不上视图 —— 它变成筛选菜单里那一条「全标已读」。
    // 🔴 `onUnread:` 里那句 `self.markAllBtn.hidden = !self.unreadOnly` 保留不动：
    //    菜单每次弹出都现算 `state`，不读这个 hidden；留着它是为了让那条老代码
    //    依旧"说得通"，将来要恢复常驻按钮时不用再改一遍。

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
    // v0.0.131：从"一行飘在灰底上的小字"改成"一条浅底细条"。
    // 🔴 只为和下面 `summaryBtn` 同族（都在同一条竖直节奏里），不引入新的视觉语言：
    //    底 = `secondarySystemFill`、圆角 7、左右内边距 8，和分段控件的高光同一档灰。
    self.hiddenHint.backgroundColor = [UIColor secondarySystemFillColor];
    self.hiddenHint.layer.cornerRadius = 7;
    self.hiddenHint.contentEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 8);
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
    // v0.0.131：与 `hiddenHint` 同款细条（同族，不引第二套）。
    self.foldedHint.backgroundColor = [UIColor secondarySystemFillColor];
    self.foldedHint.layer.cornerRadius = 7;
    self.foldedHint.contentEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 8);
    self.foldedHint.hidden = YES;
    [self.foldedHint addTarget:self action:@selector(onFoldedHintTap)
              forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.foldedHint];

    // v0.0.98：通知中心残留提示（`aliveStillCount > 0` 才显示，见 viewDidLayoutSubviews）。
    // 🔴 创建方式、字号、颜色、对齐全部照抄 `foldedHint` / `hiddenHint` ——
    //    同屏第四条提示，**不引第二套写法**（本项目"同一个东西只留一份实现"的纪律）。
    // 🔴 这一条**可点**，点一下切「只看残留」：因为用户的原话是"能打上标签吗" ——
    //    标签只是告诉他有哪些，真正想做的事是"把这些清掉"，那就得能一键只看它们。
    self.aliveHint = [UIButton buttonWithType:UIButtonTypeSystem];
    self.aliveHint.titleLabel.font = [UIFont systemFontOfSize:12];
    self.aliveHint.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.aliveHint.titleLabel.minimumScaleFactor = 0.85;
    self.aliveHint.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [self.aliveHint setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateNormal];
    self.aliveHint.hidden = YES;
    [self.aliveHint addTarget:self action:@selector(onAliveHintTap)
             forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.aliveHint];

    // 顶部 App 图标栏（横向滚动）
    self.iconBar = [[UIScrollView alloc] init];
    self.iconBar.showsHorizontalScrollIndicator = NO;
    // 🔴🔴 v0.0.177：**必须关掉 scrollsToTop**，否则「点状态栏回到顶部」在整个 App 里失效。
    //    UIKit 的规则是：「同时有**多个** `scrollsToTop == YES` 的 scroll view 在屏上 ⇒
    //    这个手势**全都不响应**」（不是"响应最上面那个"，是"全失效"）。
    //    而这个属性**默认就是 YES**，全仓又一处都没显式设过 ⇒ `iconBar` 和 `table`
    //    两个都为 YES ⇒ 用户在长列表里点状态栏，一点反应都没有。
    //    ⚠️ 这条我按 API 规则推的，装到机上点一下状态栏即可证实/证伪。
    //    🔴 为什么只关 iconBar、不显式给 table 置 YES：默认已经是 YES，
    //       多写一句"看起来像在设什么"的代码，反而是下一个人改动时的噪声。
    self.iconBar.scrollsToTop = NO;
    // v0.0.131：图标栏挂进 `topCard`（那张白卡现在是它的底），不再是浮在灰底上的裸条。
    // 🔴 坐标语义没变：`reloadIconBar` 里 `holder` 的 x/y 本来就是相对 iconBar 的，
    //    只有布局里那一处 frame 要按"相对 topCard"算（见 `viewDidLayoutSubviews`）。
    // ⚠️ `topCard.clipsToBounds` 是 YES ⇒ 红点/图标会被卡片圆角裁一点点。
    //    红点在 holder 内 y=5、图标第一行在 y=6~50，都在 64 高的卡片安全区里，实测不裁。
    [self.topCard addSubview:self.iconBar];

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

    // ================= v0.0.178：下拉刷新 =================
    // 🔴 用户要的是"手动刷新一次"，所以这条**不能走 `refreshIfChanged`**：
    //    那个函数第一句就是 `if (![self dbFingerprintChanged]) return;` —— 库没变时
    //    它什么都不做，用户拉一下松手、转圈消失、界面一点变化没有 ⇒
    //    结论是"下拉刷新是坏的"。手动入口的语义是"我要求你重查一遍"，不是"变了才查"。
    //    ⇒ 走 `reloadKeepingOffset`（完整重查 + 保住滚动位置），并在下面请 tweak 重扫。
    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(nbOnPullRefresh:)
        forControlEvents:UIControlEventValueChanged];
    // 🔴 挂在 `table.refreshControl` 上，而不是 `addSubview:` 到 table：
    //    系统只在 `refreshControl` 这一条路上管"下拉出来的距离 / 收回去的动画 / inset"。
    //    自己 addSubview 得把这些**全部**重做一遍，而且十有八九漏掉某一种（弹回、分页、编辑态）。
    self.table.refreshControl = rc;
    self.nbRefresh = rc;
    // 🔴 空列表时也必须能下拉 —— 而"一条记录都没有"恰恰是最想刷新的时候。
    //    UITableView 的 `alwaysBounceVertical` 默认就是 YES，这里显式写一遍是为了把它
    //    **钉在代码里**：以后谁给某个筛选态调了 `bounces = NO`（比如"空列表不要橡皮筋"），
    //    下拉刷新就会**只在空列表时静默失效** —— 而那一刻用户唯一的想法是"这 App 坏了"。
    self.table.alwaysBounceVertical = YES;

    // ================= v0.0.178：键盘收起 =================
    // 🔴 搜索框是**常驻**的（v0.0.132 起），所以"一边看结果一边被键盘挡住半屏"
    //    是常态而不是偶发。列表滚一下就收键盘 = 系统列表的标准行为。
    // 🔴 选 `OnDrag` 而不是 `Interactive`：`Interactive` 会让键盘跟着手指走，
    //    但本表有 section header 吸顶 + 自绘 card 的位移手势（`nbApplyOffset:`），
    //    手指在卡片上的竖直位移会**同时**喂给两个东西 ⇒ 表现为"键盘抖、卡片也抖"。
    //    `OnDrag` 是"一开始拖就收"，行为确定，不跟手势抢。
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    // v0.0.132：首帧前先给时间胶囊上色（样式只由 `updateTimePills` 管，loadData 也会调）。
    [self updateTimePills];
}

#pragma mark - v0.0.132 顶部：常驻搜索 / 时间胶囊 / 筛选菜单 / 摘要行（方案 B）

// v0.0.132（方案 B）：时间胶囊行的样式同步 —— **唯一出口**。
// 🔴 只根据 `timeSeg.selectedSegmentIndex` 设每个胶囊的选中态（蓝底白字 / 灰底灰字），
//    不在这里改任何状态、不查库。改状态只发生在 `onTimePillTapped:` 里。
// 🔴 通过 `updateSummaryRow` 调用（它在 `loadData` 每轮刷新都跑）⇒ 菜单/清除改了时间档，
//    胶囊色也会跟着翻，不会出现"菜单里勾了、胶囊没亮"的失同步。
- (void)updateTimePills {
    NSInteger ti = self.timeSeg.selectedSegmentIndex;
    for (NSUInteger i = 0; i < self.timePills.count; i++) {
        UIButton *b = self.timePills[i];
        BOOL on = ((NSInteger)i == ti);
        b.selected = on;
        b.backgroundColor = on ? [UIColor systemBlueColor] : [UIColor secondarySystemFillColor];
        [b setTitleColor:(on ? [UIColor whiteColor] : [UIColor secondaryLabelColor])
                 forState:UIControlStateNormal];
    }
}

// 点时间胶囊：走**原来的** `onTime:`（不新开赋值路径）。
// 🔴 程序改 `selectedSegmentIndex` 不触发 ValueChanged ⇒ 必须手动调 `onTime:`（v0.0.131 同款）。
- (void)onTimePillTapped:(UIButton *)sender {
    NSInteger i = sender.tag;                              // tag = 时间档序号
    if (self.timeSeg.selectedSegmentIndex == i) return;    // 点自己 ⇒ 什么都不做
    self.timeSeg.selectedSegmentIndex = i;
    [self onTime:self.timeSeg];
}

// 当前生效的筛选名 —— **唯一来源**：角标数、摘要文案、布局里的"要不要占位"全从它派生。
// 🔴 三个出口各自判一遍"有没有筛选"，迟早有一处走岔；那种错不报错，只让
//    "角标亮着但摘要行没出现"这种自相矛盾的界面留在屏幕上。
- (NSArray<NSString *> *)activeFilterNames {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSInteger ti = self.timeSeg.selectedSegmentIndex;
    NSArray<NSString *> *names = [self timeNames];
    // 🔴 第 0 段 = 近24小时 = **默认档**，不算"被筛过"。
    //    把它算进去的话角标永远亮着 1 —— 而"永远亮着"等于"没有提示"（提示条那几条纪律同源）。
    if (ti != 0 && ti >= 0 && ti < (NSInteger)names.count) {
        [parts addObject:names[(NSUInteger)ti]];
    }
    if (self.unreadOnly) [parts addObject:@"只看未读"];
    if (self.starOnly)   [parts addObject:@"★ 标星"];
    if (self.aliveOnly)  [parts addObject:@"只看残留"];
    return parts;
}

- (NSInteger)activeFilterCount {
    return (NSInteger)[self activeFilterNames].count;
}

// 摘要行 + 角标（唯一出口）。
- (void)updateSummaryRow {
    NSArray<NSString *> *parts = [self activeFilterNames];
    if (parts.count == 0) {
        // 🔴 清空时 `setTitle:nil`，而不是留一句空串再靠宽度藏 —— 留空串的话
        //    按钮仍然占着 24pt（frame 是布局算的，不由 title 决定），
        //    界面上就是一截空灰条。
        [self.summaryBtn setTitle:nil forState:UIControlStateNormal];
        self.filterBadge.text = nil;
        self.filterBadge.hidden = YES;
    } else {
        [self.summaryBtn setTitle:[[parts componentsJoinedByString:@" · "]
                                  stringByAppendingString:@"    清除"]
                         forState:UIControlStateNormal];
        self.filterBadge.text = [NSString stringWithFormat:@"%ld", (long)parts.count];
        self.filterBadge.hidden = NO;
    }
    // v0.0.132：时间胶囊色同步（状态由 timeSeg 持有，样式只在这里翻）。
    [self updateTimePills];
    // 摘要行的出现/消失会改头像卡之后所有元素的 y ⇒ 必须重布局
    [self.view setNeedsLayout];
}

// 副标题（唯一出口）。数据来自 `lastTotal` + `updateHiddenUnread` 带出来的 `allUnreadCount`。
// 🔴 不许在这里再查一次库：`loadData` 每次全量重查已经有 6~8 条 SQL，
//    为了两行小字再加一次 `COUNT(*)`，收益为负。
- (void)updateHeaderSub {
    NSInteger total = self.lastTotal;
    if (total <= 0) {
        self.bigSubLabel.text = @"还没有记录";
        return;
    }
    if (self.allUnreadCount < 0) {
        // 读不到未读数 ⇒ 只说条数。⛔ 不许写"全部已读"（那是拿读不到冒充 0 条）。
        self.bigSubLabel.text = [NSString stringWithFormat:@"共 %ld 条", (long)total];
    } else if (self.allUnreadCount == 0) {
        self.bigSubLabel.text = [NSString stringWithFormat:@"共 %ld 条 · 全部已读", (long)total];
    } else {
        self.bigSubLabel.text = [NSString stringWithFormat:@"共 %ld 条 · 未读 %ld",
                                          (long)total, (long)self.allUnreadCount];
    }
}

// 筛选菜单。用 `UIDeferredMenuElement`：**每次弹出时现算**。
// 🔴 为什么不提前构好一份菜单对象：那样只要有一处改了状态忘了重建 `menu`，
//    弹出来的就是上一次的选中态 —— 用户看到"★ 没勾上但列表只有标星的"，
//    这类"显示的读数和实际状态不是同一次"的错最难查（本项目栽过多次）。
//    延迟构建把这个失效模式整类消掉：没有缓存，就没有"忘了刷新缓存"。
- (UIMenu *)buildFilterMenu {
    __weak typeof(self) weakSelf = self;
    UIDeferredMenuElement *root =
        [UIDeferredMenuElement elementWithProvider:^(void (^completion)(NSArray<UIMenuElement *> *elements)) {
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2) { completion(@[]); return; }
            completion([self2 filterMenuElements]);
        }];
    return [UIMenu menuWithTitle:@"" children:@[root]];
}

- (NSArray<UIMenuElement *> *)filterMenuElements {
    NSMutableArray<UIMenuElement *> *out = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;

    // ---------- 时间范围（单选子菜单） ----------
    // 🔴 每一项都调**原来那一个** `onTime:`，不新开赋值路径：
    //    直接改 `selectedSegmentIndex` 之后 `loadData` 也要跑，但那样
    //    "改时间要不要重查库"这件事就有了两处实现，迟早走岔。
    NSArray<NSString *> *names = [self timeNames];
    NSMutableArray<UIAction *> *timeActs = [NSMutableArray arrayWithCapacity:names.count];
    for (NSUInteger i = 0; i < names.count; i++) {
        UIAction *a = [UIAction actionWithTitle:names[i]
                                         image:nil
                                    identifier:nil
                                       handler:^(UIAction *action) {
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2) return;
            if (self2.timeSeg.selectedSegmentIndex == (NSInteger)i) return;   // 点自己 ⇒ 什么都不做
            self2.timeSeg.selectedSegmentIndex = (NSInteger)i;
            // 🔴 程序改 `selectedSegmentIndex` **不触发** `UIControlEventValueChanged`
            //    ⇒ 这一句手动调用不能省（否则菜单点完界面纹丝不动）。
            [self2 onTime:self2.timeSeg];
        }];
        a.state = (self.timeSeg.selectedSegmentIndex == (NSInteger)i)
                    ? UIMenuElementStateOn : UIMenuElementStateOff;
        [timeActs addObject:a];
    }
    // 🔴🔴 这里必须是**六参数**版本（`identifier:` + `options:`）。
    //    写成三参数 `menuWithTitle:image:children:` 会直接编译失败 ——
    //    `UIMenu` 根本没有那个重载（只有 `menuWithTitle:children:` 两参数版
    //    和 `menuWithTitle:image:identifier:options:children:` 六参数版）。
    //    这类"API 到底存不存在"的错，源码判据永远看不见，只有编译期能抓（v0.0.131 现场）。
    [out addObject:[UIMenu menuWithTitle:@"时间范围"
                                   image:[UIImage systemImageNamed:@"clock"]
                              identifier:nil
                                 options:0
                                children:timeActs]];

    // ---------- 只看未读 ----------
    UIAction *unreadAct = [UIAction actionWithTitle:@"只看未读"
                                              image:[UIImage systemImageNamed:@"envelope.badge"]
                                         identifier:nil
                                            handler:^(UIAction *action) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        // 走原来那条路：`onUnread:` 从 `unreadSeg` 取段号，它才是 `unreadOnly` 的唯一写入者
        self2.unreadSeg.selectedSegmentIndex = self2.unreadOnly ? 0 : 1;
        [self2 onUnread:self2.unreadSeg];
    }];
    unreadAct.state = self.unreadOnly ? UIMenuElementStateOn : UIMenuElementStateOff;
    [out addObject:unreadAct];

    // ---------- ★ 只看标星 ----------
    UIAction *starAct = [UIAction actionWithTitle:@"只看标星"
                                            image:[UIImage systemImageNamed:@"star"]
                                       identifier:nil
                                          handler:^(UIAction *action) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        // `onStar:` 本身是 toggle（它自己取反），所以这里**不先改状态**
        [self2 onStar:self2.starBtn];
    }];
    starAct.state = self.starOnly ? UIMenuElementStateOn : UIMenuElementStateOff;
    [out addObject:starAct];

    // ---------- 只看残留 ----------
    // 🔴 只在**能切**的时候给这一项：
    //    ① 已经开着 ⇒ 必须给（否则用户没法关）；
    //    ② 一条残留都没有 / 快照过期 ⇒ 不给 —— 切过去是空列表，而
    //       `onAliveHintTap` 对这两种状态的处理都是"重新扫描"，不是"切换"。
    //       在这里给一个"切换"，就等于把用户带进一个空列表（v0.0.100 那条坑同源）。
    if (self.aliveOnly || (self.aliveStillCount > 0 && !self.aliveStale)) {
        UIAction *aliveAct = [UIAction actionWithTitle:@"只看通知中心残留"
                                                image:[UIImage systemImageNamed:@"dot.radiowaves.left.and.right"]
                                           identifier:nil
                                              handler:^(UIAction *action) {
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2) return;
            // 和 `onAliveHintTap` 尾部那两句**完全一样**（那里也是这么切的）
            self2.aliveOnly = !self2.aliveOnly;
            [self2 loadData];
        }];
        aliveAct.state = self.aliveOnly ? UIMenuElementStateOn : UIMenuElementStateOff;
        [out addObject:aliveAct];
    }

    // ---------- 动作 ----------
    // 全标已读只在「只看未读」下出现 —— 和 v0.0.38 把它藏进分段控件旁边同一条理由：
    // 「全部」模式下列表里已读未读混在一起，这个按钮的作用范围不明确，容易被当成清空。
    if (self.unreadOnly) {
        [out addObject:[UIAction actionWithTitle:@"全标已读"
                                           image:[UIImage systemImageNamed:@"checkmark.circle"]
                                      identifier:nil
                                         handler:^(UIAction *action) {
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2) return;
            [self2 onMarkAllRead:nil];
        }]];
    }
    if ([self activeFilterCount] > 0) {
        UIAction *clear = [UIAction actionWithTitle:@"清除全部筛选"
                                              image:[UIImage systemImageNamed:@"arrow.counterclockwise"]
                                         identifier:nil
                                            handler:^(UIAction *action) {
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2) return;
            [self2 onClearFilters];
        }];
        clear.attributes = UIMenuElementAttributesDestructive;
        [out addObject:clear];
    }
    return out;
}

// 「清除」：把摘要行里能看见的那几个筛选一起关掉，回到默认视图。
// 🔴 只清**摘要行里列出来的**那几项。App 筛选（头像栏）不在此列 ——
//    它在屏幕上是**看得见的高亮**，用户想清会自己点「全部」；
//    在"清除"里顺手把它也清掉，等于替用户改了一个他没在问的选择。
// v0.0.186：把「清筛选」拆成**只改状态**和「改完再查」两步。
// 🔴 为什么拆：统计页钻取要一次做完"清掉其它筛选 + 设 App + 设时间窗"，然后**只查一次库**。
//    v0.0.185 之前 `onClearFilters` 自带 `loadData`，直接复用就会连查两次 ——
//    列表要闪一下（第一帧"全部 App"、第二帧才跳到目标），而且那两次查询之间
//    用户的手指可能已经点到别的地方去了。
// 🔴 拆的是**执行时机**，不是筛选语义：清哪些量仍然只有这一处定义
//    （`onClearFilters` 和 `applyDrilldownBundle:` 都只调它）。
- (void)nbResetFilterState {
    if (self.timeSeg.selectedSegmentIndex != 0) {
        self.timeSeg.selectedSegmentIndex = 0;      // 回默认档（近24小时）
    }
    // 🔴 下面三个状态是**直接赋值**、而不是挨个调 `onUnread:` / `onStar:`：
    //    那两个方法各自内部都会 `loadData`（一次 6~8 条 SQL + 重建 2000 行），
    //    连调三次就是三次全量重查。这里统一交给调用方收一次口。
    //    ⚠️ 代价：`unreadOnly` 的语义等于"`unreadSeg` 的第 1 段"，两边必须一起改 ——
    //    所以这两行紧贴着写，将来改 `onUnread:` 的人一眼能看到它。
    self.unreadSeg.selectedSegmentIndex = 0;
    self.unreadOnly = NO;
    self.markAllBtn.hidden = YES;
    self.starOnly = NO;
    self.starBtn.selected = NO;
    self.aliveOnly = NO;
    if (self.searchText.length || self.searchBar.text.length) {
        // 🔴 `searchBar.text` 必须一起清：只清 `searchText` 的话框里还留着字，
        //    用户会以为"还在搜"，然后自己再清一次（`onHiddenHintTap` 同款理由）。
        self.searchText = nil;
        self.searchBar.text = nil;
    }
    [self updateSummaryRow];
}

- (void)onClearFilters {
    // 先作废挂起的搜索防抖，避免清完 250ms 后又被跑一次全量查询
    [self cancelPendingLoadData];
    [self nbResetFilterState];
    [self loadData];
}

// ================= v0.0.186：统计页钻取 =================
//
// 🔴 为什么需要它：v0.0.183 把统计提成第二个页签之后，统计页成了**孤岛** ——
//    排行榜把 67 个 App 的条数摆得清清楚楚，点上去却只有 `deselectRowAtIndexPath`。
//    用户看到"微信 18 条"最自然的下一步就是"让我看看那 18 条"。
//
// 🔴 时间窗只能**部分映射**，这是这一版最需要说清的一件事：
//      统计页：全部 / 7 天 / 30 天 / 自定义（`rangeSeg` 0~3）
//      记录页：近24小时 / 近7天 / 不限（`timeSeg` 0~2）
//    ⇒ 「全部」→ 不限、「7 天」→ 近7天，这两档是**逐字对得上**的；
//      「30 天」和「自定义」在记录页**没有对应档** —— 传 -1 表示"别动时间窗"，
//      保持用户自己选的那个，⛔ 绝不用"最接近的 7 天"去凑 ——
//      那会出现"统计说 42 条、点进去只有 8 条"，比不能点更糟（两个口径打架）。
//
// 🔴 其余筛选（未读 / ★ / 残留 / 搜索）必须一起清掉：它们**都会挡记录**，
//    不清就会出现"点进去数目对不上"，而用户完全看不出是哪个开关在挡。
- (void)applyDrilldownBundle:(NSString *)bundle dayRange:(NSInteger)days {
    [self cancelPendingLoadData];
    [self nbResetFilterState];

    // App 维度：`filterBundle` 的写入点仍然只有"用户动作的入口"这一族
    // （图标栏点击 / 本方法）。⛔ 不在 `loadData` 里改它。
    self.filterBundle = bundle.length ? bundle : nil;

    // 时间窗：只动能一一对应的档（映射表见方法头注释）
    NSInteger seg = -1;
    if (days == 0)       seg = 2;   // 全部      → 不限时间
    else if (days == 7)  seg = 1;   // 7 天      → 近7天
    else if (days == 1)  seg = 0;   // 24 小时   → 近24小时
    if (seg >= 0) {
        self.timeSeg.selectedSegmentIndex = seg;
        // 🔴 同步"上一档"：下次用户自己切时间胶囊时，滑动方向靠它算
        //    （`onTime:` 里用 `nbPrevTimeIdx` 和当前档比大小）。不同步的话，
        //    钻取后第一次切档的动画会朝反方向走 —— 一个看得见但归不到原因的小 bug。
        self.nbPrevTimeIdx = seg;
    }

    // 换了 App 筛选 = 整屏内容被换掉 ⇒ 走入场错落（和点图标栏同一条路）
    [self nbArmEntrance];
    [self loadData];
}


// 统一在 safeArea 里排版，避免和导航栏/搜索框互相压字
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat top = self.view.safeAreaInsets.top;
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat safeBottom = self.view.safeAreaInsets.bottom;
    CGFloat y = top + 4;

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
    // v0.0.98：残留提示的可见性判据。
    // 🔴 和 `foldedHint` 一样**故意不串 `items.count`**：它可能正是列表空掉的原因
    //    （「只看残留」+ 当前筛选里一条都没有），那时更要显示，否则用户只看到"暂无记录"。
    // 🔴 但过期快照也要有一条出口：`aliveStale` 时虽然一条橙条都不打，仍显示提示条
    //    告诉他"上次扫描是多久前、再删一条就会刷新" —— 否则这个功能看起来像坏了。
    // 🔴🔴 `aliveStale` 必须写进这个判据里：过期时全部行都是 Unknown ⇒ `aliveStillCount == 0`，
    //    若只判 `stillCount > 0 || aliveOnly`，那句"已过期"文案就**永远不会出现**
    //    （分支写了、条件到不了 = 交了等于没交）。
    // 🔴🔴 v0.0.99：改成**常驻**（只看列表里有没有东西）。
    //    v0.0.98 的判据要求 `aliveScanTs > 0`，于是"还没有扫描结果"时整条提示条不显示 ——
    //    而那恰好是最需要说话的时候（用户看到的就是"装了个新版什么都没变"）。
    //    现在这句同时是**功能入口**：没数据时它写"点这里重新扫描"，点了就重扫。
    BOOL showAliveHint = (self.items.count > 0);

    CGFloat cardX = NBInset;
    CGFloat cardW = w - NBInset * 2;

    // =====================================================================
    // v0.0.132（方案 B）：大标题行 + 常驻搜索 + 时间胶囊 + 头像卡。
    //    v0.0.131 的放大镜开关已移除 ⇒ 搜索框**常驻**；时间范围从筛选菜单里
    //    提到明面做成胶囊行（最常见操作少点一层菜单）。
    // 🔴 标题可用宽度只要给筛选按钮（1 个 30pt）留位，不再减两个按钮。
    // =====================================================================
    CGFloat btnS = 30;
    CGFloat rightEdge = w - NBInset;
    self.filterBtn.frame = CGRectMake(rightEdge - btnS, y + 8, btnS, btnS);
    CGFloat textW = MAX(80, rightEdge - btnS - NBInset - 8);
    self.bigTitleLabel.frame = CGRectMake(NBInset, y + 3, textW, 24);
    self.bigSubLabel.frame = CGRectMake(NBInset, y + 27, textW, 16);
    // 角标压在筛选按钮右上角，故意探出一点点
    self.filterBadge.frame = CGRectMake(CGRectGetMaxX(self.filterBtn.frame) - 8,
                                       CGRectGetMinY(self.filterBtn.frame) - 6, 16, 16);
    y += 46;

    // v0.0.132：搜索框**常驻**（去掉放大镜开关后始终占位）。
    // 🔴 左右各外扩 4 和 v0.0.71 同款：UISearchBar 自带内边距，不外扩会陷进去。
    self.searchBar.hidden = NO;
    self.searchBar.frame = CGRectMake(cardX - 4, y - 2, cardW + 8, 40);
    y += 40 + 4;

    // v0.0.132：时间胶囊行。N 个胶囊等分 `cardW`，**只在这里排 frame**（样式由 `updateTimePills` 管），
    //    两个出口（frame 归布局、颜色归样式）互不抢。
    // 🔴 `timePillRow` 容器只框住这一行高，不会盖住下面的列表 ⇒ 不抢触摸事件。
    CGFloat pillH = 30;
    CGFloat pillGap = 8;
    CGFloat pillW = (cardW - pillGap * (self.timePills.count - 1)) / (CGFloat)self.timePills.count;
    self.timePillRow.frame = CGRectMake(cardX, y, cardW, pillH);
    CGFloat px = 0;
    for (NSUInteger i = 0; i < self.timePills.count; i++) {
        self.timePills[i].frame = CGRectMake(px, 0, pillW, pillH);
        px += pillW + pillGap;
    }
    y += pillH + 6;

    // 头像卡：图标栏的底。
    // 🔴 `iconBar` 是 `topCard` 的**子视图** ⇒ 下面这行 frame 是相对 topCard 的坐标系。
    //    写错成 `(0, y, w, 56)` 的话它会被推到卡片外面去（而 `clipsToBounds` 一裁，图标整条消失）。
    self.topCard.frame = CGRectMake(cardX, y, cardW, 64);
    self.iconBar.backgroundColor = [UIColor clearColor];
    self.iconBar.frame = CGRectMake(0, 4, cardW, 56);
    y += 64 + 6;

    // 筛选摘要行：只在有筛选时占位。
    // 🔴 判据用 `activeFilterCount` —— 和角标、和摘要文案**同一个来源**。
    //    三处各自判一遍"有没有筛选"，迟早有一处走岔（"提示语与判定必须同源"）。
    BOOL hasFilter = ([self activeFilterCount] > 0);
    self.summaryBtn.hidden = !hasFilter;
    if (hasFilter) {
        self.summaryBtn.frame = CGRectMake(cardX, y, cardW, 24);
        y += 24 + 6;
    } else {
        self.summaryBtn.frame = CGRectZero;
    }

    // 提示条：竖直节奏、顺序、`cy` 累加规则**全部沿用 v0.0.71**（就是上面那三条 BOOL），
    // 这一版只改了它们的 x（从卡片内挪到页面上）和"有没有浅底"，可见性逻辑一个字没动。
    CGFloat cy = y;
    CGFloat inX = cardX;
    CGFloat inW = cardW;

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

    // v0.0.98：通知中心残留提示。排在上两条之后，节奏与它们一致（前一条在场时 2pt、不在时 8pt）。
    // 🔴 不显示时必须把 frame 也清零（只 hidden 不清 frame ⇒ 卡片底部凭空多一截空白，
    //    这个坑 v0.0.40 的 hiddenHint 已经踩过一次，注释就在上面几行）。
    self.aliveHint.hidden = !showAliveHint;
    if (showAliveHint) {
        cy += (showHint || showFoldedHint) ? 2 : 8;
        self.aliveHint.frame = CGRectMake(inX, cy, inW, kNBHintH);
        cy += kNBHintH;
    } else {
        self.aliveHint.frame = CGRectZero;
    }

    // v0.0.131：提示条走完 ⇒ 直接把 y 交给列表。
    // `topCard` / `iconBar` 的 frame 已经在上面定好了（v0.0.71 那张"卡片高度由内容撑"的
    // 算法没有内容可撑了 —— 现在它只有一行图标，高度是常量 64）。
    y = cy + 4;

    self.table.frame = CGRectMake(0, y, w, h - y - safeBottom);

    // v0.0.164：总览网格的**宽度只在这里跟随**（高度由卡片数决定，见 `nbRebuildOverview`）。
    // 🔴 为什么需要单独这一处：`nbRebuildOverview` 可能早于本次布局就跑完了 ——
    //    首屏 `loadData` 在 `viewDidLoad` 里，那时 table 宽度还是 0，走的是"屏幕宽"兜底值。
    //    宽度真变了（旋转 / 分屏）必须让表格重新量一次 header 尺寸，否则网格里两列卡片
    //    会按旧宽度排（右列被切掉一半）。判据用 0.5pt 容差，避免亚像素抖动引起每帧重赋。
    if (self.overviewGrid &&
        (self.overviewGrid.bounds.size.width < w - 0.5 ||
         self.overviewGrid.bounds.size.width > w + 0.5)) {
        CGRect f = self.overviewGrid.frame;
        f.size.width = w;
        self.overviewGrid.frame = f;
        self.table.tableHeaderView = self.overviewGrid;
    }
}

- (void)reloadIconBar {
    // 🔴 v0.0.36：重建按钮会动 `contentSize`，而图标栏是横向滚动的 ——
    //    不清醒地保住 offset 的话，用户滚到右边选了第 10 个 App、点开一条通知，
    //    一返回图标栏就跳回最左。这里手动存、算完再夹回去。
    CGPoint barOff = self.iconBar.contentOffset;

    [self.iconBar.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.bundles = [NotifyStore distinctBundles];
    // ================= v0.0.179：App 名映射**先**建（原来在函数尾部）=================
    // 🔴 为什么往前挪：图标栏的无障碍标签在下面那个循环里读 `appNameForBundle:`。
    //    留在尾部的话，**新 App 第一次来通知**那一轮读到的是兜底短名（bundle 末段，
    //    比如 `bijia` 而不是「比价」）—— 看得见的人看图标完全不受影响，
    //    只有 VoiceOver 用户会听到一个怪名字，而且下一轮自己就好了（最难查的那种）。
    // 🔴 挪动是安全的：这中间没有任何东西读 `appNameMap`
    //    （`shortName:` 只看 bundle 串，`distinctBundles` / `bundlesWithUnreadSince:` 只看库）。
    // 🔴 成本可忽略：`InstalledApps +all` 自己有 `gCache`，这里只是把数组塞进字典。
    [self rebuildAppNames];
    // v0.0.36：一次查出来，下面建每个图标时直接用（别在循环里一个个查库）
    // v0.0.37：红点只算**当前时间窗内**的未读 —— 和列表同口径，点得进去也清得掉。
    NSSet *unread = [NotifyStore bundlesWithUnreadSince:[self sinceFromSeg]];
    self.unreadDots = [NSMutableDictionary dictionary];

    CGFloat x = 8;
    // v0.0.131：44 → 40。图标条现在装在一张 64 高的白卡里（上下各 4pt 内边距），
    // 40 + 上 4 + 下划线 3 + 间距 3 = 50 ≤ 56 ⇒ 不会顶到卡片边。
    CGFloat size = 40;
    NSArray *list = [@[@"全部"] arrayByAddingObjectsFromArray:self.bundles];
    for (NSString *bid in list) {
        // 🔴 v0.0.36：按钮外面套一层容器。
        //    按钮自己要 `clipsToBounds`（圆角得把图标裁进去），红点如果挂在按钮上、
        //    又想压在角上探出一点，就会被裁掉一半。容器不裁剪，红点挂容器。
        UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(x, 4, size, size)];
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
        // v0.0.131：选中态从"2pt 蓝边框"改成"下方 3pt 短横线"。
        // 🔴 为什么换：蓝框压在**彩色** App 图标上会跟品牌色打架（微信绿边一圈蓝、
        //    招行红边一圈蓝），而且深色模式下 2pt 蓝框在深色图标上看不出来。
        // 🔴 短横线挂在 `holder` 上（不是按钮上）：按钮 `clipsToBounds = YES`（圆角要裁），
        //    挂按钮上会被裁掉一半 —— 红点当初就是因为这个才挂 holder 的，同一条理由。
        // 🔴 y = size + 3 ⇒ 落在 holder 边界之外，靠 holder 不裁剪露出来；
        //    48~50 这段仍在 topCard（高 64）之内，不会被卡片圆角切掉。
        UIView *ul = [[UIView alloc] initWithFrame:CGRectMake((size - 16) / 2.0, size + 3, 16, 3)];
        ul.backgroundColor = [UIColor labelColor];
        ul.layer.cornerRadius = 1.5;
        ul.hidden = !selected;
        [holder addSubview:ul];
        b.imageView.contentMode = UIViewContentModeScaleAspectFit;
        [holder addSubview:b];

        // v0.0.179：未读这个量**只算一次**，红点和无障碍标签都读它。
        // 🔴 为什么不让 label 自己再算一遍 `[unread containsObject:bid]`：那样"红点在不在"
        //    和"念不念有未读"就成了两条独立规则，改一条必漏一条 —— 而漏掉之后
        //    屏幕上是"红点亮着、VoiceOver 说没有未读"，两个界面互相打脸，且不报错。
        //    （本项目那条：提示语与判定必须同源，同一行也不行。）
        BOOL hasUnread = [unread containsObject:bid];

        // v0.0.36：有未读就在右上角点一个红点。「全部」不点 —— 它不是某个 App，
        // 而且"全部"聚合了所有 App，「红点 = 全部还有未读」会让人以为没有。
        if (![bid isEqualToString:@"全部"]) {
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(size - 9, -1, 9, 9)];
            dot.backgroundColor = [UIColor systemRedColor];
            dot.layer.cornerRadius = 4.5;
            // 描边用页面底色：红点压在图标上时轮廓更清楚
            dot.layer.borderWidth = 1.5;
            dot.layer.borderColor = [UIColor systemBackgroundColor].CGColor;
            dot.hidden = !hasUnread;
            [holder addSubview:dot];
            self.unreadDots[bid] = dot;
        }

        // ================= v0.0.179：无障碍（图标栏）=================
        // 🔴 为什么只有图标栏要单独写这一段：它是全 App **唯一**「纯图片、零文字」的在屏控件
        //    —— 时间胶囊有 `setTitle:tn[i]`、★ 有 `setTitle:@"★ 标星"`、分段控件自带标题，
        //    VoiceOver 都能读到文字。图标栏里每个格子只有一个 image（真 App 图标 / `tray.full`），
        //    所以滑到这里只能念「按钮」，一排全都一样。
        //    由此丢掉的恰好是三样**只有视觉才能表达**的信息：
        //      ① 这是哪个 App —— 而图标栏会随记录增删**重排**，"数第几个"根本不成立
        //      ② 有没有未读 —— 红点是 9pt 纯色 UIView，没有文字，完全不读
        //      ③ 当前筛的是哪个 —— 选中态只是一条 3pt 短横线，也读不到
        //    ⇒ 这三样必须**折进 label / traits**，不能指望 VoiceOver 去念那两个装饰。
        //
        // 🔴 精度只许到「有未读」，不许写「N 条」：红点本身就是二值的。
        //    label 说得比视觉更细，就成了"两个界面在讲不同的话"（本项目那条：
        //    界面反馈都是**结论**，不许一处比另一处知道得更多）。要写条数就得再查库，
        //    而这是每次重建图标栏都跑的循环 —— 为一个文案加 N 条 SQL 不值。
        //
        // ⛔ **不要**把 `holder` 设成 accessibility 元素（`holder.isAccessibilityElement = YES`）。
        //    看着更"整块"，但那样里面的 `b` 会被吞掉，VoiceOver 双击走的是
        //    `accessibilityActivate` —— 没实现就**双击没反应**。界面上表现为
        //    "名字念对了、就是点不动"，比完全不做更糟。
        //    `holder` 保持默认（不是 a11y 元素）⇒ `dot` / `ul` 也自然读不到（它们本来就没字）。
        NSString *a11yName = [self appNameForBundle:bid];
        // 🔴 取不到名字也不许留空 label：空 label 等于回到「按钮」，白做。
        if (!a11yName.length) a11yName = bid;
        // 未读读的就是红点用的那个量（`hasUnread`），不另算 —— 「全部」恒 NO，正好。
        b.accessibilityLabel = hasUnread
            ? [NSString stringWithFormat:@"%@，有未读", a11yName]
            : a11yName;
        // 选中态用 **trait**，不往 label 里拼「已选中」：VoiceOver 对
        // `UIAccessibilityTraitSelected` 有本地化播报（中文「已选中」），
        // 而且用户能在系统设置里关掉；自己拼进 label 就永远关不掉，还会和系统说法不一致。
        b.accessibilityTraits = UIAccessibilityTraitButton
                             | (selected ? UIAccessibilityTraitSelected : 0);

        x += size + 8;
    }
    self.iconBar.contentSize = CGSizeMake(x, 56);
    // 夹回滚动位置（内容变短时也安全）
    CGFloat maxX = MAX(0, x - self.iconBar.bounds.size.width);
    self.iconBar.contentOffset = CGPointMake(MIN(barOff.x, maxX), barOff.y);
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
    // ---------- v0.0.189：搜索支持语法（引号 / AND / 排除）----------
    // App 名匹配从「整串去匹配」改成「**第一个正向词**去匹配」。两个理由：
    //  ① 整串匹配在带语法之后必然失效：`微信 红包` 这一整串哪个 App 名都不含 ⇒
    //     以前是"搜不到"（整串 LIKE 也搜不到），现在是"少了一半"（库里没有"微信"这几个字，
    //     App 名又匹配不上 ⇒ 那个 AND 永远不成立）。这条必须跟着语法一起改，否则新语法
    //     看起来像是"把搜索改坏了"。
    //  ② SQL 里 `bundle IN (...)` 只能挂一个括号组，而它只能挂在**第一个正向词**上
    //     （挂在别的词上就是"两个 App 名同时命中"，永远为空）。
    // 🔴 解析一律走 `[NotifyStore searchTermsFromString:]` —— 那是唯一口径。
    //    在这里自己 `componentsSeparatedByString:@" "` 就会出现"库里认引号、界面不认"，
    //    症状是搜带引号的短语时 App 名匹配突然失灵，而列表里照样有结果，很难发现。
    NSString *firstPos = nil;
    for (NSDictionary *t in [NotifyStore searchTermsFromString:q]) {
        if ([t[@"neg"] boolValue]) continue;
        NSString *txt = t[@"text"];
        if ([txt isKindOfClass:[NSString class]] && txt.length) { firstPos = txt; break; }
    }
    // 只有排除词（`-红包`）⇒ 没有"搜哪个 App"这回事：那是"全部记录里去掉含红包的"。
    if (!firstPos.length) return nil;

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *bid in self.appNameMap) {
        NSString *name = self.appNameMap[bid];
        // ① 匹配 App 显示名（用户想的是「微信」，不是 com.tencent.xin）
        NSRange r1 = [name rangeOfString:firstPos
                                 options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch];
        // ② 也匹配 bundle id 本身（懂行的人会直接搜 `tencent`）
        NSRange r2 = [bid rangeOfString:firstPos options:NSCaseInsensitiveSearch];
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
    // v0.0.178：点图标栏给一次最轻的触觉。
    // 🔴 为什么这里"必须有"：图标栏是**自绘**的 UIImageView/UIButton 组合，
    //    系统不会白送任何反馈（UISegmentedControl / UIButton 那套自带的东西，自绘一概没有）。
    NBHapticFire(NBHapticKindSoft);
    self.filterBundle = [bid isEqualToString:@"全部"] ? nil : bid;
    // v0.0.176：换了 App 筛选 = 整屏内容被换掉 ⇒ 走入场错落。
    // 🔴 布防点必须落在**用户动作的入口**，不能落在 `loadData` 里 —— 见 `nbArmEntrance` 的注释。
    [self nbArmEntrance];
    [self loadData];
}

- (void)onTime:(UISegmentedControl *)seg {
    // v0.0.178：切时间档给一次最轻的触觉。
    // 🔴 放在 `onTime:` 而**不是** `onTimePillTapped:`：v0.0.37 起时间筛选是自绘胶囊，
    //    点胶囊会**手动**调 `onTime:`（程序改 selectedSegmentIndex 不触发事件）。
    //    两处都写就是一次点击震两下；只写在胶囊那边的话，将来任何直接设段号的路径又没声了。
    //    ⇒ 认"唯一的执行出口"，不认"手指落在哪儿"。
    NBHapticFire(NBHapticKindSoft);
    // v0.0.176：先按"从哪一档换到哪一档"布防，再重查。
    // 🔴 布防必须在 `loadData` **之前**：动画的触发点在 `willDisplayCell:`，
    //    而那一次布局是由 `loadData` 里的 `reloadData` 引出来的。
    NSInteger to = seg.selectedSegmentIndex;
    [self nbArmSlideFromIndex:self.nbPrevTimeIdx toIndex:to];
    self.nbPrevTimeIdx = to;
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

    // v0.0.98：通知中心残留快照。**一次刷新只读一份**（理由见属性注释）。
    // 🔴 位置必须在 `applyAliveFilter:` 之前，也在 `cellForRow` 之前 —— 而这两处都在后面，
    //    所以放在这里（查询之前）就够了，顺便让"读快照"和"查库"两件事互不依赖。
    [self loadAliveSnapshot];

    NSArray<NSDictionary *> *queried = [NotifyStore queryWithBundle:self.filterBundle
                                        since:[self sinceFromSeg]
                                       search:self.searchText
                               searchBundles:searchBundles
                                   unreadOnly:self.unreadOnly];
    // v0.0.48：给查询结果套关键词规则（标星 + 折叠）。**无规则时原样返回 ⇒ 行为零变化。**
    NSArray<NSDictionary *> *ruled = [self applyKeywordRulesToRows:queried];
    // v0.0.95：同内容同日的行归并成一条（×N）。
    // 🔴 位置不能动：必须在 `applyKeywordRulesToRows:` 之后（它决定哪些行进列表），
    //    在 `rebuildBundleUnread` 之前（未读书签要按**最终可见的 items**数）。
    // v0.0.121：归并结果**存进 `itemsBeforeAlive`** —— 它是残留筛选的输入，
    //    库没变的时候（轻路）直接拿它再筛一遍，不必把上面这一整串重跑。
    self.itemsBeforeAlive = [self applyGroupCollapse:ruled];
    // v0.0.98：残留筛选 + 未读书签 + 列表刷新 —— 全部收进共用尾部。
    // 🔴 为什么不在这里写一遍：轻路（`refreshItemsKeepingOffset`）要做**完全一样**的事，
    //    写两遍迟早走岔，而走岔的表现是"下拉一次通知中心，某些提示条不动了"这种
    //    只在特定操作序列下出现的问题。顺序必须落成代码结构，注释守不住。
    [self applyItemsAndRefreshUI];

    // 🔴 标题里直接报 DB 总记录数：这个数不依赖列表渲染，
    //    即使列表因为取图标崩了，用户也能从标题看出「库里到底有没有东西」。
    // v0.0.121：以下四行 + 后面三条提示条只属于**完整重查**（它们要么查库、
    //    要么依赖 `queriedCount` 这类只在 SQL 那一半才更新的量）。
    NSInteger total = [NotifyStore count];
    // v0.0.131：这里原来写的是 `self.title = @"消息盒子 (N)"`（系统导航栏标题）。
    // 标题改成自绘之后，这个数挪进副标题 —— 由 `updateHiddenUnread` → `updateHeaderSub`
    // 统一刷（那里才拿得到"全库未读"这个数）。本行只负责把 `lastTotal` 定下来。

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
    // v0.0.131：摘要行 + 筛选角标（`activeFilterNames` 是唯一来源）。
    // 🔴 必须排在 `setNeedsLayout` **之前**：摘要行出现/消失会改头像卡之后所有元素的 y。
    [self updateSummaryRow];
    [self.view setNeedsLayout];
}

// v0.0.121：完整路与轻路的**共用尾部**。
// 🔴 为什么必须共用：残留筛选的结果只取决于「快照 + 筛之前的 items」，
//    和"那批 items 是怎么来的"无关。两条路各写一遍 = 迟早一边改了另一边没改。
// 🔴 这里**不许**出现任何查库动作：轻路的价值就在"零 SQL"。要查库的东西一律留在
//    `loadData` 里（`updateMoreFooter` / `updateHiddenUnread` 各要查 1~2 次）。
- (void)applyItemsAndRefreshUI {
    // v0.0.98：残留筛选。**必须排在归并之后**：
    //    归并保留下来的那条是"最新那条"，而 `aliveStillCount` 是给提示条报数的 ——
    //    如果放在归并之前，一个 ×5 的组会被数 5 次，提示条说"12 条仍在"而列表里只有 3 张卡，
    //    用户按这个数去找必然找不到（本项目"分母自己会变"的同款）。
    // 🔴 用两行而不是 `self.itemsBeforeAlive ?: @[]`：三元表达式里 `@[]` 是裸 `NSArray *`，
    //    而 `applyAliveFilter:` 的形参带轻量泛型 —— 项目开 `-Werror`，
    //    这种"可能报警告"的写法不值得赌一次 CI。
    NSArray<NSDictionary *> *base = self.itemsBeforeAlive;
    if (!base) base = @[];
    self.items = [self applyAliveFilter:base];
    // 🔴 v0.0.163：分组必须紧跟 `self.items` 重建、且**排在 reloadData 之前** ——
    //    数据源读的是 `sectionModels`，晚一步就是"新数据配旧分组"。
    [self nbRebuildDaySections];
    // v0.0.72：未读书签的计数必须紧跟 `self.items` 重建（见方法注释里的顺序要求）。
    [self rebuildBundleUnread];
    // v0.0.164：总览网格。
    // 🔴 位置要求：必须排在 `self.items` 赋值之后（它是唯一的数据来源），
    //    并且排在 `reloadData` **之前** —— 换 `tableHeaderView` 会改列表的 contentSize，
    //    和 reloadData 抢同一帧时，滚动位置会被夹一次（症状是"刷新后列表自己跳了一下"）。
    [self nbRebuildOverview];

    [self.table reloadData];
    [self updateEmptyView];
    // v0.0.98：残留提示条。放在这里是因为它依赖 `applyAliveFilter` 刚算出来的
    //    `aliveStillCount` / `aliveAllCount`；起始 y 的更新由调用方最后那句
    //    `setNeedsLayout` 负责（完整路在 `loadData` 尾部，轻路在 `clampContentOffset:` 里的
    //    `layoutIfNeeded`）。
    [self updateAliveHint];
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
    // v0.0.131：顺手把这个数留给副标题（`updateHeaderSub`）。
    // 🔴 存**原始值**、不做 `MAX(0, …)`：`-1` = 库打不开，和"真的 0 条未读"是两件事。
    self.allUnreadCount = all;
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
    // v0.0.131：副标题也跟着刷。
    // 🔴 放在这里而不是 `loadData` 末尾：这个方法是**所有**未读派生物的出口
    //    （`refreshUnreadDerived` 那条"只刷一行"的路也会调它），副标题是同一个数派生出来的，
    //    跟着这个出口走才不会有"点开一条变已读、副标题还是旧数"的窗口。
    [self updateHeaderSub];
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
    // v0.0.98：残留筛选也清 —— 和 starOnly 同一类理由（它同样**挡未读**：
    // 一条已读未读都可能有橙条，但"没有橙条"的行一律被它挡掉）。
    // 🔴 不过它挡的**不是**未读口径而是"有没有残留"，所以严格说它不影响提示条承诺的那个数；
    //    这里仍然清掉，是为了守住另一条更硬的规矩：**「清干净筛选」必须是真的清干净**。
    //    留一个维度不动，"三个筛选都清了还看不到"这种更坏的情况就会出现。
    if (self.aliveOnly) {
        self.aliveOnly = NO;
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

// ================= v0.0.95：同内容同日的行归并成一条 =================
// 🔴 为什么做（`nc_diag` 真机统计）：盒子 1692 行里 **同内容重复 71 组、多出 158 行**，
//    而 `sys_id` 重复是 0 组 ⇒ 这不是"同一条通知记了两遍"，是**同一个 App 连发几条
//    一模一样的内容**（营销推送、验证码重发、群消息摘要）。列表里连着五张一样的卡，
//    用户没法用 —— 既看不出哪条是新的，也没法一次清掉。
// 🔴 分组键 = **bundle + 标题 + 正文 + 本地日期(yyyy-MM-dd)**。
//    · 为什么不带 subtitle：subtitle 常常是"共 3 条"这种数，带上它同一批消息就分不到一组了；
//    · 为什么带**日期**而不是"窗口 60 秒"：用户看列表是按天划分的，
//      跨天的相同内容归到一起会让人以为"昨天的消息被今天的覆盖了"；
//      同一天里重复几次都算一组，这正好对应"我今天被这条打扰了 N 次"。
//    · 为什么不用 hash 列：库里有 `hash` 列但它是写入侧算的（口径在 tweak 里），
//      这里需要"按天"这个维度，SQL 层没有等价索引可用，内存分组更省也更可控。
// 🔴 归并**只改显示**，不改数据库、不改 `queryWithBundle:` 的 LIMIT 口径：
//    这是"只改格的长相、不碰数量契约"那条安全路（本项目 §6 第二问）。
//    但组内条数是**真的**（`nbGroupIds` 来自查询结果里的真实 rowId），
//    所以删除/标已读必须**作用于整组** —— 否则出现"删了一条、×5 变 ×4"却还是同一张卡。
// 🔴 保留哪一条：**列表第一条**（`queryWithBundle:` 已按 `ts DESC` 排 ⇒ 最新那条）。
//    组的时间/正文/已读态都取它，`id` 也用它 ⇒ 详情页点开看到的是最新那条。
- (NSArray<NSDictionary *> *)applyGroupCollapse:(NSArray<NSDictionary *> *)rows {
    if (rows.count < 2) {
        // 0 或 1 条不可能有重复组 ⇒ 原样返回（不建字典、不建 formatter，零成本）。
        // 🔴 但**仍要给每行补上 nbGroupCount=1 / nbGroupIds**：cell 那边无条件读这两个字段，
        //    漏补就是"单条行拿到 nil 当 0 处理"⇒ ×N 永远不显示（这一版就等于没做）。
        NSMutableArray *one = [NSMutableArray arrayWithCapacity:rows.count];
        for (NSDictionary *r in rows) {
            NSMutableDictionary *m = [r mutableCopy];
            m[@"nbGroupCount"] = @1;
            m[@"nbGroupIds"] = @[r[@"id"] ?: @0];
            [one addObject:m];
        }
        return one;
    }
    // 日期 formatter 只建一次（每条都建 = 滚一次列表建 2000 个 NSDateFormatter）。
    static NSDateFormatter *dayFmt = nil;
    static dispatch_once_t onceDay;
    dispatch_once(&onceDay, ^{
        dayFmt = [[NSDateFormatter alloc] init];
        // 🔴 用**本地时区**的 yyyy-MM-dd：和列表里显示的时间是同一个时区，
        //    否则用户在 UTC+8 看到的"10-31 08:00"和分组用的日期会差一天。
        dayFmt.dateFormat = @"yyyy-MM-dd";
        dayFmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });

    NSMutableArray *out = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *byKey = [NSMutableDictionary dictionary];
    for (NSDictionary *row in rows) {
        NSString *bid = row[@"bundle"];
        NSString *ttl = row[@"title"];
        NSString *msg = row[@"message"];
        NSDate *t = [NSDate dateWithTimeIntervalSince1970:[row[@"ts"] doubleValue]];
        NSString *day = t ? [dayFmt stringFromDate:t] : @"";
        // 用 \x01 当分隔符：标题/正文里可能出现任意普通字符，用 `|` 或空格都撞得上。
        NSString *key = [NSString stringWithFormat:@"%@\x01%@\x01%@\x01%@",
                         bid ?: @"", ttl ?: @"", msg ?: @"", day];
        NSMutableDictionary *head = byKey[key];
        if (!head) {
            NSMutableDictionary *m = [row mutableCopy];
            m[@"nbGroupCount"] = @1;
            m[@"nbGroupIds"] = [NSMutableArray arrayWithObject:row[@"id"] ?: @0];
            byKey[key] = m;
            [out addObject:m];                 // 顺序 = 首次出现顺序 = 最新那条在前
        } else {
            NSInteger n = [head[@"nbGroupCount"] integerValue] + 1;
            head[@"nbGroupCount"] = @(n);
            [(NSMutableArray *)head[@"nbGroupIds"] addObject:row[@"id"] ?: @0];
            // 🔴 已读/未读取「组内只要还有未读就显示未读」：反过来（取最新那条的态）
            //    会出现"组里 4 条没看、徽章说已读"—— 未读角标本来就是为了数"还没看的"。
            if ([row[@"read"] integerValue] == 0) head[@"read"] = @0;
        }
    }
    // 数组不可变对外（`nbGroupIds` 现在还是 NSMutableArray，转成不可变再交出去：
    // 后面 `didSelect` 会读它，可变数组被别处改一下就是"删错一组"）。
    for (NSMutableDictionary *m in out) {
        NSArray *ids = [m[@"nbGroupIds"] copy];
        m[@"nbGroupIds"] = ids;
    }
    return out;
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
// ================= v0.0.98：通知中心残留标记 =================

// 读一次快照（`loadData` 里调，全刷新唯一入口）。
// 🔴 三件事一起定：`aliveSnap`（判每行状态用）、`aliveScanTs`（报时刻用）、`aliveStale`（保鲜期）。
//    分成三个方法各读一次文件，就会拿到"三个不同扫描时刻"的数（本项目"分母自己会变"同款）。
// 🔴🔴 v0.0.99 换数据源：读的是**通知中心现状**（`ncSnapshot`），不再是删除台账。
//    v0.0.98 那套回答的是"上次清理时哪些还在"，只在删记录后刷新 ⇒ 用户不删就永远空白。
- (void)loadAliveSnapshot {
    [self applyAliveSnapshot:[NotifyStore ncSnapshot]];
}

// v0.0.121：把「取哪份快照」和「用这份快照」拆开。
// 🔴 为什么：`ncWaitAndReload:` 手上**已经有一份** `ncSnapshot` 了（它要用 `seq` 判归属）。
//    再调一次 `loadAliveSnapshot` 等于把 55 KB / 637 行的快照文件读+解析两遍；
//    更要紧的是——两次读之间 tweak 可能又写了一份，那样"判归属用的 seq"和
//    "真正拿来打标记的 keys"就不是同一份数据了（本项目"三个不同时刻的数"同款）。
- (void)applyAliveSnapshot:(NSDictionary *)snap {
    // 🔴 防御一行：`ncSnapshot` 自己的每条路径都返回字典，但这里是**跨文件契约**，
    //    对面以后改成一个 nil 返回值也不会崩 —— 崩在凌晨三点的推送页面上是最贵的。
    if (![snap isKindOfClass:[NSDictionary class]]) snap = @{};
    self.aliveSnap = snap;
    self.aliveScanTs = [snap[@"scan"] doubleValue];
    self.aliveNC = [snap[@"nc"] integerValue];
    // v0.0.103：界面**严格**口径。`csemn > 0` 才算量到（能读到 uuid 的条目数），
    // 否则 `aliveCS` 保持 0 但**不显示成 0 条**。
    self.aliveCSMeasurable = ([snap[@"csemn"] integerValue] > 0);
    self.aliveCS = self.aliveCSMeasurable ? [snap[@"cse"] integerValue] : 0;
    // 🔴 保鲜期判据用 `timeIntervalSince1970` 直接比，不建 NSDateFormatter：
    //    快照里的 scan 就是 epoch，转换一道只会多一个"时区搞错"的机会。
    // 🔴 v0.0.99：阈值从 1 小时收到 **10 分钟**。通知中心是**随时会变**的东西
    //    （用户手动划掉、系统自动清理都算）⇒ 拿十分钟前的结论当现状，
    //    性质和"拿删除台账当现状"是一样的。
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    self.aliveStale = (self.aliveScanTs > 0 &&
                       (now - self.aliveScanTs) > NB_NC_SNAPSHOT_FRESH_SEC);
}

// v0.0.121：这份快照和上次读到的**内容**一样吗？
// 🔴🔴 为什么不能用"扫描时刻变大"当判据：那是 v0.0.120 的做法
//    （`got > aliveScanTs + 0.5`），而 `got` 是**这一轮刚写进去的**时间戳 ⇒ **恒真**
//    ⇒ 通知中心一条都没变，也要整表 `loadData` 一遍（6~8 条 SQL + 最高 2000 行重建）。
//    「判据恒真」在本项目是熟面孔，这次它伪装成了一条性能问题。
// 🔴 剔掉两个字段：
//    ① `scan` —— 每次扫描都变，是"什么时候扫的"，不是"扫到了什么"；
//    ② `seq`  —— 每次请求都变（毫秒时间戳），同理。
//    留着它们比出来的结论永远是"变了"，这次优化就等于没做。**新增字段不用改这里** ——
//    除了这两个，字典里其余的键一律参与比较（结构性防漏，不靠谁能记得住清单）。
- (BOOL)snapshotContentChanged:(NSDictionary *)snap {
    NSDictionary *src = [snap isKindOfClass:[NSDictionary class]] ? snap : @{};
    NSMutableDictionary *now = [NSMutableDictionary dictionaryWithDictionary:src];
    [now removeObjectForKey:@"scan"];
    [now removeObjectForKey:@"seq"];
    NSDictionary *prev = self.lastSnapContent;
    self.lastSnapContent = now;
    // prev 为 nil（第一次到这个方法）⇒ `isEqual:nil` 为 NO ⇒ 返回 YES
    // ⇒ 第一轮必定走一次重刷。这是对的：那时候屏幕上还什么都没有。
    return ![now isEqual:prev];
}

// ================= v0.0.99：主动请求扫描 =================
// 🔴 为什么需要它：快照只能由 tweak 写（`uuidsToRequests` 在 SpringBoard 里）。
//    如果只在"删记录之后"才刷新，用户想看一眼现状就得先删一条 —— 那不是功能，是副作用。
// ⇒ 每次进列表 / 回前台 / 下拉刷新，都请 tweak 扫一次。
// 🔴 时序：请求是**异步**的（Darwin 通知 → tweak 主队列 → 写文件），所以不能"发完立刻读"。
//    这里发完等 `kNBScanWait` 再读一次，用 `seq` 判断"读到的是不是我这回要的那份"：
//    是 ⇒ 直接用；不是（tweak 还没写完）⇒ 再等一轮，最多两轮。
//    ⛔ 不做成"轮询到成功为止"：tweak 没在跑（比如用户只装了 App 没 respring）时
//       会永远转下去。两轮之后就用手上最旧的那份，并在提示条上如实报扫描时刻。
- (void)requestNCSnapshot {
    // 已经在等了 ⇒ 不重复发。连续滑动列表会触发很多次 loadData，
    // 每次发一遍请求等于把 tweak 主队列刷满（而每次都要遍历全部 NC request）。
    if (self.ncScanPending) return;
    self.ncScanPending = YES;
    NSString *seq = [NSString stringWithFormat:@"%.0f",
                     [[NSDate date] timeIntervalSince1970] * 1000.0];
    self.ncScanSeq = seq;
    [NotifyStore requestNCSnapshotWithSeq:seq];
    [self ncWaitAndReload:2];       // 最多两轮
}

// v0.0.121：**自动**触发的唯一出口（带节流）。
// 🔴 为什么必须有它：v0.0.121 加了第四个触发点 `onBecameActive:`，而 `DidBecomeActive`
//    还会被"来电横幅消失 / 从 App 切换器回来 / 解锁"等触发，密集时一分钟十几次
//    ⇒ 每次都让 SpringBoard 遍历全部 NC request（真机 637 条）是纯浪费。
// 🔴 三个自动触发点（`viewWillAppear:` / `onForeground:` / `onBecameActive:`）一律走这里；
//    只有用户**手动点**提示条要求「重新扫描」时才调 `requestNCSnapshot`（不许被节流挡掉 ——
//    点了不动，用户只会当成按钮坏了）。
// 🔴 节流判断放在这**一个出口**里，不散落到三个调用点：散开以后再加第五个触发点就一定会漏。
- (void)requestNCSnapshotIfDue {
    // v0.0.122：**叫醒**先记，再判节流 —— 顺序反过来就数不出"被挡掉多少次"（
    // 那正是要观察的量：真机 79 秒叫醒 12 次，如果全是节流挡的，链路其实没跑）。
    NBRefNote(NBRefKindTrigger);
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (self.lastNCSnapReqTs > 0 && (now - self.lastNCSnapReqTs) < NB_NC_SCAN_MIN_GAP) {
        NBRefNote(NBRefKindBlocked);
        return;
    }
    self.lastNCSnapReqTs = now;
    [self requestNCSnapshot];
}

// 等一轮再读。`left` = 还能等几轮。
- (void)ncWaitAndReload:(NSInteger)left {
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) self2 = ws;
        if (!self2) return;
        NSDictionary *snap = [NotifyStore ncSnapshot];
        BOOL mine = [snap[@"seq"] isEqualToString:(self2.ncScanSeq ?: @"")];
        if (!mine && left > 1) {
            [self2 ncWaitAndReload:left - 1];
            return;
        }
        self2.ncScanPending = NO;

        // ---------- ① 这一轮到底改变了什么 ----------
        // 🔴 v0.0.121：判据从「扫描时刻变大」换成「内容变了」。
        //    旧判据 `got > aliveScanTs + 0.5` 里 `got` 是**这一轮刚写的**时间戳
        //    ⇒ 只要两轮间隔超过 0.5 秒就恒真 ⇒ 通知中心一条没变也整表重查一遍。
        // 🔴 顺序不能换：`aliveStale` 必须在 `applyAliveSnapshot:` **之前**读 ——
        //    过期↔新鲜的翻转会让所有行从 Unknown 变成真标记（或反过来），
        //    那是**看得见**的变化，内容一个字没变也必须重刷列表。
        BOOL staleWas = self2.aliveStale;
        BOOL contentChanged = [self2 snapshotContentChanged:snap];
        NSTimeInterval scanNew = [snap[@"scan"] doubleValue];
        BOOL scanAdvanced = (scanNew > self2.aliveScanTs + 0.001);
        [self2 applyAliveSnapshot:snap];
        BOOL staleFlipped = (staleWas != self2.aliveStale);

        if (!contentChanged && !staleFlipped) {
            // ---------- ② 什么都没变 ----------
            // 唯一可能变的是提示条上那句"扫描于 X 前" ⇒ 只刷它。
            // 🔴 这里**不做** `reloadData`、**不跑任何 SQL** —— "没变化也重刷一遍"
            //    正是这次要消掉的那笔开销；顺手刷一下等于这次改动白做。
            if (scanAdvanced) {
                [self2 updateAliveHint];
                [self2.view setNeedsLayout];
            }
            // v0.0.122：**这条提前返回必须留痕**。它是 v0.0.121 省下来的那笔主要开销，
            //    但静默的话，"省下来"和"根本没跑"在日志上完全一样。
            NBRefNote(NBRefKindNoSnapChange);
            // v0.0.178：下拉刷新的转圈**在这里也要收**。
            // 🔴 这条 `return` 就是"什么都没变"那条路 —— 而它恰恰是最常走的一条
            //    （用户拉一下，通知中心确实没变）。漏了它 = 转圈只能靠 2.5s 看门狗收，
            //    表现是"每次都转满 2.5 秒"，看着像卡住。幂等，重复调无害。
            [self2 nbEndPullRefresh];
            return;
        }
        // ---------- ③ 通知中心真的变了 ----------
        // 库也变了 ⇒ 走完整重查（SQL + 规则 + 归并）；库没变 ⇒ 只重算残留这一层。
        // 🔴 两条都保住滚动位置：以前这里调的是**裸 `loadData`**，而"保住位置"只写在
        //    `reloadKeepingOffset` 里 ⇒ 每扫一次列表就弹回顶部，用户滑到中间看记录时
        //    正好下拉一次通知中心，回来位置就没了。
        if ([self2 dbFingerprintChanged]) {
            [self2 reloadKeepingOffset];
        } else {
            [self2 refreshItemsKeepingOffset];
        }
        // v0.0.178：下拉刷新的第二个收尾点（"通知中心真的变了"这条路）。
        // 🔴 必须排在两条刷新**之后**：转圈消失的瞬间界面应该已经是新的 ——
        //    先收转圈再刷新，用户会看到"圈没了、界面才跳"。
        [self2 nbEndPullRefresh];
    });
}

// 某一行的残留状态。**过期快照一律 Unknown**（理由见 `aliveStale` 属性注释）。
// 🔴 v0.0.117：读 `sys_id_cand`（= `新|旧` 两组候选键）而不是 `sys_id`。
//    NC 成批重投会换新 sys_id，库里那条被改写成新 ID，而快照可能写于重投之前
//    ⇒ 只比 `sys_id` 就会把"其实还在通知中心"的行判成不在（总分说还在、逐行都说不在了）。
//    候选键由 store 侧 `NBSysIdWithAlt` 拼，**与「全库残留」同一个函数**
//    ⇒ 两个指标同口径。`sys_id` 原键继续保留原义（别处还有读者）。
- (NBAliveState)aliveStateForRow:(NSDictionary *)row {
    if (self.aliveStale) return NBAliveUnknown;
    // ---------- v0.0.122：「快照没覆盖到」必须判 Unknown，不许判 Gone ----------
    // 🔴 一个**真 bug**（v0.0.121 及以前一直存在）：快照是某一瞬间的存档，而库里
    //    一直在进新记录。凡是 `ts` **晚于**快照那一刻发布的行，**结构上不可能**出现在
    //    快照里 —— 拿它去查当然是"查不到"，然后被判定成"不在通知中心了"。
    //    真机账（2026-11-02）：`窗内残留 15/418` 里那 418 行的分母就混着这类行；
    //    用户看到的现象是"刚收到的推送马上被标成已不在通知中心"，而通知还好好的躺在那里。
    // 🔴 这正是本项目那条铁律的又一次复现：**「读不到」≠「不存在」**。
    //    `aliveStateOfSysId:` 返回 Unknown 的语义是"不知道"，返回的是布尔式判断时
    //    调用方会把"不在 keys 里"当成"不在系统里" —— 两件事必须在入口处就分开。
    // 🔴 判据取 `>` 而不是 `>=`：同一秒内发布的行允许它在快照里（保存不了就不判），
    //    宁可漏判成 Gone 也不能把真在的行判成 Unknown（Unknown 会显示成"未确认"）。
    double rowTs = [row[@"ts"] doubleValue];
    if (rowTs > 0 && self.aliveScanTs > 0 && rowTs > self.aliveScanTs) return NBAliveUnknown;
    NSString *cand = row[@"sys_id_cand"];
    if (![cand isKindOfClass:[NSString class]] || cand.length == 0) cand = row[@"sys_id"];
    return [NotifyStore aliveStateOfSysId:cand inSnapshot:self.aliveSnap];
}

// 残留筛选 + `aliveStillCount` 的计算（两个量在同一个循环里出 ⇒ 天然同口径）。
// 🔴 为什么 `aliveStillCount` 要在这里算、而不是在 `ncSnapshot` 里数一遍：
//    快照里的 Still 是**全库口径**（所有删过的记录），而提示条说的是"**当前列表里**还有几条"。
//    拿全库数来讲当前列表，就会出现"提示条说 12 条、列表里只有 1 条"这种自相矛盾
//    （红点按全库算、列表按时间窗查那次的同一个错）。
- (NSArray<NSDictionary *> *)applyAliveFilter:(NSArray<NSDictionary *> *)rows {
    self.aliveStillCount = 0;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *row in rows) {
        BOOL still = ([self aliveStateForRow:row] == NBAliveStill);
        if (still) self.aliveStillCount += 1;
        // 🔴 顺序：**先计数再筛掉**。反过来的话「只看残留」模式下
        //    `aliveStillCount` 恒等于 items.count，提示条就再也说不出"别的被筛掉了多少"。
        //    （本项目在计数型判据上栽过同一形态：按条计数必须在分类判断之前累加。）
        if (self.aliveOnly && !still) continue;
        [out addObject:row];
    }
    // ---------- v0.0.100：全库口径只在必要时才算 ----------
    // 🔴 判据是"列表里一条残留都没有" —— 只有这种时候才需要回答
    //    「是盒子里真的都没有了，还是被当前筛选挡住了」。
    //    列表里已经有 ⇒ 不需要这个数，记 `-1`（没算），省掉几千行的扫描。
    // ⛔ 不许为了省事把它写成 `aliveStillCount`：那是列表口径，冒充全库就是撒谎。
    self.aliveAllCount = (self.aliveStillCount > 0)
        ? -1
        : [NotifyStore countStillInDBWithSnapshot:self.aliveSnap];
    return out;
}

// 点残留提示条 ⇒ 切「只看残留」，然后整表重查。
// 🔴 必须走 `loadData` 而不是只筛内存：切完 `aliveStillCount` 的口径会变
//    （列表本身变了），只改内存数组就是"只改账本的读数"。
- (void)onAliveHintTap {
    // ---------- 没有数据 / 已过期 ⇒ 这个点击的语义是「重新扫描」 ----------
    // 🔴 不是弹窗解释，是**真的去扫**。用户点它是想看到结果，不是想读一段说明。
    if (self.aliveScanTs <= 0 || self.aliveStale) {
        if (self.ncScanPending) return;      // 正在扫，别叠请求
        [self requestNCSnapshot];
        return;
    }
    // ---------- v0.0.100：列表里一条残留都没有 ⇒ 这个点击**不能**是「只看残留」 ----------
    // 🔴 切过去只会得到一个空列表（"只看仍在通知中心的 0 条"），用户会以为插件坏了。
    //    这个状态下点击的语义只能是「重新扫一次」。
    if (self.aliveStillCount <= 0) {
        if (self.ncScanPending) return;
        [self requestNCSnapshot];
        return;
    }
    // ---------- 有数据 ⇒ 这个点击的语义是「只看这些」 ----------
    self.aliveOnly = !self.aliveOnly;
    [self loadData];
}

// 「多久以前」的人话。`aliveScanTs <= 0` 时返回 @"—"（调用方不该在 0 时问）。
- (NSString *)aliveAgeText {
    if (self.aliveScanTs <= 0) return @"—";
    double d = [[NSDate date] timeIntervalSince1970] - self.aliveScanTs;
    if (d < 0) d = 0;
    // v0.0.104：真机提示条上写着「· 0 秒前」—— 刚扫完还报"0 秒前"读着别扭，
    // 而且 5 秒以内本来就等于"刚刚"。只改这一档，其余口径不动。
    if (d < 5) return @"刚刚";
    if (d < 90) return [NSString stringWithFormat:@"%.0f 秒", d];
    if (d < 5400) return [NSString stringWithFormat:@"%.0f 分钟", d / 60.0];
    if (d < 172800) return [NSString stringWithFormat:@"%.0f 小时", d / 3600.0];
    return [NSString stringWithFormat:@"%.0f 天", d / 86400.0];
}

// 刷新提示条（`loadData` 里调一次）。
- (void)updateAliveHint {
    // 🔴 v0.0.99：删掉了"没快照就清空标题"那条早退。
    //    它让「点这里重新扫描」这句话永远到不了 —— 而这正是 v0.0.98 用户
    //    「什么都没看到」的直接原因之一：失败路径**没有任何出口**。
    //    现在的分寸是：**不知道就说不知道，并且给一个能点的动作**。
    NSString *t = [self aliveHintText];
    [self.aliveHint setTitle:t.length ? [t stringByAppendingString:@" ›"] : nil
                    forState:UIControlStateNormal];
}

// 残留提示文案的唯一来源（`›` 由 `updateAliveHint` 加，和 foldedHint 同规矩）。
- (NSString *)aliveHintText {
    // ---------- 还没有任何扫描结果 ----------
    // 🔴 这时候必须**说出去**，不能一个字都不说。v0.0.98 的教训：快照读不到时整条提示条
    //    直接不显示，用户看到的就是"装了个新版，什么都没变" —— 而真正的原因是
    //    tweak 没扫 / 没 respring / 权限不对，全都无从判断。
    if (self.aliveScanTs <= 0) {
        return @"想看你哪些消息还在通知中心？点这里重新扫描";
    }
    // ---------- 过期 ----------
    if (self.aliveStale) {
        return [NSString stringWithFormat:@"上次扫描是 %@前（已过期，标记已关）· 点此重新扫描",
                                         [self aliveAgeText]];
    }
    // ---------- 只看这些（已开启） ----------
    if (self.aliveOnly) {
        return [NSString stringWithFormat:@"只看仍在通知中心的 %ld 条（点此看全部）",
                                         (long)self.aliveStillCount];
    }
    // ---------- 0 条 ----------
    // 🔴 文案的分寸：能说的只有"**这次扫描时**"这个时刻的事实。
    //    ⛔ 不许写「通知中心已清空」—— 那是"我没看见"冒充"系统里没有"（本项目最贵的一类断言）。
    // 🔴🔴 v0.0.100 分叉：`aliveStillCount` 是**当前列表**口径，`aliveAllCount` 才是全库。
    //    只有全库也是 0 才准说"都不在"；全库有、列表没有 ⇒ **是筛选挡的**，
    //    这时候说"都不在"就是拿局部数做全库断言（用户会照着这句话去怀疑插件坏了）。
    if (self.aliveStillCount <= 0) {
        if (self.aliveAllCount > 0) {
            // ⚠️ 这里**不点名**具体该退哪一步：时间窗 / App / 未读 / 未读筛选可能同时生效，
            //    点名一个会把用户带进死路（`hiddenHintText` 那段注释的同一条理由）。
            return [NSString stringWithFormat:
                    @"还有 %ld 条在通知中心，当前筛选把它们挡住了（扫描于 %@前）",
                    (long)self.aliveAllCount, [self aliveAgeText]];
        }
        return [NSString stringWithFormat:@"盒子里的消息都不在通知中心了（扫描于 %@前）",
                                         [self aliveAgeText]];
    }
    // ---------- 有 ----------
    // 文案三要素一次说全：**橙条含义 + 条数 + 时刻**。
    // 缺了「橙条」那句，用户看不懂列表左边那条颜色是什么（这个标记没有文字，全靠这句解释）。
    // 🔴 把「通知中心总共几条」也报出来，不是为了好看：它是**扫描真的跑通了**的唯一旁证。
    //    如果这里写着"通知中心共 0 条"，而用户明明在通知中心看到一堆 ——
    //    那就是 tweak 没扫到 / 没权限 / 没 respring，一眼就能分辨，
    //    不用再猜"是匹配不上还是根本没数据"。
    // 🔴🔴 v0.0.103：文案**必须缩短**。v0.0.102 那句
    //    「橙色竖条 = 这条还在通知中心里 · N 条（账本 637 条 · 界面 672 条 · 扫描于 1 秒前）」
    //    在真机上被**中间截断**成「… · 2… · 界面 672 条 · 扫描于 1 秒前）」——
    //    橙条数 N 和账本数**全丢了**，提示条本来要传的信息一句没传到（用户截图直接佐证）。
    //    字数是硬约束：12pt、单行、高度写死 `kNBHintH` ⇒ 按"能放下"写，不再堆形容词。
    //    「橙色竖条」缩成「橙条」：左边那条颜色就在眼前，不需要五个字去指它。
    // 🔴 口径说明（真机两轮量出来的）：
    //    账本 = `uuidsToRequests`（NC source 的**历史账本**，虚胖）；
    //    界面 = 回来的对象 uuid 必须等于问的 uuid（严格），读不到 uuid 就报「量不到」。
    NSString *scope = self.aliveCSMeasurable
        ? [NSString stringWithFormat:@"账本 %ld · 界面 %ld",
                                    (long)self.aliveNC, (long)self.aliveCS]
        : [NSString stringWithFormat:@"账本 %ld · 界面量不到", (long)self.aliveNC];
    return [NSString stringWithFormat:@"橙条 = 还在通知中心 · %ld 条（%@ · %@前）",
                                     (long)self.aliveStillCount, scope,
                                     [self aliveAgeText]];
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
    if (![self dbFingerprintChanged]) return;
    [self reloadKeepingOffset];
}

// v0.0.121：判据单独一份 —— 「库 / 关键词规则变了没变」。
// 🔴 为什么抽出来：`refreshIfChanged`（库变了 ⇒ 自己整表重查）和 `ncWaitAndReload:`
//    （决定走完整路还是轻路）问的是**同一个问题**，但动作完全不同。
//    判据写两份，迟早改了一份漏另一份，而那种走岔的表现是"某条路径下死活不刷新"、
//    "某条路径又多刷一遍"—— 都是最难查的一类。
// 🔴 这里**只判不查**：不调 `reloadKeepingOffset`，由调用方决定用哪条路。
- (BOOL)dbFingerprintChanged {
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
    // 🔴 DB 打不开时 `count` / `maxRowId` 双双回 -1，和上一次的 -1 相等 ⇒ 返回 NO，
    //    列表保持原样。这是**故意的**：打不开库的时候"刷新"只会把好数据换成空列表。
    if (total == self.lastTotal && topId == self.lastMaxId && !rulesChanged) return NO;
    self.lastRules = rulesNow;
    return YES;
}

// v0.0.38：整表重查，但保住滚动位置。
// 🔴 为什么必须有它：本项目一条硬规矩是「改完数据库必须整表重查」（内存数组永远从
//    数据库重建，只改内存 = 只改账本的读数）。而整表 reload 会把 `contentOffset`
//    清零 —— v0.0.35 的注释里已经写明"滚到中间点开一条再返回，列表跳回顶部"。
//    这段逻辑原来只写在 `didSelectRow:` 的「只看未读」分支里，现在抽出来当**唯一来源**：
//    `refreshIfChanged` 和它共用一份。
- (void)reloadKeepingOffset {
    // v0.0.122：**唯一**的「完整重查」计数点。所有走完整路的路径最终都落到这里
    // （`refreshIfChanged` / `ncWaitAndReload:` 的库变了分支 / 轻路的回落分支）
    // ⇒ 计数点选在这里，才不会出现"某条路重查了但没数到"。
    NBRefNote(NBRefKindFull);
    CGPoint off = self.table.contentOffset;
    [self loadData];
    [self clampContentOffset:off];
}

// v0.0.121：轻路 —— **库没变、只有通知中心现状变了**。
// 🔴 跳过的东西（每一样都是钱）：图标栏重建、最高 2000 行的主查询、
//    关键词规则匹配、同内容归并、`count` / `MAX(id)` / 关键词规则三条读库、
//    两次未读计数、底部「还有 N 条更早」的计数。
//    这些的输入（`filterBundle` / `since` / `search` / `unreadOnly` / 库内容）
//    在这条路上一个字都没变 ⇒ 结果必然相同，重跑纯属浪费。
// 🔴 保留的东西：重读快照 → 重算残留筛选 → 重建未读书签 → 刷列表 → 空视图 → 橙条。
//    听起来不少，但真正花钱的只有 `applyAliveFilter` 里的那次全库扫描
//    （`countStillInDBWithSnapshot:`，只在列表内一条残留都没有时才跑），
//    而完整路要跑的那 6~8 条 SQL + 2000 行重建全都省掉了。
- (void)refreshItemsKeepingOffset {
    // 🔴 没跑过完整重查就没有 `itemsBeforeAlive`（理论上不会：`viewDidLoad` 里
    //    `loadData` 先跑）。回落到完整路 —— ⛔ **不许**拿空数组顶替，
    //    那会让列表瞬间清空，用户看到的是"记录没了"。
    if (!self.itemsBeforeAlive) {
        [self reloadKeepingOffset];
        return;
    }
    // v0.0.122：计数点排在回落分支**之后** —— 回落时已经由 `reloadKeepingOffset`
    // 记成「完整」，这里再记一次就会把同一次动作数两遍（本项目「比例型分母会变」那族）。
    NBRefNote(NBRefKindLight);
    CGPoint off = self.table.contentOffset;
    [self applyItemsAndRefreshUI];
    [self clampContentOffset:off];
}

// 🔴 顺序不能换：重查 → `layoutIfNeeded` → 写回。
//    少了 `layoutIfNeeded`，`contentSize` 还是旧值，clamp 会按旧高度算 ⇒ 位置仍然错。
// 🔴 这里**保持 `off.y` 不变**是有意的：新记录插在最前面，用户会看到内容整体下移一行、
//    新行出现在原来的位置 —— 这比"位置纹丝不动、新行藏在上面要自己往上滚"更符合直觉。
- (void)clampContentOffset:(CGPoint)off {
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
    // v0.0.98：「只看残留」把列表筛空时必须解释 —— 否则用户看到"暂无记录"
    //    会以为记录丢了（它们其实都在，只是没有橙条）。
    // 🔴 这一句不能拿"0 条残留"当结论说 —— 快照过期时 `aliveStale` 会让**所有**行都是
    //    Unknown，那时"只看残留"必然是空的，而真相是"没量过"，不是"没有残留"。
    if (self.aliveOnly) {
        if (self.aliveStale) {
            [t appendFormat:@"\n\n（上次扫描已经是 %@前，本次标记全部关闭 ⇒ "
                              @"「只看残留」看不到任何行。去通知列表删掉任意一条就会重新扫描）",
                              [self aliveAgeText]];
        } else {
            [t appendString:@"\n\n（「只看残留」只显示上次清理时仍在通知中心的那几条，"
                              @"当前筛选范围里没有）"];
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
    // v0.0.98：残留维度。排在搜索之前、★ 之后 —— 和 ★ 一样，它筛的是**行本身**。
    if (self.aliveOnly) {
        [a addObject:@"只看通知中心残留"];
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
    // v0.0.178：同样是最轻一档。位置在**改状态之前**：这一下震的是"你按到了"，
    // 不是"数据已更新"—— 后者由列表内容本身说明。
    NBHapticFire(NBHapticKindSoft);
    self.unreadOnly = (seg.selectedSegmentIndex == 1);
    // v0.0.38：「全标已读」跟着这一段进出。
    // 🔴 必须 `setNeedsLayout`：分段控件的宽度在「只看未读」时要收窄
    //    （给按钮腾位置），而宽度只在 `viewDidLayoutSubviews` 里算。
    //    只改 hidden 不重布局的话，按钮会压在分段控件上。
    self.markAllBtn.hidden = !self.unreadOnly;
    [self.view setNeedsLayout];
    // v0.0.176：同理，布防排在 `loadData` 之前。段号顺序是「全部(0) → 只看未读(1)」，
    // 所以去右边那档时内容从右侧进来，回来时从左侧。
    NSInteger to = seg.selectedSegmentIndex;
    [self nbArmSlideFromIndex:self.nbPrevUnreadIdx toIndex:to];
    self.nbPrevUnreadIdx = to;
    [self loadData];
}

// v0.0.49：★ 只看标星开关。
// 🔴 走 `loadData` 整表重查，不自己过滤 `self.items` —— 和 `onUnread:` 同一条纪律：
//    内存过滤只能过滤"已经查出来的 2000 条"，而 ★ 视图的语义是"这个范围内所有标星的"。
// 🔴 不需要 `setNeedsLayout`：starBtn 常驻、分段行宽度不随 starOnly 变
//    （布局分支只认 unreadOnly）—— 提示条的出现/消失由 loadData 末尾统一触发。
- (void)onStar:(id)sender {
    // v0.0.178：★ 也是自绘按钮（`starBtn`），系统同样不送反馈。
    NBHapticFire(NBHapticKindSoft);
    self.starOnly = !self.starOnly;
    self.starBtn.selected = self.starOnly;
    // v0.0.176：★ 也是一个"整屏内容被换掉"的入口，同样走入场错落。
    [self nbArmEntrance];
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

#pragma mark - v0.0.163 按天分组

// 把 `self.items`（已按 ts DESC 排好）切成「一天一段」。
// 🔴 只做一件事：分组。**不排序、不改行、不过滤** —— 那些都在更上游，
//    这里再动一次就变成"界面上看到的顺序 ≠ 库里的顺序"，而导出/批量操作全都按 items 走。
- (void)nbRebuildDaySections {
    NSArray<NSDictionary *> *items = self.items;
    if (![items isKindOfClass:[NSArray class]] || !items.count) {
        self.sectionModels = @[];
        return;
    }

    NSCalendar *cal = [NSCalendar currentCalendar];
    NSLocale *cn = [NSLocale localeWithLocaleIdentifier:@"zh_Hans_CN"];
    NSDateFormatter *fmtMD = [[NSDateFormatter alloc] init];
    fmtMD.locale = cn;
    fmtMD.dateFormat = @"M月d日";
    NSDateFormatter *fmtYMD = [[NSDateFormatter alloc] init];
    fmtYMD.locale = cn;
    fmtYMD.dateFormat = @"yyyy年M月d日";

    NSDate *today = [cal startOfDayForDate:[NSDate date]];
    NSDate *yesterday = [cal dateByAddingUnit:NSCalendarUnitDay value:-1
                                       toDate:today options:0];

    NSMutableArray<NSDictionary *> *models = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *buf = [NSMutableArray array];
    __block NSDate *curDay = nil;

    void (^flush)(void) = ^{
        if (!buf.count || !curDay) return;
        NSString *title;
        if ([cal isDate:curDay inSameDayAsDate:today]) {
            title = @"今天";
        } else if ([cal isDate:curDay inSameDayAsDate:yesterday]) {
            title = @"昨天";
        } else if ([cal component:NSCalendarUnitYear fromDate:curDay] ==
                   [cal component:NSCalendarUnitYear fromDate:today]) {
            title = [fmtMD stringFromDate:curDay];
        } else {
            title = [fmtYMD stringFromDate:curDay];   // 跨年必须带年份，否则"1月3日"分不清哪年
        }
        // 🔴 `[buf copy]` 是必须的：不 copy 的话下一次 removeAllObjects 会把已经存进
        //    models 的那一份也清空 ⇒ 所有分组都变成空数组（而 numberOfSections 仍然 > 0）。
        [models addObject:@{@"title": title, @"items": [buf copy]}];
        [buf removeAllObjects];
    };

    for (NSDictionary *d in items) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSDate *dt = [NSDate dateWithTimeIntervalSince1970:[d[@"ts"] doubleValue]];
        NSDate *day = [cal startOfDayForDate:dt];
        if (!curDay || ![cal isDate:day inSameDayAsDate:curDay]) {
            flush();
            curDay = day;
        }
        [buf addObject:d];
    }
    flush();

    self.sectionModels = models;
}

// 唯一的「按 indexPath 取行」入口。任何地方都不许再写 `self.items[...row]`。
- (NSDictionary *)nbItemAtIndexPath:(NSIndexPath *)ip {
    if (!ip) return nil;
    if (ip.section < 0 || ip.section >= (NSInteger)self.sectionModels.count) return nil;
    NSArray *rows = self.sectionModels[ip.section][@"items"];
    if (![rows isKindOfClass:[NSArray class]]) return nil;
    if (ip.row < 0 || ip.row >= (NSInteger)rows.count) return nil;
    id d = rows[ip.row];
    return [d isKindOfClass:[NSDictionary class]] ? (NSDictionary *)d : nil;
}

#pragma mark - v0.0.164 双列总览网格

// 从 `self.items` 聚合出「每个 App 几条 + 最新那条是什么」，交给网格去画。
//
// 🔴 聚合**只在这里做一次**，网格那边不许再算（`OverviewGridView.h` 顶部写了理由）。
//
// 🔴🔴 条数必须是 `nbGroupCount` 之和，**不是行数**：
//    v0.0.95 起同内容同日的行会归并成一条（列表上显示 ×N）。若按行数数，
//    一个发了 8 条同款营销的 App 在网格上会显示「1 条」—— 而列表里那一行明明写着 ×8。
//    两个数摆在同一个屏幕上互相解释，差一条用户就会开始怀疑整个界面。
//
// 🔴 为什么**不**在卡片上显示未读数：见方法体里那一段（口径会打架）。
- (void)nbRebuildOverview {
    if (!self.table) return;

    NSArray<NSDictionary *> *items = self.items;
    if (![items isKindOfClass:[NSArray class]]) items = @[];

    // 已经筛到某个 App ⇒ 撤掉总览。
    // 🔴 理由不是"不好看"，而是它此刻**没有信息量**：只剩那一个 App 的一张卡，
    //    却要占掉列表上方近 200pt。回到「全部」时它自己会回来。
    if (self.filterBundle.length || items.count == 0) {
        if (self.table.tableHeaderView) self.table.tableHeaderView = nil;
        return;
    }

    // ---- 按 App 聚合。`self.items` 是 ts DESC ⇒ 首次出现的那个 App 天然排在最前 ----
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *agg = [NSMutableDictionary dictionary];
    NSInteger totalCount = 0;

    for (NSDictionary *d in items) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSString *bid = d[@"bundle"];
        if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;

        // 归并一定会补这个键（`applyGroupCollapse` 两条分支都写了）；真缺了按 1 算 ——
        // 🔴 绝不按 0 算：一个 App 明明有一条通知，网格上写「0 条」比不显示更糟。
        NSInteger n = [d[@"nbGroupCount"] integerValue];
        if (n <= 0) n = 1;
        totalCount += n;

        NSMutableDictionary *a = agg[bid];
        if (!a) {
            a = [NSMutableDictionary dictionary];
            a[@"total"] = @0;
            a[@"head"] = d;          // 该 App 最新的一条（用来取摘要和时间）
            agg[bid] = a;
            [order addObject:bid];   // 顺序 = 首次出现顺序 = 最新在前
        }
        a[@"total"] = @([a[@"total"] integerValue] + n);
    }

    // 只有一个 App 时不画网格：一张卡片的"网格"没有意义，而列表第一行已经把它说完了。
    if (order.count < 2) {
        if (self.table.tableHeaderView) self.table.tableHeaderView = nil;
        return;
    }

    // ---- 时间文案。🔴 口径和列表 cell 那一套**故意保持不同**，但必须能对得上：
    //      网格只给"什么时候"，所以今天给 HH:mm、昨天给"昨天"、更早给 M/d。
    //      卡片只有 36pt 宽放时间，写完整的 "MM-dd HH:mm" 会被截成 "11-0…"（等于没写）。
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *today = [cal startOfDayForDate:[NSDate date]];
    NSDate *yest = [cal dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:today options:0];

    static NSDateFormatter *fmtHM = nil;
    static NSDateFormatter *fmtMD = nil;
    static dispatch_once_t onceOv;
    dispatch_once(&onceOv, ^{
        fmtHM = [[NSDateFormatter alloc] init];
        fmtHM.locale = [NSLocale localeWithLocaleIdentifier:@"zh_Hans_CN"];
        fmtHM.dateFormat = @"HH:mm";
        fmtMD = [[NSDateFormatter alloc] init];
        fmtMD.locale = [NSLocale localeWithLocaleIdentifier:@"zh_Hans_CN"];
        fmtMD.dateFormat = @"M/d";
    });

    NSInteger maxCards = [NBOverviewGridView maxCards];
    NSInteger want = (NSInteger)order.count;
    if (want > maxCards) want = maxCards;

    NSMutableArray<NBOverviewCard *> *cards = [NSMutableArray arrayWithCapacity:(NSUInteger)want];
    for (NSInteger i = 0; i < want; i++) {
        NSString *bid = order[(NSUInteger)i];
        NSDictionary *a = agg[bid];
        NSDictionary *head = a[@"head"];
        if (![head isKindOfClass:[NSDictionary class]]) continue;

        NBOverviewCard *c = [[NBOverviewCard alloc] init];
        c.bundleId = bid;
        c.name = [self appNameForBundle:bid];
        c.total = [a[@"total"] integerValue];

        // 摘要优先级：正文 → 副标题 → 标题。
        // 🔴 为什么最后才用 `title`：很多 App 的 title 就是它自己的名字（"微信"），
        //    拿来当摘要等于把一个字都没多说。
        NSString *line = head[@"message"];
        if (![line isKindOfClass:[NSString class]] || !line.length) line = head[@"subtitle"];
        if (![line isKindOfClass:[NSString class]] || !line.length) line = head[@"title"];
        c.line = [line isKindOfClass:[NSString class]] ? line : @"";

        NSDate *dt = [NSDate dateWithTimeIntervalSince1970:[head[@"ts"] doubleValue]];
        if (!dt) {
            c.timeText = @"";
        } else if ([cal isDate:dt inSameDayAsDate:today]) {
            c.timeText = [fmtHM stringFromDate:dt];
        } else if ([cal isDate:dt inSameDayAsDate:yest]) {
            c.timeText = @"昨天";
        } else {
            c.timeText = [fmtMD stringFromDate:dt];
        }

        // 🔴 未读**故意不放进来**：本类的 `hasUnread` 那种东西一旦加上，就会出现
        //    "网格说 1 条未读、书签说 3 条"——因为网格按 `nbGroupCount` 数条数，
        //    而 `nbUnreadByBundle` 是按**行**数的（折叠组只算 1）。两个数写的不是一回事。
        //    未读本来已经有更合适的出口：紧挨在网格上方的图标栏红点。这里不重复，也不打架。
        [cards addObject:c];
    }

    if (cards.count < 2) {
        if (self.table.tableHeaderView) self.table.tableHeaderView = nil;
        return;
    }

    // ---- 组装视图 ----
    // 🔴 宽度兜底：首屏时 `loadData` 可能早于 `viewDidLayoutSubviews`，此时 table 的宽度是 0。
    //    传 0 进去的话网格会按 0 宽排版（卡片压成一条线）。三级兜底和 `updateMoreFooter` 同款。
    CGFloat w = self.table.bounds.size.width;
    if (w <= 0) w = self.view.bounds.size.width;
    if (w <= 0) w = [UIScreen mainScreen].bounds.size.width;

    CGFloat h = [NBOverviewGridView heightForCardCount:cards.count];

    if (!self.overviewGrid) {
        self.overviewGrid = [[NBOverviewGridView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
        // 🔴 weak：网格被 `tableHeaderView` 强持有（table 又被 self.view 持有），
        //    这里再强捕 self 就是一条 self → table → header → block → self 的环，
        //    整个 ViewController 永远不会释放。
        __weak typeof(self) wself = self;
        self.overviewGrid.onSelectBundle = ^(NSString *bid) {
            [wself nbOverviewSelectBundle:bid];
        };
    }
    self.overviewGrid.frame = CGRectMake(0, 0, w, h);
    self.overviewGrid.totalApps = (NSInteger)order.count;
    self.overviewGrid.totalCount = totalCount;
    [self.overviewGrid setCards:cards];

    // 🔴 **高度变了才重新赋值**。每次刷新都赋一遍的话，UITableView 会重算
    //    contentSize 并夹一次 contentOffset —— 症状是"列表每 15 秒自己往上跳一下"。
    //    高度只由卡片数决定（`heightForCardCount:`），卡片数只随 App 数变化，
    //    所以"没变就不赋"是安全的。宽度变化走 `viewDidLayoutSubviews` 里的那一处。
    CGFloat oldH = self.table.tableHeaderView ? self.table.tableHeaderView.frame.size.height : -1;
    if (!self.table.tableHeaderView || oldH < h - 0.5 || oldH > h + 0.5) {
        self.table.tableHeaderView = self.overviewGrid;
    }
}

// 点总览里的某张卡片。
// 🔴 它和 `onIcon:` 是**同一件事**（设 `filterBundle` + `loadData`），
//    不是另一条过滤路径。两条路各写一份过滤逻辑，迟早有一处漏掉 `searchBundles` 之类。
- (void)nbOverviewSelectBundle:(NSString *)bid {
    if (!bid.length) return;
    if (self.filterBundle.length && [self.filterBundle isEqualToString:bid]) return;

    // v0.0.178：和 `onIcon:` 同一个反馈（这两条本来就是同一件事，见下面注释）。
    // 🔴 位置在两道闸门**之后**：点自己当前的 App 什么都没发生时，不该震
    //    —— "震了但屏幕上没变化"会被读成"点了但坏了"。
    NBHapticFire(NBHapticKindSoft);
    self.filterBundle = bid;
    // v0.0.176：和 `onIcon:` 一样 —— 换筛选 = 整屏内容被换掉 ⇒ 入场错落。
    [self nbArmEntrance];
    [self loadData];

    // 换筛选后列表要回到顶部 —— 否则用户点的是"抖音 11 条"，
    // 却停在原来滚到一半的位置，看到的可能是空列表（他会以为没记录）。
    if ([self.table numberOfSections] > 0 &&
        [self.table numberOfRowsInSection:0] > 0) {
        [self.table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]
                          atScrollPosition:UITableViewScrollPositionTop
                                  animated:NO];
    }
}

#pragma mark - v0.0.176 动效布防

// 入场错落：整屏重建后 0.30s 内进入屏幕的行，按行号错开淡入上浮。
- (void)nbArmEntrance {
    self.nbEntranceUntil = CFAbsoluteTimeGetCurrent() + 0.30;
}

// 筛选横滑：告诉列表"内容整体从哪一侧进来"。
- (void)nbArmSlideFromIndex:(NSInteger)from toIndex:(NSInteger)to {
    // 换到更靠后的那一档 ⇒ 内容从右侧进来；换回前面 ⇒ 从左侧。
    // 🔴 `to == from` 时**必须显式置 0**：不清的话上一次的方向会留在属性里，
    //    于是下一次由别的原因（点图标筛 App、清空搜索框）触发的 loadData
    //    会莫名其妙地带上一次的方向滑一下 —— 而那次根本没有"换档"这回事。
    if (to > from)      self.nbSlideDX = 26.0;
    else if (to < from) self.nbSlideDX = -26.0;
    else                self.nbSlideDX = 0.0;
    self.nbSlideUntil = CFAbsoluteTimeGetCurrent() + 0.30;
}

#pragma mark - v0.0.178 下拉刷新

// 用户下拉松手 ⇒ 这里。**只做两件事**：整表重查 + 请 tweak 重扫通知中心。
//
// 🔴 为什么不用 `refreshIfChanged`：见 viewDidLoad 里挂控件那段注释 ——
//    它带指纹闸门，库没变就什么都不做，用户会以为下拉坏了。
// 🔴 为什么刷新请求排在重查**之前**：`requestNCSnapshot` 是异步的
//    （Darwin 通知 → tweak 主队列 → 写文件 → 本 App 等 0.45s 再读），
//    先发出去能把它跟本地重查**并行**掉；排在后面等于白等一截。
// 🔴 为什么它**不走** `requestNCSnapshotIfDue`：那个出口带节流，专治
//    "回前台太频繁"。下拉是用户**明确点的**，被节流挡掉的话
//    "我拉了但残留标记没变"——和"按钮坏了"分不开（v0.0.121 的既定纪律）。
- (void)nbOnPullRefresh:(UIRefreshControl *)rc {
    // 🔴 重入闸门：连拉两下时第二次直接忽略。否则会有两个等待轮次同时在跑，
    //    先回来的把转圈收掉 ⇒ "转圈莫名提前消失"，而且看着像刷了两遍。
    if (self.nbPullBusy) return;
    self.nbPullBusy = YES;
    self.nbPullBeginAt = CFAbsoluteTimeGetCurrent();
    NBHapticFire(NBHapticKindSoft);

    [self requestNCSnapshot];
    [self reloadKeepingOffset];

    // 🔴 **看门狗**：转圈不能只靠 `ncWaitAndReload:` 收尾。
    //    两条路会让它永远不回调 ——
    //      ① tweak 没在跑（只装了 App 没 respring、或 SpringBoard 的 dylib 没注入）；
    //      ② `ncScanPending` 已经是 YES（自动扫描正在等），此时 `requestNCSnapshot`
    //         第一句就 return，**不会**起新的等待轮次。
    //    没有这个兜底，屏幕上就是"一直转圈"，用户只能杀掉 App —— 比"刷新不了"糟得多。
    //    ⚠️ 这是"熔断标记必须带超时"那条纪律的具体样子：闸门是 `nbPullBusy`，
    //       而解除它的条件**不能**依赖"上次成功返回"（失败恰恰不返回）。
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [ws nbEndPullRefresh];
    });
}

// 收尾：**幂等**，从任何地方调都安全（`ncWaitAndReload:` 的两个出口 + 看门狗）。
- (void)nbEndPullRefresh {
    if (!self.nbPullBusy) return;
    // 🔴 最短可见时长 0.55s。为什么需要它：正常路径上 `ncWaitAndReload:` 至少等 0.45s，
    //    但"自动扫描刚好在等"那条路上可能 50ms 就回来了 ⇒ 转圈一闪而过，
    //    看起来像"下拉没反应"（本项目那条"提示语与判定必须同源"的同类问题：
    //    界面上的反馈短到看不见，等于没有）。
    // 🔴 递归调用是**有界**的：left 单调减到 ≤0 时走下面的收尾分支，最多再延一次。
    NSTimeInterval left = 0.55 - (CFAbsoluteTimeGetCurrent() - self.nbPullBeginAt);
    if (left > 0.02) {
        __weak typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(left * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [ws nbEndPullRefresh];
        });
        return;
    }
    self.nbPullBusy = NO;
    [self.nbRefresh endRefreshing];
}

#pragma mark - UITableView
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sectionModels.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sectionModels.count) return 0;
    NSArray *rows = self.sectionModels[section][@"items"];
    return [rows isKindOfClass:[NSArray class]] ? rows.count : 0;
}

// 日期标题。plain 样式下 section header **天然吸顶**，滚动时当前日期一直挂在顶上。
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sectionModels.count) return nil;
    id t = self.sectionModels[section][@"title"];
    return [t isKindOfClass:[NSString class]] ? (NSString *)t : nil;
}

// v0.0.176：列表动效的**唯一执行点**。
//
// 🔴 为什么放在 `willDisplayCell:` 而不是 `cellForRow:`：`cellForRow` 只负责"配内容"，
//    它被调用时 cell 往往还没被加到窗口上；而 `willDisplayCell` 是"它就要上屏了",
//    此刻设初始值再动画，第一帧就已经是初始状态，看不到"先闪一下正常状态再跳回去"。
//
// ⚠️ 两个已知边界，都是有意接受而不是没想到：
//   ① 动画期间如果整表重载（比如 0.2s 内连点两次筛选），前一次的动画会被
//      `reloadData` 打断 —— 但**不会留下错值**：终态（identity / alpha 1）在动画
//      开始那一刻就已经写进 model 了，被打断只是"没看清"，不是"停在中途"。
//   ② `row < 16` 是第二道闸：万一将来有人把窗口调大，也不至于让一屏几十行一起播。
- (void)tableView:(UITableView *)tableView
  willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    // 复用池里回来的 cell 身上可能还挂着上一条的 transform / alpha —— 先归零。
    // 🔴 这一步**必须无条件做**，不能只在"要播动画"时做：不播动画的那些行
    //    正需要它来擦掉残留。
    cell.transform = CGAffineTransformIdentity;
    cell.alpha = 1.0;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL sliding  = (self.nbSlideDX != 0.0) && (now < self.nbSlideUntil);
    BOOL entrance = (!sliding) && (now < self.nbEntranceUntil) && (indexPath.row < 16);
    if (!sliding && !entrance) return;

    CGFloat dx = sliding ? self.nbSlideDX : 0.0;
    CGFloat dy = entrance ? 12.0 : 0.0;
    // 错落节奏：每行 35ms，最多累计 0.20s。再长就会有人觉得"卡"。
    NSTimeInterval delay = entrance ? MIN(indexPath.row * 0.035, 0.20) : 0.0;

    cell.transform = CGAffineTransformMakeTranslation(dx, dy);
    cell.alpha = 0.0;
    [UIView animateWithDuration:0.24
                          delay:delay
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        cell.transform = CGAffineTransformIdentity;
        cell.alpha = 1.0;
    } completion:nil];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NotifyCell *c = [tableView dequeueReusableCellWithIdentifier:@"c" forIndexPath:indexPath];
    NSDictionary *d = [self nbItemAtIndexPath:indexPath];
    if (!d) {
        // 行数与分组同源，正常到不了这里。真到了就交一张空卡，绝不让后面的取值链炸掉。
        return c;
    }
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
    // v0.0.88：每条卡片按 App **品牌色淡染**（颜色从图标主色算出来，见 AppIconLoader）。
    // 🔴 必须排在 `setIcon:` / `setUnread:` **之前**：这个 setter 会顺手把未读角标底色
    //    也刷一遍，调晚了角标会先按默认蓝画一次再被刷掉（角标闪一下颜色）。
    [c setBrandColor:[AppIconLoader brandColorForBundle:bid]];
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
    // v0.0.95：这一组压了几条（<2 ⇒ 徽章不占位，见 NotifyCell.h）。
    [c setGroupCount:[d[@"nbGroupCount"] integerValue]];
    // v0.0.98：通知中心残留橙条。**必须无条件调**（传 0 也要调）——
    // 它是 cell 的"默认可见装饰"里唯一一个由外部决定显隐的，
    // 漏调一次就是"上一条的橙条留在这一行上"（复用池串味的经典形态）。
    [c setAliveTag:[self aliveStateForRow:d]];

    // v0.0.176：整 App 静音态（卡片压暗 + 左缘琥珀竖条）。
    // 🔴 **必须无条件调**（静音时传 YES、没静音时也要传 NO）——
    //    和 `setAliveTag:` 完全同一条纪律：它是由外部决定的"默认外观"，
    //    漏调一次就是"上一条的暗卡片 + 竖条留在这一行上"（复用池串味的经典形态，
    //    而且症状极具误导性：用户会以为静音串到别的 App 上去了）。
    // 🔴 判据直接问 `NotifyFilter`，**不在这里另写一份静音表判断** ——
    //    tweak 那边丢弃通知用的是同一个函数。两边各写一份的话，
    //    "界面显示已静音但通知照弹"（或反过来）就成了没法查的双真值。
    [c nbSetMutedLook:[NotifyFilter shouldDropForMute:(bid.length ? bid : @"")
                                                  now:nil
                                               reason:NULL
                                              problem:NULL]
             animated:NO];

    // ---------- v0.0.92：左滑删除的两个回调（自绘，见 NotifyCell.h） ----------
    // 🔴 捕获 **rowId**：不捕获 indexPath（滚动/删除后就失效），也不捕获字典快照
    //    （删库后整表重查，快照就是旧对象）。rowId 是库里的事实，删错的可能性最小。
    // 🔴 `weakCell` 必须 weak：cell 持有 block、block 再强引用 cell ⇒ 循环引用，
    //    整个列表的 cell 一个都释放不掉。
    NSInteger rowId = [d[@"id"] integerValue];
    // v0.0.95：这一行可能代表一组（×N）⇒ 删除必须作用于**整组**，
    // 否则删一条之后 ×5 变 ×4、卡片还在原地（用户以为删除没生效，会连按五次）。
    // 🔴 捕获**数组快照**而不是捕获字典：items 每次 loadData 都重建，字典是旧对象。
    NSArray<NSNumber *> *groupIds = [d[@"nbGroupIds"] isKindOfClass:[NSArray class]]
                                  ? d[@"nbGroupIds"] : @[@(rowId)];
    __weak typeof(self) weakSelf = self;
    __weak NotifyCell *weakCell = c;
    c.nbOnDelete = ^{ [weakSelf nbDeleteRowIds:groupIds]; };
    c.nbOnSwipeBegin = ^{ [weakSelf nbCloseOtherSwipesExcept:weakCell]; };
    // ---------- v0.0.124：右滑蓝块 = 翻转**整组**的已读态 ----------
    // 🔴 捕获 `groupIds`（整组 id 快照）而不是单条：×N 归并的行代表一组，
    //    只翻一条会出现"组里一条变已读、其余 read 还是 0"，卡片状态自相矛盾。
    // 🔴 方向按**cellForRow 那一刻**的状态算，⛔ 不在动作执行时现读：
    //    蓝块的文案也是这一刻定的（`setUnread:` 里刷），两者必须同源。
    //    执行时现读的话，在"滑开之后列表被刷新"的场景里会翻错方向 ——
    //    用户看到按钮写着「标已读」，按下去却变成了未读。
    BOOL rowIsUnread = ([d[@"read"] integerValue] == 0);
    c.nbOnToggleRead = ^{
        // 当前未读 ⇒ 这次要标成已读（YES）；当前已读 ⇒ 标成未读（NO）。
        // 🔴 写成显式的 `makeRead` 而不是直接把 rowIsUnread 传进去：
        //    那个写法数值上恰好对，但每个读到它的人都要在脑子里验算一遍
        //    "传的是当前状态还是目标状态" —— 这类"碰巧对"的代码下次改动必翻车。
        BOOL makeRead = rowIsUnread;
        [weakSelf nbSetRead:makeRead forRowIds:groupIds];
    };
    // ---------- v0.0.118：长按菜单 ----------
    // 🔴 每次 cellForRow 都重设一次（cell 会复用）：菜单里的 App 名 / 动作必须跟着**当前这一行**，
    //    留着上一次的就会"长按 A 行、菜单里写着 B 的 App 名"。
    // 🔴 捕获的是 rowId 那一组的**数组快照**（和删除同一个理由），不是 indexPath。
    c.nbMenuBuilder = ^UIMenu *{
        return [weakSelf nbMenuForRow:d];
    };
    // ---------- v0.0.186：VoiceOver 的四个动作入口 ----------
    // 🔴 删除 / 翻已读用的是上面那两个就绪的 block（`nbOnDelete` / `nbOnToggleRead`），
    //    这里只补"复制 / 打开"两个 —— 它们需要完整正文、bundle 和深链，cell 拿不到。
    // 🔴 同样每次 cellForRow 重设：cell 会复用，留着上一行的就是"按复制拿到别人的正文"。
    c.nbOnCopy = ^{ [weakSelf nbCopyRowText:d]; };
    c.nbOnOpen = ^{ [weakSelf nbOpenRowInApp:d]; };
    return c;
}

// v0.0.92：滚动一开始就把打开的那行收起。
// 🔴 不收起的话，一边滚一边有一行歪在左边、右边露着红块，滚回来它还在 ——
//    用户会以为"这一行的渲染坏了"，其实只是状态没清。
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self nbCloseOtherSwipesExcept:nil];
}

// 关掉除 `keep` 以外的左滑。`keep == nil` ⇒ 全关。
- (void)nbCloseOtherSwipesExcept:(NotifyCell *)keep {
    NotifyCell *cur = self.nbOpenCell;
    if (cur && cur != keep) [cur nbCloseSwipeAnimated:YES];
    self.nbOpenCell = keep;
}

// ================= v0.0.124：已读态的**唯一执行入口** =================
// 两个入口共用：① 点击卡片（标已读，随后进详情）；② 右滑蓝块（按当前状态翻转）。
// 🔴 为什么必须抽出来：这一套有三段（写库 → 改内存 → 重建派生量 + 刷行），
//    原来内联在 `didSelectRow` 里。右滑若照抄一份，就是"两处各自看都对、改一处必漏一处"
//    —— 本项目 v0.0.41 已经买过一次教训：红点跟着变了、顶部提示条没变。
// 🔴 `ids` 是**整组**的 rowId（×N 归并后的那行代表一组）：只改一条会出现
//    "组里一条变成已读、其余 read 还是 0"，卡片状态自相矛盾。
// 🔴 参数里**没有 indexPath**，行号由 `nbIndexPathForRowId:` 现查。cell 的 block 拿到的是
//    滑动那一刻的 rowId，而列表随时会变（搜索/筛选/删除/整表重查）——
//    捕获 indexPath 就是"改错行"的定时炸弹（和 `nbOnDelete` 同一条纪律）。
- (void)nbSetRead:(BOOL)read forRowIds:(NSArray<NSNumber *> *)ids {
    if (![ids isKindOfClass:[NSArray class]] || ids.count == 0) return;

    // ① 先写库。「库是事实、内存是它的投影」——这条顺序不能反。
    for (NSNumber *rid in ids) {
        if (![rid isKindOfClass:[NSNumber class]]) continue;
        if ([rid integerValue] > 0) [NotifyStore setRead:read rowId:[rid integerValue]];
    }

    // ② 「只看未读」模式下**数量会变**（标成已读的那条要从列表里消失）
    //    ⇒ 必须整表重查；`reloadRowsAtIndexPaths:` 要求内存下标与行严格对应，数量一变就错位。
    if (self.unreadOnly) {
        [self reloadKeepingOffset];
        return;
    }

    // ③ 普通模式：数量不变 ⇒ 只改内存 + 刷受影响的那几行
    NSIndexPath *ip = [self nbIndexPathForRowId:[ids[0] integerValue]];
    if (!ip) {
        // 这一行已经不在当前列表里了（被筛选掉 / 上一次 loadData 之后没了）。
        // ⛔ 不许"尽力而为"地猜一个下标去改内存 —— 那改的是别的行。
        [self loadData];
        return;
    }
    NSDictionary *row = [self nbItemAtIndexPath:ip];
    if (![row isKindOfClass:[NSMutableDictionary class]]) {
        [self loadData];          // 兜底：万一哪天 query 改成返回不可变字典
        return;
    }
    [(NSMutableDictionary *)row setObject:@(read ? 1 : 0) forKey:@"read"];
    // 未读计数必须在这里手动重建（这一步不重查库），否则整屏书签停在改动之前的数
    [self rebuildBundleUnread];
    // 🔴 书签上的数是**该 App** 的未读条数 ⇒ 同一个 App 的**其它可见行**也得一起刷，
    //    否则改掉一条之后，屏幕上同 App 的另外几张卡片还写着旧数。
    //    仍然用 `reloadRows` 而不是整表 `reloadData`：**数量没变**，滚动位置不动
    //    （"数量变不变"才是这个 API 的判据，见删除场景）。
    NSString *bid = row[@"bundle"];
    NSMutableArray<NSIndexPath *> *paths = [NSMutableArray arrayWithObject:ip];
    for (NSIndexPath *other in [self.table indexPathsForVisibleRows]) {
        // 🔴 v0.0.163：原来是 `other.section != ip.section` —— 分组之前只有一个 section，
        //    这句恒假等于没写；分组之后它会**把其它天的同 App 行全部跳过**，
        //    结果就是"改了已读，隔壁那天同 App 的卡片还写着旧未读数"。
        //    正确判据只有一条：跳过自己。
        if (other.section == ip.section && other.row == ip.row) continue;
        NSDictionary *od = [self nbItemAtIndexPath:other];
        if (!od) continue;
        NSString *o = od[@"bundle"];
        if (bid.length && [o isEqualToString:bid]) [paths addObject:other];
    }
    [self.table reloadRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationNone];
    // 🔴 红点**和顶部提示条**一起重算：这一行变了已读，影响的是**两个**派生量
    //    （该 App 的未读数、以及"筛选之外还有多少"）。
    [self refreshUnreadDerived];
}

// 按 rowId 现查行号。找不到 ⇒ nil（调用方据此走"整表重查"这条安全路）。
// 🔴 线性扫一遍 items 是**故意的**：列表长度 = 当前筛选下的条数（几十到几百），
//    而这里只在用户点一下 / 滑一下时调一次。相比之下"捕获 indexPath 再校验它还有效"
//    需要的判据更多、也更容易漏（本项目删错行那几版全是这个形态）。
- (NSIndexPath *)nbIndexPathForRowId:(NSInteger)rowId {
    if (rowId <= 0) return nil;
    // 🔴 v0.0.163：分组之后"第几行"不再等于"全表第几条" ⇒ 必须**逐段**扫，
    //    返回的 indexPath 要带上真正的 section。仍返回 `inSection:0` 的话，
    //    点一天里靠后的那条会去改**另一天**的同一行号（改错行、且界面上看不出来）。
    for (NSInteger s = 0; s < (NSInteger)self.sectionModels.count; s++) {
        NSArray *rows = self.sectionModels[s][@"items"];
        if (![rows isKindOfClass:[NSArray class]]) continue;
        for (NSInteger i = 0; i < (NSInteger)rows.count; i++) {
            NSDictionary *r = rows[i];
            if (![r isKindOfClass:[NSDictionary class]]) continue;
            if ([r[@"id"] integerValue] == rowId) {
                return [NSIndexPath indexPathForRow:i inSection:s];
            }
        }
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    // 🔴 v0.0.92：左滑打开状态下点这一行 = **先收起，不进详情**。
    //    这是系统列表的既定行为，也是必须做的：不然"左滑露出删除"和"点一下进详情"
    //    会同时发生 —— 用户想点删除，手一抖点在卡片上，就跳到详情页去了。
    NotifyCell *swCell = (NotifyCell *)[tableView cellForRowAtIndexPath:indexPath];
    if ([swCell isKindOfClass:[NotifyCell class]] && swCell.nbIsSwiped) {
        [swCell nbCloseSwipeAnimated:YES];
        // animated:NO —— 这一下点击是"用来收起的"，不该再叠一个取消选中的动画
        [tableView deselectRowAtIndexPath:indexPath animated:NO];
        [self nbCloseOtherSwipesExcept:nil];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // v0.0.178：进详情页前先把键盘收掉。
    // 🔴 不收会怎样：搜索框是**常驻**的，用户搜完直接点一条 ⇒ 键盘跟着 push 到详情页上，
    //    挡住正文下半部分，而详情页里没有任何东西能把它收回去（那里没有输入框）。
    //    用户唯一的出路是返回列表再滚一下 —— 这就是"点进去看不全"。
    // ⚠️ 只在这个"真要进详情"的分支里收：上面那个"点一下收起左滑"的分支不该动键盘
    //    （用户只是想把滑出来的按钮收回去，没收搜索的意思）。
    if (self.searchBar.isFirstResponder) [self.searchBar resignFirstResponder];
    NSDictionary *d = [self nbItemAtIndexPath:indexPath];
    // v0.0.95：这一行可能是 ×N 的组 ⇒ 点开就等于"整组都看过了"，
    // 否则会出现"点开过、卡片还是未读"（组内其它几条的 read 全是 0）。
    NSArray<NSNumber *> *gids = [d[@"nbGroupIds"] isKindOfClass:[NSArray class]]
                              ? d[@"nbGroupIds"] : @[d[@"id"] ?: @0];
    // v0.0.124：标已读 + 改内存 + 重建派生量 + 刷行的整套动作，抽到 `nbSetRead:forRowIds:`，
    // 和右滑蓝块的「翻转」共用**同一份实现**（原来这一段是内联在这里的）。
    // 🔴 抽方法不是为了好看：右滑若照抄一份，就成了两处各自看都对、改一处必漏一处
    //    —— v0.0.41 已经买过一次教训（红点跟着变了、顶部提示条没变）。
    // 🔴 三段顺序一个字都没挪：先写库（`nbSetRead:` 的第一段），再改内存，再刷新派生量。
    [self nbSetRead:YES forRowIds:gids];

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
// 🔴 v0.0.92：触发方式改成**自绘**（见 NotifyCell.h 顶部注释）——
//    系统 `trailingSwipeActionsConfigurationForRowAtIndexPath:` 会把整个 cell
//    （含 contentView）一起左移，而图标就挂在 contentView 上 ⇒ 图标必然跟着走，
//    做不到「卡片动、图标原地缩小渐隐」。系统那个红块还是直角、铺满整行高。
// 🔴🔴 但**删除链路一个字都没改**，改的只是"谁来触发"：
//    仍然刻意**不用** `deleteRowsAtIndexPaths:` —— 它要求"内存数组与即将删的行严格同步"，
//    而我们删的是数据库。正确顺序是「先删库 → 整表重查」，让两边从同一个来源重建。
//    只改内存 = 只改账本的读数（数量契约第 2 问）：症状是删完那一行还在，
//    或者删了 A 却少了一条 B（搜索/筛选态下标错位）。
// 🔴 参数是 **rowId** 不是 indexPath：删除会改数量 ⇒ 内存下标立刻全体错位（v0.0.33 栽过）；
//    rowId 是库里的事实，滚动、筛选、复用都不会让它指向别人。
- (void)nbDeleteRowId:(NSInteger)rowId {
    [self nbDeleteRowIds:(rowId > 0 ? @[@(rowId)] : @[])];
}

// v0.0.95：一组一起删（×N 那一行）。`nbDeleteRowId:` 保留 —— 详情页还有单条删的入口。
// 🔴 一次开库删 N 行（`NotifyStore deleteRows:`），不是循环调 `deleteRow:`：
//    后者每行都要 `openDB`（跑一遍 CREATE TABLE IF NOT EXISTS + busy_timeout），
//    一组 5 条就是 5 次开库，而这个库**两个进程在写**（见 NotifyStore.m 的 SQLITE_BUSY 注释）。
// 🔴 返回的 outcome 取**最严重的那一种**（详见方法体），不能让"最后一条恰好成功"
//    把前面几条的"没有 sysId / 同步关"盖掉 —— 那就变成"删了但界面没说清为什么通知中心没变"。
// ================= v0.0.118：长按菜单 =================
// 菜单里放什么，**只由这里决定**（cell 只管"长按了 ⇒ 问你"）。
// 当前两项：
//   ① 打开「App 名」—— 这条通知是哪个 App 弹的就跳到哪个 App；
//   ② 复制内容 —— 把标题/正文/副标题拼起来放剪贴板（和详情页同一套拼法）。
// 🔴 为什么**故意不做**「删除」：左滑已经是删除，多一个入口就多一条"两处提示口径"
//    要维护；而且删除失败时会 present alert，正好撞上"菜单正在收起"那一刻
//    ⇒ 那个 alert 会被系统静默丢掉，用户看到的是"点了没反应"。少一个入口少一类坑。
- (UIMenu *)nbMenuForRow:(NSDictionary *)row {
    if (![row isKindOfClass:[NSDictionary class]]) return nil;

    NSString *bid  = row[@"bundle"];
    NSString *name = [self appNameForBundle:bid];
    // 🔴 标题里带上 App 名：列表里同一个 App 可能有好几张卡，
    //    光写「打开」用户不知道会跳到哪儿去。名字取不到时退回裸「打开」，不能留空标题。
    // 🔴 v0.0.133：这条记录若能从 payload 里认出深链，标题就明说「直达…内容」——
    //    用户点之前就该知道"是会跳到那条内容，还是只把 App 拉起来"。
    //    认不出时**一字不改**（退回原「打开」），所以老记录的行为完全不变。
    NSString *link = [AppLauncher deeplinkFromPayload:row[@"payload"]];
    NSString *openTitle;
    if (link.length) {
        openTitle = name.length
                  ? [NSString stringWithFormat:@"直达「%@」内容", name]
                  : @"直达内容页";
    } else {
        openTitle = name.length
                  ? [NSString stringWithFormat:@"打开「%@」", name]
                  : @"打开";
    }

    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *acts = [NSMutableArray arrayWithCapacity:4];

    UIAction *openAct = [UIAction actionWithTitle:openTitle
                                            image:[UIImage systemImageNamed:(link.length ? @"link" : @"arrow.up.forward.app")]
                                       identifier:nil
                                          handler:^(__kindof UIAction *a) {
        [weakSelf nbOpenRowInApp:row];
    }];
    [acts addObject:openAct];

    UIAction *copyAct = [UIAction actionWithTitle:@"复制内容"
                                            image:[UIImage systemImageNamed:@"doc.on.doc"]
                                       identifier:nil
                                          handler:^(__kindof UIAction *a) {
        [weakSelf nbCopyRowText:row];
    }];
    [acts addObject:copyAct];

    // ================= v0.0.186：已读切换 + 删除 =================
    // 🔴 为什么这两项以前不在菜单里（v0.0.118 起一直没有）⇒ 它们只有滑动入口：
    //    右滑翻已读、左滑删除。对 VoiceOver 用户等于**不存在**（横滑被系统拿去浏览了），
    //    对其他用户也是"长按一条想删掉它"这个最自然的动作落空。
    // 🔴 动作实现**不新写**：直接调滑动那条路用的同一批方法
    //    （`nbSetRead:forRowIds:` / `nbDeleteRowIds:`）——
    //    两个入口一个实现，才不会出现"左滑删得掉、长按删不掉"这种分叉。
    // 🔴 作用范围 = `nbGroupIds`（×N 那一行代表一组），和左滑删除同口径：
    //    只删一条会出现"删了一条、×5 变 ×4、卡片还在原地"。
    NSArray<NSNumber *> *menuIds = [row[@"nbGroupIds"] isKindOfClass:[NSArray class]]
                                 ? row[@"nbGroupIds"] : nil;
    if (!menuIds.count) {
        NSInteger one = [row[@"id"] integerValue];
        menuIds = (one > 0) ? @[@(one)] : @[];
    }
    BOOL menuRowUnread = ([row[@"read"] integerValue] == 0);
    if (menuIds.count) {
        UIAction *readAct = [UIAction actionWithTitle:(menuRowUnread ? @"标为已读" : @"标为未读")
                                                image:[UIImage systemImageNamed:
                                                       (menuRowUnread ? @"envelope.open" : @"envelope.badge")]
                                           identifier:nil
                                              handler:^(__kindof UIAction *a) {
            // 方向按**拼菜单那一刻**的 `read` 算，⛔ 不在执行时现读 ——
            // 否则"菜单还开着的时候列表被刷新了"会让标题说标已读、实际标成未读
            // （和 `nbOnToggleRead` 那条注释同一个理由）。
            [weakSelf nbSetRead:menuRowUnread forRowIds:menuIds];
        }];
        [acts addObject:readAct];

        UIAction *delAct = [UIAction actionWithTitle:@"删除"
                                               image:[UIImage systemImageNamed:@"trash"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *a) {
            [weakSelf nbDeleteRowIds:menuIds];
        }];
        // 红色。⚠️ 长按菜单不另加确认框：左滑删除也没有确认，
        //    同一个动作在两处口径必须一样（要加就两处一起加，那是另一版的事）。
        delAct.attributes = UIMenuElementAttributesDestructive;
        [acts addObject:delAct];
    }

    // ================= v0.0.166：正文提取 =================
    // 🔴 只有**真的抽到东西**才加这两项。抽不到还摆一个点了没反应的动作，
    //    用户会以为功能坏了（"永远不触发的功能比没做更糟"）。
    NSString *body = [self nbBodyTextForRow:row];

    NSString *linkStr = [NBTextExtract firstLinkInText:body];
    if (linkStr.length) {
        // 标题里带域名：用户点之前就知道会被带到哪儿去。
        // 🔴 域名过长时退回裸标题 —— 菜单标题被截成"打开链接 · mp.weixi…"反而更难读。
        NSURL *lu = [NSURL URLWithString:linkStr];
        NSString *host = lu.host;
        NSString *title = (host.length && host.length <= 22)
                        ? [NSString stringWithFormat:@"打开链接 · %@", host]
                        : @"打开链接";
        UIAction *linkAct = [UIAction actionWithTitle:title
                                                image:[UIImage systemImageNamed:@"link"]
                                           identifier:nil
                                              handler:^(__kindof UIAction *a) {
            [weakSelf nbOpenExternalLink:linkStr];
        }];
        [acts addObject:linkAct];
    }

    NSString *code = [NBTextExtract verificationCodeInText:body];
    if (code.length) {
        // 🔴 把码**印在标题里**：这样点之前就能确认抽对了没有。
        //    只写「复制验证码」的话，抽错的代价是用户粘贴时才发现。
        UIAction *codeAct = [UIAction actionWithTitle:[NSString stringWithFormat:@"复制验证码 %@", code]
                                                image:[UIImage systemImageNamed:@"number.square"]
                                           identifier:nil
                                              handler:^(__kindof UIAction *a) {
            UIPasteboard.generalPasteboard.string = code;
            [weakSelf nbToast:[NSString stringWithFormat:@"已复制 %@", code]];
        }];
        [acts addObject:codeAct];
    }

    // ================= v0.0.168：临时静音 =================
    // 与「稍后提醒」是两件事，别混（🔴 后者已在 v0.0.175 整个删除）：
    //   稍后提醒 = 过 N 分钟**再响一次**（要本地通知权限 ⇒ 越狱 App 拿不到，下线）
    //   临时静音 = 从现在起 N 小时**不弹这个 App**（记录照旧，不需要任何权限）
    // 🔴 当前已静音时，**第一项不是"再静音一次"而是"现在到什么时候"** ——
    //    不然用户点开菜单看不出自己之前静过、还剩多久，只能靠回忆。
    //    那一项设成 disabled：它是状态显示，不是动作（摆一个点了没反应的动作更糟）。
    NSString *muteBid = [row[@"bundle"] isKindOfClass:[NSString class]]
                      ? (NSString *)row[@"bundle"] : @"";
    NSString *curMute = nil;
    BOOL muted = [NotifyFilter shouldDropForMute:muteBid now:nil reason:&curMute problem:NULL];

    NSMutableArray<UIMenuElement *> *muteActs = [NSMutableArray arrayWithCapacity:5];
    if (muted) {
        UIAction *info = [UIAction actionWithTitle:[NSString stringWithFormat:@"当前：%@",
                                                    curMute ?: @"静音中"]
                                             image:[UIImage systemImageNamed:@"info.circle"]
                                        identifier:nil
                                           handler:^(__kindof UIAction *a) { }];
        info.attributes = UIMenuElementAttributesDisabled;
        [muteActs addObject:info];
    }
    for (NSInteger k = NBMuteKind1Hour; k <= NBMuteKindTomorrow9; k++) {
        NBMuteKind kind = (NBMuteKind)k;
        UIAction *a = [UIAction actionWithTitle:[NotifyFilter menuTitleForMuteKind:kind]
                                         image:nil
                                    identifier:nil
                                       handler:^(__kindof UIAction *act) {
            [weakSelf nbMuteRow:row kind:kind];
        }];
        [muteActs addObject:a];
    }
    if (muted) {
        UIAction *off = [UIAction actionWithTitle:@"取消静音"
                                            image:[UIImage systemImageNamed:@"bell"]
                                       identifier:nil
                                          handler:^(__kindof UIAction *act) {
            [weakSelf nbUnmuteRow:row];
        }];
        off.attributes = UIMenuElementAttributesDestructive;
        [muteActs addObject:off];
    }
    [acts addObject:[UIMenu menuWithTitle:@"临时静音"
                                    image:[UIImage systemImageNamed:@"bell.slash"]
                               identifier:nil
                                  options:0
                                 children:muteActs]];

    return [UIMenu menuWithTitle:@"" children:acts];
}

// ================= v0.0.186：菜单与无障碍动作共用的实现 =================
// 🔴 这两个方法原来分别是菜单里的一段内联 block（v0.0.118 起）。v0.0.186 给
//    VoiceOver 加了 `accessibilityCustomActions`，同一件事有了第二个入口
//    ⇒ 抽成方法：**两个入口、一份实现**。
//    ⛔ 否则迟早出现"长按复制出来的是全文、无障碍复制出来的是截断版"这种分叉。
- (void)nbCopyRowText:(NSDictionary *)row {
    if (![row isKindOfClass:[NSDictionary class]]) return;
    NSString *body = [self nbBodyTextForRow:row];
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = body.length ? body : @"（这条通知没有内容）";
    [self nbToast:@"已复制"];
}

- (void)nbOpenRowInApp:(NSDictionary *)row {
    if (![row isKindOfClass:[NSDictionary class]]) return;
    id bv = row[@"bundle"];
    NSString *bid = [bv isKindOfClass:[NSString class]] ? (NSString *)bv : nil;
    if (!bid.length) {
        // 🔴 没有 bundle 就明说，⛔ 不许静默返回：按了没反应会被当成"功能坏了"。
        //    和长按菜单里"抽不到链接就不加那一项"不同 —— 那一项是**入口**不该出现，
        //    而这里是入口已经存在、必须解释为什么不动作。
        NBHapticFire(NBHapticKindWarning);
        [self nbToast:@"这条没有 bundle id，没法打开 App"];
        return;
    }
    NSString *link = [AppLauncher deeplinkFromPayload:row[@"payload"]];
    // 🔴 不走 present：这个动作在菜单收起 / VoiceOver 动作回调的瞬间执行，
    //    present 会被系统静默丢掉（v0.0.118 那条注释，这里同样成立）。
    [self nbOpenAppWithBundle:bid deeplink:link];
}

// ================= v0.0.168：临时静音的写入 =================
//
// 🔴 v0.0.187：这一段从"菜单专用的实现"变成了**全工程唯一的静音写入核心**。
//    两个入口共用它：记录页长按菜单（`nbMuteRow:kind:`）和统计页行内行动
//    （`nbApplyMuteOneHourForBundle:message:`，由容器调）。
//    ⛔ 不许任何一侧再写一份 —— 下面这几条纪律抄一遍必然丢一条。
//
// 它做三件事，顺序不能换：
//   ① 用 `activeMutesAt:` **重建**整张表（它顺手把过期项、坏值清掉）；
//   ② 加本 App 那一条并落盘；
//   ③ **回读校验**：再问一次"这个 App 现在真的静音了吗"。
//   ③ 不能省。`writeToFile:` 返回 YES 只证明"文件写进去了"，
//   不证明"判定侧认这一条"（超上限那条路就是写成功但判定不生效）。
//   本项目在「保存成功但功能没生效」上已经付过学费（v0.0.32 开关白名单）。
//
// 🔴 重建表而不是在旧字典上改：旧字典里可能有 `"abc"` 这种读不出的到期值。
//   在旧值上改会把它原样带进新表，而 `activeMutesAt:` 会把它剔掉 —— 顺手修好。
//   代价是：坏条目会被**静默丢弃**。可以接受，因为坏条目本来就是"没生效"的状态。
//
// 🔴 `outMessage` 给出的是**已经拼好的整句人话**（成功/失败都有），调用方直接弹。
//    这样"菜单里那句"和"统计页那句"不可能各说各的（同一件事只有一个说法）。
//    成功文案要带 App 名，而名字只有本类拿得到（`appNameForBundle:`）⇒
//    ⛔ 这个核心不能挪进 NotifyFilter 那种"App 与 dylib 都编"的文件里。
- (BOOL)nbWriteMuteForBundle:(NSString *)bid kind:(NBMuteKind)kind message:(NSString **)outMessage {
    if (!bid.length) {
        if (outMessage) *outMessage = @"这条没有 bundle id，没法按 App 静音";
        return NO;
    }
    NSString *name = [self appNameForBundle:bid];
    NSString *who = name.length ? name : bid;

    NSMutableDictionary *tbl = [NSMutableDictionary dictionary];
    for (NSDictionary *e in [NotifyFilter activeMutesAt:nil]) {
        NSString *b = e[@"bundle"];
        if ([b isKindOfClass:[NSString class]]) tbl[b] = e[@"until"];
    }
    // 🔴 到顶就拒绝新的（不淘汰旧的）：静音是个位数级的手动操作，到顶说明写坏了；
    //    此时"少静音一个、并说出来"比"悄悄挤掉一个你不知道的"安全。
    if (!tbl[bid] && tbl.count >= NB_MUTE_MAX_ENTRIES) {
        if (outMessage) {
            *outMessage = [NSString stringWithFormat:
                           @"静音条目已经 %d 条，先取消几个再试", NB_MUTE_MAX_ENTRIES];
        }
        return NO;
    }

    NSTimeInterval until = [[NotifyFilter endDateForMuteKind:kind now:nil] timeIntervalSince1970];
    tbl[bid] = @(until);

    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[NotifyStore settings]];
    d[NB_KEY_MUTE_UNTIL] = tbl;
    BOOL saved = [NotifyStore saveSettings:d];

    // ③ 回读：问的是"判定侧认不认"，不是"我写没写"。
    // 🔴 必须查**精确那一条**在不在，不能只用 `shouldDropForMute:bid` ——
    //    那个函数找不到精确条目时会退到通配 "*"，如果恰好有全局静音，
    //    一次**失败的写入**也会被判成成功（"命中率 100% 但收到的全是自己已有的字段"那种假绿）。
    BOOL exact = NO;
    for (NSDictionary *e in [NotifyFilter activeMutesAt:nil]) {
        if ([e[@"bundle"] isEqualToString:bid]) { exact = YES; break; }
    }
    NSString *why = nil;
    BOOL ok = saved && exact
           && [NotifyFilter shouldDropForMute:bid now:nil reason:&why problem:NULL];
    if (!ok) {
        if (outMessage) {
            *outMessage = [NSString stringWithFormat:@"静音没有生效（%@）",
                           saved ? @"写进去了但判定侧不认，看日志 MUTE-BAD#" : @"写盘失败"];
        }
        return NO;
    }
    if (outMessage) {
        *outMessage = [NSString stringWithFormat:@"%@ 已静音 · %@", who, why ?: @""];
    }
    return YES;
}

// 记录页长按菜单的入口。现在只负责"取 bundle + 反馈"，写入与回读全在上面那个核心里。
// 🔴 成功触觉与熄灯动画都必须排在**回读结果**之后 —— 写盘失败也震"成功"、
//    也画一遍熄灯的话，用户读到的就是"已经静音了"，而实际通知照弹
//    （本项目最贵的那类假读数：界面在说假话）。判据 I3 机械守着这个先后。
- (void)nbMuteRow:(NSDictionary *)row kind:(NBMuteKind)kind {
    if (![row isKindOfClass:[NSDictionary class]]) return;

    id bv = row[@"bundle"];
    NSString *bid = [bv isKindOfClass:[NSString class]] ? (NSString *)bv : nil;

    NSString *msg = nil;
    BOOL ok = [self nbWriteMuteForBundle:bid kind:kind message:&msg];
    // v0.0.178：失败震 Warning 一档，和成功**不同档**。
    // 🔴 为什么失败要震：静音是"看起来生效了但可能没生效"的典型 ——
    //    卡片暗了、可通知照弹。只靠一句 toast 的话，手指按下去没有任何差别，
    //    用户会以为成功了。⚠️ Warning ≠ 通用错误音：只给"你以为成了、其实没成"这种场合。
    NBHapticFire(ok ? NBHapticKindSuccess : NBHapticKindWarning);
    [self nbToast:msg];
    if (!ok) return;

    // v0.0.176：熄铃。写在**回读校验通过之后** —— 动画表示"生效了"。
    [self nbAnimateMuteLookForBundle:bid muted:YES];
}

// ================= v0.0.187：「加入不记录」名单的写入 =================
//
// 🔴 和静音同一个形状（重建 → 落盘 → 回读），但回读问的是**另一个判定函数**
//    `shouldSkipRecordForBundle:` —— 那才是 tweak 侧真正决定"落不落库"的同一份代码。
//    拿 `shouldDropBundle:` 去验就成了"问 AB 证明 CD"。
//
// 🔴 名单的读法必须走 `NBStringArray()`：这个键历史上被写成过数组，也可能被手工写成
//    "a,b" 逗号串。`NBStringArray` 两种都认；自己写 `[d[key] isKindOfClass:]` 只认一种，
//    另一种会让"名单里明明有、判定却说没有"。
//
// 🔴 已存在的记录**不受影响**：这个键只拦"以后要不要落库"，不删历史。
//    文案必须把这一点说出来，否则用户以为点了就等于清空。
- (BOOL)nbWriteSkipRecordForBundle:(NSString *)bid message:(NSString **)outMessage {
    if (!bid.length) {
        if (outMessage) *outMessage = @"这条没有 bundle id，没法加进「不记录」";
        return NO;
    }
    NSString *name = [self appNameForBundle:bid];
    NSString *who = name.length ? name : bid;

    NSDictionary *before = [NotifyStore settings];
    NSArray<NSString *> *oldList = NBStringArray(before[NB_KEY_NO_RECORD_APPS]);
    if ([oldList containsObject:bid]) {
        // 已经在了。这不是失败 —— 判定侧现在就是"不记录"，说清楚就行
        //（⛔ 别假装又加了一次：那会让人以为名单里有两份）。
        if (outMessage) {
            *outMessage = [NSString stringWithFormat:@"%@ 本来就在「不记录」名单里", who];
        }
        return [NotifyFilter shouldSkipRecordForBundle:bid];
    }

    NSMutableArray<NSString *> *arr = [NSMutableArray arrayWithArray:oldList];
    [arr addObject:bid];
    // 排序后再存：同一组选择每次写出来的文件都一样，方便对拍
    // （和 AppPickerViewController 的 persist 用同一套口径）。
    NSArray *sorted = [arr sortedArrayUsingSelector:@selector(compare:)];

    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:before];
    d[NB_KEY_NO_RECORD_APPS] = sorted;
    BOOL saved = [NotifyStore saveSettings:d];

    // 回读两层，缺一不可：
    //   ① 键里真的有这个 bundle —— 证明写进去了、而且写的是**名单**而不是别的东西；
    //   ② 判定侧认 —— 证明 tweak 读这份设置时也会跳过它。
    // 🔴 只做①是"我写的我读回来"（自证）；只做②会被别的来源蒙对
    //    （比如黑白名单恰好也命中同一个 App）。两层一起才算证完。
    NSDictionary *after = [NotifyStore settings];
    BOOL exact = [NBStringArray(after[NB_KEY_NO_RECORD_APPS]) containsObject:bid];
    BOOL judge = [NotifyFilter shouldSkipRecordForBundle:bid];
    if (!saved || !exact || !judge) {
        if (outMessage) {
            *outMessage = [NSString stringWithFormat:@"没加成（%@）",
                           !saved ? @"写盘失败"
                                  : (!exact ? @"写进去了但名单里读不到"
                                            : @"名单里有、判定侧不认，看日志")];
        }
        return NO;
    }
    if (outMessage) {
        *outMessage = [NSString stringWithFormat:@"%@ 以后不再记录 · 已有记录保留", who];
    }
    return YES;
}

// v0.0.176：把某个 App 的静音态动画铺到**所有可见行**上。
// 🔴 为什么不是"只动刚点的那一行"：静音是按 App 的，同屏可能有 5 行属于它。
//    只亮一行的话，用户滚一下就会看到另外 4 行还是亮的，第一反应是"静音没生效"。
// 🔴 用 `cellForRowAtIndexPath:` 取 cell（而不是自己遍历可见 cell 的 subviews 猜类别）：
//    它是唯一"行 → cell"的官方映射，猜出来的东西在分组/复用时会对错行。
- (void)nbAnimateMuteLookForBundle:(NSString *)bid muted:(BOOL)muted {
    if (!bid.length) return;
    for (NSIndexPath *ip in [self.table indexPathsForVisibleRows]) {
        NSDictionary *d = [self nbItemAtIndexPath:ip];
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        id b = d[@"bundle"];
        if (![b isKindOfClass:[NSString class]] || ![b isEqualToString:bid]) continue;
        UITableViewCell *cell = [self.table cellForRowAtIndexPath:ip];
        if ([cell isKindOfClass:[NotifyCell class]]) {
            [(NotifyCell *)cell nbSetMutedLook:muted animated:YES];
        }
    }
}

// 取消静音。只删本 App 那一条 —— 但 `"*"`（全部 App）若还在生效，它照旧静音，
// 所以这里**必须把话说清**，否则用户会以为"点了取消却还在静音 = 功能坏了"。
- (void)nbUnmuteRow:(NSDictionary *)row {
    if (![row isKindOfClass:[NSDictionary class]]) return;

    id bv = row[@"bundle"];
    NSString *bid = [bv isKindOfClass:[NSString class]] ? (NSString *)bv : nil;
    if (!bid.length) { [self nbToast:@"这条没有 bundle id"]; return; }

    NSMutableDictionary *tbl = [NSMutableDictionary dictionary];
    for (NSDictionary *e in [NotifyFilter activeMutesAt:nil]) {
        NSString *b = e[@"bundle"];
        if ([b isKindOfClass:[NSString class]] && ![b isEqualToString:bid]) {
            tbl[b] = e[@"until"];
        }
    }

    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[NotifyStore settings]];
    if (tbl.count) d[NB_KEY_MUTE_UNTIL] = tbl;
    else [d removeObjectForKey:NB_KEY_MUTE_UNTIL];
    BOOL saved = [NotifyStore saveSettings:d];

    // 回读：本 App **那一条**必须真的没了。
    // 🔴 判据必须是"精确条目在不在"，不能用 `shouldDropForMute:bid` ——
    //    那个函数查不到精确条目会退到通配 "*"，于是"精确条目已删、全局静音还在"这个
    //    **成功**状态会被判成失败，弹出"取消没生效"。（我第一版就是这么写的。）
    BOOL exactStill = NO;
    for (NSDictionary *e in [NotifyFilter activeMutesAt:nil]) {
        if ([e[@"bundle"] isEqualToString:bid]) { exactStill = YES; break; }
    }
    if (!saved || exactStill) {
        NBHapticFire(NBHapticKindWarning);
        [self nbToast:saved ? @"取消没生效：条目还在，看日志 MUTE-BAD#"
                            : @"取消没生效：写盘失败"];
        return;
    }
    // 本 App 的没了、但全局静音还在 —— 这是最容易误判成"取消失败"的状态，必须点名。
    NSString *why = nil;
    if ([NotifyFilter shouldDropForMute:@"*" now:nil reason:&why problem:NULL]) {
        // v0.0.178：这一支也要 Warning —— 用户在弹菜单里点的是"取消静音"，
        // 看到的 toast 却写着"全局静音仍在"。不震一下成果音的话，手指那一下
        // 和"完全成功"没有任何区别，而它们**不是**同一个结果。
        NBHapticFire(NBHapticKindWarning);
        [self nbToast:[NSString stringWithFormat:@"已取消本 App · 但全局静音仍在（%@）", why ?: @""]];
        // v0.0.176：**故意不撤熄灯效果** —— 全局静音还在，这些行确实还被压着，
        // 界面跟着"变亮"就是画面在说假话。判据和 tweak 丢弃通知用的是同一个函数。
        return;
    }
    NBHapticFire(NBHapticKindSuccess);
    [self nbToast:@"已取消静音"];
    // v0.0.176：亮灯。同样排在回读校验之后（没真删掉就不许装作亮起来了）。
    [self nbAnimateMuteLookForBundle:bid muted:NO];
}

// ================= v0.0.187：统计页行内行动的公开入口 =================
//
// 🔴 这两个方法**不弹提示、不震触觉**：调用方是容器（`NBHomeTabBarController`），
//    因为它才知道该把提示贴在哪个 view 上（记录页那一刻在另一个页签、不可见）。
//    ⛔ 别在这里补一句 toast —— 贴在记录页上的提示用户根本看不到，
//    而"看不到提示"和"点了没反应"在用户眼里是同一件事。
//
// 🔴 固定「1 小时」这一档，不给三档菜单：统计页是"顺手治一下"的地方，
//    先让用户做三选一等于把决策成本加回来。真要 8 小时 / 到明早，
//    记录页长按菜单里那三档一直都在（同一套核心，口径不会分岔）。

- (BOOL)nbApplyMuteOneHourForBundle:(NSString *)bundle message:(NSString **)outMessage {
    BOOL ok = [self nbWriteMuteForBundle:bundle kind:NBMuteKind1Hour message:outMessage];
    if (!ok) return NO;

    // 🔴 成功了必须让列表**重算一遍静音长相**。
    //    `reloadData` 会重跑 cellForRow，而那里 `nbSetMutedLook:` 的入参
    //    正是 `shouldDropForMute:` 的结果（同一个判定函数）。
    //    ⛔ 别只调 `nbAnimateMuteLookForBundle:`：它只动**当前可见**的 cell，
    //       而记录页此刻在另一个页签 ⇒ 可见集合可能是空的，
    //       用户切回去看到的还是"没静音"的样子（界面在说假话）。
    [self nbAnimateMuteLookForBundle:bundle muted:YES];
    [self.table reloadData];
    return YES;
}

- (BOOL)nbApplySkipRecordForBundle:(NSString *)bundle message:(NSString **)outMessage {
    // 不刷新列表：这个动作只影响"以后落不落库"，屏幕上已有的记录一条都不变
    //（文案里那句"已有记录保留"说的就是这件事，界面和行为必须一致）。
    return [self nbWriteSkipRecordForBundle:bundle message:outMessage];
}

// 标题 / 正文 / 副标题按顺序拼，空的跳过。
- (NSString *)nbBodyTextForRow:(NSDictionary *)row {
    if (![row isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:3];
    for (NSString *key in @[@"title", @"message", @"subtitle"]) {
        id v = row[key];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) {
            [parts addObject:(NSString *)v];
        }
    }
    return parts.count ? [parts componentsJoinedByString:@"\n"] : nil;
}

- (void)nbOpenExternalLink:(NSString *)link {
    NSURL *u = [NSURL URLWithString:link];
    if (!u || !u.scheme.length) {
        [self nbToast:@"这个链接打不开"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[UIApplication sharedApplication] openURL:u options:@{}
                             completionHandler:^(BOOL ok) {
        if (ok) return;
        // 失败要在主线程说话（回调不保证在主线程）。
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf nbToast:@"这个链接打不开"];
        });
    }];
}

- (void)nbOpenAppWithBundle:(NSString *)bundleId {
    [self nbOpenAppWithBundle:bundleId deeplink:nil];
}

- (void)nbOpenAppWithBundle:(NSString *)bundleId deeplink:(NSString *)deeplink {
    NBOpenAppResult r = [AppLauncher openBundle:bundleId deeplink:deeplink];
    NSString *text = [AppLauncher textForResult:r];
    // 成功时 `text` 是 nil ⇒ 静默（App 已经切到前台，那本身就是反馈）。
    if (!text.length) return;
    [self nbToast:text];
}

// 浮层提示。**实现已搬到 app/NBToast.m**（v0.0.187）——
// 🔴 为什么搬：v0.0.187 的「统计页行内行动」是在统计页点下去、写入却落在记录页，
//    而记录页那一刻在另一个页签、根本不可见 ⇒ 提示必须能贴到**容器**的 view 上。
//    留在这里的话别的文件调不到（私有方法），只能复制一份 —— 两份必走岔。
// 这里保留一个同名私有入口，纯粹是为了让本文件里那二十几处调用点一个字都不用改。
- (void)nbToast:(NSString *)text {
    NBShowToast(self.view, text);
}

- (void)nbDeleteRowIds:(NSArray<NSNumber *> *)rowIds {
    if (!rowIds.count) return;
    NBSyncClearOutcome outc = NBSyncClearDeleteFail;
    NSInteger okCount = 0;
    BOOL anyFail = NO;
    BOOL anyNoSysId = NO;
    BOOL anyOff = NO;
    for (NSNumber *n in rowIds) {
        NBSyncClearOutcome one = NBSyncClearDeleteFail;
        BOOL ok = ([n integerValue] > 0) && [NotifyStore deleteRow:[n integerValue] outcome:&one];
        if (!ok) { anyFail = YES; continue; }
        okCount++;
        if (one == NBSyncClearNoSysId) anyNoSysId = YES;
        else if (one == NBSyncClearOff) anyOff = YES;
    }
    if (anyNoSysId)      outc = NBSyncClearNoSysId;   // 最该说的先说
    else if (anyOff)     outc = NBSyncClearOff;
    else if (anyFail)    outc = NBSyncClearDeleteFail;

    // 先重查（数据源变了）—— 顺序反了会"删完还留着"。
    [self loadData];
    if (rowIds.count > 1) {
        // 整组删除只在**没删干净**时出声。全部删掉就静默（用户看到卡片消失就是反馈，
        // 多弹一个框反而吵 —— 这组可能是他连着删的第 5 组）。
        if (anyFail) {
            [self alertTitle:@"有一部分没删掉"
                        text:[NSString stringWithFormat:@"这一组 %lu 条，删掉了 %ld 条；"
                              @"剩下的可能已经被「记录上限」自动清掉了。列表已刷新。",
                              (unsigned long)rowIds.count, (long)okCount]];
        } else if (anyNoSysId) {
            [self alertTitle:@"通知中心可能不会全变"
                        text:@"这组里有记录没有系统通知 ID，无法定位通知中心里的那一条，"
                              "所以只删掉了盒子里的记录。"];
        }
        return;
    }
    if (!okCount) {
        // 删不到也要说：最常见的原因是 tweak 按「记录上限」把它裁掉了，
        // 而列表还显示着。静默失败会让人以为删除按钮坏了。
        [self alertTitle:@"没删掉"
                    text:@"这条记录已经不在了（可能被「记录上限」自动清掉了）。列表已刷新。"];
    } else if (outc == NBSyncClearNoSysId) {
        // 🔴 v0.0.84：这是「有些能删、有些不行」最常见的那一半 ——
        //    记录里没有 sys_id，删它**没有任何东西可匹配**，通知中心当然纹丝不动。
        //    以前这里是静默的，用户只会说"删了没反应"。
        // 🔴 v0.0.85 改口径：上一版这里写「（是旧版本记下的）」，那是**没量过的断言**——
        //    用户明确说「有些**刚推送**的也会这样」（`nc_diag(24).txt`）。
        //    所以只陈述事实（没有 ID、因此定位不到），不猜原因。
        [self alertTitle:@"通知中心不会变"
                    text:@"这条记录没有系统通知 ID，无法定位通知中心里的那一条，"
                          "所以只能删掉盒子里的记录。"];
    } else if (outc == NBSyncClearOff) {
        [self alertTitle:@"已删除（未同步通知中心）"
                    text:@"设置里「删除时同步清通知中心」是关的。"
                          "打开后删记录才会把通知中心里那一条也一起清掉。"];
    }
}

@end
