#import "AppIconLoader.h"
#import "NBTheme.h"
#include <math.h>

// 取 App 图标的三条路（按顺序试，谁能成用谁）：
//   A. LSApplicationProxy + iconDataForVariant:  ← 正道，但参数宽度/方法名都可能变
//   B. UIImage 私有类方法 _applicationIconImageForBundleIdentifier:format:scale:
//   C. 直接读 App 包里的 Info.plist + 图标文件（老 App 才有松散 png，新 App 在 Assets.car 里）
//
// 🔴🔴 v0.0.9 及以前为什么一直只显示首字母：
//    A 里把 variant 当成 `int`（4 字节）塞进 NSInvocation。若签名里该参数是 `Q`（8 字节），
//    NSInvocation 会按 8 字节去读我们只准备了 4 字节的那块内存 ⇒ 高 4 字节是垃圾 ⇒
//    拿到的 variant 是个乱数 ⇒ iconDataForVariant: 返回 nil。
//    **参数宽度必须按 methodSignature 里的类型来填，不能一律 int。**
//    现在统一用 8 字节的 unsigned long long：签名是 4 字节时 NSInvocation 只拷低 4 字节，
//    是 8 字节时正好拷满 —— 两种都对。

static NSMutableDictionary *gCache = nil;      // bundleId -> UIImage / NSNull
static NSMutableArray<NSString *> *gTrace = nil;   // 每个 bundle 的尝试记录（最多留 20 条）
// v0.0.88：bundleId -> 品牌色（UIColor）。和图标缓存分开存：
// 🔴 图标可以"取不到"（gCache 里记 NSNull），但品牌色**永远有值**
//    （退化链最后一档是哈希调色板）⇒ 两张表的语义不同，不能并成一张。
static NSMutableDictionary<NSString *, UIColor *> *gBrandCache = nil;

@implementation AppIconLoader

+ (NSArray<NSNumber *> *)variants {
    // 常见有效档：0 默认 / 1 / 2 / 3；8、14 在部分版本上才有图
    return @[@0, @1, @2, @3, @8, @14];
}

+ (void)trace:(NSString *)line {
    if (!gTrace) gTrace = [NSMutableArray array];
    [gTrace addObject:line];
    while (gTrace.count > 20) [gTrace removeObjectAtIndex:0];
}

+ (void)clearCache {
    [gCache removeAllObjects];
    [gTrace removeAllObjects];
    // v0.0.88：品牌色必须跟着清 —— 它是由图标算出来的，
    // 图标"重新取"了而颜色还留着旧的，就会出现"换了图标、卡片颜色没变"。
    [gBrandCache removeAllObjects];
}

+ (UIImage *)iconForBundle:(NSString *)bundleId {
    if (!bundleId.length) return nil;
    if (!gCache) gCache = [NSMutableDictionary dictionary];

    id hit = gCache[bundleId];
    if (hit) return (hit == [NSNull null]) ? nil : (UIImage *)hit;

    NSMutableString *diag = [NSMutableString string];
    UIImage *img = nil;

    @try {
        img = [self viaProxy:bundleId diag:diag];
    } @catch (__unused NSException *e) {
        [diag appendString:@"A:抛异常 "];
    }
    if (!img) {
        @try {
            img = [self viaUIImagePrivate:bundleId diag:diag];
        } @catch (__unused NSException *e) {
            [diag appendString:@"B:抛异常 "];
        }
    }
    if (!img) {
        @try {
            img = [self viaBundleFiles:bundleId diag:diag];
        } @catch (__unused NSException *e) {
            [diag appendString:@"C:抛异常 "];
        }
    }

    // 🔴🔴 必须标成 AlwaysOriginal 再交出去。
    //    `UIButton buttonWithType:UIButtonTypeSystem` 默认把 setImage: 进来的图当
    //    **template** 渲染：只用它的 alpha 当形状，然后用按钮的 tintColor 上色。
    //    App 图标是不透明方形图，alpha 全覆盖 ⇒ 整块被涂成主题蓝 ⇒
    //    「顶上的图标都是蓝色的」（v0.0.10 就是这样）。
    //    给 UIImageView 用时同理：template 图也会被 tint 成单色。
    //    所以在这里统一转成原图模式，所有调用方都安全。
    if (img) img = [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];

    gCache[bundleId] = img ?: [NSNull null];
    [self trace:[NSString stringWithFormat:@"%@ ⇒ %@  [%@]",
                 bundleId, img ? @"✅ 取到" : @"❌ 全失败", diag]];
    return img;
}

#pragma mark - A：LSApplicationProxy

+ (UIImage *)viaProxy:(NSString *)bid diag:(NSMutableString *)diag {
    Class P = NSClassFromString(@"LSApplicationProxy");
    if (!P) {
        [diag appendString:@"A:找不到 LSApplicationProxy"];
        return nil;
    }
    if (![P respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        [diag appendString:@"A:无 applicationProxyForIdentifier:"];
        return nil;
    }
    id proxy = [P performSelector:@selector(applicationProxyForIdentifier:) withObject:bid];
    if (!proxy) {
        [diag appendString:@"A:proxy=nil"];
        return nil;
    }

    // iOS 16 上常见的是 iconDataForVariant:（单参数）
    SEL sel = NSSelectorFromString(@"iconDataForVariant:");
    if (![proxy respondsToSelector:sel]) {
        [diag appendString:@"A:无 iconDataForVariant:"];
        return nil;
    }
    NSMethodSignature *sig = [proxy methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments < 3) {
        [diag appendString:@"A:签名不符"];
        return nil;
    }

    NSUInteger tried = 0;
    for (NSNumber *vn in [self variants]) {
        @try {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:proxy];
            // 8 字节填参数，见文件头说明
            unsigned long long v = (unsigned long long)[vn unsignedIntegerValue];
            [inv setArgument:&v atIndex:2];
            [inv invoke];
            __unsafe_unretained id ret = nil;
            [inv getReturnValue:&ret];
            if ([ret isKindOfClass:[NSData class]] && [(NSData *)ret length]) {
                UIImage *im = [UIImage imageWithData:(NSData *)ret];
                if (im) {
                    [diag appendFormat:@"A:variant=%@ 成功", vn];
                    return im;
                }
            }
            tried++;
        } @catch (__unused NSException *e) {
            [diag appendFormat:@"A:v%@ 抛错 ", vn];
        }
    }
    [diag appendFormat:@"A:%lu 个 variant 全空", (unsigned long)tried];
    return nil;
}

#pragma mark - B：UIImage 私有方法

+ (UIImage *)viaUIImagePrivate:(NSString *)bid diag:(NSMutableString *)diag {
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:sel]) {
        [diag appendString:@"B:无该私有方法"];
        return nil;
    }
    NSMethodSignature *sig = [UIImage methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments < 5) {
        [diag appendString:@"B:签名不符"];
        return nil;
    }

    CGFloat scale = [UIScreen mainScreen].scale;
    NSArray<NSNumber *> *fmts = @[@2, @6, @10, @1];
    for (NSNumber *f in fmts) {
        @try {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:[UIImage class]];
            id b = bid;
            [inv setArgument:&b atIndex:2];
            long long fmt = (long long)[f longValue];
            [inv setArgument:&fmt atIndex:3];
            // 🔴 scale 是 CGFloat（8 字节 double），必须传 CGFloat 变量本身
            [inv setArgument:&scale atIndex:4];
            [inv invoke];
            __unsafe_unretained id ret = nil;
            [inv getReturnValue:&ret];
            if ([ret isKindOfClass:[UIImage class]]) {
                [diag appendFormat:@"B:format=%@ 成功", f];
                return (UIImage *)ret;
            }
        } @catch (__unused NSException *e) {
            [diag appendFormat:@"B:f%@ 抛错 ", f];
        }
    }
    [diag appendString:@"B:各 format 全空"];
    return nil;
}

#pragma mark - C：直接读包内图标文件

+ (UIImage *)viaBundleFiles:(NSString *)bid diag:(NSMutableString *)diag {
    // 只有老式 App（图标是松散 png）能走通；新 App 的图在 Assets.car 里，这里读不到
    Class P = NSClassFromString(@"LSApplicationProxy");
    if (!P || ![P respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        [diag appendString:@"C:无 proxy"];
        return nil;
    }
    id proxy = [P performSelector:@selector(applicationProxyForIdentifier:) withObject:bid];
    if (!proxy || ![proxy respondsToSelector:NSSelectorFromString(@"bundleURL")]) {
        [diag appendString:@"C:无 bundleURL"];
        return nil;
    }
    NSURL *u = [proxy valueForKey:@"bundleURL"];
    if (![u isKindOfClass:[NSURL class]]) {
        [diag appendString:@"C:bundleURL 非 URL"];
        return nil;
    }
    NSString *dir = [u path];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [dir stringByAppendingPathComponent:@"Info.plist"]];
    if (![info isKindOfClass:[NSDictionary class]]) {
        [diag appendString:@"C:Info.plist 读不到"];
        return nil;
    }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    id icons = info[@"CFBundleIcons"];
    if ([icons isKindOfClass:[NSDictionary class]]) {
        id primary = ((NSDictionary *)icons)[@"CFBundlePrimaryIcon"];
        if ([primary isKindOfClass:[NSDictionary class]]) {
            id files = ((NSDictionary *)primary)[@"CFBundleIconFiles"];
            if ([files isKindOfClass:[NSArray class]]) [names addObjectsFromArray:files];
        }
    }
    id flat = info[@"CFBundleIconFiles"];
    if ([flat isKindOfClass:[NSArray class]]) [names addObjectsFromArray:flat];
    if (!names.count) {
        [diag appendString:@"C:Info.plist 里没有图标名"];
        return nil;
    }

    // 名字越大通常是越大的图；从后往前试，再补常见后缀
    NSArray *suffixes = @[@"@3x.png", @"@2x.png", @".png"];
    for (NSString *base in [names reverseObjectEnumerator]) {
        if (![base isKindOfClass:[NSString class]]) continue;
        for (NSString *suf in suffixes) {
            NSString *p = [dir stringByAppendingPathComponent:[base stringByAppendingString:suf]];
            UIImage *im = [UIImage imageWithContentsOfFile:p];
            if (im) {
                [diag appendFormat:@"C:文件 %@ 成功", [p lastPathComponent]];
                return im;
            }
        }
    }
    [diag appendString:@"C:图标文件都不在（多半在 Assets.car 里）"];
    return nil;
}

#pragma mark - 诊断

+ (NSString *)diagReport {
    if (!gTrace.count) {
        return @"还没有尝试过取图标。\n"
               @"（打开一次列表后再回来看；每个 bundle 只取一次，之后走缓存）";
    }
    return [[gTrace componentsJoinedByString:@"\n\n"]
            stringByAppendingString:@"\n\n—— 说明 ——\n"
            @"A = LSApplicationProxy iconDataForVariant:\n"
            @"B = UIImage 私有方法（format 是多档尝试）\n"
            @"C = 直接读包内 png（新 App 在 Assets.car 里，必然失败）\n"
            @"只要有一个 ✅ 就说明图标能取，列表里应该显示真图标。"];
}

#pragma mark - v0.0.88 品牌色（首页卡片淡染）

// 从图标封面统计主色。
// 🔴 为什么在 16×16 缩略图上算、不在原图上扫：图标普遍 180×180（≈3 万像素），
//    一屏十几张卡片、每次滚动都要算 ⇒ 掉帧。而"主色"是个统计量，
//    16×16（256 点）已经足够稳定，放大到 512×512 也不会更准。
// 🔴 为什么先做三重过滤（去黑 / 去灰 / 去白）再取最大簇：
//    绝大多数 App 图标是"白底 + 彩色图形"。不去白，均值会被白底拉成灰白 ⇒ 染不出颜色；
//    不去灰，iOS 图标那圈浅灰阴影会把色相拖偏。饱和度加权（s²·v）让"又艳又亮"的
//    那几个像素说了算，这才是人眼认定的"这个 App 的颜色"。
static UIColor *NBDominantColor(UIImage *img) {
    CGImageRef cg = img.CGImage;
    if (!cg) return nil;

    enum { W = 16, H = 16, kBuckets = 12 };
    unsigned char buf[W * H * 4];
    memset(buf, 0, sizeof(buf));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, W * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    // 🔴 不处理上下翻转：主色是统计量，和像素的**位置**无关。
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), cg);
    CGContextRelease(ctx);

    double accR[kBuckets] = {0}, accG[kBuckets] = {0}, accB[kBuckets] = {0}, accW[kBuckets] = {0};
    for (int i = 0; i < W * H; i++) {
        double a = buf[i * 4 + 3] / 255.0;
        if (a < 0.5) continue;                       // 透明区（圆角外）
        double r = buf[i * 4 + 0] / 255.0;
        double g = buf[i * 4 + 1] / 255.0;
        double b = buf[i * 4 + 2] / 255.0;
        double mx = fmax(r, fmax(g, b));
        double mn = fmin(r, fmin(g, b));
        if (mx < 0.15) continue;                     // 近黑：描边/投影
        double d = mx - mn;
        double s = (mx > 1e-6) ? (d / mx) : 0.0;
        if (s < 0.18) continue;                      // 灰 / 白 / 黑（s=0 全覆盖）

        double hue;
        if (d < 1e-6) {
            hue = 0.0;
        } else if (mx == r) {
            hue = 60.0 * fmod(((g - b) / d), 6.0);
        } else if (mx == g) {
            hue = 60.0 * (((b - r) / d) + 2.0);
        } else {
            hue = 60.0 * (((r - g) / d) + 4.0);
        }
        if (hue < 0.0) hue += 360.0;
        int k = ((int)(hue / 30.0)) % kBuckets;
        if (k < 0) k = 0;

        double w = s * s * mx;                       // 又艳又亮的权重高
        accR[k] += r * w;
        accG[k] += g * w;
        accB[k] += b * w;
        accW[k] += w;
    }

    int best = -1;
    double bestW = 0.0;
    for (int k = 0; k < kBuckets; k++) {
        if (accW[k] > bestW) {
            bestW = accW[k];
            best = k;
        }
    }
    // 🔴 一个彩色像素都没有（纯白/纯灰图标，比如"计算器""备忘录"）⇒ 返回 nil 交给兜底。
    //    ⛔ 不许返回"最接近灰的那个"：那会给出一个看着像 bug 的浑浊颜色。
    if (best < 0 || bestW <= 0.0) return nil;

    double r = accR[best] / bestW;
    double g = accG[best] / bestW;
    double b = accB[best] / bestW;

    // 把色相留住、把饱和和亮度夹进"能看清又不刺眼"的区间：
    // 🔴 不夹的话，浅黄/浅青这类图标会算出几乎看不见的颜色；
    //    而纯饱和的红会算出刺眼的 #FF0000。卡片是背景，不是主视觉。
    CGFloat hh = 0, ss = 0, vv = 0, aa = 1;
    UIColor *avg = [UIColor colorWithRed:r green:g blue:b alpha:1.0];
    if (![avg getHue:&hh saturation:&ss brightness:&vv alpha:&aa]) return avg;
    ss = MIN(0.95, MAX(0.45, ss));
    vv = MIN(0.88, MAX(0.58, vv));
    return [UIColor colorWithHue:hh saturation:ss brightness:vv alpha:1.0];
}

+ (UIColor *)brandColorForBundle:(NSString *)bundleId {
    if (!bundleId.length) return nil;
    if (!gBrandCache) gBrandCache = [NSMutableDictionary dictionary];
    UIColor *hit = gBrandCache[bundleId];
    if (hit) return hit;

    UIColor *brand = NBDominantColor([self iconForBundle:bundleId]);
    // 🔴 退化链最后一档：图标取不到、或图标没有彩色 ⇒ 哈希调色板。
    //    这一档**保证有颜色**，所以"一片卡片全是灰的"这种退化不会发生。
    if (!brand) brand = NBBrandFallback(bundleId);
    if (brand) gBrandCache[bundleId] = brand;
    return brand;
}

@end

