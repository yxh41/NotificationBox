#import "NotifyStore.h"
#import "NotifyCommon.h"
#import <sqlite3.h>
#import <errno.h>
#import <string.h>

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
                      "ts REAL, read INTEGER DEFAULT 0, hash TEXT);"
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
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &st, NULL) != SQLITE_OK) return @[];
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
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &st, NULL) != SQLITE_OK) return NULL;
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

// v0.0.44：把"一行结果 → 字典"抽成一份。
// 🔴 列表和导出现在共用它 —— 两处各抄一遍列号，改 SELECT 时必然有一处漏改，
//    而那种错不会报错，只会让某一列悄悄变成空串。
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
    NSString *head = unreadOnly
        ? @"SELECT id,bundle,title,message,subtitle,ts,read FROM notifications WHERE read=0"
        : @"SELECT id,bundle,title,message,subtitle,ts,read FROM notifications WHERE 1=1";
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
        ? @"SELECT id,bundle,title,message,subtitle,ts,read FROM notifications WHERE read=0"
        : @"SELECT id,bundle,title,message,subtitle,ts,read FROM notifications WHERE 1=1";
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
+ (void)markRead:(NSInteger)rowId {
    sqlite3 *db = [self openDB];
    if (!db) return;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "UPDATE notifications SET read=1 WHERE id=?", -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(st, 1, (sqlite3_int64)rowId);
        if (sqlite3_step(st) != SQLITE_DONE) {
            NBStoreLog(@"markRead 失败 id=%ld err=%s", (long)rowId, sqlite3_errmsg(db));
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
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
    sqlite3 *db = [self openDB];
    if (!db) return NO;
    BOOL ok = NO;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "DELETE FROM notifications WHERE id=?", -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(st, 1, (sqlite3_int64)rowId);
        ok = (sqlite3_step(st) == SQLITE_DONE) && (sqlite3_changes(db) > 0);
        sqlite3_finalize(st);
    }
    if (!ok) NBStoreLog(@"DELETE 未删到 id=%ld err=%s", (long)rowId, sqlite3_errmsg(db));
    sqlite3_close(db);
    return ok;
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
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &st, NULL) != SQLITE_OK) return NULL;
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
