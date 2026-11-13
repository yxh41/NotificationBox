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

// ================= v0.0.187：统计页行内行动的两个落点 =================
// 由 `NBHomeTabBarController` 调（统计页长按 / 无障碍动作 → 对某个 App 采取行动）。
//
// 🔴 为什么入口在这里、而界面在统计页：写入的纪律（重建表 → 落盘 → 回读精确条目）
//    和提示文案只有**一处**实现（`nbWriteMuteForBundle:kind:message:`）。在统计页再写
//    一份的话，回读那三条必然会在抄的时候丢一条 —— 而丢掉的正好是"到底生效了没"。
//
// 🔴 这两个方法**不负责提示与触觉**：它们只返回"回读结果 + 一句拼好的话"，
//    由容器贴在**自己**的 view 上 —— 动作是从统计页发起的，记录页此刻不可见。
//
// 返回 YES = 已回读确认生效（不是"我写盘成功了"）。
- (BOOL)nbApplyMuteOneHourForBundle:(nullable NSString *)bundle
                            message:(NSString * _Nullable * _Nullable)outMessage;
- (BOOL)nbApplySkipRecordForBundle:(nullable NSString *)bundle
                           message:(NSString * _Nullable * _Nullable)outMessage;

@end
