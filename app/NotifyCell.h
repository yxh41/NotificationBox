#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 列表 cell（v0.0.10）
// 🔴🔴 之前「只有标题、没有内容」的根因：
//    列表用 `registerClass:[UITableViewCell class]` 注册，它建出来的是 **Default 样式**，
//    而 Default 样式里 **`detailTextLabel` 压根不显示**（它是 nil 或不可见）。
//    代码一直在往 detailTextLabel 上写正文 ⇒ 写了但永远看不见。
//    ⇒ 要么在 dequeue 返回 nil 时自己 `initWithStyle:UITableViewCellStyleSubtitle`，
//      要么干脆自定义 cell（本类，还能顺手放图标）。
@interface NotifyCell : UITableViewCell

// 图标：传 nil 时显示首字母色块（退化态，不能什么都不显示）
- (void)setIcon:(nullable UIImage *)icon letter:(nullable NSString *)letter;

- (void)setTitleText:(nullable NSString *)title
             message:(nullable NSString *)message
            subtitle:(nullable NSString *)subtitle;

- (void)setTimeText:(nullable NSString *)text;

// v0.0.35：未读标记（左侧 8pt 蓝点）。
// 🔴 为什么用"点"而不是"标题加粗/变灰"：
//    15pt semibold 到 bold 在小屏上几乎看不出差别；而"已读标题变灰"会让整屏发灰，
//    用户第一眼会以为列表坏了。侧面一个点是最不打扰、又一眼能数的做法。
// 🔴 传 NO 时点必须**真的消失**（hidden），不能只改颜色 —— 未读和已读要能"数出来"。
- (void)setUnread:(BOOL)unread;

+ (CGFloat)height;

@end

NS_ASSUME_NONNULL_END
