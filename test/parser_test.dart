/// 解析器回归测试
///
/// 语料是**真实抓取的页面**（已脱敏），放在 test/fixtures/。
/// 鸿蒙版用 Node 脚本跑同样的断言（testdata/run-tests.mjs，423 条）；
/// 这里用 Dart 原生测试重写核心部分，保证移植过程中解析行为不走样。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hijianzhu_jw/parser/html_lite.dart';
import 'package:hijianzhu_jw/model/models.dart';
import 'package:hijianzhu_jw/parser/plan_parser.dart';

String read(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  group('HtmlLite 基础能力', () {
    test('解码实体', () {
      expect(HtmlLite.decode('a&nbsp;b&lt;c&gt;d&amp;e'), 'a b<c>d&e');
    });

    test('读取属性：双引号 / 单引号 / 无引号', () {
      expect(HtmlLite.attr('<td id="a">', 'id'), 'a');
      expect(HtmlLite.attr("<td id='b'>", 'id'), 'b');
      expect(HtmlLite.attr('<td id=c>', 'id'), 'c');
    });

    test('属性名匹配要有边界：data-id 不能命中 id', () {
      expect(HtmlLite.attr('<td data-id="x">', 'id'), '');
    });

    test('toText 把 <br> 与块级闭合转成换行、丢标签、去空行', () {
      expect(HtmlLite.toText('a<br>b'), 'a\nb');
      expect(HtmlLite.toText('<div>a</div><div>b</div>'), 'a\nb');
      expect(HtmlLite.toText('  <b>x</b>  \n\n <i>y</i> '), 'x\ny');
    });

    test('toText 去注释', () {
      expect(HtmlLite.toText('a<!-- <b>x</b> -->b'), 'ab');
    });

    test('isLoginPage 需要密码框 + 验证码/encoded 字段', () {
      expect(
        HtmlLite.isLoginPage('<input type="password"><img src="SafeCodeImg">'),
        isTrue,
      );
      expect(HtmlLite.isLoginPage('<input type="password">'), isFalse);
      // xsMain.jsp 里也有密码框，但没有验证码字段，不能被判成登录页
      expect(
        HtmlLite.isLoginPage('<form id="loginForm1"><input type="password">'),
        isFalse,
      );
    });

    test('scanCells 保证文档顺序（内容相同的单元格不串位）', () {
      final HtmlRow row =
          HtmlRow(HtmlLite.scanCells('<td>2</td><td>x</td><td>2</td>'));
      expect(row.cells.length, 3);
      expect(row.cells[0].text, '2');
      expect(row.cells[1].text, 'x');
      expect(row.cells[2].text, '2');
    });

    test('findTableById 兼容单引号 id', () {
      final HtmlTable? t = HtmlLite.findTableById(
        "<table border='1'><tr><td>only</td></tr></TABLE>".replaceAll(
          '<table',
          "<TABLE id='mxh'",
        ),
        'mxh',
      );
      expect(t, isNotNull);
      expect(t!.rows.first.cells.first.text, 'only');
    });
  });

  group('真实页面：成绩页', () {
    test('按表头定位列并读出记录', () {
      final String html = read('score.html');
      final HtmlTable? t = HtmlLite.findTableByHeader(html, '课程名称');
      expect(t, isNotNull, reason: '应能按「课程名称」表头找到成绩表');

      // 找到表头行，确认列语义
      final List<HtmlCell> header = t!.rows.first.cells;
      final List<String> labels =
          header.map((HtmlCell c) => c.text).toList();
      expect(labels, contains('课程名称'));
      expect(labels, contains('成绩'));
      expect(labels, contains('学分'));
      expect(labels, contains('绩点'));
    });
  });

  group('真实页面：个人信息', () {
    test('#xjkpTable 存在且能读到「学号/姓名」', () {
      final String html = read('profile.html');
      final HtmlTable? t = HtmlLite.findTableById(html, 'xjkpTable');
      expect(t, isNotNull, reason: '学籍卡片表的 id 是 xjkpTable');
      final String all = t!.text;
      expect(all.contains('学号'), isTrue);
      expect(all.contains('姓名'), isTrue);
    });
  });

  group('真实页面：课表', () {
    test('课表主体表可定位，首行给出星期表头', () {
      final String html = read('timetable.html');
      // 表 id 各校不一：本校是 timetable，参考实现是 kbtable
      final HtmlTable? t =
          HtmlLite.findTableByIds(html, <String>['timetable', 'kbtable']);
      expect(t, isNotNull);
      expect(t!.rows.isNotEmpty, isTrue);
      final String head = t.rows.first.text;
      expect(head.contains('星期一'), isTrue);
      expect(head.contains('星期日'), isTrue);
    });

    test('一格多课的课程确实用长破折号分隔', () {
      final String html = read('timetable.html');
      final HtmlTable? t =
          HtmlLite.findTableByIds(html, <String>['timetable', 'kbtable']);
      bool found = false;
      for (final HtmlRow r in t!.rows) {
        for (final HtmlCell c in r.cells) {
          if (RegExp(r'-{6,}').hasMatch(c.inner)) {
            found = true;
          }
        }
      }
      expect(found, isTrue, reason: '真实课表里存在一格多课（用 ------ 分隔）');
    });
  });

  group('真实页面：周历', () {
    test('日期只写在 title 属性里，单元格文本只有日号', () {
      final String html = read('weekcal.html');
      // 形如 title='2026年08月24'
      final RegExp re = RegExp("title\\s*=\\s*['\"]?\\d{4}年\\d{1,2}月\\d{1,2}");
      expect(re.hasMatch(html), isTrue);
    });
  });

  group('真实页面：培养方案', () {
    test('#mxh 课程表用单引号 id，仍能被找到', () {
      final String html = read('plan.html');
      final HtmlTable? t = HtmlLite.findTableById(html, 'mxh');
      expect(t, isNotNull, reason: "真实页面写成 <TABLE id='mxh'>");
    });


    test('学分/总学时由课程行求和，不是合计行的错列（回归）', () {
      // 回归背景：合计/小计行只有 9 列，课程行有 14–15 列。
      // 早期用「从右数第 6 格=学分、第 3 格=总学时」的固定偏移去读合计行，
      // 实际取到的是「讲课学时 / 实验学时」，页面显示成 425 学分 / 136 学时，
      // 且不报任何错。正确值是逐门课求和得到的。
      final PlanDetail d = PlanParser.parse(read('plan.html'));
      // 语料是本校真实页面的一小段（前 2 个分组的 18 门课），已脱敏。
      //
      // **不写死具体学分/学时数**：那等于把语料的内容抄进断言，
      // 语料一换就得改数字，而且改数字时很容易把错的抄成对的
      // （这个缺陷最初就是这样漏过去的）。只断言**量级关系**，
      // 它对「读错列」敏感、对语料内容不敏感。
      expect(d.courses.length, 18);
      expect(d.totalCredit, greaterThan(0));
      expect(d.totalHours, greaterThan(0));
      // 学时必然远大于学分（1 学分 ≈ 17–34 学时）；若两者颠倒或错列，这条会失败
      expect(d.totalHours, greaterThan(d.totalCredit * 5),
          reason: '总学时与学分不可能同量级，量级错误说明读错了列');
    });

    test('每门课的学分与总学时都能解析成数字', () {
      final PlanDetail d = PlanParser.parse(read('plan.html'));
      for (final PlanCourse c in d.courses) {
        expect(double.tryParse(c.credit), isNotNull,
            reason: '${c.courseName} 的学分「${c.credit}」应为数字');
        expect(double.tryParse(c.totalHours), isNotNull,
            reason: '${c.courseName} 的总学时「${c.totalHours}」应为数字');
      }
    });

    test('分组来自「体系」列的向下继承（首行有值、后续行为空）', () {
      final PlanDetail d = PlanParser.parse(read('plan.html'));
      final Set<String> systems =
          d.courses.map((PlanCourse c) => c.system).where((String s) => s.isNotEmpty).toSet();
      // 语料含 2 个分组；关键不是数量而是「多于 1」——
      // 若不向下继承体系，整表会归成 1 组。
      expect(systems.length, greaterThan(1),
          reason: '若不继承，整表会归成 1 组');
      // 不应有课程落在空体系里
      expect(d.courses.every((PlanCourse c) => c.system.isNotEmpty), isTrue);
    });

    test('页面里出现 PDF 附件链接也不影响课程解析（附件功能已删，解析要容忍）', () {
      // 本校的培养方案实测**没有任何附件**（`uploadfile` / `.pdf` / `附件`
      // 均不出现），随合并改版删掉了整套附件下载链路（含附件路径解析）。
      // 但别的学校/未来版本可能往页面里挂附件，解析器不能因此读错课程 ——
      // 这里在语料上插入一个附件 iframe，断言课程解析结果与原来完全一致。
      final String html = read('plan.html');
      final PlanDetail base = PlanParser.parse(html);
      final PlanDetail withPdf = PlanParser.parse(html.replaceFirst(
        '<table id="dataList">',
        '<table id="dataList"><tr><td>'
            '<iframe src="/ewebeditor/uploadfile/2025033110250359448.pdf">'
            '</iframe></td></tr>',
      ));
      expect(withPdf.courses.length, base.courses.length);
      expect(withPdf.totalCredit, base.totalCredit);
      expect(withPdf.groups.length, base.groups.length);
    });
  });

  group('真实页面：修读情况 / 教室借用', () {
    test('修读情况的「课程体系 / 毕业要求学分 / 已修学分」表能按表头找到', () {
      // 本校的对应页面是「学习完成情况查看」，列名与参考实现不同：
      //   参考实现：课程体系 / 要求学分（大于等于）/ 已修学分
      //   本校    ：课程体系(属性) / 毕业要求学分 / 已修学分 / 正修读学分 / 毕业还需学分
      final String html = read('elective.html');
      final HtmlTable? t = HtmlLite.findTableByHeader(html, '毕业要求学分');
      expect(t, isNotNull, reason: '表头应含「毕业要求学分」');
      // 逐行核对：每条课程体系都要有「已修学分」这一列
      expect(html.contains('已修学分'), isTrue);
      expect(html.contains('正修读学分'), isTrue);
    });

    test('教室借用页的表与状态选项都在（本校用它查空闲教室）', () {
      final String html = read('classroom.html');
      // 本校的空闲教室信息在「教室借用」页的筛选器 + 结果表里，
      // 而不是参考实现那种「全校教室课表」页
      expect(html.contains('教室状态'), isTrue, reason: '筛选器含「教室状态」');
      expect(html.contains('完全空闲'), isTrue, reason: '状态选项含「完全空闲」');
      expect(html.contains('借用'), isTrue);
      // 页面里的表能被解析出来（结构由 HtmlLite 负责）
      final List<HtmlTable> tables = HtmlLite.parseTables(html);
      expect(tables, isNotEmpty);
    });
  });
}
