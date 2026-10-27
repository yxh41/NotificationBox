#import "NotifyCell.h"

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
@property (nonatomic, strong) UIView *dotView;      // v0.0.35 未读点
// v0.0.48：关键词规则标星（右上角 ★）。**展示时派生、不落库** —— 规则一改即时生效。
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
static const CGFloat kNBCardInsetX = 12.0;   // 卡片左右内缩
static const CGFloat kNBCardInsetY = 4.0;    // 卡片上下留白（行距）
+ (CGFloat)height { return 98.0 + kNBCardInsetY * 2; }

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
    self.cardView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.cardView.layer.cornerRadius = 12;
    self.cardView.layer.cornerCurve = kCACornerCurveContinuous;   // 和系统卡片同一个曲率
    self.cardView.clipsToBounds = YES;
    [self.contentView addSubview:self.cardView];

    // 图标容器：真图标和首字母共用一块底
    self.iconBox = [[UIView alloc] init];
    self.iconBox.backgroundColor = [UIColor secondarySystemFillColor];
    self.iconBox.layer.cornerRadius = 9;
    self.iconBox.clipsToBounds = YES;
    [self.cardView addSubview:self.iconBox];

    // v0.0.35：未读点。放在图标左边（见 layoutSubviews 里的 DOT_X/ICON_X）。
    // 默认 hidden —— 万一某处忘了调 setUnread:，宁可少一个点，也不要给所有行都点上。
    self.dotView = [[UIView alloc] init];
    self.dotView.backgroundColor = [UIColor systemBlueColor];
    // 圆的半径在 layoutSubviews 里按 dotD / 2 算（改尺寸不会忘同步）
    self.dotView.hidden = YES;
    [self.cardView addSubview:self.dotView];

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
    self.timeLabel.textAlignment = NSTextAlignmentRight;
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

    // v0.0.48：右上角 ★（关键词"标星"动作）。默认藏 —— 和未读点一样，
    // 万一某处忘了调 setStarred:，宁可少一颗星，也不要给所有行都点上。
    // 🔴 systemOrange：金/橙在浅色底上醒目，又不是"行情红绿"那种会误读成涨跌的颜色。
    self.starLabel = [[UILabel alloc] init];
    self.starLabel.text = @"★";
    self.starLabel.font = [UIFont systemFontOfSize:13];
    self.starLabel.textColor = [UIColor systemOrangeColor];
    self.starLabel.textAlignment = NSTextAlignmentRight;
    self.starLabel.hidden = YES;
    [self.cardView addSubview:self.starLabel];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // v0.0.70：先摆卡片，再把**所有**内部坐标改成相对卡片。
    // 🔴 关键：卡片内高度 = cell 高 - 上下留白 = 98，和 v0.0.69 之前的 contentView 高**完全相同**
    //    ⇒ 下面那一整套 y 坐标（10/25/47/63）一个都不用重算，只换原点。
    //    这也是为什么行高只加 8：加的是卡片外的留白，不是内容空间。
    CGRect card = CGRectInset(self.contentView.bounds, kNBCardInsetX, kNBCardInsetY);
    self.cardView.frame = card;
    CGFloat w = card.size.width;
    CGFloat h = card.size.height;
    CGFloat ox = card.origin.x;      // 卡片原点：后面每个 frame 都要带上
    CGFloat oy = card.origin.y;
    CGFloat pad = 14;
    CGFloat side = 46;

    // v0.0.35：左侧让出 8pt 给未读点。
    // 🔴 未读/已读两态**共用同一个 iconX**（不是"只有未读才右移"）：
    //    否则同一屏里图标左缘会参差不齐，比没有点更乱。
    // v0.0.70：12 → 10（卡片自己已经内缩了 12，再留 12 会显得太空）
    CGFloat dotD = 8;
    CGFloat dotX = 10;
    CGFloat iconX = dotX + dotD + 2;
    self.dotView.frame = CGRectMake(ox + dotX, oy + (h - dotD) / 2, dotD, dotD);
    // 半径按 dotD 算，改尺寸时不用记得同步 cornerRadius
    self.dotView.layer.cornerRadius = dotD / 2;

    self.iconBox.frame = CGRectMake(ox + iconX, oy + (h - side) / 2, side, side);
    self.iconView.frame = self.iconBox.bounds;
    self.letterLabel.frame = self.iconBox.bounds;

    CGFloat textX = iconX + side + 12;
    CGFloat timeW = 78;
    // v0.0.42 竖向排版（总高 98）：
    //   App 名  y=10~24    ← 新增那一行
    //   标题    y=25~45    （时间跟标题同一水平线）
    //   正文    y=47~87    （两行 13pt）
    // 🔴 标题和时间的 y 差 1pt 是**故意的**：时间 11pt、标题 15pt，基线对齐靠这一格补。
    // v0.0.48：右上角 ★。标星时给 App 名那一行**收宽**，避免 ★ 和 App 名尾字重叠。
    // 🔴 判据用原始 `self.starred`，不用 starLabel.hidden（见属性注释）。
    CGFloat starW = self.starred ? 20 : 0;
    self.starLabel.frame = CGRectMake(ox + w - pad - 18, oy + 8, 18, 18);
    self.appLabel.frame     = CGRectMake(ox + textX, oy + 10, w - textX - pad - starW, 14);
    self.titleLabel2.frame  = CGRectMake(ox + textX, oy + 25, w - textX - timeW - pad, 20);
    self.timeLabel.frame    = CGRectMake(ox + w - pad - timeW, oy + 26, timeW, 16);
    // v0.0.45：有副标题时正文下移一行；没有就完全回到原来的 47/40。
    // 🔴 判据用 `rawSubtitle`（原始串），**不用** `subLabel.text` ——
    //    `attributedText` 赋值之后 `.text` 的取值时机不保证早于本方法，
    //    拿视图状态反推数据状态这种事在本项目已经栽过（观测者把被观测量改了）。
    BOOL hasSub = (self.rawSubtitle.length > 0);
    self.subLabel.hidden    = !hasSub;
    self.subLabel.frame     = CGRectMake(ox + textX, oy + 47, w - textX - pad, 16);
    self.msgLabel.frame     = CGRectMake(ox + textX, oy + (hasSub ? 63 : 47),
                                         w - textX - pad, hasSub ? 34 : 40);
}

// v0.0.70：按下时只染**卡片**，不染整行。
// 🔴 为什么不用系统选中态：`selectionStyle` 的高亮是把整块 cell 盖一层灰，
//    卡片外的留白也会变灰 ⇒ 看起来像"上下两行连成一片"，卡片化就白做了。
//    这里自己换 cardView 的底色，留白保持透明（透出 tableView 的灰底），分层才成立。
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    self.cardView.backgroundColor = highlighted
        ? [UIColor tertiarySystemFillColor]
        : [UIColor secondarySystemGroupedBackgroundColor];
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

- (void)setUnread:(BOOL)unread {
    // 只切 hidden、不改颜色：`hidden` 不参与布局计算，也就不会因为
    // 未读/已读切换而触发多余的 layout 抖动。
    self.dotView.hidden = !unread;
}

// v0.0.48：关键词"标星"动作。和未读点一样只切 hidden（★ 不改变其它元素布局，
// 只有 App 名那一行在标星时收宽，见 layoutSubviews）。
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
    // 🔴 v0.0.35：未读点**必须**在这里复位。
    //    不复位的话，第 3 行（未读）被复用到第 30 行（已读）时会把蓝点一起带过去 ——
    //    这是 cell 复用最经典的串行 bug，而且单元测试抓不到、代码看着也没错：
    //    cellForRow 里明明调了 setUnread:NO，显示的却还是上一个 cell 的点。
    self.dotView.hidden = YES;
    // 🔴 v0.0.48：★ 同理必须复位（否则上一行标了星、这一行规则没命中，星会串过来）。
    self.starred = NO;
    self.starLabel.hidden = YES;
}

@end
