#import "NotifyStatsViewController.h"
#import "NotifyStore.h"
#import "InstalledApps.h"
#import "AppIconLoader.h"
#import "NBTheme.h"

// ================= v0.0.181：统计页改版 =================
// 这一版只动**统计页自己**（数据层另外加了「最晚一条 / 有正文数 / 按天补齐」）。
// 三条设计纪律，先写在最前面免得后人推翻：
//
// ① 🔴 卡片一律用 `NBNewCard()`（白底压灰底），**不许加边框**。
//    设置页就是这个风格，统一 token 的意义就在这儿（v0.0.71 那次把圆角/边距
//    收成一套的结果）。设计稿上画了边框只是为了在浅灰背景里看得清边界。
// ② 🔴 品牌色只用于**条形填充**，不染卡片底、不染文字。
//    统计页是"读数"的地方，一屏十几张彩色卡会把数字本身淹掉 ——
//    而首页那套淡染是"信息流"，两者的用途不同，别照抄。
// ③ 🔴 图表全部**自绘**：本仓库没有、也不允许引入第三方图表库
//    （越狱插件里多一个依赖就多一处注入失败的可能）。

static const CGFloat kNBStatsPad     = 14.0;
// 图表卡高度。🔴 抽成常量是因为 `preferredHeight` 与 `layoutSubviews` **必须用同一个值**：
//    两处写两份数字的话，改了一处就会变成"页头高度比内容高/矮"，
//    而那种错位在屏幕上看起来像"图表被截了一截"，不会有人想到是高度算错。
static const CGFloat kNBStatsChartH  = 176.0;
// 按 App 维度只取前 30：这是"谁最烦人"的排名，不是完整名单。
static const NSInteger kNBStatsTopN  = 30;
// v0.0.184：环形图只画前 6 片（其余合并「其他」）。
// 🔴 不是"最多 6 个 App"—— 本机实测 67 个，全画出来每片不到 2°，颜色也分不开。
//    尾部占比本来就不是这一屏要回答的问题（下面的排行列表才是完整名单）。
static const NSInteger kNBStatsPieTopN = 6;

// ================= v0.0.185：相邻色去重 =================
//
// 🔴 为什么需要：环形每一片、列表每一根条形，颜色都取自**各自的 App 图标主色**，
//    而图标主色不受我控制。真实数据里蓝色系扎堆（京麦 / 知乎 / 支付宝…），
//    相邻两片就糊成一片 —— 用户会以为"饼图只画了一片"。
//
// 🔴🔴 为什么放在 `self.brands` 生成时、而不是画图那一刻：
//    这个字典同时喂给环形图和下面的排行条形。只在画图时调色的话，
//    同一个 App 在饼图里是 A 色、在列表里是 B 色 —— 那比撞色更让人困惑。
//    ⛔ 绝不改 `[AppIconLoader brandColorForBundle:]` 的返回值：它带**全局缓存**，
//       卡片染色等别处也在用，改它会漫到整 App。

static void NBHSB(UIColor *c, CGFloat *h, CGFloat *s, CGFloat *v) {
    CGFloat hh = 0, ss = 0, vv = 0;
    CGFloat aa = 1;
    if (![c getHue:&hh saturation:&ss brightness:&vv alpha:&aa]) {
        // 灰度色给不出色相 ⇒ 退回感知亮度，饱和记 0（下面按"灰阶"那一支处理）
        CGFloat r = 0, g = 0, b = 0;
        if ([c getRed:&r green:&g blue:&b alpha:&aa]) {
            vv = 0.299 * r + 0.587 * g + 0.114 * b;
        }
        ss = 0;
    }
    if (h) *h = hh;
    if (s) *s = ss;
    if (v) *v = vv;
}

// 🔴 色相是**环**：0.95 和 0.05 只差 0.10，不能直接相减。
//
// 🔴🔴 v0.0.185 修订：判"太像"必须看**三个维度**（色相 / 亮度 / 饱和度），
//    只判前两个会把"淡粉 vs 艳红"这种一眼能分的组合判成撞色，
//    然后把 B 站的粉硬改成橙色 —— 那是为了解决撞色而丢掉品牌识别，不值。
//    实测：#FB7299 与 #FF2442 色相差 0.02、亮度差 0.02，但**饱和差 0.38**，
//    肉眼看得很清楚。加上第三个条件后它们不再被误判。
//    ⇒ 两色不可分 ⟺ 三者**同时**接近。
static BOOL NBColorsTooClose(UIColor *a, UIColor *b) {
    if (!a || !b) return NO;
    CGFloat ha, sa, va, hb, sb, vb;
    NBHSB(a, &ha, &sa, &va);
    NBHSB(b, &hb, &sb, &vb);
    if (sa < 0.18 && sb < 0.18) {
        // 两边都接近灰阶 ⇒ 色相没有意义，只能靠亮度分
        return fabs(va - vb) < 0.16;
    }
    CGFloat dh = fabs(ha - hb);
    if (dh > 0.5) dh = 1.0 - dh;
    return (dh < 0.075)                 // ≈27°
        && (fabs(va - vb) < 0.14)       // 亮度
        && (fabs(sa - sb) < 0.25);      // 饱和度
}

// 把 `c` 调到和 `prev` 能分辨为止。⛔ 不改色相除非必须 —— 色相是用户认 App 的线索。
static UIColor *NBSeparateFromColor(UIColor *c, UIColor *prev) {
    if (!c || !prev) return c;
    if (!NBColorsTooClose(c, prev)) return c;

    CGFloat h, s, v;
    NBHSB(c, &h, &s, &v);
    CGFloat pv = 0;
    NBHSB(prev, NULL, NULL, &pv);

    // 第一刀：调亮度，朝**远离 prev** 的方向（否则越调越像）
    CGFloat nv = (v >= pv) ? MAX(0.34, v - 0.26) : MIN(0.96, v + 0.26);
    UIColor *byV = [UIColor colorWithHue:h saturation:s brightness:nv alpha:1.0];
    if (!NBColorsTooClose(byV, prev)) return byV;

    // 第二刀：转色相 40°（≈0.111），同时把饱和度抬到"看得出色相"的下限
    CGFloat nh = fmod(h + 0.111, 1.0);
    UIColor *byH = [UIColor colorWithHue:nh saturation:MAX(s, 0.5) brightness:v alpha:1.0];
    if (!NBColorsTooClose(byH, prev)) return byH;

    // 兜底：退成灰阶，靠亮度分
    return [UIColor colorWithWhite:(v > 0.5 ? 0.42 : 0.70) alpha:1.0];
}
// 按天补齐的上限。🔴 不是"最多显示 92 天"，而是**防止全库 200 天把列表撑成 200 行**：
// 柱状图看的是趋势，最近的够用。
static const NSInteger kNBStatsDayFillMax = 92;

#pragma mark - KPI 卡（4 格数字）

// 2 列 × 2 行。每格 = 一个数字 + 一行小标签。
//
// 🔴 为什么不用 Auto Layout：本页所有子视图都是**本页私有、位置固定**，
//    手算 frame 在这个文件里更直观（和 NotifyCell / 设置页的做法一致）。
//    用约束反而要多写十几行、还得处理 header 换宽时的更新。
@interface NBKpiCard : UIView
@property (nonatomic, strong) NSArray<UILabel *> *valueLabels;   // 4 个
@property (nonatomic, strong) NSArray<UILabel *> *nameLabels;    // 4 个
- (void)setValueText:(NSString *)t atIndex:(NSInteger)i;
- (void)setValueColor:(UIColor *)c atIndex:(NSInteger)i;
- (void)setNameText:(NSString *)t atIndex:(NSInteger)i;
@end

@implementation NBKpiCard {
    UIView *_vLine;
    UIView *_hLine;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    NSMutableArray *vs = [NSMutableArray array];
    NSMutableArray *ns = [NSMutableArray array];
    for (NSInteger i = 0; i < 4; i++) {
        UILabel *v = [[UILabel alloc] init];
        v.font = [UIFont systemFontOfSize:21 weight:UIFontWeightMedium];
        v.textColor = [UIColor labelColor];
        v.adjustsFontSizeToFitWidth = YES;
        v.minimumScaleFactor = 0.6;
        v.numberOfLines = 1;
        [self addSubview:v];
        [vs addObject:v];

        UILabel *n = [[UILabel alloc] init];
        n.font = [UIFont systemFontOfSize:11];
        n.textColor = [UIColor secondaryLabelColor];
        n.numberOfLines = 1;
        [self addSubview:n];
        [ns addObject:n];
    }
    self.valueLabels = vs;
    self.nameLabels = ns;

    _vLine = [[UIView alloc] init];
    _vLine.backgroundColor = NBSepColor();
    [self addSubview:_vLine];
    _hLine = [[UIView alloc] init];
    _hLine.backgroundColor = NBSepColor();
    [self addSubview:_hLine];
    return self;
}

- (void)setValueText:(NSString *)t atIndex:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.valueLabels.count) return;
    self.valueLabels[i].text = t;
}
- (void)setValueColor:(UIColor *)c atIndex:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.valueLabels.count) return;
    self.valueLabels[i].textColor = c;
}
- (void)setNameText:(NSString *)t atIndex:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.nameLabels.count) return;
    self.nameLabels[i].text = t;
}

// 卡高 112：两行各 42（数字 26 + 标签 14 + 2pt 缝），上下各留 14。
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat pad = kNBStatsPad;
    CGFloat colW = (w - pad * 2) / 2.0;
    CGFloat rowH = (h - pad * 2) / 2.0;

    for (NSInteger i = 0; i < 4; i++) {
        CGFloat col = (i % 2);
        CGFloat row = (i / 2);
        CGFloat x = pad + col * colW;
        CGFloat y = pad + row * rowH;
        self.valueLabels[i].frame = CGRectMake(x, y, colW - 8, 26);
        self.nameLabels[i].frame  = CGRectMake(x, y + 27, colW - 8, 14);
    }
    _vLine.frame = CGRectMake(pad + colW, pad, 0.5, h - pad * 2);
    _hLine.frame = CGRectMake(pad, pad + rowH, w - pad * 2, 0.5);
}

@end

#pragma mark - 柱状图（自绘）

// 🔴 只画柱子 + 一条基线，不画网格、不画渐变、不做动画：
//    统计页要的是"一眼看出哪根高"，多余的装饰只会让柱子本身变细。
//
// 🔴 0 值的格子**照样画一根 3pt 的底槽**：这是全站同一条纪律 ——
//    "这一格是空的"和"这一格不存在"必须长得不一样。按天补齐后
//    空白日会真的以 0 出现，画成什么都没有就等于没补。
// v0.0.184：一个视图两种形态。柱状（按小时/按天）+ 环形（按 App 的来源占比）。
//
// 🔴🔴 为什么合成一个类而不是新建 `NBPieChartView`：
//    页头里只有一个 `chart` 视图，`showsChart` 的 setter 只管它的 hidden。
//    拆成两个视图之后，页头就要额外管"哪个显示、哪个隐藏"
//    ⇒ 又变成两个生产者 —— 而这轮刚修完的 bug（v0.0.182 图表卡盖住列表）
//      就是同一个毛病：显隐状态有两个地方在写。
//
// 🔴🔴 两种数据源**互斥**，由 `setKind:` 统一清理（见实现里那段注释）：
//    设成环形就清空 values/axis，设成柱状就清空 slices。
//    不这么做的话，切换维度后残留的另一半数据会让 `drawRect` 画出
//    "用柱状数据画的饼图"或者干脆什么都不画 —— 而且**不报错**。
typedef NS_ENUM(NSInteger, NBChartKind) {
    NBChartKindBars  = 0,   // 柱状：按小时 24 根 / 按天 N 根
    NBChartKindDonut = 1,   // 环形：按 App 的来源占比
};

@interface NBStatsChartView : UIView
@property (nonatomic, assign) NBChartKind kind;
@property (nonatomic, copy) NSArray<NSNumber *> *values;
@property (nonatomic, copy) NSArray<NSString *> *axis;      // 与 values 等长，nil 项不画
@property (nonatomic, strong) UIColor *barColor;
// kind == NBChartKindDonut 时用。每项：@{@"value":NSNumber, @"color":UIColor, @"name":NSString}
@property (nonatomic, copy) NSArray<NSDictionary *> *slices;
@property (nonatomic, copy) NSString *summary;              // 无障碍概述
@end

@implementation NBStatsChartView

// 🔴 唯一的类型入口，顺带做数据互斥清理。
- (void)setKind:(NBChartKind)kind {
    _kind = kind;
    if (kind == NBChartKindDonut) {
        _values = @[];
        _axis = nil;
    } else {
        _slices = @[];
    }
    [self setNeedsDisplay];
}

- (void)setSlices:(NSArray<NSDictionary *> *)slices {
    _slices = [slices copy] ?: @[];
    // 数据到了就把类型定死，调用方只喂数据、不必记得先设 kind
    if (_slices.count > 0) self.kind = NBChartKindDonut;
    [self setNeedsDisplay];
}

- (void)setValues:(NSArray<NSNumber *> *)values axis:(NSArray<NSString *> *)axis {
    self.values = values ?: @[];
    self.axis = axis;
    if (self.values.count > 0) self.kind = NBChartKindBars;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];
    if (self.kind == NBChartKindDonut) {
        [self nbDrawDonut];
        return;
    }
    NSArray<NSNumber *> *vals = self.values;
    NSInteger n = (NSInteger)vals.count;
    if (n <= 0) return;

    CGFloat pad = kNBStatsPad;
    CGFloat axisH = 14.0;                       // 底部留给轴标
    CGFloat usableW = self.bounds.size.width - pad * 2;
    CGFloat baseY = self.bounds.size.height - axisH;      // 基线
    CGFloat topY = 6.0;
    CGFloat plotH = baseY - topY;
    if (usableW <= 0 || plotH <= 0) return;

    NSInteger mx = 0;
    for (NSNumber *v in vals) {
        if ([v integerValue] > mx) mx = [v integerValue];
    }

    CGFloat slot = usableW / (CGFloat)n;
    // 柱宽 = 槽宽的 62%，最少 1.5pt（按天 92 根时槽宽只有 ~2.6pt）。
    // 🔴 最少值不能取 1.0：1pt 的柱子在 2x 屏上会被抹成半透明，看图的人会以为"数据缺失"。
    CGFloat barW = MAX(1.5, slot * 0.62);
    if (barW > 14.0) barW = 14.0;               // 只有 3~5 根时不要变成粗方块

    UIColor *empty = [UIColor tertiarySystemFillColor];
    UIColor *fill = self.barColor ?: [UIColor systemBlueColor];

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    for (NSInteger i = 0; i < n; i++) {
        NSInteger v = [vals[i] integerValue];
        CGFloat x = pad + slot * (CGFloat)i + (slot - barW) / 2.0;
        CGFloat hgt;
        if (v <= 0 || mx <= 0) {
            // 空槽：高度固定 3pt，颜色用底槽色 ⇒ "这里是一格空的"
            [empty setFill];
            hgt = 3.0;
        } else {
            [fill setFill];
            hgt = plotH * (CGFloat)v / (CGFloat)mx;
            if (hgt < 3.0) hgt = 3.0;            // 有值但很矮时也要看得见（1 条 ≠ 0 条）
        }
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:
                           CGRectMake(x, baseY - hgt, barW, hgt)
                                                    cornerRadius:MIN(2.0, barW / 2.0)];
        [p fill];
    }

    [[UIColor quaternaryLabelColor] setFill];
    UIRectFill(CGRectMake(pad, baseY, usableW, 0.5));

    // 轴标：只画打了点的那几格（VC 侧已经算好，这里按索引取）
    if (self.axis.count == (NSUInteger)n) {
        NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:10],
                                 NSForegroundColorAttributeName: [UIColor tertiaryLabelColor] };
        for (NSInteger i = 0; i < n; i++) {
            NSString *t = self.axis[i];
            if (![t isKindOfClass:[NSString class]] || !t.length) continue;
            CGSize sz = [t sizeWithAttributes:attrs];
            // 夹在图内：两端那几格的标签会顶到卡片外面
            CGFloat cx = pad + slot * (CGFloat)i + slot / 2.0;
            CGFloat tx = cx - sz.width / 2.0;
            if (tx < 0) tx = 0;
            if (tx + sz.width > self.bounds.size.width) tx = self.bounds.size.width - sz.width;
            [t drawAtPoint:CGPointMake(tx, baseY + 3) withAttributes:attrs];
        }
    }
}

- (void)setSummary:(NSString *)summary {
    _summary = [summary copy];
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitImage;
    self.accessibilityLabel = summary;
}

#pragma mark - v0.0.184 环形图

// 🔴 环形而不是实心饼：
//    ① 中间那块空白正好写总数，省掉一个额外的 label；
//    ② 实心饼在"最大那片超过 60%"时会显得像一整个圆（用户以为只有一种 App），
//       环形有内圈做参照，比例更容易看出来。
//
// 🔴 只画前 6 片 + 「其他」：本机 67 个 App，全画出来每片不到 2°，
//    颜色也分不开。占比的**尾部**本来就不是这一屏要回答的问题（下面的排行列表
//    才是完整名单）。
//
// ⚠️ 图例（右侧那几行）用 `drawInRect:` 画，不用 UILabel：
//    这几种形态共用同一个视图，用子视图就得管"环形时显示、柱状时隐藏"，
//    又是一处显隐状态的两个生产者。
- (void)nbDrawDonut {
    NSArray<NSDictionary *> *sl = self.slices;
    NSInteger n = (NSInteger)sl.count;
    if (n <= 0) return;

    CGFloat pad = kNBStatsPad;
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    if (W <= 0 || H <= 0) return;

    NSInteger total = 0;
    for (NSDictionary *d in sl) total += [d[@"value"] integerValue];
    if (total <= 0) return;

    // 环形直径：高度的 92% 与宽度的 42%，取小的那个；再给个下限防止极窄时画成小点
    CGFloat D = MIN(H - 8.0, W * 0.42);
    if (D < 72.0) D = MIN(H - 8.0, 72.0);
    if (D < 40.0) return;
    CGFloat cx = pad + D / 2.0;
    CGFloat cy = H / 2.0;
    CGFloat outerR = D / 2.0;
    CGFloat innerR = outerR * 0.56;

    CGFloat start = -M_PI_2;                    // 从 12 点开始，最像"表盘"
    UIColor *seam = NBCardBG();                 // 分隔缝的颜色 = 卡片底色
    for (NSDictionary *d in sl) {
        NSInteger v = [d[@"value"] integerValue];
        if (v <= 0) continue;
        CGFloat sweep = 2.0 * M_PI * (CGFloat)v / (CGFloat)total;
        // 🔴 只有一片（或者某片占 100%）时，整圆弧的接缝会露出一条白线。
        //    留 0.02° 的缺口看不出来，但接缝没了。
        if (sweep > 2.0 * M_PI - 0.001) sweep = 2.0 * M_PI - 0.001;

        UIBezierPath *p = [UIBezierPath bezierPath];
        [p addArcWithCenter:CGPointMake(cx, cy) radius:outerR
                  startAngle:start endAngle:start + sweep clockwise:YES];
        [p addArcWithCenter:CGPointMake(cx, cy) radius:innerR
                  startAngle:start + sweep endAngle:start clockwise:NO];
        [p closePath];
        UIColor *c = d[@"color"];
        [(c ?: [UIColor systemBlueColor]) setFill];
        [p fill];

        // 🔴🔴 v0.0.185：每片再描一圈**卡片底色** ⇒ 相邻两片之间露出一条细缝。
        //    两道防线的分工要说清，否则以后有人会以为这条缝是冗余的：
        //    ① `NBSeparateFromColor`（在生成 brands 那一步）让**颜色本身**尽量不同；
        //    ② 这条缝保证"两个 App 的图标主色真的一模一样时也能看出边界"。
        //    ⚠️ ② 还盖住了一个 ① 结构上管不到的位置：**环形的首尾**。
        //       饼图是闭环，第 1 片和第 N 片视觉上相邻，但它们不是"前后项"
        //       （序列去重只跟 prev 比）⇒ 首尾撞色只能靠这条缝兜底。
        //       ⛔ 别为了首尾再去改 slices 里最后一片的颜色：那会让同一个 App
        //          在饼图里是 A 色、在下面排行条形里是 B 色，比撞色更让人困惑。
        //    ⚠️ 用描边而不是"把扇形缩小留缝"：留缝会改变每片的**实际面积**，
        //       占比就不准了；描边压在边界上，数据面积不变。
        [seam setStroke];
        p.lineWidth = 1.2;
        [p stroke];

        start += sweep;
    }

    // ---------- 环形中间：总数 ----------
    NSMutableParagraphStyle *mid = [[NSMutableParagraphStyle alloc] init];
    mid.alignment = NSTextAlignmentCenter;
    CGFloat midW = innerR * 2.0 - 4.0;
    NSString *big = [NSString stringWithFormat:@"%ld", (long)total];
    [big drawInRect:CGRectMake(cx - midW / 2.0, cy - 16.0, midW, 20.0)
     withAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold],
                       NSForegroundColorAttributeName: [UIColor labelColor],
                       NSParagraphStyleAttributeName: mid }];
    [@"条" drawInRect:CGRectMake(cx - midW / 2.0, cy + 4.0, midW, 13.0)
       withAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:10],
                         NSForegroundColorAttributeName: [UIColor tertiaryLabelColor],
                         NSParagraphStyleAttributeName: mid }];

    // ---------- 右侧图例 ----------
    CGFloat lx = pad + D + 10.0;
    CGFloat lw = W - lx - pad;
    if (lw < 66.0) return;                      // 太窄就不画图例，环本身已经说明问题

    CGFloat rowH = MIN(19.0, (H - 4.0) / (CGFloat)n);
    CGFloat ly = (H - rowH * (CGFloat)n) / 2.0;
    NSDictionary *nameAttrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:11],
                                 NSForegroundColorAttributeName: [UIColor labelColor] };
    NSDictionary *pctAttrs  = @{ NSFontAttributeName: [UIFont systemFontOfSize:11],
                                 NSForegroundColorAttributeName: [UIColor secondaryLabelColor] };

    for (NSDictionary *d in sl) {
        NSInteger v = [d[@"value"] integerValue];
        // 色点
        UIColor *c = d[@"color"];
        [(c ?: [UIColor systemBlueColor]) setFill];
        UIBezierPath *dot = [UIBezierPath bezierPathWithRoundedRect:
                             CGRectMake(lx, ly + (rowH - 7.0) / 2.0, 7.0, 7.0) cornerRadius:2.0];
        [dot fill];

        // 百分比（先画右侧，名字用剩下的宽度，避免长名字把数字挤出去）
        NSString *pct = [NSString stringWithFormat:@"%.0f%%", (CGFloat)v * 100.0 / (CGFloat)total];
        CGSize pctSz = [pct sizeWithAttributes:pctAttrs];
        CGFloat pctX = lx + lw - pctSz.width;
        [pct drawAtPoint:CGPointMake(pctX, ly + (rowH - pctSz.height) / 2.0)
          withAttributes:pctAttrs];

        // 名字（截断）
        NSString *nm = d[@"name"];
        if (![nm isKindOfClass:[NSString class]] || !nm.length) nm = @"—";
        CGFloat nameW = pctX - (lx + 12.0) - 6.0;
        if (nameW > 4.0) {
            [nm drawInRect:CGRectMake(lx + 12.0, ly + (rowH - 14.0) / 2.0, nameW, 14.0)
            withAttributes:nameAttrs];
        }
        ly += rowH;
    }
}

@end

#pragma mark - 一行明细

@interface NBStatCell : UITableViewCell
@property (nonatomic, strong) UILabel *rankLabel;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *cntLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UIView *barBox;
@property (nonatomic, strong) UIView *barFill;
// 🔴🔴 v0.0.181：**条长用比例，不用像素宽**。
//    原来（v0.0.171~180）是 cellForRow 里直接算 `w * n / max` 写进 barFill.frame，
//    而那一刻 `barBox.bounds` 可能还是 0（cell 刚 dequeue、layoutSubviews 还没跑）
//    ⇒ 首次上屏的几行条形宽度算成 0，**滚动一下再回来才正常**。
//    比例存下来、由 layoutSubviews 乘上真实的槽宽，时序问题就从结构上消失了。
@property (nonatomic, assign) CGFloat ratio;
@end

@implementation NBStatCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    self.rankLabel = [[UILabel alloc] init];
    self.rankLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    self.rankLabel.textColor = [UIColor tertiaryLabelColor];
    self.rankLabel.textAlignment = NSTextAlignmentLeft;
    [self.contentView addSubview:self.rankLabel];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.font = [UIFont systemFontOfSize:14];
    self.nameLabel.textColor = [UIColor labelColor];
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:self.nameLabel];

    self.cntLabel = [[UILabel alloc] init];
    self.cntLabel.font = [UIFont systemFontOfSize:12];
    self.cntLabel.textColor = [UIColor secondaryLabelColor];
    self.cntLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:self.cntLabel];

    // 条形底槽（浅）+ 填充（品牌色）。分两层而不是改一个 view 的背景色：
    // 这样"占比 0"时底槽还在，用户能看出**这里确实有一格**，只是它是空的。
    self.barBox = [[UIView alloc] init];
    self.barBox.backgroundColor = [UIColor tertiarySystemFillColor];
    self.barBox.layer.cornerRadius = 3;
    self.barBox.clipsToBounds = YES;
    [self.contentView addSubview:self.barBox];

    self.barFill = [[UIView alloc] init];
    self.barFill.backgroundColor = [UIColor systemBlueColor];
    [self.barBox addSubview:self.barFill];

    // 右下角彩蛋行：未读数 / 占比之外的补充说明（各维度含义不同，由 VC 决定写什么）
    self.subLabel = [[UILabel alloc] init];
    self.subLabel.font = [UIFont systemFontOfSize:11];
    self.subLabel.textColor = [UIColor tertiaryLabelColor];
    self.subLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:self.subLabel];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat pad = kNBStatsPad;

    BOOL hasRank = self.rankLabel.text.length > 0;
    CGFloat rankW = hasRank ? 20.0 : 0.0;
    self.rankLabel.frame = CGRectMake(pad, 8, rankW, 19);

    // 🔴 右侧条数按内容宽度自适应（不写死 96 ⇒ 长文本被截断「显示不全」）。
    //    给名字至少留 90pt；超出则截断右侧标签本身，绝不挤压名字到看不见。
    CGFloat left = pad + rankW;
    CGFloat maxCnt = w - left - pad - 90.0;
    CGFloat cntW = self.cntLabel.intrinsicContentSize.width;
    if (cntW > maxCnt) cntW = maxCnt;
    if (cntW < 0) cntW = 0;

    self.cntLabel.frame  = CGRectMake(w - pad - cntW, 8, cntW, 19);
    self.nameLabel.frame = CGRectMake(left, 7, w - left - pad - cntW - 8, 20);
    self.subLabel.frame  = CGRectMake(left, 41, w - left - pad, 14);
    self.barBox.frame    = CGRectMake(left, 31, w - left - pad, 6);
    // 条长在这一处算：槽宽只有这里才知道（见 `ratio` 的注释）
    self.barFill.frame   = CGRectMake(0, 0, self.barBox.bounds.size.width * self.ratio,
                                      self.barBox.bounds.size.height);
}

// 🔴 复用池必须清：条形的宽度是"上一次的值"，不清的话滚一下就会看到
//    "新行的名字 + 上一行的条长"（本项目已栽过三次同类）。
- (void)prepareForReuse {
    [super prepareForReuse];
    self.rankLabel.text = nil;
    self.nameLabel.text = nil;
    self.cntLabel.text = nil;
    self.subLabel.text = nil;
    self.ratio = 0;
    self.barFill.frame = CGRectMake(0, 0, 0, self.barBox.bounds.size.height);
    self.barFill.backgroundColor = [UIColor systemBlueColor];
    self.accessibilityLabel = nil;
}

@end

#pragma mark - 页头（KPI 卡 + 图表卡 + 分组标题）

@interface NBStatsHeaderView : UIView
@property (nonatomic, strong) NBKpiCard *kpi;
@property (nonatomic, strong) UIView *chartCard;
@property (nonatomic, strong) UILabel *chartTitle;
@property (nonatomic, strong) NBStatsChartView *chart;
@property (nonatomic, strong) UILabel *sectionLabel;
@property (nonatomic, assign) BOOL showsChart;
- (CGFloat)preferredHeight;
@end

@implementation NBStatsHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.kpi = [[NBKpiCard alloc] initWithFrame:CGRectZero];
    self.kpi.backgroundColor = NBCardBG();
    self.kpi.layer.cornerRadius = NBCardRadius;
    self.kpi.clipsToBounds = YES;
    [self addSubview:self.kpi];

    self.chartCard = [[UIView alloc] init];
    self.chartCard.backgroundColor = NBCardBG();
    self.chartCard.layer.cornerRadius = NBCardRadius;
    self.chartCard.clipsToBounds = YES;
    [self addSubview:self.chartCard];

    self.chartTitle = [[UILabel alloc] init];
    self.chartTitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.chartTitle.textColor = [UIColor secondaryLabelColor];
    [self.chartCard addSubview:self.chartTitle];

    self.chart = [[NBStatsChartView alloc] initWithFrame:CGRectZero];
    self.chart.backgroundColor = [UIColor clearColor];
    [self.chartCard addSubview:self.chart];

    self.sectionLabel = [[UILabel alloc] init];
    self.sectionLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.sectionLabel.textColor = [UIColor secondaryLabelColor];
    [self addSubview:self.sectionLabel];
    return self;
}

// 🔴🔴 `showsChart` 有**两条赋值路径**：`setChartHidden:`（reloadData 按维度设）
//      和 `syncHeaderSize`（按 selectedSegmentIndex 重设）。原来两边各写各的，
//      而 chartCard 的 hidden 谁都不管 ⇒ 切回「按 App」时卡片留着上一轮的 170pt
//      frame 盖住列表前 3 行，页头高度却已经缩回去了。
//      ⇒ hidden 与 frame 归零一律由 setter 管，任何赋值路径都逃不掉。
//      这是"同一个量只许有一个生产者"在本页的落点，别再往调用点补 hidden。
- (void)setShowsChart:(BOOL)showsChart {
    _showsChart = showsChart;
    self.chartCard.hidden = !showsChart;
    if (!showsChart) self.chartCard.frame = CGRectZero;
    [self setNeedsLayout];
}

- (CGFloat)preferredHeight {
    // 🔴 这里的每一个数字都必须和 `layoutSubviews` 一一对应。差一处的后果不是
    //    "多留白"，而是页头和内容错位（卡片被裁 / 列表被盖）。
    CGFloat y = 10.0;
    y += 112.0;                        // KPI 卡
    if (self.showsChart) y += 12.0 + kNBStatsChartH;
    y += 20.0 + 18.0;                  // 分组标题（上间距 20：原来 14 贴着图表卡太挤）
    return y + 12.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat pad = kNBStatsPad;
    CGFloat cw = w - pad * 2;
    CGFloat y = 10.0;

    self.kpi.frame = CGRectMake(pad, y, cw, 112.0);
    y += 112.0;

    if (self.showsChart) {
        y += 12.0;
        self.chartCard.frame = CGRectMake(pad, y, cw, kNBStatsChartH);
        self.chartTitle.frame = CGRectMake(pad, 14, cw - pad * 2, 16);
        self.chart.frame = CGRectMake(pad, 38, cw - pad * 2, kNBStatsChartH - 38.0 - 12.0);
        y += kNBStatsChartH;
    }
    // 隐藏这一侧不用管 frame：`showsChart` 的 setter 已经把它归零并 hidden 了。
    self.sectionLabel.frame = CGRectMake(pad + 2, y + 20.0, cw - 4, 18);
}

@end

#pragma mark - 自定义时间窗：起止日期选择器（模态）

@interface NBDateRangeViewController : UIViewController
@property (nonatomic, assign) NSTimeInterval initialSince;
@property (nonatomic, assign) NSTimeInterval initialBeforeTs;
@property (nonatomic, copy) void (^completion)(NSTimeInterval since, NSTimeInterval beforeTs);
@property (nonatomic, copy) void (^cancelBlock)(void);
@end

@implementation NBDateRangeViewController {
    UIDatePicker *_startPicker;
    UIDatePicker *_endPicker;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"自定义时间窗";
    self.view.backgroundColor = NBPageBG();   // v0.0.71 与全站统一：分组灰底 + 白卡片
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                         style:UIBarButtonItemStyleDone
                                        target:self action:@selector(onDone:)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消"
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(onCancel:)];

    UILabel *ls = [[UILabel alloc] init];
    ls.text = @"开始日期"; ls.font = [UIFont systemFontOfSize:13];
    ls.textColor = [UIColor secondaryLabelColor];
    UILabel *le = [[UILabel alloc] init];
    le.text = @"结束日期"; le.font = [UIFont systemFontOfSize:13];
    le.textColor = [UIColor secondaryLabelColor];

    _startPicker = [[UIDatePicker alloc] init];
    _startPicker.datePickerMode = UIDatePickerModeDate;
    _startPicker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    if (@available(iOS 15.0, *)) _startPicker.maximumDate = [NSDate date];
    _endPicker = [[UIDatePicker alloc] init];
    _endPicker.datePickerMode = UIDatePickerModeDate;
    _endPicker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    if (@available(iOS 15.0, *)) _endPicker.maximumDate = [NSDate date];

    // 🔴 默认值：start = 7 天前；end = 今天（都取当地 0 点）。
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *today = [cal startOfDayForDate:[NSDate date]];
    NSDate *weekAgo = [cal dateByAddingUnit:NSCalendarUnitDay value:-7 toDate:today options:0];
    if (self.initialSince > 0)
        _startPicker.date = [cal startOfDayForDate:[NSDate dateWithTimeIntervalSince1970:self.initialSince]];
    else _startPicker.date = weekAgo;
    if (self.initialBeforeTs > 0)
        _endPicker.date = [cal startOfDayForDate:
                           [NSDate dateWithTimeIntervalSince1970:self.initialBeforeTs - 86400.0]];
    else _endPicker.date = today;

    for (UIView *v in @[ls, le, _startPicker, _endPicker]) [self.view addSubview:v];
    ls.translatesAutoresizingMaskIntoConstraints = NO;
    le.translatesAutoresizingMaskIntoConstraints = NO;
    _startPicker.translatesAutoresizingMaskIntoConstraints = NO;
    _endPicker.translatesAutoresizingMaskIntoConstraints = NO;
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [ls.topAnchor constraintEqualToAnchor:g.topAnchor constant:16],
        [ls.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [_startPicker.topAnchor constraintEqualToAnchor:ls.bottomAnchor constant:4],
        [_startPicker.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [_startPicker.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [le.topAnchor constraintEqualToAnchor:_startPicker.bottomAnchor constant:16],
        [le.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [_endPicker.topAnchor constraintEqualToAnchor:le.bottomAnchor constant:4],
        [_endPicker.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [_endPicker.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
    ]];
}

- (void)onDone:(id)sender {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *sd = [cal startOfDayForDate:_startPicker.date];          // 当地 0 点
    NSDate *ed = [cal startOfDayForDate:_endPicker.date];
    // 🔴 上界 = 结束日 + 1 天 0 点 ⇒ 让「结束日当天」整日都包含在内（闭区间语义）。
    NSDate *edNext = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:ed options:0];
    if ([edNext timeIntervalSince1970] <= [sd timeIntervalSince1970]) {
        // 结束早于开始：把结束往后推一天，保证窗口有效，不弹报错打断用户。
        edNext = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:sd options:0];
    }
    if (self.completion) {
        self.completion([sd timeIntervalSince1970], [edNext timeIntervalSince1970]);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onCancel:(id)sender {
    if (self.cancelBlock) self.cancelBlock();
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

#pragma mark - 统计页

@interface NotifyStatsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISegmentedControl *dimSeg;      // 维度：App / 小时 / 天
@property (nonatomic, strong) UISegmentedControl *rangeSeg;    // 时间窗：全部 / 7天 / 30天 / 自定义
@property (nonatomic, strong) NBStatsHeaderView *header;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSDictionary *> *rows;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *names;       // bid -> 显示名
@property (nonatomic, strong) NSDictionary<NSString *, UIColor *> *brands;       // bid -> 品牌色
@property (nonatomic, assign) NSInteger max;                   // 本屏最大值，条形按比例
@property (nonatomic, assign) NSInteger grandTotal;            // 本时间窗总条数（占比的分母）
@property (nonatomic, assign) NSTimeInterval customSince;
@property (nonatomic, assign) NSTimeInterval customBeforeTs;
// v0.0.181：数字滚动用于 KPI 前两格（总条数 / 未读）。
@property (nonatomic, strong) NSTimer *nbRollTimer;
@property (nonatomic, assign) BOOL inSync;                     // 防 tableHeaderView 重设递归
@property (nonatomic, assign) NSInteger lastRollTotal;         // 上次滚到的终值
@property (nonatomic, assign) NSInteger lastRollUnread;

- (void)onDim:(UISegmentedControl *)seg;
- (void)onRange:(UISegmentedControl *)seg;
- (void)reloadData;
- (NSTimeInterval)sinceFromSeg;
- (NSTimeInterval)beforeTsFromSeg;
- (NSString *)nameForRow:(NSDictionary *)d;
@end

@implementation NotifyStatsViewController

- (void)dealloc {
    // ⛔ 少了这一句，定时器会继续持着 block 里的 weakSelf 跑完 0.3s；
    // 虽然跑完自己会停，但"页面已经销毁、定时器还在推"是不该存在的状态。
    [_nbRollTimer invalidate];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"统计";
    self.view.backgroundColor = NBPageBG();

    self.dimSeg = [[UISegmentedControl alloc] initWithItems:@[@"按 App", @"按小时", @"按天"]];
    self.dimSeg.selectedSegmentIndex = 0;
    [self.dimSeg addTarget:self action:@selector(onDim:)
          forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.dimSeg];

    self.rangeSeg = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"7 天", @"30 天", @"自定义"]];
    self.rangeSeg.selectedSegmentIndex = 0;
    [self.rangeSeg addTarget:self action:@selector(onRange:)
            forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.rangeSeg];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 62;
    self.table.backgroundColor = [UIColor clearColor];
    self.table.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.table registerClass:[NBStatCell class] forCellReuseIdentifier:@"stat"];
    // 🔴 空列表不要留一片白底配一堆留白：给一句"这个时间窗里没有记录"，
    //    否则用户分不清"没数据"和"页面坏了"。
    self.table.tableFooterView = [[UIView alloc] init];
    // 内容整体上移一点，让卡片贴着分段控件（默认 inset 会多出一段空白）
    self.table.contentInset = UIEdgeInsetsMake(0, 0, 16, 0);
    [self.view addSubview:self.table];

    self.header = [[NBStatsHeaderView alloc] initWithFrame:CGRectMake(0, 0, 320, 200)];
    self.table.tableHeaderView = self.header;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat top = self.view.safeAreaInsets.top;
    CGFloat pad = kNBStatsPad;

    self.dimSeg.frame   = CGRectMake(pad, top + 8, w - pad * 2, 32);
    self.rangeSeg.frame = CGRectMake(pad, top + 48, w - pad * 2, 32);
    CGFloat ty = top + 88;
    self.table.frame = CGRectMake(0, ty, w, h - ty);
    [self syncHeaderSize];
}

#pragma mark - 时间窗

// 🔴 时间窗和列表完全同一个口径（`ts >= since`），不另发明一套 ——
//    两个指标打架是这个项目最贵的一类事故（v0.0.37 的红点）。
- (NSTimeInterval)sinceFromSeg {
    NSInteger i = self.rangeSeg.selectedSegmentIndex;
    if (i == 1) return [[NSDate date] timeIntervalSince1970] - 7 * 86400.0;
    if (i == 2) return [[NSDate date] timeIntervalSince1970] - 30 * 86400.0;
    if (i == 3) return self.customSince;     // 自定义起点
    return 0;
}

// 🔴 `beforeTs` 是时间窗的上界（`ts < beforeTs`），只有「自定义」才用，其余窗口都不限上界。
- (NSTimeInterval)beforeTsFromSeg {
    return (self.rangeSeg.selectedSegmentIndex == 3) ? self.customBeforeTs : 0;
}

- (void)onDim:(UISegmentedControl *)seg   { [self reloadData]; }
- (void)onRange:(UISegmentedControl *)seg {
    if (seg.selectedSegmentIndex == 3) {
        // 🔴 选「自定义」就弹起止日期选择器；若用户取消（没选就关掉），
        //    把分段切回「全部」，避免停在"自定义"却没有任何范围可用。
        NBDateRangeViewController *r = [[NBDateRangeViewController alloc] init];
        r.initialSince = self.customSince;
        r.initialBeforeTs = self.customBeforeTs;
        __weak typeof(self) wself = self;
        r.completion = ^(NSTimeInterval since, NSTimeInterval beforeTs) {
            typeof(self) s = wself;
            if (!s) return;
            s.customSince = since;
            s.customBeforeTs = beforeTs;
            [s reloadData];
        };
        // 🔴 取消时把分段切回「全部」—— 否则会出现"标着自定义、却显示全部"的矛盾。
        r.cancelBlock = ^{
            typeof(self) s = wself;
            if (!s) return;
            s.rangeSeg.selectedSegmentIndex = 0;
            [s reloadData];
        };
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:r];
        [self presentViewController:nav animated:YES completion:nil];
        return;
    }
    [self reloadData];
}

#pragma mark - 页头尺寸

// 🔴🔴 `tableHeaderView` 的**高度不会自动跟随内部内容**：它按你赋进去那一刻的
//     frame 定死。所以要改高度必须"改 frame + 重新赋一次"。而重新赋值会触发
//     table 的 layout ⇒ 可能再次进到这个函数 ⇒ 必须靠 `inSync` 断开，
//     ⛔ 不能靠"高度没变就 return"单独挡（宽度变了高度没变时也得重排）。
- (void)syncHeaderSize {
    if (self.inSync) return;
    CGFloat w = self.table.bounds.size.width;
    if (w <= 0) return;
    self.inSync = YES;

    // 🔴🔴 v0.0.184：这里**不再判断显隐**。
    //    原来这里按 `dimSeg.selectedSegmentIndex` 又算了一遍"要不要显示图表"
    //    —— 那是"按 App 维度不显示图表"时代的规则。现在按 App 也有环形图，
    //    这一句会在 reloadData 之后把它重新关掉（顺序上 syncHeaderSize 在后），
    //    表现是"饼图的数据都算好了，卡片却不见了"。
    //    ⇒ 显隐的**唯一生产者**是 reloadData 里的 `setChartHidden:`，
    //      这里只按当前状态算高度。
    //    ⚠️ 注释里**故意不把那行旧代码写出来** —— 写了就成了存在性判据的假证据
    //       （删了 X 又留一句"X 已删除"，两向都会中）。
    CGFloat h = [self.header preferredHeight];
    if (fabs(self.header.frame.size.width - w) > 0.5 ||
        fabs(self.header.frame.size.height - h) > 0.5) {
        self.header.frame = CGRectMake(0, 0, w, h);
        [self.header setNeedsLayout];
        [self.header layoutIfNeeded];
        self.table.tableHeaderView = self.header;
    }
    self.inSync = NO;
}

#pragma mark - 数据

- (void)reloadData {
    NSTimeInterval since = [self sinceFromSeg];
    NSTimeInterval before = [self beforeTsFromSeg];

    NSDictionary *sum = [NotifyStore statsSummarySince:since beforeTs:before];
    NSInteger total  = [sum[@"total"] integerValue];
    NSInteger unread = [sum[@"unread"] integerValue];
    NSInteger apps   = [sum[@"apps"] integerValue];
    NSInteger withBody = [sum[@"withBody"] integerValue];
    NSDate *earliest = sum[@"earliest"];
    NSDate *latest   = sum[@"latest"];
    self.grandTotal = total;

    NSInteger dim = self.dimSeg.selectedSegmentIndex;

    if (dim == 0) {
        self.rows = [NotifyStore statsBundlesSince:since beforeTs:before limit:kNBStatsTopN];
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (InstalledApp *a in [InstalledApps all]) {
            if (a.bundleId.length) m[a.bundleId] = a.name;
        }
        self.names = m;
        // 🔴 品牌色**只在这里算一次**（滚动时 cellForRow 会被调几十次）。
        //    取不到就走 `NBBrandFallback`（按 bundle 稳定哈希）：
        //    没有品牌色时绝不许染出一个随机色，那比无色更可疑。
        //
        // 🔴🔴 v0.0.185：**逐项和上一项比一次，太近就拉开**。
        //    环形图的片和列表的条形都用这份字典 ⇒ 两处颜色必须一致，
        //    所以去重必须在"生成字典"这一步做，不能在画图时做。
        //    ⚠️ `prev` 用的是**调整后**的颜色：链式去重，
        //       保证"任意相邻两项"都能分辨（只跟原始色比的话，
        //       连续三个同色系 Adjust 之后又会撞回去）。
        NSMutableDictionary *bm = [NSMutableDictionary dictionary];
        UIColor *prevBrand = nil;
        for (NSDictionary *d in self.rows) {
            NSString *bid = d[@"bundle"];
            if (!bid.length) continue;
            UIColor *c = [AppIconLoader brandColorForBundle:bid];
            if (!c) c = NBBrandFallback(bid);
            if (!c) c = [UIColor systemBlueColor];
            c = NBSeparateFromColor(c, prevBrand);
            bm[bid] = c;
            prevBrand = c;
        }
        self.brands = bm;
    } else {
        self.rows = [NotifyStore statsBucketsSince:since beforeTs:before
                                            byHour:(dim == 1)
                                           maxFill:kNBStatsDayFillMax];
        self.names = @{};
        self.brands = @{};
    }

    // 条形的分母 = 本屏最大值。max 为 0 时（全空）不该除零 ⇒ 下面用 `max > 0 ? … : 0`
    NSInteger mx = 0;
    for (NSDictionary *d in self.rows) {
        NSInteger n = [d[@"total"] integerValue];
        if (n > mx) mx = n;
    }
    self.max = mx;

    // ---------- KPI ----------
    // 🔴 前两格**固定**（总条数 / 未读）—— 切维度时它们不能变，
    //    否则用户每次换页签都要重新找"总数在哪"。后两格随维度给出该维度的洞察。
    CGFloat rate = (total > 0) ? ((CGFloat)unread * 100.0 / (CGFloat)total) : 0;
    NSInteger days = [self windowDaysWithEarliest:earliest latest:latest];

    [self.header.kpi setNameText:@"总条数" atIndex:0];
    [self.header.kpi setNameText:(total > 0
        ? [NSString stringWithFormat:@"未读 · 占 %.0f%%", rate]
        : @"未读") atIndex:1];
    [self.header.kpi setValueColor:[UIColor labelColor] atIndex:0];
    [self.header.kpi setValueColor:(unread > 0 ? [UIColor systemRedColor]
                                              : [UIColor labelColor]) atIndex:1];
    [self.header.kpi setValueText:(total > 0 ? [NSString stringWithFormat:@"%ld", (long)apps] : @"—")
                          atIndex:2];
    [self.header.kpi setNameText:@"来源 App" atIndex:2];

    if (dim == 0) {
        [self.header.kpi setValueText:[self dailyAverageText:total days:days] atIndex:3];
        [self.header.kpi setNameText:(withBody > 0 && total > 0
            ? [NSString stringWithFormat:@"日均条数 · 有正文 %.0f%%",
               (CGFloat)withBody * 100.0 / (CGFloat)total]
            : @"日均条数") atIndex:3];
    } else if (dim == 1) {
        // 高峰时段 / 最忙一小时都从**同一份 rows** 里取，不另查一次库
        NSInteger peakHour = -1, peakN = 0, sumN = 0;
        for (NSDictionary *d in self.rows) {
            NSInteger n = [d[@"total"] integerValue];
            sumN += n;
            if (n > peakN) { peakN = n; peakHour = [d[@"hour"] integerValue]; }
        }
        [self.header.kpi setValueText:(peakHour >= 0 && peakN > 0
            ? [NSString stringWithFormat:@"%ld 点", (long)peakHour] : @"—") atIndex:2];
        [self.header.kpi setNameText:@"高峰时段" atIndex:2];
        [self.header.kpi setValueText:(peakN > 0 ? [NSString stringWithFormat:@"%ld", (long)peakN] : @"—")
                              atIndex:3];
        [self.header.kpi setNameText:(sumN > 0
            ? [NSString stringWithFormat:@"最忙一小时 · 均 %.1f",
               (CGFloat)sumN / 24.0]
            : @"最忙一小时") atIndex:3];
    } else {
        [self.header.kpi setValueText:(days > 0 ? [NSString stringWithFormat:@"%ld", (long)days] : @"—")
                              atIndex:2];
        [self.header.kpi setNameText:@"覆盖天数" atIndex:2];
        [self.header.kpi setValueText:[self dailyAverageText:total days:days] atIndex:3];
        [self.header.kpi setNameText:@"日均条数" atIndex:3];
    }

    // ---------- 图表 + 分组标题 ----------
    if (dim == 0) {
        // v0.0.184：按 App 也有图了 —— 来源占比环形图。
        // 🔴 只有"这个时间窗一条都没有"时才藏卡片：那时环形图无内容可画，
        //    留一张空白卡比不显示更让人以为坏了。
        // ⚠️ 别再写成无条件的 `setChartHidden:YES` —— v0.0.182 那个
        //    "图表卡盖住排行前 3 名"就是因为隐藏与显隐状态不同步。
        [self setChartHidden:(total <= 0)];
        self.header.chartTitle.text = @"来源占比";
        [self feedPieChart];
        self.header.sectionLabel.text = (total > 0)
            ? [NSString stringWithFormat:@"来源排行 · 前 %ld 个 App", (long)MIN((NSInteger)self.rows.count, kNBStatsTopN)]
            : @"这个时间窗里没有记录";
    } else if (dim == 1) {
        [self setChartHidden:NO];
        self.header.chartTitle.text = @"24 小时分布";
        [self feedHourChart];
        self.header.sectionLabel.text = (total > 0) ? @"各时段明细" : @"这个时间窗里没有记录";
    } else {
        [self setChartHidden:NO];
        self.header.chartTitle.text = @"按天趋势";
        [self feedDayChart];
        self.header.sectionLabel.text = (total > 0)
            ? [NSString stringWithFormat:@"每天明细 · %ld 天", (long)self.rows.count]
            : @"这个时间窗里没有记录";
    }

    [self syncHeaderSize];
    [self.table reloadData];

    // v0.0.178 起统一的触觉层：切维度/时间窗不该"点了没反应"
    // （本页只有滚动，没有开关，所以只给这一下轻反馈）
    if (total <= 0) {
        [self.header.kpi setValueText:@"0" atIndex:0];
        [self.header.kpi setValueText:@"0" atIndex:1];
    } else {
        [self nbRollTotal:total unread:unread];
    }
}

// 日均：分母用**窗口天数**（不是"有记录的天数"）。
// 🔴 两个分母给出的数是两种意思：「这 30 天平均每天 38 条」vs「忙的那 18 天平均 60 条」。
//    用户问"我一天被烦多少次"时想的是前者，所以固定用窗口天数，并在标签里写明。
- (NSString *)dailyAverageText:(NSInteger)total days:(NSInteger)days {
    if (days <= 0 || total <= 0) return @"—";
    return [NSString stringWithFormat:@"%.1f", (CGFloat)total / (CGFloat)days];
}

- (NSInteger)windowDaysWithEarliest:(NSDate *)earliest latest:(NSDate *)latest {
    NSInteger i = self.rangeSeg.selectedSegmentIndex;
    if (i == 1) return 7;
    if (i == 2) return 30;
    if (i == 3) {
        if (self.customSince <= 0 || self.customBeforeTs <= 0) return 0;
        NSInteger d = (NSInteger)((self.customBeforeTs - self.customSince) / 86400.0 + 0.5);
        return d > 0 ? d : 1;
    }
    // 「全部」：用库里实际的跨度（最早一条 → 最晚一条），至少算 1 天
    if (!earliest) return 0;
    NSTimeInterval end = latest ? [latest timeIntervalSince1970]
                                : [[NSDate date] timeIntervalSince1970];
    NSInteger d = (NSInteger)((end - [earliest timeIntervalSince1970]) / 86400.0) + 1;
    return d > 0 ? d : 1;
}

- (void)setChartHidden:(BOOL)hidden {
    // 真正干活的是 `showsChart` 的 setter（它负责 hidden + frame 归零 + 重排）。
    // ⛔ 这里不要自己碰 chartCard —— 否则又多一个生产者。
    self.header.showsChart = !hidden;
}

// 24 小时：轴标只打 0 / 6 / 12 / 18 / 23 五处（每根都打会糊成一片）
// v0.0.184：来源占比环形图（按 App 维度）。
//
// 🔴 「其他」那一片的颜色用 `tertiaryLabelColor`，**不**参与品牌色轮转：
//    它代表"剩下的 60 个 App 加起来"，给它一个像样的品牌色会让用户以为
//    它是一个具体的 App。
- (void)feedPieChart {
    NSMutableArray<NSDictionary *> *slices = [NSMutableArray array];
    NSInteger otherSum = 0, shownSum = 0, maxN = 0;
    NSString *maxName = nil;
    NSInteger shownCount = 0;

    for (NSInteger i = 0; i < (NSInteger)self.rows.count; i++) {
        NSDictionary *d = self.rows[i];
        NSInteger n = [d[@"total"] integerValue];
        if (n <= 0) continue;
        if (i < kNBStatsPieTopN) {
            NSString *bid = d[@"bundle"];
            if (![bid isKindOfClass:[NSString class]]) bid = @"";
            NSString *nm = self.names[bid];
            if (![nm isKindOfClass:[NSString class]] || !nm.length) {
                nm = bid.length ? bid : @"未知";
            }
            UIColor *c = self.brands[bid];
            if (![c isKindOfClass:[UIColor class]]) c = [UIColor systemBlueColor];
            [slices addObject:@{ @"value": @(n), @"color": c, @"name": nm }];
            shownSum += n;
            shownCount++;
            if (n > maxN) { maxN = n; maxName = nm; }
        } else {
            otherSum += n;
        }
    }
    if (otherSum > 0) {
        [slices addObject:@{ @"value": @(otherSum),
                             @"color": [UIColor tertiaryLabelColor],
                             @"name": @"其他" }];
    }

    // 喂数据时 `setSlices:` 会把 kind 定成环形并清掉柱状数据（互斥在图表类里管）
    self.header.chart.slices = slices;

    // 🔴 播报文案**只有一个赋值点**（先算进 sum，最后统一赋）。
    //    写成两个分支各赋一次的话，"不设 summary"这个坏状态需要同时删两处才能测出来
    //    ⇒ 变异变得只能测"删掉其中一处"，实际坏的是"一处都不剩"。
    NSInteger tot = shownSum + otherSum;
    NSString *sum;
    if (tot <= 0) {
        sum = @"来源占比环形图，这个时间窗里没有记录";
    } else {
        sum = [NSString stringWithFormat:
               @"来源占比环形图，画了前 %ld 个 App，最多是 %@ 占 %.0f%%",
               (long)shownCount, maxName ?: @"—",
               (CGFloat)maxN * 100.0 / (CGFloat)tot];
    }
    self.header.chart.summary = sum;
}

- (void)feedHourChart {
    NSMutableArray<NSNumber *> *vals = [NSMutableArray array];
    NSMutableArray<NSString *> *axis = [NSMutableArray array];
    NSInteger peakHour = 0, peakN = 0;
    for (NSDictionary *d in self.rows) {
        NSInteger h = [d[@"hour"] integerValue];
        NSInteger n = [d[@"total"] integerValue];
        [vals addObject:@(n)];
        BOOL mark = (h == 0 || h == 6 || h == 12 || h == 18 || h == 23);
        [axis addObject:(mark ? [NSString stringWithFormat:@"%ld", (long)h] : @"")];
        if (n > peakN) { peakN = n; peakHour = h; }
    }
    self.header.chart.barColor = [UIColor systemBlueColor];
    [self.header.chart setValues:vals axis:axis];
    self.header.chart.summary = (peakN > 0)
        ? [NSString stringWithFormat:@"24 小时分布柱状图，共 %ld 个时段，最高是 %ld 点 %ld 条",
           (long)vals.count, (long)peakHour, (long)peakN]
        : @"24 小时分布柱状图，这个时间窗里没有记录";
}

// 按天：轴标取首 / 中 / 尾三处，显示成 MM-dd（带年份太长，卡片里挤不下）
- (void)feedDayChart {
    NSMutableArray<NSNumber *> *vals = [NSMutableArray array];
    NSMutableArray<NSString *> *axis = [NSMutableArray array];
    NSInteger n = (NSInteger)self.rows.count;
    NSInteger peakIdx = -1, peakN = 0;
    for (NSInteger i = 0; i < n; i++) {
        NSDictionary *d = self.rows[i];
        NSInteger c = [d[@"total"] integerValue];
        [vals addObject:@(c)];
        if (c > peakN) { peakN = c; peakIdx = i; }
    }
    for (NSInteger i = 0; i < n; i++) {
        BOOL mark = (n <= 3) || (i == 0) || (i == n / 2) || (i == n - 1);
        NSString *day = self.rows[i][@"day"];
        // 「2026-11-11」→「11-11」：只截后 5 位，不重新解析（原串就来自 SQL 的 localtime）
        NSString *shortDay = (day.length >= 5) ? [day substringFromIndex:day.length - 5] : day;
        [axis addObject:(mark ? (shortDay ?: @"") : @"")];
    }
    self.header.chart.barColor = [UIColor systemBlueColor];
    [self.header.chart setValues:vals axis:axis];
    self.header.chart.summary = (peakN > 0 && peakIdx >= 0)
        ? [NSString stringWithFormat:@"按天趋势柱状图，共 %ld 天，最高是 %@ 共 %ld 条",
           (long)n, self.rows[peakIdx][@"day"] ?: @"", (long)peakN]
        : @"按天趋势柱状图，这个时间窗里没有记录";
}

// ================= KPI 数字滚动 =================
// 🔴 只滚**两个计数**（总条数 / 未读）。⛔ 不滚「高峰时段」这类数：
//    从 0 滚到 18 会经过 7 点、12 点这些**不存在的高峰**，
//    和"滚日期"同属"中间态是假的"，本项目的判据口径不接受。
// 🔴 起新的一轮前**必须先掐掉上一轮**：切时间段会连续刷新，
//    不掐就会有两个定时器同时往同一个 label 上写，数字抖成随机数。
- (void)nbRollTotal:(NSInteger)total unread:(NSInteger)unread {
    // 🔴🔴 v0.0.181：**数值没变就不重滚**。
    //    切维度 / 切时间窗会连着走 reloadData，每次都从 0 滚到 1284
    //    意味着用户每点一下页签，两个数字就闪一遍 —— 而"总数没变"恰恰是
    //    用户想确认的事，闪一下反而让人以为变了。信息量为零的动效就是噪声。
    if (total == self.lastRollTotal && unread == self.lastRollUnread
        && self.header.kpi.valueLabels.firstObject.text.length > 0) {
        return;
    }
    self.lastRollTotal = total;
    self.lastRollUnread = unread;

    [self.nbRollTimer invalidate];
    self.nbRollTimer = nil;

    // 🔴🔴 这里**不能用 `self.view.window` 当闸门**（v0.0.176 第一版就是那么写的，会永久关掉动效）。
    //    唯一的调用路径是 `viewWillAppear:` → `reloadData` → 这里，而那一刻视图
    //    **还没上屏**，`view.window` 必然是 nil ⇒ 每次都走"直接给终值"那条路，
    //    屏幕上永远不会有滚动。而它和"本来就该这样"完全同形，谁也发现不了。
    if (!self.isViewLoaded) {
        [self.header.kpi setValueText:[NSString stringWithFormat:@"%ld", (long)total] atIndex:0];
        [self.header.kpi setValueText:[NSString stringWithFormat:@"%ld", (long)unread] atIndex:1];
        return;
    }

    NSDate *t0 = [NSDate date];
    const NSTimeInterval dur = 0.30;   // 轻快档：和列表那几处 0.22~0.24 是同一手感
    __weak typeof(self) weakSelf = self;

    self.nbRollTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 60.0)
                                                       repeats:YES
                                                         block:^(NSTimer *timer) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) { [timer invalidate]; return; }

        CGFloat k = (CGFloat)(-[t0 timeIntervalSinceNow] / dur);
        if (k >= 1.0) {
            k = 1.0;
            [timer invalidate];
            self2.nbRollTimer = nil;      // 完成即释放，不留一个"已经停了的"定时器
        }
        // ease-out：前段快、收尾慢，和 `UIViewAnimationOptionCurveEaseOut` 观感一致
        CGFloat inv = 1.0 - k;
        CGFloat e = 1.0 - inv * inv * inv;

        // `+0.5` 取整而不用 `lround`：少引一个 math.h，而且这两个数恒非负。
        // ⛔ 别改成 `(long)x` —— 那是截断，计数会全程偏小，最后一下才跳到位。
        [self2.header.kpi setValueText:[NSString stringWithFormat:@"%ld",
                                        (long)((double)total * e + 0.5)] atIndex:0];
        [self2.header.kpi setValueText:[NSString stringWithFormat:@"%ld",
                                        (long)((double)unread * e + 0.5)] atIndex:1];
    }];
}

- (NSString *)nameForRow:(NSDictionary *)d {
    NSInteger dim = self.dimSeg.selectedSegmentIndex;
    if (dim == 0) {
        NSString *bid = d[@"bundle"] ?: @"";
        NSString *n = self.names[bid];
        if (n.length) return n;
        return [[bid componentsSeparatedByString:@"."] lastObject] ?: bid;
    }
    if (dim == 1) {
        NSInteger h = [d[@"hour"] integerValue];
        // 显示成时间段而不是裸数字：「14」看不出是 14 点还是 14 条
        return [NSString stringWithFormat:@"%02ld:00 – %02ld:00",
                (long)h, (long)((h + 1) % 24)];
    }
    NSString *day = d[@"day"] ?: @"";
    // 按天维度补上星期几：看趋势时"周末为什么少"是最常问的问题
    if (day.length >= 10) {
        // 🔴🔴 `locale` 必须显式设 en_US_POSIX：`NSDateFormatter` 的默认 locale 跟着
        //    用户系统走，系统日历是佛历 / 和历时，`dateFromString:@"2026-11-11"`
        //    会解析成别的年份甚至 nil ⇒ 星期几算错或整行退回裸日期。
        //    而 SQL 侧 `strftime('%Y-%m-%d')` 输出的**永远是公历**，两边必须对齐。
        // 🔴 formatter 提到 static：按天维度最多 92 行，每行建一个 formatter
        //    是 92 次 locale/calendar 初始化，滚动时会明显掉帧。
        static NSDateFormatter *in = nil;
        static NSArray *wk = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            in = [[NSDateFormatter alloc] init];
            in.dateFormat = @"yyyy-MM-dd";
            in.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            in.timeZone = [NSTimeZone localTimeZone];
            wk = @[@"周日", @"周一", @"周二", @"周三", @"周四", @"周五", @"周六"];
        });
        NSDate *dt = [in dateFromString:day];
        if (dt) {
            NSInteger wd = [[NSCalendar currentCalendar] component:NSCalendarUnitWeekday fromDate:dt] - 1;
            if (wd >= 0 && wd < 7) return [NSString stringWithFormat:@"%@ %@", day, wk[wd]];
        }
    }
    return day;
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec {
    return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NBStatCell *c = [tv dequeueReusableCellWithIdentifier:@"stat" forIndexPath:ip];
    NSDictionary *d = self.rows[ip.row];
    NSInteger n = [d[@"total"] integerValue];
    NSInteger dim = self.dimSeg.selectedSegmentIndex;

    NSString *name = [self nameForRow:d];
    c.nameLabel.text = name;

    // 排名只在「按 App」维度有意义（那是排行榜）；按小时/按天是时间序列，序号没用
    if (dim == 0 && ip.row < 99) {
        c.rankLabel.text = [NSString stringWithFormat:@"%ld", (long)(ip.row + 1)];
    } else {
        c.rankLabel.text = nil;
    }

    // 占比的分母是**本时间窗的总条数**（不是本屏最大值）。
    // 🔴 两个分母差别很大：max 是"第一名多少条"，占比要的是"占全部的多少"。
    //    拿 max 当分母会让第一名永远显示 100%，那是彻底的错。
    CGFloat share = (self.grandTotal > 0)
        ? ((CGFloat)n * 100.0 / (CGFloat)self.grandTotal) : 0;
    NSInteger un = [d[@"unread"] integerValue];
    if (dim == 0) {
        c.cntLabel.text = [NSString stringWithFormat:@"%ld 条 · %.1f%%", (long)n, share];
        c.subLabel.text = (un > 0)
            ? [NSString stringWithFormat:@"未读 %ld · 该 App 未读率 %.0f%%",
               (long)un, (CGFloat)un * 100.0 / (CGFloat)MAX((NSInteger)1, n)]
            : nil;
    } else {
        c.cntLabel.text = [NSString stringWithFormat:@"%ld 条 · %.1f%%", (long)n, share];
        c.subLabel.text = (un > 0) ? [NSString stringWithFormat:@"未读 %ld", (long)un] : nil;
    }

    // 条形长度按**本屏最大值**归一：这样第一名总是满格，视觉上能看出相对差距。
    // 🔴 条长和占比用的是两个不同的分母 —— 这是刻意的，不是 bug：
    //    条长回答"谁最多"，百分比回答"占全部多少"。两个数各有各的用处。
    // 🔴 只给比例，像素宽由 cell 的 layoutSubviews 乘（见 `ratio` 的注释）。
    c.ratio = (self.max > 0) ? ((CGFloat)n / (CGFloat)self.max) : 0;
    // 🔴 0 条的行也要看得见"这是一格空的"，所以底槽保留、只让填充宽度为 0
    c.barFill.hidden = (n <= 0);
    UIColor *brand = (dim == 0) ? self.brands[d[@"bundle"] ?: @""] : nil;
    c.barFill.backgroundColor = brand ?: [UIColor systemBlueColor];

    // ---------- a11y ----------
    // v0.0.180 的教训：设了显式 label 之后子视图不再被聚合，
    // 所以要念的东西必须**自己拼全**，别指望系统去聚合那几个 label。
    NSMutableArray *parts = [NSMutableArray array];
    if (name.length) [parts addObject:name];
    if (dim == 0 && ip.row < 99) [parts addObject:[NSString stringWithFormat:@"第 %ld 名", (long)(ip.row + 1)]];
    [parts addObject:[NSString stringWithFormat:@"%ld 条", (long)n]];
    [parts addObject:[NSString stringWithFormat:@"占 %.1f%%", share]];
    if (un > 0) [parts addObject:[NSString stringWithFormat:@"未读 %ld 条", (long)un]];
    c.accessibilityLabel = [parts componentsJoinedByString:@"，"];

    // ---------- v0.0.186：只有「按 App」的行能点进记录页 ----------
    // 🔴 按小时 / 按天的行**钻不了**：记录页只有 24小时 / 7天 / 不限 三档，
    //    表达不了"14:00–15:00"或者"11-09 这一天"这种范围。
    //    ⇒ 那些行显式关掉选中态，⛔ 不留一个"点了没反应"的默认高亮 ——
    //    有高亮等于暗示能点，这比不能点更让人迷惑。
    c.selectionStyle = (dim == 0) ? UITableViewCellSelectionStyleDefault
                                  : UITableViewCellSelectionStyleNone;

    // 🔴 能点的行必须**说出来**：VoiceOver 下双击是唯一入口，而这一行原本只是
    //    一句静态文案（App 名 / 条数 / 占比）。hint 只解释"双击会发生什么"，
    //    ⛔ 不碰 `accessibilityTraits` —— 列表那边 v0.0.180 就是因为覆盖 traits
    //    把双击进详情弄坏过，而那种坏法极难归因。
    c.accessibilityHint = (dim == 0 && self.drilldownHandler)
                        ? @"双击查看这个 App 的记录" : nil;

    // 🔴 必须显式要求重排：`rankLabel.text` 从有值变成 nil 时，
    //    "名字起点要不要左移 20pt"只有 layoutSubviews 知道，
    //    而改 text 本身**不会**触发重排 —— 复用的行会带着上一行的缩进。
    [c setNeedsLayout];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    // ================= v0.0.186：按 App 的行 ⇒ 钻进记录页 =================
    // 🔴 为什么现在才做：v0.0.183 把统计提成第二个页签之后，这一页成了**孤岛** ——
    //    排行榜把每个 App 的条数摆得清清楚楚，点上去却什么也不发生。
    //    用户看到"微信 18 条"最自然的下一步就是"让我看看那 18 条"。
    if (self.dimSeg.selectedSegmentIndex != 0) return;      // 另两个维度钻不了（见 cellForRow）
    if (ip.row < 0 || ip.row >= (NSInteger)self.rows.count) return;
    NSDictionary *d = self.rows[ip.row];
    if (![d isKindOfClass:[NSDictionary class]]) return;
    id bv = d[@"bundle"];
    NSString *bid = [bv isKindOfClass:[NSString class]] ? (NSString *)bv : nil;
    if (!bid.length) return;
    // 没有接手的容器（这一页被单独 push 出来）⇒ 保持原来的"点一下只收起"
    if (!self.drilldownHandler) return;

    // 🔴 时间窗映射表（两端枚举：本页 `rangeSeg` 0~3 / 记录页 `timeSeg` 0~2）：
    //      统计「全部」  → 记录「不限时间」   days = 0
    //      统计「7 天」  → 记录「近7天」      days = 7
    //      统计「30 天」 → **记录页没有这一档** ⇒ days = -1（别动时间窗）
    //      统计「自定义」→ 记录页表达不了      ⇒ days = -1
    //    ⛔ 绝不用"最接近的 7 天"去凑 30 天：那会变成"统计说 42 条、点进去只有 8 条"，
    //      两个指标打架比"不能点"更糟（本项目最贵的一类事故）。
    NSInteger days = -1;
    switch (self.rangeSeg.selectedSegmentIndex) {
        case 0:  days = 0;  break;
        case 1:  days = 7;  break;
        default: days = -1; break;
    }
    // 触觉不在这里给：真正"生效"的是页签切过去了，那一下由容器统一震（见 NBHomeTabBarController）。
    self.drilldownHandler(bid, days);
}

@end
