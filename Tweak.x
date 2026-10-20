// Tweak.x —— v0.0.4 纯只读诊断版（零 hook，绝不可能崩）
//
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 🔴 v0.0.3 为什么进安全模式（必须记住的教训）
//
//   崩溃报告：EXC_BAD_ACCESS (SIGSEGV) / KERN_INVALID_ADDRESS at 0x0000000000000001
//            "The app read or wrote through a null pointer (address 0x1)
//             – an object was released or was never created."
//   ⇒ 这是「过度释放 / 野指针」，不是逻辑错。
//
//   唯一变量对照（这是硬证据，不是猜）：
//     v0.0.2 实际 init 的 hook = 0 个（G1/G2 都不存在，init 指令没执行） → 不崩
//     v0.0.3 实际 init 的 hook = 1 个（探针 G4 _sendAddBulletin:toFeeds:） → 崩
//
//   病因：hook 声明 `- (void)`，但**原方法的返回类型我并不确定**。
//   一旦原方法返回对象，ARC 会在我这个「void 方法」里把返回值丢掉并 release，
//   调用方稍后再用该对象 ⇒ 已释放 ⇒ 0x1。
//
//   ⇒ 铁律：**不知道原方法签名，就不要 hook**。
//     先用 method_getTypeEncoding 把签名量出来（纯只读，零风险），再照抄写 hook。
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
// 本版做三件事，全是只读：
//   1. 确认 BBServer 在哪个进程里存在
//   2. 用 class_copyMethodList + method_getTypeEncoding 打印每个候选方法的**完整类型编码**
//      （编码里能直接读出返回类型和每个参数类型，下一版照抄即可）
//   3. 结论文本放在日志最后，保证一定在 App 的 tail 窗口里
//
// 🔴 Logos 坑：注释里绝不出现以百分号开头的 Logos 关键字（nb_precheck.py 把关）。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *const kNBLogPath = @"/var/mobile/Library/NotifyBox/tweak.log";

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

// 把类型编码翻成人话，方便直接抄成 hook 签名
static NSString *NBDecodeEncoding(const char *enc) {
    if (!enc) return @"(无)";
    return [NSString stringWithUTF8String:enc] ?: @"?";
}

%ctor {
    Class c = objc_getClass("BBServer");
    if (!c) {
        NBLog(@"!!! [%@] BBServer 类不存在（该进程里没有公告板服务）", NBProc());
        return;
    }

    unsigned int cnt = 0;
    Method *ms = class_copyMethodList(c, &cnt);
    NBLog(@"=== [%@] NotifyBox v0.0.4 只读诊断（零 hook）· BBServer 共 %u 个方法 ===", NBProc(), cnt);

    NSMutableArray *names = [NSMutableArray array];   // 只存名字，用于最后统计
    if (ms) {
        for (unsigned i = 0; i < cnt; i++) {
            NSString *sel = NSStringFromSelector(method_getName(ms[i]));
            NSString *low = [sel lowercaseString];
            // 关注：发布入口 / 加公告 / 通知投递
            if (!([low containsString:@"publish"] ||
                  [low containsString:@"addbulletin"] ||
                  [low containsString:@"postnotification"] ||
                  [low containsString:@"noticesbulletin"] ||
                  [low containsString:@"sendbulletin"])) {
                continue;
            }
            [names addObject:sel];
            // 🔴 这一行就是本轮的全部价值：名字 + 精确类型编码
            //    例：v32@0:8@16Q24 ⇒ 返回 void，参数 = self, _cmd, 对象, unsigned long long
            NBLog(@"SEL %@  ENC %@", sel, NBDecodeEncoding(method_getTypeEncoding(ms[i])));
        }
        free(ms);
    }

    NBLog(@"=== [%@] 候选 %lu 条（上面每行 SEL+ENC 就是完整签名） ===",
          NBProc(), (unsigned long)names.count);
    NBLog(@"=== [%@] v0.0.4 未挂任何 hook，本版不会崩 === ", NBProc());
}
