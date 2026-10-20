#import "NotifyFilter.h"
#import "NotifyCommon.h"

@implementation NotifyFilter

+ (NSDictionary *)prefs {
    return [NSDictionary dictionaryWithContentsOfFile:NOTIFYBOX_PREFS_PATH] ?: @{};
}

// 偏好里可能是数组(多值)也可能是逗号分隔字符串(文本框)，统一成数组
+ (NSArray *)arrayFromPref:(id)v {
    if ([v isKindOfClass:[NSArray class]]) return v;
    if ([v isKindOfClass:[NSString class]] && [v length])
        return [[v componentsSeparatedByString:@","] valueForKey:@"stringByTrimmingCharactersInSet:"];
    return @[];
}

+ (BOOL)shouldDrop:(BBBulletin *)b {
    NSDictionary *p = [self prefs];
    NSString *bid = b.sectionID ?: @"";

    // 黑名单：直接拦
    if ([[self arrayFromPref:p[@"blacklist"]] containsObject:bid]) return YES;

    // 白名单：若设置了白名单，不在其中的都拦
    NSArray *white = [self arrayFromPref:p[@"whitelist"]];
    if (white.count && ![white containsObject:bid]) return YES;

    // 关键词过滤（拦截呈现，但已记录）
    NSArray *kw = [self arrayFromPref:p[@"blockKeywords"]];
    if (kw.count) {
        NSString *text = [NSString stringWithFormat:@"%@ %@ %@",
                          b.title ?: @"", b.message ?: @"", b.subtitle ?: @""];
        for (NSString *k in kw) {
            if (k.length && [text rangeOfString:k].location != NSNotFound) return YES;
        }
    }
    return NO;
}

+ (void)applyToBulletin:(BBBulletin *)b {
    NSDictionary *p = [self prefs];

    // 内容替换：[{from,to}, ...]（预设规则）
    NSArray *rules = p[@"replaceRules"];
    if ([rules isKindOfClass:[NSArray class]]) {
        for (NSDictionary *r in rules) {
            NSString *from = r[@"from"], *to = (r[@"to"] ?: @"");
            if (from.length) {
                if (b.title)    b.title    = [b.title    stringByReplacingOccurrencesOfString:from withString:to];
                if (b.message)  b.message  = [b.message  stringByReplacingOccurrencesOfString:from withString:to];
                if (b.subtitle) b.subtitle = [b.subtitle stringByReplacingOccurrencesOfString:from withString:to];
            }
        }
    }

    // 按 App 换提示音：{bundle: soundName}
    // 🔴 TODO：iOS 16 上把 bulletin.sound 设成自定义声音的具体 API 需在真机确认
    //   （UNNotificationSound / 本地音频路径）。下面只是占位，别直接当可用。
    NSDictionary *sounds = p[@"appSounds"];
    if ([sounds isKindOfClass:[NSDictionary class]]) {
        NSString *s = sounds[b.sectionID];
        if (s.length) {
            // b.sound = [UNNotificationSound soundNamed:s];  // 需确认 BBBulletin.sound 接受方式
        }
    }
}

@end
