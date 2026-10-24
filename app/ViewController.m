#import "ViewController.h"
#import "NotifyStore.h"
#import "NotifyCommon.h"
#import "SettingsViewController.h"
#import "NotifyCell.h"
#import "AppIconLoader.h"
// v0.0.33：点开看全文 + 复制 + 删单条
#import "NotifyDetailViewController.h"

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
// v0.0.36：只看未读（搜索框下的 scope bar 第 2 段）
@property (nonatomic, assign) BOOL unreadOnly;
// v0.0.36：每个 App 图标右上角那个红点，key = bundle。
// 🔴 存引用是为了**只刷新红点、不重建按钮** —— 重建会让 `contentSize` 重设，
//    把图标栏的滚动位置重置到最左（选了第 10 个 App，点开一条就跳回开头）。
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *unreadDots;

- (void)onDiag:(id)sender;
- (void)onSettings:(id)sender;
// v0.0.35：清空整张表。两个都必须在这里声明 ——
// 🔴 `onClear:` 要用于 `@selector(...)`，`doClear` 在 alert 的 block 里被 `[weakSelf ...]` 调用。
//    未声明 ⇒ ARC 下返回类型被推断成 `id` ⇒ 警告 ⇒ CI 的 `-Werror` 直接挂
//    （v0.0.33 的 `doDelete`/`str:` 就是这么挂过一次）。
- (void)onClear:(id)sender;
- (void)doClear;
// v0.0.36：只刷新图标栏红点（不重建按钮，避免图标栏滚动位置被重置）
- (void)refreshUnreadDots;
// v0.0.36：当前筛选条件的一行文字描述（空列表时写出来，避免"看着空 = 没有"的误判）
- (NSString *)filterDesc;
- (void)showText:(NSString *)text title:(NSString *)title;
// v0.0.33：轻量一行提示（左滑删除失败时用）。
// 不走 showText: —— 那个是"长文本可滚动页"，弹一句"这条已经没了"太重。
- (void)alertTitle:(NSString *)title text:(NSString *)text;
- (NSString *)keyLinesFrom:(NSString *)text;
- (NSString *)selLinesFrom:(NSString *)text;
- (NSString *)probeLinesFrom:(NSString *)text;
- (NSString *)soundDiagFileText;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"消息盒子";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // 在同一日志里打一条「App 活着」，用来和 tweak 的日志对照（见 NotifyStore.h 注释）
    [NotifyStore markAppAlive];
    // 诊断入口：把 tweak.log 尾部搬进 App，免去用 Filza 翻文件
    // v0.0.35：右侧多一个「清空」。`rightBarButtonItems` 里**第一个在最右**，
    // 所以「诊断」放第一位（更常用），「清空」在它左边 —— 一个不可撤销的动作
    // 不该占着最显眼的右上角。
    UIBarButtonItem *diag =
        [[UIBarButtonItem alloc] initWithTitle:@"诊断"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onDiag:)];
    UIBarButtonItem *clear =
        [[UIBarButtonItem alloc] initWithTitle:@"清空"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onClear:)];
    clear.tintColor = [UIColor systemRedColor];   // 不可撤销 ⇒ 和详情页的「删除」同一套视觉
    self.navigationItem.rightBarButtonItems = @[diag, clear];
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

#pragma mark - 清空（v0.0.35）

// 之前「清空」只有设置页有入口（SettingsViewController.m），要清记录得跑进设置里找。
- (void)onClear:(id)sender {
    NSInteger total = [NotifyStore count];
    if (total == 0) {
        // 空库时**不弹确认**：弹了用户点"清空"，结果什么都没发生，反而以为坏了。
        [self alertTitle:@"没有记录" text:@"数据库里是空的，不用清。"];
        return;
    }

    // 🔴 文案必须报**数据库总数**，不是 `self.items.count`。
    //    这是这一版最容易做错的一处：搜索「验证码」时列表只有 3 条，
    //    而 `clearAll` 清的是整张表。拿列表条数写确认文案 ⇒ 用户以为只删这 3 条。
    NSMutableString *msg = [NSMutableString stringWithFormat:
        @"将删除全部 %ld 条记录，删了不能恢复。", (long)total];
    if ((NSInteger)self.items.count != total) {
        [msg appendFormat:@"\n\n当前列表只显示 %ld 条（有筛选/搜索，或超出单次上限），但会一起清掉。",
         (long)self.items.count];
    }

    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"清空所有记录？"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [al addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        [weakSelf doClear];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)doClear {
    NSInteger n = [NotifyStore clearAll];
    // 🔴 先清库 → 再整表重查。和 v0.0.33 的删除是同一条纪律：
    //    列表的数据只有一个来源（数据库），内存数组永远是从它重建出来的。
    [self loadData];

    if (n > 0) {
        [self alertTitle:@"已清空"
                    text:[NSString stringWithFormat:@"删掉了 %ld 条记录。", (long)n]];
    } else if (n == 0) {
        // `DELETE FROM` 命中 0 行照样返回 SQLITE_OK ⇒ 不能当成功。
        // 最常见的原因是清之前已经被「记录上限」裁光了。
        [self alertTitle:@"没清到"
                    text:@"库里没有可删的记录（可能已被「记录上限」自动清掉）。列表已刷新。"];
    } else {
        [self alertTitle:@"清空失败"
                    text:@"打不开数据库。列表已刷新，可以重启 App 再试。"];
    }
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
    // 🔴🔴 v0.0.23：换提示音的诊断**落盘**了，这里直接读文件。
    //    为什么单开一个入口、而不是从日志里捞：
    //      · 日志只有约 50 行窗口，结构性 dump 一小时前就滚没了
    //        （v0.0.22 就是这么白跑一轮的）；
    //      · 文件不受窗口/轮转影响，且是"上一个进程完整的一次 dump"。
    //    路径与 tweak 侧共用 NotifyCommon.h 里的宏 —— 不另写一份字面量。
    [sheet addAction:[UIAlertAction actionWithTitle:@"声音诊断文件（完整，换提示音必看）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showText:[self soundDiagFileText] title:@"声音诊断"];
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

// v0.0.23：把落盘的诊断整份读出来。
// 文件不存在时给"三种可能"，而不是干巴巴一句"没有"——
// 用户看到空白时必须能自己判断是"没跑过"还是"跑了但没写进去"。
- (NSString *)soundDiagFileText {
    // 🔴 路径必须用 NotifyCommon.h 里的宏，**不许在这里再写一遍字面量**。
    //    上一版我差点写成字面量、注释还写着"共用宏"——注释和代码走岔是本项目
    //    反复付学费的那类错（改了 tweak 侧路径、App 侧还读老路径，两边都"没错"却谁也看不见）。
    NSString *path = NOTIFYBOX_SOUND_DIAG_PATH;
    NSString *body = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (!body.length) {
        return [NSString stringWithFormat:
                @"(%@ 是空的或不存在)\n\n"
                @"常见原因（按可能性排）：\n"
                @"① SpringBoard 起来之后还没收到过通知 —— 诊断要等第一条通知到达才写；\n"
                @"② 换提示音的开关/名单没配好 → 诊断只在**目标 App** 上输出（这是故意的，避免刷屏）；\n"
                @"③ tweak 没注入 —— 先去「结论行」看有没有 banner 那两行。",
                path];
    }
    NSArray *lines = [body componentsSeparatedByString:@"\n"];
    NSString *head = [NSString stringWithFormat:@"%@\n共 %lu 行\n",
                      path, (unsigned long)lines.count];
    return [head stringByAppendingFormat:@"\n%@", body];
}

// v0.0.20：只挑探针行。
// 判据域 = 含 "PROBE"（v0.0.23 起加 "SD#"）的行；变异域 = 探针的全部输出。
// ⇒ 两者必须严格对齐。这正是上一版"关键词表漏词"要买的课。
// 单独开入口、而不是塞进结论行，有两个**互相独立**的原因：
//   ① 结论行只看尾部 20KB，而探针是**开机那一刻**打的 —— 手机跑几小时后早被挤出窗口，
//      光把关键词补进表里也照样看不见（只修一半 = 还是看不到）；
//   ② 探针行很长（几十个属性名 + 类型编码），混进结论行会把 DROP#/REPL# 这些判据挤掉。
- (NSString *)probeLinesFrom:(NSString *)text {
    if (!text.length) return @"(空)";
    NSArray *all = [text componentsSeparatedByString:@"\n"];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *line in all) {
        // 🔴 v0.0.23：把 SD#（换提示音诊断）也收进来。
        //    同一个病已经犯过三次：加了新留痕、却忘了它能被筛出来。
        //    这次是"加了 SD#、但入口只认 PROBE"，等于白打。
        if ([line containsString:@"PROBE"] || [line containsString:@"SD#"]) {
            [keep addObject:line];
        }
    }
    NSUInteger total = keep.count;
    if (!total) {
        return @"(没找到 PROBE / SD# 行)\n\n"
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

// v0.0.33：轻量提示（左滑删除"删不到"时用）。不用 showText: —— 那是长文本页，太重。
- (void)alertTitle:(NSString *)title text:(NSString *)text {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:title
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
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
    // v0.0.36：搜索框下面挂两个 scope（全部 / 未读）。
    // 🔴 顺序有讲究：**先设 scopeButtonTitles，再设 showsScopeBar** ——
    //    反过来的话某些系统版本上 scope bar 不会出现（网上常见的坑）。
    // 🔴 常显而不是"搜索时才出现"：这是个筛选开关，藏起来等于没有。
    self.searchBar.scopeButtonTitles = @[@"全部", @"未读"];
    self.searchBar.selectedScopeButtonIndex = 0;
    self.searchBar.showsScopeBar = YES;
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

    // v0.0.36：开了 scope bar 之后搜索框整体是 44 + 44（搜索框一行、scope 一行）。
    // 🔴 不能用 `sizeThatFits:` / `intrinsicContentSize` 去"自动算" ——
    //    UISearchBar 是普通 UIView，`sizeThatFits:` 默认只回 bounds.size，
    //    未布局时是 (0,0) ⇒ 搜索框直接消失。按"开没开 scope"直接算最稳。
    CGFloat searchH = self.searchBar.showsScopeBar ? 88 : 44;
    self.searchBar.frame = CGRectMake(0, y, w, searchH);
    y += searchH;

    self.iconBar.frame = CGRectMake(0, y, w, 56);
    y += 56;

    self.table.frame = CGRectMake(0, y, w, h - y - safeBottom);
}

- (void)reloadIconBar {
    // 🔴 v0.0.36：重建按钮会动 `contentSize`，而图标栏是横向滚动的 ——
    //    不清醒地保住 offset 的话，用户滚到右边选了第 10 个 App、点开一条通知，
    //    一返回图标栏就跳回最左。这里手动存、算完再夹回去。
    CGPoint barOff = self.iconBar.contentOffset;

    [self.iconBar.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.bundles = [NotifyStore distinctBundles];
    // v0.0.36：一次查出来，下面建每个图标时直接用（别在循环里一个个查库）
    NSSet *unread = [NotifyStore bundlesWithUnread];
    self.unreadDots = [NSMutableDictionary dictionary];

    CGFloat x = 8;
    CGFloat size = 44;
    NSArray *list = [@[@"全部"] arrayByAddingObjectsFromArray:self.bundles];
    for (NSString *bid in list) {
        // 🔴 v0.0.36：按钮外面套一层容器。
        //    按钮自己要 `clipsToBounds`（圆角得把图标裁进去），红点如果挂在按钮上、
        //    又想压在角上探出一点，就会被裁掉一半。容器不裁剪，红点挂容器。
        UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(x, 6, size, size)];
        [self.iconBar addSubview:holder];

        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(0, 0, size, size);   // ← 相对容器
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
        [holder addSubview:b];

        // v0.0.36：有未读就在右上角点一个红点。「全部」不点 —— 它不是某个 App，
        // 而且"全部"聚合了所有 App，「红点 = 全部还有未读」会让人以为没有。
        if (![bid isEqualToString:@"全部"]) {
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(size - 9, -1, 9, 9)];
            dot.backgroundColor = [UIColor systemRedColor];
            dot.layer.cornerRadius = 4.5;
            // 描边用页面底色：红点压在图标上时轮廓更清楚
            dot.layer.borderWidth = 1.5;
            dot.layer.borderColor = [UIColor systemBackgroundColor].CGColor;
            dot.hidden = ![unread containsObject:bid];
            [holder addSubview:dot];
            self.unreadDots[bid] = dot;
        }
        x += size + 8;
    }
    self.iconBar.contentSize = CGSizeMake(x, 56);
    // 夹回滚动位置（内容变短时也安全）
    CGFloat maxX = MAX(0, x - self.iconBar.bounds.size.width);
    self.iconBar.contentOffset = CGPointMake(MIN(barOff.x, maxX), barOff.y);
}

// v0.0.36：只刷新红点，**不重建按钮**。
// 🔴 为什么点开一条通知后不能直接 `reloadIconBar`：那会让 `contentSize` 重设，
//    图标栏的滚动位置被夹回最左 —— 用户滚到第 10 个 App、点开一条、返回，位置没了。
//    这里只改已有红点的 hidden，按钮和 contentSize 都不碰。
- (void)refreshUnreadDots {
    NSSet *unread = [NotifyStore bundlesWithUnread];
    for (NSString *bid in self.unreadDots) {
        self.unreadDots[bid].hidden = ![unread containsObject:bid];
    }
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

    // v0.0.35：当前筛选的 App 可能已经一条记录都不剩了（删掉它的最后一条、
    // 或者刚点了「清空」）。此时 `reloadIconBar` 重建的图标栏里已经没有它，
    // 而 `filterBundle` 还指着它 ⇒ 列表永远是空的，用户看着"空列表 + 顶部没有任何
    // 图标被选中"，第一反应是"记录全丢了"。这里让它自愈回「全部」。
    // 🔴 顺序：必须排在 `reloadIconBar`（它才更新 self.bundles）之后、query 之前。
    if (self.filterBundle && ![self.bundles containsObject:self.filterBundle]) {
        self.filterBundle = nil;
    }

    self.items = [NotifyStore queryWithBundle:self.filterBundle
                                        since:[self sinceFromSeg]
                                       search:self.searchText
                                   unreadOnly:self.unreadOnly];
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
    // v0.0.36：多写一行「当前筛选」。
    // 🔴 加了「只看未读」之后空列表变得很常见：时间选「今天」+ 只看未读 是空的，
    //    而昨天有未读。不把条件写出来的话，用户会直接断定"没有未读"。
    l.text = [NSString stringWithFormat:@"暂无记录\n\n当前筛选：%@\n\n%@",
              [self filterDesc], [NotifyStore debugSummary]];
    self.table.backgroundView = l;
}

// v0.0.36：把当前四个筛选维度拼成一行。
- (NSString *)filterDesc {
    NSMutableArray *a = [NSMutableArray array];
    [a addObject:(self.filterBundle.length ? [self shortName:self.filterBundle] : @"全部 App")];

    NSArray *times = @[@"今天", @"近7天", @"不限时间"];
    NSInteger ti = self.timeSeg.selectedSegmentIndex;
    NSString *t = (ti >= 0 && ti < (NSInteger)times.count) ? times[ti] : @"时间?";
    [a addObject:t];

    [a addObject:(self.unreadOnly ? @"只看未读" : @"全部状态")];
    if (self.searchText.length) {
        [a addObject:[NSString stringWithFormat:@"搜索「%@」", self.searchText]];
    }
    return [a componentsJoinedByString:@" · "];
}

#pragma mark - UISearchBarDelegate
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.searchText = searchText.length ? searchText : nil;
    [self loadData];
}

// v0.0.36：scope 切换（全部 / 未读）。
// 🔴 走 `loadData` 而不是自己过滤 `self.items` —— 后者只能过滤"已经查出来的 2000 条"，
//    而"只看未读"应该是在数据库层筛（数量完全不同的两类查询）。
- (void)searchBar:(UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(NSInteger)selectedScope {
    self.unreadOnly = (selectedScope == 1);
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
    // v0.0.35：`read` 字段数据层早就有了（`queryWithBundle:` 的 SELECT 里一直带着），
    // 只是 cell 从来没用过 ⇒ `markRead:` 写了等于没写，用户看不出哪条看过。
    // 0 = 未读（建表默认值），非 0 = 已读。
    [c setUnread:([d[@"read"] integerValue] == 0)];
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = self.items[indexPath.row];
    [NotifyStore markRead:[d[@"id"] integerValue]];

    // v0.0.35：把「已读」同步回内存并只刷这一行。
    // 🔴 为什么不在 `viewWillAppear:` 里 `loadData`（这是最容易想到的做法）：
    //    整表 reload 会让**滚到中间点开一条再返回，列表跳回顶部** —— 真机上一碰就发现。
    // 🔴 为什么这里用 `reloadRowsAtIndexPaths:` 是安全的（v0.0.33 删除场景里它是禁忌）：
    //    判据从来不是"这个 API 好不好"，而是**数量变不变**。这里只把一个字段 0→1，
    //    行数不变 ⇒ 内存下标和 row 仍然一一对应；而删除会改数量 ⇒ 必须整表重查。
    // 🔴 顺序不能反：先 markRead（写库），再改内存，再刷新 —— 反了刷出来的还是旧值。
    if (self.unreadOnly) {
        // 🔴 v0.0.36：「只看未读」模式下点开一条，它变已读后**不该再出现在列表里**。
        //    这是**数量会变**的场景 ⇒ 禁用 `reloadRowsAtIndexPaths:`（它要求内存下标
        //    与行严格对应，少一行之后就对不上了），必须整表重查。
        //    但为了不把滚动位置清零，重查前后手动存/恢复 contentOffset。
        CGPoint off = tableView.contentOffset;
        [self loadData];
        [tableView layoutIfNeeded];
        CGFloat maxY = MAX(0, tableView.contentSize.height - tableView.bounds.size.height);
        tableView.contentOffset = CGPointMake(0, MIN(off.y, maxY));
    } else if ([d isKindOfClass:[NSMutableDictionary class]]) {
        [(NSMutableDictionary *)d setObject:@1 forKey:@"read"];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        // 红点要跟着变：这可能正是该 App 的最后一条未读
        [self refreshUnreadDots];
    } else {
        // 兜底：万一哪天 query 改成返回不可变字典，退回整表重查（会丢滚动位置，但不会错）
        [self loadData];
    }

    // v0.0.33：点开看**全文**。列表 cell 的正文 `numberOfLines = 2`、超了截断，
    // 而在这之前点一行只做 markRead ⇒ 长通知永远看不全、也复制不了。
    // 对「消息盒子」来说这是核心缺口：验证码、链接、长消息都看不全，等于记录没记全。
    NotifyDetailViewController *vc = [[NotifyDetailViewController alloc] init];
    vc.item = d;
    __weak typeof(self) weakSelf = self;
    // 🔴 删除后由**列表**重查数据库。详情页绝不直接改 self.items ——
    //    在「搜索 / App 筛选 / 时间段」状态下，内存下标和数据库 id 完全是两回事。
    vc.onDeleted = ^{ [weakSelf loadData]; };
    [self.navigationController pushViewController:vc animated:YES];
}

// v0.0.33：左滑删除。
// 🔴 刻意**不用** `deleteRowsAtIndexPaths:` —— 它要求"内存数组与即将删的行严格同步"，
//    而我们删的是数据库。正确顺序是「先删库 → 整表重查」，让两边从同一个来源重建。
//    只改内存 = 只改账本的读数（数量契约第 2 问）：症状是删完那一行还在，
//    或者删了 A 却少了一条 B（搜索/筛选态下标错位）。
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
        trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= (NSInteger)self.items.count) return nil;
    NSDictionary *d = self.items[indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *del = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"删除"
                          handler:^(UIContextualAction *action, UIView *src, void (^done)(BOOL)) {
        NSInteger rowId = [d[@"id"] integerValue];
        BOOL ok = (rowId > 0) && [NotifyStore deleteRow:rowId];
        // 先重查（数据源变了），再告诉系统动作完成 —— 顺序反了会"删完还留着"。
        [weakSelf loadData];
        done(YES);
        if (!ok) {
            // 删不到也要说：最常见的原因是 tweak 按「记录上限」把它裁掉了，
            // 而列表还显示着。静默失败会让人以为删除按钮坏了。
            [weakSelf alertTitle:@"没删掉"
                            text:@"这条记录已经不在了（可能被「记录上限」自动清掉了）。列表已刷新。"];
        }
    }];
    del.backgroundColor = [UIColor systemRedColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end
