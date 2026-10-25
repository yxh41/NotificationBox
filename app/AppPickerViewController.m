#import "AppPickerViewController.h"
#import "InstalledApps.h"
#import "AppIconLoader.h"
#import "NotifyStore.h"
#import "NotifyCommon.h"
// v0.0.28：SoundMap 模式的增删改**只走引擎**（NotifyFilter 的三个方法），
// 页面自己不许拼 soundMap 字典 —— 理由见 NotifyFilter.h 那段注释。
#import "NotifyFilter.h"

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
+ (NSDictionary *)defaultSoundEntry;

- (void)rebuild;
- (void)persist;
- (void)persistSoundMap;
- (void)toggle:(InstalledApp *)app;
- (void)alertNoDefaultSound;
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
        // 🔴🔴 SoundMap 模式返回的是**字典**的键名，不是数组的键名。
        //    这个返回值只有一个合法用途：**显示 / 诊断**（比如日志里说清"改的是哪个键"）。
        //    ⛔ 绝不能拿它去 `d[key] = 数组` —— 那样会用一个数组盖掉整份映射，
        //    而且界面上看不出异常（值还在、只是变成读不出来的形状）⇒ 所有 App 一起哑。
        //    写盘一律走 persistSoundMap（内部只调 NotifyFilter 的 setSoundEntry:）。
        case NBAppPickModeSoundMap:  return NB_KEY_SOUND_MAP;
        // v0.0.51：连记录都不要。普通数组键，和 speak/dnd 同族。
        case NBAppPickModeNoRecord:  return NB_KEY_NO_RECORD_APPS;
    }
    return @"whitelist";
}

+ (NSString *)titleForMode:(NBAppPickMode)mode {
    switch (mode) {
        case NBAppPickModeWhitelist: return @"白名单";
        case NBAppPickModeBlacklist: return @"黑名单";
        case NBAppPickModeSpeak:     return @"朗读限定 App";
        case NBAppPickModeDnd:       return @"免打扰生效的 App";
        case NBAppPickModeSoundMap:  return @"给哪些 App 换提示音";
        // v0.0.51：标题说清"不记录"和黑名单（不推送）不是一回事
        case NBAppPickModeNoRecord:  return @"不记录的 App";
    }
    return @"选择 App";
}

// 新勾上的 App 用什么音？= 设置页那份**默认提示音**（全局 soundFile / soundID）。
//
// 🔴 返回 nil 的语义是「用户还没配默认音」，调用方**必须据此拒绝添加并提示**。
//    为什么不能"先建一条空记录、让他之后自己改"：
//    空壳 entry（`{file:@""}` 之类）在判定里会被 NBSanitizedSoundMap 过滤掉，
//    过滤掉就等于"没有这条记录"⇒ 用户勾了、界面打了勾、却什么都没有。
//    而如果哪天净化逻辑漏了，空壳会让 playCustomSoundForBundle 返回 YES 却没出声
//    ⇒ 掐掉系统原声 ⇒ **通知变哑**（v0.0.21 那个症状）。两头都不划算，所以宁可不加。
+ (NSDictionary *)defaultSoundEntry {
    NSDictionary *d = [NotifyStore settings];

    // 🔴 文件优先，与判定口径逐字一致（soundVerdictForBundle 里也是先看文件再看 ID）。
    //    这里**还要多查一步"文件在不在"**：判定阶段会把它判成 BadFile ⇒ 放原声，
    //    也就是说"文件不在"的默认音会让新加的 App 静默地不换音。与其造一堆这种记录，
    //    不如在这里就告诉用户"先去选个音"。
    NSString *f = NBTrim(d[NB_KEY_SOUND_FILE]);
    if (f.length && NBIsSafeSoundFileName(f) && NBIsSoundFileExt(f)) {
        NSString *p = NBSoundFilePath(f);
        if (p && [[NSFileManager defaultManager] fileExistsAtPath:p]) {
            return @{NB_KEY_SOUND_ENTRY_FILE: f};
        }
    }

    // 其次系统音 ID（1000~1035，与判定里的区段校验同一区间）。
    // 🔴 用 NSScanner 严格解析：[@"1007abc" integerValue] 也是 1007，
    //    而那个值一旦被当成 ID 播出去，用户听到的是"莫名其妙的音"。
    id iv = d[NB_KEY_SOUND_ID];
    NSInteger sid = 0;
    if ([iv isKindOfClass:[NSNumber class]]) {
        sid = [(NSNumber *)iv integerValue];
    } else if ([iv isKindOfClass:[NSString class]]) {
        NSScanner *sc = [NSScanner scannerWithString:NBTrim((NSString *)iv)];
        if (!([sc scanInteger:&sid] && sc.isAtEnd)) sid = 0;
    }
    if (sid >= 1000 && sid <= 1035) return @{NB_KEY_SOUND_ENTRY_ID: @(sid)};
    return nil;
}

+ (NSUInteger)selectedCountForMode:(NBAppPickMode)mode {
    // 🔴 SoundMap 模式**不能**走 NBStringArray：那个键存的是字典（bundle → 音），
    //    不是数组。按数组读会得到 0 ⇒ 设置页永远显示"未分配"，而实际上配了一堆 ——
    //    用户会以为自己的配置丢了（这正是这一版最容易踩的显示坑）。
    if (mode == NBAppPickModeSoundMap) return [[NotifyFilter soundMap] count];
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
    if (self.mode == NBAppPickModeSoundMap) {
        // v0.0.28：选中集合的来源是 **map 的键**（每个键 = 一个有自己的音的 App），
        // 不是某个数组。读的时候也必须走 [NotifyFilter soundMap]（净化过的），
        // 否则一条脏数据会在界面上显示成"已勾选"，而判定那边根本没把它当回事。
        for (NSString *b in [NotifyFilter soundMap]) [self.selected addObject:b];
    } else {
        id cur = [NotifyStore settings][self.settingsKey];
        for (NSString *b in NBStringArray(cur)) [self.selected addObject:b];
    }

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
    // SoundMap 模式写的是**映射**，不是数组 ⇒ 单独一条路（见 persistSoundMap 注释）
    if (self.mode == NBAppPickModeSoundMap) {
        [self persistSoundMap];
        return;
    }
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[NotifyStore settings]];
    // 排序后再存：同一组选择每次写出来的文件都一样，方便对拍
    NSArray *arr = [[self.selected allObjects] sortedArrayUsingSelector:@selector(compare:)];
    if (arr.count) d[self.settingsKey] = arr;
    else [d removeObjectForKey:self.settingsKey];     // 空就删键，别留空数组
    [NotifyStore saveSettings:d];
}

// v0.0.28：把"这一页的勾选集合"翻译成 soundMap 的增删。
//
// 做法是**做差**，而不是"清空重建"：
//   · 新勾上、原来没有的  ⇒ setSoundEntry:默认音
//   · 原来有、现在取消的  ⇒ setSoundEntry:nil（删）
//   · 两边都有的          ⇒ **一个字都不动**
//
// 🔴 第三条是这一版的关键。如果改成"先全删再按 current 重建"，
//    那么用户只是进来改了另一个 App 的勾，回头发现自己给微信单独选的那个 a.mp3
//    被重置成默认音了 —— 而且没有任何提示，他只会觉得"这功能记不住东西"。
//    ⇒ 已经存在的 entry 必须原样保留，只有"这次新出现的键"才套默认音。
- (void)persistSoundMap {
    NSDictionary *old = [NotifyFilter soundMap];
    NSDictionary *def = [AppPickerViewController defaultSoundEntry];

    NSUInteger added = 0, removed = 0, failed = 0;

    for (NSString *b in self.selected) {
        if (old[b]) continue;                       // 已有 ⇒ 保留它自己的音，不动
        if (!def) { failed++; continue; }            // 没默认音 ⇒ 不建空壳（见 defaultSoundEntry）
        if ([NotifyFilter setSoundEntry:def forBundle:b]) added++;
        else failed++;
    }
    for (NSString *b in old) {
        if ([self.selected containsObject:b]) continue;
        if ([NotifyFilter setSoundEntry:nil forBundle:b]) removed++;
        else failed++;
    }

    // 🔴 写失败必须说出来，不许假装成功：界面上勾已打上、磁盘上没写进去，
    //    用户下次进来勾又没了 —— 那是最难查的一类"设置不保存"。
    if (failed) {
        NBSharedLog(@"SOUNDMAP 分配有 %lu 项写盘失败（成功 新增%lu 删除%lu）",
                    (unsigned long)failed, (unsigned long)added, (unsigned long)removed);
        // 只在没有别的弹窗在显示时弹：连点几下失败会叠出一摞同样的 alert
        if (self.presentedViewController == nil) {
            UIAlertController *al = [UIAlertController
                                     alertControllerWithTitle:@"有分配没保存成功"
                                                      message:[NSString stringWithFormat:
                                                               @"新增 %lu 个、移除 %lu 个成功，但有 %lu 个失败。\n"
                                                               @"设置文件可能不可写，请重试；"
                                                               @"如果每次都失败，去设置页看「日志」里搜 SOUNDMAP。",
                                                               (unsigned long)added,
                                                               (unsigned long)removed,
                                                               (unsigned long)failed]
                                               preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"知道了"
                                                  style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:al animated:YES completion:nil];
        }
    } else if (added || removed) {
        NBSharedLog(@"SOUNDMAP 分配 +%lu -%lu（现共 %lu 个 App）",
                    (unsigned long)added, (unsigned long)removed,
                    (unsigned long)[[NotifyFilter soundMap] count]);
    }
}

- (void)toggle:(InstalledApp *)app {
    if (!app.bundleId.length) return;
    BOOL on = [self.selected containsObject:app.bundleId];

    // 🔴 v0.0.28：SoundMap 模式下"加进来"= 立刻要给这个 App 一条分配，
    //    而分配里必须有个真能播的音。没有默认音时**不许加**，并且当场说清去哪配 ——
    //    否则用户勾上、打了勾、退出、发现什么都没发生（这一版最容易造的静默失败）。
    if (!on && self.mode == NBAppPickModeSoundMap &&
        ![AppPickerViewController defaultSoundEntry]) {
        [self alertNoDefaultSound];
        return;
    }

    if (on) {
        [self.selected removeObject:app.bundleId];
    } else {
        [self.selected addObject:app.bundleId];
    }
    [self persist];
    [self rebuild];       // 重建而不是只 reload：选中的要立刻跳到上面那一组
}

// 没有默认音时的提示。文案必须给出**两条具体路径**，只说"先去配置"等于没说。
- (void)alertNoDefaultSound {
    UIAlertController *al = [UIAlertController
                             alertControllerWithTitle:@"还没有默认提示音"
                                              message:@"给一个 App 换音，得先有一个「从哪个音开始」的答案。\n\n"
                                                      @"回设置页，二选一：\n"
                                                      @"· 在「默认提示音 ID」里填 1000~1035 之间的一个数；\n"
                                                      @"· 或者在「默认提示音文件」里选一个 wav / mp3。\n\n"
                                                      @"配好之后再回来勾 App，新加的 App 先用这个音，"
                                                      @"之后可以逐个改成别的。"
                                       preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    // 选择器是盖在设置页上面的，pop 回根就是设置页 —— 少走两步
    [al addAction:[UIAlertAction actionWithTitle:@"回设置页去配"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        [self.navigationController popToRootViewControllerAnimated:YES];
    }]];
    [self presentViewController:al animated:YES completion:nil];
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
        case NBAppPickModeSoundMap:
            // 🔴 v0.0.28：语义变了 —— 这里勾上 ≠ 立刻生效，还要看总开关。
            //    旧文案（v0.0.21~27）说的是"名单空 = 不生效"，那句现在仍然对，
            //    但只讲一半会让人以为"勾了就一定响"。两件事必须一起说。
            return @"勾上 = 这个 App 有自己的音（先用设置页的默认音，之后在上一个页面里逐个改）。\n"
                    "没勾的 App 一律用系统原声。\n\n"
                    "⚠️ 还要满足两个前提才会真的响：\n"
                    @"· 设置页的「按 App 换提示音」总开关是开的；\n"
                    @"· 这一个 App 的 entry 里那个音确实能用（文件在 / ID 在 1000~1035）。";
        case NBAppPickModeSpeak:
            return @"这个列表为空 = 全部 App 都朗读。";
        case NBAppPickModeWhitelist:
            return @"这个列表为空 = 全部放行。一旦选了，就等于「只保留这些 App」，其它全部不弹（有杀伤力，慎重）。";
        case NBAppPickModeBlacklist:
            return @"选上的 App 通知不会被弹出，但仍然会记进盒子里。";
        // v0.0.51：必须说清两件事——空列表 = 全部记录；勾了**照弹**（只不记）。
        //     不说第二件，用户会以为这是"第二个黑名单"（又拦呈现又拦记录），
        //     而两者的分工（v0.0.8 立的口径）是这个插件记录层的基本假设。
        case NBAppPickModeNoRecord:
            return @"这个列表为空 = 全部 App 都正常记录。\n"
                    "选上的 App 连记录都不落库（盒子里不会留下任何痕迹），"
                    "但通知照常弹出、朗读/换音/替换都照跑 —— 这和「黑名单」不一样："
                    "黑名单只是不弹，记录仍然在盒子里看得到。";
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
    // SoundMap 模式的"清空"后果和其它名单不一样：这里删的是**每个 App 自己的音**，
    // 删完全部退回系统原声（不是"变成全部生效"）。说法必须对着后果写。
    NSString *msg = (self.mode == NBAppPickModeSoundMap)
        ? [NSString stringWithFormat:
           @"会把 %lu 个 App 各自的音全部移除，它们都退回系统原声。\n"
           @"（总开关、默认提示音、其它设置都不动）",
           (unsigned long)self.selected.count]
        : [NSString stringWithFormat:
           @"会清掉 %@ 里全部 %lu 个 App。\n（其它设置不受影响）",
           [AppPickerViewController titleForMode:self.mode],
           (unsigned long)self.selected.count];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"清空选择"
                                                              message:msg
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
