#import "AppLauncher.h"
#import "NotifyCommon.h"

// ================= v0.0.118：按 bundleId 打开 App 的**唯一**实现 =================
// 三条路，顺序不能反（每一条都比上一条更不可靠，越往后越像"求它"）：
//    ① `LSApplicationWorkspace -openApplicationWithBundleID:`：最直接、不需要目标 App
//       声明任何 URL scheme。但它**不在任何公开头文件里** ⇒ 只能运行时拿。
//    ①b `UIApplication -launchApplicationWithIdentifier:suspended:`：UIKit 私有，iOS 16 上
//       不保证还在 ⇒ 必须先 `respondsToSelector:` 探。
//    ② URL scheme（从那个 App 的 Info.plist 里读 `CFBundleURLSchemes` 第一个）：
//       最后兜底。缺点很明显 —— **很多 App 压根没声明 scheme**，所以只能兜一部分。
//
// 🔴 为什么每条分支都要写日志：这条路失败的样子是"点了没反应"，
//    和"手势没触发"、"菜单没弹"、"App 没装"三种完全不同的病因在屏幕上长得一模一样。
//    日志里留一句 `[打开] bundle=… ⇒ 结果 via=…`，下次一眼就能分开。
//    （本项目通用铁律：不报错的失败最难查。）
//
// 🔴 绝不在这里弹任何界面：调用方（长按菜单）触发的那一刻，菜单正在收起，
//    此时 present 一个 alert 属于「present 正在进行时又 present」——
//    真机上表现为**被系统静默丢掉**，用户等不到任何提示。提示交给调用方用 toast 做。
@implementation AppLauncher

#pragma mark - 路 ① 的前置：拿 workspace 单例

+ (nullable id)nbWorkspace {
    Class WS = NSClassFromString(@"LSApplicationWorkspace");
    if (!WS) return nil;
    if (![WS respondsToSelector:@selector(defaultWorkspace)]) return nil;
    id ws = nil;
    @try {
        ws = [WS performSelector:@selector(defaultWorkspace)];
    } @catch (__unused NSException *e) {
        ws = nil;
    }
    return ws;
}

#pragma mark - "这个 App 还在不在本机"

// 🔴 返回 YES 表示"装着呢**或者查不了**"。
//    查不了时**不许**当成没装：那会让一台机器上所有记录都打不开，
//    而真正的原因只是 `LSApplicationProxy` 在这个进程里不可用。
+ (BOOL)nbInstalled:(NSString *)bid {
    Class P = NSClassFromString(@"LSApplicationProxy");
    if (!P) return YES;
    if (![P respondsToSelector:@selector(applicationProxyForIdentifier:)]) return YES;
    id proxy = nil;
    @try {
        proxy = [P performSelector:@selector(applicationProxyForIdentifier:) withObject:bid];
    } @catch (__unused NSException *e) {
        proxy = nil;
    }
    return (proxy != nil);
}

#pragma mark - 路 ② 的前置：从那个 App 的 Info.plist 里取第一个 URL scheme

+ (nullable NSString *)nbFirstURLScheme:(NSString *)bid {
    Class P = NSClassFromString(@"LSApplicationProxy");
    if (!P || ![P respondsToSelector:@selector(applicationProxyForIdentifier:)]) return nil;
    id proxy = nil;
    @try {
        proxy = [P performSelector:@selector(applicationProxyForIdentifier:) withObject:bid];
    } @catch (__unused NSException *e) {
        proxy = nil;
    }
    if (!proxy) return nil;
    if (![proxy respondsToSelector:NSSelectorFromString(@"bundleURL")]) return nil;
    NSURL *u = nil;
    @try {
        u = [proxy valueForKey:@"bundleURL"];
    } @catch (__unused NSException *e) {
        u = nil;
    }
    if (![u isKindOfClass:[NSURL class]]) return nil;
    NSString *infoPath = [[u path] stringByAppendingPathComponent:@"Info.plist"];
    if (!infoPath.length) return nil;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    if (![info isKindOfClass:[NSDictionary class]]) return nil;

    // `CFBundleURLTypes` 是数组，每一项里 `CFBundleURLSchemes` 又是数组。
    // 🔴 逐层判类型：这两个键在越狱/老 App 里被写成非数组的情况真实存在，
    //    直接 `objectAtIndex:` 就是一条 `-[__NSCFString objectAtIndex:]: unrecognized selector` ⇒ 闪退。
    id types = info[@"CFBundleURLTypes"];
    if (![types isKindOfClass:[NSArray class]]) return nil;
    for (id one in (NSArray *)types) {
        if (![one isKindOfClass:[NSDictionary class]]) continue;
        id schemes = ((NSDictionary *)one)[@"CFBundleURLSchemes"];
        if (![schemes isKindOfClass:[NSArray class]]) continue;
        for (id s in (NSArray *)schemes) {
            if (![s isKindOfClass:[NSString class]]) continue;
            NSString *str = (NSString *)s;
            if (str.length) return str;
        }
    }
    return nil;
}

#pragma mark - 对外唯一入口

+ (NBOpenAppResult)openBundle:(nullable NSString *)bundleId {
    if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0) {
        NBSharedLog(@"[打开] bundle=(空) ⇒ 没有可打开的目标");
        return NBOpenAppResultNoBundle;
    }

    if (![self nbInstalled:bundleId]) {
        NBSharedLog(@"[打开] %@ ⇒ App 不在本机（LSApplicationProxy 查不到）", bundleId);
        return NBOpenAppResultNotInstalled;
    }

    // ---------- 路 ①：LSApplicationWorkspace ----------
    id ws = [self nbWorkspace];
    SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (ws && [ws respondsToSelector:sel]) {
        BOOL ok = NO;
        @try {
            // 🔴 返回值是 BOOL，`performSelector:` 交付不出 BOOL（它返回 id）
            //    ⇒ 必须自己取 IMP 强转调用。强转签名要和真实签名**逐字节对齐**：
            //      (id self, SEL _cmd, NSString *bundleId) → BOOL
            BOOL (*fn)(id, SEL, NSString *) =
                (BOOL (*)(id, SEL, NSString *))[ws methodForSelector:sel];
            if (fn) ok = fn(ws, sel, bundleId);
        } @catch (__unused NSException *e) {
            ok = NO;
        }
        if (ok) {
            NBSharedLog(@"[打开] %@ ⇒ 成功 via=workspace", bundleId);
            return NBOpenAppResultSent;
        }
        NBSharedLog(@"[打开] %@ ⇒ workspace 回 NO，改试下一条路", bundleId);
    } else {
        NBSharedLog(@"[打开] %@ ⇒ 没有 workspace 或没有 openApplicationWithBundleID:", bundleId);
    }

    // ---------- 路 ①b：UIApplication -launchApplicationWithIdentifier:suspended: ----------
    // 这是 UIKit 的私有方法，iOS 16 上**不保证还在**（Apple 逐版在收）。
    // 🔴 只在路 ① 失败后才试，而且**先 `respondsToSelector:` 探**：
    //    不存在就跳过并留一行日志，绝不硬调（硬调是 unrecognized selector ⇒ 闪退）。
    // 🔴 存在性本身也从不当结论 —— 这条路的成败只看返回值 + 日志。
    UIApplication *app = [UIApplication sharedApplication];
    SEL selLaunch = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if (app && [app respondsToSelector:selLaunch]) {
        BOOL ok2 = NO;
        @try {
            void (*fn2)(id, SEL, NSString *, BOOL) =
                (void (*)(id, SEL, NSString *, BOOL))[app methodForSelector:selLaunch];
            if (fn2) {
                fn2(app, selLaunch, bundleId, NO);
                ok2 = YES;   // 这个方法返回 void ⇒ "没抛异常"就算发出去
            }
        } @catch (__unused NSException *e) {
            ok2 = NO;
        }
        if (ok2) {
            NBSharedLog(@"[打开] %@ ⇒ 已发请求 via=launchApplication", bundleId);
            return NBOpenAppResultSent;
        }
    }

    // ---------- 路 ②：URL scheme ----------
    NSString *scheme = [self nbFirstURLScheme:bundleId];
    if (scheme.length) {
        NSString *str = [scheme stringByAppendingString:@"://"];
        NSURL *u = [NSURL URLWithString:str];
        if (u) {
            // 🔴 用 `openURL:options:completionHandler:`，不用废弃的 `openURL:`。
            //    completion 里不判成功：那个 BOOL 只说明"系统收下了请求"，不说明 App 起来了，
            //    拿它当"打开成功"就是假判据。
            [[UIApplication sharedApplication] openURL:u options:@{}
                                    completionHandler:nil];
            NBSharedLog(@"[打开] %@ ⇒ 已发请求 via=scheme(%@)", bundleId, scheme);
            return NBOpenAppResultSent;
        }
    }
    NBSharedLog(@"[打开] %@ ⇒ 三条路都走不通（无 workspace、无 launchApplication、无 URL scheme）", bundleId);
    return NBOpenAppResultNoWay;
}

#pragma mark - v0.0.133：从 payload 里找深链

// 只认 `scheme://` 这种。`NSURL` 对 "abc:def" 也会给一个 scheme，太宽。
static NSURL *NBLinkURL(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 5) return nil;
    if ([s rangeOfString:@"://"].location == NSNotFound) return nil;
    NSURL *u = [NSURL URLWithString:s];
    if (!u || !u.scheme.length) return nil;
    return u;
}

// 已知"这是跳转链接"的键名（小写比较）。
static BOOL NBKeyLooksLikeLink(NSString *k) {
    if (![k isKindOfClass:[NSString class]] || !k.length) return NO;
    static NSSet *S = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        S = [NSSet setWithArray:@[
            @"url", @"link", @"deeplink", @"deep_link", @"deeplinkurl", @"deeplink_url",
            @"jumpurl", @"jump_url", @"openurl", @"open_url",
            @"targeturl", @"target_url", @"weburl", @"web_url",
            @"redirect", @"redirecturl", @"redirect_url",
            @"scheme", @"route", @"router", @"path", @"page",
            @"contenturl", @"content_url", @"detailurl", @"detail_url",
            // v0.0.135：tweak 侧新塞的两类线索的固定键名
            //   `action` = 系统点通知真要执行的 URL（defaultAction.launchURL / launchSessionAction）
            //   `launchurl` / `actionurl` = 同一个东西在别处可能叫的名字
            @"action", @"actionurl", @"action_url", @"launchurl", @"launch_url"
        ]];
    });
    return [S containsObject:[k lowercaseString]];
}

// 递归收集候选。**有界**：深度 ≤3 —— payload 是外部数据，
// 没有上限的话一个畸形结构就能把主线程拖住（而这是长按菜单的回调里同步跑的）。
static void NBCollectLinks(id node, NSString *key, NSInteger depth, NSMutableArray *out) {
    if (!node || depth > 3) return;
    if ([node isKindOfClass:[NSString class]]) {
        NSURL *u = NBLinkURL((NSString *)node);
        if (!u) return;
        NSString *sch = [u.scheme lowercaseString];
        BOOL isHttp = [sch isEqualToString:@"http"] || [sch isEqualToString:@"https"];
        BOOL keyish = NBKeyLooksLikeLink(key);
        NSInteger score = 0;
        // 🔴 打分就是为了"别把图片地址当跳转"：
        //    自定义 scheme（`app://…`）几乎只可能来自"让你点进去"的意图 ⇒ 优先；
        //    http(s) 太常见（图标/封面/统计上报都是）⇒ **只认已知键名**。
        if (!isHttp)      score = keyish ? 100 : 80;
        else if (keyish)  score = 60;
        if (score > 0) [out addObject:@[@(score), (NSString *)node]];
        return;
    }
    if ([node isKindOfClass:[NSDictionary class]]) {
        [(NSDictionary *)node enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            NBCollectLinks(v, [k isKindOfClass:[NSString class]] ? (NSString *)k : nil, depth + 1, out);
        }];
        return;
    }
    if ([node isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)node) NBCollectLinks(v, key, depth + 1, out);
    }
}

+ (nullable NSString *)deeplinkFromPayload:(nullable NSString *)payload {
    if (![payload isKindOfClass:[NSString class]] || !payload.length) return nil;
    NSData *d = [payload dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return nil;
    id root = nil;
    @try {
        root = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    } @catch (__unused NSException *e) {
        root = nil;
    }
    if (!root) return nil;

    NSMutableArray *cands = [NSMutableArray array];
    NBCollectLinks(root, nil, 0, cands);
    if (!cands.count) return nil;
    [cands sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSInteger sa = [((NSArray *)a)[0] integerValue];
        NSInteger sb = [((NSArray *)b)[0] integerValue];
        if (sa == sb) return NSOrderedSame;
        return (sa > sb) ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSArray *best = (NSArray *)cands.firstObject;
    id v = (best.count > 1) ? best[1] : nil;
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

+ (NBOpenAppResult)openBundle:(nullable NSString *)bundleId deeplink:(nullable NSString *)deeplink {
    NSURL *u = NBLinkURL(deeplink);
    if (!u) {
        if (deeplink.length) {
            NBSharedLog(@"[直开] 链接不可用(%@) ⇒ 兜底只打开 App", deeplink);
        }
        return [self openBundle:bundleId];
    }
    NSString *sch = [u.scheme lowercaseString];
    BOOL isHttp = [sch isEqualToString:@"http"] || [sch isEqualToString:@"https"];
    // 🔴 completion 的 YES 只说明"系统收下了请求"，**不是**"App 起来了"
    //    ⇒ 只有 NO（连请求都没被收下）才拿来兜底。同 `openBundle:` 里那条纪律。
    [[UIApplication sharedApplication] openURL:u options:@{}
                            completionHandler:^(BOOL ok) {
        if (!ok) {
            NBSharedLog(@"[直开] %@ 打不开 ⇒ 兜底只打开 App", deeplink);
            [AppLauncher openBundle:bundleId];
        }
    }];
    NBSharedLog(@"[直开] bundle=%@ via=%@ scheme=%@", bundleId,
                isHttp ? @"universal" : @"custom", sch);
    return NBOpenAppResultSent;
}

+ (nullable NSString *)textForResult:(NBOpenAppResult)r {
    switch (r) {
        case NBOpenAppResultSent:
            // 成功不提示：App 已经切到前台了，那就是最直接的反馈。
            return nil;
        case NBOpenAppResultNoBundle:
            return @"这条记录没有 App 标识，打不开";
        case NBOpenAppResultNotInstalled:
            return @"这个 App 已经不在本机了";
        case NBOpenAppResultNoWay:
            return @"这个 App 打不开（系统接口不可用，它也没声明跳转方式）";
    }
    return @"打不开这个 App";
}

@end
