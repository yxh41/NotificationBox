#import "NBToast.h"

// 提示框的识别标记。'NB' —— 和宿主里别的 view 撞 tag 的概率约等于零，
// 用一个魔数而不是给宿主加一个属性：提示是"贴着看"的一次性东西，不该让宿主记住它。
static NSInteger const kNBToastTag = 0x4E42;

// 🔴🔴 v0.0.187：跨 host 的唯一性靠这个**弱引用**，不靠遍历宿主。
//
// 原实现（v0.0.186 及更早）只在自己那个 host 的 `subviews` 里找同 tag 的旧框。
// 那时只有一个调用方（记录页），所以够用；v0.0.187 之后容器和页面都会弹，
// 两个 host 各自遍历 ⇒ **两个黑底会同时挂在屏幕上**（一个在页签页、一个在容器），
// 视觉上是"文字重影"，而且淡出时间还不同步。
//
// 🔴 为什么是 `__weak` 而不是 `strong`：这里**只想知道上一个还在不在**，
//    不能持有它。写成 strong 的话，即使那个框已经从父视图上摘掉，
//    这个静态变量还替它续着命 ⇒ 上下文常驻一块多余的内存，且永远等不到 nil。
static __weak UIView *sNBToastBox = nil;

void NBShowToast(UIView *host, NSString *text) {
    if (!host) return;
    if (!text.length) return;

    // 上一个还活着就摘掉（不管它挂在哪个 host 上）。
    UIView *old = sNBToastBox;
    if (old) [old removeFromSuperview];

    // 再扫一遍本宿主的同名 view：万一上一只的弱引用因为某种原因已经归零、
    // 而它在视图层级上还留着（例如动画 block 被中途取消），这一遍能兜住。
    // 🔴 必须遍历 `subviews` 的**副本**：循环里 `removeFromSuperview` 会改动
    //    `subviews` 本身，边遍历边改是未定义行为
    //    （快枚举会直接抛 "collection was mutated while being enumerated"）。
    for (UIView *v in [host.subviews copy]) {
        if (v.tag == kNBToastTag) [v removeFromSuperview];
    }

    UIView *box = [[UIView alloc] init];
    box.tag = kNBToastTag;
    box.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
    box.layer.cornerRadius = 12.0;
    box.layer.masksToBounds = YES;
    box.alpha = 0.0;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.userInteractionEnabled = NO;      // 提示不该挡住底下的列表
    [host addSubview:box];
    sNBToastBox = box;

    UILabel *lb = [[UILabel alloc] init];
    lb.text = text;
    lb.textColor = [UIColor whiteColor];
    lb.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    lb.textAlignment = NSTextAlignmentCenter;
    lb.numberOfLines = 0;
    lb.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:lb];

    // 内边距 14/10：外面套一层 box 而不是直接给 label 加背景 ——
    // UILabel 没有 contentInsets，硬给背景会让文字顶到圆角上。
    [NSLayoutConstraint activateConstraints:@[
        [lb.leadingAnchor  constraintEqualToAnchor:box.leadingAnchor  constant:14.0],
        [lb.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-14.0],
        [lb.topAnchor      constraintEqualToAnchor:box.topAnchor      constant:10.0],
        [lb.bottomAnchor   constraintEqualToAnchor:box.bottomAnchor   constant:-10.0],
        [box.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [box.centerYAnchor constraintEqualToAnchor:host.centerYAnchor],
        // 🔴 必须限宽：长句子不限宽会顶到屏幕边上
        //    （本项目吃过"提示语被截断 / 挤出屏幕"的亏）。
        [box.widthAnchor   constraintLessThanOrEqualToAnchor:host.widthAnchor constant:-72.0],
    ]];

    [UIView animateWithDuration:0.18
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        box.alpha = 1.0;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.35
                              delay:1.1
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            box.alpha = 0.0;
        } completion:^(BOOL finished2) {
            [box removeFromSuperview];
            // 只在"还是自己"的时候清静态引用：这期间可能已经有新的一只顶上来了，
            // 无脑置 nil 会把它从去重机制里漏掉。
            if (sNBToastBox == box) sNBToastBox = nil;
        }];
    }];
}
