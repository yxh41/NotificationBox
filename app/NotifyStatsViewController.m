#import "NotifyStatsViewController.h"
#import "NotifyStore.h"
#import "InstalledApps.h"

#pragma mark - 一行统计（名称 + 条数 + 一根条形）

// 🔴🔴 条形用**手机上的涨红跌绿无关**、这里只是数量多少 ⇒ 用系统蓝，别套行情色。
@interface NBStatCell : UITableViewCell
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *cntLabel;
@property (nonatomic, strong) UIView *barBox;
@property (nonatomic, strong) UIView *barFill;
@end

@implementation NBStatCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.font = [UIFont systemFontOfSize:14];
    self.nameLabel.textColor = [UIColor labelColor];
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:self.nameLabel];

    self.cntLabel = [[UILabel alloc] init];
    self.cntLabel.font = [UIFont systemFontOfSize:12];
    self.cntLabel.textColor = [UIColor secondaryLabelColor];
    self.cntLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:self.cntLabel];

    // 条形底槽（浅）+ 填充（蓝）。分两层而不是改一个 view 的背景色：
    // 这样"占比 0"时底槽还在，用户能看出**这里确实有一格**，只是它是空的
    // —— 和"这一行没画出来"是两种完全不同的信息。
    self.barBox = [[UIView alloc] init];
    self.barBox.backgroundColor = [UIColor tertiarySystemFillColor];
    self.barBox.layer.cornerRadius = 2;
    self.barBox.clipsToBounds = YES;
    [self.contentView addSubview:self.barBox];

    self.barFill = [[UIView alloc] init];
    self.barFill.backgroundColor = [UIColor systemBlueColor];
    [self.barBox addSubview:self.barFill];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat pad = 14;
    CGFloat cntW = 96;
    self.nameLabel.frame = CGRectMake(pad, 7, w - pad * 2 - cntW - 8, 20);
    self.cntLabel.frame  = CGRectMake(w - pad - cntW, 9, cntW, 18);
    self.barBox.frame    = CGRectMake(pad, 32, w - pad * 2, 8);
    // `barFill` 的高度跟着底槽，宽度由外部按占比设（见 cellForRow）
    self.barFill.frame   = CGRectMake(0, 0, self.barFill.frame.size.width,
                                      self.barBox.bounds.size.height);
}

// 🔴 复用池必须清：条形的宽度是"上一次的值"，
//    不清的话滚一下就会看到"新行的名字 + 上一行的条长"（本项目已栽过三次同类）。
- (void)prepareForReuse {
    [super prepareForReuse];
    self.nameLabel.text = nil;
    self.cntLabel.text = nil;
    self.barFill.frame = CGRectMake(0, 0, 0, self.barBox.bounds.size.height);
}

@end

#pragma mark - 统计页

@interface NotifyStatsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISegmentedControl *dimSeg;      // 维度：App / 小时 / 天
@property (nonatomic, strong) UISegmentedControl *rangeSeg;    // 时间窗：全部 / 7天 / 30天
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSDictionary *> *rows;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *names;   // bid -> 显示名
@property (nonatomic, assign) NSInteger max;                   // 本屏最大值，条形按比例

- (void)onDim:(UISegmentedControl *)seg;
- (void)onRange:(UISegmentedControl *)seg;
- (void)reloadData;
- (NSTimeInterval)sinceFromSeg;
- (NSString *)nameForRow:(NSDictionary *)d;
@end

@implementation NotifyStatsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"统计";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.dimSeg = [[UISegmentedControl alloc] initWithItems:@[@"按 App", @"按小时", @"按天"]];
    self.dimSeg.selectedSegmentIndex = 0;
    [self.dimSeg addTarget:self action:@selector(onDim:)
          forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.dimSeg];

    self.rangeSeg = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"7 天", @"30 天"]];
    self.rangeSeg.selectedSegmentIndex = 0;
    [self.rangeSeg addTarget:self action:@selector(onRange:)
            forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.rangeSeg];

    self.summaryLabel = [[UILabel alloc] init];
    self.summaryLabel.numberOfLines = 0;
    self.summaryLabel.font = [UIFont systemFontOfSize:12];
    self.summaryLabel.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:self.summaryLabel];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 48;
    [self.table registerClass:[NBStatCell class] forCellReuseIdentifier:@"stat"];
    // 🔴 空列表不要留一片白底配一堆留白：给一句"这个时间窗里没有记录"，
    //    否则用户分不清"没数据"和"页面坏了"。
    self.table.tableFooterView = [[UIView alloc] init];
    [self.view addSubview:self.table];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat top = self.view.safeAreaInsets.top;
    CGFloat pad = 14;

    self.dimSeg.frame   = CGRectMake(pad, top + 10, w - pad * 2, 32);
    self.rangeSeg.frame = CGRectMake(pad, top + 50, w - pad * 2, 32);
    self.summaryLabel.frame = CGRectMake(pad, top + 90, w - pad * 2, 34);
    CGFloat ty = top + 128;
    self.table.frame = CGRectMake(0, ty, w, h - ty);
}

#pragma mark - 数据

// 🔴 时间窗和列表完全同一个口径（`ts >= since`），不另发明一套 ——
//    两个指标打架是这个项目最贵的一类事故（v0.0.37 的红点）。
- (NSTimeInterval)sinceFromSeg {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSInteger i = self.rangeSeg.selectedSegmentIndex;
    if (i == 1) return now - 7 * 86400.0;
    if (i == 2) return now - 30 * 86400.0;
    return 0;
}

- (void)onDim:(UISegmentedControl *)seg   { [self reloadData]; }
- (void)onRange:(UISegmentedControl *)seg { [self reloadData]; }

- (void)reloadData {
    NSTimeInterval since = [self sinceFromSeg];

    NSDictionary *sum = [NotifyStore statsSummarySince:since];
    NSInteger total  = [sum[@"total"] integerValue];
    NSInteger unread = [sum[@"unread"] integerValue];
    NSInteger apps   = [sum[@"apps"] integerValue];
    NSDate *earliest = sum[@"earliest"];
    NSString *when = @"—";
    if (earliest) {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"yyyy-MM-dd HH:mm";
        when = [f stringFromDate:earliest];
    }
    // 🔴 总数为 0 时**直说"这个时间窗里没有记录"**，别显示"最早 —"
    //    —— 那会让用户以为时间解析坏了。
    if (total <= 0) {
        self.summaryLabel.text = @"这个时间窗里没有记录";
    } else {
        self.summaryLabel.text = [NSString stringWithFormat:
                                  @"共 %ld 条 · 未读 %ld · 覆盖 %ld 个 App · 最早 %@",
                                  (long)total, (long)unread, (long)apps, when];
    }

    NSInteger dim = self.dimSeg.selectedSegmentIndex;
    if (dim == 0) {
        // 🔴 只取前 30：这是"谁最烦人"的排名，不是完整名单。
        //    全列出来 200 个 App 反而看不出重点。
        self.rows = [NotifyStore statsBundlesSince:since limit:30];
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (InstalledApp *a in [InstalledApps all]) {
            if (a.bundleId.length) m[a.bundleId] = a.name;
        }
        self.names = m;
    } else {
        self.rows = [NotifyStore statsBucketsSince:since byHour:(dim == 1)];
        self.names = @{};
    }

    // 条形的分母：本屏最大值。max 为 0 时（全空）不该除零 ⇒ 下面用 `max > 0 ? … : 0`
    NSInteger mx = 0;
    for (NSDictionary *d in self.rows) {
        NSInteger n = [d[@"total"] integerValue];
        if (n > mx) mx = n;
    }
    self.max = mx;

    [self.table reloadData];
}

- (NSString *)nameForRow:(NSDictionary *)d {
    NSInteger dim = self.dimSeg.selectedSegmentIndex;
    if (dim == 0) {
        NSString *bid = d[@"bundle"] ?: @"";
        NSString *n = self.names[bid];
        if (n.length) return n;
        return [[bid componentsSeparatedByString:@"."] lastObject] ?: bid;
    }
    if (dim == 1) {
        NSInteger h = [d[@"hour"] integerValue];
        // 显示成时间段而不是裸数字：「14」看不出是 14 点还是 14 条
        return [NSString stringWithFormat:@"%02ld:00 – %02ld:00",
                (long)h, (long)((h + 1) % 24)];
    }
    return d[@"day"] ?: @"";
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec {
    return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NBStatCell *c = [tv dequeueReusableCellWithIdentifier:@"stat" forIndexPath:ip];
    NSDictionary *d = self.rows[ip.row];
    NSInteger n = [d[@"total"] integerValue];

    c.nameLabel.text = [self nameForRow:d];
    // 按 App 维度额外显示未读：知道"京东来了 300 条"之外，
    // 用户真正想管的往往是"其中 12 条还没看"。
    NSInteger un = [d[@"unread"] integerValue];
    if (self.dimSeg.selectedSegmentIndex == 0 && un > 0) {
        c.cntLabel.text = [NSString stringWithFormat:@"%ld 条 · 未读 %ld", (long)n, (long)un];
    } else {
        c.cntLabel.text = [NSString stringWithFormat:@"%ld 条", (long)n];
    }

    CGFloat w = c.barBox.bounds.size.width;
    CGFloat fill = (self.max > 0 && w > 0) ? (w * (CGFloat)n / (CGFloat)self.max) : 0;
    c.barFill.frame = CGRectMake(0, 0, fill, c.barBox.bounds.size.height);
    // 🔴 0 条的行也要看得见"这是一格空的"，所以底槽保留、只让填充宽度为 0
    c.barFill.hidden = (n <= 0);
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
}

@end
