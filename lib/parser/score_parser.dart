/// 成绩解析
///
/// 从鸿蒙版 `parser/ScoreParser.ets` 移植。
///
/// 列位置**按表头文本定位**而不是写死下标：真实表头是
/// `序号/开课学期/课程编号/课程名称/成绩/学分/绩点/考试性质/课程性质/课程属性/辅修课程`，
/// 但不同学期可能少一两列，写死下标会整行错位。
///
/// 注意 `学分` 与 `平均学分绩点` 这类包含关系：先精确匹配，再退回包含匹配，
/// 否则 `学分` 会命中「平均学分绩点」那一列。
library;

import '../model/models.dart';
import 'html_lite.dart';

class ScoreParser {
  static const List<String> _defaultCols = <String>[
    '序号',
    '开课学期',
    '课程编号',
    '课程名称',
    '成绩',
    '学分',
    '绩点',
    '考试性质',
    '课程性质',
    '课程属性',
    // 不列「辅修课程」：本校的成绩表没有这一列。
    // （列在这里只会让 `_findCol` 去找一个不存在的表头，
    //   而读不到时现在是空串、不是错列的值。）
  ];

  static List<ScoreRecord> parse(String html) {
    final HtmlTable? table = HtmlLite.findTableByHeader(html, '课程名称') ??
        HtmlLite.findTableById(html, 'dataList');
    if (table == null) {
      return <ScoreRecord>[];
    }

    // 找表头行
    int headerRow = -1;
    final int limit = table.rows.length < 4 ? table.rows.length : 4;
    for (int r = 0; r < limit; r++) {
      if (table.rows[r].text.contains('课程名称')) {
        headerRow = r;
        break;
      }
    }
    if (headerRow < 0) {
      return <ScoreRecord>[];
    }

    final List<HtmlCell> header = table.rows[headerRow].cells;
    final List<String> labels = header.map((HtmlCell c) => c.text.trim()).toList();
    final Map<String, int> cols = <String, int>{};
    for (int i = 0; i < _defaultCols.length; i++) {
      cols[_defaultCols[i]] = _findCol(labels, _defaultCols[i], i);
    }

    final List<ScoreRecord> out = <ScoreRecord>[];
    for (int r = headerRow + 1; r < table.rows.length; r++) {
      final List<HtmlCell> cells = table.rows[r].cells;
      if (cells.length < 5) {
        continue;
      }
      final String joined = table.rows[r].text;
      if (joined.contains('未查询到数据')) {
        continue;
      }
      String at(String key) {
        final int? idx = cols[key];
        if (idx == null || idx < 0 || idx >= cells.length) {
          return '';
        }
        return cells[idx].text.trim();
      }

      final String name = at('课程名称');
      if (name.isEmpty) {
        continue;
      }
      out.add(ScoreRecord(
        index: at('序号'),
        semester: _firstNonEmpty(<String>[at('开课学期'), at('学期')]),
        courseCode: _firstNonEmpty(<String>[at('课程编号'), at('课程代码')]),
        courseName: name,
        score: at('成绩'),
        credit: at('学分'),
        gpa: at('绩点'),
        examType: at('考试性质'),
        courseNature: at('课程性质'),
        courseAttr: at('课程属性'),
        minor: at('辅修课程'),
      ));
    }
    return out;
  }

  /// 按表头文字定位列：先精确匹配，再包含匹配；**找不到返回 -1**。
  ///
  /// ===== 为什么不能退回「位置下标」（本校踩过的坑）=====
  /// 早先找不到时返回该字段在 `_defaultCols` 里的位置。那是**某一份
  /// 表头顺序**的快照，一换学校/一换版式就完全错位 —— 而错位是**静默**的：
  /// 建大的成绩表没有「辅修课程」列，回退到第 10 位恰好是「考核方式」，
  /// 于是界面上「辅修课程」显示成「考试」这种莫名其妙的值，不报任何错。
  ///
  /// 返回 -1 后，取值处会拿到空串 —— 字段显示为空，
  /// 一眼就能看出「这一列不存在」，而不是被别的列的值冒充。
  static int _findCol(List<String> labels, String want, int fallback) {
    for (int i = 0; i < labels.length; i++) {
      if (labels[i] == want) {
        return i;
      }
    }
    for (int i = 0; i < labels.length; i++) {
      if (labels[i].contains(want)) {
        return i;
      }
    }
    return -1;
  }

  static String _firstNonEmpty(List<String> xs) {
    for (final String x in xs) {
      if (x.isNotEmpty) {
        return x;
      }
    }
    return '';
  }

  /// 由**分数**算绩点：`绩点 = (分数 - 50) ÷ 10`。
  ///
  /// ===== 为什么自己算而不是读页面 =====
  /// 本校成绩页的「绩点」列**整列都是 0**（学校没有录入），
  /// 直接读它会让界面显示成「每科 0 绩点、平均绩点 0.000」，
  /// 而这看起来完全正常、只是数字不对 —— 属于静默错误。
  ///
  /// 规则来自用户：`绩点 = (分数 - 50) ÷ 10`。
  ///
  /// 即 60 分 = 1.0、90 分 = 4.0、100 分 = 5.0 —— 国内高校常见的 5 分制。
  /// 不除十时 60 分是 10 绩点，量纲和「绩点」这个说法对不上，
  /// 汇总出的平均绩点（40.72 这种）看着也不像绩点。
  ///
  /// 对非数字成绩（「优秀」「良好」这类）返回 -1，表示「算不出」——
  /// 调用方据此跳过，而不是当成 0 参与平均（那会把均值拖低）。
  static double gpaFromScore(String score) {
    final double? v = double.tryParse(score.trim());
    if (v == null || v <= 0) {
      return -1;
    }
    return (v - 50) / 10;
  }

  /// 汇总：门数、总学分、**平均绩点**。
  ///
  /// 只统计「能算出绩点」的课程（[gpaFromScore] < 0 的跳过）——
  /// 否则会把「优秀/合格」这类没有分数的课算成 0 参与平均。
  static ScoreSummary summarize(List<ScoreRecord> records) {
    double creditSum = 0;
    double gpaSum = 0;
    int gpaCount = 0;
    for (final ScoreRecord r in records) {
      final double c = r.creditNumber();
      final double g = gpaFromScore(r.score);
      if (g < 0) {
        continue;
      }
      creditSum += c;
      gpaSum += g;
      gpaCount++;
    }
    // 平均绩点 = 各科绩点之和 ÷ 科目数。
    //
    // 注意这里**不是**学分加权（用户的规则就是简单平均）：
    // 加权口径下 1 学分的体育课对均值几乎没有影响，
    // 而这所学校的评价方式是「每科绩点直接平均」。
    final double avg = gpaCount <= 0 ? 0 : gpaSum / gpaCount;
    return ScoreSummary(
      records.length,
      (creditSum * 100).round() / 100,
      (avg * 1000).round() / 1000,
    );
  }

  /// 读学期下拉（`kksj`）
  static List<ChoiceItem> readSemesters(String html) {
    return HtmlLite.findSelect(html, 'kksj')
        .where((HtmlOption o) => o.value.isNotEmpty)
        .map((HtmlOption o) => ChoiceItem(
              o.label.isNotEmpty ? o.label : o.value,
              o.value,
            ))
        .toList();
  }
}
