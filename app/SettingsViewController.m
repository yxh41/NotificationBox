#import "SettingsViewController.h"
#import "NotifyStore.h"
#import "NotifyCommon.h"
#import "ReplaceRulesViewController.h"
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
// 🔴 v0.0.12：每个输入框对应哪个设置键，**跟着字段一起存**。
//    原来 onSave 里写死 self.fields[0] / fields[i+1] —— 只要在中间插一个新字段，
//    后面所有键就会整体错位一格：用户改"白名单"，实际写进了"黑名单"。
//    这种错完全静默（保存成功、回读一致、就是不生效），是最难查的一类。
@property (nonatomic, strong) NSMutableArray<NSString *> *fieldKeys;
@property (nonatomic, strong) NSMutableArray<UIView *> *switchRows;   // 开关行（整块）
@property (nonatomic, strong) UISwitch *speakSwitch;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableArray<UIButton *> *actions;   // 可点进去的入口行

// 🔴 内部方法全部先声明：clang 虽然能看见同一 @implementation 里后面定义的方法，
//    但显式声明可以彻底消除「method not found」类警告 —— CI 是 -Werror，宁可多写两行。
- (void)addGroup:(NSString *)title
              ph:(NSString *)ph
           value:(NSString *)value
        keyboard:(UIKeyboardType)kb
             key:(NSString *)key;
- (UIView *)addSwitchRow:(NSString *)title on:(BOOL)on;
- (UIButton *)addActionRow:(NSString *)title action:(SEL)sel;
- (NSString *)strOf:(id)v;
- (BOOL)boolOf:(id)v;
- (NSString *)trim:(NSString *)s;
- (void)onClose:(id)sender;
- (void)onSave:(id)sender;
- (void)onReplace:(id)sender;
- (void)onClearAll:(id)sender;
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
    self.fieldKeys = [NSMutableArray array];
    self.switchRows = [NSMutableArray array];

    NSDictionary *cur = NBLoadSettings();

    // 🔴 朗读相关排在最前，成一组：它是最"危险"的一个开关（会打断正在放的音乐），
    //    也是唯一一个崩了会自动关掉自己的功能，值得第一眼就看到。
    [self addSwitchRow:@"朗读通知（用系统语音念出来）"
                    on:[self boolOf:cur[NB_KEY_SPEAK_ENABLED]]];
    [self addGroup:@"朗读限定 App（逗号分隔，留空 = 全部）"
                 ph:@"com.tencent.xin"
              value:[self strOf:cur[NB_KEY_SPEAK_APPS]]
           keyboard:UIKeyboardTypeASCIICapable
                key:NB_KEY_SPEAK_APPS];

    id mx = cur[@"maxRecords"];
    NSString *mxStr = [mx respondsToSelector:@selector(stringValue)] ? [mx stringValue]
                     : ([mx isKindOfClass:[NSString class]] ? (NSString *)mx : @"");
    [self addGroup:@"记录上限（条）"
                 ph:@"500"
              value:mxStr
           keyboard:UIKeyboardTypeNumberPad
                key:@"maxRecords"];
    [self addGroup:@"白名单（逗号分隔 bundle id）"
                 ph:@"com.tencent.xin,com.apple.MobileSMS"
              value:[self strOf:cur[@"whitelist"]]
           keyboard:UIKeyboardTypeASCIICapable
                key:@"whitelist"];
    [self addGroup:@"黑名单（逗号分隔 bundle id）"
                 ph:@"com.tencent.mttlite"
              value:[self strOf:cur[@"blacklist"]]
           keyboard:UIKeyboardTypeASCIICapable
                key:@"blacklist"];
    [self addGroup:@"过滤关键词（逗号分隔，命中就不弹）"
                 ph:@"红包,限时,领取"
              value:[self strOf:cur[@"blockKeywords"]]
           keyboard:UIKeyboardTypeDefault
                key:@"blockKeywords"];

    self.actions = [NSMutableArray array];
    // 🔴 规则编辑放子页面（列表 + 增删），不塞进这个表单里
    [self addActionRow:@"内容替换规则 ›" action:@selector(onReplace:)];
    [self addActionRow:@"清空全部记录 ›" action:@selector(onClearAll:)];

    self.hintLabel = [[UILabel alloc] init];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.textColor = [UIColor secondaryLabelColor];
    self.hintLabel.text =
        @"说明\n"
        @"• 保存后立即生效，不用 respring。\n"
        @"• 白名单一旦填了，就等于「只保留这些 App」，其它全部不弹（有杀伤力）。\n"
        @"• 被拦下的通知仍然会记进盒子里，方便回头查本来要推什么。\n"
        @"• 内容替换只改通知上显示的文字；盒子里存的仍是原文。\n"
        @"• 记录上限默认 500；超出后自动淘汰最旧的。\n"
        @"• 朗读默认关闭。打开后会占用音频通道，可能让正在播放的音乐变小或暂停 ——\n"
        @"  这是系统语音合成的固有行为，不是 bug。\n"
        @"• 朗读只念「替换后」的文字（跟通知上看到的一致）；被过滤规则拦下的通知不念。\n"
        @"• 如果朗读导致桌面崩溃重启，插件会在下次开机时**自动把朗读关掉**，\n"
        @"  并往日志写一行「朗读自毁保护触发」，不需要你做任何事。\n"
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

// 读布尔型设置：统一走 NotifyCommon.h 的 NBBoolValue。
// 🔴 这里**不能再写一份**解读逻辑 —— App 和 tweak 对 "true"/"1" 的认法一旦不一致，
//    用户看到的就是"开关是开的、功能不生效"，而且保存期检查全绿，无从发现。
- (BOOL)boolOf:(id)v {
    return NBBoolValue(v);
}

- (void)addGroup:(NSString *)title
              ph:(NSString *)ph
           value:(NSString *)value
        keyboard:(UIKeyboardType)kb
             key:(NSString *)key {
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
    [self.fieldKeys addObject:key ?: @""];   // 🔴 键跟字段一起进数组，onSave 不再靠下标
}

// 开关行：「标题 + UISwitch」一行。
- (UIView *)addSwitchRow:(NSString *)title on:(BOOL)on {
    UIView *box = [[UIView alloc] init];
    box.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    box.layer.cornerRadius = 10;
    box.clipsToBounds = YES;
    [self.scroll addSubview:box];

    UILabel *l = [[UILabel alloc] init];
    l.text = title;
    l.font = [UIFont systemFontOfSize:14];
    l.textColor = [UIColor labelColor];
    l.numberOfLines = 2;
    l.tag = 1;
    [box addSubview:l];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.tag = 2;
    [box addSubview:sw];
    // ⚠️ 目前只有这一个开关，所以直接挂到 speakSwitch 属性上。
    //    以后再加开关时**必须改成分开存**（比如存进字典），否则最后一个会覆盖前面的，
    //    表现是"开 A 实际改了 B"。
    self.speakSwitch = sw;

    [self.switchRows addObject:box];
    return box;
}

- (UIButton *)addActionRow:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    b.layer.cornerRadius = 10;
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);   // 项目已 -Wno-deprecated-declarations
    b.titleLabel.font = [UIFont systemFontOfSize:15];
    [b setTitle:title forState:UIControlStateNormal];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self.scroll addSubview:b];
    [self.actions addObject:b];
    return b;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat pad = 16;
    CGFloat x = 12;
    CGFloat cw = w - x * 2;
    CGFloat y = 12;

    self.scroll.frame = CGRectMake(0, 0, w, self.view.bounds.size.height);

    // ① 开关行（朗读）
    for (UIView *box in self.switchRows) {
        CGFloat bh = 54;
        box.frame = CGRectMake(x, y, cw, bh);
        UIView *l = [box viewWithTag:1];
        UIView *sw = [box viewWithTag:2];
        // UISwitch 的尺寸现在写死的话，iOS 大字号/无障碍下会被裁掉；
        // intrinsicContentSize 在未 layout 时是 (-1,-1)，做一次兜底。
        CGSize sz = [sw intrinsicContentSize];
        if (sz.width <= 0 || sz.height <= 0) sz = CGSizeMake(51, 31);
        CGFloat lw = MAX(60.0, cw - 14 - sz.width - 24);
        CGSize ls = [l sizeThatFits:CGSizeMake(lw, CGFLOAT_MAX)];
        l.frame = CGRectMake(14, (bh - ls.height) / 2.0, lw, ls.height);
        sw.frame = CGRectMake(cw - 14 - sz.width, (bh - sz.height) / 2.0, sz.width, sz.height);
        y += bh + 10;
    }

    // ② 输入框组
    for (UIView *box in self.groups) {
        CGFloat bh = 72;
        box.frame = CGRectMake(x, y, cw, bh);
        UIView *l = [box viewWithTag:1];
        UIView *f = [box viewWithTag:2];
        l.frame = CGRectMake(12, 8, cw - 24, 18);
        f.frame = CGRectMake(12, 30, cw - 24, 34);
        y += bh + 10;
    }

    y += 2;
    for (UIButton *b in self.actions) {
        b.frame = CGRectMake(x, y, cw, 46);
        y += 46 + 10;
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

    // 以当前生效配置为底（保留 UI 没编辑的键，比如 replaceRules），
    // 再覆盖本页编辑的键。清空的项就是「删掉这个键」。
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[NotifyStore settings]];

    // 🔴 开关走布尔值，不是字符串。tweak 侧读的是 NB_KEY_SPEAK_ENABLED，
    //    写错键名的话功能会"开了不生效"而且完全静默 —— 所以键名只在 NotifyCommon.h 里定义一份。
    d[NB_KEY_SPEAK_ENABLED] = @(self.speakSwitch ? self.speakSwitch.isOn : NO);

    // 🔴 遍历字段时用 fieldKeys 配对，不再写死下标。
    //    加一个字段就整体错位一格这种 bug，保存是"成功"的、回读是"一致"的，
    //    只有功能悄悄不生效 —— 无法通过任何保存期的检查发现。
    for (NSUInteger i = 0; i < self.fields.count; i++) {
        NSString *key = (i < self.fieldKeys.count) ? self.fieldKeys[i] : nil;
        if (!key.length) continue;
        NSString *v = [self trim:self.fields[i].text];

        if ([key isEqualToString:@"maxRecords"]) {
            if (v.length == 0) {
                [d removeObjectForKey:key];
            } else {
                NSInteger n = [v integerValue];
                if (n > 0 && n < 100000) {
                    d[key] = @(n);
                } else {
                    [self fail:@"记录上限必须是 1~99999 之间的数字（原值未改）"];
                    return;
                }
            }
        } else {
            if (v.length) d[key] = v;
            else [d removeObjectForKey:key];
        }
    }

    // 🔴 统一走 NotifyStore（单一写入点：建目录 + 写文件都在那里）
    errno = 0;
    BOOL ok = [NotifyStore saveSettings:d];
    int e = errno;
    if (ok) {
        // 写完立刻回读校验：只信 writeToFile 的返回值是不够的
        NSDictionary *back = [NotifyStore settings];
        BOOL rt = [back isEqual:d];
        self.statusLabel.textColor = rt ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
        self.statusLabel.text = [NSString stringWithFormat:@"已保存 %lu 项（回读%@）· 朗读%@\n%@",
                                 (unsigned long)d.count,
                                 rt ? @"一致" : @"不一致",
                                 (self.speakSwitch && self.speakSwitch.isOn) ? @"开" : @"关",
                                 NOTIFYBOX_SETTINGS_PATH];
    } else {
        self.statusLabel.textColor = [UIColor systemRedColor];
        self.statusLabel.text = [NSString stringWithFormat:@"保存失败 errno=%d(%s)\n%@",
                                 e, strerror(e), NOTIFYBOX_SETTINGS_PATH];
    }
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

#pragma mark - 子页面 / 危险操作

- (void)onReplace:(id)sender {
    [self.view endEditing:YES];
    ReplaceRulesViewController *vc = [[ReplaceRulesViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)onClearAll:(id)sender {
    [self.view endEditing:YES];
    NSInteger n = [NotifyStore count];
    UIAlertController *a = [UIAlertController
                            alertControllerWithTitle:@"清空全部记录"
                                             message:[NSString stringWithFormat:
                                                      @"会删掉数据库里全部 %ld 条记录，不可恢复。\n"
                                                      @"（设置和替换规则不受影响）", (long)n]
                                      preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"删除 %ld 条", (long)n]
                                         style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *act) {
        [NotifyStore clearAll];
        NSInteger after = [NotifyStore count];
        self.statusLabel.textColor = [UIColor labelColor];
        self.statusLabel.text = [NSString stringWithFormat:@"已清空：%ld → %ld 条", (long)n, (long)after];
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    }]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
                                                           self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)fail:(NSString *)msg {
    self.statusLabel.textColor = [UIColor systemRedColor];
    self.statusLabel.text = msg;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

@end
