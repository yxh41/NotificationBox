// Tweak.x —— 录制 + 呈现层过滤的核心入口（带自诊断版）
//
// 🔴 唯一 hook 点：SpringBoard 的 BBServer（所有通知的中枢）。
// ⚠️ iOS 16 上发布入口到底叫什么，各家版本不一致。本版**不再靠猜**：
//    %ctor 里枚举 BBServer 全部含 publish/bulletin 的选择器写进日志，
//    并自动只挂「真实存在」的那一个（G1 / G2）。
//    日志：/var/mobile/Library/NotifyBox/tweak.log
//
// 🔴 Logos 坑（已踩两次）：注释里不要出现 %orig 字样；全方法只在末尾留一次原方法调用。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "NotifyFilter.h"   // 内含 BBBulletin 最小接口声明
#import "NotifyStore.h"

static NSString *const kNBLogPath = @"/var/mobile/Library/NotifyBox/tweak.log";
static int gNBHits = 0;

static void NBLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[kNBLogPath stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kNBLogPath];
    if (fh) {
        @try { [fh seekToEndOfFile]; [fh writeData:d]; }
        @finally { [fh closeFile]; }
    } else {
        [d writeToFile:kNBLogPath atomically:YES];
    }
}

// 共用处理：返回 YES 表示继续走原方法（展示），NO 表示拦下不展示（但已记录）
static BOOL NBHandle(BBBulletin *b) {
    if (!b) return YES;
    NSString *bid = b.sectionID ?: @"";
    if (gNBHits < 30) {
        gNBHits++;
        NBLog(@"hit#%d bundle=%@ title=%@ date=%@", gNBHits, bid, b.title, b.date);
    }
    // 1) 先记录原始通知（无论后面是否拦截/替换）
    [NotifyStore recordWithBundle:bid
                            title:b.title
                          message:b.message
                        subtitle:b.subtitle
                             date:b.date];
    // 2) 呈现层
    if ([NotifyFilter shouldDrop:b]) {
        NBLog(@"drop bundle=%@", bid);
        return NO;
    }
    [NotifyFilter applyToBulletin:b];
    return YES;
}

// ---------- G1: - publishBulletin: ----------
%group G1
%hook BBServer
- (void)publishBulletin:(BBBulletin *)bulletin {
    if (NBHandle(bulletin)) {
        %orig(bulletin);
    }
}
%end
%end

// ---------- G2: - _publishBulletin:destinations: ----------
%group G2
%hook BBServer
- (void)_publishBulletin:(BBBulletin *)bulletin destinations:(unsigned long long)destinations {
    if (NBHandle(bulletin)) {
        %orig(bulletin, destinations);
    }
}
%end
%end

%ctor {
    Class c = objc_getClass("BBServer");
    if (!c) {
        NBLog(@"!!! BBServer 类不存在（tweak 似乎没注入 SpringBoard）");
        return;
    }
    BOOL has1 = class_getInstanceMethod(c, @selector(publishBulletin:)) != NULL;
    BOOL has2 = class_getInstanceMethod(c, @selector(_publishBulletin:destinations:)) != NULL;
    NBLog(@"=== NotifyBox loaded. publishBulletin:=%@  _publishBulletin:destinations:=%@ ===",
          has1 ? @"YES" : @"NO", has2 ? @"YES" : @"NO");

    // 枚举 BBServer 上所有含 publish/bulletin 的选择器（最多 60 条）—— 这就是真机 API 清单
    unsigned int cnt = 0, logged = 0;
    Method *ms = class_copyMethodList(c, &cnt);
    if (ms) {
        for (unsigned i = 0; i < cnt && logged < 60; i++) {
            NSString *sel = NSStringFromSelector(method_getName(ms[i]));
            NSString *low = [sel lowercaseString];
            if ([low containsString:@"bulletin"] || [low containsString:@"publish"]) {
                NBLog(@"  sel: %@", sel);
                logged++;
            }
        }
        free(ms);
    }
    NBLog(@"=== BBServer 共 %u 个方法，其中列出 %u 个 ===", cnt, logged);

    if (has1) {
        NBLog(@"--> 使用 G1 (publishBulletin:)");
        %init(G1);
    } else if (has2) {
        NBLog(@"--> 使用 G2 (_publishBulletin:destinations:)");
        %init(G2);
    } else {
        NBLog(@"!!! 两个候选都不存在，请看上面的 sel 清单，把真实方法名加进 Tweak.x");
    }
}
