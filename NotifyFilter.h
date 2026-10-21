#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 🔴 BBBulletin 最小接口（只声明我们用到的属性；真机用 Flex3 核对 iOS 16 实际属性名）
@interface BBBulletin : NSObject
@property (nonatomic, copy) NSString *sectionID;   // 通常是 App 的 bundleId
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, strong, nullable) NSDate *date;   // 通知时间
@property (nonatomic, retain, nullable) id sound;       // 换提示音用（见 applyReplaceRulesTo）
@end

@interface NotifyFilter : NSObject

// 🔴 v0.0.8：改成**纯字符串**接口。
//    原因：三个挂点里传进来的对象不一定是 BBBulletin（有的版本是 request 包装类），
//    直接对它发 `[obj sectionID]` 一旦它不响应就是 NSInvalidArgumentException ⇒
//    在 SpringBoard 里等于闪退。字符串接口完全不碰传入对象，从根上没有这个风险。
//    判定口径：命中黑名单 / 白名单不符 / 命中过滤关键词 ⇒ YES（拦掉呈现）。
//    任何异常都返回 NO —— **宁可多推一条，不可把通知吞了**。
+ (BOOL)shouldDropBundle:(nullable NSString *)bundle
                   title:(nullable NSString *)title
                 message:(nullable NSString *)message
                subtitle:(nullable NSString *)subtitle;

// 内容替换（预设规则）：只对**真正响应 getter+setter** 的对象动手，逐个探。
// 返回 YES 表示真的改过。默认无规则 ⇒ 直接返回 NO，行为与不装插件一致。
+ (BOOL)applyReplaceRulesTo:(nullable id)bulletin;

@end

NS_ASSUME_NONNULL_END
