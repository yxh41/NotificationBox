//
//  NBDiagnostics.h
//  NotifyBox
//
//  v0.0.175：从 `NBSnoozeScheduler` 改名而来。
//
//  🔴 为什么改名：这个类原来装两样东西 ——「稍后提醒」（本地通知排期）和一批**只读诊断**。
//     v0.0.175 把「稍后提醒」整个删掉了（越狱 App 拿不到通知授权，真机实测
//     `/var/mobile/Library/UserNotifications/` 的 375 个条目里没有我们这一条，
//     `uicache` 也无效 ⇒ 那条路不通，功能下线）。
//     删完之后类里只剩诊断，而名字还叫 "SnoozeScheduler" —— 那是**文件名在主张
//     一个已经不存在的功能**，比没注释更误导（本项目为此栽过：注释留在原地主张死规则，
//     下游还长出了死分支）。
//
//  保留下来的都是**盒子本身**的排障读数，跟通知权限无关：
//    · 沙箱与数据：容器 / 文档目录 / 数据目录可读 / **写测试** / 记录数
//    · 装到磁盘 vs 正在跑：SpringBoard 里那个 dylib 是不是同一个版本
//    · 系统看到的身份：entitlements 逐项（含"没有这个键"这种结论）
//
//  ⚠️ 这些不是给用户看的装饰：删掉 `no-container` 换白名单那次，全靠这四行
//     才确认「记录没丢，是 App 看不见」和「白名单生效了」。留着。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NBDiagnostics : NSObject

// ---------- 完整自检报告（设置页「运行诊断」） ----------
//
// 一次拼好整份报告交给 UI。**纯只读**：
//   · 读目录用 `contentsOfDirectoryAtPath:`（只列名，不读内容）
//   · 开数据库用 `SQLITE_OPEN_READONLY`（诊断绝不能顺手建库改数据 ——
//     那会让"打不开"变成"打得开但空"，两种病混成一种，比不诊断更糟）
//   · 写测试写一个 `.nb_write_probe` 再删掉，不碰任何既有文件
//
// completion **一定在主线程**（调用方可以直接更新 UI）。
+ (void)fetchDiagnosticsReport:(nullable void (^)(NSString *report))completion;

// ---------- tweak dylib 版本对齐 ----------
//
// 🔴🔴 tweak 的 dylib 只在 SpringBoard 重启时重新加载。v0.0.173 起 postinst
// 不再自动重启（用户要求自己控制），于是「装了新版但没重启」是**必经状态**：
//     盒子 App = 新版；SpringBoard 里跑的 dylib = 旧版
// 用户看到的功能异常与「代码写错了」完全同形。
// 这个方法是把那个状态变成屏幕上的一句话（进 App 时弹一次）。
//
// 返回 nil = 版本一致（不打扰用户）；非 nil = 要显示的那段话。
+ (nullable NSString *)tweakVersionMismatchNotice;

@end

NS_ASSUME_NONNULL_END
