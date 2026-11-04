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
//   · 拆 JSON 的次数 ≤4（`scan->decodes` 预算）—— 畸形结构不许把主线程拖住
//     （这段是在长按菜单的回调里**同步**跑的）
//
// 🔴🔴 v0.0.150：**"候选 0 条"有四种完全不同的病因，原来它们长得一模一样**。
//    真机 149 的日志里 24 行有 22 行是 `候选 0 条`，我一条都解释不了：
//      ① payload 里压根没有 `://`            （tweak 侧没捞到）
//      ② 有 `://` 但是 http(s) 且键名不认识  （我的打分规则丢了它）
//      ③ 有 `://` 但被图片/头像名单误杀       （我的过滤丢了它）
//      ④ 有 `://` 但埋得比预算更深            （预算不够）
//    ⇒ 所以这里不只收「候选」，还要**记下每次"丢弃"的账**（seenURL / dropHTTP / dropAsset）。
//    「见过几个 URL」与「最后剩几个」必须能对上，这是这一版唯一的判据来源。
typedef struct {
    int decodes;     // 拆过几次「字符串里的 JSON」
    int seenURL;     // 见过的 URL 值总数（含后面被丢掉的）
    int dropHTTP;    // http(s) 且键名不像链接 ⇒ 丢
    int dropAsset;   // 图片/头像 ⇒ 丢
} NBLinkScan;

static void NBCollectLinks(id node, NSString *key, NSInteger depth,
                           NSMutableArray *out, NBLinkScan *scan) {
    if (!node || depth > 5) return;
    if ([node isKindOfClass:[NSString class]]) {
        NSString *str = (NSString *)node;
        // 🔴🔴 v0.0.149：**字符串里可能再套一层 JSON**。真机就是这样：
        //    `userInfo.ext = "{\"msg_id\":…}"` —— 不拆开，埋在里面的链接完全看不见。
        //    拆之前先看首字符，避免对每个普通字符串都跑一次 JSON 解析。
        if (scan && scan->decodes < 4 && str.length > 8 && str.length <= 4096) {
            unichar c0 = [str characterAtIndex:0];
            if (c0 == '{' || c0 == '[') {
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
                    scan->decodes++;
                    // 用同一个 key 往下走：外层键名（如 `ext`）通常不像链接，
                    // 内层的键名在下一轮迭代里才会用上，这正是我们要的。
                    NBCollectLinks(sub, key, depth + 1, out, scan);
                    // 🔴🔴 拆开之后**立刻返回**，别让这坨 JSON 原文再当链接去试：
                    //    它里面必然含 `://`，而 iOS 16 的 `URLWithString:` 非常宽松，
                    //    会给它造出一个 scheme 乱码的"候选"去和真链接抢分。
                    return;
                }
            }
        }
        NSURL *u = NBLinkURL(str);
        if (!u) return;
        // 🔴 先记「见过」，再问「要不要」—— 顺序不能反。
        //    反过来的话，被丢掉的 URL 就永远不进账本，那"0 候选"就退回到不可解释。
        if (scan) scan->seenURL++;
        if (NBURLIsAsset(str, key)) {
            if (scan) scan->dropAsset++;
            return;
        }
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
        else if (scan) scan->dropHTTP++;
        return;
    }
    if ([node isKindOfClass:[NSDictionary class]]) {
        [(NSDictionary *)node enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            NBCollectLinks(v, [k isKindOfClass:[NSString class]] ? (NSString *)k : nil,
                           depth + 1, out, scan);
        }];
        return;
    }
    if ([node isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)node) NBCollectLinks(v, key, depth + 1, out, scan);
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
    NBLinkScan scan = {0};
    NBCollectLinks(root, nil, 0, cands, &scan);

    // 去重只影响**打不打日志**，不影响返回值 —— 功能与留痕解耦。
    int quiet = NBLinkLogDedupe(payload);
    BOOL wantLog = (quiet >= 0);
    NSString *tail = (quiet > 0)
        ? [NSString stringWithFormat:@" ｜ 静默重复 %d", quiet] : @"";

    if (!cands.count) {
        if (wantLog) {
            if (scan.seenURL > 0) {
                // ② ③ 见过了但被丢 —— 说清是谁丢的，我才能改规则
                NBSharedLog(@"[直达] 候选 0 条 ｜ 拆 JSON %d 次 ｜ 见过 URL %d 个"
                            @"（http无名 %d / 图片 %d）⇒ 全被丢%@",
                            scan.decodes, scan.seenURL, scan.dropHTTP, scan.dropAsset, tail);
            } else {
                // ① 一个 `://` 都没有 ⇒ 只能靠形状看键名，判断该不该去 tweak 侧捞
                NSMutableString *sh = [NSMutableString string];
                NBShapeAppend(sh, root, 0);
                NBSharedLog(@"[直达] 候选 0 条 ｜ 拆 JSON %d 次 ｜ 全文无 :// ｜ 形状 %@%@",
                            scan.decodes, sh, tail);
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
    // 🔴 只打"选中了哪条 + 打分"，不打全部候选：候选数已经给了，
    //    需要看细节时再放开。日志行数是预算。
    if (wantLog) {
        NBSharedLog(@"[直达] 候选 %lu 条 ｜ 拆 JSON %d 次 ｜ 选中(%ld)=%@%@",
                    (unsigned long)cands.count, scan.decodes,
                    (long)[best[0] integerValue], NBLinkForLog((NSString *)v), tail);
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
