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

// 🔴🔴 延迟推送：v0.0.19 **功能整体删除**（连接口一起撤掉，不是停用）。
//
// 两版实现各撞死一次，且死法不同 —— 结论是「延迟」这件事在当前注入位置做不到：
//   ① v0.0.14「攒进 dispatch_after 再调原方法」⇒ SIGTRAP。
//      栈：_dispatch_assert_queue_fail ← dispatch_assert_queue
//          ← -[BBServer dataProviderForSectionID:] +44 ← tweak ← GCD 定时器 ← 主队列
//      ⇒ BBServer 的方法内部要求「必须在 BB 自己的私有串行队列上」，那个队列句柄
//        只活在 BBServer 内部、外面拿不到 ⇒ 换哪个队列都不对。**跨队列这条路无解。**
//   ② v0.0.16「只把时间字段往后写，让系统自己改期」⇒ 通知全不弹。
//      真机日志：PBRS 只改到 date、PBR 被幂等跳过、PB 却改到 date+publicationDate+
//      expirationDate —— 同一秒内同一条通知。⇒ 三个入口拿到的是**不同包装对象**
//      （request / bulletin），对象级关联标记跨不过去。
//      更致命的是：**改排期字段不是"延后发布一次"，是"要求系统改期"**。系统每次重排
//      都会重新走发布入口、拿到新包装对象 ⇒ 对象级幂等永远失效 ⇒ 每重排一次再 +5 秒
//      ⇒ 这条通知永远到不了。用户的真实现场就是"一条都不弹"。
//
// ⇒ 接口在这里全部撤掉（不是加一个常量门）。留着带 `dateByAddingTimeInterval` 的死代码
//   等于把一把已经伤过两次的刀留在抽屉里 —— 谁改一个字就能再打开，而它一旦打开
//   用户是"通知全没"这种最难归因的症状。要恢复必须先推翻上面两条真机证据。
//   校验脚本 nb_delay_gate.py 会把「二进制里不许出现改时间字段」当成硬判据。

// ---------- v0.0.21：免打扰时段 ----------
// 命中的通知**不弹**（同黑名单语义），但照常记进盒子。
// 返回 YES 表示"当前时间落在免打扰时段内，且这条通知的 App 在范围内"。
// reason 非空时写入一段人话（形如 "23:00~07:00"），供调用方留痕。
//
// 🔴 任何异常、任何"设置没配全"的情况一律返回 NO ——
//    这个功能的失效方式必须是"照常弹"，绝不能是"莫名其妙全都不弹"。
//    （开始时间 == 结束时间也按 NO 处理：那本来会等价于"全天不弹"，是个灾难性误配。）
+ (BOOL)shouldDropForDND:(nullable NSString *)bundle
                     now:(nullable NSDate *)now
                  reason:(NSString * _Nullable * _Nullable)reason;

// ---------- v0.0.21：按 App 换提示音（实验） ----------
// 返回 YES 表示**这条命中了规则、已经动手尝试过**（成没成看 result）；
// 返回 NO 表示不适用（功能关 / 没配 App / 这条 App 不在名单 / 没填数）。
// result 非空时写入"发生了什么"，形如 "id=1007 cls=BBSound" 或 "throw:NSInvalidArgumentException"。
// 🔴 调用方必须把 result 原样打进日志：这个功能是"造系统对象"，
//    沉默的失败等于"用户设了没效果，还查不出原因"。
+ (BOOL)applySoundForBundle:(nullable NSString *)bundle
                 toBulletin:(nullable id)bulletin
                  forResult:(NSString * _Nullable * _Nullable)result;

// v0.0.22：这个 App 是不是「该换提示音」（开关开 + 名单里有它 + ID 合法）。
// 🔴 给诊断用。判定口径与 applySoundForBundle **同源**（都走 soundVerdictForBundle），
//    不允许在诊断里另写一份 —— 两边走岔的后果见 notifybox/README.md v0.0.22 章。
+ (BOOL)isSoundTargetBundle:(nullable NSString *)bundle;

// v0.0.21：换提示音的崩溃自愈（只在 SpringBoard 的构造函数里调一次）。
// 返回 YES 表示"上次就是崩在换提示音里，已经把这个开关关掉了"，**并且已回读确认**。
+ (BOOL)recoverFromSoundCrashIfNeeded;

@end

NS_ASSUME_NONNULL_END
