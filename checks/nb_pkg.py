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


# ───────────────────────────── 二进制检查 ─────────────────────────────

def find_str(b, s):
    """含中文的 @"" 落 __ustring（UTF-16LE），纯 ASCII 的落 __cstring。
    判断自动做，不要手选 —— 用 ASCII 提取器查中文恒为 0，那是假红。"""
    if s.isascii():
        return s.encode("ascii") in b
    return s.encode("utf-16-le") in b


def regions(b):
    ncmds = struct.unpack_from("<I", b, 16)[0]
    off, uuid, sig = 32, None, None
    segs = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", b, off)
        if cmd == 0x1b:
            uuid = (off + 8, off + 24)
        elif cmd == 0x1d:
            dataoff, datasize = struct.unpack_from("<II", b, off + 8)
            sig = (dataoff, dataoff + datasize)
        elif cmd == 0x19:
            name = b[off + 8:off + 24].rstrip(b"\0").decode("ascii", "replace")
            foff, fsize = struct.unpack_from("<QQ", b, off + 40)
            segs.append((name, foff, fsize))
        if cmdsize == 0:
            break
        off += cmdsize
    return uuid, sig, segs


def code_diff(x, y):
    """逐字节比两版二进制，按段分类。**不看文件大小** —— 大小相等也要比（见文件头 B）。"""
    u, s, segs = regions(y)

    def cls(i):
        if u and u[0] <= i < u[1]:
            return "LC_UUID"
        if s and s[0] <= i < s[1]:
            return "签名"
        for nm, fo, fs in segs:
            if fs and fo <= i < fo + fs:
                return nm
        return "头部/其它"

    diffs = [i for i in range(min(len(x), len(y))) if x[i] != y[i]]
    cnt = Counter(cls(i) for i in diffs)
    code = sum(v for k, v in cnt.items()
               if k in ("__TEXT", "__TEXT_EXEC", "__DATA", "__DATA_CONST"))
    return cnt, code


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

    cur_d, cur_c = unpack_all(fetch_deb(ver))
    prev_d, prev_c = unpack_all(fetch_deb(prev))

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

    print("\n===== 1 🔴 真的改了代码？（大小相等也要逐字节比）=====")
    for nm, x, y in (("App", a0, ab), ("dylib", d0, db)):
        cnt, code = code_diff(x, y)
        print("  %s: %d → %d B（差 %+d）" % (nm, len(x), len(y), len(y) - len(x)))
        print("     差异 %d 字节 = %s"
              % (sum(cnt.values()), " + ".join("%s %d" % (k, v) for k, v in cnt.most_common())))
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

    if news or gones or prevhads:
        print("\n===== 4 版本特有判据（含反向对照）=====")
        for s in news:
            chk("新版里有：%s" % s, find_str(ab, s) or find_str(db, s))
        for s in gones:
            chk("新版里已清零：%s" % s, not find_str(ab, s) and not find_str(db, s))
        for s in prevhads:
            chk("旧版里确实有（反向对照）：%s" % s, find_str(a0, s) or find_str(d0, s))

    print("\n===== 结论 =====")
    print("全部 PASS" if OK else "有 FAIL，见上")
    return 0 if OK else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
