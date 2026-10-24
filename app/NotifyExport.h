#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// v0.0.44：把记录导出成 CSV 文件。
//
// 🔴 为什么要独立一个类：**"导出"这件事有两处很容易做错，而且错了不报错** ——
//    ① CSV 转义（正文里有逗号/引号/换行 ⇒ 不转义就是一份错列的文件，肉眼还看不出来）；
//    ② 编码（不加 BOM 的话 Excel 打开中文全是乱码，而"乱码"会被当成"文件坏了"）。
//    把它们收在一处，才能用判据盯住。
//
// 🔴 App 显示名由外面传进来（`bundle -> 名字` 的映射）：
//    库里只有 `com.tencent.xin`，"微信"这两个字只有界面层的 `InstalledApps` 知道
//    （和 v0.0.42 搜索匹配 App 名是同一个理由）。
@interface NotifyExport : NSObject

// 生成 CSV 文本。`appNames` 可为 nil（那时「App 名」列退化为 bundle id，不会空着）。
+ (NSString *)csvFromRows:(NSArray<NSDictionary *> *)rows
                appNames:(nullable NSDictionary<NSString *, NSString *> *)appNames;

// 落成一个临时文件，返回它的 URL（失败返回 nil）。
// 🔴 文件名带**时间戳**：同一天导出两次不会互相覆盖，
//    而"覆盖了上一次的备份"是备份功能最不能犯的错。
+ (nullable NSURL *)writeTempCSV:(NSString *)csv baseName:(NSString *)baseName;

// CSV 转义：字段一律加引号，内部的 `"` 翻倍。
// 🔴 一律加引号（而不是"含逗号才加"）：条件判断一多就有漏，
//    而漏掉一个含换行的字段 ⇒ 那一条记录被拆成两行，整份文件的列就全错了。
+ (NSString *)csvField:(nullable NSString *)value;

@end

NS_ASSUME_NONNULL_END
