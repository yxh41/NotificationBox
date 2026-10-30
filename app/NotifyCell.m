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
// v0.0.88：未读标记改成**卡片右下角的圆形角标**（带未读数）。
// 历史：v0.0.35 左侧蓝点 → v0.0.72 右上角 V 形书签 → v0.0.88 右下角圆形角标。
// 🔴 为什么书签让位：v0.0.88 起「时间」搬到了**第一行右端**（对齐 HyperOS 的排法），
//    而右上角正是书签占的位置 —— 两个都要右上角必然打架。
//    圆形角标挪到右下角后，第一行右端只剩时间，排布才干净。
// 🔴 为什么改成圆形、不再用 CAShapeLayer 画 V 缺口：书签那套的形状语言是
//    "系统通知中心的书签"，而这张卡现在是"每条一张的信息流卡片"（HyperOS 风），
//    圆形角标才是这一套里的东西。顺带把 CAShapeLayer + 手算路径全删掉，
//    少一层图层、少一份坐标（V 缺口的 5pt 偏移以前是写死的魔数）。
@property (nonatomic, strong) UIView *pinView;            // 角标（右下角圆形）
@property (nonatomic, strong) UILabel *pinLabel;          // 未读数
// 🔴 未读/条数都存**原始量**，不拿 pinView.hidden 反推 —— 布局要按数字位数算宽度，
//    "看视图状态反推数据状态"在本项目已经栽过（attributedText 时序、标星）。
@property (nonatomic, assign) BOOL isUnread;
@property (nonatomic, assign) NSInteger unreadCount;
// v0.0.48：关键词规则标星。v0.0.72 在右下角；**v0.0.88 起在第一行右端、紧挨时间左边**。
// 🔴 为什么又挪：右下角这次让给了未读圆形角标（见 pinView 注释）。
//    放第一行右端是"不占正文空间"的唯一位置 —— 正文最多两行、本来就紧。
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
// v0.0.88：这个 App 的品牌色（由 `AppIconLoader brandColorForBundle:` 给出）。
// 🔴 卡片底色、按下态、未读角标三处都由它派生 —— 所以它必须是**原始品牌色**，
//    不能存"已经淡染过的卡片底"：那样按下态和角标都会在卡片底上再算一层，
//    颜色会一路变浅直到看不出是这个 App。
@property (nonatomic, strong) UIColor *brandColor;
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
    // v0.0.88：行距 2pt —— HyperOS 的正文比 iOS 默认松一档，两行正文之间的缝隙
    // 是"这张卡看着舒展"的主要来源（只调字号达不到那个效果）。
    // 🔴 只加行距、**不改字距**：字距一动，同样几个字占的宽度就变了，
    //    "两行截断到哪里"跟着变 —— v0.0.86 刚为"正文被切成一行半"栽过一次。
    static NSParagraphStyle *ps = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableParagraphStyle *p = [[NSMutableParagraphStyle alloc] init];
        p.lineSpacing = 2.0;
        // 🔴 必须显式写截断方式：**段落样式一旦存在，它的 lineBreakMode 会盖掉
        //    label 自己的 `lineBreakMode`** ⇒ 不写的话两行正文变成"硬切"，没有省略号，
        //    用户看不出"还有内容没显示"。
        p.lineBreakMode = NSLineBreakByTruncatingTail;
        ps = [p copy];
    });
    NSDictionary *base = @{
        NSForegroundColorAttributeName: baseColor ?: [UIColor labelColor],
        NSParagraphStyleAttributeName: ps,
    };
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
// 🔴🔴 v0.0.88：卡片彻底换成「图标在卡片外 + 每条按 App 淡染」的 HyperOS 排法。
//    左右内缩不再是同一个值（`kNBCardInsetX` 已删）：
//    左边是**图标槽**（图标 + App 名都在卡片外面），右边只有 10pt。
//    左右不对称是故意的 —— 照着截图量的，不要"顺手改成对称"。
// 🔴 v0.0.89：槽 46 → 52（App 名搬进槽里，见 NBTheme.m）。
// 🔴 卡片内部仍用**一个常量**，行高 = 它 + 上下留白：
//    layoutSubviews 里所有 y 都相对卡片算，改高度只需改这一个数。
static const CGFloat kNBCardInsetY = 5.0;    // 卡片上下留白（行距 10）
// 🔴 v0.0.88：112 → 118。多的 6pt 不是给内容的，是给第一行"时间"和标题之间的呼吸：
//    v0.0.72 时间在**底部**，和正文之间只需 3pt；搬回第一行后，
//    第一行（时间/App 名）→ 标题 → 副标题 → 正文 变成四条线，
//    每条之间都要 1~2pt 才不会糊成一团。正文两行仍是 34pt，没有被压。
static const CGFloat kNBCardInteriorH = 118.0;
// 卡片内部统一内边距。14 → 16：截图量出来是 ~20pt，但我们的卡片比它窄
// （左边让了 46pt 给图标槽），照抄 20 会把正文挤成 3 个字一行。16 是折中。
static const CGFloat kNBPad = 16.0;
// 左侧图标（在卡片**外面**）。v0.0.89：24 → 28（用户要求"图标再大一些"）。
static const CGFloat NBListIconSize = 28.0;
static const CGFloat NBListIconX = 12.0;     // 槽宽 52 ⇒ (52-28)/2 = 12，正好居中
static const CGFloat NBListIconY = 8.0;      // 相对卡片顶

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
    self.cardView.layer.cornerRadius = NBListCardRadius;   // v0.0.88：12 → 14
    self.cardView.layer.cornerCurve = kCACornerCurveContinuous;   // 和系统卡片同一个曲率
    self.cardView.clipsToBounds = YES;
    [self.contentView addSubview:self.cardView];

    // 图标容器：真图标和首字母共用一块底。
    // 🔴🔴 v0.0.88：挂到 **contentView** 上，不再挂 cardView —— 图标现在在卡片**外面**
    //    左侧那条槽里（HyperOS 的排法）。挂错父视图的症状是"图标整个不见"：
    //    cardView 是 clipsToBounds，卡片左缘之外的子视图会被直接裁掉，而且不报错。
    self.iconBox = [[UIView alloc] init];
    self.iconBox.backgroundColor = [UIColor secondarySystemFillColor];
    self.iconBox.layer.cornerRadius = 6;      // v0.0.88：9 → 6（24pt 的小块配 9 太圆）
    self.iconBox.layer.cornerCurve = kCACornerCurveContinuous;
    self.iconBox.clipsToBounds = YES;
    [self.contentView addSubview:self.iconBox];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.iconBox addSubview:self.iconView];

    self.letterLabel = [[UILabel alloc] init];
    self.letterLabel.textAlignment = NSTextAlignmentCenter;
    self.letterLabel.font = [UIFont boldSystemFontOfSize:13];   // v0.0.88：18 → 13（块是 24pt）
    self.letterLabel.textColor = [UIColor secondaryLabelColor];
    [self.iconBox addSubview:self.letterLabel];

    // v0.0.42：App 名。
    // 🔴 v0.0.89：从「卡片内第一行左边」搬到**卡片外、图标正下方**（用户要求）。
    //    搬家的三个连带改动，少一个就错位：
    //      ① 父视图从 cardView → **contentView**（卡片外了，挂 cardView 会被裁掉）；
    //      ② 字号 12 → 10（槽只有 52pt 宽，12pt 一行只放得下 4 个字）；
    //      ③ 对齐方式 → **居中**（它是图标的标签，左对齐会跟图标错开）。
    // 🔴 它仍然是"上下文"不是内容：比标题抢眼就等于把最该看的东西挤下去了。
    self.appLabel = [[UILabel alloc] init];
    self.appLabel.font = [UIFont systemFontOfSize:10];
    self.appLabel.textColor = [UIColor secondaryLabelColor];
    self.appLabel.numberOfLines = 2;                       // "拼多多商家版"这类要两行
    self.appLabel.textAlignment = NSTextAlignmentCenter;
    self.appLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:self.appLabel];

    self.titleLabel2 = [[UILabel alloc] init];
    // v0.0.88：15 → 16。卡片染了色之后底色不再是纯白，同样字号观感会"变小一号"。
    self.titleLabel2.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.titleLabel2.textColor = [UIColor labelColor];
    self.titleLabel2.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.cardView addSubview:self.titleLabel2];

    self.timeLabel = [[UILabel alloc] init];
    self.timeLabel.font = [UIFont systemFontOfSize:12];       // v0.0.88：11 → 12
    // 🔴 用 secondaryLabel 而不是 tertiary：卡片底色现在是淡染的，不是纯白，
    //    tertiary（30% alpha）压在彩色底上会糊得几乎看不见。
    self.timeLabel.textColor = [UIColor secondaryLabelColor];
    // v0.0.88：左对齐 → **右对齐**。它从"正文下方一行"搬回了**第一行行尾**（HyperOS 排法），
    // 位置在行尾当然要右对齐，否则时间和卡片右缘之间会空出一大块。
    self.timeLabel.textAlignment = NSTextAlignmentRight;
    // 🔴 v0.0.89：加一道"缩字兜底"。用户报过「日期后面的时间没了」——
    //    真因是标签右端被推到卡片外、被 `clipsToBounds` 裁掉（坐标系 bug，已修），
    //    但这类"就差几个 pt"的截断不该再靠"我把宽度算对了"来保证：
    //    允许缩到 80%，宁可小一点，也不要悄悄少一半信息。
    self.timeLabel.adjustsFontSizeToFitWidth = YES;
    self.timeLabel.minimumScaleFactor = 0.8;
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

    // v0.0.48：★（关键词"标星"动作）。默认藏 —— 和未读角标一样，
    // 万一某处忘了调 setStarred:，宁可少一颗星，也不要给所有行都点上。
    // 🔴 systemOrange：金/橙在浅色底上醒目，又不是"行情红绿"那种会误读成涨跌的颜色。
    // v0.0.89：13 → 12；位置从「第一行右端、时间左边」**再挪到第一行左端** ——
    //    App 名搬出卡片后第一行左边空了，★ 正好去填；右端留给时间，右下角留给未读角标。
    self.starLabel = [[UILabel alloc] init];
    self.starLabel.text = @"★";
    self.starLabel.font = [UIFont systemFontOfSize:12];
    self.starLabel.textColor = [UIColor systemOrangeColor];
    self.starLabel.textAlignment = NSTextAlignmentLeft;
    self.starLabel.hidden = YES;
    [self.cardView addSubview:self.starLabel];

    // v0.0.88：右下角**圆形未读角标**（替代 v0.0.72 的右上角 V 形书签）。
    // 默认 hidden —— 万一某处忘了调 setUnread:count:，宁可少一个角标，
    // 也不要给所有行都挂上（复用池里最容易串的就是这种"默认可见的装饰"）。
    // 🔴 底色在 `setBrandColor:` 里按品牌色刷，这里只给一个能看的默认值。
    self.pinView = [[UIView alloc] init];
    self.pinView.backgroundColor = [UIColor systemBlueColor];
    self.pinView.clipsToBounds = YES;
    self.pinView.hidden = YES;
    self.pinLabel = [[UILabel alloc] init];
    self.pinLabel.font = [UIFont boldSystemFontOfSize:11];
    self.pinLabel.textColor = [UIColor whiteColor];
    self.pinLabel.textAlignment = NSTextAlignmentCenter;
    // 🔴 v0.0.88：角标是**固定 20pt 的圆**（不再像书签那样按位数变宽），
    //    而「99+」在 11pt bold 下有 ≈21pt 宽 ⇒ 会溢出圆外。
    //    用自动缩字收进圈里，⛔ 不要"按位数改圆的直径" —— 一屏里的角标大小就会参差。
    self.pinLabel.adjustsFontSizeToFitWidth = YES;
    self.pinLabel.minimumScaleFactor = 0.7;
    [self.pinView addSubview:self.pinLabel];
    // 🔴 最后 add：书签要压在卡片内所有内容的上面（含 ★）。
    //    视图层级顺序 = z 序，这一条在本项目已经栽过（topCard 必须第一个 add）。
    [self.cardView addSubview:self.pinView];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // =================================================================
    // 🔴🔴 v0.0.89：坐标系修正 —— 上一版卡片里的文字**整体右移了一个卡片原点**。
    //
    // 病根：`appLabel` / `titleLabel2` / `msgLabel` / `timeLabel` / `starLabel` / `pinView`
    //      全是 **cardView 的子视图**，frame 本来就相对 cardView ⇒ 再写一次 `ox + xxx`
    //      等于加了两次卡片原点。
    // 为什么 v0.0.87 没被发现：那版 `ox` 只有 12pt，多 12pt 在一张卡片里"看着差不多"。
    //      这版 `ox` 变成 46pt（图标槽），一次升级成三个可见症状：
    //        ① 文字偏右一大截、卡片左边空一片；
    //        ② 时间标签右端被推到卡片外 —— `cardView` 是 clipsToBounds，
    //           于是只剩左半截「10-30」，`08:11` 被裁掉（用户原话「日期后面的时间还是要的」）；
    //        ③ 未读角标整个落在卡片外 ⇒ 彻底看不见（用户原话「未读标签呢」）。
    //
    // 🔴🔴 验收口径（这类错以后一律按这个量）：**「文字左缘 − 卡片左缘」必须等于内边距**。
    //      量绝对坐标量不出这个错 —— 绝对坐标偏了多少，取决于卡片原点是多少。
    //
    // 本方法里的两个坐标系，分清楚再写：
    //   · contentView 坐标：cardView、iconBox、appLabel（左侧槽里的东西）
    //   · cardView 坐标：标题 / 副标题 / 正文 / 时间 / ★ / 未读角标
    // =================================================================
    CGFloat fullW = self.contentView.bounds.size.width;
    CGRect card = CGRectMake(NBListIconSlot, kNBCardInsetY,
                             MAX(0.0, fullW - NBListIconSlot - NBListCardRight),
                             kNBCardInteriorH);
    self.cardView.frame = card;
    CGFloat w = card.size.width;      // 卡片宽：卡片内一切横坐标都相对它
    CGFloat h = card.size.height;

    // ---------- 卡片外左侧槽：图标 + App 名（contentView 坐标，要带 card.origin.y） ----------
    self.iconBox.frame = CGRectMake(NBListIconX, card.origin.y + NBListIconY,
                                    NBListIconSize, NBListIconSize);
    self.iconView.frame = self.iconBox.bounds;
    self.letterLabel.frame = self.iconBox.bounds;
    // v0.0.89：App 名搬到**卡片外、图标下面**（用户要求）。
    // 🔴 高度只给两行（10pt x 2 + 行距 2 ≈ 26pt），**不能给"剩余全部高度"**：
    //    UILabel 在过高的 frame 里会**垂直居中** ⇒ 名字会飘到卡片中间，离图标老远。
    CGFloat nameY = NBListIconY + NBListIconSize + 3.0;
    self.appLabel.frame = CGRectMake(2.0, card.origin.y + nameY,
                                     NBListIconSlot - 4.0, 28.0);

    // ---------- 卡片内（cardView 坐标，⛔ 一个都不许再加卡片原点） ----------
    CGFloat textX = kNBPad;
    CGFloat textW = MAX(0.0, w - kNBPad * 2);
    // 时间宽 90：容得下 "10-30 08:11"（12pt ≈ 66pt），并且**永远落在卡片内**
    // （`w - kNBPad - timeW` 本身就是相对卡片宽算的）。
    CGFloat timeW = MIN(90.0, textW * 0.5);
    CGFloat starW = 16.0;

    // 第一行（y=12~27）：★（左）…… 时间（右）
    // v0.0.89：App 名搬走后这一行左边空了，把 ★ 挪过来填左端（右下角还是未读角标的）。
    self.starLabel.frame = CGRectMake(textX, 12.0, starW, 15.0);
    self.timeLabel.frame = CGRectMake(w - kNBPad - timeW, 12.0, timeW, 15.0);

    // 第二行（y=33~53）：标题，独占整行宽
    self.titleLabel2.frame = CGRectMake(textX, 33.0, textW, 20.0);

    // 第三行（y=54~70）：副标题，有才占位
    // 🔴 判据用 `rawSubtitle`（原始串），**不用** `subLabel.text` ——
    //    `attributedText` 赋值之后 `.text` 的取值时机不保证早于本方法。
    BOOL hasSub = (self.rawSubtitle.length > 0);
    self.subLabel.hidden    = !hasSub;
    self.subLabel.frame     = CGRectMake(textX, 54.0, textW, 16.0);

    // 第四块：正文（y=71 有副标题 / 54 没有，到底部留 12）
    // 🔴 118-12-71 = 35pt，正好装两行 13pt + 行距 2（≈33pt）。
    CGFloat msgY = hasSub ? 71.0 : 54.0;
    CGFloat msgH = MAX(31.0, h - 12.0 - msgY);

    // 右下角未读圆形角标（贴卡片右下角，⛔ 不许超出卡片宽 —— 超了就被 clipsToBounds 吃掉）
    // 🔴 显隐判据用原始 `self.isUnread`，不用 pinView.hidden。
    if (self.isUnread) {
        CGFloat d = 20.0;
        self.pinView.frame = CGRectMake(w - kNBPad - d, h - 12.0 - d, d, d);
        self.pinView.layer.cornerRadius = d / 2.0;
        self.pinLabel.frame = self.pinView.bounds;
    }
    // 🔴 有角标时正文要让出 26pt：角标 y=86~106，正文最后一行落在 90~106，竖向是重叠的。
    // 🔴 这一段必须排在角标判定**之后**：顺序反了会拿上一轮/上一行的 isUnread 算宽度。
    CGFloat msgW = self.isUnread ? MAX(0.0, textW - 26.0) : textW;
    self.msgLabel.frame = CGRectMake(textX, msgY, msgW, msgH);
}

// v0.0.70：按下时只染**卡片**，不染整行。
// 🔴 为什么不用系统选中态：`selectionStyle` 的高亮是把整块 cell 盖一层灰，
//    卡片外的留白也会变灰 ⇒ 看起来像"上下两行连成一片"，卡片化就白做了。
//    这里自己换 cardView 的底色，留白保持透明（透出 tableView 的灰底），分层才成立。
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    // v0.0.88：卡片底色现在是**按 App 淡染**的，所以按下态不能用固定的
    // `tertiarySystemFillColor` —— 那会把品牌色整条抹掉，按下的瞬间卡片"褪色"。
    // 改成同一品牌色的「压暗一档」（`NBCardTintPressed`）。
    self.cardView.backgroundColor = highlighted
        ? NBCardTintPressed(self.brandColor)
        : NBCardTint(self.brandColor);
}

// v0.0.88：品牌色（卡片底色 / 按下态 / 未读角标三处都由它派生）。
// 🔴 传 nil ⇒ 退回中性卡片底：这是"图标和 bundleId 都拿不到"的退化态，
//    宁可一张白卡，也不要凭空造一个颜色（那会让人以为"颜色是随机的"）。
// 🔴 **一个 setter 管到底**：卡片底 + 角标底都在这里刷。
//    只刷卡片底的话，角标会留着上一次复用的颜色（症状是"角标颜色和卡片不搭，滚一下又变了"）。
// 🔴 必须直接写 `_brandColor`，⛔ 不许写 `self.brandColor = brand;` —— 无限递归。
- (void)setBrandColor:(UIColor *)brand {
    _brandColor = brand;
    self.cardView.backgroundColor = NBCardTint(brand);
    self.pinView.backgroundColor = NBBadgeTint(brand);
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

// v0.0.72：未读 = 卡片角标（带未读数）。v0.0.88 起在**右下角**、圆形。
- (void)setUnread:(BOOL)unread count:(NSInteger)count {
    _isUnread = unread;
    self.unreadCount = count;
    [self nbUpdatePin];
    // 🔴 必须重排：v0.0.88 起角标**会挤压正文宽度**（有角标时正文让出 26pt），
    //    只改 hidden 不重排的话，从"未读"翻成"已读"之后正文还是窄的
    //    —— 表现为"这一条读过之后，正文右边莫名空一块"。
    [self setNeedsLayout];
}

- (void)nbUpdatePin {
    // 🔴 判据用原始 BOOL，不用 pinView.hidden（见属性注释）。
    self.pinView.hidden = !self.isUnread;
    if (!self.isUnread) {
        self.pinLabel.text = nil;
        return;
    }
    // 99 以上写「99+」：角标是标记，不是计数器，三位数在 20pt 的圆里放不下。
    NSInteger n = self.unreadCount;
    if (n > 99) {
        self.pinLabel.text = @"99+";
    } else {
        // 🔴 `MAX(1, n)`：未读但调用方没给数（或给了 0）时也要显示 1 ——
        //    空白角标看着像"漏渲染"，比显示一个偏小的数更让人怀疑功能坏了。
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
    // 🔴🔴 v0.0.88 加倍重要：底色现在是**按 App 染色**的，不复位就是
    //    "上一行的微信绿留在这一行的短信卡上"，而且滚回去又变回来 —— 比纯灰更难查。
    //    走 `setBrandColor:nil` 而不是直接写 backgroundColor：那个 setter 会**同时**
    //    把角标底色也刷回默认值，一条命令复位两处，不会漏。
    self.brandColor = nil;
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
