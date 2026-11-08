//
//  NBSnoozeScheduler.m
//  NotifyBox
//
//  v0.0.167
//

#import "NBSnoozeScheduler.h"
#import "NotifyFilter.h"
#import <UserNotifications/UserNotifications.h>

@implementation NBSnoozeScheduler

+ (NSString *)menuTitleForKind:(NBSnoozeKind)kind {
    switch (kind) {
        case NBSnoozeKind15Min:       return @"15 分钟后";
        case NBSnoozeKind1Hour:       return @"1 小时后";
        case NBSnoozeKindNextMorning: return @"明早 9:00";
    }
    return @"稍后提醒";
}

+ (NSDate *)fireDateForKind:(NBSnoozeKind)kind now:(NSDate *)now {
    NSDate *base = now ?: [NSDate date];

    if (kind == NBSnoozeKind15Min) return [base dateByAddingTimeInterval:15 * 60];
    if (kind == NBSnoozeKind1Hour) return [base dateByAddingTimeInterval:60 * 60];

    // ---- 明早 9:00 ----
    // 🔴 v0.0.168：这里原来有一份自己的「今天 9:00 / 不足 30 分钟顺延到明天」推算。
    //    同一版加的「临时静音」菜单里也有「明早 9:00」—— 两处各算一份必然走岔，
    //    而它们摆在**同一个长按菜单**里，用户看到两个都写着「明早 9:00」却行为不同，
    //    那种 bug 连解释都没法解释。⇒ 推算收口到 NotifyFilter 一处（tweak 与 App 都编它）。
    return [NotifyFilter nextMorningNineFrom:base];
}

+ (NSString *)describeFireDate:(NSDate *)date {
    if (![date isKindOfClass:[NSDate class]]) return @"";

    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *today = [cal startOfDayForDate:[NSDate date]];
    NSDate *target = [cal startOfDayForDate:date];

    static NSDateFormatter *fmtHM = nil;
    static NSDateFormatter *fmtMD = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmtHM = [[NSDateFormatter alloc] init];
        fmtHM.locale = [NSLocale localeWithLocaleIdentifier:@"zh_Hans_CN"];
        fmtHM.dateFormat = @"HH:mm";
        fmtMD = [[NSDateFormatter alloc] init];
        fmtMD.locale = [NSLocale localeWithLocaleIdentifier:@"zh_Hans_CN"];
        fmtMD.dateFormat = @"M月d日 HH:mm";
    });

    NSString *hm = [fmtHM stringFromDate:date];
    if ([cal isDate:target inSameDayAsDate:today]) return [@"今天 " stringByAppendingString:hm];
    // 顺延到明天（含凌晨 3 点选"明早"却被判成今天的情况之外，所有跨天）
    NSDate *tomorrow = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:today options:0];
    if ([cal isDate:target inSameDayAsDate:tomorrow]) return [@"明天 " stringByAppendingString:hm];
    return [fmtMD stringFromDate:date];
}

+ (void)scheduleKind:(NBSnoozeKind)kind
          alertTitle:(NSString *)alertTitle
            subtitle:(NSString *)subtitle
                body:(NSString *)body
          completion:(void (^)(BOOL, NSString *))completion {

    // 🔴 所有出口都走这一个 finish：保证 completion **一定在主线程**、且**一定被调用一次**。
    //    `requestAuthorization` 的回调在后台队列上，忘了 hop 回来就会出现
    //    "从后台线程改 UI"（本项目在 getter 上栽过，闪退且没日志）。
    __block BOOL finished = NO;
    void (^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *msg) {
        if (finished) return;
        finished = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, msg);
        });
    };

    NSDate *fire = [self fireDateForKind:kind now:nil];
    NSString *when = [self describeFireDate:fire];

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    if (!center) {
        finish(NO, @"这台设备不支持本地通知");
        return;
    }

    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError *error) {
        if (!granted) {
            // 🔴 不 granted 有两种：用户拒绝、以及系统层面失败（error 非 nil）。
            //    两种都要说清"去哪儿能打开"，否则用户只会觉得这个功能是坏的。
            finish(NO, @"没有通知权限：设置 → 通知 → 消息盒子 里打开");
            return;
        }

        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = alertTitle.length ? alertTitle : @"稍后提醒";
        content.subtitle = subtitle.length ? subtitle : @"";
        content.body = body.length ? body : @"";
        content.sound = [UNNotificationSound defaultSound];

        UNNotificationTrigger *trigger = nil;
        if (kind == NBSnoozeKindNextMorning) {
            NSCalendar *cal = [NSCalendar currentCalendar];
            NSDateComponents *comp = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth |
                                                     NSCalendarUnitDay | NSCalendarUnitHour |
                                                     NSCalendarUnitMinute)
                                            fromDate:fire];
            trigger = [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:comp
                                                                              repeats:NO];
        } else {
            NSTimeInterval delta = [fire timeIntervalSinceNow];
            // 🔴 `UNTimeIntervalNotificationTrigger` 要求 >= 1 秒，且我们不希望出现"0 秒后响"
            if (delta < 60) delta = 60;
            trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:delta
                                                                        repeats:NO];
        }

        NSString *ident = [NSString stringWithFormat:@"nb.snooze.%@",
                           [[NSUUID UUID] UUIDString]];
        UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:ident
                                                                         content:content
                                                                         trigger:trigger];
        [center addNotificationRequest:req withCompletionHandler:^(NSError *addError) {
            if (addError) {
                finish(NO, [NSString stringWithFormat:@"排不上：%@", addError.localizedDescription]);
            } else {
                finish(YES, [NSString stringWithFormat:@"%@ 提醒你", when]);
            }
        }];
    }];
}

@end
