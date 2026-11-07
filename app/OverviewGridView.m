//
//  OverviewGridView.m
//  NotifyBox
//
//  v0.0.164
//

#import "OverviewGridView.h"
#import "AppIconLoader.h"

// ============================================================================
// 尺寸常量：**只在这里定义一次**
// 🔴 高度算法 `heightForCardCount:` 和 `layoutSubviews` 必须用**同一组**常量。
//    两处各写一个字面量的话，`tableHeaderView` 的高度和里面画出来的东西迟早差几 pt，
//    而 UITablView 不会为此报错 —— 表现是"脚注被切掉半行"或"底部多一条空白"。
// ============================================================================
static const NSInteger kNBOverviewMaxCards = 8;   // 4 行 × 2 列
static const CGFloat   kNBOverviewTop      = 10;  // 顶部内边距
static const CGFloat   kNBOverviewHeadH    = 18;  // 抬头行（"总览" + 范围计数）
static const CGFloat   kNBOverviewHeadGap  = 6;   // 抬头 → 第一行卡片
// 🔴 v0.0.165：46 → 52。真机截图（2026-11-08）显示**摘要行压到了图标上**：
//    旧几何是 图标 y=6 高 20（占到 26），而摘要行 y=24 ⇒ 两者**重叠 2pt**。
//    这不是"离得近"，是"盖在一起"—— 图上 "EXC_BAD_ACCESS (SI…" 的顶边正好切进图标下沿。
//    现在 图标 6..26、摘要行 32..47，净空 6pt；卡片 52 高，底部留 5pt。
static const CGFloat   kNBOverviewCardH    = 52;  // 单卡高度
static const CGFloat   kNBOverviewGapX     = 8;
static const CGFloat   kNBOverviewGapY     = 8;
static const CGFloat   kNBOverviewInsetX   = 12;
static const CGFloat   kNBOverviewFootGap  = 8;   // 最后一行卡片 → 脚注
static const CGFloat   kNBOverviewFootH    = 16;
static const CGFloat   kNBOverviewBottom   = 8;

@implementation NBOverviewCard
@end

// ============================================================================
// 单张卡片：一个 `UIControl`（不是 UIButton）
// 🔴 为什么不用 UIButton：我们要自排三块标签 + 图标，UIButton 会为了自己的
//    `titleLabel`/`imageView` 抢布局、还要处理 `contentEdgeInsets`。
//    UIControl 只提供 `addTarget:` 和 `highlighted`，正好够用。
// ============================================================================
@interface NBOverviewCardView : UIControl

@property (nonatomic, copy, nullable) NSString *bundleId;

- (void)applyCard:(NBOverviewCard *)card icon:(nullable UIImage *)icon;

@end

@implementation NBOverviewCardView {
    UIView      *_iconBox;
    UIImageView *_iconImage;
    UILabel     *_iconLetter;
    UILabel     *_nameLabel;
    UILabel     *_countLabel;
    UILabel     *_lineLabel;
    UILabel     *_timeLabel;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    // 🔴 用 secondarySystemBackgroundColor 而不是白：卡片要能"浮"在列表的
    //    systemBackground 上；深浅色模式下这一对都会自动反过来。
    self.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.layer.cornerRadius = 8;
    self.layer.borderWidth = 0.5;
    self.layer.borderColor = [UIColor separatorColor].CGColor;
    // 🔴 边框色是 CGColor ⇒ **不跟随** trait 变化，必须在这里重新取一次。
    //    不写的话深色模式下会留一圈浅灰边（看着像卡片没画完）。

    _iconBox = [[UIView alloc] initWithFrame:CGRectZero];
    _iconBox.layer.cornerRadius = 5;
    _iconBox.clipsToBounds = YES;
    _iconBox.backgroundColor = [UIColor tertiarySystemFillColor];
    [self addSubview:_iconBox];

    // 退化态：图标取不到时显示首字母（和顶部图标栏同一个口径）。
    _iconLetter = [[UILabel alloc] initWithFrame:CGRectZero];
    _iconLetter.font = [UIFont boldSystemFontOfSize:11];
    _iconLetter.textColor = [UIColor secondaryLabelColor];
    _iconLetter.textAlignment = NSTextAlignmentCenter;
    [_iconBox addSubview:_iconLetter];

    _iconImage = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconImage.contentMode = UIViewContentModeScaleAspectFit;
    _iconImage.hidden = YES;
    [_iconBox addSubview:_iconImage];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _nameLabel.textColor = [UIColor labelColor];
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.numberOfLines = 1;
    [self addSubview:_nameLabel];

    _countLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countLabel.font = [UIFont systemFontOfSize:11];
    _countLabel.textColor = [UIColor secondaryLabelColor];
    _countLabel.textAlignment = NSTextAlignmentRight;
    _countLabel.numberOfLines = 1;
    [self addSubview:_countLabel];

    _lineLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _lineLabel.font = [UIFont systemFontOfSize:11];
    _lineLabel.textColor = [UIColor secondaryLabelColor];
    _lineLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _lineLabel.numberOfLines = 1;
    [self addSubview:_lineLabel];

    _timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _timeLabel.font = [UIFont systemFontOfSize:10];
    _timeLabel.textColor = [UIColor tertiaryLabelColor];
    _timeLabel.textAlignment = NSTextAlignmentRight;
    _timeLabel.numberOfLines = 1;
    [self addSubview:_timeLabel];

    return self;
}

// 🔴 边框色必须在 trait 变化时重取：`CGColor` 是快照，不会自己跟着深浅色走。
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.layer.borderColor = [UIColor separatorColor].CGColor;
}

- (void)applyCard:(NBOverviewCard *)card icon:(UIImage *)icon {
    self.bundleId = card.bundleId;

    _nameLabel.text = card.name.length ? card.name : @"?";
    _countLabel.text = [NSString stringWithFormat:@"%ld 条", (long)card.total];
    // 🔴 摘要为空时**不要**退回 App 名：那会让"这条没有正文"看起来像"正文就是 App 名"。
    //    留空 + 时间照常显示，读者自然知道这条没内容。
    _lineLabel.text = card.line.length ? card.line : @"";
    _timeLabel.text = card.timeText.length ? card.timeText : @"";

    if (icon) {
        _iconImage.image = icon;
        _iconImage.hidden = NO;
        _iconLetter.hidden = YES;
    } else {
        _iconImage.image = nil;
        _iconImage.hidden = YES;
        _iconLetter.hidden = NO;
        NSString *n = card.name.length ? card.name : @"?";
        _iconLetter.text = [[n substringToIndex:1] uppercaseString];
    }

    // 无障碍：一张卡片读出来应该是"微信，23 条，文件我改好了，14:32"。
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@，%ld 条，%@，%@",
                               card.name ?: @"", (long)card.total,
                               card.line ?: @"", card.timeText ?: @""];

    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w <= 0 || h <= 0) return;

    CGFloat iconS = 20;
    _iconBox.frame = CGRectMake(6, 6, iconS, iconS);      // 占到 y=26
    _iconImage.frame = _iconBox.bounds;
    _iconLetter.frame = _iconBox.bounds;

    // 第一行：名字与条数，纵向**对齐图标中心**（图标中心 16 ⇒ 16pt 高的标签放在 y=7）。
    // 🔴 旧值 y=5 是照着 15pt 高算的，改高度时必须一起改，否则名字会往上飘。
    CGFloat countW = 38;
    _countLabel.frame = CGRectMake(w - 6 - countW, 7, countW, 16);

    CGFloat nameX = CGRectGetMaxX(_iconBox.frame) + 5;
    _nameLabel.frame = CGRectMake(nameX, 7, MAX(20, w - 6 - countW - nameX), 16);

    // 第二行：左边摘要、右边时间。**y=32 起点是关键**（见文件头 kNBOverviewCardH 的注释）：
    // 它必须排在图标底边 26 之下、并且留出看得见的净空，否则摘要顶边会切进图标。
    CGFloat timeW = 36;
    _timeLabel.frame = CGRectMake(w - 6 - timeW, 32, timeW, 15);
    _lineLabel.frame = CGRectMake(6, 32, MAX(20, w - 12 - timeW - 4), 15);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    // 按下时压暗一点。没有这一下，点卡片就没有任何"物理"反馈。
    self.backgroundColor = highlighted ? [UIColor tertiarySystemBackgroundColor]
                                       : [UIColor secondarySystemBackgroundColor];
}

@end

#pragma mark -

@implementation NBOverviewGridView {
    UILabel  *_headLabel;
    UILabel  *_footLabel;
    NSMutableArray<NBOverviewCardView *> *_cards;
}

+ (NSInteger)maxCards {
    return kNBOverviewMaxCards;
}

+ (CGFloat)heightForCardCount:(NSInteger)count {
    if (count <= 0) return 0;
    if (count > kNBOverviewMaxCards) count = kNBOverviewMaxCards;
    // 两列 ⇒ 行数 = 向上取整。用整数写法，别用 ceil(count/2.0)（浮点没必要）。
    NSInteger rows = (count + 1) / 2;
    return kNBOverviewTop
         + kNBOverviewHeadH + kNBOverviewHeadGap
         + rows * kNBOverviewCardH + (rows - 1) * kNBOverviewGapY
         + kNBOverviewFootGap + kNBOverviewFootH
         + kNBOverviewBottom;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    // 🔴 自身不画底色：它是 `tableHeaderView`，底色应该是列表的底色，
    //    自己再刷一层会和列表背景之间多一条看得见的接缝。
    self.backgroundColor = [UIColor clearColor];

    _headLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _headLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _headLabel.textColor = [UIColor secondaryLabelColor];
    _headLabel.numberOfLines = 1;
    [self addSubview:_headLabel];

    _footLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _footLabel.font = [UIFont systemFontOfSize:11];
    _footLabel.textColor = [UIColor tertiaryLabelColor];
    _footLabel.numberOfLines = 1;
    [self addSubview:_footLabel];

    _cards = [NSMutableArray array];

    return self;
}

- (void)setCards:(NSArray<NBOverviewCard *> *)cards {
    NSArray<NBOverviewCard *> *list = cards;
    if (![list isKindOfClass:[NSArray class]]) list = @[];

    NSInteger want = (NSInteger)list.count;
    if (want > kNBOverviewMaxCards) want = kNBOverviewMaxCards;

    // 复用已有卡片视图：每次刷新都重建 8 个 UIControl 也能跑，但会在滚动中
    // 制造一堆释放/新建，而这段代码每 15 秒就会被 `applyItemsAndRefreshUI` 调一次。
    while ((NSInteger)_cards.count < want) {
        NBOverviewCardView *v = [[NBOverviewCardView alloc] initWithFrame:CGRectZero];
        [v addTarget:self action:@selector(onCardTap:)
            forControlEvents:UIControlEventTouchUpInside];
        [_cards addObject:v];
        [self addSubview:v];
    }
    while ((NSInteger)_cards.count > want) {
        NBOverviewCardView *v = _cards.lastObject;
        [v removeFromSuperview];
        [_cards removeLastObject];
    }

    for (NSInteger i = 0; i < want; i++) {
        NBOverviewCard *c = list[(NSUInteger)i];
        [_cards[(NSUInteger)i] applyCard:c icon:[AppIconLoader iconForBundle:c.bundleId]];
    }

    // ---- 抬头：说清这块区域是**什么范围**的统计 ----
    _headLabel.text = @"总览";

    // ---- 脚注：把"没画出来的"也交代清楚 ----
    // 🔴 这是本项目最容易被忽略的一条：`maxCards` 只有 8，而 App 可能有 20 个。
    //    脚注必须明说"显示前 8 个"，否则用户会认为"我就这几个 App 收到过通知"。
    NSInteger apps = self.totalApps > 0 ? self.totalApps : want;
    if (apps > want) {
        _footLabel.text = [NSString stringWithFormat:
            @"共 %ld 个 App · %ld 条，这里只画出最新的 %ld 个（全部在顶部图标栏）",
            (long)apps, (long)self.totalCount, (long)want];
    } else {
        _footLabel.text = [NSString stringWithFormat:
            @"共 %ld 个 App · %ld 条", (long)apps, (long)self.totalCount];
    }

    [self setNeedsLayout];
}

- (void)onCardTap:(NBOverviewCardView *)sender {
    NSString *bid = sender.bundleId;
    if (!bid.length) return;
    if (self.onSelectBundle) self.onSelectBundle(bid);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    if (w <= 0) return;

    _headLabel.frame = CGRectMake(kNBOverviewInsetX, kNBOverviewTop,
                                  w - kNBOverviewInsetX * 2, kNBOverviewHeadH);

    CGFloat y = kNBOverviewTop + kNBOverviewHeadH + kNBOverviewHeadGap;
    CGFloat cardW = (w - kNBOverviewInsetX * 2 - kNBOverviewGapX) / 2.0;
    if (cardW < 60) cardW = 60;   // 极窄（分屏/横屏异常）时别把卡片压成一条线

    NSInteger n = (NSInteger)_cards.count;
    for (NSInteger i = 0; i < n; i++) {
        NSInteger col = i % 2;
        NSInteger row = i / 2;
        CGFloat x = kNBOverviewInsetX + col * (cardW + kNBOverviewGapX);
        CGFloat cy = y + row * (kNBOverviewCardH + kNBOverviewGapY);
        _cards[(NSUInteger)i].frame = CGRectMake(x, cy, cardW, kNBOverviewCardH);
    }

    NSInteger rows = (n + 1) / 2;
    CGFloat footY = y + rows * kNBOverviewCardH + (rows > 0 ? (rows - 1) * kNBOverviewGapY : 0)
                  + kNBOverviewFootGap;
    _footLabel.frame = CGRectMake(kNBOverviewInsetX, footY,
                                  w - kNBOverviewInsetX * 2, kNBOverviewFootH);
}

@end
