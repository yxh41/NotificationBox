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

// v0.0.151：把「见过多少、丢了几个、被谁丢的」做成一本**能对上的账**。
// 🔴 为什么从 struct 换成类：struct 里想放 NSMutableArray，在 ARC 下要么
//    `__unsafe_unretained`（生命周期全靠人守，一不小心就是野指针），要么编不过。
//    类别干净 —— 而且这段只在长按回调里跑，一个对象的开销可以忽略。
// 🔴 为什么必须写在 `@implementation AppLauncher` **之前**：类声明不能嵌在别人的
//    @implementation 里面（那个位置只允许 C 函数与全局变量）。
//
// 三段账，两处必须闭合：
//    sawScheme == parsedOK + dropParse             （含 :// 的都去哪了）
//    parsedOK  == out.count + dropAsset + dropHTTP （解析成功的都去哪了）
@interface NBLinkDiag : NSObject
@property (nonatomic) int decodes;      // 拆过几次「字符串里的 JSON」
@property (nonatomic) int budgetHit;    // 想拆但预算用尽（1 = 还有东西没拆到）
@property (nonatomic) int sawScheme;    // 含 :// 的字符串总数（不管能不能解析）
@property (nonatomic) int parsedOK;     // NBLinkURL 解析通过的
@property (nonatomic) int dropParse;    // 含 :// 却解析不出来
@property (nonatomic) int trimmed;      // 靠「跳过垃圾前缀」才解析出来的（v0.0.154）
@property (nonatomic) int dropAsset;    // 图片/头像
@property (nonatomic) int dropReport;   // 上报/统计（键名或路径自证）
@property (nonatomic) int dropHTTP;     // http(s) 且键名不认识
@property (nonatomic, strong) NSMutableArray<NSString *> *notes;   // 「键(原因)」最多 6 条
@property (nonatomic, copy) NSString *parseSample;                 // 解析失败的第一例
@end

@implementation NBLinkDiag
- (void)note:(NSString *)s {
    if (!s.length) return;
    if (!self.notes) self.notes = [NSMutableArray array];
    if (self.notes.count >= 6) return;      // 日志行是预算
    [self.notes addObject:s];
}
@end

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

// v0.0.151：任何要进日志的外部字符串都必须先压成一行。
// 🔴 解析失败的样本完全可能是带换行的 JSON 片段 —— 一旦带换行进日志，
//    一条记录会被劈成两行，而「结论行」是按行筛的 ⇒ 后半截直接消失。
//    这是"留痕自己把证据弄丢"，和 §4.9⑤ 是同一类。
static NSString *NBOneLine(NSString *s, NSUInteger cap) {
    if (![s isKindOfClass:[NSString class]] || !s.length) return @"";
    NSString *t = [[s componentsSeparatedByCharactersInSet:
                    [NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    t = [t stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
    return (t.length > cap) ? [t substringToIndex:cap] : t;
}


// 只认 `scheme://` 这种。`NSURL` 对 "abc:def" 也会给一个 scheme，太宽。
// v0.0.154：把「前缀垃圾 + 一条合法 URL」的串截回到第一个合法 scheme。
// 🔴 真机样本（2026-11-05 00:20:18，键名 `_acts`）：
//      4,sinaweibo://gotovideo?selected_containerid=231557_2024_1&is_url_deco…
//    前面挂着 `4,`，于是 scheme 变成非法（scheme 必须字母开头）⇒ `URLWithString:` 返回 nil。
//    这条**是真的跳转目标**（微博视频），却因为一个前缀被判成"解析失败"。
//    正解不是放宽 `URLWithString:`（它已经极宽松），而是**跳过垃圾前缀再解析一次**。
// 🔴 只在**解析失败**之后才用它 ⇒ 正常串一次都不会被改动，已有结果零变化。
//    判据：`https://a.com/?next=sms://b` 的第一个 `://` 往回退到 `https` 起点 0 ⇒ 原样返回。
static NSString *NBLinkTrimToScheme(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 5) return s;
    NSUInteger n = s.length;
    for (NSUInteger i = 0; i + 2 < n; i++) {
        if ([s characterAtIndex:i] != ':') continue;
        if ([s characterAtIndex:i + 1] != '/' || [s characterAtIndex:i + 2] != '/') continue;
        // 从 `:` 往回退，凑出 scheme 主体；遇到非 scheme 字符就停
        NSUInteger j = i;
        while (j > 0) {
            unichar c = [s characterAtIndex:j - 1];
            BOOL ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                      (c >= '0' && c <= '9') || c == '+' || c == '.' || c == '-';
            if (!ok) break;
            j--;
        }
        if (j == i) continue;                       // 冒号前面一个字符都没有 ⇒ 不是 scheme
        unichar c0 = [s characterAtIndex:j];
        BOOL alpha = (c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z');
        if (!alpha) continue;                       // `4,sinaweibo://` 里若退到 `4` 开头就不算（继续找下一个 ://）
        return (j == 0) ? s : [s substringFromIndex:j];
    }
    return s;
}

static NSURL *NBLinkURL(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 5) return nil;
    if ([s rangeOfString:@"://"].location == NSNotFound) return nil;
    NSURL *u = [NSURL URLWithString:s];
    if (u && u.scheme.length) return u;
    NSString *t = NBLinkTrimToScheme(s);            // 兜底：跳过垃圾前缀再试一次
    if (!t || [t isEqualToString:s]) return nil;
    u = [NSURL URLWithString:t];
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

// v0.0.151：统计/上报类的地址**永远不配当跳转目标**。
// 🔴 放宽键名匹配（下面那个「含 url/link」）会顺手把 `report_url` / `track_url` /
//    `log_url` 一起收进来 —— 它们也是 http、键名也带 url，点了就是"直达"到一个统计页。
//    宁可漏一条真链接，也不能让用户点出一张空白上报页。
//
// 🔴🔴 v0.0.152：这套名单第一次上场就漏了 —— 真机：
//      [直达] 候选 2 条 ｜ 选中(60,timpush_rpt_url)=
//          https://apiyb.my-imcloud.com/v3/offline_push_report/apns
//    `timpush_rpt_url` = 腾讯 IM 的离线推送**上报**地址。它避开了名单，因为名单里
//    只有全拼 `report`，而这个键名用的是缩写 **`rpt`**。
//    ⇒ 教训：黑名单要**把缩写一并列上**（rpt / stat / rpt_url / apns …），
//      否则"同一件事的另一种写法"就是那个洞。
static BOOL NBKeyIsStatistic(NSString *k) {
    if (![k isKindOfClass:[NSString class]] || !k.length) return NO;
    static NSArray *bad = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = @[@"track", @"report", @"rpt", @"log", @"stat", @"monitor", @"ping",
                @"analytic", @"beacon", @"metric", @"exposure", @"impress",
                @"trace", @"collect", @"event", @"diag",
                // 推送侧专有的上报名（timpush = 腾讯 IM push）
                @"apns", @"timpush", @"offline_push"];
    });
    NSString *low = [k lowercaseString];
    for (NSString *b in bad) {
        if ([low rangeOfString:b].location != NSNotFound) return YES;
    }
    return NO;
}

// v0.0.152：**路径也是证据，而且比键名可靠**。
// 🔴 键名可以起得很随意（`timpush_rpt_url` / `pushUrl` / `ext`），但一条上报的 URL
//    路径几乎一定自证：`/v3/offline_push_report/apns`。
//    所以对"只靠词根认出来的 http"，再过一道路径检查。
// 🔴 只查**安全词**：`log` 会误伤 `/login` 与 `/blog`，`ping` 会误伤 `shopping`，
//    `stat` 会误伤 `status` —— 这三个一律不放。宁可漏，不可误伤真内容页。
static BOOL NBURLIsReportPath(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || !s.length) return NO;
    static NSArray *bad = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = @[@"report", @"rpt", @"track", @"beacon", @"metric", @"analytic",
                @"collect", @"impress", @"exposure", @"statistic", @"diag",
                @"/apns", @"offline_push"];
    });
    NSString *low = [s lowercaseString];
    for (NSString *b in bad) {
        if ([low rangeOfString:b].location != NSNotFound) return YES;
    }
    return NO;
}

// v0.0.151：http(s) 的认可范围从「精确表」放宽到「精确表 ∪ 词根」。
// 🔴 依据是真机 150 的那一行：
//      [直达] 候选 0 条 ｜ 拆 2 次 ｜ 见过 URL 2 个（http无名 2 / 图片 0）⇒ 全被丢
//    ⇒ 有两条 http 链接，键名不在精确表里，被我的打分规则丢了。
//    与其继续猜名字（`pushUrl`? `shareUrl`? `landing`?），不如按**词根**认 ——
//    "键名里带 url/link 的 http 地址"本来就是这个意思。
//    护栏：资产名单（NBURLIsAsset）在前、统计名单（NBKeyIsStatistic）在此，两道都过才收。
// 🔴 v0.0.152：词根命中只是"像"，不是"是" ⇒ 调用方要把它和精确命中**分成两档打分**，
//    并且对 http 再过一道路径检查（见 NBURLIsReportPath）。
static BOOL NBKeyLooksLikeLinkLoose(NSString *k) {
    if (![k isKindOfClass:[NSString class]] || !k.length) return NO;
    if (NBKeyLooksLikeLink(k)) return YES;
    if (NBKeyIsStatistic(k)) return NO;
    static NSArray *roots = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        roots = @[@"url", @"uri", @"link", @"jump", @"h5", @"scheme", @"redirect"];
    });
    NSString *low = [k lowercaseString];
    for (NSString *r in roots) {
        if ([low rangeOfString:r].location != NSNotFound) return YES;
    }
    return NO;
}

// v0.0.149：图片/头像类地址**不配当跳转目标**。
// 🔴 真机样本（v0.0.148 自检）长这样：
//     {"userInfo":{"ext":"{\"msg_id\":\"0\",\"product_code\":\"workbuddy\",…}"}}
//   一旦把双层 JSON 拆开，里面会冒出头像、图标、封面这些 URL —— 它们键名常常就叫
//   `url` / `image`，光靠"键名像链接"根本拦不住，命中后用户点「直达」会打开一张图。
// ⇒ 两条判据一起用：**键名黑名单** + **扩展名**（只看路径部分，忽略 ?query）。
static BOOL NBURLIsAsset(NSString *s, NSString *key) {
    static NSSet *badKeys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        badKeys = [NSSet setWithArray:@[@"avatar", @"avatarurl", @"icon", @"iconurl",
                                        @"image", @"imageurl", @"img", @"imgurl",
                                        @"head", @"headurl", @"logo", @"logourl",
                                        @"pic", @"picurl", @"picture", @"photo",
                                        @"thumb", @"thumbnail", @"cover", @"banner",
                                        @"backgroundimage", @"sticker"]];
    });
    if ([key isKindOfClass:[NSString class]] && key.length
        && [badKeys containsObject:[key lowercaseString]]) return YES;

    static NSArray *exts = nil;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{
        exts = @[@".png", @".jpg", @".jpeg", @".gif", @".webp", @".bmp",
                 @".heic", @".svg", @".ico", @".tiff"];
    });
    NSString *low = [s lowercaseString];
    NSRange q = [low rangeOfString:@"?"];
    NSString *pathPart = (q.location == NSNotFound) ? low : [low substringToIndex:q.location];
    for (NSString *e in exts) {
        if ([pathPart hasSuffix:e]) return YES;
    }
    return NO;
}

// 递归收集候选。**有界**：
//   · 深度 ≤5（v0.0.149 从 3 提到 5：多了一层"字符串里再套 JSON"要拆）
//   · 拆 JSON 的次数 ≤6（`diag.decodes` 预算）—— 畸形结构不许把主线程拖住
//     （这段是在长按菜单的回调里**同步**跑的）
//
// 🔴🔴 v0.0.150：**"候选 0 条"有好几种完全不同的病因，原来它们长得一模一样**。
//    真机 149 的日志里 24 行有 22 行是 `候选 0 条`，我一条都解释不了。
// 🔴🔴🔴 v0.0.151：150 又暴露了第 ⑤ 种 —— 而且**我自己的标签在说谎**。
//    真机那行是：`全文无 :// ｜ 形状 {…acts:[[s323://]]…}`
//    形状明明标了 `s323://`（323 字、含 `://`），结论却说"全文无 ://"。
//    原因：那个分支的条件是 `seenURL == 0`，而 seenURL 只统计**解析成功**的
//    ⇒ 「含 :// 但 NSURL 解析不出来」全都被算进了"全文无 ://"。
//    **分支条件与标签不同源** —— 和 §1.12「提示语与判定必须同源」是同一个病。
//    ⇒ 拆成三段账：
//        sawScheme == parsedOK + dropParse              （含 :// 的都去哪了）
//        parsedOK  == out.count + dropAsset + dropHTTP  （解析成功的都去哪了）
//      两段都必须闭合；标签只在 sawScheme == 0 时才敢说"全文无 ://"。
//    五类病因：① 压根没有 ://  ② http 键名不认识  ③ 图片名单误杀
//             ④ 埋得比预算更深  ⑤ 含 :// 但解析不出来
static void NBCollectLinks(id node, NSString *key, NSInteger depth,
                           NSMutableArray *out, NBLinkDiag *diag) {
    if (!node || depth > 5) return;
    if ([node isKindOfClass:[NSString class]]) {
        NSString *str = (NSString *)node;
        // 🔴🔴 v0.0.149：**字符串里可能再套一层 JSON**。真机就是这样：
        //    `userInfo.ext = "{\"msg_id\":…}"` —— 不拆开，埋在里面的链接完全看不见。
        //    拆之前先看首字符，避免对每个普通字符串都跑一次 JSON 解析。
        unichar c0 = str.length ? [str characterAtIndex:0] : 0;
        BOOL looksJSON = (c0 == '{' || c0 == '[') && str.length > 8 && str.length <= 4096;
        if (looksJSON) {
            if (diag.decodes < 6) {
                NSData *jd = [str dataUsingEncoding:NSUTF8StringEncoding];
                id sub = nil;
                if (jd) {
                    @try {
                        sub = [NSJSONSerialization JSONObjectWithData:jd options:0 error:NULL];
                    } @catch (__unused NSException *e) {
                        sub = nil;
                    }
                }
                if (sub) {
                    diag.decodes++;
                    // 用同一个 key 往下走：外层键名（如 `ext`）通常不像链接，
                    // 内层的键名在下一轮迭代里才会用上，这正是我们要的。
                    NBCollectLinks(sub, key, depth + 1, out, diag);
                    // 🔴🔴 拆开之后**立刻返回**，别让这坨 JSON 原文再当链接去试：
                    //    它里面必然含 `://`，而 iOS 16 的 `URLWithString:` 非常宽松，
                    //    会给它造出一个 scheme 乱码的"候选"去和真链接抢分。
                    return;
                }
            } else {
                // 想拆、看着像、但预算没了 ⇒ 这一条必须留痕（病因④）
                diag.budgetHit = 1;
            }
        }
        // 🔴🔴 v0.0.151：「含不含 ://」和「能不能解析成 URL」是**两件事**，分开记。
        if ([str rangeOfString:@"://"].location == NSNotFound) return;
        diag.sawScheme++;                       // 先记「见过」——顺序不能反
        NSURL *u = NBLinkURL(str);
        if (!u) {                               // ⑤ 含 :// 却解析不出来
            diag.dropParse++;
            if (!diag.parseSample) diag.parseSample = NBOneLine(str, 70);
            [diag note:[NSString stringWithFormat:@"%@(解析失败)", key.length ? key : @"?"]];
            return;
        }
        diag.parsedOK++;
        // 🔴 v0.0.154：这条是**靠截断垃圾前缀**才活下来的（真机样本 `4,sinaweibo://…`）。
        //    必须**当场把 str 归一**，不能等打开时再截：否则"判的串"（资产/上报路径/打分）
        //    和"开的串"不是同一个 —— 那条纪律（同一对象吗）本项目付过学费。
        NSString *trimmedStr = NBLinkTrimToScheme(str);
        if (![trimmedStr isEqualToString:str]) {
            diag.trimmed++;
            [diag note:[NSString stringWithFormat:@"%@(截断前缀)", key.length ? key : @"?"]];
            str = trimmedStr;
        }
        if (NBURLIsAsset(str, key)) {
            diag.dropAsset++;
            [diag note:[NSString stringWithFormat:@"%@(图片)", key.length ? key : @"?"]];
            return;
        }
        // 🔴🔴 v0.0.152：上报/统计在**打分之前**就拦掉，而且不问 scheme。
        //    真机教训：`timpush_rpt_url` 打 60 分被选中，用户点「直达」等于触发一次
        //    离线推送上报请求。上报就是上报 —— 自定义 scheme 也一样。
        if (NBKeyIsStatistic(key)) {
            diag.dropReport++;
            [diag note:[NSString stringWithFormat:@"%@(上报键名)", key.length ? key : @"?"]];
            return;
        }
        NSString *sch = [u.scheme lowercaseString];
        BOOL isHttp = [sch isEqualToString:@"http"] || [sch isEqualToString:@"https"];
        BOOL exact = NBKeyLooksLikeLink(key);            // 精确表命中 = "是链接"
        BOOL keyish = exact || NBKeyLooksLikeLinkLoose(key);   // 词根命中 = "像链接"
        NSInteger score = 0;
        // 🔴 打分就是为了"别把图片/上报地址当跳转"：
        //    自定义 scheme（`app://…`）几乎只可能来自"让你点进去"的意图 ⇒ 优先；
        //    http(s) 太常见（图标/封面/统计上报都是）⇒ 只认"键名像链接"的。
        if (!isHttp)      score = exact ? 100 : 80;
        else if (exact)   score = 60;
        else if (keyish)  score = 45;    // v0.0.152：词根只给 45，低精确一档
        // 🔴🔴 v0.0.152：**只靠词根认出来的 http，还要过一道路径检查**。
        //    例子：`https://apiyb.my-imcloud.com/v3/offline_push_report/apns`
        //    键名可能起得人畜无害（`pushUrl`），但路径自证它是上报。
        //    精确键名（`url`/`link`/`deeplink`）不过这一关 —— 那是"明确告诉你这是链接"，
        //    不能被路径里的 report 字样误杀（`https://news/report/2026-…` 是真内容页）。
        if (score == 45 && NBURLIsReportPath(str)) {
            diag.dropReport++;
            [diag note:[NSString stringWithFormat:@"%@(上报路径)", key.length ? key : @"?"]];
            return;
        }
        // v0.0.151：把键名一起带进候选 —— 打日志时才知道"认的是哪个键"，
        // 否则下次还是只能看到一个数字。
        if (score > 0) {
            [out addObject:@[@(score), str, key.length ? key : @""]];
        } else {
            diag.dropHTTP++;
            [diag note:[NSString stringWithFormat:@"%@(http无名)", key.length ? key : @"?"]];
        }
        return;
    }
    if ([node isKindOfClass:[NSDictionary class]]) {
        [(NSDictionary *)node enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            NBCollectLinks(v, [k isKindOfClass:[NSString class]] ? (NSString *)k : nil,
                           depth + 1, out, diag);
        }];
        return;
    }
    if ([node isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)node) NBCollectLinks(v, key, depth + 1, out, diag);
    }
}

// v0.0.150：把一坨 JSON 的「形状」画成一行（键名 + 类型的速写）。
// 🔴 只画形状，**不打值**：值可能是 4KB 的 JSON，而日志窗口只有 ~50 行。
//    这一行的用处是回答「0 候选时，payload 里到底有些什么键」——
//    没有它，我只能一直猜"是不是埋太深"。
//    `j88` = 88 字的 JSON 字符串（我拆过）；`s12://` = 12 字且含 `://`；`n` = 数字。
static void NBShapeAppend(NSMutableString *out, id node, int depth) {
    if (out.length > 220) return;                 // 硬上限：一行最多 ~240 字
    if (!node) { [out appendString:@"nil"]; return; }
    if ([node isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)node;
        unichar c0 = s.length ? [s characterAtIndex:0] : 0;
        if ((c0 == '{' || c0 == '[') && s.length > 8) {
            [out appendFormat:@"j%lu", (unsigned long)s.length];
        } else if ([s rangeOfString:@"://"].location != NSNotFound) {
            [out appendFormat:@"s%lu://", (unsigned long)s.length];
        } else {
            [out appendFormat:@"s%lu", (unsigned long)s.length];
        }
        return;
    }
    if ([node isKindOfClass:[NSNumber class]]) { [out appendString:@"n"]; return; }
    if ([node isKindOfClass:[NSArray class]]) {
        NSArray *a = (NSArray *)node;
        [out appendFormat:@"a%lu[", (unsigned long)a.count];
        if (a.count && depth < 3) NBShapeAppend(out, a.firstObject, depth + 1);
        [out appendString:@"]"];
        return;
    }
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)node;
        [out appendString:@"{"];
        NSUInteger i = 0;
        for (id k in d) {
            if (i >= 6) { [out appendFormat:@"+%lu", (unsigned long)(d.count - 6)]; break; }
            if (i) [out appendString:@","];
            [out appendString:([k isKindOfClass:[NSString class]] ? (NSString *)k : @"?")];
            [out appendString:@":"];
            if (depth < 3) NBShapeAppend(out, d[k], depth + 1);
            else [out appendString:@"…"];
            i++;
        }
        [out appendString:@"}"];
        return;
    }
    // NSDate / NSData / 私有对象 —— 只报告"有别的东西"，绝不 `description`（会摸锁卡死）
    [out appendString:@"(其它)"];
}

// v0.0.150：同一份 payload 只留痕一次。
// 🔴 为什么非加不可：149 装了之后，**结论行被这一行刷屏了** —— 用户贴回来的 24 行里
//    22 行都是 `候选 0 条`，真正的新信息（payload 现场/统计）全被挤走。
//    但「静默」又不能真的静默：那就退回到"没调用"与"0 候选"同形了。
//    ⇒ 用**内容签名**去重（不是时间）：不同 payload 每条都打，同一条只在首次打，
//      并把「上一批静默了几条」写进下一条 —— 两个方向都留了证据。
//    🔴 签名里绝不放秒数/序号这类每次必变的量，否则等于没去重。
//    🔴 只在主线程调用（长按菜单构建）；ARC 下这个静态变量会被 assign 保留。
static int NBLinkLogDedupe(NSString *payload) {
    static NSString *lastSig = nil;
    static int suppressed = 0;
    NSString *head = payload.length > 64 ? [payload substringToIndex:64] : payload;
    NSString *sig = [NSString stringWithFormat:@"%lu|%@", (unsigned long)payload.length, head];
    if (lastSig && [sig isEqualToString:lastSig]) { suppressed++; return -1; }
    int q = suppressed;
    suppressed = 0;
    lastSig = sig;
    return q;
}

// v0.0.149：链接进日志前先截断。
// 🔴 理由很现实：这段是在长按回调里跑的，日志窗口只有 ~50 行，而拆开双层 JSON 后
//    候选里可能躺着 4KB 的长链接 —— 一条就能把整屏证据挤掉。
//    只留前 72 字 + 总长度，足够分清"认的是哪条"，又不吃行数。
static NSString *NBLinkForLog(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"(非字符串)";
    if (s.length <= 72) return s;
    return [NSString stringWithFormat:@"%@…(共%lu字)", [s substringToIndex:72],
            (unsigned long)s.length];
}

// v0.0.153：候选**名单**里一条只留 40 字。
// 🔴 名单是 3 条挤在同一行里的，用 72 字那份会把一行撑成三行，而日志窗口只有 ~50 行。
//    40 字足够认出"这是哪家域名、哪条路径"，又不会把预算吃光。
static NSString *NBLinkForList(id s) {
    if (![s isKindOfClass:[NSString class]]) return @"(非字符串)";
    if (![s length]) return @"(空)";
    return ([(NSString *)s length] <= 40) ? (NSString *)s
        : [NSString stringWithFormat:@"%@…(%lu)",
           [(NSString *)s substringToIndex:40], (unsigned long)[(NSString *)s length]];
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
    NBLinkDiag *diag = [[NBLinkDiag alloc] init];
    NBCollectLinks(root, nil, 0, cands, diag);

    // 去重只影响**打不打日志**，不影响返回值 —— 功能与留痕解耦。
    int quiet = NBLinkLogDedupe(payload);
    BOOL wantLog = (quiet >= 0);

    NSMutableString *tail = [NSMutableString string];
    if (quiet > 0) [tail appendFormat:@" ｜ 静默重复 %d", quiet];
    if (diag.budgetHit) [tail appendString:@" ｜ 预算用尽"];
    // 🔴 v0.0.154：有几条是靠「跳过垃圾前缀」才认出来的。
    //    不给这个数，"截断"就是一条看不见的暗改（本项目的旧病）。
    if (diag.trimmed > 0) [tail appendFormat:@" ｜ 截断前缀 %d", diag.trimmed];

    // 丢弃明细：四个数字 + 涉及的键名。键名才是"下次该改哪条规则"的唯一依据。
    NSString *loss = [NSString stringWithFormat:@"丢 %d(图片)/%d(上报)/%d(http无名)/%d(解析失败)",
                      diag.dropAsset, diag.dropReport, diag.dropHTTP, diag.dropParse];
    NSString *keys = diag.notes.count ? [diag.notes componentsJoinedByString:@","] : @"-";

    if (!cands.count) {
        if (wantLog) {
            if (diag.sawScheme == 0) {
                // ① 真的一个 `://` 都没有。🔴 这个标签现在**名副其实**了：
                //    条件是 sawScheme == 0，而 sawScheme 统计的是"含 :// 的字符串"，
                //    不是"能解析成 URL 的"。（v0.0.150 之前这两件事被混成一件，
                //    于是含 :// 却解析失败的会被错报成"全文无 ://"。）
                NSMutableString *sh = [NSMutableString string];
                NBShapeAppend(sh, root, 0);
                NBSharedLog(@"[直达] 候选 0 条 ｜ 拆 %d 次 ｜ 全文无 :// ｜ 形状 %@%@",
                            diag.decodes, sh, tail);
            } else {
                // ② ③ ⑤ 见过了但全被丢 —— 说清是谁丢的、键叫什么
                NSString *sample = diag.parseSample.length
                    ? [NSString stringWithFormat:@" ｜ 样本 %@", diag.parseSample] : @"";
                NBSharedLog(@"[直达] 候选 0 条 ｜ 拆 %d 次 ｜ 见过 :// %d 个 ｜ %@ ｜ 键 %@%@%@",
                            diag.decodes, diag.sawScheme, loss, keys, sample, tail);
            }
        }
        return nil;
    }
    [cands sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSInteger sa = [((NSArray *)a)[0] integerValue];
        NSInteger sb = [((NSArray *)b)[0] integerValue];
        if (sa == sb) return NSOrderedSame;
        return (sa > sb) ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSArray *best = (NSArray *)cands.firstObject;
    id v = (best.count > 1) ? best[1] : nil;
    NSString *key = (best.count > 2 && [best[2] isKindOfClass:[NSString class]]) ? best[2] : @"";
    // 🔴🔴 v0.0.153：候选**条数** ≠ **不同目标数**。同一个 URL 可能从根上的 `userInfo`
    //    和 `ctx.userInfo` 各挂一份（v0.0.152 真机形状实测就是这样两条 path 都有），
    //    两次都进 cands ⇒ 计数虚高，用户会以为"有 3 个能跳的地方"。
    //    两个数一起给，账才对得上。（同 §4「一个 0/一个 N 必须能解释是哪种」）
    NSMutableSet *uniq = [NSMutableSet set];
    for (NSArray *c in cands) {
        if (c.count > 1 && [c[1] isKindOfClass:[NSString class]]) [uniq addObject:c[1]];
    }
    if (wantLog) {
        NBSharedLog(@"[直达] 候选 %lu 条(不同 %lu) ｜ 拆 %d 次 ｜ 见过 :// %d 个 ｜ %@ ｜ 选中(%ld,%@)=%@%@",
                    (unsigned long)cands.count, (unsigned long)uniq.count, diag.decodes,
                    diag.sawScheme, loss,
                    (long)[best[0] integerValue], key.length ? key : @"?",
                    NBLinkForLog((NSString *)v), tail);
        // 🔴🔴 v0.0.153：只打"选中哪条"是**不够的**，而且正是这个缺口让 151 的洞活了下来：
        //    151 那屏候选 2 条，选中了上报 URL；可如果那天恰好还有一条真链接分更高，
        //    日志只会说"选中了真链接"，那条上报 URL 就永远藏在名单里看不见，
        //    等换一条"没有真链接"的通知，它就会被选中。
        //    ⇒ 名单里前 3 条（分数 + 键名 + 40 字 URL）必须打出来。
        //    只有 1 条时不打：没被选中的什么都没有，`选中(…)` 那行已经说全了。
        if (cands.count > 1) {
            // 🔴 v0.0.154：名单按 **URL 去重**后再打。
            //    真机（2026-11-05 00:20:38）出现过 `候选 3 条(不同 1)` 却打了 3 行一模一样的
            //    名单：同一个 bilibili 链接从 `link` 和两个 `url` 各命中一次。
            //    那样既浪费预算，又和「不同 1」当着读者的面打架。
            //    去重后一条就够，并且把「从哪些键命中、命中几次」压进同一条。
            NSMutableArray *parts = [NSMutableArray array];
            NSMutableSet *done = [NSMutableSet set];
            for (NSArray *c in cands) {
                if (parts.count >= 3) break;
                if (c.count < 2 || ![c[1] isKindOfClass:[NSString class]] || ![(NSString *)c[1] length]) continue;
                NSString *one = (NSString *)c[1];
                if ([done containsObject:one]) continue;
                [done addObject:one];
                NSInteger times = 0;
                NSMutableArray *ks = [NSMutableArray array];
                for (NSArray *c2 in cands) {   // 同一 URL 出现几次、用过哪些键名
                    if (c2.count > 1 && [c2[1] isKindOfClass:[NSString class]]
                        && [(NSString *)c2[1] isEqualToString:one]) {
                        times++;
                        NSString *k2 = (c2.count > 2 && [c2[2] isKindOfClass:[NSString class]]
                                        && [(NSString *)c2[2] length]) ? (NSString *)c2[2] : @"?";
                        if (![ks containsObject:k2] && ks.count < 3) [ks addObject:k2];
                    }
                }
                [parts addObject:[NSString stringWithFormat:@"%ld:%@%@=%@",
                                  (long)[c[0] integerValue],
                                  [ks componentsJoinedByString:@","],
                                  (times > 1) ? [NSString stringWithFormat:@"(×%ld)", (long)times] : @"",
                                  NBLinkForList(one)]];
            }
            // 🔴 「另 N 条」按**不同目标**算（和 `不同 M` 同口径），不是按候选条数算
            NBSharedLog(@"[直达] 候选名单 %@%@", [parts componentsJoinedByString:@" ｜ "],
                        (uniq.count > parts.count)
                        ? [NSString stringWithFormat:@" ｜ …另 %lu 个不同目标",
                           (unsigned long)(uniq.count - parts.count)] : @"");
        }
    }
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
