// NBTheme.h —— v0.0.71 统一视觉层（盒子 App 全站唯一一份）
//
// 🔴 为什么要有这个文件：v0.0.70 之前每个页面各写各的数值
//    （圆角 7 / 10 / 12 混用、边距 12 / 14 / 16 混用、字号 12~15 混用），
//    结果是"每一页单看都还行、连起来像三个 App"。
//    这里把它们收成一套 token，页面只允许引用，不许再写字面量。
//
// 🔴 颜色配对纪律（v0.0.70 踩过）：浅色模式下
//    `secondarySystemBackground` 与 `systemGroupedBackground` **同为 #F2F2F7**，
//    拿前者当卡片、后者当底 ⇒ 卡片"消失"。正确配对是
//    `secondarySystemGroupedBackground`（白）压 `systemGroupedBackground`（灰），
//    这一对必须一起换，换一半等于没做。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// ---------- 尺寸 ----------
extern const CGFloat NBInset;        // 页面左右边距
extern const CGFloat NBRowH;         // 单行最小高度
extern const CGFloat NBRowHSwitch;   // 带开关的行
extern const CGFloat NBRowHSub;      // 带副标题的行
extern const CGFloat NBFieldH;       // 输入框高度
extern const CGFloat NBIconBox;      // 图标底块边长
extern const CGFloat NBCardRadius;   // 卡片圆角
extern const CGFloat NBSepInset;     // 卡片内分隔线左缩进（对齐标题）

// ---------- 颜色 ----------
UIColor *NBPageBG(void);      // 页面底（分组灰）
UIColor *NBCardBG(void);      // 卡片（白）
UIColor *NBValueColor(void);  // 右侧取值文字
UIColor *NBSubColor(void);    // 副标题 / 说明
UIColor *NBSepColor(void);    // 卡片内分隔线

// ---------- 字体 ----------
UIFont *NBFontTitle(void);    // 行标题
UIFont *NBFontSub(void);      // 行副标题
UIFont *NBFontValue(void);    // 右侧取值
UIFont *NBFontHeader(void);   // 分组标题
UIFont *NBFontField(void);    // 输入框

// ---------- 构件 ----------
/// 白底圆角卡片（分组容器 / 单行卡片共用）
UIView *NBNewCard(void);
/// 彩色圆角小方块里放一个白色 SF Symbol（iOS 设置那种图标）
/// 🔴 symbol 名不存在时**返回 nil 的 image** —— 调用方必须容忍，
///    绝不能因为图标名写错就崩或留一块空白底色。
UIView * _Nullable NBNewIconBox(NSString *symbol, UIColor *tint);
/// 右侧灰色 ↵ 箭头（替代手写的 " ›"：手写的那个在深色模式和动态字号下会歪）
UIImageView *NBNewChevron(void);
/// 卡片内的一条分隔线
UIView *NBNewSeparator(void);
/// 分组标题 / 分组脚注（灰小字、可多行）
UILabel *NBNewHeaderLabel(NSString *text);
UILabel *NBNewFooterLabel(NSString *text);

NS_ASSUME_NONNULL_END
