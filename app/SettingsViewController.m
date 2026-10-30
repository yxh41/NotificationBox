#import "SettingsViewController.h"
#import <AudioToolbox/AudioToolbox.h>   // v0.0.21：试听系统提示音（AudioServicesPlaySystemSound）
#import "NotifyStore.h"
#import "NotifyCommon.h"
// v0.0.26：试听自定义音频文件时必须调**引擎里那同一个**播放函数。
// 🔴 不能在 App 里再写一份 AVAudioPlayer / AudioServices 调用 ——
//    两份播放逻辑一旦走岔，试听能响而通知不响，而这正是最难查的一类症状。
#import "NotifyFilter.h"
#import "ReplaceRulesViewController.h"
#import "AppPickerViewController.h"
#import "VoicePickerViewController.h"
#import "SoundFilePickerViewController.h"
// v0.0.28：按 App 分配提示音的总览页（列表 + 进子页改音）
#import "SoundAppsViewController.h"
#import "InstalledApps.h"
#import "NotifyStatsViewController.h"
#import "KeywordRulesViewController.h"
// v0.0.71：统一视觉层（颜色 / 圆角 / 图标 / 分组卡片的唯一来源）
#import "NBTheme.h"
#import <errno.h>
#import <string.h>

// 内置设置页：记录上限 / 白名单 / 黑名单 / 过滤关键词 / 朗读
//
// 🔴 保存目标是 NOTIFYBOX_SETTINGS_PATH（/var/mobile/Library/NotifyBox/settings.plist），
//    不是 Preferences 域：那个域归 cfprefsd 管，App 直接写文件会被它的缓存盖回去。
// 🔴 保存后**不需要 respring**：tweak 侧每来一条通知都会重新读这个文件（NBLoadSettings）。
//
// 🔴🔴 v0.0.13 结构改动：原来布局是「先排所有开关、再排所有输入框、再排所有按钮」，
//    三组各排各的 ⇒ 想让一行入口按钮夹在两个输入框中间**做不到**。
//    现在改成**一个 rows 数组按加入顺序排**，每行的类型存在自己的 tag 里。
//    这不是为了好看 —— 是为了以后加/删/挪一行不用改布局代码。

static const NSInteger kRowSwitch = 1;   // 图标 + 标题(+副标题) + UISwitch
static const NSInteger kRowField  = 2;   // 图标 + 标题 + 右侧输入框
static const NSInteger kRowAction = 3;   // 图标 + 标题(+副标题) + 右侧取值 + chevron

// box 的 tag 表示"行类型"，子视图 tag 一律从 101 起，两套编号互不干扰
// （viewWithTag: 只搜子树，不会返回 receiver 自己）
static const NSInteger kSubTitle  = 101;
static const NSInteger kSubSub    = 102;   // 副标题（灰色第二行）
static const NSInteger kSubField  = 103;
static const NSInteger kSubSwitch = 104;
static const NSInteger kSubValue  = 105;
static const NSInteger kSubHit    = 106;
static const NSInteger kSubIcon   = 107;
static const NSInteger kSubChev   = 108;
static const NSInteger kSubSep    = 109;   // 卡片内的行分隔线（layout 时懒建）

// ---------- v0.0.71 统一几何（见 NBTheme.h 的 token 说明） ----------
static const CGFloat kIconX = 16.0;    // 图标左边距
static const CGFloat kTextX = 56.0;    // 行文字起点 = 16 + 28(图标) + 12(间距)
static const CGFloat kPadR  = 16.0;    // 右侧内边距
static const CGFloat kSecGap = 26.0;   // 组与组之间的间距
static const CGFloat kHeadGap = 8.0;   // 组标题与卡片之间

// 🔴 v0.0.19：这里原来有个 `NBIsDigits()`，只被"延迟秒数"那个字段用。
//    延迟功能删掉之后它变成死代码，`-Werror -Wunused-function` 直接把编译打断
//    （CI 报：unused function 'NBIsDigits'）。
//    ⇒ 删功能时必须连带清掉**只有它用的辅助函数**，否则编译期就拦你；
//      这类连带影响不会在"读代码"时被发现，只有真编一次才知道。
//    它当初要解决的问题留着当教训：`[@"abc" integerValue]` 是 0，跟"用户填了 0"
//    分不开 ⇒ 任何"数字输入"字段都不能只用 integerValue 判对错。

@interface SettingsViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scroll;
// 🔴 v0.0.71：结构从「一串平铺的行」改成「分组 → 组卡片 → 行」。
//    原来 20 多行一个接一个排下来、中间一个标题都没有，用户只能靠"上下滑到第几行"
//    来认位置；说明文字又是一整屏的灰字堆在底部。现在按话题分 7 组，
//    每组一个白卡片、一个灰标题、必要时一条灰脚注。
//    ⚠️ 行本身仍然是"一个 UIView + tag"那套（tag 区分行类型，子视图 tag 从 101 起）——
//      换掉的只是**容器与排布**，保存/校验/跳转逻辑一行没动。
@property (nonatomic, strong) NSMutableArray<NSMutableArray<UIView *> *> *secRows;
@property (nonatomic, strong) NSMutableArray<NSString *> *secTitles;
@property (nonatomic, strong) NSMutableArray<NSString *> *secFooters;
@property (nonatomic, strong) NSMutableArray<UIView *> *secCards;
@property (nonatomic, strong) NSMutableArray *secHeaderLabels;   // UILabel 或 NSNull
@property (nonatomic, strong) NSMutableArray *secFooterLabels;   // UILabel 或 NSNull
@property (nonatomic, strong) NSMutableArray<UITextField *> *fields;
// 🔴 每个输入框对应哪个设置键，**跟着字段一起存**。
//    写死下标的话，只要在中间插一个新字段，后面所有键就整体错位一格：
//    用户改"记录上限"，实际写进了"过滤关键词"。保存成功、回读一致、就是不生效。
@property (nonatomic, strong) NSMutableArray<NSString *> *fieldKeys;
// 🔴 v0.0.21：开关从"一个属性"改成"按 key 存"。
//    这是兑现 addSwitchRow 里早就写下的警告 ——
//    原来三个开关会全挂到同一个属性上，最后建的那个覆盖前面的，
//    症状是"我明明开了免打扰，一保存自己变回关"，而且**完全不报错**。
@property (nonatomic, strong) NSMutableDictionary<NSString *, UISwitch *> *switches;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *actionRows;
@property (nonatomic, strong) UILabel *statusLabel;

- (void)addSection:(NSString *)title footer:(NSString *)footer;
- (void)addSwitchRow:(NSString *)title
                 sub:(NSString *)sub
                icon:(NSString *)sym
                tint:(UIColor *)tint
                  on:(BOOL)on
                 key:(NSString *)key;
- (void)addActionRow:(NSString *)title
                 sub:(NSString *)sub
                icon:(NSString *)sym
                tint:(UIColor *)tint
                 key:(NSString *)key
         destructive:(BOOL)destructive
              action:(SEL)sel;
- (void)addFieldRow:(NSString *)title
               icon:(NSString *)sym
               tint:(UIColor *)tint
                 ph:(NSString *)ph
              value:(NSString *)value
           keyboard:(UIKeyboardType)kb
                key:(NSString *)key;
- (CGFloat)rowHeight:(UIView *)box width:(CGFloat)cw;
- (void)layoutRow:(UIView *)box width:(CGFloat)cw height:(CGFloat)h;
- (NSMutableArray<UIView *> *)currentRows;
- (void)attachIcon:(NSString *)sym tint:(UIColor *)tint to:(UIView *)box;
- (void)attachTitle:(NSString *)title sub:(NSString *)sub to:(UIView *)box;
- (void)onUsage:(id)sender;
- (NSString *)usageText;
- (void)refreshActionValues;
- (void)setActionValue:(NSString *)text forKey:(NSString *)key;
- (NSString *)strOf:(id)v;
- (BOOL)boolOf:(id)v;
- (NSString *)trim:(NSString *)s;
- (void)onSave:(id)sender;
- (void)onClose:(id)sender;
- (void)onReplace:(id)sender;
- (void)onClearAll:(id)sender;
// v0.0.45 批量清理。**必须显式声明**：`onBatchClean:` 要调 `pickAppToClean`，
// 而后者定义在它**之后** —— 项目开 -Werror，靠定义顺序解析选择器会直接编不过。
- (void)onBatchClean:(id)sender;
- (void)onStats:(id)sender;
- (void)confirmDeleteTitle:(NSString *)title
                    bundle:(NSString *)bundle
                  beforeTs:(NSTimeInterval)beforeTs
                  readOnly:(BOOL)readOnly;
- (void)pickAppToClean;
- (void)onWhite:(id)sender;
- (void)onBlack:(id)sender;
// v0.0.51：连记录都不要（per-App 名单）
- (void)onNoRecordApps:(id)sender;
- (void)onSpeakApps:(id)sender;
- (void)onDndApps:(id)sender;
- (void)onSoundApps:(id)sender;
- (void)onSoundFile:(id)sender;
- (void)onSoundPreview:(id)sender;
- (NSString *)timeText:(id)v;
- (void)onVoice:(id)sender;
- (void)onAppDiag:(id)sender;
- (void)onKeywordRules:(id)sender;
- (void)fail:(NSString *)msg;
- (void)onKeyboard:(NSNotification *)n;
@end

@implementation SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.view.backgroundColor = NBPageBG();
    // 本页是表单、不是内容列表 ⇒ 不跟首页抢大标题
    // 🔴 常量全名是 `UINavigationItemLargeTitleDisplayModeNever`，不是
    //    `UILargeTitleDisplayModeNever`（少了 `UINavigationItem` 前缀，编译期直接报
    //    "use of undeclared identifier"，而这类错**只有真编译才能发现**）。
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    // v0.0.71：左侧由文字「关闭」改成 ‹ 返回箭头（它本来就是 push 进来的，
    //    用"关闭"会让人以为这是个弹窗；而且文字按钮在窄屏上会挤掉中间的标题）。
    UIImage *back = [UIImage systemImageNamed:@"chevron.left"];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:back
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(onClose:)];
    // 🔴 左右分工要清楚：左边返回=放弃本页输入框的改动，右边保存=落盘。
    //    子页面（黑白名单/声音/替换规则）是"点一下立即生效"，本页是"表单要按保存"——
    //    两种模式并存不统一，但各自都符合用户当下的预期：选东西时不想再点保存，
    //    改数字时不想被"点一下就存"绑架。
    UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                                            style:UIBarButtonItemStyleDone
                                                           target:self action:@selector(onSave:)];
    save.tintColor = [UIColor systemBlueColor];
    self.navigationItem.rightBarButtonItem = save;

    self.scroll = [[UIScrollView alloc] init];
    self.scroll.alwaysBounceVertical = YES;
    self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.scroll.backgroundColor = NBPageBG();
    [self.view addSubview:self.scroll];

    self.secRows = [NSMutableArray array];
    self.secTitles = [NSMutableArray array];
    self.secFooters = [NSMutableArray array];
    self.secCards = [NSMutableArray array];
    self.secHeaderLabels = [NSMutableArray array];
    self.secFooterLabels = [NSMutableArray array];
    self.fields = [NSMutableArray array];
    self.fieldKeys = [NSMutableArray array];
    self.actionRows = [NSMutableDictionary dictionary];
    self.switches = [NSMutableDictionary dictionary];

    NSDictionary *cur = NBLoadSettings();

    // =====================================================================
    // v0.0.71：设置项按话题分 7 组。
    // 🔴 分组的依据不是"代码里谁挨着谁"，而是**用户心里的赛道**：
    //    念出来 / 别吵我 / 怎么响 / 留多少 / 挡什么 / 干活 / 关于。
    //    说明文字从行标题里搬进每组底部的灰脚注 —— 标题短了才扫得快，
    //    现在的 iOS 设置页就是这个套路（标题一行、解释在组尾）。
    // =====================================================================

    UIColor *blue   = [UIColor systemBlueColor];
    UIColor *indigo = [UIColor systemIndigoColor];
    UIColor *orange = [UIColor systemOrangeColor];
    UIColor *teal   = [UIColor systemTealColor];
    UIColor *purple = [UIColor systemPurpleColor];
    UIColor *gray   = [UIColor systemGrayColor];

    // ---------- 1. 朗读 ----------
    [self addSection:@"朗读"
              footer:@"打开后会占用音频通道，可能让正在播放的音乐变小或暂停 —— "
                     @"这是系统语音合成的固有行为，不是故障。"
                     @"朗读只念「替换后」的文字；被过滤规则拦下的通知不念。"
                     @"若朗读导致桌面崩溃重启，插件会在下次开机时自动把朗读关掉。"];
    [self addSwitchRow:@"朗读通知"
                   sub:@"用系统语音念出通知内容"
                  icon:@"speaker.wave.2.fill"
                  tint:blue
                    on:[self boolOf:cur[NB_KEY_SPEAK_ENABLED]]
                   key:NB_KEY_SPEAK_ENABLED];
    [self addActionRow:@"朗读声音" sub:nil icon:@"waveform" tint:blue
                   key:@"voice" destructive:NO action:@selector(onVoice:)];
    [self addActionRow:@"朗读限定 App" sub:nil icon:@"square.grid.2x2.fill" tint:blue
                   key:@"speakapps" destructive:NO action:@selector(onSpeakApps:)];

    // ---------- 2. 免打扰 ----------
    // v0.0.21：这是删掉「延迟推送」之后的安全替代。
    // 延迟想解决的其实是"别在某个时间点吵我"，而它必须**改系统的发布时间**才能做到
    // （两次撞死）；这里只是**我们自己不弹**，不碰 BB 内部 ⇒ 零系统风险。
    [self addSection:@"免打扰"
              footer:@"可跨零点，例如 23:00 → 07:00。"
                     @"只影响「弹不弹」，记录照旧落库。"];
    [self addSwitchRow:@"免打扰时段"
                   sub:@"这段时间不弹，但仍然记录"
                  icon:@"moon.fill"
                  tint:indigo
                    on:[self boolOf:cur[NB_KEY_DND_ENABLED]]
                   key:NB_KEY_DND_ENABLED];
    [self addFieldRow:@"开始时间" icon:@"clock.fill" tint:indigo
                   ph:@"23:00" value:[self timeText:cur[NB_KEY_DND_START]]
             keyboard:UIKeyboardTypeNumbersAndPunctuation key:NB_KEY_DND_START];
    [self addFieldRow:@"结束时间" icon:@"clock.fill" tint:indigo
                   ph:@"07:00" value:[self timeText:cur[NB_KEY_DND_END]]
             keyboard:UIKeyboardTypeNumbersAndPunctuation key:NB_KEY_DND_END];
    [self addActionRow:@"免打扰生效的 App" sub:nil icon:@"bell.slash.fill" tint:indigo
                   key:@"dndapps" destructive:NO action:@selector(onDndApps:)];

    // ---------- 3. 提示音 ----------
    // 🔴 真机 PROBE 数据说明这是"造系统对象"：默认提示音**不带 BBSound**（sound=nil），
    //    而 BBSound 没有工厂方法、alertType 只读 ⇒ 只能 alloc + 填 soundType/systemSoundID。
    //    失败的表现是"这条通知不出声"。所以：默认关、必须点名 App、可试听、每次留痕、有自愈。
    [self addSection:@"提示音（实验）"
              footer:@"文件优先于 ID。秒数 0 = 不限，清空 = 默认 8 秒。"
                     @"「压低音乐」只对长提示音有效 —— 短促的系统音走的是另一条通道，"
                     @"系统不允许它去抢音频会话，这不是开关坏了。"];
    [self addSwitchRow:@"按 App 换提示音"
                   sub:@"实验功能，默认关闭"
                  icon:@"music.note"
                  tint:orange
                    on:[self boolOf:cur[NB_KEY_SOUND_ENABLED]]
                   key:NB_KEY_SOUND_ENABLED];
    [self addFieldRow:@"默认提示音 ID" icon:@"number" tint:orange
                   ph:@"1007" value:[self strOf:cur[NB_KEY_SOUND_ID]]
             keyboard:UIKeyboardTypeNumberPad key:NB_KEY_SOUND_ID];
    // 🔴🔴 v0.0.26：自定义音频文件。**排在 ID 下面**，因为它的优先级比 ID 高 ——
    //    顺序即语义，用户从上往下读："先看有没有文件，没有才用 ID"。
    [self addActionRow:@"默认提示音文件" sub:@"优先于上面的 ID" icon:@"doc.fill" tint:orange
                   key:@"soundfile" destructive:NO action:@selector(onSoundFile:)];
    // v0.0.27：最长播放秒数。**排在文件下面**：它管的是"播多久"，紧跟着"播什么"讲。
    // 🔴 为什么必须有这一项：v0.0.26 实测出不一致 —— 同一份设置，wav 最多响 30 秒
    //    （A 通道没有 stop API，系统硬上限），mp3 从头响到尾（B 通道能 stop）。
    [self addFieldRow:@"最长播放秒数" icon:@"timer" tint:orange
                   ph:@"8（默认）" value:[self strOf:cur[NB_KEY_SOUND_MAX_SEC]]
             keyboard:UIKeyboardTypeDecimalPad key:NB_KEY_SOUND_MAX_SEC];
    [self addActionRow:@"按 App 分配提示音" sub:nil icon:@"square.grid.2x2.fill" tint:orange
                   key:@"soundapps" destructive:NO action:@selector(onSoundApps:)];
    [self addActionRow:@"试听这个提示音" sub:nil icon:@"play.circle.fill" tint:orange
                   key:@"soundpreview" destructive:NO action:@selector(onSoundPreview:)];
    [self addSwitchRow:@"来通知时压低音乐"
                   sub:@"只对长提示音有效"
                  icon:@"speaker.slash.fill"
                  tint:orange
                    on:[self boolOf:cur[NB_KEY_SOUND_DUCK_OTHERS]]
                   key:NB_KEY_SOUND_DUCK_OTHERS];

    // ---------- 4. 记录 ----------
    [self addSection:@"记录与清理"
              footer:@"上限默认 500，超出后淘汰最旧的。"
                     @"列表一次最多显示 2000 条：上限填得更大时，更早的记录翻不到，"
                     @"要用首页的「导出」才能看到（导出不受此限）。"
                     @"「自动清理」按时间裁，填 0 或清空 = 关闭，与上限各自独立生效。"];
    id mx = cur[@"maxRecords"];
    NSString *mxStr = [mx respondsToSelector:@selector(stringValue)] ? [mx stringValue]
                     : ([mx isKindOfClass:[NSString class]] ? (NSString *)mx : @"");
    [self addFieldRow:@"记录上限" icon:@"tray.full.fill" tint:teal
                   ph:@"500" value:mxStr
             keyboard:UIKeyboardTypeNumberPad key:@"maxRecords"];
    // v0.0.47：自动清理「保留最近 N 天」（0 = 关闭，默认）。
    // 🔴 这是"更老的都不要了"，连未读一起删；和"记录上限"是两件事。
    NSInteger acd = [NotifyStore autoCleanDays];
    [self addFieldRow:@"自动清理天数" icon:@"arrow.counterclockwise.circle.fill" tint:teal
                   ph:@"0" value:(acd > 0 ? [NSString stringWithFormat:@"%ld", (long)acd] : @"")
             keyboard:UIKeyboardTypeNumberPad key:@"autoCleanDays"];
    // ---------- 删除盒子记录时同步清系统通知中心（v0.0.52） ----------
    // 🔴 精确 1:1：盒子上删某一条记录时，如果该通知在系统通知中心还挂着，
    //    就把它从通知中心也删掉（只删那一条，不是按 App 整段清）。
    //    🔴 批量清理 / 清空全部**不触发**本开关（见 NotifyStore 注释）：那是"清日志"，语义不同。
    [self addSwitchRow:@"删记录时同步清通知中心"
                   sub:@"只删对应的那一条"
                  icon:@"bell.fill"
                  tint:teal
                    on:[self boolOf:cur[NB_KEY_SYNC_CLEAR]]
                   key:NB_KEY_SYNC_CLEAR];
    // ---------- v0.0.85：精确 ID 落空时按内容兜底 ----------
    // 🔴 为什么需要这个开关：系统把同一条通知重投一次就会分配**新 ID**，
    //    盒子里那行存的旧 ID 于是永远匹配不上 ⇒ 表现是「删了没反应」。
    //    兜底 = 拿记录里的 title/message 去通知中心里找，**同 App + 同标题 + 同内容
    //    且只命中 1 条**才动手；命中多条一律不动（分不清就不猜）。
    //    🔴 默认**开**：它是"精确 ID 落空时"的最后一步，不改变精确匹配的行为。
    //    留开关是因为它有可能删掉"内容相同但其实是另一条"的通知，得让用户能关。
    {
        NSNumber *cf = cur[NB_KEY_CONTENT_FALLBACK];
        [self addSwitchRow:@"ID 对不上时按内容兜底"
                       sub:@"同 App 同内容只命中 1 条才动手"
                      icon:@"text.magnifyingglass"
                      tint:teal
                        on:(cf ? [cf boolValue] : YES)
                       key:NB_KEY_CONTENT_FALLBACK];
    }

    // ---------- 5. 拦截与过滤 ----------
    // v0.0.51：单独一区、排在「黑白名单」**之前**：流水线上先记录后过滤——
    //    这个名单管"记不记"，下面那组管"弹不弹"。放一起才看得出两段的分工，
    //    用户也不会把"不记录"误当成"第二个黑名单"。
    [self addSection:@"拦截与过滤"
              footer:@"「不记录的 App」管记不记，「白名单 / 黑名单」管弹不弹 —— "
                     @"两回事，可以同时生效。被拦下的通知仍然会记进盒子里，"
                     @"方便回头查本来要推什么。"
                     @"白名单一旦填了，就等于「只保留这些 App」，其它全部不弹（有杀伤力）。"];
    [self addActionRow:@"不记录的 App" sub:@"连记录都不留" icon:@"eye.slash.fill" tint:purple
                   key:@"norecord" destructive:NO action:@selector(onNoRecordApps:)];
    [self addActionRow:@"白名单" sub:@"只推送这些" icon:@"checkmark.circle.fill" tint:purple
                   key:@"white" destructive:NO action:@selector(onWhite:)];
    [self addActionRow:@"黑名单" sub:@"不推送这些" icon:@"nosign" tint:purple
                   key:@"black" destructive:NO action:@selector(onBlack:)];
    [self addFieldRow:@"过滤关键词" icon:@"line.3.horizontal.decrease.circle.fill" tint:purple
                   ph:@"红包,限时" value:[self strOf:cur[@"blockKeywords"]]
             keyboard:UIKeyboardTypeDefault key:@"blockKeywords"];

    // ---------- 6. 工具 ----------
    [self addSection:@"工具" footer:nil];
    [self addActionRow:@"内容替换规则" sub:@"只改通知上显示的文字"
                  icon:@"arrow.left.arrow.right" tint:gray
                   key:@"replace" destructive:NO action:@selector(onReplace:)];
    // v0.0.48：关键词规则（标星 / 自动折叠）
    [self addActionRow:@"关键词规则" sub:@"标星 / 自动折叠" icon:@"tag.fill" tint:gray
                   key:@"kwrule" destructive:NO action:@selector(onKeywordRules:)];
    // v0.0.46：统计，排在"诊断"之前 —— 诊断是排查用的，统计是天天想看的。
    [self addActionRow:@"统计" sub:@"哪个 App 最烦人" icon:@"chart.bar.fill" tint:gray
                   key:@"stats" destructive:NO action:@selector(onStats:)];
    // v0.0.45：批量清理。**放在「清空全部记录」上面** ——
    // 用户想清的是"某一批"，而"全清"是那个操作的极端形式；
    // 把"更常用、更安全的"排在前面，能少一点误点全清。
    [self addActionRow:@"批量清理记录" sub:@"按时间 / 已读 / 某个 App"
                  icon:@"archivebox.fill" tint:gray
                   key:@"batchclean" destructive:NO action:@selector(onBatchClean:)];
    [self addActionRow:@"清空全部记录" sub:nil icon:@"trash.fill" tint:[UIColor systemRedColor]
                   key:@"clear" destructive:YES action:@selector(onClearAll:)];
    [self addActionRow:@"App 枚举诊断" sub:@"排查用" icon:@"magnifyingglass" tint:gray
                   key:@"appdiag" destructive:NO action:@selector(onAppDiag:)];

    // ---------- 7. 关于 ----------
    // 🔴 v0.0.71：原来那一整屏「说明」灰字（二十多条）搬进了独立页面。
    //    原因很实际：它比所有设置项加起来还长，压在最底下 ⇒
    //    想改设置要滑过一整屏说明，想查说明又要滑过所有设置。
    //    文字一个字没删，只是从"堆在设置页底部"改成"点进去看"。
    [self addSection:@"关于"
              footer:@"保存后立即生效，不用 respring。\n"
                     @"设置文件：/var/mobile/Library/NotifyBox/settings.plist"];
    [self addActionRow:@"使用说明" sub:@"每条设置到底管什么"
                  icon:@"questionmark.circle.fill" tint:gray
                   key:@"usage" destructive:NO action:@selector(onUsage:)];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [NBFontSub() fontWithSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    [self.scroll addSubview:self.statusLabel];


    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onKeyboard:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];

    [self refreshActionValues];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 🔴 从子页面返回时必须刷新：用户在里面选了 3 个 App，回到这里还显示旧数字，
    //    他会以为没保存成功，然后再进去一遍。**状态不可见 = 功能不存在。**
    [self refreshActionValues];
}

#pragma mark - 行的创建

// ---------- 分组 ----------
// 每组一个白卡片 + 一个灰标题 + 可选灰脚注。
// 🔴 卡片只在 layout 里摆放（builder 里不做 frame）：所有位置由同一处几何代码算，
//    否则"谁最后设置 frame 谁说了算"——那正是 v0.0.13 之前那套平铺布局的老毛病。
- (void)addSection:(NSString *)title footer:(NSString *)footer {
    NSMutableArray<UIView *> *rows = [NSMutableArray array];
    [self.secRows addObject:rows];
    [self.secTitles addObject:title ?: @""];
    [self.secFooters addObject:footer ?: @""];

    UIView *card = NBNewCard();
    [self.scroll addSubview:card];
    [self.secCards addObject:card];

    UILabel *head = title.length ? NBNewHeaderLabel(title) : nil;
    if (head) [self.scroll addSubview:head];
    [self.secHeaderLabels addObject:head ?: (id)[NSNull null]];

    UILabel *foot = footer.length ? NBNewFooterLabel(footer) : nil;
    if (foot) [self.scroll addSubview:foot];
    [self.secFooterLabels addObject:foot ?: (id)[NSNull null]];
}

// 当前这一组的行数组（没调过 addSection 就自动开一组无名分组，防崩）
- (NSMutableArray<UIView *> *)currentRows {
    if (!self.secRows.count) [self addSection:nil footer:nil];
    return self.secRows.lastObject;
}

// 每行统一的左半边：彩色图标方块
- (void)attachIcon:(NSString *)sym tint:(UIColor *)tint to:(UIView *)box {
    UIView *icon = NBNewIconBox(sym, tint);
    icon.tag = kSubIcon;
    [box addSubview:icon];
}

// 每行统一的标题（+可选副标题）
- (void)attachTitle:(NSString *)title sub:(NSString *)sub to:(UIView *)box {
    UILabel *l = [[UILabel alloc] init];
    l.text = title;
    l.font = NBFontTitle();
    l.textColor = [UIColor labelColor];
    l.numberOfLines = 2;
    l.tag = kSubTitle;
    [box addSubview:l];

    if (sub.length) {
        UILabel *s = [[UILabel alloc] init];
        s.text = sub;
        s.font = NBFontSub();
        s.textColor = NBSubColor();
        s.numberOfLines = 2;
        s.tag = kSubSub;
        [box addSubview:s];
    }
}

// ---------- 开关行 ----------
- (void)addSwitchRow:(NSString *)title
                 sub:(NSString *)sub
                icon:(NSString *)sym
                tint:(UIColor *)tint
                  on:(BOOL)on
                 key:(NSString *)key {
    UIView *box = [[UIView alloc] init];
    box.tag = kRowSwitch;
    box.backgroundColor = [UIColor clearColor];       // 白底由外面的卡片出

    [self attachIcon:sym tint:tint to:box];
    [self attachTitle:title sub:sub to:box];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.tag = kSubSwitch;
    // iOS 13+ 的开关自带尺寸，不写死宽度（大字号/无障碍下写死会被裁）
    [box addSubview:sw];
    // 🔴 按 key 存（v0.0.21 兑现了这里原本的警告）。
    if (key.length && self.switches) self.switches[key] = sw;

    [[self currentRows] addObject:box];
    [self.secCards.lastObject addSubview:box];
}

// ---------- 输入行 ----------
- (void)addFieldRow:(NSString *)title
               icon:(NSString *)sym
               tint:(UIColor *)tint
                 ph:(NSString *)ph
              value:(NSString *)value
           keyboard:(UIKeyboardType)kb
                key:(NSString *)key {
    UIView *box = [[UIView alloc] init];
    box.tag = kRowField;
    box.backgroundColor = [UIColor clearColor];

    [self attachIcon:sym tint:tint to:box];
    [self attachTitle:title sub:nil to:box];

    UITextField *f = [[UITextField alloc] init];
    f.text = value.length ? value : @"";
    f.placeholder = ph;
    f.keyboardType = kb;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.borderStyle = UITextBorderStyleNone;
    f.textAlignment = NSTextAlignmentRight;
    f.font = NBFontField();
    f.textColor = [UIColor labelColor];
    f.delegate = self;
    f.returnKeyType = UIReturnKeyDone;
    f.tag = kSubField;
    [box addSubview:f];

    [[self currentRows] addObject:box];
    [self.secCards.lastObject addSubview:box];
    [self.fields addObject:f];
    [self.fieldKeys addObject:key ?: @""];
}

// ---------- 入口行（可点，右侧取值 + chevron） ----------
- (void)addActionRow:(NSString *)title
                 sub:(NSString *)sub
                icon:(NSString *)sym
                tint:(UIColor *)tint
                 key:(NSString *)key
         destructive:(BOOL)destructive
              action:(SEL)sel {
    UIView *box = [[UIView alloc] init];
    box.tag = kRowAction;
    box.backgroundColor = [UIColor clearColor];

    [self attachIcon:sym tint:tint to:box];
    [self attachTitle:title sub:sub to:box];
    if (destructive) {
        UILabel *l = (UILabel *)[box viewWithTag:kSubTitle];
        l.textColor = [UIColor systemRedColor];
    }

    UILabel *v = [[UILabel alloc] init];
    v.font = NBFontValue();
    v.textColor = NBValueColor();
    v.textAlignment = NSTextAlignmentRight;
    v.numberOfLines = 1;
    v.lineBreakMode = NSLineBreakByTruncatingTail;
    v.tag = kSubValue;
    [box addSubview:v];

    // 右侧箭头用真图标，不再靠文字里手写 " ›"（那个在深色/大字号下会歪）
    UIImageView *chev = NBNewChevron();
    chev.tag = kSubChev;
    [box addSubview:chev];

    // 透明按钮铺满整行接收点击。用 UIButton 而不是 UITapGestureRecognizer：
    // 手势会和 UIScrollView 的滑动打架（滑一下被当成点击）。
    UIButton *hit = [UIButton buttonWithType:UIButtonTypeCustom];
    hit.tag = kSubHit;
    [hit addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:hit];

    [[self currentRows] addObject:box];
    [self.secCards.lastObject addSubview:box];
    if (key.length) self.actionRows[key] = box;
}

// ---------- 自适应行高 ----------
// 🔴 每行的高度必须由**文字实际占多少**决定，不能写死：
//    标题允许 2 行（"删记录时同步清通知中心"在 320pt 窄屏要换行），
//    写死 50 的话第二行字会被裁掉，而界面上看不出来"被裁了"、只像少了一句话。
- (CGFloat)rowHeight:(UIView *)box width:(CGFloat)cw {
    NSInteger kind = box.tag;
    UILabel *t = (UILabel *)[box viewWithTag:kSubTitle];
    UILabel *s = (UILabel *)[box viewWithTag:kSubSub];

    CGFloat rightW = 0;
    if (kind == kRowSwitch) {
        UIView *sw = [box viewWithTag:kSubSwitch];
        CGSize sz = [sw intrinsicContentSize];
        if (sz.width <= 0 || sz.height <= 0) sz = CGSizeMake(51, 31);
        rightW = sz.width + 12;
    } else if (kind == kRowAction) {
        rightW = 24;                       // 只给 chevron 留位置，取值宽度在 layout 里再算
    } else {
        rightW = cw * 0.42;                // 输入框那一列
    }

    CGFloat labW = MAX(60.0, cw - kTextX - kPadR - rightW);
    CGFloat h = t ? [t sizeThatFits:CGSizeMake(labW, CGFLOAT_MAX)].height : 20;
    if (s) h += 2 + [s sizeThatFits:CGSizeMake(labW, CGFLOAT_MAX)].height;

    CGFloat minH = (kind == kRowSwitch) ? NBRowHSwitch : NBRowH;
    return MAX(minH, h + 22);
}

#pragma mark - 刷新入口行的右侧说明

- (void)setActionValue:(NSString *)text forKey:(NSString *)key {
    UIView *box = self.actionRows[key];
    if (!box) return;
    UILabel *v = (UILabel *)[box viewWithTag:kSubValue];
    if (![v isKindOfClass:[UILabel class]]) return;
    // 🔴 v0.0.71：右侧箭头改成了真正的 chevron 图标，所以取值文字里那只**手写的 "›" 必须去掉**，
    //    否则会出现"文字尾巴一个 ›、右边图标又一个 ›"的双箭头。
    //    在这里统一剥一次，而不是去改十几处调用点的字面量 ——
    //    改字面量那种做法会在下次新增取值时又漏一处。
    NSString *t = [text stringByReplacingOccurrencesOfString:@"›" withString:@""];
    t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    v.text = t;
    [box setNeedsLayout];
}

- (void)refreshActionValues {
    // 🔴 这里读的是**当前生效的设置**，不是本页输入框里的内容 ——
    //    输入框改了但没保存时，这几行显示的仍是磁盘上的真实值。这个区分是对的：
    //    它们本来就不是本页能编辑的东西。
    NSDictionary *d = [NotifyStore settings];

    NSUInteger w = [NBStringArray(d[@"whitelist"]) count];
    NSUInteger b = [NBStringArray(d[@"blacklist"]) count];
    NSUInteger s = [NBStringArray(d[NB_KEY_SPEAK_APPS]) count];

    [self setActionValue:(w ? [NSString stringWithFormat:@"已选 %lu 个 ›", (unsigned long)w]
                            : @"未设置（全部放行）›")
                  forKey:@"white"];
    [self setActionValue:(b ? [NSString stringWithFormat:@"已选 %lu 个 ›", (unsigned long)b]
                            : @"未设置 ›")
                  forKey:@"black"];
    [self setActionValue:(s ? [NSString stringWithFormat:@"已选 %lu 个 ›", (unsigned long)s]
                            : @"全部 App ›")
                  forKey:@"speakapps"];

    NSUInteger dn = [NBStringArray(d[NB_KEY_DND_APPS]) count];
    [self setActionValue:(dn ? [NSString stringWithFormat:@"已选 %lu 个 ›", (unsigned long)dn]
                             : @"全部 App ›")
                  forKey:@"dndapps"];

    // v0.0.51：不记录的 App。空 = 全部记录（与 speak/dnd 的"全部 App"同族语义）。
    // 🔴 文案不能说成"未设置"就完事 —— 空名单是**功能关闭**的正常状态，
    //    和"配了但没生效"要能区分开（后者在这个插件里从不存在，因为读失败=照常记）。
    NSUInteger nr = [NBStringArray(d[NB_KEY_NO_RECORD_APPS]) count];
    [self setActionValue:(nr ? [NSString stringWithFormat:@"已选 %lu 个 ›", (unsigned long)nr]
                            : @"全部记录 ›")
                  forKey:@"norecord"];

    // 🔴🔴 v0.0.28：这一行的数据源从 `soundApps`（数组）换成了 `soundMap`（映射）。
    //    三态必须分开显示，因为后果完全不同：
    //      · 有分配                ⇒ 说个数；
    //      · 没分配但旧名单非空    ⇒ **旧格式还没迁移**（迁移在拿不到默认音时会放弃）。
    //        这种情况只显示"未分配"就是在骗人 —— 用户明明配过；
    //      · 两样都空              ⇒ 确实什么都没配。
    //    ⚠️ 顺带一条：`NBStringArray(d[NB_KEY_SOUND_MAP])` 会返回 0（形状是字典，不是数组），
    //    所以必须走 AppPicker 那个带特判的计数函数，不能在这里直接读键。
    NSUInteger sn = [AppPickerViewController selectedCountForMode:NBAppPickModeSoundMap];
    NSUInteger legacyN = [NBStringArray(d[NB_KEY_SOUND_APPS]) count];
    NSString *snShow = nil;
    if (sn) {
        snShow = [NSString stringWithFormat:@"已分配 %lu 个 ›", (unsigned long)sn];
    } else if (legacyN) {
        snShow = [NSString stringWithFormat:@"旧名单 %lu 个（尚未迁移）›", (unsigned long)legacyN];
    } else {
        snShow = @"未分配（系统原声）›";
    }
    [self setActionValue:snShow forKey:@"soundapps"];
    id sidNow = d[NB_KEY_SOUND_ID];
    [self setActionValue:(sidNow ? [NSString stringWithFormat:@"%@", sidNow] : @"未设置")
                  forKey:@"soundpreview"];

    // v0.0.26：这一行要一眼看出"到底用哪个" —— 文件优先于 ID。
    // 🔴 三态必须分开显示，不能把"选了但不合法"混进"没选"：
    //    用户放了文件、界面却显示"未选"，他只会觉得这个页面坏了。
    id fNow = d[NB_KEY_SOUND_FILE];
    NSString *fName = [fNow isKindOfClass:[NSString class]] ? (NSString *)fNow : @"";
    NSString *fShow = @"未选（用上面的 ID）›";
    if (fName.length) {
        if (!NBIsSafeSoundFileName(fName)) {
            fShow = @"文件名不合法 ›";
        } else {
            NSString *p = NBSoundFilePath(fName);
            BOOL exists = p && [[NSFileManager defaultManager] fileExistsAtPath:p];
            fShow = exists ? [NSString stringWithFormat:@"%@ ›", fName]
                           : [NSString stringWithFormat:@"%@（文件不在）›", fName];
        }
    }
    [self setActionValue:fShow forKey:@"soundfile"];

    NSString *voiceName = [VoicePickerViewController currentVoiceDisplayName];
    id rid = d[NB_KEY_SPEAK_RATE];
    NSString *rateName = @"默认速度";
    if ([rid isKindOfClass:[NSNumber class]]) {
        float r = [(NSNumber *)rid floatValue];
        if (r < 0.45f) rateName = @"慢";
        else if (r < 0.55f) rateName = @"正常";
        else if (r < 0.65f) rateName = @"快";
        else rateName = @"很快";
    }
    [self setActionValue:[NSString stringWithFormat:@"%@ · %@ ›", voiceName, rateName]
                  forKey:@"voice"];

    id rr = d[@"replaceRules"];
    NSUInteger rn = [rr isKindOfClass:[NSArray class]] ? [(NSArray *)rr count] : 0;
    [self setActionValue:(rn ? [NSString stringWithFormat:@"%lu 条 ›", (unsigned long)rn]
                             : @"未设置 ›")
                  forKey:@"replace"];

    [self setActionValue:[NSString stringWithFormat:@"%ld 条记录 ›", (long)[NotifyStore count]]
                  forKey:@"clear"];
    [self setActionValue:@"看看枚举到哪些 App ›" forKey:@"appdiag"];
}

- (NSString *)strOf:(id)v {
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    if ([v isKindOfClass:[NSArray class]]) return [(NSArray *)v componentsJoinedByString:@","];
    // 🔴 v0.0.27 补上 NSNumber：数字型设置落盘时是 @(n)（见 onSave 里的 soundID / maxRecords），
    //    而这里原来对 NSNumber 一律返回 @"" ⇒ **重新进设置页时输入框是空的**。
    //    那是一种非常难受的错：值明明在生效，界面却说没设过，用户会重新填一遍
    //    （填的如果和原来一样就没事，填成别的就等于悄悄改配置）。
    //    v0.0.21 起 soundID 一直有这个毛病，只是没人去核对过输入框。
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return @"";
}

// 读布尔型设置：统一走 NotifyCommon.h 的 NBBoolValue。
// 🔴 这里**不能再写一份**解读逻辑 —— App 和 tweak 对 "true"/"1" 的认法一旦不一致，
//    用户看到的就是"开关是开的、功能不生效"，而且保存期检查全绿，无从发现。
- (BOOL)boolOf:(id)v {
    return NBBoolValue(v);
}

#pragma mark - 布局

// 单行的内部摆放（卡片坐标系）
- (void)layoutRow:(UIView *)box width:(CGFloat)cw height:(CGFloat)h {
    NSInteger kind = box.tag;

    UIView *icon = [box viewWithTag:kSubIcon];
    icon.frame = CGRectMake(kIconX, (h - NBIconBox) / 2.0, NBIconBox, NBIconBox);
    // 图标里面那张图（没有这个子视图时 frame 设置无害）
    UIImageView *glyph = (UIImageView *)[icon viewWithTag:9001];
    glyph.frame = CGRectMake(5, 5, NBIconBox - 10, NBIconBox - 10);

    UILabel *t = (UILabel *)[box viewWithTag:kSubTitle];
    UILabel *s = (UILabel *)[box viewWithTag:kSubSub];

    CGFloat rightW = 0;
    CGFloat rightX = cw - kPadR;

    if (kind == kRowSwitch) {
        UIView *sw = [box viewWithTag:kSubSwitch];
        // UISwitch 尺寸写死的话，大字号/无障碍下会被裁掉。
        // intrinsicContentSize 在未 layout 时是 (-1,-1)，做一次兜底。
        CGSize sz = [sw intrinsicContentSize];
        if (sz.width <= 0 || sz.height <= 0) sz = CGSizeMake(51, 31);
        sw.frame = CGRectMake(rightX - sz.width, (h - sz.height) / 2.0, sz.width, sz.height);
        rightW = sz.width + 12;

    } else if (kind == kRowAction) {
        UILabel *v = (UILabel *)[box viewWithTag:kSubValue];
        UIImageView *chev = (UIImageView *)[box viewWithTag:kSubChev];
        CGFloat chevW = 8, chevH = 14;
        chev.frame = CGRectMake(rightX - chevW, (h - chevH) / 2.0, chevW, chevH);

        CGFloat maxVW = MAX(40.0, cw - kTextX - 24 - chevW - 8);
        CGSize vs = [v sizeThatFits:CGSizeMake(maxVW, h)];
        CGFloat vw = MIN(vs.width, maxVW);
        v.frame = CGRectMake(rightX - chevW - 6 - vw, (h - vs.height) / 2.0, vw, vs.height);
        rightW = cw - (rightX - chevW - 6 - vw);

        UIButton *hit = [box viewWithTag:kSubHit];
        hit.frame = CGRectMake(0, 0, cw, h);

    } else {   // kRowField
        UITextField *f = (UITextField *)[box viewWithTag:kSubField];
        CGFloat fw = MIN(170.0, cw * 0.45);
        f.frame = CGRectMake(rightX - fw, (h - NBFieldH) / 2.0, fw, NBFieldH);
        rightW = fw + 12;
    }

    CGFloat labW = MAX(60.0, cw - kTextX - kPadR - rightW);
    if (s) {
        CGFloat th = [t sizeThatFits:CGSizeMake(labW, CGFLOAT_MAX)].height;
        CGFloat sh = [s sizeThatFits:CGSizeMake(labW, CGFLOAT_MAX)].height;
        CGFloat total = th + 2 + sh;
        t.frame = CGRectMake(kTextX, (h - total) / 2.0, labW, th);
        s.frame = CGRectMake(kTextX, t.frame.origin.y + th + 2, labW, sh);
    } else {
        CGFloat th = [t sizeThatFits:CGSizeMake(labW, CGFLOAT_MAX)].height;
        t.frame = CGRectMake(kTextX, (h - th) / 2.0, labW, th);
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat w = self.view.bounds.size.width;
    CGFloat cw = w - NBInset * 2;
    CGFloat y = 12;

    self.scroll.frame = CGRectMake(0, 0, w, self.view.bounds.size.height);

    NSUInteger n = self.secRows.count;
    for (NSUInteger i = 0; i < n; i++) {
        NSMutableArray<UIView *> *rows = self.secRows[i];
        UIView *card = self.secCards[i];

        // ---- 组标题 ----
        id hl = self.secHeaderLabels[i];
        if ([hl isKindOfClass:[UILabel class]]) {
            UILabel *lb = (UILabel *)hl;
            CGSize hs = [lb sizeThatFits:CGSizeMake(cw - 8, CGFLOAT_MAX)];
            lb.frame = CGRectMake(NBInset + 4, y, cw - 8, hs.height);
            y += hs.height + kHeadGap;
        } else if (i > 0) {
            y += 6;   // 无标题的组：只补一点空隙，别和上一组脚注贴在一起
        }

        // ---- 卡片（高度 = 各行高之和）----
        NSMutableArray<NSNumber *> *heights = [NSMutableArray array];
        CGFloat cardH = 0;
        for (UIView *box in rows) {
            CGFloat rh = [self rowHeight:box width:cw];
            [heights addObject:@(rh)];
            cardH += rh;
        }
        card.frame = CGRectMake(NBInset, y, cw, cardH);

        // ---- 行 + 行间分隔线 ----
        CGFloat ry = 0;
        NSUInteger cnt = rows.count;
        for (NSUInteger j = 0; j < cnt; j++) {
            UIView *box = rows[j];
            CGFloat rh = [heights[j] doubleValue];
            box.frame = CGRectMake(0, ry, cw, rh);
            [self layoutRow:box width:cw height:rh];

            if (j + 1 < cnt) {
                // 🔴 分隔线**懒建**（只在 layout 里建一次，用 tag 找回来）：
                //    builder 那一刻还不知道自己是不是最后一行。
                UIView *sep = [box viewWithTag:kSubSep];
                if (!sep) {
                    sep = NBNewSeparator();
                    sep.tag = kSubSep;
                    [box addSubview:sep];
                }
                sep.frame = CGRectMake(kTextX, rh - 0.5, cw - kTextX, 0.5);
            }
            ry += rh;
        }

        y += cardH;

        // ---- 组脚注 ----
        id fl = self.secFooterLabels[i];
        if ([fl isKindOfClass:[UILabel class]]) {
            UILabel *lb = (UILabel *)fl;
            CGSize fs = [lb sizeThatFits:CGSizeMake(cw - 8, CGFLOAT_MAX)];
            lb.frame = CGRectMake(NBInset + 4, y + 8, cw - 8, fs.height);
            y += 8 + fs.height;
        }

        y += (i + 1 < n) ? kSecGap : 20;
    }

    // ---- 页脚状态文字 ----
    // 🔴 不显示时高度必须是 0：它空着的时候如果还占位置，
    //    症状是"设置页底部永远有一块空白"，很难归因到"一行没人写的文字"。
    if (self.statusLabel.text.length) {
        CGSize ss = [self.statusLabel sizeThatFits:CGSizeMake(cw - 8, CGFLOAT_MAX)];
        self.statusLabel.hidden = NO;
        self.statusLabel.frame = CGRectMake(NBInset + 4, y, cw - 8, ss.height);
        y += ss.height + 24;
    } else {
        self.statusLabel.hidden = YES;
        self.statusLabel.frame = CGRectZero;
    }

    self.scroll.contentSize = CGSizeMake(w, y + 24);
}

#pragma mark - 键盘

- (void)onKeyboard:(NSNotification *)n {
    NSDictionary *u = n.userInfo;
    CGRect end = [u[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat overlap = MAX(0, self.view.bounds.size.height - [self.view convertRect:end fromView:nil].origin.y);
    UIEdgeInsets in = self.scroll.contentInset;
    in.bottom = overlap;
    self.scroll.contentInset = in;
    self.scroll.scrollIndicatorInsets = in;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (NSString *)usageText {
    // 🔴 v0.0.71：这段文字原来叫 `hintLabel`，**压在整个设置页的最底部**。
    //    它比所有设置项加起来还长 ⇒ 想改设置得先滑过一整屏说明，想查说明又得先滑过所有设置。
    //    现在搬进独立页面：文字**一个字没删**（下面这些行是从 git HEAD 里原样取出来的），
    //    只是从"堆在页尾"改成"点进去看"。
    NSString *s =
        @"说明\n"
        @"• 保存后立即生效，不用 respring。\n"
        @"• 白名单一旦填了，就等于「只保留这些 App」，其它全部不弹（有杀伤力）。\n"
        @"• 白名单/黑名单/朗读限定都点进去选，可以搜索；点一下立即生效，没有保存按钮。\n"
        @"• 被拦下的通知仍然会记进盒子里，方便回头查本来要推什么。\n"
        @"• 「不记录的 App」是另一回事：选上的 App **连记录都不落库**（盒子里不留痕迹），\n"
        @"  但通知照常弹出、朗读/换音/替换都照跑 —— 它管「记不记」，黑白名单管「弹不弹」。\n"
        @"  已有的记录不受影响；想清掉已有的，用下面的「批量清理记录 / 清空全部记录」。\n"
        @"• 内容替换只改通知上显示的文字；盒子里存的仍是原文。\n"
        @"• 记录上限默认 500；超出后自动淘汰最旧的。\n"
        @"• 「自动清理：保留最近 N 天」= 每次打开盒子自动删掉 N 天前的记录（连未读一起，\n"
        @"  因为「保留最近 N 天」就是「更老的都不要了」）；填 0 或清空 = 关闭。\n"
        @"  它和「记录上限」是两件事：上限管「库里最多留多少条」，清理管「按时间裁」，可同时开。\n"
        @"• 列表一次最多显示 2000 条：上限填得更大时，更早的记录翻不到，\n"
        @"  要用首页的「导出」才能看到（导出不带这个上限）。\n"
        @"• 「批量清理记录」可按时间（7/30 天前）、按已读、按某个 App 删；\n"
        @"  确认框里报的条数就是真会删掉的条数。\n"
        @"• 朗读默认关闭。打开后会占用音频通道，可能让正在播放的音乐变小或暂停 ——\n"
        @"  这是系统语音合成的固有行为，不是 bug。\n"
        @"• 朗读只念「替换后」的文字（跟通知上看到的一致）；被过滤规则拦下的通知不念。\n"
        @"• 如果朗读导致桌面崩溃重启，插件会在下次开机时**自动把朗读关掉**，\n"
        @"  并往日志写一行「朗读自毁保护触发」，不需要你做任何事。\n"
        @"• 延迟推送已在 v0.0.19 移除（不是关闭）。它两次把手机搞坏：\n"
        @"  一次让桌面崩进安全模式，一次让通知一条都不弹，所以整个拿掉了。\n"
        @"  如果你手里那版还填着秒数，装上这版会自动把它清掉，不用你手动改。\n"
        @"• 顺带修好一个会丢数据的问题：数据库锁。以前盒子 App 和桌面同时写库时，\n"
        @"  SQLite 直接返回 busy（日志里 INSERT 失败 rc=5），那条通知就静默丢了；\n"
        @"  现在会最多等 2 秒再放弃。\n"
        @"• 存储位置：\n  /var/mobile/Library/NotifyBox/settings.plist";
    return s;
}

- (void)onUsage:(id)sender {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = @"使用说明";
    vc.view.backgroundColor = NBPageBG();

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
    tv.editable = NO;
    tv.selectable = YES;                  // 可复制，方便贴回来问
    tv.font = [UIFont systemFontOfSize:13];
    tv.textColor = [UIColor labelColor];
    tv.backgroundColor = NBPageBG();
    tv.textContainerInset = UIEdgeInsetsMake(16, 16, 24, 16);
    tv.text = [self usageText];
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


#pragma mark - 保存

- (NSString *)trim:(NSString *)s {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

- (void)onSave:(id)sender {
    [self.view endEditing:YES];

    // 以当前生效配置为底：子页面（黑白名单/替换规则/声音）写的键不在本页编辑范围内，
    // 不这样兜底就会被本页的保存动作整体冲掉。
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[NotifyStore settings]];

    // 🔴 v0.0.21：开关从字典里按 key 取（三个开关，不可能再共用一个属性）
    // 🔴🔴 v0.0.32：这个数组是**手写的**，新增开关忘了加进来 ⇒ 开关状态永远不落盘。
    //    症状：点开、保存、再进来又变回关；而保存时没有任何报错，盘上压根没这个键。
    //    ⇒ 加开关时必须同时改这里（源码判据 s0x 盯着这一点）。
    for (NSString *k in @[NB_KEY_SPEAK_ENABLED, NB_KEY_DND_ENABLED, NB_KEY_SOUND_ENABLED,
                          NB_KEY_SOUND_DUCK_OTHERS, NB_KEY_SYNC_CLEAR,
                          NB_KEY_CONTENT_FALLBACK]) {
        UISwitch *sw = self.switches[k];
        d[k] = @(sw ? sw.isOn : NO);
    }

    // 🔴 遍历字段用 fieldKeys 配对，不写死下标
    for (NSUInteger i = 0; i < self.fields.count; i++) {
        NSString *key = (i < self.fieldKeys.count) ? self.fieldKeys[i] : nil;
        if (!key.length) continue;
        NSString *v = [self trim:self.fields[i].text];

        // 🔴 时间字段：只接受 HH:mm（或纯分钟数），并且落盘成**分钟数**。
        //    存字符串会让 App 和 tweak 各解析一遍，两边差一点就是"填了不生效"，
        //    而这种错完全静默（读到 nil = 关闭）。
        if ([key isEqualToString:NB_KEY_DND_START] || [key isEqualToString:NB_KEY_DND_END]) {
            if (v.length == 0) {
                [d removeObjectForKey:key];
            } else {
                NSInteger mins = -1;
                NSArray *parts = [v componentsSeparatedByString:@":"];
                if (parts.count == 1) {
                    NSInteger n = [v integerValue];
                    if (n >= 0 && n < 24 * 60) mins = n;
                } else if (parts.count == 2) {
                    NSInteger h = [[parts[0] stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceCharacterSet]] integerValue];
                    NSInteger mi = [[parts[1] stringByTrimmingCharactersInSet:
                                     [NSCharacterSet whitespaceCharacterSet]] integerValue];
                    if (h >= 0 && h <= 23 && mi >= 0 && mi <= 59) mins = h * 60 + mi;
                }
                if (mins < 0) {
                    [self fail:@"时间要写成 HH:mm（例如 23:00），或直接填 0~1439 的分钟数（原值未改）"];
                    return;
                }
                d[key] = @(mins);
            }
        } else if ([key isEqualToString:NB_KEY_SOUND_ID]) {
            // 🔴 只收 1000~1035：这是系统提示音区段。
            //    填别的一律拒绝 —— 造一个 id=0 的 BBSound 只会让通知变哑，比不生效更坏。
            if (v.length == 0) {
                [d removeObjectForKey:key];
            } else {
                NSInteger n = [v integerValue];
                if (n < 1000 || n > 1035) {
                    [self fail:@"提示音 ID 必须是 1000~1035 之间的数字（原值未改）"];
                    return;
                }
                d[key] = @(n);
            }
        } else if ([key isEqualToString:NB_KEY_SOUND_MAX_SEC]) {
            // v0.0.27：最长播放秒数。**0 = 不限**，清空 = 回默认 8 秒。
            // 🔴 这里必须严格校验，不能只 `[v doubleValue]` —— 那对 "abc" 返回 0，
            //    而 0 的语义正是"不限"⇒ 一个手滑就变成"播到底"，而且界面上看起来还"保存成功了"。
            if (v.length == 0) {
                [d removeObjectForKey:key];       // 清空 = 用默认值（与别处"清空要能生效"一致）
            } else {
                NSScanner *sc = [NSScanner scannerWithString:v];
                double n = 0;
                if (![sc scanDouble:&n] || !sc.isAtEnd
                    || n < 0 || n > NB_SOUND_MAX_SEC_CEIL) {
                    [self fail:[NSString stringWithFormat:
                                @"最长播放秒数要填 0~%.0f 之间的数字（0 = 不限，清空 = 默认 8 秒）（原值未改）",
                                NB_SOUND_MAX_SEC_CEIL]];
                    return;
                }
                d[key] = @(n);
            }
        } else if ([key isEqualToString:@"maxRecords"]) {
            if (v.length == 0) {
                [d removeObjectForKey:key];
            } else {
                NSInteger n = [v integerValue];
                if (n > 0 && n < 100000) {
                    d[key] = @(n);
                } else {
                    [self fail:@"记录上限必须是 1~99999 之间的数字（原值未改）"];
                    return;
                }
            }
        } else if ([key isEqualToString:@"autoCleanDays"]) {
            if (v.length == 0) {
                [d removeObjectForKey:key];   // 清空 = 关闭
            } else {
                NSInteger n = [v integerValue];
                if (n >= 0 && n <= 3650) {
                    if (n > 0) d[key] = @(n);
                    else [d removeObjectForKey:key];
                } else {
                    [self fail:@"自动清理天数要填 0~3650 之间（0 = 关闭，原值未改）"];
                    return;
                }
            }
        } else {
            if (v.length) d[key] = v;
            else [d removeObjectForKey:key];
        }
    }

    // 🔴🔴 v0.0.19 总闸门：写盘之前把已移除功能的键删干净。
    //    病因：这个方法的写法是「启动时读到的整份 dict → 改一项 → 整份写回」。
    //    只要那份里还有 delaySeconds，用户改任何别的设置都会把它**原样写回去**，
    //    于是 tweak 清一次、App 复活一次 —— 表现就是"明明删了，还在跑"。
    //    ⇒ 让这一个出口负责"已移除的键绝不落盘"，比在每个入口判断都可靠。
    [d removeObjectForKey:NB_KEY_DELAY_SECONDS];
    [d removeObjectForKey:NB_KEY_DELAY_APPS];

    errno = 0;
    BOOL ok = [NotifyStore saveSettings:d];
    int e = errno;
    if (ok) {
        NSDictionary *back = [NotifyStore settings];
        BOOL rt = [back isEqual:d];
        self.statusLabel.textColor = rt ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
        self.statusLabel.text = [NSString stringWithFormat:@"已保存 %lu 项（回读%@）· 朗读%@\n%@",
                                 (unsigned long)d.count,
                                 rt ? @"一致" : @"不一致",
                                 (self.switches[NB_KEY_SPEAK_ENABLED].isOn) ? @"开" : @"关",
                                 NOTIFYBOX_SETTINGS_PATH];
    } else {
        self.statusLabel.textColor = [UIColor systemRedColor];
        self.statusLabel.text = [NSString stringWithFormat:@"保存失败 errno=%d(%s)\n%@",
                                 e, strerror(e), NOTIFYBOX_SETTINGS_PATH];
    }
    [self refreshActionValues];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

- (void)onClose:(id)sender {
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - 子页面

- (void)push:(UIViewController *)vc {
    // 子页面写的是同一份 settings.plist，返回后靠 viewWillAppear 刷新
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)onReplace:(id)sender {
    [self.view endEditing:YES];
    [self push:[[ReplaceRulesViewController alloc] init]];
}

- (void)onWhite:(id)sender {
    [self.view endEditing:YES];
    [self push:[[AppPickerViewController alloc] initWithMode:NBAppPickModeWhitelist]];
}

- (void)onBlack:(id)sender {
    [self.view endEditing:YES];
    [self push:[[AppPickerViewController alloc] initWithMode:NBAppPickModeBlacklist]];
}

// v0.0.51：连记录都不要（per-App）。走 AppPicker 的 NoRecord 模式——
// 和黑白名单同一个页面、同一套"点一下立即生效、没有保存按钮"，只是写的是 noRecordApps 键。
// 🔴 这个入口**不弹确认框**：勾选只是让以后的记录不落库，不动任何已有数据
//    （想清已有的走下面的"批量清理/清空全部"）。可逆、无破坏，不需要二次确认。
- (void)onNoRecordApps:(id)sender {
    [self.view endEditing:YES];
    [self push:[[AppPickerViewController alloc] initWithMode:NBAppPickModeNoRecord]];
}

- (void)onSpeakApps:(id)sender {
    [self.view endEditing:YES];
    [self push:[[AppPickerViewController alloc] initWithMode:NBAppPickModeSpeak]];
}

- (void)onDndApps:(id)sender {
    [self.view endEditing:YES];
    [self push:[[AppPickerViewController alloc] initWithMode:NBAppPickModeDnd]];
}

- (void)onSoundApps:(id)sender {
    [self.view endEditing:YES];
    // v0.0.28：不再是"分 App 列表 + 一个全局音"，而是"每个 App 各自的音"。
    // ⇒ 入口换成总览页（列出已分配 + 进子页逐个改），选择器只作为它的子页出现。
    [self push:[[SoundAppsViewController alloc] init]];
}

- (void)onSoundFile:(id)sender {
    [self.view endEditing:YES];
    [self push:[[SoundFilePickerViewController alloc] init]];
}

// 试听：直接在 App 里放，用户不用去猜 1007 是什么声音 / 也不用等一条真通知。
//
// 🔴 v0.0.26 改了两件事：
//   ① **文件优先**（与引擎的判定顺序一致：选了文件就不看 ID）。
//      试听如果还按 ID 播，用户会听到"不是他选的那个音"却以为配错了。
//   ② 播文件的代码**不在本文件里**，一律调 NotifyFilter 那个同一个函数
//      （见文件顶部 import 处的注释：两份播放逻辑走岔是最难查的症状）。
//
// ⚠️ 必须对用户讲清的局限：试听跑在**盒子 App 进程**，通知跑在 **SpringBoard 进程**。
//    试听响只能证明"这个文件/ID 能解码"，不能 100% 保证通知一定响。
//    所以这句话要写进状态栏文案，不能只在文档里。
- (void)onSoundPreview:(id)sender {
    [self.view endEditing:YES];

    // ---- ① 有文件就播文件 ----
    id fv = [NotifyStore settings][NB_KEY_SOUND_FILE];
    NSString *fname = [fv isKindOfClass:[NSString class]] ? (NSString *)fv : nil;
    if (fname.length) {
        NSString *detail = nil;
        BOOL ok = [NotifyFilter playSoundFileNamed:fname forResult:&detail];
        self.statusLabel.textColor = ok ? [UIColor secondaryLabelColor] : [UIColor systemRedColor];
        self.statusLabel.text = ok
            ? [NSString stringWithFormat:@"已试听文件 %@（%@）。"
                                         @"⚠️ 试听在 App 里播，通知在 SpringBoard 里播 —— "
                                         @"试听响不等于通知一定响。", fname, detail ?: @"?"]
            : [NSString stringWithFormat:@"这个文件播不出来：%@", detail ?: @"原因未知"];
        return;
    }

    // ---- ② 没文件才播 ID（v0.0.25 的老路，真机已验证）----
    NSInteger sid = 0;
    for (NSUInteger i = 0; i < self.fields.count; i++) {
        if (i < self.fieldKeys.count && [self.fieldKeys[i] isEqualToString:NB_KEY_SOUND_ID]) {
            sid = [self trim:self.fields[i].text].integerValue;
            break;
        }
    }
    if (sid < 1000 || sid > 1035) {
        [self fail:@"先填一个 1000~1035 之间的提示音 ID（或选一个提示音文件），再点试听"];
        return;
    }
    AudioServicesPlaySystemSound((SystemSoundID)sid);
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = [NSString stringWithFormat:
                             @"已试听 ID=%ld。听到声音就说明这个 ID 有效，可以保存了。",
                             (long)sid];
}

// 分钟数 → "HH:mm"，只用于**显示**（落盘永远是分钟数）。
- (NSString *)timeText:(id)v {
    NSInteger n = -1;
    if ([v isKindOfClass:[NSNumber class]]) n = [(NSNumber *)v integerValue];
    else if ([v isKindOfClass:[NSString class]]) n = [(NSString *)v integerValue];
    if (n < 0 || n >= 24 * 60) return @"";
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)(n / 60), (long)(n % 60)];
}

- (void)onVoice:(id)sender {
    [self.view endEditing:YES];
    [self push:[[VoicePickerViewController alloc] init]];
}

- (void)onAppDiag:(id)sender {
    [self.view endEditing:YES];
    // 枚举失败是静默的（列表空），所以把"哪条路走通了"直接摆出来
    NSString *rep = [InstalledApps diagReport];
    UIAlertController *a = [UIAlertController
                            alertControllerWithTitle:@"App 枚举诊断"
                                             message:rep
                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)onClearAll:(id)sender {
    [self.view endEditing:YES];
    NSInteger n = [NotifyStore count];
    UIAlertController *a = [UIAlertController
                            alertControllerWithTitle:@"清空全部记录"
                                             message:[NSString stringWithFormat:
                                                      @"会删掉数据库里全部 %ld 条记录，不可恢复。\n"
                                                      @"（设置和替换规则不受影响）", (long)n]
                                      preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"删除 %ld 条", (long)n]
                                         style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *act) {
        [NotifyStore clearAll];
        NSInteger after = [NotifyStore count];
        self.statusLabel.textColor = [UIColor labelColor];
        self.statusLabel.text = [NSString stringWithFormat:@"已清空：%ld → %ld 条", (long)n, (long)after];
        [self refreshActionValues];
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    }]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
                                                           self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - v0.0.46 统计

- (void)onStats:(id)sender {
    [self.view endEditing:YES];
    NotifyStatsViewController *v = [[NotifyStatsViewController alloc] init];
    [self.navigationController pushViewController:v animated:YES];
}

// v0.0.48：关键词规则编辑页。
- (void)onKeywordRules:(id)sender {
    [self.view endEditing:YES];
    KeywordRulesViewController *v = [[KeywordRulesViewController alloc] init];
    [self.navigationController pushViewController:v animated:YES];
}

#pragma mark - v0.0.45 批量清理

// 统一的「先报数、再删」出口。四个入口（7 天 / 30 天 / 已读 / 按 App）都走这里。
// 🔴🔴 确认框里的条数**只能**由 `countForDeleteWithBundle:` 算，
//    不能拿列表条数代替：列表带 `LIMIT 2000`，筛选态下还会被搜索词再切一刀 ——
//    v0.0.35 的 `onClear:` 就是报了列表条数（3）、实际清了整张表（2000），
//    那是本项目"两个指标互相矛盾"的第一次，别再买第二次。
- (void)confirmDeleteTitle:(NSString *)title
                    bundle:(NSString *)bundle
                  beforeTs:(NSTimeInterval)beforeTs
                  readOnly:(BOOL)readOnly {
    NSInteger n = [NotifyStore countForDeleteWithBundle:bundle beforeTs:beforeTs readOnly:readOnly];
    if (n < 0) {
        [self fail:(n == -2) ? @"清理条件不完整（至少要有一个范围）" : @"数据库打不开，无法清理"];
        return;
    }
    if (n == 0) {
        // 🔴 "删了个空"必须**明确说出来**。静默成功会让用户以为删掉了，
        //    回头一看记录还在 ⇒ 判定功能坏了。
        self.statusLabel.textColor = [UIColor labelColor];
        self.statusLabel.text = [NSString stringWithFormat:@"%@：没有符合条件的记录，什么都没删", title];
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        return;
    }
    UIAlertController *a = [UIAlertController
                            alertControllerWithTitle:title
                                             message:[NSString stringWithFormat:
                                                      @"将删除 %ld 条记录，不可恢复。", (long)n]
                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"删除 %ld 条", (long)n]
                                         style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *act) {
        NSInteger done = [NotifyStore deleteWithBundle:bundle beforeTs:beforeTs readOnly:readOnly];
        NSInteger after = [NotifyStore count];
        self.statusLabel.textColor = (done > 0) ? [UIColor labelColor] : [UIColor systemRedColor];
        self.statusLabel.text = [NSString stringWithFormat:@"%@：删掉 %ld 条，剩余 %ld 条",
                                 title, (long)done, (long)after];
        [self refreshActionValues];
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)onBatchClean:(id)sender {
    [self.view endEditing:YES];
    UIAlertController *a = [UIAlertController
                            alertControllerWithTitle:@"批量清理记录"
                                             message:@"只删记录，不影响设置和替换规则。"
                                      preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) wself = self;
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // 🔴 `beforeTs` 的语义是"**严格早于**"，所以传"N 天前那一刻"，不是 now。
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    [a addAction:[UIAlertAction actionWithTitle:@"删除 7 天前的记录"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *act) {
        [wself confirmDeleteTitle:@"删除 7 天前的记录" bundle:nil
                         beforeTs:now - 7 * 86400.0 readOnly:NO];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除 30 天前的记录"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *act) {
        [wself confirmDeleteTitle:@"删除 30 天前的记录" bundle:nil
                         beforeTs:now - 30 * 86400.0 readOnly:NO];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除全部已读记录"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *act) {
        [wself confirmDeleteTitle:@"删除全部已读记录" bundle:nil beforeTs:0 readOnly:YES];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"按 App 删除…"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *act) {
        [wself pickAppToClean];
    }]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
                                                           self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

// 🔴 只列"来过通知的 App"（`bundleCounts` 有值）：没来过通知的 App 删了也是 0 条，
//    把它们列进来只会把这个清单变成几百项的滚动地狱。
// 🔴 超过 12 个只列最多的 12 个 —— 这是**删除**操作，清单越长越容易点错。
- (void)pickAppToClean {
    NSDictionary<NSString *, NSNumber *> *counts = [NotifyStore bundleCounts];
    if (!counts.count) {
        [self fail:@"还没有任何记录"];
        return;
    }
    NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
    for (InstalledApp *a in [InstalledApps all]) {
        if (a.bundleId.length) names[a.bundleId] = a.name;
    }
    NSArray<NSString *> *bids = [counts keysSortedByValueUsingComparator:
                                 ^NSComparisonResult(NSNumber *x, NSNumber *y) {
        return [y compare:x];                    // 条数多的排前面
    }];
    NSUInteger lim = MIN(bids.count, (NSUInteger)12);
    UIAlertController *a = [UIAlertController
                            alertControllerWithTitle:@"删除某个 App 的全部记录"
                                             message:[NSString stringWithFormat:
                                                      @"共 %lu 个 App 有记录%@",
                                                      (unsigned long)bids.count,
                                                      (bids.count > lim) ? @"（列出条数最多的 12 个）" : @""]
                                      preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) wself = self;
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    for (NSUInteger i = 0; i < lim; i++) {
        NSString *bid = bids[i];
        NSString *nm = names[bid];
        if (!nm.length) nm = [[bid componentsSeparatedByString:@"."] lastObject];
        NSString *row = [NSString stringWithFormat:@"%@（%@ 条）", nm, counts[bid]];
        [a addAction:[UIAlertAction actionWithTitle:row
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *act) {
            [wself confirmDeleteTitle:[NSString stringWithFormat:@"删除「%@」的全部记录", nm]
                               bundle:bid beforeTs:0 readOnly:NO];
        }]];
    }
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
                                                           self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)fail:(NSString *)msg {
    self.statusLabel.textColor = [UIColor systemRedColor];
    self.statusLabel.text = msg;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

@end
