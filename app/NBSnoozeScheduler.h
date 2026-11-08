//
//  NBSnoozeScheduler.h
//  NotifyBox
//
//  v0.0.167：「稍后提醒」—— 把一条通知在 15 分钟 / 1 小时 / 明早 9 点再弹一次。
//
//  🔴 为什么完全放在 App 侧、不碰 tweak：
//     本地通知是 `UNUserNotificationCenter` 的能力，App 自己就能发，不需要注入 SpringBoard。
//     动 tweak 意味着往每条通知的热路径上加分支，而这件事和"通知拦截"毫无关系 ——
//     为它增加热路径风险不划算（本项目在热路径上栽过的次数最多）。
//
//  🔴 时间计算是**纯函数**（`fireDateForKind:now:` / `describeFireDate:`），
//     和"发通知"这个副作用分开：算错时间比发错通知更容易发生，也更容易被人忽略。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NBSnoozeKind) {
    NBSnoozeKind15Min = 0,
    NBSnoozeKind1Hour,
    NBSnoozeKindNextMorning,   // "明早 9:00"，规则见 fireDateForKind:now:
};

@interface NBSnoozeScheduler : NSObject

/// 菜单里显示的标题（"15 分钟后" / "1 小时后" / "明早 9:00"）
+ (NSString *)menuTitleForKind:(NBSnoozeKind)kind;

/// 真正会响的那个时间点。
/// 🔴 「明早」的判定：今天 9:00 若距现在**不足 30 分钟**（或已过）就顺延到明天。
///    这样凌晨 3 点说"明早 9:00"指的是**今天早上**（还有 6 小时），而不是 30 小时后 ——
///    用户的语感就是这样，机械地加一天会让他等整整一天。
+ (NSDate *)fireDateForKind:(NBSnoozeKind)kind now:(nullable NSDate *)now;

/// 时间的口语描述："今天 15:30" / "明天 09:00" / "11月10日 09:00"。
/// 🔴 提示语用它而不是菜单标题：凌晨 3 点选「明早 9:00」时，菜单写"明早"、
///    实际是今天早上 —— 提示语必须说**真实的那一天**，否则就是在骗人。
+ (NSString *)describeFireDate:(nullable NSDate *)date;

/// 排一条本地通知。
/// `completion` **一定在主线程**回调；`message` 是要 toast 给用户的话（失败时说明原因）。
+ (void)scheduleKind:(NBSnoozeKind)kind
          alertTitle:(nullable NSString *)alertTitle
            subtitle:(nullable NSString *)subtitle
                body:(nullable NSString *)body
          completion:(nullable void (^)(BOOL ok, NSString *_Nullable message))completion;

@end

NS_ASSUME_NONNULL_END
