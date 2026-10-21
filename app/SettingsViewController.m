#import "SettingsViewController.h"
#import "NotifyStore.h"
#import "NotifyCommon.h"
#import "ReplaceRulesViewController.h"
#import "AppPickerViewController.h"
#import "VoicePickerViewController.h"
#import "InstalledApps.h"
#import <errno.h>
#import <string.h>

// 内置设置页：记录上限 / 白名单 / 黑名单 / 过滤关键词 / 朗读
//
// 🔴 保存目标是 NOTIFYBOX_SETTINGS_PATH（/var/mobile/Library/NotifyBox/settings.plist），
//    不是 Preferences 域：那个域归 cfprefsd 管，App 直接写文件会被它的缓存盖回去。
// 🔴 保存后**不需要 respring**：tweak 侧每来一条通知都会重新读这个文件（NBLoadSettings）。
//
// 🔴🔴 v0.0.13 结构改动：原来布局是「先排所有开关、再排所有输入框、再排所有按钮」，
//    三组各排各的 ⇒ 想让一行入口按钮夹在两个输入框中间**做不到**。
//    现在改成**一个 rows 数组按加入顺序排**，每行的类型存在自己的 tag 里。
//    这不是为了好看 —— 是为了以后加/删/挪一行不用改布局代码。

static const NSInteger kRowSwitch = 1;   // 标题 + UISwitch
static const NSInteger kRowGroup  = 2;   // 标题 + 输入框
static const NSInteger kRowAction = 3;   // 标题 + 右侧说明 + 可点

// box 的 tag 表示"行类型"，子视图 tag 一律从 101 起，两套编号互不干扰
// （viewWithTag: 只搜子树，不会返回 receiver 自己）
static const NSInteger kSubTitle = 101;
static const NSInteger kSubField = 102;
static const NSInteger kSubSwitch = 103;
static const NSInteger kSubValue = 104;
static const NSInteger kSubHit = 105;

// 🔴 v0.0.19：这里原来有个 `NBIsDigits()`，只被"延迟秒数"那个字段用。
//    延迟功能删掉之后它变成死代码，`-Werror -Wunused-function` 直接把编译打断
//    （CI 报：unused function 'NBIsDigits'）。
//    ⇒ 删功能时必须连带清掉**只有它用的辅助函数**，否则编译期就拦你；
//      这类连带影响不会在"读代码"时被发现，只有真编一次才知道。
//    它当初要解决的问题留着当教训：`[@"abc" integerValue]` 是 0，跟"用户填了 0"
//    分不开 ⇒ 任何"数字输入"字段都不能只用 integerValue 判对错。

@interface SettingsViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSMutableArray<UIView *> *rows;        // 统一的行，按加入顺序
@property (nonatomic, strong) NSMutableArray<UITextField *> *fields;
// 🔴 每个输入框对应哪个设置键，**跟着字段一起存**。
//    写死下标的话，只要在中间插一个新字段，后面所有键就整体错位一格：
//    用户改"记录上限"，实际写进了"过滤关键词"。保存成功、回读一致、就是不生效。
@property (nonatomic, strong) NSMutableArray<NSString *> *fieldKeys;
@property (nonatomic, strong) UISwitch *speakSwitch;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *actionRows;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UILabel *statusLabel;

- (void)addSwitchRow:(NSString *)title on:(BOOL)on;
- (void)addGroup:(NSString *)title
              ph:(NSString *)ph
           value:(NSString *)value
        keyboard:(UIKeyboardType)kb
             key:(NSString *)key;
- (UIView *)addActionRow:(NSString *)title key:(NSString *)key action:(SEL)sel;
- (void)refreshActionValues;
- (void)setActionValue:(NSString *)text forKey:(NSString *)key;
- (NSString *)strOf:(id)v;
- (BOOL)boolOf:(id)v;
- (NSString *)trim:(NSString *)s;
- (void)onSave:(id)sender;
- (void)onClose:(id)sender;
- (void)onReplace:(id)sender;
- (void)onClearAll:(id)sender;
- (void)onWhite:(id)sender;
- (void)onBlack:(id)sender;
- (void)onSpeakApps:(id)sender;
- (void)onVoice:(id)sender;
- (void)onAppDiag:(id)sender;
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
    // 🔴 左右分工要清楚：左边关闭=放弃本页输入框的改动，右边保存=落盘。
    //    子页面（黑白名单/声音/替换规则）是"点一下立即生效"，本页是"表单要按保存"——
    //    两种模式并存不统一，但各自都符合用户当下的预期：选东西时不想再点保存，
    //    改数字时不想被"点一下就存"绑架。
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(onSave:)];

    self.scroll = [[UIScrollView alloc] init];
    self.scroll.alwaysBounceVertical = YES;
    self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.scroll];

    self.rows = [NSMutableArray array];
    self.fields = [NSMutableArray array];
    self.fieldKeys = [NSMutableArray array];
    self.actionRows = [NSMutableDictionary dictionary];

    NSDictionary *cur = NBLoadSettings();

    // ---------- 朗读 ----------
    [self addSwitchRow:@"朗读通知（用系统语音念出来）"
                    on:[self boolOf:cur[NB_KEY_SPEAK_ENABLED]]];
    [self addActionRow:@"朗读声音" key:@"voice" action:@selector(onVoice:)];
    [self addActionRow:@"朗读限定 App" key:@"speakapps" action:@selector(onSpeakApps:)];

    // ---------- 延迟推送：v0.0.19 已整体移除 ----------
    // 🔴 这里**故意连这个开关都不放**。历史上它两次把用户手机搞坏：
    //    v0.0.14 跨队列调原方法 ⇒ 桌面 SIGTRAP 进安全模式；
    //    v0.0.16 改 bulletin 的时间字段 ⇒ 通知全不弹（每次重排又 +5 秒，永远到不了）。
    //    ⇒ 留一个"填秒数"的输入框，等于留一个能把通知弄没的开关。
    //    完整证据链在仓库 notifybox/README.md 的「v0.0.19」那一章。

    // ---------- 记录 ----------
    id mx = cur[@"maxRecords"];
    NSString *mxStr = [mx respondsToSelector:@selector(stringValue)] ? [mx stringValue]
                     : ([mx isKindOfClass:[NSString class]] ? (NSString *)mx : @"");
    [self addGroup:@"记录上限（条）"
                 ph:@"500"
              value:mxStr
           keyboard:UIKeyboardTypeNumberPad
                key:@"maxRecords"];

    // ---------- 推送拦截 ----------
    [self addActionRow:@"白名单（只推送这些）" key:@"white" action:@selector(onWhite:)];
    [self addActionRow:@"黑名单（不推送这些）" key:@"black" action:@selector(onBlack:)];
    [self addGroup:@"过滤关键词（逗号分隔，命中就不弹）"
                 ph:@"红包,限时,领取"
              value:[self strOf:cur[@"blockKeywords"]]
           keyboard:UIKeyboardTypeDefault
                key:@"blockKeywords"];

    // ---------- 工具 ----------
    [self addActionRow:@"内容替换规则" key:@"replace" action:@selector(onReplace:)];
    [self addActionRow:@"App 枚举诊断" key:@"appdiag" action:@selector(onAppDiag:)];
    [self addActionRow:@"清空全部记录" key:@"clear" action:@selector(onClearAll:)];

    self.hintLabel = [[UILabel alloc] init];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.textColor = [UIColor secondaryLabelColor];
    self.hintLabel.text =
        @"说明\n"
        @"• 保存后立即生效，不用 respring。\n"
        @"• 白名单一旦填了，就等于「只保留这些 App」，其它全部不弹（有杀伤力）。\n"
        @"• 白名单/黑名单/朗读限定都点进去选，可以搜索；点一下立即生效，没有保存按钮。\n"
        @"• 被拦下的通知仍然会记进盒子里，方便回头查本来要推什么。\n"
        @"• 内容替换只改通知上显示的文字；盒子里存的仍是原文。\n"
        @"• 记录上限默认 500；超出后自动淘汰最旧的。\n"
        @"• 朗读默认关闭。打开后会占用音频通道，可能让正在播放的音乐变小或暂停 ——\n"
        @"  这是系统语音合成的固有行为，不是 bug。\n"
        @"• 朗读只念「替换后」的文字（跟通知上看到的一致）；被过滤规则拦下的通知不念。\n"
        @"• 如果朗读导致桌面崩溃重启，插件会在下次开机时**自动把朗读关掉**，\n"
        @"  并往日志写一行「朗读自毁保护触发」，不需要你做任何事。\n"
        @"• 延迟推送已在 v0.0.19 移除（不是关闭）。它两次把手机搞坏：\n"
        @"  一次让桌面崩进安全模式，一次让通知一条都不弹，所以整个拿掉了。\n"
        @"  如果你手里那版还填着秒数，装上这版会自动把它清掉，不用你手动改。\n"
        @"• 顺带修好一个会丢数据的问题：数据库锁。以前盒子 App 和桌面同时写库时，\n"
        @"  SQLite 直接返回 busy（日志里 INSERT 失败 rc=5），那条通知就静默丢了；\n"
        @"  现在会最多等 2 秒再放弃。\n"
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

    [self refreshActionValues];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 🔴 从子页面返回时必须刷新：用户在里面选了 3 个 App，回到这里还显示旧数字，
    //    他会以为没保存成功，然后再进去一遍。**状态不可见 = 功能不存在。**
    [self refreshActionValues];
}

#pragma mark - 行的创建

- (void)addSwitchRow:(NSString *)title on:(BOOL)on {
    UIView *box = [[UIView alloc] init];
    box.tag = kRowSwitch;
    box.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    box.layer.cornerRadius = 10;
    box.clipsToBounds = YES;
    [self.scroll addSubview:box];

    UILabel *l = [[UILabel alloc] init];
    l.text = title;
    l.font = [UIFont systemFontOfSize:14];
    l.textColor = [UIColor labelColor];
    l.numberOfLines = 2;
    l.tag = kSubTitle;
    [box addSubview:l];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.tag = kSubSwitch;
    [box addSubview:sw];
    // ⚠️ 目前只有这一个开关，所以直接挂到属性上。
    //    以后再加开关必须改成分开存（比如进字典），否则最后一个会覆盖前面的。
    self.speakSwitch = sw;

    [self.rows addObject:box];
}

- (void)addGroup:(NSString *)title
              ph:(NSString *)ph
           value:(NSString *)value
        keyboard:(UIKeyboardType)kb
             key:(NSString *)key {
    UIView *box = [[UIView alloc] init];
    box.tag = kRowGroup;
    box.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    box.layer.cornerRadius = 10;
    box.clipsToBounds = YES;
    [self.scroll addSubview:box];

    UILabel *l = [[UILabel alloc] init];
    l.text = title;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    l.textColor = [UIColor labelColor];
    l.tag = kSubTitle;
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
    f.tag = kSubField;
    [box addSubview:f];

    [self.rows addObject:box];
    [self.fields addObject:f];
    [self.fieldKeys addObject:key ?: @""];
}

// 入口行：左边标题，右边「已选 N 个 ›」，整行可点。
- (UIView *)addActionRow:(NSString *)title key:(NSString *)key action:(SEL)sel {
    UIView *box = [[UIView alloc] init];
    box.tag = kRowAction;
    box.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    box.layer.cornerRadius = 10;
    box.clipsToBounds = YES;
    [self.scroll addSubview:box];

    UILabel *t = [[UILabel alloc] init];
    t.text = title;
    t.font = [UIFont systemFontOfSize:15];
    t.textColor = [UIColor labelColor];
    t.tag = kSubTitle;
    [box addSubview:t];

    UILabel *v = [[UILabel alloc] init];
    v.font = [UIFont systemFontOfSize:12];
    v.textColor = [UIColor secondaryLabelColor];
    v.textAlignment = NSTextAlignmentRight;
    v.tag = kSubValue;
    [box addSubview:v];

    // 透明按钮铺满整行接收点击。用 UIButton 而不是 UITapGestureRecognizer：
    // 手势会和 UIScrollView 的滑动打架（滑一下被当成点击）。
    UIButton *hit = [UIButton buttonWithType:UIButtonTypeCustom];
    hit.tag = kSubHit;
    [hit addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:hit];

    [self.rows addObject:box];
    if (key.length) self.actionRows[key] = box;
    return box;
}

#pragma mark - 刷新入口行的右侧说明

- (void)setActionValue:(NSString *)text forKey:(NSString *)key {
    UIView *box = self.actionRows[key];
    if (!box) return;
    UILabel *v = (UILabel *)[box viewWithTag:kSubValue];
    if (![v isKindOfClass:[UILabel class]]) return;
    v.text = text;
    [box setNeedsLayout];
}

- (void)refreshActionValues {
    // 🔴 这里读的是**当前生效的设置**，不是本页输入框里的内容 ——
    //    输入框改了但没保存时，这几行显示的仍是磁盘上的真实值。这个区分是对的：
    //    它们本来就不是本页能编辑的东西。
    NSDictionary *d = [NotifyStore settings];

    NSUInteger w = [NBStringArray(d[@"whitelist"]) count];
    NSUInteger b = [NBStringArray(d[@"blacklist"]) count];
    NSUInteger s = [NBStringArray(d[NB_KEY_SPEAK_APPS]) count];

    [self setActionValue:(w ? [NSString stringWithFormat:@"已选 %lu 个 ›", (unsigned long)w]
                            : @"未设置（全部放行）›")
                  forKey:@"white"];
    [self setActionValue:(b ? [NSString stringWithFormat:@"已选 %lu 个 ›", (unsigned long)b]
                            : @"未设置 ›")
                  forKey:@"black"];
    [self setActionValue:(s ? [NSString stringWithFormat:@"已选 %lu 个 ›", (unsigned long)s]
                            : @"全部 App ›")
                  forKey:@"speakapps"];

    NSString *voiceName = [VoicePickerViewController currentVoiceDisplayName];
    id rid = d[NB_KEY_SPEAK_RATE];
    NSString *rateName = @"默认速度";
    if ([rid isKindOfClass:[NSNumber class]]) {
        float r = [(NSNumber *)rid floatValue];
        if (r < 0.45f) rateName = @"慢";
        else if (r < 0.55f) rateName = @"正常";
        else if (r < 0.65f) rateName = @"快";
        else rateName = @"很快";
    }
    [self setActionValue:[NSString stringWithFormat:@"%@ · %@ ›", voiceName, rateName]
                  forKey:@"voice"];

    id rr = d[@"replaceRules"];
    NSUInteger rn = [rr isKindOfClass:[NSArray class]] ? [(NSArray *)rr count] : 0;
    [self setActionValue:(rn ? [NSString stringWithFormat:@"%lu 条 ›", (unsigned long)rn]
                             : @"未设置 ›")
                  forKey:@"replace"];

    [self setActionValue:[NSString stringWithFormat:@"%ld 条记录 ›", (long)[NotifyStore count]]
                  forKey:@"clear"];
    [self setActionValue:@"看看枚举到哪些 App ›" forKey:@"appdiag"];
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

#pragma mark - 布局

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat x = 12;
    CGFloat cw = w - x * 2;
    CGFloat y = 12;

    self.scroll.frame = CGRectMake(0, 0, w, self.view.bounds.size.height);

    for (UIView *box in self.rows) {
        NSInteger kind = box.tag;
        UIView *title = [box viewWithTag:kSubTitle];

        if (kind == kRowSwitch) {
            CGFloat bh = 54;
            box.frame = CGRectMake(x, y, cw, bh);
            UIView *sw = [box viewWithTag:kSubSwitch];
            // UISwitch 尺寸写死的话，大字号/无障碍下会被裁掉。
            // intrinsicContentSize 在未 layout 时是 (-1,-1)，做一次兜底。
            CGSize sz = [sw intrinsicContentSize];
            if (sz.width <= 0 || sz.height <= 0) sz = CGSizeMake(51, 31);
            CGFloat lw = MAX(60.0, cw - 14 - sz.width - 24);
            CGSize ls = [title sizeThatFits:CGSizeMake(lw, CGFLOAT_MAX)];
            title.frame = CGRectMake(14, (bh - ls.height) / 2.0, lw, ls.height);
            sw.frame = CGRectMake(cw - 14 - sz.width, (bh - sz.height) / 2.0, sz.width, sz.height);
            y += bh + 10;

        } else if (kind == kRowGroup) {
            CGFloat bh = 72;
            box.frame = CGRectMake(x, y, cw, bh);
            title.frame = CGRectMake(12, 8, cw - 24, 18);
            UIView *f = [box viewWithTag:kSubField];
            f.frame = CGRectMake(12, 30, cw - 24, 34);
            y += bh + 10;

        } else {   // kRowAction
            CGFloat bh = 46;
            box.frame = CGRectMake(x, y, cw, bh);
            UILabel *v = (UILabel *)[box viewWithTag:kSubValue];
            CGSize vs = [v sizeThatFits:CGSizeMake(cw - 24, bh)];
            CGFloat vw = MIN(vs.width, cw - 24 - 100);
            v.frame = CGRectMake(cw - 14 - vw, (bh - vs.height) / 2.0, vw, vs.height);
            CGFloat tw = cw - 14 - vw - 14 - 10;
            title.frame = CGRectMake(14, 0, MAX(40.0, tw), bh);
            UIView *hit = [box viewWithTag:kSubHit];
            hit.frame = CGRectMake(0, 0, cw, bh);
            y += bh + 10;
        }
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

#pragma mark - 保存

- (NSString *)trim:(NSString *)s {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

- (void)onSave:(id)sender {
    [self.view endEditing:YES];

    // 以当前生效配置为底：子页面（黑白名单/替换规则/声音）写的键不在本页编辑范围内，
    // 不这样兜底就会被本页的保存动作整体冲掉。
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[NotifyStore settings]];

    d[NB_KEY_SPEAK_ENABLED] = @(self.speakSwitch ? self.speakSwitch.isOn : NO);

    // 🔴 遍历字段用 fieldKeys 配对，不写死下标
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

    // 🔴🔴 v0.0.19 总闸门：写盘之前把已移除功能的键删干净。
    //    病因：这个方法的写法是「启动时读到的整份 dict → 改一项 → 整份写回」。
    //    只要那份里还有 delaySeconds，用户改任何别的设置都会把它**原样写回去**，
    //    于是 tweak 清一次、App 复活一次 —— 表现就是"明明删了，还在跑"。
    //    ⇒ 让这一个出口负责"已移除的键绝不落盘"，比在每个入口判断都可靠。
    [d removeObjectForKey:NB_KEY_DELAY_SECONDS];
    [d removeObjectForKey:NB_KEY_DELAY_APPS];

    errno = 0;
    BOOL ok = [NotifyStore saveSettings:d];
    int e = errno;
    if (ok) {
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
    [self refreshActionValues];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

- (void)onClose:(id)sender {
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - 子页面

- (void)push:(UIViewController *)vc {
    // 子页面写的是同一份 settings.plist，返回后靠 viewWillAppear 刷新
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)onReplace:(id)sender {
    [self.view endEditing:YES];
    [self push:[[ReplaceRulesViewController alloc] init]];
}

- (void)onWhite:(id)sender {
    [self.view endEditing:YES];
    [self push:[[AppPickerViewController alloc] initWithMode:NBAppPickModeWhitelist]];
}

- (void)onBlack:(id)sender {
    [self.view endEditing:YES];
    [self push:[[AppPickerViewController alloc] initWithMode:NBAppPickModeBlacklist]];
}

- (void)onSpeakApps:(id)sender {
    [self.view endEditing:YES];
    [self push:[[AppPickerViewController alloc] initWithMode:NBAppPickModeSpeak]];
}

- (void)onVoice:(id)sender {
    [self.view endEditing:YES];
    [self push:[[VoicePickerViewController alloc] init]];
}

- (void)onAppDiag:(id)sender {
    [self.view endEditing:YES];
    // 枚举失败是静默的（列表空），所以把"哪条路走通了"直接摆出来
    NSString *rep = [InstalledApps diagReport];
    UIAlertController *a = [UIAlertController
                            alertControllerWithTitle:@"App 枚举诊断"
                                             message:rep
                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
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
        [self refreshActionValues];
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
