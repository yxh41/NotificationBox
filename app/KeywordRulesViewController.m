#import "KeywordRulesViewController.h"
#import "NotifyStore.h"

#pragma mark - 一行规则（关键词 + 动作徽标）

// 自定义 cell：Default 样式的 detailTextLabel 不显示（本项目在 NotifyCell 栽过一次），
// 这里同样自己画两个 label —— 关键词在左、动作徽标在右。
@interface NBKeywordRuleCell : UITableViewCell
@property (nonatomic, strong) UILabel *kwLabel;
@property (nonatomic, strong) UILabel *badgeLabel;
@end

@implementation NBKeywordRuleCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.kwLabel = [[UILabel alloc] init];
    self.kwLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.kwLabel.textColor = [UIColor labelColor];
    self.kwLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:self.kwLabel];

    // 动作徽标：★ 标星 / ⤓ 折叠 / ★ 标星 · ⤓ 折叠
    self.badgeLabel = [[UILabel alloc] init];
    self.badgeLabel.font = [UIFont systemFontOfSize:12];
    self.badgeLabel.textColor = [UIColor secondaryLabelColor];
    self.badgeLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:self.badgeLabel];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat pad = 16;
    self.kwLabel.frame    = CGRectMake(pad, 10, w - pad * 2 - 110, 24);
    self.badgeLabel.frame = CGRectMake(w - pad - 110, 12, 110, 20);
}

@end

#pragma mark - 规则编辑页

@interface KeywordRulesViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rules;
// 🔴 私有方法在类扩展里声明（本项目惯例，见 ViewController.m 的 alertTitle:text:）：
//    clang 允许同 @implementation 内先调用后定义，但排查时看一眼扩展就知道
//    这个类有哪些出口，不用把整个文件翻一遍。alertTitle:text:kind: 在 onAdd: 里
//    先调用、定义在文件末尾，没有这份声明就是"看不见的依赖"。
- (void)onAdd:(id)sender;
- (void)askActionForKeyword:(NSString *)kw;
- (void)addRuleWithKeyword:(NSString *)kw star:(BOOL)star fold:(BOOL)fold;
- (void)reload;
- (void)persist;
- (void)updateEmptyHint;
- (void)alertTitle:(NSString *)title text:(NSString *)text kind:(BOOL)ok;
@end

@implementation KeywordRulesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"关键词规则";

    // 🔴 上限 20：和 NotifyStore 的闸门同一数字（两处各写一份必然对不上）。
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self action:@selector(onAdd:)];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    // 🔴🔴 不 registerClass:[UITableViewCell class] —— Default 样式的 detailTextLabel 不显示，
    //    而我们要显示"关键词 + 动作"两列 ⇒ 用自定义 cell（NBKeywordRuleCell）。
    [self.table registerClass:[NBKeywordRuleCell class] forCellReuseIdentifier:@"kw"];
    [self.view addSubview:self.table];

    [self reload];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
}

// 从 NotifyStore 读回规范化后的规则（**唯一来源**，自己不解析 settings.plist）。
- (void)reload {
    self.rules = [[NotifyStore keywordRules] mutableCopy];
    [self.table reloadData];
    [self updateEmptyHint];
}

// 写回：全走 NotifyStore（它负责清洗：丢空关键词、丢两个动作都没选的、截到 20 条）。
- (void)persist {
    [NotifyStore saveKeywordRules:self.rules];
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
    l.text = @"还没有关键词规则\n\n\n点右上角 + 添加：命中关键词的通知可以自动标星（★）或自动折叠（从列表收起）。\n\n规则即时生效，不用重启，也不用重新记录。";
    self.table.backgroundView = l;
}

#pragma mark - 增

- (void)onAdd:(id)sender {
    // 🔴 先查上限：满了就直接说，不弹输入框让用户白填一场。
    if (self.rules.count >= 20) {
        [self alertTitle:@"最多 20 条" text:@"关键词规则上限 20 条，删掉一条再加。" kind:NO];
        return;
    }
    __weak typeof(self) wself = self;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"新增关键词规则"
                                                               message:@"命中下面这个关键词时："
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"关键词，如：验证码";
    }];
    UIAlertAction *ok = [UIAlertAction actionWithTitle:@"下一步" style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction * _Nonnull action) {
        NSString *kw = a.textFields.firstObject.text ?: @"";
        // 🔴 去首尾空白：用户手滑多打一个空格，会让规则永远命中不了（还看不出原因）。
        kw = [kw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!kw.length) return;
        [wself askActionForKeyword:kw];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [a addAction:cancel];
    [a addAction:ok];
    [self presentViewController:a animated:YES completion:nil];
}

// 输入关键词后，选这条规则做什么动作（标星 / 折叠 / 两个都做）。
- (void)askActionForKeyword:(NSString *)kw {
    __weak typeof(self) wself = self;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:kw
                                                                  message:@"命中后做什么？"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    // 🔴 iPad 上 action sheet 必须指定锚点，否则崩；iPhone 上这段被忽略。指定到 + 按钮最稳。
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    UIAlertAction *star = [UIAlertAction actionWithTitle:@"★ 标星" style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction * _Nonnull action) {
        [wself addRuleWithKeyword:kw star:YES fold:NO];
    }];
    UIAlertAction *fold = [UIAlertAction actionWithTitle:@"⤓ 折叠" style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction * _NonNull action) {
        [wself addRuleWithKeyword:kw star:NO fold:YES];
    }];
    UIAlertAction *both = [UIAlertAction actionWithTitle:@"★ 标星 · ⤓ 折叠" style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction * _NonNull action) {
        [wself addRuleWithKeyword:kw star:YES fold:YES];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    for (UIAlertAction *x in @[star, fold, both, cancel]) [sheet addAction:x];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)addRuleWithKeyword:(NSString *)kw star:(BOOL)star fold:(BOOL)fold {
    // 🔴 两个动作都没选不可能到这里（动作面板三个选项都至少选一个），双保险挡一道。
    if (!star && !fold) return;
    [self.rules addObject:@{ @"keyword": kw, @"star": @(star), @"fold": @(fold) }];
    [self persist];
    [self reload];
}

#pragma mark - 删（左滑）

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style
                                            forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    [self.rules removeObjectAtIndex:indexPath.row];
    [self persist];
    [self reload];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.rules.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NBKeywordRuleCell *c = [tableView dequeueReusableCellWithIdentifier:@"kw" forIndexPath:indexPath];
    NSDictionary *r = self.rules[indexPath.row];
    c.kwLabel.text = r[@"keyword"];
    BOOL star = [r[@"star"] boolValue];
    BOOL fold = [r[@"fold"] boolValue];
    if (star && fold)      c.badgeLabel.text = @"★ 标星 · ⤓ 折叠";
    else if (star)         c.badgeLabel.text = @"★ 标星";
    else                   c.badgeLabel.text = @"⤓ 折叠";
    return c;
}

#pragma mark - 小工具

- (void)alertTitle:(NSString *)title text:(NSString *)text kind:(BOOL)ok {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
