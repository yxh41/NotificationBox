#import "VoicePickerViewController.h"
#import "NotifyStore.h"
#import "NotifyCommon.h"
#import "NotifyFilter.h"          // v0.0.30：试听结束后交还音频会话
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#if __has_include(<AVFAudio/AVFAudio.h>)
#import <AVFAudio/AVFAudio.h>
#endif

// 语音选择 + 试听 + 语速

// 语速四档。0.5 是 AVSpeechUtteranceDefaultSpeechRate，也就是"什么都不设"时的值。
// 🔴 只能写成 C 的 const float 数组。写成
//      static NSString *const kNames[4] = {@"慢", ...};
//    ARC 下会报 "initializer element is not a compile-time constant" ——
//    ObjC 对象字面量不能当静态存储期的初始化器。名字用函数返回 NSArray 代替。
static const float kRates[4] = {0.40f, 0.50f, 0.60f, 0.70f};
static NSArray<NSString *> *NBRateNames(void) {
    return @[@"慢", @"正常", @"快", @"很快"];
}

@interface NBVoiceItem : NSObject
@property (nonatomic, copy)   NSString *identifier;   // nil / 空 = 跟随系统
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, copy)   NSString *language;
@property (nonatomic, assign) NSInteger quality;
@end

@implementation NBVoiceItem
@end

@interface VoicePickerViewController () <UITableViewDataSource, UITableViewDelegate, AVSpeechSynthesizerDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NBVoiceItem *> *voices;   // 第 0 项 = 跟随系统
@property (nonatomic, copy)   NSString *selectedId;             // 空 = 跟随系统
@property (nonatomic, assign) float rate;
@property (nonatomic, strong) AVSpeechSynthesizer *preview;     // App 侧试听用
// v0.0.30：标记「这次 stop 是为了接下一句」，用完即复位。
// 🔴 为什么需要它：`stopSpeakingAtBoundary:` 会异步回调 `didCancelSpeechUtterance:`，
//    而那个回调里我们要交还音频会话。可"连点两次试听"时，第一次的 stop 回调
//    是在第二次 `speakUtterance:` 之后才到的 —— 那时新的一句**正在说**。
//    如果看 `preview.speaking` 判断，就依赖"回调一定晚于 speakUtterance 生效"这个时序推断，
//    推断一旦不成立就会把正在说的那句掐断。用显式标志位不依赖任何时序。
@property (nonatomic, assign) BOOL previewStoppedForNew;
- (void)buildVoices;
- (void)persist;
- (void)previewWithText:(NSString *)text;
- (void)onRateChanged:(UISegmentedControl *)sc;
- (NSInteger)rateIndex;
- (float)rateAt:(NSInteger)i;
@end

@implementation VoicePickerViewController

+ (NSString *)currentVoiceDisplayName {
    NSDictionary *d = [NotifyStore settings];
    NSString *idv = d[NB_KEY_SPEAK_VOICE];
    idv = [idv isKindOfClass:[NSString class]] ? idv : nil;
    if (!idv.length) return @"跟随系统";

    // 🔴 存的是 identifier，不是 name。identifier 在不同系统版本上是稳定的，
    //    name 会变（"Ting-Ting" 在某些版本里显示成"婷婷"）。
    //    所以每次都靠 identifier 反查名字，查不到就说明这条语音已经不可用了。
    AVSpeechSynthesisVoice *v = [AVSpeechSynthesisVoice voiceWithIdentifier:idv];
    if (!v) return @"已失效（点进去重选）";
    return v.name.length ? v.name : idv;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"朗读声音";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    NSDictionary *d = [NotifyStore settings];
    NSString *idv = d[NB_KEY_SPEAK_VOICE];
    self.selectedId = [idv isKindOfClass:[NSString class]] ? idv : @"";

    id r = d[NB_KEY_SPEAK_RATE];
    // 🔴 要注意 [nil floatValue] 是 0，不是默认值 —— 所以必须先判类型再取值，
    //    否则"没设过语速"会被当成 0（几乎不动的龟速）。
    self.rate = [r isKindOfClass:[NSNumber class]] ? [(NSNumber *)r floatValue]
                                                   : AVSpeechUtteranceDefaultSpeechRate;
    if (self.rate <= 0.01f) self.rate = AVSpeechUtteranceDefaultSpeechRate;

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 56;
    [self.view addSubview:self.table];

    [self buildVoices];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
}

#pragma mark - 数据

- (void)buildVoices {
    NSMutableArray<NBVoiceItem *> *out = [NSMutableArray array];

    // 第 0 项：跟随系统
    NBVoiceItem *sys = [[NBVoiceItem alloc] init];
    sys.identifier = @"";
    sys.name = @"跟随系统";
    sys.language = @"";
    sys.quality = 0;
    [out addObject:sys];

    NSArray<AVSpeechSynthesisVoice *> *all = [AVSpeechSynthesisVoice speechVoices];
    NSString *sysLang = [AVSpeechSynthesisVoice currentLanguageCode];
    NSString *sysPrefix = [[sysLang componentsSeparatedByString:@"-"] firstObject] ?: @"";

    NSMutableArray<NBVoiceItem *> *zh = [NSMutableArray array];
    NSMutableArray<NBVoiceItem *> *rest = [NSMutableArray array];

    for (AVSpeechSynthesisVoice *v in all) {
        if (!v.identifier.length) continue;
        NBVoiceItem *it = [[NBVoiceItem alloc] init];
        it.identifier = v.identifier;
        it.name = v.name.length ? v.name : v.identifier;
        it.language = v.language ?: @"";
        it.quality = (NSInteger)v.quality;

        // 🔴 按"语言前缀"分组，不是按"是不是中文"硬编码。
        //    系统语言是英文的人最想先看到英文语音，写死中文排序对他就是噪音。
        NSString *prefix = [[it.language componentsSeparatedByString:@"-"] firstObject] ?: @"";
        if (sysPrefix.length && [prefix isEqualToString:sysPrefix]) [zh addObject:it];
        else if ([prefix isEqualToString:@"zh"]) [zh addObject:it];
        else [rest addObject:it];
    }

    // 同一组内：质量高的在前（增强/高级语音明显更自然），再按语言、名字
    NSComparator cmp = ^NSComparisonResult(NBVoiceItem *a, NBVoiceItem *b) {
        if (a.quality != b.quality) return a.quality > b.quality ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult lr = [a.language compare:b.language];
        if (lr != NSOrderedSame) return lr;
        return [a.name localizedStandardCompare:b.name];
    };
    [zh sortUsingComparator:cmp];
    [rest sortUsingComparator:cmp];

    [out addObjectsFromArray:zh];
    [out addObjectsFromArray:rest];
    self.voices = out;

    [self.table reloadData];
}

#pragma mark - 保存

- (void)persist {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[NotifyStore settings]];
    if (self.selectedId.length) d[NB_KEY_SPEAK_VOICE] = self.selectedId;
    else [d removeObjectForKey:NB_KEY_SPEAK_VOICE];     // 空 = 跟随系统 = 没有这个键
    d[NB_KEY_SPEAK_RATE] = @(self.rate);
    [NotifyStore saveSettings:d];
}

#pragma mark - 试听

- (void)previewWithText:(NSString *)text {
    if (!text.length) return;
    @try {
        if (!self.preview) self.preview = [[AVSpeechSynthesizer alloc] init];
        // v0.0.30：必须挂 delegate —— 否则"说完了"这件事没有任何回调可用，
        // 音频会话也就永远没有交还的时机（这正是这一版要修的东西）。
        self.preview.delegate = self;

        // 🔴 App 里必须自己配 audio session。
        //    不配的话，手机静音键一拨就听不到任何声音 —— 用户会以为"选声音没反应"。
        //    Playback = 忽略静音键；duckOthers = 把别人正在放的音乐压低而不是掐断。
        AVAudioSession *s = [AVAudioSession sharedInstance];
        [s setCategory:AVAudioSessionCategoryPlayback
           withOptions:AVAudioSessionCategoryOptionDuckOthers
                 error:nil];
        [s setActive:YES error:nil];

        if (self.preview.speaking) {
            // 先打标记再 stop：这个 stop 是为了接下一句，不是"用户不要听了"
            self.previewStoppedForNew = YES;
            [self.preview stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        }
        AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
        u.rate = self.rate;
        if (self.selectedId.length) {
            AVSpeechSynthesisVoice *v = [AVSpeechSynthesisVoice voiceWithIdentifier:self.selectedId];
            if (v) u.voice = v;
        }
        [self.preview speakUtterance:u];
    } @catch (__unused NSException *e) {
        // 试听失败不影响保存
        // 但别把会话留在 active 状态：试着交还一次（内部会判断有没有人在响）
        [NotifyFilter releaseAudioSessionIfIdle];
    }
}

#pragma mark - v0.0.30：试听结束 ⇒ 交还音频会话

// 说完了 ⇒ 交还。
// ⚠️ 已知精度限制：`didFinish` 之后硬件缓冲里的尾韵可能还有几十毫秒，
//    这里立刻交还可能削掉极短的尾巴。这条只能靠真机听感确认，静态判据证明不了。
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u {
    self.previewStoppedForNew = NO;         // 正常说完，标志位不该残留
    [NotifyFilter releaseAudioSessionIfIdle];
}

// 被 stop 了 ⇒ 只有在"这次停不是为了接下一句"时才交还
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didCancelSpeechUtterance:(AVSpeechUtterance *)u {
    if (self.previewStoppedForNew) {
        self.previewStoppedForNew = NO;
        return;                             // 新的一句已经在说了，交还会把它掐断
    }
    [NotifyFilter releaseAudioSessionIfIdle];
}

// 离开这一页 ⇒ 停掉试听并把会话交还（用户可能试听完直接退出 App）
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    @try {
        if (self.preview.speaking) {
            self.previewStoppedForNew = NO; // 这次是真的不要了
            [self.preview stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        }
    } @catch (__unused NSException *e) { }
    // 幂等：上面没在说也调一次，兜住"回调没来"的情况
    [NotifyFilter releaseAudioSessionIfIdle];
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return (NSInteger)self.voices.count;
    return 1;      // 语速
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        return [NSString stringWithFormat:@"语音（共 %lu 个，系统语言优先）",
                (unsigned long)(self.voices.count > 0 ? self.voices.count - 1 : 0)];
    }
    return @"语速";
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"点一下即选中并试听。想听系统里已装的高级语音（更自然的人声），"
               @"可到 系统设置 → 辅助功能 → 朗读内容 → 声音 下载后再回来。";
    }
    return @"语速只影响通知朗读，不影响系统其它朗读功能。";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    // 🔴 手动 initWithStyle:Subtitle —— registerClass 默认样式下 detailTextLabel 不显示
    static NSString *cid = @"v";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                   reuseIdentifier:cid];
    }

    if (ip.section == 1) {
        NSArray<NSString *> *names = NBRateNames();
        c.textLabel.text = @"语速";
        c.detailTextLabel.text = [NSString stringWithFormat:@"当前：%@（%.2f）",
                                  names[(NSUInteger)[self rateIndex]], self.rate];
        UISegmentedControl *sc = [[UISegmentedControl alloc] initWithItems:names];
        sc.selectedSegmentIndex = [self rateIndex];
        [sc addTarget:self action:@selector(onRateChanged:)
     forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sc;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.imageView.image = nil;
        c.accessoryType = UITableViewCellAccessoryNone;
        c.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        return c;
    }

    c.accessoryView = nil;
    c.selectionStyle = UITableViewCellSelectionStyleDefault;

    NBVoiceItem *it = (ip.row < (NSInteger)self.voices.count) ? self.voices[ip.row] : nil;
    if (!it) return c;

    BOOL on = it.identifier.length
                ? [it.identifier isEqualToString:self.selectedId]
                : (self.selectedId.length == 0);

    c.textLabel.text = it.name;
    c.textLabel.font = [UIFont systemFontOfSize:15];

    NSMutableString *sub = [NSMutableString string];
    if (it.identifier.length) {
        [sub appendString:it.language.length ? it.language : @"?"];
        if (it.quality == (NSInteger)AVSpeechSynthesisVoiceQualityEnhanced) [sub appendString:@"  ·  增强"];
        else if (it.quality == (NSInteger)AVSpeechSynthesisVoiceQualityPremium) [sub appendString:@"  ·  高级"];
        else [sub appendString:@"  ·  标准"];
    } else {
        [sub appendString:@"不指定声音，跟随系统语言"];
    }
    c.detailTextLabel.text = sub;
    c.detailTextLabel.font = [UIFont systemFontOfSize:11];
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    c.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    c.tintColor = [UIColor systemBlueColor];
    c.backgroundColor = on ? [[UIColor systemBlueColor] colorWithAlphaComponent:0.12]
                           : [UIColor secondarySystemGroupedBackgroundColor];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 0) return;
    if (ip.row >= (NSInteger)self.voices.count) return;

    NBVoiceItem *it = self.voices[ip.row];
    self.selectedId = it.identifier.length ? it.identifier : @"";
    [self persist];
    [self.table reloadData];

    // 点了就听 —— 试听文本要短，而且得有中文也得有英文数字，
    // 否则用户判断不出这个声音念通知时是什么样。
    [self previewWithText:@"微信，张三：明天上午 10 点开会，别迟到。"];
}

#pragma mark - 语速

- (NSInteger)rateIndex {
    NSInteger best = 1;
    float diff = 99.0f;
    for (NSInteger i = 0; i < 4; i++) {
        float d = fabsf(self.rate - [self rateAt:i]);
        if (d < diff) { diff = d; best = i; }
    }
    return best;
}

- (float)rateAt:(NSInteger)i {
    return (i >= 0 && i < 4) ? kRates[i] : AVSpeechUtteranceDefaultSpeechRate;
}

- (void)onRateChanged:(UISegmentedControl *)sc {
    NSInteger i = sc.selectedSegmentIndex;
    if (i < 0 || i > 3) return;
    self.rate = [self rateAt:i];
    [self persist];
    [self.table reloadData];
    [self previewWithText:@"语速已调整，这是当前的效果。"];
}

@end
