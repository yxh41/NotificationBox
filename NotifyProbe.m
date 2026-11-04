#import "NotifyProbe.h"
#import "NotifyCommon.h"
#import <objc/runtime.h>
// 🔴 v0.0.139：objc_msgSend 在 objc/message.h（runtime.h 不含它）；
//    dispatch_after/NSEC_PER_SEC 在 dispatch/dispatch.h。
//    Foundation 一般会带进来，但 tweak 侧不赌 re-export —— 显式引入。
#import <objc/message.h>
#import <dispatch/dispatch.h>

// 探针实现。设计口径：**一次说清楚，而不是每条都刷**。
//
// 🔴 日志窗口 ≈ 最后 50 条，且是全局滚动 —— 探针刷 30 行就等于把
//    紧接着要看的 DROP#/REPL#/SPEAK 全挤出去了。
//    所以：类结构只 dump 一次（约 4~6 行），实例只量前 3 条（每条 1 行）。

static int gProbed = 0;
static BOOL gDumped = NO;

// 这些名字一旦出现，就是"换提示音"要用的量
static BOOL NBIsSoundRelated(NSString *name) {
    NSString *low = [name lowercaseString];
    return ([low containsString:@"sound"] || [low containsString:@"alert"]
            || [low containsString:@"vibrat"] || [low containsString:@"interrupt"]
            || [low containsString:@"priority"] || [low containsString:@"importance"]);
}

static NSString *NBClassNameOf(id obj) {
    if (!obj) return @"nil";
    @try {
        return NSStringFromClass([obj class]);
    } @catch (__unused NSException *e) {
        return @"?";
    }
}

// dump 一个类的 property：总数一行 + 名字全列表一行 + 声音相关（带类型编码）一行
static void NBDumpProps(Class c, NSString *label) {
    if (!c) {
        NBSharedLog(@"PROBE %@ 类不存在", label);
        return;
    }
    unsigned int cnt = 0;
    objc_property_t *ps = class_copyPropertyList(c, &cnt);
    NBSharedLog(@"PROBE %@ 有 %u 个 property", label, cnt);
    if (!ps) return;

    NSMutableArray *all = [NSMutableArray array];
    NSMutableArray *key = [NSMutableArray array];
    for (unsigned i = 0; i < cnt; i++) {
        const char *n = property_getName(ps[i]);
        const char *a = property_getAttributes(ps[i]);
        // 🔴 不能写 @(n)：那是把 char* 装箱成 NSValue（指针），不是 NSString。
        NSString *name = n ? [NSString stringWithUTF8String:n] : @"?";
        NSString *attr = a ? [NSString stringWithUTF8String:a] : @"";
        [all addObject:name];
        // 🔴 类型编码是这里的核心产出：T@"BBSound" 表示是个对象，
        //    TQ 表示 unsigned long long，Tc/TB 表示标量/BOOL。
        //    下一版要判"能不能改"，看的就是这一位 —— 猜没用。
        if (NBIsSoundRelated(name)) {
            [key addObject:[NSString stringWithFormat:@"%@{%@}", name, attr]];
        }
    }
    free(ps);

    NBSharedLog(@"PROBE %@ 名字: %@", label, [all componentsJoinedByString:@","]);
    if (key.count) {
        NBSharedLog(@"PROBE %@ 声音相关(%lu): %@", label,
                    (unsigned long)key.count, [key componentsJoinedByString:@" "]);
    } else {
        NBSharedLog(@"PROBE %@ 声音相关: 无（说明名字猜错了，得看上面的名字表）", label);
    }
}

// dump 一个类的**类方法**（元类上就是类方法）。用来看能不能凭空造声音对象。
static void NBDumpClassMethods(Class c, NSString *label) {
    if (!c) return;
    Class meta = object_getClass(c);
    if (!meta) return;
    unsigned int cnt = 0;
    Method *ms = class_copyMethodList(meta, &cnt);
    NSMutableArray *hits = [NSMutableArray array];
    if (ms) {
        for (unsigned i = 0; i < cnt; i++) {
            NSString *n = NSStringFromSelector(method_getName(ms[i]));
            NSString *low = [n lowercaseString];
            if ([low containsString:@"sound"] || [low containsString:@"alert"]
                || [low containsString:@"system"] || [low containsString:@"default"]) {
                [hits addObject:n];
            }
        }
        free(ms);
    }
    NBSharedLog(@"PROBE %@ 类方法共 %u 个，其中相关 %lu 个: %@", label, cnt,
                (unsigned long)hits.count,
                hits.count ? [hits componentsJoinedByString:@" , "] : @"无");
}

@implementation NotifyProbe

+ (void)dumpClassesOnce {
    if (gDumped) return;

    // 🔴🔴 必须容忍「现在是 %ctor，BulletinBoard 还没加载」这种情况。
    //    v0.0.3 已经踩过一次同类坑：constructor 阶段对 BBServer 调
    //    class_getInstanceMethod 返回 NULL，而同一时刻 class_copyMethodList 却正常。
    //    这里如果 objc_getClass("BBBulletin") 拿到 nil 就把 gDumped 置真，
    //    探针会永久失效 —— 而且日志里只会留一句「类不存在」，
    //    下一条通知来的时候明明能拿到，却再也不试了。白跑一整轮。
    //    ⇒ 找不到就**不置位**，留给第一条通知来的时候重试。
    if (!objc_getClass("BBBulletin")) {
        // 🔴 日志文案里出现 "%ctor" 必须写成 "%%ctor"：
        //    NBSharedLog 带 NS_FORMAT_FUNCTION 标注，编译器会把 %c 当成 char 转换符，
        //    然后报 "more '%' conversions than data arguments" —— -Werror 直接挂。
        //    （ObjC 字符串字面量里 % 本身不需要转义，只有**格式串语义**要求写成 %%）
        //    任何裸 % 在格式串里都是雷，写 % 一律双写。
        NBSharedLog(@"PROBE 现在拿不到 BBBulletin（大概率是 %%ctor 阶段框架还没加载），等第一条通知再试");
        return;
    }
    gDumped = YES;

    @try {
        NBSharedLog(@"=== PROBE 开始 dump 类结构（只读，一次性）===");
        NBDumpProps(objc_getClass("BBBulletin"), @"BBBulletin");
        NBDumpProps(objc_getClass("BBBulletinRequest"), @"BBBulletinRequest");
        NBDumpProps(objc_getClass("BBSound"), @"BBSound");
        NBDumpClassMethods(objc_getClass("BBSound"), @"BBSound");
        NBDumpClassMethods(objc_getClass("BBBulletin"), @"BBBulletin");
        NBSharedLog(@"=== PROBE dump 结束 ===");
    } @catch (__unused NSException *e) {
        NBSharedLog(@"!!! PROBE dump 抛异常（已忽略）");
    }
}

+ (void)probeBulletin:(id)obj tag:(NSString *)tag {
    if (!obj) return;
    // 兜底重试：%ctor 那次可能因为框架没加载而没 dump 成
    if (!gDumped) [self dumpClassesOnce];
    if (gProbed >= 3) return;          // 只量前 3 条，别挤爆日志窗口
    gProbed++;
    int idx = gProbed;

    @try {
        // 🔴 每个键**单独 @try**：KVC 读一个不存在的键会抛 NSUndefinedKeyException。
        //    整段共用一个 @try 的话，第一个抛错的键会带走后面所有键的值
        //    ⇒ 看到 "sound 之后什么都没有"，会误判成"这些量不存在"，
        //       而真相只是"第一个键名写错了"。这类误判白烧过一整轮。
        NSArray *keys = @[@"sound", @"playSound", @"alertType", @"importance",
                          @"priority", @"bulletinID", @"sectionID", @"hasSound"];
        NSMutableArray *cells = [NSMutableArray array];
        for (NSString *k in keys) {
            NSString *cell = nil;
            @try {
                id v = [obj valueForKey:k];
                if (!v) {
                    cell = [NSString stringWithFormat:@"%@=nil", k];
                } else if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) {
                    cell = [NSString stringWithFormat:@"%@=%@", k, v];
                } else {
                    // 是对象但内容不可读 ⇒ 只报类名（真正的信息在这里：
                    // sound 若是 BBSound，下一版就得去造 BBSound）
                    cell = [NSString stringWithFormat:@"%@=<%@>", k, NBClassNameOf(v)];
                }
            } @catch (__unused NSException *e) {
                cell = [NSString stringWithFormat:@"%@=THROW", k];
            }
            [cells addObject:cell];
        }
        NBSharedLog(@"PROBE#%d tag=%@ cls=%@ :: %@", idx, tag ?: @"?",
                    NBClassNameOf(obj), [cells componentsJoinedByString:@" "]);
    } @catch (__unused NSException *e) {
        NBSharedLog(@"!!! PROBE#%d 抛异常（已忽略）", idx);
    }
}

+ (void)dumpServerQueueOnce {
    static BOOL done = NO;
    if (done) return;
    // 同 dumpClassesOnce 的教训：%ctor 阶段 BulletinBoard 可能还没加载，
    // 拿不到类就**不置位**，留给第一次 hook 命中时重试。
    Class c = objc_getClass("BBServer");
    if (!c) return;
    done = YES;

    @try {
        unsigned int cnt = 0;
        objc_property_t *ps = class_copyPropertyList(c, &cnt);
        NSMutableArray *hits = [NSMutableArray array];
        if (ps) {
            for (unsigned i = 0; i < cnt; i++) {
                const char *n = property_getName(ps[i]);
                if (!n) continue;
                NSString *name = [NSString stringWithUTF8String:n];
                NSString *low = [name lowercaseString];
                if ([low containsString:@"queue"] || [low containsString:@"serial"]
                    || [low containsString:@"dispatch"] || [low containsString:@"thread"]) {
                    [hits addObject:name];
                }
            }
            free(ps);
        }
        NBSharedLog(@"PROBE BBServer property 共 %u 个，队列相关 %lu 个: %@", cnt,
                    (unsigned long)hits.count,
                    hits.count ? [hits componentsJoinedByString:@","] : @"无");
    } @catch (__unused NSException *e) {
        NBSharedLog(@"!!! PROBE BBServer property dump 抛异常（已忽略）");
    }

    // 我们自己此刻在哪个队列上 —— 这决定了"延迟后还能不能回到这个队列"。
    // dispatch_queue_get_label 是线程安全的只读 API，不会阻塞。
    @try {
        const char *label = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
        NBSharedLog(@"PROBE 当前队列标签 = %s", label ? label : "?");
    } @catch (__unused NSException *e) { }
}

+ (int)probedCount {
    return gProbed;
}

@end

#pragma mark - v0.0.139：屏幕通道（完全不经过文件系统）

// 为什么要有这一条：2026-11-04 那天，所有基于文件的判据全部为绿
//   （大小/权限/版本串/依赖库/符号/过滤器/对照插件/两个进程都重启过/tmp 可写），
//   却一个字节都没被写出来。⇒「文件对不对」已经问完了，剩下的是「代码有没有执行」，
//   而这个问题**文件系统答不了**：沙箱、信任缓存、注入层，每一种都能让它无声消失。
//   ⇒ 换一条与文件无关的通道：把结果**显示在屏幕上**。
//     弹了 = 代码跑了（框里带着写失败的 errno）；不弹 = 代码没跑。
//
// 🔴 两条硬约束（都是为了避免把"诊断"变成"新的静默失败"）：
//   ① 全部走 NSClassFromString + objc_msgSend，**绝不硬引用 UIKit 符号**：
//      tweak 没有链 UIKit，硬引用会在加载期变成 undefined symbol ⇒
//      直接表现为"插件静默不加载"，正好是这次要排查的那个形态。
//   ② 取不到 UI 的进程（backboardd 是 root 守护进程）静默退出：
//      它本来就没有界面，不该在这里产生任何行为。

typedef id   (*NBPMsg0)(id, SEL);
typedef id   (*NBPMsg1)(id, SEL, id);
typedef id   (*NBPMsg3a)(id, SEL, id, id, NSInteger);   // alertControllerWithTitle:message:preferredStyle:
typedef id   (*NBPMsg3b)(id, SEL, id, NSInteger, id);   // actionWithTitle:style:handler:
typedef void (*NBPVMsg1)(id, SEL, id);
typedef void (*NBPVMsg3)(id, SEL, id, BOOL, id);
typedef BOOL (*NBPMsgBool)(id, SEL);

void NBShowBootAlert(void) {
    static int gAlertArmed = 0;
    if (gAlertArmed) return;

    Class appCls   = NSClassFromString(@"UIApplication");
    Class alertCls = NSClassFromString(@"UIAlertController");
    Class actCls   = NSClassFromString(@"UIAlertAction");
    if (!appCls || !alertCls || !actCls) return;   // 没有 UI 的进程，静静退出
    gAlertArmed = 1;

    NSString *msg = NBLastProbeReport();
    if (!msg.length) msg = @"探针没有产出文本（NBLastProbeReport 返回空）";
    // 太长会被系统截断；前 8 行是身份 + dylib 路径，正是最要紧的部分
    if (msg.length > 1500) msg = [msg substringToIndex:1500];

    NSString *title = [NSString stringWithFormat:@"NotifyBox 探针 v%@", NOTIFYBOX_VER_STR];

    // 🔴 为什么要重试：ctor 跑在 SpringBoard 启动的很早阶段，6 秒后界面未必就绪；
    //    一次弹不出来就永远看不到 —— 那又会变成"没弹 = 没跑"的误判。
    //    ⇒ 最多试 8 轮、每轮隔 3 秒，成功即停。只有 8 轮全失败才是真的弹不出来。
    __block int tries = 0;
    void (^attempt)(void) = ^{
        tries++;
        @try {
            id app = ((NBPMsg0)objc_msgSend)((id)appCls, @selector(sharedApplication));
            if (!app) return;

            id win = nil;
            id wins = ((NBPMsg0)objc_msgSend)(app, @selector(windows));
            if ([wins isKindOfClass:[NSArray class]]) {
                for (id w in (NSArray *)wins) {
                    if (((NBPMsgBool)objc_msgSend)(w, @selector(isKeyWindow))) { win = w; break; }
                }
                if (!win && [(NSArray *)wins count]) win = [(NSArray *)wins objectAtIndex:0];
            }
            if (!win) return;

            id vc = ((NBPMsg0)objc_msgSend)(win, @selector(rootViewController));
            for (int i = 0; i < 8 && vc; i++) {
                id p = ((NBPMsg0)objc_msgSend)(vc, @selector(presentedViewController));
                if (!p) break;
                vc = p;
            }
            if (!vc) return;
            if (((NBPMsg0)objc_msgSend)(vc, @selector(presentedViewController))) return;

            id alert = ((NBPMsg3a)objc_msgSend)((id)alertCls,
                @selector(alertControllerWithTitle:message:preferredStyle:),
                title, msg, (NSInteger)1);
            if (!alert) return;
            id ok = ((NBPMsg3b)objc_msgSend)((id)actCls,
                @selector(actionWithTitle:style:handler:), @"知道了", (NSInteger)0, nil);
            if (ok) ((NBPVMsg1)objc_msgSend)(alert, @selector(addAction:), ok);
            ((NBPVMsg3)objc_msgSend)(vc, @selector(presentViewController:animated:completion:),
                                     alert, YES, nil);
            NBSharedLog(@"!! [屏幕探针] 已弹出（第 %d 次尝试）", tries);
        } @catch (__unused NSException *e) {
            // 弹不出来就下一轮，绝不因为 UI 异常影响 tweak 本身
        }
    };

    // 8 轮 × 3 秒，超出就不再试（避免用户几十分钟后又看到一个框，误以为是别的东西）
    for (int i = 0; i < 8; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((6 + i * 3) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (tries >= 8) return;
            attempt();
        });
    }
}
