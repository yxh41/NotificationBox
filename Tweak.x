// Tweak.x —— 录制 + 呈现层过滤的核心入口
//
// 🔴 唯一 hook 点：SpringBoard 的 BBServer（所有通知的中枢）。
//    拿到 BBBulletin（sectionID=bundleId / title / message / subtitle / date）。
//    —— 在这里「先记录、后改呈现」再调原方法，覆盖记录/过滤/替换/换声/延迟全部需求。
//
// ⚠️ 真机确认（Flex3 看 iOS 16 实际方法名）：
//    本工程默认 hook `- [BBServer publishBulletin:]`。
//    若设备上看到的是 `- [BBServer _publishBulletin:destinations:]` 或别的，
//    把下面方法名换掉即可（逻辑不变）。两处不要同时 hook 同一个真实方法，会重复处理。
//
// 🔴 Logos 坑（已踩）：注释里**不要出现 %orig 字样**，Logos 预处理会把注释里的它
//    也当成指令，导致生成代码花括号失衡（报 "function definition is not allowed here"）。

#import "NotifyFilter.h"   // 内含 BBBulletin 最小接口声明
#import "NotifyStore.h"

%hook BBServer

- (void)publishBulletin:(BBBulletin *)bulletin {
    // 全方法只在末尾留一次原方法调用，避免 Logos 展开出岔子
    if (bulletin) {
        NSString *bid = bulletin.sectionID ?: @"";

        // 1) 先记录「原始通知」—— 无论后面是否拦截/替换，记录 = 「系统收到过」
        //    （关键词过滤只拦「呈现」，不拦「记录」；想连记录都不要另开开关）
        [NotifyStore recordWithBundle:bid
                                title:bulletin.title
                              message:bulletin.message
                            subtitle:bulletin.subtitle
                                 date:bulletin.date];

        // 2) 呈现层：黑名单 / 白名单不符 / 命中过滤关键词 ⇒ 拦下不展示（但已记录）
        if ([NotifyFilter shouldDrop:bulletin]) {
            return;
        }
        [NotifyFilter applyToBulletin:bulletin];

        // 阶段3「延迟推送」打算在这里做：先不调原方法，稍后再把 bulletin 交回去。
        // 注意那样等于「再展示一次」，不走 App 自身逻辑，需先评估体验。
    }
    %orig(bulletin);
}

%end
