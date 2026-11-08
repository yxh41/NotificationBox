//
//  NBTextExtract.m
//  NotifyBox
//
//  v0.0.166
//

#import "NBTextExtract.h"

// 私有方法写在前面：`firstLinkInText:` 里会调它，靠"同文件稍后定义"解析选择器太脆
// （本项目为这个栽过），显式声明一行的事。
@interface NBTextExtract ()
+ (nullable NSString *)trimLinkTail:(nullable NSString *)s;
@end

// 出现这些词，才允许把数字当验证码看。
// 🔴 只放"明确指验证码"的词，**不放**「码」这种单字（会把「条码」「二维码」「取货码」全捞进来）。
static NSArray<NSString *> *NBVerificationKeywords(void) {
    static NSArray<NSString *> *kw = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kw = @[@"验证码", @"校验码", @"动态码", @"确认码", @"激活码", @"认证码",
               @"验证编号", @"安全码", @"登录码", @"verification code", @"passcode",
               @"OTP"];
        // 🔴 刻意**不放**裸 "code"：`rangeOfString:` 是子串匹配，它会命中 `barcode`、
        //    `promo code`、`discount code`，然后顺手把旁边的数字当验证码复制出去。
        //    "含 X" ≠ "是 X"，本项目栽过同一类 —— 要么用完整词，要么不用。
    });
    return kw;
}

// 数字前面挨着这些词 ⇒ 它不是验证码，是账号/单号/金额。
// 🔴 「尾号 1234 消费」「订单 12345678 已发货」是最常见的两类误判，必须挡住。
static NSArray<NSString *> *NBNotACodePrefixes(void) {
    static NSArray<NSString *> *bad = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = @[@"尾号", @"尾数", @"末四", @"单号", @"订单", @"编号", @"卡号", @"账号",
                @"手机", @"金额", @"余额", @"支付", @"消费", @"人民", @"￥", @"¥",
                @"No.", @"NO.", @"no.", @"第", @"共"];
    });
    return bad;
}

@implementation NBTextExtract

#pragma mark - 链接

+ (NSString *)firstLinkInText:(NSString *)text {
    if (![text isKindOfClass:[NSString class]] || !text.length) return nil;

    // scheme://rest。rest 只排除空白 —— 中文标点留到最后手工剔，
    // 🔴 不把 CJK 写进正则的原因：`\u4e00-\u9fff` 这类区间会把**中文域名/中文路径**也挡掉，
    //    而真正的对手只是句末那个"。"。剔尾比禁头安全。
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"[A-Za-z][A-Za-z0-9+.\\-]*://[^\\s]+"
                                                       options:0 error:NULL];
    });
    if (!re) return nil;

    __block NSString *hit = nil;
    NSRange full = NSMakeRange(0, text.length);
    [re enumerateMatchesInString:text options:0 range:full
                      usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        if (m.range.location == NSNotFound || m.range.length == 0) return;
        NSString *s = [self trimLinkTail:[text substringWithRange:m.range]];
        if (!s.length) return;
        NSURL *u = [NSURL URLWithString:s];
        // 🔴 必须过一遍 `URLWithString:` 再认：字符串长得像链接、解析出来却是 nil 的情况
        //    真机上出现过（前缀里混进了 "4," 之类的垃圾）。**判的串和开的串必须是同一条**，
        //    所以这里校验的就是最后要拿去 open 的那个字符串。
        if (!u || !u.scheme.length) return;
        hit = s;
        *stop = YES;
    }];
    return hit;
}

// 从尾部逐个剔掉"不可能属于链接"的字符。
// 🔴 两种：① 非 ASCII（中文标点、全角括号，通知正文里最常见的是"。"）；
//          ② ASCII 里只会出现在句末的标点。
//    不能只在末尾剔一次然后返回 —— "https://a.com/b）。" 这种要连剔两个。
+ (NSString *)trimLinkTail:(NSString *)s {
    if (!s.length) return s;
    NSCharacterSet *tailASCII = [NSCharacterSet characterSetWithCharactersInString:
                                 @".，,;；:：!！?？)）]】>》\"'”’、"];
    NSUInteger end = s.length;
    while (end > 0) {
        unichar c = [s characterAtIndex:end - 1];
        BOOL ascii = (c < 0x80);
        BOOL drop = ascii ? [tailASCII characterIsMember:c] : YES;
        if (!drop) break;
        end--;
    }
    if (end == 0) return nil;
    return [s substringToIndex:end];
}

#pragma mark - 验证码

+ (NSString *)verificationCodeInText:(NSString *)text {
    if (![text isKindOfClass:[NSString class]] || !text.length) return nil;

    // ---- ① 正文里必须有验证码类的词，否则一律不认 ----
    NSUInteger kwPos = NSNotFound;
    for (NSString *kw in NBVerificationKeywords()) {
        NSRange r = [text rangeOfString:kw options:NSCaseInsensitiveSearch];
        if (r.location == NSNotFound) continue;
        if (kwPos == NSNotFound || r.location < kwPos) kwPos = r.location;
    }
    if (kwPos == NSNotFound) return nil;

    // ---- ② 找所有"独立"的 4~8 位数字 ----
    // 前后都不许再跟数字：(?<![0-9]) / (?![0-9])，否则会把长数字串的中间一段抠出来。
    static NSRegularExpression *re = nil;
    static dispatch_once_t onceRe;
    dispatch_once(&onceRe, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"(?<![0-9])[0-9]{4,8}(?![0-9])"
                                                       options:0 error:NULL];
    });
    if (!re) return nil;

    NSString *best = nil;
    NSUInteger bestDist = NSUIntegerMax;
    NSRange full = NSMakeRange(0, text.length);
    NSArray<NSTextCheckingResult *> *all = [re matchesInString:text options:0 range:full];
    for (NSTextCheckingResult *m in all) {
        NSUInteger loc = m.range.location;

        // ---- ③ 前面挨着"不是验证码"的词 ⇒ 跳过 ----
        // 取前 4 个字符做窗口（「尾号」两字、「订单编号」四字都落在窗口里）。
        NSUInteger winLen = MIN((NSUInteger)4, loc);
        NSString *win = [text substringWithRange:NSMakeRange(loc - winLen, winLen)];
        BOOL blocked = NO;
        for (NSString *bad in NBNotACodePrefixes()) {
            if ([win containsString:bad]) { blocked = YES; break; }
        }
        if (blocked) continue;

        // ---- ④ 取离「验证码」那个词最近的 ----
        // 🔴 通知里常有一串数字（金额、时间、单号），"最近的"比"第一个"稳得多：
        //    「验证码 483920，5分钟内有效」里 5 也满足 4~8 位，靠距离才能选对。
        NSUInteger dist = (loc > kwPos) ? (loc - kwPos) : (kwPos - loc);
        if (dist < bestDist) {
            bestDist = dist;
            best = [text substringWithRange:m.range];
        }
    }
    if (best.length) return best;

    // 走不到这里（上面按距离选过一轮，有关系就等于全扫过）。
    // 🔴 刻意**不**在这一步放宽条件（比如允许 3 位、允许带字母）：宁可返回 nil，
    //    也不要复制一个错的东西出去 —— 用户会把错码填进去，然后以为是短信没到。
    return nil;
}

@end
