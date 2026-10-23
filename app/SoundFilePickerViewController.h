#import <UIKit/UIKit.h>

// v0.0.26：选一个自定义提示音文件。
//
// 存的是**纯文件名**（NB_KEY_SOUND_FILE），不是路径 —— 目录由 NotifyCommon.h 里的
// NOTIFYBOX_SOUND_DIR 定死。理由见那边的注释（外部输入必须净化）。
//
// 设计取舍：这里**不做"导入"入口**（不接 UIDocumentPicker）。
//   ① 越狱 App 走 document picker 在 iOS 16 上有额外不确定性，第一版不赌它；
//   ② 用户本来就有 Filza，把文件放进这个目录是最短路径；
//   ③ 页面会把完整路径显示出来 + 列表可刷新，放完文件回到这里就能看到。
//   等这一版真机验证过、链路稳了，再考虑加导入按钮。
@interface SoundFilePickerViewController : UIViewController
@end
