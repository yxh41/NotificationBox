//
//  NBProbe.m — 注入/沙箱诊断（v0.0.159 起：**零垃圾版**）
//
//  v0.0.158 那版每个进程会留下 5 个垃圾（实测反馈）：
//    /private/var/tmp/nbprobe_<proc>.txt
//    /private/var/tmp/nbprobe_<proc>_report.txt
//    /var/mobile/Library/NotifyBox/.inj_<proc>.txt
//    /var/mobile/Library/NotifyBox/.inj_<proc>_report.txt
//    以及在**每个 App 自己的 prefs 域**里塞 NBProbeReport / NBProbeReportFull
//  最后那条最脏：等于往微信、抖音的偏好设置里写东西。
//  ⇒ 本版**一个文件都不写、外部域一个键都不碰**，只用我们自己的一个域，
//    且每进程只留 2 个短键。
//
//  🔴 但"不写盘"不等于"测不出沙箱"：写测试是为了量权限，而
//    `access(W_OK)` 和 `stat()` 同样会被沙箱拦（沙箱 hook 的就是这些入口），
//    区别只是**它们不产生任何文件**。所以能力判定一点没丢。
//
//  🔴 两个键的分工（这是唯一还不能省的判据）：
//    `alive.<proc>`  —— **第一句就写**，内容只有架构串。
//                       它不在 ⇒ 探针没被注入 / 没跑到第一句。
//    `report.<proc>` —— 完整报告。
//                       它在而 alive 不在 ⇒ 不可能（证明写入是有序的、可信的）。
//                       alive 在而 report 不在 ⇒ 中途失败，能归因。
//    一个键的话，"没注入"和"跑到一半失败"又会同形。
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
    return [@"proc:" stringByAppendingString:NBPProcName()];
}

// 编译期宏 = **实际被加载的那个切片**（fat 包里两个切片共用源码，各带各的宏值）
static NSString *NBPArchSelf(void) {
#if defined(__arm64e__)
    return @"arm64e";
#elif defined(__arm64__)
    return @"arm64";
#else
    return @"other";
#endif
}

// 只写我们自己的域。这是唯一全通的通道（v0.0.158 实测：连 backboardd 都 OK）。
static BOOL NBPWritePrefs(NSString *key, NSString *val) {
    @try {
        CFStringRef aid = (__bridge CFStringRef)NBP_DOMAIN;
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFStringRef)val, aid);
        return CFPreferencesAppSynchronize(aid) ? YES : NO;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static void NBProbeRun(void) {
    @autoreleasepool {
        @try {
            NSString *proc = NBPProcName();
            NSString *arch = NBPArchSelf();

            // ① 第一句：只记"我活着 + 我是哪个切片"。它不在 ⇒ 没注入/没跑到这里。
            NBPWritePrefs([@"alive." stringByAppendingString:proc], arch);

            // ② 能力测量：**只读**，不产生任何文件。
            //    access/stat 与 writeToFile 走的是同一条沙箱判定，所以结论等价。
            errno = 0;
            struct stat st;
            int ds = stat([NBP_DATADIR fileSystemRepresentation], &st);
            int dse = errno;
            errno = 0;
            int dw = access([NBP_DATADIR fileSystemRepresentation], W_OK);
            int dwe = errno;
            errno = 0;
            int tw = access("/private/var/tmp", W_OK);
            int twe = errno;

            NSString *home = NSHomeDirectory();
            errno = 0;
            int hw = home.length ? access([home fileSystemRepresentation], W_OK) : -1;
            int hwe = errno;

            NSMutableString *r = [NSMutableString string];
            [r appendFormat:@"proc=%@\n", proc];
            [r appendFormat:@"bid=%@\n", NBPBundleID()];
            [r appendFormat:@"arch=%@\n", arch];
            [r appendFormat:@"uid=%d euid=%d pid=%d\n", (int)getuid(), (int)geteuid(), (int)getpid()];
            [r appendFormat:@"v=0.0.159\n"];
            [r appendFormat:@"home=%@\n", home ?: @"(nil)"];
            [r appendFormat:@"stat(数据目录)=%d errno=%d\n", ds, ds == 0 ? 0 : dse];
            [r appendFormat:@"数据目录可写(W_OK)=%d errno=%d\n", dw, dw == 0 ? 0 : dwe];
            [r appendFormat:@"/tmp 可写(W_OK)=%d errno=%d\n", tw, tw == 0 ? 0 : twe];
            [r appendFormat:@"自家目录可写(W_OK)=%d errno=%d\n", hw, hw == 0 ? 0 : hwe];

            // ③ 完整报告，仍然只进我们自己的域
            BOOL ok = NBPWritePrefs([@"report." stringByAppendingString:proc], r);
            NSLog(@"[NBProbe] %@ %@ prefs写入=%@\n%@", proc, arch, ok ? @"OK" : @"FAIL", r);
        } @catch (__unused NSException *e) {
            NSLog(@"[NBProbe] ⚠️ 探针异常（已吞，绝不影响宿主）proc=%@", NBPProcName());
        }
    }
}

__attribute__((constructor))
static void NBProbeCtor(void) {
    NBProbeRun();
}
