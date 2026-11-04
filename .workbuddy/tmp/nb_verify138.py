# -*- coding: utf-8 -*-
"""
v0.0.138 判据。三层跑：
  ① 正向：当前工作区必须全绿
  ② 负向变异：每条的锚点被破坏一次，该条**必须变红**（不变红 = 恒绿假判据）
  ③ 反向对照：用 v0.0.137 的文件跑新判据，kind="new" 的必须红、kind="inv" 的必须绿

判据写法纪律：
  · 判"源码里不含 X" 一律用 code()（剥字符串+注释），否则字符串字面量会让否定式恒绿
  · 判"确实写了 X 这句话/这个串" 用 lite()（剥注释、留字符串）
  · 取函数体用 braced()（花括号配平），不许用"找行首 }"——缩进的 } 会吞到下一个顶层 }
  · 变异必须**全替换**（同一常量出现两次时只换第一处 ⇒ 仍命中 ⇒ 假绿）
"""
import sys, os, subprocess, re, glob, unicodedata

def _find_repo():
    """从脚本位置往上找，第一个含 NotifyCommon.h 的目录就是仓库根。"""
    d = os.path.dirname(os.path.abspath(__file__))
    for _ in range(8):
        if os.path.isfile(os.path.join(d, 'NotifyCommon.h')):
            return d
        nd = os.path.dirname(d)
        if nd == d:
            break
        d = nd
    raise SystemExit('找不到仓库根（没有 NotifyCommon.h）')


REPO = _find_repo()
BASE = '480b919'          # v0.0.137 最后一次提交


def read(path, rev=None):
    if rev is None:
        p = os.path.join(REPO, path)
        if not os.path.isfile(p):
            return None
        with open(p, 'rb') as f:
            return f.read().decode('utf-8', 'replace')
    out = subprocess.run(['git', 'show', '%s:%s' % (rev, path)],
                         cwd=REPO, capture_output=True)
    if out.returncode != 0:
        return None
    return out.stdout.decode('utf-8', 'replace')


def strip_comments(s):
    """剥 C 注释，保留字符串。"""
    out = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == '"' or c == "'":
            q = c
            out.append(c)
            i += 1
            while i < n:
                if s[i] == '\\':
                    out.append(s[i:i + 2]); i += 2; continue
                out.append(s[i])
                if s[i] == q:
                    i += 1; break
                i += 1
            continue
        if s.startswith('//', i):
            j = s.find('\n', i)
            i = n if j < 0 else j
            continue
        if s.startswith('/*', i):
            j = s.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue
        out.append(c); i += 1
    return ''.join(out)


def strip_strings(s):
    """剥字符串字面量（先剥注释），用于否定式判据。"""
    s = strip_comments(s)
    return re.sub(r'"(?:[^"\\]|\\.)*"', '""', s)


def lite(s):
    return strip_comments(s)


def code(s):
    return strip_strings(s)


def braced(s, anchor):
    """从 anchor 所在位置起，按花括号配平取出 {...} 内部文本。"""
    i = s.find(anchor)
    if i < 0:
        return None
    j = s.find('{', i)
    if j < 0:
        return None
    depth = 0
    k = j
    while k < len(s):
        if s[k] == '{':
            depth += 1
        elif s[k] == '}':
            depth -= 1
            if depth == 0:
                return s[j + 1:k]
        k += 1
    return None


def fbody(s, sig):
    """取函数体（签名后必须见到 { 之前不出现 ;）。"""
    i = s.find(sig)
    if i < 0:
        return None
    seg = s[i:i + 2000]
    # 签名到 { 之间不许有 ;
    b = seg.find('{')
    semi = seg.find(';')
    if b < 0 or (0 <= semi < b):
        return None
    return braced(s, sig)


# ---------------- 判据定义 ----------------
# kind: "new" = v0.0.138 必须有；"inv" = 不该变（反向对照必须仍绿）
C = []


def add(name, kind, fn, mut):
    C.append((name, kind, fn, mut))


def n(str_or_none):
    return str_or_none if str_or_none is not None else ""


# --- 版本号单一来源 ---
add("S01 NotifyCommon.h 定义 NOTIFYBOX_VER_STR=\"0.0.138\"", "new",
    lambda f: '#define NOTIFYBOX_VER_STR @"0.0.138"' in lite(n(f('NotifyCommon.h'))),
    ('NotifyCommon.h', '@"0.0.138', '@"9.9.9'))

add("S02 control 版本=0.0.138", "new",
    lambda f: re.search(r'^Version: 0\.0\.138$', n(f('control')), re.M) is not None,
    ('control', 'Version: 0.0.138', 'Version: 0.0.137'))

add("S03 Info.plist 两处版本都是 0.0.138", "new",
    lambda f: n(f('Resources/Info.plist')).count('<string>0.0.138</string>') == 2,
    ('Resources/Info.plist', '<string>0.0.138</string>', '<string>0.0.137</string>'))

add("S04 control/Info.plist 不再出现 0.0.137", "new",
    lambda f: ('0.0.137' not in n(f('control'))) and ('0.0.137' not in n(f('Resources/Info.plist'))),
    ('Resources/Info.plist', '<string>0.0.138</string>', '<string>0.0.137</string>'))

add("S05 Tweak.x 的 NB_VER_STR 是别名、不是字面量", "new",
    lambda f: ('#define NB_VER_STR NOTIFYBOX_VER_STR' in lite(n(f('Tweak.x'))))
              and not re.search(r'#define\s+NB_VER_STR\s+@"', lite(n(f('Tweak.x')))),
    ('Tweak.x', '#define NB_VER_STR NOTIFYBOX_VER_STR', '#define NB_VER_STR @"0.0.138"'))

add("S06 NOTIFYBOX_VER_STR 的定义在 Tweak.x 引用之前(含 import)", "new",
    lambda f: _def_before_use(f),
    ('Tweak.x', '#import "NotifyCommon.h"', '// #import "NotifyCommon.h"'))


def _def_before_use(f):
    tw = lite(n(f('Tweak.x')))          # 必须 lite：注释里写同一句会让 find 恒成功
    i_imp = tw.find('#import "NotifyCommon.h"')
    i_use = tw.find('#define NB_VER_STR NOTIFYBOX_VER_STR')
    return (0 <= i_imp) and (0 <= i_use) and (i_imp < i_use)


# --- ctor 顺序：探针必须是第一句 ---
def _probe_first(f):
    tw = lite(n(f('Tweak.x')))
    body = braced(tw, '%ctor {')
    if body is None:
        return False
    for line in body.split('\n'):
        t = line.strip()
        if not t or t.startswith('//'):
            continue
        return t.startswith('NBWriteBootProbe();')
    return False


add("S07 %ctor 的第一句可执行语句是 NBWriteBootProbe();", "new",
    _probe_first,
    ('Tweak.x', 'NBWriteBootProbe();\n\n    gRecent', 'gRecent'))


# --- 自愈：不许删目录 ---
def _heal_body(f):
    return fbody(code(n(f('NotifyStore.m'))), 'BOOL NBHealDataDirOwnership(void)')


add("S08 NBHealDataDirOwnership 不含 removeItemAtPath", "new",
    lambda f: _heal_body(f) is not None and 'removeItemAtPath' not in _heal_body(f),
    ('NotifyStore.m', 'return NO;\n}\n\n// ───────────────────────────── v0.0.138 启动探针',
     'removeItemAtPath:NOTIFYBOX_LEGACY_DIR error:nil;\n    return NO;\n}\n\n// ───────────────────────────── v0.0.138 启动探针'))

def _heal_body_lite(f):
    # ⚠️ 这条判的是**日志文案**，文案在字符串字面量里 ⇒ 必须 lite()。
    #    用 code()（剥字符串）去判就是恒红；反过来判"不含某标识符"才该用 code()。
    return fbody(lite(n(f('NotifyStore.m'))), 'BOOL NBHealDataDirOwnership(void)')


add("S09 NBHealDataDirOwnership 写不进时要 NSLog 报出来", "new",
    lambda f: _heal_body_lite(f) is not None
              and 'NSLog' in _heal_body_lite(f)
              and '⚠️ 数据目录存在但当前身份写不进' in _heal_body_lite(f),
    ('NotifyStore.m', '@"[NotifyBox] ⚠️ 数据目录存在但当前身份写不进 dir=%@',
     '@"[NotifyBox] 数据目录存在 dir=%@'))


# --- 标记写入不再静默 ---
def _ctor_marker(f):
    return n(f('Tweak.x'))


add("S10 .tweak_ctor 写入结果被检查(BOOL mw = ...)", "new",
    lambda f: 'BOOL mw = [md writeToFile:mark atomically:YES];' in lite(_ctor_marker(f)),
    ('Tweak.x', 'BOOL mw = [md writeToFile:mark atomically:YES];',
     '[md writeToFile:mark atomically:YES];'))

add("S11 .tweak_ctor 写失败有 NSLog", "new",
    lambda f: '⚠️ 写 .tweak_ctor 失败' in lite(_ctor_marker(f)),
    ('Tweak.x', '⚠️ 写 .tweak_ctor 失败', '⚠️ 写标记失败X'))

add("S12 .tweak_ctor_root 写入带 error 参数并检查", "new",
    lambda f: 'if (![body writeToFile:m atomically:YES encoding:NSUTF8StringEncoding error:&rerr])'
              in lite(_ctor_marker(f)),
    ('Tweak.x', 'error:&rerr])', 'error:nil])'))


# --- 探针本身 ---
add("S13 NotifyCommon.h 声明 int NBWriteBootProbe(void)", "new",
    lambda f: re.search(r'int\s+NBWriteBootProbe\(void\);', lite(n(f('NotifyCommon.h')))) is not None,
    ('NotifyCommon.h', 'int      NBWriteBootProbe(void);', 'int      NBWriteBootProbeX(void);'))

add("S14 NotifyStore.m 实现 NBWriteBootProbe(非 static)", "new",
    lambda f: re.search(r'^int NBWriteBootProbe\(void\) \{', n(f('NotifyStore.m')), re.M) is not None,
    ('NotifyStore.m', 'int NBWriteBootProbe(void) {', 'static int NBWriteBootProbe(void) {'))

add("S15 探针试了 /private/var/tmp/NotifyBox", "new",
    lambda f: '@"/private/var/tmp/NotifyBox"' in lite(n(f('NotifyStore.m'))),
    ('NotifyStore.m', '@"/private/var/tmp/NotifyBox"', '@"/private/var/tmp/NotifyBoxX"'))

add("S16 探针两种写法都在(atomically:YES 与 open+O_CREAT+O_TRUNC)", "new",
    lambda f: ('atomically:YES' in code(n(f('NotifyStore.m'))))
              and re.search(r'open\(\[f2 fileSystemRepresentation\],\s*O_WRONLY \| O_CREAT \| O_TRUNC',
                            n(f('NotifyStore.m'))) is not None,
    ('NotifyStore.m', 'O_WRONLY | O_CREAT | O_TRUNC', 'O_WRONLY'))

add("S17 探针写 /tmp 自身失败也要 NSLog", "new",
    lambda f: '⚠️ %@ 探针写 /tmp 失败' in lite(n(f('NotifyStore.m'))),
    ('NotifyStore.m', '⚠️ %@ 探针写 /tmp 失败', '探针写 /tmp 失败X'))

add("S18 探针落盘路径带进程名(nb_boot_<proc>.txt)", "new",
    lambda f: '"/private/var/tmp/nb_boot_%@.txt"' in lite(n(f('NotifyStore.m'))),
    ('NotifyStore.m', '"/private/var/tmp/nb_boot_%@.txt"', '"/private/var/tmp/nb_boot.txt"'))

add("S19 AppDelegate 也跑一遍探针", "new",
    lambda f: 'NBWriteBootProbe();' in lite(n(f('app/AppDelegate.m'))),
    ('app/AppDelegate.m', 'NBWriteBootProbe();', '/*NBWriteBootProbe();*/'))

add("S20 envCheck 里有 /private/var/tmp 探针段", "new",
    lambda f: 'v0.0.138 启动探针（/private/var/tmp）' in lite(n(f('NotifyStore.m'))),
    ('NotifyStore.m', 'v0.0.138 启动探针（/private/var/tmp）', 'v0.0.138 启动探针X'))

add("S21 NotifyStore.m 引入 fcntl.h 与 dlfcn.h", "new",
    lambda f: ('#import <fcntl.h>' in lite(n(f('NotifyStore.m'))))
              and ('#import <dlfcn.h>' in lite(n(f('NotifyStore.m')))),
    ('NotifyStore.m', '#import <fcntl.h>', '// #import <fcntl.h>'))


# --- 不该变的 ---
add("B01 NBCanWriteSharedFiles 仍是 getuid()==0 判定", "inv",
    lambda f: 'cached = (getuid() == 0) ? 0 : 1;' in code(n(f('NotifyStore.m'))),
    ('NotifyStore.m', 'cached = (getuid() == 0) ? 0 : 1;', 'cached = 1;'))

add("B02 数据目录仍是常量宏", "inv",
    lambda f: '#define NOTIFYBOX_LEGACY_DIR  @"/var/mobile/Library/NotifyBox"'
              in lite(n(f('NotifyCommon.h'))),
    ('NotifyCommon.h', '#define NOTIFYBOX_LEGACY_DIR  @"/var/mobile/Library/NotifyBox"',
     '#define NOTIFYBOX_LEGACY_DIR  [NBDataDir() stringByAppendingPathComponent:@"x"]'))

add("B03 root 进程仍不写共享目录(NBCanWriteSharedFiles 在 ctor 里用)", "inv",
    lambda f: 'if (!NBCanWriteSharedFiles()) {' in code(n(f('Tweak.x'))),
    ('Tweak.x', 'if (!NBCanWriteSharedFiles()) {', 'if (0) {'))

add("B04 NBDataDir 里仍只许非 root 建目录", "inv",
    lambda f: 'if (NBCanWriteSharedFiles()) {' in code(n(f('NotifyStore.m'))),
    ('NotifyStore.m', 'if (NBCanWriteSharedFiles()) {', 'if (1) {'))

add("B05 过滤器仍是 springboard + backboardd", "inv",
    lambda f: ('"com.apple.springboard"' in lite(n(f('NotifyBox.plist'))))
              and ('"com.apple.backboardd"' in lite(n(f('NotifyBox.plist')))),
    ('NotifyBox.plist', 'com.apple.backboardd', 'com.apple.backboarddX'))




# ---------- 编译期邻近判据：字符串提前闭合 ----------
# 🔴 2026-11-04 CI 实测：`@"…靠"App 能否看到 /tmp"区分：…"` 这种写法在**文本判据里全绿**
#    （引号成对、字数正常），clang 一上来就 error: expected ':' ——
#    字符串在 `靠` 后面就被闭合了，`App` 变成了标识符。
#    上一版同样栽过：24 条文本判据全绿，clang 死在 `use of undeclared identifier 'mtxt'`。
#    ⇒ 这一类必须有一条**扫描式的**判据：字符串收尾引号后紧跟标识符/CJK 就是错。
def _bad_strings(s):
    out = []
    i, n = 0, len(s)
    line = 1
    state = 'code'
    open_line = 0

    def ident(c):
        if c.isalnum() or c == '_':
            return True
        return unicodedata.east_asian_width(c) in ('W', 'F')   # 全角/CJK

    while i < n:
        c = s[i]
        if c == '\n':
            line += 1
        if state == 'code':
            if s.startswith('//', i):
                state = 'lc'; i += 2; continue
            if s.startswith('/*', i):
                state = 'bc'; i += 2; continue
            if c == '"':
                state = 'str'; open_line = line; i += 1; continue
            i += 1; continue
        if state == 'lc':
            if c == '\n':
                state = 'code'
            i += 1; continue
        if state == 'bc':
            if s.startswith('*/', i):
                state = 'code'; i += 2; continue
            i += 1; continue
        if c == '\\':
            i += 2; continue
        if c == '"':
            nxt = s[i + 1] if i + 1 < n else '\n'
            if nxt != '\n' and ident(nxt):
                out.append(open_line)
            state = 'code'; i += 1; continue
        if c == '\n':
            out.append(open_line)
            state = 'code'; i += 1; continue
        i += 1
    return out


_SRC = ['NotifyStore.m', 'Tweak.x', 'NotifyCommon.h'] \
       + sorted('app/' + os.path.basename(x)
                for x in glob.glob(os.path.join(REPO, 'app', '*.m'))) \
       + sorted('app/' + os.path.basename(x)
                for x in glob.glob(os.path.join(REPO, 'app', '*.h')))


def _scan_count(f):
    tot = 0
    for p in _SRC:
        if p.startswith('app/'):
            txt = n(f(p))
        else:
            txt = n(f(p))
        if txt:
            tot += len(_bad_strings(txt))
    return tot


add("S22 全仓源码无「字符串提前闭合」(收尾引号后紧跟标识符/CJK)", "inv",
    lambda f: _scan_count(f) == 0,
    ('NotifyStore.m', '靠「App 能否看到 /tmp」区分', '靠"App 能否看到 /tmp"区分'))

add("S23 探针提示语用「」而不是 ASCII 引号", "new",
    lambda f: ('靠「App 能否看到 /tmp」区分' in lite(n(f('NotifyStore.m'))))
              and ('上一行说了「看不到 /private/var/tmp」' in lite(n(f('NotifyStore.m')))),
    ('NotifyStore.m', '靠「App 能否看到 /tmp」区分', '靠"App 能否看到 /tmp"区分'))


# ---------------- 驱动 ----------------
FILES = ['NotifyCommon.h', 'NotifyStore.m', 'Tweak.x', 'control',
         'Resources/Info.plist', 'app/AppDelegate.m', 'NotifyBox.plist']

_cache = {}


def loader(rev=None):
    def f(p):
        key = (rev, p)
        if key not in _cache:
            _cache[key] = read(p, rev)
        return _cache[key]
    return f


def run(rev=None, overrides=None, verbose=False):
    files = loader(rev) if not overrides else None
    if overrides:
        base = dict(_cache)
        def f(p):
            if p in overrides:
                return overrides[p]
            return loader(rev)(p)
    else:
        f = files
    res = []
    for name, kind, fn, mut in C:
        try:
            ok = bool(fn(f))
        except Exception as e:
            ok = False
            if verbose:
                print("   ! %s 抛异常: %r" % (name, e))
        res.append((name, kind, ok))
    return res


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'all'
    fail = 0

    def show(title, rows, must_red_new=False, must_green_inv=False):
        nonlocal fail
        bad = []
        print("\n===== %s =====" % title)
        for name, kind, ok in rows:
            if must_red_new and kind == 'new' and ok:
                bad.append(name); tag = 'FAIL(该红没红)'
            elif must_red_new and kind == 'inv' and not ok:
                bad.append(name); tag = 'FAIL(inv 不许受影响)'
            elif must_green_inv and not ok:
                bad.append(name); tag = 'FAIL'
            else:
                tag = 'PASS'
            print("  [%s] %-58s %s" % (tag, name, kind))
        fail += len(bad)
        print("  ---- %d/%d %s ----" % (len(rows) - len(bad), len(rows),
                                        'PASS' if not bad else 'FAIL'))
        return bad

    if mode in ('all', 'pos'):
        rows = run()
        show("① 正向（当前工作区，必须全绿）", rows, must_green_inv=True)
        if mode == 'pos':
            return fail

    if mode in ('all', 'mut'):
        print("\n===== ② 负向变异（每条锚点破坏一次，必须变红）=====")
        mutfail = 0
        for name, kind, fn, mut in C:
            path, old, new = mut
            src = read(path)
            if src is None:
                print("  [SKIP] %s —— 文件读不到" % name); mutfail += 1; continue
            if old not in src:
                print("  [SKIP] %s —— 锚点不在文件里: %r" % (name, old[:50])); mutfail += 1; continue
            broken = src.replace(old, new)          # 全替换
            rows = run(overrides={path: broken})
            hit = dict(((nm, k), ok) for nm, k, ok in rows)
            got = hit[(name, kind)]
            if got:
                print("  [FAIL] %-58s 变异后仍绿 ⇒ 恒绿假判据" % name); mutfail += 1
            else:
                print("  [PASS] %-58s 变异后变红" % name)
        print("  ---- 变异 %d/%d ----" % (len(C) - mutfail, len(C)))
        fail += mutfail

    if mode in ('all', 'rev'):
        rev = sys.argv[2] if len(sys.argv) > 2 else BASE
        print("\n===== ③ 反向对照（v0.0.137 %s 跑新判据）=====" % rev)
        rows = run(rev=rev)
        show("③ 反向对照：new 必须红、inv 必须绿", rows, must_red_new=True)

    print("\n总失败数 = %d" % fail)
    return 1 if fail else 0


if __name__ == '__main__':
    sys.exit(main())
