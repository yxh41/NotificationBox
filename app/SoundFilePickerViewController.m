#import "SoundFilePickerViewController.h"
#import "NotifyCommon.h"
#import "NotifyStore.h"
#import "NotifyFilter.h"

// 选一个自定义提示音文件（v0.0.26）
//
// 🔴 三件事必须做到，否则用户会"选了但没声音"并且完全不知道为什么：
//   ① 目录不存在就**在这里建**（App 有写权限；tweak 侧只读，不建目录）；
//   ② 把**完整路径**显示在页脚 —— 用户要拿这个路径去 Filza 里放文件；
//   ③ 空目录时给出**明确的下一步**，而不是一个空白列表。
@interface SoundFilePickerViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSString *> *files;   // 纯文件名
@property (nonatomic, copy) NSString *selected;                    // 当前值（纯文件名，空 = 不用文件）
@property (nonatomic, assign) BOOL dirOK;
@end

@implementation SoundFilePickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"提示音文件";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    id v = [NotifyStore settings][NB_KEY_SOUND_FILE];
    self.selected = [v isKindOfClass:[NSString class]] ? (NSString *)v : @"";
    if (!NBIsSafeSoundFileName(self.selected)) self.selected = @"";

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 52;
    [self.view addSubview:self.table];

    [self reloadFiles];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
}

#pragma mark - 目录与文件

- (void)reloadFiles {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    BOOL exists = [fm fileExistsAtPath:NOTIFYBOX_SOUND_DIR isDirectory:&isDir];

    // 🔴 只在"不存在"时建；存在但不是目录（比如用户拿同名文件占了位置）就保持 NO，
    //    让页脚把原因说出来，而不是偷偷删掉用户的东西。
    if (!exists) {
        NSError *e = nil;
        exists = [fm createDirectoryAtPath:NOTIFYBOX_SOUND_DIR
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:&e];
        NBSharedLog(@"SOUNDDIR 建目录 %@ ⇒ %@", NOTIFYBOX_SOUND_DIR, exists ? @"OK" : (e.localizedDescription ?: @"失败"));
    }
    self.dirOK = (exists && isDir);

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (self.dirOK) {
        NSArray<NSString *> *all = [fm contentsOfDirectoryAtPath:NOTIFYBOX_SOUND_DIR error:NULL];
        for (NSString *n in all) {
            if (!NBIsSafeSoundFileName(n)) continue;
            if (!NBIsSoundFileExt(n)) continue;          // 只列认得的音频
            [out addObject:n];
        }
        // 名字排序（大小写不敏感）：让列表顺序稳定，用户下次进来还能找到上次那个。
        [out sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [a caseInsensitiveCompare:b];
        }];
    }
    self.files = out;
    [self.table reloadData];
}

- (void)pop {
    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : (NSInteger)self.files.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"当前选择";
    return self.files.count ? @"目录里的音频" : @"目录里的音频（空）";
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return self.selected.length
             ? [NSString stringWithFormat:@"正在用文件：%@（会盖过上面的提示音 ID）", self.selected]
             : @"没选文件 ⇒ 用上面那个 1000~1035 的系统提示音 ID（v0.0.25 已验证可用的那条路）";
    }
    if (!self.dirOK) {
        return [NSString stringWithFormat:
                @"目录建不出来：%@\n"
                @"（可能 /var/mobile/Library/NotifyBox 不存在或不可写）", NOTIFYBOX_SOUND_DIR];
    }
    if (!self.files.count) {
        return [NSString stringWithFormat:
                @"把音频放进来就能选：\n%@\n"
                @"支持 %@。放完回到这个页面会自动刷新；没刷新就退出去再进来一次。\n"
                @"⚠️ 超过 30 秒的音频建议先剪短：AudioServices 那条路只播前 30 秒。",
                NOTIFYBOX_SOUND_DIR,
                [NOTIFYBOX_SOUND_EXTS componentsJoinedByString:@"/"]];
    }
    return [NSString stringWithFormat:
            @"目录：%@\n"
            @"⚠️ 试听是在**盒子 App 进程**里播的；通知是在 **SpringBoard 进程**里播的。"
            @"试听能响只能说明这个文件能解码，不能 100%% 保证通知一定响 —— "
            @"如果试听响、通知不响，去看 tweak.log 里的 SOUND# 行。",
            NOTIFYBOX_SOUND_DIR];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"sfcell";
    // 🔴 手动 Subtitle 样式：registerClass 默认样式下 detailTextLabel 不显示（本项目踩过）
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];

    if (ip.section == 0) {
        c.textLabel.text = @"不用文件（用系统提示音 ID）";
        c.detailTextLabel.text = @"v0.0.25 那条路：1000~1035";
        c.accessoryType = self.selected.length ? UITableViewCellAccessoryNone
                                              : UITableViewCellAccessoryCheckmark;
        return c;
    }

    NSString *name = self.files[(NSUInteger)ip.row];
    c.textLabel.text = name;

    // 副标题给"大小 + 能不能被 A 通道吃下"——这两个直接决定"点了会不会响"
    NSString *path = NBSoundFilePath(name);
    NSNumber *sz = nil;
    NSDictionary *attr = path ? [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL] : nil;
    if ([attr[NSFileSize] isKindOfClass:[NSNumber class]]) sz = attr[NSFileSize];
    NSString *sizeText = sz ? [NSByteCountFormatter stringFromByteCount:sz.longLongValue
                                                             countStyle:NSByteCountFormatterCountStyleFile]
                            : @"?";
    NSString *ext = [[name pathExtension] lowercaseString];
    BOOL aOK = [@[@"caf", @"wav", @"aiff", @"aif"] containsObject:ext];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
                              sizeText,
                              aOK ? @"AudioServices（已验证通道）" : @"AVAudioPlayer 兜底"];
    c.accessoryType = [name isEqualToString:self.selected] ? UITableViewCellAccessoryCheckmark
                                                           : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    NSString *pick = @"";
    if (ip.section == 1 && (NSUInteger)ip.row < self.files.count) {
        pick = self.files[(NSUInteger)ip.row];
        // 🔴 选之前先试播一次：把"选了但播不出来"当场暴露，而不是等一条通知来了才发现。
        NSString *detail = nil;
        BOOL ok = [NotifyFilter playSoundFileNamed:pick forResult:&detail];
        if (!ok) {
            // 播不出来就**不保存** —— 保存了只会让用户以为配好了。
            UIAlertController *al = [UIAlertController
                                     alertControllerWithTitle:@"这个文件播不出来"
                                                      message:[NSString stringWithFormat:
                                                               @"%@\n\n文件仍在目录里，但选它不会生效。",
                                                               detail ?: @"原因未知"]
                                              preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:al animated:YES completion:nil];
            return;
        }
    }

    self.selected = pick;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[NotifyStore settings]];
    if (pick.length) d[NB_KEY_SOUND_FILE] = pick;
    else [d removeObjectForKey:NB_KEY_SOUND_FILE];      // 空 = 没这个键 = 用 ID（与别处"清空要能生效"一致）
    [NotifyStore saveSettings:d];
    NBSharedLog(@"SOUNDFILE 选中 = %@", pick.length ? pick : @"(无，用 ID)");

    [self.table reloadData];
    // 🔴 选完就返回上一页：这个页面是"选一个"，不是"编辑多个"。
    //    留在原地会让用户以为还要再点保存（本页没有保存按钮，是**立刻生效**的）。
    [self pop];
}

@end
