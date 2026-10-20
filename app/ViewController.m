#import "ViewController.h"
#import "NotifyStore.h"
#import "NotifyCommon.h"

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
@property (nonatomic, strong) NSMutableDictionary *iconCache;  // bundle -> UIImage（含 NSNull miss）
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"消息盒子";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self buildUI];
    [self loadData];
}

- (void)buildUI {
    CGFloat w = self.view.bounds.size.width;

    // 时间分段
    self.timeSeg = [[UISegmentedControl alloc] initWithItems:@[@"今天", @"近7天", @"全部"]];
    self.timeSeg.selectedSegmentIndex = 0;
    [self.timeSeg addTarget:self action:@selector(onTime:) forControlEvents:UIControlEventValueChanged];
    self.timeSeg.frame = CGRectMake(12, 8, w - 24, 30);
    [self.view addSubview:self.timeSeg];

    // 搜索
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 44, w, 40)];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索标题或正文";
    [self.view addSubview:self.searchBar];

    // 顶部 App 图标栏（横向滚动）
    self.iconBar = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 88, w, 56)];
    self.iconBar.showsHorizontalScrollIndicator = NO;
    [self.view addSubview:self.iconBar];

    // 列表
    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 148, w, self.view.bounds.size.height - 148)
                                             style:UITableViewStylePlain];
    self.table.delegate = self;
    self.table.dataSource = self;
    [self.table registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
    [self.view addSubview:self.table];
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
            UIImage *ic = [self iconForBundle:bid];
            if (ic) [b setImage:ic forState:UIControlStateNormal];
            else    [b setTitle:[self shortName:bid] forState:UIControlStateNormal];
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

// 🔴 取 App 真图标（LSApplicationProxy）。App 不是 SpringBoard，不能用 SBApplication，
//    只能走 LSApplicationProxy。用 NSClassFromString + NSInvocation 避免依赖私有头文件。
// ⚠️ TODO（真机）：iconDataForVariant: 的 variant 取值（0 通常=默认图标），若拿到空图再调。
- (UIImage *)iconForBundle:(NSString *)bid {
    if (!bid.length) return nil;
    if (self.iconCache == nil) self.iconCache = [NSMutableDictionary dictionary];
    id cached = self.iconCache[bid];
    if (cached) return (cached == [NSNull null]) ? nil : cached;

    UIImage *img = nil;
    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    if (LSApplicationProxy) {
        id proxy = [LSApplicationProxy performSelector:@selector(applicationProxyForIdentifier:)
                                          withObject:bid];
        if (proxy) {
            SEL sel = @selector(iconDataForVariant:);
            NSMethodSignature *sig = [proxy methodSignatureForSelector:sel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:sel];
                [inv setTarget:proxy];
                int variant = 0;
                [inv setArgument:&variant atIndex:2];
                [inv invoke];
                NSData *data = nil;
                [inv getReturnValue:&data];
                if (data.length) img = [UIImage imageWithData:data];
            }
        }
    }
    self.iconCache[bid] = img ?: [NSNull null];
    return img;
}

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
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"c" forIndexPath:indexPath];
    NSDictionary *d = self.items[indexPath.row];
    NSString *title = d[@"title"] ?: @"(无标题)";
    NSString *msg = d[@"message"] ?: @"";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[d[@"ts"] doubleValue]];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"MM-dd HH:mm";
    c.textLabel.text = title;
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@\n%@",
                             d[@"bundle"], [f stringFromDate:date], msg];
    c.detailTextLabel.numberOfLines = 2;
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    UIImage *ic = [self iconForBundle:d[@"bundle"]];
    if (ic) {
        c.imageView.image = ic;
        c.imageView.layer.cornerRadius = 6;
        c.imageView.clipsToBounds = YES;
    }
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = self.items[indexPath.row];
    [NotifyStore markRead:[d[@"id"] integerValue]];
}

@end
