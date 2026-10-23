#import <UIKit/UIKit.h>

// 选一个自定义提示音。
//
// 存的是**纯文件名**（NB_KEY_SOUND_FILE / soundMap 的 file 子键），不是路径 ——
// 目录由 NotifyCommon.h 里的 NOTIFYBOX_SOUND_DIR 定死。理由见那边的注释（外部输入必须净化）。
//
// 设计取舍：这里**不做"导入"入口**（不接 UIDocumentPicker）。
//   ① 越狱 App 走 document picker 在 iOS 16 上有额外不确定性，第一版不赌它；
//   ② 用户本来就有 Filza，把文件放进这个目录是最短路径；
//   ③ 页面会把完整路径显示出来 + 列表可刷新，放完文件回到这里就能看到。
//   等这一版真机验证过、链路稳了，再考虑加导入按钮。
//
// 🔴 v0.0.28：同一个页面服务两个目标（两套语义，不是两份代码）：
//    · `init`                    ⇒ 编辑**默认提示音**（写全局 soundFile / soundID）；
//    · `initWithBundle:…`        ⇒ 编辑**某个 App 自己的音**（写 soundMap[bundle]）。
//    为什么必须是同一个页面：两边"选音"的规则（文件优先、播不出来的不保存、试听走引擎同一个函数）
//    一旦分成两份实现，就一定会走岔，而走岔的症状是"我给微信选的音，通知里不是它"。
@interface SoundFilePickerViewController : UIViewController

- (instancetype)init;

// bundleId 非空 ⇒ per-App 模式；displayName 只用于标题与文案（不参与判定/写盘）。
- (instancetype)initWithBundle:(NSString *)bundleId displayName:(NSString *)displayName;

@end
