#import "AppDelegate.h"
#import "ViewController.h"
#import "NotifyFilter.h"
#import "NotifyStore.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 🔴🔴 v0.0.28：旧格式（soundApps 名单 + 全局音）→ soundMap 的**唯一**迁移时机。
    //
    // 为什么放在这里、而且只放在这里：
    //   · **必须在 App 进程**：SpringBoard 侧的通知路径不写盘（写盘是用户的动作，
    //     不是通知的副作用）。放 SpringBoard 里做迁移，等于每条通知都可能改一次设置文件。
    //   · **必须在 didFinishLaunching**：界面读值的每一处（设置页副标题、按 App 总览页）
    //     都假定"读到的是迁移后的形状"。放到页面里做，先打开的那一页就会读到旧形状。
    //   · 它是**幂等**的（已有 soundMap 就直接返回 NO），所以每次启动都调没有代价；
    //     不调反而有一个坑：用户升级后一直没打开 App，迁移就永远不发生。
    //   · 失败无害：迁移放弃时旧回退路径照旧工作（见 soundVerdictForBundle 的 ② 分支），
    //     用户不会因此"换音突然全失效"。
    [NotifyFilter migrateSoundMapIfNeeded];

    // v0.0.47：自动清理「保留最近 N 天」。**同样必须在 App 进程、didFinishLaunching**：
    //   days=0（默认）时 runAutoClean 直接返回 0、不打日志，等于零开销。
    //   它复用 v0.0.45 的批量删除（bundle=nil、readOnly=NO），与手动批量清理同一条 SQL 路径。
    //   失败无害：删不掉下次启动再试，不阻塞界面。
    [NotifyStore runAutoClean];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[UINavigationController alloc]
        initWithRootViewController:[[ViewController alloc] init]];
    self.window.backgroundColor = [UIColor systemBackgroundColor];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
