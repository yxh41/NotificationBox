#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 一个可选中的 App（v0.0.13）
@interface InstalledApp : NSObject

@property (nonatomic, copy)   NSString *bundleId;
@property (nonatomic, copy)   NSString *name;        // 显示名，取不到就退回 bundle 末段
@property (nonatomic, assign) NSInteger noteCount;   // 盒子里这个 App 的记录条数（0 = 还没来过通知）
// YES ⇒ 枚举不到它，只是历史记录里有。典型是「App 已卸载但记录还在」，
// 也可能是枚举那条路本身没走通。两种情况都该让用户看到并能够取消勾选。
@property (nonatomic, assign) BOOL onlyInHistory;

@end

// 已安装 App 枚举
//
// 🔴 为什么要独立一个类：**这件事在越狱环境里没有一条保证成功的路**，
//    而且失败是静默的（列表空 ⇒ 用户以为"我手机没装 App"）。
//    LSApplicationWorkspace 是私有 API，能不能用取决于 CoreServices 有没有加载、
//    以及 App 自身的权限；目录布局又因 roothide 的前缀重定向而变。
//    所以这里做三件事：多路依次尝试 + 记下每条路的成败 + 最后用数据库历史兜底。
//    任何一条路通了，用户就能选 App；全都不通时诊断行会说明为什么。
@interface InstalledApps : NSObject

// 全部候选 App，已按「有通知的优先、其次按名称」排好序。带缓存。
+ (NSArray<InstalledApp *> *)all;

// 哪条路走通了、各拿到多少个。给人看的一行人话。
+ (NSString *)diagReport;

// 清缓存（重新枚举）
+ (void)clearCache;

@end

NS_ASSUME_NONNULL_END
