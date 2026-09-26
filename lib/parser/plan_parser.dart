/// 培养方案解析（含 PDF 附件路径）
///
/// 从鸿蒙版 `parser/PlanParser.ets` 移植。
///
/// ===== PDF 路径是动态提取的（不要写死）=====
/// 附件地址形如 `<iframe src="/ewebeditor/uploadfile/2025033110250359448.pdf">`，
/// 不同专业、不同年份的名字都不同，页数也不同。
/// 因此这里只从页面里**正则提取路径**，不做任何文件名或页数的假设。
///
/// ===== 页面结构 =====
///   - `#dataList`：引言表。其中「三、课程设置总表」是分隔标题，
///     其后的行才是课程数据（还有一层嵌套子表，需要识别并跳过）。
///   - `#mxh`：真正的课程表，**嵌套在 `#dataList` 内部**，
///     而且用单引号写 id（`<TABLE id='mxh'>`）。
///     这两点都踩过坑：早期的按 id 查找只扫最外层表，导致整张培养方案空白。
///
/// 课程行数据**从右往左读**：因为左侧的「选课组/课号」列数不固定，
/// 从右边数位置才是稳定的。
library;

import '../model/models.dart';
import 'html_lite.dart';

class PlanParser {
  /// 只有带这些前缀的才算正文小标题
  static const List<String> _sectionPrefixes = <String>['一、', '二、', '三、', '四、', '五、'];

  static PlanDetail parse(String html) {
    final PlanDetail detail = PlanDetail();

    final HtmlTable? dataList = HtmlLite.findTableById(html, 'dataList');
    if (dataList != null) {
      _readIntro(dataList, detail);
    }

    final HtmlTable? mxh = HtmlLite.findTableById(html, 'mxh');
    if (mxh != null) {
      _readCourses(mxh, detail);
    }

    detail.pdfPath = _parsePdfPath(html);
    detail.buildGroups();
    return detail;
  }

  /// 提取 PDF 附件相对地址。
  ///
  /// 直接匹配「路径本身」而不是 iframe 标签，这样不依赖引号风格与属性顺序
  /// （真实页面里出现过单引号、双引号混用）。
  static String _parsePdfPath(String html) {
    final RegExpMatch? m = RegExp(
      r'/[A-Za-z0-9_/.-]*uploadfile/[A-Za-z0-9_.%-]+\.pdf',
      caseSensitive: false,
    ).firstMatch(html);
    if (m != null && m.group(0)!.isNotEmpty) {
      return m.group(0)!;
    }
    // 兜底：任意位置的 .pdf 路径
    final RegExpMatch? m2 = RegExp(
      r'[A-Za-z0-9_/.-]+\.pdf',
      caseSensitive: false,
    ).firstMatch(html);
    return m2?.group(0) ?? '';
  }

  /// 读引言段落
  static void _readIntro(HtmlTable table, PlanDetail detail) {
    for (final HtmlRow row in table.rows) {
      // 课程表的行（含这些表头）不是引言
      final String joined = row.text;
      if (joined.contains('学时分类') && joined.contains('开设学期')) {
        continue;
      }
      for (final HtmlCell cell in row.cells) {
        final String raw = cell.text.trim();
        if (raw.isEmpty) {
          continue;
        }
        for (final String line in raw.split('\n')) {
          final String t = line.trim();
          if (t.isEmpty) {
            continue;
          }
          if (!_sectionPrefixes.any((String p) => t.startsWith(p))) {
            continue;
          }
          // 「课程设置总表」是分隔标题，不是正文
          if (t.contains('课程设置总表')) {
            continue;
          }
          final String body = _stripHeading(t);
          if (body.isEmpty) {
            continue;
          }
          if (t.contains('培养目标')) {
            detail.introParagraphs.add(body);
          } else {
            detail.detailParagraphs.add(body);
          }
        }
      }
    }
  }

  /// 去掉 `一、` 之类前缀与内嵌的「培养目标/详细说明」
  static String _stripHeading(String line) {
    String s = line;
    for (final String p in _sectionPrefixes) {
      if (s.startsWith(p)) {
        s = s.substring(p.length);
        break;
      }
    }
    s = s.replaceFirst(RegExp(r'^\s*培养目标'), '');
    s = s.replaceFirst(RegExp(r'^\s*详细说明'), '');
    return s.trim();
  }

  /// 读课程表：数据行 + 合计/小计
  ///
  /// **合计不读「合计行」，而是把课程行自己加起来。**
  /// 原因（实测，别再改回去）：合计/小计行的列数与课程行**不一样** ——
  /// 数据行 14–15 列，小计行只有 9 列（丢掉体系/选课组/课号/课程名称/
  /// 完成情况/性质/属性这些文字列，只留学分与 6 个学时分类再跟一个空列）。
  /// 早期用「从右数第 6 格 = 学分」这类固定偏移去读，结果在两个不同列数的
  /// 行上悄悄读错列：页面上显示成「425 学分 / 136 学时」，而且**不报错**。
  ///
  /// 求和法还有个附带好处：它天然与「课程设置总表」逐门课对得上，
  /// 用户能自己核对，不必相信一个来源不明的总数。
  static void _readCourses(HtmlTable table, PlanDetail detail) {
    String currentSystem = '';

    // 列位置从**表头**推导，不硬编码（见 _headerOffsets 的说明）
    final Map<String, int> cols = _headerOffsets(table);

    for (final HtmlRow row in table.rows) {
      final List<HtmlCell> cells = row.cells;
      if (cells.isEmpty) {
        continue;
      }
      final String first = cells[0].text.trim();

      // 合计 / 小计行：列布局与课程行不同，跳过（总数由课程行求和得出）
      if (first.startsWith('合计') || first.startsWith('小计')) {
        continue;
      }
      // 表头行（第一格是「体系」，或含「讲课学时」）
      if (first == '体系' || row.text.contains('讲课学时')) {
        continue;
      }
      // 数据行的第一格是课程体系（分组首行有值、后续行为空），
      // 而引言段落的行只有一格且是长文 —— 用格数把两者分开。
      if (cells.length < 12) {
        continue;
      }

      final PlanCourse c = _readCourseFromRight(cells, currentSystem, cols);
      if (c.courseName.isEmpty) {
        continue;
      }
      if (c.system.isNotEmpty) {
        currentSystem = c.system;
      }
      detail.courses.add(c);
    }

    // 学分与总学时：由课程行累加（见上方说明）
    double credit = 0;
    double hours = 0;
    for (final PlanCourse c in detail.courses) {
      credit += double.tryParse(c.credit) ?? 0;
      hours += double.tryParse(c.totalHours) ?? 0;
    }
    detail.totalCredit = credit;
    detail.totalHours = hours;
  }

  /// 从表头推导「列名 → 距右端的偏移」。
  ///
  /// ===== 为什么必须推导而不能写死 =====
  /// 这张表的列**不只是顺序，连数量都随学校/年级变**：本校有
  /// `完成情况 / 课程性质 / 课程属性` 三列，参考实现的学校只有 `类别` 一列。
  /// 早先按固定的「从右数第 9 格 = 课程名称」去读，在本校实际读到了
  /// **课程性质** —— 于是课程列表里每门课都显示成它所属的性质
  /// （「素质拓展必修课」重复 13 遍），课号列读到了「完成情况」。
  /// 这类错位不会抛异常，只会安静地显示错的数据。
  ///
  /// 表头是**两行**：第一行带 rowspan/colspan（`学时分类` 横跨 6 列），
  /// 第二行只填那 6 个子列（`总学时` 在最后一个）。因此先把两行展开成
  /// 一条等宽的列名数组，再算每个名字距右端多少格。
  ///
  /// 数据行左侧会因为 rowspan 少掉格子（分组首行有「选课组」、
  /// 后续行没有），但**右侧永远对齐** —— 所以偏移一律从右端算。
  static Map<String, int> _headerOffsets(HtmlTable table) {
    int hr = -1;
    for (int i = 0; i < table.rows.length && i < 8; i++) {
      final String t = table.rows[i].text;
      if (t.contains('课程编号') || t.contains('课程名称')) {
        hr = i;
        break;
      }
    }
    if (hr < 0) {
      return <String, int>{}; // 认不出表头 → 用调用方的兜底偏移
    }

    final List<HtmlCell> head = table.rows[hr].cells;
    final List<String> names = <String>[];
    // 哪些列留给下一行填（本行 rowspan<2 的那些）
    final List<bool> open = <bool>[];
    for (final HtmlCell c in head) {
      final int w = c.colspan < 1 ? 1 : c.colspan;
      for (int k = 0; k < w; k++) {
        names.add(c.text.trim());
        open.add(c.rowspan < 2);
      }
    }
    if (hr + 1 < table.rows.length) {
      int idx = 0;
      for (final HtmlCell c in table.rows[hr + 1].cells) {
        final int w = c.colspan < 1 ? 1 : c.colspan;
        for (int k = 0; k < w; k++) {
          while (idx < open.length && !open[idx]) {
            idx++;
          }
          if (idx >= open.length) {
            break;
          }
          final String t = c.text.trim();
          if (t.isNotEmpty) {
            names[idx] = t; // 子列名覆盖上去（「总学时」就是这时来的）
          }
          idx++;
        }
      }
    }

    final int last = names.length - 1;
    final Map<String, int> out = <String, int>{};
    for (int i = 0; i <= last; i++) {
      final String n = names[i];
      // 同名列（学时分类的 5 个无名子列都是空串）不覆盖
      if (n.isNotEmpty && !out.containsKey(n)) {
        out[n] = last - i;
      }
    }
    return out;
  }

  /// 从右往左读一行的课程数据。
  ///
  /// 表头（两行合并后共 15 列）：
  /// `课程体系 | 选课组 | 课程编号 | 课程名称 | 完成情况 | 课程性质 |
  ///   课程属性 | 学分 | 学时分类×6（末列是总学时） | 开设学期`
  ///
  /// `cols` 是 [_headerOffsets] 从表头推出来的「列名 → 距右端偏移」。
  /// 拿不到（表头变了）时用兜底常量，那组常量是按上面的表头数出来的。
  ///
  /// 关键点：**「课程体系」只在每个分组的首行出现**，后续行第 0 格是空的
  /// （靠 rowspan 视觉合并）。所以要向下继承，否则整表会归成一组。
  ///
  /// ===== 从右侧数是唯一稳的做法 =====
  /// 左侧列数会变：
  ///   · 分组首行的「课程体系」占两行（rowspan），该行还有「选课组」，
  ///     于是 15 格；后续行两个都没有，14 格 —— 按固定下标读会**首行错位**；
  ///   · 本校的「选课组」列**整列为空**（学校没填），但它确实占一列。
  /// 右侧那些列（学期 / 总学时 / 学时分类 / 学分 / 性质 / 属性 / 完成情况
  /// / 课程名称 / 课号）的顺序与数量在一份表里是稳定的，因此从右往左数。
  static PlanCourse _readCourseFromRight(
    List<HtmlCell> cells,
    String inheritSystem,
    Map<String, int> cols,
  ) {
    int off(String name, int fallback) => cols[name] ?? fallback;

    String at(int fromEnd) {
      final int i = cells.length - 1 - fromEnd;
      if (i < 0 || i >= cells.length) {
        return '';
      }
      return cells[i].text.trim();
    }

    // 第 0 格是「体系」（仅分组首行有值，靠 rowspan 合并）
    final String system = cells.isNotEmpty ? cells[0].text.trim() : '';

    // 「选课组」= 课号左边那一格。
    //
    // 不能按固定下标（`cells[1]`）读：分组首行的课程体系占两行，
    // 于是该行的课号提前一格、`cells[1]` 恰好是**课程编号** ——
    // 界面会冒出一个组名叫「AQ25000001」的假分组。
    // 这里改成「先定位课号，再取它左邻」。
    final int codeOff = off('课程编号', 12);
    final String code = at(codeOff);
    String group = '';
    if (code.isNotEmpty) {
      final int ci = cells.length - 1 - codeOff;
      if (ci >= 2) {
        group = cells[ci - 1].text.trim();
      }
    }
    // 左邻若是课程体系自身（首行 rowspan 的情形），说明这行没有选课组
    if (group == system) {
      group = '';
    }

    return PlanCourse(
      semester: at(off('开设学期', 0)),
      totalHours: at(off('总学时', 1)),
      // 学时分类的 5 个子列本校**表头是空的**（学校没填名），
      // 只能按位置读；界面不展示它们，只展示总学时，因此不影响显示。
      computerHours: at(2),
      labHours: at(3),
      seminarHours: at(4),
      practiceHours: at(5),
      lectureHours: at(6),
      credit: at(off('学分', 7)),
      // 「课程性质」才是界面上那个彩色标签（素质拓展必修课 / 公共必修课…）。
      // 「课程属性」是另一个字段（必修 / 实践 / 选修），别拿错。
      category: at(off('课程性质', 9)),
      courseName: at(off('课程名称', 11)),
      courseCode: code,
      group: group,
      system: system.isNotEmpty ? system : inheritSystem,
    );
  }
}
