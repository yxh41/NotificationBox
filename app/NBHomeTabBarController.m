//
//  NBHomeTabBarController.m
//  NotificationBox
//

#import "NBHomeTabBarController.h"
#import "ViewController.h"
#import "NotifyStatsViewController.h"

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

@end
