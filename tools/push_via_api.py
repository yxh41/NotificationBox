#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用 GitHub REST API 把本地 HEAD 推上去 —— 绕开走不通的 github.com:443。

## 为什么需要这个文件

本机（Windows）实测：
  · `git push` 需要连 `github.com:443` ⇒ 直连超时、走代理 `CONNECT tunnel failed, response 502`
  · 而 `api.github.com:443` 直连返回 200

⇒ 只是 git 协议那条路不通，不是断网。于是改走 **Git Data API**（blob → tree → commit → PATCH ref）。

## 为什么值得放进仓库

它是这个项目**唯一能用的推送通道**，之前一直躺在临时目录里（会被清掉）。
丢了它就得从零再踩一遍上面那两个错误。

## 用法

    GH_TOKEN_FILE=~/.nb_gh_token.txt python tools/push_via_api.py

环境变量（都可省，省了用默认值）：
    GH_TOKEN_FILE   存 token 的文件路径（**脚本绝不打印 token 内容**）
    REPO_DIR        本地仓库路径（默认 = 本文件所在目录的上一级）
    GH_SLUG         owner/repo，默认 yxh41/NotificationBox
    GH_BRANCH       分支，默认 main

## 🔴 验收口径：不比 commit sha，比**逐文件 blob sha**

API 建的 commit，committer 由服务端填 ⇒ sha 必然和本地不同。
真正要比的是「远端 tree 里每个文件的 sha == 本地 `git rev-parse HEAD:<path>`」——
这比"sha 相同"更硬：它直接证明远端每个文件的字节都等于本地 HEAD 里那份。
"""
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.environ.get("REPO_DIR") or os.path.dirname(HERE)
TOK_FILE = os.environ.get("GH_TOKEN_FILE") or os.path.expanduser("~/.nb_gh_token.txt")
OWNER_REPO = os.environ.get("GH_SLUG") or "yxh41/NotificationBox"
BRANCH = os.environ.get("GH_BRANCH") or "main"
API = "https://api.github.com"

TOK = ""
try:
    with open(TOK_FILE, "r", encoding="utf-8", errors="ignore") as f:
        TOK = f.read().strip()
except Exception as e:
    print("读不到 token 文件 %s：%r" % (TOK_FILE, e))
    sys.exit(2)
if not TOK:
    print("token 文件是空的")
    sys.exit(2)

# 🔴 直连 api.github.com（显式不带 ProxyHandler）：代理对 api 偶发 502。
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

# 🔴🔴 起手先验 https 能力 —— 这条报错**长得完全不像网络问题**，实测白丢一轮：
#   本机默认 `python`（.workbuddy/binaries/python/versions/3.13.12.old.10788）
#   的 `_ssl` DLL 加载失败（`ImportError: DLL load failed while importing _ssl`），
#   于是 urllib **静默地不注册 HTTPSHandler**，等到真正发请求时才抛
#   `URLError('unknown url type: https')` —— 看着像 URL 拼错，其实是这个解释器残废。
#   同一台机器上 versions/3.13.12（无 .old 后缀）是好的 ⇒ 判据 = 换解释器，不是改代码。
if not any(h.__class__.__name__ == "HTTPSHandler" for h in OPENER.handlers):
    try:
        import ssl as _ssl_probe  # noqa: F401
        _why = "ssl 可导入，但 urllib 没注册 HTTPSHandler"
    except Exception as _e:
        _why = "import ssl 失败：%r" % (_e,)
    print("✗ 这个 python 用不了 https（%s）" % _why)
    print("  典型症状：请求时报 URLError('unknown url type: https')，看着像 URL 错了。")
    print("  本机可用解释器：C:/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe")
    print("  当前解释器  ：%s" % sys.executable)
    sys.exit(3)


def scrub(s):
    if not s:
        return s or ""
    s = str(s).replace(TOK, "***")
    if len(TOK) > 12:
        s = s.replace(TOK[:12], "ghp_***")
    return s


def api(method, path, body=None, ok=(200, 201)):
    headers = {
        "Authorization": "Bearer " + TOK,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "notifybox-push",
    }
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=data, headers=headers, method=method)
    try:
        with OPENER.open(req, timeout=40) as r:
            txt = r.read().decode("utf-8", "replace")
            return r.status, (json.loads(txt) if txt.strip() else {})
    except urllib.error.HTTPError as e:
        return e.code, {"_err": scrub(e.read().decode("utf-8", "replace")[:1200])}
    except Exception as e:
        return -1, {"_err": scrub(repr(e))}


def git(args):
    p = subprocess.run(["git"] + args, cwd=REPO_DIR, capture_output=True)
    if p.returncode != 0:
        print("git 失败 %s\n%s" % (" ".join(args), scrub(p.stderr.decode("utf-8", "replace"))))
        sys.exit(1)
    return p.stdout


def gt(args):
    return git(args).decode("utf-8", "replace")


def main():
    print("repo   : %s" % REPO_DIR)
    print("token  : 长度 %d（不回显任何片段）" % len(TOK))
    print()

    local_head = gt(["rev-parse", "HEAD"]).strip()
    local_parent = gt(["rev-parse", "HEAD^"]).strip()
    msg = gt(["log", "-1", "--format=%B"])
    author = gt(["log", "-1", "--format=%an"]).strip()
    email = gt(["log", "-1", "--format=%ae"]).strip()
    print("本地 HEAD : %s" % local_head[:12])
    print("本地父提交: %s" % local_parent[:12])
    print("消息首行  : %s" % msg.splitlines()[0])
    print()

    st, r = api("GET", "/repos/%s/git/ref/heads/%s" % (OWNER_REPO, BRANCH))
    if st != 200:
        print("取远端 ref 失败 HTTP %s: %s" % (st, r.get("_err")))
        return 1
    remote_head = r["object"]["sha"]
    print("远端 %-6s: %s" % (BRANCH, remote_head[:12]))

    if remote_head != local_parent:
        # 🔴 不按 sha 判、按 **tree** 判：API 建的 commit 由服务端填 committer，
        #    内容相同 sha 也不同 ⇒ 第二次推送必然撞上 remote_head != local_parent。
        #    要证明的是「远端此刻的文件内容 == 本地父提交的文件内容」，那个量就是 tree sha。
        st2, r2 = api("GET", "/repos/%s/git/commits/%s" % (OWNER_REPO, remote_head))
        if st2 != 200:
            print("取远端 commit 失败 HTTP %s" % st2)
            return 1
        remote_parent_tree = r2["tree"]["sha"]
        local_parent_tree = gt(["rev-parse", local_parent + "^{tree}"]).strip()
        if remote_parent_tree == local_parent_tree:
            print("关系      : sha 不同但 **tree 相同** ⇒ 内容等价，按快进处理")
        else:
            m2 = (r2.get("message") or "").splitlines()
            print()
            print("!!! 远端 head 与本地父提交的 tree **不同** ⇒ 真分叉，不是「sha 不同而已」。")
            print("    远端最新: %s" % (m2[0] if m2 else "(取不到)"))
            print("    ⇒ 不自动 force，先人工对齐。")
            return 3
    else:
        print("关系      : 远端正指向本地父提交（快进）")
    print()

    st, r = api("GET", "/repos/%s/git/commits/%s" % (OWNER_REPO, remote_head))
    if st != 200:
        print("取远端 commit 失败 HTTP %s: %s" % (st, r.get("_err")))
        return 1
    base_tree = r["tree"]["sha"]
    print("base_tree : %s" % base_tree[:12])
    print()

    raw = gt(["diff-tree", "-r", "--no-commit-id", "--name-status", local_head + "^", local_head])
    changes = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        changes.append((parts[0][0], parts[-1]))
    print("这一个 commit 改了 %d 个文件：" % len(changes))
    for stc, p in changes:
        print("  %s  %s" % (stc, p))
    print()

    tree_items, fails = [], []
    for stc, path in changes:
        if stc == "D":
            tree_items.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
            print("  删除  %s" % path)
            continue
        blob = git(["show", "%s:%s" % (local_head, path)])
        st, r = api("POST", "/repos/%s/git/blobs" % OWNER_REPO,
                    {"content": base64.b64encode(blob).decode("ascii"), "encoding": "base64"})
        if st not in (200, 201):
            fails.append("blob %s HTTP %s %s" % (path, st, r.get("_err")))
            print("  !!! blob 失败 %s" % path)
            continue
        mode = "100755" if path.endswith(".sh") else "100644"
        tree_items.append({"path": path, "mode": mode, "type": "blob", "sha": r["sha"]})
        print("  blob  %s  %s  %d B" % (r["sha"][:10], path, len(blob)))
    if fails:
        print()
        print("!!! 有 blob 失败，中止（远端一个字没改）：")
        for f in fails:
            print("  - %s" % f)
        return 1

    st, r = api("POST", "/repos/%s/git/trees" % OWNER_REPO,
                {"base_tree": base_tree, "tree": tree_items})
    if st not in (200, 201):
        print("建 tree 失败 HTTP %s: %s" % (st, r.get("_err")))
        return 1
    new_tree = r["sha"]
    print()
    print("新 tree   : %s" % new_tree[:12])

    st, r = api("POST", "/repos/%s/git/commits" % OWNER_REPO,
                {"message": msg, "tree": new_tree, "parents": [remote_head],
                 "author": {"name": author, "email": email}})
    if st not in (200, 201):
        print("建 commit 失败 HTTP %s: %s" % (st, r.get("_err")))
        return 1
    new_commit = r["sha"]
    print("新 commit : %s" % new_commit[:12])

    st, r = api("PATCH", "/repos/%s/git/refs/heads/%s" % (OWNER_REPO, BRANCH),
                {"sha": new_commit, "force": False})
    if st not in (200, 201):
        print("更新 ref 失败 HTTP %s: %s" % (st, r.get("_err")))
        return 1
    print("分支已移动: %s -> %s" % (BRANCH, new_commit[:12]))
    print()

    print("=" * 70)
    print("验收：远端 tree 的每个文件 blob sha 与本地 HEAD:<path> 逐一对比")
    st, r = api("GET", "/repos/%s/git/trees/%s?recursive=1" % (OWNER_REPO, new_tree))
    if st != 200:
        print("取新 tree 失败 HTTP %s" % st)
        return 1
    if r.get("truncated"):
        print("!!! tree 太大被截断，验收不完整")
    remote_files = {e["path"]: e["sha"] for e in r["tree"] if e["type"] == "blob"}
    local_files = {}
    # 🔴 `-c core.quotepath=false` 不能省：默认 true 时非 ASCII 路径被转成八进制转义，
    #    同一个文件在远端叫「docs/换提示音-…md」、本地被读成「"docs/\346\215\242…"」
    #    ⇒ 冒出一对「仅远端有 / 仅本地有」，内容其实是同一个 ⇒ **假红**。
    for line in gt(["-c", "core.quotepath=false", "ls-tree", "-r", local_head]).splitlines():
        meta, path = line.split("\t", 1)
        local_files[path] = meta.split()[2]

    only_remote = sorted(set(remote_files) - set(local_files))
    only_local = sorted(set(local_files) - set(remote_files))
    diff = sorted(p for p in (set(remote_files) & set(local_files))
                  if remote_files[p] != local_files[p])
    print("远端文件数 %d / 本地文件数 %d" % (len(remote_files), len(local_files)))
    print("仅远端有：%s" % (only_remote or "无"))
    print("仅本地有：%s" % (only_local or "无"))
    print("内容不同：%s" % (diff or "无"))
    print()

    allok = True
    for stc, p in changes:
        if stc == "D":
            ok = p not in remote_files
            print("  [%s] 删除 %s" % ("OK" if ok else "FAIL", p))
        else:
            ok = remote_files.get(p) == local_files.get(p)
            print("  [%s] %s  %s" % ("OK" if ok else "FAIL", p, (remote_files.get(p) or "(缺)")[:10]))
        if not ok:
            allok = False

    print()
    if allok and not only_remote and not only_local and not diff:
        print("结果：PASS —— 远端 %s 的内容与本地 HEAD %s 逐字节一致"
              % (new_commit[:12], local_head[:12]))
        print("⚠️ commit sha 必然不同（服务端填 committer）⇒ 验收口径是逐文件 blob 对拍。")
        return 0
    print("结果：FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
