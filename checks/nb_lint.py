#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NotificationBox 常驻结构判据（v0.0.157 起入库，挂在 CI 上每次编译都跑）
================================================================================
为什么要有这个文件
--------------------------------------------------------------------------------
在此之前，每版的判据脚本都写在 `.workbuddy/tmp/nb_checkNNN.py` 里 —— 临时目录
清一次就全丢，而里面那些判据恰恰是**用真机代价换来的**。丢掉的直接后果是：
同一个病换个位置再犯一次，而没人记得上次是怎么抓到的。所以这一份**必须入库**。

三条设计原则（都吃过亏）
--------------------------------------------------------------------------------
1. **判据必须是"能红"的**。`--selftest` 会把每条判据对应的代码改坏，断言它变红。
   只在新代码上是绿的判据等于没有判据。
2. **判据域必须是被测上下文**，不是磁盘上的当前仓库。所有 check 都只读传进来的
   字符串 ⇒ 才能拿 `--baseline REV` 的历史源码跑同一套判据做反向对照。
3. **不判"这次改了什么"，只判"永远必须成立什么"**。版本相关的判断一律不进来，
   否则下个版本就得改脚本，改脚本就等于给自己开后门。

判据清单（编号稳定，改动会破坏历史对照）
--------------------------------------------------------------------------------
A  版本一致性
B  共享目录/标记文件的权限（对应 2026-11-04 「记录全没了」事故）
C  静默截断（"没画出来"与"没有"必须不同形）
D  已删物不许复活
E  日志行 ↔ 关键词筛选表机械对拍（人眼扫表已连续失败六次）
F  三态纪律（读不到 ≠ 不存在）
G  文件格式（纯 LF）

用法
--------------------------------------------------------------------------------
  python3 checks/nb_lint.py                 跑全部常驻判据（CI 跑的就是这一条）
  python3 checks/nb_lint.py --selftest      再做变异（证明每条判据都能红）
  python3 checks/nb_lint.py --baseline REV  反向对照，按每条判据的标注验证该红/该绿
                                            ⚠️ REV 取**本版之前**的那一版（通常 HEAD~1）
  python3 checks/nb_lint.py --root PATH     指定仓库根（默认 = 本文件上一级）
"""
import os
import re
import subprocess
import sys

# ───────────────────────────── 基础设施 ─────────────────────────────


def mask(src):
    """字符串内容 / 字符常量 / 注释 → 空格（长度不变）。用来切函数体。"""
    out, i, n = list(src), 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            i += 1
            while i < n and src[i] != '"':
                if src[i] == "\\":
                    out[i] = " "
                    i += 1
                if i < n:
                    out[i] = " "
                    i += 1
            i += 1
        elif c == "'":
            j = i + 1
            j = j + 2 if (j < n and src[j] == "\\") else j + 1
            if j < n and src[j] == "'":
                for k in range(i, j + 1):
                    out[k] = " "
                i = j + 1
            else:
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                out[i] = " "
                i += 1
            if i + 1 < n:
                out[i] = " "
                out[i + 1] = " "
            i += 2
        else:
            i += 1
    return "".join(out)


def strip_comments(src):
    """抹注释、**保留**字符串内容。

    🔴 不能用 mask 代替：本项目的判据词几乎全写在 @"…" 里，mask 会把它们一起抹掉
       ⇒ 肯定式判据恒红、"已删除"类判据恒绿（两条都在骗人）。
       只剥注释，才能区分「代码/字符串里还在」与「我自己的注释里提过这个名字」。
       这一条是第一次做反向对照时当场栽的坑。
    """
    out, i, n = list(src), 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            i += 1
            while i < n and src[i] != '"':
                if src[i] == "\\":
                    i += 1
                i += 1
            i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                out[i] = " "
                i += 1
            if i + 1 < n:
                out[i] = " "
                out[i + 1] = " "
            i += 2
        else:
            i += 1
    return "".join(out)


def func_body(src, signature):
    """按签名切出 `{ ... }` 函数体（用 mask 后的文本定位，返回值取原文）。"""
    m = mask(src)
    i = m.find(signature)
    if i < 0:
        return None
    j = m.find("{", i)
    if j < 0 or ";" in m[i:j]:
        return None
    depth, k = 0, j
    while k < len(m):
        if m[k] == "{":
            depth += 1
        elif m[k] == "}":
            depth -= 1
            if depth == 0:
                return src[i:k + 1]
        k += 1
    return None


def after(src, anchor, span=1200):
    """anchor 之后的一段原文。用来判「某句之后必须紧跟某动作」，比锚点精确匹配耐改名。"""
    i = src.find(anchor)
    return None if i < 0 else src[i:i + span]


def rd(p):
    with open(p, "rb") as f:
        return f.read().decode("utf-8", "replace")


# ───────────────────────────── 读源码 ─────────────────────────────

SRC_EXT = (".m", ".x", ".h")

# 除源码外还要读的文件（版本号判据要它们；I3 要 Makefile 判"新文件有没有进 FILES"）
EXTRA_FILES = ("control", "Resources/Info.plist", "Makefile")


def wanted(rel):
    return rel.endswith(SRC_EXT) or rel in EXTRA_FILES


def tracked(root):
    """仓库里**已被 git 跟踪**的文件列表 —— 这是唯一的白名单来源。

    🔴🔴 v0.0.157 第一次 CI 就栽在这里，必须记下来：
       CI 把 Theos 和 iOS SDK clone 到**仓库根目录**（`$THEOS = $GITHUB_WORKSPACE/theos`），
       于是 `os.walk(root)` 把几万个苹果头文件一起扫进来 ⇒ G1 在
       `theos/vendor/include/BaseBoard/BSAction.h` 上判 CRLF、H1 在 CoreData 的头文件上判
       花括号不平衡 —— **判据在别人的代码上判红**。副作用还包括 lint 白跑 4.5 分钟。
       修法**不是补排除名单**：名单永远漏（今天漏 theos，明天漏别的），
       而 `git ls-files` 是**事实**，不是我的记忆。判据只该量我们自己的代码。
       ⇒ 这是「判据域必须是被测上下文」的第三次变形
         （前两次：量了磁盘上的当前仓库、注释里写的函数名把自己算进去）。

    ⚠️ 副作用（必须知道）：白名单来自 git ⇒ **新建但没 `git add` 的文件不会被判**。
       所以本地流程是「先 add，再跑 lint」，而不是反过来。
    """
    r = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True)
    if r.returncode == 0 and r.stdout.strip():
        names = [p for p in r.stdout.decode("utf-8", "replace").split("\0") if p]
        return [p for p in names if wanted(p)]
    # 没有 git（比如从 tarball 跑）：回退到目录遍历，但**把这件事喊出来**，
    # 否则又是一条"看着一样、其实量的是别的东西"的静默降级。
    print("⚠️  git ls-files 不可用，回退到目录遍历（可能扫进第三方 SDK）")
    out = []
    for dirpath, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs
                   if d not in (".git", ".workbuddy", "packages", "dist", "obj", "theos")]
        for n in names:
            rel = os.path.relpath(os.path.join(dirpath, n), root).replace("\\", "/")
            if wanted(rel):
                out.append(rel)
    return out


def load(root):
    """把仓库里**我们自己的**源码读进两个 dict：str（判据用）与 bytes（行尾判据用）。

    🔴 为什么必须同时留 bytes：G1 判的是行尾，而 `text=True` 的通用换行会把 CRLF
       悄悄翻译成 LF ⇒ 判据恒绿。这是「读不到 ≠ 不存在」的变种：
       **被读取层改写过的内容，不能用来判断它原本是什么。**
    """
    files, raw = {}, {}
    for rel in tracked(root):
        p = os.path.join(root, *rel.split("/"))
        if not os.path.isfile(p):
            print("⚠️  git 里记着但磁盘上没有（已删除未提交？）：%s" % rel)
            continue
        with open(p, "rb") as f:
            b = f.read()
        raw[rel] = b
        files[rel] = b.decode("utf-8", "replace")
    return files, raw


def load_baseline(root, rev):
    """用 `git show REV:path` 把某个历史版本的全部源码读出来（反向对照用）。"""
    listing = subprocess.run(["git", "-C", root, "ls-tree", "-r", "--name-only", rev],
                             capture_output=True, text=True, encoding="utf-8")
    if listing.returncode != 0:
        return None, None
    files, raw = {}, {}
    for rel in listing.stdout.splitlines():
        if not (rel.endswith(SRC_EXT) or rel in EXTRA_FILES):
            continue
        if rel.startswith("checks/"):
            continue
        r = subprocess.run(["git", "-C", root, "show", "%s:%s" % (rev, rel)],
                           capture_output=True)
        if r.returncode == 0:
            raw[rel] = r.stdout
            files[rel] = r.stdout.decode("utf-8", "replace")
    return (files, raw) if files else (None, None)


def allsrc(files):
    return "\n".join(v for k, v in sorted(files.items()) if k.endswith(SRC_EXT))


def find1(files, name):
    """按文件名找唯一一份源码（同名多处 ⇒ 报错，不许默默挑一个）。"""
    hits = [v for k, v in files.items() if k.rsplit("/", 1)[-1] == name]
    if len(hits) != 1:
        return None if not hits else "\n".join(hits)
    return hits[0]


def versions(files):
    """四处版本号：NotifyCommon.h 的宏、control 的 Version、Info.plist 的两个键。

    🔴 「换了版本但只换了一半」本项目栽过，所以这里既判"都读到"也判"都相等"。
    """
    got = {}
    hdr = find1(files, "NotifyCommon.h") or ""
    m = re.search(r'#define\s+NOTIFYBOX_VER_STR\s+@"([^"]+)"', hdr)
    got["NotifyCommon.h"] = m.group(1) if m else None
    ctl = files.get("control") or ""
    m = re.search(r"^Version:\s*(\S+)", ctl, re.M)
    got["control"] = m.group(1) if m else None
    pl = files.get("Resources/Info.plist") or ""
    for key in ("CFBundleVersion", "CFBundleShortVersionString"):
        m = re.search(r"<key>%s</key>\s*<string>([^<]+)</string>" % key, pl)
        got["Info.plist/" + key] = m.group(1) if m else None
    return got


# ───────────────────────────── 判据本体 ─────────────────────────────

CHECKS = []


def chk(cid, desc, baseline="green"):
    """登记一条判据。

    baseline="green"  ⇒ 拿旧版源码跑也必须绿（既有性质，用来防回归）
    baseline="red"    ⇒ 拿旧版源码跑必须红（本版新增性质，用来证明判据有分辨力）
    """
    def deco(fn):
        CHECKS.append((cid, desc, baseline, fn))
        return fn
    return deco


# ── A. 版本一致性 ───────────────────────────────────────────────

@chk("A1", "四处版本号都读到")
def _(c):
    got = versions(c["files"])
    miss = [k for k, v in got.items() if not v]
    return (not miss, "读不到：%s" % miss if miss else str(sorted(set(got.values()))))


@chk("A2", "四处版本号相等")
def _(c):
    got = versions(c["files"])
    vals = [v for v in got.values() if v]
    ok = len(vals) == 4 and len(set(vals)) == 1
    return (ok, "四处不相等：%s" % got)


# ── B. 共享目录 / 标记文件权限 ───────────────────────────────────
# 2026-11-04 事故：backboardd(root) 先 createDirectory ⇒ 目录归 root ⇒ App(mobile) 写不进，
# 记录整体消失且现场看着"不像权限问题"。修法是「放开权限」而不是「禁止写入者」。
# 这里守四条，缺一条那个洞就重新打开。

@chk("B1", "NBDataDir() 建目录后 chmod 0777")
def _(c):
    b = strip_comments(find1(c["files"], "NotifyStore.m") or "")
    body = func_body(b, "NSString *NBDataDir(void)")
    if body is None:
        return (False, "切不到 NBDataDir 函数体")
    return ("0777" in body and "chmod(" in body, "函数体里没有 chmod 0777")


@chk("B2", "root 分支 chown 之后补 chmod 0777", baseline="red")
def _(c):
    """🔴 v0.0.157 新增：0777 此前只写在 NBDataDir() 里，而 backboardd **从不调它**
    （root 那条分支只写 NSLog）⇒ 唯一以 root 注入的进程只 chown 不 chmod，
    真机实测目录是 755 —— 预防措施在这一侧是空的。"""
    tw = strip_comments(find1(c["files"], "Tweak.x") or "")
    body = func_body(tw, "if (getuid() == 0)") if "if (getuid() == 0)" in tw else None
    if body is None:
        return (False, "切不到 root 分支")
    ok = ("chown(" in body) and re.search(r"chmod\(\s*legacy\s*,\s*0777\s*\)", body)
    return (bool(ok), "root 分支里没有 chmod(legacy, 0777)")


@chk("B3", ".tweak_ctor_root 写成功后 chmod", baseline="red")
def _(c):
    """root 建的标记文件要能被 mobile 身份的盒子 App 读到 —— 否则「标记在不在」
    这个判定就被交给了 umask，而读不到在证据上和「没写」一模一样。"""
    tw = strip_comments(find1(c["files"], "Tweak.x") or "")
    seg = after(tw, "写 .tweak_ctor_root 失败", 1500)
    if seg is None:
        return (False, "找不到 .tweak_ctor_root 的写失败日志锚点")
    return ("chmod(" in seg and "0666" in seg, "写成功分支里没有 chmod 0666")


@chk("B4", ".tweak_ctor 写成功后 chmod", baseline="red")
def _(c):
    tw = strip_comments(find1(c["files"], "Tweak.x") or "")
    seg = after(tw, "写 .tweak_ctor 失败 errno=", 1500)
    if seg is None:
        return (False, "找不到 .tweak_ctor 的写失败日志锚点")
    return ("chmod(" in seg and "0666" in seg, "写成功分支里没有 chmod 0666")


@chk("B5", ".old_location 代读记录写完 chmod")
def _(c):
    ns = strip_comments(find1(c["files"], "NotifyStore.m") or "")
    body = func_body(ns, "static void NBWriteOldLocationProbe(void)")
    if body is None:
        return (False, "切不到 NBWriteOldLocationProbe 函数体")
    return ("chmod(" in body and "0666" in body, "函数体里没有 chmod 0666")


# ── C. 静默截断 ─────────────────────────────────────────────────
# 「没画出来」与「没有」必须不同形 —— 这是本项目最贵的一类病。

@chk("C1", "形状速写到上限时自报截断", baseline="red")
def _(c):
    al = strip_comments(find1(c["files"], "AppLauncher.m") or "")
    body = func_body(al, "static void NBShapeAppend(")
    if body is None:
        return (False, "切不到 NBShapeAppend 函数体")
    if "220" not in body:
        return (False, "截断阈值不见了（判据锚点失效）")
    return ("截断" in body, "到上限直接 return，读者会以为形状就长这样")


@chk("C2", "截断标记只打一次（递归去重）", baseline="red")
def _(c):
    al = strip_comments(find1(c["files"], "AppLauncher.m") or "")
    body = func_body(al, "static void NBShapeAppend(") or ""
    i = body.find("截断")
    if i < 0:
        return (False, "没有截断标记（C1 先红）")
    head = body[:i]
    ok = ("containsString:" in head) or ("rangeOfString:" in head)
    return (ok, "追加标记前没有去重守卫 ⇒ 递归会重复追加")


# ── D. 已删物不许复活 ───────────────────────────────────────────

@chk("D1", "NBAltDataDir 连声明一起删掉（代码里 0 次）")
def _(c):
    """v0.0.156 删掉了这个函数：它唯一调用点在 App 进程里恒走 nil 分支 ⇒ 死探针。
    🔴 注释里提名字不算，所以先 strip_comments。"""
    n = strip_comments(allsrc(c["files"])).count("NBAltDataDir")
    return (n == 0, "代码中仍出现 %d 次" % n)


@chk("D2", "恒 YES 的闸门不许养出死分支", baseline="red")
def _(c):
    """🔴🔴 **死探针的第二种长相**：不是"读不到"（入参恒 nil），而是"永不执行"。

    `NBCanWriteSharedFiles()` 自 v0.0.142 起恒返 YES，可 ctor 里还留着
    `if (!NBCanWriteSharedFiles()) { NSLog(@"…（root 进程不写共享目录）"); } else { … }`
    ⇒ 上面那一支永远进不去，而它打出的话在主张一条**早就不存在的规则**。
    死代码里的话最贵：它不会被任何测试推翻，只会被下一个人当真（我这次就信了两天）。

    判据写成"闸门恒 YES ⇒ 任何取反分支都算死分支"，而不是盯着某个函数名 ——
    这样以后再有别的恒真/恒假闸门，同一条判据也守得住。
    """
    ns = strip_comments(find1(c["files"], "NotifyStore.m") or "")
    body = strip_comments(func_body(ns, "BOOL NBCanWriteSharedFiles(void)") or "")
    if not body:
        return (False, "切不到 NBCanWriteSharedFiles 函数体")
    if not re.search(r"\{\s*return\s+YES\s*;\s*\}", body):
        return (True, "闸门不恒 YES，本判据不适用（恒假的反向写法需另立一条）")
    n = strip_comments(allsrc(c["files"])).count("if (!NBCanWriteSharedFiles())")
    return (n == 0, "仍有 %d 处恒不成立的分支" % n)


# ── E. 日志行 ↔ 关键词表机械对拍 ─────────────────────────────────
# 发出侧打了、筛选表里没有词能匹配 ⇒ 等于没打。人眼扫表已连续失败六次
# （DELAY# / PROBEDATE / payload / 降级 / 直达+直开 / 打开 / 路径），只能靠这条。

# 「结论行」这一屏读的是 `[NotifyStore logText:]` ⇒ `NOTIFYBOX_LOG_PATH`（tweak.log）。
# 所以判据域 = **所有写这个文件的入口**。写别的文件的通道不是不管，而是**显式列出原因**，
# 并且一旦出现第 4 个新名字就当场 FAIL（见下面的 unknown 守卫）。
#   🔴 直接把闸门关成"只认 NBSharedLog"就是本判据六个月来的原状 —— 代价是 11 行日志
#      从来没被看过。宁可多列两行注释，也不许再出现"不在域里却在绿着"。
LOG_CHANNEL_SEEDS = ("NBSharedLog", "NBStoreLog")

OTHER_LOG_CHANNELS = {
    "NBDiagStep":  "Tweak.x:2946 → NBDiagAppend，写 pre-log 文件，不写 tweak.log",
    "NBDiagLogF":  "NotifySoundDiag.m:136，只写 sound diag 文件（App 有单独的查看页）",
    "NSLog":       "走 oslog / 控制台，不进 tweak.log",
}


def log_aliases(src):
    """写 tweak.log 的那几个函数的**全部名字**，含宏别名（`Tweak.x:225` 的 `#define NBLog NBSharedLog`）。

    🔴🔴 不认别名 = 别名发出的日志整批不在判据域里。实测（v0.0.167）：
       Tweak.x 有 11 行 `NBLog(@"[…` 带标签，而 E1 的锚点只认字面 `NBSharedLog(@"[`
       ⇒ 这 11 行从写下那天起**一次也没被这条判据看过**。判据一直是绿的，
       但它绿的理由是"没看见"，不是"没问题"——正是 REF §Z4 的第①类假绿。
       「人眼扫表失败六次」的教训，被"锚点只覆盖一半"原封不动地复制了一遍。

    这里**动态解析宏**而不是把 `NBLog|NBSharedLog` 写死：以后再有人加一个别名，
    同一条判据自动覆盖，不用回来改脚本（写死的话，下个别名又是一个盲区）。
    """
    names = set(LOG_CHANNEL_SEEDS)
    for seed in LOG_CHANNEL_SEEDS:
        for m in re.finditer(r'#\s*define\s+([A-Za-z_]\w*)\s+%s\b' % seed, src):
            names.add(m.group(1))
    return names


# 标签只有两种长相：`[中文/英文…]` 或 `大写字母开头的词#`（`DND#` `DROP#` `MUTE#` `DELAY-SKIP#`）。
# 🔴 `#` 前面**允许小写**（`{0,20}` 里放开 a-z）：只认全大写的话，`MUTE-bad#` 这种
#    「前缀大写、中间小写」的标签会**既进不了 emitted、也进不了 used** ——
#    于是它连"锚点不认识我"都不会喊，属于最安静的那种漏。放开字符集把这个类直接堵掉。
#    （这也是为什么下面的 used 守卫不是万能的：它只能喊出"名字不认识"，
#      喊不出"这行的长相不在我的模式里"。模式本身的收口只能靠写宽一点。）
# 🔴 **方括号要留住**，不能只取里面的字：App 侧是 `[line containsString:k]` 整行子串比，
#    判据把括号剥掉之后 `[源]` 就只剩一个 `源` 字 —— 而关键词表里写 `[源]` 才是精确的。
#    剥掉括号 ⇒ 要么判据判不过（口径不一致的假红），要么逼我在表里放一个单字 `源`
#    （把一堆无关行也捞进来）。两把尺子必须先对齐刻度。
TAG_RE = r'(?:\[[^\]"]{1,40}\]|[A-Z][A-Za-z0-9_\-]{0,20}#)'


@chk("E1", "每个日志标签都能过关键词筛选表", baseline="red")
def _(c):
    src = strip_comments(allsrc(c["files"]))
    vc = strip_comments(find1(c["files"], "ViewController.m") or "")
    m = re.search(r'kNBKeyLineTable\s*=\s*\n?\s*@"([^"]+)"', vc)
    if not m:
        return (False, "找不到 kNBKeyLineTable")
    kws = m.group(1).split("|")
    alts = log_aliases(src)
    # 🔴 先无条件自曝"锚点不认识的名字"：凡是**以标签开头**的日志调用，名字必须落在
    #    「写 tweak.log 的函数」或「显式登记过的其他通道」里。都不在 ⇒ FAIL。
    #    不这么做的话，将来再来一个别名，那批行又是不在域里地绿着，谁也发现不了。
    used = set(re.findall(r'\b([A-Za-z_]\w*)\(@\s*"%s' % TAG_RE, src))
    unknown = sorted(used - alts - set(OTHER_LOG_CHANNELS))
    if unknown:
        return (False, "有标签的调用来自没登记过的名字 %s ⇒ 这些行不被检查"
                       "（要么加进 LOG_CHANNEL_SEEDS/OTHER_LOG_CHANNELS，要么把标签去掉）" % unknown)
    emitted = set(re.findall(r'(?:%s)\(@\s*"(%s)'
                             % ("|".join(re.escape(a) for a in sorted(alts, key=len, reverse=True)),
                                TAG_RE), src))
    if not emitted:
        return (False, "一个带标签的日志行都没扫到（判据锚点失效）")
    bad = sorted(t for t in emitted if not any(k and k in t for k in kws))
    return (not bad, "过不了筛的标签：%s" % bad if bad else "%d 个标签全过" % len(emitted))


@chk("E2", "关键词表非空且带 NBKEYLINES 头")
def _(c):
    vc = strip_comments(find1(c["files"], "ViewController.m") or "")
    m = re.search(r'kNBKeyLineTable\s*=\s*\n?\s*@"([^"]+)"', vc)
    if not m:
        return (False, "找不到 kNBKeyLineTable")
    kws = [k for k in m.group(1).split("|") if k]
    return (len(kws) >= 8 and kws[0] == "NBKEYLINES", "%d 个词" % len(kws))


# ── F. 三态纪律 ─────────────────────────────────────────────────

@chk("F1", "「读不到」单列一支并明说不能断言")
def _(c):
    ns = strip_comments(find1(c["files"], "NotifyStore.m") or "")
    return ("读不到，不是不存在" in ns and "!oldSeen" in ns,
            "缺 !oldSeen 分支或缺「读不到，不是不存在」这句话")


@chk("F2", "标记的三态（目录/在不在/读不读得出）分别记录")
def _(c):
    ns = strip_comments(find1(c["files"], "NotifyStore.m") or "")
    need = ('@"dirExists=', '@"markerExists=', '@"markerUnreadable=')
    miss = [k for k in need if k not in ns]
    return (not miss, "缺：%s" % miss if miss else "三态齐全")


# ── G. 文件格式 ─────────────────────────────────────────────────

@chk("G1", "源码/control/Info.plist/Makefile 纯 LF", baseline="red")
def _(c):
    """🔴 判据域必须是**被测上下文**（`c["raw"]`），不许回头去读磁盘上的当前仓库 ——
       否则 `--baseline` 模式下它量的是别人。这条是第一次跑反向对照当场抓到的 bug
       （G1 在旧版源码上依然读磁盘 ⇒ 「该绿却红」，看着像旧版有病，其实是判据走错门）。
       真机/编辑器都不在乎 CRLF，所以这个病谁都不会报 —— 只能靠这里守。
       v0.0.157 入库时它当场抓到 `app/SettingsViewController.m` 整份 1472 行全是 CRLF。
       标注为 baseline="red"：这条判据是**本版才有**的，而 v0.0.156 的树确实违反它
       ⇒ 「旧版必红」正是它有效力的证明，不是误判。"""
    bad = sorted(rel for rel, b in c["raw"].items() if b"\r" in b)
    return (not bad, "CRLF：%s" % bad if bad else "%d 个文件全为 LF" % len(c["raw"]))


# ── H. 低级语法自检（本地没有 clang，编译只能靠 CI，先把这类错挡在推送之前）──

@chk("H1", "每个源文件的花括号平衡")
def _(c):
    """🔴 没有本地编译器时，最大的浪费是「推上去等 CI 报一个少括号」。
       这一条不能代替编译，但能在 3 秒内拦住最蠢的一类。
       mask 之后统计（字符串/注释里的括号不算），深度从不为负、收尾必须回到 0。"""
    bad = []
    for rel, src in sorted(c["files"].items()):
        if not rel.endswith(SRC_EXT):
            continue
        d = 0
        for ch in mask(src):
            if ch == "{":
                d += 1
            elif ch == "}":
                d -= 1
                if d < 0:
                    break
        if d != 0:
            bad.append("%s(%+d)" % (rel, d))
    return (not bad, "不平衡：%s" % bad if bad else "%d 个文件平衡" % len(c["files"]))


# ── I. 列表动效的挂钩与顺序（v0.0.176）─────────────────────────

def _func_body(m, anchor):
    """在 mask 过的源码里，从 anchor 起截到下一个方法的开头（`\\n- (` 或 `\\n#pragma`）。

    ⚠️ 这是"够用"的切法，不是语法分析：本项目的函数体里既没有嵌套的
       `\\n- (` 也没有 `#pragma`，所以切不歪。⛔ 别拿它去切别的文件。
    """
    i = m.find(anchor)
    if i < 0:
        return None
    ends = [x for x in (m.find("\n- (", i + len(anchor)),
                        m.find("\n#pragma", i + len(anchor))) if x > 0]
    return m[i:min(ends)] if ends else m[i:]


@chk("I1", "列表动效三挂钩齐全，且布防排在 loadData 之前", baseline="red")
def _(c):
    """🔴 v0.0.176 新增。每一条坏掉都**不报错、界面上也看不出来**，所以必须机械守：

       ① `nbArmSlideFromIndex:` 若排到 `[self loadData]` **之后** —— 布防发生在
          `reloadData` 之后，那一次布局已经过了 ⇒ 动画永远不播，功能却一切正常。
          这正是本项目反复栽的「用"到不了的轮次"当触发 = 交了等于没交」。
       ② `willDisplayCell:` 里必须**两个量都读**（`nbEntranceUntil` / `nbSlideDX`）。
          只写一处等于只做了一半动效，而"少一个动效"和"本来就该这样"在截图上同形。
       ③ `prepareForReuse` 里必须把静音态复位（`nbSetMutedLook:NO`）：不复位 ⇒
          暗卡片串到**没被静音**的 App 的行上，用户会以为静音串 App 了
          —— 静音表其实是对的，画面在说假话。

       ⚠️🔴 判据域一律用 `mask()` 之后的源码。这几个名字在我自己写的注释里全都出现过，
          不 mask 就是**拿自己的解释当证据**（本项目刚为这个坑付过账：
          `MUST_BE_GONE` 里的裸串被文件头注释误伤，脚本连跑两遍都报残留）。
    """
    vc = mask(c["files"].get("app/ViewController.m", ""))
    nc = mask(c["files"].get("app/NotifyCell.m", ""))
    problems = []

    for name, anchor in (("onTime:", "\n- (void)onTime:(UISegmentedControl *)seg {"),
                         ("onUnread:", "\n- (void)onUnread:(UISegmentedControl *)seg {")):
        body = _func_body(vc, anchor)
        if body is None:
            problems.append("%s 找不到" % name)
            continue
        i_arm = body.find("nbArmSlideFromIndex:")
        i_load = body.find("[self loadData]")
        if i_arm < 0:
            problems.append("%s 没有布防" % name)
        elif i_load < 0:
            problems.append("%s 没有 loadData" % name)
        elif i_arm > i_load:
            problems.append("%s 布防排在 loadData 之后" % name)

    wd = _func_body(vc, "\n- (void)tableView:(UITableView *)tableView\n  willDisplayCell:")
    if wd is None:
        wd = _func_body(vc, "willDisplayCell:")
    if wd is None:
        problems.append("willDisplayCell: 找不到")
    else:
        # 🔴 `willDisplayCell:` 的签名跨了三行，所以先用整段签名找；找不到才退到裸名字。
        #    裸名字能匹配到"别处提到它"，所以它只当兜底，而且兜底失败要**明说**，
        #    不许静默通过（"找不到"和"通过了"在输出上必须能分开）。
        for tok in ("nbEntranceUntil", "nbSlideDX"):
            if tok not in wd:
                problems.append("willDisplayCell: 没读 %s" % tok)

    # ④ 入场错落的布防点：必须在 `viewWillAppear:`，**且绝不能落在重建列表的那两处**。
    #    这组一正两负，缺一条就等于只判了一半：
    #    · 丢了 viewWillAppear 那处 ⇒ 首屏永远不播（A 变成死功能）；
    #    · 布防漏进 `applyItemsAndRefreshUI`（**两条刷新路径的共用尾部**，`reloadData`
    #      就在里面）⇒ 前台回来/删除/标已读/从详情页返回全都重播一遍，列表一直在抖。
    #      🔴 我第一版把这条判在 `loadData` 上，**判错了地方**：`loadData` 里根本没有
    #      `reloadData`，它只是查完数据就交给共用尾部。判据写在那儿永远绿 ——
    #      是"变异跑不红"当场把它抓出来的（M18 恒绿），不是我看出来的。
    vwa = _func_body(vc, "\n- (void)viewWillAppear:")
    if vwa is None:
        problems.append("viewWillAppear: 找不到")
    elif "nbArmEntrance" not in vwa:
        problems.append("viewWillAppear: 没布防入场")

    for fname in ("\n- (void)loadData {", "\n- (void)applyItemsAndRefreshUI {"):
        fb = _func_body(vc, fname)
        if fb is None:
            problems.append("%s 找不到" % fname.strip())
        elif "nbArmEntrance" in fb:
            problems.append("%s 里布防了入场（会让每次刷新都重播）" % fname.strip())

    pfr = _func_body(nc, "\n- (void)prepareForReuse")
    if pfr is None:
        problems.append("NotifyCell prepareForReuse 找不到")
    elif "nbSetMutedLook:NO" not in pfr.replace(" ", ""):
        problems.append("prepareForReuse 没复位静音态")

    return (not problems, "；".join(problems) if problems else "三挂钩齐全、顺序正确")


@chk("I2", "列表页除 table 外的 scrollView 必须显式关掉 scrollsToTop", baseline="red")
def _(c):
    """🔴 v0.0.177 新增，起因是一处**功能被静默顶掉**的 bug：

       UIKit 的规则是「同时有**多个** `scrollsToTop == YES` 的 scroll view 在屏上 ⇒
       点状态栏回到顶部这个手势**全都不响应**」—— 不是"响应最上面那个"，是全部失效。
       而这个属性**默认 YES**，全仓一处都没显式设过 ⇒ `iconBar`（横向图标栏）和
       `table` 两个都是 YES ⇒ 长列表里点状态栏毫无反应。

       ⚠️ 这条判据只覆盖 `ViewController.m`：只有列表页同时挂着两个 scroll view。
         别的页面（设置/规则测试/统计）自己那一屏只有一个，保持默认才对
          —— 把它们也一起判，会逼着我在那些页面上写一堆没用的 `= YES`。

       🔴 判据域用 `mask()` 之后的源码：我在这条修复旁边写了段解释，里面反复出现
          `scrollsToTop` 这个词 —— 不 mask 就等于**拿自己的注释当"已经设过了"的证据**。
    """
    vc = mask(c["files"].get("app/ViewController.m", ""))
    total = vc.count("[[UIScrollView alloc]")
    if total == 0:
        # 找不到锚点必须报红，不许当"没有风险"放过去（判据静默失效比没有更糟）。
        return (False, "一个 `[[UIScrollView alloc]` 都没找到 —— 锚点失效，判据作废")
    bad, i = [], 0
    while True:
        i = vc.find("[[UIScrollView alloc]", i)
        if i < 0:
            break
        win = vc[i:i + 2000]
        if "scrollsToTop" not in win:
            ls = vc.rfind("\n", 0, i)
            bad.append((vc[ls + 1:i].strip() or "(匿名)")[:40])
        i += 1
    return (not bad, "没关掉 scrollsToTop：%s" % bad if bad
            else "%d 个非 table 的 scrollView 都显式关掉了" % total)


# ── I3. 下拉刷新的闭环 / 键盘收起 / 触觉入口（v0.0.178）──────────

@chk("I3", "下拉刷新闭环、键盘收起、触觉入口齐全", baseline="red")
def _(c):
    """🔴 v0.0.178 新增。这一版加的三件事**坏掉以后界面上都不报错**，所以必须机械守：

       ① 下拉刷新必须是**闭环**：挂载 → 重查 → 两个出口收转圈 → 无出口时看门狗兜底。
          任何一环漏掉的表现都不是"报错"，而是"一直转圈"或"转一下就没了" ——
          前者只能杀 App，后者会被读成"下拉没反应"。
       ② 下拉**绝不能**走 `refreshIfChanged`：它第一句是 `if (!dbFingerprintChanged) return;`
          ⇒ 库没变时什么都不做、转圈照样消失、界面一个像素都不变。
          这是"交了等于没交"的典型，而且看起来完全正常 —— 所以写成**反向判据**。
       ③ 触觉必须落在**用户动作的入口**（换筛选 / 点图标 / 标已读 / 静音 / 下拉）。
          漏一个的后果是那个动作"手感上不存在"，没有任何日志会报。
          另外成功那档必须排在**回读校验之后**：写盘失败也震"成功"，
          用户摸到的就是"成了"，而通知照弹（和 v0.0.176 熄灯动画同一条纪律）。
       ④ `NotifyCell.m` 里**不许**再出现自己那份 `static` 触觉实现。
          v0.0.178 之前就是它导致列表页一次都没震过 —— 死实现留着，
          下一个人会以为"已经有触觉了"，然后发现调不到、再抄一份。

       ⚠️ 判据域一律 `mask()` 之后：这几版的解释注释里把这些名字全写过一遍，
          不 mask 就是拿自己的注释当证据（两个方向都会中：假红 + 假绿）。
    """
    vc = mask(c["files"].get("app/ViewController.m", ""))
    nc = mask(c["files"].get("app/NotifyCell.m", ""))
    ha = mask(c["files"].get("app/NBHaptic.m", ""))
    problems = []

    # ---------- ① 挂载 + 唯一收尾 + 两个出口 ----------
    if "self.table.refreshControl" not in vc:
        problems.append("没见过把 refreshControl 挂到 table 上")

    end = _func_body(vc, "\n- (void)nbEndPullRefresh {")
    if end is None:
        problems.append("nbEndPullRefresh 找不到")
    else:
        if "endRefreshing" not in end:
            problems.append("nbEndPullRefresh 里没有 endRefreshing")
        if "nbPullBeginAt" not in end:
            problems.append("nbEndPullRefresh 没复核最短可见时长")
        # 🔴 "唯一收尾出口"：全文的 `endRefreshing` 只许出现在这一个函数里。
        #    散出去以后就会出现"两个地方都能收"⇒ 先到的那个把转圈收掉，
        #    用户看到的是"转圈提前消失"，而日志里看不出谁收的。
        if vc.count("endRefreshing") != end.count("endRefreshing"):
            problems.append("endRefreshing 有 %d 处，只有 1 处该在 nbEndPullRefresh 里"
                            % vc.count("endRefreshing"))

    nw = _func_body(vc, "\n- (void)ncWaitAndReload:(NSInteger)left {")
    if nw is None:
        problems.append("ncWaitAndReload: 找不到")
    elif nw.count("nbEndPullRefresh") < 2:
        # "什么都没变"那条 `return` 是最常走的一条；漏了它，转圈只能靠 2.5s 看门狗收
        # ⇒ 表现是"每次都转满 2.5 秒"，像卡住。
        problems.append("ncWaitAndReload: 只收 %d 处转圈（两个出口都要收）"
                        % nw.count("nbEndPullRefresh"))

    pr = _func_body(vc, "\n- (void)nbOnPullRefresh:(UIRefreshControl *)rc {")
    if pr is None:
        problems.append("nbOnPullRefresh: 找不到")
    else:
        if "nbPullBusy" not in pr:
            problems.append("nbOnPullRefresh: 没有重入闸门")
        if "dispatch_after" not in pr:
            problems.append("nbOnPullRefresh: 没有兜底定时器（永不回调时转圈不收）")
        if "reloadKeepingOffset" not in pr:
            problems.append("nbOnPullRefresh: 没走完整重查")
        if "refreshIfChanged" in pr:
            problems.append("nbOnPullRefresh: 用了带指纹闸门的 refreshIfChanged（库没变就空转）")
        if "NBHapticFire" not in pr:
            problems.append("nbOnPullRefresh: 没触觉")
        if "requestNCSnapshotIfDue" in pr:
            problems.append("nbOnPullRefresh: 用了节流出口（手动动作不许被挡）")

    # ---------- ② 键盘 ----------
    if "keyboardDismissMode" not in vc:
        problems.append("没设 keyboardDismissMode")
    did = _func_body(vc, "\n- (void)tableView:(UITableView *)tableView "
                         "didSelectRowAtIndexPath:(NSIndexPath *)indexPath {")
    if did is None:
        problems.append("didSelectRowAtIndexPath: 找不到")
    elif "resignFirstResponder" not in did:
        problems.append("didSelectRow 没把键盘收掉（键盘会跟到详情页上）")

    # ---------- ③ 触觉入口 ----------
    entries = [
        ("onTime:", "\n- (void)onTime:(UISegmentedControl *)seg {"),
        ("onUnread:", "\n- (void)onUnread:(UISegmentedControl *)seg {"),
        ("onStar:", "\n- (void)onStar:(id)sender {"),
        ("onIcon:", "\n- (void)onIcon:(UIButton *)sender {"),
        ("nbOverviewSelectBundle:", "\n- (void)nbOverviewSelectBundle:(NSString *)bid {"),
        ("doMarkAllRead", "\n- (void)doMarkAllRead {"),
    ]
    for name, anchor in entries:
        fb = _func_body(vc, anchor)
        if fb is None:
            problems.append("%s 找不到" % name)
        elif "NBHapticFire" not in fb:
            problems.append("%s 没有触觉" % name)

    # 成功那档必须排在回读校验之后（写盘失败也震"成功" = 手指收到假结论）
    for name, anchor, verify in (
            ("nbMuteRow:", "\n- (void)nbMuteRow:(NSDictionary *)row kind:(NBMuteKind)kind {",
             "BOOL ok ="),
            ("nbUnmuteRow:", "\n- (void)nbUnmuteRow:(NSDictionary *)row {",
             "BOOL exactStill")):
        fb = _func_body(vc, anchor)
        if fb is None:
            problems.append("%s 找不到" % name)
            continue
        if "NBHapticFire" not in fb:
            problems.append("%s 没有触觉" % name)
            continue
        i_ok = fb.find(verify)
        i_su = fb.find("NBHapticKindSuccess")
        if i_ok < 0:
            problems.append("%s 找不到回读校验（%s）" % (name, verify))
        elif i_su < 0:
            problems.append("%s 没有成功触觉" % name)
        elif i_su < i_ok:
            problems.append("%s 的成功触觉排在回读校验之前" % name)

    # ---------- ④ 死实现 / 死名字 / 链接配置 ----------
    if "static void NBHapticFire" in nc or "static UIImpactFeedbackGenerator" in nc:
        problems.append("NotifyCell.m 里又出现自己那份 static 触觉实现")
    for dead in ("NBHapticKindArm", "NBHapticKindDelete", "NBHapticKindStop"):
        if dead in nc or dead in vc:
            problems.append("旧档位名 %s 还在（死名字会让人以为还有另一套）" % dead)
    if "void NBHapticFire(NBHapticKind kind)" not in ha:
        problems.append("NBHaptic.m 里没有 NBHapticFire 的实现")
    # 档位的判定必须是**黑名单**式（只有 Light 用轻，其余一律柔）。
    # 写成白名单 `? soft : light` 时，以后新增的档会静默落到 light —— 分量偏重且看不出来。
    if "? light : soft" not in ha:
        problems.append("NBHaptic.m 的档位判定不是黑名单式（`? light : soft`）")
    if "? soft : light" in ha:
        problems.append("NBHaptic.m 的档位判定是白名单式（新增档会静默变重）")
    # 🔴🔴 Makefile 这一条**不能复用 `mask()`**：`mask` 只认 C 的 `//` 和 `/* */`，
    #    不认 Makefile 的 `#` 注释。而我在上面那段说明里正好写了 "新增 app/NBHaptic.m"
    #    ⇒ mask 之后那句话还在 ⇒ 判据永远绿。
    #    这不是假设：第一版就是这么写的，是 **M23 变异跑不红**当场抓出来的。
    #    （同族账：本项目已为"解释性注释污染判据域"付过两次 —— 一次是裸串被文件头
    #      注释误伤，一次是 `MUST_BE_GONE` 里放裸串。这是第三次，形态换了：
    #      换成了一个 mask 不认识的注释语法。）
    #    ⇒ 正解不是再补一套"剥 # 注释"，而是**只认那一行赋值**：
    #      注释里提到文件名叫"说明"，`FILES` 行里有它才叫"编进去了"。
    files_line = next((ln for ln in c["files"].get("Makefile", "").splitlines()
                       if ln.lstrip().startswith("NotifyBoxApp_FILES")), "")
    if not files_line:
        problems.append("Makefile 里找不到 NotifyBoxApp_FILES 赋值行 —— 锚点失效，判据作废")
    elif "app/NBHaptic.m" not in files_line:
        # 🔴 这是本项目"新文件忘了进 Makefile"的**第九次**防守点。
        #    失败形态是链接期 undefined symbol（`_NBHapticFire`，连 _OBJC_CLASS_$_ 前缀都没有），
        #    看着像代码问题。判据放在这里，就再也不用靠记忆。
        problems.append("Makefile 的 App FILES 里没有 app/NBHaptic.m（链接期 undefined symbol）")

    return (not problems, "；".join(problems) if problems else
            "下拉闭环 / 键盘 / 触觉入口 / 链接配置 全齐")


# ── I4. 图标栏的无障碍（v0.0.179）────────────────────────────

@chk("I4", "图标栏：名字/未读/选中都折进 label·traits，且 holder 不许变成 a11y 元素", baseline="red")
def _(c):
    """🔴 v0.0.179 新增。这一条守的是**看不见的界面**：

       图标栏是全 App 唯一「纯图片、零文字」的在屏控件（时间胶囊 `setTitle:`、
       ★ `setTitle:`、分段控件都自带文字）⇒ VoiceOver 滑到那里只会念「按钮」，
       一排全都一样。于是三样**只有视觉才能表达**的信息全丢：是哪个 App、
       有没有未读（红点是 9pt 纯色块）、当前筛的是哪个（3pt 短横线）。
       而这些装饰**结构上不可能**被读出来 —— 它们压根没有文字。
       ⇒ 必须折进 `accessibilityLabel` / `accessibilityTraits`，否则等于没做。

       🔴🔴 反向那一条（`holder` 不许被设成 a11y 元素）才是这条判据里最值钱的：
          一旦 `holder.isAccessibilityElement = YES`，里面的 button 会被**吞掉**，
          VoiceOver 双击走 `accessibilityActivate` —— 没实现就**双击没反应**。
          表现在界面上是"名字念对了、就是点不动"，比完全不做更糟，而且
          光看代码/截图完全看不出来。所以必须机械守。

       ⚠️🔴 判据域用 `strip_comments()` 而不是 `mask()`：这里要判的 `有未读` 是
          **字符串字面量**，而 `mask()` 会把整个 `@""` 抹成空格 ⇒ 判据恒红；
          反过来只 `strip_comments()` 又会让**我自己写的解释注释**（里面反复出现
          `accessibilityLabel` / `isAccessibilityElement` / 「有未读」）变成假证据
          ⇒ 假绿。两个方向都踩过，所以是"先剥注释、再留字符串"这一种。
    """
    raw = c["files"].get("app/ViewController.m", "")
    body = func_body(strip_comments(raw), "\n- (void)reloadIconBar {")
    if not body:
        return (False, "reloadIconBar 找不到 —— 锚点失效，判据作废")
    problems = []
    if "accessibilityLabel" not in body:
        problems.append("没有 accessibilityLabel（VoiceOver 只会念「按钮」）")
    if "appNameForBundle" not in body:
        problems.append("名字没走 appNameForBundle（必须和列表同源，不许自己拼 bundle 串）")
    if "有未读" not in body:
        problems.append("未读没折进 label（红点是纯色块，读不到）")
    if "UIAccessibilityTraitSelected" not in body:
        problems.append("选中态没折进 traits（3pt 短横线，读不到）")
    # 同源： 「有没有未读」这个量只许算一次 —— 红点和 label 必须读同一个变量。
    # 算两次就是两条规则：改一条必漏一条，屏幕上是"红点亮着、VoiceOver 说没有未读"，
    # 而且不报错（本项目「提示语与判定必须同源，同一行也不行」）。
    n_rule = body.count("[unread containsObject:")
    if n_rule != 1:
        problems.append("「有没有未读」被算了 %d 次（只许 1 次：红点与 label 必须同源）" % n_rule)
    # 反向：holder 一旦成为 a11y 元素，里面的按钮就点不动了
    if (re.search(r"holder\s*\.\s*isAccessibilityElement\s*=", body)
            or "[holder setIsAccessibilityElement:" in body):
        problems.append("holder 被设成 a11y 元素（会吞掉按钮 ⇒ VoiceOver 双击没反应）")
    return (not problems, "；".join(problems) if problems else
            "名字 / 未读 / 选中都折进去了，holder 仍是普通容器")


@chk("I5", "列表 cell 整行文案由唯一出口接管：未读/★/×N/静音都念得出，且不覆盖 traits", baseline="red")
def _(c):
    """🔴 v0.0.180 新增。守的是列表**每一行**的听觉版本。

       病根不是"cell 没有无障碍元素" —— `UITableViewCell` 默认就是，VoiceOver 一直
       能扫到每一行。问题是**这一行念什么全靠系统聚合子视图**，于是：
         ① 未读角标里只有个数字（`3` / `99+`）⇒ 念成孤零零一个「3」，什么意思猜不出来；
         ② ★ 是 `starLabel.text = @"★"` ⇒ 念「星号」或者被当成符号跳过；
         ③ **静音态零文本**（卡片压暗 + 琥珀竖条都是纯视觉的）⇒「这个 App 现在不响」
            这件事对 VoiceOver 用户**完全不存在**，他会以为通知没收到；
         ④ ×N 徽章念成「叉三」。
       ⇒ 正解是设 `accessibilityLabel` 把整行接管过来（cell 是无障碍元素，一旦有了
         显式 label，子视图就不再被聚合，①②④ 那些怪念法一并消失）。

       🔴🔴 反向那两条（⛔ 不许覆盖 `accessibilityTraits` / `isAccessibilityElement`）
          才是这条判据里最值钱的：cell 的双击走 `didSelectRow`、长按走
          `UIContextMenuInteraction`，全靠系统按自己的 traits 派发。覆盖掉之后
          双击**没反应**，而单指扫、左右滑全都正常 —— 这种坏法在真机上极难归因。
          我校准的是"念什么"，不是"能干什么"。

       🔴🔴 另一条值钱的是「`(无标题)` / `(无正文)` 必须排除」：那两个串是**给眼睛看的
          兜底**，念出来是「左括号无正文右括号」，等于把占位符变成了正文内容，
          而且跟着每一条空正文的记录出现，听感上就像坏了。判据要求用
          `isEqualToString:`（完整串比较），⛔ 不是 `containsString:` ——
          正文里真写了「(无正文)」四个字（有人在群里聊这个 bug）就会被误吞。

       ⚠️🔴 判据域用 `strip_comments()`：要判的「已标星」「已静音」都是**字符串字面量**，
          `mask()` 会把 `@""` 整段抹成空格 ⇒ 恒红。反过来只 `strip_comments()` 又会让
          我写的解释注释（里面反复出现这些词）变成假证据 ⇒ 假绿。两个方向都踩过，
          所以照 I4 的做法：先剥注释、再只在函数体里判。
    """
    raw = c["files"].get("app/NotifyCell.m", "")
    sc = strip_comments(raw)
    body = func_body(sc, "\n- (void)nbUpdateA11y {")
    if not body:
        return (False, "nbUpdateA11y 找不到 —— 锚点失效，判据作废")
    problems = []

    # ---------- ① 三样"只有视觉能表达"的状态必须折进文案 ----------
    for lit, why in (
            ("未读", "角标里只有一个数字，念出来是孤零零的「3」"),
            ("已标星", "★ 是「★」字符本身，念成「星号」或被跳过"),
            ("相同内容", "×N 徽章会被念成「叉三」"),
            ("已静音", "静音态零文本，不念等于这个状态不存在"),
    ):
        if lit not in body:
            problems.append("文案里没有「%s」：%s" % (lit, why))

    # ---------- ② 出口只许读原始量 ----------
    # 两个视图状态（`timeLabel.text` / `cardView.alpha`）尤其不许读：
    # 前者在 prepareForReuse 里曾经是直接写 label 清的，后者带动画时是中间值。
    for var, why in (
            ("rawAppName", "App 名不在文案出口里"),
            ("rawTitle", "标题不在文案出口里"),
            ("rawBody", "正文不在文案出口里"),
            ("nbTimeText", "时间不在文案出口里（新加的原始量白加了）"),
            ("isUnread", "未读判据不在文案出口里"),
            ("unreadCount", "未读条数不在文案出口里"),
            ("starred", "★ 判据不在文案出口里"),
            ("groupCount", "×N 判据不在文案出口里"),
            ("nbMuted", "静音判据不在文案出口里"),
    ):
        if var not in body:
            problems.append("%s（%s）" % (why, var))

    # ---------- ③ 视觉兜底串必须按完整串排除 ----------
    for lit in ("(无标题)", "(无正文)"):
        if not re.search(r'isEqualToString:\s*@"%s"' % re.escape(lit), body):
            problems.append("「%s」没按完整串排除（兜底文案会念成「左括号…右括号」）" % lit)

    # ---------- ④ 反向：不许覆盖 cell 自己那套无障碍身份 ----------
    if (re.search(r"self\s*\.\s*accessibilityTraits\s*=", sc)
            or "[self setAccessibilityTraits:" in sc):
        problems.append("覆盖了 accessibilityTraits（会弄坏双击进详情）")
    if (re.search(r"self\s*\.\s*isAccessibilityElement\s*=", sc)
            or "[self setIsAccessibilityElement:" in sc):
        problems.append("覆盖了 isAccessibilityElement（cell 默认 YES，多设一处就跟系统版本打架）")

    # ---------- ⑤ 文案只许出现在两处：出口设一次、复用复位清一次 ----------
    # 多一处就是"同一个量算两遍"（v0.0.179 图标栏刚栽过：改一条必漏一条）。
    n_lbl = sc.count("accessibilityLabel")
    if n_lbl != 2:
        problems.append("accessibilityLabel 出现 %d 次（只许 2 次：出口设、复用清）" % n_lbl)

    # ---------- ⑥ 七个 setter 一个都不许漏 ----------
    for sig in ("\n- (void)setAppName:",
                "\n- (void)setTitleText:",
                "\n- (void)setTimeText:",
                "\n- (void)setUnread:",
                "\n- (void)setStarred:",
                "\n- (void)setGroupCount:",
                "\n- (void)nbSetMutedLook:"):
        sb = func_body(sc, sig)
        if not sb:
            problems.append("%s 找不到 —— 锚点失效" % sig.strip())
        elif "nbUpdateA11y" not in sb:
            problems.append("%s 结尾没调 nbUpdateA11y（输入变了文案不跟着变）" % sig.strip())

    # ---------- ⑦ 静音状态必须记在早返回之前，且不许从 alpha 反推 ----------
    mb = func_body(sc, "\n- (void)nbSetMutedLook:")
    if not mb:
        problems.append("nbSetMutedLook: 找不到 —— 锚点失效")
    else:
        i_ret = mb.find("return;")
        i_set = mb.find("self.nbMuted =")
        i_upd = mb.find("[self nbUpdateA11y]")
        if i_set < 0:
            problems.append("静音状态没存进 nbMuted（既念不出，也躲不开从 alpha 反推）")
        elif i_ret >= 0 and i_set > i_ret:
            problems.append("静音状态记在早返回之后（animated:NO 那条路不更新文案）")
        if i_upd < 0:
            problems.append("nbSetMutedLook: 里没调 nbUpdateA11y")
        elif i_ret >= 0 and i_upd > i_ret:
            problems.append("nbUpdateA11y 排在早返回之后（animated:NO 那条路不更新文案）")
        if re.search(r"nbMuted\s*=\s*[^;]*alpha", mb):
            problems.append("静音态从 cardView.alpha 反推（动画途中读到中间值 ⇒ 时念时不念）")

    # ---------- ⑧ 复用必须清文案 ----------
    rb = func_body(sc, "\n- (void)prepareForReuse {")
    if not rb:
        problems.append("prepareForReuse 找不到 —— 锚点失效")
    else:
        if not re.search(r"self\s*\.\s*accessibilityLabel\s*=\s*nil", rb):
            problems.append("prepareForReuse 没清 accessibilityLabel（复用会念上一条的内容）")
        # ⚠️ 时间也要走 setter 清：`nbTimeText` 是喂给文案的原始量，
        #    直接写 `timeLabel.text = nil` 会把它留下来 ⇒ 复用回来的行文案里
        #    挂着上一条的时间。而上面那条（清 accessibilityLabel）看不出来这件事：
        #    label 反正会被下一次重算覆盖，只有 `nbTimeText` 会真的残留下去。
        if re.search(r"self\s*\.\s*timeLabel\s*\.\s*text\s*=", rb):
            problems.append("prepareForReuse 直接写 timeLabel.text（绕过 setTimeText:，nbTimeText 会残留）")

    return (not problems, "；".join(problems) if problems else
            "未读/★/×N/静音都折进唯一出口，traits 与 a11y 元素身份未被覆盖")


@chk("I6", "统计页：占比与条长各用各的分母、条长只传比例、图表可念、页头重设不递归", baseline="red")
def _(c):
    """🔴 v0.0.181 新增。守的是统计页的**口径**，不是长相。

       这一版把统计页整个重写了（KPI 卡 + 自绘柱状图 + 品牌色排行），
       而统计页最容易错的从来不是画得好不好看，是**两个分母混用**：
         · 「占比 25.5%」的分母必须是**本时间窗总条数**（`grandTotal`）；
         · 「条形长度」的分母必须是**本屏最大值**（`max`，这样第一名满格）。
       写反了屏幕上完全看不出来 —— 第一名会显示 100%，而真实占比可能是 4%。
       本项目栽过的同族事故（v0.0.37：红点按全库算、列表按时间窗查）就在这个位置。

       另外三条都是"看不见的错"：
         · **条长用像素宽**时，cell 刚 dequeue 那一下 `barBox.bounds` 还是 0
           ⇒ 首屏几行条形画不出来，滚一下再回来又正常（时序型 bug，最难复现）；
         · **`tableHeaderView` 的高度不会自动跟随内容**，改完 frame 必须重新赋一次，
           而重新赋值会触发 layout ⇒ 没有 `inSync` 就是死循环（表现为切一下维度就卡住）；
         · **日期解析不设 `en_US_POSIX`**：系统日历是佛历/和历时 `dateFromString:` 会错，
           而 SQL 侧 `strftime` 输出的永远是公历 —— 两边不对齐，星期几就会标错一天。

       ⚠️🔴 判据域用 `strip_comments()`：要判的「总条数」「未读」都是字符串字面量。
    """
    raw = c["files"].get("app/NotifyStatsViewController.m", "")
    stats = strip_comments(raw)
    store = strip_comments(c["files"].get("NotifyStore.m", ""))
    problems = []

    # ---------- ① KPI 卡：前两格是固定语义，切维度不许变 ----------
    if "NBKpiCard" not in stats:
        problems.append("KPI 卡不存在（退回一行小字的形态）")
    for lit in ("总条数", "未读"):
        if lit not in stats:
            problems.append("KPI 里没有「%s」" % lit)

    # ---------- ② 两个分母必须分开 ----------
    body = func_body(stats, "- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:")
    if not body:
        problems.append("cellForRow 找不到 —— 锚点失效")
    else:
        if "grandTotal" not in body:
            problems.append("占比没走 grandTotal（分母必须是本时间窗总数）")
        m = re.search(r"share\s*=[^;]{0,240};", body)
        if not m:
            problems.append("找不到 share 的赋值（占比没算？）")
        elif re.search(r"self\s*\.\s*max", m.group(0)):
            problems.append("占比错用 self.max 当分母（第一名会显示 100%，真实占比被藏掉）")
        if "ratio" not in body:
            problems.append("条长没传比例（像素宽必须在 cell 里算）")
        if "barFill.frame" in body:
            problems.append("cellForRow 直接写 barFill.frame（那一刻槽宽可能还是 0 ⇒ 首屏条形画不出来）")

    # ---------- ③ 像素宽只许出现在 cell 内部两处 ----------
    n_fill = stats.count("barFill.frame")
    if n_fill != 2:
        problems.append("barFill.frame 出现 %d 次（只许 2 次：layoutSubviews 算宽度、prepareForReuse 归零）"
                        % n_fill)

    # ---------- ④ 图表必须念得出来（v0.0.180 的教训） ----------
    # 🔴🔴 判据域必须收进**各自图表的函数体**，⛔ 别用「全文件 chart.summary 出现几次」。
    #    第一版就是全局计数 `>= 2`，而 dim==0 分支里新增一句「隐藏时清 summary」
    #    就把计数从 2 补到 3 ⇒ M51（把按天的 summary 改到 accessibilityLabel）
    #    **立刻变成恒绿**。计数型判据只要有别处能顺手把数字填满，就等于没判。
    for sig, label in (("- (void)feedHourChart {", "按小时"),
                       ("- (void)feedDayChart {", "按天"),
                       ("- (void)feedPieChart {", "按 App 环形")):
        fb = func_body(stats, sig)
        if not fb:
            problems.append("%s图表函数找不到 —— 锚点失效" % label)
        elif "chart.summary" not in fb:
            problems.append("%s图表的 summary 没设（VoiceOver 扫过去是一块空白）" % label)

    # ---------- ⑤ 页头重设必须有防递归闸门，且 YES/NO 成对 ----------
    if not re.search(r"if\s*\(\s*self\s*\.\s*inSync\s*\)\s*return", stats):
        problems.append("没有 `if (self.inSync) return`（重设 tableHeaderView 会递归）")
    if stats.count("self.inSync =") < 2:
        problems.append("inSync 只设了一边（YES/NO 必须成对，否则一次重设就永久卡住不再更新）")

    # ---------- ⑥ 汇总必须一条 SQL 出齐，且空串不算"有正文" ----------
    # 🔴🔴 判据域**必须收进 `statsSummarySince:` 的函数体**：整个 NotifyStore.m 里
    #    `MAX(ts)` 出现 4 次（别处的查询也在用）⇒ 拿全文判「有没有 MAX(ts)」
    #    等于没判，改动这个函数照样绿。实测：M47 第一版就恒绿，真因就是这个。
    sum_body = func_body(store, "+ (NSDictionary *)statsSummarySince:")
    if not sum_body:
        problems.append("statsSummarySince: 找不到 —— 锚点失效")
    else:
        if "MAX(ts)" not in sum_body:
            problems.append("汇总没取 MAX(ts)（算不出最晚一条 / 真实跨度）")
        if "message<>''" not in sum_body:
            problems.append("「有正文」没排除空串（库里空正文有 NULL 和空串两种）")
        if sum_body.count("SELECT COUNT(*)") != 1:
            problems.append("汇总的 SELECT 不是一条（六个值必须一次出齐，否则口径会分裂）")

    # ---------- ⑦ 按天补齐：上限 + 时区对齐 ----------
    if "maxFill" not in store:
        problems.append("按天没有补齐上限（全库 200 天会把列表撑成 200 行）")
    if not re.search(r"fmt\s*\.\s*timeZone\s*=", store):
        problems.append("补齐用的日期格式没设 timeZone（和 SQL 的 'localtime' 对不上 ⇒ 有记录的天也会写成 0）")

    # ---------- ⑧ 网页日历陷阱：解析必须用 POSIX locale ----------
    if "en_US_POSIX" not in stats:
        problems.append("解析日期没设 en_US_POSIX（佛历/和历系统下星期几会算错一天）")

    # ---------- ⑨ 图表卡的显隐：showsChart 只许有一个生产者 ----------
    # 🔴🔴 这一条是 v0.0.181 的用户现场反馈换来的（第一个靠真人截图抓到的 bug）：
    #    从「按小时」切回「按 App」后，图表卡留着上一轮的 170pt frame，
    #    **盖住列表前 3 行**，页头高度却已经缩回去了。
    #    现场表现是"来源排行"和"24 小时分布"两个标题叠在同一个 y 上，
    #    用户的原话是「来源排行跟下面的 24 小时太紧凑了，然后前几个 App 被挡住了」。
    #    病根：`showsChart` 有两条赋值路径（setChartHidden: / syncHeaderSize），
    #    而 `chartCard.hidden` 谁都不管，`layoutSubviews` 只在 showsChart 为 YES 时赋 frame。
    #    ⇒ 正解是让 setter 一个人管 hidden + frame 归零，调用点一个都不许碰。
    if "static const CGFloat kNBStatsChartH" not in stats:
        problems.append("图表卡高度没抽成常量（preferredHeight 与 layoutSubviews 会各写一份数字）")
    ph = func_body(stats, "- (CGFloat)preferredHeight {")
    if not ph:
        problems.append("preferredHeight 找不到 —— 锚点失效")
    elif "kNBStatsChartH" not in ph:
        problems.append("preferredHeight 没用高度常量 ⇒ 页头高度会和内容错位（卡片被裁或列表被盖）")

    st = func_body(stats, "- (void)setShowsChart:(BOOL)showsChart {")
    if not st:
        problems.append("showsChart 没有自定义 setter ⇒ 图表卡的显隐没人管（这次的真 bug）")
    else:
        if "chartCard.hidden" not in st:
            problems.append("setter 没设 chartCard.hidden ⇒ 切回「按 App」时卡片继续盖住列表前几行")
        if "CGRectZero" not in st:
            problems.append("setter 没把 chartCard.frame 归零 ⇒ 旧高度会残留到下一轮")

    n_hide = stats.count("chartCard.hidden")
    if n_hide != 1:
        problems.append("chartCard.hidden 出现 %d 次（只许 1 次，就在 setter 里；"
                        "多一处就是第二个生产者，hidden 会和 showsChart 打架）" % n_hide)
    sch = func_body(stats, "- (void)setChartHidden:(BOOL)hidden {")
    if not sch:
        problems.append("setChartHidden: 找不到 —— 锚点失效")
    elif "chartCard" in sch:
        problems.append("setChartHidden: 自己碰了 chartCard（第二个生产者）")

    # ---------- ⑩ 按 App 维度也要有图（v0.0.184 的环形） ----------
    # 三个维度各一张图：按 App 环形 / 按小时柱状 / 按天柱状。
    # ⛔ 不许把按 App 那条退回 `setChartHidden:YES`（用户明确要了饼图）。
    if "feedPieChart" not in stats:
        problems.append("按 App 维度没有环形图（用户明确要求加饼图）")
    if "chart.slices" not in stats:
        problems.append("环形图的数据没喂给 chart.slices")

    # 🔴 判"被用在那里"而不是"常量存在"：常量定义在文件顶部，
    #    把使用点改成 `if (YES)` 之后常量照样在 ⇒ 存在性判据恒绿。
    pie = func_body(stats, "- (void)feedPieChart {")
    if not pie:
        problems.append("feedPieChart 找不到 —— 锚点失效")
    elif "kNBStatsPieTopN" not in pie:
        problems.append("环形图没有分片上限（本机 67 个 App 全画出来每片不到 2°）")

    # 🔴 判"被调用"而不是只判"存在"：函数写好了却没人调 = 图上什么都没有，
    #    而存在性判据照样绿（本项目栽过"分支写了、条件到不了"好几次）。
    rel = func_body(stats, "- (void)reloadData {")
    if not rel:
        problems.append("reloadData 找不到 —— 锚点失效")
    else:
        for f, label in (("feedPieChart", "按 App 环形"),
                         ("feedHourChart", "按小时柱状"),
                         ("feedDayChart", "按天柱状")):
            if f not in rel:
                problems.append("%s图表的 feed 没在 reloadData 里调用（图永远不显示）" % label)

    kind_body = func_body(stats, "- (void)setKind:(NBChartKind)kind {")
    if not kind_body:
        problems.append("chart 没有 setKind:（两种形态共用同一视图，必须有类型入口）")
    else:
        # 🔴 两种数据源必须互斥清理：残留的那一半会让 drawRect 画出
        #    "用柱状数据画的饼图"，而且**不报错、不崩**。
        if "_values" not in kind_body:
            problems.append("setKind: 没清柱状数据（切到环形后 values 残留）")
        if "_slices" not in kind_body:
            problems.append("setKind: 没清环形数据（切回柱状后 slices 残留）")

    # ---------- ⑪ 显隐不许在 syncHeaderSize 里再判一次 ----------
    # 🔴🔴 v0.0.182 的 bug 就是这个形状：显隐有两个写入点，其中一个在
    #    reloadData 之后执行（syncHeaderSize 更晚），把刚设好的状态又改回去。
    #    当时的表现是"图表卡盖住排行前 3 名"；v0.0.184 加饼图时同样的位置
    #    会把饼图重新关掉（"数据算好了、卡片不见了"）。
    sync_body = func_body(stats, "- (void)syncHeaderSize {")
    if not sync_body:
        problems.append("syncHeaderSize 找不到 —— 锚点失效")
    elif re.search(r"showsChart\s*=", sync_body):
        problems.append("syncHeaderSize 又自己算了一遍显隐（唯一的显隐生产者必须是 reloadData）")

    # ---------- ⑫ 相邻色不许撞（v0.0.185） ----------
    # 🔴 用户实际用下来报的第一个视觉问题就是"品牌色撞色"：环形相邻两片
    #    糊成一片，看起来像只画了一片。根因是颜色取自各 App 的图标主色，
    #    而图标主色不受控制（蓝色系 App 扎堆）。
    #    两道防线缺一不可：①按 HSB 拉开（颜色本身不同）②片间描一圈底色缝
    #    （就算颜色真的相同，也能看出边界在哪）。
    close_body = func_body(stats, "static BOOL NBColorsTooClose(UIColor *a, UIColor *b) {")
    if not close_body:
        problems.append("没有「两个颜色是否太像」的判定（撞了也发现不了）")
    else:
        # 🔴 色相是**环**：0.95 和 0.05 只差 0.10。直接相减会把它们当成差很远。
        if "1.0 - dh" not in close_body:
            problems.append("色相差没按环处理（0.95 与 0.05 只差 0.10，直接相减会漏判）")
        if "0.18" not in close_body:
            problems.append("没处理「两边都接近灰阶」的情况（灰阶拿不到色相，只能靠亮度分）")

    if not func_body(stats, "static UIColor *NBSeparateFromColor(UIColor *c, UIColor *prev) {"):
        problems.append("没有相邻色去重函数")

    # 去重必须落在**生成 brands 字典**那一步：这个字典同时喂给环形和排行条形。
    # 只在画图时调色 ⇒ 同一个 App 在饼图里 A 色、在列表里 B 色，比撞色更困惑。
    if not rel:
        pass
    elif "NBSeparateFromColor" not in rel:
        problems.append("生成 brands 时没做相邻去重（环形与列表会各撞各的）")

    donut_body = func_body(stats, "- (void)nbDrawDonut {")
    if not donut_body:
        problems.append("nbDrawDonut 找不到 —— 锚点失效")
    # 🔴 必须同时有"设线宽"和"真的描边"：只设 lineWidth 不 stroke 等于没缝，
    #    而只判 lineWidth 会在删掉 stroke 之后照样绿（M70 第一版就这么恒绿的）。
    elif "lineWidth" not in donut_body or "stroke]" not in donut_body:
        problems.append("环形各片之间没有分隔缝（设了线宽却没描边，或压根没设）")

    return (not problems, "；".join(problems) if problems else
            "两个分母分离，条长只传比例，图表可念，页头重设不递归，图表显隐只有一个生产者")


@chk("I7", "首页是两个页签（记录/统计）：各自带 nav、根不许再套 nav、tab 外观不透明、临时页收起页签", baseline="red")
def _(c):
    """🔴 v0.0.183 新增。守的是**导航骨架**，不是长相。

       用户看完统计页说「这个统计是不是放首页会比较好」，选了「底部两个页签」。
       骨架类改动一旦错了，表现都是"整页打不开"或者"tab bar 出现在奇怪的位置"，
       而且几乎不可能靠读代码回推。这里钉住五件事：

       ① 两个页签的标题必须是中文「记录」「统计」（英文/`stats` 用户看不懂）；
       ② **每个 child 必须各自包一层 UINavigationController** ——
          首页会 push 设置/详情、统计页会 push 自定义时间窗；没有 nav 的话
          `pushViewController:` **静默什么都不做**（不报错、不崩、点了没反应）；
       ③ **根不许再套一层 nav**：`UITabBarController` 必须是 root。
          外面套 nav 会让 tab bar 变成 nav 的 child，出现在导航栏下面；
       ④ iOS 15+ 的 `scrollEdgeAppearance` 默认**透明**：页面滚到边缘时 tab bar
          背景消失、内容从下面透上来（本 App 是自绘灰底白卡片，透上来非常明显）；
       ⑤ 临时页（设置/详情）要 `hidesBottomBarWhenPushed`，否则用户点进设置，
          底下还挂着「记录/统计」两个页签。
       ⚠️🔴 判据域：Makefile 那条**只认 `NotifyBoxApp_FILES` 那一行赋值**，
          不能对整个文件判 —— Makefile 的 `#` 注释不是 C 注释，`mask()` 不认它。
    """
    tab = strip_comments(c["files"].get("app/NBHomeTabBarController.m", ""))
    app = strip_comments(c["files"].get("app/AppDelegate.m", ""))
    sets = strip_comments(c["files"].get("app/SettingsViewController.m", ""))
    detail = strip_comments(c["files"].get("app/NotifyDetailViewController.m", ""))
    mk = c["files"].get("Makefile", "")
    problems = []

    if not tab:
        problems.append("NBHomeTabBarController.m 不存在（还是单页结构）")
    else:
        # ① 标题
        for lit in ('@"记录"', '@"统计"'):
            if lit not in tab:
                problems.append("页签标题缺 %s" % lit)

        # ② 两个 child 各自带 nav
        n_nav = tab.count("[[UINavigationController alloc] initWithRootViewController:")
        if n_nav != 2:
            problems.append("UINavigationController 建了 %d 个（必须 2 个：每个页签各一层，"
                            "否则那个页面的 push 会静默失效）" % n_nav)

        # ③ viewControllers 必须同时含两个 nav
        m = re.search(r"self\s*\.\s*viewControllers\s*=\s*@\[([^\]]*)\]", tab)
        if not m:
            problems.append("找不到 self.viewControllers = @[…] —— 锚点失效")
        else:
            body = m.group(1)
            if body.count(",") < 1:
                problems.append("viewControllers 只塞了一个页签")
            for nm in ("recordsNav", "statsNav"):
                if nm not in body:
                    problems.append("viewControllers 里少了 %s" % nm)

        # ④ iOS 15+ 外观不许留透明
        if "scrollEdgeAppearance" not in tab:
            problems.append("没设 scrollEdgeAppearance（iOS 15+ 滚到边缘时 tab bar 变透明、"
                            "列表内容从下面透上来）")

    # ⑤ 根不许再套 nav
    if "NBHomeTabBarController" not in app:
        problems.append("AppDelegate 没用 NBHomeTabBarController 当根")
    if re.search(r"initWithRootViewController:\s*\[\[ViewController alloc\] init\]", app):
        problems.append("AppDelegate 里还留着旧写法（nav 包 ViewController）⇒ 根被套了两层")

    # ⑥ 临时页收起页签
    if "hidesBottomBarWhenPushed" not in sets:
        problems.append("设置页没设 hidesBottomBarWhenPushed（点进设置底下还挂着两个页签）")
    if "hidesBottomBarWhenPushed" not in detail:
        problems.append("详情页没设 hidesBottomBarWhenPushed")

    # ⑦ 新文件必须进 FILES（只认那一行赋值，别对整个 Makefile 判）
    line = next((ln for ln in mk.splitlines() if ln.lstrip().startswith("NotifyBoxApp_FILES")), "")
    if "app/NBHomeTabBarController.m" not in line:
        problems.append("Makefile 的 NotifyBoxApp_FILES 里没有 NBHomeTabBarController.m"
                        "（报错符号是 _OBJC_CLASS_$_NBHomeTabBarController）")

    # ⑧ 统计入口只许在页签里，设置页那条必须删干净（v0.0.184）
    # ⚠️ `sets` 是 strip_comments 之后的文本 ⇒ 注释里写的"已删除"不会造成假红。
    if "onStats" in sets:
        problems.append("设置页还留着统计入口的 handler（统计只该在页签里）")
    if "NotifyStatsViewController" in sets:
        problems.append("设置页还 import 了统计页（入口没删干净）")
    if 'addActionRow:@"统计"' in sets:
        problems.append("设置页还有一行叫「统计」的入口")

    return (not problems, "；".join(problems) if problems else
            "两个页签各带 nav，根没套 nav，tab 外观不透明，临时页收起页签，新文件已进 FILES")


# ───────────────────────────── 跑判据 ─────────────────────────────
def run_all(ctx, verbose=True):
    bad = {}
    for cid, desc, _bl, fn in CHECKS:
        try:
            ok, detail = fn(ctx)
        except Exception as e:                      # 判据自己崩掉也算红，不许静默跳过
            ok, detail = False, "判据异常：%r" % (e,)
        name = "%s %s" % (cid, desc)
        if ok:
            if verbose:
                print("  PASS  %s" % name)
        else:
            bad[cid] = detail
            if verbose:
                print("  FAIL  %s  —  %s" % (name, detail))
    return bad


# ───────────────────────────── 变异自证 ─────────────────────────────
# 每条变异 = 把某个文件里的一处代码改坏 ⇒ 指定判据**必须**变红。
# 🔴 变异要挑「两个条件同时成立」的反例；这里每条只动一个条件，所以一条判据对应一条变异。
# 🔴 锚点必须存在且唯一 —— 找不到就直接算失败，不许"跳过当没事"。

MUTATIONS = [
    ("M1 目录 chmod 从 NBDataDir 删掉", "NotifyStore.m",
     "        chmod([NOTIFYBOX_LEGACY_DIR fileSystemRepresentation], 0777);",
     "        ;", "B1"),
    ("M2 root 分支 chmod 0777 改成 0755", "Tweak.x",
     "chmod(legacy, 0777);", "chmod(legacy, 0755);", "B2"),
    ("M3 删掉 .tweak_ctor_root 的 chmod", "Tweak.x",
     "chmod([m fileSystemRepresentation], 0666);", ";", "B3"),
    ("M4 删掉 .tweak_ctor 的 chmod", "Tweak.x",
     "chmod([mark fileSystemRepresentation], 0666);", ";", "B4"),
    ("M5 截断标记删掉（回到静默 return）", "app/AppLauncher.m",
     'if (![out containsString:@"…(截断)"]) [out appendString:@"…(截断)"];',
     "/* 静默 return */", "C1"),
    ("M6 截断标记去掉去重守卫", "app/AppLauncher.m",
     'if (![out containsString:@"…(截断)"]) [out appendString:@"…(截断)"];',
     '[out appendString:@"…(截断)"];', "C2"),
    ("M7 把死探针函数名写回代码", "NotifyStore.m",
     "static void NBWriteOldLocationProbe(void)",
     "static void NBAltDataDir(void)", "D1"),
    ("M8 关键词表删掉「路径」", "app/ViewController.m",
     "|打开|路径|[源]", "|打开|[源]", "E1"),
    # 🔴 v0.0.168 新增两条：E1 在这一版把锚点扩成"动态解析宏别名 + 留住方括号"，
    #   等于换了把尺子 ⇒ 新加的两个分支必须各自能被单独证伪，否则又是"换了个说法还是绿的"。
    #   M13 打的是**方括号标签分支**：表里没了 `[源]`，`[源]` 这行就必须红。
    ("M13 关键词表删掉 [源]（方括号标签分支）", "app/ViewController.m",
     "|[源]|[自动清]|", "|[自动清]|", "E1"),
    #   M14 打的是**别名自曝守卫**（unknown 那条）：把 NBLog 宏改成指向别的名字后，
    #   它发出的 11 行标签就重新落回"不在域里"的状态。这时判据必须喊"这个名字我没登记"，
    #   而不是像改锚点之前那样悄悄看不见 ⇒ 这才是真正修掉了那个六个月的盲区。
    ("M14 NBLog 宏指向别的名字（别名自曝守卫）", "Tweak.x",
     "#define NBLog NBSharedLog", "#define NBLog NBLogOther", "E1"),
    ("M9 !oldSeen 分支写死成 NO", "NotifyStore.m",
     "} else if (!oldSeen) {", "} else if (NO) {", "F1"),
    # 🔴 v0.0.158：锚点里**不许写死版本号**。
    #   原来是 `@"0.0.157"`，一发版就变成"锚点出现 0 次"⇒ 变异自证自己先红。
    #   这类判据的失效方式是"每次发版都要人肉改一次"，而漏改的表现是
    #   「变异没跑起来」被写成 FAIL —— 看着像判据有问题，其实是锚点过期。
    #   改成占位符，运行时从 NotifyCommon.h 现读当前版本。
    ("M10 版本号只改一处", "NotifyCommon.h",
     '#define NOTIFYBOX_VER_STR @"@VER@"',
     '#define NOTIFYBOX_VER_STR @"9.9.9"', "A2"),
    ("M11 把恒不成立的死分支加回去", "Tweak.x",
     '    if (getuid() == 0) {\n        NSString *selfPath = @"?";',
     '    if (!NBCanWriteSharedFiles()) {\n        NSString *selfPath = @"?";', "D2"),
    ("M12 少一个右花括号", "NotifyStore.m",
     "BOOL NBCanWriteSharedFiles(void) {",
     "BOOL NBCanWriteSharedFiles(void) {{", "H1"),
    # 🔴 v0.0.176：两条变异分别打 I1 的**两个不同条件**（顺序 / 复位）。
    #    只测一个的话，"判据在另一个维度上是瞎的"看不出来 —— 这是本项目
    #    「变异要挑两个条件同时成立的反例」那条的常规用法。
    ("M15 布防挪到 loadData 之后（交了就等于没交）", "app/ViewController.m",
     "    [self nbArmSlideFromIndex:self.nbPrevTimeIdx toIndex:to];\n"
     "    self.nbPrevTimeIdx = to;\n"
     "    [self loadData];",
     "    self.nbPrevTimeIdx = to;\n"
     "    [self loadData];\n"
     "    [self nbArmSlideFromIndex:self.nbPrevTimeIdx toIndex:to];", "I1"),
    ("M16 prepareForReuse 不复位静音态", "app/NotifyCell.m",
     "    [self nbSetMutedLook:NO animated:NO];", "    ;", "I1"),
    ("M17 入场布防从 viewWillAppear 删掉（首屏永远不播）", "app/ViewController.m",
     "        self.nbEntranceDone = YES;\n        [self nbArmEntrance];",
     "        self.nbEntranceDone = YES;", "I1"),
    ("M18 把入场布防塞进共用尾部 applyItemsAndRefreshUI（每次刷新都重播）", "app/ViewController.m",
     "    [self nbRebuildOverview];\n\n    [self.table reloadData];",
     "    [self nbRebuildOverview];\n    [self nbArmEntrance];\n\n    [self.table reloadData];", "I1"),
    ("M19 删掉 iconBar 的 scrollsToTop = NO（点状态栏回顶全失效）", "app/ViewController.m",
     "    self.iconBar.scrollsToTop = NO;", "    ;", "I2"),
    # 🔴 v0.0.178：六条分别打 I3 的**六个独立条件**。
    #    只测一条的话，"判据在另外五个维度上是瞎的"完全看不出来 ——
    #    M21 尤其重要：它是本判据里唯一的**反向**判据（"不许用 refreshIfChanged"），
    #    肯定式判据挡不住"换成另一个看起来合理的调用"。
    ("M20 删掉「什么都没变」出口的收转圈（转圈只能靠看门狗收）", "app/ViewController.m",
     "            [self2 nbEndPullRefresh];\n            return;",
     "            return;", "I3"),
    ("M21 下拉改成走 refreshIfChanged（库没变就什么都不做）", "app/ViewController.m",
     "    [self requestNCSnapshot];\n    [self reloadKeepingOffset];",
     "    [self refreshIfChanged];\n    [self reloadKeepingOffset];", "I3"),
    ("M22 删掉 keyboardDismissMode（搜索时键盘不收）", "app/ViewController.m",
     "    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;",
     "    ;", "I3"),
    ("M23 把 NBHaptic.m 从 Makefile 的 App FILES 里删掉", "Makefile",
     "app/NBHaptic.m app/NBHomeTabBarController.m NotifyStore.m",
     "app/NBHomeTabBarController.m NotifyStore.m", "I3"),
    ("M24 删掉点图标栏的触觉", "app/ViewController.m",
     "    NBHapticFire(NBHapticKindSoft);\n"
     '    self.filterBundle = [bid isEqualToString:@"全部"] ? nil : bid;',
     '    self.filterBundle = [bid isEqualToString:@"全部"] ? nil : bid;', "I3"),
    ("M25 删掉收尾里的 endRefreshing（转圈永不消失）", "app/ViewController.m",
     "    self.nbPullBusy = NO;\n    [self.nbRefresh endRefreshing];",
     "    self.nbPullBusy = NO;", "I3"),
    # 🔴 v0.0.179：五条，**每个条件各一条**（不是一条打三个）。
    #    理由：一条变异同时干掉三个条件时，判据"有分辨力"这句话就说不清是哪一条有 ——
    #    而这三个条件坏掉的表现完全不同（念不出名字 / 听不出未读 / 听不出选中），
    #    将来某一条被改坏、另外两条还在，共用一条变异就会漏掉。
    #    M29 是唯一的**反向**判据，也是真机上唯一会"点了没反应"的那种坏法。
    ("M26 label 写成 hint（VoiceOver 不念，等于回到「按钮」）", "app/ViewController.m",
     "        b.accessibilityLabel = hasUnread",
     "        b.accessibilityHint = hasUnread", "I4"),
    ("M27 未读不折进 label（只剩那个读不到的红点）", "app/ViewController.m",
     '@"%@，有未读"', '@"%@"', "I4"),
    ("M28 名字改用兜底短名（audit 用户听到 bijia 而不是比价）", "app/ViewController.m",
     "        NSString *a11yName = [self appNameForBundle:bid];",
     "        NSString *a11yName = [self shortName:bid];", "I4"),
    ("M29 把 holder 设成 a11y 元素（按钮被吞掉 ⇒ 双击没反应）", "app/ViewController.m",
     "        [holder addSubview:b];",
     "        holder.isAccessibilityElement = YES;\n        [holder addSubview:b];", "I4"),
    ("M30 选中态不进 traits（只靠那条 3pt 短横线）", "app/ViewController.m",
     "                             | (selected ? UIAccessibilityTraitSelected : 0);",
     "                             | (selected ? 0 : 0);", "I4"),
    # M31 打的不是"有没有做"，而是"是不是只做了一次" —— 同源这条最难自查，
    # 因为两条规则的**初始值一样**，只有改了其中一条的那天才看得出来。
    ("M31 红点自己再算一遍未读（与 label 变成两条规则）", "app/ViewController.m",
     "            dot.hidden = !hasUnread;",
     "            dot.hidden = ![unread containsObject:bid];", "I4"),

    # ===== v0.0.180：cell 整行文案（I5）=====
    # 四个状态各一条变异：它们坏掉的表现完全不同（听不出未读 / 听不出星标 /
    # 听不出×N / 听不出静音），共用一条变异会在"只坏一个"时漏掉。
    ("M32 兜底串改成前缀判断（正文里真有「(无正文)」就被误吞）", "app/NotifyCell.m",
     'if (self.rawTitle.length && ![self.rawTitle isEqualToString:@"(无标题)"]) {',
     'if (self.rawTitle.length && ![self.rawTitle hasPrefix:@"(无"]) {', "I5"),
    ("M33 未读不进文案（角标只剩孤零零一个数字）", "app/NotifyCell.m",
     "    if (self.isUnread) {\n"
     "        NSInteger n = self.unreadCount;\n"
     "        if (n > 1) {\n"
     '            [parts addObject:[NSString stringWithFormat:@"未读，这个 App 共 %ld 条未读", (long)n]];\n'
     "        } else {\n"
     '            [parts addObject:@"未读"];\n'
     "        }\n"
     "    }",
     "    ;", "I5"),
    ("M34 ★ 不进文案（念「星号」或被跳过）", "app/NotifyCell.m",
     '    if (self.starred) [parts addObject:@"已标星"];',
     "    ;", "I5"),
    ("M35 静音不进文案（压暗 + 琥珀竖条零文本 ⇒ 状态不存在）", "app/NotifyCell.m",
     '    if (self.nbMuted) [parts addObject:@"这个 App 已静音"];',
     "    ;", "I5"),
    # 这条打的是"读回时机"：带动画时 alpha 是中间值，念出来取决于谁来问、什么时候问
    ("M36 静音态从 cardView.alpha 反推（动画途中读到中间值）", "app/NotifyCell.m",
     "    self.nbMuted = muted;",
     "    self.nbMuted = (self.cardView.alpha < 0.9);", "I5"),
    ("M37 复用不清文案（念的是上一条的内容）", "app/NotifyCell.m",
     "    self.accessibilityLabel = nil;",
     "    ;", "I5"),
    ("M38 setAppName: 漏调文案出口", "app/NotifyCell.m",
     "    self.rawAppName = name.length ? name : nil;\n"
     "    [self nbRender];\n"
     "    [self nbUpdateA11y];",
     "    self.rawAppName = name.length ? name : nil;\n"
     "    [self nbRender];", "I5"),
    # 「提前返回必须留痕」：状态只记在动画分支里，静默 return 与"没调过"同形
    ("M39 nbSetMutedLook 早返回漏调文案出口", "app/NotifyCell.m",
     "    self.nbMuted = muted;\n    [self nbUpdateA11y];",
     "    self.nbMuted = muted;", "I5"),
    ("M40 覆盖 accessibilityTraits（双击进详情失灵）", "app/NotifyCell.m",
     '    self.accessibilityLabel = parts.count ? [parts componentsJoinedByString:@"，"] : nil;',
     "    self.accessibilityTraits = UIAccessibilityTraitButton;\n"
     '    self.accessibilityLabel = parts.count ? [parts componentsJoinedByString:@"，"] : nil;', "I5"),
    ("M41 ×N 念成「共 3 条」（与未读混淆）", "app/NotifyCell.m",
     '@"共 %ld 条相同内容"',
     '@"共 %ld 条"', "I5"),
    # 同源：文案只许有一个生产者，多一处就是两条规则、改一条必漏一条
    ("M42 ★ 顺手再设一次 accessibilityLabel（两条规则）", "app/NotifyCell.m",
     '    if (self.starred) [parts addObject:@"已标星"];',
     '    if (self.starred) self.accessibilityLabel = @"★";\n'
     '    if (self.starred) [parts addObject:@"已标星"];', "I5"),
    ("M43 时间改读视图状态（绕过 nbTimeText）", "app/NotifyCell.m",
     "    if (self.nbTimeText.length) [parts addObject:self.nbTimeText];",
     "    if (self.timeLabel.text.length) [parts addObject:self.timeLabel.text];", "I5"),
    ("M44 复用直接写 timeLabel.text（nbTimeText 残留上一条）", "app/NotifyCell.m",
     "    [self setTimeText:nil];",
     "    self.timeLabel.text = nil;", "I5"),

    # ===== v0.0.181：统计页（I6）=====
    # 🔴 两个分母各一条变异：写反的表现完全不同（第一名恒 100% vs 条长算不出），
    #    共用一条会在"只错一个"时漏掉。
    ("M45 条长改回像素宽（cell 刚 dequeue 时槽宽是 0 ⇒ 首屏没条形）", "app/NotifyStatsViewController.m",
     "    c.ratio = (self.max > 0) ? ((CGFloat)n / (CGFloat)self.max) : 0;",
     "    c.barFill.frame = CGRectMake(0, 0, 100, 6);\n"
     "    c.ratio = (self.max > 0) ? ((CGFloat)n / (CGFloat)self.max) : 0;", "I6"),
    ("M46 占比错用本屏最大值当分母（第一名恒 100%）", "app/NotifyStatsViewController.m",
     "        ? ((CGFloat)n * 100.0 / (CGFloat)self.grandTotal) : 0;",
     "        ? ((CGFloat)n * 100.0 / (CGFloat)MAX((NSInteger)1, self.max)) : 0;", "I6"),
    ("M47 汇总不取 MAX(ts)（算不出真实跨度）", "NotifyStore.m",
     '        @"COUNT(DISTINCT bundle), MIN(ts), MAX(ts), "',
     '        @"COUNT(DISTINCT bundle), MIN(ts), MIN(ts), "', "I6"),
    ("M48 有正文数不排空串（NULL 和空串是两回事）", "NotifyStore.m",
     '@"SUM(CASE WHEN message IS NOT NULL AND message<>\'\' THEN 1 ELSE 0 END) "',
     '@"SUM(CASE WHEN message IS NOT NULL THEN 1 ELSE 0 END) "', "I6"),
    ("M49 补齐用的日期格式不设时区（和 SQL 的 localtime 对不上）", "NotifyStore.m",
     "    fmt.timeZone = [NSTimeZone localTimeZone];",
     "    ;", "I6"),
    ("M50 日期解析不设 en_US_POSIX（佛历系统下星期几算错）", "app/NotifyStatsViewController.m",
     '            in.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];',
     "            ;", "I6"),
    # 🔴🔴 变异必须**改行为/改字面**，不能只改可达性。
    #    第一版写的是 `if (NO) self.header.chart.summary = …`，字面还在原地
    #    ⇒ 判据按 `chart.summary` 计数，数出来还是 2，**恒绿**。
    #    （这正是 MEMORY 里那条「变异要改行为，不能只改可达性/字面」，
    #      180 刚记过、181 自己又踩了一次。）
    ("M51 按天图表改设到 accessibilityLabel（summary 少一处 ⇒ 图表念不出）", "app/NotifyStatsViewController.m",
     "    self.header.chart.summary = (peakN > 0 && peakIdx >= 0)",
     "    self.header.chart.accessibilityLabel = (peakN > 0 && peakIdx >= 0)", "I6"),
    ("M52 去掉 inSync 闸门（重设 tableHeaderView 递归）", "app/NotifyStatsViewController.m",
     "    if (self.inSync) return;",
     "    ;", "I6"),

    # ===== v0.0.181 修订：图表卡显隐（用户截图报的真 bug）=====
    ("M53 setter 不设 chartCard.hidden（切回「按 App」后卡片盖住列表前几行）", "app/NotifyStatsViewController.m",
     "    self.chartCard.hidden = !showsChart;",
     "    (void)0;", "I6"),
    ("M54 setter 不把 frame 归零（旧高度残留到下一轮）", "app/NotifyStatsViewController.m",
     "    if (!showsChart) self.chartCard.frame = CGRectZero;",
     "    if (!showsChart) self.chartCard.frame = CGRectMake(0, 0, 0, 176);", "I6"),
    ("M55 setChartHidden: 自己再设一次 chartCard.hidden（两个生产者打架）", "app/NotifyStatsViewController.m",
     "    self.header.showsChart = !hidden;",
     "    self.header.showsChart = !hidden;\n    self.header.chartCard.hidden = hidden;", "I6"),
    ("M56 preferredHeight 用回字面量（页头高度与 layoutSubviews 不同步）", "app/NotifyStatsViewController.m",
     "    if (self.showsChart) y += 12.0 + kNBStatsChartH;",
     "    if (self.showsChart) y += 12.0 + 170.0;", "I6"),

    # ===== v0.0.183：底部两个页签（I7）=====
    # 🔴 六条各打一个条件：标题 / 页签数 / 数量 / 外观 / 根结构 / 临时页。
    #    坏掉的表现完全不同（点了没反应 / tab bar 悬在导航栏下 / 内容透上来），
    #    共用一条会在"只坏一个"时漏掉。
    ("M57 AppDelegate 换回旧写法（nav 包 ViewController，根被套两层）", "app/AppDelegate.m",
     "    self.window.rootViewController = [[NBHomeTabBarController alloc] init];",
     "    self.window.rootViewController = [[UINavigationController alloc]\n"
     "        initWithRootViewController:[[ViewController alloc] init]];", "I7"),
    ("M58 只留一个页签（统计没了）", "app/NBHomeTabBarController.m",
     "    self.viewControllers = @[recordsNav, statsNav];",
     "    self.viewControllers = @[recordsNav];", "I7"),
    ("M59 Makefile 漏掉 NBHomeTabBarController.m（链接期才炸）", "Makefile",
     "app/NBHaptic.m app/NBHomeTabBarController.m NotifyStore.m",
     "app/NBHaptic.m NotifyStore.m", "I7"),
    ("M60 统计页签标题写成英文（用户看不懂）", "app/NBHomeTabBarController.m",
     '        [[UITabBarItem alloc] initWithTitle:@"统计"',
     '        [[UITabBarItem alloc] initWithTitle:@"Stats"', "I7"),
    ("M61 不设 scrollEdgeAppearance（滚到边缘 tab bar 变透明、内容透上来）", "app/NBHomeTabBarController.m",
     "        self.tabBar.scrollEdgeAppearance = ap;",
     "        ;", "I7"),
    ("M62 设置页不收起页签（点进设置底下还挂着两个页签）", "app/SettingsViewController.m",
     "    self.hidesBottomBarWhenPushed = YES;",
     "    ;", "I7"),

    # ===== v0.0.184：设置页去入口 + 按 App 环形图 =====
    ("M63 设置页加回统计入口（两个地方进同一个页面）", "app/SettingsViewController.m",
     "    [self addActionRow:@\"规则测试器\"",
     "    [self addActionRow:@\"统计\" sub:nil icon:@\"chart.bar.fill\" tint:gray\n"
     "                   key:@\"stats\" destructive:NO action:@selector(onStats:)];\n"
     "    [self addActionRow:@\"规则测试器\"", "I7"),
    ("M64 环形图不设 summary（VoiceOver 扫过去是空白）", "app/NotifyStatsViewController.m",
     "    self.header.chart.summary = sum;",
     "    ;", "I6"),
    ("M65 setKind: 不清柱状数据（切到环形后 values 残留）", "app/NotifyStatsViewController.m",
     "    if (kind == NBChartKindDonut) {\n        _values = @[];\n        _axis = nil;",
     "    if (kind == NBChartKindDonut) {\n        _axis = nil;", "I6"),
    ("M66 reloadData 不调 feedPieChart（饼图永远不显示）", "app/NotifyStatsViewController.m",
     "        [self feedPieChart];", "        ;", "I6"),
    ("M67 syncHeaderSize 又自己算一遍显隐（v0.0.182 同族回归）", "app/NotifyStatsViewController.m",
     "    CGFloat h = [self.header preferredHeight];",
     "    self.header.showsChart = (self.dimSeg.selectedSegmentIndex != 0);\n"
     "    CGFloat h = [self.header preferredHeight];", "I6"),
    ("M68 环形图不分片上限（67 个 App 全画，每片不到 2°）", "app/NotifyStatsViewController.m",
     "        if (i < kNBStatsPieTopN) {", "        if (YES) {", "I6"),

    # ===== v0.0.185：相邻色去重（I6 ⑫）=====
    ("M69 生成 brands 时不做相邻去重（撞色回潮）", "app/NotifyStatsViewController.m",
     "            c = NBSeparateFromColor(c, prevBrand);",
     "            (void)0;", "I6"),
    ("M70 环形各片之间不描缝（两个 App 主色一样时完全分不清）", "app/NotifyStatsViewController.m",
     "        [p stroke];", "        ;", "I6"),
    ("M71 色相差不按环处理（0.95 与 0.05 会被当成差很远）", "app/NotifyStatsViewController.m",
     "    if (dh > 0.5) dh = 1.0 - dh;", "    ;", "I6"),
]


def selftest(files, base_ctx):
    """把代码改坏 ⇒ 对应判据必须红。全绿就说明判据没有分辨力。"""
    print("\n===== 变异自证（改坏 ⇒ 必须红）=====")
    bad = {}
    for name, rel, old, new, expect in MUTATIONS:
        # 变异表里写的是「AppLauncher.m」这种短名，仓库里的键是「app/AppLauncher.m」这种全路径
        # 🔴 这里曾经只比对 basename 却拿 rel 去比 ⇒ 三处锚点全部"文件缺失"，
        #    而"文件缺失"被我写成了 FAIL 才没有静默通过。**变异表里的每条都必须真跑起来。**
        key = rel if rel in files else next(
            (k for k in files if k.rsplit("/", 1)[-1] == rel), None)
        if key is None:
            print("  ✗ %s —— 在仓库里找不到 %s" % (name, rel))
            bad[name] = "文件缺失"
            continue
        src = files[key]
        # 占位符 @VER@ ⇒ 现读当前版本号（见 MUTATIONS 里 M10 的注释）
        if "@VER@" in old or "@VER@" in new:
            m = re.search(r'NOTIFYBOX_VER_STR @"([^"]+)"',
                          files.get("NotifyCommon.h", ""))
            cur = m.group(1) if m else ""
            if not cur:
                print("  ✗ %s —— 读不到当前版本号，占位符 @VER@ 无法展开" % name)
                bad[name] = "版本号读不到"
                continue
            old = old.replace("@VER@", cur)
            new = new.replace("@VER@", cur)
        # 🔴 "0 次"和"N 次"是**两种病**，不许共用一句诊断：
        #    0 次 = 原文被改过（变异过期了，要更新锚点）；
        #    N 次 = 锚点不够具体（要加长锚点）。混成一句"不唯一"会让人去改错东西。
        n_anchor = src.count(old)
        if n_anchor != 1:
            print("  ✗ %s —— 锚点出现 %d 次（必须唯一）：%r" % (name, n_anchor, old))
            bad[name] = ("锚点找不到（0 次：原文被改过，变异已过期）" if n_anchor == 0
                         else "锚点不唯一（%d 次：锚点不够具体）" % n_anchor)
            continue
        mut = dict(files)
        mut[key] = src.replace(old, new)
        mctx = dict(base_ctx)
        mctx["files"] = mut
        mbad = run_all(mctx, verbose=False)
        if expect in mbad:
            print("  RED-OK  %s  ⇒ %s 如期变红" % (name, expect))
        else:
            print("  ✗ 恒绿！ %s  ⇒ %s 没变红（判据失效）" % (name, expect))
            bad[name] = "判据未变红：" + expect
    return bad


def baseline_check(root, rev, base_ctx):
    """反向对照：拿历史版本的源码跑同一套判据。

    baseline="red" 的判据必须红（证明它是本版新增、且真有分辨力），
    baseline="green" 的必须绿（证明既有性质没被误判）。

    🔴🔴 **`baseline="red"` 是"引入那一版的前一版"，**不是"任意旧版"**。
       这条标注是**累积**的：B2/B3/B4/C1/C2/D2/G1 都标在 v0.0.157 引入时，
       而 E1 在 v0.0.168 改过口径也标了 red。一次只能传一个 REV，
       所以除了"最新那条 red"以外，其余必然以「该红没红」的形式出现在列表里 ——
       **那是标注机制的算术结果，不是判据失效。**
       实测（v0.0.168，`--baseline HEAD`）：wrong_green = 7 条历史判据，
       E1 已从列表里消失（= 旧表确实过不了新尺子，分辨力成立）。
       ⇒ 看这一屏的正确姿势：**只盯你这一版动过的那几条**在不在列表里。
       别去"修"那 7 条 —— 修法只能是给每条 red 标注再记一个引入版号，
       那是又一份会漂移的手工台账，比噪声更贵。
    """
    print("\n===== 反向对照（%s 的源码）=====" % rev)
    old_files, old_raw = load_baseline(root, rev)
    if not old_files:
        print("  ✗ 读不到 %s 的源码（git show 失败）—— 反向对照作废" % rev)
        return {"baseline": "读不到 %s" % rev}
    octx = dict(base_ctx)
    octx["files"] = old_files
    octx["raw"] = old_raw
    obad = run_all(octx, verbose=False)
    bad = {}
    must_red = [cid for cid, _d, bl, _f in CHECKS if bl == "red"]
    must_green = [cid for cid, _d, bl, _f in CHECKS if bl == "green"]
    wrong_green = [c for c in must_red if c not in obad]
    wrong_red = [c for c in must_green if c in obad]
    print("  应为红却仍绿：%s" % (wrong_green or "无"))
    print("  应为绿却变红：%s" % (wrong_red or "无"))
    if wrong_green:
        print("  ⚠️ 上面这些里，只有**本版改过的那几条**算真问题；"
              "其余是 red 标注按引入版累积、而一次只传了一个 REV 的算术结果。")
        bad["baseline/该红没红"] = str(wrong_green)
    if wrong_red:
        bad["baseline/该绿却红"] = str(wrong_red)
    if not wrong_green and not wrong_red:
        print("  ✓ 反向对照通过：%d 条新增判据在旧版全红，%d 条既有判据全绿"
              % (len(must_red), len(must_green)))
    return bad


# ───────────────────────────── 主流程 ─────────────────────────────


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    do_selftest = False
    baseline = None
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--selftest":
            do_selftest = True
        elif a == "--baseline":
            i += 1
            baseline = argv[i] if i < len(argv) else None
        elif a == "--root":
            i += 1
            root = argv[i]
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        i += 1

    files, raw = load(root)
    if not files:
        print("✗ 一个源码文件都没读到（root=%s）" % root)
        return 1
    ctx = {"files": files, "raw": raw, "root": root}

    print("===== 常驻判据（%d 条）@ %s =====" % (len(CHECKS), root))
    bad = run_all(ctx, verbose=True)
    print("  ⇒ PASS %d / FAIL %d" % (len(CHECKS) - len(bad), len(bad)))

    if do_selftest:
        bad.update(selftest(files, ctx))
    if baseline:
        bad.update(baseline_check(root, baseline, ctx))

    print("\n===== 结论 =====")
    if bad:
        print("FAIL %d 项：" % len(bad))
        for k, v in sorted(bad.items()):
            print("  - %s  %s" % (k, v))
        return 1
    print("全部 PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
