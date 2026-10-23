#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 选择器服务于哪个设置键。三个键语义不同、存储格式相同（bundle id 数组）。
// 🔴 v0.0.19：`NBAppPickModeDelay = 3` 已删除（延迟推送功能整体移除）。
//    它不只是"没人用的枚举值"——这个页面保存选择时会用 keyForMode 得到键名并写盘，
//    也就是说只要有人再触发一次这个模式，`delayApps` 就被**写回设置**，
//    正是我们刚堵死的那条复活通道。留着它就是留一个后门。
typedef NS_ENUM(NSInteger, NBAppPickMode) {
    NBAppPickModeWhitelist = 0,   // whitelist：只推送这些
    NBAppPickModeBlacklist = 1,   // blacklist：不推送这些
    NBAppPickModeSpeak     = 2,   // speakApps：只朗读这些
    NBAppPickModeDnd       = 3,   // dndApps：这些 App 在免打扰时段不弹
    NBAppPickModeSound     = 4,   // soundApps：这些 App 换提示音（空 = 不生效）
};

// 可搜索、可多选的 App 选择器（v0.0.13）
//
// 🔴 为什么要做这个页面：原来黑白名单是一个「逗号分隔 bundle id」的输入框。
//    手填的问题不是"麻烦"，而是**填完就失控** —— 过几天回来，谁也不知道
//    "com.tencent.xin,com.apple.MobileSMS" 里那个 MobileSMS 当初为什么加进去，
//    想删一个又怕删错。**看不见的选择等于不能调整。**
//
// 设计口径：
//    · 列表 = 已安装 App ∪ 历史来过通知的 App（枚举全失败时后者仍可用）
//    · 已选的单独成一组排在顶部，不用在长列表里找
//    · 搜索同时匹配显示名和 bundle id（用户经常只记得"那个蓝色图标的"或半截 id）
//    · 点一下立即生效并落盘，没有"保存"按钮可忘
@interface AppPickerViewController : UIViewController

- (instancetype)initWithMode:(NBAppPickMode)mode;

// 供设置页问「当前选了几个」用（不依赖打开过本页）
+ (NSUInteger)selectedCountForMode:(NBAppPickMode)mode;

@end

NS_ASSUME_NONNULL_END
