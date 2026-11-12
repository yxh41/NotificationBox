#import "AppDelegate.h"
// v0.0.183：根视图换成 tab 容器。`ViewController.h` 保留不动 —— 它历史上被
// 当作"顺手引入一批 UIKit/自定义类型"的头用着，删掉要重新验证一遍编译，
// 而多一个未使用的 #import 不会触发 -Werror。等下次真正改这个文件时再一起清。
#import "ViewController.h"
#import "NBHomeTabBarController.h"
#import "NotifyFilter.h"
#import "NotifyStore.h"
// 🔴 v0.0.137：NBDataDir() / NBAltDataDir() / NBSharedLog() / NBHealDataDirOwnership() 都在这份头里。
//    NotifyStore.h **不** import 它（tweak 与 App 的公共契约单独一份，避免头文件互相牵连），
//    所以这里必须显式引 —— 少一行就是 "implicit declaration of function NBSharedLog"。
#import "NotifyCommon.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 🔴🔴 v0.0.137：**第一件事**就是属主自愈 + 打「我在哪个目录」。
    //
    // 为什么排在最前面：后面每一步（读设置、runAutoClean、合并重复、读列表）都要先能写盘；
    //   晚一步就是"用错的权限做了一次操作"，比不做更糟。
    //
    // ① `NBHealDataDirOwnership()`：目录存在但当前身份写不进、且**为空**时，删掉重建。
    //    这是**不依赖 root 注入**的那条腿（root 那条在 Tweak.x 的 ctor 里 chown）。
    //    删目录看的是**父目录**（/var/mobile/Library，归 mobile）的写权限 ⇒ 这里删得掉。
    // ⚠️ 非空目录它**绝不**动 —— 里面有记录就是用户的全部历史，宁可不自愈也不赌。
    //
    // ② 路径是**常量**，不再有"来源"可打。v0.0.136 那行 `来源=老路径兜底/App容器`
    //    看着像"判断结果"，实际是两个进程各算各的 —— 那个 bug 就是被这行字藏起来的。
    BOOL healed = NBHealDataDirOwnership();
    NSString *dataDir = NBDataDir();
    NBSharedLog(@"[路径] 盒子App 数据目录=%@ 自愈=%@ DB存在=%@",
                dataDir, healed ? @"是" : @"否",
                [[NSFileManager defaultManager] fileExistsAtPath:NOTIFYBOX_DB_PATH] ? @"是" : @"否");

    // 🔴🔴 v0.0.138：App 侧也跑一遍启动探针，结果落到 /private/var/tmp/nb_boot_NotifyBoxApp.txt。
    //
    // 为什么 App 也要跑：**App 的沙箱和 SpringBoard 的沙箱不是同一个**。
    //   同一批候选路径两边各试一次、并排看，才能判断"是谁被拒"：
    //     · 只有 App 写不进  ⇒ App 的 entitlement 问题（要加 no-container）
    //     · 两边都写不进      ⇒ 路径本身有问题，得换地方
    //     · 两边都写进        ⇒ 那个目录没问题，问题在别处（比如 tweak 压根没跑）
    //   摆在 didFinishLaunching 最前面，理由同下：后面每一步都要先能写盘。
    NBWriteBootProbe();

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

    // 🔴🔴 v0.0.84：历史重复一次性合并（同 `sys_id` 只留最新一行）。
    //   为什么必须在这一刻：写入侧本版才加上去重，**本版之前落库的重复行不会自己消失**，
    //   用户的抱怨会一直挂在那里。
    //   为什么放 App 进程：SpringBoard 侧的通知路径不许写盘（写盘是用户动作的副作用），
    //   和上面 runAutoClean 同一条纪律。
    //   为什么放 didFinishLaunching：幂等（库里干净时返回 0 且不打日志），
    //   而且早于任何界面读值，列表一打开就是干净的形状。
    //   🔴 失败无害：合并失败只是重复行留着，不影响任何功能。
    //   🔴 不在这里打日志：`NBStoreLog` 是 NotifyStore.m 的内部宏，这个文件够不着；
    //      合并本身在 `dedupeBySysId` 里已经记了「期望 N 行 / 实际删 M 行」。
    (void)[NotifyStore dedupeBySysId];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    // 🔴🔴 v0.0.183：根视图从「一个 UINavigationController」换成 tab 容器。
    //    ⛔ 不要再在外面套一层 UINavigationController —— `UITabBarController`
    //       必须是 root，套一层 nav 会让 tab bar 变成"nav 的 child"，
    //       表现为 tab bar 出现在导航栏下面、或者两个 nav 抢着管标题。
    self.window.rootViewController = [[NBHomeTabBarController alloc] init];
    self.window.backgroundColor = [UIColor systemBackgroundColor];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
