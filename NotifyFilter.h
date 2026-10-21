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

// v0.0.14：把「把一堆规则按顺序套到一段文字上」抽成**纯函数**，给 App 侧复用
//           （内容替换页的「试运行」和「这条规则真的改过几条通知」都用它）。
//
// 🔴🔴 为什么必须是同一个函数：如果 App 自己再写一份顺序套用，两边一旦有一点点不一样，
//       用户看到的试运行结果就是**假的** —— 假结果比没有结果更坏（他会照着一个错的结果去调规则）。
//
// rules：形如 @[@{@"from": 原文, @"to": 替换成}]，允许有非法项（会被跳过）。
// hits ：可为 nil；不为 nil 时**必须与 rules 等长**，某条规则真的把文字改动了就 +1。
//        传进来的数组必须是可变的、且已经预填好足够的 @0（本函数不负责扩数组）。
+ (NSString *)applyRulesToString:(nullable NSString *)text
                           rules:(nullable NSArray *)rules
                            hits:(nullable NSMutableArray<NSNumber *> *)hits;

// v0.0.14：把 settings 里的 replaceRules（可能是任意脏数据）归一成 @[{from,to}]。
//          引擎与 App 都用这一份口径 ⇒ 不会出现「界面认为有 5 条、引擎只认 4 条」。
+ (NSArray<NSDictionary *> *)normalizedRules:(nullable id)raw;

// v0.0.14：延迟推送判定。
// 返回 YES ⇒ 这条通知要延后 *seconds 秒再发布。
// 关闭条件（任一）：没配 delaySeconds / 配了 0 或非数字 / delayApps 里有值但这条的 bundle 不在里面。
// seconds 会夹在 1~600：用户填 86400 就等于让通知永远不出现，那不该被当成"设置成功"。
+ (BOOL)shouldDelayBundle:(nullable NSString *)bundle seconds:(NSTimeInterval *)seconds;

@end

NS_ASSUME_NONNULL_END
