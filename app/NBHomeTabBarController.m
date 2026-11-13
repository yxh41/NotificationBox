//
//  NBHomeTabBarController.m
//  NotificationBox
//

#import "NBHomeTabBarController.h"
#import "ViewController.h"
#import "NotifyStatsViewController.h"
#import "NBHaptic.h"
// v0.0.187：提示要贴在**容器**上。动作是从统计页发起的，而写入发生在记录页 ——
// 记录页那一刻在另一个页签、不可见，提示贴在那上面等于什么都没提示。
#import "NBToast.h"

// 私有声明。🔴 必须写在 `@implementation` 之前：`viewDidLoad` 里那个 block 会调它，
//    而方法体在文件后面 —— 不声明的话 clang 报
//    "instance method not found（返回类型默认成 id）"，一旦哪天开 -Werror 就是编译错误。
//    本项目已经在 `%new` 方法上踩过三次同类（"忘了顶部声明"）。
@interface NBHomeTabBarController ()
- (void)handleStatsAppAction:(NBStatAppAction)action forBundle:(NSString *)bundle;
- (nullable ViewController *)nbRecordsRoot;
@end

@implementation NBHomeTabBarController

- (void)viewDidLoad {
    [super viewDidLoad];

    // ---------- 页签 1：记录 ----------
    ViewController *records = [[ViewController alloc] init];
    UINavigationController *recordsNav =
        [[UINavigationController alloc] initWithRootViewController:records];
    recordsNav.tabBarItem =
        [[UITabBarItem alloc] initWithTitle:@"记录"
                                      image:[UIImage systemImageNamed:@"tray.full"]
                              selectedImage:[UIImage systemImageNamed:@"tray.full.fill"]];

    // ---------- 页签 2：统计 ----------
    // 🔴 统计页的 `viewWillAppear:` 里已经会 `reloadData`（v0.0.181 就有），
    //    所以切页签回来会**自动重查**，不用在这里额外挂刷新。
    //    ⚠️ 反过来别在这里手动调 reloadData：那时视图还没出来，
    //    而统计页的 `syncHeaderSize` 依赖 `table.bounds.size.width > 0`。
    NotifyStatsViewController *stats = [[NotifyStatsViewController alloc] init];
    UINavigationController *statsNav =
        [[UINavigationController alloc] initWithRootViewController:stats];
    statsNav.tabBarItem =
        [[UITabBarItem alloc] initWithTitle:@"统计"
                                      image:[UIImage systemImageNamed:@"chart.bar"]
                              selectedImage:[UIImage systemImageNamed:@"chart.bar.fill"]];

    // 🔴 两个 child 必须各自包一层 nav：这两个页面都会 push
    //    （首页 → 设置/详情，统计页 → 自定义时间窗）。没有 nav 的话
    //    `pushViewController:` 会静默什么都不做 —— 界面上表现为"点了没反应"，
    //    而且不报错、不崩，极难归因。
    self.viewControllers = @[recordsNav, statsNav];
    self.selectedIndex = NBHomeTabRecords;

    // ---------- v0.0.186：把统计页的"我要钻出去"接到记录页上 ----------
    // 🔴 weakSelf 必须 weak：容器持有 stats（childViewController），
    //    stats 持有这个 block ⇒ 强引用就成环，两个页面都释放不掉。
    __weak typeof(self) weakSelf = self;
    stats.drilldownHandler = ^(NSString *bundle, NSInteger days) {
        [weakSelf showRecordsForBundle:bundle dayRange:days];
    };

    // ---------- v0.0.187：把统计页的"对这个 App 做点什么"接到记录页上 ----------
    // 🔴 和上面那条同样的 weakSelf 理由（stats 持有 block，容器持有 stats）。
    // 🔴 接线本身**不做任何写入**：写入与回读全在记录页（那里才有那三条纪律）。
    //    容器在这里的职责只有两件 —— 把动作转给记录页、把结果显示给用户。
    stats.appActionHandler = ^(NSString *bundle, NBStatAppAction action) {
        [weakSelf handleStatsAppAction:action forBundle:bundle];
    };

    // ---------- iOS 15+ 的 tab bar 外观 ----------
    // 🔴 默认的 `scrollEdgeAppearance` 是**透明**的：当页面里最外层 scrollView
    //    滚到边缘时，tab bar 背景会消失，内容从下面透上来。
    //    本 App 的列表是自绘灰底 + 白卡片，透上来非常明显（看起来像"tab bar 坏了"）。
    //    ⇒ 两种状态都钉成标准背景。
    if (@available(iOS 15.0, *)) {
        UITabBarAppearance *ap = [[UITabBarAppearance alloc] init];
        [ap configureWithDefaultBackground];
        self.tabBar.scrollEdgeAppearance = ap;
        self.tabBar.standardAppearance = ap;
    }
}

#pragma mark - v0.0.186 统计页 → 记录页的钻取

- (void)showRecordsForBundle:(NSString *)bundle dayRange:(NSInteger)days {
    if (self.viewControllers.count <= NBHomeTabRecords) return;
    id navObj = self.viewControllers[NBHomeTabRecords];
    if (![navObj isKindOfClass:[UINavigationController class]]) return;
    UINavigationController *nav = (UINavigationController *)navObj;
    UIViewController *root = nav.viewControllers.firstObject;
    if (![root isKindOfClass:[ViewController class]]) return;

    // 🔴 顺序必须是「先把记录页的筛选设好，再切页签」。
    //    反过来会先让记录页按**旧筛选**刷一次（用户看到一帧"全部 App"的列表，
    //    下一帧才跳成目标 App），而 `viewWillAppear` 里还有一次它自己的 `refreshIfChanged`。
    [(ViewController *)root applyDrilldownBundle:bundle dayRange:days];

    // 🔴 记录页可能还停在详情页上：直接切过去会看到"某个 App 的通知详情"，
    //    而用户期望的是列表。⇒ 先回根，再切页签（动画关掉，避免和切页做成两段）。
    [nav popToRootViewControllerAnimated:NO];
    self.selectedIndex = NBHomeTabRecords;

    // 🔴 切页签给一次最轻的触觉：页签切换本身系统不给任何反馈，
    //    而从统计页"跳走"是用户主动发起的一次跨越，没有反馈会像误触。
    NBHapticFire(NBHapticKindSoft);
}

#pragma mark - v0.0.187 统计页行内行动

// 记录页的根 VC。取不到就返回 nil（调用方一律当"做不了"处理，⛔ 不崩）。
// 🔴 刻意不做"缓存一份 records 指针"：页签数组只有容器自己会在 viewDidLoad 里建，
//    缓存下来就等于多一个可能与 viewControllers 不同步的引用。
- (nullable ViewController *)nbRecordsRoot {
    if (self.viewControllers.count <= NBHomeTabRecords) return nil;
    id navObj = self.viewControllers[NBHomeTabRecords];
    if (![navObj isKindOfClass:[UINavigationController class]]) return nil;
    UIViewController *root = ((UINavigationController *)navObj).viewControllers.firstObject;
    if (![root isKindOfClass:[ViewController class]]) return nil;
    return (ViewController *)root;
}

- (void)handleStatsAppAction:(NBStatAppAction)action forBundle:(NSString *)bundle {
    ViewController *records = [self nbRecordsRoot];
    if (!records || !bundle.length) {
        // 到这里说明 App 的结构被改坏了（页签顺序变了 / 根不是记录页）。
        // 🔴 也要有反馈：静默 return 和"点了没反应"完全同形，事后无法区分。
        NBHapticFire(NBHapticKindWarning);
        NBShowToast(self.view, @"记录页不在，这个动作做不了");
        return;
    }

    NSString *msg = nil;
    BOOL ok = NO;
    switch (action) {
        case NBStatAppActionMuteOneHour:
            ok = [records nbApplyMuteOneHourForBundle:bundle message:&msg];
            break;
        case NBStatAppActionSkipRecord:
            ok = [records nbApplySkipRecordForBundle:bundle message:&msg];
            break;
    }

    // 🔴 提示贴在 **self.view**（容器）上，不是 records.view 上：
    //    用户此刻在统计页，records 那一页在另一个页签、根本不可见。
    //    贴错了的表现是"点了没反应"，而日志里一切正常 —— 这类问题极难归因。
    // 🔴 触觉与提示都排在 `ok` **之后**：成功了说成功、失败了说失败，
    //    不许因为"反正写过了"就统一弹一句好话（界面在说假话是本项目最贵的事故）。
    NBShowToast(self.view, msg);
    NBHapticFire(ok ? NBHapticKindSuccess : NBHapticKindWarning);
}

@end
