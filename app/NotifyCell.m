#import "NotifyCell.h"
#import "NBTheme.h"

@interface NotifyCell ()
// 🔴 v0.0.70：卡片容器。以前所有子视图直接挂在 `contentView` 上、靠系统分隔线区分行，
//    整屏是一块连续的灰白。现在改成「灰色大底 + 一张张圆角卡片」：
//    · 卡片之间靠**留白**分行，不再需要分隔线（`separatorStyle = None`）
//    · 卡片比 cell 窄 12pt/侧 ⇒ 视觉上有"内缩"，更像现代列表
//    · 所有内部布局都改成**相对卡片**算，这样横竖屏/分屏宽度变了也不用改常量
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIView *iconBox;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *letterLabel;
// v0.0.42：App 名（标题上方一行小字）
@property (nonatomic, strong) UILabel *appLabel;
@property (nonatomic, strong) UILabel *titleLabel2;
// v0.0.45：subtitle **单独成行**（以前只能在"正文为空"时顶替正文，见 setTitleText:）
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UILabel *msgLabel;
@property (nonatomic, strong) UILabel *timeLabel;
// v0.0.72：未读标记改成**卡片右上角的书签**（带未读数），v0.0.35 的左侧蓝点已删除。
// 🔴 为什么用 CAShapeLayer 画、不用圆角矩形：书签的样子是**底下有个 V 形缺口**，
//    圆角矩形做不出来（它只能是"标签"，不是"书签"）。缺口只能靠路径画。
// 🔴 为什么底色层和数字分开两层：缺口只该裁到**底色**上，
//    如果把 shape 当 pinView 的 mask，里面的数字 label 也会被一起裁——
//    虽然这次数字恰好在缺口上方、看不出来，但那种"碰巧没露馅"的写法迟早翻车。
@property (nonatomic, strong) UIView *pinView;        // 书签容器（右上角）
@property (nonatomic, strong) CAShapeLayer *pinShape; // 书签底色（带 V 缺口）
@property (nonatomic, strong) UILabel *pinLabel;      // 未读数
// 🔴 未读/条数都存**原始量**，不拿 pinView.hidden 反推 —— 布局要按数字位数算宽度，
//    "看视图状态反推数据状态"在本项目已经栽过（attributedText 时序、标星）。
@property (nonatomic, assign) BOOL isUnread;
@property (nonatomic, assign) NSInteger unreadCount;
// v0.0.48：关键词规则标星（v0.0.72 起在**右下角** ★）。**展示时派生、不落库**。
@property (nonatomic, strong) UILabel *starLabel;
// 🔴 布局判据用这个原始 BOOL，**不拿 starLabel.hidden 反推**：
//    "拿视图状态反推数据状态"本项目栽过（attributedText 时序），星也必须存一份原始量。
@property (nonatomic, assign) BOOL starred;
// v0.0.44：高亮要"先存原始串、最后统一渲染" —— 两个 setter 的调用顺序不固定，
// 谁先到都只是记下来，真正写字在 `nbRender` 里一次做完。
@property (nonatomic, copy) NSString *rawAppName;
@property (nonatomic, copy) NSString *rawTitle;
@property (nonatomic, copy) NSString *rawSubtitle;   // v0.0.45
@property (nonatomic, copy) NSString *rawBody;
@property (nonatomic, strong) UIColor *rawBodyColor;
@property (nonatomic, copy) NSString *hlQuery;
// 🔴 内部方法必须显式声明：项目开 -Werror，靠"定义在前面"来解析选择器太脆
//    （本项目栽过三次：kAutoChainTrigger / uiscrollerInternalVelocity / forceLayoutVisibleCells）。
- (void)nbRender;
// v0.0.72：未读书签的唯一入口（数字 + 显隐）。和 nbRender 分开：
// 书签不参与高亮，混进 nbRender 会让"只翻了一次未读"也重算一遍正文富文本。
- (void)nbUpdatePin;
@end

// v0.0.44：把 `query` 在 `text` 里出现的每一处都标出来。
// 🔴 匹配用 `NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch`，
//    和 `ViewController -bundlesMatchingSearch:` 的口径一致 ——
//    否则会出现"App 名那一栏明明命中了，字却没标"这种对不上的情况。
// 🔴 高亮只改**背景色 + 字色**，不动字体：换字号会让那一行基线跳动，
//    滚动时一片一片地抖，比不高亮更难受。
static NSAttributedString *NBHighlight(NSString *text, NSString *query, UIColor *baseColor) {
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:text ?: @""];
    if (!text.length) return s;
    NSDictionary *base = @{ NSForegroundColorAttributeName: baseColor ?: [UIColor labelColor] };
    [s setAttributes:base range:NSMakeRange(0, text.length)];
    if (!query.length) return s;

    NSDictionary *hit = @{
        NSForegroundColorAttributeName: [UIColor labelColor],
        NSBackgroundColorAttributeName: [[UIColor systemYellowColor] colorWithAlphaComponent:0.40],
    };
    NSString *hay = text, *needle = query;
    NSRange search = NSMakeRange(0, hay.length);
    NSUInteger guard = 0;
    while (search.length > 0 && guard++ < 64) {
        NSRange r = [hay rangeOfString:needle
                              options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch
                                range:search];
        if (r.location == NSNotFound) break;
        [s addAttributes:hit range:r];
        NSUInteger next = NSMaxRange(r);
        if (next >= hay.length) break;
        search = NSMakeRange(next, hay.length - next);
        // 🔴 空匹配会死循环（`needle` 为空时 `rangeOfString:` 返回 {0,0}）。
        //    上面已经挡了 `query.length`，这里再挡一次"找到的位置没前进"。
        if (r.length == 0) break;
    }
    return s;
}

@implementation NotifyCell

// v0.0.42：82 → 98。多出来的 16pt 给「App 名」那一行。
// 🔴 为什么宁可加高也不把 App 名塞进标题或正文：
//    ① 塞进标题（如「微信 · 你好」）会让标题能显示的字变少，而标题是用户扫列表时最先看的；
//    ② 塞进正文前面会被当成正文的一部分，而且正文本来只有两行、已经不够用。
//    ③ iOS 自己的通知就是这样排的：App 名一行小字在最上面。用户不需要学。
// 🔴 行高是 **常量**（`tableView.rowHeight` 直接用它），所以某个 App 名字取不到时
//    也不能让那一行变矮 —— 否则整屏行高参差不齐，比空一行难看得多。
// 🔴🔴 v0.0.70：98 → 106。加的 8pt **不是给内容的**，是给卡片上下的留白（各 4pt）。
//    卡片内部可用高度仍是 98 ⇒ 下面 layoutSubviews 里所有 y 坐标**一个都不用改**
//    （只是整体平移卡片原点）。改行高时必须同步这里的 8，否则卡片会被压扁或架空。
// 🔴🔴 v0.0.72：卡片内部 98 → 112（行高 106 → 120）。
//    **为什么非加不可**：用户要求「时间放到内容下面」。原来是"时间跟标题同一水平线、
//    右对齐"，它不占竖向空间；挪到内容下方就**凭空多出一行 15pt + 间距**。
//    🔴 那能不能不加高、靠压正文腾地方？不能。有副标题时正文只剩 34pt，
//       而两行 13pt 正文本身就要 ≈31pt —— 再压就是把两行正文截成一行半，
//       用户会看到"正文显示不全"，比多占 14pt 难受得多。
//    🔴 代价讲清楚：行高是常量、被 `tableView.rowHeight` 直接用 ⇒
//       每屏少看约 1 条（≈700pt 可视区：106 时 6.6 条 → 120 时 5.8 条）。
//       这个代价换的是"时间、未读、正文三者不再互相挤"，值得。
static const CGFloat kNBCardInsetX = 12.0;   // 卡片左右内缩
static const CGFloat kNBCardInsetY = 4.0;    // 卡片上下留白（行距）
// 卡片内部可用高度（行高 = 它 + 上下留白）。layoutSubviews 里 h 就是这个数。
static const CGFloat kNBCardInteriorH = 112.0;
+ (CGFloat)height { return kNBCardInteriorH + kNBCardInsetY * 2; }

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    // v0.0.70 卡片化（见类扩展里 cardView 的注释）
    // 🔴 cell 自身必须透明：卡片背后的"灰色大底"要由 tableView.backgroundColor 透出来，
    //    否则每张卡片周围还是白底，等于只加了圆角、没做出分层。
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    // 🔴 关掉系统选中态：它会盖一层灰在整个 cell 上（含卡片外的留白），
    //    看起来像"整行被框住了"。选中反馈改在 setHighlighted: 里只染卡片自己。
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.cardView = [[UIView alloc] init];
    self.cardView.backgroundColor = NBCardBG();
    self.cardView.layer.cornerRadius = NBCardRadius;
    self.cardView.layer.cornerCurve = kCACornerCurveContinuous;   // 和系统卡片同一个曲率
    self.cardView.clipsToBounds = YES;
    [self.contentView addSubview:self.cardView];

    // 图标容器：真图标和首字母共用一块底
    self.iconBox = [[UIView alloc] init];
    self.iconBox.backgroundColor = [UIColor secondarySystemFillColor];
    self.iconBox.layer.cornerRadius = 9;
    self.iconBox.clipsToBounds = YES;
    [self.cardView addSubview:self.iconBox];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.iconBox addSubview:self.iconView];

    self.letterLabel = [[UILabel alloc] init];
    self.letterLabel.textAlignment = NSTextAlignmentCenter;
    self.letterLabel.font = [UIFont boldSystemFontOfSize:18];
    self.letterLabel.textColor = [UIColor secondaryLabelColor];
    [self.iconBox addSubview:self.letterLabel];

    // v0.0.42：App 名。
    // 🔴 字号 11 / secondaryLabel —— 和 `timeLabel` 同一规格。它是"上下文"，不是内容：
    //    比标题抢眼就等于把最该看的东西挤下去了。
    self.appLabel = [[UILabel alloc] init];
    self.appLabel.font = [UIFont systemFontOfSize:11];
    self.appLabel.textColor = [UIColor secondaryLabelColor];
    self.appLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.cardView addSubview:self.appLabel];

    self.titleLabel2 = [[UILabel alloc] init];
    self.titleLabel2.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.titleLabel2.textColor = [UIColor labelColor];
    self.titleLabel2.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.cardView addSubview:self.titleLabel2];

    self.timeLabel = [[UILabel alloc] init];
    self.timeLabel.font = [UIFont systemFontOfSize:11];
    self.timeLabel.textColor = [UIColor tertiaryLabelColor];
    // v0.0.72：右对齐 → 左对齐。它从"标题右侧"挪到了"内容正下方"，
    // 位置从"行尾"变成"行首"，对齐方式必须跟着改 ——
    // 否则右对齐会让时间贴着卡片右缘，和上一行正文的左缘彻底脱开，看着像另一条记录的时间。
    self.timeLabel.textAlignment = NSTextAlignmentLeft;
    [self.cardView addSubview:self.timeLabel];

    // v0.0.45：subtitle 单独一行。
    // 🔴 为什么以前根本看不到它：旧逻辑是"**正文为空**才拿 subtitle 顶替正文"，
    //    而正文为空是少数情况 ⇒ 绝大多数记录的 subtitle **一个字都显示不出来**，
    //    用户明明有这条数据、搜也搜得到（v0.0.42 已把 subtitle 加进 LIKE），
    //    界面上却看不见 —— 属于"数据层有、视图层没有"。
    //    iOS 自己的通知就是「标题 / 副标题 / 正文」三行，跟着系统排用户不用学。
    // 🔴🔴 行高**不变**（仍是 98）：subtitle 抢的是正文的竖向空间
    //    （正文两行 40pt → 副标题 16pt + 正文 34pt），
    //    没有副标题时布局**完全回到原样** ⇒ 不会为了偶尔才有的一行把整屏都撑高
    //    （行高是常量、被 `tableView.rowHeight` 直接用，撑高的代价是每一屏都少看两条）。
    self.subLabel = [[UILabel alloc] init];
    self.subLabel.font = [UIFont systemFontOfSize:13];
    // 比正文稍浅：它是"标题的补充"，不是内容本体，不能和正文抢注意力
    self.subLabel.textColor = [UIColor secondaryLabelColor];
    self.subLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.subLabel.hidden = YES;                      // 默认藏：没给值时宁可少一行
    [self.cardView addSubview:self.subLabel];

    self.msgLabel = [[UILabel alloc] init];
    self.msgLabel.font = [UIFont systemFontOfSize:13];
    self.msgLabel.textColor = [UIColor secondaryLabelColor];
    self.msgLabel.numberOfLines = 2;                 // 正文最多两行，超了截断
    self.msgLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.cardView addSubview:self.msgLabel];

    // v0.0.48：右下角 ★（关键词"标星"动作）。默认藏 —— 和未读书签一样，
    // 万一某处忘了调 setStarred:，宁可少一颗星，也不要给所有行都点上。
    // 🔴 systemOrange：金/橙在浅色底上醒目，又不是"行情红绿"那种会误读成涨跌的颜色。
    self.starLabel = [[UILabel alloc] init];
    self.starLabel.text = @"★";
    self.starLabel.font = [UIFont systemFontOfSize:13];
    self.starLabel.textColor = [UIColor systemOrangeColor];
    self.starLabel.textAlignment = NSTextAlignmentRight;
    self.starLabel.hidden = YES;
    [self.cardView addSubview:self.starLabel];

    // v0.0.72：右上角**未读书签**（替代 v0.0.35 的左侧蓝点）。
    // 默认 hidden —— 万一某处忘了调 setUnread:count:，宁可少一个书签，
    // 也不要给所有行都挂上（复用池里最容易串的就是这种"默认可见的装饰"）。
    self.pinView = [[UIView alloc] init];
    self.pinView.backgroundColor = [UIColor clearColor];   // 底色由 pinShape 画（要带缺口）
    self.pinView.hidden = YES;
    self.pinShape = [CAShapeLayer layer];
    self.pinShape.fillColor = [UIColor systemBlueColor].CGColor;
    [self.pinView.layer addSublayer:self.pinShape];
    self.pinLabel = [[UILabel alloc] init];
    self.pinLabel.font = [UIFont boldSystemFontOfSize:11];
    self.pinLabel.textColor = [UIColor whiteColor];
    self.pinLabel.textAlignment = NSTextAlignmentCenter;
    [self.pinView addSubview:self.pinLabel];
    // 🔴 最后 add：书签要压在卡片内所有内容的上面（含 ★）。
    //    视图层级顺序 = z 序，这一条在本项目已经栽过（topCard 必须第一个 add）。
    [self.cardView addSubview:self.pinView];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // v0.0.70：先摆卡片，再把**所有**内部坐标改成相对卡片。
    // v0.0.72：卡片内部高 98 → 112（多了「时间」那一行，见 +height 的注释）。
    CGRect card = CGRectInset(self.contentView.bounds, kNBCardInsetX, kNBCardInsetY);
    self.cardView.frame = card;
    CGFloat w = card.size.width;
    CGFloat h = card.size.height;
    CGFloat ox = card.origin.x;      // 卡片原点：后面每个 frame 都要带上
    CGFloat oy = card.origin.y;
    CGFloat pad = 14;
    CGFloat side = 46;

    // v0.0.72：**左缘对齐**。v0.0.35~71 这里是 `dotX(10) + dotD(8) + 2 = 20`，
    // 那 20pt 是给蓝点让位留出来的 ⇒ 图标左缘比卡片的 14pt 内边距多缩进了 6pt，
    // 而标题/正文又从 78 起 —— 三个左缘互不相等，一屏十几张卡片叠起来边缘就"毛"了。
    // 蓝点删掉后图标直接回到 `pad`，图标/标题/正文/时间四者的左缘关系变成
    // 「图标 14，文字一律 72」，左侧一整列彻底齐。
    CGFloat iconX = pad;
    self.iconBox.frame = CGRectMake(ox + iconX, oy + (h - side) / 2, side, side);
    self.iconView.frame = self.iconBox.bounds;
    self.letterLabel.frame = self.iconBox.bounds;

    CGFloat textX = iconX + side + 12;
    CGFloat textW = w - textX - pad;

    // v0.0.72 竖向排版（卡片内部 112）：
    //   App 名   y=8~22
    //   标题     y=23~42   ← 时间挪走后**独占整行宽**（以前要让出 78pt 给时间）
    //   副标题   y=43~58   （有才占位）
    //   正文     y=59 或 43，两行 13pt（≈31pt）
    //   时间     y=h-21~h-6（**贴底**，左对齐）｜ ★ 同一行右端
    // 🔴 时间用「贴底」而不是「接在正文后面」：接在正文后面的话，
    //    没有副标题的行和有的行会差 16pt ⇒ 同一屏里的时间**上下错位**，
    //    滚动时看着像在跳。贴底让所有行的时间落在同一条水平线上。
    CGFloat timeH = 15;
    CGFloat timeY = h - 6 - timeH;
    self.appLabel.frame    = CGRectMake(ox + textX, oy + 8, textW, 14);
    self.titleLabel2.frame = CGRectMake(ox + textX, oy + 23, textW, 19);
    // v0.0.45：有副标题时正文下移一行；没有就完全回到原来的位置。
    // 🔴 判据用 `rawSubtitle`（原始串），**不用** `subLabel.text` ——
    //    `attributedText` 赋值之后 `.text` 的取值时机不保证早于本方法，
    //    拿视图状态反推数据状态这种事在本项目已经栽过（观测者把被观测量改了）。
    BOOL hasSub = (self.rawSubtitle.length > 0);
    self.subLabel.hidden    = !hasSub;
    self.subLabel.frame     = CGRectMake(ox + textX, oy + 43, textW, 15);
    CGFloat msgY = hasSub ? 59 : 43;
    // 🔴 正文高度取「到底部时间之间还剩多少」，再兜一个 31pt 下限：
    //    宁可和上方元素挤 1~2pt，也绝不让正文压到时间上（压上去就是字叠字）。
    CGFloat msgH = MAX(31.0, timeY - 3 - msgY);
    self.msgLabel.frame = CGRectMake(ox + textX, oy + msgY, textW, msgH);

    self.timeLabel.frame = CGRectMake(ox + textX, oy + timeY, textW - 24, timeH);
    // v0.0.48：★ 从右上角挪到**右下角**（右上角让给未读书签），和时间同一行、右对齐。
    self.starLabel.frame = CGRectMake(ox + w - pad - 18, oy + timeY - 1, 18, 16);

    // v0.0.72：右上角未读书签。
    // 🔴 宽度按**数字位数**算，不写死：一位数 18、两位数 24、三位数 30。
    //    写死一个宽度的话，99 条未读时数字会被挤出书签外（这种"只在少数数据下翻车"
    //    的 bug 最难被发现 —— 平时测试永远只有 1~2 位）。
    // 🔴 显隐判据用原始 `self.isUnread`，不用 pinView.hidden。
    if (self.isUnread) {
        NSString *num = self.pinLabel.text ?: @"1";
        // 🔴 先转成**有符号**整数再减：`num.length` 是 NSUInteger，
        //    空串时 `length - 1` 会下溢成天文数字 ⇒ 书签被撑到屏幕外。
        NSInteger digits = (NSInteger)num.length;
        CGFloat pinW = 18.0 + (CGFloat)MAX((NSInteger)0, digits - 1) * 6.0;
        CGFloat pinH = 20;
        // 右缩进 14（比卡片圆角 12 多让 2pt）：卡片是 clipsToBounds，
        // 贴着圆角切的地方会被削掉一个角，看起来像书签缺了一块。
        self.pinView.frame = CGRectMake(ox + w - pad - pinW, oy, pinW, pinH);
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(0, 0)];
        [p addLineToPoint:CGPointMake(pinW, 0)];
        [p addLineToPoint:CGPointMake(pinW, pinH)];
        [p addLineToPoint:CGPointMake(pinW / 2, pinH - 5)];   // 底下的 V 形缺口
        [p addLineToPoint:CGPointMake(0, pinH)];
        [p closePath];
        self.pinShape.frame = self.pinView.bounds;
        self.pinShape.path = p.CGPath;
        self.pinLabel.frame = CGRectMake(0, 1, pinW, 14);
        // 🔴 App 名那一行要给书签让位：书签 y=0~20，App 名 y=8~22，两者**竖向重叠 12pt**
        //    ⇒ 不让位就会字压在书签上。标题(y=23)在书签下方，不用让。
        self.appLabel.frame = CGRectMake(ox + textX, oy + 8, MAX(0, textW - pinW - 6), 14);
    }
}

// v0.0.70：按下时只染**卡片**，不染整行。
// 🔴 为什么不用系统选中态：`selectionStyle` 的高亮是把整块 cell 盖一层灰，
//    卡片外的留白也会变灰 ⇒ 看起来像"上下两行连成一片"，卡片化就白做了。
//    这里自己换 cardView 的底色，留白保持透明（透出 tableView 的灰底），分层才成立。
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    self.cardView.backgroundColor = highlighted
        ? [UIColor tertiarySystemFillColor]
        : NBCardBG();
}

- (void)setIcon:(UIImage *)icon letter:(NSString *)letter {
    if (icon) {
        self.iconView.image = icon;
        self.iconView.hidden = NO;
        self.letterLabel.hidden = YES;
    } else {
        self.iconView.image = nil;
        self.iconView.hidden = YES;
        self.letterLabel.hidden = NO;
        self.letterLabel.text = letter.length ? letter : @"?";
    }
}

- (void)setAppName:(NSString *)name {
    // 🔴 取不到名字时**留空**、不写「未知」：这一行是上下文，写个「未知」反而抢眼，
    //    而且实际路径上不会发生（`ViewController` 的 `appNameForBundle:` 会兜底成 bundle 末段）。
    self.rawAppName = name.length ? name : nil;
    [self nbRender];
}

- (void)setTitleText:(NSString *)title message:(NSString *)message subtitle:(NSString *)subtitle {
    self.rawTitle = title.length ? title : @"(无标题)";

    // 🔴🔴 v0.0.45：subtitle **单独成行**，不再"只在正文为空时才顶替正文"。
    //    两个分支的判据是"正文有没有"，不是"副标题有没有"：
    //      ① 正文非空 ⇒ 副标题单独占一行（这才是绝大多数情况）
    //      ② 正文为空 ⇒ 副标题顶上当正文，**不再单独占一行**
    //         —— 否则同一句话在屏幕上出现两遍，比不显示更糟。
    //    🔴 还要排除"副标题和正文一模一样"（不少 App 把同一段文字两处都填）：
    //       那种情况下单独显示一行等于原样复制一遍正文。
    if (message.length && subtitle.length && ![subtitle isEqualToString:message]) {
        self.rawSubtitle = subtitle;
    } else {
        self.rawSubtitle = nil;
    }

    // 🔴 正文为空时**明确写出「(无正文)」**，不要留空。
    //    留空的话，「库里没存到正文」和「存了但没画出来」看起来一模一样 ——
    //    上一版就是因为这个把两种病因混在一起了。
    if (message.length) {
        self.rawBody = message;
        self.rawBodyColor = [UIColor secondaryLabelColor];
    } else if (subtitle.length) {
        self.rawBody = subtitle;
        self.rawBodyColor = [UIColor secondaryLabelColor];
    } else {
        self.rawBody = @"(无正文)";
        self.rawBodyColor = [UIColor tertiaryLabelColor];
    }
    [self nbRender];
}

- (void)setHighlightQuery:(NSString *)query {
    self.hlQuery = query.length ? query : nil;
    [self nbRender];
}

// v0.0.44：三个 label 的唯一写字出口。
// 🔴 为什么集中在这里：高亮依赖"原始串 + 搜索词"两样东西，而它们由两个不同的 setter 给。
//    分开写就会出现"后调的那个把前一个的高亮冲掉"（高亮只在 App 名上、正文没标）。
- (void)nbRender {
    self.appLabel.attributedText = NBHighlight(self.rawAppName, self.hlQuery,
                                               [UIColor secondaryLabelColor]);
    self.titleLabel2.attributedText = NBHighlight(self.rawTitle, self.hlQuery,
                                                  [UIColor labelColor]);
    // v0.0.45：副标题也参与高亮（搜索本来就命中 subtitle，界面上必须能看出命中的是哪一处）
    self.subLabel.attributedText = NBHighlight(self.rawSubtitle, self.hlQuery,
                                               [UIColor secondaryLabelColor]);
    self.subLabel.hidden = !self.rawSubtitle.length;
    self.msgLabel.attributedText = NBHighlight(self.rawBody, self.hlQuery,
                                               self.rawBodyColor ?: [UIColor secondaryLabelColor]);
}

- (void)setTimeText:(NSString *)text {
    self.timeLabel.text = text;
}

// v0.0.72：未读 = 卡片右上角书签（带未读数）。v0.0.35 的蓝点已删除。
- (void)setUnread:(BOOL)unread count:(NSInteger)count {
    _isUnread = unread;
    self.unreadCount = count;
    [self nbUpdatePin];
    // 🔴 必须重排：书签**宽度取决于数字位数**（一位 18 / 两位 24），
    //    只改 text 不重排的话，从「9 条」变成「12 条」时数字会被挤出书签外。
    //    这里不用 `hidden` 就够了 —— 书签宽度参与布局计算，和旧蓝点不一样。
    [self setNeedsLayout];
}

- (void)nbUpdatePin {
    // 🔴 判据用原始 BOOL，不用 pinView.hidden（见属性注释）。
    self.pinView.hidden = !self.isUnread;
    if (!self.isUnread) {
        self.pinLabel.text = nil;
        return;
    }
    // 99 以上写「99+」：书签是角标，不是计数器，三位数会把宽度撑到盖住 App 名。
    NSInteger n = self.unreadCount;
    if (n > 99) {
        self.pinLabel.text = @"99+";
    } else {
        // 🔴 `MAX(1, n)`：未读但调用方没给数（或给了 0）时也要显示 1 ——
        //    空白书签看着像"漏渲染"，比显示一个偏小的数更让人怀疑功能坏了。
        self.pinLabel.text = [NSString stringWithFormat:@"%ld", (long)MAX((NSInteger)1, n)];
    }
}

// v0.0.48：关键词"标星"动作。只切 hidden，★ **不改变任何其它元素的布局**
// （v0.0.72 起它在右下角和「时间」同一行，位置固定；标星不参与任何收宽计算）。
// 🔴🔴 必须直接写 `_starred`，⛔ 不许写 `self.starred = starred;` —— 那就是
//    在 setter 里调自己 ⇒ 无限递归 ⇒ 一标星就爆栈（CI #98 的 clang
//    -Wunused-property-ivar 逮到的正是这个：ivar 没在 accessor 里被引用）。
- (void)setStarred:(BOOL)starred {
    _starred = starred;
    self.starLabel.hidden = !starred;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // 🔴 v0.0.70：卡片底色必须复位。
    //    复用池里如果留着一次"按下时的高亮色"（`setHighlighted:` 换的 tertiarySystemFill），
    //    下一行滚进来就会是一片浅灰卡片 —— 症状是"某几行底色不对，滚动一下又变了"，
    //    极难复现也极难归因。**凡是 setter 改过的外观，prepareForReuse 必须改回去。**
    self.cardView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.iconView.image = nil;
    self.iconView.hidden = YES;
    self.letterLabel.hidden = NO;
    self.letterLabel.text = nil;
    // v0.0.42：App 名也要清 —— 复用池里留着上一行的名字，
    // 会出现"新记录显示的是上一个 App 的名字"，而且只闪一下就很难复现。
    // v0.0.44：高亮是 `attributedText`，**两个都要清**：
    //   ① 只清 `.text` 不清 `attributedText` ⇒ 上一行的黄底会跟着复用过来；
    //   ② 只清 `attributedText` 不清原始串 ⇒ 下一行若先调 `setHighlightQuery:`
    //      就会拿上一行的原始串重新渲染一遍（显示上一条的标题）。
    self.appLabel.attributedText = nil;
    self.titleLabel2.attributedText = nil;
    // v0.0.45：副标题**两个都要清**（attributedText + 原始串），理由和上面那三个一样：
    //   不清原始串 ⇒ 下一行 `layoutSubviews` 会按"有副标题"排，凭空空出一行。
    self.subLabel.attributedText = nil;
    self.subLabel.hidden = YES;
    self.msgLabel.attributedText = nil;
    self.rawAppName = nil;
    self.rawTitle = nil;
    self.rawSubtitle = nil;
    self.rawBody = nil;
    self.rawBodyColor = nil;
    self.hlQuery = nil;
    self.timeLabel.text = nil;
    // 🔴 v0.0.72：未读书签**必须连同数字一起复位**。
    //    v0.0.35 那会儿只复位 `dotView.hidden` 就够了（点没有内容）；
    //    书签里**有数字**，只藏视图不清 text 的话，下一行是未读时
    //    会先按上一行的位数排好宽度，再被新数字冲掉 —— 表现为"书签宽度闪一下"。
    self.isUnread = NO;
    self.unreadCount = 0;
    self.pinView.hidden = YES;
    self.pinLabel.text = nil;
    // 🔴 v0.0.48：★ 同理必须复位（否则上一行标了星、这一行规则没命中，星会串过来）。
    self.starred = NO;
    self.starLabel.hidden = YES;
}

@end
