// Tweak.x —— v0.0.71（当前）：**tweak 侧逻辑依旧一字未动，只修"版本串写死"这一件事** ——
//   ⇒ v0.0.71 说明：
//      本版主体是「盒子 App 的界面现代化 + 设置页重排」（App 侧，见 app/NBTheme.h/.m），
//      tweak 侧只有一处修正：**诊断文件里写死的版本串全部改用 `NB_VER_STR`**。
//      起因：`nc_diag(11).txt` 头部自称 `v0.0.56`，而实际装的是 v0.0.70 ——
//      因为那句是字面量 ⇒ **诊断文件不能用来判断"装的是哪一版"**，会把人带偏。
//      现在文件头、方法表标题、各条运行时日志戳都走同一个 `NB_VER_STR`。
//      ⚠️ 反过来说：「诊断文件里出现 `# ---- v0.0.70 方法表`」在 v0.0.70 之后不再是历史标注，
//      而是当前版本号本身（这一行也改成 `%@` 了）；判"装的哪一版"请看**文件头那一行**。
//   ---- 以下是 v0.0.70 的内容，仍然成立，保留 ----
// v0.0.70：**那一版只改盒子 App 的界面，tweak 侧一字未动** ——
//   ⇒ v0.0.70 说明：
//      tweak 侧沿用 v0.0.69 的全部逻辑（NC 清除先于清账本 + 清后读回 + 每次删除归零计数），
//      一条都不改。**故意拆成两个版本**：v0.0.69 验的是「通知中心那条会不会消失」，
//      这一版验的是「界面好不好看」；两件事混在一个包里，出问题时说不清是谁干的。
//      唯一变化是版本号（`NB_VER_STR` / 运行时日志戳），方便在真机日志里分清装的是哪一版。
//   ---- 以下是 v0.0.69 的内容，仍然成立，保留 ----
//   🔴🔴 v0.0.69 定案：**顺序反了 —— 我先把 NC 要用的那块砖自己拆了**。
//      v0.0.68 四层判据全绿、界面不动 ⇒ 只剩"顺序"这一种解释：
//      NC 那条驱动界面的清除要靠 `NCBulletinNotificationSource` 把 request 翻回 **BBBulletin**
//      再让 BB 撤一次（`_bulletinsToClearPerSectionIdForNotificationRequests:removingDestinations:`）；
//      而我们把 ⓪（`withdrawBulletinRequestsWithRecordID:`）和 ③（`_removeBulletin:`）
//      排在 NC **之前** ⇒ 调 NC 时 `BB live` 早已 `含本条=否` ⇒ 它翻不出东西 ⇒ 静默什么都不做。
//      ⚠️ 这条教训 v0.0.61 就写在文件头里（"先 NC 两步、再删 BB 账本"），v0.0.65 重写流程时
//      被我**亲手推翻**了 ⇒ **写下来的教训没人守着，就会在下一次重构里静悄悄失效。**
//   ⇒ v0.0.69 三条：
//      ① `⓪ + ③` 打包成 `bbCleanup` 块，**只定义不执行**；由 `NBForwardClearAsync` 新增的
//         `done` 完成回调在 NC 那一刀真的返回之后调用（再 `dispatch_async` 回 BBServer 队列）。
//      ② 新增唯一一条读回判据（纯只读）`[验] 清后 NC：还能找到本条=是/否`：
//         「是」⇒ 系统只是收到通知、**没真删** ⇒ 换刀；「否」⇒ NC 模型真删了 ⇒ 补刷 UI。
//      ③ 没拿到 NC dispatcher/bulletin 时退回老路就地清账本（界面可能不变，但账本要干净）。
//   🔴 判据（五层，第 5 层才算数）：
//      `[序] v0.0.69：先走 NC 清除` → `匹配=精确` → `[dest] ✅` → `[清] ②… 已返回`
//      → `[验] 清后 NC：还能找到本条=否` → **人眼确认那条消失**。
//   ---- 以下是 v0.0.68 / v0.0.67 / v0.0.66 / v0.0.65 / v0.0.64 的内容，仍然成立，保留 ----
//      v0.0.68 四条：`request.bulletin` 精确锁定 / `destinationsRegistry` 同步补抓 destination /
//      `registerDestination:` 注册期接住实例 / 三把刀按"离界面由近到远"排 / 删 `NBFindCachedRequest`。
//      成对触发（dispatcher+source）、⓪ 官方撤回稳定生效、
//      不投 NC 队列（投了不跑）、闸门带超时、绝不对未知类调 description（`NBStringish`）、
//      写前日志、`_requestUUIDForBulletinPublisherMatchID:`。
//   🔴 用户实测 v0.0.58/v0.0.59：「没有消失，是不是没真正删除啊啊」。
//      日志里 BB 的 live 确实 50→49、含本条 是→否 —— 但界面不动。
//      根因两条，都是我自己的错：
//        ① **只量了 BB 账本**（`_allBulletinsForSectionID:`）。BB 是账本，NC 才是界面。
//        ② 第 ① 步让 BB 计数变了 ⇒ `still=NO` ⇒ **早停** ⇒ 后面「NC 原生撤回」
//           （唯一驱动界面的那步）**一次都没执行**。
//   ⇒ v0.0.61 改成：BB 层与 NC 层**分别量**（`NBLiveScan` + `NBScanNC`）、**分别动手**、
//      **不许早停**。NC 侧三条路：`observer:removeBulletin:`（BB 撤回广播的 NC 入口）、
//      `withdrawNotificationWithRequest:`（用 source 自己缓存的**真 request**，不是我造的）、
//      以及 `_clearBulletinIDs:` 补刀。
//   🔴 执行顺序也改了：**先 NC 两步、再删 BB 账本**。因为 `observer:removeBulletin:`
//      要拿一个**还有效**的 bulletin 对象；先把账本删了再传进去，等于传个已失效对象
//      （v0.0.58 就是排在这个位置之后，很可能也是它一次都没生效的原因之一）。
//      删账本那步现在会**重新取一次对象**，避免用旧指针。
//   🔴 本版唯一的验收判据：`删后 NC 含本条=否`。只有这个「否」才代表界面上会变；
//      `删后 BB 含本条=否` 只代表账本干净了 —— 这一条 v0.0.58/59 已经"绿"过两次，是假绿。
//
//   v0.0.57 的历史（当年的尝试方向，保留作背景）：
//   v0.0.56 探针取回的 `nc_diag.txt` 里，BBServer 有 253 个实例方法，关键几条：
//     - withdrawBulletinRequestsWithRecordID:forSectionID:        v@:@@   ← iOS16 正规撤回
//     - withdrawBulletinRequestsWithPublisherBulletinID:forSectionID: v@:@@
//     - withdrawBulletinID:                                       v@:@
//     - _bulletinsForIDs:                                         @@:@   ← 按 ID 取真实对象
//     - _allBulletinsForSectionID:                                @@:@   ← 段内 live 枚举
//     - _removeBulletin:shouldSync:                               v@:@B
//   🔴 这也解释清了 v0.0.52~56 为什么白干：`_clearBulletinIDs:forSectionID:shouldSync:` 确实在、
//      确实能调、确实不抛，但它是**老语义**（清 cleared-info），iOS 16 的界面由 withdraw 驱动。
//   🔴 另外我 v0.0.53 找的两个"枚举"名字（_bulletinIDsForSectionID: / bulletinIDsForSectionID:）
//      本来就不存在 —— 真名是 `_allBulletinsForSectionID:` / `_bulletinsForIDs:`。
//   ⇒ v0.0.57 的做法：先枚举取基准 → 按 ID 取对象并读出 recordID/publisherBulletinID →
//      依次试 _removeBulletin: / withdraw…WithRecordID: / withdraw…WithPublisherID: / withdrawBulletinID: →
//      **再按同一口径复查**（段内 live 数、_bulletinsForIDs 命中数），数变小才算真删掉。
//      全部 respondsToSelector + @try 守卫；尝试过程逐条追加进 nc_diag.txt。
//   以下为 v0.0.52 功能主体（保留）：
//   「删除盒子记录时同步清系统通知中心」（精确 1:1）：
//   ① NBRecordItem 记录时读系统 bulletin ID（bulletinID / notificationIdentifier）存进库；
//   ② %ctor 在 SpringBoard 注册 Darwin 通知观察者；盒子 App 删单条记录时写请求文件 + post；
//   ③ 回调在捕获到的 BBServer 内部队列上调用 _clearBulletinIDs:forSectionID:shouldSync:，
//      把那一条从系统通知中心也删掉（respondsToSelector: 守卫，本机没有就优雅跳过）。
//   ④ 绕开 extern __BBServerQueue 外部符号：在 publish hook 里 capture self + dispatch_get_current_queue()。
//   🔴 上一次 tweak 侧真的动是 v0.0.51：在 NBRecordItem 加「连记录都不要」per-App 闸门。
//   「连记录都不要」per-App 名单：NBRecordItem 在 recordWithBundle: 之前加闸门
//   （NotifyFilter shouldSkipRecordForBundle:，读 settings.plist 的 noRecordApps）。
//   只掐"记"这一路，过滤/替换/换声/朗读照跑。
//   🔴 上一次 tweak 侧真的动是 v0.0.45：在 SpringBoard 后台代读 App 显示名、
//      写进 `app_names` 表（病根与做法见 NBAppName.h）；
//      v0.0.46 / v0.0.47 / v0.0.48 / v0.0.49 / v0.0.50 都只升版本号。
//   🔴 为什么要由 tweak 来做（这是 v0.0.42/43/44 连着三版没修好的直接原因）：
//     盒子 App 有沙盒，读不到 /var/containers/Bundle/Application/<UUID>/Xxx.app，
//     而 App 自己 bundle 里本地化的 CFBundleDisplayName **才是桌面那个字的权威来源**。
//     ⇒ 不是"在没权限的地方再猜一轮"，而是让有权限的进程（SpringBoard）算好送来。
//     完整说明见 NBAppName.h。
// 🔴 连着八版都写清楚"tweak 到底动没动"，因为日志里会打出 v0.0.45 —— 不给说明的话，
//      以后看到这版日志会以为 tweak 动了别的地方，白查一轮。
//   上上版 v0.0.44：App 名改用桌面短名 + 搜索命中高亮 + 导出 CSV（**只有 App 侧**）。
//   上上上版 v0.0.43：真机反馈两修（App 中文名 + 底部截断提示的未读口径）
//   上上版 v0.0.42：列表显示 App 名 + 搜索能搜 App 名和 subtitle + 搜索防抖 + 底部截断提示
//   上上版 v0.0.41：顶部提示条可点 + 未读派生量收成一个出口（只有 App 侧）
//   上上上版 v0.0.40：提示条范围从"比时间窗更早"扩成"当前筛选之外"（只有 App 侧）
//
// 🔴🔴 先认账：v0.0.23 的假设被真机数据**正面否掉了**。
//
// v0.0.23 的推断：`repetitions` / `maxDuration` 在空壳里是 0 ⇒ 播 0 次 / 0 秒 ⇒ 没声音。
// v0.0.23 落盘的 sound_diag.log 反驳（用户手机实测）：
//   系统自己给的、**能正常出声**的那个 BBSound：
//       maxDuration=0   repeats=0   soundType=2   systemSoundID=0
//       alertConfiguration=<TLAlertConfiguration>   toneIdentifier=""   alertType=17
// ⇒ 0/0 是正常的，与出不出声无关。
// ⇒ 而且 `repetitions` 这个键**根本不存在**（真机 `rep=!无键`）；
//    正确的名字是 `repeats`（{TB,N,GisRepeating,V_repeats}，BOOL，是"要不要重复"）。
//    病根：我照着上一版 PROBE 截图**凭印象转写**了一个意思相近的名字，
//    没有逐字抄。⇒ 以后键名只能从数据里逐字抄，不许"翻成同义词"。
//
// 把两边摊开对比，唯一还没被排除的差异：
//     能响的：   soundType=2   systemSoundID=0     alertConfiguration=<非 nil>
//     我们的：   soundType=1   systemSoundID=1009  alertConfiguration=nil
// ⇒ iOS 16 的通知音走 **TonesLibrary（TLAlert + TLAlertConfiguration）**；
//    `systemSoundID` 是 AudioServices 的老 ID，BulletinBoard 已经不看它了。
//    这同时解释了设置页"试听"为什么是响的 —— 试听走 AudioServices 播放，
//    跟系统投递通知是两条完全不同的路。**试听能响 ≠ 通知能响。**
//
// ⇒ 这一版**不改刀**。刀继续"造不出能响的对象就不挂"，手机停在"能响原声"这个安全状态
//    （v0.0.21 已实测：挂空壳 = 通知彻底没声音 = 用户漏消息，比"没换成"糟得多）。
//
// 这一版只做一件事：**把"怎么造一个能响的 BBSound"挖出来。**
//   ① dump BBSound 的**类方法** —— 找 +soundWith… 这类工厂。
//      ⚠️ v0.0.20 的 PROBE 曾记过"只有 1 个类方法且与声音无关"，
//         但当时那份 dump 是否真的取到了元类（object_getClass）无法确认，
//         所以再确认一次；有工厂就让它替我们造，不要在字段里继续摸。
//   ② dump **TLAlertConfiguration** 的属性 + 类方法 + ivar —— iOS 16 通知音的真身。
//      `alertConfiguration` 是 BBSound 上标 [W] 的字段，我们需要的只是"造一个能用的 cfg"。
//   ③ 抓到系统给的 sound 时不再只留 1 个样本：按"长相"去重最多留 4 个，
//      并把它们的 alertConfiguration 一起 dump。
//      只有多样性才能看出 soundType 有哪几个取值、各形态分别靠哪个字段发声 ——
//      上一版只留一个样本，等于只认识了一种长相。
//
// 另外修掉两处**诊断自己在说谎**的 bug（真机输出里已经出现了，都是判据类错误）：
//   · `NBDiagDumpSetters` 拿 `buf.length` 同时当"缓冲区还剩多少"和"有没有找到过"，
//     而 flush 会清空缓冲区 ⇒ 6 个 setter 加起来正好 111 字触发 flush，
//     于是打出「setter: setVibrationPattern: … setRingtoneName:」紧跟着
//     「声音相关 setter: 一个都没有」—— 两行自相矛盾。判据变量必须独立记事实。
//   · 关键词过滤漏了 duration / repeat / song / audio，把真实存在的
//     setMaxDuration: / setRepeats: / setSongPath: 全筛掉了 ⇒ 我以为"只有 6 个可写字段"。
//
// ⚠️ 顺带记录两条已被数据证伪的猜测，别再回头捡：
//   · `playSound` **不是**出声的闸门 —— 用户明确听到原声的那几条也是 playSound=0；
//   · `soundSource` 在 BBSound 上不存在（KVC 抛 NSUnknownKeyException）。
//
// 更早一版的白捡经验仍然成立：遇到系统给的、非 nil 的 sound 就整份 dump ——
// 抄一个真实对象的字段值，比猜枚举值强一万倍。（这一版把它从"一次"扩到"按形态最多 4 次"。）
//
// 依据真机 PROBE 数据（v0.0.20 采）定下换提示音的实现方式，一条都不凭猜：
//   sound{T@"BBSound",&,N,V_sound} 可写；BBSound **只有 1 个类方法且与声音无关 ⇒ 没有工厂方法**；
//   alertType 是 R（只读），可写的是 soundType / systemSoundID / vibrationIdentifier；
//   PROBE#1/2/3 全是 sound=nil ⇒ 默认提示音**不带 BBSound**，必须自己 alloc/init 造一个再挂。
//   挂完必须回读验证（造出来的对象被系统丢弃 = 静默无效，不报错）。
//
// 免打扰：命中时段就 NBDeny() 丢掉，仍记一条日志（DND#），保证"不弹但可回看"。
// 换提示音：**空名单不生效** —— 实验性功能，绝不允许一次性改掉整台手机的通知音。
//
// 上一版（v0.0.20）修的是「探针数据被结论行筛掉」：
//
//   探针（PROBE）的实质数据行里一个筛选关键词都不含 ⇒ 结论行只剩「开始/结束」两行空壳，
//   看起来像「探针跑了但什么都没量到」，实际数据一直在日志里。
//
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 📌 真机量回来的签名（v0.0.4 零 hook 诊断，SpringBoard / iOS 16.4.1）：
//
//   SEL publishBulletin:destinations:
//       ENC v32@0:8@16Q24   ⇒ - (void)xxx:(id) destinations:(unsigned long long)
//   SEL publishBulletinRequest:destinations:
//       ENC v32@0:8@16Q24   ⇒ - (void)xxx:(id) destinations:(unsigned long long)
//   SEL _publishBulletinRequest:forSectionID:forDestinations:
//       ENC v40@0:8@16@24Q32 ⇒ - (void)xxx:(id) forSectionID:(id) forDestinations:(unsigned long long)
//
// 🔴 v0.0.3 为什么三个候选全 "NO"：我把名字抄成了
//    `publishBulletinRequest:forSectionID:forDestinations:`（**漏了前导下划线**），
//    真名是 `_publishBulletinRequest:...`。缩略图读串丢了细节。
//    ⇒ 定签名只认 ENC 输出，不认截图。
//
// 🔴 v0.0.3 为什么进安全模式：挂了一个签名不明的探针并声明成 void。
//    现在三个目标全部确认返回 void，签名逐字照抄，才敢挂。
//
// 🔴 三个入口可能都被调用（一个通知走完整链路），所以必须**去重**，
//    否则同一条通知会被记 3 次。去重键 = bundle|title|message，窗口 2 秒。
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
// 🔴 Logos 坑：注释里绝不出现以百分号开头的 Logos 关键字（nb_precheck.py 把关）。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "NotifyStore.h"
#import "NotifyCommon.h"
#import "NotifyFilter.h"
#import "NotifySpeaker.h"
#import "NotifyProbe.h"
#import "NotifySoundDiag.h"
#import "NBAppName.h"


static int gHit1 = 0;   // publishBulletin:destinations:
static int gHit2 = 0;   // publishBulletinRequest:destinations:
static int gHit3 = 0;   // _publishBulletinRequest:forSectionID:forDestinations:
static int gDropped = 0;    // 被过滤掉（没有交给原方法）的条数
static int gReplaced = 0;   // 内容替换真正改过字段的次数
static int gDndDropped = 0; // v0.0.21：免打扰时段拦下的条数
static int gSoundApplied = 0; // v0.0.21：尝试过换提示音的条数（成没成看 SOUND# 那行）
// 去重表：key -> 最后一次记录的时间戳
static NSMutableDictionary *gRecent = nil;

static NSString *NBProc(void) {
    NSString *p = [NSProcessInfo processInfo].processName;
    return p.length ? p : @"?";
}

// 🔴 v0.0.13：日志实现搬到 NotifyStore.m 的 NBSharedLog（那个文件 tweak 与 App 都编），
//    这里只留一个别名，全部调用点不用改。
//    为什么不各留一份：Tweak.x 原来是 static NBLog，新加的 NotifySpeaker/NotifyProbe
//    够不着它。复制一份日志函数是最差解 —— 两份轮转逻辑迟早走岔。
#define NBLog NBSharedLog

// 🔴🔴 v0.0.71：**版本串必须在「第一次被引用之前」定义**。
//   原来它躺在第 ~452 行的护栏常量堆里（上下文是"版本号写进护栏文件、每个新版本
//   自动获得一次重试机会"），而 v0.0.71 把第 ~424 行那句 `[v0.0.70]` 也换成了它
//   ⇒ **引用在定义之前** ⇒ 编译期直接
//        error: use of undeclared identifier 'NB_VER_STR'
//   教训（源码级自检抓不到）：括号配平 / `_NonNull` / 版本四处一致 / 行尾这几条
//   全是**文本层**判据，没有一条能发现"符号可达性"问题 ⇒ 新增一条自检：
//   **改「字面量 → 宏」之前，先比一行号：`#define` 在哪、第一个引用在哪。**
//   顺便加一条：`#define` 别埋在几百行之后的常量堆里，宏一律放这个区域。
#define NB_VER_STR @"0.0.85"

// ---------- 延迟推送的残留清理（v0.0.19） ----------
//
// 🔴🔴 为什么这一版把"自愈"整个换掉 —— v0.0.16~v0.0.18 的自愈会**骗人**：
//
//   真机现场（用户 v0.0.18 截图）：
//       17:59:52  延迟自愈已触发 / 已自动删除 delaySeconds ⇒ 延迟推送回到关闭状态
//       18:00:18  DELAY#2516 tag=PBRS 5.0s 字段=date          ← 26 秒后还在推
//       18:00:18  DELAY#2517 tag=PB   5.0s 字段=date+...
//   ⇒ 它说"删了"，实际上延迟还在按 5 秒跑。用户看到的是"功能明明关掉了，通知还是不弹"。
//
//   病因查清了，而且是我自己埋的：
//     `NBWriteDelayGuard(@"start")` 只在 **v0.0.15** 那个 commit 里被调用过；
//     v0.0.16 把"写 start"删了、却把"读 start"留着。而 v0.0.15 的延迟是全程关闭的，
//     所以它写下 start 之后**永远等不到 done** ⇒ 这个文件永久停在 start
//     ⇒ 从 v0.0.16 起每次启动都误判成"上次崩在延迟里"。
//     （git log -S 'NBWriteDelayGuard(@"start")' 只有 d47ac61 / 6dc778c 两个 commit。）
//
//   ⇒ 教训：**一个只写不读的状态是死状态，一个只读不写的状态是永远为真的谎言。**
//     自愈判据必须"写和读在同一处、成对出现"，且**回读验证**。
//
// 现在的做法只有一件事：把残留的键**真的**清掉，然后把**回读结果**打出来。
//   不判断、不自愈、不猜测 —— 因为功能已经整个删除了，没有"开着"这个状态。
static void NBPurgeDelayLeftovers(void) {
    @try {
        // 两处都要清：NBLoadSettings() 是「新文件优先，旧 Preferences 域兜底」，
        // 只清一个的话，另一个会把键"复活"回来。这就是"删了还在跑"的第二个可能来源。
        NSArray *paths = @[NOTIFYBOX_SETTINGS_PATH, NOTIFYBOX_PREFS_PATH];
        BOOL purged = NO;

        for (NSString *path in paths) {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
            if (![d isKindOfClass:[NSDictionary class]] || !d.count) continue;
            if (!d[NB_KEY_DELAY_SECONDS] && !d[NB_KEY_DELAY_APPS]) continue;

            NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:d];
            [m removeObjectForKey:NB_KEY_DELAY_SECONDS];
            [m removeObjectForKey:NB_KEY_DELAY_APPS];
            if ([m writeToFile:path atomically:YES]) purged = YES;
            else NBLog(@"!!! 清理延迟残留失败（写不进去）：%@", path);
        }

        // 🔴 回读验证：把"我以为的结果"换成"实际读到的结果"。
        //    上面那句 v0.0.18 的假话就是这么来的 —— 只有写、没有回读。
        NSDictionary *back = NBLoadSettings();
        BOOL gone = (back[NB_KEY_DELAY_SECONDS] == nil && back[NB_KEY_DELAY_APPS] == nil);
        if (!gone) {
            NBLog(@"!!! 延迟残留还在：回读 settings 仍有 delaySeconds=%@ delayApps=%@",
                  back[NB_KEY_DELAY_SECONDS] ?: @"(无)", back[NB_KEY_DELAY_APPS] ?: @"(无)");
        } else if (purged) {
            NBLog(@"已清除延迟推送的历史残留（回读确认已无 delaySeconds / delayApps）");
        }

        // 老版本留下的 guard 文件同样是垃圾（它停在 start 上，会让旧版误判）。
        // 顺手删掉：万一用户回退到旧版，也不会再被这个死状态骗到。
        [[NSFileManager defaultManager] removeItemAtPath:NOTIFYBOX_DELAY_GUARD_PATH error:nil];
    } @catch (__unused NSException *e) { }
}

// ---------- 防御式取值：SpringBoard 里抛异常就等于崩，全部包 @try ----------

// 🔴🔴 v0.0.64：**绝不对未知类调 `description`**。
//   v0.0.63 真机铁证：进入 NC 队列的 9 条 9 条全没回来、连第一行都没打印；
//   而那块第一句里唯一新增的动作就是对 `BBBulletin` / `NCNotificationRequest`
//   这类**未知类**调 `description`。这类对象的 `-description` 会摸内部锁、
//   或递归描述整包 payload ⇒ 在 NC 队列上调即自杀。
//   ⇒ 只接受「本来就是字符串」或「数字」（NSNumber 的 description 是安全的、纯格式化）。
//     其余一律返回 nil —— 少显示一个字段，远好过把手机卡死。
static NSString *NBStringish(id v) {
    if (!v) return nil;
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return nil;   // ⛔ 不调 description
}

static id NBSafeValue(id obj, NSString *key) {
    if (!obj) return nil;
    if (![obj respondsToSelector:@selector(valueForKey:)]) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *NBSafeStr(id obj, NSString *key) {
    id v = NBSafeValue(obj, key);
    if (!v) return nil;
    return NBStringish(v);
}

static NSDate *NBSafeDate(id obj, NSString *key) {
    id v = NBSafeValue(obj, key);
    return [v isKindOfClass:[NSDate class]] ? (NSDate *)v : nil;
}

static NSString *NBClassName(id obj) {
    if (!obj) return @"nil";
    @try {
        return NSStringFromClass([obj class]);
    } @catch (__unused NSException *e) {
        return @"?";
    }
}

// ---------- 去重 ----------
// 三个发布入口可能依次都被调用，同一条通知不能记三遍。
// 窗口取 2 秒：足够覆盖同一次发布的多个入口，又不至于吃掉用户连发的两条相同通知。
static BOOL NBClaimKey(NSString *key) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    @synchronized (gRecent) {
        if (!gRecent) return YES;
        NSNumber *t = gRecent[key];
        if (t && (now - t.doubleValue) < 2.0) return NO;
        gRecent[key] = @(now);
        if (gRecent.count > 300) {
            NSMutableArray *dead = [NSMutableArray array];
            for (NSString *k in gRecent) {
                if (now - [gRecent[k] doubleValue] > 15.0) [dead addObject:k];
            }
            // 🔴 NSMutableDictionary 的方法是 removeObjectsForKeys:（复数 Keys）
            if (dead.count) [gRecent removeObjectsForKeys:dead];
        }
        return YES;
    }
}

// ---------- 录制 ----------
// sectionHint：能从参数直接拿到 sectionID 时优先用（最可靠）
// 🔴 v0.0.8：返回**真正用来记录的那个 bundle**（可能是从 .bulletin 里兜出来的）。
//    这样下游过滤判定用的 bundle 和库里存的是同一个值，不会出现「记的 A、判的 B」错位。
//
// 🔴 v0.0.13 新增 firstTime 出参（可为 NULL）：
//    三个入口可能对同一条通知依次触发，去重表只会让**第一条**真正落库。
//    但调用方仍然拿到 bid ⇒ 下游会跟着跑三次。
//    这对「过滤/替换」无害（幂等：判三次、替换三次结果一样），
//    对**朗读**是灾难 —— 用户会听见同一句话被读三遍。
//    所以必须把"是不是首次"这个事实交出去，而不是让每个下游自己再猜一遍。
// ---------- v0.0.52：同步清系统通知中心（盒子删记录 → 通知中心也删那一条） ----------

// 🔴 声明在 NSObject 上，避免编译器不认识 BBServer 类型而报警；
//   真正有没有这个方法，运行时用 respondsToSelector: 守卫，没有就优雅跳过（不崩）。
// 🔴🔴 v0.0.57：这些选择器**全部来自真机 dump 的 nc_diag.txt**（v0.0.56 探针取回），
//   不是我猜的名字 —— 名字/参数个数/类型都按 dump 里的签名写，所以调用是 ABI 正确的。
@interface NSObject (NBClearNC)
- (void)_clearBulletinIDs:(NSArray<NSString *> *)identifiers
            forSectionID:(NSString *)sectionID
              shouldSync:(BOOL)shouldSync;
// ---- 以下是 v0.0.57 新增（签名照 nc_diag.txt 抄） ----
- (NSArray *)_bulletinsForIDs:(NSArray<NSString *> *)ids;                 // @@:@  按 ID 取真实对象
- (NSArray *)_allBulletinsForSectionID:(NSString *)sectionID;             // @@:@  段内 live 枚举
- (void)_removeBulletin:(id)bulletin shouldSync:(BOOL)shouldSync;         // v@:@B  按对象删
- (void)_removeBulletins:(NSArray *)bulletins
            forSectionID:(NSString *)sectionID
              shouldSync:(BOOL)shouldSync;                                // v@:@@B 按对象数组删
- (void)withdrawBulletinRequestsWithRecordID:(NSString *)recordID
                                forSectionID:(NSString *)sectionID;       // v@:@@  iOS16 正规撤回
- (void)withdrawBulletinRequestsWithPublisherBulletinID:(NSString *)publisherBulletinID
                                           forSectionID:(NSString *)sectionID;  // v@:@@
- (void)withdrawBulletinID:(NSString *)bulletinID;                       // v@:@
// ---- v0.0.72：按 bulletinID 直接摘（签名照 `nc_diag(11).txt` 的方法表逐字抄）----
// 🔴🔴 这两行**不是可选的**：`gBBServer` 的类型是 `id`，选择器只要在整份 TU 里
//    **没有被声明过**，clang 就报 `no known instance method for selector ...` ⇒ 直接编译失败。
//    v0.0.72 就是这么炸的（四道文本自检全绿，因为括号/宏/行尾都没问题）：
//    调用一个未声明的选择器在 C 里根本不是"运行时会不会崩"的问题，而是**编译期就过不去**。
//    这一条已补进源码自检第 ⑨ 道（见 tools/check_selectors.py）。
// ---- v0.0.74：两条 `removeBulletinID:*` 的声明已删 ----
// 🔴 ⑤ 三条刀整体删除后，整份 TU 里**再没有地方发这两个选择器**。
//    留着声明的坏处：它们会进 `__objc_methname` ⇒ 包级反向判据
//    「旧选择器必须消失」永远过不了，下一轮看包里还有这名字会误判成"还在用"。
- (void)_sendRemoveBulletin:(id)bulletin
                    toFeeds:(unsigned long long)feeds
                 shouldSync:(BOOL)shouldSync;                            // v@:@QB 广播给 observer（只观测）
- (void)_sendRemoveBulletins:(id)bulletins
                     toFeeds:(unsigned long long)feeds
                  shouldSync:(BOOL)shouldSync;                           // v@:@QB 复数版（v0.0.76 只观测）
// ---- v0.0.77：⑦d 的两条声明已删（`clearAction` / `destination:performAction:…`）----
// 🔴 ⑦d 整把刀删除后，整份 TU 里**再没有地方发这两个选择器**。
//    死声明留在 `__objc_methname` ⇒ 包级反向判据「旧选择器必须消失」永远过不了。
// ---- v0.0.73：CoverSheet 目的地自己那几条「清除」----
// 🔴 为什么换到这一层：v0.0.72 真机（`nc_diag(12).txt`）定案 —— ⑤ 新刀三条候选
//    都**广播出去了**（`_sendRemoveBulletin` 计数 1→4）却**没动账本**（BB live 一直=2）；
//    而 ⓪ 官方撤回把账本清干净了（live 2→1、含本条=否）之后，
//    `系统自己传给 NC` 仍然是 **0 次**，界面照旧不动 ——
//    说明「BB 账本 → NC 界面」这一跳根本不靠 observer 广播，得直接在 CoverSheet 侧动手。
//    这个类的方法表在这一轮才第一次被看见（52 个），里面有现成的 clear 语义。
- (void)destination:(id)destination clearNotificationRequests:(id)requests;             // v@:@@
- (void)destination:(id)destination clearNotificationRequestsInSections:(id)sections;   // v@:@@
- (void)destination:(id)destination clearNotificationRequestsFromDate:(id)fromDate
                                                                toDate:(id)toDate
                                                            inSections:(id)sections;    // v@:@@@@
- (void)_clearNotificationRequestsFromIncomingSection:(id)section;                      // v@:@
- (BOOL)dismissNotificationInLongLookAnimated:(BOOL)animated;                           // B@:B ← 返回 BOOL
- (id)listDestination;                                                                  // @@:  列表目的地（真 UI）
- (id)modalDestination;                                                                 // @@:  模态目的地（长按预览）
- (void)postNotificationRequest:(id)request;                                            // v@:@ （CS 侧投递）
// ---- NC 原生路径（这条才会驱动界面）----
- (void)withdrawNotificationWithRequest:(id)request;                     // v@:@  NCNotificationDispatcher
- (id)notificationRequestWithSectionId:(NSString *)sectionID
                        notificationId:(NSString *)notificationId;       // 类方法，用 (id)cls 发
// ---- v0.0.58：NCBulletinNotificationSource（BB 与 NC 之间的桥）----
- (id)dispatcher;                                                        // @@:  拿 dispatcher
- (id)observer;                                                          // @@:  拿 BBObserver
- (void)observer:(id)observer removeBulletin:(id)bulletin;               // v@:@@ BB 撤回时 NC 侧真正的入口
- (id)bulletinsToUUIDs;                                                  // @@:  bulletin → NC uuid
- (id)uuidsToRequests;                                                   // @@:  NC uuid → 真 request
// 🔴🔴 v0.0.81：这两个 **setter 必须声明**。`gNCSource` 的类型是 `id`，
//    往 `id` 上发一个没在可见 @interface 里声明过的选择器 = **编译期硬错**
//    （"no visible @interface declares the selector"），八道文本自检全绿也挡不住。
//    真机方法表里它们是 `setUuidsToRequests: v@:@` / `setBulletinsToUUIDs: v@:@`。
- (void)setUuidsToRequests:(id)m;                                        // v@:@ ⑦u 摘映射用
- (void)setBulletinsToUUIDs:(id)m;                                       // v@:@ ⑦u 同步摘悬空键
// 🔴 v0.0.83：`observer:addBulletin:forFeed:` 的声明**已随观测一起删除**。
//    真机 `nc_diag(22).txt`：`addBulletin 累计=0` 打 8 次，同期段重载 122→242 次
//    ⇒ 这个 source 不走 addBulletin，加回全走「段重载」。留死声明只会进 `__objc_methname`，
//    让反向判据「旧选择器必须消失」永远不过（§13③）。
// 🔴 v0.0.82：同样必须声明（往 `id` 上发未声明选择器 = 编译期硬错，§7.6 第 ⑨ 道）。
//    真机方法表逐字：`observer:modifyBulletin:forFeed: v@:@@Q`（同 addBulletin，第三参是 Q）。
//    `observer:noteBulletinsLoadedForSectionID:` 方法表里是 `v@:@@`。
- (void)observer:(id)observer noteBulletinsLoadedForSectionID:(id)sectionID;
- (void)observer:(id)observer modifyBulletin:(id)bulletin forFeed:(unsigned long long)feed;
// ---- v0.0.64：一次性换 uuid（不遍历、不 description）----
- (id)_requestUUIDForBulletinPublisherMatchID:(NSString *)matchID;        // @@:@  publisherMatchID → uuid
- (id)dispatcher:(id)dispatcher notificationRequestForUUID:(NSString *)uuid; // @@:@@ 后备取真 request
// ---- v0.0.67：照着系统自己那条路走 ----
// 🔴 签名依据是真机观测到的**成对调用**（nc_diag(8).txt）：
//    dispatch 侧 destination:requestsClearing… 与 source 侧 dispatcher:requestsClearing…
//    每次条数一致 ⇒ 就是"目的地请求清除 → 翻成 bulletin 交给 BBServer"这一条链。
//    `requests` 实测是集合（日志里能数出条数），按 `@@:@@` 发。
- (void)destination:(id)destination requestsClearingNotificationRequests:(id)requests;   // v@:@@
- (void)dispatcher:(id)dispatcher requestsClearingNotificationRequests:(id)requests;     // v@:@@
// ---- v0.0.68：签名全部照真机方法表抄（nc_diag(9).txt，v0.0.67 自己 dump 出来的）----
- (id)destinationsRegistry;                        // @@:  NCNotificationDispatcher 的 destination 注册表
- (id)registeredDestinations;                      // @@:  NCNotificationDestinationsRegistry 内的集合
- (id)bulletin;                                   // @@:  NCNotificationRequest → **BBBulletin**（精确匹配的钥匙）
- (id)requestDestinations;                         // @@:  NCNotificationRequest 自己记录了要投给谁
- (void)withdrawNotificationRequest:(id)request;   // v@:@ CSNotificationDispatcher —— **界面层**的那一刀
@end

// 🔴 捕获 BBServer 单例与其内部队列（在 publish hook 里、即 BB 队列上调用时 capture）。
// 🔴 不用 extern __BBServerQueue：iOS 16 该全局符号可能未导出，
//    tweak 加载时链接失败会直接进安全模式。改为在 hook 里 capture self + 当前队列，绕开外部符号。
static __strong id gBBServer = nil;
static dispatch_queue_t gBBServerQueue = nil;
static void NBCaptureServerIfNeeded(id server) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gBBServer = server;          // 单例，强引用无碍
        // 🔴 dispatch_get_current_queue() 已废弃，包一层忽略弃用警告
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        gBBServerQueue = dispatch_get_current_queue();
        #pragma clang diagnostic pop
        NBLog(@"=== [v%@] 已捕获 BBServer 实例 + 队列（同步清通知中心可用）", NB_VER_STR);
    });
}

// ---------- v0.0.58：NC 原生路径的现场捕获 ----------
// 🔴 为什么非捕获不可：真机清单里 `NCNotificationDispatcher` **一个类方法都没有**
//    （dump 写着 `+ 无方法(共0)`）⇒ 拿不到单例，只能在它被别人创建/调用时抓住实例。
//    `NCBulletinNotificationSource - initWithDispatcher:observer:queue:` 正好把 dispatcher 递过来。
// 🔴 为什么还要走 NC 这一层：BB 侧的 `_removeBulletin:` 改的是 BB 的账本，
//    而 iOS 16 通知中心列表是 NC 派发器驱动的；BB 删了 NC 不一定跟着刷新
//    ⇒ 「数据层删掉了、眼睛还看得见」这种半成品必须靠这条路兜住。
static __strong id gNCSource = nil;         // NCBulletinNotificationSource 实例
static __strong id gNCDispatcher = nil;     // NCNotificationDispatcher 实例
// ---- v0.0.78：⑧ 的两件现场（`gBBObserver` / `gSelfPostingRemove`）已删 ----
// 🔴 删的理由是**整把刀没了**，不是"换名字"：`nc_diag(18).txt` 实测 ⑧ 只投递到 1 次，
//    块进了 `observer:removeBulletin:` 就**再也没返回**（`.nc_pending` 从 08:05:18 留到
//    08:07:15，近 2 分钟；后面 29 次尝试全被那道闸门挡在原地）。
//    它既没卡屏注销（后台队列生效了），也**一次都没成功** —— 留着只会继续废掉后面的尝试。
// 🔴 按 §1.13③：刀删了，只给它用的变量一起删；否则留着会被下一轮读成"还在用"。
// 🔴🔴 v0.0.62：**必须**也抓住这条队列 —— 系统平时就是在这条队列上回调 source 的
//    （`initWithDispatcher:observer:queue:` 的第 3 个参数）。NC 的动作只在它上面跑，
//    不在 BB 队列上跑 —— v0.0.61 就是因为在 BB 队列里同步调 NC 而把 SpringBoard 卡死。
//    抓不到就宁可不调。
static dispatch_queue_t gNCSourceQueue = nil;
// ---------- v0.0.62：NC 路径的「卡死自恢复」 ----------
// 🔴 v0.0.61 卡死注销一次就够了，不能让它变成「每次删都卡」。三个文件分工：
//    `.nc_pending` —— 进 NC 路径前写、跑完立刻删。**它留到下次开机 = 上一次卡死了**。
//    `.nc_off`     —— 开机看到 `.nc_pending` 还在，就建这个 ⇒ 本次及以后**永久禁用 NC 路径**，
//                     只删 BB 账本（不卡、但界面也不变）。删掉这个文件即可重新尝试。
//    这就是「朗读自愈」那套思路的复用：先保证手机能用，再谈功能。
static NSString *const kNBGuardPending = @"/var/mobile/Library/NotifyBox/.nc_pending";
static NSString *const kNBGuardOff     = @"/var/mobile/Library/NotifyBox/.nc_off";
// ---------- v0.0.78：⑦r（CS 侧带时间窗的单条清除）护栏 ----------
// 🔴 为什么这把刀也要护栏：它在**主队列**上同步调一个从没调过的 NC/CS 方法。
//    v0.0.76 的「卡屏后注销」就是主队列上同步调未知 NC 方法造成的自死锁。
//    CS 侧方法理论上就该在主队列跑（v0.0.75 的 ⑦c 在主队列上跑过、没卡），
//    但"理论上"不是证据 ⇒ 按 §1.11 给它一个**带版本戳的熔断标记**：
//      调用前写 `.cs_ws` → 返回立刻删；留到下次开机 = 这把刀把主队列卡死过
//      ⇒ 写 `.nc_off` 永久压制（和 NC 路径共用同一个"关掉界面侧"开关）。
static NSString *const kNBGuardCSWs   = @"/var/mobile/Library/NotifyBox/.cs_ws";
static BOOL gCsWsSuppressed = NO;   // YES ⇒ 本进程不用 ⑦s/⑦t/⑦r（但账本照清）
// 🔴 v0.0.80：⑦s/⑦t 与 ⑦r **共用同一个护栏文件**，靠文件正文里的标记（⑦s/⑦t/⑦r）
//    区分是哪一把刀没返回。三把都是「主队列上同步调未知 NC/CS 方法」，失败模式同一类，
//    分开建文件只会让启动检查变长，不会多出任何信息。
// ---------- v0.0.78：[寿] 旧删台账 ----------
// 🔴 它要回答的是**比"这一刀成不成"更根本的问题**：
//    「⓪ 把 BB 账本清了之后，NC 里那条到底会不会自己消失？多久消失？」
//    这一版之前所有读回都是「删完同秒读回」，等于默认"立即生效" —— 而宿主实测
//    BB→NC 传播是 **65 秒 ~ 4.5 分钟**（`nc_diag(17).txt`：07:41 撤、07:45:56 才到 NC）
//    ⇒ 同秒读回**必然**读到"还在"，它不是判据，是噪声。
//    做法：⓪ 成功那条记进台账；每次进 NC 侧时扫一遍比对 ⇒ 一行就能看出"几分钟后消失"。
static NSString *const kNBDeletedLog = @"/var/mobile/Library/NotifyBox/.nb_deleted";
// v0.0.79：[段] / [重] 的明细每个进程只打一次（日志窗口 ≈ 最后 50 条、全局滚动）
static BOOL gCensusDumped = NO;
#define NB_DEL_KEEP 24            // 台账最多留 24 条（更老的没有诊断价值，且让扫描变贵）
// 🔴 版本号写进护栏文件：**每个新版本自动获得一次重试机会**。
//    否则 v0.0.62 那次卡死留下的 `.nc_off` 会一直压着，新版明明修好了也测不到。
// 🔴 v0.0.71：`#define NB_VER_STR` **已上移到 `#define NBLog` 那一区**（文件最前面的宏区）。
//    原来它就在这个位置，而第 ~424 行也要用 ⇒ 引用在定义之前 ⇒ 编译失败。
//    这里只留说明，不再放定义。
static BOOL gNCSuppressed = NO;   // YES ⇒ 本进程不碰界面侧（⑧），但**账本照清**
// ---------- v0.0.78：⑧ 的后台队列（`gNC8Queue` / `gTry8Busy` / `NBEnsure8Queue`）已删 ----------
// 🔴 v0.0.77 自建这条串行队列**是对的**（它确实把「卡屏注销」治好了：v0.0.78 这份
//    `nc_diag(18).txt` 里 30 次尝试、无一卡屏），**错的是块里的那一刀**：
//    块进了 `observer:removeBulletin:` 就没再回来 ⇒ 队列本身没卡（进程还能正常写日志），
//    但那把刀在**方法内部**等一个永远不来的东西。⇒ 换队列救不了它，只能换刀。
// 🔴 教训写在这里，不要下次又"自建一条队列试试"：**队列选对了 ≠ 刀选对了**。
static BOOL gNCBusy = NO;         // YES ⇒ 上一次 NC 尝试还没回来（同进程内不再赌第二次）
static NSTimeInterval gNCBusyAt = 0;   // 🔴 v0.0.65：闸门加上时间戳，超时自动放行
// 🔴🔴 v0.0.65：**默认不再把动作投到 NC 队列**。
//   v0.0.64 真机铁证（`nc_diag(6).txt`）：写了 `.nc_pending`、进了 dispatch_async，
//   然后 **NC 块的第一行 `[NC] 进入 NC 队列` 一次都没打印**，30 秒内 4 次后续尝试全被
//   `gNCBusy` 挡住。同一条 dispatch 在 v0.0.62 是能跑起来的 ⇒ 说明这条队列这次没被服务。
//   既然投了也不跑，不如**不投**：⓪ 官方撤回已经证明能把 BB 账本清干净，
//   本版就把这条唯一有效的路走到底，同时用观测 hook 看系统会不会自己把它传到 NC 侧。
//   代码保留（置 NO），下一版拿到队列身份证据再决定要不要开。
static BOOL gNCUseQueuePath = NO;
static int  gBBWithdrawOk = 0;    // ⓪ 成功清掉账本的次数（给观测 hook 做时间参照）
static int  gBBToNCSeen   = 0;    // 系统自己把「BB 撤回」传给 NC 的次数（观测 hook 累加）
// ---------- v0.0.72：新刀「按 bulletinID 直接摘」的两个计数 ----------
// 🔴 为什么换这把刀（全量 dump 重挖的结论，`nc_diag(11).txt` 前半段 253 个方法）：
//    已试的 31 条里失败原因只有四类，而 `removeBulletinID:…` 这一族**一次绕开其中两个**：
//      ① 不需要 destination 实例（`destination:requestsClearing…` 那个死结）；
//      ② 锚点精确到 **bulletinID（个体）**，不是 section（`BB live=2` 时按 section 匹配会撤错条）。
// 🔴 计数分开记，是因为它们回答的是**两个不同的问题**：
//    `gBBRemoveByIDOk` = 刀有没有真的把账本摘掉；
//    `gBBSendRemoveSeen` = 摘掉之后**有没有广播给 observer（NC）** —— 界面变不变看这一个。
//    两者都涨而界面不动 ⇒ 问题在 NC 那一侧；只有前者涨 ⇒ 刀只改了账本，还是老毛病。
static int  gBBRemoveByIDOk = 0;  // 新刀返回且**读回确认已删**的次数
static int  gBBSendRemoveSeen = 0; // 观测：BBServer - _sendRemoveBulletin:toFeeds:shouldSync: 被调次数
// v0.0.76：复数版（一次投一批）的观测。回答「v0.0.75 里那 8 条为什么挤在同一秒」。
static int  gBBSendRemoveManySeen = 0;
// ⛔ v0.0.67：`gNCGlobalTried` / `gGQWithdrawOk` 已随旧 [GQ] 通道一起删除 ——
//    那条通道只会调 `withdrawNotificationWithRequest:`，而 v0.0.66 真机证明
//    用户手动清一条时 **withdraw 一次都不走**（观测计数 = 0）。
//    🔴 v0.0.74 修正：这只对"手动清一条"成立。**真删除**（段清 / BB 撤回驱动的那一批）
//    每条都配一次 `withdrawNotificationWithRequest:` —— 见 v0.0.73 真机 9 条一一对应。
//    留着它只会继续骗自己"还差一步"。
// ---------- v0.0.66：观测计数器（只为了回答"系统自己怎么删的"）----------
static BOOL gCacheDumped   = NO;  // 缓存键形态只 dump 一次
static int  gObsDispatcherClear = 0;  // dispatcher - destination:requestsClearingNotificationRequests:
static int  gObsDispatcherWithdraw = 0;  // dispatcher - withdrawNotificationWithRequest:（系统+我方，混计）
// 🔴 v0.0.80：**我方**调用计数单独记 —— 混计会把「系统自己调了 N 次」读成「我的刀跑了 N 次」。
static int  gNCDirectWithdraw = 0;       // ⑦s：我方调 NCNotificationDispatcher -withdrawNotificationWithRequest:
static int  gCSDirectWithdraw = 0;       // ⑦t：我方调 CSNotificationDispatcher -withdrawNotificationRequest:
static int  gNCDirectMapKill  = 0;       // ⑦u：我方从 NC source 映射里摘掉的**键**数
// 🔴 v0.0.83：`gReAddSeen`（[RE] 命中加回）已随观测一起删除 —— 见下面 [RL] 那段注释。
// ---------- v0.0.82：纯诊断计数（不加新刀）----------
// 🔴 缺口一：「[RE] 加回=0」**没有分母**。`投递=%d` 打的是 `gCSDPost`（CS dispatcher 投递），
//    不是 addBulletin 的次数 ⇒ 现在无法区分「钩子活着但没命中」和「钩子根本没被调用」。
//    判据绿的原因必须等于它本来要证的那件事 ⇒ 先给分母。
// 🔴🔴 v0.0.83：`[RE]`（addBulletin）整场**累计=0** —— `nc_diag(22).txt` 里
//    `addBulletin 累计=0` 连打 8 次，而同期 `重建入口` 从 122 涨到 242。
//    ⇒ 这个 source **根本不走 `observer:addBulletin:forFeed:`**，加回全走「段重载」。
//    「命中加回=0」于是从来不是「没人加回」，而是**这个探针从没被调用**（典型假绿）。
//    ⇒ 按 §13③：删掉观测**并连声明一起删**。加回真凶改由 [RL] 常驻记录。
static int  gNoteLoadedSeen   = 0;   // [RL] noteBulletinsLoadedForSectionID: 总次数（映射重建入口）
static int  gModifySeen       = 0;   // [RM] modifyBulletin:forFeed: 总次数
static int  gModifyHit        = 0;   // [RM] 其中命中「最近删过」的条数
static int  gPostSeen         = 0;   // [RP] NCNotificationDispatcher -postNotificationWithRequest: 总次数
static int  gRepostHit        = 0;   // [RP] 其中命中「最近删过」的条数 = 复投
// ---------- v0.0.83：[RL] 常驻环形缓冲 ----------
// 🔴 为什么不能只在诊断窗口记：v0.0.82 的真机数据是 **242 次重载 / 0 行日志**。
//    原因：打印条件里带了 `NBDiagReady()`（= 诊断文件存在），而诊断文件只在用户点
//    「生成诊断」那一刻才存在 —— 全部重载都发生在窗口之外。
//    ⇒ 纪律：**别把「必须拿到手的记录」挂在「可能不发生的事件」上**。
//    正解 = 常驻记录（只存时间戳 + 段名，24 条环形），到 ⑦ 段再补打出来。
#define NB_RL_RING 24
static NSTimeInterval gRlTs[NB_RL_RING];
static char  gRlSec[NB_RL_RING][48];
static int   gRlNext  = 0;
static int   gRlTotal = 0;
// 🔴 v0.0.81：⑦r 默认**关闭**。依据：`nc_diag(21).txt` 26 次尝试里，⑦r 的「已返回」和
//    「读回还在」都可以被 ⑦s/⑦t 完全解释 —— 它从来没有过一次**独立生效**的证据，
//    而它是三把刀里唯一有连带风险的（时间窗一旦被忽略就是整段清）。
//    要看它就把它改成 YES，别默认开着烧轮次。
static BOOL gUseR = NO;
static int  gObsSrcClear   = 0;   // source - dispatcher:requestsClearingNotificationRequests:
// ---------- v0.0.73：CoverSheet 目的地（CSNotificationDispatcher）侧的观测计数 ----------
// 🔴 这一组存在的唯一目的：回答「**用户手动清一条通知时，系统到底调了哪一把**」。
//    v0.0.72 已经证明：账本清干净了、广播也发了，NC 侧计数仍是 0、界面不动。
//    再猜下去只会继续白跑 —— 必须先让系统自己在正确的时机把答案打出来。
//    ⇒ 这一组全是**只读**：只计数 + 打几行，原样 `%orig` 透传，绝不改参数、绝不吞调用。
static int  gCSDPost      = 0;   // - postNotificationRequest:（**存活对照**：它一定会有，证明 hook 真的挂上了）
static int  gCSDWithdraw  = 0;   // - withdrawNotificationRequest:
static int  gCSDClear     = 0;   // - destination:clearNotificationRequests:
static int  gCSDClearSec  = 0;   // - destination:clearNotificationRequestsInSections:
static int  gCSDClearRng  = 0;   // - destination:clearNotificationRequestsFromDate:toDate:inSections:
static int  gCSDIncoming  = 0;   // - _clearNotificationRequestsFromIncomingSection:
static int  gCSDDismiss   = 0;   // - dismissNotificationInLongLookAnimated:
static BOOL gCSDDestsDumped = NO;  // listDestination / modalDestination 只看一次
static NSMutableDictionary *gNCRequestByID = nil;  // notificationIdentifier → NCNotificationRequest
// ---------- v0.0.67：改走「正向清除」需要的东西 ----------
// 🔴 v0.0.66 真机 `nc_diag(8).txt` 定案两件事（都不是猜的）：
//   ① 用户手动清通知时，系统**成对**走这两跳，条数一模一样（各 2 条）：
//        NCNotificationDispatcher      - destination:CSNotificationDispatcher requestsClearingNotificationRequests:
//        NCBulletinNotificationSource  - dispatcher:requestsClearingNotificationRequests:
//      而 `withdrawNotificationWithRequest:` **0 次** ⇒ 「手动清一条」这一路不走 withdraw。
//    🔴 v0.0.74 修正边界：**"真删除"那一批是逐条走 withdraw 的**（v0.0.73 真机 15 次 /
//    9 条真删除）。所以这条路不是"不存在"，是"只在真删除时才出现"。
//      上一版把希望押在 withdraw 上，押错了方向。
//   ② `[cache]` 里键是**纯数字 nid**（7700421581079711010），而我们的 cid 是 UUID、
//      recordID 是 `f__-XoQCXfP67C4A` ⇒ **永远对不上**。所以「按 id 找 request」结构性无效，
//      换成 **按 sectionIdentifier 找**（"属于哪个 App"是我们唯一确定、系统一定会写的字段）。
static BOOL      gMapDumped  = NO;   // 映射普查只做一次
static BOOL      gAPIDumped  = NO;   // 方法表只追加一次
static NSString *gWantBundle = nil;  // 最近一次要删的 App（给「按 section 找 request」用）
static NSArray  *gWantIDs    = nil;  // v0.0.68：本条的 cid / recordID / publisherID（精确匹配用）
// 🔴 v0.0.85：本条记录的 title / message。精确 ID 匹配不到时用它做兜底匹配。
//   为什么需要兜底：`nc_diag(24).txt` 34 次删除里 28 次是「同段有它条、ID 都不是目标」——
//   系统把同一条通知重投一次就会给新 ID，盒子里那行的 sys_id 就永远匹配不上，
//   用户看到的就是「删了没反应」。兜底判据见 NBFindRequestByContent。
static NSString *gWantTitle  = nil;
static NSString *gWantMsg    = nil;
static __strong id gCSDestination = nil;  // 真 destination（CSNotificationDispatcher 实例）
static BOOL gCSDestFromHook = NO;          // 它是「注册期 hook」接住的（不是靠 OBS 撞上的）
static __strong id gFoundNCReq = nil;     // 找到的**真** request（系统对象，不是我造的）
// 🔴🔴 v0.0.69：这两个计数**必须每次删除重新归零**。
//    原来它们是"全进程 ≤2 / 全进程 ≤4"，而 `gActClearTried` 只增不减、`tries` 是函数内 static
//    ⇒ **第 3 次删除之后 NC 那条路永远不再尝试**（且日志看起来像"什么都没发生"）。
//    这和 `.nc_off` / `gNCBusy` 是同一个设计缺陷（护栏没有解除条件）—— 我第三次犯。
//    判据：**上限要按"每次操作"算，不能按"每个进程"算**。
static int  gFindTries     = 0;      // 「找 request」尝试次数（**本次删除内** ≤4）

// KVC 读一个字段，读不到就返回 nil。
// 🔴 必须逐次 @try：类没有这个键时 valueForKey: 会抛 NSUnknownKeyException，
//    一次抛出就会带走整段逻辑（本项目在探针上踩过这个坑）。
static NSString *NBKVCStr(id obj, NSString *key) {
    if (!obj) return nil;
    @try {
        // ⛔ v0.0.64：不再 `[v description]` —— 只认 NSString / NSNumber（见 NBStringish）
        return NBStringish([obj valueForKey:key]);
    } @catch (__unused NSException *e) { return nil; }
}

// 把收到的 request 存起来（上限 300 条，超了整体清空 —— 宁可丢历史，也不要无限涨）
static void NBStashNCRequest(id request) {
    if (!request) return;
    NSString *nid = NBKVCStr(request, @"notificationIdentifier");
    if (!nid.length) return;
    @synchronized ([NSObject class]) {
        if (!gNCRequestByID) gNCRequestByID = [NSMutableDictionary dictionary];
        if (gNCRequestByID.count > 300) [gNCRequestByID removeAllObjects];
        gNCRequestByID[nid] = request;
    }
}

static id NBStashedNCRequest(NSString *nid) {
    if (!nid.length) return nil;
    @synchronized ([NSObject class]) {
        return gNCRequestByID ? gNCRequestByID[nid] : nil;
    }
}

// ⛔ v0.0.68：`NBFindCachedRequest` 已删除。
//   它做的是「在 post 缓存里按 cid / recordID / publisherID 找 request」，而
//   v0.0.67 真机（nc_diag(9).txt）把缓存键的真实形态摊开了：
//       key=7700421581079711010            section=com.ss.iphone.ugc.Aweme
//       key=com.huaye.Drinking-2026-10-25-15-01
//   有的 App 用纯数字 nid、有的用它自己拼的串 —— **都不是 BB 那边的 UUID**。
//   ⇒ 拿 cid/recordID/publisherID 去这个字典里找，**结构性无解**，留着只会把下一轮又骗一次。
//   真要找本条，用 v0.0.68 的 `NBFindOurRequest`（按 section 缩小范围 +
//   `request.bulletin` 的 bulletinID 精确比对），它拿的是系统自己的对象。

// 集合/数组通吃地取第一个元素。
// 🔴 v0.0.57 真机踩过：`_bulletinsForIDs:` 返回的是 **NSSet**，我写 `bs[0]`
//    ⇒ `-[__NSSetM objectAtIndexedSubscript:]: unrecognized selector` ⇒ bullet 恒为 nil
//    ⇒ **最有希望的 `_removeBulletin:shouldSync:` 一次都没被执行**（那一轮的失败是脚本 bug，不是 API 不行）。
static id NBFirstObject(id coll) {
    if (!coll) return nil;
    @try {
        if ([coll isKindOfClass:[NSArray class]]) {
            NSArray *a = (NSArray *)coll;
            return a.count ? a[0] : nil;
        }
        if ([coll isKindOfClass:[NSSet class]]) return [(NSSet *)coll anyObject];
        if ([coll isKindOfClass:[NSDictionary class]]) {
            NSArray *vals = [(NSDictionary *)coll allValues];
            return vals.count ? vals[0] : nil;
        }
        if ([coll respondsToSelector:@selector(anyObject)]) return [coll anyObject];
    } @catch (__unused NSException *e) { }
    return nil;
}

// 段内 live 扫描：一次读同时给出「总数」和「我们这条还在不在」。
// 🔴 这是本版唯一的判据来源。要点：**删前删后必须同一口径**，
//    而且要找的是「我们这条」而不是「总数少了一个」——
//    v0.0.57 只比总数（50→49）无法归因（这中间用户自己划掉一条也一样会少）。
// 返回 -1 = 读失败；found = 本条是否仍在段内。
static NSInteger NBLiveScan(id server, NSString *section, NSString *cid, BOOL *found) {
    if (found) *found = NO;
    @try {
        id all = [server _allBulletinsForSectionID:section];
        NSArray *arr = nil;
        if ([all isKindOfClass:[NSArray class]]) arr = (NSArray *)all;
        else if ([all isKindOfClass:[NSSet class]]) arr = [(NSSet *)all allObjects];
        else if ([all respondsToSelector:@selector(allObjects)]) arr = [all allObjects];
        if (!arr) return -1;
        for (id b in arr) {
            NSString *bid = NBKVCStr(b, @"bulletinID");
            NSString *rid = NBKVCStr(b, @"recordID");
            if ((bid.length && [bid isEqualToString:cid])
                || (rid.length && [rid isEqualToString:cid])) {
                if (found) *found = YES;
            }
        }
        return (NSInteger)arr.count;
    } @catch (__unused NSException *e) { return -1; }
}

// v0.0.55 诊断：把入参类型签名里的**数字偏移**去掉，只留类型字符。
//   "@32@0:8@16B24" → "@@:@B"（= self, SEL, object, BOOL）
// 🔴 为什么必须带签名：v0.0.54 只打名字，光看名字分不清
//    `removeNotificationRequest:`（1 参）与 `removeNotificationRequest:options:completion:`（3 参），
//    下一版写调用只能靠猜 ⇒ 又是一轮。一次把名字+签名给全，下一版能直接写对。
static NSString *NBDiagEnc(Method m) {
    const char *e = method_getTypeEncoding(m);
    if (!e) return @"?";
    NSString *raw = [NSString stringWithUTF8String:e];
    NSMutableString *clean = [NSMutableString stringWithCapacity:raw.length];
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar ch = [raw characterAtIndex:i];
        if (![digits characterIsMember:ch]) [clean appendFormat:@"%C", ch];
    }
    return clean;
}

// v0.0.56 诊断：把某个类的**全部方法**（实例方法 + 类方法，带类型签名）收进 buffer。
// 🔴 只读类结构、**不调用任何未知方法**（零风险）。
// 🔴 为什么不筛关键字：v0.0.54/55 都按 clear/remove/withdraw… 筛，万一 iOS 16 的叫法
//    完全在筛子外（比如 `_handleDismiss…`、`dropBulletin…`），筛完就是一片空白 ⇒ 又白跑一轮。
//    这里**不筛**，全给，让我在本地 grep —— 一次拿全，不再依赖"猜关键字"。
static void NBDiagCollectClass(NSMutableString *buf, const char *clsName) {
    Class c = objc_getClass(clsName);
    if (!c) { [buf appendFormat:@"### %s 类不存在\n", clsName]; return; }
    for (int pass = 0; pass < 2; pass++) {
        // pass 0 = 实例方法；pass 1 = 元类（类方法，单例工厂在那里）
        Class target = (pass == 0) ? c : object_getClass((id)c);
        const char *mark = (pass == 0) ? "-" : "+";
        unsigned cnt = 0;
        Method *ms = class_copyMethodList(target, &cnt);
        if (!ms) { [buf appendFormat:@"### %s %s 无方法(共%u)\n", clsName, mark, cnt]; continue; }
        NSMutableArray *lines = [NSMutableArray arrayWithCapacity:cnt];
        for (unsigned i = 0; i < cnt; i++) {
            [lines addObject:[NSString stringWithFormat:@"%s %@\t%@", mark,
                              NSStringFromSelector(method_getName(ms[i])),
                              NBDiagEnc(ms[i])]];
        }
        free(ms);
        [buf appendFormat:@"### %s %s方法 %u 个\n", clsName, mark, cnt];
        for (NSString *ln in [lines sortedArrayUsingSelector:@selector(compare:)]) {
            [buf appendString:ln];
            [buf appendString:@"\n"];
        }
    }
}

// v0.0.56：把清单写进**独立文件**，返回写成功的字节数（0=失败）。
// 🔴 关键：文件不受「日志窗口只剩最后几十行」的限制 ⇒ 可以一次给全，用户直接整份发出来，
//    不用在几百 KB 的 tweak.log 里翻、也不会因为长行折行而漏读（v0.0.54/55 就栽在这）。
static NSUInteger NBDiagWriteFile(NSString *sysId, NSString *bundle) {
    NSMutableString *buf = [NSMutableString stringWithCapacity:(1 << 18)];
    // 🔴 v0.0.71：原来是写死的 `v0.0.56` 字面量 ⇒ v0.0.70 上跑出来的诊断文件
    //    第一行仍说自己 0.0.56。改成 NB_VER_STR，从此跟着版本走。
    [buf appendString:[NSString stringWithFormat:@"# NotifyBox v%@ · 通知中心可用 API 清单\n",
                                                      NB_VER_STR]];
    [buf appendFormat:@"# 生成时刻: %@\n", [NSDate date]];
    [buf appendFormat:@"# 触发时删的记录: sysId=%@ bundle=%@\n", sysId, bundle];
    [buf appendString:@"# 格式: [-+]选择器<TAB>类型签名   (签名里的数字偏移已去掉; @=对象 B=BOOL v=void)\n"];
    [buf appendString:@"# ### 开头是段标题\n"];
    // 🔴 挑这些类的理由：iOS 16 通知栈 = SpringBoard(BulletinBoard) + NotificationCenter(NC*) +
    //    UserNotificationsCore(UNC*)。真账本只可能在这三层里，三层全给，不留猜测余地。
    static const char *classes[] = {
        "BBServer", "BBObserver", "BBObserverClientProxy",
        "NCNotificationDispatcher", "NCNotificationCenter", "NCNotificationRequest",
        "SBNotificationCenterController", "NCBulletinNotificationSource",
        "UNCNotificationRepository", "UNCNotificationStore"
    };
    for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) {
        NBDiagCollectClass(buf, classes[i]);
    }
    [[NSFileManager defaultManager]
        createDirectoryAtPath:[NOTIFYBOX_NC_DIAG_PATH stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *err = nil;
    BOOL ok = [buf writeToFile:NOTIFYBOX_NC_DIAG_PATH atomically:YES
                      encoding:NSUTF8StringEncoding error:&err];
    // 自证：写盘成败 + 字节数都记一笔（写不进去时下一轮才不会误判成"类都取到了"）
    NBLog(@"=== [NC-DIAG] 清单 %@ ⇒ %@ (%lu 字节) 共 %lu 行",
          ok ? @"已写" : @"写失败", NOTIFYBOX_NC_DIAG_PATH,
          (unsigned long)[buf lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
          (unsigned long)[[buf componentsSeparatedByString:@"\n"] count]);
    if (!ok) NBLog(@"!!! [NC-DIAG] 写盘错误: %@", err);
    return ok ? [buf lengthOfBytesUsingEncoding:NSUTF8StringEncoding] : 0;
}

// v0.0.57：把一段文本**追加**到诊断文件末尾（方法表已经写好了，这里只追加「本次尝试记录」）。
//   🔴 为什么追加而不是重写：方法表是静态的（一次就够）；每次删除的尝试过程才是新信息。
//      两者放同一个文件 ⇒ 用户下次只要把这一个文件整份发来，信息就齐了。
static void NBDiagAppend(NSString *text) {
    if (!text.length) return;
    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:NOTIFYBOX_NC_DIAG_PATH];
        if (!fh) {
            [text writeToFile:NOTIFYBOX_NC_DIAG_PATH atomically:YES
                     encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
        } @finally { [fh closeFile]; }
    } @catch (__unused NSException *e) { }
}

// ---------- v0.0.61 / v0.0.64：NC 层的读与取 ----------
// 🔴 为什么必须有这一层：`_allBulletinsForSectionID:` 量的是 **BB 账本**，
//    而用户眼睛看的是 **NC 界面**。
// 🔴 v0.0.63 真机重要发现（`nc_diag(4).txt`）：
//      `bulletinsToUUIDs` 有 **1062** 条，但我们按 key 比对**匹配不上**（`含本条=否`）。
//      ⇒ key 到底是什么形态我还不知道（BBBulletin 对象 / publisherID / uuid 反向映射都有可能）。
//      ⇒ 所以这一版不再赌"哪种比法是对的"：**四种比法全都试**，并且**一次性把前几对
//        key / value 的类名和描述 dump 出来**。下次看一眼就知道该按什么匹配。
//      —— 这是本项目的老纪律：先量现场，再下判断；别拿"名字像"当证据。

static void NBDiagStep(NSString *fmt, ...);   // 定义在后面（写前日志）

// v0.0.73：诊断文件**存在了才能写**。
// 🔴🔴 为什么非要这个守卫：`NBDiagAppend` 在文件不存在时会**自己新建**它，
//    而「方法表只写一次」的判据正是 `!fileExists`（见 NBClearNCCallback 开头）。
//    v0.0.73 新加的 CS 观测 hook 是**系统级**的（用户一划掉任何通知都可能触发），
//    它完全可能在**任何一次删除之前**就跑 ⇒ 用几行观测日志把文件建出来
//    ⇒ 接下来那次删除会认为"方法表已经写过"，**整份方法表永久丢失**。
//    表现是"这次的文件里没有方法表"，极难联想到是观测日志干的。
//    所以：观测日志一律先问文件在不在；计数照常累加（日志没了数还在）。
static BOOL NBDiagReady(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:NOTIFYBOX_NC_DIAG_PATH];
}

// 把任意对象裁成可读短串（避免一行日志吃掉整个 bulletin 描述）
// 🔴🔴 v0.0.64：**绝不对未知类调 `description`**。
//    v0.0.63 真机 9/9 次进入 NC 队列都在第一句就再没回来，而第一句里唯一新增的动作
//    就是对 key / value 调 `description`。BBBulletin / NCNotificationRequest 的
//    `-description` 会去摸一把内部锁（或递归描述整包 payload）⇒ 在 NC 队列上等于自杀。
//    ⇒ 非 NSString 一律只回类名。要内容就只读**已知安全**的 KVC 键（NBKVCStr，v0.0.62 已验千条）。
static NSString *NBClip(id obj, NSUInteger max) {
    if (!obj) return @"(nil)";
    if (![obj isKindOfClass:[NSString class]]) {
        return [NSString stringWithFormat:@"<%@>", NSStringFromClass([obj class])];
    }
    NSString *s = (NSString *)obj;
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    if (s.length > max) s = [[s substringToIndex:max] stringByAppendingString:@"…"];
    return s;
}

// 集合条数（字典 / 集合 / 数组通吃，读不到返回 -1）。只读 count，不遍历、不 description。
static NSInteger NBCollectionCount(id c) {
    if (!c) return -1;
    @try {
        if ([c isKindOfClass:[NSDictionary class]]) return (NSInteger)[(NSDictionary *)c count];
        if ([c isKindOfClass:[NSSet class]])        return (NSInteger)[(NSSet *)c count];
        if ([c isKindOfClass:[NSArray class]])      return (NSInteger)[(NSArray *)c count];
        if ([c respondsToSelector:@selector(count)]) return (NSInteger)[c count];
    } @catch (__unused NSException *e) { }
    return -1;
}

// 四种比对全都试，任一命中即算命中；命中时把 uuid 取出来（可能在 key 侧也可能在 value 侧）。
static BOOL NCMatchEntry(id k, id v, NSString *cid, NSString **uuidOut) {
    if (!cid.length) return NO;
    // ① key 本身就是字符串且等于 cid
    if ([k isKindOfClass:[NSString class]] && [(NSString *)k isEqualToString:cid]) {
        if (uuidOut) *uuidOut = NBClip(v, 120);
        return YES;
    }
    // ② key 的 bulletinID / publisherBulletinID / recordID 等于 cid
    for (NSString *key in @[@"bulletinID", @"publisherBulletinID", @"recordID"]) {
        NSString *kb = NBKVCStr(k, key);
        if (kb.length && [kb isEqualToString:cid]) {
            if (uuidOut) *uuidOut = NBClip(v, 120);
            return YES;
        }
    }
    // ③ value 是字符串且等于 cid（映射方向可能是 uuid → bulletinID）
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v isEqualToString:cid]) {
        if (uuidOut) *uuidOut = NBClip(k, 120);
        return YES;
    }
    // ⛔ v0.0.64：原来的第 ④ 种比法是"key 的 description 里包含 cid"——
    //    就是对未知类调 description，v0.0.63 真机 9/9 卡死在这类调用上。
    //    ⇒ 已删除。只剩 ①②③ 三种比法，全部只碰字符串和**已知安全**的 KVC 键。
    return NO;
}

// 一次读两层的量：
//   返回值        = bulletinsToUUIDs 的条数（-1 = 读不到）
//   found         = 「本条」在不在映射里（四种比法任一命中）
//   uuidOut       = 本条对应的 uuid（可能为 nil）
//   reqCntOut     = uuidsToRequests 的条数（-1 = 读不到）
// 🔴 为什么要同时读 uuidsToRequests：`bulletinsToUUIDs` 少了「一条」不代表少的就是
//    我们这一条（v0.0.62 真机：1062→1061，但含本条前后都是「否」⇒ 少的那条可能根本不是我们的）。
//    两个数一起看，才能说清"我们这条到底动没动"。
static NSInteger NBScanNC2(id source, NSString *cid, BOOL *found,
                           NSString **uuidOut, NSInteger *reqCntOut) {
    if (found) *found = NO;
    if (uuidOut) *uuidOut = nil;
    if (reqCntOut) *reqCntOut = -1;
    if (!source) return -1;
    @try {
        if (reqCntOut) {
            @try {
                id rq = [source uuidsToRequests];
                if ([rq isKindOfClass:[NSDictionary class]])      *reqCntOut = (NSInteger)[(NSDictionary *)rq count];
                else if ([rq isKindOfClass:[NSSet class]])        *reqCntOut = (NSInteger)[(NSSet *)rq count];
                else if ([rq isKindOfClass:[NSArray class]])      *reqCntOut = (NSInteger)[(NSArray *)rq count];
            } @catch (__unused NSException *e) { }
        }
        id m = [source bulletinsToUUIDs];
        if (!m) return -1;
        NSInteger total = -1;
        if ([m isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = (NSDictionary *)m;
            total = (NSInteger)d.count;
            for (id k in d) {
                NSString *u = nil;
                if (NCMatchEntry(k, d[k], cid, &u)) {
                    if (found) *found = YES;
                    if (uuidOut && u.length) *uuidOut = u;
                    break;
                }
            }
        } else if ([m isKindOfClass:[NSSet class]]) {
            total = (NSInteger)[(NSSet *)m count];
        } else if ([m isKindOfClass:[NSArray class]]) {
            total = (NSInteger)[(NSArray *)m count];
        }
        return total;
    } @catch (__unused NSException *e) { return -1; }
}

// 老签名保留（只看条数 + 是否命中）
static NSInteger __attribute__((unused)) NBScanNC(id source, NSString *cid, BOOL *found) {
    return NBScanNC2(source, cid, found, NULL, NULL);
}

// ⛔ v0.0.64：原来的 `NBDumpNCMapsOnce` 已删除 ——
//    它会对映射的 key / value 调 `description`，真机 9/9 次进 NC 队列都死在这里。
//    映射的真实形态改用另一条更便宜也更安全的路去拿：
//    `_requestUUIDForBulletinPublisherMatchID:` —— 一次调用换一个 uuid，不遍历、不 description。

// bulletin ID → NC 侧 uuid：直接用同一套四种比法（不再只认 key 字符串一种）
static NSString *__attribute__((unused)) NCNUUIDForBulletin(id source, NSString *cid) {
    if (!source || !cid.length) return nil;
    NSString *u = nil;
    NBScanNC2(source, cid, NULL, &u, NULL);
    return u;
}

// uuid → 真 NCNotificationRequest（source 自己缓存着，是**真对象**，不是我造的）
static id NBNCRequestForUUID(id source, NSString *uuid) {
    if (!source || !uuid.length) return nil;
    @try {
        id m = [source uuidsToRequests];
        if ([m isKindOfClass:[NSDictionary class]]) return ((NSDictionary *)m)[uuid];
    } @catch (__unused NSException *e) { }
    return nil;
}

// ⛔⛔ v0.0.63：**工厂现造 request 这条路已经废掉**。
//   v0.0.62 真机：`uuid=(无) req=有(工厂新造)` 之后 `withdrawNotificationWithRequest:`
//   **再也没返回** ⇒ 把 NC 队列整条堵死（下一条记录连 `[NC队列]` 都没打印出来）。
//   ⇒ 造一个系统不认识的 request 去撤回 = 把别人的队列卡死。
//   ⇒ 现在只接受**真 request**：`uuidsToRequests` 里捞到的，或 post 时缓存下来的。
//   函数保留但恒返回 nil，防止别处再误用；真要再造，先证明它不会卡。
static id __attribute__((unused)) NBMakeNCRequest(NSString *bundle, NSString *cidOrUUID) {
    (void)bundle; (void)cidOrUUID;
    return nil;
}

// ================= v0.0.67：不猜了，改成「按 section 找真 request + 走正向清除」 =================

// 安全取值：字符串/数字就给内容，其余只给 `<类名>`。**绝不调 description。**
static NSString *NBSafeClip(id v, NSUInteger max) {
    NSString *s = NBStringish(v);
    if (s) {
        if (s.length > max) return [[s substringToIndex:max] stringByAppendingString:@"…"];
        return s;
    }
    return NBClip(v, max);   // 非字符串 ⇒ NBClip 只返回 <类名>
}

// 一次性：把两张映射的**条数 + 前 3 对形态**打出来。
// 🔴 v0.0.62/63 两次想 dump 映射都死了，元凶是 `description`（9/9 卡死）。
//    这次只碰 NSString/NSNumber/类名，代价是少几个字段，换来绝不卡死。
// 🔴 调用点必须是在 **NC 自己的队列**上（OBS hook）或主队列 —— 不在这两条队列上读
//    可能与写操作撞车。
static void NBMapCensus(id source) {
    if (!source) return;
    @try {
        id b2u = nil, u2r = nil;
        @try { b2u = [source bulletinsToUUIDs]; } @catch (__unused NSException *e) { }
        @try { u2r = [source uuidsToRequests];  } @catch (__unused NSException *e) { }
        NBDiagStep(@"  [map] bulletinsToUUIDs=%ld  uuidsToRequests=%ld（-1=读不到）\n",
                   (long)NBCollectionCount(b2u), (long)NBCollectionCount(u2r));
        if ([b2u isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = (NSDictionary *)b2u;
            NSUInteger i = 0;
            for (id k in d) {
                if (i >= 3) break;
                NBDiagStep(@"    b2u #%lu k=%@  v=%@\n", (unsigned long)i,
                           NBSafeClip(k, 60), NBSafeClip(d[k], 60));
                i++;
            }
        } else {
            NBDiagStep(@"    b2u 不是字典（%@）\n", NBClassName(b2u));
        }
        if ([u2r isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = (NSDictionary *)u2r;
            NSUInteger i = 0;
            for (id k in d) {
                if (i >= 3) break;
                id v = d[k];
                NBDiagStep(@"    u2r #%lu k=%@  v=<%@> section=%@ nid=%@\n", (unsigned long)i,
                           NBSafeClip(k, 60), NBClassName(v),
                           NBSafeClip(NBKVCStr(v, @"sectionIdentifier"), 40),
                           NBSafeClip(NBKVCStr(v, @"notificationIdentifier"), 60));
                i++;
            }
        } else {
            NBDiagStep(@"    u2r 不是字典（%@）\n", NBClassName(u2r));
        }
    } @catch (NSException *e) {
        NBDiagStep(@"  [map] 普查抛: %@\n", e.reason);
    }
}

// 集合（数组/集合/任何有 allObjects 的）→ NSArray；不是集合就返回 nil。只读，不遍历内部。
static NSArray *NBObjectsOf(id v) {
    if (!v) return nil;
    if ([v isKindOfClass:[NSArray class]]) return (NSArray *)v;
    if ([v isKindOfClass:[NSSet class]])   return [(NSSet *)v allObjects];
    if ([v respondsToSelector:@selector(allObjects)]) {
        @try {
            id a = [v allObjects];
            if ([a isKindOfClass:[NSArray class]]) return (NSArray *)a;
        } @catch (__unused NSException *e) { }
    }
    return nil;
}

// 把 value 侧可能是「request」或「一组 request」的情况摊平成 request 数组（深度 ≤2）。
static void NBCollectRequestsIn(id v, NSMutableArray *out, int depth) {
    if (!v || !out || depth > 2) return;
    NSString *sid = NBKVCStr(v, @"sectionIdentifier");
    if (sid.length) { [out addObject:v]; return; }      // 有 sectionIdentifier ⇒ 当它是 request
    NSDictionary *d = [v isKindOfClass:[NSDictionary class]] ? (NSDictionary *)v : nil;
    if (d) {
        for (id k in d) NBCollectRequestsIn(d[k], out, depth + 1);
        return;
    }
    NSArray *arr = NBObjectsOf(v);
    if (arr) {
        for (id e in arr) NBCollectRequestsIn(e, out, depth + 1);
    }
}

// 🔴🔴 v0.0.68：**精确**判定「这个 request 是不是我们这一条」。
//   判据来自上一版自己 dump 出来的真机方法表（nc_diag(9).txt 第 462 行起）：
//   `NCNotificationRequest - bulletin`（`@@:`）直接返回 **BBBulletin** ⇒
//   拿它的 bulletinID / recordID / publisherBulletinID 跟我们的比，**一比一个准**。
//   🔴 为什么非加这一层：v0.0.67 只按 section 匹配就动手，而实测命中的
//      nid=E18CDC81… 与我们的 bulletinID=D29F20AB… / recordID=F5C756A8… **三个全不一样**
//      ⇒ 同一个 App 在 NC 里可以有多条通知，只按 section 取第一条**很可能撤错了别人那条**。
// 🔴 v0.0.81：原来只有 BOOL，调用方**一律**打印「精确（request.bulletin 命中）」——
//    不管实际是按 `notificationIdentifier`、按 `uuid`，还是按 bulletin 的三个键命中的。
//    日志因此会骗人：`[寿]` 与 `⑦ 读回` 看上去"打架"，其中一种可能就是**命中的键根本不同**。
//    ⇒ 改成返回命中的那个键（带前缀），调用方照原样打出来。
static NSString *NBReqMatchKey(id req, NSArray *ids) {
    if (!req || !ids.count) return nil;
    for (NSString *k in @[@"notificationIdentifier", @"uuid"]) {
        NSString *v = NBKVCStr(req, k);
        if (v.length && [ids containsObject:v])
            return [NSString stringWithFormat:@"%@=%@", k, v];
    }
    id b = NBSafeValue(req, @"bulletin");       // 🔴 关键：request 自带 BB bulletin
    if (b) {
        for (NSString *k in @[@"bulletinID", @"recordID", @"publisherBulletinID"]) {
            NSString *v = NBKVCStr(b, k);
            if (v.length && [ids containsObject:v])
                return [NSString stringWithFormat:@"bulletin.%@=%@", k, v];
        }
    }
    return nil;
}

static BOOL NBReqIsOurs(id req, NSArray *ids) {
    return NBReqMatchKey(req, ids) != nil;
}

// 在 `uuidsToRequests` 里找本条 request。
//   **只返回精确命中**（NBReqIsOurs）。v0.0.75 起不再退回「section 命中的第一条」：
//   那个兜底会撤错条、还会把读回变成恒真的假判据（详见函数末尾）。
//   找不到就返回 nil，调用方一律不动手。
static id NBFindOurRequest(id source, NSString *bundle, NSArray *ids,
                           NSString **howOut, NSUInteger *scannedOut, int *secHitsOut) {
    if (howOut) *howOut = @"(无)";
    if (scannedOut) *scannedOut = 0;
    if (secHitsOut) *secHitsOut = 0;
    if (!source || !bundle.length) return nil;
    @try {
        id m = [source uuidsToRequests];
        if (![m isKindOfClass:[NSDictionary class]]) return nil;
        NSDictionary *d = (NSDictionary *)m;
        NSMutableArray *all = [NSMutableArray arrayWithCapacity:d.count];
        for (id k in d) NBCollectRequestsIn(d[k], all, 0);
        if (scannedOut) *scannedOut = all.count;
        // 🔴🔴🔴 v0.0.84：**命中之后不许立刻 return**。
        //   上一版就是在这里提前 return、顺手把 `*secHitsOut = secHits` 写成了
        //   「扫到匹配为止的部分计数」。而 ⑦u 量前/量后两处传的是空数组 `@[]`
        //   （`NBReqMatchKey` 第一行 `if (!ids.count) return nil;` ⇒ 永不匹配 ⇒ 扫完
        //   ⇒ 全量计数）。两处口径不同，相减就恒为正 ⇒ `NBReportSectionJump` 报
        //   「同段 3 → 8 ⇒ 该段刚被重载」，可真机 `[RL]` 里**那个段一次都没重载过**。
        //   `nc_diag(23).txt` 的 5 次「跳升」全部满足 `量前 == ⓪ 之后 BB live`
        //   （8/7/6/5/100 一一对上）⇒ 跳升是假的，是部分 vs 全量。
        //   ⇒ 现在：找到之后继续扫完，只数数不再判，`secHits` **永远是全量**。
        int secHits = 0;
        id loose = nil;
        id found = nil;
        NSString *foundHow = nil;
        for (id req in all) {
            NSString *sid = NBKVCStr(req, @"sectionIdentifier");
            if (!sid.length || ![sid isEqualToString:bundle]) continue;
            secHits++;
            if (found) continue;               // 已命中 ⇒ 这一段只为把 secHits 数完
            NSString *mk = NBReqMatchKey(req, ids);
            if (mk) { found = req; foundHow = mk; continue; }
            if (!loose) loose = req;
        }
        if (secHitsOut) *secHitsOut = secHits;   // 🔴 唯一出口，全量口径
        if (found) {
            if (howOut) *howOut = foundHow;
            return found;
        }
        // 🔴🔴🔴 v0.0.75：**删掉 loose 兜底**（原来精确匹配不到就退回「同段第一条」）。
        //   后果两个，都是致命的：
        //     ① **撤错条** —— 用户看到的是"有些通知没了，但不是我要删的那条"；
        //     ② **读回变成假判据** —— 只要这个 App 在 NC 里还有任何一条，读回永远是
        //        「还能找到本条=是」。v0.0.74 真机 19 次读回全「是」、0 次「否」，就是被这一条兜住的。
        //   ⇒ 现在：匹配不到就返回 nil，调用方**一律不动手**。
        if (loose) {
            if (howOut) *howOut = @"无精确命中（同段有它条 → 不动手）";
        }
        return nil;
    } @catch (__unused NSException *e) { return nil; }
}

// ---------- v0.0.85：按「同段 + 同内容」兜底找 request ----------
// 🔴 为什么需要这条：`nc_diag(24).txt` 34 次删除里 **28 次**都是
//   `[找] … 同段 N 条 ⇒ 都不是目标（目标已不在 NC）⇒ 不动手`。
//   而同一份日志里 `_bulletinsForIDs:@[cid]` **能按 ID 取到那个 bulletin**
//   （`bulletinID` 打印出来就是我们存的 cid）——说明对象还在，只是**不在 NC 现役列表里**：
//   系统把同一条通知重投/重排过一次，给了**新的 ID**，盒子里那行的 sys_id 就成了旧 ID。
//   ⇒ 精确匹配结构性失效。用户看到的正是「有些能删，有些不行」。
// 🔴 兜底判据故意收得很紧（宁可不动，也不许撤错条）：
//   ① 同 App（sectionIdentifier 相等）；
//   ② title **和** message 都完全相等（读 BBBulletin 上的已知安全键，不摸未知类）；
//   ③ **同段里只命中 1 条**才动手。命中 ≥2 条 = 分不清是哪一条 ⇒ 一条都不动。
//      （和 ⑦u「同段只剩 1 条才允许按段清」同一条纪律。）
// 🔴 内容全空的行不兜底：空 title + 空 message 对该 App 的所有通知都"相等"，
//   兜底会退化成"随机删一条"。
static BOOL NBStrSame(NSString *a, NSString *b) {
    if (!a.length && !b.length) return YES;
    if (!a.length || !b.length) return NO;
    return [a isEqualToString:b];
}

static id NBFindRequestByContent(id source, NSString *bundle,
                                 NSString *title, NSString *message, int *hitsOut) {
    if (hitsOut) *hitsOut = 0;
    if (!source || !bundle.length) return nil;
    if (!title.length && !message.length) return nil;
    @try {
        id m = [source uuidsToRequests];
        if (![m isKindOfClass:[NSDictionary class]]) return nil;
        NSDictionary *d = (NSDictionary *)m;
        NSMutableArray *all = [NSMutableArray arrayWithCapacity:d.count];
        for (id k in d) NBCollectRequestsIn(d[k], all, 0);
        int hits = 0;
        id hit = nil;
        for (id req in all) {
            NSString *sid = NBKVCStr(req, @"sectionIdentifier");
            if (!sid.length || ![sid isEqualToString:bundle]) continue;
            id b = NBSafeValue(req, @"bulletin");
            if (!b || b == req) continue;
            if (!NBStrSame(NBKVCStr(b, @"title"), title)) continue;
            if (!NBStrSame(NBKVCStr(b, @"message"), message)) continue;
            hits++;
            if (hits == 1) hit = req;
            else break;             // ≥2 条 ⇒ 立刻收手，连数都不必数完
        }
        if (hitsOut) *hitsOut = hits;
        return (hits == 1) ? hit : nil;
    } @catch (__unused NSException *e) { return nil; }
}

// ---------- v0.0.83：环形缓冲 + 同段跳升判据（替换掉坏死的 NBSectionTop）----------
// 🔴 为什么删掉 v0.0.82 的 `NBSectionTop`：它在真机上打出的 top3 是
//    `im.xym.marknow=1, com.bankcomm.Bankcomm=1, com.github.stormbreaker.prod=1`
//    —— 三条全是 1，而同一次 `⑦ 基线` 明确写着「同段 6 条 / 同段 93 条」。
//    自制的直方图与可信口径矛盾 ⇒ **按纪律：不可信的工具直接删**，不要留着当"组成指纹"。
//    🔴 这也是「探针自己会错」的第 6 次：新判据要先拿已知量验证，验不过就删。
static void NBRingPush(NSString *sec) {
    @synchronized(@"nbRlRing") {
        gRlTs[gRlNext] = [[NSDate date] timeIntervalSince1970];
        const char *cs = (sec.length ? [sec UTF8String] : "?");
        if (!cs) cs = "?";
        int i = 0;
        while (cs[i] && i < 47) { gRlSec[gRlNext][i] = cs[i]; i++; }
        gRlSec[gRlNext][i] = 0;
        gRlNext = (gRlNext + 1) % NB_RL_RING;
        gRlTotal++;
    }
}
// center = 参照时刻；win = 前后窗口秒数。只打窗口内的，最多 12 行。
// 🔴 v0.0.83：`why` 用 **NSString *** 而不是 `const char *`。
//    CI 第一轮就是这么炸的：调用点传 `@"段重载"`（NSString*）给 `const char *` 形参 ——
//    文本自检 14 道全绿也挡不住，**只有编译期能抓**（§7.6）。改成 NSString* 后
//    调用点怎么传中文都不会错，转换只在函数内做一次。
static void NBRingDump(double center, double win, NSString *why) {
    int shown = 0;
    const char *whyC = (why.length ? [why UTF8String] : "");
    @synchronized(@"nbRlRing") {
        for (int k = 0; k < NB_RL_RING; k++) {
            int idx = ((gRlNext - 1 - k) % NB_RL_RING + NB_RL_RING) % NB_RL_RING;
            if (gRlTs[idx] <= 0) continue;
            double d = gRlTs[idx] - center;
            if (d < -win || d > win) continue;
            NBDiagStep(@"  [RL] %+.0fs section=%.47s（%s）\n", d, gRlSec[idx], whyC ? whyC : "");
            if (++shown >= 12) break;
        }
    }
    if (!shown) NBDiagStep(@"  [RL] ±%.0fs 内没有段重载记录（本次会话共记 %d 次）\n", win, gRlTotal);
}
// 🔴 同段条数「刀后比基线多」= 这一段被重载了。
//    依据：`nc_diag(22).txt` 里 ⑦t 之前 93 条、读回 99 条（= BB 该段 live），总数只掉 1；
//    v0.0.81 里 68 → 99 同理。**这是「删了又出现」的物理路径**：
//    重载按 BB 现况把整段重新装回映射，所以只有先清 BB（⓪）才断得掉。
static void NBReportSectionJump(const char *tag, int base, int now) {
    if (base < 0 || now <= base) return;
    NBDiagStep(@"  🔴 [%s] 同段 %d → %d（+%d）⇒ 该段刚被重载（映射按 BB 现况重装全部条目）\n",
               tag, base, now, now - base);
}

// ---------- v0.0.81：[RE] 「谁把它加回来」的时间戳查询 ----------
// 返回 -1 = 没命中；否则返回「这条删除距今多少秒」。
// 🔴 只读台账文件（≤64 行），不改任何状态，可以在 NC 队列上安全调用。
static double NBDeletedAgeFor(NSString *a, NSString *b, NSString *c) {
    if (!a.length && !b.length && !c.length) return -1;
    @try {
        NSString *old = [NSString stringWithContentsOfFile:kNBDeletedLog
                                                  encoding:NSUTF8StringEncoding error:NULL];
        if (!old.length) return -1;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        for (NSString *ln in [old componentsSeparatedByString:@"\n"]) {
            if (!ln.length) continue;
            NSArray *p = [ln componentsSeparatedByString:@"|"];
            if (p.count < 3) continue;
            BOOL hit = NO;
            for (NSUInteger i = 2; i < p.count && i < 5; i++) {
                NSString *v = p[i];
                if (!v.length) continue;
                if ((a.length && [v isEqualToString:a])
                    || (b.length && [v isEqualToString:b])
                    || (c.length && [v isEqualToString:c])) { hit = YES; break; }
            }
            if (hit) return now - [p[0] doubleValue];
        }
    } @catch (__unused NSException *e) { }
    return -1;
}

// ---------- v0.0.78：⑦r 的闸门量 + [寿] 旧删台账 ----------
// 数「同段 + timestamp 落在 ts±win 秒内」的 request 条数。
// 🔴 只返回**数**，不返回对象 —— 它唯一的用途是给 ⑦r 当闸门。
//    返回 -1 = 读不到（调用方必须当成"不许动刀"处理，不是"0 条"）。
static int NBCountInWindow(id source, NSString *bundle, NSDate *ts, NSTimeInterval win) {
    if (!source || !bundle.length || !ts) return -1;
    @try {
        id m = [source uuidsToRequests];
        if (![m isKindOfClass:[NSDictionary class]]) return -1;
        NSDictionary *d = (NSDictionary *)m;
        NSMutableArray *all = [NSMutableArray arrayWithCapacity:d.count];
        for (id k in d) NBCollectRequestsIn(d[k], all, 0);
        int n = 0;
        for (id req in all) {
            NSString *sid = NBKVCStr(req, @"sectionIdentifier");
            if (!sid.length || ![sid isEqualToString:bundle]) continue;
            id v = NBSafeValue(req, @"timestamp");
            if (![v isKindOfClass:[NSDate class]]) continue;
            NSTimeInterval dt = [(NSDate *)v timeIntervalSinceDate:ts];
            if (dt >= -win && dt <= win) n++;
        }
        return n;
    } @catch (__unused NSException *e) { return -1; }
}

// 把「刚刚被 ⓪ 清掉的那条」记进台账。
// 行格式：时间戳|bundle|bulletinID|recordID|publisherBulletinID
// 🔴 v0.0.79：从 1 个键扩到 3 个键。原因是 `nc_diag(19).txt` 暴露的：
//    读回时如果 `req.bulletin` 变成 nil（BB 对象被 ⓪ 撤掉之后完全可能），
//    那 `req.bulletin.bulletinID` 就**读不到** ⇒ 判据会报"已消失"，
//    而 request 其实还躺在 NC 里 ⇒ **假绿**。
//    ⇒ 必须有一条**不依赖 req.bulletin** 的键：`request.notificationIdentifier`。
//      本机实测它正好等于 BB 的 recordID（`nid=ae3046702a374c00b6736bc70096b84a`），
//      所以记下 recordID 就能在 NC 侧独立验证。
static void NBDeletedRemember(NSString *cid, NSString *recID, NSString *pubID, NSString *bundle) {
    if (!cid.length || !bundle.length) return;
    @try {
        NSString *old = [NSString stringWithContentsOfFile:kNBDeletedLog
                                                  encoding:NSUTF8StringEncoding error:NULL];
        NSMutableArray *keep = [NSMutableArray array];
        if (old.length) {
            for (NSString *ln in [old componentsSeparatedByString:@"\n"]) {
                if (!ln.length) continue;
                NSArray *p = [ln componentsSeparatedByString:@"|"];
                if (p.count >= 3 && [p[2] isEqualToString:cid]) continue;   // 同一 cid 只留最新那次
                [keep addObject:ln];
            }
        }
        [keep addObject:[NSString stringWithFormat:@"%.0f|%@|%@|%@|%@",
                         [[NSDate date] timeIntervalSince1970], bundle, cid,
                         recID.length ? recID : @"", pubID.length ? pubID : @""]];
        while (keep.count > NB_DEL_KEEP) [keep removeObjectAtIndex:0];
        [[keep componentsJoinedByString:@"\n"] writeToFile:kNBDeletedLog atomically:YES
                                                  encoding:NSUTF8StringEncoding error:NULL];
    } @catch (__unused NSException *e) { }
}

// ---------- v0.0.79：[寿] 台账 + [段] 段级计数 + [重] 重复诊断，一次遍历全出 ----------
// 🔴🔴 修掉 v0.0.78 的一个**语义反转**（真机当场撞到）：
//    上一版默认 `alive=@YES`，命中 NC 时置 `@NO`，而输出时 `YES ⇒ 仍在`、`NO ⇒ 已消失`
//    ⇒ **命中 = 在 NC 里找到 = 它还活着**，却被写成了「已消失」。
//    `nc_diag(19).txt` 里 5 次尝试全是「已消失 0 / 仍在 5」，真相**正好相反**：
//    那 5 条全都被系统撤掉了（和 `⑦ 基线：本条还在=否` 完全一致，两个判据本来是同一个答案）。
//    ⇒ 现在字段直接叫 `gone`：默认 `NO`（没找到过 ⇒ 认为还在），命中才置 `YES`。
static void NBCheckDeletedAlive(void) {
    @try {
        NSString *bundleNow = gWantBundle;

        // ---- 1. 台账 ----
        NSString *old = [NSString stringWithContentsOfFile:kNBDeletedLog
                                                  encoding:NSUTF8StringEncoding error:NULL];
        NSMutableArray *recs = [NSMutableArray array];
        NSMutableSet  *allIDs = [NSMutableSet set];
        if (old.length) {
            for (NSString *ln in [old componentsSeparatedByString:@"\n"]) {
                if (!ln.length) continue;
                NSArray *p = [ln componentsSeparatedByString:@"|"];
                if (p.count < 3 || ![(NSString *)p[2] length]) continue;
                NSMutableSet *keys = [NSMutableSet setWithObject:p[2]];
                if (p.count >= 4 && [(NSString *)p[3] length]) [keys addObject:p[3]];
                if (p.count >= 5 && [(NSString *)p[4] length]) [keys addObject:p[4]];
                [recs addObject:[@{@"ts": p[0], @"bundle": (p.count >= 2 ? p[1] : @""),
                                   @"cid": p[2], @"keys": keys, @"hitNC": @NO} mutableCopy]];
                [allIDs unionSet:keys];
            }
        }

        // ---- 2. NC 快照 ----
        id m = [gNCSource uuidsToRequests];
        if (![m isKindOfClass:[NSDictionary class]]) {
            NBDiagStep(@"  [寿] 读不到 uuidsToRequests ⇒ 本次不判\n");
            return;
        }
        NSDictionary *d = (NSDictionary *)m;
        NSMutableArray *all = [NSMutableArray arrayWithCapacity:d.count];
        for (id k in d) NBCollectRequestsIn([d objectForKey:k], all, 0);

        // ---- 3. 一次遍历：存活比对 + 段级计数 + 重复诊断 ----
        NSMutableDictionary *secCount = [NSMutableDictionary dictionary];
        NSMutableDictionary *tsGroups = [NSMutableDictionary dictionary];   // 仅 bundleNow 段
        int noBulletin = 0, hitById = 0, hitByBulletin = 0;
        for (id req in all) {
            NSString *sid = NBKVCStr(req, @"sectionIdentifier");
            if (sid.length) secCount[sid] = @([secCount[sid] intValue] + 1);

            // 3a) 台账存活：先按**不依赖 bulletin** 的键（nid / uuid）判，再按 bulletin 的键判
            NSMutableSet *hit = [NSMutableSet set];
            for (NSString *key in @[@"notificationIdentifier", @"uuid"]) {
                NSString *v = NBKVCStr(req, key);
                if (v.length && [allIDs containsObject:v]) { [hit addObject:v]; hitById++; }
            }
            id b = NBSafeValue(req, @"bulletin");
            if (b) {
                for (NSString *key in @[@"bulletinID", @"recordID", @"publisherBulletinID"]) {
                    NSString *v = NBKVCStr(b, key);
                    if (v.length && [allIDs containsObject:v]) { [hit addObject:v]; hitByBulletin++; }
                }
            } else if (sid.length && [sid isEqualToString:bundleNow]) {
                noBulletin++;
            }
            if (hit.count) {
                for (NSMutableDictionary *rec in recs) {
                    if ([rec[@"keys"] intersectsSet:hit]) rec[@"hitNC"] = @YES;
                }
            }

            // 3b) 重复诊断：只在**本段**做，按 timestamp 精确到毫秒分组
            if (sid.length && bundleNow.length && [sid isEqualToString:bundleNow]) {
                NSDate *ts = NBSafeDate(req, @"timestamp");
                if (ts) {
                    NSString *tk = [NSString stringWithFormat:@"%.3f", [ts timeIntervalSince1970]];
                    NSMutableArray *g = tsGroups[tk];
                    if (!g) { g = [NSMutableArray array]; tsGroups[tk] = g; }
                    NSString *nid = NBKVCStr(req, @"notificationIdentifier");
                    [g addObject:(nid.length ? nid : @"?")];
                }
            }
        }

        // ---- 4. [寿] 汇总 ----
        // 🔴🔴🔴 v0.0.81：**同一个语义反转，我犯了第二次。**
        //   v0.0.79 只是把字段名从 `alive` 改成 `gone`、默认值从 YES 改成 NO，
        //   **却把输出映射原样留着**：`hit`（在 NC 里找到了）⇒ 置 YES ⇒ 输出「已消」。
        //   找到 = 它还在 ⇒ 应该输出「仍在」。改名没改映射，等于没修。
        //   现场后果（`nc_diag(21).txt`）：`⑦s/⑦t/⑦r 读回` 全说「本条还在=是」，
        //   而 `[寿]` 同时说「已消 D5C64897（0s 前）」—— 两个判据"打架"，
        //   真相是它们**本来就同义**，是我把其中一个的标签写反了。
        //   ⇒ 这一版字段直接叫 `hitNC`（命中 NC = 还在），输出 `hitNC ? 仍在 : 已消`。
        //   🔴 教训：改语义先改**输出映射**，别只改变量名 —— 变量名不会让日志变对。
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        int liveN = 0, goneN = 0;
        NSTimeInterval lOld = 0, lNew = 0, gOld = 0, gNew = 0;
        for (NSDictionary *rec in recs) {
            NSTimeInterval age = now - [rec[@"ts"] doubleValue];
            if ([rec[@"hitNC"] boolValue]) {
                liveN++;
                if (!lOld || age > lOld) lOld = age;
                if (!lNew || age < lNew) lNew = age;
            } else {
                goneN++;
                if (!gOld || age > gOld) gOld = age;
                if (!gNew || age < gNew) gNew = age;
            }
        }
        NBDiagStep(@"  [寿] 台账 %lu 条 × 扫 NC %lu 条 ⇒ NC 里仍在 %d / 已消失 %d"
                   @"（按 nid/uuid 命中 %d 次、按 bulletin 命中 %d 次、本段 bulletin 读不到 %d 条）\n",
                   (unsigned long)recs.count, (unsigned long)all.count, liveN, goneN,
                   hitById, hitByBulletin, noBulletin);
        if (liveN) NBDiagStep(@"  [寿]   仍在  ：最老 %.0fs 最新 %.0fs%@\n", lOld, lNew,
                              (lOld > 600 ? @"  ← 最老已 >10 分钟仍在 ⇒ **不会自己消失**" : @""));
        if (goneN) NBDiagStep(@"  [寿]   已消失：最老 %.0fs 最新 %.0fs\n", gOld, gNew);
        int shown = 0;
        for (NSDictionary *rec in [recs reverseObjectEnumerator]) {
            if (shown >= 3) break;
            NBDiagStep(@"  [寿]   %@ %@ %@（%.0fs 前）\n",
                       [rec[@"hitNC"] boolValue] ? @"仍在" : @"已消",
                       NBSafeClip(rec[@"bundle"], 32), NBSafeClip(rec[@"cid"], 28),
                       now - [rec[@"ts"] doubleValue]);
            shown++;
        }

        // ---- 5. [段] + [重]：回答「同一时间怎么有一模一样的信息」 ----
        // 🔴 只在**每个进程的头一次**打明细（日志窗口 ≈ 最后 50 条，全局滚动，必须省行数）。
        if (!gCensusDumped) {
            gCensusDumped = YES;
            NSArray *ks = [secCount allKeys];
            NSArray *sorted = [ks sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
                return [secCount[b] compare:secCount[a]];      // 条数多的排前面
            }];
            NSUInteger n = sorted.count < 5 ? sorted.count : 5;
            NSMutableString *sb = [NSMutableString string];
            for (NSUInteger i = 0; i < n; i++) {
                NSString *s = sorted[i];
                [sb appendFormat:@"%@=%d%@", NBSafeClip(s, 30), [secCount[s] intValue],
                                  (i + 1 < n ? @" " : @"")];
            }
            NBDiagStep(@"  [段] NC 共 %lu 条 / %lu 个段；最多的 5 个：%@\n",
                       (unsigned long)all.count, (unsigned long)secCount.count, sb);

            // 同段 + 同一时刻（毫秒级相同）= 同一条通知被放了多份
            NSMutableArray *dupTs = [NSMutableArray array];
            for (NSString *tk in tsGroups) {
                NSArray *g = tsGroups[tk];
                if (g.count >= 2) [dupTs addObject:@[tk, g]];
            }
            [dupTs sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
                return [(NSArray *)b[1] count] > [(NSArray *)a[1] count] ? NSOrderedDescending
                                                                        : NSOrderedAscending;
            }];
            NBDiagStep(@"  [重] 段 %@ 在 NC 里 %d 条 ⇒ 同一时刻出现 ≥2 次的组 %lu 个\n",
                       NBSafeClip(bundleNow, 32),
                       [secCount[bundleNow ?: @""] intValue],
                       (unsigned long)dupTs.count);
            // ---- v0.0.84：[重] 盒子自己的重复（只读聚合，不改数据）----
            // 🔴 用户报「消息盒子里部份信息有重复」。可能的来源两类，必须分开量：
            //    ① 同一条系统通知被记了两遍（`sys_id` 相同）⇒ 真 bug，本版靠写入侧去重治；
            //    ② 真的是多条内容相同的通知（`sys_id` 不同）⇒ 如实记录，不算 bug。
            //    ⇒ 一行同时给出两个数，下次日志就能判断到底是哪一种。
            NSDictionary *ds = [NotifyStore dupStats];
            if (ds) {
                NBDiagStep(@"  [重] 盒子 %@ 行 ⇒ sysId 重复 %@ 组(多 %@ 行) / "
                           @"无 sysId %@ 行 ｜ 同内容重复 %@ 组(多 %@ 行)\n",
                           ds[@"rows"] ?: @"?", ds[@"sysGroups"] ?: @"?",
                           ds[@"sysExtra"] ?: @"?", ds[@"noSys"] ?: @"?",
                           ds[@"txtGroups"] ?: @"?", ds[@"txtExtra"] ?: @"?");
                // 🔴 v0.0.85：**判决性的一行**。「无 sysId N 行」只说了有多少，
                //    没说它们有多新 —— 而"新记录也在丢 ID"和"全是老记录"是两件完全不同的事，
                //    修法也完全不同（前者改写入侧，后者只能等新记录替换）。
                //    `24h 内` 就是那把尺子：> 0 ⇒ 写入侧在丢 ID（配合 `[无ID#n]` 行看是哪个入口）。
                NBDiagStep(@"  [重] 无 sysId 的时间分布：24h 内 %@ 行 / 最新 %@ 秒前 / 最老 %@ 秒前"
                           @"（-1 = 没有这类行）\n",
                           ds[@"noSys24h"] ?: @"?", ds[@"noSysNewestAgo"] ?: @"?",
                           ds[@"noSysOldestAgo"] ?: @"?");
            }
            int shownG = 0;
            for (NSArray *pair in dupTs) {
                if (shownG >= 2) break;
                NSArray *g = pair[1];
                NSMutableString *ids = [NSMutableString string];
                NSUInteger gn = g.count < 3 ? g.count : 3;
                for (NSUInteger i = 0; i < gn; i++) {
                    [ids appendFormat:@"%@%@", NBSafeClip(g[i], 40), (i + 1 < gn ? @" / " : @"")];
                }
                NBDiagStep(@"  [重]   ts=%@ 共 %lu 份：%@\n", pair[0], (unsigned long)g.count, ids);
                shownG++;
            }
        }
    } @catch (NSException *e) {
        NBDiagStep(@"  [寿] 抛: %@\n", e.reason);
    }
}

// 把一批 request 的 section/nid 打出来（最多 max 条）。只读 KVC，不碰 description。
static void NBLogRequests(NSString *tag, id requests, int max) {
    NSArray *arr = nil;
    if ([requests isKindOfClass:[NSArray class]])     arr = requests;
    else if ([requests isKindOfClass:[NSSet class]])  arr = [(NSSet *)requests allObjects];
    else if ([requests respondsToSelector:@selector(allObjects)]) arr = [requests allObjects];
    if (!arr) {
        NBDiagStep(@"  [%@] 不是集合（%@）\n", tag, NBClassName(requests));
        return;
    }
    NSUInteger n = arr.count < (NSUInteger)max ? arr.count : (NSUInteger)max;
    for (NSUInteger i = 0; i < n; i++) {
        id r = arr[i];
        NBDiagStep(@"  [%@] #%lu <%@> section=%@ nid=%@\n", tag, (unsigned long)i,
                   NBClassName(r),
                   NBSafeClip(NBKVCStr(r, @"sectionIdentifier"), 40),
                   NBSafeClip(NBKVCStr(r, @"notificationIdentifier"), 56));
    }
}

// 一次性：按关键字把这几个类的方法表追加到 diag 文件。
// 🔴 为什么现在还要它：`NCNotificationRequest` 的**构造器**我还没见过真名，
//    而「造不出 request 就只能等系统送」是这一路的死结。看清楚就能一次写对。
// 🔴 只读类结构、**不调用任何未知方法**（零风险）。
static void NBDiagAppendAPIOnce(void) {
    if (gAPIDumped) return;
    gAPIDumped = YES;
    @try {
        NSMutableString *buf = [NSMutableString stringWithCapacity:(1 << 14)];
        [buf appendFormat:@"\n# ---- v%@ 方法表（关键字筛：bulletin/request/clear/remov/withdraw/dismiss/destination）----\n", NB_VER_STR];
        NSArray *kw = @[@"ulletin", @"equest", @"lear", @"emov", @"ithdraw", @"ismiss", @"estination"];
        NSArray *classes = @[@"NCNotificationRequest", @"NCNotificationDispatcher",
                             @"NCBulletinNotificationSource", @"CSNotificationDispatcher", @"BBServer"];
        for (NSString *cn in classes) {
            Class c = NSClassFromString(cn);
            if (!c) { [buf appendFormat:@"### %@ 不存在\n", cn]; continue; }
            for (int pass = 0; pass < 2; pass++) {
                Class t = (pass == 0) ? c : object_getClass((id)c);
                unsigned cnt = 0;
                Method *ms = class_copyMethodList(t, &cnt);
                [buf appendFormat:@"### %@ %@方法 共 %u 个（下面只列关键字命中的）\n",
                 cn, (pass == 0) ? @"-" : @"+", cnt];
                if (!ms) continue;
                NSMutableArray *lines = [NSMutableArray array];
                for (unsigned i = 0; i < cnt; i++) {
                    NSString *sel = NSStringFromSelector(method_getName(ms[i]));
                    BOOL hit = NO;
                    for (NSString *k in kw) {
                        if ([sel rangeOfString:k].location != NSNotFound) { hit = YES; break; }
                    }
                    if (!hit) continue;
                    [lines addObject:[NSString stringWithFormat:@"  %@\t%@", sel, NBDiagEnc(ms[i])]];
                }
                free(ms);
                for (NSString *ln in [lines sortedArrayUsingSelector:@selector(compare:)]) {
                    [buf appendString:ln];
                    [buf appendString:@"\n"];
                }
                if (!lines.count) [buf appendString:@"  (无匹配)\n"];
            }
        }
        NBDiagAppend(buf);

        // ---------- v0.0.73：CSNotificationDispatcher **全量**方法表 ----------
        // 🔴 为什么单独给它一份全量：v0.0.72 的关键发现（`destination:clearNotificationRequests:`）
        //    是在**关键字筛**的结果里看到的 —— 而筛子是按我上一版猜的关键字织的，
        //    换句话说"漏掉哪条"取决于我猜得对不对。这个类只有 52 个方法，
        //    全量打出来的成本可以接受，换来的是**下一轮不再靠关键字碰运气**。
        Class csd2 = NSClassFromString(@"CSNotificationDispatcher");
        if (csd2) {
            NSMutableString *buf2 = [NSMutableString stringWithCapacity:(1 << 11)];
            [buf2 appendFormat:@"\n### CSNotificationDispatcher 全量方法表（v%@，关键词筛之外也全给）\n", NB_VER_STR];
            for (int pass = 0; pass < 2; pass++) {
                Class t = (pass == 0) ? csd2 : object_getClass((id)csd2);
                unsigned c2 = 0;
                Method *m2 = class_copyMethodList(t, &c2);
                [buf2 appendFormat:@"### CSNotificationDispatcher %@ 全量 %u 个\n",
                 (pass == 0) ? @"-" : @"+", c2];
                if (!m2) continue;
                NSMutableArray *ln2 = [NSMutableArray array];
                for (unsigned i = 0; i < c2; i++) {
                    [ln2 addObject:[NSString stringWithFormat:@"  %@\t%@",
                                    NSStringFromSelector(method_getName(m2[i])), NBDiagEnc(m2[i])]];
                }
                free(m2);
                for (NSString *s in [ln2 sortedArrayUsingSelector:@selector(compare:)]) {
                    [buf2 appendString:s];
                    [buf2 appendString:@"\n"];
                }
            }
            NBDiagAppend(buf2);
            NBDiagStep(@"  [api] CS 全量表已追加 %lu 行\n",
                       (unsigned long)[[buf2 componentsSeparatedByString:@"\n"] count]);
        }
        NBDiagStep(@"  [api] 方法表已追加 %lu 行\n",
                   (unsigned long)[[buf componentsSeparatedByString:@"\n"] count]);
    } @catch (NSException *e) {
        NBDiagStep(@"  [api] 方法表追加抛: %@\n", e.reason);
    }
}

// ================= v0.0.68：先拿到**真 destination**，再动手 =================
// 🔴🔴 v0.0.67 的致命缺口，日志一句话说明了：
//      `[清] 跳过 destination（实例=(nil) 方法=有）`
//    因为 destination 实例全靠 OBS hook 抓，而那一轮 **OBS 触发 0 次**
//    （`观测计数: 目的地请求清除=0 / dispatcher 撤回=0 / source 请求清除=0`）
//    ⇒ 唯一有能力驱动界面的那一步**从来没发出去过**。
// 🔴 正规入口就在方法表里：`NCNotificationDispatcher - destinationsRegistry`（`@@:`）。
//    目标类 = `CSNotificationDispatcher`（CoverSheet = 通知中心界面本身），
//    它自己有 `- withdrawNotificationRequest:` —— 那一刀才真正对着界面。
// 🔴 全程只碰 `isKindOfClass` / `count` / 类名，**绝不对未知对象调 description**（v0.0.63 教训）。
static BOOL NBIsCSDest(id o) {
    if (!o) return NO;
    Class c = NSClassFromString(@"CSNotificationDispatcher");
    return c ? [o isKindOfClass:c] : NO;
}

static id NBFindCSDestIn(id v, int depth) {
    if (!v || depth > 3) return nil;
    if (NBIsCSDest(v)) return v;
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)v;
        for (id k in d) {
            id r = NBFindCSDestIn(d[k], depth + 1);
            if (r) return r;
        }
        return nil;
    }
    NSArray *arr = NBObjectsOf(v);
    if (arr) {
        for (id e in arr) {
            id r = NBFindCSDestIn(e, depth + 1);
            if (r) return r;
        }
        return nil;
    }
    // registry 可能把 destination 藏在 registeredDestinations 里（名字不确定，两种都试）
    if ([v respondsToSelector:@selector(registeredDestinations)]) {
        id inner = nil;
        @try { inner = [v registeredDestinations]; } @catch (__unused NSException *e) { }
        if (inner) {
            id r = NBFindCSDestIn(inner, depth + 1);
            if (r) return r;
        }
    }
    return nil;
}

// 同步补抓 destination。**不依赖 OBS hook 有没有触发** —— 这正是上一版栽的地方。
// 两条来源依次试：① dispatcher 的 destinationsRegistry ② request 自己的 requestDestinations
// （后者如果直接给对象，那就最省事：request 自己知道它被投给了谁）。
static void NBProbeDestinations(id req) {
    if (gCSDestination) {
        NBDiagStep(@"  [dest] ✅ 已有实例 <%@>（来源：%@）\n",
                   NBClassName(gCSDestination),
                   gCSDestFromHook ? @"注册期 hook" : @"OBS");
        return;
    }
    if (!gNCDispatcher) return;
    @try {
        id reg = nil;
        @try { reg = [gNCDispatcher destinationsRegistry]; } @catch (__unused NSException *e) { }
        NBDiagStep(@"  [dest] registry=<%@> 条数=%ld\n",
                   NBClassName(reg), (long)NBCollectionCount(reg));
        NSArray *arr = NBObjectsOf(reg);
        if (arr) {
            NSUInteger n = arr.count < 8 ? arr.count : 8;
            for (NSUInteger i = 0; i < n; i++) {
                NBDiagStep(@"    reg #%lu <%@>\n", (unsigned long)i, NBClassName(arr[i]));
            }
        }
        id found = NBFindCSDestIn(reg, 0);
        if (found) {
            gCSDestination = found;
            NBDiagStep(@"  [dest] ✅ 从 registry 拿到 <%@> 实例\n", NBClassName(found));
        } else {
            NBDiagStep(@"  [dest] registry 里没找到 CSNotificationDispatcher，改试 request.requestDestinations\n");
        }
    } @catch (NSException *e) {
        NBDiagStep(@"  [dest] registry 探测抛: %@\n", e.reason);
    }
    if (gCSDestination || !req) return;
    @try {
        id rd = nil;
        @try { rd = [req requestDestinations]; } @catch (__unused NSException *e) { }
        NBDiagStep(@"  [dest] req.requestDestinations=<%@> 条数=%ld\n",
                   NBClassName(rd), (long)NBCollectionCount(rd));
        NSArray *rda = NBObjectsOf(rd);
        if (rda) {
            NSUInteger n = rda.count < 4 ? rda.count : 4;
            for (NSUInteger i = 0; i < n; i++) {
                NBDiagStep(@"    rd #%lu <%@> 值=%@\n", (unsigned long)i, NBClassName(rda[i]),
                           NBSafeClip(rda[i], 50));
            }
        } else {
            NBDiagStep(@"    rd 值=%@\n", NBSafeClip(rd, 60));
        }
        id found2 = NBFindCSDestIn(rd, 0);
        if (found2) {
            gCSDestination = found2;
            NBDiagStep(@"  [dest] ✅ 从 requestDestinations 拿到 <%@> 实例\n", NBClassName(found2));
        } else {
            NBDiagStep(@"  [dest] ⛔ 两条来源都没拿到 CSNotificationDispatcher（只能退回 dispatcher 层那一刀）\n");
        }
    } @catch (NSException *e) {
        NBDiagStep(@"  [dest] requestDestinations 探测抛: %@\n", e.reason);
    }
}

// ---------- v0.0.77：**[清] 整段删除**，这个函数只剩「交回控制权」 ----------
// 🔴🔴 删掉的东西（两版实测，不是猜）：
//    [清]① `CSNotificationDispatcher - withdrawNotificationRequest:`   v0.0.75 4 次全空转
//    [清]② `destination:<CS> requestsClearingNotificationRequests:`    同上
//    [清]③ 兜底 `withdrawNotificationWithRequest:`                      v0.0.74 4 次全空转
//    [验]  读回（它的判据域是 source，而这几个刀动的是 destination，本来就对不上）
// 🔴🔴 更要紧的是**它们都在主队列上调用未知的 NC 方法**。v0.0.76 真机两次「卡屏后注销」
//    最可疑的就是这一类：主队列上同步调一个内部可能 `dispatch_sync(main)` 的方法 ⇒ 自死锁。
//    ⇒ 本版起，**主队列上不再有任何未知 NC 调用**（⑦c/⑦d 也一起删）。
//    🔴 v0.0.78：⑧ 也删了（实测块进方法就再不返回，把后面 29 次尝试全废掉）。
//    界面侧现在只剩 ⑦r 一把，见 ⑦ 段。
static void NBForwardClearAsync(id req, NSString *how, void (^done)(void)) {
    (void)how;                       // v0.0.77：只保留调用点的签名，参数不再用
    if (req) {
        // destination 实例只做**只读探测**（registerDestination: hook 之外的第二来源），不调任何清除方法
        @try { NBProbeDestinations(req); } @catch (__unused NSException *e) { }
    }
    // 🔴🔴 v0.0.77 最重的一个 bug 就修在这里：
    //    v0.0.76 的抑制分支是「写一行日志 + return」，**没有把 done 交回去** ⇒
    //    调用方那句「清完再清账本」永远等不到 ⇒ 用户删一条，连 ⓪ 都不跑 ⇒
    //    `nc_diag(17).txt` 里 20 次尝试全是 `[清] 跳过` 然后**什么都没有**，
    //    表现就是用户那句「没效果了」。⇒ 现在抑制只影响界面侧，账本一律照清。
    if (gNCSuppressed) {
        NBDiagStep(@"  [清] 界面侧被 .nc_off 压制（删 %@ 可恢复）⇒ 只清 BB 账本，界面等系统自己跟\n",
                   kNBGuardOff);
    }
    if (done) { @try { done(); } @catch (__unused NSException *e) { } }
}

// 「找 request + 动手」的统一入口：谁先跑到（主队列 / OBS hook）就由谁做，只做一次。
// 🔴 全进程最多试 4 次：OBS 可能反复触发，而每次都要遍历近千条映射 —— 不能让它变成常态开销。
static void NBFindAndForwardClear(NSString *why, void (^done)(void)) {
    // 🔴 v0.0.69：`tries` 从函数内 static 改成全局 `gFindTries` —— 函数内 static 没法在
    //    每次删除时归零 ⇒ 全进程只有前 4 次能找，之后永久静默（见全局变量处的说明）。
    // 🔴 所有早退分支都必须把 done 交回去，否则调用方的「清完再清账本」永远等不到
    //    ⇒ 账本一次都不清 ⇒ 下一次删除会看到"通知还在"。这就是 v0.0.65 的 gNCBusy 那类坑。
    if (gFoundNCReq) { if (done) done(); return; }
    if (gFindTries >= 4) { if (done) done(); return; }
    if (!gWantBundle.length || !gNCSource) { if (done) done(); return; }
    gFindTries++;
    NSUInteger scanned = 0;
    int secHits = 0;
    NSString *how = nil;
    id r = NBFindOurRequest(gNCSource, gWantBundle, gWantIDs, &how, &scanned, &secHits);
    if (r) {
        gFoundNCReq = r;
        NBDiagStep(@"  [找] %@：扫 %lu 条 request，同段 %d 条 ⇒ 选中 匹配=%@ section=%@ nid=%@\n",
                   why, (unsigned long)scanned, secHits, how ?: @"?",
                   NBSafeClip(NBKVCStr(r, @"sectionIdentifier"), 40),
                   NBSafeClip(NBKVCStr(r, @"notificationIdentifier"), 56));
        // 把它自带的 bulletin 也打出来 —— 这是「到底是不是我们那条」的唯一硬证据
        @try {
            id b = NBSafeValue(r, @"bulletin");
            NBDiagStep(@"  [找] req.bulletin=<%@> bulletinID=%@ recordID=%@\n",
                       NBClassName(b),
                       NBSafeClip(NBKVCStr(b, @"bulletinID"), 40),
                       NBSafeClip(NBKVCStr(b, @"recordID"), 40));
        } @catch (__unused NSException *e) { }
        NBForwardClearAsync(r, how, done);
    } else {
        // 🔴 v0.0.75：区分两种"没找到" —— 同段 0 条（NC 里本来没有）
        //    与 同段 N 条但不是目标（**目标已经不在**）。后者以前会被 loose 兜底吃掉。
        NBDiagStep(@"  [找] %@：扫 %lu 条 request，section=%@ 同段 %d 条 ⇒ %@\n",
                   why, (unsigned long)scanned, gWantBundle, secHits,
                   secHits > 0 ? @"都不是目标（目标已不在 NC）⇒ 不动手"
                               : @"该段在 NC 里一条都没有");
        // ---------- v0.0.85：精确 ID 落空 ⇒ 按内容兜底（默认开，可在设置页关掉）----------
        // 🔴 只在这里兜底，不动 NBFindOurRequest 本身：那个函数还被 5 处「复量」调用，
        //    一旦它也按内容认亲，「本条还在=否」这个验收判据就变成"同内容还在也算还在"
        //    ⇒ 又是一条假绿判据（这坑本项目踩过两次）。
        if (secHits > 0 && (gWantTitle.length || gWantMsg.length)) {
            NSDictionary *p = NBLoadSettings();
            NSNumber *cf = p[NB_KEY_CONTENT_FALLBACK];
            BOOL on = cf ? [cf boolValue] : YES;    // 缺省开
            if (on) {
                int chits = 0;
                id cr = NBFindRequestByContent(gNCSource, gWantBundle, gWantTitle, gWantMsg, &chits);
                NBDiagStep(@"  [找·内容] title=%@ msg=%@ ⇒ 同内容命中 %d 条 ⇒ %@\n",
                           NBSafeClip(gWantTitle, 30), NBSafeClip(gWantMsg, 30), chits,
                           cr ? @"唯一命中，按它动手" : (chits > 1 ? @"多条同内容 ⇒ 不猜，不动手"
                                                                : @"没有同内容的 ⇒ 真的不在"));
                if (cr) {
                    // 🔴 一句必须说的话：下面 5 处「复量」用的还是**原 ID**
                    //    （`gWantIDs` = 盒子里那一行的旧 sys_id）。旧 ID 在兜底之前就已经
                    //    匹配不到了 ⇒ 那些复量必然报「已删」，**对本次没有信息量**。
                    //    不写这一行，下次我自己会把「已删」当成"界面变了"的证据（假绿）。
                    //    「仍在/已删」要认的话，只认 `[找·内容]` 那一行有没有再出现。
                    NBDiagStep(@"  [找·内容] ⚠️ 本次按内容动手 ⇒ 下面各处的「复量」仍按原 ID 判，"
                               @"读数对本次无意义（别当已删的证据）\n");
                    gFoundNCReq = cr;
                    NBForwardClearAsync(cr, @"内容兜底(唯一)", done);
                    return;
                }
            } else {
                NBDiagStep(@"  [找·内容] 设置里已关 ⇒ 不兜底\n");
            }
        }
        // 没找到 request ⇒ 这一刀打不出去 ⇒ 立刻把控制权交回去，让调用方去清账本
        if (done) done();
    }
}

// ---------- v0.0.62：全程 async，取消一切 dispatch_sync ----------
// 🔴🔴 v0.0.61 的真机后果：**卡屏一段时间后注销（respring）**，而且用户发回的
//    `nc_diag.txt` 里 **一条 v0.0.61 的记录都没有**（`NC 映射=` / `observer=` / `BB 已删`
//    全部 0 命中，最后一条还是 v0.0.59 的措辞）。
//    两件事拼起来只有一种解释：
//      ① 我新加的 NC 调用是在 **BBServer 的队列里同步执行的** ⇒ 和 NC 侧互相等待 ⇒
//         SpringBoard 主线程被拖住 ⇒ 看门狗杀进程 ⇒ 用户看到「卡一会儿然后注销」；
//      ② 我的 `NBDiagAppend(rec)` 写在整段流程**最后** ⇒ 卡死时一行都没落盘 ⇒
//         **事后什么证据都没有**（这是比 bug 本身更坏的问题）。
//    ⇒ 本版两条硬规矩：
//      ① **绝不在 BB 队列上调 NC 的方法**。NC 的两个动作投到
//         `NCBulletinNotificationSource` 自己那个 `queue`（系统平时就是在这条队列上回调它的）。
//         万一没抓到这条队列 ⇒ **干脆不调**：宁可这次不动，也不许再把手机卡死。
//      ② **写前日志**：每完成一步立刻 append 一行，卡死也要留下证据。
//    ⇒ 另外「量」的动作也一起搬家了：BB 的量在 BB 队列、NC 的量在 NC 队列，
//      结论最后在 BB 队列（删除账本那一步）上拼 —— 谁的队列测谁的东西。

// 立即落盘一行（写前日志）。格式同 printf。
static void NBDiagStep(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NBDiagAppend(s);
}

// 盒子 App 删记录后唤醒我们，精确清掉那一条通知。
//
// 🔴 执行链（**没有一处 dispatch_sync**）：
//     BB 队列：选 cid + 取 bulletin + 量 BB
//        └─ NC 队列：量 NC → ① observer:removeBulletin: → ② withdraw → 复量 NC
//              └─ BB 队列：③ 重新取对象 + _removeBulletin → ④ _clearBulletinIDs → 拼结论
//    每一步做完立刻 NBDiagStep 落盘。
static void NBClearNCCallback(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @try {
        NSDictionary *req = [NSDictionary dictionaryWithContentsOfFile:NOTIFYBOX_NC_CLEAR_REQ];
        NSString *sysId  = req[@"sysId"];
        NSString *bundle = req[@"bundle"];
        if (!sysId.length || !bundle.length) {
            NBLog(@"!!! [NC-CLEAR] 请求文件缺 sysId/bundle，跳过");
            return;
        }
        if (!gBBServer || !gBBServerQueue) {
            NBLog(@"!!! [NC-CLEAR] 尚未捕获 BBServer 实例/队列，跳过");
            return;
        }
        NBLog(@"=== [NC-CLEAR] v%@ 请求 sysId=%@ bundle=%@", NB_VER_STR, sysId, bundle);
        // 方法表是静态信息，只在文件不存在时写一次
        if (![[NSFileManager defaultManager] fileExistsAtPath:NOTIFYBOX_NC_DIAG_PATH]) {
            NBDiagWriteFile(sysId, bundle);
        }
        NBDiagStep(@"\n=== [尝试 %@ @%@] v%@ async sysId=%@ bundle=%@\n",
                   [NSDate date], NBProc(), NB_VER_STR, sysId, bundle);

        NSArray  *cands   = [sysId componentsSeparatedByString:@"|"];
        NSString *bundleC = [bundle copy];
        // 🔴 v0.0.67：把「这次要删哪个 App」记到全局 —— OBS hook 在主队列/NC 队列上
        //    也要用它去 `uuidsToRequests` 里按 section 找 request。
        gWantBundle = bundleC;
        // 🔴 v0.0.85：本条记录的 title / message（按内容兜底用）。
        //    🔴 每次删除都必须**重新赋值**（哪怕这段记录没有内容 ⇒ 也要显式置 nil）：
        //       否则上一次删除的 title 会残留下来，兜底会拿"上一条的内容"去本段里认亲，
        //       认到的必然是错的 —— 这种"跨次残留"在 v0.0.69 的 gFindTries 上已经吃过一次。
        gWantTitle = [(NSString *)req[@"title"] copy];
        gWantMsg   = [(NSString *)req[@"message"] copy];
        if (![gWantTitle isKindOfClass:[NSString class]]) gWantTitle = nil;
        if (![gWantMsg isKindOfClass:[NSString class]])   gWantMsg   = nil;
        gFoundNCReq = nil;
        // 🔴🔴 v0.0.69：每次删除都把两个上限计数**归零**。不归零的后果不是"少清一条"，
        //    而是「从第 3 条起 NC 那条路永远不再尝试」—— 用户测到第 3、4 条时会以为
        //    修复没生效，而其实根本没跑。护栏的上限必须按"每次操作"算。
        gFindTries     = 0;
        // 🔴 v0.0.68：三个候选 id 也记到全局。上一版只按 section 匹配就动手，而同一个 App
        //    在 NC 里可以有好几条通知（实测命中 nid 与我们的 bulletinID/recordID 三个全不一样）
        //    ⇒ 必须用 `request.bulletin` 的 bulletinID 做精确比对，否则可能撤错条。
        gWantIDs = cands.count ? [cands copy] : nil;
        // 方法表（按关键字筛）只追加一次：`NCNotificationRequest` 的构造器我还没见过真名，
        // 而"造不出 request 就只能等系统送"是这一路的死结 ⇒ 一次看清，下版一次写对。
        NBDiagAppendAPIOnce();

        // 跨队列传的测量值：NC 侧在 NC 队列上写，BB 侧在 BB 队列上读
        __block NSString *cid      = nil;
        __block BOOL      bbIn     = NO;
        __block BOOL      ncIn     = NO;
        // 🔴 v0.0.64：`ncAfter` 已删除。它的唯一用途是"扫 1062 条看本条还在不在"，
        //    而那条判据正是逼我去调 description、把 NC 队列搞死的元凶；
        //    现在判据改成 `uuid=有/无` + `req=有/无` + `winStep` + `bbWithdrew`。
        //    （删掉声明不留变量，否则 -Werror -Wunused-but-set-variable 直接编译失败）
        __block BOOL      ncRan     = NO;  // NC 块到底有没有进去跑
        __block BOOL      ncHadUUID = NO;  // 有没有换到 uuid
        __block BOOL      ncHadReq  = NO;  // 有没有拿到真 request
        __block NSInteger bbCnt    = -1;
        __block NSInteger ncCnt    = -1;
        __block NSInteger ncCnt2   = -1;
        __block NSString *pubID    = nil;   // publisherBulletinID（换 uuid 用）
        __block NSString *recID    = nil;   // recordID（换 uuid 兜底）
        __block NSInteger ncReqCnt  = -1;   // uuidsToRequests 条数（删前）
        __block NSInteger ncReqCnt2 = -1;   // uuidsToRequests 条数（删后）
        // 🔴 v0.0.82：`ncMeasured` = 「这两个数到底量过没有」。
        //    真机实测（`paste_1030.txt` 19/19 次尝试）这一行一直打的是 `映射=-1 req数=-1`：
        //    `ncCnt` 只在「投 NC 队列」那个分支里赋值，而该分支自 v0.0.64 起就是关的
        //    （日志里那行 `[NC] 本版不投 NC 队列`）⇒ 这两个字段**永远是 -1**。
        //    一个看着像数据、实际从没采样过的字段比没有更坏 —— 它会被当成"读数"去推理。
        __block BOOL ncMeasured = NO;
        __block NSString *ncUUID   = nil;   // 本条在 NC 映射里对应的 uuid（可能是 nil）
        __block NSInteger winStep  = 0;
        __block BOOL      bbWithdrew = NO;   // ⓪ 官方撤回之后 BB 里是不是没了
        __block BOOL      bbHadAtStart = NO; // 一开始 BB 里到底有没有（⓪ 会改写 bbIn，得单独记）
        // v0.0.72：新刀「按 bulletinID 直接摘」有没有把本条摘掉（**读回确认**，不是看返回值——
        // 这几个方法全返回 void，"没抛异常"根本不等于"删掉了"）。
        __block BOOL      bbRemovedByID = NO;

        // ---------- ③④ 删 BB 账本（最后做，且重新取对象）+ 拼结论 ----------
        void (^bbRemove)(void) = ^{
            if (!bbIn) {
                NBDiagStep(@"  ③ 跳过（BB 里已经没有对象：本来到处没有，或刚被 ⓪ 撤回）\n");
            } else if (![gBBServer respondsToSelector:@selector(_removeBulletin:shouldSync:)]) {
                NBDiagStep(@"  ③ 跳过（_removeBulletin:shouldSync: 不存在）\n");
            } else {
                id b2 = nil;
                @try { b2 = NBFirstObject([gBBServer _bulletinsForIDs:@[cid]]); }
                @catch (__unused NSException *e) { }
                if (!b2) {
                    NBDiagStep(@"  ③ 跳过（NC 两步之后 BB 里已没有对象）\n");
                } else {
                    @try {
                        [gBBServer _removeBulletin:b2 shouldSync:NO];
                        BOOL f = NO; NSInteger n = NBLiveScan(gBBServer, bundleC, cid, &f);
                        if (!f && !winStep) winStep = 3;
                        NBDiagStep(@"  ③ BB _removeBulletin ⇒ BB live=%ld 含本条=%@\n",
                                   (long)n, f ? @"是" : @"否");
                    } @catch (NSException *e) {
                        NBDiagStep(@"  ③ BB _removeBulletin 抛: %@\n", e.reason);
                    }
                }
            }
            // ④ 老 API 补一刀（只当「标记已清」，不改界面）
            if (bbIn && [gBBServer respondsToSelector:@selector(_clearBulletinIDs:forSectionID:shouldSync:)]) {
                @try {
                    [gBBServer _clearBulletinIDs:@[cid] forSectionID:bundleC shouldSync:NO];
                    NBDiagStep(@"  ④ _clearBulletinIDs（补刀，不改界面）\n");
                } @catch (NSException *e) {
                    NBDiagStep(@"  ④ _clearBulletinIDs 抛: %@\n", e.reason);
                }
            }
            // 结论
            BOOL bbAfter = NO;
            NSInteger bbN2 = NBLiveScan(gBBServer, bundleC, cid, &bbAfter);
            // 🔴 v0.0.64：结论不再引用 ncAfter —— 那条判据靠"扫 1062 条比 key"，
            //    正是它逼我去调 description、把 NC 队列搞死的。现在只按**实测到的状态**说人话：
            //    ⓪ 官方撤回有没有把 BB 清掉、有没有 uuid、有没有真 request、NC 那两步有没有真的跑过。
            // 🔴 注意用 bbHadAtStart 而不是 bbIn：⓪ 之后 bbIn 已经被改写成"现在还含不含本条"，
            //    拿它判"本来有没有"会把「⓪ 刚清掉」误报成「本来就没有」——那是假绿第 ⑧ 型。
            NSString *verdict;
            if (!bbHadAtStart && !ncRan) {
                verdict = @"两层都没动（BB 本来就没有，NC 也没进）";
            } else if (!bbHadAtStart && ncRan) {
                verdict = @"BB 本来就没有；NC 侧见上面的 [NC] 行";
            } else if (bbAfter) {
                verdict = @"BB 仍在（删不掉）";
            } else if (bbRemovedByID) {
                // v0.0.72：新刀**读回确认**摘掉了。判据分两问，日志里两个数都要看：
                //   `_sendRemove` 涨了 ⇒ 刀走到了"广播给 observer"那一跳；
                //   `BB→NC` 也涨了  ⇒ NC 真的收到了 ⇒ 界面该变；
                //   两个都不涨 ⇒ 这把刀和 ⓪ 一样，只改账本。
                verdict = @"✅ ⑤ 新刀摘掉了本条（本分支自本版起已不可达，留着只为不改动旧判定链）";
            } else if (bbWithdrew && winStep == 2) {
                verdict = @"✅ ⓪ 官方撤回清掉 BB + ② NC withdraw 也跑了 ⇒ 界面应会变（本轮最强态）";
            } else if (bbWithdrew) {
                verdict = @"✅ ⓪ BB 官方撤回清掉了本条（账本已清）⇒ 界面看**下面**的 [找] / [清] 两段";
            } else if (winStep == 2) {
                verdict = @"BB 已删 + NC 已用真 request 撤回（第 2 步）⇒ 界面应会变";
            } else if (winStep == 3) {
                verdict = @"BB 已删（③ _removeBulletin）；NC 没撤到 request";
            } else if (winStep == 1) {
                verdict = @"BB 已删；NC 只走了撤回广播（第 1 步），没撤 request";
            } else if (!ncHadReq) {
                // 🔴 v0.0.64：② 不再要求先有 uuid ⇒ 这里按「有没有真 request」说，
                //    而不是按「有没有 uuid」说（uuid 一直是「无」，按它说会误导）。
                verdict = @"BB 已删；没捞到真 request（uuid 映射 + 本地缓存都没有）⇒ 没走到撤回";
            } else if (!ncHadUUID) {
                verdict = @"BB 已删；request 是从本地缓存拿的（uuid 映射里没换到）";
            } else {
                verdict = @"BB 已删；NC 侧状态见上面的 [NC] 行";
            }
            NBDiagStep(@"  删后 BB: live=%ld 含本条=%@ | NC: %@ | 系统自己传给 NC 共 %d 次\n",
                       (long)bbN2, bbAfter ? @"是" : @"否",
                       ncMeasured
                           ? [NSString stringWithFormat:@"映射=%ld req数=%ld uuid=%@ req=%@",
                              (long)ncCnt2, (long)ncReqCnt2,
                              ncHadUUID ? @"有" : @"无", ncHadReq ? @"有" : @"无"]
                           : @"未量（NC 队列分支本版关闭 ⇒ 本行不读；真实读数见下面的 ⑦ 段）",
                       gBBToNCSeen);
            NBDiagStep(@"  观测计数: 目的地请求清除=%d / dispatcher 撤回=%d / source 请求清除=%d / ⑤新刀成功=%d(本版起已删,恒0) / _sendRemove=%d\n  ⇒ %@\n",
                       gObsDispatcherClear, gObsDispatcherWithdraw, gObsSrcClear,
                       gBBRemoveByIDOk, gBBSendRemoveSeen, verdict);
            NBLog(@"=== [NC-CLEAR] 删后 BB含=%@ ⇒ %@", bbAfter ? @"是" : @"否", verdict);
        };

        // ---------- 起步：BB 队列上挑 cid、取 bulletin、量 BB ----------
        dispatch_async(gBBServerQueue, ^{
            id bullet = nil;
            for (NSString *c in cands) {
                if (!c.length) continue;
                if (!cid) cid = c;                       // 兜底：先用第一个候选
                @try {
                    id b = NBFirstObject([gBBServer _bulletinsForIDs:@[c]]);
                    if (b) { cid = c; bullet = b; break; }   // 真在 BB 里的那个优先
                } @catch (__unused NSException *e) { }
            }
            if (!cid.length) { NBDiagStep(@"  (没有可用的 id，退出)\n"); return; }
            bbCnt = NBLiveScan(gBBServer, bundleC, cid, &bbIn);
            bbHadAtStart = bbIn;      // 🔴 先记下「本来在不在」——⓪ 之后 bbIn 会被改写
            NBDiagStep(@"  cid=%@\n  BB live=%ld 含本条=%@ 对象=%@\n",
                       cid, (long)bbCnt, bbIn ? @"是" : @"否",
                       bullet ? NSStringFromClass([bullet class]) : @"(没取到)");
            if (bullet) {
                recID = NBKVCStr(bullet, @"recordID");
                pubID = NBKVCStr(bullet, @"publisherBulletinID");
                NBDiagStep(@"  bulletinID=%@ recordID=%@ publisherID=%@\n",
                           NBKVCStr(bullet, @"bulletinID"), recID, pubID);
            }
            NBDiagStep(@"  环境 source=%@ dispatcher=%@ ncQueue=%@ 缓存=%lu 抑制=%@\n",
                   gNCSource ? NSStringFromClass([gNCSource class]) : @"(nil)",
                   gNCDispatcher ? NSStringFromClass([gNCDispatcher class]) : @"(nil)",
                   gNCSourceQueue ? @"有" : @"无",
                   (unsigned long)gNCRequestByID.count,
                   gNCSuppressed ? @"是" : @"否");

            // ---------- v0.0.66：把「缓存里到底是什么键」一次性看清楚 ----------
            // v0.0.65 真机：缓存 43→63→69→100 条一直在长（说明 NBStashNCRequest 正常在存），
            // 但按 cid 精确查**一条都没中** ⇒ 键肯定不是 cid。不猜了，直接打前 5 条出来。
            if (!gCacheDumped) {
                NSDictionary *snap0 = nil;
                @synchronized ([NSObject class]) {
                    snap0 = gNCRequestByID ? [gNCRequestByID copy] : nil;
                }
                if (snap0.count) {
                    gCacheDumped = YES;
                    NSArray *ks0 = [snap0 allKeys];
                    NSUInteger n0 = ks0.count < 5 ? ks0.count : 5;
                    NBDiagStep(@"  [cache] 共 %lu 条，前 %lu 个键：\n",
                               (unsigned long)snap0.count, (unsigned long)n0);
                    for (NSUInteger i0 = 0; i0 < n0; i0++) {
                        id r0 = snap0[ks0[i0]];
                        NBDiagStep(@"    key=%@ | section=%@ nid=%@\n",
                                   NBClip(ks0[i0], 50),
                                   NBClip(NBKVCStr(r0, @"sectionIdentifier"), 30),
                                   NBClip(NBKVCStr(r0, @"notificationIdentifier"), 50));
                    }
                }
            }

            // ---------- ⓪ BB 官方撤回 + ③ _removeBulletin：**打包成块，等 NC 那一刀返回后再跑** ----------
            // 🔴🔴 v0.0.69 定案（`nc_diag(10).txt`）：这两个动作原来跑在最前面，是整条链失败的真因。
            //    NC 那条驱动界面的清除，要靠 `NCBulletinNotificationSource` 把 request 翻回
            //    **BBBulletin** 再让 BB 撤一次（`_bulletinsToClearPerSectionIdForNotificationRequests:removingDestinations:`）。
            //    我们先清账本 ⇒ 它翻不出东西 ⇒ **静默什么都不做** ⇒ 界面永远收不到「移除」信号。
            //    实测证据：v0.0.68 日志里 ①②③ 全绿、`[OBS-src]` 也收到了我们的 request，
            //    但 `BB live` 在调 NC **之前**就已经 `含本条=否` —— 砖是我自己先拆掉的。
            //    ⇒ 所以这里**不再执行**，只定义；由 `[账本]` 那一跳在 NC 返回后调用。
            void (^bbCleanup)(void) = ^{
            // ---------- ⑤ v0.0.74：**整块删除**（三条候选已被真机判死）----------
            // 🔴 v0.0.72 加的三条「按 bulletinID 直接摘」—— fromNoticesSection: /
            //    fromSection:inFeed:0 / fromSection:inFeed:1 —— 在 v0.0.73 真机
            //    （`nc_diag(13).txt`）里**全部判死**：
            //      三条各广播一次 `_sendRemoveBulletin`（feeds = 1 / 0 / 1，sync 全是 0），
            //      而每次读回账本都是 `BB live` **一个没少**、`含本条=是`、`⑤ 新刀成功=0`。
            // 🔴 更糟的是它们会**先把 NC 惊动一遍**：每条都引发一次 `[BB→NC]`，
            //    K1 还额外触发了一次 `withdrawNotificationWithRequest:` ——
            //    凭空多出来的动作让后面的读回更难判，也白烧掉日志行数预算。
            // 🔴 定案，别再回来试：`removeBulletinID:*` 家族**只广播、不删账本**。
            //    要删账本只有 ⓪ `withdrawBulletinRequestsWithRecordID:forSectionID:`。
            if (bullet && bbIn) {
                NSString *rID = recID.length ? recID : cid;
                if (rID.length
                    && [gBBServer respondsToSelector:@selector(withdrawBulletinRequestsWithRecordID:forSectionID:)]) {
                    NBDiagStep(@"  ⓪ 将要调用 withdrawBulletinRequestsWithRecordID:%@ forSectionID:%@\n",
                               rID, bundleC);
                    @try {
                        [gBBServer withdrawBulletinRequestsWithRecordID:rID forSectionID:bundleC];
                        NBDiagStep(@"  ⓪ withdraw…WithRecordID 已返回\n");
                    } @catch (NSException *e) {
                        NBDiagStep(@"  ⓪ withdraw…WithRecordID 抛: %@\n", e.reason);
                    }
                } else {
                    NBDiagStep(@"  ⓪ 跳过 withdraw…WithRecordID（rID=%@ 方法=%@）\n",
                               rID.length ? rID : @"(无)",
                               [gBBServer respondsToSelector:@selector(withdrawBulletinRequestsWithRecordID:forSectionID:)] ? @"有" : @"无");
                }
                if (pubID.length && ![pubID isEqualToString:rID]
                    && [gBBServer respondsToSelector:@selector(withdrawBulletinRequestsWithPublisherBulletinID:forSectionID:)]) {
                    NBDiagStep(@"  ⓪ 将要调用 withdrawBulletinRequestsWithPublisherBulletinID:%@\n", pubID);
                    @try {
                        [gBBServer withdrawBulletinRequestsWithPublisherBulletinID:pubID forSectionID:bundleC];
                        NBDiagStep(@"  ⓪ withdraw…WithPublisherBulletinID 已返回\n");
                    } @catch (NSException *e) {
                        NBDiagStep(@"  ⓪ withdraw…WithPublisherBulletinID 抛: %@\n", e.reason);
                    }
                } else if (pubID.length) {
                    NBDiagStep(@"  ⓪ 跳过 withdraw…WithPublisherBulletinID（与 recordID 相同，上面已经用同一个键调过）\n");
                } else {
                    NBDiagStep(@"  ⓪ 跳过 withdraw…WithPublisherBulletinID（pubID=(无)）\n");
                }
                BOOL f0 = NO;
                NSInteger n0 = NBLiveScan(gBBServer, bundleC, cid, &f0);
                bbIn = f0;                 // ⓪ 之后 BB 里还在不在，交给后面的 ③ 用真实状态
                if (!f0) {
                    bbWithdrew = YES;
                    gBBWithdrawOk++;
                    // v0.0.78：⓪ 真的把账本清掉了 ⇒ 记进 [寿] 台账，后面才能量
                    //   「这条从 NC 消失用了多久」。只记真撤掉的（f0==NO），不记"本来就没有"。
                    NBDeletedRemember(cid, recID, pubID, bundleC);
                }
                NBDiagStep(@"  ⓪ 之后 BB live=%ld 含本条=%@\n", (long)n0, f0 ? @"是" : @"否");
            } else {
                // 🔴 v0.0.72：这句话原来只写"本来就没有"。新刀插在前面之后，
                //    走到这个 else 的**绝大多数情况**是"刚被 ⑤ 摘掉了"——
                //    照旧写会让人以为这一条根本没进过 BB（假绿第 ⑧ 型：否定式恒真）。
                NBDiagStep(@"  ⓪ 跳过（%@）\n",
                           bbRemovedByID ? @"刚被 ⑤ 新刀摘掉，无需官方撤回" : @"BB 里本来就没有对象");
            }
            // 清完账本后打结论（bbRemove 内部会做 ③ / ④ / 读回 / verdict）
            bbRemove();

            // ---------- ⑦ v0.0.75：只留两把可能有戏的刀，**匹配不到就不动手** ----------
            // 🔴🔴 v0.0.74 真机（`nc_diag(14).txt`，23 次尝试）先判掉两条，次数够：
            //     ⑦a `NCNotificationDispatcher -withdrawNotificationWithRequest:` —— 4 次尝试，
            //        每次「已返回」、每次读回目标还在 ⇒ 空转（这把在 v0.0.73 只是被系统自己调过，
            //        不是我们调它就有效）。
            //     ⑦b `destination:<CS 自己> clearNotificationRequests:` —— 同样 4 次全空。
            //     ⇒ 两条都删掉。留着不只烧日志行数，还会把读回的判读搅乱。
            // 🔴🔴🔴 但本轮最关键的发现不是"又少两把刀"，而是**我们的读回一直是个假判据**：
            //    `NBFindOurRequest` 精确匹配不到时会退回「同段第一条」⇒ 只要这个 App 在 NC 里
            //    还有任何一条通知，读回永远是「还能找到本条=是」。19 次读回全「是」、0 次「否」，
            //    而同一份文件里 `BB live` 已经 `含本条=否`、系统自己还打了
            //    `_sendRemoveBulletin feeds=15871 sync=1`、`[BB→NC]` 回调也有 ——
            //    该发生的都发生了，读回却雷打不动。
            //    ⇒ 这一版把 loose 兜底**整个删掉**（见 NBFindOurRequest 的注释）：
            //      匹配不到精确的就一律不动手，读回也不许兜底。
            //      顺带修掉一个**真·副作用**：loose 兜底会去撤**别人的**通知 ——
            //      用户那句"有些通知没了，但不是我要删的那条"就是这么来的。
            // 🔴 v0.0.77：gate 里去掉 `gCSDestination` —— ⑧ 不需要它（它只要 source + bulletin
            //   + observer）。以前挂上它是为了 [清]①②，那两把已经删了。
            if (!bbIn && gFoundNCReq && gNCSource) {
                id req7 = gFoundNCReq;
                NSString *want7 = [gWantBundle copy];
                // v0.0.78：`bullet8` 已删 —— ⑧ 没了，⑦ 侧不再需要 BB 的 bulletin 对象
                //   （精确匹配走 `req.bulletin`，那是 NC request 自己带的，跟 BB 账本无关）。
                dispatch_async(dispatch_get_main_queue(), ^{
                    NBDiagStep(@"  ⑦ 进入主队列：账本已清 ⇒ 界面侧开始（严格匹配，匹配不到就不动手）\n");
                    NSUInteger sc7 = 0; int sh7 = 0;
                    int shBase = -1;    // v0.0.83：基线同段条数，用来判「刀后该段被重载」
                    NSString *how7x = nil;
                    NSString *nid7 = NBSafeClip(NBKVCStr(req7, @"notificationIdentifier"), 56);
                    BOOL still = YES;

                    // ---- 基线：先量一次，让后面每一刀都有同一个起点 ----
                    @try {
                        still = (NBFindOurRequest(gNCSource, want7, gWantIDs, &how7x, &sc7, &sh7) != nil);
                        shBase = sh7;
                        NBDiagStep(@"  ⑦ 基线：扫 %lu 条 / 同段 %d 条 ⇒ 本条还在=%@ nid=%@（匹配=%@）\n",
                                   (unsigned long)sc7, sh7, still ? @"是" : @"否", nid7, how7x ?: @"?");
                    } @catch (NSException *e) {
                        NBDiagStep(@"  ⑦ 基线抛: %@\n", e.reason);
                    }

                    // ---- 🔴🔴 ⑧ 已整段删除（v0.0.78）----
                    // 下面这几行保留**只作为"为什么不再走这条路"的记录**，代码已经不在了。
                    // 真机判据（`nc_diag(18).txt`）：30 次尝试里 ⑧ 只投递到 **1 次**，
                    // 块进去后打出 `⑧ observer=<BBObserver> 方法=有` 就**再没返回** ——
                    // `.nc_pending` 从 08:05:18 一直留到 08:07:15（近 2 分钟），
                    // 后面 **29 次尝试全被那道闸门挡在原地**（`⑧ 跳过（上一次投递没回来…）`）。
                    // 🔴 两个结论，都要记住：
                    //   ① **队列选对了 ≠ 刀选对了** —— v0.0.77 自建后台队列确实治好了
                    //      「卡屏注销」（本份日志 30 次尝试无一卡屏），但刀本身在方法内部
                    //      等一个永远不来的东西 ⇒ 换成什么队列都救不了。
                    //   ② **熔断闸门会把"一刀失败"放大成"整条路径全废"** —— 一次没回来，
                    //      后面 29 次连试都不试。这就是用户那句"好像没效果了"的全部原因。
                    // ---- 以下是 v0.0.77 当年的原文（保留作依据）----
                    // ⑧ v0.0.77：**冒充系统投递**，但从主队列搬到后台队列
                    // 🔴🔴 依据（`nc_diag(17).txt` + 用户口述）：v0.0.76 的 ⑧ 在主队列上同步调
                    //   `observer:removeBulletin:` ⇒ **卡屏后注销两次**（「滑了菜鸟两次就卡屏注销了」）。
                    //   卡屏 = 主线程被拖住 = 看门狗杀进程。系统自己调这个方法时是在
                    //   `NCBulletinNotificationSource` 自己的 queue（后台）上 —— 队列选错了。
                    //   第三次之后不再卡，是因为 `.nc_pending` 留到下次开机写出了 `.nc_off`
                    //   （`抑制=是`）⇒ 界面侧被整段压掉 —— 所以"不卡了、但也没效果了"是一件事的两个面。
                    // ⇒ 本版三条约束：
                    //   ① 移到**自建后台串行队列**：块一定被执行（v0.0.64 投系统队列那次从没执行过），
                    //      且**永不占主线程** ⇒ 就算它卡，卡的也只是这条队列，不会卡屏注销。
                    //   ② `.nc_pending` 从"护栏"升级成**投递闸门**：投之前先看它还在不在，
                    //      在 ⇒ 上一次投递没回来 ⇒ 本次不投（不再往已经卡住的队列里堆）。
                    //   ③ `.nc_off` 压制时只跳过 ⑧，账本照清（见 NBForwardClearAsync）。
                    // ---------- v0.0.78：⑦r —— ⑦c 的「带时间窗」版，精确到单条 ----------
                    // 🔴🔴 为什么是这一把（`nc_diag(18).txt` 之后重读方法表定的）：
                    //    CS 侧 `- destination:clearNotificationRequestsFromDate:toDate:inSections:` `v@:@@@@`
                    //    与 ⑦c 的 `…InSections:` `v@:@@` 是**同一族**（只多两个 NSDate），
                    //    而 ⑦c 是唯一被真机证实「系统自己清一条时就是这么走」的那把
                    //    （v0.0.66 实测：手动清一条 ⇒ `destination:…requestsClearing…` 与
                    //     `dispatcher:…requestsClearing…` **成对**出现、条数一致）。
                    //    NC 侧还有它的孪生 `- destination:requestsClearingNotificationRequestsFromDate:
                    //    toDate:inSections:` —— 名字只差一个词，是**另一把刀、另一个类**，本版先只打 CS 侧。
                    // 🔴🔴 ⑦c 当年的死结：闸门写的是「同段 ≤ 1 条」，而真机实测同段条数
                    //    9 / 19 / 30 / 37 / 39 / 45 / 99 —— **一次都不满足** ⇒ 那把刀等于没装。
                    //    时间窗正好把这个死结解开：精度从「整个段」收窄到「±0.4 秒内的那一条」。
                    // 🔴 两道闸门，都基于**当场量出来的真实数**（不是估）：
                    //    ① `req.timestamp` 必须真是 NSDate。传 nil 给这个 API 极可能等价于
                    //       「不限时间」⇒ 退化成整段清 ⇒ 连带清掉同段几十条别人的通知。宁可不打。
                    //    ② 同段里 timestamp 落在窗口内的**只能有 1 条**（就是本条）。
                    //       这一量同时也是「方法万一忽略时间参数」的兜底：窗口内=1 而段内>1 时
                    //       我们仍然要打（否则永不触发），所以窗口取窄（±0.4s）来压低概率。
                    // ================= v0.0.80：⑦s / ⑦t —— 不再等 BB→NC 自己传播 =================
                    // 🔴🔴🔴 本版存在的**全部理由**（`nc_diag(20).txt`，27 次尝试）：
                    //    ⓪ 撤回 BB 之后，BB→NC 的传播是**成批 + 延迟 13~99 秒**的。
                    //    同一份日志里 4 次删除的 `[BB→NC] observer:removeBulletin:` 全堆到
                    //    09:56:47~48 才一起到达：
                    //      ⓪@09:55:08 → 09:56:47（99s）  ⓪@09:55:20 → 09:56:47（87s）
                    //      ⓪@09:56:03 → 09:56:48（45s）  ⓪@09:56:35 → 09:56:48（13s）
                    //    ⇒ 用户删完立刻划开通知中心，看到的就是**还在** ⇒ 「好像没效果」。
                    //    🔴 决定性对照：同一批里 NC 的 request 数从 651 跳到 1381（整份重载），
                    //       **重载之后**每一次 ⓪ 都在同一轮就到达 NC（`⑦r 不需要` × 5）。
                    //       ⇒ 传播速度取决于 NC 那边 observer 客户端的**装载状态**，
                    //         那个状态我们控制不了 ⇒ 唯一出路是**自己走 NC 侧那两刀**。
                    //    🔴 另一条更要紧的账：上一版「能用了」是**碰巧**，不是修好了 ——
                    //       那一次 ⓪ 的传播恰好没排队。判据不能建立在别人的队列上。
                    // 🔴 为什么现在敢打这两把（**旧结论作废**，不是"再试一次"）：
                    //    ⑦a / [清]① / [清]③ 当年被判「4 次全空转」用的读回，是
                    //    `NBFindOurRequest` 的 **loose 兜底**（精确匹配不到就退回「同段第一条」）
                    //    ⇒ 只要该段还有任何一条通知，读回**永远**是「还在=是」，
                    //    结构上不可能出现「否」。v0.0.75 已把兜底整个删掉（见函数注释），
                    //    判据到这里才第一次可信。
                    //    而且现在手里是 `[找]` 出来的**真 request**（`req.bulletin` 命中），
                    //    不是 v0.0.62 那种工厂造的空壳 —— 前提条件也换了。
                    if (still && req7) {
                        // ---- ⑦s：NC 侧派发器。系统自己撤一条时走的就是这一步 ----
                        // 依据：09:56:47 那批 `[OBS] dispatcher withdrawNotificationWithRequest:`
                        //       紧跟着 `[OBS-cs] withdrawNotificationRequest:` **成对**出现。
                        if (gNCDispatcher
                            && [gNCDispatcher respondsToSelector:@selector(withdrawNotificationWithRequest:)]) {
                            if (gCsWsSuppressed) {
                                NBDiagStep(@"  ⑦s 跳过（%@ 压制；删它并 respring 可恢复）\n", kNBGuardOff);
                            } else {
                                [[[NSString stringWithFormat:@"%@ ⑦s %@ %@", NB_VER_STR, [NSDate date], nid7 ?: @"?"]
                                  dataUsingEncoding:NSUTF8StringEncoding] writeToFile:kNBGuardCSWs atomically:YES];
                                NBDiagStep(@"  ⑦s 将要调用 NCNotificationDispatcher -withdrawNotificationWithRequest:"
                                           @"（真 request nid=%@）\n", nid7);
                                gNCDirectWithdraw++;
                                @try {
                                    [gNCDispatcher withdrawNotificationWithRequest:req7];
                                    NBDiagStep(@"  ⑦s 已返回\n");
                                } @catch (NSException *e) {
                                    NBDiagStep(@"  ⑦s 抛: %@\n", e.reason);
                                }
                                [[NSFileManager defaultManager] removeItemAtPath:kNBGuardCSWs error:NULL];
                                @try {
                                    still = (NBFindOurRequest(gNCSource, want7, gWantIDs, &how7x, &sc7, &sh7) != nil);
                                    NBDiagStep(@"  ⑦s 读回：扫 %lu 条 / 同段 %d 条 ⇒ 本条还在=%@（匹配=%@）\n",
                                               (unsigned long)sc7, sh7,
                                               still ? @"是" : @"否（已删）", how7x ?: @"?");
                                    NBReportSectionJump("7s", shBase, sh7);
                                } @catch (NSException *e) {
                                    NBDiagStep(@"  ⑦s 读回抛: %@\n", e.reason);
                                }
                            }
                        } else {
                            NBDiagStep(@"  ⑦s 跳过（没有 dispatcher，或方法不在表里）\n");
                        }
                        // ---- ⑦t：CS 侧（界面层）那一刀 —— 系统那条链的最后一步 ----
                        // 🔴 只在 ⑦s 没撤掉时才打：⑦s 生效时它内部本来就会走到 CS，
                        //    重复打没有收益，只会让「谁起的作用」变糊。
                        if (still && gCSDestination
                            && [gCSDestination respondsToSelector:@selector(withdrawNotificationRequest:)]) {
                            if (gCsWsSuppressed) {
                                NBDiagStep(@"  ⑦t 跳过（%@ 压制；删它并 respring 可恢复）\n", kNBGuardOff);
                            } else {
                                [[[NSString stringWithFormat:@"%@ ⑦t %@ %@", NB_VER_STR, [NSDate date], nid7 ?: @"?"]
                                  dataUsingEncoding:NSUTF8StringEncoding] writeToFile:kNBGuardCSWs atomically:YES];
                                NBDiagStep(@"  ⑦t 将要调用 CSNotificationDispatcher -withdrawNotificationRequest:\n");
                                gCSDirectWithdraw++;
                                @try {
                                    [gCSDestination withdrawNotificationRequest:req7];
                                    NBDiagStep(@"  ⑦t 已返回\n");
                                } @catch (NSException *e) {
                                    NBDiagStep(@"  ⑦t 抛: %@\n", e.reason);
                                }
                                [[NSFileManager defaultManager] removeItemAtPath:kNBGuardCSWs error:NULL];
                                @try {
                                    still = (NBFindOurRequest(gNCSource, want7, gWantIDs, &how7x, &sc7, &sh7) != nil);
                                    NBDiagStep(@"  ⑦t 读回：扫 %lu 条 / 同段 %d 条 ⇒ 本条还在=%@（匹配=%@）\n",
                                               (unsigned long)sc7, sh7,
                                               still ? @"是" : @"否（已删）", how7x ?: @"?");
                                    NBReportSectionJump("7t", shBase, sh7);
                                } @catch (NSException *e) {
                                    NBDiagStep(@"  ⑦t 读回抛: %@\n", e.reason);
                                }
                            }
                        }
                    }

                    // ---- ⑦u：摘掉 NC source 自己的映射（**唯一改模型的一刀**）----
                    // 🔴🔴🔴 依据（`nc_diag(21).txt`，26 次尝试）：
                    //    ⑦s / ⑦t / ⑦r 三把刀的读回 **7/7 全是「本条还在=是」**，
                    //    可用户**眼睛看到那张卡同步删掉了**（原话：「刚好看到通知中心有同步删除了」）。
                    //    ⇒ 界面侧的刀是有效的；**无效的是我们读的那个模型**：
                    //      读回走 `NCBulletinNotificationSource.uuidsToRequests`，
                    //      而这个映射**只有 BB→NC 传播（observer:removeBulletin:）才会动**，
                    //      界面侧怎么撤它都不动一下。
                    //    两个后果都是致命的：
                    //      ① 读回永远是「还在」⇒ 前几版所有「刀空转」的判读都不可信
                    //         （这也是 ⑦a/[清]①③ 当年被冤枉的同一类错，换个位置又犯了）；
                    //      ② 那条 request 还躺在映射里 ⇒ NC 一旦重新装载/重新 post，
                    //         就把它**加回界面** —— 这正是用户说的「删除了，然后又出现」。
                    //    ⇒ 必须显式把它从 uuidsToRequests / bulletinsToUUIDs 里摘掉。
                    //    🔴 这一刀和前三把的本质区别：前三把动的是**界面**，这一把动的是**账本**。
                    //       按 §1 的纪律，改模型的刀要放在最后，且必须有独立的读回。
                    if (still && gNCSource && want7.length) {
                        @try {
                            NSDictionary *m0 = nil;
                            @try { m0 = [gNCSource uuidsToRequests]; } @catch (__unused NSException *e) { }
                            if (![m0 isKindOfClass:[NSDictionary class]]) {
                                NBDiagStep(@"  ⑦u 跳过（uuidsToRequests 读不到 / 不是字典）\n");
                            } else {
                                NSUInteger before = m0.count;
                                // v0.0.82 量前（只读）：让 setter 前后的「组成」可比
                                NSInteger b2uBefore = -1;
                                @try {
                                    id x0 = [gNCSource bulletinsToUUIDs];
                                    if ([x0 isKindOfClass:[NSDictionary class]])
                                        b2uBefore = (NSInteger)((NSDictionary *)x0).count;
                                } @catch (__unused NSException *e) { }
                                // v0.0.83：不再打自制直方图（已证坏死），改打**同段**——
                                // 它和读回走同一段代码（`NBFindOurRequest` 的 secHits 口径），可信。
                                NSUInteger scB = 0; int shB = 0; NSString *howB = nil;
                                (void)NBFindOurRequest(gNCSource, want7, @[], &howB, &scB, &shB);
                                NBDiagStep(@"  ⑦u 量前：uuidsToRequests=%lu bulletinsToUUIDs=%ld"
                                           @" ｜ 同段=%d（基线 %d）扫 %lu 条\n",
                                           (unsigned long)before, (long)b2uBefore, shB, shBase,
                                           (unsigned long)scB);
                                NSMutableDictionary *cp = [m0 mutableCopy];
                                NSMutableArray *killed = [NSMutableArray array];
                                for (id k in cp) {
                                    NSMutableArray *arr = [NSMutableArray array];
                                    NBCollectRequestsIn([cp objectForKey:k], arr, 0);
                                    for (id r2 in arr) {
                                        NSString *sid2 = NBKVCStr(r2, @"sectionIdentifier");
                                        if (!sid2.length || ![sid2 isEqualToString:want7]) continue;
                                        if (NBReqIsOurs(r2, gWantIDs)) { [killed addObject:k]; break; }
                                    }
                                }
                                if (!killed.count) {
                                    NBDiagStep(@"  ⑦u 没摘到（映射 %lu 键，本案已不在里面）\n",
                                               (unsigned long)before);
                                } else {
                                    for (id k in killed) [cp removeObjectForKey:k];
                                    if ([gNCSource respondsToSelector:@selector(setUuidsToRequests:)]) {
                                        [gNCSource setUuidsToRequests:cp];
                                    }
                                    // bulletinsToUUIDs：值是刚摘掉的那些 uuid ⇒ 一起摘，别留悬空键
                                    @try {
                                        id b2u = [gNCSource bulletinsToUUIDs];
                                        if ([b2u isKindOfClass:[NSDictionary class]]) {
                                            NSMutableDictionary *bc = [b2u mutableCopy];
                                            NSMutableArray *bk = [NSMutableArray array];
                                            for (id k2 in bc) {
                                                id bv = [bc objectForKey:k2];
                                                if (bv && [killed containsObject:bv]) [bk addObject:k2];
                                            }
                                            for (id k2 in bk) [bc removeObjectForKey:k2];
                                            if (bk.count
                                                && [gNCSource respondsToSelector:@selector(setBulletinsToUUIDs:)]) {
                                                [gNCSource setBulletinsToUUIDs:bc];
                                            }
                                            NBDiagStep(@"  ⑦u bulletinsToUUIDs 同步摘掉 %lu 键\n",
                                                       (unsigned long)bk.count);
                                        }
                                    } @catch (__unused NSException *e) { }
                                    gNCDirectMapKill += (int)killed.count;
                                    NSUInteger afterN = 0;
                                    NSInteger b2uAfter = -1;
                                    id m1 = nil;
                                    @try {
                                        m1 = [gNCSource uuidsToRequests];
                                        if ([m1 isKindOfClass:[NSDictionary class]])
                                            afterN = ((NSDictionary *)m1).count;
                                    } @catch (__unused NSException *e) { }
                                    @try {
                                        id x1 = [gNCSource bulletinsToUUIDs];
                                        if ([x1 isKindOfClass:[NSDictionary class]])
                                            b2uAfter = (NSInteger)((NSDictionary *)x1).count;
                                    } @catch (__unused NSException *e) { }
                                    NBDiagStep(@"  ⑦u 已从 uuidsToRequests 摘掉 %lu 键（%lu → %lu）\n",
                                               (unsigned long)killed.count,
                                               (unsigned long)before, (unsigned long)afterN);
                                    // v0.0.82 量后（只读）：与「量前」逐字对比 ⇒ 组成变没变一眼可判
                                    NSUInteger scA = 0; int shA = 0; NSString *howA = nil;
                                    (void)NBFindOurRequest(gNCSource, want7, @[], &howA, &scA, &shA);
                                    NBDiagStep(@"  ⑦u 量后：uuidsToRequests=%lu bulletinsToUUIDs=%ld"
                                               @" ｜ 同段=%d（基线 %d）扫 %lu 条\n",
                                               (unsigned long)afterN, (long)b2uAfter, shA, shBase,
                                               (unsigned long)scA);
                                    NBReportSectionJump("7u", shBase, shA);
                                }
                                still = (NBFindOurRequest(gNCSource, want7, gWantIDs, &how7x, &sc7, &sh7) != nil);
                                NBDiagStep(@"  ⑦u 读回：扫 %lu 条 / 同段 %d 条 ⇒ 本条还在=%@（匹配=%@）\n",
                                           (unsigned long)sc7, sh7,
                                           still ? @"是" : @"否（已删）", how7x ?: @"?");
                                // 🔴 v0.0.82 双读：同一次块里连读两遍。
                                //   两次不一致 ⇒ 这个判据本身不稳定 ⇒ 之前所有「已删」都不能当证据。
                                {
                                    NSUInteger sc8 = 0; int sh8 = 0; NSString *how8 = nil;
                                    BOOL still2 = (NBFindOurRequest(gNCSource, want7, gWantIDs,
                                                                    &how8, &sc8, &sh8) != nil);
                                    if (still2 != still || sc8 != sc7 || sh8 != sh7) {
                                        NBDiagStep(@"  ⑦u 🔴 读回不稳定：①扫 %lu/同段 %d/还在=%@ ｜ "
                                                   @"②扫 %lu/同段 %d/还在=%@ ⇒ 两次之间映射变了\n",
                                                   (unsigned long)sc7, sh7, still ? @"是" : @"否",
                                                   (unsigned long)sc8, sh8, still2 ? @"是" : @"否");
                                    } else {
                                        NBDiagStep(@"  ⑦u 读回稳定（连读两次同结果：扫 %lu 条 / 同段 %d 条 / 还在=%@）\n",
                                                   (unsigned long)sc8, sh8, still2 ? @"是" : @"否");
                                    }
                                }
                            }
                        } @catch (NSException *e) {
                            NBDiagStep(@"  ⑦u 抛: %@\n", e.reason);
                        }
                    }

                    // ---- ⑦r：前三把都没撤掉才用（带 ±0.4s 时间窗，唯一有连带风险的那把）----
                    if (still && !gUseR) {
                        NBDiagStep(@"  ⑦r 跳过（本版默认关闭：26 次尝试里它从无独立生效的证据，"
                                   @"且是唯一有连带风险的刀；要开就改 gUseR）\n");
                    }
                    if (still && gCSDestination && req7 && gUseR) {
                        NSString *nid7r = nid7;
                        NSDate *ts7 = nil;
                        @try {
                            id v = NBSafeValue(req7, @"timestamp");
                            if ([v isKindOfClass:[NSDate class]]) ts7 = (NSDate *)v;
                        } @catch (__unused NSException *e) { }
                        BOOL hasRng = [gCSDestination respondsToSelector:
                                       @selector(destination:clearNotificationRequestsFromDate:toDate:inSections:)];
                        int winHits = (ts7 ? NBCountInWindow(gNCSource, want7, ts7, 0.4) : -1);
                        NBDiagStep(@"  ⑦r 闸门：timestamp=%@ 窗口(±0.4s)内同段=%d 段内总=%d 方法=%@ 压制=%@\n",
                                   ts7 ? [NSString stringWithFormat:@"%.3f", [ts7 timeIntervalSince1970]]
                                       : @"(取不到/不是 NSDate)",
                                   winHits, sh7, hasRng ? @"有" : @"无",
                                   gCsWsSuppressed ? @"是" : @"否");
                        if (gCsWsSuppressed) {
                            NBDiagStep(@"  ⑦r 跳过（主队列上卡死过 ⇒ %@ 压制；删它可恢复）\n", kNBGuardOff);
                        } else if (!ts7) {
                            NBDiagStep(@"  ⑦r 跳过（timestamp 不可用 ⇒ 不传 nil 时间窗）\n");
                        } else if (!hasRng) {
                            NBDiagStep(@"  ⑦r 跳过（clearNotificationRequestsFromDate:toDate:inSections: 不在方法表）\n");
                        } else if (winHits != 1) {
                            NBDiagStep(@"  ⑦r 跳过（窗口内 %d 条 ≠ 1 ⇒ 要么打不中、要么连带）\n", winHits);
                        } else {
                            // 🔴 护栏先写、后调用、返回立刻删 —— 顺序不能反
                            [[[NSString stringWithFormat:@"%@ ⑦r %@ %@", NB_VER_STR, [NSDate date], nid7r ?: @"?"]
                              dataUsingEncoding:NSUTF8StringEncoding] writeToFile:kNBGuardCSWs atomically:YES];
                            NBDiagStep(@"  ⑦r 将要调用 destination:clearNotificationRequestsFromDate:toDate:inSections:\n"
                                       @"       首参=dispatcher(%@) 段=%@ from=%.3f to=%.3f\n",
                                       NBClassName(gNCDispatcher), want7,
                                       [ts7 timeIntervalSince1970] - 0.4,
                                       [ts7 timeIntervalSince1970] + 0.4);
                            @try {
                                [gCSDestination destination:gNCDispatcher
                             clearNotificationRequestsFromDate:[ts7 dateByAddingTimeInterval:-0.4]
                                                      toDate:[ts7 dateByAddingTimeInterval:0.4]
                                                   inSections:[NSSet setWithObject:want7]];
                                NBDiagStep(@"  ⑦r 已返回\n");
                            } @catch (NSException *e) {
                                NBDiagStep(@"  ⑦r 抛: %@\n", e.reason);
                            }
                            [[NSFileManager defaultManager] removeItemAtPath:kNBGuardCSWs error:NULL];
                            @try {
                                still = (NBFindOurRequest(gNCSource, want7, gWantIDs, &how7x, &sc7, &sh7) != nil);
                                NBDiagStep(@"  ⑦r 读回：扫 %lu 条 / 同段 %d 条 ⇒ 本条还在=%@\n",
                                           (unsigned long)sc7, sh7, still ? @"是" : @"否（已删）");
                            } @catch (NSException *e) {
                                NBDiagStep(@"  ⑦r 读回抛: %@\n", e.reason);
                            }
                            // 🔴 v0.0.80：这里原来有个 ⑦r 专属的 +20s 复量，已**上移**成统一的 ⑦T
                            //    （+5s / +30s，见 NBCheckDeletedAlive 之后那段）。
                            //    原因：20 秒这个数本身就选错了 —— `nc_diag(20).txt` 证明 BB→NC 的
                            //    传播能拖到 99 秒，而延迟的长短**不由我们这把刀决定**。
                        }
                    } else if (!still) {
                        // 🔴🔴 v0.0.79：这一分支是 `nc_diag(19).txt` 里**每一次都走到的那个** ——
                        //    ⓪ 撤回 BB 之后，系统自己把整条链跑完了
                        //    （`_sendRemoveBulletins` → `[BB→NC] observer:removeBulletin:` →
                        //      `[OBS] dispatcher withdrawNotificationWithRequest:` →
                        //      `[OBS-cs] withdrawNotificationRequest:`），
                        //    ⑦ 基线 复量就是「本条还在=否」⇒ 界面侧**已经干净了**。
                        //    ⇒ 这时候再打 ⑦r 是多余的，而且 ⑦r 是唯一一把有连带风险的刀。
                        //    🔴 必须显式打这一行：否则日志里 ⑦r 一次都不出现，
                        //       下一轮会读成"⑦r 没跑"，而事实是"根本不需要跑"（假绿的 ⑧ 型反过来）。
                        NBDiagStep(@"  ⑦r 不需要（此刻本条已不在 NC —— 要么 ⓪ 之后系统自己撤了，"
                                   @"要么 ⑦s/⑦t 刚刚撤掉了；看上面的逐刀读回是哪一种）\n");
                    }

                    // ---------- v0.0.78：[寿] 旧删台账（本轮的核心取证）----------
                    // 🔴 放在 ⑦rs 之后、同一个主队列块里：省一次调度，且此刻 NC 的映射是热的。
                    //    它一次扫描比对多条旧 cid，比"每条旧记录各扫一遍"便宜一个数量级。
                    NBCheckDeletedAlive();

                    // ---------- v0.0.80：⑦T 统一延迟复量（+5s / +30s）----------
                    // 🔴 为什么同秒读回不够用：本版已知 BB→NC 的传播能拖到 99 秒（见 ⑦s 注释），
                    //    ⇒ 「同秒还在」不等于刀无效；反过来「同秒已删」也可能是撞上了那一批传播，
                    //    把功劳记在刀头上。两个方向都要有延迟量才能定性。
                    // 🔴 顺带把 `gObsDispatcherWithdraw` 一起打出来 —— 它是「有没有人到过 NC」
                    //    唯一的旁证，且**混计系统与我方**，正好用来交叉验证 ⑦s 到底发没发出去。
                    {
                        NSString *nidT = [nid7 copy];
                        // 🔴 v0.0.82：加 +90s —— 已实测 BB→NC 传播能拖到 **99 秒**（nc_diag(20)），
                        //    +30s 仍在「传播窗口」里面 ⇒ 看不到「晚到又被加回」的那一类。
                        //    窗口必须盖住传播上界，否则「+30s 已删」证明不了「不会再回来」。
                        for (NSNumber *secN in @[ @5, @30, @90 ]) {
                            const double sec = [secN doubleValue];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                NSUInteger scT = 0; int shT = 0; NSString *howT = nil;
                                BOOL stT = (NBFindOurRequest(gNCSource, want7, gWantIDs, &howT, &scT, &shT) != nil);
                                NBDiagStep(@"  ⑦T +%.0fs 复量 nid=%@：扫 %lu 条 / 同段 %d 条 ⇒ 本条还在=%@"
                                           @"（匹配=%@ ｜ dispatcher 撤回总计=%d，其中我方 ⑦s=%d/⑦t=%d/⑦u=%d"
                                           @" ｜ [RL] 重载=%d [RM] %d(命中 %d) [RP] %d(命中 %d)）\n",
                                           sec, nidT,
                                           (unsigned long)scT, shT, stT ? @"是" : @"否（已删）", howT ?: @"?",
                                           gObsDispatcherWithdraw, gNCDirectWithdraw,
                                           gCSDirectWithdraw, gNCDirectMapKill,
                                           gNoteLoadedSeen, gModifySeen, gModifyHit,
                                           gPostSeen, gRepostHit);
                            });
                        }
                    }

                    // ---------- v0.0.77：⑦c / ⑦d 一并删除 ----------
                    // ⑦c `destination:dispatcher clearNotificationRequestsInSections:` ——
                    //   v0.0.75/76 各跑到 1 次，`已返回` + 读回还是「是」，而且它的连带风险最大
                    //   （整段清会带走别人的通知），只有"同段≤1"时才敢用 —— 收益比太差。
                    // ⑦d `destination:performAction:forNotificationRequest:…` + `request.clearAction` ——
                    //   v0.0.75 两次 `完成回调 ok=是` 但没有任何可观测变化；而且它是**执行一个 UI 动作**，
                    //   副作用面最大。
                    // 🔴 两条都在主队列上，且都动不了 source 的账 ⇒ 删掉，界面侧只留 ⑧。

                    // 顺带把真 UI 目的地对象看一眼（只读，一次）
                    if (!gCSDDestsDumped) {
                        gCSDDestsDumped = YES;
                        @try {
                            id ld2 = [gCSDestination respondsToSelector:@selector(listDestination)]
                                     ? [gCSDestination listDestination] : nil;
                            id md2 = [gCSDestination respondsToSelector:@selector(modalDestination)]
                                     ? [gCSDestination modalDestination] : nil;
                            NBDiagStep(@"  ⑦ 目的地：list=<%@> modal=<%@>\n", NBClassName(ld2), NBClassName(md2));
                        } @catch (NSException *e) {
                            NBDiagStep(@"  ⑦ 目的地探测抛: %@\n", e.reason);
                        }
                    }
                    NBDiagStep(@"  ⑦ 结束：本条还在=%@ nid=%@ ｜ CS 侧观测计数 撤回=%d 清=%d 段清=%d 段范围清=%d incoming=%d 长按=%d（投递=%d 存活对照）\n",
                               still ? @"是" : @"否", nid7,
                               gCSDWithdraw, gCSDClear, gCSDClearSec, gCSDClearRng,
                               gCSDIncoming, gCSDDismiss, gCSDPost);
                    NBDiagStep(@"  ⑦ 逐刀计数：我方 ⑦s=%d ⑦t=%d ⑦u(摘键)=%d ⑦r(段范围清)=%d"
                               @" ｜ dispatcher 撤回总计(系统+我方)=%d"
                               @" ｜ [RL] 段重载=%d [RM] modify=%d(命中 %d) [RP] 投递=%d(命中复投 %d)\n",
                               gNCDirectWithdraw, gCSDirectWithdraw, gNCDirectMapKill,
                               gCSDClearRng, gObsDispatcherWithdraw,
                               gNoteLoadedSeen, gModifySeen, gModifyHit, gPostSeen, gRepostHit);
                    // v0.0.83：把「删除前后 ±300 秒内的段重载」补打出来 ——
                    // 这些重载绝大多数发生在诊断窗口之外，只有靠常驻环形缓冲才看得见。
                    @try {
                        // 🔴 v0.0.84：这里传 ASCII `@"reload"`，不传中文。
                                   //   `%s` 收 UTF-8 中文在 NSString 格式化里会被按 8-bit
                                   //   字符集解码 ⇒ 真机打出 `（ÊÆµÈáçËΩΩ）`，grep 不到。
                                   NBRingDump([[NSDate date] timeIntervalSince1970], 300, @"reload");
                    } @catch (__unused NSException *e) { }
                });
            }
            };   // ← bbCleanup 结束，**这里只是定义，没有被调用**

            // ---------- 🔴 v0.0.69：**先**走 NC 清除（此时 BB 里本条还活着），走完再清账本 ----------
            // v0.0.66 真机 `nc_diag(8).txt` 定案（两条都是实测，不是推断）：
            //   ① 手动清通知时系统成对走 `destination:requestsClearing…` + `dispatcher:requestsClearing…`，
            //      条数一致；而 `withdrawNotificationWithRequest:` **0 次**（**仅**"手动清一条"成立）。
//    🔴 v0.0.74：真删除那一批是**逐条** withdraw 的 ⇒ ⑦a 就是照它抄的。
            //   ② 缓存键是纯数字 nid，我们手里是 UUID / `f__-XoQ…` ⇒ 按 id 找**结构性无效**。
            // 🔴 v0.0.68 补：section 只用来**缩小范围**，真正定案靠 `request.bulletin` 的 bulletinID。
            // 🔴 v0.0.69 补：**顺序**。这一刀要能驱动界面，必须让 source 把 request 翻回 BBBulletin；
            //    所以它必须跑在 `bbCleanup`（⓪ + ③）**之前**。原来反着，等于先拆砖再砌墙。
            BOOL ncPathTaken = NO;
            // 🔴🔴🔴 v0.0.78：原来这里是 `if (gNCDispatcher && bullet)` —— 一个 `&& bullet`
            //    让 **23/30 次删除（77%）根本没碰 NC 侧**（`nc_diag(18).txt`：那些尝试的
            //    `BB live=… 含本条=否 对象=(没取到)`，然后直接落到下面的
            //    `[序] 没有 NC dispatcher/bulletin ⇒ 就地清账本`，界面一个字都没动）。
            //    🔴 而 `bullet` 是 **BB 账本里**的对象 —— 账本里没有，不等于 NC 里没有：
            //    NC 的 request 自带一份 `bulletin`（日志里 `[找] req.bulletin=<BBBulletin>`），
            //    那才是精确匹配真正用的东西（`NBReqIsOurs` 读的就是它）。
            //    ⇒ 判据从「BB 里有对象」改成「有 dispatcher」（dispatcher 是常驻的）。
            //    这条改动的量级比换刀大得多：它把 77% 的空转变成真尝试。
            if (gNCDispatcher) {
                ncPathTaken = YES;
                // 🔴 v0.0.77：这句原来的措辞是「先走 NC 清除 ⇒ 等它返回再清账本」。
                //   [清] 整段删除后，主队列上这一步**只找 request、不动手**，
                //   真正的界面侧动作是 ⑧，而且它在**账本清完之后**、在后台队列上跑。
                NBDiagStep(@"  [序] 本版顺序：主队列只找 request ⇒ 回 BB 队列清账本（⓪）⇒ 再回主队列复量，"
                           @"还在就依次 ⑦s(NC 直撤) ⇒ ⑦t(CS 直撤) ⇒ ⑦u(摘 NC 映射)，⑦r 默认关"
                           @"（缓存 %lu 条对本条无效）\n",
                           (unsigned long)gNCRequestByID.count);
                dispatch_async(dispatch_get_main_queue(), ^{
                    NBDiagStep(@"  [找] 进入主队列\n");
                    if (!gMapDumped) {
                        gMapDumped = YES;
                        NBMapCensus(gNCSource);
                    }
                    // 🔴 done 回调 = ①②③ 真的返回了。**只有到这一刻**才允许清账本。
                    NBFindAndForwardClear(@"主队列", ^{
                        dispatch_async(gBBServerQueue ?: dispatch_get_main_queue(), ^{
                            NBDiagStep(@"  [账本] NC 那一刀已返回 ⇒ 现在补 ⓪ / ③（顺序反了就是 v0.0.68 的死因）\n");
                            bbCleanup();
                        });
                    });
                });
            }

            // ---------- 🔴 v0.0.65：不再把动作投到 NC 队列 ----------
            // v0.0.64 真机：投了、`dispatch_async` 也返回了，但块的第一行从没打印
            // （30 秒内 4 次后续尝试全被 gNCBusy 挡）。既然投了不跑，就不投。
            if (!gNCUseQueuePath) {
                NBDiagStep(@"  [NC] 本版不投 NC 队列（v0.0.64 真机：投了但块从没被执行）\n");
                if (!ncPathTaken) {
                    // 没有 NC dispatcher / bulletin ⇒ 退回老路：就地清账本。
                    // 界面多半不会变（这正是历史遗留问题），但至少账本要干净。
                    NBDiagStep(@"  [序] 没有 NC dispatcher/bulletin ⇒ 就地清账本（界面可能不变）\n");
                    bbCleanup();
                }
                // 🔴 v0.0.69：这里原来还有一句 `bbRemove();` —— **必须删掉**。
                //    `bbCleanup` 内部最后就是 `bbRemove()`，留着会清两遍；更致命的是：
                //    NC 路已把 bbCleanup 交给完成回调 ⇒ 这一句会抢在 NC 之前把账本清了，
                //    等于把本版刚修好的顺序又改回去（自己拆砖）。
                return;
            }

            dispatch_queue_t ncq = gNCSourceQueue;
            if (gNCBusy && ([NSDate timeIntervalSinceReferenceDate] - gNCBusyAt) < 8.0) {
                // 🔴 v0.0.64：上一次进 NC 队列的块还没回来 ⇒ 本进程**再也不进**。
                //    v0.0.63 真机就是因为没有这道闸，9 次尝试一条条排在同一条队列后面全部陪葬。
                NBDiagStep(@"  ⚠️ 上一次 NC 尝试还没回来（本进程）⇒ 本次不再进 NC 队列\n");
                bbRemove();
                return;
            }
            if (gNCBusy) {
                // 🔴🔴 v0.0.65：闸门**必须带超时**。v0.0.64 真机就是被它锁死的 ——
                //    块从没执行 ⇒ 标记永远清不掉 ⇒ 后面 4 次尝试全被挡（日志里 4 条「本进程」）。
                //    这和「`.nc_off` 一写就永久压制新版」是同一个设计缺陷，我犯了两遍。
                NBDiagStep(@"  ⚠️ 上一次 NC 尝试已超时 %.1fs ⇒ 放行本次（清掉闸门标记）\n",
                           [NSDate timeIntervalSinceReferenceDate] - gNCBusyAt);
                gNCBusy = NO;
            }
            if (gNCSuppressed) {
                NBDiagStep(@"  ⚠️ 上次 NC 路径卡死过 ⇒ 本次不碰 NC，只删 BB 账本（删 %@ 可恢复）\n", kNBGuardOff);
                bbRemove();
                return;
            }
            if (!ncq || !gNCSource || !bullet) {
                NBDiagStep(@"  ⚠️ NC 队列/source/bulletin 缺一 ⇒ 跳过 NC 两步，只删 BB 账本\n");
                bbRemove();
                return;
            }
            if (ncq == gBBServerQueue) {
                // 真出现这种巧合就说明"NC 队列 == BB 队列"，那 NC 侧调用等于又回到 v0.0.61 的坑里
                NBDiagStep(@"  ⚠️ NC 队列就是 BB 队列 ⇒ 跳过 NC 两步（避免再次死锁）\n");
                bbRemove();
                return;
            }

            // 🔴 写「我马上要碰 NC」标记：跑完立刻删；留到下次开机 = 这次卡死了
            // 🔴 写「我马上要碰 NC」标记：跑完立刻删；留到下次开机 = 这次卡死了。
            //    内容带**版本号**，开机时才能判断"是哪一版卡死的"（新版自动重试一次）。
            [[[NSString stringWithFormat:@"%@ pending %@ %@", NB_VER_STR, [NSDate date], cid]
              dataUsingEncoding:NSUTF8StringEncoding] writeToFile:kNBGuardPending atomically:YES];
            NBDiagStep(@"  [guard] 已写 .nc_pending，进 NC 队列\n");

            // ---------- NC 队列：**每一步先写「将要调用什么」，再调用** ----------
            // 🔴🔴 v0.0.63 真机铁证（`nc_diag(5).txt`，22 条记录）：
            //      **进入本块的 9 条全部没回来，而且连第一行都没打印**；
            //      同一份日志里走「缺一 ⇒ 跳过 NC」的 12 条全部正常走完。
            //    ⇒ 死在 NC 块的第一句。v0.0.63 唯一新加在第一句的是 `NBDumpNCMapsOnce`
            //      （里面调 `[k description]` / `[v description]`）⇒ **对未知类调 description 会卡死**。
            //    ⇒ 本版三条规矩：
            //       ① **绝不对未知类调 `description`**（`NBClip` 已改成只认 NSString）。
            //       ② **写前日志**：先写「将要调用 X」，再调 X，再写结果。
            //          上一版是「调完才写」，所以第一句里死掉就一个字都没有 —— 教训。
            //       ③ **一次进程只赌一次**：`gNCBusy` 没清掉就说明上次没回来 ⇒ 不再进 NC，
            //          否则 9 条会一条条排在同一条队列后面，全部陪葬。
            gNCBusy = YES;          // 置位；块里跑完会清掉。没清掉 ⇒ 8 秒后超时放行
            gNCBusyAt = [NSDate timeIntervalSinceReferenceDate];
            // 🔴 v0.0.65：投递前先把队列身份记下来 —— v0.0.64 就是"投了但块从没被执行"，
            //    而日志里只有「ncQueue=有」，连它是不是 dispatch queue 都看不出来。
            //    `[obj class]` 对任意对象都安全（不碰 dispatch 内部结构），可以放心打。
            NBDiagStep(@"  [NC] 队列身份 %p class=%@ 与BB队列相同=%@\n",
                       (__bridge void *)ncq,
                       ncq ? NSStringFromClass([(id)ncq class]) : @"(nil)",
                       (ncq == gBBServerQueue) ? @"是" : @"否");
            dispatch_async(ncq, ^{
                ncRan = YES;
                NBDiagStep(@"  [NC] 进入 NC 队列\n");

                // --- 只数条数：count 不遍历、不 description ---
                NBDiagStep(@"  [NC] 将要读 bulletinsToUUIDs / uuidsToRequests 的条数\n");
                @try {
                    ncCnt     = NBCollectionCount([gNCSource bulletinsToUUIDs]);
                    ncReqCnt  = NBCollectionCount([gNCSource uuidsToRequests]);
                    ncReqCnt2 = ncReqCnt;
                    ncMeasured = YES;
                    NBDiagStep(@"  [NC] 映射=%ld req数=%ld\n", (long)ncCnt, (long)ncReqCnt);
                } @catch (NSException *e) {
                    NBDiagStep(@"  [NC] 读映射抛: %@\n", e.reason);
                }

                // --- ① NC 侧收「撤回广播」：BBObserverDelegate 那条（v0.0.62 已证**会返回**）---
                // 🔴 v0.0.64 顺序调整：① 挪到 uuid 查询**之前**。
                //    原因：① 是上一版唯一被真机证明「会返回」的 NC 调用；
                //    一旦后面的 uuid 查询卡住，至少 ① 的结果已经落盘了。
                //    上一版把 uuid 查询排在前面 ⇒ 卡住时连 ① 有没有效都不知道。
                NBDiagStep(@"  [NC] 将要调用 observer:removeBulletin:\n");
                if ([gNCSource respondsToSelector:@selector(observer:removeBulletin:)]) {
                    id obs = nil;
                    @try {
                        if ([gNCSource respondsToSelector:@selector(observer)]) obs = [gNCSource observer];
                    } @catch (__unused NSException *e) { }
                    NBDiagStep(@"  [NC] observer=%@\n", obs ? NSStringFromClass([obs class]) : @"(nil)");
                    if (obs) {
                        @try {
                            [gNCSource observer:obs removeBulletin:bullet];
                            if (!winStep) winStep = 1;      // ① 真的跑过了（以前从没赋值 ⇒ 那个分支是死的）
                            NBDiagStep(@"  [NC] ① observer:removeBulletin 已返回\n");
                            @try {
                                ncReqCnt2 = NBCollectionCount([gNCSource uuidsToRequests]);
                            } @catch (__unused NSException *e) { }
                            NBDiagStep(@"  [NC] ① 之后 req数=%ld\n", (long)ncReqCnt2);
                        } @catch (NSException *e) {
                            NBDiagStep(@"  [NC] ① observer:removeBulletin 抛: %@\n", e.reason);
                        }
                    }
                } else {
                    NBDiagStep(@"  [NC] 跳过（没有 observer:removeBulletin:）\n");
                }

                // --- 换 uuid：`_requestUUIDForBulletinPublisherMatchID:`（真机 dump 里有，`@@:@`）
                //     一次调用换一个 uuid，比"遍历 1062 条逐个比对"便宜得多，也不碰 description。
                NBDiagStep(@"  [NC] 将要调用 _requestUUIDForBulletinPublisherMatchID:\n");
                if ([gNCSource respondsToSelector:@selector(_requestUUIDForBulletinPublisherMatchID:)]) {
                    NSArray *tries = @[pubID.length ? pubID : @"",
                                       recID.length ? recID : @"",
                                       cid.length   ? cid   : @""];
                    for (NSString *t in tries) {
                        if (!t.length) continue;
                        @try {
                            id u = [gNCSource _requestUUIDForBulletinPublisherMatchID:t];
                            if (u) {
                                ncUUID = NBClip(u, 120);
                                ncHadUUID = YES;
                                NBDiagStep(@"  [NC] matchID=%@ ⇒ uuid=%@\n", t, ncUUID);
                                break;
                            }
                            NBDiagStep(@"  [NC] matchID=%@ ⇒ (nil)\n", t);
                        } @catch (NSException *e) {
                            NBDiagStep(@"  [NC] matchID=%@ 抛: %@\n", t, e.reason);
                        }
                    }
                } else {
                    NBDiagStep(@"  [NC] 跳过（没有 _requestUUIDForBulletinPublisherMatchID:）\n");
                }

                // --- ② 只接受真 request（⛔ 绝不工厂造：v0.0.62 就是造了假 request 把队列堵死的）---
                // 🔴 v0.0.64：**不再要求先有 uuid**。原来 `ncUUID.length` 是前置条件，
                //    而真机上 uuid 一直是「无」⇒ ② 一次都没进过。
                //    现在的取法有两条，两条拿到的**都是系统造的真对象**：
                //      (a) uuid → uuidsToRequests[uuid]
                //      (b) post 那一刻我们自己缓存的 request（`NCNotificationDispatcher
                //          -postNotificationWithRequest:` 里存下来的，见 NBStashNCRequest）
                //    两条都没有 ⇒ 跳过，绝不自己造。
                if (gNCDispatcher
                    && [gNCDispatcher respondsToSelector:@selector(withdrawNotificationWithRequest:)]) {
                    id ncReq = ncUUID.length ? NBNCRequestForUUID(gNCSource, ncUUID) : nil;
                    NSString *ncReqFrom = ncReq ? @"uuid→uuidsToRequests" : @"(无)";
                    if (!ncReq) {
                        // (b) 缓存后备：拿 cid / recordID / publisherID 三个键去试
                        NSArray *candKeys = @[cid.length ? cid : @"",
                                              recID.length ? recID : @"",
                                              pubID.length ? pubID : @""];
                        for (NSString *k in candKeys) {
                            if (!k.length) continue;
                            id r2 = NBStashedNCRequest(k);
                            if (r2) { ncReq = r2; ncReqFrom = [@"缓存键=" stringByAppendingString:k]; break; }
                        }
                    }
                    ncHadReq = (ncReq != nil);
                    NBDiagStep(@"  [NC] ② uuid=%@ ⇒ request=%@（来源 %@）\n",
                               ncUUID.length ? ncUUID : @"(无)", ncReq ? @"有" : @"无", ncReqFrom);
                    if (!ncReq) {
                        NBDiagStep(@"  [NC] ② 跳过：uuid 映射和本地缓存都没捞到真 request（**不造 request**）\n");
                    } else {
                        NSString *reqSid = NBKVCStr(ncReq, @"sectionIdentifier");
                        NBDiagStep(@"  [NC] ② request 类=%@ section=%@\n",
                                   NSStringFromClass([ncReq class]), reqSid.length ? reqSid : @"(无)");
                        if (reqSid.length && ![reqSid isEqualToString:bundleC]) {
                            NBDiagStep(@"  [NC] ② 跳过：属于 %@ 不是 %@（撤了会误删别人的通知）\n",
                                       reqSid, bundleC);
                        } else {
                            NBDiagStep(@"  [NC] 将要调用 withdrawNotificationWithRequest:\n");
                            @try {
                                [gNCDispatcher withdrawNotificationWithRequest:ncReq];
                                NBDiagStep(@"  [NC] ② withdraw 已返回\n");
                                @try {
                                    ncReqCnt2 = NBCollectionCount([gNCSource uuidsToRequests]);
                                } @catch (__unused NSException *e) { }
                                // ② 比 ① 强 ⇒ **无条件**覆盖（① 已经把 winStep 置成 1 了，
                                // 这里若写 `if (!winStep)` 就永远进不了 2 —— 死分支）
                                winStep = 2;
                                NBDiagStep(@"  [NC] ② 之后 req数=%ld\n", (long)ncReqCnt2);
                            } @catch (NSException *e) {
                                NBDiagStep(@"  [NC] ② withdraw 抛: %@\n", e.reason);
                            }
                        }
                    }
                } else if (!gNCDispatcher) {
                    NBDiagStep(@"  [NC] ② 跳过（没有 dispatcher）\n");
                } else {
                    // 以前这里还有一条 `!ncUUID.length` 的分支 —— 现在 uuid 不再是前置条件，已删
                    NBDiagStep(@"  [NC] ② 跳过（dispatcher 没有 withdrawNotificationWithRequest:）\n");
                }

                ncCnt2 = ncCnt;
                gNCBusy = NO;
                // NC 块活着跑完了 ⇒ 撤掉防卡死标记
                [[NSFileManager defaultManager] removeItemAtPath:kNBGuardPending error:nil];
                NBDiagStep(@"  [guard] NC 块跑完，已删 .nc_pending\n");
                dispatch_async(gBBServerQueue, ^{ bbRemove(); });
            });
        });
    } @catch (NSException *e) {
        NBLog(@"!!! [NC-CLEAR] 回调异常：%@", e);
    }
}

static NSString *NBRecordItem(id obj, NSString *sectionHint, NSString *tag,
                              int *counter, BOOL *firstTime) {
    if (firstTime) *firstTime = NO;
    if (!obj) return nil;

    NSString *bid   = sectionHint.length ? sectionHint : NBSafeStr(obj, @"sectionID");
    NSString *title = NBSafeStr(obj, @"title");
    NSString *msg   = NBSafeStr(obj, @"message");
    NSString *sub   = NBSafeStr(obj, @"subtitle");
    NSDate   *date  = NBSafeDate(obj, @"date");

    // 有的版本 packing 了一层，真正内容在 .bulletin 里
    if (!bid.length || (title.length == 0 && msg.length == 0)) {
        id inner = NBSafeValue(obj, @"bulletin");
        if (inner && inner != obj) {
            if (!bid.length)   bid   = NBSafeStr(inner, @"sectionID");
            if (!title.length) title = NBSafeStr(inner, @"title");
            if (!msg.length)   msg   = NBSafeStr(inner, @"message");
            if (!sub.length)   sub   = NBSafeStr(inner, @"subtitle");
            if (!date)         date  = NBSafeDate(inner, @"date");
        }
    }
    // v0.0.54：**两个候选 ID 都读、都存**（清除时都试）。
    // 🔴 v0.0.53 真机结论：`_clearBulletinIDs:` 能调、不抛，但通知没消失；且
    //    `_bulletinIDsForSectionID:` / `bulletinIDsForSectionID:` 在 iOS 16 **都不存在**
    //    ⇒ 无法靠枚举反查。所以改成"两个候选都留一手"：
    //    - bulletinID           = BB 自己的 bulletin 标识（清除 API 最可能要这个）
    //    - notificationIdentifier = UNNotificationRequest 的标识
    //    两个都非空且不同 ⇒ 存成 "bID|nID"，清除时逐个试（见 NBClearNCCallback）。
    NSString *bID = NBSafeStr(obj, @"bulletinID");
    NSString *nID = NBSafeStr(obj, @"notificationIdentifier");
    {
        id inner2 = NBSafeValue(obj, @"bulletin");
        if (inner2 && inner2 != obj) {
            if (!bID.length) bID = NBSafeStr(inner2, @"bulletinID");
            if (!nID.length) nID = NBSafeStr(inner2, @"notificationIdentifier");
        }
    }
    NSString *sysId = nil;
    if (bID.length && nID.length && ![bID isEqualToString:nID]) {
        sysId = [NSString stringWithFormat:@"%@|%@", bID, nID];
    } else if (bID.length) {
        sysId = bID;
    } else {
        sysId = nID;
    }
    // v0.0.54 诊断：只前 5 条打一次 ID 来源（不刷屏）。看清 bulletinID / notificationIdentifier
    //   到底哪个有值、是否相同 —— 这是判断"存的 ID 对不对"的唯一直接证据。
    {
        static int gIdLog = 0;
        if (gIdLog < 5) {
            gIdLog++;
            NBLog(@"[NC-ID#%d] cls=%@ bID=%@ nID=%@ 存=%@", gIdLog, NBClassName(obj),
                  bID.length ? bID : @"(nil)", nID.length ? nID : @"(nil)", sysId ?: @"(nil)");
        }
    }

    // 有些 wrapper 用 bulletinID / requestID 之类的键放 section；读不到就只报诊断
    if (!bid.length) {
        if (*counter < 6) {
            (*counter)++;
            NBLog(@"%@#%d 没有 bundle，cls=%@ title=%@", tag, *counter, NBClassName(obj),
                  title.length ? title : @"(nil)");
        }
        return nil;
    }

    // v0.0.51：连记录都不要（per-App 名单）—— 命中的 App 不落库，但**不影响呈现**
    //    （过滤/替换/换声/朗读照跑，通知照弹；这个开关只掐"记"这一路）。
    // 🔴 摆在 NBClaimKey **之前**：没记的东西不该占去重表的名额；另两个入口还会
    //    走到这儿，让它们也过同一条闸门，三个入口行为一致。
    // 🔴 返回 bid 而不是 nil：调用方拿它做下游过滤判定，呈现层必须照常工作。
    // 🔴 与黑名单的分工：黑名单拦"呈现"（记录已落库、盒子里仍看得到，v0.0.8 口径），
    //    这里拦"记录"本身——用户要的是"这个 App 别在我盒子里留任何痕迹"。
    if ([NotifyFilter shouldSkipRecordForBundle:bid]) return bid;

    NSString *key = [NSString stringWithFormat:@"%@|%@|%@", bid, title ?: @"", msg ?: @""];
    if (!NBClaimKey(key)) {
        // 🔴🔴 v0.0.85：**"已经被记过"不等于"已经记好了"**。
        //   同一条通知会经过三个入口，谁先到谁记录；先到的那个可能还没拿到
        //   `bulletinID`（系统在 publish 过程中才分配）⇒ 那一行 `sys_id` 空着
        //   ⇒ 以后永远删不掉通知中心里那条（真机表现就是「提示通知不会变」）。
        //   后到的入口手里有 ID，却正是被这一行 return 挡掉的 ⇒ 在这里把 ID 补写回去。
        //   🔴 只在**这次拿到 ID** 时才补；补写自带三条护栏（只改空 sys_id / 只改最近一行 /
        //      查 changes）和 600 秒窗口，见 NotifyStore.m 的 backfillSysId。
        if (sysId.length) {
            NSInteger bf = [NotifyStore backfillSysId:sysId bundle:bid title:title message:msg];
            if (bf > 0) {
                // 只在前 3 次打，避免热路径刷屏（这条路径每条通知都会走两次）
                static int gBfLog = 0;
                if (gBfLog < 3) { gBfLog++; NBLog(@"[补ID#%d] tag=%@ bundle=%@ ⇒ 补上 1 行", gBfLog, tag, bid); }
            }
        }
        return bid;      // 已被另一个入口记过；bundle 仍有效
    }

    // 🔴 v0.0.85：记录侧自证 —— 走到这里说明**这条真落库了**，那就必须知道它有没有 ID。
    //   真机 `[重]` 行报过 `无 sysId 221 行`，而用户说「有些**刚推送**的也会提示通知不会变」
    //   ⇒ 这批空 ID 的行到底是不是老记录，只能在这里量。
    //   🔴 上限 8 条/进程：这个函数在 publish 热路径上，diag 是**无条件追加文件**的。
    //   🔴 必须先问 `NBDiagReady()`（文件存在）：`NBDiagAppend` 在文件不存在时会**自己新建**它，
    //      而「方法表只写一次」的判据正是「文件不存在」⇒ 让它新建就等于把方法表永久弄丢（v0.0.73 的坑）。
    if (!sysId.length) {
        static int gNoIdLog = 0;
        if (gNoIdLog < 8 && NBDiagReady()) {
            gNoIdLog++;
            NBDiagStep(@"[无ID#%d] tag=%@ cls=%@ bundle=%@ bID=%@ nID=%@ title=%@\n",
                       gNoIdLog, tag, NBClassName(obj), bid,
                       NBSafeClip(bID, 40), NBSafeClip(nID, 40), NBSafeClip(title, 30));
        }
    }

    if (firstTime) *firstTime = YES;       // 🔴 只有走到这里才算"首次"

    if (*counter < 10) {
        (*counter)++;
        NBLog(@"%@#%d bundle=%@ title=%@ msg=%@",
              tag, *counter, bid,
              title.length ? title : @"(nil)",
              msg.length ? (msg.length > 40 ? [[msg substringToIndex:40] stringByAppendingString:@"..."] : msg) : @"(nil)");
    }
    [NotifyStore recordWithBundle:bid title:title message:msg subtitle:sub date:date sysId:sysId];
    return bid;
}

// ---------- 流水线结论 ----------
// 🔴 v0.0.14：原来返回 BOOL，只能表达「拦不拦」。延迟推送要表达「放行，但晚 N 秒」，
//    一件事变两个维度 ⇒ 换成结构体。
//    ⚠️ ARC 禁止结构体持有 ObjC 对象指针，所以 bundle **不进结构体**；
//    需要 bundle 的日志一律在 NBPipeline 内部就打掉。
// 🔴 v0.0.19：删掉了 delay 字段。理由见 NotifyFilter.h 顶部那条长注释 ——
//    延迟这件事两次撞死（跨队列 SIGTRAP / 改时间字段导致通知全不弹），
//    功能已整体删除。**结构体里留一个永远为 0 的字段是最坏的做法**：
//    它会让后来的人以为"这条链路是通的，只是没启用"。
typedef struct {
    BOOL allow;              // NO ⇒ 调用点不要执行原方法（被过滤掉）
} NBDecision;

static NBDecision NBAllowNow(void) { NBDecision d; d.allow = YES; return d; }
static NBDecision NBDeny(void)     { NBDecision d; d.allow = NO;  return d; }

// ---------- 记录 + 过滤流水线（三入口共用） ----------
// 返回 allow=NO ⇒ 调用点**不要执行原方法**，等于把这条通知拦下来（盒子里仍然查得到）。
// 返回 delay>0 ⇒ 调用点延后这么久再执行原方法。
// 🔴 整段 @try：这段跑在 SpringBoard 里，抛一个异常就是用户眼里的闪退 / 进安全模式。
// 🔴 顺序讲究：**先记录原文 → 再判定过滤（用原文判）→ 最后才做内容替换**。
//    若先替换再判定，用户配了「把"红包"替换成空」又同时过滤"红包"时，过滤会永远不命中。
static NBDecision NBPipeline(id obj, NSString *sectionHint, NSString *tag, int *counter) {
    // ① 记录（原文；被过滤也留档，方便回头查「本来要推什么」）
    BOOL firstTime = NO;
    NSString *bid = NBRecordItem(obj, sectionHint, tag, counter, &firstTime);
    if (!bid.length) return NBAllowNow();   // 认不出是哪个 App ⇒ 绝不拦

    NBDecision out = NBAllowNow();          // 🔴 初值就是"立即放行"：异常兜底 = 不改变行为

    @try {
        // ①.5 只读探针（v0.0.13）：量 BBBulletin 的 sound/alertType 等量，
        //     为下一版「按 App 换提示音」取数。内部自己限流（只前 3 条、且只 dump 一次）。
        //     🔴 放在过滤判定**之前**：我要的是"原始对象长什么样"，
        //        不能等替换改过字段之后再量。
        if (firstTime) [NotifyProbe probeBulletin:obj tag:tag];

        // ①.6 v0.0.16：BBServer 队列情报，只跑一次（只读）。
        //     🔴 必须放在**这里**而不是构造函数里：构造阶段 BulletinBoard 还没加载，
        //        objc_getClass("BBServer") 拿到 nil。放这里才能拿到真实数据，
        //        而且此刻我们正站在 BB 的调用队列上 —— 队列标签才有意义。
        [NotifyProbe dumpServerQueueOnce];

        NSString *t = NBSafeStr(obj, @"title");
        NSString *m = NBSafeStr(obj, @"message");
        NSString *s = NBSafeStr(obj, @"subtitle");

        // ② 拦截判定（用原文）
        if ([NotifyFilter shouldDropBundle:bid title:t message:m subtitle:s]) {
            gDropped++;
            // 前 8 条全记（方便确认到底拦了什么），之后每 50 条记一次（不刷爆日志）
            if (gDropped <= 8 || (gDropped % 50) == 0) {
                NBLog(@"DROP#%d bundle=%@ tag=%@ title=%@",
                      gDropped, bid, tag, t.length ? t : @"(nil)");
            }
            // 🔴🔴 被拦下的通知**不朗读**。
            //    「别烦我」是用户配这条规则的全部意图 —— 屏幕上不弹、耳朵里却念出来，
            //    那是最糟的组合：既没躲开，还更吵。所以朗读只能在 drop 判定之后。
            return NBDeny();
        }
        // ②.5 免打扰时段（v0.0.21）
        //
        // 这是 v0.0.19 删掉「延迟推送」之后给的安全替代：
        // 延迟要达成的是"别在这个时间吵我"，而它必须**改系统发布时间**才能实现
        // （两次撞死：跨队列 SIGTRAP / 通知永远到不了）；这里只是**我们自己不弹**，
        // 不碰 BB 内部、不改任何系统字段 ⇒ 从根上没有那两类风险。
        //
        // 🔴 被免打扰拦下的通知**不朗读、不换音**（和黑名单同一个语义）：
        //    「别吵我」是用户配这条规则的全部意图，屏幕上不弹、耳朵里却念出来是最糟的组合。
        NSString *dndWhy = nil;
        if ([NotifyFilter shouldDropForDND:bid now:nil reason:&dndWhy]) {
            gDndDropped++;
            if (gDndDropped <= 8 || (gDndDropped % 50) == 0) {
                NBLog(@"DND#%d bundle=%@ tag=%@ 时段=%@ ⇒ 不弹（仍记进盒子）",
                      gDndDropped, bid, tag, dndWhy ?: @"?");
            }
            return NBDeny();
        }

        // ③ 内容替换（只改呈现，库里留着原文）
        //
        // 🔴 这里必须留痕：替换是"静默"的 —— 配了规则没生效，界面上完全看不出来。
        //    若日志里从来没有 REPL 行，只有两种可能：①没配规则 ②入口传进来的对象
        //    没有 setTitle:/setMessage:（request 包装类常见）⇒ 是"对象不对"，不是"规则没读到"。
        //    这两种病因必须能分开，否则又是一轮盲猜。
        BOOL replaced = [NotifyFilter applyReplaceRulesTo:obj];
        if (replaced) {
            gReplaced++;
            if (gReplaced <= 8 || (gReplaced % 50) == 0) {
                NBLog(@"REPL#%d bundle=%@ tag=%@ cls=%@",
                      gReplaced, bid, tag, NBClassName(obj));
            }
        }

        // ④.4 v0.0.22 只读诊断：如果这个对象身上已经带了一个**系统给的** sound，
        //     立刻整份 dump（全进程只一次）。
        //     🔴 必须在 ④.5 **之前**：挂完之后再看，就分不清是"系统给的"还是"我们挂的"，
        //        而这两者的字段值正是这一轮唯一能抄到正确答案的来源。
        [NBSoundDiag noteForeignSoundIfAny:obj stage:tag];

        // ④.5 按 App 换提示音 —— 🔴 v0.0.25 起**不在这里做了**。
        //
        //    这里原来干的是「alloc 一个 BBSound、填字段、setValue:forKey:@"sound"」，
        //    也就是**造系统对象**。v0.0.21~v0.0.24 四个版本下来确认了三件事：
        //      · 造对了不一定响（字段都对，仍然一声不出）；
        //      · 造错了**整条通知变哑**（v0.0.21 实测，用户直接漏消息）；
        //      · `BBSound` 上**连 bundle id 都没有** ——"按 App 换音"这件事在这里无从下手。
        //    v0.0.25 把动手的位置搬到 `SBNCSoundController -canPlaySoundForNotificationRequest:`
        //    （通知音的**总闸门**，见本文件末尾的 GSC 组）。
        //
        //    ⇒ 这段说明留着而不是删干净，是因为「为什么不在 publish 点动手」本身是结论：
        //      **拦在"要播声音"的那一刻，比拦在"造声音对象"的那一刻更靠下游**，
        //      而下游 = 更接近最终判定 = 更不容易被后续链路覆盖（本项目吃过太多次亏）。

        // ⑤ 朗读（v0.0.13）
        //
        // 🔴 只在 firstTime 做：三个入口会依次触发，不判首次就会把同一句话读三遍。
        // 🔴 读**替换后**的文字：替换规则的意义就是"让这条通知说人话"，
        //    屏幕上改干净了、耳朵里还在念原来的骚扰词，等于只做了一半。
        //    替换失败时退回原文（replaced==NO 就不重读，省两次 KVC）。
        // 🔴 朗读**不跟着延迟**：延迟改的是"弹窗什么时候出现"，朗读是即时播报。
        //    两者同时开着时，用户会先听到、N 秒后才看到。设置页里写明了这一点。
        //    不做成"一起延后"是刻意的：朗读是刚在真机上验证过的功能，
        //    不想为了组合场景去动它的调用路径。
        if (firstTime) {
            NSString *st = t;
            NSString *sm = m;
            if (replaced) {
                NSString *x = NBSafeStr(obj, @"title");
                NSString *y = NBSafeStr(obj, @"message");
                if (x) st = x;
                if (y) sm = y;
            }
            if ([NotifySpeaker shouldSpeakBundle:bid title:st message:sm]) {
                [NotifySpeaker speakWithBundle:bid title:st message:sm];
            }
        }
    } @catch (__unused NSException *e) {
        // 兜底一律放行：宁可多推一条，也不要把通知吞掉
        return NBAllowNow();
    }
    return out;
}

// ---------- 入口 1：- publishBulletin:destinations: ----------
%group GPB
%hook BBServer
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations {
    NBCaptureServerIfNeeded(self);   // v0.0.52：捕获 BBServer 实例 + 队列（同步清通知中心用）
    NBDecision d = NBPipeline(bulletin, nil, @"PB", &gHit1);
    if (!d.allow) return;
    %orig(bulletin, destinations);
    // 🔴 v0.0.22：必须在 orig **之后**读 —— 要看的正是"系统处理完之后 sound 还在不在"。
    //    只在目标 App 输出（内部判），不会刷屏。
    [NBSoundDiag probeAfterPublish:bulletin stage:@"PB"];
}
%end
%end

// ---------- 入口 2：- publishBulletinRequest:destinations: ----------
%group GPBR
%hook BBServer
- (void)publishBulletinRequest:(id)request destinations:(unsigned long long)destinations {
    NBCaptureServerIfNeeded(self);   // v0.0.52：捕获 BBServer 实例 + 队列（同步清通知中心用）
    NBDecision d = NBPipeline(request, nil, @"PBR", &gHit2);
    if (!d.allow) return;
    %orig(request, destinations);
    [NBSoundDiag probeAfterPublish:request stage:@"PBR"];
}
%end
%end

// ---------- 入口 3：- _publishBulletinRequest:forSectionID:forDestinations: ----------
// 🔴 注意前导下划线，v0.0.3 就是漏了它才判 NO
%group GPBRS
%hook BBServer
- (void)_publishBulletinRequest:(id)request
                   forSectionID:(id)sectionID
                forDestinations:(unsigned long long)destinations {
    // 第二个参数按 ENC 是 @（对象），本身就是 sectionID，直接当 bundle 用最可靠
    NSString *sid = [sectionID isKindOfClass:[NSString class]] ? (NSString *)sectionID : nil;
    NBCaptureServerIfNeeded(self);   // v0.0.52：捕获 BBServer 实例 + 队列（同步清通知中心用）
    NBDecision d = NBPipeline(request, sid, @"PBRS", &gHit3);
    if (!d.allow) return;
    %orig(request, sectionID, destinations);
    [NBSoundDiag probeAfterPublish:request stage:@"PBRS"];
}
%end
%end


// ---------- v0.0.72：观测「把删除广播给 observer（NC）」的那一跳 ----------
// 🔴 为什么非要这一条：v0.0.72 的新刀（`removeBulletinID:…`）和 ⓪（`withdrawBulletinRequests…`）
//    外形很像 —— 都是"把 BB 账本里那一条拿掉"。两者的**唯一实质区别**在于
//    **拿掉之后有没有通知观察者**。没有这一跳，界面永远不动，而账本早就干净了
//    （32 条老刀的失败原因全收敛到这一点）。
// 🔴 所以这条 hook 是**只读观测**：计数 + 少量日志，原样透传，绝不改参数、绝不吞调用。
// 🔴 日志必须**带上限**（≤20 条）：NBDiagStep 是**无条件追加**文件的，
//    而这个方法在整个 SpringBoard 生命周期里会被系统自己调很多次，
//    不限量就等于拿诊断文件刷屏（并且把真正的删除记录挤出日志窗口）。
%group GOBSREM
%hook BBServer
- (void)_sendRemoveBulletin:(id)bulletin toFeeds:(unsigned long long)feeds shouldSync:(BOOL)sync {
    gBBSendRemoveSeen++;
    if (gBBSendRemoveSeen <= 40 && NBDiagReady()) {
        // 🔴 只读**已知安全**的 KVC 键。⛔ 绝不对 bulletin 调 description
        //    （v0.0.63 真机 9/9 全灭就是因为它会摸内部锁）。
        NBDiagStep(@"  [OBS-rem] _sendRemoveBulletin 第 %d 次 feeds=%llu sync=%d section=%@ recordID=%@ bulletinID=%@（此时 ⑤ 新刀成功 %d 次）\n",
                   gBBSendRemoveSeen, feeds, (int)sync,
                   NBClip(NBKVCStr(bulletin, @"sectionID"), 30),
                   NBClip(NBKVCStr(bulletin, @"recordID"), 40),
                   NBClip(NBKVCStr(bulletin, @"bulletinID"), 40),
                   gBBRemoveByIDOk);
    }
    %orig;
}
// ---- v0.0.76：复数版（批量投递）只读观测 ----
// 要回答的问题：v0.0.75 真机里 ⓪ 撤回的两条，`[BB→NC]` 回调**晚了 65 秒**才到，
//   而且是 8 条挤在同一秒。若这里（复数版）被调，说明 BB 把多个 removal 攒成一批再投；
//   全程 0 次则说明是别的节流 —— 两种结果都能把下一步钉死。
- (void)_sendRemoveBulletins:(id)bulletins toFeeds:(unsigned long long)feeds shouldSync:(BOOL)sync {
    gBBSendRemoveManySeen++;
    if (gBBSendRemoveManySeen <= 10 && NBDiagReady()) {
        NBDiagStep(@"  [OBS-rem] _sendRemoveBulletins(复数) 第 %d 次 feeds=%llu sync=%d 条数=%ld\n",
                   gBBSendRemoveManySeen, feeds, (int)sync, (long)NBCollectionCount(bulletins));
    }
    %orig;
}
%end
%end

// ---------- v0.0.73：CoverSheet 目的地（CSNotificationDispatcher）侧的**只读**观测 ----------
// 🔴 为什么必须有这一组（这是本版的主判据，不是"顺手加的探针"）：
//    v0.0.72 真机 `nc_diag(12).txt` 把链路切成了三段，每段都实测：
//      ① ⑤ 新刀三条候选**广播出去了**（`_sendRemoveBulletin` 1→4），但**账本没动**（BB live 恒=2）；
//      ② ⓪ 官方撤回**把账本清干净了**（live 2→1、含本条=否）；
//      ③ 可 `系统自己传给 NC` 仍然是 **0 次** ⇒ 界面照旧。
//    ⇒ 结论：从"账本"到"界面"这一跳**不走 observer 广播**。那么界面到底是靠谁掉的？
//    唯一可靠的回答方式不是继续猜 API，而是 —— **让用户手动清一条，看系统调了哪一把**。
//    （本项目铁律：判据 = 系统自己走的时候调了哪一把，不是我们觉得哪一把该被调。）
// 🔴 全是只读：计数 + 有限行日志，`%orig` 原样透传。
// 🔴 除了 `postNotificationRequest:` 之外都限 6 行日志；`postNotificationRequest:` 是
//    **存活对照**（它一定频繁触发 ⇒ 计数涨就证明这组 hook 真的挂上了，不是"没触发"）。
%group GCSD
%hook CSNotificationDispatcher
- (void)postNotificationRequest:(id)request {
    gCSDPost++;
    %orig;
}
- (void)withdrawNotificationRequest:(id)request {
    gCSDWithdraw++;
    if (gCSDWithdraw <= 6 && NBDiagReady()) {
        NBDiagStep(@"  [OBS-cs] withdrawNotificationRequest: 第 %d 次 section=%@ nid=%@\n",
                   gCSDWithdraw,
                   NBSafeClip(NBKVCStr(request, @"sectionIdentifier"), 30),
                   NBSafeClip(NBKVCStr(request, @"notificationIdentifier"), 50));
    }
    %orig;
}
- (void)destination:(id)destination clearNotificationRequests:(id)requests {
    gCSDClear++;
    if (gCSDClear <= 6 && NBDiagReady()) {
        NBDiagStep(@"  [OBS-cs] destination:<%@> clearNotificationRequests: 第 %d 次 %ld 条\n",
                   NBClassName(destination), gCSDClear, (long)NBCollectionCount(requests));
    }
    %orig;
}
- (void)destination:(id)destination clearNotificationRequestsInSections:(id)sections {
    gCSDClearSec++;
    if (gCSDClearSec <= 6 && NBDiagReady()) {
        NBDiagStep(@"  [OBS-cs] destination:<%@> clearNotificationRequestsInSections: 第 %d 次 %ld 个段\n",
                   NBClassName(destination), gCSDClearSec, (long)NBCollectionCount(sections));
    }
    %orig;
}
- (void)destination:(id)destination clearNotificationRequestsFromDate:(id)fromDate
                                                                toDate:(id)toDate
                                                            inSections:(id)sections {
    gCSDClearRng++;
    if (gCSDClearRng <= 6 && NBDiagReady()) {
        NBDiagStep(@"  [OBS-cs] destination:<%@> clearNotificationRequestsFromDate:toDate:inSections: 第 %d 次 %ld 个段\n",
                   NBClassName(destination), gCSDClearRng, (long)NBCollectionCount(sections));
    }
    %orig;
}
- (void)_clearNotificationRequestsFromIncomingSection:(id)section {
    gCSDIncoming++;
    if (gCSDIncoming <= 6 && NBDiagReady()) {
        NBDiagStep(@"  [OBS-cs] _clearNotificationRequestsFromIncomingSection: 第 %d 次 %@\n",
                   gCSDIncoming, NBSafeClip(NBKVCStr(section, @"sectionIdentifier"), 30));
    }
    %orig;
}
- (BOOL)dismissNotificationInLongLookAnimated:(BOOL)animated {
    gCSDDismiss++;
    if (gCSDDismiss <= 6 && NBDiagReady()) {
        NBDiagStep(@"  [OBS-cs] dismissNotificationInLongLookAnimated: 第 %d 次\n", gCSDDismiss);
    }
    return %orig;
}
%end
%end

// 🔴 v0.0.25：SBNCSoundController 的**前向声明**。
//
// 为什么写它：Logos 在 %hook 里生成的函数签名，self 的类型取决于 Logos 版本/配置
// （本项目 `%hook BBServer` 一直不声明也能编过，说明走的是 id）。
// 多一个纯声明是零成本的：编过了就等于保险，编不过就说明这个类名得让编译器知道 ——
// 而"unknown type name"这种报错一轮 CI 就没了，不值得赌。
// ⚠️ 这个类**可能根本不存在**（名字来自外部参考）。声明只是编译期的东西，
//    运行时能不能拿到由 %ctor 里的 objc_getClass 决定，拿不到就不 %init。
@interface SBNCSoundController : NSObject
- (BOOL)canPlaySoundForNotificationRequest:(id)request;
@end

// ---------- v0.0.25：按 App 换提示音 · **新挂点** ----------
//
// 🔴🔴 为什么整段换掉旧做法：
//    v0.0.21~v0.0.24 一直在 BulletinBoard 的 `BBSound` 上手工拼字段 ——
//    那是"造系统对象"，实测造错就**整条通知变哑**，而且 BBSound 上**连 bundle id 都没有**，
//    "按 App" 只能靠外层传参凑。
//    `SBNCSoundController -canPlaySoundForNotificationRequest:` 是通知音的**总闸门**
//    （返回 BOOL 的最终判定），参数就是通知请求，自带 sectionIdentifier。
//    参考实现见 docs/换提示音-外部插件调研.md（SilentNotifs 就挂这同一个方法实现"静音通知音"）。
//
// 流程一句话：**先把我们的声音送出去，送成功了才让系统别播**。
// 顺序反过来（先掐再播）就是"播失败 ⇒ 哑巴"，所以返回契约在 NotifyFilter.h 里写死了。
//
// ⚠️ 这个类/方法名来自外部参考（iOS 14.8 / 16.4.1 实测可用），**本机还没验证**。
//    所以 %ctor 里先用 class_copyMethodList 确认它存在、名字对得上，再 %init ——
//    不存在就一个 hook 都不挂，通知照旧原声（绝不因为"我以为有"而变哑）。
%group GSC
%hook SBNCSoundController
- (BOOL)canPlaySoundForNotificationRequest:(id)request {
    // 🔴 这是系统最热的一条路之一，**任何异常都必须吃掉**：
    //    抛出去轻则这条通知不出声，重则崩 SpringBoard。
    @try {
        // 用 KVC 而不是点语法：这个类是靠 objc_getClass 拿的，没有编译期类型可依赖。
        NSString *bid = nil;
        @try {
            id s = [request valueForKey:@"sectionIdentifier"];
            if ([s isKindOfClass:[NSString class]]) bid = (NSString *)s;
        } @catch (__unused NSException *e) {
            bid = nil;          // 读不到 bundle id 就当"没配"，放原声
        }

        // 🔴🔴 去重：同一条通知可能在**锁屏 + 横幅**两处各问一次"要不要出声"。
        //    不判重就是同一个音**连响两遍** —— 用户的第一句反馈必然是"响两次"。
        //    只在能拿到 notificationIdentifier 时才去重：拿不到就**不去重**。
        //    理由：没有唯一 ID 时只能按时间窗猜，而"同一个 App 紧接着发的第二条真通知"
        //    会被那个窗误吞（少响一次）。⇒ **宁可偶尔响两遍，也不要吞掉一条真通知。**
        NSString *nid = nil;
        @try {
            id v = [request valueForKey:@"notificationIdentifier"];
            if ([v isKindOfClass:[NSString class]]) nid = (NSString *)v;
        } @catch (__unused NSException *e) {
            nid = nil;
        }

        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        static NSString *gLastNid = nil;
        static NSTimeInterval gLastNidAt = 0;
        if (nid.length && gLastNid.length
            && [nid isEqualToString:gLastNid] && (now - gLastNidAt) < 2.0) {
            return NO;          // 这条已经响过了 ⇒ 只掐原声，不再播第二遍
        }

        NSString *sres = nil;
        if ([NotifyFilter playCustomSoundForBundle:bid forResult:&sres]) {
            // 🔴 记 nid 必须在**播成功之后**。写在播之前的话，第一次播失败时
            //    这条 nid 也会被记上 ⇒ 第二次调用就直接 return NO ⇒ 原声被掐 + 我们没响
            //    = **哑巴**。这个顺序和"先播再掐"是同一条道理的另一面。
            if (nid.length) {
                gLastNid = nid;
                gLastNidAt = now;
            }
            gSoundApplied++;
            // 限流：前 8 次 + 每 50 次一条。日志窗口约 50 行、全局滚动，不许刷屏。
            if (gSoundApplied <= 8 || (gSoundApplied % 50) == 0) {
                NBLog(@"SOUND#%d 闸门掐掉原声 bundle=%@ %@",
                      gSoundApplied, bid ?: @"?", sres ?: @"?");
            }
            return NO;          // 🔴 我们的音已经送出去了 ⇒ 别让系统再播一遍（否则双响）
        }
    } @catch (__unused NSException *e) {
        // 我们自己出错 ⇒ 一律退回系统判断。绝不因为我的 bug 让用户漏消息。
    }
    @try {
        return %orig;
    } @catch (__unused NSException *e) {
        return YES;             // 系统自己抛 ⇒ 放行（默认允许播，比静音安全）
    }
}
%end
%end

// ---------- v0.0.58：捕获 NC 派发器与 request（只为"删除"这一路服务，纯透传） ----------
// 🔴 为什么非要 hook：真机清单里 `NCNotificationDispatcher` 写着 `+ 无方法(共0)`
//    —— 它**没有任何类方法**，拿不到 sharedInstance；实例只能在别人创建/调用它时抓。
//    `NCBulletinNotificationSource - initWithDispatcher:observer:queue:` 正好把 dispatcher 递过来。
// 🔴 两个 hook **都只做「记下现场 + 调 %orig」**，不改任何行为 ⇒ 不影响通知正常显示。
%group GNC
%hook NCBulletinNotificationSource
- (id)initWithDispatcher:(id)dispatcher observer:(id)observer queue:(id)queue {
    id r = %orig;
    if (r) {
        gNCSource = r;
        gNCDispatcher = dispatcher;
        // 🔴 v0.0.64：这条 queue 是关键 —— 系统平时就在它上面回调 source。
        //    NC 的删除动作必须回到这条队列上执行（v0.0.61 在 BB 队列上调用 ⇒ 卡死注销）。
        gNCSourceQueue = (dispatch_queue_t)queue;
        NBLog(@"=== [v%@] 捕获 NC source，dispatcher=%@ queue=%@", NB_VER_STR,
              dispatcher ? NSStringFromClass([dispatcher class]) : @"(nil)",
              queue ? @"有" : @"(nil)");
    }
    return r;
}
// ---------- 🔴🔴 v0.0.82：映射「重建 / 修改」这两条路（⑦u 摘映射唯一的推翻者）----------
// 🔴 为什么非查不可（`paste_1030.txt`）：⑦u 摘掉映射之后，同一次块里紧接着量到的「同段」
//    从 68 跳到 99 —— **正好等于 BB 在该段的 live 条数**，而总数只掉了 1。
//    ⇒ 系统会把映射**从 BB 重建**一遍，而这条路**不走 `addBulletin`**
//      ⇒ `[RE] 加回=0` 覆盖不到它。**没看到加回 ≠ 没被加回。**
// ⇒ 这两条 hook 只做三件事：无条件 ++、命中台账才打一行、原样 %orig。
// 🔴 只读 bulletinID / recordID / publisherBulletinID / sectionID / sectionIdentifier
//    这几个已知字符串键 —— **绝不打印对象 description**（BBBulletin 会摸内部锁 ⇒ 卡死）。
- (void)observer:(id)observer noteBulletinsLoadedForSectionID:(id)sectionID {
    gNoteLoadedSeen++;
    // 🔴 v0.0.83：**无条件**进环形缓冲，不再看 `NBDiagReady()`。
    //    v0.0.82 的教训：242 次重载、**0 行日志** —— 这正是「必须拿到手的记录
    //    挂在可能不发生的事件上」。改成常驻记录，到 ⑦ 段（那时诊断文件一定在）补打。
    @try {
        NSString *sec = nil;
        if ([sectionID isKindOfClass:[NSString class]]) sec = (NSString *)sectionID;
        else sec = NBKVCStr(sectionID, @"sectionIdentifier");
        NBRingPush(sec);
    } @catch (__unused NSException *e) { }
    %orig;
}
- (void)observer:(id)observer modifyBulletin:(id)bulletin forFeed:(unsigned long long)feed {
    gModifySeen++;
    @try {
        if (gNCSource && NBDiagReady()) {
            NSString *bid = NBKVCStr(bulletin, @"bulletinID");
            NSString *rid = NBKVCStr(bulletin, @"recordID");
            NSString *pid = NBKVCStr(bulletin, @"publisherBulletinID");
            double age = NBDeletedAgeFor(bid, rid, pid);
            if (age >= 0 && age <= 600) {
                gModifyHit++;
                if (gModifyHit <= 20) {
                    NBDiagStep(@"  [RM] ⚠️ modifyBulletin 第 %d 次 @%@ section=%@ bulletinID=%@ recordID=%@"
                               @"（命中 %.0fs 前删过的那条）\n",
                               gModifySeen, [NSDate date], NBKVCStr(bulletin, @"sectionID"),
                               NBSafeClip(bid, 40), NBSafeClip(rid, 44), age);
                }
            }
        }
    } @catch (__unused NSException *e) { }
    %orig;
}
// ---------- 🔴🔴 v0.0.65：观测「系统会不会自己把 BB 撤回传到 NC 侧」 ----------
// ⓪ 已经证明能把 BB 账本清干净（v0.0.64 真机 5/5）。接下来唯一的问题是：
//   **系统有没有把这个撤回转给 NC？**（NC 才是界面）
// 这条 hook 就是那个问题的答案，纯观测 + 原样透传。
// 🔴 它跑在 **NC 自己的队列**上（系统调它就在那条队列）——
//    正好绕开「我们投不进那条队列」的缺口：让系统自己在正确的队列上把现场打出来。
// 🔴 为什么要带 `⓪已成功 N 次`：把两边时间对齐。如果每次 ⓪ 之后紧跟一条
//    `[BB→NC] …（此时⓪已成功 k 次）`，就说明**链路是通的，界面本该变**；
//    如果 ⓪ 成功了很多次而这里一条都没有，就说明**BB 的撤回根本没到 NC**，得换路。
- (void)observer:(id)observer removeBulletin:(id)bulletin {
    gBBToNCSeen++;
    // 🔴 v0.0.78：⑧ 删掉之后，这条 hook 上**只可能**是系统自己调的 ⇒ 那两行区分
    //   「我方投递 / 系统自己」的分支（`gSelfPostingRemove`）一起删。
    //   留着不删的坏处：下一轮看到「我方投递」会以为 ⑧ 还在（死分支恒假 = 假绿的 ⑧ 型）。
    if (gBBToNCSeen <= 60) {
        NBDiagStep(@"  [BB→NC] 系统自己调用 observer:removeBulletin: 第 %d 次 @%@ recordID=%@（此时⓪已成功 %d 次）\n",
                   gBBToNCSeen, [NSDate date], NBKVCStr(bulletin, @"recordID"), gBBWithdrawOk);
    }
    %orig;
}
// 🔴 v0.0.66：这条才是"请求清除"在 source 侧的那一跳。
//   dispatcher 收到目的地的清除请求后，会把它转给 source，由 source 把 NC request 翻成 bulletin
//   再交给 BBServer 去 withdraw。**用户手动清一条时它应该会响** —— 如果不响，
//   就说明手动清除根本不经过 BB，那我们的 ⓪ 也就注定不会改变界面。
- (void)dispatcher:(id)dispatcher requestsClearingNotificationRequests:(id)requests {
    gObsSrcClear++;
    if (gObsSrcClear <= 6) {
        NBDiagStep(@"  [OBS] source dispatcher:requestsClearing…（第 %d 次，%ld 条）\n",
                   gObsSrcClear, (long)NBCollectionCount(requests));
        // 🔴 v0.0.67：上一版只打条数（每次都是"2 条"）⇒ 根本不知道清的是谁。
        //    这次把每条的 section/nid 打出来 —— 只要有一次 section 是我们这条 App，
        //    就说明系统确实会清它，问题只在"谁去触发"。
        NBLogRequests(@"OBS-src", requests, 4);
    }
    // 🔴 这里跑在**系统自己的 NC 队列**上 ⇒ 读映射是安全的（不另投队列，也不重入）。
    //    上一版一直想"投进这条队列"，其实不用投：让系统自己把我们带进来就行。
    if (!gMapDumped && self) {
        gMapDumped = YES;
        NBMapCensus(self);
    }
    if (!gFoundNCReq && gWantBundle.length && self) {
        NBFindAndForwardClear(@"NC 队列(OBS)", nil);
    }
    %orig;
}
%end
%hook NCNotificationDispatcher
- (void)postNotificationWithRequest:(id)request {
    gNCDispatcher = self;
    NBStashNCRequest(request);   // 存「通知标识 → 真 request 对象」，删除时直接拿来撤回
    // ---------- 🔴🔴 v0.0.83：[RP] 复投观测（**只观测，不拦**）----------
    // 为什么盯这条：`nc_diag(21).txt` 里那条东西是**同 recordID、换了新 bulletinID**
    // 又回到 BB 的（`BB live 99→100`，盒子里也多了一条）。那不是"没删掉"，是**又被投了一次**。
    // 而 v0.0.82 已证 `addBulletin` 整场 0 次调用 ⇒ 复投只能从 post 这一侧看。
    // ⚠️ 本版**只记录**，不做抑制 —— 抑制是改行为的新刀，得先有这个数。
    gPostSeen++;
    @try {
        // 🔴 节流：这是一条热路径，台账读盘最多 1 秒一次。
        //    不加节流就是"每次投递读一次文件"，而这个 hook 在投递高峰期会连续触发。
        //    ⚠️ 用「跳过检查」而不是 `%orig; return;` —— 在 hook 里提前返回很容易变成双调原方法。
        static double sLastChk = 0;
        double nowP = [[NSDate date] timeIntervalSince1970];
        if (nowP - sLastChk >= 1.0) {
            sLastChk = nowP;
            NSString *rid = NBKVCStr(request, @"notificationIdentifier");
            NSString *uuid = NBKVCStr(request, @"uuid");
            id b = NBSafeValue(request, @"bulletin");
            NSString *bid = b ? NBKVCStr(b, @"bulletinID") : nil;
            double age = NBDeletedAgeFor(rid, uuid, bid);
            if (age >= 0 && age <= 600) {
                gRepostHit++;
                if (gRepostHit <= 20) {
                    NBDiagStep(@"  [RP] ⚠️ 复投第 %d 次 @%@ nid=%@ bulletinID=%@（命中 %.0fs 前删过的那条）\n",
                               gRepostHit, [NSDate date], NBSafeClip(rid, 44), NBSafeClip(bid, 40), age);
                }
            }
        }
    } @catch (__unused NSException *e) { }
    %orig;
}
// ---------- 🔴🔴 v0.0.68：注册 destination 时**顺手接住实例** ----------
// 为什么非要这条：v0.0.67 的 destination 实例只能靠 `destination:requestsClearing…` 那条 OBS 抓，
// 而那一轮 OBS **触发 0 次** ⇒ `[清] 跳过 destination（实例=(nil)）` ⇒ 唯一能驱动界面的那一刀
// 从来没发出去过。注册动作在 SpringBoard 起来时就发生，**比任何一次删除都早、且一定会走**。
// 🔴 这里**不写日志**（这个时点 diag 文件可能还不该存在，早写会让方法表那段被跳过），
//    只静静接住；由 `NBProbeDestinations` 在真要动手时打一行说明来源。
// 🔴 只接 `CSNotificationDispatcher`（CoverSheet = 通知中心界面本身），别的一概不碰。
- (void)registerDestination:(id)destination {
    if (destination && NBIsCSDest(destination)) {
        gCSDestination = destination;
        gCSDestFromHook = YES;
    }
    %orig;
}
- (void)_registerDestination:(id)destination {
    if (destination && NBIsCSDest(destination)) {
        gCSDestination = destination;
        gCSDestFromHook = YES;
    }
    %orig;
}
// ---------- 🔴🔴 v0.0.66：**纯观测**——系统自己"清掉通知"到底走哪条路 ----------
// 为什么盯这两条（依据是真机方法清单，不是猜）：
//   `NCNotificationDispatcher` 只有 67 个方法，其中和"清掉"直接相关的就这几条：
//     - destination:requestsClearingNotificationRequests:   ← 目的地（NC 界面）**请求清除**
//     - withdrawNotificationWithRequest:                    ← 真正执行撤回
//     - _clearUnsafeNotification: / _didRemoveNotificationRequest:
//   而 `NCBulletinNotificationSource` 上有一组同名镜像 `dispatcher:requestsClearingNotificationRequests:`
//   —— 它是 dispatcher → source 的那一跳，负责把 NC 的 request 翻成 bulletin 再交给 BBServer。
// 🔴 v0.0.65 真机教训：我盯的 `observer:removeBulletin:` 是**反方向**的广播
//   （BBServer 通知 NC "这条没了"）⇒ 用户手动清一条时它**一次都没触发**（4 次尝试全 0）。
//   盯错了方向，等于整轮白看。这次把"请求清除"这一侧也挂上。
- (void)destination:(id)destination requestsClearingNotificationRequests:(id)requests {
    gObsDispatcherClear++;
    // 🔴 v0.0.67：**这条 hook 现在不只是观测，还是「拿 destination 实例」的唯一来源**。
    //    要照着系统那条路走（`destination:requestsClearing…`），第一个参数必须是**真的**
    //    destination 对象（日志里是 `CSNotificationDispatcher`）—— 传 nil 或自己造的一律不认。
    if (destination && !gCSDestination) {
        gCSDestination = destination;
        NBDiagStep(@"  [拿] 已捕获 destination 实例 <%@>\n", NBClassName(destination));
    }
    if (gObsDispatcherClear <= 12) {
        NBDiagStep(@"  [OBS] dispatcher destination:<%@> requestsClearing…（第 %d 次，%ld 条）\n",
                   NBClassName(destination), gObsDispatcherClear, (long)NBCollectionCount(requests));
        NBLogRequests(@"OBS-dst", requests, 4);
    }
    %orig;
}
- (void)withdrawNotificationWithRequest:(id)request {
    gObsDispatcherWithdraw++;
    if (gObsDispatcherWithdraw <= 40) {
        NBDiagStep(@"  [OBS] dispatcher withdrawNotificationWithRequest:（第 %d 次）nid=%@\n",
                   gObsDispatcherWithdraw, NBClip(NBKVCStr(request, @"notificationIdentifier"), 50));
    }
    %orig;
}
%end
%end

%ctor {
    gRecent = [NSMutableDictionary dictionary];   // 单线程时机初始化，之后只读引用

    // 🔴 与 tweak.log 独立的「我跑过」证据：
    //    上一轮出现「日志文件不存在」，但 App 侧又疑似有记录 ⇒ 无法区分
    //    「tweak 没注入」与「日志写不进去」。这个标记文件把两者分开：
    //      .tweak_ctor 存在 + tweak.log 不存在 ⇒ 注入成功、但写日志失败
    //      两个都不存在                      ⇒ 真的没注入
    {
        NSString *mark = @"/var/mobile/Library/NotifyBox/.tweak_ctor";
        // 🔴 用 dladdr 拿到 dylib 自己的真实路径：roothide 会把前缀重定向，
        //    App 侧探测那几个写死的候选路径通常都落空，只有 tweak 自己知道它被装在哪。
        NSString *selfPath = @"?";
        Dl_info dli;
        if (dladdr((const void *)&NBProc, &dli) && dli.dli_fname) {
            selfPath = [NSString stringWithUTF8String:dli.dli_fname];
        }
        NSString *body = [NSString stringWithFormat:@"%@ %@ %@ dylib=%@",
                          [NSDate date], NBProc(), @"v0.0.25", selfPath];
        NSData *md = [body dataUsingEncoding:NSUTF8StringEncoding];
        [[NSFileManager defaultManager] createDirectoryAtPath:
            [mark stringByDeletingLastPathComponent]
                                 withIntermediateDirectories:YES attributes:nil error:nil];
        [md writeToFile:mark atomically:YES];
    }

    // 🔴🔴 v0.0.13：朗读自毁保护，必须排在任何 hook 之前。
    //    如果上次是崩在朗读里，先把开关关掉再干别的 —— 否则这一轮开机又会崩一次，
    //    用户陷入「开机→崩→安全模式→开机」的循环，连盒子 App 都进不去改设置。
    BOOL recovered = [NotifySpeaker recoverFromCrashIfNeeded];

    // 🔴🔴 这两件事**只让 SpringBoard 做**（本 tweak 同时注入 backboardd，见 NotifyBox.plist）：
    //    ① 两个进程同时改 settings.plist 会互相覆盖（后写的赢，可能把用户的改动冲掉）；
    //    ② backboardd 以 **root** 运行 —— 它写出来的文件/目录会变成 root 所有，
    //       之后盒子 App（mobile）就写不动了，表现是「设置保存失败 / 存不住」，
    //       而且现场看起来完全不像是权限问题。这种坑不能留。
    BOOL soundRecovered = NO;
    if ([NBProc() isEqualToString:@"SpringBoard"]) {
        // v0.0.52：注册 Darwin 通知观察者（盒子 App 删记录时唤醒我们清通知中心）。
        // 🔴 只在 SpringBoard 注册：tweak 主逻辑都在 SpringBoard；backboardd 不处理通知中心。
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, NBClearNCCallback,
            CFSTR("com.yxh41.notifybox.ncClear"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        NBLog(@"=== [v%@] 已注册 Darwin 通知观察者（NC 同步清除）", NB_VER_STR);
        // 🔴🔴 v0.0.62/63：NC 路径的「卡死自恢复」检查。
        //    `.nc_pending` 在进 NC 路径前写、正常跑完删 ⇒ 它还在 = 上次没回来。
        //    `.nc_off` = 永久禁用，只删 BB 账本（不卡，但界面也不变）。
        //    🔴 v0.0.63 关键改动：**两个文件里都写了版本号** ⇒ 只有「同一版本」卡死才继续禁用；
        //       换新版本就自动获得一次重试机会（否则 v0.0.62 留下的 .nc_off 会一直压着新版）。
        {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *offBody = nil;
            if ([fm fileExistsAtPath:kNBGuardOff]) {
                offBody = [NSString stringWithContentsOfFile:kNBGuardOff
                                                   encoding:NSUTF8StringEncoding error:nil];
            }
            if (offBody && [offBody containsString:NB_VER_STR]) {
                gNCSuppressed = YES;
                NBLog(@"!!! %@ 记录的就是本版 %@ 卡死 ⇒ 本次禁用 NC 路径", kNBGuardOff, NB_VER_STR);
            } else {
                if (offBody) {
                    [fm removeItemAtPath:kNBGuardOff error:nil];
                    NBLog(@"--> %@ 是旧版本留下的（内容=%@）⇒ 已删除，本版 %@ 重新试一次",
                          kNBGuardOff, NBClip(offBody, 60), NB_VER_STR);
                }
                NSString *pendBody = [NSString stringWithContentsOfFile:kNBGuardPending
                                                              encoding:NSUTF8StringEncoding error:nil];
                if (pendBody && [pendBody containsString:NB_VER_STR]) {
                    gNCSuppressed = YES;
                    [fm removeItemAtPath:kNBGuardPending error:nil];
                    [[[NSString stringWithFormat:@"%@ disabled %@ —— 上一次进 NC 路径卡死，已自动禁用。\n"
                        "删掉本文件并 respring 即可重新尝试。", NB_VER_STR, [NSDate date]]
                      dataUsingEncoding:NSUTF8StringEncoding] writeToFile:kNBGuardOff atomically:YES];
                    NBLog(@"!!! 本版上次进 NC 路径没回来 ⇒ 已禁用 NC 路径，并写下 %@", kNBGuardOff);
                } else {
                    if (pendBody) {
                        [fm removeItemAtPath:kNBGuardPending error:nil];
                        NBLog(@"--> %@ 是旧版本留下的（内容=%@）⇒ 已删除，不影响本版",
                              kNBGuardPending, NBClip(pendBody, 60));
                    }
                    NBLog(@"--> NC 路径护栏：干净，本次允许尝试 NC（版本 %@）", NB_VER_STR);
                }
            }
        }
        // ---- v0.0.78：⑦r 的护栏（主队列上同步调一个从没调过的 CS 方法）----
        // 🔴 判据和 `.nc_pending` 同一套：**文件还在 + 版本号是本版** ⇒ 上次这把刀把主队列
        //    卡死过 ⇒ 写 `.nc_off` 永久压制（界面侧退回「只清账本」）。
        //    换新版本号就自动获得一次重试机会（否则一次意外会把后面所有版本锁死）。
        {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *wsBody = [NSString stringWithContentsOfFile:kNBGuardCSWs
                                                        encoding:NSUTF8StringEncoding error:nil];
            if (wsBody && [wsBody containsString:NB_VER_STR]) {
                gCsWsSuppressed = YES;
                gNCSuppressed = YES;
                [fm removeItemAtPath:kNBGuardCSWs error:nil];
                [[[NSString stringWithFormat:@"%@ disabled ⑦r %@ —— ⑦r 调用没返回，主队列被卡住过。\n"
                    "删掉本文件并 respring 即可重新尝试。", NB_VER_STR, [NSDate date]]
                  dataUsingEncoding:NSUTF8StringEncoding] writeToFile:kNBGuardOff atomically:YES];
                NBLog(@"!!! 本版上次 ⑦r 调用没返回 ⇒ 已禁用界面侧，并写下 %@", kNBGuardOff);
            } else {
                if (wsBody) {
                    [fm removeItemAtPath:kNBGuardCSWs error:nil];
                    NBLog(@"--> %@ 是旧版本留下的（内容=%@）⇒ 已删除，本版重新试一次",
                          kNBGuardCSWs, NBClip(wsBody, 60));
                }
                NBLog(@"--> ⑦r 护栏：干净，本次允许（版本 %@）", NB_VER_STR);
            }
        }
        // v0.0.58：挂上 NC 派发器捕获（NCNotificationDispatcher 无类方法，只能靠 hook 拿实例）
        {
            Class srcCls = objc_getClass("NCBulletinNotificationSource");
            Class dspCls = objc_getClass("NCNotificationDispatcher");
            if (srcCls || dspCls) {
                NBLog(@"--> 挂 GNC（NC 派发器捕获：source=%@ dispatcher=%@）",
                      srcCls ? @"有" : @"无", dspCls ? @"有" : @"无");
                %init(GNC);
            } else {
                NBLog(@"!!! v0.0.58 两个 NC 类都不存在 ⇒ 只走 BB 侧撤回");
            }
        }
        // 🔴 v0.0.19：延迟功能已整体删除 ⇒ 这里不再有"自愈"，只有**残留清理**。
        //    只在 SpringBoard 里做，理由同上一段（backboardd 是 root）。
        NBPurgeDelayLeftovers();
        // 🔴 v0.0.21：换提示音是本版唯一的"造系统对象"操作，必须有自愈兜底。
        //    和 v0.0.15 那个坏掉的 guard 的区别：这里的 start/done 是**配对写**的
        //    （都在 NotifyFilter 的同一个函数里），而且关开关之后会**回读确认**。
        soundRecovered = [NotifyFilter recoverFromSoundCrashIfNeeded];

        // ---------- v0.0.45：SpringBoard 侧**代读** App 显示名 ----------
        //
        // 🔴🔴 病根（v0.0.42/43/44 连着三版没修好的那个）：
        //     用户报「京东显示的不是『京东』两个字」「信息 App 显示的不是『信息』」。
        //     三版都在**盒子 App 进程里**打转（换字段、加汉字优先、加"取更短"），
        //     但没碰一个前提：**盒子 App 有沙盒**。
        //     名字最权威的来源不是 `LSApplicationProxy.localizedName`（那是 App Store
        //     的**商品名**，常带「-购物商城」这类副标题），而是 **App 自己 bundle 里
        //     本地化过的 CFBundleDisplayName** —— 那才是 SpringBoard 画在图标底下的字。
        //     而桌面上的用户 App 装在 /var/containers/Bundle/Application/<UUID>/Xxx.app，
        //     **沙盒 App 读不到那一层**。
        //     ⇒ 正解不是"在没权限的地方再猜一轮"，而是**让有权限的进程算好送来**。
        //       SpringBoard 有权限，把结果写进 `app_names` 表，盒子 App 只管读。
        //
        // 🔴🔴🔴 三条安全约束，一条都不能省：
        //   ① **必须后台线程** —— 这里是 SpringBoard 的构造函数，
        //      主线程卡住的表现是白苹果/重启，代价远大于"名字还是差点"。
        //   ② **必须延迟** —— 刚启动时 LaunchServices 的注册表可能还没建好，
        //      立刻枚举只会拿到一部分（而且是静默地少）。
        //   ③ **整段 @try** —— 名字是锦上添花，解析失败最多是名字差一点，
        //      绝不能把通知录制这条主路径拖下水。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            @try {
                // 先跑一遍**不读 bundle**的全量枚举（快），只为拿到完整的 bid 列表
                NSMutableArray<NSString *> *stats = [NSMutableArray array];
                NSDictionary<NSString *, NSString *> *fast = NBEnumerateAppNames(NO, stats);
                if (!fast.count) {
                    NBLog(@"!!! [SpringBoard] v0.0.46 App 名表：枚举失败 · %@",
                          [stats componentsJoinedByString:@" · "]);
                    return;
                }
                NSDictionary<NSString *, NSString *> *known = [NotifyStore appNames];
                // 只精修"表里还没有的"：第一次是全部（表空），之后就是新装的几个
                // ⇒ 不会每次开机都把 200 多个 bundle 重读一遍。
                NSMutableDictionary<NSString *, NSString *> *todo = [NSMutableDictionary dictionary];
                for (NSString *bid in fast) {
                    if (known[bid].length) continue;
                    todo[bid] = [fast objectForKey:bid];
                }
                NSMutableDictionary<NSString *, NSString *> *refined = [NSMutableDictionary dictionary];
                for (NSString *bid in todo) {
                    NSString *nm = NBResolveNameForBundle(bid);
                    if (nm.length) refined[bid] = nm;
                }
                NSInteger written = refined.count ? [NotifyStore saveAppNames:refined] : 0;
                NBLog(@"=== [SpringBoard] v0.0.46 App 名表：枚举 %lu 个 · 待补 %lu 个 · 写入 %ld 个 · %@ ===",
                      (unsigned long)fast.count, (unsigned long)todo.count, (long)written,
                      [stats componentsJoinedByString:@" · "]);
            } @catch (NSException *e) {
                NBLog(@"!!! [SpringBoard] v0.0.46 App 名表解析抛异常（不影响录制）：%@", e);
            }
        });
    }

    // 🔴 v0.0.19：banner 里**不许再出现"延迟"的"已启用/已触发"字样**。
    //    用户是靠这一行判断功能状态的；功能没了却还在说"已启用"，就是 v0.0.18 那种假现场。
    // 🔴 banner 必须如实：用户是靠这一行判断"我改的功能到底有没有上线"。
    //    换提示音是实验功能，所以这里写「实验」，不写「已启用」。
    NBLog(@"=== [%@] NotifyBox v%@ · %@ · 朗读自愈%@ · 换提示音自愈%@ · 免打扰时段%@ · 换提示音%@ · 同步清通知中心%@ · 延迟推送已移除 ===",
          NBProc(), NB_VER_STR, [NotifySpeaker diagnosticLine],
          recovered ? @"已触发" : @"无异常",
          soundRecovered ? @"已触发" : @"无异常",
          @"可用",
          @"实验（默认关，按 App 各自一个音 + 时长上限 + 连发不叠加）",
          @"实验（默认关，删除单条记录时把那一条从通知中心也删掉）");

    // 只读探针：dump 一次 BBBulletin / BBSound 的类结构（内部自己保证只做一次）
    [NotifyProbe dumpClassesOnce];
    // 🔴 v0.0.22：换提示音听不到 ⇒ 必须知道 BBSound 到底有哪些属性、哪些**可写**。
    //    和上面那份的分工：NotifyProbe 打的是"名字 + 类型"，
    //    这份额外标注 [R]/[W]，并且把 BBSound 的声音相关 setter 全列出来 ——
    //    "能不能填进去"看的就是 setter 在不在。
    [NBSoundDiag dumpClassOnce];

    Class c = objc_getClass("BBServer");
    if (!c) {
        NBLog(@"!!! [%@] BBServer 类不存在（该进程里没有公告板服务）", NBProc());
        return;
    }

    // 🔴 用 class_copyMethodList 建名字集合来判断存在性。
    //    v0.0.3 用 class_getInstanceMethod 在 constructor 阶段对本机 BBServer 会返回 NULL
    //    （同一时刻 class_copyMethodList 却能列出该方法），所以这条路径更可靠。
    NSMutableSet *names = [NSMutableSet set];
    unsigned int cnt = 0;
    Method *ms = class_copyMethodList(c, &cnt);
    if (ms) {
        for (unsigned i = 0; i < cnt; i++) {
            [names addObject:NSStringFromSelector(method_getName(ms[i]))];
        }
        free(ms);
    }

    BOOL h1 = [names containsObject:@"publishBulletin:destinations:"];
    BOOL h2 = [names containsObject:@"publishBulletinRequest:destinations:"];
    BOOL h3 = [names containsObject:@"_publishBulletinRequest:forSectionID:forDestinations:"];
    // ---------- v0.0.72：新刀与它的观测点 ----------
    // 🔴 三条都先查名字再决定挂/调：
    //    `⑤K1` / `⑤K2` 是**要调用的刀**（不是 hook），查不到就不调（respondsToSelector 还会再兜一次）；
    //    `_sendRemoveBulletin:toFeeds:shouldSync:` 是**要 hook 的观测点**。
    // 🔴 为什么要在这里就把结果打出来：这三条名字来自 dump（静态），
    //    而"dump 里有 ≠ 这台机器上跑得通"是本项目反复踩到的（手册有、本机没有的类已经四个）。
    //    开机日志能留下的信息有限，所以把结果编进那一行 NBLog 里，不额外占行。
    BOOL h6 = [names containsObject:@"_sendRemoveBulletin:toFeeds:shouldSync:"];

    // ---------- v0.0.73：CoverSheet 目的地侧（观测 + ⑥ 动作）----------
    // 🔴 这一组**必须**先确认类名和方法名再 %init：`CSNotificationDispatcher` 是本机
    //    真机 dump 里见过的类，但"dump 里有 ≠ 这里能挂"（手册有、本机没有的类已经四个）。
    //    挂不上时把 `clearNotificationRequests*` 相关的名字打出来，下一轮不用猜。
    BOOL h7 = NO;
    {
        Class csd = objc_getClass("CSNotificationDispatcher");
        if (!csd) {
            NBLog(@"!!! CSNotificationDispatcher 类不存在 ⇒ ⑥ 与 CS 观测都不做");
        } else {
            NSMutableSet *cn2 = [NSMutableSet set];
            unsigned int c2 = 0;
            Method *cm2 = class_copyMethodList(csd, &c2);
            if (cm2) {
                for (unsigned i = 0; i < c2; i++) {
                    [cn2 addObject:NSStringFromSelector(method_getName(cm2[i]))];
                }
                free(cm2);
            }
            h7 = [cn2 containsObject:@"postNotificationRequest:"]
                 && [cn2 containsObject:@"withdrawNotificationRequest:"]
                 && [cn2 containsObject:@"destination:clearNotificationRequests:"];
            NBLog(@"=== [%@] CSNotificationDispatcher %u 个方法 · 投递=%@ 撤回=%@ 清除=%@ 按段清=%@ 列表=%@ 模态=%@ ===",
                  NBProc(), c2,
                  [cn2 containsObject:@"postNotificationRequest:"] ? @"YES" : @"NO",
                  [cn2 containsObject:@"withdrawNotificationRequest:"] ? @"YES" : @"NO",
                  [cn2 containsObject:@"destination:clearNotificationRequests:"] ? @"YES" : @"NO",
                  [cn2 containsObject:@"destination:clearNotificationRequestsInSections:"] ? @"YES" : @"NO",
                  [cn2 containsObject:@"listDestination"] ? @"YES" : @"NO",
                  [cn2 containsObject:@"modalDestination"] ? @"YES" : @"NO");
        }
    }

    NBLog(@"=== [%@] NotifyBox v%@ · BBServer %u 个方法 · PB=%@ PBR=%@ PBRS=%@ · 广播观测=%@ ===",
          NBProc(), NB_VER_STR, cnt, h1 ? @"YES" : @"NO", h2 ? @"YES" : @"NO", h3 ? @"YES" : @"NO",
          h6 ? @"YES" : @"NO");

    // v0.0.55：删掉 v0.0.53 在这里（%ctor）打的那行方法清单。
    //   🔴 理由：%ctor 是**开机**那一刻，日志窗口（≈最后 50 行）早就把它滚掉了 ——
    //      用户根本看不到，白占日志预算。方法清单已整体搬到「用户删记录」那一刻（NBClearNCCallback）。

    if (h1) { NBLog(@"--> 挂 GPB (publishBulletin:destinations:)");  %init(GPB); }
    if (h2) { NBLog(@"--> 挂 GPBR (publishBulletinRequest:destinations:)"); %init(GPBR); }
    if (h3) { NBLog(@"--> 挂 GPBRS (_publishBulletinRequest:forSectionID:forDestinations:)"); %init(GPBRS); }
    // 🔴 v0.0.72：只挂"广播观测"这一条。两条新刀是**调用**、不是 hook，不需要 %init。
    if (h6) { NBLog(@"--> 挂 GOBSREM (_sendRemoveBulletin:toFeeds:shouldSync:)"); %init(GOBSREM); }
    // 🔴 v0.0.73：CS 侧观测。`h7` 只要求三条核心方法都在 —— 其余几条各自
    //    `respondsToSelector:` 兜底（少一条不影响其它几条生效）。
    if (h7) { NBLog(@"--> 挂 GCSD (CSNotificationDispatcher 侧 6 条观测)"); %init(GCSD); }

    // ---------- v0.0.25：换提示音的新挂点 ----------
    //
    // 🔴 先**确认类和闸门存在**再 %init。理由见 GSC 组上面的注释：
    //    这个名字来自外部参考，本机未验证；类不存在时往 nil 上 hook 是"什么都可能发生"。
    // 🔴 名字对不上时把含 sound/play/vibrat/alert 的方法名**全打出来** ——
    //    这是"下一轮不用猜"的唯一来源（本项目因为"名字像"已经白跑过好几轮）。
    {
        Class gsc = objc_getClass("SBNCSoundController");
        if (!gsc) {
            NBLog(@"!!! v0.0.25 SBNCSoundController 类不存在 ⇒ 换提示音不挂（通知照旧原声）");
        } else {
            NSMutableSet *gn = [NSMutableSet set];
            unsigned int gcnt = 0;
            Method *gms = class_copyMethodList(gsc, &gcnt);
            if (gms) {
                for (unsigned i = 0; i < gcnt; i++) {
                    [gn addObject:NSStringFromSelector(method_getName(gms[i]))];
                }
                free(gms);
            }
            BOOL hs = [gn containsObject:@"canPlaySoundForNotificationRequest:"];
            NBLog(@"=== [%@] SBNCSoundController %u 个方法 · canPlaySoundForNotificationRequest=%@ ===",
                  NBProc(), gcnt, hs ? @"YES" : @"NO");
            if (hs) {
                NBLog(@"--> 挂 GSC (canPlaySoundForNotificationRequest:)");
                %init(GSC);
            } else {
                NSMutableArray *hits = [NSMutableArray array];
                for (NSString *n in gn) {
                    NSString *low = [n lowercaseString];
                    if ([low containsString:@"sound"] || [low containsString:@"play"]
                        || [low containsString:@"vibrat"] || [low containsString:@"alert"]) {
                        [hits addObject:n];
                    }
                }
                NBLog(@"!!! 没有 canPlaySoundForNotificationRequest:；"
                      @"含 sound/play/vibrat/alert 的共 %lu 条：%@",
                      (unsigned long)hits.count,
                      [[hits sortedArrayUsingSelector:@selector(compare:)]
                          componentsJoinedByString:@" , "]);
            }
        }
    }

    if (!h1 && !h2 && !h3) {
        // 全不存在时把相关名字打出来（只打名字，省日志）
        NSMutableArray *hits = [NSMutableArray array];
        for (NSString *n in names) {
            NSString *low = [n lowercaseString];
            if ([low containsString:@"publish"] || [low containsString:@"addbulletin"]) {
                [hits addObject:n];
            }
        }
        NBLog(@"!!! 三个入口都不存在；BBServer 上含 publish/addBulletin 的共 %lu 条：%@",
              (unsigned long)hits.count,
              [[hits sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" , "]);
    }

    NBLog(@"=== [%@] v%@ %@ ===", NBProc(), NB_VER_STR,
          (h1 || h2 || h3) ? @"已挂发布入口，等通知（看 PB/PBR/PBRS 开头的命中行）"
                           : @"没挂上任何入口");
}
