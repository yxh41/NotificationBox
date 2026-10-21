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

// 诊断用：当前朗读子系统的可用性一行摘要（盒子 App 的日志页会读它）
+ (NSString *)diagnosticLine;

@end

NS_ASSUME_NONNULL_END
