#import "NotifyDetailViewController.h"
#import "NotifyStore.h"
#import "AppIconLoader.h"
#import "NotifyCommon.h"
#import "NBTheme.h"

// 一条通知的详情：App / 时间 / 标题 / 副标题 / **正文全文**（可滚动、可选中复制）。
//
// 三个设计约束：
//
// ① **正文用 UITextView 而不是 UILabel**：`selectable = YES` 让用户能长按选中、复制
//    其中一段（验证码、链接通常只需要一部分）。UILabel 做不到"选一段"，
//    而"整条复制"这个按钮我已经单独给了 —— 两种需求都得满足。
//
// ② **删除只改数据库，不碰列表的数据源**。删完调 `onDeleted` 让列表自己重查。
//    直接在详情页里 `[self.listVC.items removeObjectAtIndex:]` 是经典的错：
//    搜索状态下内存里是过滤后的子集，下标和数据库的 id 完全是两回事。
//
// ③ **删不到也要给反馈**。`deleteRow:` 在 id 不存在时返回 NO（典型场景：tweak 那边
//    按"记录上限"把老记录裁掉了，而盒子列表还显示着）。这时要说"这条已经没了"，
//    并照样刷新列表 —— 静默失败会让人以为删除按钮坏了。
@interface NotifyDetailViewController ()
@property (nonatomic, strong) UIView *headerBox;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *appLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UITextView *bodyView;
- (void)onCopy:(id)sender;
- (void)onDelete:(id)sender;
- (void)doDelete;
- (NSString *)str:(NSString *)key;
- (NSString *)shortName:(NSString *)bid;
- (NSString *)timeText;
- (NSString *)plainText;
- (void)toast:(NSString *)msg;
@end

@implementation NotifyDetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"通知详情";
    // 🔴 v0.0.70：和列表页、设置页统一到**分组灰底 + 白卡片**。
    //    以前这里是纯白底，而 `headerBox` / `bodyView` 用的是 `secondarySystemBackground` ——
    //    浅色模式下它正好也是 #F2F2F7 那种浅灰 ⇒ 白底上两块浅灰块，看着像"没加载完"。
    //    换成分组灰底之后，卡片必须跟着换成 `secondarySystemGroupedBackground`（白），
    //    **一对要一起换**：只换底不换卡片 = 浅灰压浅灰，卡片直接消失。
    self.view.backgroundColor = NBPageBG();

    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:@"复制"
                                                            style:UIBarButtonItemStylePlain
                                                           target:self action:@selector(onCopy:)];
    UIBarButtonItem *del = [[UIBarButtonItem alloc] initWithTitle:@"删除"
                                                           style:UIBarButtonItemStylePlain
                                                          target:self action:@selector(onDelete:)];
    // 删除放最右、并染色：它是这一页唯一不可撤销的动作。
    del.tintColor = [UIColor systemRedColor];
    self.navigationItem.rightBarButtonItems = @[del, copy];

    NSString *bid = [self str:@"bundle"];

    self.headerBox = [[UIView alloc] init];
    self.headerBox.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.headerBox.layer.cornerRadius = 10;
    [self.view addSubview:self.headerBox];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.layer.cornerRadius = 8;
    self.iconView.clipsToBounds = YES;
    // 取不到图标时退化成首字母色块（与列表一致的做法：宁可难看，不要空白）
    UIImage *ic = [AppIconLoader iconForBundle:bid];
    self.iconView.image = ic;
    self.iconView.backgroundColor = ic ? [UIColor clearColor] : [UIColor tertiarySystemFillColor];
    [self.headerBox addSubview:self.iconView];

    self.appLabel = [[UILabel alloc] init];
    self.appLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.appLabel.text = [self shortName:bid];
    self.appLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.headerBox addSubview:self.appLabel];

    self.timeLabel = [[UILabel alloc] init];
    self.timeLabel.font = [UIFont systemFontOfSize:12];
    self.timeLabel.textColor = [UIColor secondaryLabelColor];
    self.timeLabel.text = [NSString stringWithFormat:@"%@ · %@", [self timeText], bid];
    self.timeLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.headerBox addSubview:self.timeLabel];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.titleLabel.numberOfLines = 0;
    self.titleLabel.text = [self str:@"title"];
    [self.view addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.font = [UIFont systemFontOfSize:12];
    self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
    self.subtitleLabel.numberOfLines = 2;
    NSString *sub = [self str:@"subtitle"];
    self.subtitleLabel.text = sub.length ? sub : nil;
    self.subtitleLabel.hidden = (sub.length == 0);
    [self.view addSubview:self.subtitleLabel];

    self.bodyView = [[UITextView alloc] init];
    self.bodyView.editable = NO;
    self.bodyView.selectable = YES;              // ← 见文件头 ①
    self.bodyView.scrollEnabled = YES;
    self.bodyView.alwaysBounceVertical = YES;
    self.bodyView.font = [UIFont systemFontOfSize:15];
    self.bodyView.textColor = [UIColor labelColor];
    self.bodyView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.bodyView.layer.cornerRadius = 10;
    self.bodyView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    NSString *msg = [self str:@"message"];
    // 正文为空时明确写出来 —— 空白会让人以为是"没加载出来"
    self.bodyView.text = msg.length ? msg : @"（这条通知没有正文）";
    [self.view addSubview:self.bodyView];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    CGFloat w = b.size.width;
    CGFloat pad = 16;
    // 🔴 v0.0.34：必须加 safeAreaInsets.top。
    //    这一页在 UINavigationController 里，`edgesForExtendedLayout` 默认是 .all ⇒
    //    `self.view.bounds` 的 (0,0) 在**屏幕顶点**（状态栏之上），不是导航栏下沿。
    //    写成 `y = 12` 的直接后果就是 App 图标顶进状态栏里（v0.0.33 的真机反馈）。
    //    底部那半边本来就用的是 safeAreaInsets.bottom，所以只有上半截会顶上去 ——
    //    "整体偏上"这个描述的来源就在这里。
    UIEdgeInsets si = self.view.safeAreaInsets;
    CGFloat top = si.top;

    self.headerBox.frame = CGRectMake(pad, top + 12, w - pad * 2, 52);
    self.iconView.frame = CGRectMake(10, 8, 36, 36);
    CGFloat tx = CGRectGetMaxX(self.iconView.frame) + 10;
    self.appLabel.frame = CGRectMake(tx, 8, CGRectGetWidth(self.headerBox.frame) - tx - 10, 20);
    self.timeLabel.frame = CGRectMake(tx, 28, CGRectGetWidth(self.headerBox.frame) - tx - 10, 16);

    CGFloat y = CGRectGetMaxY(self.headerBox.frame) + 14;

    CGSize ts = [self.titleLabel sizeThatFits:CGSizeMake(w - pad * 2, CGFLOAT_MAX)];
    self.titleLabel.frame = CGRectMake(pad, y, w - pad * 2, ts.height);
    y = CGRectGetMaxY(self.titleLabel.frame) + 6;

    if (!self.subtitleLabel.hidden) {
        CGSize ss = [self.subtitleLabel sizeThatFits:CGSizeMake(w - pad * 2, CGFLOAT_MAX)];
        self.subtitleLabel.frame = CGRectMake(pad, y, w - pad * 2, ss.height);
        y = CGRectGetMaxY(self.subtitleLabel.frame) + 8;
    }

    // 正文吃满剩余高度（自己会滚），但上下都要留出安全区
    CGFloat bottomInset = si.bottom + 12;
    CGFloat h = b.size.height - y - bottomInset;
    self.bodyView.frame = CGRectMake(pad, y, w - pad * 2, MAX(h, 80));
}

#pragma mark - 取值

- (NSString *)str:(NSString *)key {
    id v = self.item[key];
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    if ([v respondsToSelector:@selector(stringValue)]) return [v stringValue];
    return @"";
}

- (NSString *)shortName:(NSString *)bid {
    if (!bid.length) return @"未知";
    return [[bid componentsSeparatedByString:@"."] lastObject] ?: bid;
}

- (NSString *)timeText {
    id ts = self.item[@"ts"];
    if (![ts respondsToSelector:@selector(doubleValue)]) return @"";
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:[ts doubleValue]];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"MM-dd HH:mm";
    return [fmt stringFromDate:d];
}

// 复制出去的格式：**给人看的顺序**（标题 → 正文 → 落款）。
// 不把 bundleId 放前面：粘到聊天框里第一眼该是内容本身。
- (NSString *)plainText {
    NSMutableArray *parts = [NSMutableArray array];
    NSString *title = [self str:@"title"];
    NSString *msg   = [self str:@"message"];
    NSString *sub   = [self str:@"subtitle"];
    if (title.length) [parts addObject:title];
    if (msg.length)   [parts addObject:msg];
    if (sub.length)   [parts addObject:sub];
    if (!parts.count) [parts addObject:@"（这条通知没有内容）"];
    [parts addObject:[NSString stringWithFormat:@"—— %@ · %@",
                      [self shortName:[self str:@"bundle"]], [self timeText]]];
    return [parts componentsJoinedByString:@"\n"];
}

#pragma mark - 动作

- (void)onCopy:(id)sender {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = [self plainText];
    [self toast:@"已复制"];
}

- (void)onDelete:(id)sender {
    UIAlertController *al = [UIAlertController
        alertControllerWithTitle:@"删除这条记录？"
                         message:@"会从数据库里删掉，盒子列表里也不会再出现。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [al addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        [weakSelf doDelete];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)doDelete {
    id idv = self.item[@"id"];
    NSInteger rowId = [idv respondsToSelector:@selector(integerValue)] ? [idv integerValue] : 0;
    BOOL ok = (rowId > 0) && [NotifyStore deleteRow:rowId];
    // 无论删到没删到，都让列表重查一次：
    //   删到了 ⇒ 那一行要消失；没删到 ⇒ 它其实已经不在了（被上限裁剪），列表也该跟着变。
    if (self.onDeleted) self.onDeleted();
    if (ok) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    // 没删掉：说清楚，并且不要 pop —— 停在详情页，用户能自己再试或返回。
    UIAlertController *al = [UIAlertController
        alertControllerWithTitle:@"没删掉"
                         message:@"这条记录已经不在了（可能被「记录上限」自动清掉了）。列表已刷新。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"返回列表" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)toast:(NSString *)msg {
    UILabel *l = [[UILabel alloc] init];
    l.text = msg;
    l.font = [UIFont systemFontOfSize:14];
    l.textColor = [UIColor whiteColor];
    l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
    l.layer.cornerRadius = 10;
    l.clipsToBounds = YES;
    l.alpha = 0;
    CGSize sz = [l sizeThatFits:CGSizeMake(self.view.bounds.size.width - 80, CGFLOAT_MAX)];
    CGFloat w = MIN(sz.width + 32, self.view.bounds.size.width - 60);
    l.frame = CGRectMake((self.view.bounds.size.width - w) / 2,
                         self.view.bounds.size.height - 120, w, 40);
    l.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin
                       | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:l];
    [UIView animateWithDuration:0.18 animations:^{ l.alpha = 1; } completion:^(BOOL done) {
        [UIView animateWithDuration:0.3 delay:1.1 options:0 animations:^{ l.alpha = 0; }
                         completion:^(BOOL fin) { [l removeFromSuperview]; }];
    }];
}

@end
