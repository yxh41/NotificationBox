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

static NSString *NBFallbackName(NSString *bid) {
    NSString *last = [[bid componentsSeparatedByString:@"."] lastObject];
    return last.length ? last : bid;
}

#pragma mark - 路 1：LSApplicationWorkspace

// 返回 @{bid: name}；失败返回 nil
static NSDictionary<NSString *, NSString *> *NBViaWorkspace(void) {
    // 这个类在 CoreServices 里。App 里不一定已经加载，所以先用几种方式把库带进来。
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls) {
        // 🔴 绝对路径在 roothide 上可能被重定向，所以先用裸名让 dyld 自己找，
        //    再退回绝对路径。两个都失败也不致命 —— 还有下一条路。
        const char *cands[] = {
            "CoreServices",
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
        };
        for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
            void *h = dlopen(cands[i], RTLD_LAZY);
            if (h) {
                cls = NSClassFromString(@"LSApplicationWorkspace");
                if (cls) break;
            }
        }
    }
    if (!cls) {
        NBAddDiag(@"LSApplicationWorkspace：类找不到（CoreServices 没能加载）");
        return nil;
    }

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
    NSInteger skipped = 0;
    for (id proxy in (NSArray *)raw) {
        // 🔴 逐项 @try：有的 proxy 是占位对象，读键会抛。
        //    整段共用 @try 的话，一个坏项会带走后面全部 App。
        @try {
            id b = [proxy valueForKey:@"bundleIdentifier"];
            if (![b isKindOfClass:[NSString class]] || ![(NSString *)b length]) {
                skipped++;
                continue;
            }
            NSString *bid = (NSString *)b;
            id n = [proxy valueForKey:@"localizedName"];
            NSString *name = [n isKindOfClass:[NSString class]] ? (NSString *)n : nil;
            if (!name.length) {
                id d = [proxy valueForKey:@"displayName"];
                if ([d isKindOfClass:[NSString class]]) name = (NSString *)d;
            }
            out[bid] = name.length ? name : NBFallbackName(bid);
        } @catch (__unused NSException *e) {
            skipped++;
        }
    }
    NBAddDiag(@"LSApplicationWorkspace：拿到 %lu 个 App（跳过 %ld 个读不出 bundle 的）",
              (unsigned long)out.count, (long)skipped);
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
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [p stringByAppendingPathComponent:@"Info.plist"]];
            id bid = info[@"CFBundleIdentifier"];
            if (![bid isKindOfClass:[NSString class]] || ![(NSString *)bid length]) continue;
            id dn = info[@"CFBundleDisplayName"];
            id nm = info[@"CFBundleName"];
            NSString *name = [dn isKindOfClass:[NSString class]] ? (NSString *)dn
                           : ([nm isKindOfClass:[NSString class]] ? (NSString *)nm : nil);
            out[(NSString *)bid] = name.length ? name : NBFallbackName((NSString *)bid);
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
        a.name = names[bid] ?: NBFallbackName(bid);
        a.noteCount = [counts[bid] integerValue];
        a.onlyInHistory = NO;
        [list addObject:a];
        [seen addObject:bid];
    }
    for (NSString *bid in counts) {
        if ([seen containsObject:bid]) continue;
        InstalledApp *a = [[InstalledApp alloc] init];
        a.bundleId = bid;
        a.name = NBFallbackName(bid);
        a.noteCount = [counts[bid] integerValue];
        a.onlyInHistory = YES;
        [list addObject:a];
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
    NBAddDiag(@"合计：%lu 个候选（含仅历史 %ld 个）", (unsigned long)list.count, (long)histOnly);

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
