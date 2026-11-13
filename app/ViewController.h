#import <UIKit/UIKit.h>

@interface ViewController : UIViewController <UITableViewDelegate, UITableViewDataSource,
                                              UISearchBarDelegate, UIScrollViewDelegate>

// ================= v0.0.186：统计页钻取进来的入口 =================
// 由 `NBHomeTabBarController` 调（统计页点排行某一行 → 切到记录页只看这个 App）。
// 🔴 只带两件事：**哪个 App** 和**时间窗多少天**。⛔ 不把统计页的筛选状态整个搬过来 ——
//    两页的筛选维度根本不是一套（统计有 30 天 / 自定义，记录页只有 24 小时 / 7 天 / 不限）。
// 🔴 `bundle` 传 nil = 全部 App；`days` 传 0 = 不限时间；传负数 = **映射不了，别动时间窗**
//    （实现里有一张映射表；宁可不改时间窗，也不要悄悄给一个口径不对的范围）。
- (void)applyDrilldownBundle:(nullable NSString *)bundle dayRange:(NSInteger)days;

@end
