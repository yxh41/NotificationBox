#import "NotifyCell.h"

@interface NotifyCell ()
@property (nonatomic, strong) UIView *iconBox;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *letterLabel;
@property (nonatomic, strong) UILabel *titleLabel2;
@property (nonatomic, strong) UILabel *msgLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@end

@implementation NotifyCell

+ (CGFloat)height { return 82.0; }

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    // 图标容器：真图标和首字母共用一块底
    self.iconBox = [[UIView alloc] init];
    self.iconBox.backgroundColor = [UIColor secondarySystemFillColor];
    self.iconBox.layer.cornerRadius = 9;
    self.iconBox.clipsToBounds = YES;
    [self.contentView addSubview:self.iconBox];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.iconBox addSubview:self.iconView];

    self.letterLabel = [[UILabel alloc] init];
    self.letterLabel.textAlignment = NSTextAlignmentCenter;
    self.letterLabel.font = [UIFont boldSystemFontOfSize:18];
    self.letterLabel.textColor = [UIColor secondaryLabelColor];
    [self.iconBox addSubview:self.letterLabel];

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
    CGFloat pad = 14;
    CGFloat side = 46;

    self.iconBox.frame = CGRectMake(pad, (self.contentView.bounds.size.height - side) / 2, side, side);
    self.iconView.frame = self.iconBox.bounds;
    self.letterLabel.frame = self.iconBox.bounds;

    CGFloat textX = pad + side + 12;
    CGFloat timeW = 78;
    self.titleLabel2.frame = CGRectMake(textX, 12, w - textX - timeW - pad, 20);
    self.timeLabel.frame = CGRectMake(w - pad - timeW, 13, timeW, 16);
    self.msgLabel.frame = CGRectMake(textX, 34, w - textX - pad, 40);
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

- (void)prepareForReuse {
    [super prepareForReuse];
    self.iconView.image = nil;
    self.iconView.hidden = YES;
    self.letterLabel.hidden = NO;
    self.letterLabel.text = nil;
    self.titleLabel2.text = nil;
    self.msgLabel.text = nil;
    self.timeLabel.text = nil;
}

@end
