//
//  NBTextExtract.h
//  NotifyBox
//
//  v0.0.166：从通知正文里抽「能立刻用起来」的东西 —— 链接、验证码。
//
//  🔴 为什么单独成文件、而且做成纯函数：
//     ① 列表长按菜单和详情页都要用它，写两处必然走岔（本项目反复记的一类）；
//     ② 它不碰数据库、不碰视图 ⇒ 以后要拿到别的地方（规则测试器、导出）直接调用。
//
//  🔴 纪律：**抽不到就返回 nil，绝不返回"大概能用"的东西。**
//     调用方只在非 nil 时才显示菜单项 —— 摆一个点了没反应的动作比不摆更糟。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NBTextExtract : NSObject

/// 第一段看起来能打开的链接（`scheme://…`）。抽不到返回 nil。
/// 🔴 会剔掉尾部的中文标点和句读（"详见 https://a.com/b。" 里那个句号不属于链接）。
+ (nullable NSString *)firstLinkInText:(nullable NSString *)text;

/// 验证码。返回**纯数字串**（4~8 位），抽不到返回 nil。
/// 🔴 必须同时满足：正文里有「验证码/校验码/动态码…」这类词，且数字是独立的、不挨着
///    「尾号/单号/订单/金额」这些词 —— 否则「尾号 1234 消费」会被当成验证码复制出去。
+ (nullable NSString *)verificationCodeInText:(nullable NSString *)text;

@end

NS_ASSUME_NONNULL_END
