// Tweak.x —— 录制 + 呈现层过滤的核心入口（v0.0.3：换到真身发布方法）
//
// 🔴 唯一 hook 点：SpringBoard 的 BBServer（所有通知的中枢）。
//
// 📌 v0.0.2 真机日志结论（9367 B）：
//    `=== [SpringBoard] NotifyBox loaded. publishBulletin:=NO  _publishBulletin:destinations:=NO ===`
//    `=== BBServer 共 256 个方法，其中列出 66 个 ===`
//    `!!! 两个候选都不存在`
//    ⇒ 注入是成功的（loaded 行打得出来），但**方法名全猜错**，所以一条都没录。
//    同时 `!!! [backboardd] BBServer 类不存在` ⇒ backboardd 不用管，只在 SpringBoard 里。
//    真身（日志清单里读到）：
//        publishBulletinRequest:forSectionID:forDestinations:
//    ⇒ v0.0.3 加 G3 组挂它，优先级 G3 > G2 > G1。
//
// 🔴 Logos 坑（已踩两次）：注释里绝对不要写出任何以百分号开头的 Logos 关键字，
//    否则预处理会把它当成真指令、把花括号搞失衡。由 nb_precheck.py 把关。
//    另：每个方法只在末尾留一次原方法调用。
//
// 🔴🔴 SpringBoard 里 unrecognized selector = 立刻崩（白苹果/安全模式）。
//    所以读任何属性都走 **防御式 KVC**（NBSafeStr/NBSafeDate 里全包 @try），
//    绝不直接 b.title 这种硬调用。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "NotifyFilter.h"   // 内含 BBBulletin 最小接口声明
#import "NotifyStore.h"

static NSString *const kNBLogPath = @"/var/mobile/Library/NotifyBox/tweak.log";
static int gNBHits = 0;

static NSString *NBProc(void) {
    NSString *p = [NSProcessInfo processInfo].processName;
    return p.length ? p : @"?";
}

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

// ---------- 防御式取值（SpringBoard 里抛异常就等于崩，必须全包） ----------

static id NBSafeValue(id obj, NSString *key) {
    if (!obj) return nil;
    if (![obj respondsToSelector:@selector(valueForKey:)]) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *NBSafeStr(id obj, NSString *key) {
    id v = NBSafeValue(obj, key);
    if (!v) return nil;
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    if ([v isKindOfClass:[NSDate class]]) return [(NSDate *)v description];
    @try {
        return [v description];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSDate *NBSafeDate(id obj, NSString *key) {
    id v = NBSafeValue(obj, key);
    return [v isKindOfClass:[NSDate class]] ? (NSDate *)v : nil;
}

static NSString *NBClassName(id obj) {
    if (!obj) return @"nil";
    @try {
        return NSStringFromClass([obj class]);
    } @catch (__unused NSException *e) {
        return @"?";
    }
}

// ---------- 录制核心 ----------
// bundleHint：能直接拿到 sectionID 时优先用它（哪怕 req 类型不认识也能记对 App）
static BOOL NBRecord(id req, NSString *bundleHint) {
    NSString *bid   = bundleHint;
    NSString *title = NBSafeStr(req, @"title");
    NSString *msg   = NBSafeStr(req, @"message");
    NSString *sub   = NBSafeStr(req, @"subtitle");
    NSDate   *date  = NBSafeDate(req, @"date");

    // 有的版本 req 是外层包装，真正的内容在 .bulletin 里；钻一层再试
    BOOL needDig = (title.length == 0 && msg.length == 0);
    if (needDig) {
        id inner = NBSafeValue(req, @"bulletin");
        if (inner && inner != req) {
            if (!bid.length)   bid   = NBSafeStr(inner, @"sectionID");
            if (!title.length) title = NBSafeStr(inner, @"title");
            if (!msg.length)   msg   = NBSafeStr(inner, @"message");
            if (!sub.length)   sub   = NBSafeStr(inner, @"subtitle");
            if (!date)         date  = NBSafeDate(inner, @"date");
        }
    }
    if (!bid.length) bid = NBSafeStr(req, @"sectionID");
    if (!bid.length) return NO;                 // 连 App 都认不出，不记

    if (gNBHits < 30) {
        gNBHits++;
        NBLog(@"hit#%d bundle=%@ cls=%@ title=%@ msg=%@",
              gNBHits, bid, NBClassName(req),
              title.length ? title : @"(nil)", msg.length ? msg : @"(nil)");
    }
    [NotifyStore recordWithBundle:bid title:title message:msg subtitle:sub date:date];
    return YES;
}

// 呈现层：返回 YES 继续展示，NO 拦下（但已记录）
static BOOL NBApply(BBBulletin *b) {
    if (!b) return YES;
    if ([NotifyFilter shouldDrop:b]) {
        NBLog(@"drop bundle=%@", NBSafeStr(b, @"sectionID"));
        return NO;
    }
    [NotifyFilter applyToBulletin:b];
    return YES;
}

// ---------- G3（iOS 16 真身）：- publishBulletinRequest:forSectionID:forDestinations: ----------
%group G3
%hook BBServer
- (void)publishBulletinRequest:(id)request
                  forSectionID:(NSString *)sectionID
               forDestinations:(unsigned long long)destinations {
    if (gNBHits == 0) {
        NBLog(@"G3 首次调用 reqCls=%@ sectionID=%@ dest=%llu",
              NBClassName(request), sectionID, destinations);
    }
    if (!NBRecord(request, sectionID)) {
        NBLog(@"G3 req 认不出 bundle，cls=%@ sectionID=%@", NBClassName(request), sectionID);
    }
    // 过滤/替换只作用于 BBBulletin 场景；req 不是 BBBulletin 时跳过（避免类型误用）
    if ([request isKindOfClass:NSClassFromString(@"BBBulletin")]) {
        NBApply((BBBulletin *)request);
    }
    %orig(request, sectionID, destinations);
}
%end
%end

// ---------- G1: - publishBulletin: ----------
%group G1
%hook BBServer
- (void)publishBulletin:(BBBulletin *)bulletin {
    NBLog(@"G1 首次调用 bundle=%@", NBSafeStr(bulletin, @"sectionID"));
    NBRecord(bulletin, nil);
    if (NBApply(bulletin)) {
        %orig(bulletin);
    }
}
%end
%end

// ---------- G2: - _publishBulletin:destinations: ----------
%group G2
%hook BBServer
- (void)_publishBulletin:(BBBulletin *)bulletin destinations:(unsigned long long)destinations {
    NBLog(@"G2 首次调用 bundle=%@ dest=%llu", NBSafeStr(bulletin, @"sectionID"), destinations);
    NBRecord(bulletin, nil);
    if (NBApply(bulletin)) {
        %orig(bulletin, destinations);
    }
}
%end
%end

// ---------- G4：纯只读探针（不记录、不改行为、不改返回值） ----------
// 目的：万一 G3 也不是真入口，这一轮仍然能拿到「谁在被调用」的事实，
//       避免再白跑一次。参数一律按 id 声明，unsigned long long 与指针在 arm64
//       是同一个 x 寄存器、8 字节，原样转发不会破坏调用约定。
%group G4
%hook BBServer
- (void)_sendAddBulletin:(id)bulletin toFeeds:(id)feeds {
    static int p4 = 0;
    if (p4 < 20) {
        p4++;
        NBLog(@"P#%d _sendAddBulletin:toFeeds: cls=%@ bundle=%@ title=%@",
              p4, NBClassName(bulletin),
              NBSafeStr(bulletin, @"sectionID"), NBSafeStr(bulletin, @"title"));
    }
    %orig(bulletin, feeds);
}
%end
%end

%group G5
%hook BBServer
- (void)addBulletin:(id)bulletin toSectionID:(id)sectionID {
    static int p5 = 0;
    if (p5 < 20) {
        p5++;
        NBLog(@"P#%d addBulletin:toSectionID: cls=%@ sid=%@ title=%@",
              p5, NBClassName(bulletin),
              NBSafeStr(sectionID, @"description"), NBSafeStr(bulletin, @"title"));
    }
    %orig(bulletin, sectionID);
}
%end
%end

%ctor {
    Class c = objc_getClass("BBServer");
    if (!c) {
        NBLog(@"!!! [%@] BBServer 类不存在（该进程里没有公告板服务）", NBProc());
        return;
    }
    BOOL has3 = class_getInstanceMethod(c, @selector(publishBulletinRequest:forSectionID:forDestinations:)) != NULL;
    BOOL has1 = class_getInstanceMethod(c, @selector(publishBulletin:)) != NULL;
    BOOL has2 = class_getInstanceMethod(c, @selector(_publishBulletin:destinations:)) != NULL;
    NBLog(@"=== [%@] NotifyBox loaded. G3:publishBulletinRequest:forSectionID:forDestinations:=%@  G1:publishBulletin:=%@  G2:_publishBulletin:destinations:=%@ ===",
          NBProc(), has3 ? @"YES" : @"NO", has1 ? @"YES" : @"NO", has2 ? @"YES" : @"NO");

    // 只在「一个都没命中」时才打印清单（v0.0.2 打 66 条把结论行挤出了日志窗口）
    if (!has3 && !has1 && !has2) {
        unsigned int cnt = 0;
        Method *ms = class_copyMethodList(c, &cnt);
        NSMutableArray *hits = [NSMutableArray array];
        if (ms) {
            for (unsigned i = 0; i < cnt; i++) {
                NSString *sel = NSStringFromSelector(method_getName(ms[i]));
                NSString *low = [sel lowercaseString];
                if ([low containsString:@"publish"] || [low containsString:@"addbulletin"] ||
                    [low containsString:@"noticesbulletin"] || [low containsString:@"postnotification"] ||
                    [low containsString:@"bulletinrequest"]) {
                    [hits addObject:sel];
                }
            }
            free(ms);
        }
        NBLog(@"=== BBServer 共 %u 个方法，关键 %lu 条 ===", cnt, (unsigned long)hits.count);
        for (NSUInteger i = 0; i < hits.count; i += 3) {
            NSUInteger n = MIN((NSUInteger)3, hits.count - i);
            NSArray *slice = [hits subarrayWithRange:NSMakeRange(i, n)];
            NBLog(@"  sel: %@", [slice componentsJoinedByString:@"  |  "]);
        }
    }

    BOOL inited = NO;
    if (has3) {
        NBLog(@"--> 使用 G3 (publishBulletinRequest:forSectionID:forDestinations:)");
        %init(G3);
        inited = YES;
    } else if (has2) {
        NBLog(@"--> 使用 G2 (_publishBulletin:destinations:)");
        %init(G2);
        inited = YES;
    } else if (has1) {
        NBLog(@"--> 使用 G1 (publishBulletin:)");
        %init(G1);
        inited = YES;
    }

    // 只读探针：只在方法确实存在时挂，避免给 BBServer 凭空 addMethod
    BOOL has4 = class_getInstanceMethod(c, @selector(_sendAddBulletin:toFeeds:)) != NULL;
    BOOL has5 = class_getInstanceMethod(c, @selector(addBulletin:toSectionID:)) != NULL;
    if (has4) { NBLog(@"--> 探针 G4 已挂 (_sendAddBulletin:toFeeds:)"); %init(G4); }
    if (has5) { NBLog(@"--> 探针 G5 已挂 (addBulletin:toSectionID:)");  %init(G5); }
    if (!has4 && !has5) NBLog(@"--> 两个探针方法都不存在");

    // 结论再打一次：保证它在日志尾部窗口内（v0.0.2 的结论行被 66 行清单挤掉了）
    NBLog(@"=== [%@] NotifyBox %@ ===", NBProc(), inited ? @"已挂上发布方法，等通知" : @"!!! 三个候选全不存在，看上面清单");
}
