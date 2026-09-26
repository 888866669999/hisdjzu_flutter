# 把新抓的建大页面脱敏，写成 test/fixtures/ 下的测试语料。
#
# ===== 为什么要脱敏 =====
# test/fixtures/ 是**随仓库公开**的（解析器测试需要真实结构做语料，
# 否则只能手写 HTML，测不出真实排版差异）。因此语料里的真实个人信息
# 必须先换成人造值。
#
# ===== 实测这些页面里有什么 =====
# 逐个查过：**没有学号、没有身份证号**（它们是子页面，标识信息不在页面里），
# 唯一需要处理的是 timetable.html 里的**教师姓名** —— 教师是可关联到真人的
# 第三方信息，公开发布前应当换成假名。
#
# 课表页与成绩页里还有一些**12 位数字**（形如 `20` + 年份 + 序号），
# 它们是教务系统给排课通知单的流水号（页面标签写作「通知单编号」），
# 与学号同形但不是个人信息，保持原样。
# 审计脚本已按这个标签做过排除，不会把它报成学号。
import io
import os
import re

SRC = 'testdata/raw'
DST = 'test/fixtures'

# 教师假名（按出现顺序映射，保持「不同课不同老师」的关系）
FAKE_TEACHERS = [
    '李静', '王敏', '张辉', '刘洋', '陈曦', '周彤', '孙鹏', '吴倩',
    '赵磊', '郑毅', '冯爽', '吕鹏', '朱砂', '秦岭', '韩雪', '许静',
]

MAP = {
    'timetable.html': 'timetable.html',
    'score_list.html': 'score.html',
    'weekcal.html': 'weekcal.html',
    'plan.html': 'plan.html',
    # 本校的「空教室」信息在教室借用页（含「教室状态：完全空闲」筛选），
    # 而参考实现那边是一张「全校教室课表」—— 页面不同，语料也要换。
    'classroom_borrow.html': 'classroom.html',
    # 本校的修读情况页是「学习完成情况查看」（含毕业要求学分/已修学分），
    # 对应参考实现的「通选课修读情况」。
    'elective_completion.html': 'elective.html',
}


def scrub(s: str) -> str:
    """把教师姓名换成人造值。"""
    used: dict = {}

    def pick(name: str) -> str:
        name = name.strip()
        if not name:
            return name
        if name not in used:
            used[name] = FAKE_TEACHERS[len(used) % len(FAKE_TEACHERS)]
        return used[name]

    def repl(m: re.Match) -> str:
        head, names = m.group(1), m.group(2)
        parts = [pick(x) for x in re.split(r'([,，、])', names)]
        return head + ''.join(parts)

    return re.sub(
        r'(title\s*=\s*["\u0027]教师["\u0027]\s*>)([^<]{2,80})',
        repl, s)


def main():
    os.makedirs(DST, exist_ok=True)
    for src, dst in MAP.items():
        p = os.path.join(SRC, src)
        if not os.path.exists(p):
            print('  跳过（不存在）:', src)
            continue
        raw = io.open(p, encoding='utf-8', errors='ignore').read()
        out = scrub(raw)
        io.open(os.path.join(DST, dst), 'w', encoding='utf-8',
                newline='\n').write(out)
        flag = '已脱敏' if out != raw else '无改动'
        print(f'  {src} -> test/fixtures/{dst}  ({len(out)} B, {flag})')


if __name__ == '__main__':
    main()
