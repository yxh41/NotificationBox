#import "NotifySpeaker.h"
#import "NotifyCommon.h"
#import "NotifyStore.h"
#import <objc/runtime.h>

// 🔴 iOS 14 起 AVSpeechSynthesizer 实际住在 AVFAudio.framework 里，
//    AVFoundation 只是转发（re-export）。两个都试：
//    哪个在头文件层面找得到就用哪个，避免"SDK 布局变了 ⇒ 编译直接挂"。
#if __has_include(<AVFAudio/AVFAudio.h>)
#import <AVFAudio/AVFAudio.h>
#endif
#import <AVFoundation/AVFoundation.h>

// 通知朗读（v0.0.12）
//
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 🔴 这个模块跑在 SpringBoard 里。三条硬约束，每条都是踩过的类型：
//
// ① **必须在主队列调 AVSpeechSynthesizer。** 它内部依赖 runloop；
//    在 publishBulletin: 的调用线程（不保证是主线程）上直接 speak 会静默不出声。
//
// ② **绝不能排队。** 群聊刷屏时一次来十几条，排队会让用户听到几分钟前的消息。
//    策略是「新通知优先」：正在读就直接打断。
//
// ③ **必须有崩溃自愈。** 见 NotifyCommon.h 里 guard 文件的注释：
//    朗读把 SpringBoard 拖崩时，用户连设置页都进不去，
//    所以"关掉朗读"这件事不能指望用户操作，只能下次启动自己关。
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

static NSString *NBTrimStr(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

// 🔴 布尔解读统一走 NotifyCommon.h 的 NBBoolValue（这里不再自己写一份）：
//    NotifySpeaker 和设置页各写一份的话，两边迟早对 "true"/"1" 的认法不一致，
//    表现就是"开关开了、功能不生效"，而且完全静默。

static NSString *NBJoinedString(id v) {
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableArray *ok = [NSMutableArray array];
        for (id one in (NSArray *)v) {
            if ([one isKindOfClass:[NSString class]]) [ok addObject:one];
        }
        return [ok componentsJoinedByString:@","];
    }
    return @"";
}

static void NBWriteGuard(NSString *s) {
    [[NSFileManager defaultManager] createDirectoryAtPath:
        [NOTIFYBOX_SPEAK_GUARD_PATH stringByDeletingLastPathComponent]
                             withIntermediateDirectories:YES attributes:nil error:nil];
    [s writeToFile:NOTIFYBOX_SPEAK_GUARD_PATH atomically:YES
          encoding:NSUTF8StringEncoding error:nil];
}

static AVSpeechSynthesizer *gSynth = nil;

// 🔴 内部方法先声明：CI 是 -Werror，不声明会在 @implementation 里报
//    "no known class method for selector"（即使定义在同一文件后面）。
@interface NotifySpeaker ()
+ (void)speakOnMainThread:(NSString *)text bundle:(NSString *)bundle;
@end

@implementation NotifySpeaker

#pragma mark - 判定

+ (BOOL)shouldSpeakBundle:(NSString *)bundle title:(NSString *)title message:(NSString *)message {
    @try {
        NSDictionary *d = NBLoadSettings();
        if (!NBBoolValue(d[NB_KEY_SPEAK_ENABLED])) return NO;
        if (!bundle.length) return NO;

        NSString *t = NBTrimStr(title);
        NSString *m = NBTrimStr(message);
        // 没文字的通知（纯进度条、纯图标角标）读它等于放一声气，不读
        if (!t.length && !m.length) return NO;

        // App 白名单：空/缺失 = 所有 App
        NSString *list = NBTrimStr(NBJoinedString(d[NB_KEY_SPEAK_APPS]));
        if (!list.length) return YES;
        for (NSString *one in [list componentsSeparatedByString:@","]) {
            NSString *x = NBTrimStr(one);
            // 🔴 bundle id 大小写不敏感比较：iOS 的 bundle id 本身区分大小写，
            //    但用户手打时 99% 会大小写打错，严格比较等于"配了但永远不命中"。
            if (x.length && [x caseInsensitiveCompare:bundle] == NSOrderedSame) return YES;
        }
        return NO;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

#pragma mark - 朗读

+ (void)speakWithBundle:(NSString *)bundle title:(NSString *)title message:(NSString *)message {
    @try {
        NSString *t = NBTrimStr(title);
        NSString *m = NBTrimStr(message);

        NSMutableArray *parts = [NSMutableArray array];
        if (t.length) [parts addObject:t];
        // 标题与正文常常一模一样（很多 App 就是这么发的），重复读两遍很蠢
        if (m.length && ![m isEqualToString:t]) [parts addObject:m];
        if (!parts.count) return;

        NSString *text = [parts componentsJoinedByString:@"，"];
        // 240 字 ≈ 40 秒语音。再长就读不完了，而且用户这时候已经被下一条打断。
        if (text.length > 240) {
            text = [[text substringToIndex:240] stringByAppendingString:@"，以下省略"];
        }

        // 🔴🔴 start 标记必须在**任何 AV 调用之前**落盘。
        //    顺序反了（先建 synthesizer 再写标记）等于没保护：崩在建 synthesizer 这一步时
        //    下次启动看不到 start，还会再试一次 ⇒ 每次开机都崩一次。
        NBWriteGuard(@"start");

        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                [self speakOnMainThread:text bundle:bundle];
            } @catch (__unused NSException *e) {
                NBSharedLog(@"!!! SPEAK 主队列内抛异常 bundle=%@", bundle);
                NBWriteGuard(@"failed");
            }
        });
    } @catch (__unused NSException *e) {
        // 兜底：朗读再重要也不能影响通知投递
    }
}

// 主队列上执行。私有方法，头文件不暴露。
+ (void)speakOnMainThread:(NSString *)text bundle:(NSString *)bundle {
    // 🔴 存在性检查用 NSClassFromString，但**调用点必须用真类型**：
    //    拿 Class 变量发类方法消息，clang 不知道接口 ⇒ 报 "no known class method" ⇒ -Werror 挂。
    //    拆成「查得到吗」和「怎么调」两步，两个目的都达到。
    if (!NSClassFromString(@"AVSpeechSynthesizer") || !NSClassFromString(@"AVSpeechUtterance")) {
        // 说明本进程没有 AVFoundation（比如 backboardd）。这不是错误，是环境事实。
        NBSharedLog(@"SPEAK 跳过：本进程没有 AVSpeechSynthesizer bundle=%@", bundle);
        NBWriteGuard(@"unavailable");
        return;
    }

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSynth = [[AVSpeechSynthesizer alloc] init];
    });
    if (!gSynth) {
        NBWriteGuard(@"failed");
        return;
    }

    // 新通知优先
    if (gSynth.speaking) {
        [gSynth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    }

    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
    if (!u) {
        NBWriteGuard(@"failed");
        return;
    }

    // ---------- 语音与语速（v0.0.13）----------
    // 每次朗读都重新读设置：用户在设置页改完立刻生效，不需要 respring。
    // 这点 IO 相比"改完不生效"的代价可以忽略。
    NSDictionary *cfg = NBLoadSettings();

    id rid = cfg[NB_KEY_SPEAK_RATE];
    float rate = [rid isKindOfClass:[NSNumber class]] ? [(NSNumber *)rid floatValue]
                                                      : AVSpeechUtteranceDefaultSpeechRate;
    // 🔴 必须夹范围。设置文件是可以手改的，也可能因为别的原因出现 0 或 5：
    //    • rate=0 ⇒ 几乎不动，用户以为"朗读没声音"
    //    • rate>1 ⇒ 系统行为未定义，可能极快或直接不出声
    //    这两种都属于"看起来像功能坏了"的错，而原值其实还在文件里，极难查。
    if (rate < 0.20f || rate > 1.00f) rate = AVSpeechUtteranceDefaultSpeechRate;
    u.rate = rate;

    NSString *vid = cfg[NB_KEY_SPEAK_VOICE];
    if ([vid isKindOfClass:[NSString class]] && [(NSString *)vid length]) {
        AVSpeechSynthesisVoice *v = [AVSpeechSynthesisVoice voiceWithIdentifier:vid];
        // 🔴 找不到就**不设** voice（= 跟随系统），既不要报错也不要静音。
        //    这个语音可能已经被用户在系统设置里删掉了，那时正确的退化就是回默认声音。
        if (v) u.voice = v;
    }

    u.pitchMultiplier = 1.0f;
    u.volume = 1.0f;
    u.postUtteranceDelay = 0.0;

    // 🔴 用户没选语音时**不显式指定** ⇒ 跟随系统语言。
    //    写死 zh-CN 看着像"照顾中文用户"，实际在英文系统上会把英文读成怪腔，
    //    而且中文里混的英文单词（"Wi-Fi 已连接"）也会被读坏。

    [gSynth speakUtterance:u];

    // speakUtterance: 是异步的，返回时声音还没出来 —— 这里只需要确认"调用没炸"
    NBWriteGuard(@"done");
    NBSharedLog(@"SPEAK 已提交 bundle=%@ len=%lu voice=%@ rate=%.2f",
                bundle, (unsigned long)text.length,
                u.voice ? u.voice.name : @"(跟随系统)", u.rate);
}

#pragma mark - 崩溃自愈

+ (BOOL)recoverFromCrashIfNeeded {
    @try {
        NSString *s = NBTrimStr([NSString stringWithContentsOfFile:NOTIFYBOX_SPEAK_GUARD_PATH
                                                          encoding:NSUTF8StringEncoding
                                                             error:nil]);
        if (![s isEqualToString:@"start"]) return NO;

        NBSharedLog(@"!!! 朗读自毁保护触发：guard=start 但没有 done ⇒ 上次崩在朗读里");

        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:NBLoadSettings()];
        d[NB_KEY_SPEAK_ENABLED] = @NO;
        BOOL ok = [NotifyStore saveSettings:d];

        // 立刻改成 crash-closed：否则用户没机会手动关，下次启动又会重写一遍设置
        NBWriteGuard(@"crash-closed");

        NBSharedLog(@"朗读已强制关闭（写回设置%@）—— 想再试请到 设置 → 朗读通知 重新打开",
                    ok ? @"成功" : @"失败");
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

#pragma mark - 诊断

+ (NSString *)diagnosticLine {
    @try {
        NSDictionary *d = NBLoadSettings();
        BOOL on = NBBoolValue(d[NB_KEY_SPEAK_ENABLED]);
        BOOL hasCls = (NSClassFromString(@"AVSpeechSynthesizer") != nil);
        NSString *guard = NBTrimStr([NSString stringWithContentsOfFile:NOTIFYBOX_SPEAK_GUARD_PATH
                                                              encoding:NSUTF8StringEncoding
                                                                 error:nil]);
        // v0.0.13：把语音/语速也带上 —— "朗读没声音"和"朗读声音不对"是两种问题，
        // 诊断行必须能直接分开，否则又要来回问一轮。
        NSString *vid = d[NB_KEY_SPEAK_VOICE];
        NSString *vname = @"跟随系统";
        if ([vid isKindOfClass:[NSString class]] && [(NSString *)vid length]) {
            AVSpeechSynthesisVoice *v = [AVSpeechSynthesisVoice voiceWithIdentifier:vid];
            vname = v ? v.name : [NSString stringWithFormat:@"已失效(%@)", vid];
        }
        id rid = d[NB_KEY_SPEAK_RATE];
        NSString *rateStr = [rid isKindOfClass:[NSNumber class]]
                          ? [NSString stringWithFormat:@"%.2f", [(NSNumber *)rid floatValue]]
                          : @"默认";
        return [NSString stringWithFormat:@"朗读=%@ 声音=%@ 语速=%@ AVSpeech=%@ guard=%@",
                on ? @"开" : @"关", vname, rateStr,
                hasCls ? @"有" : @"无",
                guard.length ? guard : @"(无)"];
    } @catch (__unused NSException *e) {
        return @"朗读=诊断失败";
    }
}

@end
