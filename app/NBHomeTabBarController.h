//
//  NBHomeTabBarController.h
//  NotificationBox
//
//  v0.0.183：把「记录 / 统计」提成底部两个页签。
//
//  🔴 为什么要有这个类（而不是在 AppDelegate 里就地拼一个 UITabBarController）：
//     ① 判据需要一个**稳定的锚点**。写在 AppDelegate 的
//        `didFinishLaunchingWithOptions:` 里的话，判据只能按字符串片段判，
//        而那个方法里已经塞了属主自愈 / 去重合并 / 窗口创建三件事；
//     ② 两个页签各自的 nav + tabBarItem 配置有 5 处细节（图标两态、标题、
//        iOS 15 的外观），这些必须和"谁是根"分开写，否则 AppDelegate 会变成杂物间。
//
//  ⚠️ tab 里的 child 必须各自包一层 UINavigationController：
//     ViewController 和 NotifyStatsViewController 都会 push（设置页 / 详情页 /
//     自定义时间窗），没有 nav 的话那些 push 全部静默失效。
//

#import <UIKit/UIKit.h>

// 页签下标。⛔ 别在别处写字面量 0 / 1 —— 顺序改了会被静默带偏。
// （`+1` 这种偏移在"加一个页签"时会全部错位，所以对外只暴露语义名。）
typedef NS_ENUM(NSInteger, NBHomeTab) {
    NBHomeTabRecords = 0,   // 记录：现有首页（列表 + 筛选 + 图标栏）
    NBHomeTabStats   = 1,   // 统计：v0.0.181 重写的那一页
};

@interface NBHomeTabBarController : UITabBarController

// ================= v0.0.186：统计页 → 记录页的钻取 =================
// 统计页点排行榜某一行时调它：切到「记录」页签，并只看这个 App。
// 🔴 为什么由**容器**来转这一手，而不是让统计页自己去拿列表对象：
//    统计页不该认识 `ViewController`（那会让两个页面互相 import 头文件、
//    以后任何一页改名都会牵连另一页）。统计页只声明一个 block 回调，
//    由本类在 `viewDidLoad` 里把它们接起来 —— 谁持有谁一目了然。
// 🔴 `dayRange` 是**天**：0 = 不限时间，-1 = 映射不了、别动时间窗（见 ViewController.h）。
- (void)showRecordsForBundle:(nullable NSString *)bundle dayRange:(NSInteger)days;

@end
