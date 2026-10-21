#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 朗读声音选择（v0.0.13）
//
// 🔴 为什么值得单独一页：朗读能出声只是"可用"，声音对不对是"好用"。
//    iOS 自带的语音在不同机器上差很多 —— 有的机型只有 Ting-Ting 这类老式合成音，
//    装了增强语音的会有 Siri 系的人声。不给选择的话，用户听到的是
//    "机器人在念经"，功能等于白做。
//
// 交互口径：
//    · 点一下 = 选中 + **立刻试听**。不设"试听按钮"是因为
//      选了才听得到、听到了才知道要不要换，合成一步用户少想一层。
//    · 首项是「跟随系统」，即不指定声音（英文系统读英文、中文系统读中文）。
//    · 语速单独一组，四档。默认值就是系统默认，不动它也是对的。
@interface VoicePickerViewController : UIViewController

// 给设置页显示「当前是哪个声音」用
+ (NSString *)currentVoiceDisplayName;

@end

NS_ASSUME_NONNULL_END
