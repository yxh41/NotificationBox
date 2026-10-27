#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""查 GitHub Actions 的最近几次运行（只读）。用法：

    PY  tools/ci_status.py            # 最近 5 次
    PY  tools/ci_status.py -n 10

为什么不写进 push_via_api.py：那个脚本只管推，别让它多职责。
token 复用 ~/.nb_gh_token.txt（绝不打印）。
"""
import json
import os
import sys
import urllib.error
import urllib.request

TOK_FILE = os.environ.get("GH_TOKEN_FILE") or os.path.expanduser("~/.nb_gh_token.txt")
SLUG = os.environ.get("GH_SLUG") or "yxh41/NotificationBox"
BRANCH = os.environ.get("GH_BRANCH") or "main"

try:
    TOK = open(TOK_FILE, "r", encoding="utf-8", errors="ignore").read().strip()
except Exception as e:
    print("读不到 token：%r" % (e,))
    sys.exit(2)

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
if not any(h.__class__.__name__ == "HTTPSHandler" for h in OPENER.handlers):
    print("✗ 这个 python 用不了 https（_ssl 坏了）⇒ 换 versions/3.13.12（无 .old）")
    sys.exit(3)


def api(path):
    req = urllib.request.Request(
        "https://api.github.com" + path,
        headers={
            "Authorization": "Bearer " + TOK,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "notifybox-ci",
        },
    )
    try:
        with OPENER.open(req, timeout=40) as r:
            return json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        print("HTTP %d %s" % (e.code, e.read().decode("utf-8", "replace")[:400]))
        sys.exit(1)


n = 5
if "-n" in sys.argv:
    n = int(sys.argv[sys.argv.index("-n") + 1])

d = api("/repos/%s/actions/runs?branch=%s&per_page=%d" % (SLUG, BRANCH, n))
runs = d.get("workflow_runs") or []
if not runs:
    print("没有运行记录（分支 %s）" % BRANCH)

for r in runs:
    print("%-10s %-12s %-22s %s" % (
        r.get("status"), r.get("conclusion") or "-",
        (r.get("head_sha") or "")[:12], (r.get("head_commit") or {}).get("message", "").split("\n")[0][:56]))
    print("           id=%s  %s  %s" % (r.get("id"), r.get("created_at"), r.get("html_url")))
    if r.get("status") != "completed":
        print("           ↑ 未完成")
