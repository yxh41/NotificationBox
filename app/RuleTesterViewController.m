#import "RuleTesterViewController.h"
#import "NotifyFilter.h"
#import "NotifyStore.h"
#import "NotifyCommon.h"
#import "NBTheme.h"

@interface RuleTesterViewController ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UITextField *bundleField;
@property (nonatomic, strong) UITextField *titleField;
@property (nonatomic, strong) UITextField *subtitleField;
@property (nonatomic, strong) UITextField *messageField;
@property (nonatomic, strong) UILabel *resultLabel;

- (void)recompute;
- (void)onFillLatest;
- (void)onTapBlank;
- (NSString *)trim:(nullable NSString *)s;
- (UITextField *)nbField:(NSString *)placeholder;
- (UILabel *)nbSectionLabel:(NSString *)text;
- (UIView *)nbCardWrapping:(UIView *)inner;
@end

@implementation RuleTesterViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"规则测试器";
    self.view.backgroundColor = NBPageBG();

    self.scroll = [[UIScrollView alloc] init];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [self.scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor
                                        constant:NBInset],
        [stack.leadingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor
                                            constant:NBInset],
        [stack.trailingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor
                                             constant:-NBInset],
        [stack.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor
                                           constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor
                                          constant:-2 * NBInset],
    ]];

    [stack addArrangedSubview:[self nbSectionLabel:@"输入（样例通知）"]];

    self.bundleField   = [self nbField:@"bundle，如 com.tencent.xin（留空 = 视为无 App）"];
    self.titleField    = [self nbField:@"标题"];
    self.subtitleField = [self nbField:@"副标题（可留空）"];
    self.messageField  = [self nbField:@"正文"];

    self.bundleField.autocapitalizationType   = UITextAutocapitalizationTypeNone;
    self.bundleField.autocorrectionType       = UITextAutocorrectionTypeNo;
    self.messageField.autocorrectionType      = UITextAutocorrectionTypeNo;

    for (UITextField *f in @[self.bundleField, self.titleField,
                             self.subtitleField, self.messageField]) {
        // 实时重算：不需要"运行"按钮，改一个字结果就跟着变
        [f addTarget:self action:@selector(recompute)
            forControlEvents:UIControlEventEditingChanged];
        [stack addArrangedSubview:f];
    }

    UIButton *fill = [UIButton buttonWithType:UIButtonTypeSystem];
    [fill setTitle:@"用最近一条通知填入" forState:UIControlStateNormal];
    fill.titleLabel.font = NBFontField();
    fill.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [fill addTarget:self action:@selector(onFillLatest) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:fill];

    [stack addArrangedSubview:[self nbSectionLabel:@"判定结果（走引擎同一套函数）"]];

    self.resultLabel = [[UILabel alloc] init];
    self.resultLabel.numberOfLines = 0;
    self.resultLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.resultLabel.textColor = [UIColor labelColor];
    self.resultLabel.backgroundColor = NBCardBG();
    [stack addArrangedSubview:[self nbCardWrapping:self.resultLabel]];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTapBlank)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];

    [self recompute];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 从设置页改完规则回来，结果必须跟着变 —— 否则用户会拿着旧结论去调规则
    [self recompute];
}

#pragma mark - 计算

- (void)recompute {
    NSString *bid  = [self trim:self.bundleField.text];
    NSString *ttl  = [self trim:self.titleField.text];
    NSString *sub  = [self trim:self.subtitleField.text];
    NSString *msg  = [self trim:self.messageField.text];

    NSMutableString *s = [NSMutableString string];

    // ① 记录闸门（不落库 ≠ 不弹窗）
    BOOL skip = [NotifyFilter shouldSkipRecordForBundle:bid];
    [s appendFormat:@"① 记录：%@\n",
        skip ? @"✗ 不落库（该 App 在「不记录的 App」名单里）" : @"✓ 会落库"];

    // ② 呈现闸门（黑名单 / 白名单 / 过滤关键词）—— 原因来自引擎的唯一实现
    NSString *reason = [NotifyFilter dropReasonForBundle:bid title:ttl
                                                  message:msg subtitle:sub];
    if (reason.length) {
        [s appendFormat:@"② 呈现：✗ 拦截 —— %@\n", reason];
    } else {
        [s appendString:@"② 呈现：✓ 正常弹出\n"];
    }

    // ③ 免打扰（不弹但照记）
    NSString *dndReason = nil;
    BOOL dnd = [NotifyFilter shouldDropForDND:bid now:[NSDate date] reason:&dndReason];
    if (dnd) {
        [s appendFormat:@"③ 免打扰：✗ 不弹（时段 %@），但照常记录\n", dndReason ?: @"?"];
    } else {
        [s appendString:@"③ 免打扰：✓ 不在时段内\n"];
    }

    // ④ 内容替换 —— 引擎是**三个字段各自独立**套用整串规则（见 applyReplaceRulesTo:）
    NSDictionary *st = [NotifyStore settings] ?: @{};
    NSArray<NSDictionary *> *rules = [NotifyFilter normalizedRules:st[@"replaceRules"]];
    [s appendFormat:@"④ 内容替换（%@）：\n",
        rules.count ? [NSString stringWithFormat:@"%lu 条规则", (unsigned long)rules.count]
                    : @"没配规则"];
    if (rules.count) {
        NSMutableArray<NSNumber *> *hitsT = [NSMutableArray array];
        for (NSUInteger i = 0; i < rules.count; i++) [hitsT addObject:@0];
        NSString *t2 = [NotifyFilter applyRulesToString:ttl rules:rules hits:hitsT];

        NSMutableArray<NSNumber *> *hitsM = [NSMutableArray array];
        for (NSUInteger i = 0; i < rules.count; i++) [hitsM addObject:@0];
        NSString *m2 = [NotifyFilter applyRulesToString:msg rules:rules hits:hitsM];

        [s appendFormat:@"   标题：%@\n",
            [t2 isEqualToString:ttl] ? @"无变化"
                : [NSString stringWithFormat:@"%@ → %@", ttl.length ? ttl : @"(空)", t2]];
        [s appendFormat:@"   正文：%@\n",
            [m2 isEqualToString:msg] ? @"无变化"
                : [NSString stringWithFormat:@"%@ → %@", msg.length ? msg : @"(空)", m2]];

        // 每条规则的命中次数：标题+正文各自独立累计
        NSMutableArray<NSString *> *hitLines = [NSMutableArray array];
        for (NSUInteger i = 0; i < rules.count; i++) {
            NSUInteger n = hitsT[i].unsignedIntegerValue + hitsM[i].unsignedIntegerValue;
            if (!n) continue;
            [hitLines addObject:[NSString stringWithFormat:@"   第 %lu 条「%@ → %@」命中 %lu 次",
                (unsigned long)(i + 1), rules[i][@"from"], rules[i][@"to"], (unsigned long)n]];
        }
        if (hitLines.count) {
            [s appendString:[hitLines componentsJoinedByString:@"\n"]];
            [s appendString:@"\n"];
        } else {
            [s appendString:@"   没有任何规则命中\n"];
        }
    }

    // ⑤ 提示音（开关 + 名单 + 该 App 的分配 + 播放计划）
    BOOL sound = [NotifyFilter isSoundTargetBundle:bid];
    NSDictionary *entry = bid.length ? [NotifyFilter soundMap][bid] : nil;
    NSString *sndName = [NotifyFilter soundEntrySummary:entry];
    if (sound) {
        NSString *file = entry[NB_KEY_SOUND_ENTRY_FILE];
        NSString *plan = [file isKindOfClass:[NSString class]]
            ? [NotifyFilter playbackPlanForFileNamed:file forBundle:bid] : nil;
        [s appendFormat:@"⑤ 提示音：✓ 会换 —— %@%@\n", sndName,
            plan.length ? [NSString stringWithFormat:@"（%@）", plan] : @""];
    } else {
        [s appendFormat:@"⑤ 提示音：✗ 不换 —— %@\n",
            sndName.length ? sndName : @"未配置"];
    }

    // 结论行：一句话给"最后到底会怎样"，省得用户自己把五段拼起来
    NSMutableString *tail = [NSMutableString string];
    [tail appendFormat:@"\n—— 结论 ——\n记录：%@   呈现：%@   免打扰：%@   换音：%@",
        skip ? @"否" : @"是",
        reason.length ? @"拦" : @"放",
        dnd ? @"静音" : @"不静音",
        sound ? @"是" : @"否"];
    self.resultLabel.text = [s stringByAppendingString:tail];
}

#pragma mark - 动作

// 用库里最近一条真实通知填进输入框 —— 比手打 bundle 靠谱（用户通常记不住 bundle id）
- (void)onFillLatest {
    NSArray<NSDictionary *> *rows = [NotifyStore queryWithBundle:nil since:0 search:nil
                                                   searchBundles:nil unreadOnly:NO];
    NSDictionary *r = rows.firstObject;
    if (!r) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"库里还没有记录"
            message:@"先去收一条通知，或者手动填 bundle / 标题 / 正文。"
            preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"知道了"
                                               style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:al animated:YES completion:nil];
        return;
    }
    self.bundleField.text   = r[@"bundle"]   ?: @"";
    self.titleField.text    = r[@"title"]    ?: @"";
    self.subtitleField.text = r[@"subtitle"] ?: @"";
    self.messageField.text  = r[@"message"]  ?: @"";
    [self recompute];
}

- (void)onTapBlank {
    [self.view endEditing:YES];
}

#pragma mark - 构件

- (NSString *)trim:(NSString *)s {
    return [s stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

- (UITextField *)nbField:(NSString *)placeholder {
    UITextField *f = [[UITextField alloc] init];
    f.placeholder = placeholder;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.font = NBFontField();
    f.backgroundColor = NBCardBG();
    f.translatesAutoresizingMaskIntoConstraints = NO;
    [f.heightAnchor constraintEqualToConstant:NBFieldH].active = YES;
    return f;
}

- (UILabel *)nbSectionLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = NBFontHeader();
    l.textColor = NBSubColor();
    l.numberOfLines = 0;
    return l;
}

// 给 label 加卡片底 + 内边距（UILabel 没有 contentInset，只能外面包一层）
- (UIView *)nbCardWrapping:(UIView *)inner {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor clearColor];
    card.layer.cornerRadius = NBCardRadius;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [inner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [inner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [inner.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
    ]];
    return card;
}

@end
