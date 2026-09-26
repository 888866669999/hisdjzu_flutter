/// 课表解析
///
/// ===== 页面结构（已对着真实页面核实）=====
/// 课表主体是**一张表**，id 各校不一：本校（山东建筑大学）是 `#timetable`，
/// 参考实现里是 `#kbtable`。表下还有一张 `#dataTables`（无课表课程），
/// 与主表无关，不要误取。
///
/// 表的结构：
///   - 第 0 行：星期表头 `星期一…星期日`；
///   - 第 1..5 行：五个节次（第一大节 … 第五大节）；节次名的单元格里**同时
///     写着小节与起止时刻**（形如「第一大节 (01,02小节) 07:50-09:25」），
///     这正好可以替代「官网作息表」——本校官网没有公开作息页，
///     所以这些时刻就是唯一的权威来源（见 SectionTimeStore）；
///   - 最后一行：备注（首格文本为「备注」）。
/// 列 0 是节次名，列 1..7 对应周一到周日。
///
/// 每个格子内部有两层同内容的 div：`kbcontent1`（简略）与 `kbcontent`（含教师）。
/// **只解析其中一层**，否则同一门课会被加两遍。
///
/// 一门课的文本形态（多门课之间用 `----------------------` 分隔）：
///   课程名 [教师] 1-18(周) 或 (双周) 或 (单周)，后跟教室名
/// 页面在 `<font title="教师">` 这类属性里给了语义标签，优先按属性取值，
/// 取不到再用正则兜底（不同学期页面写法略有差异）。
///
/// ===== 本校的两处不同 =====
///   1. **周次写法更复杂**：除 `1-16(周)` 外还有 `2,4,6,8(周)`（隔周）与
///      `1-8,13-16(周)`（分段）。旧实现只认 `a-b`，会把 `1-8,13-16` 解成
///      1~8 周、`2,4,6,8` 解成单周 2 —— 都少显示了课。这里按「取首段起、
///      末段止」处理，宁可显示得宽一点也不漏课。
///   2. **教室没有校区括号**：形如 `外文馆211[媒159]`，同属一个校区。
///      旧实现要求 `房间(校区)` 形式，取不到校区；这里把方括号里的
///      「媒159」这类也识别为分校区标记。
library;

import '../common/constants.dart';
import '../model/models.dart';
import 'html_lite.dart';

class TimetableParseResult {
  TimetableParseResult(this.timetable, this.semesters, this.weeks,
      {this.rawHtml = ''});

  final Timetable timetable;
  final List<String> semesters;
  final List<String> weeks;

  /// 服务端原文。
  ///
  /// 保留它是为了让**作息同步**能复用这次请求：建大的作息时刻只存在于
  /// 课表页的节次行里（`第一大节 (01,02小节) 07:50-09:25`），
  /// 要解析它就得有原文 —— 否则得再请求一次同一个页面。
  /// 缓存路径（从本地文件读的课表）没有原文，此时为空串。
  final String rawHtml;
}

/// 课表主体表的候选 id（本校在前）。
///
/// 强智系统各校给这张表的 id 不统一：本校是 `timetable`，别处常见 `kbtable`。
/// 两个都试，避免换一所学校就整套解析失效。
const List<String> _kTimetableTableIds = <String>['timetable', 'kbtable'];

class TimetableParser {
  /// 一格多课的分隔符：6 个及以上连续短横
  static final RegExp _multiSep = RegExp(r'-{6,}');

  static TimetableParseResult parse(String html, String semester, String week) {
    // 请求时可能**没有指定学期**（首次启动、本地还没记录过），
    // 此时服务端返回的是「它认为的当前学期」，并以 selected 标出。
    // 必须把这个值回填到 tt.semester，否则：
    //   - 课表拿不到学期名 → TimetableStore.save 因 semester 为空直接失败
    //     → 首次启动永远存不下缓存，每次启动都要联网；
    //   - 会话一旦失效，明明取到过课表却没有任何缓存可看。
    // 因此「请求值优先，请求为空时取服务端选中项」。
    final List<HtmlOption> semOpts = HtmlLite.findSelect(html, 'xnxq01id');
    final List<HtmlOption> weekOpts = HtmlLite.findSelect(html, 'zc');
    final String sem =
        semester.isNotEmpty ? semester : _selectedValue(semOpts);
    final String wk = week.isNotEmpty ? week : _selectedValue(weekOpts);

    final Timetable tt = Timetable()
      ..semester = sem
      ..week = wk;

    final HtmlTable? table = HtmlLite.findTableByIds(html, _kTimetableTableIds);
    if (table == null) {
      return TimetableParseResult(tt, _values(semOpts), _values(weekOpts),
        rawHtml: html);
    }

    int sectionRow = 0;
    for (final HtmlRow row in table.rows) {
      if (_isRemarkRow(row)) {
        tt.remark = _remarkText(row);
        continue;
      }
      // 头部行（含星期表头）跳过
      if (_isHeaderRow(row)) {
        continue;
      }
      // 数据行：列 0 是节次名，列 1..7 是周一到周日
      if (sectionRow >= kSectionRows) {
        continue;
      }
      for (int c = 1; c < row.cells.length && c <= kWeekdayCols; c++) {
        final HtmlCell cell = row.cells[c];
        final List<CourseEntry> entries =
            _parseCell(cell, sectionRow, c - 1);
        if (entries.isEmpty) {
          continue;
        }
        final CellData cd = tt.ensureCell(sectionRow, c - 1);
        cd.entries.addAll(entries);
      }
      sectionRow++;
    }

    tt.semesters = _values(semOpts);
    tt.weeks = _values(weekOpts);
    return TimetableParseResult(tt, tt.semesters, tt.weeks, rawHtml: html);
  }

  /// 取下拉框里被服务端标记为 selected 的值；没有就退回第一项。
  ///
  /// 退回第一项是有意的：教务系统的学期下拉一般按「最新在前」排序，
  /// 且实测服务端总会给当前学期打上 selected。若某次没打标记，
  /// 用第一项比用空串好 —— 空串会让缓存写入整体失效（见 parse 的说明）。
  static String _selectedValue(List<HtmlOption> opts) {
    for (final HtmlOption o in opts) {
      if (o.selected && o.value.isNotEmpty) {
        return o.value;
      }
    }
    for (final HtmlOption o in opts) {
      if (o.value.isNotEmpty) {
        return o.value;
      }
    }
    return '';
  }

  static List<String> _values(List<HtmlOption> opts) => opts
      .map((HtmlOption o) => o.value)
      .where((String v) => v.isNotEmpty)
      .toList();

  /// 是否是备注行：单格且 colspan 很大，或单元格 id 是 bz_td，
  /// 或首格文本含「备注」
  static bool _isRemarkRow(HtmlRow row) {
    if (row.cells.length == 1) {
      final HtmlCell c = row.cells.first;
      if (c.colspan >= 5 || c.id == 'bz_td') {
        return true;
      }
    }
    if (row.cells.length == 2) {
      final String first = row.cells[0].text;
      if (first.contains('备注') || row.cells[1].id == 'bz_td') {
        return true;
      }
    }
    return false;
  }

  static String _remarkText(HtmlRow row) {
    for (final HtmlCell c in row.cells) {
      if (c.id == 'bz_td' && c.text.isNotEmpty) {
        return c.text;
      }
    }
    for (final HtmlCell c in row.cells) {
      if (c.colspan >= 5 && c.text.isNotEmpty) {
        return c.text;
      }
    }
    return '';
  }

  /// 是否是表头行（含星期表头，或整行都没有课程内容）
  static bool _isHeaderRow(HtmlRow row) {
    final String joined = row.text;
    if (joined.contains('星期一') && joined.contains('星期日')) {
      return true;
    }
    // 有些页面第一行是「节次 / 星期一 …」在同一行
    if (joined.contains('星期一') && row.cells.length >= 6) {
      return true;
    }
    return false;
  }

  /// 只取一层内容（优先含教师的详细层）
  static String _pickBlock(String inner) {
    final RegExp detailed = RegExp(
      r'<div[^>]*class\s*=\s*["\u0027][^"\u0027]*\bkbcontent\b[^"\u0027]*["\u0027][^>]*>([\s\S]*?)</div>',
      caseSensitive: false,
    );
    final RegExpMatch? dm = detailed.firstMatch(inner);
    if (dm != null && (dm.group(1) ?? '').trim().isNotEmpty) {
      return dm.group(1)!;
    }
    final RegExp simple = RegExp(
      r'<div[^>]*class\s*=\s*["\u0027][^"\u0027]*kbcontent1[^"\u0027]*["\u0027][^>]*>([\s\S]*?)</div>',
      caseSensitive: false,
    );
    final RegExpMatch? sm = simple.firstMatch(inner);
    if (sm != null && (sm.group(1) ?? '').trim().isNotEmpty) {
      return sm.group(1)!;
    }
    return inner;
  }

  static List<CourseEntry> _parseCell(HtmlCell cell, int row, int col) {
    final String block = _pickBlock(cell.inner);
    if (HtmlLite.toText(block).trim().isEmpty) {
      return <CourseEntry>[];
    }
    final List<CourseEntry> out = <CourseEntry>[];

    // 一格多课：按长破折号切开，各自独立解析
    final List<String> chunks = _multiSep.hasMatch(block)
        ? block.split(_multiSep)
        : <String>[block];

    for (final String chunk in chunks) {
      final CourseEntry? e = _parseOne(chunk, row, col);
      if (e != null && e.courseName.isNotEmpty) {
        out.add(e);
      }
    }
    return out;
  }

  static CourseEntry? _parseOne(String chunk, int row, int col) {
    if (chunk.trim().isEmpty) {
      return null;
    }
    final CourseEntry e = CourseEntry(id: '', courseName: '');

    // 1) 优先用 <font title="…"> 的语义标签
    bool hasSemantic = false;
    final RegExp fontRe = RegExp(
      r'<font[^>]*title\s*=\s*["\u0027]([^"\u0027]*)["\u0027][^>]*>([\s\S]*?)</font>',
      caseSensitive: false,
    );
    for (final RegExpMatch m in fontRe.allMatches(chunk)) {
      final String title = HtmlLite.decode(m.group(1) ?? '');
      final String value = HtmlLite.toText(m.group(2) ?? '').trim();
      if (value.isEmpty) {
        continue;
      }
      if (title.contains('老师') || title.contains('教师')) {
        e.teacher = value;
        hasSemantic = true;
      } else if (title.contains('周次') || title.contains('节次')) {
        e.weekText = value;
        hasSemantic = true;
      } else if (title.contains('教室') || title.contains('地点')) {
        _applyRoom(e, value);
        hasSemantic = true;
      }
    }
    if (hasSemantic) {
      _applyWeek(e, e.weekText);
    }

    // 2) 课程名 = 去掉所有 <font> 后的第一行
    String withoutFont = chunk.replaceAll(fontRe, ' ');
    final String nameText = HtmlLite.toText(withoutFont).trim();
    e.courseName = nameText.split('\n').first.trim();

    // 3) 语义标签不足时，用正则从原文兜底
    if (e.weekText.isEmpty) {
      final String all = HtmlLite.toText(chunk);
      _fillFromText(e, all);
    }
    // 只在**语义标签完全没给出教室**时才兜底。
    //
    // 早先的条件是 `room.isEmpty || campus.isEmpty` —— 于是「教室」标签
    // 已经给出正确教室、只是没有校区时，兜底照样运行并**把正确值覆盖掉**。
    // 实测后果：`碳中和与碳循环（能创25）` 的教室被写成了课名里的「能创25」
    // （兜底正则把「能创」当成楼名、「25」当成房号），课表上那门课
    // 显示的地点纯属虚构。
    if (e.room.isEmpty) {
      final String all = HtmlLite.toText(chunk);
      _fillRoomFromText(e, all);
    }

    // 4) 稳定的 id：同一门课每次解析都能得到同一个 id
    e.id = 'srv-$row-$col-${e.courseName}-${e.startWeek}-${e.endWeek}-${e.parity}';
    return e;
  }

  /// 教室文本形如 `9-316(章丘)` 或 `外文馆211[媒159]`
  ///
  /// ===== 方括号里是什么 =====
  /// 建大的教室写成 `楼名+房号[媒159]`，方括号里是学校内部的教室编码，
  /// 不是校区（校区总是纯汉字，如「章丘/燕山/舜耕」）。它对学生没有任何
  /// 用处，却要占掉卡片上近一半的字符 —— 而卡片只有 40dp 出头宽。
  /// 因此：**纯汉字的方括号内容当校区保留，含数字的丢弃**。
  static void _applyRoom(CourseEntry e, String value) {
    final String v = value.trim();
    // 形态一：`房间(校区)`
    final RegExp re = RegExp(r'^(.+?)\s*[（(]\s*([^)）]+)\s*[)）]\s*$');
    final RegExpMatch? m = re.firstMatch(v);
    if (m != null) {
      e.room = m.group(1)!.trim();
      e.campus = m.group(2)!.trim();
      return;
    }
    // 形态二：`楼名+房号[编码]`
    final RegExpMatch? br = RegExp(r'^(.+?)\s*\[([^\]]*)\]\s*$').firstMatch(v);
    if (br != null) {
      e.room = br.group(1)!.trim();
      final String mark = br.group(2)!.trim();
      if (mark.isNotEmpty && !RegExp(r'\d').hasMatch(mark)) {
        e.campus = mark;
      }
      return;
    }
    e.room = v;
  }

  /// 从整段文本兜底提取周次/教室/教师
  static void _fillFromText(CourseEntry e, String text) {
    // 周次：`数字[,数字 - 数字]…(周)`，兼容本校的逗号列表写法
    final RegExp weekRe = RegExp(
      r'[\d,\-—~、\s]+\(\s*(单|双)?周\s*\)|\(\s*(单|双)?周\s*\)',
    );
    final RegExpMatch? wm = weekRe.firstMatch(text);
    if (wm != null) {
      e.weekText = wm.group(0)!;
      _applyWeek(e, e.weekText);
    }

    for (final String line in text.split('\n')) {
      final String t = line.trim();
      if (t.isEmpty || t == e.courseName) {
        continue;
      }
      // 教师启发式：职称，或 2–6 个汉字/间隔号
      if (e.teacher.isEmpty &&
          (RegExp(r'讲师|副教授|教授|助教|工程师|研究员').hasMatch(t) ||
              RegExp(r'^[\u4e00-\u9fa5·]{2,6}$').hasMatch(t))) {
        e.teacher = t;
      }
    }
  }

  /// 教室兜底。
  ///
  /// 本校的教室写作 `外文馆211[媒159]`：
  ///   - 没有 `房间(校区)` 那种括号，校区信息在**方括号**里；
  ///   - 楼名与房间号连写，靠「汉字+数字」的边界切开。
  /// 参考实现要求 `数字开头(校区)`，在本校一个都取不到。
  ///
  /// 因此这里两套都试：先按 `房间(校区)`，再按本校的 `楼名+房号[标记]`。
  ///
  /// 两条正则都**跳过落在课名里的匹配**：课名带数字很常见
  /// （「碳中和与碳循环（能创25）」），正则会把「能创25」切成楼名+房号，
  /// 于是课表上出现一个虚构的地点。宁可没有教室，也不能给错教室。
  static void _fillRoomFromText(CourseEntry e, String text) {
    bool inName(RegExpMatch m) =>
        e.courseName.isNotEmpty && e.courseName.contains(m.group(0)!.trim());

    // 形态一：`7-120(章丘)`
    final RegExp withCampus = RegExp(
      r'([0-9A-Za-z\-]+)\s*[（(]\s*([\u4e00-\u9fa5]{2,6})\s*[)）]',
    );
    for (final RegExpMatch m in withCampus.allMatches(text)) {
      final String room = m.group(1) ?? '';
      if (room.isNotEmpty && RegExp(r'^\d').hasMatch(room) && !inName(m)) {
        e.room = room;
        e.campus = m.group(2) ?? '';
        return;
      }
    }
    // 形态二：`外文馆211[媒159]`（本校）
    final RegExp local = RegExp(
      r'([\u4e00-\u9fa5]{2,8})(\d{2,4}[0-9A-Za-z\-]*)',
    );
    for (final RegExpMatch m in local.allMatches(text)) {
      final String building = m.group(1) ?? '';
      final String room = m.group(2) ?? '';
      if (room.isEmpty) {
        continue;
      }
      // **课名不能当教室**：课名里带数字很常见（「碳中和与碳循环（能创25）」
      // 「大学英语3」），而这条正则会正好把「能创25」切成楼名+房号。
      // 实测后果是那门课在课表上显示一个虚构的地点。凡是整体落在课名里的
      // 匹配一律跳过。
      if (e.courseName.isNotEmpty &&
          e.courseName.contains(m.group(0)!.trim())) {
        continue;
      }
      e.room = building + room;
      return;
    }
  }

  /// 从周次文本解析起始/结束周与单双周。
  ///
  /// ===== 本校的周次写法比参考实现复杂，必须都覆盖 =====
  ///   `1-16(周)`          → 1..16（最常见）
  ///   `3(周)`             → 3..3（单周上课）
  ///   `1-8,13-16(周)`     → 1..16（**分段**：去掉中间几周）
  ///   `2,4,6,8(周)`       → 2..8（**隔周**）
  ///   `1-18(周)[03-04节]` → 后面还跟着节次，取前面的周次即可
  ///
  /// 后两种是本校特有的。旧实现只认 `a-b`，遇到逗号列表会取到**第一个数字**
  /// 当成起止（`2,4,6,8` 变成单周 2；`1-8,13-16` 变成 1~8）——
  /// 结果是这些课在多数周次里不显示，看起来像「课表漏课」。
  ///
  /// 这里的策略是**宁宽勿漏**：取所有分段中的最小值当起始、最大值当结束。
  /// 代价是分段之间的空档也会显示课程，但那只是「多显示」；
  /// 反过来漏课会让用户以为没课，性质更严重。
  static void _applyWeek(CourseEntry e, [String? text]) {
    final String t = (text == null || text.isEmpty) ? e.weekText : text;
    if (t.contains('双周')) {
      e.parity = 2;
    } else if (t.contains('单周')) {
      e.parity = 1;
    } else {
      e.parity = 0;
    }

    // 取出周次部分（`(周)` / `(单周)` 之前的内容），避免把节次数字当周次
    final int paren = t.indexOf('(');
    final String head = paren > 0 ? t.substring(0, paren) : t;

    // 收集该字段里出现的**所有**数字，取最小/最大
    final List<int> nums = <int>[];
    for (final RegExpMatch m in RegExp(r'\d+').allMatches(head)) {
      final int? v = int.tryParse(m.group(0)!);
      if (v != null && v > 0 && v <= kMaxWeeks) {
        nums.add(v);
      }
    }
    if (nums.isEmpty) {
      return;
    }
    int lo = nums.first;
    int hi = nums.first;
    for (final int v in nums) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    // 只有一个数字时是「单周上课」，起止相同
    e.startWeek = lo;
    e.endWeek = hi;
  }
}
