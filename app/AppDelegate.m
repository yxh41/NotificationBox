#import "AppDelegate.h"
#import "ViewController.h"
#import "NotifyFilter.h"

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

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[UINavigationController alloc]
        initWithRootViewController:[[ViewController alloc] init]];
    self.window.backgroundColor = [UIColor systemBackgroundColor];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
