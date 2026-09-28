/// 修读大类「详情」页的解析（合并页里「修读记录」的依赖）
///
/// 本校的通选主页是**单表**，只有各专业的学分统计；课程明细在另一个页面：
/// 每行的「详情」是 `window.open('/jsxsd/xxwcqk/xxwcqkOnkctxByxq.do?kctxmc=…')`。
/// 合并后的培养方案页在用户展开某个体系时按需去抓这个页面（放在「修读记录」
/// 小节里），实现就落在这个页面的解析上。
///
/// 表头实测 8 列（抓自真实页面）：
///   课程编号 | 课程名称 | 学分 | 课程属性 | 课程性质 | 总成绩 | 备注 | 是否学位课
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hijianzhu_jw/model/models.dart';
import 'package:hijianzhu_jw/parser/elective_parser.dart';

String _page(String rows) => '''
<html><body><table id="dataList">
<tr><td colspan="8">学科基础必修课</td></tr>
<tr>
  <th>课程编号</th><th>课程名称</th><th>学分</th><th>课程属性</th>
  <th>课程性质</th><th>总成绩</th><th>备注</th><th>是否学位课</th>
</tr>
$rows
</table></body></html>''';

void main() {
  group('详情页解析', () {
    test('8 列全部就位（课号/课名/学分/属性/成绩）', () {
      final List<ElectiveCourse> cs = ElectiveParser.parseDetail(_page('''
<tr><td>HJ25030001</td><td>普通化学</td><td>3（计划内）</td><td>必修</td>
    <td>学科基础必修课</td><td>92.7</td><td></td><td>否</td></tr>'''));
      expect(cs.length, 1);
      expect(cs.first.courseCode, 'HJ25030001');
      expect(cs.first.courseName, '普通化学');
      expect(cs.first.credit, '3（计划内）');
      expect(cs.first.attr, '必修');
      expect(cs.first.score, '92.7');
    });

    test('跨列的「大类名」标题行不算课程', () {
      // 真实页面第一行是只有一格的标题；按列数过滤掉
      final List<ElectiveCourse> cs = ElectiveParser.parseDetail(_page('''
<tr><td>HJ25030001</td><td>普通化学</td><td>3</td><td>必修</td>
    <td>学科基础必修课</td><td>92.7</td><td></td><td>否</td></tr>'''));
      expect(cs.map((ElectiveCourse c) => c.courseName),
          isNot(contains('学科基础必修课')));
    });

    test('学分里的括号说明能被数值化（进度条要算）', () {
      final List<ElectiveCourse> cs = ElectiveParser.parseDetail(_page('''
<tr><td>X1</td><td>某课</td><td>3（计划内）</td><td>必修</td>
    <td>体系</td><td>90</td><td></td><td>否</td></tr>'''));
      expect(cs.first.creditNumber(), 3);
    });

    test('没有成绩的课（在修读）能识别出来', () {
      final List<ElectiveCourse> cs = ElectiveParser.parseDetail(_page('''
<tr><td>X2</td><td>在修课</td><td>2</td><td>选修</td>
    <td>体系</td><td></td><td></td><td>否</td></tr>'''));
      expect(cs.first.score, isEmpty);
      expect(cs.first.hasScore, isFalse);
    });

    test('课程名为空的行跳过（表头残留 / 空行）', () {
      final List<ElectiveCourse> cs = ElectiveParser.parseDetail(_page('''
<tr><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
<tr><td>X3</td><td>正常课</td><td>1</td><td>必修</td>
    <td>体系</td><td>80</td><td></td><td>否</td></tr>'''));
      expect(cs.length, 1);
      expect(cs.first.courseName, '正常课');
    });

    test('没有课程表时返回空列表（不是抛错）', () {
      expect(ElectiveParser.parseDetail('<html><body>无表</body></html>'),
          isEmpty);
    });

    test('列顺序变了也能对（按表头文字定位，不写死列号）', () {
      // 打乱列序：只保留表头名字，位置全变
      final List<ElectiveCourse> cs = ElectiveParser.parseDetail('''
<html><body><table id="dataList">
<tr><th>课程名称</th><th>总成绩</th><th>课程编号</th><th>学分</th>
    <th>课程属性</th><th>课程性质</th><th>备注</th><th>是否学位课</th></tr>
<tr><td>乱序课</td><td>88</td><td>Z9</td><td>4</td>
    <td>选修</td><td>体系</td><td></td><td>否</td></tr>
</table></body></html>''');
      expect(cs.length, 1);
      expect(cs.first.courseCode, 'Z9');
      expect(cs.first.courseName, '乱序课');
      expect(cs.first.credit, '4');
      expect(cs.first.attr, '选修');
      expect(cs.first.score, '88');
    });
  });
}
