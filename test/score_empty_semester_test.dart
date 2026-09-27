/// 成绩页「空结果」的两种含义（学期筛选失效的回归测试）
///
/// ===== 这个用例守的是一个真实缺陷 =====
/// 用户报「成绩页的学期选项无法准确执行过滤」。实测确认服务端**是对的**：
///   · 不传 `kksj`      → 回全部 23 条（两个学期）
///   · `kksj=2025-2026-1` → 只回该学期的 13 条
///   · `kksj=2026-2027-1` → 该学期确实没成绩，回 0 条
/// 也就是说后端按学期过滤得好好的，问题全在客户端：
///
/// 页面当时用「记录是不是空的」来决定要不要覆盖列表：
/// ```dart
/// if (recs.isNotEmpty || _records.isEmpty) { _records = recs; }
/// ```
/// 于是切到**没有成绩的学期**时，服务端如实回了空、而这条守卫生效，
/// 列表仍显示上一个学期的成绩 —— 界面上就是「学期筛选点了没反应」。
///
/// 修法是把两种「空」分开：
///   · `recognized == true` 且为空 → 该学期确实没成绩，**必须**覆盖成空；
///   · `recognized == false`        → 这次响应不是成绩结果页，保留旧数据。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hijianzhu_jw/model/models.dart';
import 'package:hijianzhu_jw/parser/score_parser.dart';

void main() {
  group('结果页可识别性（决定「空」的含义）', () {
    test('正常结果页：recognized=true 且有记录', () {
      final ScorePageResult r = ScoreParser.parsePage(
        _table(<String>[
          '<tr><th>序号</th><th>开课学期</th><th>课程编号</th>'
              '<th>课程名称</th><th>成绩</th><th>学分</th></tr>',
          '<tr><td>1</td><td>2025-2026 第一学期</td><td>AQ25000001</td>'
              '<td>安全教育</td><td>96</td><td>1</td></tr>',
        ]),
      );
      expect(r.recognized, isTrue);
      expect(r.records.length, 1);
      expect(r.records.first.courseName, '安全教育');
    });

    test('「该学期没有成绩」：表头在、有提示行 → recognized=true 且为空', () {
      // 这是切换学期后**必须接受**的空结果。服务端在表里放一行
      // 「未查询到数据」，解析时跳过它，但页面结构认得出来。
      final ScorePageResult r = ScoreParser.parsePage(
        _table(<String>[
          '<tr><th>序号</th><th>开课学期</th><th>课程编号</th>'
              '<th>课程名称</th><th>成绩</th><th>学分</th></tr>',
          '<tr><td colspan="6">未查询到数据</td></tr>',
        ]),
      );
      expect(r.recognized, isTrue,
          reason: '表头认出来了，就该认为这是权威的「没有成绩」');
      expect(r.records, isEmpty);
    });

    test('表头在但一行数据都没有 → 同样视为「没有成绩」', () {
      final ScorePageResult r = ScoreParser.parsePage(
        _table(<String>[
          '<tr><th>序号</th><th>开课学期</th><th>课程编号</th>'
              '<th>课程名称</th><th>成绩</th><th>学分</th></tr>',
        ]),
      );
      expect(r.recognized, isTrue);
      expect(r.records, isEmpty);
    });
  });

  group('非结果页（recognized=false，必须保留旧数据）', () {
    test('登录页', () {
      final ScorePageResult r = ScoreParser.parsePage(
        '<html><body><form id="loginForm" action="/jsxsd/xk/LoginToXk">'
        '<input id="userAccount"><input id="RANDOMCODE">'
        '</form></body></html>',
      );
      expect(r.recognized, isFalse);
      expect(r.records, isEmpty);
    });

    test('服务端错误页', () {
      final ScorePageResult r =
          ScoreParser.parsePage('<html><body>系统繁忙，请稍后重试</body></html>');
      expect(r.recognized, isFalse);
    });

    test('空响应', () {
      expect(ScoreParser.parsePage('').recognized, isFalse);
    });

    test('有数据表但没有成绩表头 —— 不能当成「没有成绩」', () {
      // 认不出表头时返回 false：调用方据此保留旧数据，
      // 而不是把用户手里的成绩清成空白。
      final ScorePageResult r = ScoreParser.parsePage(
        _table(<String>['<tr><th>其它表头</th><th>列</th></tr>']),
      );
      expect(r.recognized, isFalse);
    });
  });

  group('合并决策（缺陷就在这一行，必须钉死）', () {
    final List<ScoreRecord> old = <ScoreRecord>[
      ScoreRecord(courseName: '上学期的一门课', score: '90', credit: '3'),
    ];

    test('该学期没有成绩（recognized=true 且为空）→ 覆盖成空', () {
      // **这是缺陷本体**：旧写法「新结果非空才覆盖」在这里选择保留旧数据，
      // 于是列表里显示的是上一个学期的成绩 —— 学期筛选看起来没反应。
      final List<ScoreRecord> got = mergeScoreRecords(
          old, const ScorePageResult(<ScoreRecord>[], true));
      expect(got, isEmpty,
          reason: '服务端已明确回答「该学期无成绩」，必须如实显示空');
    });

    test('查询没拿到结果页（recognized=false）→ 保留旧数据', () {
      final List<ScoreRecord> got = mergeScoreRecords(
          old, const ScorePageResult(<ScoreRecord>[], false));
      expect(got, same(old), reason: '不是结果页时清空，会让用户以为成绩丢了');
    });

    test('正常取到新数据 → 覆盖', () {
      final List<ScoreRecord> fresh = <ScoreRecord>[
        ScoreRecord(courseName: '新学期的课', score: '95', credit: '2'),
      ];
      final List<ScoreRecord> got =
          mergeScoreRecords(old, ScorePageResult(fresh, true));
      expect(got, same(fresh));
    });

    test('本来就没有旧数据时，非结果页也照常采用（空就是空）', () {
      final List<ScoreRecord> got = mergeScoreRecords(
          <ScoreRecord>[], const ScorePageResult(<ScoreRecord>[], false));
      expect(got, isEmpty);
    });
  });

  group('parse() 仍返回纯列表（兼容既有调用方）', () {
    test('只取记录', () {
      final List<ScoreRecord> rs = ScoreParser.parse(
        _table(<String>[
          '<tr><th>序号</th><th>开课学期</th><th>课程编号</th>'
              '<th>课程名称</th><th>成绩</th><th>学分</th></tr>',
          '<tr><td>1</td><td>2025-2026 第一学期</td><td>CY25010003</td>'
              '<td>创新创业基础</td><td>98</td><td>2</td></tr>',
        ]),
      );
      expect(rs.length, 1);
      expect(rs.first.courseCode, 'CY25010003');
    });
  });
}

/// 把若干 `<tr>` 包成一张带 id=dataList 的页
String _table(List<String> rows) =>
    '<html><body><table id="dataList">${rows.join()}</table></body></html>';
