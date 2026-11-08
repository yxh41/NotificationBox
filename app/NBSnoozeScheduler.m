//
//  NBSnoozeScheduler.m
//  NotifyBox
//
//  v0.0.167
//

#import "NBSnoozeScheduler.h"
#import "NotifyFilter.h"
#import "NotifyCommon.h"
#import <sqlite3.h>
#import <errno.h>
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

// 🔴🔴 v0.0.173：把"读不到"拆成三种病因。
//    上一版这里只有一句 `(读不到：SecTask 符号不在，或签名里没有这个键)` ——
//    一句话盖住三种完全不同的世界：
//      ① 这台系统上根本没有 SecTask 这两个符号（dlsym 拿不到）⇒ 是我的探测方法不可用；
//      ② 符号在、任务建不出来                          ⇒ 是运行环境的问题；
//      ③ 符号和任务都正常，但签名里**确实没这个键**      ⇒ 这才是"没配"。
//    而 v0.0.172 真机截图里 `no-container` 显示的就是那句合并话 —— 我盯着它
//    无法判断"删掉生效了"还是"探测本身坏了"。这正是本项目反复栽的那类假读数：
//    **一个 0 必须说清是几种病因里的哪一种。**
typedef NS_ENUM(NSInteger, NBEntLookup) {
    NBEntLookupNoAPI = 0,   // dlsym 找不到 SecTask 符号
    NBEntLookupNoTask,      // 有符号，但 SecTaskCreateFromSelf 返回 NULL
    NBEntLookupMissing,     // 符号/任务都正常，这个键不在签名里
    NBEntLookupOK,          // 读到了（*outValue 是 +1 的引用，调用方负责 CFRelease）
};

static NBEntLookup NBCopyEntitlement(NSString *key, CFTypeRef *outValue) {
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
    if (!createSelf || !copyValue) return NBEntLookupNoAPI;

    NBSecTaskRef t = createSelf(kCFAllocatorDefault);
    if (!t) return NBEntLookupNoTask;
    CFTypeRef v = copyValue(t, (__bridge CFStringRef)key, NULL);
    CFRelease(t);
    if (!v) return NBEntLookupMissing;
    if (outValue) *outValue = v;
    return NBEntLookupOK;
}

// 🔴 只认标量（字符串/布尔/数字）。数组/字典一律回"非标量"：**绝不 description 未知对象**，
//    这条纪律在通知回调里尤其硬（曾经因为打印未知对象直接卡死）。
static NSString *NBEntitlementValue(NSString *key) {
    CFTypeRef v = NULL;
    NBEntLookup st = NBCopyEntitlement(key, &v);
    switch (st) {
        // 🔴 三种病因三种话，绝不合并 —— 合并了就等于把"没配"和"我量不到"混成一条。
        case NBEntLookupNoAPI:   return @"量不到（这台系统没有 SecTask 符号）";
        case NBEntLookupNoTask:  return @"量不到（SecTaskCreateFromSelf 失败）";
        // ⚠️ "没有这个键"是**结论**，不是"读不到"。v0.0.172 删掉 no-container 之后
        //    这一行就应该显示这句 —— 它显示这句才说明删干净了。
        case NBEntLookupMissing: return @"没有这个键（签名里确实没配）";
        case NBEntLookupOK:      break;
    }

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

// ─────────────────────────────────────────────────────────────────────────────
// v0.0.172：沙箱与数据实测。
//
// 🔴 这一段存在的唯一目的 = 给「删掉 no-container」这刀**配一把能读的尺子**。
//    v0.0.172 把 `com.apple.private.security.no-container` 换成了路径白名单，
//    改对了：App 有了容器，通知权限能落库；
//    改错了：App 又被关回容器，读不到 /var/mobile/Library/NotifyBox
//            ⇒ 盒子列表空（而这不是"记录丢了"，是"App 看不见"）。
//    两种结果的**唯一可分辨之处**就在下面这四行，所以必须摊在自检页上，
//    不能靠用户描述"好像没记录"。
//
// 🔴 为什么用 `NSHomeDirectory()` 判容器，而不是去读 entitlement：
//    entitlement **声明了什么** ≠ 系统**给了什么**。白名单写了但没被沙箱采用（拼错、
//    或键名在这个 iOS 版本上不认）时，读 entitlement 依然显示"有这条"
//    —— 那是拿声明当事实，本项目栽过多次（"改了 ≠ 在跑"）。
//    `NSHomeDirectory()` 是内核/沙箱给的**结果**，它落在 Containers/Data/Application/<UUID>
//    才说明 App 真的有数据容器。宁可用结果，不用声明。
//
// 🔴 读目录/开库都是**只读**（sqlite3_open_v2 + SQLITE_OPEN_READONLY）：
//    诊断绝不能顺手建库改数据 —— 那会让"打不开"变成"打得开但空"，
//    两种病混成一种，比不诊断更糟。
static NSString *NBSandboxReport(void) {
    NSMutableString *s = [NSMutableString string];

    NSString *home = NSHomeDirectory() ?: @"(nil)";
    BOOL hasContainer = ([home rangeOfString:@"/Containers/Data/Application/"].location != NSNotFound);
    [s appendFormat:@"我的容器：%@\n   %@\n", hasContainer ? @"有" : @"没有", home];

    // 文档目录在"没有容器"时会**恒为 nil**——它是最灵敏的那一根探针，
    // 而且它 nil 的时候屏幕上会显示一个空白，所以必须显式写出人话。
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = docs.count ? docs.firstObject : nil;
    [s appendFormat:@"文档目录：%@\n", doc.length ? doc : @"拿不到（nil ⇒ 系统没给数据容器）"];

    // 数据目录：能不能列。列不出来要把 errno 带出来——
    // errno=1(EPERM) = 沙箱拒绝（白名单没生效）；errno=2(ENOENT) = 目录真不在。
    NSString *dir = NOTIFYBOX_LEGACY_DIR;
    NSError *e = nil;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:&e];
    if (items) {
        [s appendFormat:@"数据目录：可读，%lu 项\n", (unsigned long)items.count];
    } else {
        [s appendFormat:@"数据目录：不可读（errno=%d %@）\n",
            (int)e.code, e.localizedDescription ?: @"?"];
    }

    // 🔴🔴 写测试：**能读 ≠ 能写**，而这一版最怕的恰恰是"能读不能写"。
    //    两种病在同一屏上长得几乎一样（列表有记录=读通了），但静音要生效必须**能写**：
    //    静音表就在这个目录里（settings.plist）。只测读 ⇒ 用户设了静音、表没落盘、
    //    通知照弹，而自检页全绿 —— 又是一次"判据绿的理由不是它要证的事"。
    //    测试文件写到数据目录、写完立刻删；不碰任何既有文件。
    NSError *we = nil;
    NSString *probe = [dir stringByAppendingPathComponent:@".nb_write_probe"];
    BOOL canWrite = [@"ok" writeToFile:probe atomically:YES
                              encoding:NSUTF8StringEncoding error:&we];
    if (canWrite) {
        [[NSFileManager defaultManager] removeItemAtPath:probe error:NULL];
        [s appendFormat:@"写测试：能写（静音表能落盘）\n"];
    } else {
        [s appendFormat:@"写测试：**不能写**（errno=%d %@）⇒ 静音设了也存不进去\n",
            (int)we.code, we.localizedDescription ?: @"?"];
    }

    // 数据库：真开一次、真数一次。
    // 🔴 只报"记录数"是不够的：0 条和"根本没打开"长得一样。三种结局分开写：
    //    打不开（rc/errno）、打得开但查不出（表不对）、查出来 N 条。
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2([NOTIFYBOX_DB_PATH UTF8String], &db, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) {
        [s appendFormat:@"数据库：打不开（rc=%d，sqlite 说：%s）",
            rc, db ? sqlite3_errmsg(db) : "句柄都没建出来"];
    } else {
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM notifications", -1, &st, NULL) == SQLITE_OK
            && sqlite3_step(st) == SQLITE_ROW) {
            [s appendFormat:@"数据库：能打开，记录 %lld 条",
                (long long)sqlite3_column_int64(st, 0)];
        } else {
            [s appendFormat:@"数据库：能打开，但数不出来（%s）", sqlite3_errmsg(db)];
        }
        sqlite3_finalize(st);
    }
    if (db) sqlite3_close(db);

    return s;
}

// ─────────────────────────────────────────────────────────────────────────────
// v0.0.172：「装到磁盘的版本」 vs 「SpringBoard 里正在跑的版本」。
//
// 🔴🔴 为什么这条必须存在：这一版对静音**一行逻辑都没改**（dylib 的 __TEXT 只差 1 字节，
//    就是版本号里那个数字）。用户「静音设了还是弹」的唯一解释是 **SpringBoard 里跑的
//    还是旧 dylib** —— tweak 只在 SpringBoard 重启时重新加载。
//    而这件事在此之前**从来没被量过**，全是我的推断。
//    postinst 现在会自动 respring，但"postinst 到底跑没跑"在这里也是不可见的：
//    dpkg 脚本失败、chroot、killall 不存在……每一种都表现为「和没改一样」。
//    ⇒ 唯一能分辨的办法 = 让 dylib 自己报版本，App 读回来和磁盘上的比。
//
// 数据来源：`Tweak.x` 的 %ctor 每次都把
//      `<日期> <进程名> <版本号> dylib=<真实路径>`
//   写进 `.tweak_ctor`（0666，root/mobile 都读得到）。所以这个文件的版本号 = 
//   **最近一次 SpringBoard 启动时加载的那个 dylib 的版本**，正是要的那一个。
static NSString *NBVersionFromMark(NSString *path) {
    NSString *txt = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding error:NULL];
    if (!txt.length) return nil;
    // 🔴 不按"第 5 段"取：`[NSDate date]` 的段数会随格式变（还有本地化）。
    //    改成"扫所有词，找第一个形如 数字.数字.数字 的"，写死的只有版本号自身的形状。
    for (NSString *tok in [txt componentsSeparatedByCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        NSArray *parts = [tok componentsSeparatedByString:@"."];
        if (parts.count != 3) continue;
        BOOL digits = YES;
        for (NSString *p in parts) {
            if (!p.length) { digits = NO; break; }
            for (NSUInteger i = 0; i < p.length; i++) {
                unichar c = [p characterAtIndex:i];
                if (c < '0' || c > '9') { digits = NO; break; }
            }
            if (!digits) break;
        }
        if (digits) return tok;
    }
    return nil;
}

static NSString *NBTweakVersionReport(void) {
    NSString *mine = NOTIFYBOX_VER_STR;
    // 🔴 两个标记都读：
    //    `.tweak_ctor`      = 非 root 进程（SpringBoard）写的 —— 这才是**执行过滤的那一个**
    //    `.tweak_ctor_root` = root 进程（backboardd）写的 —— 只作旁证
    //    只读 root 那个会把"backboardd 新版、SpringBoard 旧版"这种半边更新的现场看反。
    NSString *sbMark = [NOTIFYBOX_LEGACY_DIR stringByAppendingPathComponent:@".tweak_ctor"];
    NSString *rtMark = [NOTIFYBOX_LEGACY_DIR stringByAppendingPathComponent:@".tweak_ctor_root"];
    NSString *sbVer = NBVersionFromMark(sbMark);
    NSString *rtVer = NBVersionFromMark(rtMark);

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"盒子 App：%@\n", mine];
    if (!sbVer.length) {
        // 🔴 三态里的"读不到"必须单独说，不能和"版本不一致"共用一句话 ——
        //    读不到的病因是没注入/写不进共享目录，方向完全不同。
        [s appendFormat:@"SpringBoard 里的 dylib：**读不到**（%@ 不在或读不出）\n"
                        @"   ⇒ 要么没注入，要么写不进共享目录", sbMark.lastPathComponent];
    } else if ([sbVer isEqualToString:mine]) {
        [s appendFormat:@"SpringBoard 里的 dylib：%@（一致 ✅）", sbVer];
    } else {
        [s appendFormat:@"SpringBoard 里的 dylib：%@ ❗️ **不是同一个版本**\n"
                        @"   ⇒ 正在跑的是旧的，装完要重启一次手机（或注销）才生效",
         sbVer];
    }
    [s appendFormat:@"\nbackboardd 里的 dylib：%@", rtVer.length ? rtVer : @"读不到"];
    return s;
}

@implementation NBSnoozeScheduler

+ (NSString *)tweakVersionMismatchNotice {
    // 🔴 判据和自检页那一节**用同一个函数读同一个文件**（`NBVersionFromMark`），
    //    不另写一份解析：两处代码一旦走岔，"进 App 没提示但自检页说不一致"
    //    就成了一个新的、只能靠猜的现场。
    NSString *sbMark = [NOTIFYBOX_LEGACY_DIR stringByAppendingPathComponent:@".tweak_ctor"];
    NSString *sbVer = NBVersionFromMark(sbMark);
    NSString *mine = NOTIFYBOX_VER_STR;

    if (!sbVer.length) {
        // 读不到有两种：从没装过 tweak，或者装过但写不进共享目录。
        // 两种都归到"还没重启过"这句话里能落地 —— 因为重启是用户唯一能做的动作，
        // 而它同时也是这两种情况的正确答案。
        return [NSString stringWithFormat:
                @"没读到 SpringBoard 里的 tweak 版本。\n\n"
                @"一般是还差一次重启：装完之后 SpringBoard 仍在跑旧的 dylib，"
                @"启动时没写过标记。\n"
                @"重启一次手机（或注销）后就对上了。\n\n"
                @"这个 App 是 %@。", mine];
    }
    if ([sbVer isEqualToString:mine]) {
        return nil;      // 一致 ⇒ 不打扰用户
    }
    return [NSString stringWithFormat:
            @"SpringBoard 里跑的是 %@，这个 App 是 %@。\n\n"
            @"新装的代码还没生效 —— tweak 的 dylib 只在 SpringBoard 重启时重新加载。\n"
            @"在那之前，临时静音、拦截规则这些都由**旧版逻辑**执行，"
            @"看起来就像「改了没用」。\n\n"
            @"重启一次手机（或注销）即可对上。", sbVer, mine];
}

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
            @"no-container：%@\n"
            @"路径白名单：%@\n"
            @"— 沙箱与数据（白名单验收） —\n"
            @"%@\n"
            @"— 装到磁盘 vs 正在跑 —\n"
            @"%@",
            NBStatusText(s.authorizationStatus),
            NBSettingText(s.alertSetting),
            NBSettingText(s.soundSetting),
            NBSettingText(s.notificationCenterSetting),
            bundle, path,
            NBEntitlementValue(@"application-identifier"),
            NBEntitlementValue(@"platform-application"),
            // 🔴 v0.0.172：这一行现在**应该**显示「没有」。它显示「有」= 装的是旧包。
            NBEntitlementValue(@"com.apple.private.security.no-container"),
            // 数组型 entitlement 会印成「(非标量 type=…)」——那正是"它在"的旁证，
            // 别把它改成"读不到"。真要看内容得解包，不是这一页的事。
            NBEntitlementValue(@"com.apple.security.exception.files.absolute-path.read-write"),
            NBSandboxReport(),
            NBTweakVersionReport()];

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
