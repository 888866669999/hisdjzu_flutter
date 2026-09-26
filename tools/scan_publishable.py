# 扫描「假如 git init 并提交，实际会入库的那部分文件」，找出敏感值。
#
# ===== 为什么需要它（与 audit_sensitive.py 的分工）=====
# audit_sensitive.py 是**模式匹配**：查「长得像学号/身份证的串」。
# 它不知道哪些文件会被 .gitignore 排除，所以全盘扫时会报一片 —— 反而看不清
# 真正会公开的那部分是否干净。
#
# 本脚本补上这一环：先用 gitignore 的匹配语义筛出「会入库的文件」，
# 只扫这些 —— 它的结论能直接回答「发布出去安全吗」。
#
# 与 audit_sensitive.py 的另一处区别：这里**比对真实值**。
# 模式匹配只能发现「长得像」的，抓不到「用户名、设备号」这类无固定形状的值。
#
# ===== 为什么具体值放在本地文件里 =====
# 要确认「某个真实值没被带出去」，必须知道那个值是什么。但把真实值写进
# 本脚本，就等于**脚本本身成了泄露源**（这仓库是要公开的）。
# 因此真实值从 `tmp/known-pii.txt` 读取 —— 该路径已被 .gitignore 排除。
# 文件不存在时跳过「精确值」检查，只做模式匹配（依然能用，只是弱一点）。
#
# 格式：每行一条，`标签 = 值`。
#
# 用法: python tools/scan_publishable.py
import io
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_ignore import parse, ignored  # noqa: E402

# 本地真实值清单（不入库）
KNOWN_FILE = 'tmp/known-pii.txt'

# 人工放进去的占位值（连续零 / 明显的假值）
PLACEHOLDER = re.compile(r'^(2025000000\d{2}|110101200001010000|20000101|'
                         r'00000000000000|20250901)$')

SKIP_DIRS = {'node_modules', '.git', '.idea', '.dart_tool', 'build',
             '.zcode', '__pycache__', '.gradle', 'local-repo'}
BIG = 60 * 1024 * 1024

# 只扫这些文本类型（其余是二进制，模式匹配没有意义）
TEXT_EXT = ('.dart', '.kt', '.java', '.py', '.sh', '.md', '.json', '.json5',
            '.yaml', '.yml', '.properties', '.html', '.txt', '.gradle',
            '.kts', '.xml', '.gitignore', '.metadata')


def load_known():
    """读取本地真实值清单，返回 [(标签, bytes)]。

    ===== 短值也要查（姓名就是两个汉字）=====
    早先按「长度 ≥ 4 才比对」过滤，理由是一两个字符在任何文本里都会命中 ——
    那条规则对**拉丁字符**成立，对**中文姓名**不成立：真实姓名通常就是
    2–3 个汉字，恰恰是最该确认「有没有被写进语料」的一类值。
    而姓名不会像单个字母那样在源码里到处出现。

    因此判据改成按**字符类别**分别定长度：
      · 含中文 → 2 个字符起就查（姓名、地名）；
      · 纯 ASCII → 6 个字符起（学号、口令这类），避免单字母变量名噪音。
    """
    out = []
    if not os.path.exists(KNOWN_FILE):
        print('提示：%s 不存在，跳过精确值检查（只做模式匹配）\n' % KNOWN_FILE)
        return out
    for ln in io.open(KNOWN_FILE, encoding='utf-8'):
        ln = ln.strip()
        if not ln or ln.startswith('#'):
            continue
        if '=' not in ln:
            continue
        label, val = ln.split('=', 1)
        val = val.strip()
        has_cjk = any('\u4e00' <= ch <= '\u9fff' for ch in val)
        min_len = 2 if has_cjk else 6
        if len(val) >= min_len:
            out.append((label.strip(), val.encode('utf-8')))
    return out


def tracked_files():
    """按 .gitignore 语义筛出会入库的文件。"""
    rules = parse('.gitignore')
    out = []
    for root, dirs, files in os.walk('.'):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            p = os.path.relpath(os.path.join(root, f), '.').replace(os.sep, '/')
            if not ignored(p, rules):
                out.append(p)
    return sorted(out)


def main():
    known = load_known()
    files = tracked_files()
    print('会入库的文件：%d 个' % len(files))
    print('精确值条目：%d 条\n' % len(known))

    hits = {}
    for p in files:
        if not p.lower().endswith(TEXT_EXT):
            continue
        try:
            if os.path.getsize(p) > BIG:
                continue
            b = open(p, 'rb').read()
        except Exception:
            continue
        for label, pat in known:
            if pat in b:
                hits.setdefault(label, []).append(p)
        txt = b.decode('utf-8', 'ignore')
        # 学号：本校为 12 位、20 开头。
        #
        # **要排除「通知单编号」**：课表页里那种 12 位数字
        # 是教务系统给排课通知单的流水号，形如「20 + 年份 + 序号」，
        # 与学号完全同形、正则区分不了。不排除的话每次扫描都报假警，
        # 报告长期飘红，真出问题时反而没人看。
        # 判据是**回头看的上下文**（见下面的 ctx）。
        for m in re.finditer(r'(?<!\d)20\d{10}(?!\d)', txt):
            if PLACEHOLDER.match(m.group(0)):
                continue
            # **两侧都看**：真实页面写「通知单编号：202620271695」（词在前），
            # 而说明文档写「形如 202620271695 的数字是通知单编号」（词在后）。
            # 只看一侧会漏掉后者，于是工具自己的注释被报成泄露源。
            ctx = txt[max(0, m.start() - 40):m.end() + 40]
            if re.search(r'通知单编号|tzdbh|singleNo', ctx):
                continue
            hits.setdefault('可疑学号 ' + m.group(0), []).append(p)
        # 身份证：18 位（末位可为 X）
        for m in re.findall(r'(?<![0-9Xx])[1-9]\d{5}(?:19|20)\d{2}'
                            r'(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])'
                            r'\d{3}[0-9Xx](?![0-9Xx])', txt):
            if not PLACEHOLDER.match(m):
                hits.setdefault('可疑身份证 ' + m, []).append(p)
        # 会话凭据：一旦入库就是可直接复用的登录态
        if re.search(r'JSESSIONID=[A-Za-z0-9]{10,}', txt):
            hits.setdefault('会话 Cookie', []).append(p)
        # 明文密码：只看**带引号的字面量**，且要求它长得像密码。
        #
        # 判据分两层（早先按「赋值给 password 的串」扫，误报满天飞）：
        #   1. 必须是引号包起来的字符串 —— 变量名（`_password`）与注释里的
        #      `passwd` 都不是字面量，不该报；
        #   2. 值本身要含大写字母/数字/符号中至少两类 —— 存储键
        #      （`sdjzu_jw_password` 这种全小写加下划线）不是密码。
        # 真正的测试账号口令（大小写 + 数字 + 符号）两条都满足。
        for m in re.finditer(
                r'(?:password|passwd|pwd)\s*[=:]\s*["\']([^"\']{6,40})["\']',
                txt, re.I):
            val = m.group(1)
            kinds = sum(bool(re.search(rx, val)) for rx in
                        (r'[A-Z]', r'\d', r'[^A-Za-z0-9]'))
            if kinds >= 2:
                hits.setdefault('疑似明文密码 ' + val[:2] + '***', []).append(p)

    if not hits:
        print('结论：将公开的文件里未发现敏感值')
        return 0
    print('发现以下问题：')
    for label, ps in sorted(hits.items()):
        print('  %s: %d 个文件' % (label, len(ps)))
        for x in ps[:10]:
            print('      ' + x)
    return 1


if __name__ == '__main__':
    sys.exit(main())
