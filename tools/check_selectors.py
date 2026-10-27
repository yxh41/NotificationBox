# -*- coding: utf-8 -*-
"""第 ⑨ 道源码自检：**id 接收者的选择器必须有声明**。

🔴🔴 为什么必须有这一道（v0.0.72 真实事故）：
    `Tweak.x` 里的 `gBBServer` / `gNCDispatcher` / `gNCSource` / `gCSDestination`
    类型全是 `id`。往 `id` 上发一个**整份文件里从没声明过**的选择器，
    clang 报 `error: no known instance method for selector '...'` —— **编译期直接失败**。

    而当时已有的 8 道文本自检**全绿**：括号配平对、宏可达性对、行尾对、版本对……
    因为"选择器有没有声明"**根本不在那 8 道的判据域里**。
    ⇒ 这是"判据域必须等于变异域"的又一次实例：新增了调用，就要新增检查调用的判据。

它查什么：
    ① 收集整份 TU 里所有**已声明**的选择器：
       - `@interface ... (分类)` 块里的方法声明（这些就是手写的私有 API 声明区）
       - `%hook` 块里的方法定义（Logos 生成声明）
    ② 收集所有 `[g<大写开头>... ]` 这种对全局对象的消息发送，取出选择器
    ③ 未声明的逐条报出来（附行号），退出码 1

⛔ 它**不**判断"这个方法在这台机器上存不存在" —— 那是运行时 `respondsToSelector:` 的事。
"""
import io
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TWEAK = os.path.join(REPO, "Tweak.x")

# 这些是 NSObject / 集合上的基础方法，不需要（也不该）在私有声明区里重复声明
ALLOW = {
    "respondsToSelector:", "isKindOfClass:", "isEqual:", "isEqualToString:", "class",
    "copy", "mutableCopy", "count", "anyObject", "allKeys", "allObjects", "length",
    "valueForKey:", "setValue:forKey:", "description", "synchronized",
}


def read(path):
    with io.open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()


def strip_comments(s):
    """剥注释但保留字符串内容；同时保留行号（用等长空白替换，避免行号错位）。"""
    out = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == '"':
            j = i + 1
            while j < n:
                if s[j] == "\\":
                    j += 2
                    continue
                if s[j] == '"':
                    break
                j += 1
            out.append(s[i:j + 1])
            i = j + 1
            continue
        if c == "/" and i + 1 < n and s[i + 1] == "/":
            while i < n and s[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if c == "/" and i + 1 < n and s[i + 1] == "*":
            j = s.find("*/", i + 2)
            j = n if j < 0 else j + 2
            while i < j:
                out.append("\n" if s[i] == "\n" else " ")
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def selector_of(method_tail):
    """把 `foo:(id)a bar:(BOOL)b { ... }` 的头部还原成 `foo:bar:`。

    🔴 只取**顶格层级**的冒号标签：参数里可能嵌着别的方法调用
       （`forSectionID:[self x:1]`），把那些也算进来就会得到假选择器。
    """
    parts = []
    i, n = 0, len(method_tail)
    depth = 0
    cur = []
    while i < n:
        c = method_tail[i]
        if c in "([{":
            depth += 1
            if depth == 1 and c == "(":
                # 返回类型括号，跳过整段
                d = 1
                i += 1
                while i < n and d:
                    if method_tail[i] == "(":
                        d += 1
                    elif method_tail[i] == ")":
                        d -= 1
                    i += 1
                depth = 0
                continue
            cur.append(c)
            i += 1
            continue
        if c in ")]}":
            depth = max(0, depth - 1)
            cur.append(c)
            i += 1
            continue
        if c == ";" or c == "{":
            break
        if c == ":" and depth == 0:
            word = "".join(cur).strip().split()
            label = word[-1] if word else ""
            parts.append(label + ":")
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    if not parts:
        word = "".join(cur).strip().split()
        if word:
            return word[-1], False
        return None, False
    return "".join(parts), True


DECL_RE = re.compile(r"^\s*[-+]\s*\(", re.M)


def collect_declared(text):
    """扫描 `@interface ... @end` 与 `%hook ... %end` 之间的方法声明/定义。"""
    declared = set()
    lines = text.split("\n")
    mode = None      # 'iface' | 'hook'
    for idx, line in enumerate(lines):
        st = line.strip()
        if st.startswith("@interface"):
            mode = "iface"
            continue
        if st.startswith("%hook"):
            mode = "hook"
            continue
        if st.startswith("@end") or st.startswith("%end"):
            mode = None
            continue
        if mode and DECL_RE.match(line):
            # 方法签名可能跨行：拼到 `;` 或 `{` 为止
            buf = line
            k = idx
            while k + 1 < len(lines) and (";" not in buf) and ("{" not in buf):
                k += 1
                buf += " " + lines[k].strip()
            sel, is_multi = selector_of(buf)
            if sel:
                declared.add(sel if is_multi else sel)
    return declared


def find_calls(text, id_receivers):
    """所有 `[gXxx ...]` 形式的消息发送 → (行号, 选择器)。

    🔴 只查**类型是 `id` 的接收者**。`[gRecent removeObjectsForKeys:x]` 里
       `gRecent` 是 `NSMutableDictionary *`，编译器认识这个类型、也知道这个方法，
       根本不会报错 —— 把它算进来就是假红（判据域必须等于变异域：
       要证的是"**编译器不知道类型**的那些接收者有没有声明"）。
    """
    out = []
    for m in re.finditer(r"\[\s*(g[A-Z]\w*)", text):
        if m.group(1) not in id_receivers:
            continue
        start = m.end()
        depth = 1
        i = start
        n = len(text)
        while i < n and depth:
            if text[i] == "[":
                depth += 1
            elif text[i] == "]":
                depth -= 1
            i += 1
        body = text[start:i - 1]
        sel, _ = selector_of(body)
        if sel:
            line_no = text.count("\n", 0, m.start()) + 1
            out.append((line_no, sel))
    return out


ID_DECL_RE = re.compile(r"^\s*(?:__block\s+)?static\s+(?:__strong\s+|__unsafe_unretained\s+)?id\s+(g[A-Z]\w*)")


def collect_id_receivers(text):
    """哪些 `gXxx` 全局变量的**声明类型是 id**（这类接收者才需要选择器已声明）。"""
    out = set()
    for line in text.split("\n"):
        m = ID_DECL_RE.match(line)
        if m:
            out.add(m.group(1))
    return out


def main():
    # 允许指定别的文件 —— 唯一用途是**反向对照**：
    # 拿上一版（有 bug 的那版）跑一遍，它必须报错。判据必须有区分力，
    # 否则"全绿"只证明这个脚本什么都没做（八种假绿第 ① 型）。
    path = sys.argv[1] if len(sys.argv) > 1 else TWEAK
    raw = read(path)
    text = strip_comments(raw)
    declared = collect_declared(text)
    id_receivers = collect_id_receivers(text)
    calls = find_calls(text, id_receivers)
    print("文件：%s" % path)
    print("已声明选择器 %d 条 / id 型全局对象 %d 个 / 对它们发消息 %d 处"
          % (len(declared), len(id_receivers), len(calls)))
    print("  id 型接收者：%s" % ", ".join(sorted(id_receivers)))
    bad = []
    for line_no, sel in calls:
        if sel in ALLOW:
            continue
        if sel not in declared:
            bad.append((line_no, sel))
    if not bad:
        print("  ✅ 全部已声明")
        return 0
    print("  ❌ %d 处调用了**未声明**的选择器（CI 会报 no known instance method）:" % len(bad))
    for line_no, sel in bad:
        print("     %s:%d  %s" % (os.path.basename(path), line_no, sel))
    print("  ⇒ 修法：在 `@interface NSObject (NBClearNC)` 里照 dump 的签名补一行。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
