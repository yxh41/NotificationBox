#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 🔴 内置设置页（v0.0.8 起）
//    为什么不用 PreferenceLoader / 设置 App 的那一套：
//    只要把偏好 bundle 装进包，设置 App 就进不去，而且**没有崩溃日志**（不是闪崩，
//    是挂起/被跳过）。在这条路上盲调没有意义 ⇒ 设置直接做进盒子 App，
//    设置 App 的载荷从此彻底移除，这条故障通道从根上消失。
@interface SettingsViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
