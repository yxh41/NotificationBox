// NBHaptic.m —— 见 NBHaptic.h 顶部的来历与纪律。这里只放实现。
#import "NBHaptic.h"

// 🔴 generator **只建一次并长期持有**。
//    每次 `new` 一个 `UIImpactFeedbackGenerator` 都要重新唤醒 TapticEngine（~100ms），
//    手感直接变成"慢半拍"；更糟的是新建实例的**首次** `impactOccurred`
//    经常压根不震 —— 症状是"有时候震有时候不震，第一次总没反应"。
//    这段实现是从 `NotifyCell.m` 原样搬过来的，v0.0.94 就是这么写的，别改。
static UIImpactFeedbackGenerator *NBHapticImpactGen(NBHapticKind kind) {
    static UIImpactFeedbackGenerator *soft = nil;
    static UIImpactFeedbackGenerator *light = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(iOS 13.0, *)) {
            soft = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
        } else {
            // iOS 12 及以下没有 Soft，退到 Light（部署目标是 16，这条只是兜底）
            soft = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        }
        light = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    });
    // 🔴 判据是**黑名单**：「只有 Light 用轻，其余一律柔」。
    //    v0.0.128 那版写的是白名单 `(kind == Arm) ? soft : light` —— 那样新增的档
    //    会**静默**落到 light（比该有的分量重一档），而且看不出是漏改还是故意的。
    //    黑名单式之后，以后再加档默认都是"柔"，要重就显式点名。
    return (kind == NBHapticKindLight) ? light : soft;
}

// 成功/失败那种"咚咚"用的是另一个类，别混进 impact 体系里
// （`UINotificationFeedbackTypeError` 的分量明显重于任何 impact，混用会失真）。
static UINotificationFeedbackGenerator *NBHapticNotifyGen(void) {
    static UINotificationFeedbackGenerator *g = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g = [[UINotificationFeedbackGenerator alloc] init];
    });
    return g;
}

void NBHapticPrepare(NBHapticKind kind) {
    if (kind == NBHapticKindSuccess || kind == NBHapticKindWarning) {
        [NBHapticNotifyGen() prepare];
        return;
    }
    [NBHapticImpactGen(kind) prepare];
}

void NBHapticFire(NBHapticKind kind) {
    switch (kind) {
        case NBHapticKindSuccess:
            [NBHapticNotifyGen() notificationOccurred:UINotificationFeedbackTypeSuccess];
            break;
        case NBHapticKindWarning:
            [NBHapticNotifyGen() notificationOccurred:UINotificationFeedbackTypeWarning];
            break;
        default:
            // ⚠️ 这里**故意**写 `default` 而不是把 Soft/Light 两条 case 列全：
            //    以后再加冲击档时会自动落到这里，不会因为漏写一个 `case`
            //    就静默变成"什么都不做"（switch 少 case 编译器不报错，
            //    那是最难查的一种"加了等于没加"）。
            [NBHapticImpactGen(kind) impactOccurred];
            break;
    }
}
