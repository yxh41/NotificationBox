#import "NotifyCell.h"

@interface NotifyCell ()
@property (nonatomic, strong) UIView *iconBox;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *letterLabel;
// v0.0.42：App 名（标题上方一行小字）
@property (nonatomic, strong) UILabel *appLabel;
@property (nonatomic, strong) UILabel *titleLabel2;
@property (nonatomic, strong) UILabel *msgLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UIView *dotView;      // v0.0.35 未读点
@end

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
    self.msgLabel.frame     = CGRectMake(textX, 47, w - textX - pad, 40);
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
    self.appLabel.text = name.length ? name : nil;
}

- (void)setTitleText:(NSString *)title message:(NSString *)message subtitle:(NSString *)subtitle {
    self.titleLabel2.text = title.length ? title : @"(无标题)";

    // 🔴 正文为空时**明确写出「(无正文)」**，不要留空。
    //    留空的话，「库里没存到正文」和「存了但没画出来」看起来一模一样 ——
    //    上一版就是因为这个把两种病因混在一起了。
    if (message.length) {
        self.msgLabel.text = message;
        self.msgLabel.textColor = [UIColor secondaryLabelColor];
    } else if (subtitle.length) {
        self.msgLabel.text = subtitle;
        self.msgLabel.textColor = [UIColor secondaryLabelColor];
    } else {
        self.msgLabel.text = @"(无正文)";
        self.msgLabel.textColor = [UIColor tertiaryLabelColor];
    }
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
    self.appLabel.text = nil;
    self.titleLabel2.text = nil;
    self.msgLabel.text = nil;
    self.timeLabel.text = nil;
    // 🔴 v0.0.35：未读点**必须**在这里复位。
    //    不复位的话，第 3 行（未读）被复用到第 30 行（已读）时会把蓝点一起带过去 ——
    //    这是 cell 复用最经典的串行 bug，而且单元测试抓不到、代码看着也没错：
    //    cellForRow 里明明调了 setUnread:NO，显示的却还是上一个 cell 的点。
    self.dotView.hidden = YES;
}

@end
