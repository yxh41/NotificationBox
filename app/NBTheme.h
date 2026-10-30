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

// ---------- v0.0.88：信息流卡片（首页每条记录一张，HyperOS 风） ----------
// 🔴 为什么**单独一组**、不并进上面的尺寸 token：上面那一组是「分组卡片」
//    （设置页那种"一张白卡片里套若干行"），这一组是「信息流卡片」
//    （每条记录各自一张、各自染色）。两者的边距/圆角/底色纪律不一样，
//    混用会让设置页跟着变形 —— 而设置页这次一个字都不该动。
extern const CGFloat NBListIconSlot;     // 左侧图标槽宽（图标在卡片**外面**）
extern const CGFloat NBListCardRight;    // 卡片右缘到 cell 右缘
extern const CGFloat NBListCardRadius;   // 卡片圆角（比分组卡片大 2pt）

/// 淡染：品牌色按 20%（浅色）/ 28%（深色）混进卡片底色，返回**动态色**。
/// 🔴 传 nil ⇒ 退回 `NBCardBG()`：没有品牌色时绝不许染出一张彩色卡
///    （否则"图标取不到"这个退化态会变成"随机颜色"，比无色更可疑）。
UIColor *NBCardTint(UIColor * _Nullable brand);
/// 按下态：淡染底再压一层中性灰。
/// 🔴 不能直接换 `tertiarySystemFillColor`（v0.0.70 的做法）：那会把品牌色整条抹掉
///    ⇒ 按下的瞬间卡片"褪色"，在一屏彩色卡片里非常跳。
UIColor *NBCardTintPressed(UIColor * _Nullable brand);
/// 未读角标底色：品牌色压暗一档（白字才压得住）。
UIColor *NBBadgeTint(UIColor * _Nullable brand);
/// 没有图标时的兜底品牌色：按 bundle **稳定哈希**取调色板（同一 App 永远同一色）。
/// 🔴 不能用 `[bundleId hash]`：NSString 的 hash 苹果不保证跨进程/跨版本稳定，
///    那样会出现"重启 App 后微信从绿色变成紫色"。
UIColor * _Nullable NBBrandFallback(NSString * _Nullable bundleId);

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
