#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// v0.0.33：通知详情页 —— 看**全文**、复制、删单条。
//
// 为什么需要它：列表 `NotifyCell` 的正文 `numberOfLines = 2`，超了截断；
// 而点一行原来只做 `markRead:` ⇒ **长通知永远看不全、也复制不了**。
// 对「消息盒子」来说这是核心缺口：验证码、链接、长消息都看不全，等于记录没记全。
@interface NotifyDetailViewController : UIViewController

// 一条记录（`NotifyStore queryWithBundle:since:search:` 返回的字典）。
@property (nonatomic, copy, nullable) NSDictionary *item;

// 删除成功后回调。**由列表页负责重查数据库** ——
// 详情页绝不直接改列表的数据源：在「搜索 / App 筛选 / 时间段」状态下，
// 内存下标和数据库对不上，只改内存就是"只改账本的读数"（数量契约第 2 问）。
@property (nonatomic, copy, nullable) void (^onDeleted)(void);

@end

NS_ASSUME_NONNULL_END
