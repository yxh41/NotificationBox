#import "SoundAppsViewController.h"
#import "NotifyCommon.h"
#import "NotifyStore.h"
#import "NotifyFilter.h"
#import "InstalledApps.h"
#import "SoundFilePickerViewController.h"
#import "AppPickerViewController.h"

// 按 App 分配提示音的总览页（v0.0.28）
//
// 🔴 这一页的数据**只有一个来源** = `[NotifyFilter soundMap]`。
//    它不自己拼字典、也不自己落盘：增删改都走 NotifyFilter 的那三个方法。
//    理由：界面各处各写一份"改 map + 写盘"，迟早出现「这页删了、那页还留着」，
//    而那种错在界面上看不出来（值都在，只是对不上）。
@interface SoundAppsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSString *> *bundles;   // 排好序的 bundle id
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *map;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *nameOf;   // bundle → 显示名

// 内部方法显式声明（-Werror 下"靠定义顺序解析选择器"太脆）
- (void)reload;
- (void)updateEmptyHint;
@end

@implementation SoundAppsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"按 App 分配提示音";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 56;
    [self.view addSubview:self.table];

    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];          // 从子页回来要看到新值（改了音/删了 App）
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
}

- (void)reload {
    self.map = [NotifyFilter soundMap];

    // 显示名：一次枚举，做成字典。枚举不到就用 bundle id 当名字 ——
    // 🔴 绝不能因此把那一行**藏起来**：枚举失败是静默的（越狱环境下常见），
    //    藏起来会让用户以为"我的分配丢了"。
    NSMutableDictionary<NSString *, NSString *> *nm = [NSMutableDictionary dictionary];
    for (InstalledApp *a in [InstalledApps all]) {
        if (a.bundleId.length && a.name.length) nm[a.bundleId] = a.name;
    }
    self.nameOf = nm;

    // 按显示名排（用户找的是"微信"，不是 "com.tencent.xin"）
    NSArray *keys = [[self.map allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSString *na = self.nameOf[a] ?: a;
        NSString *nb = self.nameOf[b] ?: b;
        return [na caseInsensitiveCompare:nb];
    }];
    self.bundles = [NSMutableArray arrayWithArray:keys];

    [self.table reloadData];
    [self updateEmptyHint];
}

- (void)updateEmptyHint {
    if (self.bundles.count) {
        self.table.backgroundView = nil;
        return;
    }
    UILabel *l = [[UILabel alloc] init];
    l.numberOfLines = 0;
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = [UIColor secondaryLabelColor];
    l.font = [UIFont systemFontOfSize:15];
    l.text = @"还没有给任何 App 分配提示音\n\n"
             @"点下面「添加 / 移除 App」选中几个 App，\n"
             @"再点列表里的 App 就能给它单独选一个音。\n\n"
             @"（没分配过的 App 用系统原声）";
    self.table.backgroundView = l;
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)self.bundles.count : 1;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        return self.bundles.count
             ? [NSString stringWithFormat:@"已分配 %lu 个 App", (unsigned long)self.bundles.count]
             : @"已分配";
    }
    return @"添加 / 移除";
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"每个 App 一个音，互不影响。没列在这里的 App 一律用系统原声。";
    }
    return @"「添加 / 移除」里勾上就出现在上面（新加的 App 先用设置页的默认音，"
           @"之后可以在上面逐个改）。";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"sacell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];

    if (ip.section == 1) {
        c.textLabel.text = @"添加 / 移除 App";
        c.textLabel.textColor = [UIColor labelColor];
        c.detailTextLabel.text = @"勾选 = 这个 App 换音";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }

    NSString *b = self.bundles[(NSUInteger)ip.row];
    c.textLabel.text = self.nameOf[b] ?: b;
    // 副标题给"用的是哪个音"：这一行就是这一版存在的全部理由 ——
    // 用户要能一眼看出"微信现在是 a.mp3、QQ 是系统音 1007"。
    // v0.0.31：如果这个 App 单独设过时长，也一并显示 —— 否则"同一份 a.mp3、
    // 微信响 30 秒、QQ 响 8 秒"这件事在总览页完全看不出来，用户只会觉得"时长设置没生效"。
    NSString *limit = [NotifyFilter soundEntryLimitSummary:self.map[b]];
    BOOL custom = ![limit isEqualToString:@"跟随全局"];
    c.detailTextLabel.text = custom
                           ? [NSString stringWithFormat:@"%@ · %@",
                              [NotifyFilter soundEntrySummary:self.map[b]], limit]
                           : [NotifyFilter soundEntrySummary:self.map[b]];
    c.textLabel.textColor = [UIColor labelColor];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 1) {
        // AppPicker 的 SoundMap 模式：勾选/取消直接落盘（点一下就是生效，没有保存按钮）
        [self.navigationController pushViewController:
         [[AppPickerViewController alloc] initWithMode:NBAppPickModeSoundMap] animated:YES];
        return;
    }

    NSString *b = self.bundles[(NSUInteger)ip.row];
    [self.navigationController pushViewController:
     [[SoundFilePickerViewController alloc] initWithBundle:b displayName:(self.nameOf[b] ?: b)]
                                             animated:YES];
}

// 左滑删除 = 移除这个 App 的分配（和进页面点「移除」等价，走同一条写盘路径）
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != 0 || ip.row >= (NSInteger)self.bundles.count) return nil;
    NSString *b = self.bundles[(NSUInteger)ip.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *del = [UIContextualAction
                               contextualActionWithStyle:UIContextualActionStyleDestructive
                               title:@"移除"
                               handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        BOOL ok = [NotifyFilter setSoundEntry:nil forBundle:b];
        if (ok) {
            NBSharedLog(@"SOUNDMAP 移除 %@", b);
            [weakSelf reload];
        }
        done(ok);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end
