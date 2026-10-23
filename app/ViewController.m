#import "ViewController.h"
#import "NotifyStore.h"
#import "NotifyCommon.h"
#import "SettingsViewController.h"
#import "NotifyCell.h"
#import "AppIconLoader.h"

// 🔴 盒子 App：读 NotifyStore 的 SQLite，展示通知列表
//    - 顶部横向 App 图标栏（抖音聊天页那种）：点击筛选对应 bundle
//    - 时间分段：今天 / 近7天 / 全部
//    - 搜索框：标题/正文模糊搜
//    - 列表：图标占位 + 标题 + 正文 + 时间
//
// ⚠️ TODO（真机）：App 图标用 LSApplicationProxy 取
//    `[[LSApplicationProxy applicationProxyForIdentifier:bid] iconDataForVariant:...]`
//    这里先用「bundle 末段首字母 + 色块」占位。

@interface ViewController ()
@property (nonatomic, strong) UIScrollView *iconBar;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UISegmentedControl *timeSeg;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, strong) NSArray<NSString *> *bundles;
@property (nonatomic, copy)   NSString *filterBundle;   // nil = 全部
@property (nonatomic, copy)   NSString *searchText;

- (void)onDiag:(id)sender;
- (void)onSettings:(id)sender;
- (void)showText:(NSString *)text title:(NSString *)title;
- (NSString *)keyLinesFrom:(NSString *)text;
- (NSString *)selLinesFrom:(NSString *)text;
- (NSString *)probeLinesFrom:(NSString *)text;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"消息盒子";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // 在同一日志里打一条「App 活着」，用来和 tweak 的日志对照（见 NotifyStore.h 注释）
    [NotifyStore markAppAlive];
    // 诊断入口：把 tweak.log 尾部搬进 App，免去用 Filza 翻文件
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"诊断"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onDiag:)];
    // 🔴 v0.0.8：设置留在自己 App 里，不再往设置 App 装 PreferenceLoader 载荷
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"设置"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onSettings:)];
    [self buildUI];
    [self loadData];
}

- (void)onSettings:(id)sender {
    SettingsViewController *vc = [[SettingsViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - 诊断

- (void)onDiag:(id)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"诊断"
                                                                  message:@"选择要查看的内容"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    // 结论行优先：日志动辄 9KB，全量截图很难抓重点
    [sheet addAction:[UIAlertAction actionWithTitle:@"环境自检（不依赖日志）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[NotifyStore envCheck] title:@"环境自检"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"只看结论行（推荐）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[self keyLinesFrom:[NotifyStore logText:20000]] title:@"结论行"];
    }]];
    // 🔴 v0.0.20：探针数据单独开一个入口。
    //    为什么不能只靠结论行：
    //      ① 结论行只看**尾部 20KB**，而探针是**开机那一刻**打的 —— 手机跑几个小时后
    //         那几行早被挤出窗口了，改了关键词也照样看不到（这是"两个独立的丢数据原因"，
    //         只修关键词等于只修了一半）；
    //      ② 探针行很长（几十个属性名 + 类型编码），混在结论行里会把别的判据挤出去。
    //    窗口取 200KB（日志轮转阈值 512KB，足够覆盖一次开机到现在的全部内容）。
    [sheet addAction:[UIAlertAction actionWithTitle:@"探针数据（PROBE，换提示音要用）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[self probeLinesFrom:[NotifyStore logText:200000]] title:@"探针数据"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"方法清单（SEL+ENC）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[self selLinesFrom:[NotifyStore logText:60000]] title:@"方法清单"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"tweak 日志（尾部 20KB）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[NotifyStore logText:20000] title:@"tweak 日志"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"数据库自检"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[NotifyStore debugSummary] title:@"数据库自检"];
    }]];
    // 🔴 取图标在越狱环境里没有保证成功的路，失败又是静默的（退化成首字母）。
    //    这一项直接告诉你：A/B/C 哪条路走通了、哪条为什么没通。
    [sheet addAction:[UIAlertAction actionWithTitle:@"图标诊断（A/B/C 哪条通）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[AppIconLoader diagReport] title:@"图标诊断"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"清空图标缓存并重取"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [AppIconLoader clearCache];
        [self loadData];
        [self showText:@"缓存已清空，列表已重取。\n再看一次「图标诊断」。" title:@"图标缓存"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    // iPad 上 actionSheet 必须给 popover 锚点
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

// 只挑 SEL/ENC 行：这就是 v0.0.4 要量回来的「精确方法签名」
- (NSString *)selLinesFrom:(NSString *)text {
    if (!text.length) return @"(空)";
    NSArray *all = [text componentsSeparatedByString:@"\n"];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *line in all) {
        if ([line containsString:@"SEL "] || [line containsString:@"候选"] ||
            [line containsString:@"BBServer 共"]) {
            // 去掉时间戳前缀，截图更省宽度
            NSRange r = [line rangeOfString:@"]"];
            if (r.location != NSNotFound && r.location + 1 < line.length) {
                [keep addObject:[line substringFromIndex:r.location + 1]];
            } else {
                [keep addObject:line];
            }
        }
    }
    if (!keep.count) {
        return @"没有 SEL 行 —— 要么日志被截断，要么 BBServer 不在这个进程。\n先看「只看结论行」。";
    }
    return [NSString stringWithFormat:@"共 %lu 条（ENC 里 v=void 返回，@=对象，Q=unsigned long long，B=BOOL）\n\n%@",
            (unsigned long)keep.count, [keep componentsJoinedByString:@"\n"]];
}

// 🔴🔴 v0.0.17：关键词表压成**一条带哨兵前缀的字面量**，不再用数组字面量。
//
// 为什么非改不可：校验脚本只能"在 App 二进制里找子串"，它要判的是
// 「DELAY 在不在筛选表里」，但实际能判的只有「App 里有没有出现过 DELAY 这个词」。
// 而设置页的帮助文案里早就写着「如果日志里出现 DELAY-MISS…我按 PROBEDATE 那行…」
// ⇒ **在完全没有筛选词的 v0.0.16 上，这条判据也是绿的（假通过）**。
// 假通过比没判据更坏：它会让我以为已经修好了。
// 加成哨兵前缀后，脚本能精确定位"表里有哪些词"，判据才等于变异域。
//
// 额外好处：全部关键词集中一处，以后加新留痕只改这一行，不会漏。
//
// 🔴🔴 v0.0.20：把已经死掉的 DELAY / PROBEDATE 换成 PROBE。
//   这一条又是"留痕被自己筛掉"，和 v0.0.17 的 DELAY# 是**同一个病，第三次了**：
//   探针所有实质数据都以 PROBE 开头（`PROBE BBBulletin 名字: …` /
//   `PROBE#1 tag=PB :: sound=<BBSound> …` / `PROBE 当前队列标签 = …`），
//   而表里一个能匹配它们的词都没有 ⇒ 结论行里只剩
//   `=== PROBE 开始 dump 类结构 ===` 和 `=== PROBE dump 结束 ===` 两行，
//   **这两行恰好不含任何数据**。
//   现场看起来就是"探针跑了、什么都没量到"，实际数据一直在日志里。
//   ⇒ 「按 App 换提示音」等 PROBE 数据等了好几版，根因在这里。
//   🔴 教训升级版：**加了新留痕，必须同时问"它能通过筛选吗"**；
//      而"筛选表里有旧词"不等于"新留痕能被捞出来"。
static NSString * const kNBKeyLineTable =
    @"NBKEYLINES|===|-->|hit#|P#|drop |DROP#|REPL#|PROBE|DND#|SOUND#|SD#|APP-ALIVE|G3 首次|失败|!!!|探针";

static NSArray<NSString *> *NBKeyLineKeywords(void) {
    return [kNBKeyLineTable componentsSeparatedByString:@"|"];
}

// v0.0.20：只挑探针行。
// 判据域 = 含 "PROBE" 的行；变异域 = 探针的全部输出（NotifyProbe.m 里每一行都以 PROBE 开头）
// ⇒ 两者严格对齐。这正是上一版"关键词表漏词"要买的课。
// 单独开入口、而不是塞进结论行，有两个**互相独立**的原因：
//   ① 结论行只看尾部 20KB，而探针是**开机那一刻**打的 —— 手机跑几小时后早被挤出窗口，
//      光把关键词补进表里也照样看不见（只修一半 = 还是看不到）；
//   ② 探针行很长（几十个属性名 + 类型编码），混进结论行会把 DROP#/REPL# 这些判据挤掉。
- (NSString *)probeLinesFrom:(NSString *)text {
    if (!text.length) return @"(空)";
    NSArray *all = [text componentsSeparatedByString:@"\n"];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *line in all) {
        if ([line containsString:@"PROBE"]) [keep addObject:line];
    }
    NSUInteger total = keep.count;
    if (!total) {
        return @"(没找到 PROBE 行)\n\n"
                "常见原因（按可能性排）：\n"
                "① SpringBoard 起来之后还没收到过通知 —— 探针要等第一条通知到达才跑；\n"
                "② 日志轮转过了（超过 512KB 切到 .1），开机那几条不在当前文件里；\n"
                "③ tweak 没注入 —— 先去「只看结论行」看有没有 banner 那两行。";
    }
    // 只留最后 40 行：单行可能上千字，多了翻不动
    if (keep.count > 40) {
        keep = [[keep subarrayWithRange:NSMakeRange(keep.count - 40, 40)] mutableCopy];
    }
    NSString *head = [NSString stringWithFormat:@"PROBE 行 %lu 条 / 全文 %lu 行%@",
                      (unsigned long)total, (unsigned long)all.count,
                      (total > keep.count
                       ? [NSString stringWithFormat:@"（只显示最后 %lu 条）", (unsigned long)keep.count]
                       : @"")];
    return [head stringByAppendingFormat:@"\n\n%@", [keep componentsJoinedByString:@"\n"]];
}

// 从全量日志里挑出「能下结论」的行：装载/挂了哪组/命中/探针/丢弃/写库失败
- (NSString *)keyLinesFrom:(NSString *)text {
    if (!text.length) return @"(空)";
    NSArray *all = [text componentsSeparatedByString:@"\n"];
    NSMutableArray *keep = [NSMutableArray array];
    // 这些是判据行；不含它们的（比如 sel 清单）不在这里显示
    // 🔴 DROP# / REPL# 是「过滤真的拦了」「替换真的改了」的唯一证据，必须进结论行
    //
    // 🔴🔴 v0.0.17 修一个很隐蔽的漏判：`DELAY` / `PROBEDATE` 必须显式加进表里。
    //    之前只有 `P#` 这个关键词，于是：
    //      `DELAY-SKIP#1`  刚好含 "SKIP#" 里的 "P#"  ⇒ 侥幸显示
    //      `DELAY#1`       D,E,L,A,Y,#             ⇒ 一个关键词都不含 ⇒ **被筛掉**
    //      `DELAY-MISS#1`  同上                    ⇒ 也被筛掉
    //    结果就是用户截图上只看到 SKIP、看不到 DELAY# —— 而 DELAY# 恰恰带着
    //    「我改的是哪个字段」这个最关键的信息。查这个问题时我一度以为延迟根本没生效。
    //    ⇒ 教训：**新增一种日志行，必须同时检查它能不能通过"结论行"筛选**。
    //      判据写出来了但看不见，等于没写。
    NSArray *keys = NBKeyLineKeywords();
    for (NSString *line in all) {
        if (!line.length) continue;
        for (NSString *k in keys) {
            if ([line containsString:k]) { [keep addObject:line]; break; }
        }
    }
    NSString *head = [NSString stringWithFormat:@"命中 %lu 行 / 全文 %lu 行",
                      (unsigned long)keep.count, (unsigned long)all.count];
    if (!keep.count) {
        // 日志都没有时，附上「不依赖日志」的环境自检，否则这一屏毫无信息量
        return [head stringByAppendingFormat:
                @"\n\n没有任何结论行 —— 日志文件里没有装载记录。\n\n"
                @"【环境自检】\n%@\n\n【日志原文前 800 字】\n%@",
                [NotifyStore envCheck],
                text.length > 800 ? [text substringToIndex:800] : text];
    }
    return [head stringByAppendingFormat:@"\n\n%@", [keep componentsJoinedByString:@"\n"]];
}

// 长文本用可滚动 VC 展示：UIAlertController 的 message 太长会被截断，且不能复制
- (void)showText:(NSString *)text title:(NSString *)title {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = title;
    vc.view.backgroundColor = [UIColor systemBackgroundColor];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
    tv.editable = NO;
    tv.selectable = YES;                 // 可全选复制，方便发回给我
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.text = text ?: @"(空)";
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor],
    ]];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)buildUI {
    // 时间分段
    self.timeSeg = [[UISegmentedControl alloc] initWithItems:@[@"今天", @"近7天", @"全部"]];
    self.timeSeg.selectedSegmentIndex = 0;
    [self.timeSeg addTarget:self action:@selector(onTime:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.timeSeg];

    // 搜索
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索标题或正文";
    [self.view addSubview:self.searchBar];

    // 顶部 App 图标栏（横向滚动）
    self.iconBar = [[UIScrollView alloc] init];
    self.iconBar.showsHorizontalScrollIndicator = NO;
    [self.view addSubview:self.iconBar];

    // 列表
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.delegate = self;
    self.table.dataSource = self;
    // 🔴 自定义 cell：Default 样式的 UITableViewCell **不显示 detailTextLabel**，
    //    以前正文全写在那上面 ⇒ 只有标题、没有正文。见 NotifyCell.h 注释。
    [self.table registerClass:[NotifyCell class] forCellReuseIdentifier:@"c"];
    self.table.rowHeight = [NotifyCell height];
    [self.view addSubview:self.table];
}

// 统一在 safeArea 里排版，避免和导航栏/搜索框互相压字
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat top = self.view.safeAreaInsets.top;
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat safeBottom = self.view.safeAreaInsets.bottom;
    CGFloat y = top + 6;

    self.timeSeg.frame = CGRectMake(12, y, w - 24, 30);
    y += 30 + 6;

    self.searchBar.frame = CGRectMake(0, y, w, 44);
    y += 44;

    self.iconBar.frame = CGRectMake(0, y, w, 56);
    y += 56;

    self.table.frame = CGRectMake(0, y, w, h - y - safeBottom);
}

- (void)reloadIconBar {
    [self.iconBar.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.bundles = [NotifyStore distinctBundles];

    CGFloat x = 8;
    CGFloat size = 44;
    NSArray *list = [@[@"全部"] arrayByAddingObjectsFromArray:self.bundles];
    for (NSString *bid in list) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(x, 6, size, size);
        b.layer.cornerRadius = 8;
        b.clipsToBounds = YES;
        b.backgroundColor = [UIColor secondarySystemFillColor];
        b.tag = [list indexOfObject:bid];
        [b addTarget:self action:@selector(onIcon:) forControlEvents:UIControlEventTouchUpInside];
        // 真图标（LSApplicationProxy）；「全部」用 SF Symbol
        if ([bid isEqualToString:@"全部"]) {
            [b setImage:[[UIImage systemImageNamed:@"tray.full"]
                imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                       forState:UIControlStateNormal];
            b.tintColor = [UIColor secondaryLabelColor];
        } else {
            UIImage *ic = [AppIconLoader iconForBundle:bid];
            if (ic) {
                [b setImage:ic forState:UIControlStateNormal];
            } else {
                // 退化态：只放**首字母**。之前放的是 bundle 末段全名（如 "bijia"），
                // 44pt 的方块里根本显示不下，看起来像坏掉。
                NSString *last = [self shortName:bid];
                NSString *ch = last.length ? [[last substringToIndex:1] uppercaseString] : @"?";
                [b setTitle:ch forState:UIControlStateNormal];
                b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
                // 系统按钮的标题默认走 tintColor（蓝），退化态用灰色更克制
                [b setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
            }
        }

        // 🔴 当前筛选的 App 必须看得出来：以前点完毫无视觉反馈，
        //    用户没法判断"现在到底筛的是哪个"。
        BOOL selected = [bid isEqualToString:@"全部"] ? (self.filterBundle.length == 0)
                                                     : [bid isEqualToString:self.filterBundle];
        if (selected) {
            b.layer.borderWidth = 2.0;
            b.layer.borderColor = [UIColor systemBlueColor].CGColor;
        }
        b.imageView.contentMode = UIViewContentModeScaleAspectFit;
        [self.iconBar addSubview:b];
        x += size + 8;
    }
    self.iconBar.contentSize = CGSizeMake(x, 56);
}

- (NSString *)shortName:(NSString *)bid {
    if ([bid isEqualToString:@"全部"]) return @"全部";
    NSArray *parts = [bid componentsSeparatedByString:@"."];
    return [parts lastObject];
}

// 图标统一由 AppIconLoader 负责（多策略 + 诊断 + 缓存），这里不再自己实现。
// 🔴 历史：v0.0.5 的崩溃（NSInvocation getReturnValue: 的 ARC 过度释放）就发生在这段，
//    已经搬进 AppIconLoader 并保留了 __unsafe_unretained 的正确写法。

- (void)onIcon:(UIButton *)sender {
    NSArray *list = [@[@"全部"] arrayByAddingObjectsFromArray:self.bundles];
    NSString *bid = list[sender.tag];
    self.filterBundle = [bid isEqualToString:@"全部"] ? nil : bid;
    [self loadData];
}

- (void)onTime:(UISegmentedControl *)seg {
    [self loadData];
}

- (NSTimeInterval)sinceFromSeg {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (self.timeSeg.selectedSegmentIndex == 0) return now - 86400;
    if (self.timeSeg.selectedSegmentIndex == 1) return now - 7 * 86400;
    return 0;
}

- (void)loadData {
    [self reloadIconBar];
    self.items = [NotifyStore queryWithBundle:self.filterBundle
                                        since:[self sinceFromSeg]
                                       search:self.searchText];
    [self.table reloadData];
    [self updateEmptyView];

    // 🔴 标题里直接报 DB 总记录数：这个数不依赖列表渲染，
    //    即使列表因为取图标崩了，用户也能从标题看出「库里到底有没有东西」。
    NSInteger total = [NotifyStore count];
    self.title = [NSString stringWithFormat:@"消息盒子 (%ld)", (long)total];
}

// 空列表时直接把自检信息打在屏幕上（判断 tweak 有没有写库、App 能不能读到）
- (void)updateEmptyView {
    if (self.items.count) {
        self.table.backgroundView = nil;
        return;
    }
    UILabel *l = [[UILabel alloc] init];
    l.numberOfLines = 0;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:13];
    l.textColor = [UIColor secondaryLabelColor];
    l.text = [@"暂无记录\n\n" stringByAppendingString:[NotifyStore debugSummary]];
    self.table.backgroundView = l;
}

#pragma mark - UISearchBarDelegate
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.searchText = searchText.length ? searchText : nil;
    [self loadData];
}

#pragma mark - UITableView
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NotifyCell *c = [tableView dequeueReusableCellWithIdentifier:@"c" forIndexPath:indexPath];
    NSDictionary *d = self.items[indexPath.row];
    NSString *bid = d[@"bundle"];
    NSString *title = d[@"title"];
    NSString *msg = d[@"message"];
    NSString *sub = d[@"subtitle"];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[d[@"ts"] doubleValue]];

    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm";
    });

    UIImage *ic = [AppIconLoader iconForBundle:bid];
    [c setIcon:ic letter:[self shortName:bid]];
    [c setTitleText:title message:msg subtitle:sub];
    [c setTimeText:[fmt stringFromDate:date]];
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = self.items[indexPath.row];
    [NotifyStore markRead:[d[@"id"] integerValue]];
}

@end
