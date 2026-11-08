#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NotificationBox 产物（deb）验收 —— v0.0.157 起入库
================================================================================
为什么要有这个文件
--------------------------------------------------------------------------------
到 v0.0.157 为止，这份脚本我已经**从零重写十五遍**（每个版本一份 nb_dlNNN.py），
而每次重写都会重新踩同样的坑。v0.0.157 这一轮就踩了三个：

  A. `control` 在 **control.tar** 里，不在 data.tar 里（dpkg-deb 有两个成员）。
     只在 data.tar 里找 ⇒ 报「control 里 Version 不对」，是脚本的错、不是包的错。
     ⚠️ control.tar 也不一定是 xz（可能是 gz 或未压缩）——按后缀分派，
        **别把 data.tar 的假设照抄过来**。
  B. 🔴🔴 **文件大小不是内容变化的代理。** 157 与 156 的 App/dylib 字节数完全相同
     （624912 / 363280），而内容差 20 万字节 —— 代码增长被段/页对齐的 padding 吸收了。
     上一版里有一句「大小相等 ⇒ 跳过逐字节对拍」，那是**假绿**：
     它把"没法对拍"当成了"不用对拍"。所以这里**永远逐字节比**。
  C. `regions()` 返回三元组，我按二元组解包 ⇒ 最后一节直接崩。
     **"崩了"比"恒绿"好**，但更该一开始就写对。

判据分两类，缺一不可
--------------------------------------------------------------------------------
1. **通用判据**（任何版本都必须成立）：control 字段、payload 里没有源码/判据、
   版本串进新清旧、两个二进制真的改了代码、签名与 UUID 在。
2. **版本特有判据**（由命令行给）：本版新增的串、本版必须清零的旧串、
   以及对应的**反向对照**（旧版里确实有）。

反向对照为什么必须做
--------------------------------------------------------------------------------
「157 里有 `…(截断)`」单独成立不了 —— 也可能 156 里早就有。
只有「157 有 + 156 没有」才证明它是**本版新增**的。
同理「157 里旧串清零」必须配「156 里确实有」，否则无法排除"旧串从来就不在二进制里"。

用法
--------------------------------------------------------------------------------
  python3 checks/nb_pkg.py --ver 0.0.157 --prev 0.0.156 \\
      --new "…(截断)" --new "|直开|打开|路径" \\
      --gone "（root 进程不写共享目录）" \\
      --prev-had "（root 进程不写共享目录）" --prev-had "|直开|打开"

  deb 优先用本地 dist/ 下的同名文件，没有再走 GitHub 的 ci-deb 分支下载。
  纯 ASCII 的串按 ASCII 查、含中文的按 UTF-16LE 查（判断自动，不用手选）。
"""
import base64
import gzip
import hashlib
import io
import json
import lzma
import os
import struct
import sys
import tarfile
import urllib.request
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")
REPO = "yxh41/NotificationBox"
API = "https://api.github.com"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
TOKEN_FILE = os.path.expanduser("~/.nb_gh_token.txt")


# ───────────────────────────── 下载 / 解包 ─────────────────────────────

def _token():
    if not os.path.isfile(TOKEN_FILE):
        return None
    with open(TOKEN_FILE, encoding="utf-8") as f:
        return f.read().strip()


def api(path, retries=8):
    tok = _token()
    last = None
    for a in range(retries):
        try:
            req = urllib.request.Request(API + path)
            if tok:
                req.add_header("Authorization", "Bearer " + tok)
            req.add_header("Accept", "application/vnd.github+json")
            req.add_header("User-Agent", "nb-pkg")
            with OPENER.open(req, timeout=180) as r:
                buf = bytearray()
                while True:
                    c = r.read(1 << 20)
                    if not c:
                        break
                    buf += c
            return json.loads(bytes(buf).decode("utf-8"))
        except Exception as e:                      # 网络抖动：重试并报次数，别静默吞
            last = e
            print("   重试 %d/%d：%s" % (a + 1, retries, type(e).__name__))
    raise SystemExit("拉取失败：%s" % last)


def fetch_deb(ver):
    name = "com.yxh41.notifybox_%s_iphoneos-arm64e.deb" % ver
    local = os.path.join(DIST, name)
    if os.path.isfile(local):
        with open(local, "rb") as f:
            data = f.read()
        print("已存在 %s  %d B  sha256=%s" % (name, len(data),
                                            hashlib.sha256(data).hexdigest()[:32]))
        return data
    tree = api("/repos/%s/git/trees/ci-deb?recursive=1" % REPO)
    sha = next((t["sha"] for t in tree.get("tree", []) if t["path"] == name), None)
    if not sha:
        raise SystemExit("ci-deb 分支上没有 %s —— 先确认 CI 成功并发布了这个版本" % name)
    blob = api("/repos/%s/git/blobs/%s" % (REPO, sha))
    data = base64.b64decode(blob["content"])
    print("下载 %s  %d B  sha256=%s" % (name, len(data), hashlib.sha256(data).hexdigest()))
    os.makedirs(DIST, exist_ok=True)
    with open(local, "wb") as f:
        f.write(data)
    return data


def ar_members(b):
    out, off = [], 8
    while off + 60 <= len(b):
        h = b[off:off + 60]
        try:
            sz = int(h[48:58].decode().strip())
        except ValueError:
            break
        out.append((h[0:16].decode().strip(), b[off + 60:off + 60 + sz]))
        off += 60 + sz + (sz % 2)
    return out


def open_tar(name, d):
    """按后缀分派解压方式。deb 的 control.tar 常常不是 xz。"""
    if name.endswith(".xz"):
        return tarfile.open(fileobj=io.BytesIO(d), mode="r:xz")
    if name.endswith(".gz"):
        return tarfile.open(fileobj=io.BytesIO(gzip.decompress(d)), mode="r:")
    if name.endswith(".tar"):
        return tarfile.open(fileobj=io.BytesIO(d), mode="r:")
    return tarfile.open(fileobj=io.BytesIO(lzma.decompress(d, format=lzma.FORMAT_ALONE)), mode="r:")


def unpack_all(data):
    """返回 (data.tar 里的文件, control.tar 里的文件)。**两个都要**，见文件头 A。"""
    data_files, ctl_files = {}, {}
    for n, d in ar_members(data):
        if n.startswith("data.tar"):
            tgt = data_files
        elif n.startswith("control.tar"):
            tgt = ctl_files
        else:
            continue
        tf = open_tar(n, d)              # 只打开一次：tarfile 是有状态的流
        for m in tf.getmembers():
            if m.isfile():
                tgt[m.name] = tf.extractfile(m).read()
    return data_files, ctl_files


def ctl_modes(data):
    """control.tar 成员的 {名字: 权限位}。

    🔴🔴 v0.0.172 新增。存在的理由是**一场已经差点发生的静默失败**：
       `layout/DEBIAN/postinst` 不以 `.sh` 结尾，而推送脚本的 mode 规则写的是
       `p.endswith('.sh')` ⇒ 它会被推成 100644 ⇒ dpkg exec 失败 ⇒ **postinst 不跑，
       而 deb 照样装上了**。用户在设备上看到的现象是「装了新版，但行为还是旧的」，
       与「代码没改」完全同形。
       ⚠️ 而 `unpack_all()` 只返回**内容**、把 mode 丢了 —— 于是「全量 blob sha 对拍」
       对这件事是瞎的（sha 与 mode 无关）。判据必须显式把 mode 读出来。
    """
    out = {}
    for n, d in ar_members(data):
        if not n.startswith("control.tar"):
            continue
        tf = open_tar(n, d)
        for m in tf.getmembers():
            if m.isfile():
                out[m.name] = m.mode
    return out


# ───────────────────────────── 二进制检查 ─────────────────────────────

def find_str(b, s):
    """在二进制里找一个字符串字面量。

    🔴🔴 v0.0.168 修一个把"在"读成"不在"的尺子错（**假红**，与"恒绿"同族、方向相反）：
       编码不是按**针**决定的，是按**目标字面量**决定的。clang 把含任何非 ASCII 字符的
       `@""` 整串放进 `__ustring`（UTF-16LE），于是 `@"DND#%d bundle=%@ … ⇒ 不弹"` 里的
       `DND#` 在文件里是 `D\0N\0D\0#\0` —— 拿 ASCII 去查**恒为 False**。
       实测代价：v0.0.168 验包把「新版里有 MUTE#」判成 FAIL，差点让我去改一段没坏的代码；
       而同一批里 `DROP#`/`REPL#` 是"有"，只是因为它们的格式串恰好全 ASCII。
       ⇒ 判据：**纯 ASCII 的针必须两种编码都查**。
       （反过来的方向原本就是对的：中文针只查 UTF-16LE，因为中文不可能出现在 ASCII 串里。）
    """
    if not s.isascii():
        return s.encode("utf-16-le") in b
    return (s.encode("ascii") in b) or (s.encode("utf-16-le") in b)


FAT_MAGIC_32 = 0xcafebabe
FAT_MAGIC_64 = 0xcafebabf


def fat_slices(b):
    """fat（通用）二进制 ⇒ [(cputype, 切片起始, 切片长度)]；thin 二进制 ⇒ []。

    🔴 v0.0.164 新增。本仓库从 0.0.160 起 `ARCHS = arm64 arm64e` ⇒ App 与 dylib
       **都是 fat**。旧 `regions()` 直接把文件开头当 Mach-O 头读，而 fat 头里
       偏移 16 处根本不是 `ncmds`（是切片表的内容），解析出的段偏移全是垃圾，
       最后在 `struct.unpack_from` 越界处抛 `struct.error`。
       「崩比恒绿好」，但这一条必须修 —— 否则「代码真的改了」这一整节在 fat 包上
       从来没有真正跑过（每次都在它之前就崩了）。
    """
    if len(b) < 8:
        return []
    magic = struct.unpack_from(">I", b, 0)[0]
    if magic not in (FAT_MAGIC_32, FAT_MAGIC_64):
        return []
    n = struct.unpack_from(">I", b, 4)[0]
    if n <= 0 or n > 16:
        return []                      # 明显不是 fat（防垃圾头）
    out = []
    if magic == FAT_MAGIC_32:
        for i in range(n):
            o = 8 + i * 20
            if o + 20 > len(b):
                return []
            cputype, _sub, off, size, _align = struct.unpack_from(">IIIII", b, o)
            out.append((cputype, off, size))
    else:
        for i in range(n):
            o = 8 + i * 32
            if o + 32 > len(b):
                return []
            cputype, _sub, off, size, _align, _res = struct.unpack_from(">IIQQII", b, o)
            out.append((cputype, off, size))
    return out


def regions(b):
    """返回 (uuid 区间, 签名区间, [(段名, 起始, 长度)])，**全部是文件内绝对偏移**。

    🔴 fat 二进制只在**第一个切片**里找（本包的切片顺序是 arm64 在前）。
       切片的 `fileoff` 都是"相对切片起点"的，所以统统要加 `base` —— 漏加的表现是
       所有 diff 都被归到"头部/其它"，于是 `code` 恒 0（假的"代码没改"）。
    """
    sl = fat_slices(b)
    base = sl[0][1] if sl else 0
    ncmds = struct.unpack_from("<I", b, base + 16)[0]
    off, uuid, sig = base + 32, None, None
    segs = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", b, off)
        if cmd == 0x1b:
            uuid = (off + 8, off + 24)
        elif cmd == 0x1d:
            dataoff, datasize = struct.unpack_from("<II", b, off + 8)
            sig = (base + dataoff, base + dataoff + datasize)
        elif cmd == 0x19:
            name = b[off + 8:off + 24].rstrip(b"\0").decode("ascii", "replace")
            foff, fsize = struct.unpack_from("<QQ", b, off + 40)
            segs.append((name, base + foff, fsize))
        if cmdsize == 0:
            break
        off += cmdsize
    # 🔴 算不出来就明说：宁可红，也不要拿一个错的分类去比。
    for nm, fo, fs in segs:
        if fs and fo + fs > len(b):
            raise SystemExit("regions(): 段 %s 越界（%d+%d > 文件 %d）—— 头解析错了"
                             % (nm, fo, fs, len(b)))
    return uuid, sig, segs


CSMAGIC_EMBEDDED_SIGNATURE = 0xfade0cc0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xfade7171


def entitlements_xml(b):
    """从二进制的 code signature 里取出 entitlements 的 XML 原文；取不到返回 None。

    🔴🔴 v0.0.172 新增，起因是一把**已经不能用了的尺子**：
       验 entitlements 的老办法是「在二进制里搜键名字符串」（v0.0.171 的 nb_ent171.py
       就是这么验的，当时有效）。但这一版的自检页要**把键名念给用户看**，
       于是 `@"com.apple.private.security.no-container"` 这个字面量被编进了 __cstring
       ⇒ 「搜得到」从此恒为真 ⇒ **判据被自己的诊断代码污染，变成恒绿**。
       （同族：v0.0.161 那次"锚点只覆盖一半"，结论都是"绿的理由不是它要证的事"。）
       ⇒ 正解不是换一个更冷门的针，而是**去读签名本身**：
          LC_CODE_SIGNATURE 指向一个 SuperBlob，里面 type=5 的那一条就是 entitlements 原文。
          它和代码里的字符串**物理上不是同一份东西**，污染不了。

    结构（全部大端）：
        SuperBlob   magic(0xfade0cc0) length count 然后 count 个 {type, offset}
                    offset 是相对 SuperBlob 起点的
        Blob(type=5) magic(0xfade7171) length payload=XML
    """
    _u, sig, _segs = regions(b)          # regions 已把 fat 的 base 加好，给的是绝对偏移
    if not sig:
        return None
    off, _end = sig
    if off + 12 > len(b):
        return None
    magic, _length, count = struct.unpack_from(">III", b, off)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        return None
    if count <= 0 or count > 64:
        return None                      # 防垃圾计数
    for i in range(count):
        eo = off + 12 + i * 8
        if eo + 8 > len(b):
            return None
        btype, boff = struct.unpack_from(">II", b, eo)
        if btype != 5:                   # CSSLOT_ENTITLEMENTS
            continue
        p = off + boff
        if p + 8 > len(b):
            return None
        bmagic, blen = struct.unpack_from(">II", b, p)
        if bmagic != CSMAGIC_EMBEDDED_ENTITLEMENTS or blen < 8 or p + blen > len(b):
            return None
        return b[p + 8:p + blen].rstrip(b"\0")
    return None


def same_arch_bytes(x, y):
    """两版都是 fat ⇒ 各取**第一个切片**（同一架构）。否则原样返回。

    🔴 v0.0.164 为什么要切：fat 包里两版切片的长度几乎必然不同（代码长了），
       整文件逐字节比会在**切片边界之后**全面错位 —— 从那里往后每一个字节都对不上，
       差异数会变成几万，而它说明的不是"代码改了多少"，只是"长度不同"。
       切开之后两边的偏移从各自切片起点算，段分类才落在真正的位置上。
    """
    sx, sy = fat_slices(x), fat_slices(y)
    if sx and sy:
        ox, lx = sx[0][1], sx[0][2]
        oy, ly = sy[0][1], sy[0][2]
        return x[ox:ox + lx], y[oy:oy + ly]
    return x, y


def code_diff(x, y):
    """逐字节比两版二进制，按段分类。**不看文件大小** —— 大小相等也要比（见文件头 B）。"""
    xs, ys = same_arch_bytes(x, y)
    u, s, segs = regions(ys)

    def cls(i):
        if u and u[0] <= i < u[1]:
            return "LC_UUID"
        if s and s[0] <= i < s[1]:
            return "签名"
        for nm, fo, fs in segs:
            if fs and fo <= i < fo + fs:
                return nm
        return "头部/其它"

    n = min(len(xs), len(ys))
    diffs = [i for i in range(n) if xs[i] != ys[i]]
    cnt = Counter(cls(i) for i in diffs)
    code = sum(v for k, v in cnt.items()
               if k in ("__TEXT", "__TEXT_EXEC", "__DATA", "__DATA_CONST"))
    # 🔴 读这个数时别把"差异字节多"当成"改得多"：只要有一处函数长度变了 4~8 字节，
    #    它后面的代码**整体位移**，于是成千上万条 `bl` 的**相对偏移**全部重算
    #    （实测 0.0.165 只改了两个布局常量，__TEXT 就差了 207752 字节；总长度没变，
    #    是因为段内 padding 把增量吸收了）。⇒ `code > 0` 只能证「真的重新编译过、代码确实变了」，
    #    **不能**用来衡量改动规模；改了什么要看源码 diff，别拿这个数字交差。
    # 比了多少也要报出来 —— 「两版长度不同 ⇒ 尾部没比」这件事必须写在屏幕上，
    # 否则读者会把它当成"尾部完全相同"。
    return cnt, code, (len(xs), len(ys), n)


# ───────────────────────────── 常驻回归串 ─────────────────────────────
# 这里是「**每一版都必须成立**」的二进制级纪律，和 checks/nb_lint.py 的常驻判据同性质：
# 只不过那些看源码，这些看**真正装到手机上的那个二进制**。
# 加一条的时机：某版因为某个串缺失/残留出过事，就把它钉在这里，别只写在版本脚本里。
MUST_ABSENT = [
    # v0.0.156 删掉的死探针（App 进程里恒走 nil 分支）
    "NBAltDataDir",
    # v0.0.157 删掉的死分支里那句假事实（闸门恒 YES ⇒ 该分支永不执行）
    "（root 进程不写共享目录）",
]

MUST_PRESENT_DYLIB = [
    # v0.0.156：旧位置改由 root 进程代读（三态各一条，缺一条就等于丢了一态）
    "旧位置（由 %@ 代读于 %@）",
    "没有代读记录",
    "dirExists=%d",
    "markerExists=%d",
    "markerUnreadable=%llu",
    "proc=%@",
    ".old_location",
    ".tweak_ctor_root",
    # v0.0.156：探针节的瘦身版，这三条是它「不静默」的凭据
    "读回 OK %d",
    "空值 %lu 项",
    # v0.0.157：root 侧唯一不依赖"能写共享目录"的证据通道
    "ctor 跑过 proc=%@ v=%@ dylib=%@",
    # 🔴 v0.0.172：临时静音从"版本特有"升格为常驻。
    #    升格的理由：用户在 v0.0.168~171 连着四版反馈「静音设了还是弹」，
    #    而其中至少一轮的真因是 **dylib 没重载**（装了新包、跑的还是旧 dylib）。
    #    这两条串是"静音这把刀确实在跑着的那个二进制里"的**唯一机械凭据**：
    #    光看源码有、装上没有，用户看到的现象和不写这段代码完全一样。
    #    刀在（MUTE#）+ 刀坏了会说（MUTE-BAD#），缺一条就剩盲猜。
    "MUTE#",
    "MUTE-BAD#",
]

# App 侧的常驻回归串。和 MUST_PRESENT_DYLIB 分开：两个二进制混在一个表里，
# 「dylib 里必须有」被写成「哪里有一个就行」是迟早的事。
MUST_PRESENT_APP = [
    # 🔴 v0.0.172：沙箱自检四行。它们是删掉 no-container 之后**唯一的验收读数**，
    #    少任何一行，用户报上来"记录没了"时我都无法区分
    #    「白名单没生效」/「目录真不在」/「能读不能写」/「库打不开」这四种病。
    "我的容器：",
    "文档目录：",
    "数据目录：",
    "写测试：",
    # 空值那一支也要在：三态里的"没算出来"不能和"0 条"共用一句话
    "拿不到（nil ⇒ 系统没给数据容器）",
    # 🔴 v0.0.172：把"dylib 到底重载了没"变成读数的那一节。
    #    这一版对静音逻辑一行没改，全靠 SpringBoard 重启才生效 —— 所以在它生效之前，
    #    "静音不生效"和"装了没重启"是**同形的**。这三条是分开它们的唯一凭据。
    "SpringBoard 里的 dylib：",
    "不是同一个版本",
    "backboardd 里的 dylib：",
]


# ───────────────────────────── 主流程 ─────────────────────────────

OK = True


def chk(title, cond, detail=""):
    global OK
    print("  %s  %s%s" % ("PASS" if cond else "FAIL", title, ("   " + detail) if detail else ""))
    OK = OK and bool(cond)


def argval(argv, name, multi=False):
    vals = []
    i = 0
    while i < len(argv):
        if argv[i] == name and i + 1 < len(argv):
            vals.append(argv[i + 1])
            i += 2
            continue
        i += 1
    return vals if multi else (vals[0] if vals else None)


def main(argv):
    ver = argval(argv, "--ver")
    prev = argval(argv, "--prev")
    news = argval(argv, "--new", multi=True)
    gones = argval(argv, "--gone", multi=True)
    prevhads = argval(argv, "--prev-had", multi=True)
    if not ver or not prev:
        print(__doc__)
        return 2

    cur_raw = fetch_deb(ver)
    prev_raw = fetch_deb(prev)
    cur_d, cur_c = unpack_all(cur_raw)
    prev_d, prev_c = unpack_all(prev_raw)
    cur_m = ctl_modes(cur_raw)

    def pick(files, suffix):
        hit = [k for k in files if k.endswith(suffix)]
        if len(hit) != 1:
            raise SystemExit("包内 %s 匹配到 %d 个，无法确定是哪一个：%s"
                             % (suffix, len(hit), hit))
        return files[hit[0]]

    ab = pick(cur_d, "/NotifyBoxApp")
    db = pick(cur_d, "NotifyBox.dylib")
    a0 = pick(prev_d, "/NotifyBoxApp")
    d0 = pick(prev_d, "NotifyBox.dylib")

    print("\n===== 0 包内文件清单 =====")
    for k in sorted(cur_d):
        print("  %8d  %s" % (len(cur_d[k]), k))
    print("  control.tar 成员: %s" % sorted(cur_c))
    chk("包里没把源码/判据打进去",
        not any(k.endswith((".m", ".x", ".h", ".py")) for k in cur_d))
    ctl = (cur_c.get("./control") or cur_c.get("control") or b"").decode("utf-8", "replace")
    for line in ctl.splitlines():
        if line.startswith(("Package:", "Version:", "Architecture:")):
            print("    " + line)
    chk("control 里 Version: %s" % ver, "Version: %s" % ver in ctl)
    chk("control 里 Architecture: iphoneos-arm64e", "iphoneos-arm64e" in ctl)

    # 🔴🔴 v0.0.172：maintainer script 必须真的在包里、而且**带 x 位**。
    #    「内容对」和「会被执行」是两件事：dpkg 靠 exec 跑 postinst，没有 x 位就失败。
    #    这也是"sha 对拍看不见 mode"留下的那个洞，只能在包这一层量。
    pi_key = next((k for k in cur_m if k.endswith("postinst")), None)
    chk("control.tar 里有 postinst", pi_key is not None)
    if pi_key is not None:
        pm = cur_m[pi_key]
        print("    postinst 权限：0%o" % pm)
        chk("postinst 带可执行位（否则 dpkg 静默不跑它）", bool(pm & 0o111))

    print("\n===== 0.5 🔴 App 的 entitlements（v0.0.172 的核心改动）=====")
    # 这一节比的是**签名里的那一条 blob**，不是代码里的字符串 —— 理由见 entitlements_xml()。
    ex = entitlements_xml(ab)
    chk("App 二进制里有 entitlements blob（ldid 真的用了 -S 那份）", ex is not None)
    if ex is not None:
        ent = ex.decode("utf-8", "replace")
        print("    entitlements 原文 %d 字节" % len(ex))
        chk("有 application-identifier",
            "<key>application-identifier</key>" in ent)
        chk("🔴 no-container 已删除（否则通知权限落不了库）",
            "com.apple.private.security.no-container" not in ent)
        chk("🔴 路径白名单 read-write 已加入",
            "com.apple.security.exception.files.absolute-path.read-write" in ent)
        chk("白名单里写的是数据目录",
            "/var/mobile/Library/NotifyBox" in ent)
        chk("platform-application 还在",
            "<key>platform-application</key>" in ent)

    print("\n===== 1 🔴 真的改了代码？（大小相等也要逐字节比）=====")
    for nm, x, y in (("App", a0, ab), ("dylib", d0, db)):
        cnt, code, cmp_info = code_diff(x, y)
        lx, ly, n = cmp_info
        fat = "fat" if fat_slices(y) else "thin"
        print("  %s: 整文件 %d → %d B（差 %+d），%s 同架构切片 %d vs %d B"
              % (nm, len(x), len(y), len(y) - len(x), fat, lx, ly))
        print("     逐字节比了前 %d 字节；差异 %d 字节 = %s"
              % (n, sum(cnt.values()),
                 " + ".join("%s %d" % (k, v) for k, v in cnt.most_common())))
        chk("%s 的代码/数据段有差异（%d 字节）" % (nm, code), code > 0)
        u, s, _ = regions(y)
        chk("%s 有 LC_UUID" % nm, u is not None)
        chk("%s 有 LC_CODE_SIGNATURE" % nm, s is not None)

    print("\n===== 2 版本串 =====")
    for nm, b in (("App", ab), ("dylib", db)):
        chk("%s 里有 %s" % (nm, ver), find_str(b, ver))
        chk("%s 里 %s 的串已清零" % (nm, prev), not find_str(b, prev))

    print("\n===== 3 常驻回归串（每版都必须成立）=====")
    for s in MUST_ABSENT:
        chk("两个二进制里都不该有：%s" % s,
            not find_str(ab, s) and not find_str(db, s))
    for s in MUST_PRESENT_DYLIB:
        chk("dylib 里必须有：%s" % s, find_str(db, s))
    for s in MUST_PRESENT_APP:
        chk("App 里必须有：%s" % s, find_str(ab, s))

    if news or gones or prevhads:
        print("\n===== 4 版本特有判据（含反向对照）=====")
        for s in news:
            chk("新版里有：%s" % s, find_str(ab, s) or find_str(db, s))
            # 🔴🔴 v0.0.164 补：文件头第 2 条写的是「新版有 **+ 旧版没有** 才证明本版新增」，
            #    而这里以前只判了前半句 —— 一个**旧版早就存在**的串照样 PASS。
            #    症状：这一节看起来在验"本版新增了什么"，实际只验了"这个名字此刻在包里"，
            #    拿它当"新增证据"就是假绿（REF §Z4 的第①种）。
            chk("旧版里没有（反向对照）：%s" % s,
                not (find_str(a0, s) or find_str(d0, s)))
        for s in gones:
            chk("新版里已清零：%s" % s, not find_str(ab, s) and not find_str(db, s))
        for s in prevhads:
            chk("旧版里确实有（反向对照）：%s" % s, find_str(a0, s) or find_str(d0, s))

    print("\n===== 结论 =====")
    print("全部 PASS" if OK else "有 FAIL，见上")
    return 0 if OK else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
