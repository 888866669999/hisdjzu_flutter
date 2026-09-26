/// 空闲教室结果解析
///
/// ===== 本校与参考实现的页面结构不同，两种都要支持 =====
///
/// 参考实现（`/jsxsd/kbcx/kbxx_classroom_ifr`）：
///   一张 `#kbtable`，表头是 `教室 | 星期一 … 星期日`（8 列），
///   多节次查询时 36 列。数据行首列是教室名。
///
/// 本校（`POST /jsxsd/kbxx/jsjy_query2`，返回 `#dataList`）：
///   **三行表头** + 数据行：
///     行 0：`功能区名称 | 教室名称 | 查询`（合并单元格，忽略）
///     行 1：`星期 | 星期一 … 星期日`
///     行 2：`'' | 0102 | 030405 | 0607 | 0809 | 101112 | 0102 …`
///           —— 每 5 列一组对应一个星期，组内是 5 个大节
///     行 3+：`信息楼211(80/80) | 各节次格子（有内容=占用，空=空闲）`
///
///   **关键差别**：本校的节次维度在第 2 行表头（`0102` 这种小节编号），
///   不能像参考实现那样只靠「列数/位置」推断 —— 那样会把周三的占用
///   算到周二去。因此本校结构必须读那一行才能建列映射。
///
/// ===== 空闲的判定是共用的 =====
/// 两边返回的都是「按条件筛出的结果」：**格子里有内容 = 被占用**，
/// 空 = 空闲。本校多一个 `jszt` 参数可以直接筛「完全空闲」。
///
/// ===== 表头列数不固定 =====
/// 同一个结果表可能是 8 列（单节次）也可能是 36 列（多节次）。
/// 因此**不能按列下标硬映射星期**，必须按表头文本里的
/// `星期一…星期日` 动态建映射。
library;

import '../model/classroom_models.dart';
import 'html_lite.dart';

/// 课表的节次行数（本校 5 个大节）。
///
/// 与 `constants.dart` 的 `kSectionRows` 同值。这里单独定义一份是为了
/// 不把 `constants.dart` 拖进解析器（解析器要保持「纯函数、无全局依赖」，
/// 那样才好在单测里直接喂 HTML）。
const int _kSectionCount = 5;

class ClassroomParser {
  /// 读校区下拉。值形如 `01|本部`（value|label）。
  ///
  /// 下拉 name 各校不同：参考实现是 `xqid`，本校是 `xqbh`。
  static List<String> parseCampuses(String html) {
    for (final String name in <String>['xqbh', 'xqid']) {
      final List<String> out = HtmlLite.findSelect(html, name)
          .where((HtmlOption o) => o.value.isNotEmpty)
          .map((HtmlOption o) => '${o.value}|${o.label}')
          .toList();
      if (out.isNotEmpty) {
        return out;
      }
    }
    return <String>[];
  }

  /// 读当前学期。
  ///
  /// ===== 本校的学期**不是下拉**，是隐藏字段（实测）=====
  /// 页面里学期写作 `<input type="hidden" id="xnxqh" value="2026-2027-1">`
  /// 加一行只读文本；连页面 JS 里那句 `$("#xnxqh").options[...]` 都被注释掉了
  /// ——学校就是把下拉改成了固定值。
  ///
  /// 早先只查 `select`，于是永远返回空列表 → 空教室页直接卡在
  /// 「请先选择学期」，一次查询都发不出去（而界面上看不出是为什么）。
  ///
  /// 因此现在的顺序是：先找下拉（别处仍是下拉），找不到再读隐藏字段。
  static List<String> parseSemesters(String html) {
    for (final String name in <String>['xnxqh', 'xnxq01id']) {
      final List<String> out = HtmlLite.findSelect(html, name)
          .map((HtmlOption o) => o.value)
          .where((String v) => v.isNotEmpty)
          .toList();
      if (out.isNotEmpty) {
        return out;
      }
    }
    // 兜底：隐藏字段里那个「当前学期」
    for (final String name in <String>['xnxqh', 'xnxq01id']) {
      final String v = HtmlLite.findInputValue(html, name).trim();
      if (v.isNotEmpty) {
        return <String>[v];
      }
    }
    return <String>[];
  }

  /// 解析结果。
  ///
  /// @param sectionRow 查询的是第几个节次（用于多节次表时挑对应块）
  static ClassroomResult parseResult(String html, int sectionRow) {
    // 表 id 各校不同：本校 dataList、参考实现 kbtable
    final HtmlTable? table =
        HtmlLite.findTableByIds(html, <String>['dataList', 'kbtable']);
    if (table == null || table.rows.isEmpty) {
      return ClassroomResult(sectionRow: sectionRow);
    }
    // 先按本校的三行表头结构试；不像就走参考实现那套
    final ClassroomResult? local = _parseLocalLayout(table, sectionRow);
    if (local != null) {
      return local;
    }
    return _parseReferenceLayout(table, sectionRow);
  }

  /// 本校布局（三行表头 + `教室名(容量/人数)` 行首）。
  ///
  /// 返回 null 表示「不是这个结构」，交给参考实现的解析器。
  static ClassroomResult? _parseLocalLayout(HtmlTable table, int sectionRow) {
    // ---- 找「星期表头行」与紧随其后的「节次编号行」----
    int dayRow = -1;
    for (int i = 0; i < table.rows.length && i < 4; i++) {
      final String t = table.rows[i].text;
      if (t.contains('星期一') && t.contains('星期日')) {
        dayRow = i;
        break;
      }
    }
    if (dayRow < 0 || dayRow + 1 >= table.rows.length) {
      return null;
    }
    final List<HtmlCell> secCells = table.rows[dayRow + 1].cells;

    // ===== 列映射必须靠**节次编号行**，不能靠星期表头 =====
    //
    // 这张表的实际结构：
    //   行 0：`功能区名称 | 教室名称 | 查询`（合并格，忽略）
    //   行 1：`星期 | 星期一 | 星期二 | …`  ← **8 格**，星期列是 colspan=5
    //   行 2：`'' | 01 02 | 03 04 05 | 06 07 | 08 09 | 10 11 12 | 01 02 …`
    //         ← **36 格** = 7 天 × 5 大节，每格是该大节的小节编号
    //   行 3+：`信息楼211(80/80) | 各节次格子`
    //
    // 早先按行 1 的格号建映射：它只有 8 格，于是
    //   列1..5（周一的五个大节）被当成周一…周五，
    //   列6..7（周二前两节）被当成周六、周日，
    //   **周三到周日的数据一格都没读**。
    // 而查询「完全空闲」时所有格子都是空的，结果看起来完全正常 ——
    // 直到某间教室有占用，才会把周二的内容显示到周一。
    //
    // 正确做法：行 2 的格 i 对应「天 = (i-1) ÷ 5、大节 = (i-1) % 5」。
    final Map<int, int> dayOfCol = <int, int>{};
    final Map<int, int> sectionOfCol = <int, int>{};
    for (int c = 1; c < secCells.length; c++) {
      final int day = (c - 1) ~/ _kSectionCount;
      final int sec = (c - 1) % _kSectionCount;
      if (day >= 0 && day < 7) {
        dayOfCol[c] = day;
        sectionOfCol[c] = sec;
      }
    }
    if (dayOfCol.isEmpty) {
      return null;
    }

    final ClassroomResult result = ClassroomResult(sectionRow: sectionRow);
    for (int r = dayRow + 2; r < table.rows.length; r++) {
      final List<HtmlCell> cells = table.rows[r].cells;
      if (cells.length < 2) {
        continue;
      }
      final String roomRaw = cells[0].text.trim();
      if (roomRaw.isEmpty || roomRaw.contains('教室名称')) {
        continue;
      }
      final RoomSlot slot = RoomSlot(_stripCapacity(roomRaw));
      for (final MapEntry<int, int> e in dayOfCol.entries) {
        if (e.key >= cells.length) {
          continue;
        }
        final int day = e.value;
        final int sec = sectionOfCol[e.key] ?? 0;
        // 同一格同时记两份：按天（粗粒度）与按天+节次（精确）。
        // 只记前者的后果见 RoomSlot.bySection 的说明。
        _parseCell(cells[e.key].inner, slot.bySection[day][sec]);
        _parseCell(cells[e.key].inner, slot.days[day]);
      }
      result.rooms.add(slot);
    }
    return result;
  }

  /// 把教室名里的**冗余后缀**去掉，只留教室本身的名字。
  ///
  /// 服务端给的是 `博文馆101[媒159](159/72)`，三段各有各的毛病：
  ///   - `(159/72)` 是「容量/当前人数」。留着的后果不只是多一截数字：
  ///     同一间教室人数一变就被当成两间，排序与计数都会乱。
  ///   - `[媒159]` 是教室编码前缀（媒=多媒体、智=智慧教室，数字与容量相同），
  ///     纯粹是内部标记，学生找教室用不到，却占掉卡片近一半宽度。
  ///
  /// 因此两段都去掉，只留 `博文馆101` —— 那才是要找的名字。
  static String _stripCapacity(String raw) {
    String s = raw.trim();
    // 先剥尾部的 `(容量/人数)`；个别行没这一段，剥不到就原样继续
    final RegExpMatch? m =
        RegExp(r'^(.+?)\s*[（(]\s*\d+\s*/\s*\d+\s*[)）]\s*$').firstMatch(s);
    if (m != null) {
      s = m.group(1)!.trim();
    }
    // 再剥尾部的 `[编码]`
    final RegExpMatch? b = RegExp(r'^(.+?)\s*\[[^\]]*\]\s*$').firstMatch(s);
    if (b != null) {
      s = b.group(1)!.trim();
    }
    return s.isEmpty ? raw.trim() : s;
  }

  /// 参考实现的布局（表头单行星期、首列教室名）
  static ClassroomResult _parseReferenceLayout(
      HtmlTable table, int sectionRow) {
    final ClassroomResult result = ClassroomResult(sectionRow: sectionRow);

    // 1) 建「列 → 星期」映射
    final Map<int, int> dayOfCol = <int, int>{};
    final List<HtmlCell> header = table.rows[0].cells;
    for (int c = 0; c < header.length; c++) {
      final int d = _dayIndex(header[c].text);
      if (d >= 0 && !dayOfCol.containsValue(d)) {
        dayOfCol[c] = d;
      }
    }
    // 表头识别失败时退回「第 1 列起依次为周一到周日」
    if (dayOfCol.isEmpty) {
      for (int c = 1; c < header.length && c <= 7; c++) {
        dayOfCol[c] = c - 1;
      }
    }

    // 宽表（≥30 列）时每 5 列一组：与本校布局同样的划分规则。
    // 窄表（8 列 = 单节次查询）时所有列都归第 0 节。
    final bool multiSection = table.rows.isNotEmpty &&
        table.rows
            .any((HtmlRow r) => r.cells.length >= _kSectionCount * 6);

    // 2) 数据行从第 2 行开始（第 1 行是节次标签）
    for (int r = 1; r < table.rows.length; r++) {
      final List<HtmlCell> cells = table.rows[r].cells;
      if (cells.isEmpty) {
        continue;
      }
      final String room = cells[0].text.trim();
      if (room.isEmpty || room.contains('教室')) {
        continue;
      }
      final RoomSlot slot = RoomSlot(room);
      for (final MapEntry<int, int> e in dayOfCol.entries) {
        if (e.key >= cells.length) {
          continue;
        }
        final int day = e.value;
        final int sec = multiSection ? (e.key - 1) % _kSectionCount : 0;
        _parseCell(cells[e.key].inner, slot.bySection[day][sec]);
        _parseCell(cells[e.key].inner, slot.days[day]);
      }
      result.rooms.add(slot);
    }
    return result;
  }

  /// `星期一` / `周一` 都认
  static int _dayIndex(String text) {
    const List<String> full = <String>[
      '星期一',
      '星期二',
      '星期三',
      '星期四',
      '星期五',
      '星期六',
      '星期日',
    ];
    const List<String> short = <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    for (int i = 0; i < 7; i++) {
      if (text.contains(full[i]) || text.contains(short[i])) {
        return i;
      }
    }
    return -1;
  }

  /// 一个格子里可能有多条（`<br>` 分隔）
  static void _parseCell(String inner, List<RoomBooking> out) {
    if (inner.trim().isEmpty) {
      return;
    }
    final List<String> parts =
        inner.split(RegExp(r'<br\s*/?>', caseSensitive: false));
    bool any = false;
    for (final String part in parts) {
      final RoomBooking? b = _parseBooking(part);
      if (b != null) {
        out.add(b);
        any = true;
      }
    }
    if (!any) {
      // 有文本但没解析出结构：保守判为占用（宁可少报空闲，不要误报）
      final String text = HtmlLite.toText(inner).trim();
      if (text.isNotEmpty) {
        final WeekSpec? spec = WeekSpecParser.first(text);
        out.add(RoomBooking(
          label: text.split('\n').first,
          spec: spec ?? WeekSpec(<List<int>>[], 0, ''),
        ));
      }
    }
  }

  static RoomBooking? _parseBooking(String raw) {
    final String text = HtmlLite.toText(raw).trim();
    if (text.isEmpty) {
      return null;
    }

    // ---- 借用形态 ----
    if (text.contains('被借用')) {
      // 借用( 第(2周)(01-04节)周,王超,学生活动 )
      final String after = text.substring(text.indexOf('被借用') + 3);
      final RegExpMatch? m = RegExp(r'\(\s*([^)]*)\s*\)').firstMatch(after);
      final String inner = m?.group(1)?.trim() ?? '';
      final List<String> segs = inner
          .split(RegExp(r'[,，]'))
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
      String person = '';
      String label = '被借用';
      if (segs.length >= 2 && !segs[1].contains('第')) {
        person = segs[1];
      }
      if (segs.length >= 3) {
        label = '借用：${segs[2].replaceAll(RegExp(r'[)）\s]+$'), '')}';
      }
      if (person.isNotEmpty) {
        label = '$label · $person';
      }
      final String weekSrc = text.contains('(') ? after : text;
      return RoomBooking(
        label: label,
        person: person,
        borrowed: true,
        spec: WeekSpecParser.first(weekSrc) ?? WeekSpec(<List<int>>[], 0, ''),
      );
    }

    // ---- 课程形态 ----
    // `课程名 教师\n(3-18周)\n班级`
    final int parenAt = text.indexOf('(');
    final String head = parenAt > 0 ? text.substring(0, parenAt) : text;
    final String tail = parenAt > 0 ? text.substring(parenAt) : '';

    final List<String> tokens = head.replaceAll('\n', ' ').split(RegExp(r'\s+'));
    String person = '';
    if (tokens.length >= 2) {
      final String last = tokens.last;
      if (RegExp(r'^[\u4e00-\u9fa5·]{2,6}$').hasMatch(last)) {
        person = last;
      }
    }
    final String label =
        person.isNotEmpty ? head.replaceFirst(RegExp('$person\$'), '').trim() : head.trim();

    String className = '';
    final int closeParen = tail.indexOf(')');
    if (closeParen >= 0 && closeParen + 1 < tail.length) {
      className = tail.substring(closeParen + 1).trim();
    }

    return RoomBooking(
      label: label.isEmpty ? head.trim() : label,
      person: person,
      className: className,
      spec: WeekSpecParser.first(text) ?? WeekSpec(<List<int>>[], 0, ''),
    );
  }
}
