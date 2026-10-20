// Tweak.x —— 录制 + 呈现层过滤的核心入口
//
// 🔴 唯一 hook 点：SpringBoard 的 BBServer（所有通知的中枢）。
//    拿到 BBBulletin（sectionID=bundleId / title / message / subtitle / date）。
//    —— 在这里「先记录、后改呈现」再 %orig，覆盖记录/过滤/替换/换声/延迟全部需求。
//
// ⚠️ 真机确认（Flex3 看 iOS 16 实际方法名）：
//    本工程默认 hook `- [BBServer publishBulletin:]`。
//    若你设备上看到的是 `- [BBServer _publishBulletin:destinations:]` 或别的，
//    把下面方法名换掉即可（逻辑不变）。两处不要同时 hook 同一个真实方法，会重复处理。

#import "NotifyFilter.h"   // 内含 BBBulletin 最小接口声明
#import "NotifyStore.h"

%hook BBServer

- (void)publishBulletin:(BBBulletin *)bulletin {
    if (!bulletin) { %orig; return; }

    NSString *bid = bulletin.sectionID ?: @"";

    // 1) 先记录「原始通知」—— 无论后面是否拦截/替换，记录 = 「系统收到过」
    //    （所以关键词过滤只拦「呈现」，不拦「记录」；想要连记录都不要就另开开关）
    [NotifyStore recordWithBundle:bid
                            title:bulletin.title
                          message:bulletin.message
                        subtitle:bulletin.subtitle
                             date:bulletin.date ?: [NSDate date]];

    // 2) 呈现层处理
    if ([NotifyFilter shouldDrop:bulletin]) {
        return;   // 拦截呈现（黑名单 / 白名单不符 / 命中过滤关键词），但已记录
    }
    [NotifyFilter applyToBulletin:bulletin];

    // TODO（阶段3·延迟推送）：在这里若选择延迟，就 return 并自己 dispatch_after 后再 %orig(bulletin)；
    //       注意再注入的 bulletin 不走 App 自身逻辑，属「再展示一次」，需评估体验是否可接受。
    %orig(bulletin);
}

%end
