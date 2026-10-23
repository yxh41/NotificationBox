#import "SoundFilePickerViewController.h"
#import "NotifyCommon.h"
#import "NotifyStore.h"
#import "NotifyFilter.h"
#import <AudioToolbox/AudioToolbox.h>   // 试听系统提示音 ID（与设置页同一条路）

// 选一个自定义提示音（v0.0.26；v0.0.28 起同时服务「默认音」与「某个 App 的音」）
//
// 🔴 三件事必须做到，否则用户会"选了但没声音"并且完全不知道为什么：
//   ① 目录不存在就**在这里建**（App 有写权限；tweak 侧只读，不建目录）；
//   ② 把**完整路径**显示在页脚 —— 用户要拿这个路径去 Filza 里放文件；
//   ③ 空目录时给出**明确的下一步**，而不是一个空白列表。
//
// 🔴 v0.0.28 的分叉只有一个 `self.bundleId`：
//    空 = 写全局（soundFile / soundID）；非空 = 写 soundMap[bundle]。
//    **"选音"的规则两边完全一样**（播不出来的不保存、试听调引擎同一个函数、文件优先于 ID），
//    所以它们必须在这一个文件里 —— 两份实现迟早走岔。
@interface SoundFilePickerViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSString *> *files;   // 纯文件名
@property (nonatomic, copy) NSString *selected;                    // 当前选中的文件名（空 = 不用文件）
@property (nonatomic, assign) BOOL dirOK;

// per-App 模式（bundleId 为空 ⇒ 全局模式）
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, strong) NSDictionary *entry;                 // 只有 per-App 模式用

// 🔴 内部方法一律显式声明（与 AppPickerViewController 顶部那段注释同一个理由：
//    CI 是 -Werror，靠"定义在前面"来解析选择器太脆，多写两行声明最便宜）。
- (BOOL)isPerApp;
- (void)reloadCurrent;
- (NSInteger)currentSID;
- (void)reloadFiles;
- (void)pop;
- (BOOL)commitFile:(NSString *)pick;
- (BOOL)commitSID:(NSInteger)sid;
- (void)failSave;
- (UITableViewCell *)fileCell:(UITableView *)tv at:(NSIndexPath *)ip;
- (void)previewCurrent;
- (void)askSID;
- (void)confirmRemove;
- (void)toast:(NSString *)text;
@end

@implementation SoundFilePickerViewController

- (instancetype)init {
    self = [super init];
    return self;
}

- (instancetype)initWithBundle:(NSString *)bundleId displayName:(NSString *)displayName {
    self = [super init];
    if (self) {
        _bundleId = [bundleId copy];
        _appName = [displayName copy];
    }
    return self;
}

- (BOOL)isPerApp {
    return self.bundleId.length > 0;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if ([self isPerApp]) {
        self.title = [NSString stringWithFormat:@"%@ 的提示音", self.appName.length ? self.appName : self.bundleId];
    } else {
        self.title = @"默认提示音";
    }
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    [self reloadCurrent];

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

#pragma mark - 当前值

// 读当前值。**两个模式读的不是同一个地方**，但都只读一处（引擎侧的口径方法）。
- (void)reloadCurrent {
    if ([self isPerApp]) {
        NSDictionary *map = [NotifyFilter soundMap];
        id e = map[self.bundleId];
        self.entry = [e isKindOfClass:[NSDictionary class]] ? (NSDictionary *)e : nil;
        NSString *f = self.entry[NB_KEY_SOUND_ENTRY_FILE];
        self.selected = [f isKindOfClass:[NSString class]] ? (NSString *)f : @"";
    } else {
        id v = [NotifyStore settings][NB_KEY_SOUND_FILE];
        self.selected = [v isKindOfClass:[NSString class]] ? (NSString *)v : @"";
    }
    if (!NBIsSafeSoundFileName(self.selected)) self.selected = @"";
}

// 当前这个 App 用的系统音 ID（全局模式下是设置页那个全局 ID）。取不到返回 0。
- (NSInteger)currentSID {
    id v = nil;
    if ([self isPerApp]) {
        v = self.entry[NB_KEY_SOUND_ENTRY_ID];
    } else {
        v = [NotifyStore settings][NB_KEY_SOUND_ID];
    }
    NSInteger sid = 0;
    if ([v isKindOfClass:[NSNumber class]])      sid = [(NSNumber *)v integerValue];
    else if ([v isKindOfClass:[NSString class]]) sid = [(NSString *)v integerValue];
    return (sid >= 1000 && sid <= 1035) ? sid : 0;
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
        NBSharedLog(@"SOUNDDIR 建目录 %@ ⇒ %@", NOTIFYBOX_SOUND_DIR,
                    exists ? @"OK" : (e.localizedDescription ?: @"失败"));
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

#pragma mark - 写盘

// 写"这个目标"的文件名。per-App 写 soundMap[bundle] = {file}；全局写 soundFile。
// 🔴 **写一处、删一处**：per-App 模式下不许同时留 id —— 一个 App 只有一个"音"，
//    两个字段并存会让界面不知道该显示哪个（引擎侧 file 优先，但界面上会看着有两个值）。
- (BOOL)commitFile:(NSString *)pick {
    if ([self isPerApp]) {
        NSDictionary *entry = pick.length ? @{NB_KEY_SOUND_ENTRY_FILE: pick} : nil;
        BOOL ok = [NotifyFilter setSoundEntry:entry forBundle:self.bundleId];
        if (ok) {
            self.entry = entry;
            NBSharedLog(@"SOUNDMAP 设 %@ ⇒ %@", self.bundleId, pick.length ? pick : @"(删除分配)");
        }
        return ok;
    }

    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[NotifyStore settings]];
    if (pick.length) d[NB_KEY_SOUND_FILE] = pick;
    else [d removeObjectForKey:NB_KEY_SOUND_FILE];   // 空 = 没这个键 = 用 ID（与别处"清空要能生效"一致）
    BOOL ok = [NotifyStore saveSettings:d];
    if (ok) NBSharedLog(@"SOUNDFILE 默认音 = %@", pick.length ? pick : @"(无，用 ID)");
    return ok;
}

// 写系统提示音 ID。per-App 写 {id}（清掉 file），全局写 soundID。
- (BOOL)commitSID:(NSInteger)sid {
    if ([self isPerApp]) {
        NSDictionary *entry = @{NB_KEY_SOUND_ENTRY_ID: @(sid)};
        BOOL ok = [NotifyFilter setSoundEntry:entry forBundle:self.bundleId];
        if (ok) {
            self.entry = entry;
            self.selected = @"";
            NBSharedLog(@"SOUNDMAP 设 %@ ⇒ id=%ld", self.bundleId, (long)sid);
        }
        return ok;
    }
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[NotifyStore settings]];
    d[NB_KEY_SOUND_ID] = @(sid);
    BOOL ok = [NotifyStore saveSettings:d];
    if (ok) NBSharedLog(@"SOUNDID 默认音 ID = %ld", (long)sid);
    return ok;
}

- (void)failSave {
    UIAlertController *al = [UIAlertController
                             alertControllerWithTitle:@"没写进设置"
                                              message:@"settings.plist 写盘失败（可能目录不可写）。"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return [self isPerApp] ? 4 : 2;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if ([self isPerApp]) {
        if (section == 2) return (NSInteger)self.files.count;
        return 1;                                   // 0=当前 / 1=系统音 ID / 3=删除
    }
    return section == 0 ? 1 : (NSInteger)self.files.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if ([self isPerApp]) {
        switch (section) {
            case 0: return @"当前用的音";
            case 1: return @"或改用系统提示音（1000~1035）";
            case 2: return self.files.count ? @"或选一个音频文件" : @"音频文件（目录里是空的）";
            default: return nil;
        }
    }
    return section == 0 ? @"当前选择" : (self.files.count ? @"目录里的音频" : @"目录里的音频（空）");
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if ([self isPerApp]) {
        if (section == 1) return @"填 1007 就是「三全音」。保存后**留在本页**点最上面那行试听。";
        if (section == 2) {
            return [NSString stringWithFormat:
                    @"目录：%@\n"
                    @"选中时**当场试播**，播不出来就不保存。\n"
                    @"⚠️ 试听是在**盒子 App 进程**里播的；通知是在 **SpringBoard 进程**里播的 —— "
                    @"试听响不等于通知一定响。", NOTIFYBOX_SOUND_DIR];
        }
        if (section == 3) return @"只影响这个 App；其它 App 各自的分配不变。";
        return nil;
    }

    if (section == 0) {
        return self.selected.length
             ? [NSString stringWithFormat:@"正在用文件：%@（会盖过下面的提示音 ID）", self.selected]
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
                @"长音频不用先剪：超过「最长播放秒数」的会自动截断（在上一页设，默认 8 秒）。",
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
    c.accessoryType = UITableViewCellAccessoryNone;
    c.textLabel.textColor = [UIColor labelColor];

    if ([self isPerApp]) {
        if (ip.section == 0) {
            c.textLabel.text = [NotifyFilter soundEntrySummary:self.entry];
            c.detailTextLabel.text = @"点一下试听";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        if (ip.section == 1) {
            NSInteger sid = [self currentSID];
            c.textLabel.text = @"系统提示音 ID";
            c.detailTextLabel.text = sid ? [NSString stringWithFormat:@"%ld", (long)sid] : @"未设置";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        if (ip.section == 3) {
            c.textLabel.text = @"移除这个 App 的分配";
            c.detailTextLabel.text = @"恢复系统原声";
            c.textLabel.textColor = [UIColor systemRedColor];
            return c;
        }
        // section 2：文件
        return [self fileCell:tv at:ip];
    }

    if (ip.section == 0) {
        c.textLabel.text = @"不用文件（用系统提示音 ID）";
        c.detailTextLabel.text = @"v0.0.25 那条路：1000~1035";
        c.accessoryType = self.selected.length ? UITableViewCellAccessoryNone
                                              : UITableViewCellAccessoryCheckmark;
        return c;
    }
    return [self fileCell:tv at:ip];
}

- (UITableViewCell *)fileCell:(UITableView *)tv at:(NSIndexPath *)ip {
    static NSString *fid = @"sffile";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:fid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:fid];

    // 两个模式的"文件"都落在自己那一节里，行号直接就是文件下标
    NSInteger row = ip.row;
    if (row < 0 || row >= (NSInteger)self.files.count) return c;
    NSString *name = self.files[(NSUInteger)row];
    c.textLabel.text = name;
    c.textLabel.textColor = [UIColor labelColor];

    // 副标题给"大小 + 这个文件会怎么播"——这两项直接决定"点了会不会响、会响多久"
    //
    // 🔴 v0.0.27 改口径：**不再按扩展名猜通道**。现在通道是由「文件时长 / 最长播放秒数」
    //    决定的，按扩展名写"这是 A 通道"会直接写错，而用户是照着这行字做判断的。
    NSString *path = NBSoundFilePath(name);
    NSNumber *sz = nil;
    NSDictionary *attr = path ? [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL] : nil;
    if ([attr[NSFileSize] isKindOfClass:[NSNumber class]]) sz = attr[NSFileSize];
    NSString *sizeText = sz ? [NSByteCountFormatter stringFromByteCount:sz.longLongValue
                                                             countStyle:NSByteCountFormatterCountStyleFile]
                            : @"?";
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
                              sizeText,
                              [NotifyFilter playbackPlanForFileNamed:name]];
    c.accessoryType = [name isEqualToString:self.selected] ? UITableViewCellAccessoryCheckmark
                                                          : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    // ---------- per-App 模式 ----------
    if ([self isPerApp]) {
        if (ip.section == 0) {                                  // 当前音 ⇒ 试听
            [self previewCurrent];
            return;
        }
        if (ip.section == 1) {                                  // 填系统音 ID
            [self askSID];
            return;
        }
        if (ip.section == 3) {                                  // 删除分配
            [self confirmRemove];
            return;
        }
    } else {
        if (ip.section == 0) {                                  // 全局：不用文件
            if (![self commitFile:@""]) { [self failSave]; return; }
            self.selected = @"";
            [self.table reloadData];
            [self pop];
            return;
        }
    }

    // ---------- 文件（两个模式共用） ----------
    if (ip.row < 0 || ip.row >= (NSInteger)self.files.count) return;
    NSString *pick = self.files[(NSUInteger)ip.row];

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

    if (![self commitFile:pick]) { [self failSave]; return; }
    self.selected = pick;
    [self.table reloadData];
    // 🔴 选完就返回上一页：这个页面是"选一个"，不是"编辑多个"。
    //    留在原地会让用户以为还要再点保存（本页没有保存按钮，是**立刻生效**的）。
    [self pop];
}

#pragma mark - per-App 的两个动作

- (void)previewCurrent {
    NSInteger sid = [self currentSID];
    if (self.selected.length) {
        NSString *detail = nil;
        BOOL ok = [NotifyFilter playSoundFileNamed:self.selected forResult:&detail];
        [self toast:ok ? [NSString stringWithFormat:@"试听了文件 %@（%@）", self.selected, detail ?: @"?"]
                       : [NSString stringWithFormat:@"播不出来：%@", detail ?: @"原因未知"]];
        return;
    }
    if (sid) {
        AudioServicesPlaySystemSound((SystemSoundID)sid);
        [self toast:[NSString stringWithFormat:@"试听了系统音 %ld", (long)sid]];
        return;
    }
    [self toast:@"这个 App 还没有音：选个文件，或填一个 1000~1035 的系统音 ID"];
}

- (void)askSID {
    NSInteger cur = [self currentSID];
    UIAlertController *al = [UIAlertController
                             alertControllerWithTitle:@"系统提示音 ID"
                                              message:@"1000~1035（1007 = 三全音）"
                                       preferredStyle:UIAlertControllerStyleAlert];
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.placeholder = @"1007";
        tf.text = cur ? [NSString stringWithFormat:@"%ld", (long)cur] : @"";
    }];
    __weak typeof(self) weakSelf = self;
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        NSInteger n = [[al.textFields.firstObject.text
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                       integerValue];
        if (n < 1000 || n > 1035) {
            [weakSelf toast:@"ID 必须在 1000~1035 之间（原值未改）"];
            return;
        }
        if (![weakSelf commitSID:n]) { [weakSelf failSave]; return; }
        [weakSelf.table reloadData];
        // 🔴 不 pop：保存完**留在本页**，用户点最上面那行就能试听。
        //    如果直接返回，他就得再进来一次才能听 —— 而"没听过就走"正是
        //    "配了但不知道对不对"的来源。
        [weakSelf toast:[NSString stringWithFormat:@"已保存系统音 %ld，点最上面那行可以试听", (long)n]];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)confirmRemove {
    UIAlertController *al = [UIAlertController
                             alertControllerWithTitle:@"移除这个 App 的分配？"
                                              message:[NSString stringWithFormat:
                                                       @"%@ 的通知会恢复系统原声（其它 App 不受影响）。",
                                                       self.appName.length ? self.appName : self.bundleId]
                                       preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:@"移除" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        if (![weakSelf commitFile:@""]) { [weakSelf failSave]; return; }
        [weakSelf pop];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)toast:(NSString *)text {
    NBSharedLog(@"SOUNDFILE %@", text);
    UIAlertController *al = [UIAlertController alertControllerWithTitle:nil
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

@end
