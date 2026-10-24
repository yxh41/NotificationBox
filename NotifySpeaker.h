#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 通知朗读（v0.0.12）
//
// 🔴 为什么单开一个类：朗读是整个插件里**唯一**去碰音频子系统的动作，
//    它有两种独立的失败模式，跟记录/过滤完全无关：
//    ① 调用炸了 ⇒ SpringBoard 跟着炸 ⇒ 用户连续安全模式；
//    ② 没炸但没声音（音频会话被别的东西占着）⇒ 看起来"功能没做"。
//    这两件事必须能各自定位，塞进 Tweak.x 里就分不开了。
@interface NotifySpeaker : NSObject

// 读设置判断「这条该不该读」。**纯读，无副作用**，可以放心在热路径上调。
// 条件：speakEnabled 为真 + bundle 命中 speakApps（为空 = 全部）+ 确实有文字可读。
+ (BOOL)shouldSpeakBundle:(nullable NSString *)bundle
                    title:(nullable NSString *)title
                  message:(nullable NSString *)message;

// 真正朗读。内部**异步入主队列**，绝不阻塞通知投递。
// 🔴 调用方不用关心线程，但必须知道：这个函数返回时声音还没出来。
+ (void)speakWithBundle:(nullable NSString *)bundle
                  title:(nullable NSString *)title
                message:(nullable NSString *)message;

// 崩溃自愈。%ctor 里调用一次。
// 返回 YES ⇒ 检测到「上次朗读没走完」⇒ 已把 speakEnabled 强制写回 NO。
+ (BOOL)recoverFromCrashIfNeeded;

// v0.0.30：**现在正在朗读吗？** 纯读，无副作用。
//
// 谁需要它：音频会话的"交还"时机（`NotifyFilter releaseAudioSessionIfIdle`）。
// 朗读自己从不碰 AVAudioSession（靠 AVSpeechSynthesizer 内部激活），
// 所以换音通道收工时如果不管三七二十一就 `setActive:NO`，**会把正在朗读的那句掐断** ——
// 这种"音被掐一半"的症状用户只会描述成"插件坏了"，极难查。
//
// 🔴 为什么必须是公开的类方法：`gSynth` 是 NotifySpeaker.m 里的 static 私有变量，
//    NotifyFilter.m 拿不到 ⇒ 只能由本类出面回答。
// 🔴 为什么 NotifyFilter 那边要用 NSClassFromString 问：NotifyFilter.m 同时被编进
//    盒子 App，而 App 目标**没有链接 NotifySpeaker.m**（Makefile 的 App_FILES 里没有它），
//    直接发消息会在**链接期** undefined symbol。反射调用则在 App 里自然返回 nil ⇒ 放行。
+ (BOOL)isSpeakingNow;

// 诊断用：当前朗读子系统的可用性一行摘要（盒子 App 的日志页会读它）
+ (NSString *)diagnosticLine;

@end

NS_ASSUME_NONNULL_END
