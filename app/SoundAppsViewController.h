#import <UIKit/UIKit.h>

// v0.0.28：按 App 分配提示音的总览页。
//
// 它只做两件事：
//   ① 列出"哪些 App 有自己的音"（名字 + 那个音是哪来的）；
//   ② 点进去改某个 App 的音（复用 SoundFilePickerViewController 的 per-App 模式）。
//
// 🔴 为什么单独一页、而不是塞进设置页：
//   设置页那一行只能显示「已分配 N 个」。用户真正要看的是"微信用的哪个音、QQ 用的哪个音"，
//   那是一张列表 —— 而这正是 v0.0.27 之前**做不到**的事（只能一份名单共用一个音）。
@interface SoundAppsViewController : UIViewController
@end
