#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// v0.0.22：换提示音「听不到」的**只读**诊断。
//
// 🔴 为什么单独一个文件、而不是塞进那把刀里：
//    重型只读观测如果和"刀"混在一处，刀被观测代码拖出异常时，用户看到的是
//    「功能彻底坏了」，而观测代码自己也成了嫌疑犯 —— 一轮下来两个都解释不清。
//
// 这一轮必须**一次拿全**三件事（缺任何一件都得再来一轮）：
//   ① `BBSound` 到底有哪些属性、哪些**可写**（带 R/W 标注）
//      ⇒ 决定"自己造 BBSound"这条路走不走得通；
//   ② 我们造的那个对象上哪些 setter 真的存在
//      ⇒ 决定"值填得进去吗"（这一项由 NotifyFilter 直接写进 SOUND# 行，见那里的注释）；
//   ③ `%orig` 之后 sound 还在不在
//      ⇒ 决定系统有没有把它抹掉/换掉。
//
// 另外一个白捡的宝贝：一旦遇到**系统给的、非 nil 的 sound**，立刻整份 dump。
//   抄一个真实对象的字段值，比猜枚举值强一万倍 —— 这是本项目最硬的一条经验。
//   （v0.0.20 的 PROBE 显示默认通知 sound=nil，所以那时没得抄；但只要用户手机上
//     有一个 App 配了自定义提示音，这个钩子就会把正确配置送到我们面前。）
//
// 🔴 全部只读：一个系统对象的 setter 都不调，一个字段都不改。
//    唯一被写的是**我们自己 alloc 出来的那个** BBSound —— 那是刀本来就要做的事。

@interface NBSoundDiag : NSObject

// 一次性 dump 两个类的属性表（BBSound 全量、BBBulletin 只挑声音相关）。
// 放 %ctor 里调，内部容忍"框架还没加载"（拿不到就不置位，留给第一条通知重试）。
+ (void)dumpClassOnce;

// 每条通知调一次：只在**目标 App**（开关开 + 名单里有它 + ID 合法）才输出，
// 否则静默返回 —— 日志窗口只有约 50 行，诊断不许刷屏。
// stage 形如 "PB" / "PBR" / "PBRS"，用来区分三个入口。
// 内部会再排一次 0.4 秒后的复查，专门看"系统有没有把它抹掉"。
+ (void)probeAfterPublish:(nullable id)obj stage:(nullable NSString *)stage;

// 每条通知调一次：如果这个对象身上带了一个**系统给的** sound（非 nil），
// 整份 dump 一次（全进程只一次）—— 这是唯一能拿到"正确字段值"的来源。
+ (void)noteForeignSoundIfAny:(nullable id)obj stage:(nullable NSString *)stage;

@end

NS_ASSUME_NONNULL_END
