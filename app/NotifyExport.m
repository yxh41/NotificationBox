#import "NotifyExport.h"

@implementation NotifyExport

+ (NSString *)csvField:(NSString *)value {
    NSString *s = value ?: @"";
    // 🔴 顺序不能反：先翻倍引号、再整体包引号。
    //    反过来的话，翻倍这一步会把刚加上去的外层引号也翻倍 ⇒ 每行多出一堆 `"`。
    s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
    return [NSString stringWithFormat:@"\"%@\"", s];
}

+ (NSString *)csvFromRows:(NSArray<NSDictionary *> *)rows
                appNames:(NSDictionary<NSString *, NSString *> *)appNames {
    // 🔴 BOM 不是装饰：Windows / Excel 不认 UTF-8 的中文 CSV，
    //    没有这三个字节打开就是一片乱码，而用户只会说"导出的文件坏了"。
    NSMutableString *out = [NSMutableString stringWithString:@"\uFEFF"];

    NSArray<NSString *> *head = @[@"时间", @"App 名", @"bundle", @"标题", @"副标题", @"正文", @"已读"];
    NSMutableArray<NSString *> *hl = [NSMutableArray array];
    for (NSString *h in head) [hl addObject:[self csvField:h]];
    [out appendString:[hl componentsJoinedByString:@","]];
    [out appendString:@"\r\n"];
    // 🔴 换行用 CRLF：CSV 的惯例，Excel 用 \n 也能认，但 Numbers/部分工具会把整份当成一行。

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    // 🔴 导出用**完整**日期（列表里只显示 MM-dd HH:mm 是为了省地方，
    //    备份文件里少写年份就等于"以后看不出这是哪年的记录"）。
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

    for (NSDictionary *d in rows) {
        NSString *bid = d[@"bundle"] ?: @"";
        NSString *app = appNames[bid];
        if (!app.length) app = bid;                 // 映射里没有 ⇒ 退化成 bundle，不留空
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:[d[@"ts"] doubleValue]];

        NSMutableArray<NSString *> *f = [NSMutableArray array];
        [f addObject:[self csvField:[fmt stringFromDate:date]]];
        [f addObject:[self csvField:app]];
        [f addObject:[self csvField:bid]];
        [f addObject:[self csvField:d[@"title"]]];
        [f addObject:[self csvField:d[@"subtitle"]]];
        [f addObject:[self csvField:d[@"message"]]];
        [f addObject:[self csvField:([d[@"read"] integerValue] == 0 ? @"未读" : @"已读")]];
        [out appendString:[f componentsJoinedByString:@","]];
        [out appendString:@"\r\n"];
    }
    return out;
}

+ (NSURL *)writeTempCSV:(NSString *)csv baseName:(NSString *)baseName {
    if (!csv.length) return nil;
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyyMMdd-HHmm";
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSString *stamp = [f stringFromDate:[NSDate date]];
    NSString *name = [NSString stringWithFormat:@"%@-%@.csv",
                      baseName.length ? baseName : @"notifybox", stamp];

    NSString *dir = NSTemporaryDirectory();
    NSString *path = [dir stringByAppendingPathComponent:name];
    NSError *err = nil;
    // 🔴 必须写 **UTF-8 原始字节**（`writeToFile:atomically:` 会把 NSString 写成 UTF-8，
    //    但它顺手做的"原子写"在临时目录里没必要，且失败原因更难读）⇒ 直接写 data。
    NSData *data = [csv dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return nil;
    BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&err];
    if (!ok) {
        NSLog(@"[NotifyExport] 写文件失败 %@ : %@", path, err);
        return nil;
    }
    return [NSURL fileURLWithPath:path];
}

@end
