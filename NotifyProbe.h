#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// BulletinBoard 侧只读探针（v0.0.12）
//
// 🔴 为什么要有这个东西：
//    「按 App 换提示音」和「延迟推送」都卡在同一个问题上 ——
//    **我不知道真机上的 BBBulletin 到底长什么样**。
//    `BBBulletin.sound` 这个名字是从公开资料推出来的假设，不是量出来的。
//    照假设写代码的结局通常是：编译过、装上、日志一行没有、界面毫无变化，
//    然后分不清「属性名错了」「hasSound 判断错了」「根本没走到这一行」。
//
//    所以这一版先不实现功能，只把**类结构**量回来：
//      · BBBulletin 有哪些 property，各自的类型编码是什么（property_getAttributes 最准）
//      · BBSound 类有哪些 property / 类方法（能不能凭空造一个声音对象）
//      · 真机上 sound 这个量到底是不是 nil（很多 App 用默认声音时它就是 nil）
//    拿到这三样，下一版才谈得上"写对"。
//
// 🔴 全部只读。一个 setter 都不调，一个对象都不改。它可以随便跑、随便删。

@interface NotifyProbe : NSObject

// 一次性 dump 类结构。%ctor 里调一次即可（内部自己保证只 dump 一次）。
+ (void)dumpClassesOnce;

// 每条通知调一次。内部只在前 3 条里输出，之后静默 —— 日志窗口只有约 50 行，
// 探针不能把真正有用的 DROP#/REPL#/SPEAK 行挤掉。
+ (void)probeBulletin:(nullable id)obj tag:(nullable NSString *)tag;

// v0.0.16：万一「改时间字段」不能让系统推迟显示，下一步就得知道
// **BBServer 的串行队列在哪儿** —— 崩溃栈已经证明只有那个队列能安全调它的方法。
// 输出两行：① BBServer 里所有名字含 queue/serial/dispatch/thread 的 property；
//          ② 我们被调用时所在的队列标签（dispatch_queue_get_label）。
// 🔴 全部只读，一个 setter 都不调。内部自己保证只跑一次（拿不到类就不置位，留给下次）。
+ (void)dumpServerQueueOnce;

// 计数器（判断探针到底跑没跑过；盒子 App 的日志页能读到）
+ (int)probedCount;

@end

NS_ASSUME_NONNULL_END
