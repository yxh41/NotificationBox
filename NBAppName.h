// NBAppName.h —— v0.0.45：App 显示名解析，**盒子 App 与 tweak 共用一份**。
//
// 🔴🔴 为什么要抽出来（这是 v0.0.42 / v0.0.43 / v0.0.44 连着三版没修好的直接后果）：
//
//   用户报的是「京东显示的不是『京东』两个字」「信息 App 显示的不是『信息』」。
//   三版的改法都在**盒子 App 进程里**打转（换字段、加汉字优先、加"取更短"），
//   但都没碰一个前提：**盒子 App 是一个有沙盒的 App**。
//
//   名字最权威的来源不是 `LSApplicationProxy.localizedName`（那是 App Store 的
//   **商品名**，常带「-购物商城」这类副标题），而是 **App 自己 bundle 里本地化过的
//   `CFBundleDisplayName`** —— 那才是 SpringBoard 画在图标底下的那个字。
//   而桌面上的用户 App 装在 `/var/containers/Bundle/Application/<UUID>/Xxx.app`，
//   **沙盒 App 读不到那一层**。
//
//   ⇒ 正解不是"在没权限的地方再猜一轮"，而是**让有权限的进程把名字算好送来**。
//     tweak 注入的是 SpringBoard（root、能读所有 bundle），由它在后台解析并写进
//     `app_names` 表；盒子 App 只管读表。两边必须用**同一份**解析代码，
//     否则又变成"两处抄两遍、必有一处先改"。
//
// 🔴 这个文件同时编进 tweak 和 App 两个目标 ⇒ **不许 import UIKit**，
//    也**不许**引用任何只在一侧存在的东西（见 Makefile 两个 FILES 都要加 NBAppName.m）。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 读一个**字符串**键（KVC + 逐键 @try + 类型校验 + 去空白）。键不存在/类型不对/抛异常 ⇒ nil。
// 也对外导出：目录扫描那条路要拿 `CFBundleIdentifier`，规则和名字键是同一套。
NSString * _Nullable NBStrForKey(id obj, NSString *key);

// 名字里有没有汉字（含 CJK 部首 / 兼容汉字 / 全角标点）。
BOOL NBHasCJK(NSString *s);

// 最后一层兜底：bundle 末段（`com.xiaomi.mihome` → `mihome`）。
NSString *NBLastSegmentName(NSString *bid);

// 在若干候选里挑一个：
//   ① **有汉字 > 没汉字**（用户的手机是中文环境，出现 `Mi Home` / `UPay` 就是 bug）
//   ② **都有汉字 ⇒ 取更短的**（「京东-购物商城」→「京东」，这正是桌面图标底下那个）
//   ③ 都没汉字 ⇒ **不比长度**，保持候选顺序（否则 `WhatsApp` 会被某个内部短名干掉）
// 🔴 永远不做"把这一个切开"的截断：`WPS Office` 这种真名不会被削成 `WPS`。
NSString *NBPickName(NSArray<NSString *> *cands);

// 从一个 `.app` 目录（或它的容器目录）里读显示名。
// `whyOut`（可为 NULL）在**读不到**时回报原因，只用于诊断 ——
// 🔴 这是 v0.0.45 新增的，因为没有它，三版都只能看到"Info.plist 那一档是 0"，
//    却分不清是「路径键读不到」「沙盒不让读」还是「读到了但里面没名字」，
//    而这三种的修法完全不同。
//   取值：nil=成功 / @"路径为空" / @"Info.plist 读不出" / @"无名字键"
NSString * _Nullable NBNameFromAppBundle(NSString *path, NSString * _Nullable * _Null_unspecified whyOut);

// 从一个 `LSApplicationProxy` 上解析显示名。全部来源都失败返回 nil。
// `srcOut`（可为 NULL）回报名字从哪儿来（@"Info.plist" / @"短名" / @"系统名"）。
// 🔴 `allowIO` = 要不要为了拿名字去读 App 的 bundle（I/O）。
//    · 全量枚举 200 多个 App 时传 NO（只吃注册表里的名字，快）；
//    · 对"用户真的会看到的那几十个"传 YES（精修，慢值这个价）。
// 🔴🔴 v0.0.44 的病就在这：当时写成"手上已经有汉字就不读 bundle"，
//    于是系统给的「京东-购物商城」一进场就把真名「京东」挤掉了 ——
//    "有汉字"不等于"是对的"，**是否去读 bundle 只该由「值不值这个 I/O」决定**，
//    不该由"现在已经拿到什么"决定。
NSString * _Nullable NBNameFromProxy(id proxy,
                                     NSString * _Nullable * _Null_unspecified srcOut,
                                     NSString * _Nullable * _Null_unspecified whyOut,
                                     BOOL allowIO);

// 定向解析**单个** bundle 的显示名（一次 `+applicationProxyForIdentifier:` + 一次读 bundle）。
// 用途：库里来过通知、但全量枚举没列出它的 App；或需要精修某一个。
NSString * _Nullable NBResolveNameForBundle(NSString *bid);

// 全量枚举 @{bid: name}。`allowIO` 同上。
// `statsOut`（可为 NULL）回报诊断串数组。失败返回 nil。
NSDictionary<NSString *, NSString *> * _Nullable NBEnumerateAppNames(BOOL allowIO,
                                                                    NSMutableArray<NSString *> * _Nullable statsOut);

NS_ASSUME_NONNULL_END
