#import "ReplaceRulesViewController.h"
#import "NotifyStore.h"
#import "NotifyFilter.h"
#import "NotifyCommon.h"

// 内容替换规则：settings.plist 里的 replaceRules = [{from, to}, ...]
// 引擎侧（NotifyFilter applyReplaceRulesTo）按顺序逐条套用，只改**显示**的文字，
// 盒子里存的仍然是原文（记录发生在替换之前），所以替换不会污染历史。
//
// 🔴🔴 v0.0.14 重做这一页的原因（用户原话：「设置后都不清楚替换掉的是哪些，
//    等设置的多的时候，那记得住那么多」）：
//    ① v0.0.9~v0.0.13 这里有个**一直是坏的** bug：
//       用的是 registerClass:[UITableViewCell class] ⇒ 建出来的是 **Default** 样式
//       ⇒ detailTextLabel 根本不在视图层级里 ⇒ 「→ 替换成什么」那行**从来没显示过**。
//       用户只看得到原文，看不到替换目标 —— 这正是「不清楚替换掉的是哪些」。
//    ② 每条规则「到底命中过什么」没有地方看，规则一多全靠记忆。
//    ③ 没有任何试运行的途径，只能真发一条通知去试，试错成本高。
//
//    这一版：Subtitle 那套换成自己的三行 cell（不再依赖系统的样式约束）+
//    每条规则标出「改过 N 条 / 被前面吃掉 N 条」+ 顶部给一块试运行区。
//
// 🔴 命中统计的口径必须是**引擎里那个同一个函数**（NotifyFilter applyRulesToString），
//    否则界面显示的统计和真机行为就是两回事 —— 假数据比没数据更坏。

static const NSInteger kSecProbe  = 0;   // 试运行
static const NSInteger kSecRules  = 1;   // 规则列表
static const NSInteger kSecAction = 2;   // 清空

static const CGFloat kRuleRowHeight = 68;

static NSString *const kRuleCellID  = @"nb-rule-3line";
static NSString *const kFieldCellID = @"nb-probe-field";
static NSString *const kLabelCellID = @"nb-probe-result";
static NSString *const kPlainCellID = @"nb-plain";

static const NSInteger kTagProbeField  = 201;
static const NSInteger kTagProbeResult = 202;

static NSMutableArray<NSNumber *> *NBZeroArray(NSUInteger n) {
    NSMutableArray<NSNumber *> *a = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) [a addObject:@0];
    return a;
}

#pragma mark - 三行规则 cell

// 🔴 为什么不用 UITableViewCellStyleSubtitle：
//    Subtitle 的 detailTextLabel 是**单行且高度固定**的，塞不下
//    「→ 替换成什么」+「改过 N 条，另有 M 条被前面吃掉」两段信息，
//    长一点的替换内容会把统计挤掉（尾部截断）—— 而统计恰恰是这次要解决的痛点。
//    所以自己摆三个 label，每行独立截断，信息不会互相挤掉。
@interface NBReplaceRuleCell : UITableViewCell
@property (nonatomic, strong) UILabel *lineFrom;   // #1  原文
@property (nonatomic, strong) UILabel *lineTo;     // → 替换成什么
@property (nonatomic, strong) UILabel *lineStat;   // 改过 N 条 / 被前面吃掉 M 条
@end

@implementation NBReplaceRuleCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    // 父类样式用 Default（我们完全不用系统的 textLabel/detailTextLabel，全部自己摆）
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (self) {
        _lineFrom = [[UILabel alloc] init];
        _lineFrom.font = [UIFont systemFontOfSize:16];
        _lineFrom.lineBreakMode = NSLineBreakByTruncatingTail;

        _lineTo = [[UILabel alloc] init];
        _lineTo.font = [UIFont systemFontOfSize:13];
        _lineTo.lineBreakMode = NSLineBreakByTruncatingTail;

        _lineStat = [[UILabel alloc] init];
        _lineStat.font = [UIFont systemFontOfSize:11];
        _lineStat.lineBreakMode = NSLineBreakByTruncatingTail;

        [self.contentView addSubview:_lineFrom];
        [self.contentView addSubview:_lineTo];
        [self.contentView addSubview:_lineStat];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat full = self.contentView.bounds.size.width;
    // 右边要给 disclosure 箭头留位置，否则最后几个字会被箭头压住
    CGFloat w = full - 16.0 * 2 - 14.0;
    if (w < 60) w = 60;              // 防御：布局还没算出来时别摆出负数宽度
    _lineFrom.frame = CGRectMake(16,  7, w, 20);
    _lineTo.frame   = CGRectMake(16, 28, w, 17);
    _lineStat.frame = CGRectMake(16, 47, w, 15);
}

@end

#pragma mark - 页面

@interface ReplaceRulesViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rules;

// 试运行
@property (nonatomic, strong) UITextField *probeField;
@property (nonatomic, copy)   NSString *probeText;      // 与输入框同步（cell 重建时用它复原）
@property (nonatomic, copy)   NSString *probeResult;    // 套用后的文字（nil = 还没输入）
@property (nonatomic, copy)   NSString *probeHitLine;   // 「命中 #1、#3」/「没有任何规则命中…」

// 命中统计
@property (nonatomic, strong) NSMutableArray<NSNumber *> *hitCounts;    // 每条规则真的改过几条通知
@property (nonatomic, strong) NSMutableArray<NSNumber *> *eatenCounts;  // 每条规则被前面的规则吃掉几条
@property (nonatomic, assign) NSInteger scannedCount;                   // 统计基于多少条通知
@property (nonatomic, assign) BOOL statsReady;
@property (nonatomic, assign) NSUInteger statsGen;                      // 代数：防止过期结果盖掉新结果

- (void)reload;
- (void)updateEmptyHint;
- (void)persist;
- (void)onAdd:(id)sender;
- (void)askReplacementFor:(NSString *)from atIndex:(NSInteger)idx;
- (void)addRuleFrom:(NSString *)from to:(NSString *)to;
- (void)setRuleFrom:(NSString *)from to:(NSString *)to atIndex:(NSInteger)idx;
- (void)askAgain:(NSString *)msg;
- (void)confirmClear;
- (void)refreshProbe;
- (void)scheduleStats;
- (void)computeStatsWithRules:(NSArray<NSDictionary *> *)rules;
- (NSString *)detailForRuleAtIndex:(NSUInteger)idx;
- (void)onProbeChanged:(UITextField *)tf;
- (UITableViewCell *)probeFieldCell:(UITableView *)tableView;
- (UITableViewCell *)probeResultCell:(UITableView *)tableView;
- (UITableViewCell *)ruleCell:(UITableView *)tableView indexPath:(NSIndexPath *)indexPath;
- (NSString *)probeDisplayText;
@end

@implementation ReplaceRulesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"内容替换";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.probeText = @"";
    self.rules = [NSMutableArray array];
    self.hitCounts = [NSMutableArray array];
    self.eatenCounts = [NSMutableArray array];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(onAdd:)];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    // 🔴🔴 这里**不要** registerClass:[UITableViewCell class]。
    //    规则 cell 全部在 cellForRow 里手动 alloc，样式才能自己说了算
    //    （反正 MultiSelect 与自定义三行 cell 都用不上系统预设样式）。
    [self.view addSubview:self.table];

    [self reload];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
}

- (void)reload {
    // 🔴 读规则走 NotifyFilter 的归一函数（引擎用的是同一个）⇒
    //    不会出现「界面显示 5 条、引擎只认 4 条」这种对不上的情况。
    NSArray<NSDictionary *> *norm = [NotifyFilter normalizedRules:[NotifyStore settings][@"replaceRules"]];
    self.rules = [norm mutableCopy] ?: [NSMutableArray array];

    [self.table reloadData];
    [self updateEmptyHint];
    [self refreshProbe];
    [self scheduleStats];
}

- (void)updateEmptyHint {
    if (self.rules.count) {
        self.table.backgroundView = nil;
        return;
    }
    UILabel *l = [[UILabel alloc] init];
    l.numberOfLines = 0;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:13];
    l.textColor = [UIColor secondaryLabelColor];
    l.text = @"还没有规则\n\n点右上角 + 添加。\n"
             @"例：把「限时」替换成空 ⇒ 通知里这个词就消失了\n"
             @"（盒子里仍然保留原文，方便回溯）\n\n"
             @"规则一多，顺序就有影响 —— 加完看每条的统计，\n"
             @"上面那块「试运行」可以直接输入文字看效果。";
    self.table.backgroundView = l;
}

#pragma mark - 保存

- (void)persist {
    // 🔴 以当前设置为底，只覆盖 replaceRules；没规则时删键而不是写空数组
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[NotifyStore settings]];
    if (self.rules.count) d[@"replaceRules"] = [self.rules copy];
    else [d removeObjectForKey:@"replaceRules"];

    BOOL ok = [NotifyStore saveSettings:d];
    if (!ok) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"保存失败"
                                                                  message:NOTIFYBOX_SETTINGS_PATH
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

#pragma mark - 添加 / 编辑

- (void)onAdd:(id)sender {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"添加规则"
                                                              message:@"要替换掉的内容（原文）"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"例：限时";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    // 🔴 用 __weak 接：block 被 alert 持有、block 又强引用 alert 会成环，
    //    弹窗关掉也不释放（内存泄漏，虽不崩但没必要）
    __weak UIAlertController *weakA = a;
    [a addAction:[UIAlertAction actionWithTitle:@"下一步" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *act) {
        NSString *from = [weakA.textFields.firstObject.text
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!from.length) {
            [self askAgain:@"原文不能为空"];
            return;
        }
        [self askReplacementFor:from atIndex:-1];     // -1 = 新增
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// idx < 0 ⇒ 新增；idx >= 0 ⇒ 改第 idx 条的替换目标（顺序不变）
- (void)askReplacementFor:(NSString *)from atIndex:(NSInteger)idx {
    NSString *curTo = @"";
    if (idx >= 0 && (NSUInteger)idx < self.rules.count) {
        id v = self.rules[(NSUInteger)idx][@"to"];
        if ([v isKindOfClass:[NSString class]]) curTo = (NSString *)v;
    }
    NSString *title = (idx >= 0) ? [NSString stringWithFormat:@"改 #%ld 的替换内容", (long)(idx + 1)]
                                 : @"替换成什么";
    UIAlertController *b = [UIAlertController
                            alertControllerWithTitle:title
                                             message:[NSString stringWithFormat:@"「%@」→ ?（留空 = 直接删掉这个词）", from]
                                      preferredStyle:UIAlertControllerStyleAlert];
    [b addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"留空表示删除";
        tf.text = curTo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [b addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakB = b;
    [b addAction:[UIAlertAction actionWithTitle:(idx >= 0 ? @"保存" : @"添加")
                                          style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *act) {
        NSString *to = weakB.textFields.firstObject.text ?: @"";
        if (idx >= 0) [self setRuleFrom:from to:to atIndex:idx];
        else          [self addRuleFrom:from to:to];
    }]];
    [self presentViewController:b animated:YES completion:nil];
}

- (void)addRuleFrom:(NSString *)from to:(NSString *)to {
    // 同 from 只留一条：后加的覆盖前面的，避免规则互相打架（套用是按顺序的）
    for (NSInteger i = (NSInteger)self.rules.count - 1; i >= 0; i--) {
        if ([self.rules[(NSUInteger)i][@"from"] isEqualToString:from]) {
            [self.rules removeObjectAtIndex:(NSUInteger)i];
        }
    }
    [self.rules addObject:@{@"from": from, @"to": to ?: @""}];
    [self persist];
    [self reload];
}

- (void)setRuleFrom:(NSString *)from to:(NSString *)to atIndex:(NSInteger)idx {
    if (idx < 0 || (NSUInteger)idx >= self.rules.count) return;
    NSDictionary *newRule = @{@"from": from, @"to": to ?: @""};
    // 原位替换（顺序不变 = 用户看到的位置不变）；顺手把**别处**同 from 的重复项丢掉
    NSMutableArray<NSDictionary *> *out = [NSMutableArray arrayWithCapacity:self.rules.count];
    for (NSUInteger i = 0; i < self.rules.count; i++) {
        if (i == (NSUInteger)idx) { [out addObject:newRule]; continue; }
        id f = self.rules[i][@"from"];
        if ([f isKindOfClass:[NSString class]] && [(NSString *)f isEqualToString:from]) continue;
        [out addObject:self.rules[i]];
    }
    self.rules = out;
    [self persist];
    [self reload];
}

- (void)askAgain:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"没填内容"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) { [self onAdd:nil]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)confirmClear {
    if (!self.rules.count) return;
    UIAlertController *a = [UIAlertController
                            alertControllerWithTitle:@"清空全部规则"
                                             message:[NSString stringWithFormat:@"会删掉全部 %lu 条规则，不可撤销。\n（已经发出去的通知不受影响，只是之后不再替换）",
                                                      (unsigned long)self.rules.count]
                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *x) {
        [self.rules removeAllObjects];
        [self persist];
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 试运行

- (NSString *)probeDisplayText {
    if (!self.probeText.length) {
        return @"输入一段文字，这里会显示套用这些规则之后变成了什么。";
    }
    NSMutableString *s = [NSMutableString string];
    if (self.probeResult.length) {
        [s appendFormat:@"替换后：\n%@", self.probeResult];
    } else {
        [s appendString:@"替换后：\n（空 —— 整段都被删掉了）"];
    }
    if (self.probeHitLine.length) [s appendFormat:@"\n%@", self.probeHitLine];
    return s;
}

- (void)refreshProbe {
    NSString *raw = self.probeField ? self.probeField.text : self.probeText;
    self.probeText = raw ?: @"";

    if (!self.probeText.length) {
        self.probeResult = nil;
        self.probeHitLine = nil;
    } else {
        NSUInteger n = self.rules.count;
        // 🔴 hits 数组必须预填、且与 rules 等长（函数不负责扩数组）
        NSMutableArray<NSNumber *> *h = NBZeroArray(n);
        self.probeResult = [NotifyFilter applyRulesToString:self.probeText rules:self.rules hits:h];

        NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
        for (NSUInteger i = 0; i < n; i++) {
            if ([h[i] unsignedIntegerValue] > 0) [ids addObject:@(i + 1)];
        }
        if (!n) {
            self.probeHitLine = @"还没有规则，没东西可套用。";
        } else if (!ids.count) {
            self.probeHitLine = @"没有任何规则命中这段文字（套用后一字未变）。";
        } else {
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            for (NSNumber *x in ids) [parts addObject:[NSString stringWithFormat:@"#%@", x]];
            self.probeHitLine = [NSString stringWithFormat:@"命中 %@（按顺序套用）",
                                 [parts componentsJoinedByString:@"、"]];
        }
    }

    NSIndexPath *ip = [NSIndexPath indexPathForRow:1 inSection:kSecProbe];
    if ([self.table numberOfSections] > kSecProbe &&
        [self.table numberOfRowsInSection:kSecProbe] > 1) {
        [self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    }
}

#pragma mark - 命中统计

- (void)scheduleStats {
    NSUInteger gen = ++self.statsGen;
    NSUInteger n = self.rules.count;

    self.hitCounts = NBZeroArray(n);
    self.eatenCounts = NBZeroArray(n);
    self.scannedCount = 0;
    self.statsReady = (n == 0);
    if (!n) return;

    NSArray<NSDictionary *> *snapshot = [self.rules copy];     // 统计期间用户可能又改了规则
    __weak ReplaceRulesViewController *wself = self;
    // 🔴 必须异步到主队列：读库 + 2000 条 × 3 字段 × N 条规则的字符串套用，
    //    同步做的话首帧画不出来 —— 用户看到的是一个空白页，会以为页面坏了。
    //    （v0.0.13 的 App 选择器已经踩过同类坑：主线程被占 ⇒ 界面根本没画出来。）
    dispatch_async(dispatch_get_main_queue(), ^{
        ReplaceRulesViewController *sself = wself;
        if (!sself) return;
        if (gen != sself.statsGen) return;      // 过期的那一轮直接丢掉
        [sself computeStatsWithRules:snapshot];
    });
}

- (void)computeStatsWithRules:(NSArray<NSDictionary *> *)rules {
    NSUInteger n = rules.count;
    if (!n) return;

    // 与引擎一致：只看盒子里存的**原文**（记录发生在替换之前，所以原文是真的原文）
    NSArray<NSDictionary *> *notes = [NotifyStore queryWithBundle:nil since:0 search:nil];

    NSMutableArray<NSNumber *> *hit = NBZeroArray(n);
    NSMutableArray<NSNumber *> *eaten = NBZeroArray(n);

    for (NSDictionary *note in notes) {
        if (![note isKindOfClass:[NSDictionary class]]) continue;
        NSArray *fields = @[ note[@"title"]    ?: @"",
                             note[@"message"]  ?: @"",
                             note[@"subtitle"] ?: @"" ];   // 引擎对这三个字段各套一遍
        NSMutableArray<NSNumber *> *noteHit = NBZeroArray(n);

        for (id f in fields) {
            if (![f isKindOfClass:[NSString class]] || ![(NSString *)f length]) continue;
            NSMutableArray<NSNumber *> *h = NBZeroArray(n);
            [NotifyFilter applyRulesToString:(NSString *)f rules:rules hits:h];
            for (NSUInteger i = 0; i < n; i++) {
                if ([h[i] unsignedIntegerValue] > 0) noteHit[i] = @1;   // 字段之间去重
            }
        }

        for (NSUInteger i = 0; i < n; i++) {
            if ([noteHit[i] boolValue]) {
                hit[i] = @([hit[i] unsignedIntegerValue] + 1);
                continue;
            }
            // 没命中：是原文里本来就没有，还是**被前面的规则先改没了**？
            // 后者是顺序套用最容易踩的坑，必须单独标出来，否则用户只会觉得「这条规则没生效」。
            id fromObj = rules[i][@"from"];
            if (![fromObj isKindOfClass:[NSString class]] || ![(NSString *)fromObj length]) continue;
            for (id f in fields) {
                if (![f isKindOfClass:[NSString class]]) continue;
                if ([(NSString *)f rangeOfString:(NSString *)fromObj].location != NSNotFound) {
                    eaten[i] = @([eaten[i] unsignedIntegerValue] + 1);
                    break;
                }
            }
        }
    }

    self.hitCounts = hit;
    self.eatenCounts = eaten;
    self.scannedCount = (NSInteger)notes.count;
    self.statsReady = YES;

    // 🔴 只刷规则那一节：整表 reloadData 会把正在输入的试运行输入框的键盘收掉。
    if ([self.table numberOfSections] > kSecRules) {
        [self.table reloadSections:[NSIndexSet indexSetWithIndex:(NSUInteger)kSecRules]
                  withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (NSString *)detailForRuleAtIndex:(NSUInteger)idx {
    if (idx >= self.rules.count) return @"";
    NSDictionary *d = self.rules[idx];
    NSString *from = d[@"from"] ?: @"";
    NSString *to   = d[@"to"]   ?: @"";

    NSString *arrow = to.length ? [NSString stringWithFormat:@"→ %@", to] : @"→ （删除）";
    // 手改过 plist 或者填了两遍一样的：这条规则等于没配，明确说出来
    if ([from isEqualToString:to]) {
        return [arrow stringByAppendingString:@"　·　⚠️ 和原文一样，等于没配"];
    }
    if (!self.statsReady) return [arrow stringByAppendingString:@"　·　统计中…"];
    if (self.scannedCount == 0) return arrow;      // 盒子里还没通知，无从统计

    // 🔴 越界保护：统计数组和 rules 正常是等长的，但"正常"不等于"永远"。
    //    这里少一个判断就是一次闪退，而闪退的现场（这一页）恰好是用户最常来的页面。
    if (idx >= self.hitCounts.count || idx >= self.eatenCounts.count) return arrow;

    NSUInteger h = [self.hitCounts[idx] unsignedIntegerValue];
    NSUInteger e = [self.eatenCounts[idx] unsignedIntegerValue];
    if (h == 0 && e == 0) return [arrow stringByAppendingString:@"　·　最近的通知里没命中过"];
    if (h == 0 && e > 0)  return [arrow stringByAppendingFormat:@"　·　⚠️ 被前面的规则吃掉 %lu 条",
                                  (unsigned long)e];
    if (e > 0) return [arrow stringByAppendingFormat:@"　·　改过 %lu 条，另有 %lu 条被前面吃掉",
                       (unsigned long)h, (unsigned long)e];
    return [arrow stringByAppendingFormat:@"　·　改过 %lu 条", (unsigned long)h];
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == kSecProbe)  return 2;                       // 输入 + 结果
    if (section == kSecRules)  return (NSInteger)self.rules.count;
    return self.rules.count ? 1 : 0;                          // 没规则就不显示「清空」
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == kSecProbe) return @"试运行（走的是引擎里同一个函数）";
    if (section == kSecRules && self.rules.count) {
        return [NSString stringWithFormat:@"规则（从上往下执行，共 %lu 条）",
                (unsigned long)self.rules.count];
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == kSecProbe) {
        return @"输入一段文字，看下面这些规则会把它改成什么。"
               @"真实通知里会对「标题」「正文」「副标题」三个字段各套一遍，三个字段互不影响。";
    }
    if (section == kSecRules && self.rules.count) {
        NSMutableString *s = [NSMutableString string];
        if (!self.statsReady) {
            [s appendString:@"正在统计历史命中情况…"];
        } else if (self.scannedCount == 0) {
            [s appendString:@"盒子里还没有历史通知，暂时没法统计命中情况。"];
        } else {
            [s appendFormat:@"统计基于盒子里最近 %ld 条通知的原文："
                            @"「改过 N 条」= 这条规则真的把这些通知的内容改掉了；"
                            @"「被前面吃掉 N 条」= 原文里本来有，但已经被上面的规则先改没了，"
                            @"轮到它时已经匹配不到。",
             (long)self.scannedCount];
        }
        [s appendString:@"\n⚠️ 顺序很重要：想删「限时优惠」这种长词，就得排在只删「限时」的规则之前。"
                      @"点一条规则可以改它的替换内容。"];
        return s;
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == kSecProbe) {
        if (indexPath.row == 0) return 48;
        NSString *text = [self probeDisplayText];
        CGFloat w = tableView.bounds.size.width - 40 - 32;    // insetGrouped 两侧各 20，cell 内再留 32
        if (w < 120) w = 120;
        CGRect r = [text boundingRectWithSize:CGSizeMake(w, CGFLOAT_MAX)
                                      options:NSStringDrawingUsesLineFragmentOrigin
                                   attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:14]}
                                      context:nil];
        return MAX(48, ceil(r.size.height) + 22);
    }
    if (indexPath.section == kSecRules) return kRuleRowHeight;
    return 48;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == kSecProbe) {
        if (indexPath.row == 0) return [self probeFieldCell:tableView];
        return [self probeResultCell:tableView];
    }
    if (indexPath.section == kSecRules) return [self ruleCell:tableView indexPath:indexPath];

    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:kPlainCellID];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                   reuseIdentifier:kPlainCellID];
        c.textLabel.textAlignment = NSTextAlignmentCenter;
        c.textLabel.textColor = [UIColor systemRedColor];
        c.textLabel.font = [UIFont systemFontOfSize:16];
    }
    c.textLabel.text = @"清空全部规则";
    return c;
}

- (UITableViewCell *)probeFieldCell:(UITableView *)tableView {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:kFieldCellID];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                   reuseIdentifier:kFieldCellID];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        UITextField *tf = [[UITextField alloc] init];
        tf.tag = kTagProbeField;
        tf.placeholder = @"输入一段文字，例：限时优惠来啦";
        tf.font = [UIFont systemFontOfSize:15];
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.returnKeyType = UIReturnKeyDone;
        tf.delegate = self;
        [tf addTarget:self action:@selector(onProbeChanged:)
     forControlEvents:UIControlEventEditingChanged];
        [c.contentView addSubview:tf];
        // 🔴 cell 被重建（reloadData / 复用池空了）时，输入框是**新对象** ⇒
        //    必须用 probeText 把用户已经打的字复原，否则他会看到自己输入的内容突然消失。
        tf.text = self.probeText;
        self.probeField = tf;      // 只在建 cell 那一次赋值，复用时不覆盖成别的实例
    }
    return c;
}

- (UITableViewCell *)probeResultCell:(UITableView *)tableView {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:kLabelCellID];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                   reuseIdentifier:kLabelCellID];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        UILabel *l = [[UILabel alloc] init];
        l.tag = kTagProbeResult;
        l.numberOfLines = 0;
        l.font = [UIFont systemFontOfSize:14];
        [c.contentView addSubview:l];
    }
    UILabel *l = (UILabel *)[c.contentView viewWithTag:kTagProbeResult];
    l.text = [self probeDisplayText];
    BOOL nothing = (!self.probeText.length || ![self.probeHitLine hasPrefix:@"命中"]);
    l.textColor = nothing ? [UIColor secondaryLabelColor] : [UIColor labelColor];
    return c;
}

- (UITableViewCell *)ruleCell:(UITableView *)tableView indexPath:(NSIndexPath *)indexPath {
    NBReplaceRuleCell *c = [tableView dequeueReusableCellWithIdentifier:kRuleCellID];
    if (!c) {
        c = [[NBReplaceRuleCell alloc] initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:kRuleCellID];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    if ((NSUInteger)indexPath.row >= self.rules.count) return c;      // 防御：行号越界

    NSDictionary *d = self.rules[(NSUInteger)indexPath.row];
    NSString *from = [d[@"from"] isKindOfClass:[NSString class]] ? d[@"from"] : @"";
    NSString *to   = [d[@"to"]   isKindOfClass:[NSString class]] ? d[@"to"]   : @"";

    c.lineFrom.text = [NSString stringWithFormat:@"#%ld　%@", (long)(indexPath.row + 1), from];
    c.lineTo.text = to.length ? [NSString stringWithFormat:@"→ 替换成「%@」", to]
                              : @"→ 删除（替换成空）";
    c.lineTo.textColor = to.length ? [UIColor secondaryLabelColor] : [UIColor systemRedColor];
    c.lineStat.text = [self detailForRuleAtIndex:(NSUInteger)indexPath.row];

    // 统计行的语气：有问题（和原文一样 / 被前面吃掉）才用颜色喊出来，正常就低调
    NSString *stat = c.lineStat.text ?: @"";
    if ([stat containsString:@"⚠️"]) {
        c.lineStat.textColor = [UIColor systemOrangeColor];
    } else if ([stat containsString:@"改过"]) {
        c.lineStat.textColor = [UIColor systemGreenColor];
    } else {
        c.lineStat.textColor = [UIColor tertiaryLabelColor];
    }
    return c;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
                                forRowAtIndexPath:(NSIndexPath *)indexPath {
    // 🔴 输入框的 frame 只能在这里给：cellForRow 那一刻 tableView 的宽度还不一定算出来了
    //    （viewDidLoad 里 reloadData 时 table 的 frame 还是 CGRectZero）。
    if (indexPath.section != kSecProbe) return;
    if (indexPath.row == 0 && self.probeField) {
        CGSize sz = cell.contentView.bounds.size;
        CGFloat w = sz.width - 32;
        if (w < 60) w = 60;
        self.probeField.frame = CGRectMake(16, 0, w, sz.height);
        self.probeField.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    } else if (indexPath.row == 1) {
        UILabel *l = (UILabel *)[cell.contentView viewWithTag:kTagProbeResult];
        CGSize sz = cell.contentView.bounds.size;
        CGFloat w = sz.width - 32;
        if (w < 60) w = 60;
        l.frame = CGRectMake(16, 11, w, sz.height - 22);
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == kSecProbe) {
        if (indexPath.row == 0) [self.probeField becomeFirstResponder];
        return;
    }
    if (indexPath.section == kSecRules) {
        if ((NSUInteger)indexPath.row >= self.rules.count) return;
        id f = self.rules[(NSUInteger)indexPath.row][@"from"];
        if (![f isKindOfClass:[NSString class]]) return;
        [self askReplacementFor:(NSString *)f atIndex:indexPath.row];
        return;
    }
    [self confirmClear];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
                                            forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section != kSecRules) return;
    if ((NSUInteger)indexPath.row >= self.rules.count) return;      // 防御：行号越界直接不动
    [self.rules removeObjectAtIndex:(NSUInteger)indexPath.row];
    [self persist];
    [self reload];
}

#pragma mark - 输入框

- (void)onProbeChanged:(UITextField *)tf {
    self.probeText = tf.text ?: @"";
    [self refreshProbe];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

@end
