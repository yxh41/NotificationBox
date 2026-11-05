#import "NotifyStore.h"
#import "NotifyCommon.h"
#import <sqlite3.h>
#import <errno.h>
#import <string.h>
#import <unistd.h>     // v0.0.136：access()/W_OK/getuid() —— 判「以当前身份能不能写」
#import <sys/stat.h>   // v0.0.136：stat() 读目录属主（诊断里要打 uid:gid）
#import <fcntl.h>      // v0.0.138：open()/O_WRONLY/O_CREAT/O_TRUNC（探针的第二种写法）
#import <dlfcn.h>      // v0.0.138：dladdr() —— 探针要报 dylib 自己的真实路径
#import <CoreFoundation/CoreFoundation.h>   // v0.0.52：Darwin 通知（清系统通知中心用）

// ---------- 列表一次最多取多少条 ----------
// 🔴 这个数**只和"列表能显示多少"有关**，和 `maxRecords`（库里留多少）是两件事：
//    `maxRecords` 是用户自己填的保留上限，默认 500、最大允许到 99999；
//    而列表无论库里有多少条，一次最多取这么多（再多就要分页了）。
// ⇒ 两者**可能不一致**：用户把 maxRecords 填成 5000 时，库里留 5000、
//    列表只显示最新 2000，剩下 3000 条既看不到也左滑删不掉（只能"清空"）。
//    这就是 v0.0.42 加底部「还有 N 条更早记录」提示的原因 —— 让它**说出来**，
//    而不是让用户以为记录丢了。
// 🔴 唯一的来源：`queryWithBundle:` 的 LIMIT 和底部文案的「上限 N」都用它，
//    界面上不许再写一个 2000。
static const NSInteger kNBListLimit = 2000;

// ---------- v0.0.137：数据目录 = 常量（v0.0.136 的"运行时解析"已撤销） ----------
// 🔴🔴 v0.0.136 的错假设，逐条记下来，别再犯：
//    它以为「tweak 有 root 权限，能写进 App 容器」。**只有 backboardd 是 root**，
//    SpringBoard 是 mobile 且受沙箱约束：列不出 `/var/mobile/Containers/Data/Application`
//    （读不了别人容器的父目录），也写不进别人的容器（那是 **那个 App 的** profile 放行的）。
//    ⇒ 真机结果 = split-brain：App 在自己容器里读写（记录数 0），SpringBoard 落回老路径
//      记到别处；而 App 只在**自己的**目录里找 `.tweak_ctor` ⇒ 报「tweak 从未注入」。
//    ⇒ 两条铁律：
//      ① **路径只能是常量**（NOTIFYBOX_LEGACY_DIR）。常量算不出两个答案。
//      ② 老路径的真问题只有**属主**，而属主只有 root 能改 ⇒ 由 backboardd 的 ctor chown。
// 🔴 下面这个 `NBFindAppDocsDir()` 现在**只服务诊断**（v0.0.156 起唯一的调用者是
//    NBWriteOldLocationProbe —— root 进程代读旧位置标记），
//    **绝不**参与写入路径决策 —— 它拿到的路径在 SpringBoard 里恒为 nil，
//    在 App 里恒为自己的容器，两边不一致本身就是这个 bug 的源头。
static NSString *NBFindAppDocsDir(void) {
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *kids = [fm contentsOfDirectoryAtPath:base error:nil];
    if (!kids.count) return nil;
    for (NSString *u in kids) {
        NSString *meta = [[base stringByAppendingPathComponent:u]
                          stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:meta];
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        id ident = d[@"MCMMetadataIdentifier"];
        if (![ident isKindOfClass:[NSString class]]) continue;
        if (![(NSString *)ident isEqualToString:NOTIFYBOX_APP_BUNDLE]) continue;
        // 不判存在：App 第一次启动前 Documents 可能还没建，由调用方统一 createDirectory
        return [[base stringByAppendingPathComponent:u] stringByAppendingPathComponent:@"Documents"];
    }
    return nil;
}

// v0.0.137：数据目录就是那个常量。留成函数只为「有个名字可以打日志」。
// 🔴 这里**不许**再加任何 if/else 去选路径 —— 一旦路径能在运行时变，
//    两个进程就会算出两个答案，那就是 v0.0.136 的 split-brain（记录写在一边、读在另一边）。
// v0.0.142：建完目录立刻 **chmod 0777**（对齐系统自己的 /var/mobile/Library/Preferences，
//   它是 drwxrwxrwx）。理由见 NBCanWriteSharedFiles 上方：共享目录必须「谁写都行」。
//   ⚠️ chmod 是**幂等且无害**的：已存在就再设一次，权限本来就是 0777 时等于空操作。
//   这一行失败也不要紧（下次进来还会设），但它成功就意味着**属主是谁都无所谓了**。
static BOOL gNBDirTried = NO;
NSString *NBDataDir(void) {
    if (!gNBDirTried) {
        gNBDirTried = YES;
        [[NSFileManager defaultManager] createDirectoryAtPath:NOTIFYBOX_LEGACY_DIR
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        chmod([NOTIFYBOX_LEGACY_DIR fileSystemRepresentation], 0777);
    }
    return NOTIFYBOX_LEGACY_DIR;
}

// v0.0.137：属主自愈的**非 root 那条腿**。
//   能改属主的只有 root（在 Tweak.x 的 ctor 里做），但那条腿依赖 backboardd 真被注入。
//   这一条不依赖 root：目录被 root 建成 501 写不进时，只要它是**空的**，
//   当前进程就能把它删掉重建 —— 删目录看的是**父目录**的写权限，而
//   `/var/mobile/Library` 归 mobile ⇒ mobile 删得掉。
// 🔴 三条限制，一条都不能松：
//   ① **非空绝不删**：里面有记录就是用户全部历史，宁可不自愈也不赌；
//   ② root 进程不许调：它会把自己刚建的那个目录再建一次，等于原地复活这个 bug；
//   ③ 只在「存在但当前身份写不进」时动手 —— 可写时零动作（不碰就不会出事）。
// 返回 YES = 这次真的动手且成功了（调用方要把这个事实打进日志）。
// 🔴🔴 v0.0.138：**删掉 `removeItemAtPath` 那一步**。不是"怕删数据"，是更硬的三条：
//   ① **不可逆动作不许落在"读数不可信"的轮次**。这个函数的入口条件就是 `access(W_OK) != 0`
//      —— 而那正是我们无法解释的那个 EPERM。在"不知道谁在拒"的状态下去删目录，是拿现场赌博。
//   ② **先删后建，建失败就永久失去现场**：删成功了、`createDirectory` 失败（沙箱/空间/任何原因），
//      目录就没了；返回值还是 NO ⇒ 调用方看不出发生了不可逆的事。
//   ③ 2026-11-04 真机就出现过「11:38 还有 6 个文件、11:52 路径整个不存在」这一段，
//      而**没有任何一行代码承认过自己删了东西**。这种形状不能再留。
// ⇒ v0.0.138 起只做一件事：**写不进就如实报出来**，目录留着。
// 🔴 v0.0.142：现在**真的能治了**，而且不需要删任何东西 —— 因为 v0.0.136 那个
//   「root 不许写」的闸门已经撤销，当前进程可能就有 chmod 的资格（目录 owner 或 root
//   都能 chmod）。所以自愈动作从「删了重建（不可逆）」改成「**chmod 0777（幂等、可逆）**」：
//     ① 可逆：权限可以再改回去，数据一个字节都不动；
//     ② 幂等：跑一百次和跑一次结果一样；
//     ③ 不依赖不知道谁在拒 —— 它只是把「谁能写」这个前提**放宽**，而不是去猜凶手。
//   这正是本次事故的正解：**不要禁止写入者，要放开目录权限。**
BOOL NBHealDataDirOwnership(void) {
    const char *p = [NOTIFYBOX_LEGACY_DIR fileSystemRepresentation];
    struct stat hst; memset(&hst, 0, sizeof(hst));
    if (stat(p, &hst) != 0) return NO;              // 不存在：让 NBDataDir 正常建（会顺带 chmod 0777）
    if (access(p, W_OK) == 0) return NO;            // 可写：零动作

    // 写不进 ⇒ 先试 chmod 0777。这就是「把前提放宽」，不猜凶手、不删数据。
    errno = 0;
    int rc = chmod(p, 0777);
    int ec = errno;
    BOOL nowOK = (rc == 0) && (access(p, W_OK) == 0);
    NSLog(@"[NotifyBox] %@ 数据目录写不进 dir=%@ 属主=%d:%d uid=%d mode=%o ⇒ chmod 0777 rc=%d errno=%d(%s) 现在可写=%@",
          nowOK ? @"✅" : @"⚠️", NOTIFYBOX_LEGACY_DIR,
          (int)hst.st_uid, (int)hst.st_gid, (int)getuid(),
          (unsigned)(hst.st_mode & 07777), rc, ec, strerror(ec),
          nowOK ? @"YES" : @"NO");
    NBSharedLog(@"数据目录自愈 chmod 0777 rc=%d errno=%d(%s) 现在可写=%@",
                rc, ec, strerror(ec), nowOK ? @"YES" : @"NO");
    return nowOK;
}

// ───────────────────────────── v0.0.138 启动探针 ─────────────────────────────
// 设计要点（每一条都是被真机打过的地方，别删）：
//   ① **它自己不能是静默的**：连"写 /tmp 这一步"的结果都要检查并 NSLog。
//      否则又是一个"探针失败 ⇒ 看起来像没跑"的闭环。
//   ② **同一目录试两种写法**：`NSData writeToFile:atomically:YES`（`.tweak_ctor` 就是这种）
//      与 `open+write`（绕开 atomic 的"临时文件 + rename"）。结果若不同，
//      直接指向"是 atomic 那条路被拒"，而不是笼统的"写不进"。
//   ③ **errno 每个动作分别清零再取**，绝不复用上一句的残留（否则会报出误导性的 errno）。
//   ④ 候选目录**不只试第一个能写的就收工**：全部试完再汇总，才知道"应该搬到哪去"。

static NSString *NBProbeProcName(void) {
    NSString *n = [[NSProcessInfo processInfo] processName];
    if (!n.length) n = @"?";
    // 进程名里可能有路径/空格，当文件名用之前先洗一遍
    NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSString *s = [[n componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    return s.length ? s : @"?";
}

// 探一个目录：建目录 → 写法① → 写法② → 读回。返回该目录（能写）或 nil。
static NSString *NBProbeOneDir(NSString *dir, NSMutableString *out) {
    NSFileManager *fm = [NSFileManager defaultManager];
    const char *cp = [dir fileSystemRepresentation];

    struct stat st; memset(&st, 0, sizeof(st));
    errno = 0;
    BOOL hasSt = (stat(cp, &st) == 0);
    int stErr = errno;

    [out appendFormat:@"  ── %@\n", dir];
    if (hasSt) {
        [out appendFormat:@"     stat=OK 属主=%d:%d mode=%o\n",
                           (int)st.st_uid, (int)st.st_gid, (unsigned)(st.st_mode & 07777)];
    } else {
        [out appendFormat:@"     stat=FAIL errno=%d(%s)\n", stErr, strerror(stErr)];
    }

    errno = 0;
    BOOL mk = [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    int mkErr = errno;
    if (mk) {
        [out appendString:@"     createDirectory=OK\n"];
    } else {
        [out appendFormat:@"     createDirectory=FAIL errno=%d(%s)%@\n", mkErr, strerror(mkErr),
                           hasSt ? @"（目录已存在，FAIL 属正常）" : @"（目录不存在且建不出来）"];
    }
    if (!mk && !hasSt) {
        [out appendString:@"     ⇒ 目录不存在也建不出来，写入测试跳过\n"];
        return nil;
    }

    NSString *f1 = [dir stringByAppendingPathComponent:@".nb_probe_atomic"];
    NSString *f2 = [dir stringByAppendingPathComponent:@".nb_probe_open"];
    NSData *payload = [@"NotifyBox probe\n" dataUsingEncoding:NSUTF8StringEncoding];

    // 写法①：和 `.tweak_ctor` / `.tweak_ctor_root` 完全同一种写法
    errno = 0;
    BOOL w1 = [payload writeToFile:f1 atomically:YES];
    int e1 = errno;
    if (w1) {
        [out appendString:@"     NSData(atomically:YES)=OK\n"];
    } else {
        [out appendFormat:@"     NSData(atomically:YES)=FAIL errno=%d(%s)\n", e1, strerror(e1)];
    }

    // 写法②：直接 open+write，绕开 atomic 的临时文件 + rename
    errno = 0;
    int fd = open([f2 fileSystemRepresentation], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    int eOpen = errno;
    BOOL w2 = NO;
    int e2 = 0;
    if (fd >= 0) {
        errno = 0;
        ssize_t n = write(fd, payload.bytes, payload.length);
        e2 = errno;
        w2 = (n == (ssize_t)payload.length);
        close(fd);
    }
    if (w2) {
        [out appendString:@"     open+write=OK\n"];
    } else if (fd < 0) {
        [out appendFormat:@"     open+write=FAIL（open 就失败）errno=%d(%s)\n", eOpen, strerror(eOpen)];
    } else {
        [out appendFormat:@"     open+write=FAIL（open 成功、write 失败）errno=%d(%s)\n", e2, strerror(e2)];
    }

    // 读回：证明"写得进"与"读得回"是两件事，两个都要有
    NSString *probeKept = w1 ? f1 : (w2 ? f2 : nil);
    if (probeKept) {
        NSString *rb = [NSString stringWithContentsOfFile:probeKept
                                                 encoding:NSUTF8StringEncoding error:nil];
        [out appendFormat:@"     读回=%@\n", rb.length ? @"OK" : @"FAIL"];
        [fm removeItemAtPath:probeKept error:nil];    // 探针自己收拾干净，不污染数据目录
        return dir;
    }
    [out appendString:@"     读回=（没写成，跳过）\n"];
    return nil;
}

// v0.0.139：把 ctor 那次探针的**原文**留一份，供屏幕提示（NBShowBootAlert）复用。
// 🔴 为什么留原文而不是让弹窗自己再探一遍：再探一遍会**重复做写入测试**（每个候选目录
//    两个测试文件），而"写不进去"恰恰是被观察的对象 —— 多写一次等于干扰现场。
//    留一份只读副本，屏幕上的数字和 /tmp 文件里的数字**必然同源**，不会出现两个版本。
// 🔴 只在 ctor 里写一次、之后全进程只读 ⇒ 不需要加锁。
static NSString *gNBProbeReport = nil;

NSString *NBLastProbeReport(void) {
    return gNBProbeReport;
}

// ───────── v0.0.156：旧位置（App 容器）装载标记的**代读** ─────────
//
// 🔴 为什么需要别人代读（这是「死探针」的正解，不是排版问题）：
//    盒子 App 带 `com.apple.private.security.no-container`（见 Resources/NotifyBoxApp.entitlements）
//    ⇒ 它**没有自己的容器** ⇒ `URLsForDirectory:NSDocumentDirectory` 返 nil
//    ⇒ 旧位置那条路径在 App 进程里永远算不出来。
//    而 envCheck **只在 App 里跑**，所以「旧位置 .tweak_ctor」那一行过去一直是**死探针**：
//    恒打「本进程算不出这个路径」，一条信息都不含 —— 与 v0.0.144 删掉那一节**同一个死因**。
//    更糟的是它上方的注释还写着「那条留着，因为它读的是**文件**、不是进程能力」——
//    那句话在 App 进程里根本不成立：path 为 nil 时 NBAppendMarker 第一句就 return，从不读文件。
//    ⇒ split-brain（tweak 记到别处去了）这条判据，实际上**已经失效了整整十二版**。
//
// 🔴 正解（铁律：读不到某个值，先问**这进程有没有权限**，不是换字段）：
//    换有权限的进程代做、结果落共享介质。
//    `NBFindAppDocsDir()` 扫的是 `/var/mobile/Containers/Data/Application/*/…metadata.plist`，
//    SpringBoard 受沙箱限制扫不到，**backboardd(root) 扫得到** ⇒ 由 root 进程写一份记录，
//    App 只读文件（共享数据目录 0777，App 有 entitlement 读得进）。
//
// 🔴 三条纪律（每条对应一种会被误读的失败）：
//    ① **算不出就不写** —— 绝不用空值覆盖别人已经写好的答案（否则轮次一换，答案自己消失）；
//    ② 写失败要 NSLog 喊出来，不许静默（静默失败与"没跑"在证据上同形）；
//    ③ 记录必须带 `proc=`，否则读的人不知道这份答案是**哪个进程**给的。
static void NBWriteOldLocationProbe(void) {
    NSString *p = NBFindAppDocsDir();
    if (!p.length) return;                  // ① 算不出就沉默（SpringBoard / App 都走这条）

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL dirExists = [fm fileExistsAtPath:p];
    NSString *mk = [p stringByAppendingPathComponent:@".tweak_ctor"];
    NSDictionary *ma = [fm attributesOfItemAtPath:mk error:nil];
    NSString *txt = [NSString stringWithContentsOfFile:mk
                                             encoding:NSUTF8StringEncoding error:nil];
    // 🔴 三态不许合并：「目录在不在」「标记在不在」「标记读不读得出」是三件事。
    NSMutableString *o = [NSMutableString string];
    [o appendFormat:@"proc=%@\n", NBProbeProcName()];
    [o appendFormat:@"path=%@\n", p];
    [o appendFormat:@"dirExists=%d\n", dirExists ? 1 : 0];
    [o appendFormat:@"markerExists=%d\n", ma ? 1 : 0];
    if (txt.length) {
        NSString *t = [txt stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length > 200) t = [t substringToIndex:200];
        // 记录格式是「一行一个键」⇒ 内容里的换行必须压掉，否则 key=value 解析会串行
        t = [t stringByReplacingOccurrencesOfString:@"\n" withString:@" ⏎ "];
        [o appendFormat:@"marker=%@\n", t];
    }
    if (ma && !txt.length) [o appendFormat:@"markerUnreadable=%llu\n",
                                   [ma[NSFileSize] unsignedLongLongValue]];
    [o appendFormat:@"ts=%.0f\n", [[NSDate date] timeIntervalSince1970]];

    NSString *dst = [NBDataDir() stringByAppendingPathComponent:@".old_location"];
    errno = 0;
    BOOL w = [[o dataUsingEncoding:NSUTF8StringEncoding] writeToFile:dst atomically:YES];
    if (!w) {
        // ② 写不进要喊：这条记录缺失会让 App 侧说「没有代读记录」，别让它无声无息
        NSLog(@"[NotifyBox/probe] ⚠️ 旧位置代读记录写失败 errno=%d(%s) path=%@",
              errno, strerror(errno), dst);
    } else {
        chmod([dst fileSystemRepresentation], 0666);   // 与日志/设置同一条规矩：共享文件人人可读
    }
}

int NBWriteBootProbe(void) {
    NSMutableString *out = [NSMutableString string];
    NSString *proc = NBProbeProcName();

    [out appendFormat:@"NotifyBox 启动探针 v%@\n", NOTIFYBOX_VER_STR];
    [out appendFormat:@"进程=%@ pid=%d uid=%d euid=%d\n",
                      proc, (int)getpid(), (int)getuid(), (int)geteuid()];
    [out appendFormat:@"时间=%@\n", [NSDate date]];
    Dl_info dli;
    if (dladdr((const void *)&NBWriteBootProbe, &dli) && dli.dli_fname) {
        [out appendFormat:@"dylib=%s\n", dli.dli_fname];
    }
    [out appendFormat:@"数据目录(常量)=%@\n\n", NOTIFYBOX_LEGACY_DIR];

    // 4 个候选，全部试完再汇总 —— 只试到第一个能写的就收工，等于放弃了"搬到哪"的答案
    NSArray *cands = @[
        NOTIFYBOX_LEGACY_DIR,
        @"/var/mobile/Documents/NotifyBox",
        @"/private/var/tmp/NotifyBox",
        @"/var/mobile/Library/Preferences/NotifyBox",
    ];
    NSMutableArray *writable = [NSMutableArray array];
    for (NSString *c in cands) {
        NSString *ok = NBProbeOneDir(c, out);
        if (ok) [writable addObject:ok];
    }
    [out appendFormat:@"\n== 写成功的目录: %@\n",
                      writable.count ? [writable componentsJoinedByString:@"  "] : @"（一个都没有）"];

    // 🔴 落盘这一步自身也要检查：写不进 /tmp ⇒ 至少 NSLog 里要有，不能让探针自己静默消失
    NSString *dst = [NSString stringWithFormat:@"/private/var/tmp/nb_boot_%@.txt", proc];
    NSString *dstAll = @"/private/var/tmp/nb_boot_all.txt";
    NSData *od = [out dataUsingEncoding:NSUTF8StringEncoding];
    errno = 0;
    BOOL w = [od writeToFile:dst atomically:YES];
    int ew = errno;
    if (w) {
        NSLog(@"[NotifyBox/probe] %@ 探针已写入 %@（可写目录 %lu 个）",
              proc, dst, (unsigned long)writable.count);
    } else {
        NSLog(@"[NotifyBox/probe] ⚠️ %@ 探针写 /tmp 失败 errno=%d(%s) path=%@",
              proc, ew, strerror(ew), dst);
    }
    // 汇总文件：把两个进程的结果并排放，一次 cat 就能对比（末次写赢的问题由"文件名带进程名"避免）
    errno = 0;
    BOOL wa = [od writeToFile:dstAll atomically:NO];   // 非 atomic 追加语义更接近"就地覆盖"，不会互相删临时文件
    if (!wa) {
        NSLog(@"[NotifyBox/probe] ⚠️ %@ 汇总文件写失败 errno=%d(%s) path=%@",
              proc, errno, strerror(errno), dstAll);
    }
    NSLog(@"[NotifyBox/probe] ===== 探针结果（%@）=====\n%@", proc, out);
    gNBProbeReport = [out copy];

    // v0.0.156：顺手把「旧位置（App 容器）的装载标记」记一份，供 App 侧 envCheck 读。
    //   🔴 必须排在 /tmp 探针**之后**：那一条是本函数的主产出，不能被这里任何异常拖住。
    //   算不出容器路径的进程（SpringBoard / App）会自己沉默，见函数上方纪律 ①。
    NBWriteOldLocationProbe();

    return (int)writable.count;
}


// 🔴 v0.0.156：**删掉 `NBAltDataDir()`**（连声明一起删，见 NotifyCommon.h）。
//   它曾经的唯一调用点是 envCheck 里那条「旧位置 .tweak_ctor」，而那条在 App 进程里
//   恒走 nil 分支（App 带 no-container ⇒ 没有容器 ⇒ NSDocumentDirectory 返 nil）⇒ 死探针。
//   现在改由 root 进程代读（NBWriteOldLocationProbe），这个函数就再没有调用者了。
//   留着它的坏处不是占几行，而是**下次还会有人拿它写一个新的死探针**
//   —— 一个在 App 里恒为 nil 的 API，名字看起来却像"能拿到路径"。

// 🔴🔴🔴 v0.0.142：**撤销** v0.0.136「uid==0 一律不许碰共享目录」那一刀。
//
// 它把**唯一在干活的进程关在了门外**，这是本次事故最贵的一课：
//   ① `%hook BBServer` 有 4 处，而 BBServer 跑在 **backboardd（root）**；
//      SpringBoard 里挂的是声音和通知中心（SBNCSoundController / NC*）。
//      ⇒ **「记录一条通知」这件事，本来就是 root 在做的。**
//   ② 装上 v0.0.136（11-04 09:47）之后，数据库最后一次写入停在 **09:55**，
//      再往后 8 小时零写入 —— 不是写失败，是**根本没人去写**。
//   ③ 而这条规则的**初衷是对的**（防止 root 建目录后 owner=root，mobile 从此读不了），
//      错在**手段**：不该禁止某个身份写，而该让目录**谁写都行**。
//
// 🔴 正解 = 抄系统自己的做法。真机对照：
//      /var/mobile/Library/Preferences   drwxrwxrwx  mobile mobile  ← 0777，从没出过这种事
//      /var/mobile/Library/NotifyBox     drwxr-xr-x  mobile mobile  ← 0755，我建的
//   系统把跨进程共享的目录设成 0777，所以 cfprefsd(root) / SpringBoard(mobile) / App
//   都能写。⇒ 本目录一律 **0777**，属主是谁都无所谓。
//
// 🔴 铁律：**「禁止某个身份写」这条规矩，根本不该出现在多进程共享目录上。**
//   你永远不可能穷举出所有会来写的进程（今天是 backboardd，明天可能是别的），
//   禁谁都是在赌 —— 而且赌输的样子是「功能整体静默消失」，最难查。
//   要防属主错乱，就**放开权限**，而不是**关掉写入者**。
BOOL NBCanWriteSharedFiles(void) {
    // 恒 YES：保留这个函数只为不再改动各处调用点，语义已变成「所有进程都可以」。
    return YES;
}

// 写库失败要留痕：区分「hook 没触发」与「触发了但写不进」
static void NBStoreLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    // 🔴🔴 v0.0.157：这里原本是
    //     `if (!NBCanWriteSharedFiles()) { NSLog(@"[NotifyBox/root STORE] %@", msg); return; }`
    //   —— 那个闸门恒返 YES（见 NotifyCommon.h 该函数的注释）⇒ 这一支**永不执行**。
    //   死代码里的话最贵：它唯一的作用是让人以为「root 的 STORE 日志走 NSLog」，
    //   而事实相反 —— root 和别的进程一样写共享日志。
    //   纯结构改动（闸门恒 YES 时分支本来就不进），行为一字未变。
    //   同一份副本 `NBSharedLog` 里那处**必须同时删**，否则两处不同源、以后又会被抄来抄去。
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[NOTIFYBOX_LOG_PATH stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *d = [[NSString stringWithFormat:@"[STORE %@] %@\n",
                  [NSDate date], msg] dataUsingEncoding:NSUTF8StringEncoding];
    errno = 0;
    BOOL wok = NO;
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:NOTIFYBOX_LOG_PATH];
    if (fh) { @try { [fh seekToEndOfFile]; [fh writeData:d]; wok = YES; } @finally { [fh closeFile]; } }
    else { wok = [d writeToFile:NOTIFYBOX_LOG_PATH atomically:YES]; }
    // v0.0.137：与 NBSharedLog 同一条规矩 —— 写不进去要当场喊，不许静默。
    if (!wok) NSLog(@"[NotifyBox/写日志失败 STORE] errno=%d(%s) path=%@ | %@",
                    errno, strerror(errno), NOTIFYBOX_LOG_PATH, msg);
    // v0.0.142：同 NBSharedLog —— 文件权限也要放开，否则 root 先写一步，
    //   mobile 之后就对同一个文件写不进了。
    else chmod([NOTIFYBOX_LOG_PATH fileSystemRepresentation], 0666);
}

// ---------- 统一日志（tweak / App / 新模块共用） ----------
// 🔴 从 Tweak.x 搬过来的，逻辑逐字保持：超过 512 KB 就切成 .1（覆盖上一份），
//    避免长期运行把分区写满。用计数器节流：不是每次写都 stat，每 200 次看一眼。
void NBSharedLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    // 🔴🔴 v0.0.157：这里原本是 `if (!NBCanWriteSharedFiles()) { NSLog(@"[NotifyBox/root] %@", msg); return; }`
    //   加上面那句「root 进程不许建/写这个目录」的注释 —— 两者都过期了。
    //   闸门恒返 YES ⇒ 这支永不执行；而「root 不许写」这条规矩 v0.0.142 就撤销了
    //   （它把唯一在干活的 backboardd 关在门外，记录整体消失 8 小时）。
    //   ⚠️ 写失败仍然会 NSLog 兜底（见下面的 `if (!wok)`），那一条是**真的会执行**的通道 ——
    //   删掉的是假分支，不是独立通道。

    // 轮转检查（节流）
    {
        static int tick = 0;
        tick++;
        if ((tick % 200) == 1) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSDictionary *a = [fm attributesOfItemAtPath:NOTIFYBOX_LOG_PATH error:nil];
            if ([a[NSFileSize] unsignedLongLongValue] >= 512 * 1024) {
                NSString *old = [NOTIFYBOX_LOG_PATH stringByAppendingString:@".1"];
                [fm removeItemAtPath:old error:nil];
                [fm moveItemAtPath:NOTIFYBOX_LOG_PATH toPath:old error:nil];
            }
        }
    }

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[NOTIFYBOX_LOG_PATH stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    // 🔴🔴 v0.0.137：**写不进去必须留痕**。
    //   以前这里失败是完全静默的：日志文件不存在 ⇒ 用户看到的是「tweak 没生效」，
    //   而真相是「写了、但一个字节都没落盘」。静默失败和"没触发"长得一模一样，
    //   这类坑只能靠当场喊出来区分（NSLog 进系统日志，落哪里都能捞）。
    errno = 0;
    BOOL wok = NO;
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:NOTIFYBOX_LOG_PATH];
    if (fh) {
        @try { [fh seekToEndOfFile]; [fh writeData:d]; wok = YES; }
        @catch (NSException *e) { wok = NO; }
        @finally { [fh closeFile]; }
    } else {
        wok = [d writeToFile:NOTIFYBOX_LOG_PATH atomically:YES];
    }
    if (!wok) {
        NSLog(@"[NotifyBox/写日志失败] errno=%d(%s) path=%@ | %@",
              errno, strerror(errno), NOTIFYBOX_LOG_PATH, msg);
    } else {
        // 🔴 v0.0.142：**文件本身也要「谁都能写」**。
        //   目录放开到 0777 只解决「能不能新建文件」；已经存在的日志文件如果是
        //   root 建的那份（rw-r--r-- root wheel），mobile 进程照样写不进 ——
        //   症状和目录权限问题一模一样，又是一轮无从下手。
        //   0666 是幂等的，每次写完设一次，开销一条 syscall。
        chmod([NOTIFYBOX_LOG_PATH fileSystemRepresentation], 0666);
    }
}

@implementation NotifyStore

+ (void)ensureDir {
    NSString *dir = [NOTIFYBOX_DB_PATH stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    // v0.0.142：共享目录一律 0777（对齐系统自己的 /var/mobile/Library/Preferences）
    chmod([dir fileSystemRepresentation], 0777);
}

+ (sqlite3 *)openDB {
    [self ensureDir];
    sqlite3 *db = NULL;
    int orc = sqlite3_open([NOTIFYBOX_DB_PATH UTF8String], &db);
    if (orc != SQLITE_OK) {
        // 🔴 v0.0.142：**不许静默 return NULL**。
        //   在调用方看来，「库打不开」和「库里没有记录」完全是同一个现象
        //   —— 本次事故就是被这种出口藏住的。
        NSLog(@"[NotifyBox/store] ⚠️ sqlite3_open 失败 rc=%d err=%s path=%@",
              orc, db ? sqlite3_errmsg(db) : "(db=NULL)", NOTIFYBOX_DB_PATH);
        NBStoreLog(@"sqlite3_open 失败 rc=%d path=%@", orc, NOTIFYBOX_DB_PATH);
        if (db) sqlite3_close(db);      // open 失败时 handle 也可能已分配，不关就是泄漏
        return NULL;
    }
    // 🔴 v0.0.142：库文件本身也放开到 0666。
    //   两个进程（backboardd root 记通知 / SpringBoard·App 读写）共用同一个库，
    //   哪一个先建，文件属主就是谁。若它是 rw-r--r-- 且属主不是当前进程，
    //   另一方从此写不进 —— 而 SQLite 报的是 READONLY / BUSY，看着像"锁竞争"，
    //   根本不像权限问题。0666 幂等，一条 syscall 换掉一整类事故。
    chmod([NOTIFYBOX_DB_PATH fileSystemRepresentation], 0666);
    // 🔴🔴 v0.0.15：必须设 busy_timeout。
    //    真机日志里反复出现：
    //        INSERT 失败 rc=5 err=database is locked bundle=com.jd.jingmai / com.lemon.lv
    //    rc=5 就是 SQLITE_BUSY。**两个进程都在写这个库**（SpringBoard 里的 tweak 记通知、
    //    盒子 App 清空/标已读），SQLite 的默认行为是"拿不到写锁立刻返回 BUSY"⇒
    //    **那条通知就被静默丢掉了**，而且丢了以后没有任何回头路（库里根本没有它）。
    //    设 2 秒超时：正常情况写一下就几毫秒，2 秒足够等对方放开；
    //    真超过 2 秒说明对方卡的更久，那时再失败也不冤。
    sqlite3_busy_timeout(db, 2000);
    const char *sql = "CREATE TABLE IF NOT EXISTS notifications ("
                      "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                      "bundle TEXT, title TEXT, message TEXT, subtitle TEXT, "
                      "ts REAL, read INTEGER DEFAULT 0, hash TEXT, sys_id TEXT, sys_id_alt TEXT, "
                      // v0.0.133：通知原始 userInfo 的 JSON（有界，见 NotifyStore.h 说明）。
                      "payload TEXT);"
                      "CREATE INDEX IF NOT EXISTS idx_bundle ON notifications(bundle);"
                      "CREATE INDEX IF NOT EXISTS idx_ts ON notifications(ts);"
                      // v0.0.45：App 显示名表。**SpringBoard 写、盒子 App 读**。
                      // 为什么要有这张表：见 NBAppName.h 的说明 —— 桌面上的用户 App
                      // 装在 /var/containers/Bundle/Application/<UUID>/Xxx.app，
                      // **盒子 App 的沙盒读不到那一层**，于是"读 bundle 里的
                      // CFBundleDisplayName"这条最权威的路在 App 进程里根本走不通
                      // （v0.0.42/43/44 三版就是卡在这里）。
                      // ⇒ 由注入 SpringBoard 的 tweak（有权限）算好名字写进来。
                      // 🔴 用 `IF NOT EXISTS` + 没有 NOT NULL 约束：老库升级时
                      //    这张表是新增的，INSERT 前不许有任何迁移前置条件。
                      "CREATE TABLE IF NOT EXISTS app_names ("
                      "bid TEXT PRIMARY KEY, name TEXT);";
    sqlite3_exec(db, sql, NULL, NULL, NULL);

    // v0.0.52：老库补 sys_id 列（精确同步清通知中心用）。
    // v0.0.117：再补 sys_id_alt 列（系统重投换 ID 时把**旧 ID**留着，见内容去重那段）。
    // 🔴 SQLite 不支持 `ALTER TABLE … ADD COLUMN IF NOT EXISTS`，
    //    所以先 PRAGMA table_info 探测，没有才 ALTER（避免对已是新结构的库重复 ALTER 报错）。
    // 🔴 v0.0.117：改成**一次 PRAGMA 同时探测两列**。原来只探 sys_id、探到就 break ——
    //    再加一列时那种写法必然漏（第二次 ALTER 会被跳过，然后整版按"有这一列"去读写 ⇒
    //    运行期 `no such column`，而且只在老库上升级才炸）。
    {
        BOOL hasSysId = NO, hasAlt = NO, hasPayload = NO;
        sqlite3_stmt *p = NULL;
        if (sqlite3_prepare_v2(db, "PRAGMA table_info(notifications)", -1, &p, NULL) == SQLITE_OK) {
            while (sqlite3_step(p) == SQLITE_ROW) {
                const char *nm = (const char *)sqlite3_column_text(p, 1);
                if (!nm) continue;
                if (strcmp(nm, "sys_id") == 0) hasSysId = YES;
                if (strcmp(nm, "sys_id_alt") == 0) hasAlt = YES;
                // v0.0.133：同上，第三个待补列。**同一个 PRAGMA 一起探** —— 分两次探
                //   就会重演 v0.0.117 那个坑（第二次 ALTER 被跳过 ⇒ 运行期 no such column，
                //   而且只在老库升级时炸）。
                if (strcmp(nm, "payload") == 0) hasPayload = YES;
            }
            sqlite3_finalize(p);
        }
        // 🔴🔴🔴 v0.0.141：**ALTER 的返回值不许再丢。**
        //   事故现场就是这三行：v0.0.133 加 `payload` 列时写的是
        //   `sqlite3_exec(db, "...", NULL, NULL, NULL)` —— 失败与否没有任何人知道。
        //   于是库结构停在旧版（没有 payload 列），而 INSERT 已经按新版（8 列）写死
        //   ⇒ 每条通知在 prepare 阶段就被丢掉，**静默**，找了两天才找到这里。
        //   🔴 「尽力而为」只对**可有可无**的步骤成立；对**建表结构**不成立 ——
        //     结构没补上，后面所有读写全是错的，且错得无声。
        //   🔴 还要同时打 NSLog：NBStoreLog 写的是 tweak.log，而它与数据库同目录，
        //     目录不可写时**报错和故障会一起被吞掉**（正是本次事故的形态）。
        if (!hasSysId) {
            char *e = NULL;
            if (sqlite3_exec(db, "ALTER TABLE notifications ADD COLUMN sys_id TEXT;",
                             NULL, NULL, &e) != SQLITE_OK) {
                NSLog(@"[NotifyBox/store] ⚠️ ALTER sys_id 失败 err=%s", e ? e : "(null)");
                NBStoreLog(@"ALTER sys_id 失败 err=%s", e ? e : "(null)");
            }
            sqlite3_free(e);
        }
        if (!hasAlt) {
            char *e = NULL;
            if (sqlite3_exec(db, "ALTER TABLE notifications ADD COLUMN sys_id_alt TEXT;",
                             NULL, NULL, &e) != SQLITE_OK) {
                NSLog(@"[NotifyBox/store] ⚠️ ALTER sys_id_alt 失败 err=%s", e ? e : "(null)");
                NBStoreLog(@"ALTER sys_id_alt 失败 err=%s", e ? e : "(null)");
            }
            sqlite3_free(e);
        }
        if (!hasPayload) {
            char *e = NULL;
            if (sqlite3_exec(db, "ALTER TABLE notifications ADD COLUMN payload TEXT;",
                             NULL, NULL, &e) != SQLITE_OK) {
                NSLog(@"[NotifyBox/store] ⚠️ ALTER payload 失败 err=%s", e ? e : "(null)");
                NBStoreLog(@"ALTER payload 失败 err=%s", e ? e : "(null)");
            }
            sqlite3_free(e);
        }
    }
    return db;
}

+ (NSInteger)maxRecords {
    // v0.0.8：走统一入口（新 settings.plist 优先，旧 Preferences 域兜底、只读）
    // 🔴🔴 v0.0.45：上界从 100000 收紧到 `kNBRMaxRecordsHardCap`（20000）。
    //    原来的 100000 是个"反正不会有人填"的占位，但它意味着：
    //    用户可以设一个**列表永远显示不完**的上限（`listLimit` 是 2000），
    //    于是库里常年堆着几千条"只能通过导出才能看见"的记录 ——
    //    用户以为自己留了 10 万条，其实能翻到的永远只有最新 2000 条。
    //    ⇒ 上界必须是一个**能被解释**的数：填大了要能在界面上说清楚代价。
    NSDictionary *p = NBLoadSettings();
    id v = p[@"maxRecords"];
    NSInteger n = v ? [v integerValue] : 500;
    return (n >= kNBRMinRecords && n <= kNBRMaxRecordsHardCap) ? n : 500;
}

#pragma mark - v0.0.45 App 显示名表（**tweak 写 / App 读**）

// 🔴 进程内缓存。tweak 每收到一条通知都会走到 `saveAppName:`，
//    同一个 App 第二次之后必须是 **no-op** —— 否则每来一条通知都多一次写锁竞争，
//    而写锁竞争的对象正是 SpringBoard 记通知那条路径（v0.0.15 就栽在 BUSY 上）。
// 🔴 两个进程各有一份缓存没关系：写的是同一张表，且 `INSERT OR REPLACE` 是幂等的。
static NSMutableDictionary<NSString *, NSString *> *gAppNameCache = nil;
static NSObject *gAppNameLock = nil;

+ (void)saveAppName:(NSString *)name forBundle:(NSString *)bundle {
    if (!bundle.length || !name.length) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gAppNameCache = [NSMutableDictionary dictionary];
        gAppNameLock = [[NSObject alloc] init];
    });
    @synchronized (gAppNameLock) {
        NSString *old = gAppNameCache[bundle];
        if (old && [old isEqualToString:name]) return;   // 名字没变 ⇒ 不写
    }
    sqlite3 *db = [self openDB];
    if (!db) return;
    const char *sql = "INSERT OR REPLACE INTO app_names (bid, name) VALUES (?, ?);";
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        return;
    }
    sqlite3_bind_text(st, 1, bundle.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, name.UTF8String, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_DONE) {
        @synchronized (gAppNameLock) { gAppNameCache[bundle] = name; }
    }
    sqlite3_finalize(st);
    sqlite3_close(db);
}

// 🔴 一次性写入多个（tweak 后台全量刷新用）。
//    为什么不能循环调 `saveAppName:`：那条每次都开关一次数据库连接，
//    200 个 App 就是 200 次 `openDB`（每次都要跑一遍 CREATE TABLE IF NOT EXISTS）。
//    批量版本**只开一次库、只开一个事务**。
+ (NSInteger)saveAppNames:(NSDictionary<NSString *, NSString *> *)names {
    if (!names.count) return 0;
    sqlite3 *db = [self openDB];
    if (!db) return 0;
    sqlite3_exec(db, "BEGIN;", NULL, NULL, NULL);
    const char *sql = "INSERT OR REPLACE INTO app_names (bid, name) VALUES (?, ?);";
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) {
        sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
        sqlite3_close(db);
        return 0;
    }
    NSInteger done = 0;
    for (NSString *bid in names) {
        NSString *name = names[bid];
        if (!bid.length || !name.length) continue;
        sqlite3_reset(st);
        sqlite3_bind_text(st, 1, bid.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, name.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(st) == SQLITE_DONE) done++;
    }
    sqlite3_finalize(st);
    sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
    sqlite3_close(db);
    return done;
}

+ (NSDictionary<NSString *, NSString *> *)appNames {
    sqlite3 *db = [self openDB];
    if (!db) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    const char *sql = "SELECT bid, name FROM app_names;";
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        return @{};
    }
    while (sqlite3_step(st) == SQLITE_ROW) {
        const char *b = (const char *)sqlite3_column_text(st, 0);
        const char *n = (const char *)sqlite3_column_text(st, 1);
        if (!b || !n) continue;
        NSString *bid = [NSString stringWithUTF8String:b];
        NSString *name = [NSString stringWithUTF8String:n];
        if (bid.length && name.length) out[bid] = name;
    }
    sqlite3_finalize(st);
    sqlite3_close(db);
    return out;
}

+ (NSString *)appNameForBundle:(NSString *)bundle {
    if (!bundle.length) return nil;
    return [self appNames][bundle];
}

#pragma mark - v0.0.46 统计

// 🔴 三个统计方法共用：开库 + 准备 + 逐行取。
//    分开写三份的话，"某个方法忘了 sqlite3_finalize" 是迟早的事，
//    而这种泄漏在真机上的表现是"用久了盒子打不开"，很难往这边想。
// `build` 由调用方给：它决定"这一行的列分别是什么 key、什么类型"。
// 一开始我试过传 key 数组 + 两个 BOOL（"第一列是 int 还是 text"），
// 结果读起来像谜语 ⇒ 直接传构造 block，列号由调用方自己写清楚。
static NSArray<NSDictionary *> *NBRows(sqlite3 *db, NSString *sql, NSTimeInterval since,
                                       NSTimeInterval beforeTs,
                                       NSDictionary *(^build)(sqlite3_stmt *st)) {
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &st, NULL) != SQLITE_OK) {
        // 🔴 v0.0.141：别静默返回空数组 —— 在调用方看来，「查不出来」和「本来就没有」
        //    完全同形（统计数字恒 0、而且零报错）。本次「记录全没了」就是被这种出口藏了两天。
        NSLog(@"[NotifyBox/store] ⚠️ 统计查询 prepare 失败 err=%s sql=%@",
              sqlite3_errmsg(db), sql);
        NBStoreLog(@"统计查询 prepare 失败 err=%s sql=%@", sqlite3_errmsg(db), sql);
        return @[];
    }
    // 🔴 两个时间边界**顺序绑定**：since 占第 1 个 `?`，beforeTs 占第 2 个。
    //    SQL 里 `AND ts>=? AND ts<?` 的顺序必须和这里一致。
    int p = 1;
    if (since > 0) sqlite3_bind_double(st, p++, (double)since);
    if (beforeTs > 0) sqlite3_bind_double(st, p++, (double)beforeTs);
    NSMutableArray *out = [NSMutableArray array];
    while (sqlite3_step(st) == SQLITE_ROW) {
        NSDictionary *d = build(st);
        if (d) [out addObject:d];
    }
    sqlite3_finalize(st);
    return out;
}

+ (NSArray<NSDictionary *> *)statsBundlesSince:(NSTimeInterval)since
                                       beforeTs:(NSTimeInterval)beforeTs
                                          limit:(NSInteger)limit {
    sqlite3 *db = [self openDB];
    if (!db) return @[];
    NSMutableString *sql = [NSMutableString stringWithString:
        @"SELECT bundle, COUNT(*), SUM(CASE WHEN read=0 THEN 1 ELSE 0 END) "
        @"FROM notifications WHERE 1=1"];
    if (since > 0) [sql appendString:@" AND ts>=?"];
    if (beforeTs > 0) [sql appendString:@" AND ts<?"];
    [sql appendString:@" GROUP BY bundle ORDER BY COUNT(*) DESC"];
    // 🔴 LIMIT 只能拼字面量（SQLite 不支持 `LIMIT ?` 之外的写法其实支持，
    //    但这里 limit 来自我们自己的常量，且是 long ⇒ 用 %ld 拼，不走用户输入）
    if (limit > 0) [sql appendFormat:@" LIMIT %ld", (long)limit];
    NSArray *rows = NBRows(db, sql, since, beforeTs, ^NSDictionary *(sqlite3_stmt *st) {
        const char *b = (const char *)sqlite3_column_text(st, 0);
        return @{
            @"bundle": (b ? [NSString stringWithUTF8String:b] : @""),
            @"total":  @(sqlite3_column_int(st, 1)),
            @"unread": @(sqlite3_column_int(st, 2)),
        };
    });
    sqlite3_close(db);
    return rows;
}

+ (NSArray<NSDictionary *> *)statsBucketsSince:(NSTimeInterval)since
                                     beforeTs:(NSTimeInterval)beforeTs
                                       byHour:(BOOL)byHour {
    sqlite3 *db = [self openDB];
    if (!db) return @[];
    NSString *expr = byHour
        ? @"CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER)"
        : @"strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime')";
    NSMutableString *sql = [NSMutableString stringWithFormat:
        @"SELECT %@ AS k, COUNT(*) FROM notifications WHERE 1=1", expr];
    if (since > 0) [sql appendString:@" AND ts>=?"];
    if (beforeTs > 0) [sql appendString:@" AND ts<?"];
    [sql appendString:@" GROUP BY k ORDER BY k"];
    NSArray *rows = NBRows(db, sql, since, beforeTs, ^NSDictionary *(sqlite3_stmt *st) {
        if (byHour) return @{ @"hour": @(sqlite3_column_int(st, 0)),
                              @"total": @(sqlite3_column_int(st, 1)) };
        const char *s = (const char *)sqlite3_column_text(st, 0);
        return @{ @"day": (s ? [NSString stringWithUTF8String:s] : @""),
                  @"total": @(sqlite3_column_int(st, 1)) };
    });
    sqlite3_close(db);
    if (byHour) {
        // 🔴 24 个桶**补齐**：SQL 的 GROUP BY 只回有记录的小时。
        //    不补的话，"凌晨 3 点一条都没有"这个信息在界面上就变成了"那一格不存在"，
        //    而"没有"和"没查到"在用户眼里是两回事。
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSDictionary *d in rows) map[d[@"hour"]] = d[@"total"];
        NSMutableArray *out = [NSMutableArray array];
        for (NSInteger h = 0; h < 24; h++) {
            [out addObject:@{@"hour": @(h), @"total": map[@(h)] ?: @0}];
        }
        return out;
    }
    return rows;
}

// ---------- v0.0.84：盒子侧的重复量（只读，三个聚合查询）----------
// 🔴 为什么必须有这个函数：用户报「部份信息有重复」，而上面那条写入侧去重
//    只有在 `sys_id` 有值时才生效。**得先量出重复到底集中在哪一类**：
//      · `sysGroups` > 0、`sysExtra` 也大 ⇒ 确实是同一条被记了多遍（去重该管用）；
//      · `sysGroups` == 0 而 `txtGroups` 大 ⇒ 那是**多条内容相同的不同通知**，
//        如实记录是对的，硬合并会丢信息；
//      · `noSys` 大 ⇒ 大量记录读不到 sys_id，去重对这些无效，得先修 sysId 来源。
//    🔴 三个数一起看才有意义，只报一个必然误判。
+ (NSDictionary *)dupStats {
    sqlite3 *db = [self openDB];
    if (!db) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    @try {
        const char *q1 = "SELECT COUNT(*), "
                         "SUM(CASE WHEN sys_id IS NULL OR sys_id='' THEN 1 ELSE 0 END) "
                         "FROM notifications;";
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, q1, -1, &st, NULL) == SQLITE_OK) {
            if (sqlite3_step(st) == SQLITE_ROW) {
                out[@"rows"] = @(sqlite3_column_int(st, 0));
                out[@"noSys"] = @(sqlite3_column_int(st, 1));
            }
            sqlite3_finalize(st);
        }
        const char *q2 = "SELECT COUNT(*), IFNULL(SUM(c-1),0) FROM ("
                         "SELECT sys_id, COUNT(*) c FROM notifications "
                         "WHERE sys_id IS NOT NULL AND sys_id<>'' "
                         "GROUP BY sys_id HAVING c>1);";
        if (sqlite3_prepare_v2(db, q2, -1, &st, NULL) == SQLITE_OK) {
            if (sqlite3_step(st) == SQLITE_ROW) {
                out[@"sysGroups"] = @(sqlite3_column_int(st, 0));
                out[@"sysExtra"] = @(sqlite3_column_int(st, 1));
            }
            sqlite3_finalize(st);
        }
        const char *q3 = "SELECT COUNT(*), IFNULL(SUM(c-1),0) FROM ("
                         "SELECT bundle, title, message, COUNT(*) c FROM notifications "
                         "GROUP BY bundle, title, message HAVING c>1);";
        if (sqlite3_prepare_v2(db, q3, -1, &st, NULL) == SQLITE_OK) {
            if (sqlite3_step(st) == SQLITE_ROW) {
                out[@"txtGroups"] = @(sqlite3_column_int(st, 0));
                out[@"txtExtra"] = @(sqlite3_column_int(st, 1));
            }
            sqlite3_finalize(st);
        }
        // ---------- v0.0.85：无 sys_id 的行到底有多"新" ----------
        // 🔴 这一条是**判决性**的。v0.0.84 的文案默认它们"是旧版本记下的"，
        //   但用户明确说「有些**刚推送**的也会提示通知不会变」⇒ 必须量，不许猜。
        //   · noSys24h > 0 ⇒ 新记录里也在丢 ID（先到的入口没拿到 bulletinID）⇒ 写入侧的问题；
        //   · noSys24h = 0 ⇒ 这批空 ID 全是老记录（v0.0.52 之前没这一列）⇒ 只能慢慢替换。
        //   两个「距今多少秒」用同一把尺子（`strftime('%s','now')`），
        //   🔴 不用 `timeIntervalSince1970` 在本地算 —— 两个进程各算一遍就可能差一秒，
        //      而这一行是给人看的判据，口径必须只有一个。
        const char *q4 = "SELECT "
                         "IFNULL(SUM(CASE WHEN ts>=strftime('%s','now')-86400 THEN 1 ELSE 0 END),0), "
                         "IFNULL(CAST(strftime('%s','now')-MAX(ts) AS INTEGER),-1), "
                         "IFNULL(CAST(strftime('%s','now')-MIN(ts) AS INTEGER),-1) "
                         "FROM notifications WHERE sys_id IS NULL OR sys_id='';";
        if (sqlite3_prepare_v2(db, q4, -1, &st, NULL) == SQLITE_OK) {
            if (sqlite3_step(st) == SQLITE_ROW) {
                out[@"noSys24h"]        = @(sqlite3_column_int(st, 0));
                out[@"noSysNewestAgo"]  = @(sqlite3_column_int(st, 1));
                out[@"noSysOldestAgo"]  = @(sqlite3_column_int(st, 2));
            }
            sqlite3_finalize(st);
        }
    } @catch (__unused NSException *e) { }
    sqlite3_close(db);
    return out;
}

+ (NSDictionary *)statsSummarySince:(NSTimeInterval)since beforeTs:(NSTimeInterval)beforeTs {
    sqlite3 *db = [self openDB];
    if (!db) return @{};
    NSMutableString *sql = [NSMutableString stringWithString:
        @"SELECT COUNT(*), SUM(CASE WHEN read=0 THEN 1 ELSE 0 END), "
        @"COUNT(DISTINCT bundle), MIN(ts) FROM notifications WHERE 1=1"];
    if (since > 0) [sql appendString:@" AND ts>=?"];
    if (beforeTs > 0) [sql appendString:@" AND ts<?"];
    sqlite3_stmt *st = NULL;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &st, NULL) == SQLITE_OK) {
        int p = 1;
        if (since > 0) sqlite3_bind_double(st, p++, (double)since);
        if (beforeTs > 0) sqlite3_bind_double(st, p++, (double)beforeTs);
        if (sqlite3_step(st) == SQLITE_ROW) {
            out[@"total"] = @(sqlite3_column_int(st, 0));
            out[@"unread"] = @(sqlite3_column_int(st, 1));
            out[@"apps"] = @(sqlite3_column_int(st, 2));
            double ts = sqlite3_column_double(st, 3);
            // 🔴 空表时 MIN(ts) 是 NULL ⇒ sqlite3_column_double 给 0 ⇒ 不能当"1970 年"显示
            if (ts > 0) out[@"earliest"] = [NSDate dateWithTimeIntervalSince1970:ts];
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return out;
}

// v0.0.133：旧签名退化成**薄封装**（见 NotifyStore.h 的理由：唯一实现只写一遍）。
+ (void)recordWithBundle:(NSString *)bundle
                   title:(NSString *)title
                 message:(NSString *)message
               subtitle:(NSString *)subtitle
                    date:(NSDate *)date
                  sysId:(NSString *)sysId {
    [self recordWithBundle:bundle title:title message:message subtitle:subtitle
                      date:date sysId:sysId payload:nil];
}

+ (void)recordWithBundle:(NSString *)bundle
                   title:(NSString *)title
                 message:(NSString *)message
               subtitle:(NSString *)subtitle
                    date:(NSDate *)date
                  sysId:(NSString *)sysId
                 payload:(NSString *)payload {
    if (!bundle.length) return;
    sqlite3 *db = [self openDB];
    if (!db) {
        NBStoreLog(@"openDB 失败 path=%@ err=%s", NOTIFYBOX_DB_PATH, sqlite3_errmsg(db));
        return;
    }

    // v0.0.52：加 sys_id 列（系统 bulletin ID，精确同步清通知中心用）。读不到时传 @""，
    //   该列只是空串，不影响记录本身，feature 自动失效。
    // 🔴🔴 v0.0.84：**同一条系统通知不许记两遍。**
    //   真机反馈「消息盒子里部份信息有重复」。查下来写入侧是**无条件 INSERT**：
    //   `hash` 列虽然写了，但**从来没有哪一行代码去查它**（等于装饰品）。
    //   唯一的去重是 tweak 侧 `NBClaimKey`，而它的窗口只有 **2 秒**
    //   （`bid|title|msg` 相同才算重复）—— 系统重投同一条通知只要间隔 > 2 秒，
    //   就会再落一行，看起来就是"重复"。
    //   ⇒ 正解不是拉长那个窗口（会吃掉用户连发的两条相同通知），而是用
    //   **系统级唯一标识 `sys_id`** 判等：同一个 sys_id = 同一条通知。
    //   🔴 三个必须守住的点：
    //     ① `sys_id` 为空（读不到）时**不许**去重 —— 否则所有空串行互相匹配，
    //        会把不相干的通知合并掉；
    //     ② 只 UPDATE **最新那一行**（`ORDER BY ts DESC LIMIT 1`），
    //        历史脏数据里同 sys_id 可能有多行，一次性全改会连坐；
    //     ③ 必须查 `sqlite3_changes()` —— UPDATE 命中 0 行也返回 `SQLITE_DONE`，
    //        不看 changes 就会"以为更新了、实际没插"，这条通知凭空消失。
    if (sysId.length) {
        const char *upd = "UPDATE notifications SET ts=? WHERE id=("
                          "SELECT id FROM notifications WHERE sys_id=? AND bundle=? "
                          "ORDER BY ts DESC LIMIT 1);";
        sqlite3_stmt *us = NULL;
        if (sqlite3_prepare_v2(db, upd, -1, &us, NULL) == SQLITE_OK) {
            double uts = date ? [date timeIntervalSince1970]
                              : [[NSDate date] timeIntervalSince1970];
            sqlite3_bind_double(us, 1, uts);
            sqlite3_bind_text(us, 2, [sysId UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(us, 3, [bundle UTF8String], -1, SQLITE_TRANSIENT);
            int urc = sqlite3_step(us);
            int changed = (urc == SQLITE_DONE) ? sqlite3_changes(db) : 0;
            sqlite3_finalize(us);
            if (changed > 0) {
                // 已经有过这一条 ⇒ 只把它顶到最新，不新增行
                sqlite3_close(db);
                return;
            }
        }
    }

    // ---------- v0.0.85：第二级去重（同内容 + 60 秒窗口）----------
    // 🔴 为什么非要第二级：`nc_diag(24).txt` 的 `[重]` 行给出
    //   `盒子 2145 行 ⇒ sysId 重复 0 组(多 0 行) ｜ 同内容重复 204 组(多 1853 行)`。
    //   ⇒ v0.0.84 按 sys_id 的判等**确实干净了**（0 组），但**同内容的重复一点没治**：
    //     系统把同一条通知重投时会分配**新的** sys_id，按 sys_id 判等永远认不出是同一件事。
    //     用户眼里的"重复"就是这 1853 行（占 2145 行的 86%）。
    // 🔴 窗口必须有限（60 秒）：不设窗口 ⇒ 用户连发两条一模一样的会被吞掉；设太长同理。
    //   ⚠️ 比的是**两条通知自己的时间戳**，不是墙钟 —— 系统重投旧通知时带的是原来的时间。
    // 🔴 命中就只 UPDATE（顶到最新 + 顺手把 sys_id 换成这次拿到的那个），**绝不新增行**。
    //   ⚠️ ts 用 `MAX(ts, ?)`：系统重投旧通知时带的是**原来的**时间戳，直接写会把行往后挪。
    {
        double inTs = date ? [date timeIntervalSince1970]
                           : [[NSDate date] timeIntervalSince1970];
        const char *sel = "SELECT id FROM notifications WHERE bundle=? AND title=? AND message=? "
                          "AND ts>=? ORDER BY ts DESC LIMIT 1;";
        sqlite3_stmt *ss = NULL;
        sqlite3_int64 dupId = 0;
        if (sqlite3_prepare_v2(db, sel, -1, &ss, NULL) == SQLITE_OK) {
            sqlite3_bind_text(ss, 1, [bundle UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(ss, 2, [title ?: @"" UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(ss, 3, [message ?: @"" UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_double(ss, 4, inTs - 60.0);
            if (sqlite3_step(ss) == SQLITE_ROW) dupId = sqlite3_column_int64(ss, 0);
            sqlite3_finalize(ss);
        }
        if (dupId > 0) {
            // 🔴 v0.0.85 为什么**允许覆盖**已有的 sys_id：系统把同一条通知重投一次会分配新 ID，
            //   而"删记录要能删掉界面上那条"靠的正是**最新**的那个 ID。若只补空位，
            //   这一行会永远攥着一个过期 ID ⇒ 用户点删除永远打不中现役那条
            //   —— 这正是 `nc_diag(24).txt` 里 34 次尝试中 28 次「同段有它条、ID 都不是目标」的由来。
            //   窗口只有 60 秒 ⇒ 能落到这里的两条必然是同一件事的重投，覆盖是安全的。
            //   ⚠️ 反过来：这次**没**拿到 ID 时保持原样（`?<>''` 守卫），别把好 ID 抹成空。
            // 🔴🔴 v0.0.117：覆盖 sys_id 之前，先把**旧 ID 存进 `sys_id_alt`**。
            //    为什么必须这么做（真机血账，2026-11-02 18:10）：NC 成批重投时这里会把
            //    几百行的 sys_id 改写成新 ID，而磁盘上的快照还是重投**之前**写的那一份
            //    ⇒ 两侧 ID 空间错开 ⇒ `全库残留` 在同一份快照、同一批行上 22 秒内从 179 掉到 2，
            //    盒子上"还在通知中心"的橙框一路灭掉，提示条还会写「都不在通知中心了」。
            //    ⇒ 留着旧 ID，匹配（`aliveStateOfSysId` 本来就按 `|` 拆开逐段比）就跨得过这次换 ID。
            // 🔴 三条边界：
            //    ① `sys_id_alt` 最多留 **2 个**旧 ID（`instr(...)>0` 判断），不然每重投一次就长一截，
            //       长到几十个 ID 时既费空间、又让"这个键命中"变成碰运气；
            //       满了以后**丢最早那个、留最近两个**（`substr(...instr+1)`）：快照通常只落后
            //       一两轮重投，最近两个旧 ID 才是真正用得上的；最老的那个早已过期。
            //       不变式：`sys_id_alt` 里最多一个 `|`（两段），下面那个 `substr` 因此必然取到第 2 段。
            //    ② 只在**旧 ID 非空且与新 ID 不同**时才动它 —— 相同就是没换 ID，不该往里塞重复串；
            //    ③ SQLite 的 UPDATE 是**先按旧行算完所有表达式再赋值** ⇒ 下面 `sys_id_alt` 表达式里
            //       引用的 `sys_id` 一定是改写前那个。（把 alt 写在前面只是让人读懂意图，不是语法要求。）
            const char *upd =
                "UPDATE notifications SET "
                "ts = MAX(ts, ?1), "
                "sys_id_alt = CASE "
                "  WHEN ?2<>'' AND sys_id<>'' AND sys_id<>?2 THEN "
                "    CASE WHEN IFNULL(sys_id_alt,'')='' THEN sys_id "
                "         WHEN instr(sys_id_alt,'|')>0 "
                "              THEN substr(sys_id_alt, instr(sys_id_alt,'|')+1) || '|' || sys_id "
                "         ELSE sys_id_alt || '|' || sys_id END "
                "  ELSE sys_id_alt END, "
                "sys_id = CASE WHEN ?2<>'' THEN ?2 ELSE sys_id END "
                "WHERE id=?3;";
            sqlite3_stmt *us2 = NULL;
            int changed = 0;
            if (sqlite3_prepare_v2(db, upd, -1, &us2, NULL) == SQLITE_OK) {
                sqlite3_bind_double(us2, 1, inTs);
                sqlite3_bind_text(us2, 2, [sysId ?: @"" UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_int64(us2, 3, dupId);
                int urc2 = sqlite3_step(us2);
                changed = (urc2 == SQLITE_DONE) ? sqlite3_changes(db) : 0;
                sqlite3_finalize(us2);
            } else {
                // 🔴 v0.0.117：prepare 失败**必须**留痕。不报的话 changed 仍是 0 ⇒ 直接落到
                //    下面 INSERT ⇒ 同一条通知被记两遍，而日志上什么都看不出来
                //    （本项目吃过"静默落一行"的亏，这类错只能靠一行日志抓）。
                NBStoreLog(@"内容去重 prepare 失败 err=%s", sqlite3_errmsg(db));
            }
            // 🔴 必须查 changes：UPDATE 命中 0 行也返回 SQLITE_DONE。
            //    命中 0 行说明这一行在这几毫秒里被别人删了 ⇒ 落到下面正经 INSERT，别把通知吞掉。
            if (changed > 0) {
                sqlite3_close(db);
                return;
            }
        }
    }

    // 🔴🔴🔴 v0.0.141：**INSERT 必须能降级 —— 附加字段永远不许决定核心功能的生死。**
    //
    // 事故复盘（2026-11-03 晚 v0.0.133 → 11-04 真机「记录全没了」）：
    //   v0.0.133 给这条 INSERT 加了第 8 个字段 `payload`（长按直达用的原始 userInfo）。
    //   全新库没问题（CREATE TABLE 里就带这一列）；但**老库**要靠 ALTER TABLE 补，
    //   而那条 ALTER 的返回值当时被丢掉了 —— 成没成功没人知道。
    //   一旦它没补上（真机现场：`/var/mobile/Library/NotifyBox` 已不可写，ALTER 必然失败），
    //   库结构里就永远没有 payload 列 ⇒ 这条 prepare 直接
    //   `no such column: payload` ⇒ **每一条通知都在这里被丢掉**。
    //   而失败日志写在同目录的 tweak.log 里 ⇒ **连报错都被一起吞了**。
    //   ⇒ 症状长得像「整个插件全死了」，真实原因只是「附加字段存不了」。
    //
    // 🔴 所以判据不是「ALTER 写对」，而是「ALTER 没成功时这条记录还能不能存」。
    //   写法：8 列 prepare 失败 → **退回 7 列**，功能自动降级成「没有 payload」，
    //   而不是「没有记录」。这条降级路径**不依赖** ALTER 成功、也不依赖 PRAGMA 探测对不对
    //   —— 它是自愈的：库长什么样，就走哪条路。
    const char *ins8 = "INSERT INTO notifications (bundle,title,message,subtitle,ts,hash,sys_id,payload) "
                       "VALUES (?,?,?,?,?,?,?,?)";
    const char *ins7 = "INSERT INTO notifications (bundle,title,message,subtitle,ts,hash,sys_id) "
                       "VALUES (?,?,?,?,?,?,?)";
    sqlite3_stmt *stmt = NULL;
    BOOL withPayload = YES;
    if (sqlite3_prepare_v2(db, ins8, -1, &stmt, NULL) != SQLITE_OK) {
        // 🔴 errmsg 必须先拷成 NSString：下一次任何 sqlite 调用都会覆盖这块内部缓冲。
        const char *m1 = sqlite3_errmsg(db);
        NSString *e1 = m1 ? [NSString stringWithUTF8String:m1] : @"(null)";
        stmt = NULL;
        withPayload = NO;
        if (sqlite3_prepare_v2(db, ins7, -1, &stmt, NULL) != SQLITE_OK) {
            const char *m2 = sqlite3_errmsg(db);
            // 连 7 列都不行 ⇒ 这条真的存不了。**但绝不许静默**：
            //   NBStoreLog 可能写不进去（正是本次事故的形态），所以 NSLog 也要打。
            NSLog(@"[NotifyBox/store] ⚠️ INSERT 8列/7列 都 prepare 失败 err8=%@ err7=%s bundle=%@",
                  e1, m2 ? m2 : "(null)", bundle);
            NBStoreLog(@"INSERT 8列/7列 都 prepare 失败 err8=%@ err7=%s bundle=%@",
                       e1, m2 ? m2 : "(null)", bundle);
            stmt = NULL;
        } else {
            // 降级成功：记录保住了，只是没有 payload。
            //   **必须留痕** —— 否则「长按没有直达」会表现为「新功能悄悄失灵」，
            //   和「payload 里本来就没链接」长得一模一样，又是一轮无从下手。
            NSLog(@"[NotifyBox/store] ⚠️ payload 列不可用，已降级 7 列写入（记录正常）err=%@", e1);
            NBStoreLog(@"INSERT 降级 7 列（无 payload）err=%@", e1);
        }
    }
    if (stmt) {
        sqlite3_bind_text(stmt, 1, [bundle UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, [title ?: @"" UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, [message ?: @"" UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 4, [subtitle ?: @"" UTF8String], -1, SQLITE_TRANSIENT);
        double ts = date ? [date timeIntervalSince1970] : [[NSDate date] timeIntervalSince1970];
        sqlite3_bind_double(stmt, 5, ts);
        NSString *h = [NSString stringWithFormat:@"%@|%@|%@", bundle, title ?: @"", message ?: @""];
        NSData *hd = [h dataUsingEncoding:NSUTF8StringEncoding];
        sqlite3_bind_text(stmt, 6, [[hd description] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 7, [sysId ?: @"" UTF8String], -1, SQLITE_TRANSIENT);
        // v0.0.133：payload 允许为 nil（读不到 userInfo 的通知是大多数情况）。
        // 🔴 nil 存 NULL 而不是空串：空串会让"有 payload 但解析不出链接"和
        //    "压根没有 payload"在库里长得一样，以后想统计命中率就分不开。
        // 🔴🔴 v0.0.141：**只有真的用 8 列语句时才 bind 第 8 个参数。**
        //   降到 7 列语句后还 bind(8) 会报 SQLITE_RANGE（参数越界），
        //   等于把刚救回来的记录又丢一次。
        if (withPayload) {
            if (payload.length) {
                sqlite3_bind_text(stmt, 8, [payload UTF8String], -1, SQLITE_TRANSIENT);
            } else {
                sqlite3_bind_null(stmt, 8);
            }
        }
        int rc = sqlite3_step(stmt);
        if (rc != SQLITE_DONE) {
            NSLog(@"[NotifyBox/store] ⚠️ INSERT 失败 rc=%d err=%s bundle=%@ cols=%d",
                  rc, sqlite3_errmsg(db), bundle, withPayload ? 8 : 7);
            NBStoreLog(@"INSERT 失败 rc=%d err=%s bundle=%@", rc, sqlite3_errmsg(db), bundle);
        }
        sqlite3_finalize(stmt);
    }

    // 上限裁剪：保留最新的 maxRecords 条
    NSInteger limit = [self maxRecords];
    if (limit > 0) {
        NSString *del = [NSString stringWithFormat:
            @"DELETE FROM notifications WHERE id NOT IN "
            @"(SELECT id FROM notifications ORDER BY ts DESC LIMIT %ld);", (long)limit];
        sqlite3_exec(db, [del UTF8String], NULL, NULL, NULL);
    }
    sqlite3_close(db);
}

// ---------- v0.0.85：给「刚记下但没 ID」的那一行补写 sys_id ----------
// 🔴 真机背景（`nc_diag(24).txt`）：`[重]` 行报 `无 sysId 221 行`，而用户明确说
//   「有些**刚推送**的，也有的会提示通知不会变」⇒ 这批空 ID 的行**不全是老记录**。
//   机制上完全说得通：同一条通知会经过三个入口
//   （`publishBulletin:` / `publishBulletinRequest:` / `_publishBulletinRequest:forSectionID:forDestinations:`），
//   **谁先到谁记录**（`NBClaimKey` 只放行第一个）。先到的入口手里可能还没有 `bulletinID`
//   —— 系统是在 publish 过程中才分配的 —— 于是那一行 `sys_id` 落成空串；
//   后到的入口手里有 ID，却被 `NBClaimKey` 挡在 store 之前，**永远没机会补**。
//   ⇒ 这里就是那个"补"的出口：claim 被挡时把 ID 写回去。
// 🔴 三条护栏（少一条都会出事，v0.0.84 的教训在这里同样成立）：
//   ① 只改 `sys_id` 为空/NULL 的行 —— 空串相同 ≠ 同一条通知，一旦允许覆盖已有 ID，
//      会把两条不相干的通知合成一条；
//   ② 只改**最近那一行**（`ORDER BY ts DESC LIMIT 1`）—— 同内容的历史脏行可能有好几行，
//      一把 UPDATE 会连坐；
//   ③ 必须查 `sqlite3_changes()` —— UPDATE 命中 0 行照样返回 `SQLITE_DONE`。
// 🔴 窗口 600 秒：超出就不补。理由是「补错人」比「没补上」更糟——
//   两小时前的同内容行几乎肯定不是刚才这条通知。
+ (NSInteger)backfillSysId:(NSString *)sysId
                    bundle:(NSString *)bundle
                     title:(NSString *)title
                   message:(NSString *)message {
    if (!sysId.length || !bundle.length) return 0;
    sqlite3 *db = [self openDB];
    if (!db) return 0;
    NSInteger changed = 0;
    @try {
        double now = [[NSDate date] timeIntervalSince1970];
        // 🔴 v0.0.86：窗口 600 → 1800 秒。原来的 600 是基于「补写紧跟在插入之后，秒级」这个
        //   假设，但 `ts` 存的**不是插入时刻**，而是 `date ?: now`（见 insert 那段）——
        //   系统重投一条通知时，`date` 可能是它**原本该发生的时间**，早于插入时刻。
        //   于是 `ts>=now-600` 会把"刚插进来的那一行"自己排除掉 ⇒ 补写恒 0 行，
        //   而日志显示「取到 ID、补写 0 行」，看着像是 ID 不对，其实是时间窗把它筛掉了。
        //   放宽到 1800 秒的风险由两条护栏兜住：只碰 `sys_id` 为空的行，且取 ts 最大的那一条。
        const char *upd = "UPDATE notifications SET sys_id=? WHERE id=("
                          "SELECT id FROM notifications WHERE bundle=? AND title=? AND message=? "
                          "AND (sys_id IS NULL OR sys_id='') AND ts>=? "
                          "ORDER BY ts DESC LIMIT 1);";
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, upd, -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, [sysId UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 2, [bundle UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 3, [title ?: @"" UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 4, [message ?: @"" UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_double(st, 5, now - 1800.0);
            int rc = sqlite3_step(st);
            if (rc == SQLITE_DONE) changed = sqlite3_changes(db);
            else NBStoreLog(@"补写 sys_id 失败 rc=%d err=%s", rc, sqlite3_errmsg(db));
            sqlite3_finalize(st);
        }
    } @catch (__unused NSException *e) { }
    sqlite3_close(db);
    return changed;
}

// 🔴🔴 v0.0.40：**筛选条件的唯一出口**。
//    列表（`queryWithBundle:`）、图标栏红点（`bundlesWithUnreadSince:`）、
//    未读计数（`unreadCountWithBundle:`）、批量标记（`markAllRead…`）四条路全走这里。
//    拼 WHERE 和绑参必须在同一个函数里完成 —— 拆成"拼一处、绑一处"就有顺序走岔的可能，
//    而这类错**不报错、只静默少筛或多筛一个条件**。
//    v0.0.35 的 `onClear:` 已经买过一次教训：确认框报列表条数（3）、实际清整张表（2000）。
// v0.0.40 为什么必须加 `search`：顶部提示条要回答「当前筛选之外还有多少条未读」，
//    这个数 = 全库未读 − **当前筛选下的未读**，而"当前筛选"包含 App 图标 + 时间 + 搜索三项。
//    如果搜索只在 `queryWithBundle:` 里生效、计数那边没有，两边的未读数就永远对不上，
//    症状是"列表里明明全读完了，顶部还在喊还有 3 条"。
// 🔴 `search` 只给**查询**用：`markAllRead…` 一律传 nil —— 搜索只决定列表显示什么，
//    不缩小标记范围（v0.0.38 的确认文案里对用户就是这么承诺的）。
// v0.0.42 为什么又加 `searchBundles`：搜索从此**同时匹配 App 名**。
//    App 名不在库里（库里只有 bundle id），「搜到的词命中了哪几个 App」只能由界面层
//    拿 `InstalledApps` 算好、把 bundle 列表传进来。
//    🔴🔴 **它必须进这个函数** —— 如果留在 `queryWithBundle:` 里单独拼，计数那条路就少一个
//    `OR bundle IN (...)`，两个口径立刻不一致 ⇒ v0.0.40 花整版修掉的
//    「列表里明明都读完了、顶部还在喊还有 3 条」当场复发。
//    🔴 `searchBundles` 只在 `search.length` 时生效：它和三个 LIKE 是**同一个括号组**里的 OR。
//    只传 bundles、search 却是 nil 的调用没有意义 ⇒ 直接忽略（不报错，因为调用方可能
//    复用同一个"筛选快照"，那里 search 可能恰好是空的）。
// `head` 里可以预置 `read=0`（未读专用）；`tail` 放 ORDER BY / LIMIT。
static sqlite3_stmt *NBPrepareScope(sqlite3 *db, NSString *head, NSString * _Nullable tail,
                                    NSString * _Nullable bundle, NSTimeInterval since,
                                    NSString * _Nullable search,
                                    NSArray<NSString *> * _Nullable searchBundles) {
    NSMutableString *sql = [NSMutableString stringWithString:head];
    if (bundle.length) [sql appendString:@" AND bundle=?"];
    if (since > 0)     [sql appendString:@" AND ts>=?"];
    if (search.length) {
        // v0.0.42 两处扩展：
        // ① 加 `subtitle` —— 以前 subtitle 只在 message 为空时才当正文显示（见 NotifyCell），
        //    正文不空时它**一个字都看不到**、也搜不到。用户明明有这条记录，搜关键词却是空列表。
        // ② 加 `bundle IN (...)` —— 搜「微信」「招商银行」这种 App 名，而库里只有
        //    `com.tencent.xin` / `cmb.pb`，标题正文里也没有那几个汉字 ⇒ 以前永远搜不到。
        [sql appendString:@" AND (title LIKE ? OR message LIKE ? OR subtitle LIKE ?"];
        if (searchBundles.count) {
            NSMutableString *ph = [NSMutableString string];
            for (NSUInteger k = 0; k < searchBundles.count; k++) {
                [ph appendString:(k ? @",?" : @"?")];
            }
            [sql appendFormat:@" OR bundle IN (%@)", ph];
        }
        [sql appendString:@")"];
    }
    if (tail.length)   [sql appendString:tail];

    // 🔴🔴🔴 v0.0.141：**读路径也必须能降级** —— 这是「记录全没了」最直接的那一半。
    //
    // 事故现场（2026-11-03 晚 v0.0.133 → 真机「一条记录都没有」）：
    //   老库没有 `payload` 列（ALTER 静默失败），而四条 SELECT 全把
    //   `IFNULL(payload,'')` 写死在语句里 ⇒ 这里 prepare 失败 ⇒ 返回 NULL ⇒
    //   调用处 `if (st) { while(...) }` 直接跳过 ⇒ **函数返回空数组、一条报错都没有**。
    //   于是界面上「记录全没了」，而库里其实可能有几百条 —— 只是读不出来。
    //   ⇒ 上一版修了写入（INSERT 降级）还不够：**写得进、读不出，用户看到的同样是空**。
    //
    // 🔴 降级写法固定为「把取不到的列换成空串常量 `,''`」：
    //   ① **列数一律不变** ⇒ `NBAppendRow` 里写死的列号 9 仍然有效，
    //      `row[@"payload"]` 拿到空串，与「没有 payload」同义（消费端本来就是这么理解的）；
    //   ② 不需要在四条 SELECT 里各写一份降级分支（它们是同一个出口，改一处全覆盖）；
    //   ③ 顺序不可反：先降 payload（v0.0.133 新增，最可能缺），再降 sys_id_alt。
    //      **一次只降一列**，才知道到底是哪一列缺 —— 两列一起降会把病因抹掉。
    NSString *finalSQL = sql;
    sqlite3_stmt *st = NULL;
    int rc = sqlite3_prepare_v2(db, [finalSQL UTF8String], -1, &st, NULL);

    if (rc != SQLITE_OK) {
        const char *m0 = sqlite3_errmsg(db);
        NSString *err0 = m0 ? [NSString stringWithUTF8String:m0] : @"(null)";
        NSString *d1 = [sql stringByReplacingOccurrencesOfString:@",IFNULL(payload,'')"
                                                     withString:@",''"];
        if (![d1 isEqualToString:sql]) {
            st = NULL;
            rc = sqlite3_prepare_v2(db, [d1 UTF8String], -1, &st, NULL);
            if (rc == SQLITE_OK) {
                finalSQL = d1;
                NSLog(@"[NotifyBox/store] ⚠️ SELECT 降级（payload 列缺失）原错误=%@", err0);
                NBStoreLog(@"SELECT 降级：payload 列缺失，已用空串替代 err=%@", err0);
            }
        }
    }
    if (rc != SQLITE_OK) {
        const char *m1 = sqlite3_errmsg(db);
        NSString *err1 = m1 ? [NSString stringWithUTF8String:m1] : @"(null)";
        NSString *d2 = [sql stringByReplacingOccurrencesOfString:@",IFNULL(payload,'')"
                                                     withString:@",''"];
        d2 = [d2 stringByReplacingOccurrencesOfString:@",IFNULL(sys_id_alt,'')"
                                           withString:@",''"];
        if (![d2 isEqualToString:sql]) {
            st = NULL;
            rc = sqlite3_prepare_v2(db, [d2 UTF8String], -1, &st, NULL);
            if (rc == SQLITE_OK) {
                finalSQL = d2;
                NSLog(@"[NotifyBox/store] ⚠️ SELECT 降级（payload + sys_id_alt 都缺）原错误=%@", err1);
                NBStoreLog(@"SELECT 降级：payload+sys_id_alt 都缺 err=%@", err1);
            }
        }
    }
    if (rc != SQLITE_OK) {
        // 真的查不出来。**绝不许静默 return NULL** —— 那个 NULL 在调用处看起来
        // 和「库里没有记录」完全一样，正是本次找了两天的原因。
        const char *m2 = sqlite3_errmsg(db);
        NSLog(@"[NotifyBox/store] ⚠️ SELECT 彻底失败（降级也没救回）err=%s sql=%@",
              m2 ? m2 : "(null)", finalSQL);
        NBStoreLog(@"SELECT 彻底失败 err=%s sql=%@", m2 ? m2 : "(null)", finalSQL);
        return NULL;
    }
    // 绑参顺序**必须**和上面 append 的顺序逐条对应。
    int i = 1;
    if (bundle.length) sqlite3_bind_text(st, i++, [bundle UTF8String], -1, SQLITE_TRANSIENT);
    if (since > 0)     sqlite3_bind_double(st, i++, (double)since);
    if (search.length) {
        NSString *like = [NSString stringWithFormat:@"%%%@%%", search];
        // 🔴 三条 LIKE **各绑一次**。少绑一条不会报错（SQLite 把没绑的参数当 NULL，
        //    而 `x LIKE NULL` 恒不成立）—— 症状是"搜出来的东西莫名其妙少一半"，
        //    而且紧接着的 `bundle IN` 参数会**整体前移一格**，绑错值。
        sqlite3_bind_text(st, i++, [like UTF8String], -1, SQLITE_TRANSIENT);   // title
        sqlite3_bind_text(st, i++, [like UTF8String], -1, SQLITE_TRANSIENT);   // message
        sqlite3_bind_text(st, i++, [like UTF8String], -1, SQLITE_TRANSIENT);   // subtitle
        if (searchBundles.count) {
            for (NSString *bid in searchBundles) {
                sqlite3_bind_text(st, i++, [bid UTF8String], -1, SQLITE_TRANSIENT);
            }
        }
    }
    return st;
}

+ (NSInteger)listLimit {
    // v0.0.42：把 `LIMIT 2000` 抽成唯一来源。底部「还有 N 条更早记录（列表上限 N）」
    // 要把它写进文案里 —— 界面上另写一个字面量 2000，这个数以后一改就会对不上。
    return kNBListLimit;
}

// ---------- v0.0.117：把「现役 ID」和「保留的旧 ID」拼成一组候选键 ----------
// 🔴 为什么需要它：NC（通知中心）成批重投时会**换新 sys_id**，内容去重那条 UPDATE
//    就把库里的 `sys_id` 改写成了新 ID ⇒ 快照写于重投之前的话，两侧 ID 空间当场错开。
//    真机实测后果：同一份快照、同一批 2163 行，「全库残留」22 秒内 179 → 91 → 2。
//    ⇒ 改写前把旧 ID 存进 `sys_id_alt`，这里拼成 `新|旧` 交给 `aliveStateOfSysId`，
//      它本来就按 `|` 拆开逐段比 —— **匹配逻辑一行不用改**，跨度就自动跨过重投。
// 🔴 绝不许把旧 ID 拼进 `sys_id` 本身：`deDupBySysId` 是按 `sys_id` **整串** `GROUP BY` 的，
//    一改分组结果就变，列表会冒出重复行。旧 ID 必须留在独立列里。
// 🔴 去重保序：同一个 ID 出现两次会让 `[残]` 的「段=」数虚高，而那个数正是我们要读的量。
// 🔴 总长设上限：`sys_id` 是 TEXT 不限长，但一行日志打印不了无限长；
//    超过上限就**丢掉多出来的旧 ID**（宁可少匹配一个旧 ID，不许把日志撑爆）。
// ⚠️ 这个 helper 有两个调用点（列表行映射 `NBAppendRow` 在前、残留计数在后），
//    ⇒ 定义必须放在**最早**那个调用点之前（C 里先用后定义 = undeclared identifier）。
#define NB_SYSID_ALT_SEP @"|"
#define NB_SYSID_CAND_MAXLEN 200
static NSString *NBSysIdWithAlt(NSString *sysId, NSString *alt) {
    if (![alt isKindOfClass:[NSString class]] || alt.length == 0) return sysId ?: @"";
    if (![sysId isKindOfClass:[NSString class]] || sysId.length == 0) return alt;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in [sysId componentsSeparatedByString:NB_SYSID_SEP]) {
        if (p.length && ![out containsObject:p]) [out addObject:p];
    }
    for (NSString *p in [alt componentsSeparatedByString:NB_SYSID_ALT_SEP]) {
        if (p.length && ![out containsObject:p]) [out addObject:p];
    }
    NSString *joined = [out componentsJoinedByString:NB_SYSID_SEP];
    if (joined.length > NB_SYSID_CAND_MAXLEN) {
        // 截到上限后最后一段可能是半个 ID ⇒ 宁可整段丢掉，也不留半截去比
        NSString *cut = [joined substringToIndex:NB_SYSID_CAND_MAXLEN];
        NSRange r = [cut rangeOfString:NB_SYSID_SEP options:NSBackwardsSearch];
        if (r.location != NSNotFound) cut = [cut substringToIndex:r.location];
        NBStoreLog(@"候选键超长已截断 %lu→%lu", (unsigned long)joined.length, (unsigned long)cut.length);
        joined = cut;
    }
    return joined;
}

// v0.0.44：把"一行结果 → 字典"抽成一份。
// 🔴 列表和导出现在共用它 —— 两处各抄一遍列号，改 SELECT 时必然有一处漏改，
//    而那种错不会报错，只会让某一列悄悄变成空串。
// 🔴🔴 v0.0.100 血账：`sys_id` 列从 v0.0.52 就进库了，但**列表 SELECT 一直没取它**，
//    本函数也就一直没映射它。后果不是"少一列空串"，而是
//    `row[@"sys_id"]` 恒为 `nil` ⇒ `aliveStateOfSysId:` 恒返回 `NBAliveUnknown`
//    ⇒ `aliveStillCount` **恒为 0**，且**一条报错都没有**（nil 一路传到 `if (!sysId.length) return Unknown;`）。
//    真机表现：tweak 日志明写「NC 现状 4 条（有键 4）写入=成功」，盒子上却是 0 条。
    //    ⇒ 判据必须把「SELECT 列表 / 这里的列号映射 / 消费端读的键名」三处钉在一起，
//      静态查"代码里出现过 sys_id"完全挡不住这类（本项目 Z4 那族：绿的原因不等于它要证的事）。
//    ⚠️ 改这里必须同时改**两个** SELECT（列表 + 导出）：它们共用本函数，
//      列数/列序不一致会让后面某一列读到 NULL 而静默变空。
// v0.0.117：末尾加了第 9 列 `IFNULL(sys_id_alt,'')`，**四个** SELECT 一起加了
//    （列表两条 + 导出两条）。静态判据要数 `IFNULL(sys_id_alt` 出现 4 次 ——
//    只加一处就会让另一处的第 9 列读到 NULL，而 `?: ""` 会让它静默变空串。
static void NBAppendRow(sqlite3_stmt *st, NSMutableArray *res) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"]       = @(sqlite3_column_int(st, 0));
    // 🔴 `sqlite3_column_text` 对 NULL 返回 NULL，直接塞给 `stringWithUTF8String:` 会崩
    //    ⇒ 每个文本列都要有 `?: ""` 这个兜底。
    d[@"bundle"]   = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(st, 1) ?: ""];
    d[@"title"]    = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(st, 2) ?: ""];
    d[@"message"]  = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(st, 3) ?: ""];
    d[@"subtitle"] = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(st, 4) ?: ""];
    d[@"ts"]       = @(sqlite3_column_double(st, 5));
    d[@"read"]     = @(sqlite3_column_int(st, 6));
    // v0.0.100：第 8 列。`sys_id` 是列表页判"还在不在通知中心"的唯一依据（见上面的血账）。
    d[@"sys_id"]   = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(st, 7) ?: ""];
    // 🔴🔴 v0.0.117：第 9 列 `sys_id_alt`（保留的旧 ID），拼成 `新|旧` 放进**另一个键**。
    //    为什么不直接改进 `sys_id`：那个键还有别的读者（导出、以及后续可能的 NC 清请求），
    //    改它的语义 = 在别处静默改行为。这里只多给一个"候选键"专用键，
    //    消费端（`ViewController` 的存活标记）改读它，`sys_id` 原义不动。
    // 🔴 口径必须和 `countStillInDBWithSnapshot:` 一致 —— 同一个界面里"互相解释"的两个指标
    //    （残留条数 vs 每行标记）不同口径，就会出现"总数说还在、逐行都说不在了"。
    NSString *sid7 = d[@"sys_id"] ?: @"";
    NSString *salt8 = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(st, 8) ?: ""];
    d[@"sys_id_cand"] = NBSysIdWithAlt(sid7, salt8);
    // 🔴🔴 v0.0.133：第 10 列（列号 9）`payload`。
    //    **跨文件契约的第三边**：SELECT 里的顺序 ↔ 这里的列号 ↔ 消费端键名
    //    （`ViewController -nbMenuForRow:` 读 `row[@"payload"]`）。
    //    漏了这一边 = 消费端恒 nil、**恒 0 且不报错** —— v0.0.99 那次的同一个坑。
    d[@"payload"]  = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(st, 9) ?: ""];
    [res addObject:d];
}

+ (NSArray<NSDictionary *> *)queryWithBundle:(NSString *)bundle
                                       since:(NSTimeInterval)since
                                      search:(NSString *)q
                              searchBundles:(NSArray<NSString *> *)searchBundles
                                  unreadOnly:(BOOL)unreadOnly {
    NSMutableArray *res = [NSMutableArray array];
    sqlite3 *db = [self openDB];
    if (!db) return res;

    // v0.0.36：只看未读。`read=0` 是未读（建表默认值），1 是已读。
    // 🔴 用 `read=0` 而不是 `read<>1`：后者对 NULL 不成立，老库若有 read 为 NULL 的行
    //    会既不进"未读"也不进"已读"，凭空消失。
    // v0.0.40：WHERE 部分交给 `NBPrepareScope`，本方法只负责"读哪些列、怎么排序"。
    // 🔴🔴 v0.0.100：**必须带 `sys_id`**。列表页要靠它判"这条还在不在通知中心"
    //    （`ViewController` 读 `row[@"sys_id"]`）。v0.0.99 漏了这一列 ⇒ 消费端恒拿 nil
    //    ⇒ 残留标记恒 0，而且不报错。加/删列时**四个** SELECT（列表两条 + 导出两条）
    //    和 `NBAppendRow` 的列号必须一起改。
    NSString *head = unreadOnly
        ? @"SELECT id,bundle,title,message,subtitle,ts,read,sys_id,IFNULL(sys_id_alt,''),IFNULL(payload,'') FROM notifications WHERE read=0"
        : @"SELECT id,bundle,title,message,subtitle,ts,read,sys_id,IFNULL(sys_id_alt,''),IFNULL(payload,'') FROM notifications WHERE 1=1";
    NSString *tail = [NSString stringWithFormat:@" ORDER BY ts DESC LIMIT %ld", (long)kNBListLimit];
    sqlite3_stmt *st = NBPrepareScope(db, head, tail, bundle, since, q, searchBundles);
    if (st) {
        while (sqlite3_step(st) == SQLITE_ROW) NBAppendRow(st, res);
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return res;
}

// v0.0.44：导出专用 —— **没有 LIMIT**。
// 🔴 为什么不复用 `queryWithBundle:`：它带 `LIMIT listLimit`（2000）⇒
//    导出来的文件会"刚好少掉最旧的几千条"，而用户拿到手时**根本看不出来**
//    （这正是备份功能最不能犯的错：你以为备份了，其实没有）。
// 🔴🔴 但 WHERE 条件**必须**和列表走同一个 `NBPrepareScope`，不能自己另拼一份 ——
//    否则"导出的"和"看到的"不是一批数据（v0.0.40 那条坑的同一族）。
//    这里只有 `tail` 和列表那一份不一样（一个不带 LIMIT）。
+ (NSArray<NSDictionary *> *)exportRowsWithBundle:(NSString * _Nullable)bundle
                                            since:(NSTimeInterval)since
                                           search:(NSString * _Nullable)q
                                    searchBundles:(NSArray<NSString *> * _Nullable)searchBundles
                                       unreadOnly:(BOOL)unreadOnly {
    NSMutableArray *res = [NSMutableArray array];
    sqlite3 *db = [self openDB];
    if (!db) return res;
    NSString *head = unreadOnly
        ? @"SELECT id,bundle,title,message,subtitle,ts,read,sys_id,IFNULL(sys_id_alt,''),IFNULL(payload,'') FROM notifications WHERE read=0"
        : @"SELECT id,bundle,title,message,subtitle,ts,read,sys_id,IFNULL(sys_id_alt,''),IFNULL(payload,'') FROM notifications WHERE 1=1";
    sqlite3_stmt *st = NBPrepareScope(db, head, @" ORDER BY ts DESC", bundle, since, q, searchBundles);
    if (st) {
        while (sqlite3_step(st) == SQLITE_ROW) NBAppendRow(st, res);
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return res;
}

+ (NSArray<NSString *> *)distinctBundles {
    NSMutableArray *a = [NSMutableArray array];
    sqlite3 *db = [self openDB];
    if (!db) return a;
    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(db, "SELECT DISTINCT bundle FROM notifications ORDER BY bundle", -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const char *t = (const char *)sqlite3_column_text(st, 0);
            if (t) [a addObject:[NSString stringWithUTF8String:t]];
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return a;
}

+ (NSSet<NSString *> *)bundlesWithUnreadSince:(NSTimeInterval)since {
    // v0.0.36：图标栏红点用。只回"这个 App 有没有未读"，不回条数。
    // 🔴 为什么不复用 `bundleCounts`：它 `SELECT bundle, COUNT(*)` 数的是**全部**记录
    //    （v0.0.13 给 App 选择器排序用），拿它判未读 ⇒ 所有 App 永远都有红点，
    //    红点变成装饰，等于没有。
    // v0.0.37：加时间窗。红点必须和列表同一口径 —— 否则会出现"有红点、点进去没记录、
    //    红点永远消不掉"（v0.0.36 真机实测）。`since <= 0` 就当全库。
    NSMutableSet *s = [NSMutableSet set];
    sqlite3 *db = [self openDB];
    if (!db) return s;
    // v0.0.40：时间条件改成走 `NBPrepareScope`（以前这里自己拼了一份 `AND ts>=?`，
    //    和列表那份是两处代码 —— 只要有一处改了，红点和列表就会不同口径）。
    sqlite3_stmt *st = NBPrepareScope(db,
        @"SELECT DISTINCT bundle FROM notifications "
        @"WHERE read=0 AND bundle IS NOT NULL AND bundle <> ''",
        nil, nil, since, nil, nil);
    if (st) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const char *t = (const char *)sqlite3_column_text(st, 0);
            if (!t) continue;
            NSString *bid = [NSString stringWithUTF8String:t];
            if (bid.length) [s addObject:bid];
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return s;
}

+ (NSDictionary<NSString *, NSNumber *> *)bundleCounts {
    // v0.0.13：给「可搜索 App 选择器」用 —— 有通知记录的 App 排在前面。
    // 只回 bundle + 条数，不碰 title/message，比拉全表轻得多。
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    sqlite3 *db = [self openDB];
    if (!db) return m;
    sqlite3_stmt *st;
    const char *sql = "SELECT bundle, COUNT(*) FROM notifications "
                      "WHERE bundle IS NOT NULL AND bundle <> '' "
                      "GROUP BY bundle ORDER BY COUNT(*) DESC";
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const char *t = (const char *)sqlite3_column_text(st, 0);
            if (!t) continue;
            NSString *bid = [NSString stringWithUTF8String:t];
            if (bid.length) m[bid] = @(sqlite3_column_int(st, 1));
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return m;
}

// v0.0.38：改成参数绑定。
// 🔴 不是因为 rowId 有注入面（它是整数，没有），而是因为 v0.0.33 在下面 `deleteRow:`
//    的注释里写着「一处拼串、一处绑参，以后有人把某个参数换成字符串时就会在拼串那处出事」
//    —— 同文件里注释和代码自相矛盾了五版。删除和标记都是「按 id 改一行」，
//    写法应该只有一种。
// v0.0.124：已读态的**唯一写入口**。`read` 绑参（不拼串），`rowId <= 0` 直接返回。
// 🔴 为什么两个 id 参数都用 `sqlite3_bind_int64`：`read` 在表里是 INTEGER，
//    但这里传的是 BOOL ⇒ 显式绑 1/0 比依赖 BOOL→int 的隐式转换安全
//    （BOOL 在 64 位下是 signed char，绑错类型不会报错，只会写进 0 或 1 之外的值）。
+ (void)setRead:(BOOL)read rowId:(NSInteger)rowId {
    if (rowId <= 0) return;
    sqlite3 *db = [self openDB];
    if (!db) return;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "UPDATE notifications SET read=? WHERE id=?", -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(st, 1, read ? 1 : 0);
        sqlite3_bind_int64(st, 2, (sqlite3_int64)rowId);
        if (sqlite3_step(st) != SQLITE_DONE) {
            // 日志带 `read=` 的值：标记"失败"本身不够，得知道当时想写成什么
            NBStoreLog(@"setRead 失败 id=%ld read=%d err=%s",
                       (long)rowId, (int)(read ? 1 : 0), sqlite3_errmsg(db));
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
}

+ (void)markRead:(NSInteger)rowId {
    [self setRead:YES rowId:rowId];
}

// v0.0.38：批量标记 / 批量计数的共用条件 → **v0.0.40 起并入 `NBPrepareScope`**。
// 保留这段注释是因为它立的两条规矩仍然有效，只是实现搬到了统一的那个函数里：
// 🔴 拼 WHERE 和绑参必须在同一个函数里，不能拆成「拼一个函数、绑一个函数」——
//    拆开就有"两边顺序不一致"的可能，而这类错不会报错，只会静默少筛一个条件。
// 🔴 两个调用方必须用同一套条件：界面上的确认文案报的是「将要改多少条」，
//    计数和实际改动只要有一点点不一样，就会出现"说改 5 条、实际改了 200 条"
//    （v0.0.35 的 `onClear:` 已经栽过一次：报列表 3 条、实际清整张表）。
+ (NSInteger)markAllReadWithBundle:(NSString * _Nullable)bundle since:(NSTimeInterval)since {
    sqlite3 *db = [self openDB];
    if (!db) return -1;
    NSInteger n = -1;
    // `WHERE read=0` 不只是优化：`sqlite3_changes` 数的是"真的被改写的行"，
    // 已经 read=1 的行不会重复计数 ⇒ 返回值正好是"这次标掉了多少条未读"。
    // 🔴 search 传 nil：搜索只影响列表显示，**不缩小标记范围**（确认文案里对用户承诺过）。
    //    v0.0.42 同理：`searchBundles` 也传 nil —— 就算搜索命中了某个 App 名，
    //    「全标已读」也不该因此缩小范围。
    sqlite3_stmt *st = NBPrepareScope(db, @"UPDATE notifications SET read=1 WHERE read=0",
                                      nil, bundle, since, nil, nil);
    if (st) {
        if (sqlite3_step(st) == SQLITE_DONE) n = (NSInteger)sqlite3_changes(db);
        sqlite3_finalize(st);
    } else {
        NBStoreLog(@"markAllRead 失败 err=%s", sqlite3_errmsg(db));
    }
    sqlite3_close(db);
    return n;
}

+ (NSInteger)unreadCountWithBundle:(NSString * _Nullable)bundle
                             since:(NSTimeInterval)since
                            search:(NSString * _Nullable)search
                     searchBundles:(NSArray<NSString *> * _Nullable)searchBundles {
    sqlite3 *db = [self openDB];
    if (!db) return -1;
    NSInteger n = -1;
    sqlite3_stmt *st = NBPrepareScope(db, @"SELECT COUNT(*) FROM notifications WHERE read=0",
                                      nil, bundle, since, search, searchBundles);
    if (st) {
        if (sqlite3_step(st) == SQLITE_ROW) n = (NSInteger)sqlite3_column_int64(st, 0);
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return n;
}

+ (NSInteger)unreadCountWithBundle:(NSString * _Nullable)bundle
                             since:(NSTimeInterval)since
                            search:(NSString * _Nullable)search {
    // v0.0.42：变成四参版本的薄封装（不带 App 名匹配）。
    // `updateHiddenUnread` 里「全库未读」那一问走的就是这里（search 恒为 nil）。
    return [self unreadCountWithBundle:bundle since:since search:search searchBundles:nil];
}

+ (NSInteger)unreadCountWithBundle:(NSString * _Nullable)bundle since:(NSTimeInterval)since {
    // v0.0.40：变成上面那个三参版本的薄封装。**不要**在这里另写一份 SQL ——
    // 那样又会出现"两处条件各写一遍"的老问题。
    return [self unreadCountWithBundle:bundle since:since search:nil];
}

+ (NSInteger)countWithBundle:(NSString * _Nullable)bundle
                       since:(NSTimeInterval)since
                      search:(NSString * _Nullable)search
               searchBundles:(NSArray<NSString *> * _Nullable)searchBundles
                  unreadOnly:(BOOL)unreadOnly {
    // v0.0.42：**当前筛选下的总条数**。
    // 🔴 和 `count`（全库不分筛选）是两件事，别混用。
    // 用途只有一个：底部「还有 N 条更早记录」= 本方法 − 列表里实际拿到的条数。
    // ⇒ 它必须和 `queryWithBundle:` 走**同一个** `NBPrepareScope`，
    //   否则会出现"列表已经到底了，底部还在说还有 3 条"。
    // v0.0.43：`unreadOnly` 必须一起传进来 —— 见 `NotifyStore.h` 里那条真机 bug。
    // 🔴 `head` 里带 `read=0`（而不是另加一个参数）就和 `queryWithBundle:` 一模一样了：
    //    那个方法也是靠 `head` 区分"只看未读"的。两边用同一种表达，才不会有一边漏改。
    sqlite3 *db = [self openDB];
    if (!db) return -1;
    NSInteger n = -1;
    NSString *head = unreadOnly
        ? @"SELECT COUNT(*) FROM notifications WHERE read=0"
        : @"SELECT COUNT(*) FROM notifications WHERE 1=1";
    sqlite3_stmt *st = NBPrepareScope(db, head, nil, bundle, since, search, searchBundles);
    if (st) {
        if (sqlite3_step(st) == SQLITE_ROW) n = (NSInteger)sqlite3_column_int64(st, 0);
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return n;
}

// v0.0.33：删单条。返回 YES = 真的删掉了（id 不存在 ⇒ NO，界面据此提示"这条已经没了"）。
// 🔴 用参数绑定而不是拼 SQL：rowId 虽然来自数据库（整数、无注入面），
//    但这里保持和 queryWithBundle 同一口径 —— 一处拼串、一处绑参，
//    以后有人把某个参数换成字符串时就会在拼串那处出事。
+ (BOOL)deleteRow:(NSInteger)rowId {
    // 🔴🔴 v0.0.84：**不许传 NULL**。`NotifyStore.h` 处在 `NS_ASSUME_NONNULL` 范围内，
    //    `NBSyncClearOutcome *outcome` 因此是隐式 `_Nonnull` —— 传 `NULL` 会被
    //    `-Werror,-Wnonnull` 当场判死（CI 首轮就是这么炸的：
    //    `NotifyStore.m:822:18: error: null passed to a callee that requires a non-null argument`）。
    //    用栈上的局部变量接住即可：既满足非空约定，也不必给形参加 `nullable` 注解
    //    （本项目自检第 10 道明令禁止 `_Nonnull`/`_Nullable` 出现在源码里）。
    NBSyncClearOutcome ignored = NBSyncClearDeleteFail;
    return [self deleteRow:rowId outcome:&ignored];
}

+ (BOOL)deleteRow:(NSInteger)rowId outcome:(NBSyncClearOutcome *)outcome {
    if (outcome) *outcome = NBSyncClearDeleteFail;
    sqlite3 *db = [self openDB];
    if (!db) return NO;
    BOOL ok = NO;

    // v0.0.52：删前读 bundle + sys_id（精确同步清通知中心用）。
    // 🔴 必须先读后删：删完就 SELECT 不到了。这两个值只在"开启同步清且 sys_id 非空"时才用到。
    // v0.0.85：多读 title / message —— tweak 侧在精确 ID 落空时要靠它们做「同段同内容只命中 1 条」
    //   的兜底匹配（见 `NB_KEY_CONTENT_FALLBACK` 的注释）。
    NSString *delBundle = nil;
    NSString *delSysId  = nil;
    NSString *delTitle  = nil;
    NSString *delMsg    = nil;
    {
        sqlite3_stmt *r = NULL;
        if (sqlite3_prepare_v2(db, "SELECT bundle, sys_id, title, message FROM notifications WHERE id=?",
                               -1, &r, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(r, 1, (sqlite3_int64)rowId);
            if (sqlite3_step(r) == SQLITE_ROW) {
                const char *b = (const char *)sqlite3_column_text(r, 0);
                const char *s = (const char *)sqlite3_column_text(r, 1);
                const char *t = (const char *)sqlite3_column_text(r, 2);
                const char *m = (const char *)sqlite3_column_text(r, 3);
                if (b) delBundle = [NSString stringWithUTF8String:b];
                if (s) delSysId  = [NSString stringWithUTF8String:s];
                if (t) delTitle  = [NSString stringWithUTF8String:t];
                if (m) delMsg    = [NSString stringWithUTF8String:m];
            }
            sqlite3_finalize(r);
        }
    }

    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "DELETE FROM notifications WHERE id=?", -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(st, 1, (sqlite3_int64)rowId);
        ok = (sqlite3_step(st) == SQLITE_DONE) && (sqlite3_changes(db) > 0);
        sqlite3_finalize(st);
    }
    if (!ok) NBStoreLog(@"DELETE 未删到 id=%ld err=%s", (long)rowId, sqlite3_errmsg(db));
    sqlite3_close(db);

    // 🔴 删成功 + 开启同步清 + sys_id 非空 ⇒ 请求 tweak 把系统通知中心**那一条**也清掉。
    //    放在 `sqlite3_close(db)` **之后**：请求文件用独立 writeToFile，不依赖这个 db 句柄；
    //    且保证"记录确实从库里没了"才去清通知中心，避免"库没删成却把通知中心清了"的错位。
    //    delBundle 也一并要求非空：sectionID 必须和 bulletinID 成对，否则 _clearBulletinIDs: 无效。
    // v0.0.84：三道闸逐个记结论，别让它静默。
    if (!ok) {
        if (outcome) *outcome = NBSyncClearDeleteFail;
    } else if (!delSysId.length) {
        if (outcome) *outcome = NBSyncClearNoSysId;
    } else if (!delBundle.length) {
        if (outcome) *outcome = NBSyncClearNoBundle;
    } else {
        NSDictionary *p = NBLoadSettings();
        if (![p[NB_KEY_SYNC_CLEAR] boolValue]) {
            if (outcome) *outcome = NBSyncClearOff;
        } else {
            [self nbRequestClearNCWithSysId:delSysId bundle:delBundle
                                      title:delTitle message:delMsg];
            if (outcome) *outcome = NBSyncClearRequested;
        }
    }
    return ok;
}

// ---------- v0.0.84：历史重复一次性合并 ----------
// 🔴🔴 顺序必须「先数、再删、再复核」，不能一把 DELETE 了事：
//    ① 先 `SELECT COUNT(*)` 拿到"会删多少行"，作为**期望值**；
//    ② 删完查 `sqlite3_changes()`，和期望值对不上就记日志（说明有并发写），
//       但**不回滚**（删的都是同 sys_id 的冗余行，少删多删都不影响正确性）；
//    ③ 最后整表复核一次剩余重复组数。
// 🔴 为什么不用 `NOT IN (SELECT MAX(id) …)` 一把梭：这个库**两个进程都在写**
//    （SpringBoard 记通知、盒子 App 删记录），子查询和 DELETE 之间可能被插入新行，
//    虽然结果仍然正确，但 `changes()` 对不上时无从解释。分两步至少能说清发生了什么。
// 🔴 绝不动 `sys_id` 为空/NULL 的行 —— 空串相同 ≠ 同一条通知。
+ (NSInteger)dedupeBySysId {
    sqlite3 *db = [self openDB];
    if (!db) return 0;
    NSInteger expect = 0, removed = 0;
    @try {
        const char *cnt = "SELECT IFNULL(SUM(c-1),0) FROM ("
                          "SELECT sys_id, COUNT(*) c FROM notifications "
                          "WHERE sys_id IS NOT NULL AND sys_id<>'' "
                          "GROUP BY sys_id HAVING c>1);";
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, cnt, -1, &st, NULL) == SQLITE_OK) {
            if (sqlite3_step(st) == SQLITE_ROW) expect = sqlite3_column_int(st, 0);
            sqlite3_finalize(st);
        }
        if (expect > 0) {
            const char *del = "DELETE FROM notifications WHERE sys_id IS NOT NULL "
                              "AND sys_id<>'' AND id NOT IN ("
                              "SELECT MAX(id) FROM notifications WHERE sys_id IS NOT NULL "
                              "AND sys_id<>'' GROUP BY sys_id);";
            if (sqlite3_exec(db, del, NULL, NULL, NULL) == SQLITE_OK) {
                removed = sqlite3_changes(db);
            }
            NBStoreLog(@"合并重复：期望 %ld 行，实际删掉 %ld 行", (long)expect, (long)removed);
        }
    } @catch (__unused NSException *e) { }
    sqlite3_close(db);
    return removed;
}

// v0.0.52：把"要清哪一条"写进共享请求文件，再 post Darwin 通知唤醒 tweak。
// 🔴 文件用**覆盖写**：手动逐条删几乎不会竞态；批量清理 / 清空全部不触发本通道（见 deleteWithBundle:/clearAll）。
// 🔴 整段 @try：这步只是"发个请求"，任何失败都不该影响"盒子记录已经删掉"这个结果。
+ (void)nbRequestClearNCWithSysId:(NSString *)sysId bundle:(NSString *)bundle
                            title:(NSString *)title message:(NSString *)message {
    @try {
        // 🔴 v0.0.85：多带 title / message 两个键。理由见 `backfillSysId` 头注释：
        //   系统重投同一条通知会分配新 ID，精确 ID 匹配必然落空；
        //   tweak 侧要靠「同段 + 同 title + 同 message 且只命中 1 条」兜底。
        //   没有这两个键，那条兜底路径就只能是猜。
        NSDictionary *req = @{@"sysId": sysId ?: @"", @"bundle": bundle ?: @"",
                              @"title": title ?: @"", @"message": message ?: @""};
        [[NSFileManager defaultManager] createDirectoryAtPath:
            [NOTIFYBOX_NC_CLEAR_REQ stringByDeletingLastPathComponent]
                                     withIntermediateDirectories:YES attributes:nil error:nil];
        [req writeToFile:NOTIFYBOX_NC_CLEAR_REQ atomically:YES];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.yxh41.notifybox.ncClear"),
                                             NULL, NULL, TRUE);
        NBStoreLog(@"NC-CLEAR 已请求 sysId=%@ bundle=%@ title=%@", sysId, bundle, title);
    } @catch (NSException *e) {
        NBStoreLog(@"NC-CLEAR 请求失败：%@", e);
    }
}

#pragma mark - v0.0.45 批量删除

// 🔴 删除的 WHERE **故意不复用** `NBPrepareScope`。
//    那一份是"列表筛选"（bundle + 时间**下界** + 搜索词 + 未读），
//    这一份是"删除范围"（bundle + 时间**上界** + 只读已读）。两组量的语义就不同
//    （一个要新于、一个要旧于），硬凑一份只会让两边都难改。
//    ⇒ 同理，删除**故意不含搜索词**：搜索只决定列表显示什么，不缩小清理范围
//    （v0.0.38 在 `markAllRead` 上对用户承诺过这条口径，这里必须一致）。
static sqlite3_stmt *NBPrepareDelete(sqlite3 *db, NSString *bundle, NSTimeInterval beforeTs,
                                     BOOL readOnly, BOOL forCount) {
    NSMutableString *sql = [NSMutableString string];
    // `WHERE 1=1` 让后面每个条件都能一律写成 `AND ...`，不用判断"是第一个条件吗"。
    [sql appendString:forCount ? @"SELECT COUNT(*) FROM notifications WHERE 1=1"
                               : @"DELETE FROM notifications WHERE 1=1"];
    if (bundle.length) [sql appendString:@" AND bundle=?"];
    if (beforeTs > 0)  [sql appendString:@" AND ts<?"];
    if (readOnly)      [sql appendString:@" AND read=1"];
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &st, NULL) != SQLITE_OK) {
        // 🔴 v0.0.141：同 NBRows —— 静默返回 NULL 会让「删不掉」看起来像「本来就没有」。
        NSLog(@"[NotifyBox/store] ⚠️ 删除语句 prepare 失败 err=%s sql=%@",
              sqlite3_errmsg(db), sql);
        NBStoreLog(@"删除语句 prepare 失败 err=%s sql=%@", sqlite3_errmsg(db), sql);
        return NULL;
    }
    // 🔴 绑参顺序必须和上面 append 的顺序逐条对应（少绑一条不会报错，
    //    SQLite 把没绑的参数当 NULL ⇒ 条件恒不成立 ⇒ 静默删了个空）。
    int i = 1;
    if (bundle.length) sqlite3_bind_text(st, i++, [bundle UTF8String], -1, SQLITE_TRANSIENT);
    if (beforeTs > 0)  sqlite3_bind_double(st, i++, (double)beforeTs);
    return st;
}

+ (NSInteger)countForDeleteWithBundle:(NSString *)bundle
                             beforeTs:(NSTimeInterval)beforeTs
                             readOnly:(BOOL)readOnly {
    // 🔴🔴 三个条件全空 = 删整张表。这**不是**"批量清理"该触发的动作
    //    （清空有专门的 `clearAll`，确认文案是另一套）。
    //    ⇒ 这里直接拒绝、返回 -2。宁可让调用方多走一步，也不要留一条
    //      "参数拼错了就清空用户所有记录"的路 —— 这是真账本，删了没有回头路。
    if (!bundle.length && beforeTs <= 0 && !readOnly) return -2;
    sqlite3 *db = [self openDB];
    if (!db) return -1;
    NSInteger n = -1;
    sqlite3_stmt *st = NBPrepareDelete(db, bundle, beforeTs, readOnly, YES);
    if (st) {
        if (sqlite3_step(st) == SQLITE_ROW) n = (NSInteger)sqlite3_column_int(st, 0);
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return n;
}

+ (NSInteger)deleteWithBundle:(NSString *)bundle
                     beforeTs:(NSTimeInterval)beforeTs
                     readOnly:(BOOL)readOnly {
    // 🔴 v0.0.52：批量删除**不触发**同步清通知中心。
    //    本方法一次可能删成百上千条，"逐条写请求文件 + post Darwin"既无必要也危险
    //    （共享请求文件是单文件、会被覆盖；且一次清上千条通知中心不符合"精确 1:1"的语义）。
    //    同步清只服务于"手动删单条记录"这一个路径（见 deleteRow:）。
    if (!bundle.length && beforeTs <= 0 && !readOnly) return -2;   // 同上，拒绝无条件全删
    sqlite3 *db = [self openDB];
    if (!db) return -1;
    NSInteger n = -1;
    sqlite3_stmt *st = NBPrepareDelete(db, bundle, beforeTs, readOnly, NO);
    if (st) {
        if (sqlite3_step(st) == SQLITE_DONE) {
            // 🔴 必须查 `sqlite3_changes()`：`DELETE` 命中 0 行照样返回 SQLITE_DONE，
            //    不查的话"条件写错了删了个空"和"删掉了 800 条"在界面上长得一样。
            n = (NSInteger)sqlite3_changes(db);
        } else {
            NBStoreLog(@"批量删除失败 err=%s", sqlite3_errmsg(db));
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return n;
}

// v0.0.35：返回真正删掉的条数（-1 = DB 打不开）。
// 🔴 `sqlite3_changes` 必须在 `exec` 之后、**任何别的语句之前**取 ——
//    它是"最近一条语句改了 N 行"，插一句别的就串了。
// 🔴 v0.0.52：清空全部**不触发**同步清通知中心。理由同 deleteWithBundle: ——
//    这是"清空我的盒子日志"，不是"清空系统通知中心"；且批量场景不该逐条发请求。
+ (NSInteger)clearAll {
    sqlite3 *db = [self openDB];
    if (!db) return -1;
    NSInteger n = -1;
    if (sqlite3_exec(db, "DELETE FROM notifications", NULL, NULL, NULL) == SQLITE_OK) {
        n = (NSInteger)sqlite3_changes(db);
    } else {
        NBStoreLog(@"clearAll 失败 err=%s", sqlite3_errmsg(db));
    }
    sqlite3_close(db);
    return n;
}

+ (NSDictionary *)settings {
    return NBLoadSettings();
}

+ (BOOL)saveSettings:(NSDictionary *)settings {
    [self ensureDir];       // settings.plist 与 DB 同目录，目录建好就能写
    return [(settings ?: @{}) writeToFile:NOTIFYBOX_SETTINGS_PATH atomically:YES];
}

#pragma mark - v0.0.47 自动清理（保留最近 N 天）

+ (NSInteger)autoCleanDays {
    NSDictionary *p = NBLoadSettings();
    id v = p[@"autoCleanDays"];
    NSInteger n = v ? [v integerValue] : 0;
    // 🔴 0 = 关闭；上限 3650 天（10 年）—— 超出当关闭，避免手滑填个天文数字把库清空。
    return (n >= 0 && n <= 3650) ? n : 0;
}

+ (void)setAutoCleanDays:(NSInteger)days {
    NSMutableDictionary *d = [[self settings] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (days > 0 && days <= 3650) d[@"autoCleanDays"] = @(days);
    else [d removeObjectForKey:@"autoCleanDays"];
    [self saveSettings:d];
}

+ (NSInteger)runAutoClean {
    NSInteger days = [self autoCleanDays];
    if (days <= 0) return 0;   // 关闭 ⇒ 什么都不做，也不打日志（避免每次启动刷屏）
    NSTimeInterval cutoff = [[NSDate date] timeIntervalSince1970] - (NSTimeInterval)days * 86400.0;
    // 🔴 复用 v0.0.45 的批量删除：bundle=nil（所有 App）、readOnly=NO（连未读一起删，
    //    因为"保留最近 N 天"的语义就是"更老的都不要了"）。
    NSInteger n = [self deleteWithBundle:nil beforeTs:cutoff readOnly:NO];
    if (n > 0) {
        NBStoreLog(@"自动清理：删掉 %ld 天前的 %ld 条（cutoff=%.0f）", (long)days, (long)n, cutoff);
    }
    return n;
}

#pragma mark - v0.0.48 关键词自动规则（展示时生效）

// 大小写不敏感子串包含，nil/空安全。
// 🔴 中文无大小写，但英文关键词（如 "verify" / "code"）必须忽略大小写，
//    否则用户填小写规则命中不到大写的 "VERIFY"。
static BOOL NBContainsText(NSString *hay, NSString *needle) {
    if (!hay.length || !needle.length) return NO;
    return [hay rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

+ (NSArray<NSDictionary *> *)keywordRules {
    NSDictionary *p = NBLoadSettings();
    NSArray *raw = p[@"keywordRules"];
    if (![raw isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id item in raw) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *kw = item[@"keyword"];
        if (![kw isKindOfClass:[NSString class]] || !kw.length) continue;
        [out addObject:@{ @"keyword": kw,
                          @"star": @([item[@"star"] boolValue]),
                          @"fold": @([item[@"fold"] boolValue]) }];
        if (out.count >= 20) break;   // 🔴 上限 20 条（和设置页的闸门同一数字）
    }
    return out;
}

+ (BOOL)saveKeywordRules:(NSArray<NSDictionary *> *)rules {
    NSMutableArray *clean = [NSMutableArray array];
    for (id item in rules ?: @[]) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *kw = item[@"keyword"];
        if (![kw isKindOfClass:[NSString class]] || !kw.length) continue;
        BOOL star = [item[@"star"] boolValue];
        BOOL fold = [item[@"fold"] boolValue];
        // 🔴 两个动作都没选的规则是死的（命中什么也不做）⇒ 存进去只会让用户以为设了。
        if (!star && !fold) continue;
        [clean addObject:@{ @"keyword": kw, @"star": @(star), @"fold": @(fold) }];
        if (clean.count >= 20) break;
    }
    NSMutableDictionary *d = [[self settings] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (clean.count) d[@"keywordRules"] = clean;
    else [d removeObjectForKey:@"keywordRules"];   // 全删干净 ⇒ 键也消失，不留空数组
    return [self saveSettings:d];
}

+ (NBKeywordAction)keywordActionForTitle:(NSString *)title
                                 message:(NSString *)message
                                subtitle:(NSString *)subtitle
                                 appName:(NSString *)appName {
    NSArray *rules = [self keywordRules];
    if (!rules.count) return NBKeywordActionNone;
    NSUInteger action = NBKeywordActionNone;
    for (NSDictionary *r in rules) {
        NSString *kw = r[@"keyword"];
        if (!kw.length) continue;
        BOOL hit = NBContainsText(title, kw) || NBContainsText(message, kw)
                || NBContainsText(subtitle, kw) || NBContainsText(appName, kw);
        if (!hit) continue;
        // 🔴 一条规则可同时标星+折叠；多条规则可叠加（星来自 A、折叠来自 B）。
        if ([r[@"star"] boolValue])  action |= NBKeywordActionStar;
        if ([r[@"fold"] boolValue])  action |= NBKeywordActionFold;
    }
    return action;
}

+ (NSInteger)count {
    sqlite3 *db = [self openDB];
    if (!db) return -1;
    NSInteger n = -1;
    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM notifications", -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int(st, 0);
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return n;
}

// v0.0.38：给「列表要不要重查」当探针。空表返回 0，DB 打不开返回 -1。
// 🔴 `IFNULL(MAX(id),0)`：空表时 `MAX(id)` 是 NULL，`sqlite3_column_int64` 读 NULL 也回 0，
//    但显式写 IFNULL 是为了让"0 = 空表"这件事在 SQL 里就说清楚，而不是靠 C 层的巧合。
+ (NSInteger)maxRowId {
    sqlite3 *db = [self openDB];
    if (!db) return -1;
    NSInteger n = 0;
    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(db, "SELECT IFNULL(MAX(id),0) FROM notifications",
                           -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) n = (NSInteger)sqlite3_column_int64(st, 0);
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return n;
}

+ (void)markAppAlive {
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NBStoreLog(@"[APP-ALIVE] 盒子App 启动 v%@ · 说明此路径本 App 可写", ver);
}

// v0.0.137：把「某个位置的装载标记」打出来，返回其内容（没有就 nil）。
// 🔴 为什么单独一个函数、而不是在 envCheck 里写一遍：
//    现在有**三个**位置要查（老路径的 SpringBoard 标记、老路径的 root 标记、App 容器的旧标记），
//    每个位置的判据必须**各自独立打印**。上一版只查了「当前数据目录」这一处 ⇒
//    把「tweak 记到别处去了」误报成「tweak 从未注入」，方向错了整整一天。
static NSString *NBAppendMarker(NSMutableString *s, NSString *label, NSString *path) {
    if (!path.length) {
        [s appendFormat:@"  ❔ %@：本进程算不出这个路径\n", label];
        return nil;
    }
    NSFileManager *fm2 = [NSFileManager defaultManager];
    NSDictionary *a = [fm2 attributesOfItemAtPath:path error:nil];
    NSString *txt = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding error:nil];
    NSString *t = [txt stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 🔴 三态必须分清，不许合并：「读到内容」「文件在但读不出」「不存在」是三件事。
    //   上一版把前两个并成「不存在」⇒ 直接把排查方向带偏一整天。
    if (txt != nil) {
        [s appendFormat:@"  ✅ %@\n     %@\n     %@\n", label, path,
            t.length ? t : @"（文件存在但内容为空）"];
        return t.length ? t : nil;
    }
    if (a) {   // 文件在、但内容读不出（0 字节 / 权限）
        [s appendFormat:@"  ⚠️ %@\n     %@\n     文件在但内容读不出（%llu B）\n", label, path,
            [a[NSFileSize] unsignedLongLongValue]];
        return nil;
    }
    [s appendFormat:@"  ❌ %@ 不存在\n     %@\n", label, path];
    return nil;
}

// v0.0.144：环境自检里「payload 到底卡在哪」的三个量。
// 🔴 为什么非要在这里量（而不是去看日志）：
//    「长按直达」这个功能的失败形态是「长按只有『打开』、没有『直达』」，
//    而它和「这条通知本来就没链接」在屏幕上**长得一模一样**。三条完全不同的故障
//    （① 列根本没建上 ② 建上了但一条都没抓到 ③ 抓到了但 App 侧认不出链接）
//    必须能在**同一屏**上区分开，否则又是一轮「猜一个改一版」。
// 🔴 返回 -1 表示**没算出来**，绝不能返回 0 冒充「零条」（§4.17）。
static long NBEnvCount(sqlite3 *db, const char *sql) {
    if (!db || !sql) return -1;
    sqlite3_stmt *st = NULL;
    long n = -1;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) n = (long)sqlite3_column_int64(st, 0);
        sqlite3_finalize(st);
    }
    return n;
}

// 最新一条**非空** payload。全是 NULL/空串时返回 nil（= 还没抓到过任何一条）。
static NSString *NBEnvPayloadSample(sqlite3 *db) {
    if (!db) return nil;
    sqlite3_stmt *st = NULL;
    NSString *out = nil;
    if (sqlite3_prepare_v2(db,
            "SELECT payload FROM notifications "
            "WHERE payload IS NOT NULL AND payload<>'' ORDER BY ts DESC LIMIT 1;",
            -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_type(st, 0) == SQLITE_TEXT) {
            const char *p = (const char *)sqlite3_column_text(st, 0);
            if (p) out = [NSString stringWithUTF8String:p];
        }
        sqlite3_finalize(st);
    }
    return out;
}

// v0.0.145：「样本里有没有链接」必须**先反转义再判**。
// 🔴 这是 v0.0.144 那次真机自证里抓到的一把坏尺子：
//    样本是 `{"action":"sms:\/\/open?groupid=…(smsft)"}` —— 明明有链接，
//    我的判据在原始文本里找 `://` 却恒不命中，报了个「否」。
//    原因：库里存的是 JSON，`/` 被序列化成了 `\/`。
//    ⇒ 三态输出，把「原文就含」与「反转义后才含」分开 —— 后者正是本次的真身，
//      合并成一个「是」就把"我的判据要反转义"这条信息抹掉了。
static NSString *NBEnvLinkState(NSString *payload) {
    if (![payload isKindOfClass:[NSString class]] || !payload.length) return @"(无样本)";
    if ([payload rangeOfString:@"://"].location != NSNotFound) return @"是·原文";
    NSString *un = [payload stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
    if (un && [un rangeOfString:@"://"].location != NSNotFound) return @"是·反转义后";
    return @"否";
}

// 最近 N 条里带 payload 的条数 —— 这是把「5/500」拆开的唯一判据。
// 🔴 为什么非要它：`5/500` 有两种完全相反的解释 ——
//    ① 现在抓得挺好，那 495 条是**加列之前的库存**（永久补不回来，正常）；
//    ② 现在也只抓得到 1%（真故障）。
//    只看总数永远分不开；只看「最新一条」又会被一条巧合骗到。
//    `ts DESC LIMIT N` 问的是"**最近这批**里命中多少"，直接回答"现在还在抓吗"。
static long NBEnvPayloadRecent(sqlite3 *db, int n) {
    if (!db || n <= 0) return -1;
    // 用 NSString 拼而不是 char[256]+snprintf：SQL 一长就容易悄悄截断，
    // 而截断后的 SQL 语法错 ⇒ prepare 失败 ⇒ 返回 -1，看起来像"库有问题"。
    NSString *sql = [NSString stringWithFormat:
        @"SELECT COUNT(*) FROM (SELECT payload FROM notifications "
        @"ORDER BY ts DESC LIMIT %d) WHERE payload IS NOT NULL AND payload<>'';", n];
    return NBEnvCount(db, [sql UTF8String]);
}

// 带 payload 的记录：条数、时间跨度、最新那条是谁。
// 一次返回字典而不是三个函数：它们来自同一个"有 payload 的子集"，
// 分成三个出口就会出现"三条读数各自成立、合起来却矛盾"（§4.6 那类自欺）。
static NSDictionary *NBEnvPayloadStats(sqlite3 *db) {
    if (!db) return nil;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db,
            "SELECT COUNT(*), MIN(ts), MAX(ts) FROM notifications "
            "WHERE payload IS NOT NULL AND payload<>'';", -1, &st, NULL) != SQLITE_OK) {
        return nil;
    }
    if (sqlite3_step(st) == SQLITE_ROW) {
        d[@"count"] = @((long long)sqlite3_column_int64(st, 0));
        if (sqlite3_column_type(st, 1) != SQLITE_NULL) d[@"minTs"] = @(sqlite3_column_double(st, 1));
        if (sqlite3_column_type(st, 2) != SQLITE_NULL) d[@"maxTs"] = @(sqlite3_column_double(st, 2));
    }
    sqlite3_finalize(st);
    if (sqlite3_prepare_v2(db,
            "SELECT bundle,title FROM notifications WHERE payload IS NOT NULL AND payload<>'' "
            "ORDER BY ts DESC LIMIT 1;", -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) {
            const char *b = (const char *)sqlite3_column_text(st, 0);
            const char *t = (const char *)sqlite3_column_text(st, 1);
            if (b) d[@"bundle"] = [NSString stringWithUTF8String:b];
            if (t) d[@"title"] = [NSString stringWithUTF8String:t];
        }
        sqlite3_finalize(st);
    }
    return d;
}

static NSString *NBEnvClock(double ts) {
    if (ts <= 0) return @"?";
    static NSDateFormatter *f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"MM-dd HH:mm";
    });
    return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]];
}

// ───── v0.0.156：旧位置（App 容器）装载标记 —— App 侧只读「代读记录」 ─────
// 🔴 为什么不再自己算路径：App 带 no-container ⇒ 无容器 ⇒ 路径恒算不出 ⇒ 死探针。
//    真相由 root 进程写进 `数据目录/.old_location`（见 NBWriteOldLocationProbe）。
// 🔴 四态，一个都不许合并（合并的代价就是上一版那种「一条信息都不含」的行）：
//    ① 有记录 + 标记在   ⇒ 返回标记正文（调用方据此判 split-brain）
//    ② 有记录 + 标记不在 ⇒ 正常（没有残留）
//    ③ 有记录但解析不出路径 ⇒ 记录坏了，如实说「坏了」，不许退化成 ②
//    ④ 没记录 ⇒ **「读不到」而不是「不存在」**（tweak 侧可能也扫不到，或还没重启过）
static NSString *NBAppendOldLocation(NSMutableString *s, BOOL *seenOut) {
    if (seenOut) *seenOut = NO;
    NSString *fp = [NOTIFYBOX_LEGACY_DIR stringByAppendingPathComponent:@".old_location"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *a = [fm attributesOfItemAtPath:fp error:nil];
    NSString *txt = [NSString stringWithContentsOfFile:fp
                                             encoding:NSUTF8StringEncoding error:nil];
    if (!txt.length) {
        if (a) {
            [s appendFormat:@"  ⚠️ 旧位置（App 容器）：代读记录在但读不出（%llu B）\n",
                [a[NSFileSize] unsignedLongLongValue]];
        } else {
            [s appendString:@"  ❔ 旧位置（App 容器）：没有代读记录 ⇒ **读不到，不是不存在**\n"
                          @"     （App 自己没有容器、算不出这个路径；记录由 root 进程在 ctor 写）\n"];
        }
        return nil;
    }
    // 记录格式固定「一行一个键」，逐行取第一个 `=` 切开（值里可能还有 `=`，只切第一处）
    NSMutableDictionary *kv = [NSMutableDictionary dictionary];
    for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
        NSRange r = [line rangeOfString:@"="];
        if (r.location == NSNotFound || r.location == 0) continue;
        NSString *k = [line substringToIndex:r.location];
        NSString *v = [line substringFromIndex:r.location + 1];
        if (k.length && v.length) kv[k] = v;
    }
    NSString *proc = kv[@"proc"] ?: @"?";
    NSString *path = kv[@"path"];
    if (!path.length) {
        [s appendFormat:@"  ⚠️ 旧位置（App 容器）：代读记录在但没解析出路径（proc=%@）\n", proc];
        return nil;
    }
    if (seenOut) *seenOut = YES;
    BOOL marker = [kv[@"markerExists"] isEqualToString:@"1"];
    BOOL dirOK  = [kv[@"dirExists"] isEqualToString:@"1"];
    [s appendFormat:@"  %@ 旧位置（由 %@ 代读于 %@）\n     %@\n",
        marker ? @"⚠️" : @"✅", proc,
        NBEnvClock([(NSString *)kv[@"ts"] doubleValue]), path];
    if (!dirOK) {
        [s appendString:@"     目录不在（App 从没在该容器里跑过 ⇒ 无残留）\n"];
        return nil;
    }
    if (!marker) {
        [s appendString:@"     .tweak_ctor 不在（没有 split-brain 残留）\n"];
        return nil;
    }
    NSString *t = kv[@"marker"];
    if (t.length) {
        [s appendFormat:@"     .tweak_ctor 在：%@\n", t];
        return t;
    }
    // 标记文件在、但内容读不出（0 字节 / 权限）—— 又说了一遍「三态不许合并」
    [s appendFormat:@"     .tweak_ctor 在但内容读不出（%@）\n",
        kv[@"markerUnreadable"] ? [NSString stringWithFormat:@"%@ B", kv[@"markerUnreadable"]]
                                : @"原因未知"];
    return @"(标记在、内容读不出)";
}

+ (NSString *)envCheck {
    NSMutableString *s = [NSMutableString string];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NOTIFYBOX_DB_PATH stringByDeletingLastPathComponent];

    [s appendFormat:@"── 路径 ──\n目录 %@（v0.0.137 起是**常量**，两个进程必然一致）\n", dir];
    BOOL dirExists = [fm fileExistsAtPath:dir];
    [s appendFormat:@"  存在=%@  可写=%@\n", dirExists ? @"是" : @"否",
        [fm isWritableFileAtPath:dir] ? @"是" : @"否"];
    // 🔴 v0.0.137：**属主单列一行**。
    //   「存在 / 可读 / 可写」是**一个事实说三遍**（目录不在，后两个必然否），
    //   看着像三条证据、其实只有一条 —— 上一轮真机排查就是被它带偏的。
    //   属主才是那个独立信息量：不是 501:501 就直接指向「被 root 进程占过」。
    struct stat dst; memset(&dst, 0, sizeof(dst));
    BOOL hasSt = (stat([dir fileSystemRepresentation], &dst) == 0);
    [s appendFormat:@"  属主=%d:%d（应为 501:501）\n",
        hasSt ? (int)dst.st_uid : -1, hasSt ? (int)dst.st_gid : -1];
    if (!dirExists) {
        NSError *e = nil;
        BOOL ok = [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&e];
        [s appendFormat:@"  尝试创建=%@  err=%@\n", ok ? @"成功" : @"失败",
            e ? [NSString stringWithFormat:@"%ld/%@", (long)e.code, e.localizedDescription] : @"-"];
    }

    // 实测写入：失败时才报 errno
    // 🔴 成功路径上 errno 也可能残留非 0（writeToFile:atomically: 内部会先写临时文件）。
    //    之前把「写入测试=成功」和「errno=2」并排显示，读者会以为失败 —— 判据措辞本身要准。
    NSString *probe = [dir stringByAppendingPathComponent:@".probe"];
    NSData *pd = [@"probe" dataUsingEncoding:NSUTF8StringEncoding];
    errno = 0;
    BOOL wok = [pd writeToFile:probe atomically:YES];
    int e1 = errno;
    if (wok) {
        [s appendString:@"  写入测试=成功\n"];
        [fm removeItemAtPath:probe error:nil];
    } else {
        [s appendFormat:@"  写入测试=失败  errno=%d(%s)\n", e1, strerror(e1)];
    }

    [s appendFormat:@"\n── DB ──\n%@\n", NOTIFYBOX_DB_PATH];
    NSDictionary *da = [fm attributesOfItemAtPath:NOTIFYBOX_DB_PATH error:nil];
    [s appendFormat:@"  存在=%@  大小=%llu B  记录数=%ld\n",
        [fm fileExistsAtPath:NOTIFYBOX_DB_PATH] ? @"是" : @"否",
        [da[NSFileSize] unsignedLongLongValue], (long)[self count]];

    // 🔴 记录数被 maxRecords 顶在上限时，「数」是死的（永远等于上限），看不出还在不在收。
    //    「最新一条的时间」才看得出 —— 这也是判断「是不是早就断了」的唯一硬指标。
    NSTimeInterval latest = 0;
    // v0.0.144：payload（长按直达）的三个量，跟着这一次 openDB **一起量**。
    //   `plCol` 三态：在 / 不在（带 SQLite 原话）/ 打不开库 —— 三者不许合并。
    long plTotal = -1, plHave = -1, plRecent20 = -1, plLink = -1;
    NSString *plCol = @"打不开库";
    NSString *plSample = nil;
    NSDictionary *plStats = nil;
    sqlite3 *ldb = [self openDB];
    if (ldb) {
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(ldb, "SELECT MAX(ts) FROM notifications;", -1, &st, NULL) == SQLITE_OK) {
            if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_type(st, 0) != SQLITE_NULL) {
                latest = sqlite3_column_double(st, 0);
            }
            sqlite3_finalize(st);
        }
        // ① 列在不在：**故意用 prepare 试，而不是查 PRAGMA** ——
        //    INSERT 走的就是 prepare，能让每条通知被丢掉的是这条判定；
        //    `openDB` 里那次 PRAGMA+ALTER 是"尽力补上"，补没补上要看这里。
        sqlite3_stmt *cs = NULL;
        if (sqlite3_prepare_v2(ldb, "SELECT payload FROM notifications LIMIT 1;",
                               -1, &cs, NULL) == SQLITE_OK) {
            sqlite3_finalize(cs);
            plCol = @"在";
            // ② 分子分母一起给：只有分子（0）分不清「一条都没抓到」与「压根没记录」。
            plTotal  = NBEnvCount(ldb, "SELECT COUNT(*) FROM notifications;");
            plHave   = NBEnvCount(ldb, "SELECT COUNT(*) FROM notifications "
                                       "WHERE payload IS NOT NULL AND payload<>'';");
            // ③ 最新一条样本：它同时回答「抓到了什么形状」与「App 侧能不能认出链接」，
            //    是这三问里信息量最大的一条。
            plSample = NBEnvPayloadSample(ldb);
            // ④ v0.0.145：「5 / 500 到底是库存还是抓不到」—— 只能靠最近这批来分。
            plRecent20 = NBEnvPayloadRecent(ldb, 20);
            plStats    = NBEnvPayloadStats(ldb);
            // ⑤ 🔴 v0.0.147：**这才是产品的真指标** —— payload 里真的含链接的条数。
            //   v0.0.146 的真机账：泛扫让「有 payload 的记录」从 5/500 变成全表，
            //   但收到的只有 `title,message`（数据库里本来就有的列）⇒ 指标好看、功能零进展。
            //   `LIKE '%:\/%'` 那条是必需的：JSON 序列化会把 `/` 写成 `\/`。
            //   SQLite 的 LIKE 默认没有转义符，反斜杠就是普通字符，不用 ESCAPE。
            plLink = NBEnvCount(ldb, "SELECT COUNT(*) FROM notifications "
                                     "WHERE payload LIKE '%://%' OR payload LIKE '%:\\/%';");
        } else {
            // 🔴 先把 errmsg 拷成 NSString 再看：下一次任何 sqlite 调用都会覆盖内部缓冲。
            const char *m = sqlite3_errmsg(ldb);
            NSString *mm = m ? [NSString stringWithUTF8String:m] : @"(null)";
            plCol = [NSString stringWithFormat:@"不在（%@）", mm];
        }
        sqlite3_close(ldb);
    }
    if (latest > 0) {
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:latest];
        NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:d];
        [s appendFormat:@"  最新一条=%@  （%.0f 分钟前）\n",
            d, age / 60.0];
    } else {
        [s appendString:@"  最新一条=(读不到)\n"];
    }

    // ── payload：长按「直达内容页」的唯一线索 ──
    // 🔴 判定表（照这一屏就能定死病因，不用连电脑）：
    //    列=不在                        ⇒ 走「补列」，功能与记录**都不该**受影响
    //    列=在，最近 20 条里 0 条       ⇒ tweak 侧现在也抓不到 ⇒ 看 `[payload现场]` 的结构 dump
    //    列=在，最近 20 条里大半有      ⇒ 抓取正常，那批 0 的只是**加列之前的库存**
    //    🔴 **「有 payload」多而「含链接」少** ⇒ 收到的都是 title/message 这种冗余列，
    //       指标好看但功能零进展（v0.0.146 真机就是这个形态）⇒ 看「含链接」那一行才有意义
    //    含链接 > 0                     ⇒ 平台该显示「直达」；若仍显示「打开」= App 侧解析问题
    [s appendString:@"\n── payload（长按直达）──\n"];
    [s appendFormat:@"  列=%@   有 payload 的记录=%ld / %ld\n", plCol, plHave, plTotal];
    if (plTotal < 0) {
        [s appendString:@"  ⚠️ 分子分母是 -1 = **没算出来**（不是 0 条）⇒ 先解决上面那条\n"];
    }
    // 🔴 这一行是本版的核心判据：「5/500」分不开库存与故障，最近 20 条能。
    [s appendFormat:@"  最近 20 条里有 payload 的 = %ld 条\n", plRecent20];
    [s appendFormat:@"  其中**含链接**的 = %ld 条（这才是「直达」用得上的）\n", plLink];
    if (plStats) {
        NSNumber *cnt = plStats[@"count"];
        NSNumber *mn  = plStats[@"minTs"];
        NSNumber *mx  = plStats[@"maxTs"];
        if (cnt) {
            [s appendFormat:@"  带 payload 的 %@ 条，时间 %@ ~ %@\n",
                cnt, NBEnvClock(mn ? mn.doubleValue : 0), NBEnvClock(mx ? mx.doubleValue : 0)];
        }
        // 「最新一条带 payload 的是谁」——用来在列表里**定位到那张卡**，
        // 让"长按看菜单标题"这件事有个明确的靶子，而不是让用户随便挑一条试。
        NSString *bid2 = plStats[@"bundle"] ?: @"?";
        NSString *ttl  = plStats[@"title"] ?: @"(无标题)";
        if (ttl.length > 24) ttl = [[ttl substringToIndex:24] stringByAppendingString:@"…"];
        [s appendFormat:@"  其中最新一条 = %@ 「%@」%@\n", bid2, ttl,
            NBEnvClock(mx ? mx.doubleValue : 0)];
    }
    if (plSample.length) {
        NSString *head = plSample.length > 160
                       ? [[plSample substringToIndex:160] stringByAppendingString:@"…"]
                       : plSample;
        // 样本行与「含链接」合并成一行：屏幕篇幅是稀缺资源（用户明确抱怨过长）。
        [s appendFormat:@"  最新样本 %lu 字（含链接=%@）：%@\n",
            (unsigned long)plSample.length, NBEnvLinkState(plSample), head];
    } else {
        [s appendString:@"  最新样本=（还没有任何记录带 payload）\n"];
    }

    [s appendFormat:@"\n── 日志 ──\n%@\n", NOTIFYBOX_LOG_PATH];
    NSDictionary *la = [fm attributesOfItemAtPath:NOTIFYBOX_LOG_PATH error:nil];
    BOOL logExists = (la != nil);
    [s appendFormat:@"  存在=%@  大小=%llu B\n", logExists ? @"是" : @"否",
        [la[NSFileSize] unsignedLongLongValue]];
    if (logExists && la[NSFileModificationDate]) {
        [s appendFormat:@"  最后修改=%@\n", la[NSFileModificationDate]];
    }

    // ── 装载标记：三个位置各查一次 ──
    // 🔴 v0.0.137：这三个标记对应**三个不同的事实**，合并成一个就必然误判：
    //      `.tweak_ctor`       非 root 进程（SpringBoard/mobile）跑过 —— 真·注入证据
    //      `.tweak_ctor_root`  root 进程（backboardd）跑过**且 chown 成功** —— 属主自愈证据
    //      旧位置里的 `.tweak_ctor`   v0.0.136 留下的 split-brain 残留
    //    上一版只查了「当前数据目录」这一处 ⇒「tweak 记到别处去了」被误报成
    //    「tweak 从未注入任何进程」。判据说得比证据宽，方向就错。
    [s appendString:@"\n── tweak 装载标记 ──\n"];
    NSString *txtSB  = NBAppendMarker(s, @"SpringBoard（mobile）",
                                      [dir stringByAppendingPathComponent:@".tweak_ctor"]);
    NSString *txtRt  = NBAppendMarker(s, @"backboardd（root，chown 成功才写）",
                                      [dir stringByAppendingPathComponent:@".tweak_ctor_root"]);
    // 🔴🔴 v0.0.156：旧位置这一条改成**由 root 进程代读**，不再由 App 自己算路径。
    //   以前这里是 `altDir ? … : nil`，而 App 带 no-container ⇒ altDir 恒 nil
    //   ⇒ NBAppendMarker 第一句 `if (!path.length)` 就 return，**从不读文件**
    //   ⇒ 恒打一行「本进程算不出这个路径」= 死探针，split-brain 判据实际已失效十二版。
    //   注意 txtOld 现在的含义变了：它是**代读回来的标记正文**，不是 App 读到的文件内容。
    BOOL oldSeen = NO;
    NSString *txtOld = NBAppendOldLocation(s, &oldSeen);
    if (txtSB.length && txtRt.length) {
        [s appendString:@"  ⇒ 两个进程都注入过，属主自愈也跑过了\n"];
    } else if (txtSB.length) {
        [s appendString:@"  ⇒ SpringBoard 注入过；缺 root 标记 = backboardd 没跑到或 chown 没过\n"];
    } else if (txtOld.length) {
        [s appendString:@"  ⇒ ⚠️ 只有旧位置的标记：tweak 在跑，但**记到别处去了**（split-brain）\n"];
    } else if (!oldSeen) {
        // 🔴 铁律：读不到 ≠ 不存在。这一支不许并进下面那句「三处都没有」。
        [s appendString:@"  ⇒ 可见的两处都没有标记；旧位置**读不到**（无代读记录）\n"
                      @"     ⇒ 因此**不能**断言「tweak 从未注入」，先看下面的 /tmp 探针\n"];
    } else {
        [s appendString:@"  ⇒ 三处都没有：tweak 没注入（或装了没 respring、或过滤器未命中）\n"];
    }

    // ── v0.0.138 启动探针 ──
    // 🔴 这一段存在的唯一理由：上面那三个标记**全都押在"能往共享目录写文件"这一个前提上**，
    //    一旦写不进就同时消失 ⇒「没注入」和「写不进」在证据上同形。探针走 /private/var/tmp，
    //    是完全独立的第二条通道。App 自己也会写一份 `nb_boot_NotifyBoxApp.txt`。
    // ⚠️ App 受容器沙箱约束，**可能读不到 /tmp**（读不到就如实说"读不到"，不许当成"没有"）。
    //
    // 🔴🔴 v0.0.156：**这一节的篇幅瘦身**（原来 4 个文件 ≈49 行，占整屏一半）。
    //    冗余不在"打了几行"，而在"同一件事说了好几遍"：
    //      ① 每个文件对 4 个候选目录各打一行 `读回=OK`，而同文件末尾的
    //         `== 写成功的目录` 一行已经给出了答案 ⇒ 同一件事说五遍；
    //      ② 逐目录明细（`  ── 目录` / `=FAIL`）**只有失败时**才需要看；
    //      ③ `nb_boot_all.txt` 是 `writeToFile:atomically:NO` 的**末次写赢副本**
    //         （见 NBWriteBootProbe 末尾），内容与某个 per-process 文件完全重复
    //         ⇒ 它唯一独有的信息是「最后是谁写的」。
    //    ⇒ 健康时每文件 4 行（文件/进程/读回汇总/写成功目录），**出现 =FAIL 才展开明细**，
    //       异常时的输出与旧版**逐字一致**（信息一条不丢），健康时 49 → 15 行。
    [s appendString:@"\n── v0.0.138 启动探针（/private/var/tmp）──\n"];
    {
        NSArray *names = @[@"nb_boot_SpringBoard.txt",
                           @"nb_boot_backboardd.txt",
                           @"nb_boot_NotifyBoxApp.txt",
                           @"nb_boot_all.txt"];
        NSFileManager *pfm = [NSFileManager defaultManager];
        BOOL anyRead = NO;
        for (NSString *n in names) {
            NSString *fp = [@"/private/var/tmp" stringByAppendingPathComponent:n];
            NSDictionary *pa = [pfm attributesOfItemAtPath:fp error:nil];
            if (!pa && ![pfm fileExistsAtPath:@"/private/var/tmp"]) {
                [s appendString:@"  ❔ 本进程看不到 /private/var/tmp（沙箱）⇒ 下面几行无意义\n"];
                break;
            }
            if (!pa) {
                [s appendFormat:@"  ❌ %@ 不存在\n", n];
                continue;
            }
            anyRead = YES;
            NSString *txt = [NSString stringWithContentsOfFile:fp
                                                      encoding:NSUTF8StringEncoding error:nil];
            NSArray *lines = txt.length ? [txt componentsSeparatedByString:@"\n"] : @[];
            NSString *procLine = nil, *dylibLine = nil, *writable = nil;
            int rbOK = 0, rbFail = 0, rbSkip = 0;
            BOOL anyFail = NO;
            for (NSString *line in lines) {
                if ([line hasPrefix:@"进程="]) { procLine = line; continue; }
                if ([line hasPrefix:@"dylib="]) { dylibLine = line; continue; }
                if ([line hasPrefix:@"== 写成功的目录"]) { writable = line; continue; }
                if ([line hasPrefix:@"     读回="]) {
                    if ([line containsString:@"OK"]) rbOK++;
                    else if ([line containsString:@"FAIL"]) rbFail++;
                    else rbSkip++;                 // 「（没写成，跳过）」
                    continue;
                }
                if (!anyFail && [line containsString:@"=FAIL"]) anyFail = YES;
            }
            // 🔴 `     读回=FAIL` 会在上面被 `读回=` 那一支先吃掉（continue 掉了），
            //    所以这里必须再补一次判定 —— 否则「读到失败 1」却不展开明细，
            //    汇总说有问题、下面却什么都没有（读者会以为明细被截断了）。
            if (rbFail > 0) anyFail = YES;
            if ([n isEqualToString:@"nb_boot_all.txt"]) {
                // ③ 末次写赢的副本 ⇒ 只报"最后是谁写的"，不再 dump 内部
                [s appendFormat:@"  ✅ %@  %llu B  改于 %@（末次写赢副本，内容同上某份）\n     %@\n",
                    n, [pa[NSFileSize] unsignedLongLongValue], pa[NSFileModificationDate],
                    procLine ?: @"进程=(空)"];
                continue;
            }
            [s appendFormat:@"  ✅ %@  %llu B  改于 %@\n",
                n, [pa[NSFileSize] unsignedLongLongValue], pa[NSFileModificationDate]];
            [s appendFormat:@"     %@\n", procLine ?: @"进程=(空)"];
            if (dylibLine) [s appendFormat:@"     %@\n", dylibLine];
            // ① `读回` 与 `写成功的目录` 合成一行：两个量本来就是同一件事的两种说法
            NSMutableString *rb = [NSMutableString string];
            [rb appendFormat:@"读回 OK %d", rbOK];
            if (rbFail) [rb appendFormat:@" / **失败 %d**", rbFail];
            if (rbSkip) [rb appendFormat:@" / 跳过 %d", rbSkip];
            [s appendFormat:@"     %@ ｜ %@\n", rb, writable ?: @"== 写成功的目录:(空)"];
            // ② 明细只在真出错时展开（与旧版输出逐字一致）
            if (anyFail) {
                [s appendString:@"     ⚠️ 失败明细：\n"];
                int shown = 0;
                for (NSString *line in lines) {
                    if (shown >= 14) { [s appendString:@"       …（还有更多，去终端 cat）\n"]; break; }
                    BOOL keep = ([line containsString:@"=FAIL"] || [line hasPrefix:@"  ── "] ||
                                 [line hasPrefix:@"     读回="] || [line hasPrefix:@"== 写成功的目录"]);
                    if (!keep) continue;
                    [s appendFormat:@"       %@\n", line];
                    shown++;
                }
            }
        }
        if (!anyRead) {
            [s appendString:@"\n  🔴 一个探针文件都没有 ⇒ 两个可能，靠「App 能否看到 /tmp」区分：\n"
                          @"     · 上一行说了「看不到 /private/var/tmp」⇒ 是沙箱，本条不作证据；\n"
                          @"     · 能看到 /tmp 却一个文件都没有 ⇒ tweak 与 App 都没跑起来/没写成功，\n"
                          @"       去终端用 root 跑：cat /private/var/tmp/nb_boot_*.txt\n"];
        }
    }

    // ── 旧位置（App 容器）那一节已删 ──
    // 🔴 v0.0.144 删掉的理由：v0.0.143 之后盒子 App 带 `no-container` entitlement，
    //    容器路径在 App 进程里**恒为 nil** ⇒ 这一节恒显示「（本进程算不出来）」，
    //    是一条**恒为定值的死探针**：看起来总在报警，实际一条信息都不含。
    // 🔴🔴 v0.0.156 更正上一版的自我安慰：这里原本写着「它要证的事已由上面
    //    『旧位置装载标记』那条覆盖 —— 那条留着，因为它读的是**文件**、不是进程能力」。
    //    **那句话是错的**：那条走的也是同一个 nil 路径，NBAppendMarker 第一句就 return，
    //    从不读文件 ⇒ 十二个版本里 split-brain 判据一直是空的（一个恒定的 ❔）。
    //    现在改由 root 进程代读、结果落 `.old_location`，App 只读文件（见 NBAppendOldLocation）。

    // dylib 装在哪：优先用 tweak 自己用 dladdr 报出来的路径（roothide 会重定向前缀，
    // App 侧猜路径基本猜不中），猜不到才退回逐个探测。
    // 🔴 v0.0.137：`mtxt` 从三个标记里挑**任意一个有内容的**（优先级 SpringBoard → root → 旧位置）。
    //    ⚠️ 这一行是编译期才发现的漏写：判据全绿、clang 报 `use of undeclared identifier 'mtxt'`
    //    ——「文本全绿挡不住编译」，漏一个变量就是这么死的（§7 编译期才是硬闸门）。
    NSString *mtxt = txtSB.length ? txtSB : (txtRt.length ? txtRt : txtOld);
    [s appendString:@"\n── dylib 安装位置 ──\n"];
    NSString *dylibPath = nil;
    NSRange dr = mtxt ? [mtxt rangeOfString:@"dylib="] : NSMakeRange(NSNotFound, 0);
    if (dr.location != NSNotFound) {
        NSString *p = [[mtxt substringFromIndex:dr.location + dr.length]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        dylibPath = p;
        NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
        [s appendFormat:@"  ✅ %@\n     %llu B（由 tweak 自己上报，最可靠）\n", p,
            [a[NSFileSize] unsignedLongLongValue]];
    } else {
        NSArray *cands = @[
            @"/var/jb/Library/MobileSubstrate/DynamicLibraries/NotifyBox.dylib",
            @"/Library/MobileSubstrate/DynamicLibraries/NotifyBox.dylib",
            @"/var/jb/usr/lib/TweakInject/NotifyBox.dylib",
            @"/usr/lib/TweakInject/NotifyBox.dylib",
        ];
        BOOL anyDylib = NO;
        for (NSString *p in cands) {
            if ([fm fileExistsAtPath:p]) {
                NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
                [s appendFormat:@"  ✅ %@  %llu B\n", p, [a[NSFileSize] unsignedLongLongValue]];
                anyDylib = YES;
                if (!dylibPath) dylibPath = p;
            }
        }
        if (!anyDylib) {
            [s appendString:@"  ❓ tweak 未上报路径，候选路径也都没命中（roothide 前缀被重定向，属正常）\n"];
        }
    }

    [s appendString:@"\n── 注入过滤器 ──\n"];
    // 🔴🔴 v0.0.9：判据改成「跟 tweak 上报的 dylib **同目录**的 NotifyBox.plist」。
    //    上一版把候选路径写死在 /var/jb/... 与 /Library/...，而 roothide 实际把它放在
    //    .../.jbroot-XXXX/usr/lib/TweakInject/ 里 ⇒ 永远猜不中 ⇒ 界面上一直显示
    //    「未读到过滤器 plist」。**那是假红灯：判据写死路径造成的，不是安装有问题。**
    //    教训：凡是「换个环境就换个位置」的东西，判据必须**从已知的真实位置推导**，不能写死。
    NSMutableArray<NSString *> *plists = [NSMutableArray array];
    if (dylibPath.length) {
        [plists addObject:[[dylibPath stringByDeletingLastPathComponent]
                           stringByAppendingPathComponent:@"NotifyBox.plist"]];
    }
    [plists addObjectsFromArray:@[
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/NotifyBox.plist",
        @"/Library/MobileSubstrate/DynamicLibraries/NotifyBox.plist",
        @"/usr/lib/TweakInject/NotifyBox.plist",
    ]];
    BOOL anyPl = NO;
    for (NSString *p in plists) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) {
            id filt = d[@"Filter"];
            NSString *ftxt = @"(无 Filter 键)";
            if ([filt isKindOfClass:[NSDictionary class]]) {
                id bundles = ((NSDictionary *)filt)[@"Bundles"];
                if ([bundles isKindOfClass:[NSArray class]]) {
                    ftxt = [(NSArray *)bundles componentsJoinedByString:@","];
                }
            }
            [s appendFormat:@"  ✅ %@\n     Filter.Bundles = %@\n", p, ftxt];
            anyPl = YES;
            break;      // 找到一份就够，别把三份都打印出来占屏
        }
    }
    if (!anyPl) {
        [s appendFormat:@"  ❓ 同目录也没找到 NotifyBox.plist（dylib 目录=%@）\n",
            dylibPath.length ? [dylibPath stringByDeletingLastPathComponent] : @"未知"];
    }

    // 🔴 v0.0.8：设置到底有没有被读到 —— 这一段是「设置改了不生效」类问题的第一判据
    [s appendString:@"\n── 设置（settings.plist） ──\n"];
    NSFileManager *sfm = [NSFileManager defaultManager];
    BOOL sExists = [sfm fileExistsAtPath:NOTIFYBOX_SETTINGS_PATH];
    [s appendFormat:@"  文件：%@  %@\n", NOTIFYBOX_SETTINGS_PATH, sExists ? @"存在" : @"不存在"];
    NSDictionary *cfg = NBLoadSettings();
    [s appendFormat:@"  生效配置项数：%lu\n", (unsigned long)cfg.count];
    if (cfg.count) {
        // 🔴🔴 v0.0.156：**空值键折叠成一行**。
        //    逐键打一行时，一个「装过但都清空了」的配置能让这一段吃掉十几行；
        //    而那些行对判据零贡献 —— 判据是上面那个「生效配置项数」。
        // 🔴 折叠 ≠ 隐藏：键名一个不少地列在那一行里，只是不再各占一行。
        //    （「文件存在但为空 = 全部清空，是合法状态」这条语义必须保留，见下面那行提示。）
        // 🔴 「空」的判定要把 `()`、`{}`、空白、逗号分号都当噪声去掉再判 ——
        //    否则空数组的 description 是 `(\n)`，会被当成"有值"照打一行。
        NSArray *keys = [[cfg allKeys] sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray *empties = [NSMutableArray array];
        for (NSString *k in keys) {
            NSString *v = [cfg[k] description] ?: @"";
            NSString *probe = [v stringByReplacingOccurrencesOfString:@"(" withString:@""];
            probe = [probe stringByReplacingOccurrencesOfString:@")" withString:@""];
            probe = [probe stringByReplacingOccurrencesOfString:@"{" withString:@""];
            probe = [probe stringByReplacingOccurrencesOfString:@"}" withString:@""];
            probe = [probe stringByReplacingOccurrencesOfString:@"," withString:@""];
            probe = [probe stringByReplacingOccurrencesOfString:@";" withString:@""];
            probe = [probe stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!probe.length) { [empties addObject:k]; continue; }
            if (v.length > 60) v = [[v substringToIndex:60] stringByAppendingString:@"..."];
            [s appendFormat:@"    %@ = %@\n", k, v];
        }
        if (empties.count) {
            [s appendFormat:@"    空值 %lu 项（未清空前不显示，键名照列）：%@\n",
                (unsigned long)empties.count, [empties componentsJoinedByString:@","]];
        }
    } else {
        [s appendString:@"    （无设置 ⇒ 不过滤、不替换，行为与不装插件一致）\n"];
    }
    if (sExists && cfg.count == 0) {
        [s appendString:@"  ⚠️ 文件存在但为空：等于「全部清空」，这是合法状态\n"];
    }

    return s;
}

+ (NSString *)logText:(NSUInteger)maxBytes {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:NOTIFYBOX_LOG_PATH]) {
        return [NSString stringWithFormat:@"日志文件不存在：\n%@\n\n（说明 tweak 从未在本机跑过，或注入过滤器未命中）",
                NOTIFYBOX_LOG_PATH];
    }
    NSDictionary *attrs = [fm attributesOfItemAtPath:NOTIFYBOX_LOG_PATH error:nil];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    if (size == 0) return @"日志文件存在但为空（0 字节）";

    if (maxBytes == 0) maxBytes = 8000;
    unsigned long long start = (size > maxBytes) ? (size - maxBytes) : 0;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:NOTIFYBOX_LOG_PATH];
    if (!fh) return @"日志文件打不开（权限问题）";
    NSData *d = nil;
    @try {
        [fh seekToFileOffset:start];
        d = [fh readDataToEndOfFile];
    } @finally {
        [fh closeFile];
    }
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    NSString *head = [NSString stringWithFormat:@"日志 %llu B，显示尾部 %lu B：\n\n", size, (unsigned long)d.length];
    return [head stringByAppendingString:s ?: @"(解码失败)"];
}

+ (NSString *)debugSummary {
    NSFileManager *fm = [NSFileManager defaultManager];
    // 🔴 v0.0.136：把「目录是谁的」直接摆到界面上。
    //   旧的三行（存在/可读/可写）是**一个事实说三遍** —— 文件不在，后两个必然是否，
    //   看着像三条证据，其实只有一条。真机排查时它没能回答"为什么 App 进不去"。
    //   现在改成：属主 uid:gid + 目录可写（当前身份）——各项独立，
    //   属主不是 501:501 就直接指向"被 root 进程占过"。
    // 🔴 v0.0.137：删掉「来源」那一行 —— 路径已回常量，它恒等于「老路径」，
    //   **恒为定值的字段就是死探针**（占界面一行、信息量为零，还让人以为在判断什么）。
    NSString *dir = NBDataDir();
    struct stat st; memset(&st, 0, sizeof(st));
    BOOL hasStat = (stat([dir fileSystemRepresentation], &st) == 0);
    BOOL exists = [fm fileExistsAtPath:NOTIFYBOX_DB_PATH];
    NSDictionary *attrs = [fm attributesOfItemAtPath:NOTIFYBOX_DB_PATH error:nil];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    NSInteger n = [self count];
    NSMutableString *s = [NSMutableString stringWithFormat:
            @"数据目录：%@\n  属主：%d:%d（应为 501:501）  可写：%@\n"
            @"DB 文件：%@\n  存在：%@  大小：%llu B  可读：%@\n记录数：%ld  上限：%ld",
            dir,
            hasStat ? (int)st.st_uid : -1, hasStat ? (int)st.st_gid : -1,
            (access([dir fileSystemRepresentation], W_OK) == 0) ? @"是" : @"否",
            NOTIFYBOX_DB_PATH,
            exists ? @"是" : @"否", size,
            [fm isReadableFileAtPath:NOTIFYBOX_DB_PATH] ? @"是" : @"否",
            (long)n, (long)[self maxRecords]];

    // 🔴 v0.0.10：把最近 3 条的**字段长度**打出来。
    //    这个量专治一种混淆：「列表里看不到正文」到底是
    //    ① 库里就没存到正文（message 长度=0） 还是 ② 存了但没画出来。
    //    不看这个数，两种病因长得一模一样，只能猜。
    sqlite3 *db = [self openDB];
    if (db) {
        sqlite3_stmt *st = NULL;
        const char *sql = "SELECT bundle, title, message, subtitle FROM notifications "
                          "ORDER BY id DESC LIMIT 3;";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
            [s appendString:@"\n\n最近 3 条（字段字数）:"];
            int row = 0;
            while (sqlite3_step(st) == SQLITE_ROW && row < 3) {
                row++;
                const unsigned char *b = sqlite3_column_text(st, 0);
                const unsigned char *t = sqlite3_column_text(st, 1);
                const unsigned char *m = sqlite3_column_text(st, 2);
                const unsigned char *u = sqlite3_column_text(st, 3);
                NSUInteger lt = t ? strlen((const char *)t) : 0;   // 字节数，够判断"有没有"
                NSUInteger lm = m ? strlen((const char *)m) : 0;
                NSUInteger lu = u ? strlen((const char *)u) : 0;
                [s appendFormat:@"\n  %d) %@  title=%luB message=%luB subtitle=%luB",
                 row, b ? [NSString stringWithUTF8String:(const char *)b] : @"?",
                 (unsigned long)lt, (unsigned long)lm, (unsigned long)lu];
            }
            if (row == 0) [s appendString:@"\n  (空)"];
            sqlite3_finalize(st);
        }
        sqlite3_close(db);
    }
    return s;
}

#pragma mark - v0.0.99 通知中心「现状」快照（只读）

// ---------- 请求 tweak 扫一次 ----------
// 🔴 和 `nbRequestClearNCWithSysId:` 是**两条独立通道**：那个会动系统状态（撤通知），
//    这个纯只读。⛔ 绝不复用同一个 Darwin 通知名 —— 一次"只想看一眼"的请求
//    会走进清通知的流程。
// 🔴 写失败（沙盒/权限）只记日志，不影响调用方 —— 列表照常显示，只是标记不出来。
+ (void)requestNCSnapshotWithSeq:(NSString *)seq {
    @try {
        NSString *body = seq.length ? seq : [NSString stringWithFormat:@"%.0f",
                                             [[NSDate date] timeIntervalSince1970] * 1000.0];
        [[NSFileManager defaultManager] createDirectoryAtPath:
            [NOTIFYBOX_NC_SCAN_REQ stringByDeletingLastPathComponent]
                                     withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *err = nil;
        BOOL ok = [body writeToFile:NOTIFYBOX_NC_SCAN_REQ atomically:YES
                           encoding:NSUTF8StringEncoding error:&err];
        if (!ok) {
            NBStoreLog(@"扫描请求写不进去：%@", err.localizedDescription ?: @"?");
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR(NB_NC_SCAN_NOTIFY_NAME),
                                             NULL, NULL, TRUE);
        NBStoreLog(@"已请求扫描 NC 现状 seq=%@", body);
    } @catch (NSException *e) {
        NBStoreLog(@"扫描请求失败：%@", e);
    }
}

// ---------- 读快照 ----------
// 🔴🔴 这个方法的全部工作就是**如实翻译** tweak 落盘的那份快照，不做任何推断：
//    · 没有文件 / 没有表头 ⇒ scan=0、keys 空（一切 Unknown）。**没有基准就没法判断新旧** ——
//      猜成"仍在"是满屏橙条，猜成"已不在"是把真残留藏起来（最坏的那一档）⇒ 宁可什么都不说。
//    · `#` 开头的行是表头，不是条目。
// 🔴 表头格式 `#scan=<epoch>|nc=<账本条数>|cs=<界面认的条数>|csn=<实际探测条数>|cse=<严格相等的条数>|csem=<能读到uuid的条数>|csm=<0|1>|tmin=<NC最早那条的epoch>|tmax=<NC最新那条的epoch>|seq=<序号>`；
//    条目 `<section>|<key1>|<key2>|…|cs=<1|0|-1>`。
// 🔴 v0.0.116：`tmin`/`tmax` 是给「窗内残留」用的（见 `countStillInDBWithSnapshot:`）。
//    旧快照没有这两个字段 ⇒ 解析成 0 ⇒ 窗内口径报 -1（**没算出来用 -1，不用 0**）。
//    向后兼容是**故意**的：装上新版那一刻磁盘上还是旧文件，不能因为少两个字段就整份作废。
// 🔴 🔴 v0.0.102：`csn`（实际探测条数）**本类故意不解析** —— App 侧只需要
//    「界面认几条」（cs）和「到底量没量到」（csm）两个数；`csn` 是给日志诊断用的。
//    写一堆"解析了但谁都不读"的字段，在 `-Werror` 下就是一条 unused-but-set 编译错误
//    （v0.0.102 第一次 CI 正是这么炸的），所以宁可一个都不留。
// 🔴🔴🔴 v0.0.103：App 侧现在要的是 **`cse` / `csem`**（严格口径），
//    `cs`（返回非 nil 就算认）**退成旁证**、本类不再解析它 —— 真机已把 `cs` 否掉：
//    提示条量出「账本 637 · 界面 672」，两个数一个量级，说明"返回了"根本区分不出真假。
//    `cs` 仍留在文件里给日志读，但 App 一个字节都不碰（不解析就不会有 dead variable）。
// 🔴 `keys` 用 **NSSet**：匹配是 O(1)，而这个集合可能有几百个元素、每行都要查一次。
+ (NSDictionary *)ncSnapshot {
    NSTimeInterval scan = 0;
    NSInteger ncTotal = 0;
    NSInteger cseTotal = 0;
    NSInteger cseMeasured = 0;
    BOOL csOn = NO;
    NSString *seq = nil;
    // v0.0.116：通知中心的时间跨度（0 = 旧快照没这两个字段 / 一条都没读到时间）
    NSTimeInterval tmin = 0, tmax = 0;
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    // v0.0.112：v0.0.111 在这里收过一份 `hashes`（`h=` 列）和一个 `hcol` 标记，已全部撤掉。
    // 🔴 撤的理由：扫描侧算出来的哈希恒等于 `bundle||` ⇒ 同一 App 所有通知同哈希 ⇒ 死探针。
    //    这里少两个键，`empty` 字典也跟着少两个（形状必须一一对应，不许只改一边）。
    // 🔴 空快照的**唯一**形态（三个早退点共用一份，别各写一遍 ——
    //    少一个键就是"某个调用方读到 nil 然后当 0 处理"，本项目栽过）。
    NSDictionary *empty = @{@"scan": @0, @"nc": @0, @"cse": @0, @"csemn": @0,
                            @"csm": @0, @"tmin": @0, @"tmax": @0,
                            @"seq": @"", @"keys": [NSSet set]};
    @try {
        NSString *st = [NSString stringWithContentsOfFile:NOTIFYBOX_NC_SNAPSHOT
                                                encoding:NSUTF8StringEncoding error:NULL];
        if (!st.length) return empty;
        for (NSString *ln in [st componentsSeparatedByString:@"\n"]) {
            if (!ln.length) continue;
            // ---------- 表头 ----------
            if ([ln hasPrefix:@"#"]) {
                if (![ln hasPrefix:@"#scan="]) continue;
                for (NSString *f in [ln componentsSeparatedByString:@"|"]) {
                    if ([f hasPrefix:@"#scan="])      scan        = [[f substringFromIndex:6] doubleValue];
                    else if ([f hasPrefix:@"nc="])    ncTotal     = [[f substringFromIndex:3] integerValue];
                    // ⚠️ 长前缀先判：`csem=` 排在 `cse=` 之前。两个前缀其实互不吞
                    //    （`cse=` 比 "csem" 第 4 字符是 'm'≠'='；`csem=` 比 "cse=" 第 4 字符是 '='≠'m'），
                    //    排"先长后短"是为了让这条规矩**落成代码顺序**，别指望以后加字段的人自己推。
                    else if ([f hasPrefix:@"csem="])  cseMeasured = [[f substringFromIndex:5] integerValue];
                    else if ([f hasPrefix:@"cse="])   cseTotal    = [[f substringFromIndex:4] integerValue];
                    else if ([f hasPrefix:@"csm="])   csOn        = ([[f substringFromIndex:4] integerValue] != 0);
                    else if ([f hasPrefix:@"tmin="])  tmin        = [[f substringFromIndex:5] doubleValue];
                    else if ([f hasPrefix:@"tmax="])  tmax        = [[f substringFromIndex:5] doubleValue];
                    else if ([f hasPrefix:@"seq="])   seq         = [f substringFromIndex:4];
                }
                continue;
            }
            // ---------- 条目：第 0 段是 sectionIdentifier，其后每一段都是一把唯一键 ----------
            NSArray *q = [ln componentsSeparatedByString:@"|"];
            // 🔴 从下标 1 开始：第 0 段是 sectionIdentifier（App 里叫 bundle），
            //    **它不是唯一键**，放进匹配集会误命中（一个 App 的所有通知都同段）。
            // 🔴 v0.0.102：末尾的 `cs=N` **不是键**，必须挑掉。
            //    不挑也不会误命中（UUID 不可能叫 "cs=1"），但那属于"靠巧合正确"——
            //    以后快照再加字段（`th=…` 之类）就会变成真的 bug。这里按前缀排除。
            // 🔴 v0.0.112：`h=` 这一列已经不再写，但**必须继续跳过** ——
            //    v0.0.111 写的旧快照每行还带着一个 `h=<16位hex>`，装上新版时
            //    App 启动那一刻磁盘上就是那种旧文件。不跳过的后果：哈希串被当成一把"唯一键"
            //    塞进 keys ⇒「键 N 个」虚高（每行多一个），而且它是**恒不命中**的污染。
            //    ⚠️ 这一行是向后兼容，不是死代码；等能确认设备上不会再有旧快照了才可删。
            for (NSUInteger i = 1; i < q.count; i++) {
                NSString *k = q[i];
                if (!k.length || [k hasPrefix:@"cs="] || [k hasPrefix:@"h="]) continue;
                [keys addObject:k];
            }
        }
    } @catch (__unused NSException *e) {
        return empty;
    }
    // 🔴 没有基准 ⇒ 整份作废（理由见头注释）。**早退**，不是"尽力而为"。
    if (scan <= 0) return empty;
    return @{@"scan": @(scan), @"nc": @(ncTotal), @"cse": @(cseTotal),
             @"csemn": @(cseMeasured), @"csm": @(csOn ? 1 : 0),
             @"tmin": @(tmin), @"tmax": @(tmax),
             @"seq": seq ?: @"", @"keys": keys};
}

// ---------- v0.0.117：`NBSysIdWithAlt` 定义在文件前部（最早的调用点 `NBAppendRow` 之前）。 ----------

// ---------- 某条记录此刻在不在通知中心 ----------
// 🔴🔴 **必须按 `|` 拆开逐段匹配**：库里的 `sys_id` 存的是 `bulletinID|notificationIdentifier`
//    （写入侧把两个候选键拼起来，见 Tweak.x 的 sysId 拼装处），而快照里每个键都是**单独一个**。
//    拿整串去查只有单个键的集合 ⇒ 一条也命中不了。v0.0.98 就是栽在这里：
//    功能看着装好了，屏幕上一条都没有 —— 而且**不报错**，最难查的一种。
// 🔴 任一候选段命中就算"仍在"：两个键说的是同一条通知，命中哪个都算数。
// 🔴 拆开后**空段要跳过**：`"bID|"` 这种（只有一把键时写入侧仍会带分隔符）拆出来是空串，
//    拿空串去查集合虽然查不到，但语义上它是"没有这个键"，不是"这个键不在"。
+ (NBAliveState)aliveStateOfSysId:(NSString *)sysId inSnapshot:(NSDictionary *)snap {
    if (!sysId.length || ![snap isKindOfClass:[NSDictionary class]]) return NBAliveUnknown;
    NSSet *keys = snap[@"keys"];
    if (![keys isKindOfClass:[NSSet class]]) return NBAliveUnknown;
    // 快照里的扫描时刻为 0 ⇒ 根本没读过 ⇒ 一律 Unknown（不许当 Gone）
    if ([snap[@"scan"] doubleValue] <= 0) return NBAliveUnknown;

    NSArray *parts = [sysId componentsSeparatedByString:NB_SYSID_SEP];
    for (NSString *p in parts) {
        if (!p.length) continue;
        // 🔴 大小写敏感查、不留兜底：这些 ID 是系统给的十六进制串，
        //    "差不多的键"在本项目里已经造成过撤错条（loose 兜底 v0.0.75 已删）。
        if ([keys containsObject:p]) return NBAliveStill;
    }
    return NBAliveGone;
}

// ---------- v0.0.110 起：只读诊断「全库残留」为什么低（v0.0.112 修正取样口径） ----------
// 🔴🔴 v0.0.112 修的核心缺陷：**这行诊断以前是个恒否判据。**
//    它原来取「库里最新 5 条」（`ORDER BY ts DESC LIMIT 5`），而快照是**更早**写的
//    ⇒ 最新那 5 条当时还没发生，**结构上永远不可能出现在那份快照里** ⇒ `命中=0` 是必然。
//    真机（2026-11-02）就是被它带偏的：#1 是 3 分前、#5 是 18 分前，而快照写于 26 分钟前，
//    五行全是「否」。我据此得出「两侧 ID 完全不重叠」——**错的**。
//    ⇒ 现在改成先卡 **`ts <= 快照时刻`** 再倒序取 5 条：取"快照写下那一刻之前"最近的几条，
//      这几条才**有可能**在快照里，判据才有"是/否"两种结果。
//    🔴 记住这个反模式：凡是「拿最新数据去比旧快照」的判据，天生恒否。
//
// 当初为什么要这个诊断：真机报「全库残留」极低，需要分辨是
//   ① ID 被系统重投换掉了（老记录对不上现存通知 ⇒ 本来就这样，不用改）；
//   ② 拆段/格式对不上（真 bug，后果就是列表上「还在通知中心」的标记几乎全灰）。
// 🔴 后来查明 ① ② 都不是：那个「2 条」是在 **respring 后 40 秒**量的 ——
//    那时通知中心只加载出 4 条（`[源] nc=4`，51 秒后就是 293 条）。
//    换成重启前那份快照，同一个指标就是 254 / 2154，而当时通知中心总共 296 条 ⇒ 匹配率 ≈86%。
//    **结论：匹配逻辑一直是好的，坏的是尺子。** 用户真机也确认橙框"对得上"。
// 🔴 一个进程只打一次（`static done`）：日志窗口只有 ~50 行，这条一次就够定性。
//    ⚠️ 但 `done` **只在本函数真能跑取样时才置位**：拿不到快照时刻就直接退出、留待下次。
//    v0.0.111 的血账：`hcol=0` 说明它读完旧格式快照就把那唯一一次机会烧掉了，整版什么也没测到。
// 🔴 ID 截成 8…4 位：保留能比对的形状，又不至于把一行撑爆。
// 🔴 绝不改匹配逻辑：先让眼睛看清是哪种，再决定动不动手（本项目「量看着小 ≠ 尺子坏了」）。
static NSString *NBShortId(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return @"(空)";
    if (s.length <= 13) return s;
    return [NSString stringWithFormat:@"%@…%@", [s substringToIndex:8],
            [s substringFromIndex:s.length - 4]];
}

static void NBDiagAliveMatchOnce(sqlite3 *db, NSDictionary *snap) {
    static BOOL done = NO;
    if (done || !db || ![snap isKindOfClass:[NSDictionary class]]) return;
    // 🔴🔴 `done` 必须在**确认能取样之后**才置位（下面几行）。
    //    v0.0.111 把 `done = YES` 写在了最前面，于是"快照还没写成新格式"那一轮
    //    就把本进程唯一的一次机会烧掉了，整版一条数据都没测到。
    //    ⇒ 顺序就是判据：**先确认前提，再消费一次性的机会。**
    double scanTs = [snap[@"scan"] doubleValue];
    if (scanTs <= 0) return;      // 没读过快照 ⇒ 连"截至时刻"都没有，直接留待下次
    NSSet *keys = snap[@"keys"];
    if (![keys isKindOfClass:[NSSet class]]) keys = [NSSet set];
    // 🔴🔴 v0.0.113：**空快照也不算"能取样"**。
    //    空快照是带上 `#scan=` 时刻的（`nc=0` 照样写盘），所以 v0.0.112 只判 `scanTs > 0`
    //    挡不住它：读到空快照 ⇒ 键集为空 ⇒ 那 5 行必然全「否」，而 `done` 已经烧掉，
    //    本进程再也不会重跑 —— 这正是 v0.0.111 `hcol=0` 那个错的同一种形态。
    //    ⇒ 判据必须包含"键集非空"，否则这行诊断在某些启动时序下仍是恒否判据。
    if (keys.count == 0) return;
    done = YES;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    // v0.0.114：两档宽松索引（只诊断）
    NSSet *lcKeys = nil, *p8Keys = nil;
    NBBuildLooseIndex(keys, &lcKeys, &p8Keys);
    @try {
        // ① 重读快照文件，按 section 把键分组
        //    —— `snap` 里只剩一个扁平 key 集（解析时 section 被丢了），要并排比就得自己再分一次。
        NSMutableDictionary<NSString *, NSMutableArray *> *secKeys = [NSMutableDictionary dictionary];
        NSInteger rowCount = 0;      // v0.0.114：快照里到底有几行（键/行 比值能判断 `bulletin` 在不在）
        NSString *body = [NSString stringWithContentsOfFile:NOTIFYBOX_NC_SNAPSHOT
                                                  encoding:NSUTF8StringEncoding error:NULL];
        for (NSString *ln in [body componentsSeparatedByString:@"\n"]) {
            if (!ln.length || [ln hasPrefix:@"#"]) continue;
            NSArray *q = [ln componentsSeparatedByString:@"|"];
            if (q.count < 2) continue;
            rowCount++;
            NSString *sec = q[0];
            NSMutableArray *arr = [secKeys objectForKey:sec];
            if (!arr) { arr = [NSMutableArray array]; [secKeys setObject:arr forKey:sec]; }
            for (NSUInteger i = 1; i < q.count && arr.count < 6; i++) {
                NSString *k = q[i];
                // `h=` 同上下：旧快照里还有这列，跳过的理由一样（否则会被摆成"同段键"骗眼睛）。
                if (!k.length || [k hasPrefix:@"cs="] || [k hasPrefix:@"h="]) continue;
                [arr addObject:k];
            }
        }
        // 报快照有多旧：这是判"这 5 行该不该中"的前提，缺了它读出来的数又会被误读。
        // v0.0.114：「键/行」比值是判断 `bulletin` 在不在的旁证 ——
        //   每行本应最多 3 把（nid / uuid / bulletinID），实测恒为 2 ⇒ 有一把从来没进过键集。
        double kpr = (rowCount > 0) ? ((double)keys.count / (double)rowCount) : -1.0;
        NBStoreLog(@"[残] 诊断：快照分 %lu 段 / %ld 行 / 键 %lu 个（%.2f 键/行）/ 写于 %.0f 秒前",
                   (unsigned long)secKeys.count, (long)rowCount,
                   (unsigned long)keys.count, kpr, now - scanTs);
        NBStoreLog(@"[残] 下面 5 行取的是「快照写下那一刻之前」最近的 5 条"
                   @"（ts<=快照时刻，倒序）：段后的 (在/否) = 该段 ID 在不在快照键集里");

        // ② v0.0.112：**必须先卡 `ts <= 快照时刻`**。
        //    不卡就是"拿最新数据比旧快照" ⇒ 这 5 行永远全否（v0.0.111 的血账）。
        // v0.0.117：带上 `sys_id_alt` —— 否则这 5 行会按"只有现役 ID"去比，
        //   和上面那个三档统计（已经拼了旧 ID）口径不一致，两处数会打架。
        const char *sql = "SELECT bundle, sys_id, sys_id_alt, ts, title FROM notifications "
                          "WHERE sys_id IS NOT NULL AND sys_id<>'' AND ts <= ?1 "
                          "ORDER BY ts DESC LIMIT 5;";
        sqlite3_stmt *st = NULL;
        // 🔴 第 5 参 `pzTail` **不能省**：`sqlite3_prepare_v2` 是 5 参数，
        //    少写一个编译期直接 "too few arguments"（v0.0.110 CI 首跑就栽在这）。
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) {
            NBStoreLog(@"[残] 诊断 prepare 失败 err=%s", sqlite3_errmsg(db));
            return;
        }
        sqlite3_bind_double(st, 1, scanTs);
        int idx = 0;
        while (sqlite3_step(st) == SQLITE_ROW) {
            idx++;
            const char *cb = (const char *)sqlite3_column_text(st, 0);
            const char *cs = (const char *)sqlite3_column_text(st, 1);
            const char *ca = (const char *)sqlite3_column_text(st, 2);
            double ts = sqlite3_column_double(st, 3);
            const char *ct = (const char *)sqlite3_column_text(st, 4);
            NSString *bundle = cb ? [NSString stringWithUTF8String:cb] : nil;
            NSString *sysId0 = cs ? [NSString stringWithUTF8String:cs] : nil;
            NSString *sysAlt = ca ? [NSString stringWithUTF8String:ca] : nil;
            NSString *sysId  = NBSysIdWithAlt(sysId0, sysAlt);
            NSString *title  = ct ? [NSString stringWithUTF8String:ct] : @"";

            NSMutableArray *parts = [NSMutableArray array];
            NSInteger hit = 0;
            for (NSString *p in [sysId componentsSeparatedByString:NB_SYSID_SEP]) {
                if (!p.length) continue;
                BOOL in = [keys containsObject:p];
                if (in) hit++;
                [parts addObject:[NSString stringWithFormat:@"%@(%@)", NBShortId(p), in ? @"在" : @"否"]];
            }
            // v0.0.114：同一行的两档宽松口径，和精确数并排打（只诊断，不参与匹配）
            BOOL ci = NO, p8 = NO;
            NBCountLooseForms(sysId, lcKeys, p8Keys, &ci, &p8);
            NSString *age = @"?时";
            if (ts > 0) {
                double d = now - ts;
                if (d < 0) d = 0;
                age = (d < 3600) ? [NSString stringWithFormat:@"%.0f分前", d / 60.0]
                                 : [NSString stringWithFormat:@"%.1f时前", d / 3600.0];
            }
            NSArray *sample = bundle ? [secKeys objectForKey:bundle] : nil;
            NSMutableArray *sv = [NSMutableArray array];
            for (NSUInteger i = 0; sample && i < sample.count && sv.count < 2; i++)
                [sv addObject:NBShortId(sample[i])];

            // v0.0.112：这里原来还对每条现算一次内容哈希，已撤（扫描侧恒等于 `bundle||`）。
            // v0.0.114：精确 / 忽略大小写 / 前8位 三档并排 —— 一眼看出"差在哪一档"。
            NBStoreLog(@"[残] #%d %@ %@ ｜库ID(段=%lu 精确=%ld/忽略大小写=%d/前8位=%d): %@ ｜同段键: %@ ｜title=%@",
                       idx, bundle.length ? bundle : @"(空bundle)", age,
                       (unsigned long)parts.count, (long)hit,
                       ci ? 1 : 0, p8 ? 1 : 0,
                       parts.count ? [parts componentsJoinedByString:@" "] : @"（sys_id 拆不出段）",
                       sv.count ? [sv componentsJoinedByString:@" "] : @"（该段快照里没有条目）",
                       NBShortId(title));
        }
        sqlite3_finalize(st);
    } @catch (NSException *e) {
        NBStoreLog(@"[残] 诊断抛: %@", e.reason);
    }
}

// ---------- v0.0.114：三档「宽松口径」，**只用于诊断，绝不参与匹配** ----------
// 为什么需要：同一个「全库残留」在代码未变时出现过 1 / 2 / 6 / 245 / 254 这些值，
//   跨度 100 倍以上。在没量出"差在哪一档"之前，任何结论都是猜（v0.0.110 就这么猜错过）。
// 三档的读法：
//   · 精确少、忽略大小写多   ⇒ **大小写**问题（真机上快照每行两把键，一把小写一把大写，
//                              而库里 `sys_id` 是大写 —— 这个组合必须先排掉）
//   · 两者都少、前8位多      ⇒ 分隔符 / 前后缀 / 格式不同（同一个 UUID 的两种写法）
//   · 三个都少              ⇒ ID 真的换了（那就不是 bug，是该换尺子）
// 🔴🔴 「前8位」是**故意做松**的诊断量，⛔ 永远不许拿去当匹配依据 ——
//    本项目在 loose 兜底上出过撤错条（v0.0.75 已删过一版）。
// 🔴 三个数必须**在同一遍循环里**累加：各扫一遍会让"分母相同"从事实变成假设。
static void NBCountLooseForms(NSString *sysId, NSSet *lcKeys, NSSet *p8Keys,
                              BOOL *ciOut, BOOL *p8Out) {
    if (ciOut) *ciOut = NO;
    if (p8Out) *p8Out = NO;
    if (!sysId.length) return;
    for (NSString *p in [sysId componentsSeparatedByString:NB_SYSID_SEP]) {
        if (!p.length) continue;
        if (lcKeys && [lcKeys containsObject:[p lowercaseString]]) {
            if (ciOut) *ciOut = YES;
        }
        if (p8Keys) {
            NSString *h = (p.length >= 8) ? [p substringToIndex:8] : p;
            if ([p8Keys containsObject:[h lowercaseString]]) {
                if (p8Out) *p8Out = YES;
            }
        }
    }
}

// 从快照键集派生两份宽松索引（忽略大小写 / 前 8 位）。键集很小（几百个），一次建好复用。
static void NBBuildLooseIndex(NSSet *keys, NSSet **lcOut, NSSet **p8Out) {
    NSMutableSet *lc = [NSMutableSet setWithCapacity:keys.count];
    NSMutableSet *p8 = [NSMutableSet setWithCapacity:keys.count];
    for (id k in keys) {
        if (![k isKindOfClass:[NSString class]]) continue;
        NSString *s = (NSString *)k;
        if (!s.length) continue;
        [lc addObject:[s lowercaseString]];
        // 🔴 三元不许直接当消息接收者（`[[cond ? a : b] xxx]` 解析不了，
        //    clang 报 `error: expected identifier`）⇒ 先落到变量再发消息。
        NSString *h = (s.length >= 8) ? [s substringToIndex:8] : s;
        [p8 addObject:[h lowercaseString]];
    }
    if (lcOut) *lcOut = lc;
    if (p8Out) *p8Out = p8;
}

// v0.0.130：残留统计的行数节流参数。**唯一出口** —— 别在函数体里另写秒数
// （「同一界面里互相解释的两个指标必须同口径」，节流窗口同理：两处各写一个数必走岔）。
#define NB_STILL_LOG_GAP       20.0
#define NB_STILL_LOG_GAP_IDLE 120.0

// ============= v0.0.130：`sys_id_alt` 撞车只读诊断（一次性） =============
// 🔴🔴 这一版之前**从没量过**的一件事：`sys_id_alt` 里留的旧 ID，会不会正好是
//    **库里另一行**的现役 `sys_id`？会的话，`NBSysIdWithAlt` 拼出的候选键就带着
//    「别人家的 ID」⇒ 那一行被判成 Still 的原因**根本不是「它自己还在」**，
//    而是「别人的 ID 还在」⇒ **`旧ID救回` 那个数对它们不成立**。
//    这正是本项目「归因不排他」那一型：数是真的，但它证不了它被拿来证的那件事。
// 🔴 判据三件套（缺一个就只剩八卦）：① 分子「撞车行」；② 分母（见下）；③ 净额「旧ID段」。
// 🔴 一次进程只打一行 —— 日志窗口 ~50 行，这条是定性用的。
// 🔴🔴 `sDone` 必须在**取样成功之后**才置位：v0.0.111 的血账是 `done` 写在最前面，
//    第一次调用时库还空着，唯一一次机会就烧在那个 0 上了。
static void NBDiagSysIdAltOnce(sqlite3 *db, NSInteger altRows) {
    static BOOL sDone = NO;
    static BOOL sErrLogged = NO;
    static NSInteger sTries = 0;
    if (sDone || !db) return;
    // 🔴 分母直接用**主扫描算出来的那个数**，不在这里重算一遍：主扫描的 WHERE 是
    //    `sys_id IS NOT NULL AND sys_id<>''`，这里只要差一个条件，两行日志上的
    //    「带旧ID行」就会是两个数，而读的人只会以为「数据变了」。
    if (altRows <= 0) {
        sTries++;
        // 没旧 ID 可查时**不许**把一次性机会烧掉；也不许无限重试（这个 EXISTS 是 O(n²)）
        // ⇒ 3 次之后死心，并且**说出来**：「没打日志」必须能和「查过了、结果是 0」分开。
        if (sTries < 3) return;
        sDone = YES;
        NBStoreLog(@"旧ID撞车 -1（查了 %ld 次，带ID行里带旧ID的一直是 0）｜ 这不是「撞车 0 行」，是「没有旧 ID 可查」⇒ 写入侧没在写 sys_id_alt（整版空转），不是匹配没用",
                   (long)sTries);
        return;
    }
    // 🔴 判据只有一条：某个旧 ID 段 == **另一行**的现役 `sys_id`。
    //    `'|'||alt||'|'` 两头补竖线 + `LIKE '%|b.sys_id|%'` ⇒ 要求**整段**相等而不是
    //    子串相同（前缀会被算进去 —— 本项目「反向判据必须精确到边界」那一条）。
    //    `b.id<>a.id` 是排自己：被改写过的行自己的 `sys_id` 当然不再等于旧 ID，
    //    但「同一行」必须显式排掉，否则将来某次写入不改 `sys_id` 就会被算成撞车。
    const char *sql =
        "SELECT "
        " (SELECT COUNT(*) FROM notifications a "
        "   WHERE IFNULL(a.sys_id_alt,'')<>'' AND a.sys_id IS NOT NULL AND a.sys_id<>'' "
        "     AND EXISTS (SELECT 1 FROM notifications b "
        "                  WHERE b.id<>a.id AND IFNULL(b.sys_id,'')<>'' "
        "                    AND ('|'||a.sys_id_alt||'|') LIKE ('%|'||b.sys_id||'|%'))), "
        " (SELECT IFNULL(SUM(LENGTH(sys_id_alt)-LENGTH(REPLACE(sys_id_alt,'|',''))+1),0) "
        "   FROM notifications WHERE IFNULL(sys_id_alt,'')<>'' "
        "     AND sys_id IS NOT NULL AND sys_id<>'');";
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) {
        if (!sErrLogged) {
            sErrLogged = YES;   // 只报一次；但**不置 `sDone`** —— 查询坏了不是结论
            NBStoreLog(@"!!! 旧ID撞车 查不动 err=%s（这条是查询坏了，不是撞车 0 行）",
                       sqlite3_errmsg(db));
        }
        return;
    }
    if (sqlite3_step(st) == SQLITE_ROW) {
        NSInteger crash = sqlite3_column_int(st, 0);
        NSInteger segs  = sqlite3_column_int(st, 1);
        sDone = YES;
        NBStoreLog(@"旧ID撞车 %ld 行 / 带ID行里带旧ID的 %ld 行（旧ID段共 %ld 个）｜ 撞车 = 某行的旧ID正好是**另一行**的现役 sys_id ⇒ 这些行的「还在」可能是别人的 ID 顶出来的，`旧ID救回` 对它们不成立 ｜ 撞车 0 行才是净证据（一次性诊断）",
                   (long)crash, (long)altRows, (long)segs);
    }
    sqlite3_finalize(st);
}

// ---------- v0.0.100：全库口径「此刻还在通知中心」的行数 ----------
// 🔴🔴 为什么需要第二个数：`aliveStillCount` 是**当前列表**口径（受时间窗 / App 筛选 /
//    未读筛选 / LIMIT 2000 影响）。拿它去说「盒子里的消息都不在通知中心了」，
//    就是在用**局部**的数做一个**全库**的断言 —— 用户明明有记录还在通知中心，
//    只是被时间窗挡在列表外，屏幕上那句就会是假话。
//    （本项目同一个形态栽过：红点按全库算、列表按时间窗查。）
// ⇒ 两个数都要有，并且在文案里**分开说**：全库 0 才准说"都不在"，
//    全库 >0 而列表 0 就必须说"被当前筛选挡住了"。
// 🔴 匹配规则只有 `aliveStateOfSysId:` 一份实现 —— 这里逐行调它，不另写一套。
//    （两处各写一遍判等 ⇒ 改一处忘一处，本项目已付过代价。）
// 🔴 只取 `sys_id` 一列，不整行取：几千行也只是几个指针，且不碰任何界面字段。
+ (NSInteger)countStillInDBWithSnapshot:(NSDictionary *)snap {
    if (![snap isKindOfClass:[NSDictionary class]]) return 0;
    // 没有可用快照 ⇒ 一条都判不了，返回 0 但调用方**不许**把它当"都不在"
    // （`aliveHintText` 里 `aliveScanTs <= 0` / `aliveStale` 两个分支已经先把它挡掉了）。
    double snapTs0 = [snap[@"scan"] doubleValue];
    if (snapTs0 <= 0) return 0;
    sqlite3 *db = [self openDB];
    if (!db) return 0;
    NSInteger still = 0;
    NSInteger scanned = 0;      // 有多少行**带 ID** 参与了比对（用来区分"键不重合"和"根本没 ID"）
    // v0.0.114：两档宽松口径（只诊断）。真实匹配仍然只走 `aliveStateOfSysId:` 一份实现。
    NSInteger stillCI = 0;      // 忽略大小写
    NSInteger stillP8 = 0;      // 前 8 位相同
    NSSet *snapKeys = snap[@"keys"];
    if (![snapKeys isKindOfClass:[NSSet class]]) snapKeys = [NSSet set];
    NSSet *lcKeys = nil, *p8Keys = nil;
    NBBuildLooseIndex(snapKeys, &lcKeys, &p8Keys);
    // ---------- v0.0.115：命中/总量按「记录年龄」分档（只读诊断） ----------
    // 🔴 为什么要这个：真机同一个「全库残留」在三份快照上量到 245 / 2 / 1，
    //    而三次的分母几乎一样（带ID行 2140~2162、快照 nc 283~289），匹配代码一个字没动。
    //    ⇒ 光有总数分不清下面两种完全不同的病因：
    //      ① **通知中心里的 bulletin 换了一批新 ID**（重启后常见）⇒ 库里的旧 ID 全部失效；
    //      ② **键根本对不上**（拆段/格式/读法错）⇒ 那是真 bug。
    //    这两件事有一个可测的指纹：① 的命中会**集中在最近这段时间**（重启之后发布的那些），
    //    ② 则是各年龄一样地不命中。⇒ 把命中数和分母按同样的年龄档并排打出来，就不再靠猜。
    // 🔴 分档边界沿用扫描侧那份（<1h / 1-6h / 6-24h / >24h），两处口径必须一致，
    //    否则「命中全在最新档」这种结论又会因为边界不同而失真。
    static BOOL sAgeLogged = NO;
    NSInteger hitAge[4] = {0, 0, 0, 0};
    NSInteger allAge[4] = {0, 0, 0, 0};
    // ---------- v0.0.122：「未覆盖」必须单独数出来，不许混进分母 ----------
    // 🔴 真 bug（v0.0.121 及以前）：这个函数的分母是**全部带 ID 的行**，其中包含
    //    「快照写下之后才发布」的那些 —— 它们结构上不可能出现在快照里，拿它们当分母
    //    必然算成"不在"。真机账：`窗内残留 15/418`（3.6%）看着像匹配全坏，
    //    其实那 418 行里混着快照之后才进来的新记录。
    // 🔴 这是本项目「读不到 ≠ 不存在」的第 N 次复现，也是那条铁律的镜像：
    //    **分母里混进"根本不可能成立"的样本，比分子算错更隐蔽** —— 它不报错，
    //    只把百分比做小，然后把一次"正常"读成"坏了"。
    NSInteger uncovered = 0;
    // 🔴 年龄分档的基准时刻。v0.0.121 用的是 `nowTs`（"现在"），而快照可能写于
    //    6339 秒前 ⇒ `<1h` 那一档的条件等价于 `ts > 快照时刻 + 2739`，
    //    落在这一档的行**全部在快照之后才发布** ⇒ 命中必然 0。真机量到 0/29，
    //    而日志里那句读法写着"三档都接近 0 才是真 bug" ⇒ 差点把"口径错"读成"代码错"。
    //    ⇒ 年龄一律按**快照时刻**算：`snapTs0 − ts`，与"这一行相对快照有多老"同义。
    // ---------- v0.0.116：「窗内残留」—— 分母只取**可能活着**的行 ----------
    // 🔴 真机血账（2026-11-02 18:10:12）：`全库残留 179 ／ 带ID行 2163` 读成"匹配只有 8.3%"，
    //    但按年龄并排一看：<1h 2/6、1-6h 27/70、6-24h 149/312、**>24h 1/1775**。
    //    而那一刻通知中心里最老的才 23.9 小时 ⇒ 那 1775 行（占库 **82%**）比 NC 最老的还老，
    //    **结构上不可能命中**。它们只是把分母撑大，把百分比压成假象。
    //    ⇒ 窗内口径：`ts` 落在 `[tmin, tmax]`（= 通知中心自己的时间跨度）里的行才算分母。
    //      同一份数据：全库 179/2163 = 8.3%（假） vs 窗内 178/388 = 46%（真）。
    // 🔴 旧口径**一个字不动**、并排保留：局部口径不许说全库的话，两个数各有各的用途
    //    （全库那个 0 才是"盒子里的消息都不在通知中心了"的依据）。
    double winMax = [snap[@"tmax"] doubleValue];
    double winMin = [snap[@"tmin"] doubleValue];
    BOOL winOk = (winMax > 0);
    NSInteger winRows = 0, winStill = 0;
    // v0.0.117：这两个数就是**这一版修的东西到底修好没有**的唯一直接证据。
    //   `altRows` = 带旧 ID 的行（证明**写入侧**真在写 `sys_id_alt`，否则整版是空转）；
    //   `altSaved` = 只靠旧 ID 才判成 Still 的行（证明**匹配侧**真的靠它救回来了）。
    //   🔴 只报 `altSaved` 不报 `altRows` 就会犯"没有分母"的错：altRows=0 时 altSaved
    //      必然是 0，那说明的是"没在写"，不是"匹配没用"。
    NSInteger altRows = 0, altSaved = 0;
    // 🔴 v0.0.117：把保留的旧 ID 一起取出来拼成候选键（`新|旧`），跨过 NC 重投换 ID。
    //    WHERE 一个字不动：`sys_id_alt` 只在 `sys_id` 非空、且被改写过时才写
    //    ⇒ 「带 ID 的行」这个分母的口径不会因为这次改动而变（否则年龄分档全都要重算）。
    const char *sql = "SELECT sys_id, ts, IFNULL(sys_id_alt,'') FROM notifications "
                      "WHERE sys_id IS NOT NULL AND sys_id<>'';";
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const char *t = (const char *)sqlite3_column_text(st, 0);
            if (!t) continue;
            // v0.0.122：`ts` 必须**在决定这一行算不算分母之前**读出来。
            // 🔴 顺序不是风格问题：先 `scanned++` 再判覆盖，就等于"未覆盖的行也算进了分母"，
            //    而那正是这一版要修的那个 bug —— 顺序错了会伪装成"改法没用"。
            double ts = sqlite3_column_double(st, 1);
            if (ts > 0 && ts > snapTs0) { uncovered++; continue; }
            scanned++;
            NSString *sid0 = [NSString stringWithUTF8String:t];
            const char *ta = (const char *)sqlite3_column_text(st, 2);
            NSString *salt = ta ? [NSString stringWithUTF8String:ta] : nil;
            NSString *sid = NBSysIdWithAlt(sid0, salt);
            BOOL isStill = ([self aliveStateOfSysId:sid inSnapshot:snap] == NBAliveStill);
            if (isStill) still++;
            // v0.0.117：把"只靠旧 ID 才救回来"的行单独数出来。
            // 🔴 只在真有旧 ID 时才多查一次（没有旧 ID 的行，`sid` 和 `sid0` 完全相同，
            //    再查一遍是同义反复，白花时间而且给出的 0 没有意义）。
            if (salt.length) {
                altRows++;
                if (isStill && [self aliveStateOfSysId:sid0 inSnapshot:snap] != NBAliveStill) altSaved++;
            }
            // 同一遍里把两档宽松口径也数掉（分母必须是同一批行）
            BOOL ci = NO, p8 = NO;
            NBCountLooseForms(sid, lcKeys, p8Keys, &ci, &p8);
            if (ci) stillCI++;
            if (p8) stillP8++;
            // 年龄分档：`ts` 读成 0/负数（老库没写时间）一律并进最后一档，不另设「未知」档
            // —— 多一个档就多一个可以被读错的口径，而且这类行本来就该按"老"处理。
            // 🔴 v0.0.122：基准改 `snapTs0`（快照时刻），**不是** `nowTs2`（现在）。
            //    走到这里 `ts <= snapTs0` 已经保证，所以 age >= 0，`<1h` 档终于有真实样本。
            double age = (ts > 0) ? (snapTs0 - ts) : -1.0;
            int bi = (age < 0)      ? 3
                   : (age < 3600)   ? 0
                   : (age < 21600)  ? 1
                   : (age < 86400)  ? 2
                                    : 3;
            allAge[bi]++;
            if (isStill) hitAge[bi]++;
            // 窗内：上下界都要卡（`tmin` 缺失时只卡上界，别因为读不到下界就整窗作废）
            if (winOk && ts > 0 && ts <= winMax && (winMin <= 0 || ts >= winMin)) {
                winRows++;
                if (isStill) winStill++;
            }
        }
        sqlite3_finalize(st);
    } else {
        NBStoreLog(@"countStillInDB prepare 失败 err=%s", sqlite3_errmsg(db));
    }
    // v0.0.110：顺手做一次「为什么命中这么低」的只读诊断（一个进程只打一次，内部幂等）。
    // 🔴 必须放在 close 之前：它要用同一个 db 句柄。
    // v0.0.112：仍然传整份 `snap` —— 现在要用的是它的 `scan`（快照时刻），
    //    没有这个时刻就没法把取样卡在「ts <= 快照时刻」，那 5 行又会变回恒否判据。
    NBDiagAliveMatchOnce(db, snap);
    // v0.0.130：`sys_id_alt` 撞车诊断。和上一条同理 —— 必须在 close 之前，用同一个句柄。
    // 🔴 分母传的是主扫描已经算好的 `altRows`（不是这里再数一遍，理由见函数头）。
    NBDiagSysIdAltOnce(db, altRows);
    sqlite3_close(db);
    // 🔴 v0.0.100 自证：这一行是"匹配到底成不成立"的唯一直接证据。
    //    v0.0.99 那个 bug（列表 SELECT 漏了 sys_id ⇒ 消费端恒 nil ⇒ 恒 0）全程**不报错**，
    //    只能靠"tweak 日志说 4 条、界面说 0 条"这种跨进程对拍才发现。
    //    有了这一行，「全库 4 / 界面 0」当场就能定位到列表那一侧。
    // 🔴 `带ID行` 是**分母**：它等于 0 说明库里根本没有可比对的 ID（等于没数据），
    //    它很大而残留 0 才是"键对不上"（等于匹配规则有问题）。两个数缺一个就判不了。
    // 🔴🔴 v0.0.112：**读这个数之前必须先看「扫描于 N 秒前」**。
    //    2026-11-02 就是这里骗了我一次：respring 后 40 秒量到「残留 4 / 带ID 2154」，
    //    看着像"匹配全坏"，其实是那会儿通知中心只加载出 4 条；同一份代码在重启前的快照上是
    //    254 / 2154，而当时通知中心总共 296 条 ⇒ 匹配率 ≈86%。
    //    ⇒ **这个数是"相对当前通知中心里有多少条"的比值，不是绝对值。分母要先读 `快照 nc=`。**
    // 🔴 没扫过就报 -1（本项目铁律：没算出来用 -1，不用 0 —— 0 会被读成"算出来是零"）。
    double scanTs2 = [snap[@"scan"] doubleValue];
    double snapAge = (scanTs2 > 0) ? ([[NSDate date] timeIntervalSince1970] - scanTs2) : -1.0;
    // ============= v0.0.130：残留统计的**行数节流**（内容签名 + 保底） =============
    // 🔴 现场：这个函数只在「列表里一条残留都没有」时跑，而那个状态恰恰是用户盯着空列表
    //    反复刷新的状态 ⇒ 每刷一次就是 4 行长日志（全库残留 / 读法 / 窗内残留 / 旧ID救回），
    //    其中**两行是散文**、两行的数字一个没变。真机一份日志里这块占 21%，
    //    把「一个进程只打一次」那几条真诊断整个挤出窗口。
    // ⇒ 照 v0.0.123 给 `[扫]` 行用的那套办法（**已经证过的**，不再另发明一套）：
    //    ① **数值一个都不删** —— 它们是数据；散文压成一次性（见下面的 `sStillHintLogged`）；
    //    ② 内容签名变了才打，且最小间隔 `NB_STILL_LOG_GAP` 秒（数字抖动时不刷屏）；
    //    ③ 一直不变 ⇒ `NB_STILL_LOG_GAP_IDLE` 秒保底打一条 ——
    //       「没日志」会被读成「这函数不跑了」，那是比多几行更贵的误读；
    //    ④ 被节流掉几轮，下一行里必须写出来（`期间省略 N 轮`）。
    // 🔴🔴 签名里**不许**放每次都变的字段：`snapAge`（秒数）放进去就等于没节流 ——
    //    v0.0.129 刚在 `[扫]` 那边踩过同一形态（`seq` 每次都变）。
    //    这里只放**业务量**：残留数 / 分母 / 未覆盖 / 窗内 / 旧ID / 快照条数与键数。
    static NSTimeInterval sStillLogTs = 0;
    static NSString *sStillLogSig = nil;
    static NSUInteger sStillLogSkip = 0;
    NSTimeInterval stillNow = [[NSDate date] timeIntervalSince1970];
    // 🔴 键数一律取**已经校验过的** `snapKeys`：原来那行直接强转 `snap[@"keys"]`，
    //    它如果不是 NSSet，打出来的数就和匹配实际用的那个集不是同一个（两套口径）。
    NSString *stillSig = [NSString stringWithFormat:@"%ld|%ld|%ld|%ld|%ld|%ld|%ld|%ld|%ld|%@|%lu",
                          (long)still, (long)stillCI, (long)stillP8,
                          (long)scanned, (long)uncovered,
                          (long)winStill, (long)winRows,
                          (long)altSaved, (long)altRows,
                          snap[@"nc"] ?: @"?", (unsigned long)snapKeys.count];
    BOOL stillSigChanged = ![stillSig isEqualToString:(sStillLogSig ?: @"")];
    BOOL stillDueChange = stillSigChanged
        && ((sStillLogTs <= 0) || ((stillNow - sStillLogTs) >= NB_STILL_LOG_GAP));
    BOOL stillDueIdle = (sStillLogTs <= 0)
        || ((stillNow - sStillLogTs) >= NB_STILL_LOG_GAP_IDLE);
    BOOL doStillLog = stillDueChange || stillDueIdle;
    // 🔴 v0.0.122：`带ID行` 与 `未覆盖` 必须**并排**打出来。
    //    只报残留数和分母（旧格式）时，读不出"分母里混着不可能成立的行" —— 那正是
    //    v0.0.121 把 3.6% 读成"匹配全坏"的原因。`未覆盖 N 条` 就是那个分母的**净额**：
    //    `带ID行` 从此只算**被快照覆盖到**的行（`ts <= 快照时刻`），口径与 App 侧
    //    `aliveStateForRow:` 的「未覆盖判 Unknown」完全一致（两个指标必须同源）。
    if (doStillLog) {
        NBStoreLog(@"全库残留 %ld 条 ｜ 忽略大小写 %ld ｜ 前8位同 %ld ｜ 带ID行(已覆盖) %ld ｜ 未覆盖 %ld（快照之后才发布，结构上不可能在快照里，已排除出分母）｜ 快照 nc=%@ 键 %lu 个 ｜ 扫描于 %.0f 秒前 ｜ 期间省略 %lu 轮",
                   (long)still, (long)stillCI, (long)stillP8, (long)scanned,
                   (long)uncovered,
                   snap[@"nc"] ?: @"?",
                   (unsigned long)snapKeys.count,
                   snapAge, (unsigned long)sStillLogSkip);
    }
    // ---------- v0.0.130：读法压成**一次性**（散文不是读数） ----------
    // 🔴 v0.0.114 的初衷不变：「把读法写在日志里，别指望下次还记得怎么解读」
    //    （一个数被反复误读，比没有这个数更糟）。变的是**次数**：
    //    读法是一份说明书，不是测量值 —— 每轮重抄一遍说明书，等于把读数挤出窗口。
    // ⇒ 一个进程打一次，两段读法合成一行（省一行窗口）；数字行照旧受节流门控。
    static BOOL sStillHintLogged = NO;
    if (!sStillHintLogged && scanned > 0) {
        sStillHintLogged = YES;
        NBStoreLog(@"残留读法（一次性，本进程不再重复）：① 全库三档 —— 精确少、忽略大小写多 ⇒ 大小写问题；两者都少、前8位多 ⇒ 格式/分隔符不同；三个都少 ⇒ ID 真的换了（不是 bug）｜② 旧ID —— 「旧ID救回」的分母是「带旧ID的行」：分母 0 时救回 0 说明的是「写入侧没在写 sys_id_alt」（整版空转），不是匹配没用");
    }
    // 🔴 v0.0.116：「窗内残留」—— 这才是判断"匹配好不好"该看的百分比。
    //    全库那个百分比的分母里混着大批"比通知中心最老的还老"的行，本来就不可能命中。
    //    没算出来（旧快照没有 tmin/tmax）一律报 -1，**不许报 0**（0 会被读成"算出来是零"）。
    if (winOk && winRows > 0) {
        if (doStillLog) {
            double winSpanMin = (winMax - ((winMin > 0) ? winMin : winMax)) / 60.0;
            NBStoreLog(@"窗内残留 %ld 条 / %ld 行（%.1f%%）｜ 窗 = 通知中心跨度 %.0f 分 ｜ 分母只含 ts<=快照时刻的行（已排除未覆盖 %ld 条）｜ 全库那个 %.1f%% 被「结构上不可能活着」的老记录稀释，别拿它下结论",
                       (long)winStill, (long)winRows,
                       (double)winStill * 100.0 / (double)winRows, winSpanMin,
                       (long)uncovered,
                       (scanned > 0) ? (double)still * 100.0 / (double)scanned : -1.0);
        }
    } else {
        // 🔴 v0.0.130：「算不出来」是**恒定的异常形态**（快照里就是没有 tmin/tmax），
        //    不是每轮都值得报一次的告警 ⇒ 一个进程打一次。但**必须打**：
        //    不打就分不清「这个口径没实现」和「算出来是 0」（「没算用 -1」那条的配套）。
        static BOOL sWinNAOnce = NO;
        if (!sWinNAOnce) {
            sWinNAOnce = YES;
            NBStoreLog(@"窗内残留 -1 / -1（快照里没有 tmin/tmax ⇒ 这个口径算不出来；不是 0；本进程只打这一条）");
        }
    }
    // 🔴🔴 v0.0.117：这一行是判断「这一版修好没有」的唯一直接证据 ——
    //    两个数缺一个就读不出结论：`带旧ID的行 0` ⇒ **写入侧压根没在写**（整版空转），
    //    这时 `救回 0` 说明的是「没东西可救」，不是「匹配没用」；反过来
    //    `带旧ID的行 > 0` 而 `救回 0` ⇒ 旧 ID 一条都没命中，才轮到怀疑匹配/快照时刻。
    // 🔴 v0.0.130：两个数**仍然每轮都算**，只是「打」跟着节流走（读法已挪进上面那行一次性的）。
    if (doStillLog) {
        NBStoreLog(@"旧ID救回 %ld 条 / 带旧ID的行 %ld ｜ 两个数必须同一轮一起读（读法见上面「残留读法」那行）",
                   (long)altSaved, (long)altRows);
    }
    // 🔴 节流账本：打过的才刷新时间戳与签名；被省掉的累加，并且**在下一行里写出来**
    //    （「省了几轮」看不见 ⇒ 读的人会以为这个函数停了，那是比多几行更贵的误读）。
    if (doStillLog) {
        sStillLogTs = stillNow;
        sStillLogSig = stillSig;
        sStillLogSkip = 0;
    } else {
        sStillLogSkip++;
    }

    // 🔴 v0.0.115：年龄分档，一个进程只打一次（日志窗口只有 ~50 行，这条是定性用的）。
    //    `scanned > 0` 是必置位的前提：库是空的就打，会把唯一一次机会烧在与病因无关的轮次上
    //    （v0.0.111 `done` 写在最前面那个血账的同一形态）。
    if (!sAgeLogged && scanned > 0) {
        sAgeLogged = YES;
        NBStoreLog(@"全库残留按年龄：命中 <1h=%ld 1-6h=%ld 6-24h=%ld >24h=%ld ｜ 带ID <1h=%ld 1-6h=%ld 6-24h=%ld >24h=%ld",
                   (long)hitAge[0], (long)hitAge[1], (long)hitAge[2], (long)hitAge[3],
                   (long)allAge[0], (long)allAge[1], (long)allAge[2], (long)allAge[3]);
        // 🔴🔴 v0.0.116：上一版这条读法**写错了方向**，必须改。
        //    v0.0.115 只给了两种：「命中全挤在最新档 ⇒ 换 ID」/「各年龄都不命中 ⇒ 键对不上」。
        //    真机 2026-11-02 18:10:12 的读数（2/6、27/70、149/312、1/1775）**两种都不是** ——
        //    真实答案是第三种：命中率在三档里大致相同（33%/39%/48%），只有 **>24h 那档是 0**，
        //    因为那 1775 行比通知中心最老的（23.9 小时）还老，结构上不可能活着。
        //    ⇒ 判据的分类不全，就会把一次"正常"读成"没结论"，甚至读成"bug"。
        // 🔴🔴 v0.0.122：这一句的**前半段以前是错的**（v0.0.116~v0.0.121），必须改。
        //    旧口径的年龄是「现在 − ts」，而快照写于几千秒前 ⇒ `<1h` 档里那些行
        //    全部是"快照之后才发布"的 ⇒ 结构上不可能命中 ⇒ 恒 0。
        //    旧读法却写「<1h/1-6h/6-24h 三档都接近 0 才是真 bug」⇒ 一次正常的读数
        //    （0/29）会被读成"键对不上"。**读法写错，比没有读数更贵**。
        //    ⇒ 现在年龄基准是**快照时刻**，`<1h` 档 = 快照前 1 小时内发布的行，
        //      是有真实分母的档，必须参与判断。
        //    `>24h` 那段不变：那批行比通知中心最老的还老，结构上不可能活着。
        NBStoreLog(@"残留按年龄读法：年龄 = 快照时刻 − ts（**不是**「现在 − ts」），分母已排除快照之后才发布的行 ⇒ <1h 档 = 快照前 1 小时内发布那些，与 1-6h/6-24h 一起看；>24h 那档几乎必然是 0 —— 比通知中心最老的还老，结构上不可能活着，不是 bug、也不许拿它算百分比；已覆盖的三档都接近 0 才是键对不上（真 bug）");
        // 🔴 v0.0.116：这个数**不是稳定量**，必须写进日志，否则下次又会被当成"匹配坏了"。
        //    实测（同一份快照、同一批 2163 行、22 秒内）：179 → 91 → 2。
        //    机制：NC 成批重投时，库里那些行的 `sys_id` 正被成批改写成新 ID（同内容去重那条路），
        //    而快照还是重投**之前**写的那一份 ⇒ 两侧 ID 空间在同一个窗口里错开。
        NBStoreLog(@"⚠️ 残留是个移动靶：同一份快照 + 同一批行，实测 22 秒内 179→91→2 —— NC 成批重投时库里的 sys_id 正被改写成新 ID ⇒ 必须连「扫描于 N 秒前」和「本轮新增 N 条」一起看，离开重投窗口才稳定");
    }
    return still;
}


@end
