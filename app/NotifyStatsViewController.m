#import "NotifyStatsViewController.h"
#import "NotifyStore.h"
#import "InstalledApps.h"
#import "NBTheme.h"

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
    // 🔴 右侧条数/未读标签按内容宽度自适应（不再写死 96 ⇒ 长文本被截断「显示不全」）。
    //    给名字至少留 80pt；超出则截断右侧标签本身，绝不挤压名字到看不见。
    CGFloat maxCnt = w - pad * 2 - 80;
    CGFloat cntW = self.cntLabel.intrinsicContentSize.width;
    if (cntW > maxCnt) cntW = maxCnt;
    if (cntW < 0) cntW = 0;
    self.cntLabel.frame  = CGRectMake(w - pad - cntW, 9, cntW, 18);
    self.nameLabel.frame = CGRectMake(pad, 7, w - pad * 2 - cntW - 8, 20);
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
@property (nonatomic, assign) NSTimeInterval customSince;      // 自定义时间窗起点（0 = 未设）
@property (nonatomic, assign) NSTimeInterval customBeforeTs;   // 自定义时间窗上界（0 = 未设）

- (void)onDim:(UISegmentedControl *)seg;
- (void)onRange:(UISegmentedControl *)seg;
- (void)reloadData;
- (NSTimeInterval)sinceFromSeg;
- (NSTimeInterval)beforeTsFromSeg;
- (NSString *)nameForRow:(NSDictionary *)d;
@end

#pragma mark - 自定义时间窗：起止日期选择器（模态）

@interface NBDateRangeViewController : UIViewController
@property (nonatomic, assign) NSTimeInterval initialSince;
@property (nonatomic, assign) NSTimeInterval initialBeforeTs;
@property (nonatomic, copy) void (^completion)(NSTimeInterval since, NSTimeInterval beforeTs);
@property (nonatomic, copy) void (^cancelBlock)(void);
@end

@implementation NBDateRangeViewController {
    UIDatePicker *_startPicker;
    UIDatePicker *_endPicker;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"自定义时间窗";
    self.view.backgroundColor = NBPageBG();   // v0.0.71 与全站统一：分组灰底 + 白卡片
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                         style:UIBarButtonItemStyleDone
                                        target:self action:@selector(onDone:)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消"
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(onCancel:)];

    UILabel *ls = [[UILabel alloc] init];
    ls.text = @"开始日期"; ls.font = [UIFont systemFontOfSize:13];
    ls.textColor = [UIColor secondaryLabelColor];
    UILabel *le = [[UILabel alloc] init];
    le.text = @"结束日期"; le.font = [UIFont systemFontOfSize:13];
    le.textColor = [UIColor secondaryLabelColor];

    _startPicker = [[UIDatePicker alloc] init];
    _startPicker.datePickerMode = UIDatePickerModeDate;
    _startPicker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    if (@available(iOS 15.0, *)) _startPicker.maximumDate = [NSDate date];
    _endPicker = [[UIDatePicker alloc] init];
    _endPicker.datePickerMode = UIDatePickerModeDate;
    _endPicker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    if (@available(iOS 15.0, *)) _endPicker.maximumDate = [NSDate date];

    // 🔴 默认值：start = 7 天前；end = 今天（都取当地 0 点）。
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *today = [cal startOfDayForDate:[NSDate date]];
    NSDate *weekAgo = [cal dateByAddingUnit:NSCalendarUnitDay value:-7 toDate:today options:0];
    if (self.initialSince > 0)
        _startPicker.date = [cal startOfDayForDate:[NSDate dateWithTimeIntervalSince1970:self.initialSince]];
    else _startPicker.date = weekAgo;
    if (self.initialBeforeTs > 0)
        _endPicker.date = [cal startOfDayForDate:
                           [NSDate dateWithTimeIntervalSince1970:self.initialBeforeTs - 86400.0]];
    else _endPicker.date = today;

    for (UIView *v in @[ls, le, _startPicker, _endPicker]) [self.view addSubview:v];
    ls.translatesAutoresizingMaskIntoConstraints = NO;
    le.translatesAutoresizingMaskIntoConstraints = NO;
    _startPicker.translatesAutoresizingMaskIntoConstraints = NO;
    _endPicker.translatesAutoresizingMaskIntoConstraints = NO;
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [ls.topAnchor constraintEqualToAnchor:g.topAnchor constant:16],
        [ls.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [_startPicker.topAnchor constraintEqualToAnchor:ls.bottomAnchor constant:4],
        [_startPicker.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [_startPicker.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [le.topAnchor constraintEqualToAnchor:_startPicker.bottomAnchor constant:16],
        [le.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [_endPicker.topAnchor constraintEqualToAnchor:le.bottomAnchor constant:4],
        [_endPicker.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [_endPicker.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
    ]];
}

- (void)onDone:(id)sender {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *sd = [cal startOfDayForDate:_startPicker.date];          // 当地 0 点
    NSDate *ed = [cal startOfDayForDate:_endPicker.date];
    // 🔴 上界 = 结束日 + 1 天 0 点 ⇒ 让「结束日当天」整日都包含在内（闭区间语义）。
    NSDate *edNext = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:ed options:0];
    if ([edNext timeIntervalSince1970] <= [sd timeIntervalSince1970]) {
        // 结束早于开始：把结束往后推一天，保证窗口有效，不弹报错打断用户。
        edNext = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:sd options:0];
    }
    if (self.completion) {
        self.completion([sd timeIntervalSince1970], [edNext timeIntervalSince1970]);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onCancel:(id)sender {
    if (self.cancelBlock) self.cancelBlock();
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

@implementation NotifyStatsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"统计";
    self.view.backgroundColor = NBPageBG();   // v0.0.71 与全站统一：分组灰底 + 白卡片

    self.dimSeg = [[UISegmentedControl alloc] initWithItems:@[@"按 App", @"按小时", @"按天"]];
    self.dimSeg.selectedSegmentIndex = 0;
    [self.dimSeg addTarget:self action:@selector(onDim:)
          forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.dimSeg];

    self.rangeSeg = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"7 天", @"30 天", @"自定义"]];
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
    NSInteger i = self.rangeSeg.selectedSegmentIndex;
    if (i == 1) return [[NSDate date] timeIntervalSince1970] - 7 * 86400.0;
    if (i == 2) return [[NSDate date] timeIntervalSince1970] - 30 * 86400.0;
    if (i == 3) return self.customSince;     // 自定义起点
    return 0;
}

// 🔴 `beforeTs` 是时间窗的上界（`ts < beforeTs`），只有「自定义」才用，其余窗口都不限上界。
- (NSTimeInterval)beforeTsFromSeg {
    return (self.rangeSeg.selectedSegmentIndex == 3) ? self.customBeforeTs : 0;
}

- (void)onDim:(UISegmentedControl *)seg   { [self reloadData]; }
- (void)onRange:(UISegmentedControl *)seg {
    if (seg.selectedSegmentIndex == 3) {
        // 🔴 选「自定义」就弹起止日期选择器；若用户取消（没选就关掉），
        //    把分段切回「全部」，避免停在"自定义"却没有任何范围可用。
        NBDateRangeViewController *r = [[NBDateRangeViewController alloc] init];
        r.initialSince = self.customSince;
        r.initialBeforeTs = self.customBeforeTs;
        __weak typeof(self) wself = self;
        r.completion = ^(NSTimeInterval since, NSTimeInterval beforeTs) {
            typeof(self) s = wself;
            if (!s) return;
            s.customSince = since;
            s.customBeforeTs = beforeTs;
            [s reloadData];
        };
        // 🔴 取消时把分段切回「全部」—— 否则会出现"标着自定义、却显示全部"的矛盾。
        r.cancelBlock = ^{
            typeof(self) s = wself;
            if (!s) return;
            s.rangeSeg.selectedSegmentIndex = 0;
            [s reloadData];
        };
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:r];
        [self presentViewController:nav animated:YES completion:nil];
        return;
    }
    [self reloadData];
}

- (void)reloadData {
    NSTimeInterval since = [self sinceFromSeg];
    NSTimeInterval before = [self beforeTsFromSeg];

    NSDictionary *sum = [NotifyStore statsSummarySince:since beforeTs:before];
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
        self.rows = [NotifyStore statsBundlesSince:since beforeTs:before limit:30];
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (InstalledApp *a in [InstalledApps all]) {
            if (a.bundleId.length) m[a.bundleId] = a.name;
        }
        self.names = m;
    } else {
        self.rows = [NotifyStore statsBucketsSince:since beforeTs:before byHour:(dim == 1)];
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
