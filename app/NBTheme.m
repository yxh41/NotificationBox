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
