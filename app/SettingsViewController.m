#import "SettingsViewController.h"
#import "NotifyCommon.h"
#import <errno.h>
#import <string.h>

// 内置设置页：记录上限 / 白名单 / 黑名单 / 过滤关键词
//
// 🔴 保存目标是 NOTIFYBOX_SETTINGS_PATH（/var/mobile/Library/NotifyBox/settings.plist），
//    不是 Preferences 域：那个域归 cfprefsd 管，App 直接写文件会被它的缓存盖回去。
// 🔴 保存后**不需要 respring**：tweak 侧每来一条通知都会重新读这个文件（NBLoadSettings）。

@interface SettingsViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSMutableArray<UIView *> *groups;   // 每个「标题+输入框」块
@property (nonatomic, strong) NSMutableArray<UITextField *> *fields;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UILabel *statusLabel;

// 🔴 内部方法全部先声明：clang 虽然能看见同一 @implementation 里后面定义的方法，
//    但显式声明可以彻底消除「method not found」类警告 —— CI 是 -Werror，宁可多写两行。
- (void)addGroup:(NSString *)title
              ph:(NSString *)ph
           value:(NSString *)value
        keyboard:(UIKeyboardType)kb;
- (NSString *)strOf:(id)v;
- (NSString *)trim:(NSString *)s;
- (void)onClose:(id)sender;
- (void)onSave:(id)sender;
- (void)fail:(NSString *)msg;
- (void)onKeyboard:(NSNotification *)n;
@end

@implementation SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(onClose:)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(onSave:)];

    self.scroll = [[UIScrollView alloc] init];
    self.scroll.alwaysBounceVertical = YES;
    self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.scroll];

    self.groups = [NSMutableArray array];
    self.fields = [NSMutableArray array];

    NSDictionary *cur = NBLoadSettings();
    id mx = cur[@"maxRecords"];
    NSString *mxStr = [mx respondsToSelector:@selector(stringValue)] ? [mx stringValue]
                     : ([mx isKindOfClass:[NSString class]] ? (NSString *)mx : @"");
    [self addGroup:@"记录上限（条）"
                 ph:@"500"
              value:mxStr
           keyboard:UIKeyboardTypeNumberPad];
    [self addGroup:@"白名单（逗号分隔 bundle id）"
                 ph:@"com.tencent.xin,com.apple.MobileSMS"
              value:[self strOf:cur[@"whitelist"]]
           keyboard:UIKeyboardTypeASCIICapable];
    [self addGroup:@"黑名单（逗号分隔 bundle id）"
                 ph:@"com.tencent.mttlite"
              value:[self strOf:cur[@"blacklist"]]
           keyboard:UIKeyboardTypeASCIICapable];
    [self addGroup:@"过滤关键词（逗号分隔，命中就不弹）"
                 ph:@"红包,限时,领取"
              value:[self strOf:cur[@"blockKeywords"]]
           keyboard:UIKeyboardTypeDefault];

    self.hintLabel = [[UILabel alloc] init];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.textColor = [UIColor secondaryLabelColor];
    self.hintLabel.text =
        @"说明\n"
        @"• 保存后立即生效，不用 respring。\n"
        @"• 白名单一旦填了，就等于「只保留这些 App」，其它全部不弹（有杀伤力）。\n"
        @"• 被拦下的通知仍然会记进盒子里，方便回头查本来要推什么。\n"
        @"• 记录上限默认 500；超出后自动淘汰最旧的。\n"
        @"• 存储位置：\n  /var/mobile/Library/NotifyBox/settings.plist";
    [self.scroll addSubview:self.hintLabel];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    [self.scroll addSubview:self.statusLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onKeyboard:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
}

- (NSString *)strOf:(id)v {
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    if ([v isKindOfClass:[NSArray class]]) return [(NSArray *)v componentsJoinedByString:@","];
    return @"";
}

- (void)addGroup:(NSString *)title
              ph:(NSString *)ph
           value:(NSString *)value
        keyboard:(UIKeyboardType)kb {
    UIView *box = [[UIView alloc] init];
    box.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    box.layer.cornerRadius = 10;
    box.clipsToBounds = YES;
    [self.scroll addSubview:box];

    UILabel *l = [[UILabel alloc] init];
    l.text = title;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    l.textColor = [UIColor labelColor];
    [box addSubview:l];

    UITextField *f = [[UITextField alloc] init];
    f.text = value.length ? value : @"";
    f.placeholder = ph;
    f.keyboardType = kb;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.font = [UIFont systemFontOfSize:14];
    f.delegate = self;
    f.returnKeyType = UIReturnKeyDone;
    [box addSubview:f];

    // 标题/输入框都靠 tag 在 layout 里定位，避免每块各写一遍 frame
    l.tag = 1;
    f.tag = 2;
    [self.groups addObject:box];
    [self.fields addObject:f];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat pad = 16;
    CGFloat x = 12;
    CGFloat cw = w - x * 2;
    CGFloat y = 12;

    self.scroll.frame = CGRectMake(0, 0, w, self.view.bounds.size.height);

    for (UIView *box in self.groups) {
        CGFloat bh = 72;
        box.frame = CGRectMake(x, y, cw, bh);
        UIView *l = [box viewWithTag:1];
        UIView *f = [box viewWithTag:2];
        l.frame = CGRectMake(12, 8, cw - 24, 18);
        f.frame = CGRectMake(12, 30, cw - 24, 34);
        y += bh + 10;
    }

    CGSize hs = [self.hintLabel sizeThatFits:CGSizeMake(cw - 8, CGFLOAT_MAX)];
    self.hintLabel.frame = CGRectMake(x + 4, y + 8, cw - 8, hs.height);
    y += hs.height + 16;

    CGSize ss = [self.statusLabel sizeThatFits:CGSizeMake(cw - 8, CGFLOAT_MAX)];
    self.statusLabel.frame = CGRectMake(x + 4, y, cw - 8, ss.height);
    y += ss.height + 24;

    self.scroll.contentSize = CGSizeMake(w, y);
}

#pragma mark - 键盘

- (void)onKeyboard:(NSNotification *)n {
    NSDictionary *u = n.userInfo;
    CGRect end = [u[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat overlap = MAX(0, self.view.bounds.size.height - [self.view convertRect:end fromView:nil].origin.y);
    UIEdgeInsets in = self.scroll.contentInset;
    in.bottom = overlap;
    self.scroll.contentInset = in;
    self.scroll.scrollIndicatorInsets = in;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - 动作

- (NSString *)trim:(NSString *)s {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

- (void)onClose:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onSave:(id)sender {
    [self.view endEditing:YES];

    // 以当前生效配置为底（保留 UI 没编辑的键，比如 replaceRules / appSounds），
    // 再覆盖本页的四个键。清空的项就是「删掉这个键」。
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:NBLoadSettings()];

    NSString *mx = [self trim:self.fields[0].text];
    if (mx.length == 0) {
        [d removeObjectForKey:@"maxRecords"];
    } else {
        NSInteger n = [mx integerValue];
        if (n > 0 && n < 100000) d[@"maxRecords"] = @(n);
        else { [self fail:@"记录上限必须是 1~99999 之间的数字（原值未改）"]; return; }
    }

    NSArray *keys = @[@"whitelist", @"blacklist", @"blockKeywords"];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSString *v = [self trim:self.fields[i + 1].text];
        if (v.length) d[keys[i]] = v;
        else [d removeObjectForKey:keys[i]];
    }

    // 目录必须先建好（App 首启时目录可能还不存在）
    NSString *dir = [NOTIFYBOX_SETTINGS_PATH stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];

    errno = 0;
    BOOL ok = [d writeToFile:NOTIFYBOX_SETTINGS_PATH atomically:YES];
    int e = errno;
    if (ok) {
        // 写完立刻回读校验：只信 writeToFile 的返回值是不够的
        NSDictionary *back = [NSDictionary dictionaryWithContentsOfFile:NOTIFYBOX_SETTINGS_PATH];
        BOOL rt = [back isKindOfClass:[NSDictionary class]];
        self.statusLabel.textColor = rt ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
        self.statusLabel.text = [NSString stringWithFormat:@"已保存 %lu 项（回读%@）\n%@",
                                 (unsigned long)d.count,
                                 rt ? @"一致" : @"失败",
                                 NOTIFYBOX_SETTINGS_PATH];
    } else {
        self.statusLabel.textColor = [UIColor systemRedColor];
        self.statusLabel.text = [NSString stringWithFormat:@"保存失败 errno=%d(%s)\n%@",
                                 e, strerror(e), NOTIFYBOX_SETTINGS_PATH];
    }
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

- (void)fail:(NSString *)msg {
    self.statusLabel.textColor = [UIColor systemRedColor];
    self.statusLabel.text = msg;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

@end
