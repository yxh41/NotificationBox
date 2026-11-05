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


def load(root):
    """把仓库里所有源码读进两个 dict：str（判据用）与 bytes（行尾/编码判据用）。

    🔴 为什么必须同时留 bytes：G1 判的是行尾，而 `text=True` 的通用换行会把 CRLF
       悄悄翻译成 LF ⇒ 判据恒绿。这是「读不到 ≠ 不存在」的变种：
       **被读取层改写过的内容，不能用来判断它原本是什么。**
    """
    files, raw = {}, {}
    for dirpath, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git", ".workbuddy", "packages", "dist", "obj")]
        for n in names:
            if not n.endswith(SRC_EXT):
                continue
            full = os.path.join(dirpath, n)
            rel = os.path.relpath(full, root).replace("\\", "/")
            with open(full, "rb") as f:
                b = f.read()
            raw[rel] = b
            files[rel] = b.decode("utf-8", "replace")
    for extra in ("control", "Resources/Info.plist"):
        p = os.path.join(root, *extra.split("/"))
        if os.path.exists(p):
            with open(p, "rb") as f:
                b = f.read()
            raw[extra] = b
            files[extra] = b.decode("utf-8", "replace")
    return files, raw


def load_baseline(root, rev):
    """用 `git show REV:path` 把某个历史版本的全部源码读出来（反向对照用）。"""
    listing = subprocess.run(["git", "-C", root, "ls-tree", "-r", "--name-only", rev],
                             capture_output=True, text=True, encoding="utf-8")
    if listing.returncode != 0:
        return None, None
    files, raw = {}, {}
    for rel in listing.stdout.splitlines():
        if not (rel.endswith(SRC_EXT) or rel in ("control", "Resources/Info.plist")):
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

@chk("E1", "每个 NBSharedLog 标签都能过关键词筛选表", baseline="red")
def _(c):
    vc = strip_comments(find1(c["files"], "ViewController.m") or "")
    m = re.search(r'kNBKeyLineTable\s*=\s*\n?\s*@"([^"]+)"', vc)
    if not m:
        return (False, "找不到 kNBKeyLineTable")
    kws = m.group(1).split("|")
    emitted = set(re.findall(r'NBSharedLog\(@"\[([^\]"]+)\]', strip_comments(allsrc(c["files"]))))
    if not emitted:
        return (False, "一个带标签的 NBSharedLog 都没扫到（判据锚点失效）")
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

@chk("G1", "源码/control/Info.plist 纯 LF", baseline="red")
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
     "|打开|路径\";", "|打开\";", "E1"),
    ("M9 !oldSeen 分支写死成 NO", "NotifyStore.m",
     "} else if (!oldSeen) {", "} else if (NO) {", "F1"),
    ("M10 版本号只改一处", "NotifyCommon.h",
     "#define NOTIFYBOX_VER_STR @\"0.0.157\"",
     "#define NOTIFYBOX_VER_STR @\"0.0.156\"", "A2"),
    ("M11 把恒不成立的死分支加回去", "Tweak.x",
     '    if (getuid() == 0) {\n        NSString *selfPath = @"?";',
     '    if (!NBCanWriteSharedFiles()) {\n        NSString *selfPath = @"?";', "D2"),
    ("M12 少一个右花括号", "NotifyStore.m",
     "BOOL NBCanWriteSharedFiles(void) {",
     "BOOL NBCanWriteSharedFiles(void) {{", "H1"),
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
        if src.count(old) != 1:
            print("  ✗ %s —— 锚点出现 %d 次（必须唯一）：%r" % (name, src.count(old), old))
            bad[name] = "锚点不唯一"
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
