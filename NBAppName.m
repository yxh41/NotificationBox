// NBAppName.m —— v0.0.45：App 显示名解析（App 与 tweak 共用）。设计理由见 NBAppName.h。
//
// 🔴 这个文件**同时编进 tweak 和盒子 App** ⇒
//    ① 不许 import UIKit（tweak 注入的是 SpringBoard，没有 UIKit 进程语义）；
//    ② 所有私有 API 访问走 objc_msgSend + respondsToSelector + @try，
//       不声明假 @interface（私有 API 的签名会随系统版本变，声明错了运行期才崩）。

#import "NBAppName.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
// 🔴 `CFAbsoluteTimeGetCurrent` 在 CoreFoundation 里。Foundation 通常 re-export 它，
//    但 tweak 侧（SpringBoard）不一定有这份 re-export ⇒ 显式引入，别赌。
#import <CoreFoundation/CoreFoundation.h>

#pragma mark - 私有 API 访问（逐键 @try）

// 无参、返回对象。
// 🔴 不走 performSelector: —— 项目开 -Werror，传变量 SEL 触发 -Warc-performSelector-leaks。
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

// 一个对象参数版本（`+[LSApplicationProxy applicationProxyForIdentifier:]`）。
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

// 读一个**字符串**属性。
// 🔴🔴 为什么坚持"逐键 @try"：v0.0.42 的真机 bug 现场是三个键共用一个 @try
//    （`bundleIdentifier` 读成功了，随后 `localizedName` 抛异常 ⇒ 整个 App 被丢弃）。
//    `LSApplicationProxy` 是私有类，占位 App / 扩展 / 已删记录都可能让某个键抛。
//    ⇒ 一个键读不出来，只该让**这个键**作废，不该让这个 App 作废。
// 🔴 顺带去掉首尾空白：真机上见过 `@" 微信 "` 这种值。
NSString *NBStrForKey(id obj, NSString *key) {
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

#pragma mark - 挑选

BOOL NBHasCJK(NSString *s) {
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= 0x2E80 && c <= 0x9FFF) return YES;
        if (c >= 0xF900 && c <= 0xFAFF) return YES;
        if (c >= 0xFF00 && c <= 0xFFEF) return YES;
    }
    return NO;
}

NSString *NBLastSegmentName(NSString *bid) {
    NSString *last = [[bid componentsSeparatedByString:@"."] lastObject];
    return last.length ? last : bid;
}

NSString *NBPickName(NSArray<NSString *> *cands) {
    NSString *best = nil;
    BOOL bestCJK = NO;
    for (NSString *s in cands) {
        if (!s.length) continue;
        BOOL cjk = NBHasCJK(s);
        if (!best) { best = s; bestCJK = cjk; continue; }
        if (cjk && !bestCJK) { best = s; bestCJK = YES; continue; }  // ① 有汉字 > 没汉字
        if (cjk && bestCJK && s.length < best.length) { best = s; }  // ② 都有汉字 ⇒ 更短
        // ③ 都没汉字 ⇒ 不比长度，保持候选顺序
    }
    return best;
}

#pragma mark - 从 bundle 读名字

NSString *NBNameFromAppBundle(NSString *path, NSString **whyOut) {
    if (whyOut) *whyOut = nil;
    if (!path.length) {
        if (whyOut) *whyOut = @"路径为空";
        return nil;
    }
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
        if (!hit) {
            if (whyOut) *whyOut = @"路径为空";
            return nil;
        }
        app = hit;
    }

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [app stringByAppendingPathComponent:@"Info.plist"]];
    if (![info isKindOfClass:[NSDictionary class]]) {
        // 🔴 这一档就是"沙盒不让读"最可能的落地形态：路径是对的、文件打不开。
        //    没有这一句，`Info.plist` 那一档只会报 0，看不出是被挡还是没这个键。
        if (whyOut) *whyOut = @"Info.plist 读不出";
        return nil;
    }

    // 本地化表只读**一次**
    NSMutableArray<NSDictionary *> *tables = [NSMutableArray array];
    for (NSString *lp in @[@"zh-Hans.lproj", @"zh_CN.lproj"]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                           [[app stringByAppendingPathComponent:lp]
                            stringByAppendingPathComponent:@"InfoPlist.strings"]];
        if ([d isKindOfClass:[NSDictionary class]]) [tables addObject:d];
    }

    // 🔴 顺序：本地化 DisplayName → 顶层 DisplayName → 本地化 Name → 顶层 Name。
    //    `NBPickName` 会在这些候选里优先挑带汉字的那个，所以顺序只是"同等条件下"的次序。
    NSMutableArray<NSString *> *c = [NSMutableArray array];
    for (NSString *key in @[@"CFBundleDisplayName", @"CFBundleName"]) {
        for (NSDictionary *d in tables) {
            NSString *v = NBStrForKey(d, key);
            if (v.length) [c addObject:v];
        }
        NSString *v = NBStrForKey(info, key);
        if (v.length) [c addObject:v];
    }

    NSString *picked = NBPickName(c);
    if (!picked.length && whyOut) *whyOut = @"无名字键";
    return picked;
}

#pragma mark - 从 proxy 解析

NSString *NBNameFromProxy(id proxy, NSString **srcOut, NSString **whyOut, BOOL allowIO) {
    if (srcOut) *srcOut = nil;
    if (whyOut) *whyOut = nil;
    if (!proxy) return nil;

    NSMutableArray<NSString *> *c = [NSMutableArray array];
    // 这四个键有的系统版本有、有的没有。**逐键读**，不存在的键不构成失败。
    // 🔴 短名排第一：`localizedShortName` 是桌面/搜索里那个短标签，
    //    `NBPickName` 在"都有汉字"时会取更短的，让"用户眼睛里的名字"优先胜出。
    for (NSString *k in @[@"localizedShortName", @"localizedName", @"displayName", @"itemName"]) {
        NSString *v = NBStrForKey(proxy, k);
        if (v.length) [c addObject:v];
    }
    NSString *shortName = c.count ? c[0] : nil;

    // 🔴🔴 v0.0.45 的关键改动：**bundle 里的名字现在总是参与竞选**（只要允许 I/O）。
    //    v0.0.44 写成"手上已经有汉字就不读 bundle" ⇒ 系统给的「京东-购物商城」
    //    一进场就把真名「京东」挤掉了。是否去读 bundle 只该由「值不值这个 I/O」决定，
    //    不该由"现在已经拿到什么"决定。
    NSString *fromPlist = nil;
    if (allowIO) {
        NSString *path = NBPathForKey(proxy, @"bundleURL");
        if (!path.length) path = NBPathForKey(proxy, @"resolvedInstallationURL");
        if (!path.length) path = NBPathForKey(proxy, @"bundleContainerURL");
        NSString *why = nil;
        fromPlist = NBNameFromAppBundle(path, &why);
        if (!fromPlist.length && why.length && whyOut) *whyOut = why;
    }

    // 候选顺序：**bundle 本地化名在前**（长度相同时它赢，因为它才是桌面那个字）
    NSMutableArray<NSString *> *all = [NSMutableArray array];
    if (fromPlist.length) [all addObject:fromPlist];
    [all addObjectsFromArray:c];

    NSString *picked = NBPickName(all);
    if (srcOut) {
        if (picked.length && fromPlist.length && [picked isEqualToString:fromPlist]) {
            *srcOut = @"Info.plist";
        } else if (picked.length && shortName.length && [picked isEqualToString:shortName]) {
            *srcOut = @"短名";
        } else if (picked.length) {
            *srcOut = @"系统名";
        }
    }
    return picked;
}

NSString *NBResolveNameForBundle(NSString *bid) {
    if (!bid.length) return nil;
    NBEnsureCoreServices();
    Class pcls = NSClassFromString(@"LSApplicationProxy");
    if (!pcls) return nil;
    id proxy = NBCallId1((id)pcls, @"applicationProxyForIdentifier:", bid);
    if (!proxy) return nil;
    return NBNameFromProxy(proxy, NULL, NULL, YES);
}

#pragma mark - 全量枚举

NSDictionary<NSString *, NSString *> *NBEnumerateAppNames(BOOL allowIO,
                                                          NSMutableArray<NSString *> *statsOut) {
    if (!NBEnsureCoreServices()) {
        if (statsOut) [statsOut addObject:@"LSApplicationWorkspace：类找不到（CoreServices 没能加载）"];
        return nil;
    }
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    id ws = NBCallId((id)cls, @"defaultWorkspace");
    if (!ws) {
        if (statsOut) [statsOut addObject:@"LSApplicationWorkspace：defaultWorkspace 返回 nil"];
        return nil;
    }
    id raw = NBCallId(ws, @"allInstalledApplications");
    if (![raw isKindOfClass:[NSArray class]]) {
        if (statsOut) {
            [statsOut addObject:[NSString stringWithFormat:
                                 @"LSApplicationWorkspace：allInstalledApplications 没给数组（cls=%@）",
                                 raw ? NSStringFromClass([raw class]) : @"nil"]];
        }
        return nil;
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSInteger skipped = 0, fromShort = 0, fromSys = 0, fromPlist = 0, fromLastSeg = 0;
    NSMutableDictionary<NSString *, NSNumber *> *whys = [NSMutableDictionary dictionary];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();

    for (id proxy in (NSArray *)raw) {
        // 🔴🔴 v0.0.43 的修法：**先只读 bundleIdentifier**，读到了这个 App 就归属了。
        //     后面不管哪个键抛异常、返回空，都只影响"名字"，不许把这个 App 丢掉。
        NSString *bid = NBStrForKey(proxy, @"bundleIdentifier");
        if (!bid.length) {
            skipped++;
            continue;
        }

        NSString *src = nil, *why = nil;
        NSString *name = NBNameFromProxy(proxy, &src, &why, allowIO);
        if (name.length) {
            if ([src isEqualToString:@"Info.plist"]) fromPlist++;
            else if ([src isEqualToString:@"短名"]) fromShort++;
            else fromSys++;
        } else {
            name = NBLastSegmentName(bid);
            fromLastSeg++;
            if (why.length) whys[why] = @([whys[why] integerValue] + 1);
        }
        out[bid] = name;
    }

    if (statsOut) {
        [statsOut addObject:[NSString stringWithFormat:
                             @"LSApplicationWorkspace：拿到 %lu 个 App（跳过 %ld 个读不出 bundle 的）%@",
                             (unsigned long)out.count, (long)skipped,
                             allowIO ? @"[含读 bundle]" : @"[不读 bundle]"]];
        [statsOut addObject:[NSString stringWithFormat:
                             @"名字来源：短名 %ld / 系统全名 %ld / Info.plist %ld / 兜底末段 %ld",
                             (long)fromShort, (long)fromSys, (long)fromPlist, (long)fromLastSeg]];
        if (whys.count) {
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            for (NSString *k in whys) [parts addObject:[NSString stringWithFormat:@"%@ %@ 个", k, whys[k]]];
            [statsOut addObject:[NSString stringWithFormat:@"读不到名字的原因：%@",
                                 [parts componentsJoinedByString:@" / "]]];
        }
        [statsOut addObject:[NSString stringWithFormat:@"枚举耗时：%.0f ms",
                             (CFAbsoluteTimeGetCurrent() - t0) * 1000.0]];
    }
    return out.count ? out : nil;
}
