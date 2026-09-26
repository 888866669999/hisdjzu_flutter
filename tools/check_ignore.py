# check_ignore.py —— 不依赖 git 仓库，复核 .gitignore 是否真的挡住了敏感路径。
#
# ===== 为什么需要它 =====
# 发布前要反复确认「真实 PII、会话数据、第三方大二进制不会被提交」。
# 正常做法是 `git check-ignore -v <路径>`，但它有个致命的坑：
# **没有 git 仓库时它以 128 退出、且不打印任何内容** —— 看起来就像
# 「没有任何规则匹配」。这个项目长期没有仓库，如果那时跑
# `git check-ignore` 会得到「全部沉默」的假象。
#
# 因此这里按 git 的语义手写一遍匹配（锚定、目录前缀、`!` 取反），
# 用固定的路径清单做断言 —— 既能在没有仓库时复核，也能当 .gitignore 的
# 回归测试（改了规则跑一下就知道有没有漏）。
#
# 用法: python tools/check_ignore.py
import io
import fnmatch
import os
import sys


def parse(path):
    """读取 .gitignore，返回 [(模式, 是否取反)]。

    只处理规则行：跳过空行与注释；`!` 前缀表示白名单（重新纳入）。
    """
    out = []
    for ln in io.open(path, encoding='utf-8'):
        ln = ln.rstrip('\n').rstrip('\r')
        if not ln.strip() or ln.lstrip().startswith('#'):
            continue
        neg = ln.startswith('!')
        out.append((ln[1:] if neg else ln, neg))
    return out


def match(pat, p):
    """判断单个模式是否匹配路径 p（p 为相对仓库根的 / 分隔路径）。

    ===== 尾部斜杠不影响「任意层级」这条规则 =====
    git 的判定是：**斜杠出现在开头或中间**才锚定到本 .gitignore 所在目录；
    斜杠出现在**末尾**时不算（那只表示「只匹配目录」）。
    因此 `.gradle/` 能匹配 `android/.gradle/x`，与 `.gradle` 同效；
    而 `android/.gradle/` 只能匹配根下那一个。

    早先的实现先把尾部 `/` 换成 `/**` 再去判断「含不含斜杠」，
    于是 `.gradle/` 变成了含斜杠的 `.gradle/**`，被误判成锚定模式 ——
    嵌套目录里的 `.gradle` 全都没被忽略，而这份脚本还报「全部符合预期」。
    """
    if pat.startswith('/'):
        # 前导 / 表示锚定仓库根；本例中 p 本身就是相对根的，去掉即可
        pat = pat[1:]
    # 先判断「是否锚定」：去掉尾部斜杠后再看有没有斜杠
    anchored = '/' in pat.rstrip('/')
    pat = pat.rstrip('/')
    if not anchored:
        # 不含（中间的）斜杠的模式匹配任意层级（git 的规则）
        cands = [pat, '*/' + pat, pat + '/**', '*/' + pat + '/**']
    else:
        cands = [pat, pat + '/**']
    return any(fnmatch.fnmatch(p, c) for c in cands)


def ignored(p, rules):
    """按顺序应用全部规则，后出现的规则（含 ! 白名单）覆盖先前的。"""
    hit = False
    for pat, neg in rules:
        if match(pat, p):
            hit = not neg
    return hit


# ===== 断言清单 =====
# 左列是路径，右列是**期望是否被忽略**。
CASES = [
    # --- 含真实 PII，必须忽略 ---
    ('testdata/raw/profile.html', True),      # 原始抓取：姓名/学号/身份证
    ('testdata/raw/score_list.html', True),   # 原始抓取：成绩
    ('testdata/raw/timetable.html', True),
    ('testdata/raw/plan.html', True),

    # --- 构建产物：体积与缓存 ---
    ('build/app/outputs/flutter-apk/app-release.apk', True),
    ('.dart_tool/package_config.json', True),
    ('.flutter-plugins-dependencies', True),
    ('android/.gradle/8.0/fileHashes.bin', True),
    ('android/app/debug/x', True),
    ('android/app/release/y', True),

    # --- 第三方引擎产物：560 MB，绝不能进仓库 ---
    #
    # 这是本地为了绕开 download.flutter.io 不可达而导出的 Flutter 引擎 Maven
    # 仓库。体积巨大且是第三方二进制，进 git 会让 clone 变成 600 MB+，
    # 而且**永留在历史里**（删掉文件也瘦不回来）。
    ('android/local-repo/io/flutter/arm64_v8a_debug/1.0/x.pom', True),
    ('android/local-repo/io/flutter/flutter_embedding_release/1.0/y.aar', True),

    # --- 验证码自检语料：第三方系统数据 ---
    ('tools/ocr_eval/captcha_train/1a2b.jpg', True),

    # --- 发布包：正确去处是 Releases 页，不是仓库 ---
    ('release/hijianzhu-jw-v1.0.0.apk', True),

    # --- 开发期临时文件 ---
    ('tmp/shot.png', True),
    ('hs_err_pid12345.log', True),
    ('flutter_01.log', True),

    # --- 这些必须能提交 ---
    ('README.md', False),
    ('LICENSE', False),
    ('pubspec.yaml', False),
    ('lib/main.dart', False),
    ('lib/parser/plan_parser.dart', False),
    ('android/app/build.gradle.kts', False),
    ('android/build.gradle.kts', False),
    # 模拟器用的 x86_64 库是**有意**入库的（见 docs/技术笔记.md）：
    # 插件只打包 ARM，缺这份库时模拟器上验证码识别直接失效。
    # 38 MB 虽然不小，但它是让「clone 下来就能跑」成立的关键。
    ('android/app/src/debug/jniLibs/x86_64/libonnxruntime.so', False),
    ('test/fixtures/timetable.html', False),   # 人工脱敏过的语料
    ('test/fixtures/plan.html', False),
    ('docs/技术笔记.md', False),
    ('assets/captcha.onnx', False),            # ddddocr 的模型，MIT 许可
    ('tools/audit_sensitive.py', False),
    ('tools/check_ignore.py', False),
    ('tools/scan_publishable.py', False),
    ('tools/__pycache__/x.pyc', True),
]


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    gi = os.path.join(root, '.gitignore')
    if not os.path.exists(gi):
        print('找不到 .gitignore: %s' % gi)
        return 2
    rules = parse(gi)
    print('已载入 %d 条规则（%s）\n' % (len(rules), gi))

    bad = []
    for p, want in CASES:
        got = ignored(p, rules)
        if got != want:
            bad.append((p, want, got))
        print('  [%s] %s  %s' % ('ok ' if got == want else 'FAIL',
                                '忽略' if got else '保留', p))
    print()
    if bad:
        print('%d 项不符预期：' % len(bad))
        for p, want, got in bad:
            print('   %s  期望%s，实际%s'
                  % (p, '忽略' if want else '保留', '忽略' if got else '保留'))
        return 1
    print('全部 %d 项符合预期' % len(CASES))
    return 0


if __name__ == '__main__':
    sys.exit(main())
