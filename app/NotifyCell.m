#import "NotifyCell.h"

@interface NotifyCell ()
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
+ (CGFloat)height { return 98.0; }

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    // 图标容器：真图标和首字母共用一块底
    self.iconBox = [[UIView alloc] init];
    self.iconBox.backgroundColor = [UIColor secondarySystemFillColor];
    self.iconBox.layer.cornerRadius = 9;
    self.iconBox.clipsToBounds = YES;
    [self.contentView addSubview:self.iconBox];

    // v0.0.35：未读点。放在图标左边（见 layoutSubviews 里的 DOT_X/ICON_X）。
    // 默认 hidden —— 万一某处忘了调 setUnread:，宁可少一个点，也不要给所有行都点上。
    self.dotView = [[UIView alloc] init];
    self.dotView.backgroundColor = [UIColor systemBlueColor];
    // 圆的半径在 layoutSubviews 里按 dotD / 2 算（改尺寸不会忘同步）
    self.dotView.hidden = YES;
    [self.contentView addSubview:self.dotView];

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
    [self.contentView addSubview:self.appLabel];

    self.titleLabel2 = [[UILabel alloc] init];
    self.titleLabel2.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.titleLabel2.textColor = [UIColor labelColor];
    self.titleLabel2.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:self.titleLabel2];

    self.timeLabel = [[UILabel alloc] init];
    self.timeLabel.font = [UIFont systemFontOfSize:11];
    self.timeLabel.textColor = [UIColor tertiaryLabelColor];
    self.timeLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:self.timeLabel];

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
    [self.contentView addSubview:self.subLabel];

    self.msgLabel = [[UILabel alloc] init];
    self.msgLabel.font = [UIFont systemFontOfSize:13];
    self.msgLabel.textColor = [UIColor secondaryLabelColor];
    self.msgLabel.numberOfLines = 2;                 // 正文最多两行，超了截断
    self.msgLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:self.msgLabel];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat pad = 14;
    CGFloat side = 46;

    // v0.0.35：左侧让出 8pt 给未读点。
    // 🔴 未读/已读两态**共用同一个 iconX**（不是"只有未读才右移"）：
    //    否则同一屏里图标左缘会参差不齐，比没有点更乱。
    CGFloat dotD = 8;
    CGFloat dotX = 12;
    CGFloat iconX = dotX + dotD + 2;
    self.dotView.frame = CGRectMake(dotX, (h - dotD) / 2, dotD, dotD);
    // 半径按 dotD 算，改尺寸时不用记得同步 cornerRadius
    self.dotView.layer.cornerRadius = dotD / 2;

    self.iconBox.frame = CGRectMake(iconX, (h - side) / 2, side, side);
    self.iconView.frame = self.iconBox.bounds;
    self.letterLabel.frame = self.iconBox.bounds;

    CGFloat textX = iconX + side + 12;
    CGFloat timeW = 78;
    // v0.0.42 竖向排版（总高 98）：
    //   App 名  y=10~24    ← 新增那一行
    //   标题    y=25~45    （时间跟标题同一水平线）
    //   正文    y=47~87    （两行 13pt）
    // 🔴 标题和时间的 y 差 1pt 是**故意的**：时间 11pt、标题 15pt，基线对齐靠这一格补。
    self.appLabel.frame     = CGRectMake(textX, 10, w - textX - pad, 14);
    self.titleLabel2.frame  = CGRectMake(textX, 25, w - textX - timeW - pad, 20);
    self.timeLabel.frame    = CGRectMake(w - pad - timeW, 26, timeW, 16);
    // v0.0.45：有副标题时正文下移一行；没有就完全回到原来的 47/40。
    // 🔴 判据用 `rawSubtitle`（原始串），**不用** `subLabel.text` ——
    //    `attributedText` 赋值之后 `.text` 的取值时机不保证早于本方法，
    //    拿视图状态反推数据状态这种事在本项目已经栽过（观测者把被观测量改了）。
    BOOL hasSub = (self.rawSubtitle.length > 0);
    self.subLabel.hidden    = !hasSub;
    self.subLabel.frame     = CGRectMake(textX, 47, w - textX - pad, 16);
    self.msgLabel.frame     = CGRectMake(textX, hasSub ? 63 : 47,
                                         w - textX - pad, hasSub ? 34 : 40);
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

- (void)prepareForReuse {
    [super prepareForReuse];
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
}

@end
