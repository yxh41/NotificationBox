#import "NotifyStore.h"
#import "NotifyCommon.h"
#import <sqlite3.h>

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
