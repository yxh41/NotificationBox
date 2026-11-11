// NBHaptic.h —— v0.0.178：全 App 触觉反馈的唯一来源
//
// 🔴 为什么必须要有这个文件：v0.0.178 之前，整套触觉只活在一个文件里 ——
//    `NotifyCell.m` 里那份 `typedef NS_ENUM` + 三个 `static` 函数。
//    `static` 且不在任何头文件里 ⇒ **别的文件调不到**。
//    于是 v0.0.94 加完左滑手感之后，列表页（换筛选、点图标栏、标已读、静音）
//    **一次都没有过触觉** —— 不是"忘了写"，是"想写也写不了"。
//    审计的账：`NBHapticFire` 在 `ViewController.m` 里出现过 **0 次**。
//    这是本项目那条纪律的又一次复现：**同一件事只有一个实现，且它必须在
//    双方都看得见的地方**；否则另一处只能"照抄一份"（两份必走岔）或者"干脆不做"。
//
// 🔴 档位按**分量**命名，不按动作命名（原先是 Arm / Delete / Stop）。
//    动作名的问题是：`NBHapticKindDelete` 一旦被"标已读"复用，名字就开始说谎；
//    而分量名（柔 / 轻 / 成功 / 失败）在任何调用点都成立。
//    ⇒ 判据（`nb_lint` I3）：全仓代码里不许再出现旧档位名。死名字留着，
//      下一个人会以为"还有另一套"，或者以为某处还在用它。
//
// 🔴🔴 纪律：**触觉表示"生效了"，所以必须排在回读校验之后**。
//    写盘失败也震一下的话，用户读到的就是"成了"，而实际没成 ——
//    这比不震糟得多（和 v0.0.176 静音熄灯动画同一条纪律：
//    界面上的每个反馈都是"结论"，不是"动作的陪衬"）。

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NBHapticKind) {
    /// 最轻，**默认档**：换筛选、点图标栏、切时间档、下拉触发。
    NBHapticKindSoft = 0,
    /// 稍实一点：真的删掉了一条、标为已读、静音写入并回读通过。
    NBHapticKindLight = 1,
    /// 成功提示音（`UINotificationFeedbackGenerator`）。
    NBHapticKindSuccess = 2,
    /// 失败 / 被拒绝（同上，warning）。
    /// ⚠️ 只用在"用户会以为成功了、但其实没成"那种失败上，不要当通用错误音。
    NBHapticKindWarning = 3,
};

/// 预热：在"即将要震"的那一刻提前调一次，把 TapticEngine 唤醒。
/// 🔴 不预热时第一次会慢半拍甚至完全不震（左滑手势里踩过：
///    "有时候震有时候不震，第一次总没反应"）。
void NBHapticPrepare(NBHapticKind kind);

/// 震一下。
void NBHapticFire(NBHapticKind kind);

NS_ASSUME_NONNULL_END
