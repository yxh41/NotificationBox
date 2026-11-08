//
//  NBSnoozeScheduler.m
//  NotifyBox
//
//  v0.0.167
//

#import "NBSnoozeScheduler.h"
#import "NotifyFilter.h"
#import <UserNotifications/UserNotifications.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dlfcn.h>

// 从**当前进程的代码签名**里读一个 entitlement。
//
// 🔴 为什么必须读这个而不是读 Info.plist：`requestAuthorization` 背后是
//    `usernotificationsd` 按**签名身份**认 App，Info.plist 里的 CFBundleIdentifier
//    对它没有约束力。v0.0.170 的真机现象是 status 永远停在 notDetermined ——
//    也就是"系统不认识这个进程"，而唯一的身份凭据就是这一串 entitlement。
//
// 🔴🔴 v0.0.171：`SecTask` 这一族 API **不在公共 Security 头里**（那个头里只有 `SecTrust`），
//    直接写 `SecTaskRef` 会编译期 `unknown type name 'SecTaskRef'`（CI run #302 报的就是这个）。
//    ⇒ 改用 **dlsym 运行期取符号**，自己声明类型。三个好处：
//      ① 编译期不依赖任何私有头；
//      ② 符号不存在时只是"读不到"，不会在**链接期**变成 undefined symbol
//         （链接失败的报错看着像代码问题，其实只是这台系统没这个 API）；
//      ③ 拿不到就明说"读不到"，而不是编一个值出来 —— 这正是本项目反复栽的那类假读数。
typedef struct __SecTask *NBSecTaskRef;

static CFTypeRef NBCopyEntitlement(NSString *key) {
    static NBSecTaskRef (*createSelf)(CFAllocatorRef) = NULL;
    static CFTypeRef (*copyValue)(NBSecTaskRef, CFStringRef, CFErrorRef *) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // dlopen 只是兜底：UIKit 已经把 Security 装进进程了，RTLD_DEFAULT 通常直接能找到。
        // 打不开也继续往下走（不 return），否则一次 dlopen 失败就永久拿不到读数。
        dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
        void *s1 = dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
        void *s2 = dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
        if (s1) createSelf = (NBSecTaskRef (*)(CFAllocatorRef))s1;
        if (s2) copyValue = (CFTypeRef (*)(NBSecTaskRef, CFStringRef, CFErrorRef *))s2;
    });
    if (!createSelf || !copyValue) return NULL;

    NBSecTaskRef t = createSelf(kCFAllocatorDefault);
    if (!t) return NULL;
    CFTypeRef v = copyValue(t, (__bridge CFStringRef)key, NULL);
    CFRelease(t);
    return v;
}

// 🔴 只认标量（字符串/布尔/数字）。数组/字典一律回"非标量"：**绝不 description 未知对象**，
//    这条纪律在通知回调里尤其硬（曾经因为打印未知对象直接卡死）。
static NSString *NBEntitlementValue(NSString *key) {
    CFTypeRef v = NBCopyEntitlement(key);
    if (!v) return @"(读不到：SecTask 符号不在，或签名里没有这个键)";

    NSString *out = nil;
    CFTypeID t = CFGetTypeID(v);
    if (t == CFBooleanGetTypeID())      out = CFBooleanGetValue((CFBooleanRef)v) ? @"true" : @"false";
    else if (t == CFStringGetTypeID())  out = [NSString stringWithString:(__bridge NSString *)v];
    else if (t == CFNumberGetTypeID())  out = [(__bridge NSNumber *)v stringValue];
    else                                out = [NSString stringWithFormat:@"(非标量 type=%lu)", (unsigned long)t];
    CFRelease(v);
    return out ?: @"(空)";
}

// 状态/开关 ⇒ 人话。**每个值都要有名字**，包括"我不认识这个值"——
// 只印数字的话，用户报上来一个 "3"，我仍要回来查表（"只给数字的留痕改不了规则"）。
static NSString *NBStatusText(UNAuthorizationStatus s) {
    switch ((NSInteger)s) {
        case 0: return @"未决（0 notDetermined —— 系统还没问过 / 授权框没弹出来）";
        case 1: return @"已拒绝（1 denied —— 用户或系统关掉了）";
        case 2: return @"已授权（2 authorized）";
        case 3: return @"临时授权（3 provisional，静默投递）";
        case 4: return @"短暂授权（4 ephemeral）";
    }
    return [NSString stringWithFormat:@"未知状态（%ld）", (long)s];
}

static NSString *NBSettingText(UNNotificationSetting v) {
    switch ((NSInteger)v) {
        case 0: return @"不支持";
        case 1: return @"关";
        case 2: return @"开";
    }
    return [NSString stringWithFormat:@"未知（%ld）", (long)v];
}

@implementation NBSnoozeScheduler

+ (void)fetchAuthorizationReport:(void (^)(NSString *, UNAuthorizationStatus))completion {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    if (!center) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(@"拿不到 UNUserNotificationCenter（系统没有这个服务）", 0);
            });
        }
        return;
    }

    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *s) {
        // 🔴 这个回调**在后台队列**：拼字符串无所谓，但绝不能在这里碰 UI。
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)";
        NSString *path = [[NSBundle mainBundle] bundlePath] ?: @"(nil)";

        NSString *report = [NSString stringWithFormat:
            @"授权状态：%@\n"
            @"弹窗 %@ ｜ 声音 %@ ｜ 通知中心 %@\n"
            @"Bundle：%@\n"
            @"App 路径：%@\n"
            @"— 系统看到的身份 —\n"
            @"application-identifier：%@\n"
            @"platform-application：%@\n"
            @"no-container：%@",
            NBStatusText(s.authorizationStatus),
            NBSettingText(s.alertSetting),
            NBSettingText(s.soundSetting),
            NBSettingText(s.notificationCenterSetting),
            bundle, path,
            NBEntitlementValue(@"application-identifier"),
            NBEntitlementValue(@"platform-application"),
            NBEntitlementValue(@"com.apple.private.security.no-container")];

        // 再补一条"系统到底认不认这个 App"的旁证：能查待发请求 = 服务是通的；
        // 查不出来也只是异常，不影响上面的状态读数，所以单独 try 一下。
        [center getPendingNotificationRequestsWithCompletionHandler:^(NSArray *reqs) {
            NSString *full = [report stringByAppendingFormat:@"\n待发提醒：%lu 条",
                              (unsigned long)reqs.count];
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(full, s.authorizationStatus);
                });
            }
        }];
    }];
}

+ (void)requestAuthorization:(void (^)(BOOL, NSString *))completion {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    if (!center) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"这台设备没有通知服务（UNUserNotificationCenter 为 nil）");
            });
        }
        return;
    }

    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError *error) {
        // 无论成败都**复查状态**：granted 只是"这次请求的结果"，
        // 而我们要报给用户的是"现在到底能不能发"。
        [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *s) {
            NSString *detail = nil;
            if (granted) {
                detail = [NSString stringWithFormat:@"已授权（%@）", NBStatusText(s.authorizationStatus)];
            } else if (s.authorizationStatus == UNAuthorizationStatusDenied) {
                // ① 用户拒绝：这句话必须指向"去哪儿打开"，因为 App 自己改不了
                detail = @"你之前拒绝过通知权限 ⇒ 设置 → 通知 → 消息盒子 → 允许通知";
            } else if (error) {
                // ② 系统报错。**必须带上 domain/code**：这就是判断"有没有被系统登记"的唯一线索
                detail = [NSString stringWithFormat:
                          @"系统拒绝了（%@ %ld：%@）⇒ 这个 App 可能没被系统登记",
                          error.domain, (long)error.code,
                          error.localizedDescription ?: @"无描述"];
            } else {
                // ③ granted=NO 但既没拒绝也没报错 ⇒ 授权框没弹出来。这一支以前和①混在一起。
                detail = [NSString stringWithFormat:
                          @"系统没有弹出授权框（状态仍为 %@）⇒ 多半是这个 App 没被系统登记",
                          NBStatusText(s.authorizationStatus)];
            }
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(granted, detail);
                });
            }
        }];
    }];
}

+ (BOOL)openSystemNotificationSettings {
    NSString *s = UIApplicationOpenSettingsURLString;
    if (!s.length) return NO;
    NSURL *u = [NSURL URLWithString:s];
    UIApplication *app = [UIApplication sharedApplication];
    if (!u || !app) return NO;
    [app openURL:u options:@{} completionHandler:nil];
    return YES;
}

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

    // 🔴 v0.0.169：授权失败**不再笼统说"没有通知权限"**。
    //    v0.0.167 那一句话把三种病因（用户拒绝 / 系统报错 / 授权框没弹）说成同一件事，
    //    结果用户只能反复点、我只能盲猜 —— 也正是这次「稍后提醒显示没有通知权限」的由来。
    //    现在把 `requestAuthorization:` 报出来的状态与原因原样转给用户。
    [self requestAuthorization:^(BOOL granted, NSString *detail) {
        if (!granted) {
            finish(NO, [NSString stringWithFormat:@"稍后提醒没排上：%@",
                        detail ?: @"没有通知权限"]);
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
                // 🔴 同样带上 domain/code：`localizedDescription` 是本地化文案，
                //    同一个 code 在不同系统语言下长得完全不同，事后对不上账。
                finish(NO, [NSString stringWithFormat:@"排不上（%@ %ld：%@）",
                            addError.domain, (long)addError.code,
                            addError.localizedDescription ?: @"无描述"]);
            } else {
                finish(YES, [NSString stringWithFormat:@"%@ 提醒你", when]);
            }
        }];
    }];
}

@end
