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
