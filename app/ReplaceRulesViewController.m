#import "ReplaceRulesViewController.h"
#import "NotifyStore.h"
#import "NotifyCommon.h"

// 内容替换规则：settings.plist 里的 replaceRules = [{from, to}, ...]
// 引擎侧（NotifyFilter applyReplaceRulesTo）按顺序逐条套用，只改**显示**的文字，
// 盒子里存的仍然是原文（记录发生在替换之前），所以替换不会污染历史。

@interface ReplaceRulesViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rules;
- (void)reload;
- (void)onAdd:(id)sender;
- (void)addRuleFrom:(NSString *)from to:(NSString *)to;
- (void)persist;
@end

@implementation ReplaceRulesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"内容替换";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(onAdd:)];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.table registerClass:[UITableViewCell class] forCellReuseIdentifier:@"r"];
    [self.view addSubview:self.table];

    [self reload];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
}

- (void)reload {
    id raw = [NotifyStore settings][@"replaceRules"];
    self.rules = [NSMutableArray array];
    if ([raw isKindOfClass:[NSArray class]]) {
        for (id e in (NSArray *)raw) {
            // 🔴 存进来的东西不一定干净（用户可能手改过 plist），逐项校验再收
            if (![e isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *d = (NSDictionary *)e;
            if (![d[@"from"] isKindOfClass:[NSString class]]) continue;
            [self.rules addObject:d];
        }
    }
    [self.table reloadData];
    [self updateEmptyHint];
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
             @"（盒子里仍然保留原文，方便回溯）";
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

#pragma mark - 添加

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
        [self askReplacementFor:from];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)askReplacementFor:(NSString *)from {
    UIAlertController *b = [UIAlertController
                            alertControllerWithTitle:@"替换成什么"
                                             message:[NSString stringWithFormat:@"「%@」→ ?（留空 = 直接删掉这个词）", from]
                                      preferredStyle:UIAlertControllerStyleAlert];
    [b addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"留空表示删除";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [b addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakB = b;
    [b addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *act) {
        NSString *to = weakB.textFields.firstObject.text ?: @"";
        [self addRuleFrom:from to:to];
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

- (void)askAgain:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"没填内容"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) { [self onAdd:nil]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 表格

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.rules.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.rules.count ? @"按顺序逐条套用（左滑删除）" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"r" forIndexPath:indexPath];
    NSDictionary *d = self.rules[(NSUInteger)indexPath.row];
    NSString *from = d[@"from"] ?: @"";
    NSString *to = d[@"to"] ?: @"";
    c.textLabel.text = from;
    c.detailTextLabel.text = to.length ? [NSString stringWithFormat:@"→ %@", to] : @"→ （删除）";
    c.detailTextLabel.textColor = to.length ? [UIColor secondaryLabelColor] : [UIColor systemRedColor];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
                                            forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if ((NSUInteger)indexPath.row >= self.rules.count) return;      // 防御：行号越界直接不动
    [self.rules removeObjectAtIndex:(NSUInteger)indexPath.row];
    [self persist];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    [self updateEmptyHint];
}

@end
