//
//  NBHomeTabBarController.m
//  NotificationBox
//

#import "NBHomeTabBarController.h"
#import "ViewController.h"
#import "NotifyStatsViewController.h"
#import "NBHaptic.h"

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

@end
