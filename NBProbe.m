//
//  NBProbe.m — 注入/沙箱通道诊断（v0.0.158 临时件）
//
//  为什么单独做一个 dylib，而不是塞进 NotifyBox：
//    NotifyBox 的 Filter 只匹配 SpringBoard + backboardd。要回答的问题是
//    「插件在**用户 App** 里到底拿得到什么权限」，就必须注入到用户 App 里 ——
//    那是 NotifyBox 从来不去的地方，把它塞进去等于给产品加了一堆它不该有的行为。
//
//  🔴 注入到「所有 App」意味着这份代码会在每一次 App 启动时跑。
//     所以它的第一要求不是"测得全"，而是**绝不能把 App 弄崩**：
//       · 全部工作裹在 @try/@catch + @autoreleasepool 里
//       · 不碰 UIKit（不建视图、不碰 window、不读任何未知对象的 description）
//       · 不做任何扫描/遍历（NotifyBox 就是死在 ctor 里那个 Containers 扫描上的）
//       · 每个进程只跑一次（ctor 天然只跑一次，不用额外加锁）
//
//  🔴 设计要点：**五条通道 + 一条对照组，成败与 errno 全记下来。**
//     这一整轮排查最贵的教训是"两种病同形"：
//       文件不在 = 没跑到 / 跑了但写不进 / 写进了但没人读
//     所以这里：
//       ① ctl（自己的家目录）—— **必须成功**。它失败说明探针自己没跑通，
//          与沙箱无关。没有这一条，后面四条全 FAIL 时无法归因。
//       ② tmp（/private/var/tmp）—— 已实测 App 和 SpringBoard 都写不进
//       ③ data（/var/mobile/Library/NotifyBox）—— 共享数据目录
//       ④ prefsA（固定域 com.yxh41.notifybox.probe）—— cfprefsd 代写
//       ⑤ prefsB（自身 bundle id 域）—— App 一定写得进自己的域，用来区分
//          "cfprefsd 整体不通" 与 "只是不许写别人的域"
//
//  🔴 另一个必须记的字段：`arch`。
//     它来自**编译期宏**，也就是"这个进程实际加载的是哪个切片"。
//     瘦 arm64e 的 dylib 进不了 arm64 进程；如果某个 App 报 `arch=arm64`，
//     那就直接证明了 thin-arm64e 包在它里面不可能工作 —— 这是本轮的头号假设。
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>

#define NBP_DOMAIN  @"com.yxh41.notifybox.probe"
#define NBP_DATADIR @"/var/mobile/Library/NotifyBox"

static NSString *NBPProcName(void) {
    @try {
        NSString *n = [NSProcessInfo processInfo].processName;
        if (n.length) return n;
    } @catch (__unused NSException *e) { }
    return @"?";
}

static NSString *NBPBundleID(void) {
    @try {
        NSString *b = [[NSBundle mainBundle] bundleIdentifier];
        if (b.length) return b;
    } @catch (__unused NSException *e) { }
    // 守护进程（如 backboardd）常常没有 bundle id，用进程名当身份，别返回空
    return [@"proc:" stringByAppendingString:NBPProcName()];
}

// 🔴 编译期宏 = **实际被加载的那个切片**。fat 包里两个切片共用同一份源码，
//    编出来各带各的宏值，所以这条是"谁在里面跑"的硬证据，不是猜测。
static NSString *NBPArchSelf(void) {
#if defined(__arm64e__)
    return @"arm64e";
#elif defined(__arm64__)
    return @"arm64";
#else
    return @"other";
#endif
}

// 写文件测试：返回 @"OK" 或 @"FAIL(errno=N:strerror)"。
// 先试 atomically:YES（临时文件 + rename，要求目录可写），
// 失败再试 NO（直接 open+write，只要求文件可建），两轮的 errno 都要能区分。
static NSString *NBPWriteFile(NSString *dir, NSString *name, NSString *body) {
    @try {
        if (!dir.length) return @"FAIL(nodir)";
        NSString *p = [dir stringByAppendingPathComponent:name];
        NSData *d = [body dataUsingEncoding:NSUTF8StringEncoding];
        if (!d) return @"FAIL(nodata)";

        errno = 0;
        BOOL ok = [d writeToFile:p atomically:YES];
        int e1 = errno;
        if (!ok) {
            errno = 0;
            ok = [d writeToFile:p atomically:NO];
            int e2 = errno;
            if (!ok) {
                return [NSString stringWithFormat:@"FAIL(atomic errno=%d:%s / plain errno=%d:%s)",
                        e1, strerror(e1), e2, strerror(e2)];
            }
        }
        chmod([p fileSystemRepresentation], 0666);
        return @"OK";
    } @catch (__unused NSException *e) {
        return @"FAIL(exception)";
    }
}

static NSString *NBPWritePrefs(NSString *appID, NSString *key, NSString *val) {
    @try {
        if (!appID.length || !key.length) return @"FAIL(noid)";
        CFStringRef aid = (__bridge CFStringRef)appID;
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFStringRef)val, aid);
        // Synchronize 才是"交给 cfprefsd 落盘"的那一步；不同步 = 只在内存里 = 读回必然空
        Boolean ok = CFPreferencesAppSynchronize(aid);
        return ok ? @"OK" : @"FAIL(sync=NO)";
    } @catch (__unused NSException *e) {
        return @"FAIL(exception)";
    }
}

static void NBProbeRun(void) {
    @autoreleasepool {
        @try {
            NSString *proc = NBPProcName();
            NSString *bid  = NBPBundleID();
            NSString *arch = NBPArchSelf();
            NSString *home = NSHomeDirectory();
            NSString *tmpName  = [NSString stringWithFormat:@"nbprobe_%@.txt", proc];
            NSString *dataName = [NSString stringWithFormat:@".inj_%@.txt", proc];

            // 第一轮：只用最小 body 做写入测试，避免"测试内容本身太大"影响结果
            NSString *seed = [NSString stringWithFormat:@"%@ %@ %@ %d",
                              [NSDate date], proc, arch, (int)getpid()];

            NSString *ctl   = NBPWriteFile(home, @".nbprobe_ctl", seed);
            NSString *tmp   = NBPWriteFile(@"/private/var/tmp", tmpName, seed);
            NSString *data  = NBPWriteFile(NBP_DATADIR, dataName, seed);
            NSString *prefsA = NBPWritePrefs(NBP_DOMAIN, [@"inj." stringByAppendingString:proc], seed);
            NSString *prefsB = NBPWritePrefs(bid, @"NBProbeReport", seed);

            // 读能力：能 stat 到和能写到是两件事，分开记
            errno = 0;
            struct stat st;
            int rs = stat([NBP_DATADIR fileSystemRepresentation], &st);
            int rerr = errno;

            NSMutableString *r = [NSMutableString string];
            [r appendFormat:@"at=%@\n", [NSDate date]];
            [r appendFormat:@"proc=%@\n", proc];
            [r appendFormat:@"bid=%@\n", bid];
            [r appendFormat:@"arch=%@\n", arch];
            [r appendFormat:@"uid=%d euid=%d pid=%d\n", (int)getuid(), (int)geteuid(), (int)getpid()];
            [r appendFormat:@"v=%@\n", @"0.0.158"];
            [r appendFormat:@"home=%@\n", home];
            [r appendString:@"--- 五条通道 ---\n"];
            [r appendFormat:@"ctl(自家目录,对照组,必须OK)=%@\n", ctl];
            [r appendFormat:@"tmp(/private/var/tmp)=%@\n", tmp];
            [r appendFormat:@"data(通知盒子数据目录)=%@\n", data];
            [r appendFormat:@"prefsA(固定域)=%@\n", prefsA];
            [r appendFormat:@"prefsB(自身域)=%@\n", prefsB];
            [r appendFormat:@"stat(数据目录)=%d errno=%d\n", rs, rs == 0 ? 0 : rerr];

            // 第二轮：把完整报告写回**每一条**通道（各自成败只记日志，不再影响结论）。
            //   为什么五条都写：任何一条能通，人就能读到答案；只写"看起来会成的那条"
            //   等于把结论押在一个还没验证的假设上。
            NSString *r1 = NBPWriteFile(home, @".nbprobe_report", r);
            NSString *r2 = NBPWriteFile(@"/private/var/tmp", [NSString stringWithFormat:@"nbprobe_%@_report.txt", proc], r);
            NSString *r3 = NBPWriteFile(NBP_DATADIR, [NSString stringWithFormat:@".inj_%@_report.txt", proc], r);
            NSString *r4 = NBPWritePrefs(NBP_DOMAIN, [@"report." stringByAppendingString:proc], r);
            NSString *r5 = NBPWritePrefs(bid, @"NBProbeReportFull", r);

            NSLog(@"[NBProbe] ===== %@ / %@ / %@ =====\n%@"
                  @"--- 报告回写 ---\nctl=%@ tmp=%@ data=%@ prefsA=%@ prefsB=%@",
                  proc, bid, arch, r, r1, r2, r3, r4, r5);
        } @catch (__unused NSException *e) {
            // 🔴 静默失败与"没跑到"同形 ⇒ 至少留一条 NSLog
            NSLog(@"[NBProbe] ⚠️ 探针异常（已吞，绝不影响宿主）proc=%@", NBPProcName());
        }
    }
}

__attribute__((constructor))
static void NBProbeCtor(void) {
    NBProbeRun();
}
