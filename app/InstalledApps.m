#import "InstalledApps.h"
#import "NotifyStore.h"
#import "NotifyCommon.h"
#import "NBAppName.h"

// 🔴🔴 v0.0.45：名字解析的所有工具函数**搬走**了（现在在根目录的 NBAppName.h/.m，
//    tweak 和 App 两个目标共用一份）。
//    搬的原因不是"整理代码"，是一个修不动的 bug：
//    京东显示「京东-购物商城」、信息 App 显示不出「信息」，连着三版都在 App 进程里
//    换字段 / 加汉字优先 / 加"取更短"，都没碰真正的前提 ——
//    **盒子 App 有沙盒，读不到 /var/containers/Bundle/Application/<UUID>/Xxx.app**，
//    而"读 bundle 里本地化的 CFBundleDisplayName"才是桌面那个字的唯一权威来源。
//    ⇒ 正解是让注入 SpringBoard（有权限）的 tweak 把名字算好写进 `app_names` 表，
//      两边用**同一份**解析代码，否则又变成两处抄两遍。

// 🔴 私有方法**必须**在这里显式声明：项目开 -Werror，
//    靠"定义写在调用点之前"来解析选择器太脆（本项目栽过三次：
//    kAutoChainTrigger / uiscrollerInternalVelocity / forceLayoutVisibleCells）。
//    这里 `pickNameForBundle:` 定义在 `+all` **之后**，而 `+all` 要调它 ⇒ 不声明就编不过。
@interface InstalledApps ()
+ (NSString *)pickNameForBundle:(NSString *)bid
                          table:(NSDictionary<NSString *, NSString *> *)table
                         refine:(NSDictionary<NSString *, NSString *> *)refine
                          enum1:(NSDictionary<NSString *, NSString *> *)enum1;
@end

@implementation InstalledApp
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ note=%ld%@>", self.name, self.bundleId,
            (long)self.noteCount, self.onlyInHistory ? @" 仅历史" : @""];
}
@end

static NSArray<InstalledApp *> *gCache = nil;
static NSMutableArray<NSString *> *gDiag = nil;

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

#pragma mark - 路 1：LSApplicationWorkspace（不读 bundle，快）

// 返回 @{bid: name}；失败返回 nil。
static NSDictionary<NSString *, NSString *> *NBViaWorkspace(void) {
    return NBEnumerateAppNames(NO, gDiag);
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
            NSString *name = NBNameFromAppBundle(p, NULL);
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

    // ① **名字表优先**（v0.0.45）。这份是 tweak 在 SpringBoard 里算好写进库的，
    //    那一侧能读 /var/containers/Bundle/Application/<UUID>/Xxx.app ⇒ 最权威。
    NSDictionary<NSString *, NSString *> *tableNames = [NotifyStore appNames];
    NBAddDiag(@"名字表（tweak 写入）：%lu 个", (unsigned long)tableNames.count);

    // ② 本进程枚举（**不读 bundle**，只吃注册表里的名字，快）
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

    // ③ **精修**：对"来过通知的 App"（用户眼睛里真正会出现的那几十个）
    //    逐个去读它的 bundle（I/O），拿到本地化的 CFBundleDisplayName。
    //    🔴 只对这批做：全量 200 多个都读一遍没必要，而没来过通知的 App
    //    就算名字差点也不影响列表阅读。
    //    🔴 精修成功的**写回名字表** —— 下一次打开就不用再读一遍文件了
    //    （表是两边共享的，App 侧写它和 tweak 侧写它是同一件事）。
    NSInteger refined = 0, refineFailed = 0;
    NSMutableDictionary<NSString *, NSString *> *refinedNames = [NSMutableDictionary dictionary];
    for (NSString *bid in counts) {
        NSString *t = tableNames[bid];
        if (t.length) continue;                       // 表里已有 ⇒ 不用再读一次文件
        NSString *nm = NBResolveNameForBundle(bid);
        if (nm.length) {
            refined++;
            refinedNames[bid] = nm;
            names[bid] = nm;                          // 精修结果压过枚举结果
        } else {
            refineFailed++;
        }
    }
    if (refined) [NotifyStore saveAppNames:refinedNames];
    NBAddDiag(@"精修（读 bundle）：成功 %ld / 失败 %ld", (long)refined, (long)refineFailed);

    NSMutableArray<InstalledApp *> *list = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    for (NSString *bid in names) {
        InstalledApp *a = [[InstalledApp alloc] init];
        a.bundleId = bid;
        a.name = [self pickNameForBundle:bid
                                   table:tableNames
                                  refine:refinedNames
                                   enum1:names];
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
        NSString *nm = tableNames[bid];
        if (!nm.length) {
            nm = NBResolveNameForBundle(bid);
            if (nm.length) {
                [NotifyStore saveAppName:nm forBundle:bid];
                histResolved++;
            }
        } else {
            histResolved++;
        }
        if (nm.length) {
            a.name = nm;
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

    // 🔴 **把"来过通知的 App 最终显示成什么"直接打进诊断**（v0.0.45 新增）。
    //    没有这一行，用户说"京东显示的不是京东"时我只能猜 ——
    //    到底是"表里就是那个值"还是"表没写、走了兜底"，一眼看不出来。
    //    有了它，用户截一张诊断图就能定位到具体是哪一个环节。
    NSMutableArray<NSString *> *samples = [NSMutableArray array];
    for (InstalledApp *a in list) {
        if (samples.count >= 8) break;
        if (a.noteCount <= 0) continue;
        [samples addObject:[NSString stringWithFormat:@"%@=%@", a.bundleId, a.name]];
    }
    if (samples.count) {
        NBAddDiag(@"来过通知的 App 最终名：%@", [samples componentsJoinedByString:@" | "]);
    }

    NSInteger histOnly = 0;
    for (InstalledApp *a in list) {
        if (a.onlyInHistory) histOnly++;
    }
    NBAddDiag(@"合计：%lu 个候选（含仅历史 %ld 个，其中 %ld 个查到了名字）",
              (unsigned long)list.count, (long)histOnly, (long)histResolved);

    gCache = list;
    return gCache;
}

// 名字的四级优先级。**越靠前越权威**：
//   ① 名字表（tweak 在 SpringBoard 里读 bundle 算出来的 —— 只有它有权限）
//   ② 本轮精修（App 进程自己试着读了一次 bundle，读到了就用）
//   ③ 本进程枚举（只读注册表，快，但 `localizedName` 常带「-购物商城」这类副标题）
//   ④ bundle 末段（`com.xiaomi.mihome` → `mihome`，最坏情况，不是默认值）
+ (NSString *)pickNameForBundle:(NSString *)bid
                          table:(NSDictionary<NSString *, NSString *> *)table
                         refine:(NSDictionary<NSString *, NSString *> *)refine
                          enum1:(NSDictionary<NSString *, NSString *> *)enum1 {
    NSString *t = table[bid];
    if (t.length) return t;
    NSString *r = refine[bid];
    if (r.length) return r;
    NSString *e = enum1[bid];
    if (e.length) return e;
    return NBLastSegmentName(bid);
}

+ (NSString *)diagReport {
    if (!gDiag) [self all];       // 没跑过就先跑一次，别给空报告
    NSString *head = [NSString stringWithFormat:@"已安装 App 枚举（共 %lu 个候选）",
                      (unsigned long)(gCache ? gCache.count : 0)];
    return [[@[head] arrayByAddingObjectsFromArray:gDiag ?: @[]]
            componentsJoinedByString:@"\n"];
}

@end
