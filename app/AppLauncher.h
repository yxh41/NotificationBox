#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// ================= v0.0.118：按 bundleId 打开对应的 App =================
// 用途：列表里长按一张卡片 ⇒ 菜单里的「打开」⇒ 打开这条通知对应的那个 App。
// （用户在系统通知的菜单里看到的是「打开 / 系统设置 / 更多」，盒子这边先只做「打开」。）
//
// 🔴 为什么自己写一个模块，而不是在 ViewController 里顺手两行：
//    ① "能不能打开"有**两条**路，而且第一条在这台机器上不一定可用 —— 需要留痕，
//       否则失败时只能靠猜（本项目最贵的一课：不报错的失败最难查）；
//    ② `openApplicationWithBundleID:` 是**私有** API，返回 BOOL 且**不存在头文件**
//       ⇒ 只能用 `NSClassFromString` + `performSelector`/IMP 调，这类代码放在一起
//       才好审（散在业务代码里，下次谁改都不知道它调的是私有方法）。
//    ③ App 名表/图标那边已经在用 `LSApplicationProxy`（见 AppIconLoader/InstalledApps），
//       说明这两条路在这个进程里**确实可用** —— 结论来自实测，不是猜的。
typedef NS_ENUM(NSInteger, NBOpenAppResult) {
    // 打开请求已经发出去了（系统收下了；不代表那个 App 一定在前台起来了）
    NBOpenAppResultSent = 0,
    // 这条记录没有 bundleId ⇒ 没有可打开的目标
    NBOpenAppResultNoBundle,
    // 本机没有这个 App（已卸载 / 记录是别的设备带过来的）
    NBOpenAppResultNotInstalled,
    // 两条路都走不通（workspace 拿不到 且 这个 App 没有声明 URL scheme）
    NBOpenAppResultNoWay,
};

@interface AppLauncher : NSObject

// 打开。**只发请求、不弹任何界面** —— 失败提示由调用方决定怎么显示
// （调用方往往正处在"菜单正在收起"的时刻，这里再 present 一个框会和收起的动画打架）。
+ (NBOpenAppResult)openBundle:(nullable NSString *)bundleId;

// v0.0.133：**有深链就先直达内容页，没有/打不开就兜底只打开 App**。
// 🔴 兜底是硬要求，不是"顺便"：iOS 没有「跳到某条通知」的通用能力，
//    深链能命中的只是少数通知（很多 App 的推送压根不带链接）。
//    ⇒ 这个方法的契约是「**永不比 openBundle: 更差**」：任何一步失败都退回它。
// 🔴 只用 `openURL` 的 completion `NO`（连请求都没被系统收下）当兜底触发，
//    **不拿 YES 当"打开了"的证据** —— 同 `openBundle:` 里那条纪律。
+ (NBOpenAppResult)openBundle:(nullable NSString *)bundleId deeplink:(nullable NSString *)deeplink;

// v0.0.133：从库里存的 payload(JSON) 里找一条"能跳转"的 URL，找不到返回 nil。
// 🔴 解析**故意放在 App 侧**（tweak 只哑存原始 payload）：
//    "哪个键是跳转链接"是会变的知识，放这里改规则不用重编 tweak。
// 🔴 选键策略（避免把图片地址当跳转）：
//    自定义 scheme（`app://…`）优先；`http(s)` **只认已知键名**（url/link/jumpUrl…），
//    否则 payload 里随便一个图片 URL 都会把用户送进浏览器。
+ (nullable NSString *)deeplinkFromPayload:(nullable NSString *)payload;

// 给用户看的一句话。返回 nil = 不用提示（成功时静默：App 切走了本身就是反馈）。
+ (nullable NSString *)textForResult:(NBOpenAppResult)r;

@end

NS_ASSUME_NONNULL_END
