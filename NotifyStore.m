#import "NotifyStore.h"
#import "NotifyCommon.h"
#import <sqlite3.h>
#import <errno.h>
#import <string.h>

// 写库失败要留痕：区分「hook 没触发」与「触发了但写不进」
static void NBStoreLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[NOTIFYBOX_LOG_PATH stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *d = [[NSString stringWithFormat:@"[STORE %@] %@\n",
                  [NSDate date], msg] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:NOTIFYBOX_LOG_PATH];
    if (fh) { @try { [fh seekToEndOfFile]; [fh writeData:d]; } @finally { [fh closeFile]; } }
    else { [d writeToFile:NOTIFYBOX_LOG_PATH atomically:YES]; }
}

// ---------- 统一日志（tweak / App / 新模块共用） ----------
// 🔴 从 Tweak.x 搬过来的，逻辑逐字保持：超过 512 KB 就切成 .1（覆盖上一份），
//    避免长期运行把分区写满。用计数器节流：不是每次写都 stat，每 200 次看一眼。
void NBSharedLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

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
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:NOTIFYBOX_LOG_PATH];
    if (fh) {
        @try { [fh seekToEndOfFile]; [fh writeData:d]; }
        @finally { [fh closeFile]; }
    } else {
        [d writeToFile:NOTIFYBOX_LOG_PATH atomically:YES];
    }
}

@implementation NotifyStore

+ (void)ensureDir {
    NSString *dir = [NOTIFYBOX_DB_PATH stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

+ (sqlite3 *)openDB {
    [self ensureDir];
    sqlite3 *db = NULL;
    if (sqlite3_open([NOTIFYBOX_DB_PATH UTF8String], &db) != SQLITE_OK) return NULL;
    const char *sql = "CREATE TABLE IF NOT EXISTS notifications ("
                      "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                      "bundle TEXT, title TEXT, message TEXT, subtitle TEXT, "
                      "ts REAL, read INTEGER DEFAULT 0, hash TEXT);"
                      "CREATE INDEX IF NOT EXISTS idx_bundle ON notifications(bundle);"
                      "CREATE INDEX IF NOT EXISTS idx_ts ON notifications(ts);";
    sqlite3_exec(db, sql, NULL, NULL, NULL);
    return db;
}

+ (NSInteger)maxRecords {
    // v0.0.8：走统一入口（新 settings.plist 优先，旧 Preferences 域兜底、只读）
    NSDictionary *p = NBLoadSettings();
    id v = p[@"maxRecords"];
    NSInteger n = v ? [v integerValue] : 500;
    return (n > 0 && n < 100000) ? n : 500;
}

+ (void)recordWithBundle:(NSString *)bundle
                   title:(NSString *)title
                 message:(NSString *)message
               subtitle:(NSString *)subtitle
                    date:(NSDate *)date {
    if (!bundle.length) return;
    sqlite3 *db = [self openDB];
    if (!db) {
        NBStoreLog(@"openDB 失败 path=%@ err=%s", NOTIFYBOX_DB_PATH, sqlite3_errmsg(db));
        return;
    }

    const char *ins = "INSERT INTO notifications (bundle,title,message,subtitle,ts,hash) "
                      "VALUES (?,?,?,?,?,?)";
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(db, ins, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [bundle UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, [title ?: @"" UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, [message ?: @"" UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 4, [subtitle ?: @"" UTF8String], -1, SQLITE_TRANSIENT);
        double ts = date ? [date timeIntervalSince1970] : [[NSDate date] timeIntervalSince1970];
        sqlite3_bind_double(stmt, 5, ts);
        NSString *h = [NSString stringWithFormat:@"%@|%@|%@", bundle, title ?: @"", message ?: @""];
        NSData *hd = [h dataUsingEncoding:NSUTF8StringEncoding];
        sqlite3_bind_text(stmt, 6, [[hd description] UTF8String], -1, SQLITE_TRANSIENT);
        int rc = sqlite3_step(stmt);
        if (rc != SQLITE_DONE) {
            NBStoreLog(@"INSERT 失败 rc=%d err=%s bundle=%@", rc, sqlite3_errmsg(db), bundle);
        }
        sqlite3_finalize(stmt);
    } else {
        NBStoreLog(@"prepare 失败 err=%s", sqlite3_errmsg(db));
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

+ (NSArray<NSDictionary *> *)queryWithBundle:(NSString *)bundle
                                       since:(NSTimeInterval)since
                                      search:(NSString *)q {
    NSMutableArray *res = [NSMutableArray array];
    sqlite3 *db = [self openDB];
    if (!db) return res;

    NSMutableString *sql = [NSMutableString stringWithString:
        @"SELECT id,bundle,title,message,subtitle,ts,read FROM notifications WHERE 1=1"];
    if (bundle.length) [sql appendString:@" AND bundle=?"];     // 顶部 App 图标筛选
    if (since > 0)     [sql appendString:@" AND ts>=?"];         // 时间筛选
    if (q.length)      [sql appendString:@" AND (title LIKE ? OR message LIKE ?)"]; // 搜索
    [sql appendString:@" ORDER BY ts DESC LIMIT 2000"];

    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &st, NULL) == SQLITE_OK) {
        int i = 1;
        if (bundle.length) sqlite3_bind_text(st, i++, [bundle UTF8String], -1, SQLITE_TRANSIENT);
        if (since > 0)     sqlite3_bind_double(st, i++, (double)since);
        if (q.length) {
            NSString *like = [NSString stringWithFormat:@"%%%@%%", q];
            sqlite3_bind_text(st, i++, [like UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, i++, [like UTF8String], -1, SQLITE_TRANSIENT);
        }
        while (sqlite3_step(st) == SQLITE_ROW) {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            d[@"id"]       = @(sqlite3_column_int(st, 0));
            d[@"bundle"]   = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(st, 1) ?: ""];
            d[@"title"]    = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(st, 2) ?: ""];
            d[@"message"]  = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(st, 3) ?: ""];
            d[@"subtitle"] = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(st, 4) ?: ""];
            d[@"ts"]       = @(sqlite3_column_double(st, 5));
            d[@"read"]     = @(sqlite3_column_int(st, 6));
            [res addObject:d];
        }
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

+ (void)markRead:(NSInteger)rowId {
    sqlite3 *db = [self openDB];
    if (!db) return;
    sqlite3_exec(db, [[NSString stringWithFormat:@"UPDATE notifications SET read=1 WHERE id=%ld", (long)rowId] UTF8String], NULL, NULL, NULL);
    sqlite3_close(db);
}

+ (void)clearAll {
    sqlite3 *db = [self openDB];
    if (!db) return;
    sqlite3_exec(db, "DELETE FROM notifications", NULL, NULL, NULL);
    sqlite3_close(db);
}

+ (NSDictionary *)settings {
    return NBLoadSettings();
}

+ (BOOL)saveSettings:(NSDictionary *)settings {
    [self ensureDir];       // settings.plist 与 DB 同目录，目录建好就能写
    return [(settings ?: @{}) writeToFile:NOTIFYBOX_SETTINGS_PATH atomically:YES];
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

+ (void)markAppAlive {
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NBStoreLog(@"[APP-ALIVE] 盒子App 启动 v%@ · 说明此路径本 App 可写", ver);
}

+ (NSString *)envCheck {
    NSMutableString *s = [NSMutableString string];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NOTIFYBOX_DB_PATH stringByDeletingLastPathComponent];

    [s appendFormat:@"── 路径 ──\n目录 %@\n", dir];
    BOOL dirExists = [fm fileExistsAtPath:dir];
    [s appendFormat:@"  存在=%@  可写=%@\n", dirExists ? @"是" : @"否",
        [fm isWritableFileAtPath:dir] ? @"是" : @"否"];
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
    sqlite3 *ldb = [self openDB];
    if (ldb) {
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(ldb, "SELECT MAX(ts) FROM notifications;", -1, &st, NULL) == SQLITE_OK) {
            if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_type(st, 0) != SQLITE_NULL) {
                latest = sqlite3_column_double(st, 0);
            }
            sqlite3_finalize(st);
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

    [s appendFormat:@"\n── 日志 ──\n%@\n", NOTIFYBOX_LOG_PATH];
    NSDictionary *la = [fm attributesOfItemAtPath:NOTIFYBOX_LOG_PATH error:nil];
    BOOL logExists = (la != nil);
    [s appendFormat:@"  存在=%@  大小=%llu B\n", logExists ? @"是" : @"否",
        [la[NSFileSize] unsignedLongLongValue]];
    if (logExists && la[NSFileModificationDate]) {
        [s appendFormat:@"  最后修改=%@\n", la[NSFileModificationDate]];
    }

    // 🔴 与日志独立的「tweak 跑过」标记：用来区分「没注入」和「写日志失败」
    NSString *mark = [dir stringByAppendingPathComponent:@".tweak_ctor"];
    NSString *mtxt = [NSString stringWithContentsOfFile:mark
                                               encoding:NSUTF8StringEncoding error:nil];
    if (mtxt.length) {
        [s appendFormat:@"\n── tweak 装载标记 ──\n  ✅ %@\n  内容=%@\n", mark,
            [mtxt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        [s appendString:@"  ⇒ tweak 确实注入过；若日志缺失则是写日志环节的问题\n"];
    } else {
        [s appendFormat:@"\n── tweak 装载标记 ──\n  ❌ %@ 不存在\n", mark];
        [s appendString:@"  ⇒ tweak 从未注入任何进程（或装了没 respring、或过滤器未命中）\n"];
    }

    // dylib 装在哪：优先用 tweak 自己用 dladdr 报出来的路径（roothide 会重定向前缀，
    // App 侧猜路径基本猜不中），猜不到才退回逐个探测。
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
        NSArray *keys = [[cfg allKeys] sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *k in keys) {
            NSString *v = [cfg[k] description] ?: @"";
            if (v.length > 60) v = [[v substringToIndex:60] stringByAppendingString:@"..."];
            [s appendFormat:@"    %@ = %@\n", k, v];
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
    BOOL exists = [fm fileExistsAtPath:NOTIFYBOX_DB_PATH];
    NSDictionary *attrs = [fm attributesOfItemAtPath:NOTIFYBOX_DB_PATH error:nil];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    NSInteger n = [self count];
    NSMutableString *s = [NSMutableString stringWithFormat:
            @"DB 路径：%@\n存在：%@    大小：%llu B\n可读：%@    可写：%@\n记录数：%ld    上限：%ld",
            NOTIFYBOX_DB_PATH,
            exists ? @"是" : @"否", size,
            [fm isReadableFileAtPath:NOTIFYBOX_DB_PATH] ? @"是" : @"否",
            [fm isWritableFileAtPath:NOTIFYBOX_DB_PATH] ? @"是" : @"否",
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

@end
