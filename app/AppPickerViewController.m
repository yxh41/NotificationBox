#import "AppPickerViewController.h"
#import "InstalledApps.h"
#import "AppIconLoader.h"
#import "NotifyStore.h"
#import "NotifyCommon.h"

// 可搜索多选的 App 选择器。实现要点都在注释里，因为这里每一条都对应一个会静默出错的地方。

static NSString *NBTrim(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

// 把 App 图标缩放到列表用的尺寸。
// 🔴 不缩放的后果：图标原始尺寸 60x60 甚至 180x180，UITableViewCell 的 imageView
//    会按图片尺寸撑开 ⇒ 行高乱跳，列表看起来像坏了。而且不同 App 图标尺寸不一致，
//    不统一就更乱。
static UIImage *NBScaledIcon(UIImage *img, CGFloat side) {
    if (!img) return nil;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc]
                                  initWithSize:CGSizeMake(side, side)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, side, side)];
    }];
}

@interface AppPickerViewController () <UITableViewDataSource, UITableViewDelegate,
                                       UISearchResultsUpdating>
@property (nonatomic, assign) NBAppPickMode mode;
@property (nonatomic, copy)   NSString *settingsKey;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<InstalledApp *> *allApps;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@property (nonatomic, strong) NSArray<InstalledApp *> *selRows;    // 已选（命中搜索的）
@property (nonatomic, strong) NSArray<InstalledApp *> *otherRows;  // 未选（命中搜索的）
@property (nonatomic, copy)   NSString *query;
@property (nonatomic, assign) BOOL loading;

// 🔴 内部类方法也要显式声明：CI 是 -Werror，而 [[self class] someClassMethod]
//    这种写法 clang 不知道 [self class] 具体是哪个类 ⇒ 报
//    "no known class method for selector"。所以调用点一律写类名，声明也要补齐。
+ (NSString *)keyForMode:(NBAppPickMode)mode;
+ (NSString *)titleForMode:(NBAppPickMode)mode;

- (void)rebuild;
- (void)persist;
- (void)toggle:(InstalledApp *)app;
- (void)onClear:(id)sender;
- (void)onClose:(id)sender;
- (InstalledApp *)appAt:(NSIndexPath *)ip;
@end

@implementation AppPickerViewController

+ (NSString *)keyForMode:(NBAppPickMode)mode {
    switch (mode) {
        case NBAppPickModeWhitelist: return @"whitelist";
        case NBAppPickModeBlacklist: return @"blacklist";
        case NBAppPickModeSpeak:     return NB_KEY_SPEAK_APPS;
        case NBAppPickModeDnd:       return NB_KEY_DND_APPS;
        case NBAppPickModeSound:     return NB_KEY_SOUND_APPS;
    }
    return @"whitelist";
}

+ (NSString *)titleForMode:(NBAppPickMode)mode {
    switch (mode) {
        case NBAppPickModeWhitelist: return @"白名单";
        case NBAppPickModeBlacklist: return @"黑名单";
        case NBAppPickModeSpeak:     return @"朗读限定 App";
        case NBAppPickModeDnd:       return @"免打扰生效的 App";
        case NBAppPickModeSound:     return @"换提示音的 App";
    }
    return @"选择 App";
}

+ (NSUInteger)selectedCountForMode:(NBAppPickMode)mode {
    NSDictionary *d = [NotifyStore settings];
    return [NBStringArray(d[[AppPickerViewController keyForMode:mode]]) count];
}

- (instancetype)initWithMode:(NBAppPickMode)mode {
    self = [super init];
    if (self) {
        _mode = mode;
        _settingsKey = [AppPickerViewController keyForMode:mode];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [AppPickerViewController titleForMode:self.mode];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    // 🔴 这个页面**点一下就是生效**，没有「保存」按钮。
    //    理由：保存按钮是可以忘的，而"忘了点保存"之后用户看到的是
    //    "我明明选了怎么不生效" —— 又是一次无从排查的静默失败。
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"清空"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onClear:)];

    self.selected = [NSMutableSet set];
    id cur = [NotifyStore settings][self.settingsKey];
    for (NSString *b in NBStringArray(cur)) [self.selected addObject:b];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 60;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.table];

    // 搜索放 nav 里，比自己塞 tableHeaderView 稳（后者要手工维护 header 高度）
    UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    sc.searchResultsUpdater = self;
    sc.obscuresBackgroundDuringPresentation = NO;
    sc.searchBar.placeholder = @"搜索名称或 bundle id";
    self.navigationItem.searchController = sc;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    // 🔴 不在 viewDidLoad 里同步枚举。
    //    workspace 那条路很快，但**走目录扫描兜底时要遍历
    //    /var/containers/Bundle/Application 下几百个 UUID 目录**，能卡一两秒。
    //    同步做的话页面在这个时间窗里是一片空白（主线程被占，界面根本没画出来），
    //    用户会以为"这个功能点进去就死了"。
    //    所以先让页面画出来（显示"正在枚举"），下一轮 runloop 再枚举。
    self.loading = YES;
    self.allApps = @[];
    [self rebuild];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.allApps = [InstalledApps all];
        self.loading = NO;
        [self rebuild];
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
}

#pragma mark - 数据

- (void)rebuild {
    NSString *q = NBTrim(self.query);

    NSMutableArray *sel = [NSMutableArray array];
    NSMutableArray *other = [NSMutableArray array];

    for (InstalledApp *a in self.allApps) {
        if (q.length) {
            // 🔴 名称和 bundle id 都要匹配：用户有时记得名字（"微信"），
            //    有时只记得半截 id（"tencent"）。只匹配一种就经常搜不到。
            BOOL hit = ([a.name rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound)
                    || ([a.bundleId rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound);
            if (!hit) continue;
        }
        if ([self.selected containsObject:a.bundleId]) [sel addObject:a];
        else [other addObject:a];
    }

    self.selRows = sel;
    self.otherRows = other;
    [self.table reloadData];
    [self updateBackground];
    [self updateTitle];
}

- (void)updateTitle {
    // 标题里带数量：这是用户唯一能在"退出本页后"知道配了几个的地方之一，
    // 但真正长期可见的是设置页那一行的副标题（见 SettingsViewController）。
    self.navigationItem.title = [NSString stringWithFormat:@"%@（已选 %lu）",
                                 [AppPickerViewController titleForMode:self.mode],
                                 (unsigned long)self.selected.count];
}

- (void)updateBackground {
    if (self.selRows.count + self.otherRows.count > 0) {
        self.table.backgroundView = nil;
        return;
    }
    UILabel *l = [[UILabel alloc] init];
    l.numberOfLines = 0;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:13];
    l.textColor = [UIColor secondaryLabelColor];
    if (self.loading) {
        l.text = @"正在枚举已安装 App…";
    } else if (NBTrim(self.query).length) {
        l.text = @"没有匹配的 App\n\n换个关键词，或者直接搜 bundle id 的一段";
    } else {
        l.text = [NSString stringWithFormat:
                  @"没枚举到任何 App\n\n"
                  @"说明「已安装 App 列表」这条链路没走通。\n"
                  @"请回设置页点「App 枚举诊断」看哪条路失败。\n\n"
                  @"%@", [InstalledApps diagReport]];
    }
    self.table.backgroundView = l;
}

- (void)persist {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[NotifyStore settings]];
    // 排序后再存：同一组选择每次写出来的文件都一样，方便对拍
    NSArray *arr = [[self.selected allObjects] sortedArrayUsingSelector:@selector(compare:)];
    if (arr.count) d[self.settingsKey] = arr;
    else [d removeObjectForKey:self.settingsKey];     // 空就删键，别留空数组
    [NotifyStore saveSettings:d];
}

- (void)toggle:(InstalledApp *)app {
    if (!app.bundleId.length) return;
    if ([self.selected containsObject:app.bundleId]) {
        [self.selected removeObject:app.bundleId];
    } else {
        [self.selected addObject:app.bundleId];
    }
    [self persist];
    [self rebuild];       // 重建而不是只 reload：选中的要立刻跳到上面那一组
}

- (InstalledApp *)appAt:(NSIndexPath *)ip {
    BOOL twoGroups = (self.selRows.count > 0);
    if (twoGroups && ip.section == 0) {
        return ip.row < (NSInteger)self.selRows.count ? self.selRows[ip.row] : nil;
    }
    return ip.row < (NSInteger)self.otherRows.count ? self.otherRows[ip.row] : nil;
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return self.selRows.count ? 2 : 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (self.selRows.count) {
        return section == 0 ? (NSInteger)self.selRows.count : (NSInteger)self.otherRows.count;
    }
    return (NSInteger)self.otherRows.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (self.selRows.count) {
        if (section == 0) {
            return [NSString stringWithFormat:@"已选 %lu 个（点一下取消）",
                    (unsigned long)self.selRows.count];
        }
        return @"其它 App";
    }
    return self.otherRows.count
        ? [NSString stringWithFormat:@"点一下加入（共 %lu 个）", (unsigned long)self.otherRows.count]
        : nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    // 只在最后一节显示：这页的使用口径每个模式都不一样，
    // 尤其是「空列表 = 全部 App」这条 —— 不说清楚，用户会以为"没选就是没配、等于关闭"。
    NSInteger last = [tv numberOfSections] - 1;
    if (section != last) return nil;
    switch (self.mode) {
        case NBAppPickModeDnd:
            // 🔴 空列表 = 全部 App（和其它名单一致）
            return @"这个列表为空 = 全部 App 都在免打扰时段内不弹。"
                    "时段本身在设置页填（开始/结束时间，可跨零点）。";
        case NBAppPickModeSound:
            // 🔴 空列表 = **不生效**（与其它名单相反，必须写清楚）
            return @"⚠️ 这个列表为空 = 换提示音**不生效**（实验功能不会一次性改掉所有 App）。"
                    "先只选一个 App 试，确认能听到声音后再加别的。";
        case NBAppPickModeSpeak:
            return @"这个列表为空 = 全部 App 都朗读。";
        case NBAppPickModeWhitelist:
            return @"这个列表为空 = 全部放行。一旦选了，就等于「只保留这些 App」，其它全部不弹（有杀伤力，慎重）。";
        case NBAppPickModeBlacklist:
            return @"选上的 App 通知不会被弹出，但仍然会记进盒子里。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"app";
    // 🔴 必须手动 initWithStyle:Subtitle。
    //    用 registerClass:[UITableViewCell class] 建出来的是 Default 样式，
    //    detailTextLabel 根本不显示 —— 而且样式在注册那一刻定死，运行期改不了。
    //    （v0.0.9 就是因为这个，列表只显示标题不显示正文。）
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                   reuseIdentifier:cid];
    }

    InstalledApp *a = [self appAt:ip];
    if (!a) return c;

    BOOL on = [self.selected containsObject:a.bundleId];

    c.textLabel.text = a.name.length ? a.name : a.bundleId;
    c.textLabel.font = [UIFont systemFontOfSize:15];

    NSMutableString *sub = [NSMutableString stringWithString:a.bundleId];
    if (a.noteCount > 0) {
        [sub appendFormat:@"  ·  %ld 条通知", (long)a.noteCount];
    }
    if (a.onlyInHistory) {
        [sub appendString:@"  ·  仅历史记录"];
    }
    c.detailTextLabel.text = sub;
    c.detailTextLabel.font = [UIFont systemFontOfSize:11];
    c.detailTextLabel.textColor = a.onlyInHistory ? [UIColor systemOrangeColor]
                                                  : [UIColor secondaryLabelColor];

    c.imageView.image = NBScaledIcon([AppIconLoader iconForBundle:a.bundleId], 32);

    c.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    c.tintColor = [UIColor systemBlueColor];
    // 🔴 只加勾不够。长列表里勾在右边、名称在左边，眼睛要来回扫才数得清选了几个；
    //    整行给个淡蓝底，滚动时一眼就知道哪些已经在名单里。
    c.backgroundColor = on ? [[UIColor systemBlueColor] colorWithAlphaComponent:0.12]
                           : [UIColor secondarySystemGroupedBackgroundColor];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    InstalledApp *a = [self appAt:ip];
    if (a) [self toggle:a];
}

#pragma mark - 搜索

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    self.query = sc.searchBar.text;
    [self rebuild];
}

#pragma mark - 动作

- (void)onClear:(id)sender {
    if (self.selected.count == 0) return;
    UIAlertController *a = [UIAlertController
                            alertControllerWithTitle:@"清空选择"
                                             message:[NSString stringWithFormat:
                                                      @"会清掉 %@ 里全部 %lu 个 App。\n"
                                                      @"（其它设置不受影响）",
                                                      [AppPickerViewController titleForMode:self.mode],
                                                      (unsigned long)self.selected.count]
                                      preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"清空"
                                         style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *act) {
        [self.selected removeAllObjects];
        [self persist];
        [self rebuild];
    }]];
    a.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)onClose:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
