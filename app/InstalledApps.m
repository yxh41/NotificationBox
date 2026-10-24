#import "InstalledApps.h"
#import "NotifyStore.h"
#import "NotifyCommon.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

@implementation InstalledApp
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ note=%ld%@>", self.name, self.bundleId,
            (long)self.noteCount, self.onlyInHistory ? @" 仅历史" : @""];
}
@end

static NSArray<InstalledApp *> *gCache = nil;
static NSMutableArray<NSString *> *gDiag = nil;

// 无参、返回对象的消息。用它访问 LSApplicationWorkspace 这类私有 API：
// 🔴 不用 performSelector: —— 项目开 -Werror，传变量 SEL 会触发
//    -Warc-performSelector-leaks，直接编译失败。
// 🔴 也不用声明假 @interface —— 私有 API 的方法名/签名会随系统版本变，
//    声明错了链接期不报、运行期崩。走 objc_msgSend + respondsToSelector 探一次最稳。
typedef id (*NBIdMsgSend)(id, SEL);
static id NBCallId(id target, NSString *selName) {
    if (!target || !selName.length) return nil;
    SEL s = NSSelectorFromString(selName);
    if (!s) return nil;
    @try {
        if (![target respondsToSelector:s]) return nil;
        return ((NBIdMsgSend)objc_msgSend)(target, s);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

// 一个对象参数版本（v0.0.43：`+[LSApplicationProxy applicationProxyForIdentifier:]`）。
// 同上，不走 performSelector:（带参版本触发的是 -Warc-performSelector-leaks 的另一条路径）。
typedef id (*NBIdMsgSend1)(id, SEL, id);
static id NBCallId1(id target, NSString *selName, id arg) {
    if (!target || !selName.length) return nil;
    SEL s = NSSelectorFromString(selName);
    if (!s) return nil;
    @try {
        if (![target respondsToSelector:s]) return nil;
        return ((NBIdMsgSend1)objc_msgSend)(target, s, arg);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

// 🔴 必须是可变参数。写的时候很容易先写成单参数（"反正就是往数组里塞一行"），
//    然后调用处全是 NBAddDiag(@"...%lu...", n) —— 编译器报的是
//    "too many arguments to function call"，一堆报错全指在这个定义上，看着像别处的问题。
static void NBAddDiag(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = fmt ? [[NSString alloc] initWithFormat:fmt arguments:ap] : @"?";
    va_end(ap);
    if (!gDiag) gDiag = [NSMutableArray array];
    [gDiag addObject:line ?: @"?"];
}

#pragma mark - v0.0.43 取值工具（**每个键单独 @try**）

// 读一个**字符串**属性。键不存在、值类型不符、读的时候抛异常 —— 一律返回 nil。
// 🔴🔴 为什么坚持"逐键"而不是"逐项"：
//      v0.0.42 的真机 bug 现场是三个键共用一个 @try（`bundleIdentifier` 读成功了，
//      随后 `localizedName` 抛异常 ⇒ 整个 App 被丢弃，连已经读到的 bundle 一起丢）。
//      `LSApplicationProxy` 是私有类，占位 App / 扩展 / 已删记录都可能让某个键抛。
//      ⇒ 一个键读不出来，只该让**这个键**作废，不该让这个 App 作废。
// 🔴 顺带把首尾空白去掉：真机上见过 `@" 微信 "` 这种值，直接显示会多出空隙。
static NSString *NBStrForKey(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try {
        id v = [obj valueForKey:key];
        if ([v isKindOfClass:[NSString class]]) {
            NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (s.length) return s;
        }
    } @catch (__unused NSException *e) {
        return nil;
    }
    return nil;
}

// 读一个**路径**属性。私有 API 有的回 `NSURL`、有的回 `NSString`（不同系统版本不一样）。
static NSString *NBPathForKey(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try {
        id v = [obj valueForKey:key];
        if ([v isKindOfClass:[NSURL class]]) return [(NSURL *)v path];
        if ([v isKindOfClass:[NSString class]]) {
            NSString *s = (NSString *)v;
            if (s.length) return s;
        }
    } @catch (__unused NSException *e) {
        return nil;
    }
    return nil;
}

// 名字里有没有汉字（含 CJK 部首 / 兼容汉字 / 全角标点）。
static BOOL NBHasCJK(NSString *s) {
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= 0x2E80 && c <= 0x9FFF) return YES;
        if (c >= 0xF900 && c <= 0xFAFF) return YES;
        if (c >= 0xFF00 && c <= 0xFFEF) return YES;
    }
    return NO;
}

// 在若干候选里挑一个：**优先带汉字的**，其次第一个非空。
// 🔴 为什么需要这条规则：v0.0.42 真机反馈「云闪付 / 米家 / 京东 / 小红书显示的不是中文名」。
//    用户的手机是中文环境，界面上出现 `Mi Home`、`UPay`、`jdmobile` 就是 bug。
//    而这个项目里能拿到名字的地方有三处（系统本地化名 / Info.plist / 本地化 strings），
//    它们谁给英文、谁给中文并不固定 ⇒ 候选全收进来，再按"有汉字优先"挑一次。
// 🟢 副作用可控：英文名本来就是英文的 App（QQ / Telegram）不受影响 —— 没有汉字候选时取第一个。
static NSString *NBPickName(NSArray<NSString *> *cands) {
    NSString *first = nil;
    for (NSString *s in cands) {
        if (!s.length) continue;
        if (!first) first = s;
        if (NBHasCJK(s)) return s;
    }
    return first;
}

// 最后一层兜底：bundle 末段（`com.xiaomi.mihome` → `mihome`）。
// 🔴 这是**最坏情况**，不是"默认值"：调用它之前应该已经试过系统名和 Info.plist。
//    在 v0.0.43 之前它被当成主路径用，所以云闪付显示 `cup`、米家显示 `mihome`。
static NSString *NBLastSegmentName(NSString *bid) {
    NSString *last = [[bid componentsSeparatedByString:@"."] lastObject];
    return last.length ? last : bid;
}

// 从一个 `.app` 目录里读显示名。读不到返回 nil（**不要**在这里兜底，兜底是调用方的事）。
// 取值顺序：本地化 DisplayName → DisplayName → 本地化 Name → Name，然后按"有汉字优先"挑。
// 🔴 为什么要读 `zh-Hans.lproj/InfoPlist.strings`：很多 App 顶层 `CFBundleDisplayName`
//    写的是英文（或干脆没有这个键），中文名放在本地化表里。只读 Info.plist 顶层，
//    就会"名字拿到了、但是英文"—— 在用户眼里和"没拿到"一样糟。
// 🔴 `InfoPlist.strings` 在设备上是 **bplist**（不是文本），`dictionaryWithContentsOfFile:` 能读。
static NSString *NBNameFromAppBundle(NSString *path) {
    if (!path.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];

    // `bundleContainerURL` 给的是容器目录（`.../<UUID>`），里面才是 `Xxx.app`
    NSString *app = path;
    if (![app hasSuffix:@".app"]) {
        NSString *hit = nil;
        NSArray *subs = [fm contentsOfDirectoryAtPath:app error:nil];
        for (NSString *s in subs) {
            if (![s hasSuffix:@".app"]) continue;
            hit = [app stringByAppendingPathComponent:s];
            break;
        }
        if (!hit) return nil;
        app = hit;
    }

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [app stringByAppendingPathComponent:@"Info.plist"]];
    if (![info isKindOfClass:[NSDictionary class]]) return nil;

    // 本地化表只读**一次**（上面两个循环各读一遍的话，每个 App 要多读两次文件）
    NSMutableArray<NSDictionary *> *tables = [NSMutableArray array];
    for (NSString *lp in @[@"zh-Hans.lproj", @"zh_CN.lproj"]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                           [[app stringByAppendingPathComponent:lp]
                            stringByAppendingPathComponent:@"InfoPlist.strings"]];
        if ([d isKindOfClass:[NSDictionary class]]) [tables addObject:d];
    }

    // 优先级：本地化 DisplayName → 顶层 DisplayName → 本地化 Name → 顶层 Name
    // （`NBPickName` 会在这些候选里优先挑带汉字的那个，所以顺序只是"同等条件下"的次序）
    NSMutableArray<NSString *> *c = [NSMutableArray array];
    for (NSString *key in @[@"CFBundleDisplayName", @"CFBundleName"]) {
        for (NSDictionary *d in tables) {
            // 复用 NBStrForKey：KVC 在 NSDictionary 上等价于 objectForKey:，同样带 @try
            NSString *v = NBStrForKey(d, key);
            if (v.length) [c addObject:v];
        }
        NSString *v = NBStrForKey(info, key);
        if (v.length) [c addObject:v];
    }

    return NBPickName(c);
}

// 从一个 `LSApplicationProxy` 上解析显示名。全部来源都失败返回 nil。
// `srcOut`（可为 NULL）回报名字是从哪儿来的，只用于诊断。
// 🔴 只有"手上一个汉字都没有"时才去读 Info.plist —— 读文件是 I/O，
//    200 个 App 全都读一遍没必要；系统本地化名已经是中文时它就是最权威的答案。
static NSString *NBNameFromProxy(id proxy, NSString **srcOut) {
    if (srcOut) *srcOut = nil;
    if (!proxy) return nil;

    NSMutableArray<NSString *> *c = [NSMutableArray array];
    // 这四个键有的系统版本有、有的没有。**逐键读**，不存在的键不构成失败。
    for (NSString *k in @[@"localizedName", @"localizedShortName", @"displayName", @"itemName"]) {
        NSString *v = NBStrForKey(proxy, k);
        if (v.length) [c addObject:v];
    }
    NSString *picked = NBPickName(c);
    NSString *src = picked.length ? @"系统名" : nil;

    if (!(picked.length && NBHasCJK(picked))) {
        NSString *path = NBPathForKey(proxy, @"bundleURL");
        if (!path.length) path = NBPathForKey(proxy, @"resolvedInstallationURL");
        if (!path.length) path = NBPathForKey(proxy, @"bundleContainerURL");
        NSString *fromPlist = path.length ? NBNameFromAppBundle(path) : nil;
        if (fromPlist.length) {
            if (!picked.length || NBHasCJK(fromPlist)) {
                picked = fromPlist;
                src = @"Info.plist";
            }
        }
    }
    if (srcOut) *srcOut = src;
    return picked;
}

// 把 CoreServices 带进来（`LSApplicationWorkspace` / `LSApplicationProxy` 都在里面）。
// 🔴 绝对路径在 roothide 上可能被重定向，所以先用裸名让 dyld 自己找，再退回绝对路径。
static BOOL NBEnsureCoreServices(void) {
    if (NSClassFromString(@"LSApplicationWorkspace")) return YES;
    const char *cands[] = {
        "CoreServices",
        "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
    };
    for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
        void *h = dlopen(cands[i], RTLD_LAZY);
        if (h && NSClassFromString(@"LSApplicationWorkspace")) return YES;
    }
    return NO;
}

// 定向解析**单个** bundle 的显示名（不做全量枚举）。
// 用途：库里来过通知、但枚举没列出它的 App（已卸载 / 某个键抛异常被跳过的那几个）。
// 🔴 为什么不靠 `NBViaScan`：那个要遍历上万个目录，为几个 App 跑一遍不值。
//    这条只需要一次 `+applicationProxyForIdentifier:` + 一次 Info.plist 读。
static NSString *NBNameForBundle(NSString *bid) {
    if (!bid.length) return nil;
    NBEnsureCoreServices();
    Class pcls = NSClassFromString(@"LSApplicationProxy");
    if (!pcls) return nil;
    id proxy = NBCallId1((id)pcls, @"applicationProxyForIdentifier:", bid);
    if (!proxy) return nil;
    return NBNameFromProxy(proxy, NULL);
}

#pragma mark - 路 1：LSApplicationWorkspace

// 返回 @{bid: name}；失败返回 nil
static NSDictionary<NSString *, NSString *> *NBViaWorkspace(void) {
    if (!NBEnsureCoreServices()) {
        NBAddDiag(@"LSApplicationWorkspace：类找不到（CoreServices 没能加载）");
        return nil;
    }
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    id ws = NBCallId((id)cls, @"defaultWorkspace");
    if (!ws) {
        NBAddDiag(@"LSApplicationWorkspace：defaultWorkspace 返回 nil");
        return nil;
    }
    id raw = NBCallId(ws, @"allInstalledApplications");
    if (![raw isKindOfClass:[NSArray class]]) {
        NBAddDiag(@"LSApplicationWorkspace：allInstalledApplications 没给数组（cls=%@）",
                  raw ? NSStringFromClass([raw class]) : @"nil");
        return nil;
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *fallbacks = [NSMutableArray array];
    NSInteger skipped = 0, fromSys = 0, fromPlist = 0, fromLastSeg = 0;

    for (id proxy in (NSArray *)raw) {
        // 🔴🔴 v0.0.43 的修法：**先只读 bundleIdentifier**，读到了这个 App 就归属了。
        //     后面不管哪个键抛异常、返回空，都只影响"名字"，不许把这个 App 丢掉。
        //     v0.0.42 是三个键共用一个 @try，`localizedName` 一抛就 `continue` 到
        //     下一条 ⇒ App 从名单里消失 ⇒ 列表那行退化成 bundle 末段（真机 bug 症状）。
        NSString *bid = NBStrForKey(proxy, @"bundleIdentifier");
        if (!bid.length) {
            skipped++;
            continue;
        }

        NSString *src = nil;
        NSString *name = NBNameFromProxy(proxy, &src);
        if (name.length) {
            if ([src isEqualToString:@"Info.plist"]) fromPlist++;
            else fromSys++;
        } else {
            name = NBLastSegmentName(bid);
            fromLastSeg++;
            if (fallbacks.count < 8) [fallbacks addObject:bid];
        }
        out[bid] = name;
    }

    NBAddDiag(@"LSApplicationWorkspace：拿到 %lu 个 App（跳过 %ld 个读不出 bundle 的）",
              (unsigned long)out.count, (long)skipped);
    // 🔴 v0.0.43 新增：名字**从哪来的**也要报。上一版只有"拿到几个"，
    //    于是"拿到的名字是 bundle 末段"这种情况在报告里完全看不见 ——
    //    而那恰好就是用户看到的那一堆英文小字。
    NBAddDiag(@"名字来源：系统名 %ld / Info.plist %ld / 兜底末段 %ld",
              (long)fromSys, (long)fromPlist, (long)fromLastSeg);
    if (fallbacks.count) {
        NBAddDiag(@"兜底的 bundle：%@", [fallbacks componentsJoinedByString:@", "]);
    }
    return out.count ? out : nil;
}

#pragma mark - 路 2：目录扫描

static void NBScanAppsIn(NSString *dir, BOOL descend, NSMutableDictionary *out, NSInteger depth) {
    if (depth > 2 || !dir.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *it in items) {
        NSString *p = [dir stringByAppendingPathComponent:it];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&isDir] || !isDir) continue;

        if ([it hasSuffix:@".app"]) {
            NSString *bid = nil;
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [p stringByAppendingPathComponent:@"Info.plist"]];
            if ([info isKindOfClass:[NSDictionary class]]) {
                bid = NBStrForKey(info, @"CFBundleIdentifier");
            }
            if (!bid.length) continue;
            // v0.0.43：走和 workspace 完全同一条解析（含 zh-Hans 本地化），
            // 不再自己抄一份"DisplayName → Name"的顺序 —— 两处抄两遍必然有一处先改。
            NSString *name = NBNameFromAppBundle(p);
            out[bid] = name.length ? name : NBLastSegmentName(bid);
        } else if (descend && ![it hasSuffix:@".appex"] && ![it hasSuffix:@".bundle"]) {
            // /var/containers/Bundle/Application/<UUID>/Foo.app 这一层
            NBScanAppsIn(p, NO, out, depth + 1);
        }
    }
}

static NSDictionary<NSString *, NSString *> *NBViaScan(void) {
    // roothide 会把 /Applications 重定向到自己的前缀，所以两条都扫。
    NSArray *dirs = @[
        @"/Applications",
        @"/var/jb/Applications",
        @"/var/containers/Bundle/Application",
    ];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSMutableArray *okDirs = [NSMutableArray array];
    for (NSString *d in dirs) {
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:d isDirectory:&isDir] || !isDir) continue;
        NSInteger before = (NSInteger)out.count;
        NBScanAppsIn(d, YES, out, 0);
        [okDirs addObject:[NSString stringWithFormat:@"%@(+%ld)", d,
                           (long)((NSInteger)out.count - before)]];
    }
    if (!out.count) {
        NBAddDiag(@"目录扫描：没扫到任何 .app（可读目录：%@）",
                  okDirs.count ? [okDirs componentsJoinedByString:@" "] : @"一个都没有");
        return nil;
    }
    NBAddDiag(@"目录扫描：%@ ⇒ 共 %lu 个",
              [okDirs componentsJoinedByString:@" "], (unsigned long)out.count);
    return out;
}

#pragma mark -

@implementation InstalledApps

+ (void)clearCache {
    gCache = nil;
    gDiag = nil;
}

+ (NSArray<InstalledApp *> *)all {
    if (gCache) return gCache;
    gDiag = [NSMutableArray array];

    // 三条来源依次来，前面的优先（workspace 给的名字最准，扫描给的是 Info.plist）
    NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];

    NSDictionary *viaWs = NBViaWorkspace();
    if (viaWs) [names addEntriesFromDictionary:viaWs];

    if (names.count < 3) {
        // workspace 不通（或只拿到两三个）才去扫目录：扫描要遍历上万个目录，不能白跑
        NSDictionary *viaScan = NBViaScan();
        if (viaScan) {
            for (NSString *k in viaScan) {
                if (!names[k]) names[k] = viaScan[k];
            }
        }
    } else {
        NBAddDiag(@"目录扫描：跳过（workspace 已够用，扫描很慢）");
    }

    // 🔴 无论如何都要合上数据库历史：
    //    ① 它提供"这个 App 来过多少条通知"，用来排序（用户最想管的就在这几个里）；
    //    ② 枚举全失败时它是**唯一**的数据来源，至少还能把已配置的 App 列出来取消。
    NSDictionary<NSString *, NSNumber *> *counts = [NotifyStore bundleCounts];
    NBAddDiag(@"数据库历史：%lu 个 App 来过通知", (unsigned long)counts.count);

    NSMutableArray<InstalledApp *> *list = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    for (NSString *bid in names) {
        InstalledApp *a = [[InstalledApp alloc] init];
        a.bundleId = bid;
        a.name = names[bid] ?: NBLastSegmentName(bid);
        a.noteCount = [counts[bid] integerValue];
        a.onlyInHistory = NO;
        [list addObject:a];
        [seen addObject:bid];
    }
    // v0.0.43：仅历史的 App 也要**定向查一次名字**，不能直接给 bundle 末段。
    // 🔴 为什么它们是"仅历史"有很多原因（枚举那条路没走通 / 某个键抛异常 / 真的卸了），
    //    其中前两种的 App **明明装在手机上**，把它的名字写成 `mihome` 是纯粹的错。
    NSInteger histResolved = 0;
    NSMutableArray<NSString *> *histFallback = [NSMutableArray array];
    for (NSString *bid in counts) {
        if ([seen containsObject:bid]) continue;
        InstalledApp *a = [[InstalledApp alloc] init];
        a.bundleId = bid;
        NSString *nm = NBNameForBundle(bid);
        if (nm.length) {
            a.name = nm;
            histResolved++;
        } else {
            a.name = NBLastSegmentName(bid);
            if (histFallback.count < 8) [histFallback addObject:bid];
        }
        a.noteCount = [counts[bid] integerValue];
        a.onlyInHistory = YES;
        [list addObject:a];
    }
    if (histFallback.count) {
        NBAddDiag(@"仅历史里仍兜底的 bundle：%@", [histFallback componentsJoinedByString:@", "]);
    }

    // 排序：来过通知的按条数降序在前，其余按名称。
    // 🔴 用户要管的就是"老给我推通知的那几个"，排在名单末尾等于没做。
    [list sortUsingComparator:^NSComparisonResult(InstalledApp *x, InstalledApp *y) {
        BOOL hx = (x.noteCount > 0), hy = (y.noteCount > 0);
        if (hx != hy) return hx ? NSOrderedAscending : NSOrderedDescending;
        if (hx && hy && x.noteCount != y.noteCount) {
            return x.noteCount > y.noteCount ? NSOrderedAscending : NSOrderedDescending;
        }
        return [x.name localizedStandardCompare:y.name];
    }];

    NSInteger histOnly = 0;
    for (InstalledApp *a in list) {
        if (a.onlyInHistory) histOnly++;
    }
    NBAddDiag(@"合计：%lu 个候选（含仅历史 %ld 个，其中 %ld 个定向查到了名字）",
              (unsigned long)list.count, (long)histOnly, (long)histResolved);

    gCache = list;
    return gCache;
}

+ (NSString *)diagReport {
    if (!gDiag) [self all];       // 没跑过就先跑一次，别给空报告
    NSString *head = [NSString stringWithFormat:@"已安装 App 枚举（共 %lu 个候选）",
                      (unsigned long)(gCache ? gCache.count : 0)];
    return [[@[head] arrayByAddingObjectsFromArray:gDiag ?: @[]]
            componentsJoinedByString:@"\n"];
}

@end
