#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 🔴 BBBulletin 最小接口（只声明我们用到的属性；真机用 Flex3 核对 iOS 16 实际属性名）
@interface BBBulletin : NSObject
@property (nonatomic, copy) NSString *sectionID;   // 通常是 App 的 bundleId
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, strong, nullable) NSDate *date;   // 通知时间
@property (nonatomic, retain, nullable) id sound;       // 换提示音用（见 applyToBulletin）
@end

@interface NotifyFilter : NSObject

// 是否拦截「呈现」（黑名单 / 白名单不符 / 命中过滤关键词）。记录已在此之前完成。
+ (BOOL)shouldDrop:(BBBulletin *)bulletin;

// 发布前改 bulletin：内容替换 + 按 App 换提示音。
+ (void)applyToBulletin:(BBBulletin *)bulletin;

@end

NS_ASSUME_NONNULL_END
