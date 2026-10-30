#import "NBTheme.h"

// 见 NBTheme.h 顶部的颜色配对纪律说明。
const CGFloat NBInset      = 16.0;
const CGFloat NBRowH       = 50.0;
const CGFloat NBRowHSwitch = 56.0;
const CGFloat NBRowHSub    = 64.0;
const CGFloat NBFieldH     = 34.0;
const CGFloat NBIconBox    = 28.0;
const CGFloat NBCardRadius = 12.0;
const CGFloat NBSepInset   = 60.0;   // 16(内边距) + 28(图标) + 12(间距) + 4

// v0.0.88：信息流卡片（见 NBTheme.h 里「为什么单独一组」）
// 🔴 这几个数是从用户给的那张 HyperOS 截图**逐像素量出来再折算成 pt** 的
//    （按截图宽 = 393pt）：图标槽 46 / 右缘 10 / 圆角 14。
//    ⚠️ 卡片**左缘 46 而右缘只有 10**，左右不对称是**故意的** ——
//    左边要让出「图标在卡片外」那条槽，右边不需要。
// 🔴 v0.0.89：槽 46 → 52。因为 App 名搬到了图标下面（用户要求），
//    46pt 宽只放得下 4 个汉字/行；52 能让「拼多多商家版」排成两行还留边。
// 🔴 v0.0.90：App 名又搬回卡片内了，槽里只剩图标 —— **52 仍然不改回 46**。
//    28pt 图标要两侧各 12pt 才有"缝"；46 只剩 9pt/侧，大图标会贴住卡片左缘。
//    ⛔ 别以为"名字走了槽就该缩回去"：这个数是**图标 + 呼吸**定的，不是名字定的。
const CGFloat NBListIconSlot   = 52.0;
const CGFloat NBListCardRight  = 10.0;
const CGFloat NBListCardRadius = 14.0;

UIColor *NBPageBG(void)     { return [UIColor systemGroupedBackgroundColor]; }
UIColor *NBCardBG(void)     { return [UIColor secondarySystemGroupedBackgroundColor]; }
UIColor *NBValueColor(void) { return [UIColor secondaryLabelColor]; }
UIColor *NBSubColor(void)   { return [UIColor secondaryLabelColor]; }
UIColor *NBSepColor(void)   { return [UIColor separatorColor]; }

UIFont *NBFontTitle(void)  { return [UIFont systemFontOfSize:16]; }
UIFont *NBFontSub(void)    { return [UIFont systemFontOfSize:12]; }
UIFont *NBFontValue(void)  { return [UIFont systemFontOfSize:15]; }
UIFont *NBFontHeader(void) { return [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]; }
UIFont *NBFontField(void)  { return [UIFont systemFontOfSize:16]; }

UIView *NBNewCard(void) {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = NBCardBG();
    v.layer.cornerRadius = NBCardRadius;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.clipsToBounds = YES;
    return v;
}

UIView *NBNewIconBox(NSString *symbol, UIColor *tint) {
    UIView *box = [[UIView alloc] init];
    box.backgroundColor = tint ?: [UIColor systemGrayColor];
    box.layer.cornerRadius = 7;
    box.layer.cornerCurve = kCACornerCurveContinuous;
    box.clipsToBounds = YES;

    // 🔴 设备上确实存在这张图才加：`systemImageNamed:` 名字写错会返回 nil，
    //    此时留一个纯色小方块（仍然好看），而不是崩、也不是一条空白。
    UIImage *img = symbol.length ? [UIImage systemImageNamed:symbol] : nil;
    if (img) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:img];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.tintColor = [UIColor whiteColor];
        iv.tag = 9001;
        [box addSubview:iv];
    }
    return box;
}

UIImageView *NBNewChevron(void) {
    UIImage *img = [UIImage systemImageNamed:@"chevron.right"];
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.tintColor = [UIColor tertiaryLabelColor];
    return iv;
}

UIView *NBNewSeparator(void) {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = NBSepColor();
    return v;
}

UILabel *NBNewHeaderLabel(NSString *text) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = NBFontHeader();
    l.textColor = [UIColor secondaryLabelColor];
    l.numberOfLines = 0;
    return l;
}

UILabel *NBNewFooterLabel(NSString *text) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:12];
    l.textColor = [UIColor secondaryLabelColor];
    l.numberOfLines = 0;
    return l;
}

// =====================================================================
// v0.0.88：卡片淡染
// =====================================================================
// 🔴 为什么是"淡染"而不是照抄截图的饱和底：截图里紫卡白字、蓝卡白字，
//    文字色要跟着底色亮度在「黑/白」之间切。而本项目的所有字色是**写死**的
//    system label / secondaryLabel（`NBHighlight` 里还有搜索高亮底色），
//    换成饱和底就要把这一整条链路的颜色全部改成"按对比度算" ⇒
//    深色模式下很容易做出"白底白字"，而那种 bug 在模拟器上不一定复现。
//    淡染能用 **同一套系统字色**通吃浅色/深色/搜索高亮，代价只是颜色浅一点。
static UIColor *NBLightCardBase(void) {
    // 和 NBCardBG() 的浅色取值一致：`secondarySystemGroupedBackground` = 白
    return [UIColor whiteColor];
}

static UIColor *NBDarkCardBase(void) {
    // 和 NBCardBG() 的深色取值一致：`secondarySystemGroupedBackground` ≈ #1C1C1E
    return [UIColor colorWithRed:0.1098 green:0.1098 blue:0.1176 alpha:1.0];
}

// 混色：t=0 ⇒ 全 a，t=1 ⇒ 全 b。
// 🔴 直接在 RGB 空间线性混、不做伽马校正：这是"观感调参"，不是色彩管理，
//    而且系统自己的 fill color 也是这么干的。
static UIColor *NBMix(UIColor *a, UIColor *b, CGFloat t) {
    CGFloat ar = 0.5, ag = 0.5, ab = 0.5, aa = 1.0;
    CGFloat br = 0.5, bg = 0.5, bb = 0.5, ba = 1.0;
    if (![a getRed:&ar green:&ag blue:&ab alpha:&aa]) { ar = ag = ab = 0.5; }
    if (![b getRed:&br green:&bg blue:&bb alpha:&ba]) { br = bg = bb = 0.5; }
    CGFloat r = ar + (br - ar) * t;
    CGFloat g = ag + (bg - ag) * t;
    CGFloat bl = ab + (bb - ab) * t;
    return [UIColor colorWithRed:r green:g blue:bl alpha:1.0];
}

// 淡染比例：浅色 20%、深色 28%。
// 🔴 深色必须比浅色高：同样的 alpha 落在 #1C1C1E 上，色差只有落在白上的一半，
//    照搬 20% 的话深色模式下"卡片染色"几乎看不出来（同一份 token 两种观感，最容易漏）。
UIColor *NBCardTint(UIColor *brand) {
    if (!brand) return NBCardBG();
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        BOOL dark = (tc.userInterfaceStyle == UIUserInterfaceStyleDark);
        CGFloat t = dark ? 0.28 : 0.20;
        return NBMix(dark ? NBDarkCardBase() : NBLightCardBase(), brand, t);
    }];
}

UIColor *NBCardTintPressed(UIColor *brand) {
    if (!brand) return [UIColor tertiarySystemFillColor];
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        BOOL dark = (tc.userInterfaceStyle == UIUserInterfaceStyleDark);
        UIColor *tinted = NBMix(dark ? NBDarkCardBase() : NBLightCardBase(), brand,
                                dark ? 0.28 : 0.20);
        // 浅色压黑、深色压白：往下压的方向永远朝"和底色相反"那一边，才看得出按下去了
        return NBMix(tinted, dark ? [UIColor whiteColor] : [UIColor blackColor],
                     dark ? 0.10 : 0.07);
    }];
}

UIColor *NBBadgeTint(UIColor *brand) {
    if (!brand) return [UIColor systemBlueColor];
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        BOOL dark = (tc.userInterfaceStyle == UIUserInterfaceStyleDark);
        // 压暗到亮度 ≈0.55：白字压得住（对比度 ≈4:1），又不至于变成"黑疙瘩"
        return NBMix(brand, [UIColor blackColor], dark ? 0.30 : 0.34);
    }];
}

UIColor *NBBrandFallback(NSString *bundleId) {
    if (!bundleId.length) return nil;
    static NSArray<UIColor *> *pal = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pal = @[
            [UIColor colorWithRed:0.24 green:0.48 blue:0.98 alpha:1.0],   // 蓝
            [UIColor colorWithRed:0.20 green:0.66 blue:0.33 alpha:1.0],   // 绿
            [UIColor colorWithRed:0.92 green:0.34 blue:0.34 alpha:1.0],   // 红
            [UIColor colorWithRed:0.95 green:0.60 blue:0.29 alpha:1.0],   // 橙
            [UIColor colorWithRed:0.61 green:0.32 blue:0.88 alpha:1.0],   // 紫
            [UIColor colorWithRed:0.18 green:0.61 blue:0.86 alpha:1.0],   // 青
            [UIColor colorWithRed:0.88 green:0.34 blue:0.55 alpha:1.0],   // 玫红
            [UIColor colorWithRed:0.49 green:0.70 blue:0.26 alpha:1.0],   // 黄绿
        ];
    });
    // 🔴 FNV-1a，不用 `[bundleId hash]`：NSString 的 hash 苹果不保证跨进程稳定，
    //    用它会出现"重启一下 App，微信从绿色变成紫色"这种没法解释的漂移。
    const char *s = bundleId.UTF8String;
    uint32_t h = 2166136261u;
    while (s && *s) {
        h ^= (uint32_t)(unsigned char)(*s);
        h *= 16777619u;
        s++;
    }
    return pal[(NSUInteger)(h % (uint32_t)pal.count)];
}

