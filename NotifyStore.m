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
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:NOTIFYBOX_PREFS_PATH];
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

    // 实测写入：报 errno + strerror，比 isWritableFileAtPath 可靠
    NSString *probe = [dir stringByAppendingPathComponent:@".probe"];
    NSData *pd = [@"probe" dataUsingEncoding:NSUTF8StringEncoding];
    errno = 0;
    BOOL wok = [pd writeToFile:probe atomically:YES];
    int e1 = errno;
    [s appendFormat:@"  写入测试=%@  errno=%d(%s)\n", wok ? @"成功" : @"失败", e1, strerror(e1)];
    if (wok) [fm removeItemAtPath:probe error:nil];

    [s appendFormat:@"\n── DB ──\n%@\n", NOTIFYBOX_DB_PATH];
    NSDictionary *da = [fm attributesOfItemAtPath:NOTIFYBOX_DB_PATH error:nil];
    [s appendFormat:@"  存在=%@  大小=%llu B  记录数=%ld\n",
        [fm fileExistsAtPath:NOTIFYBOX_DB_PATH] ? @"是" : @"否",
        [da[NSFileSize] unsignedLongLongValue], (long)[self count]];

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

    // dylib 装在哪儿？不同越狱方案前缀不同，逐个探一遍（探不到也没关系）
    [s appendString:@"\n── dylib 安装位置 ──\n"];
    NSArray *cands = @[
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/NotifyBox.dylib",
        @"/Library/MobileSubstrate/DynamicLibraries/NotifyBox.dylib",
        @"/var/jb/usr/lib/TweakInject/NotifyBox.dylib",
        @"/usr/lib/TweakInject/NotifyBox.dylib",
        @"/var/jb/usr/lib/ellekit/NotifyBox.dylib",
    ];
    BOOL anyDylib = NO;
    for (NSString *p in cands) {
        if ([fm fileExistsAtPath:p]) {
            NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
            [s appendFormat:@"  ✅ %@  %llu B\n", p, [a[NSFileSize] unsignedLongLongValue]];
            anyDylib = YES;
        }
    }
    if (!anyDylib) {
        [s appendString:@"  ❓ 以上路径都没找到（roothide 前缀可能被重定向，属正常）\n"];
        [s appendString:@"     ⇒ 去包管理器里确认版本号是不是 0.0.6\n"];
    }

    [s appendString:@"\n── 注入过滤器 ──\n"];
    NSArray *plists = @[
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/NotifyBox.plist",
        @"/Library/MobileSubstrate/DynamicLibraries/NotifyBox.plist",
    ];
    BOOL anyPl = NO;
    for (NSString *p in plists) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) {
            [s appendFormat:@"  ✅ %@ ⇒ %@\n", p, d[@"Filter"] ?: @"(无 Filter 键)"];
            anyPl = YES;
        }
    }
    if (!anyPl) [s appendString:@"  ❓ 未读到过滤器 plist\n"];

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
    return [NSString stringWithFormat:
            @"DB 路径：%@\n存在：%@    大小：%llu B\n可读：%@    可写：%@\n记录数：%ld    上限：%ld",
            NOTIFYBOX_DB_PATH,
            exists ? @"是" : @"否", size,
            [fm isReadableFileAtPath:NOTIFYBOX_DB_PATH] ? @"是" : @"否",
            [fm isWritableFileAtPath:NOTIFYBOX_DB_PATH] ? @"是" : @"否",
            (long)n, (long)[self maxRecords]];
}

@end
