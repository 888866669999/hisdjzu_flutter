/// 个人信息解析
///
/// ===== 本校页面与参考实现不同，但形态更简单 =====
/// 参考实现（山财）是「学籍卡片」大表（`#xjkpTable`），一格里塞多组
/// 「标签：值」，还混着子表节标题，判据要写得很小心。
///
/// 本校没有学籍卡片页 —— 逐条试过所有候选后，用 `/jsxsd/bygl/bysxx`
/// （「毕业生信息核对」，实测非毕业年级同样可访问）：
///
/// ```
/// ┌──────────┬──────────────┬──────────┬──────────────────┐
/// │ 所属院系 : │ 热能工程学院   │ 所属专业 : │ 能源与动力工程…    │
/// ├──────────┼──────────────┼──────────┼──────────────────┤
/// │ 所在班级 : │ 能创251       │ 培养层次 : │ 普通本科          │
/// └──────────┴──────────────┴──────────┴──────────────────┘
/// ```
/// 即**每行 4 格 = 两组「标签: 值」**，标签带冒号（全角/半角都有）。
///
/// 因此这里保留参考实现的两条通路（单元格内冒号对 + 相邻成对），
/// 但**放宽表定位**：不再要求 `#xjkpTable`，而是扫所有表取第一张
/// 含「标签: 值」形态的 —— 本校的表没有 id。
///
/// 另外把标签**去掉末尾冒号**统一成 `所属院系`：页面写的是
/// `所属院系 :`（冒号前还有空格），不清掉会让界面显示成
/// 「所属院系 :」这种带符号的怪标签。
library;

import '../model/models.dart';
import 'html_lite.dart';

class ProfileParser {
  /// 基本信息字段（按此决定展示顺序；未列出的归入「其他信息」）
  static const List<String> _basicKeys = <String>[
    // 本校的叫法（带「所属/所在」前缀）
    '学号',
    '姓名',
    '姓名拼音',
    '性别',
    '所属院系',
    '所属专业',
    '所在班级',
    '培养层次',
    '学制',
    // 参考实现那边的叫法，一并保留：两校都能正确分组
    '院系',
    '专业',
    '班级',
    '出生日期',
    '民族',
    '政治面貌',
    '学习层次',
    '学习形式',
    '外语种类',
    '籍贯',
    '婚否',
  ];

  /// **不展示、也不缓存**的字段。
  ///
  /// ===== 为什么要有这个名单 =====
  /// 学籍卡片原文里含**身份证号**、入学考号、证书号这类高敏感信息，
  /// 而本应用把「整页原文」落盘做离线缓存 —— 若不拦掉，
  /// 身份证号就会以明文躺在应用私有目录里（虽然沙箱隔离，但没有必要承担
  /// 这个风险：这些字段与本应用的任何功能都无关）。
  ///
  /// 拦在**解析层**而不是界面层，是为了让缓存也拿不到它们：
  /// 缓存存的是原文、展示的是解析结果，只有在这里丢掉才两边都干净。
  ///
  /// 用关键词匹配而不是精确标签名：服务端这类字段的措辞不统一
  /// （实测见过「身份证编号」，别处可能叫「身份证号」「证件号码」）。
  static const List<String> _sensitiveKeywords = <String>[
    '身份证',
    // 「证件」比「证件号」更宽：本校页面把这两个字段拆成
    // 「证件类型 / 证件号」两格，「证件类型」不含「号」字，
    // 只匹配「证件号」会漏掉它（而它与号码一样与本事无关）。
    '证件',
    '入学考号',
    '证书号',
    '考生号',
    '银行卡',
  ];

  /// 该字段是否属于敏感信息（命中任一关键词）
  static bool _isSensitive(String label) {
    for (final String k in _sensitiveKeywords) {
      if (label.contains(k)) {
        return true;
      }
    }
    return false;
  }

  static StudentProfile parse(String html) {
    final StudentProfile p = StudentProfile();
    // 本校的表**没有 id**，因此扫所有表、取第一张含「标签: 值」形态的。
    // 仍优先找 `#xjkpTable`（参考实现那边用它），找不到再扫 ——
    // 这样两校都能用，不必为每所学校各写一份。
    HtmlTable? table = HtmlLite.findTableById(html, 'xjkpTable');
    if (table == null) {
      for (final HtmlTable t in HtmlLite.parseTables(html)) {
        if (_looksLikeProfileTable(t)) {
          table = t;
          break;
        }
      }
    }
    if (table == null) {
      return p;
    }

    final List<ProfileField> raw = <ProfileField>[];
    bool afterSectionTitle = false;

    for (final HtmlRow row in table.rows) {
      final List<HtmlCell> cells = row.cells;

      if (_isSectionTitleRow(cells)) {
        afterSectionTitle = true;
        continue;
      }
      // 节标题后的那一行：只有**确实是子表列名**时才跳过。
      //
      // 这里必须再加一层判断，否则会误伤真实数据行 ——
      // 实测「学籍卡片」标题（写成 `学 籍 卡 片`）后面紧跟的就是
      // 院系/专业/学制/班级/学号 那一行，早期实现把它当列名整行丢掉，
      // 结果学号、姓名拼音等字段全部消失，而界面上看不出任何异常。
      //
      // 区分依据：列名行不含冒号（`起止年月 / 学 校 或 工 作 单 位 / 职务`），
      // 真实数据行含冒号（`院系：示例学院`）。
      if (afterSectionTitle) {
        afterSectionTitle = false;
        if (!_hasColonCell(cells)) {
          continue;
        }
      }

      // 形态一：`标签：值`（一个单元格可能多组）
      for (final HtmlCell c in cells) {
        final String text = c.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (text.isEmpty || !text.contains('：')) {
          continue;
        }
        _pullColonPairs(text, raw);
      }

      // 形态二：相邻成对
      _pullAdjacentPairs(cells, raw);
    }

    // 去重（保序）。
    //
    // **值为空的字段也保留**：学校常常留空某些格（本校的「姓名」
    // 就是空的，只有拼音），丢掉会让用户以为「没有这个字段」，
    // 而实际是「学校没填」。界面会显示成 `姓名`（空值）。
    // 唯一的例外是完全没有标签的行（表头、装饰行）。
    final List<ProfileField> dedup = <ProfileField>[];
    for (final ProfileField f in raw) {
      if (f.label.isEmpty) {
        continue;
      }
      if (dedup.any((ProfileField x) => x.label == f.label)) {
        continue;
      }
      dedup.add(f);
    }

    // 抽姓名/学号
    for (final ProfileField f in dedup) {
      if (f.label == '姓名' && p.name.isEmpty) {
        p.name = f.value;
      }
      if (f.label == '学号' && p.studentId.isEmpty) {
        p.studentId = f.value;
      }
    }
    // ===== 姓名回退到拼音 =====
    // 本校的「姓名」格里是空的（学校没录入），而「姓名拼音」有值。
    // 不回退的话，外壳（顶栏/侧栏）与桌面卡片都会显示「未获取到姓名」——
    // 用户看着自己的名字明明在校网上，会以为应用坏了。
    // 用拼音显示是个可接受的折中：至少能认出是自己。
    if (p.name.isEmpty) {
      for (final ProfileField f in dedup) {
        if (f.label.contains('姓名拼音') || f.label.contains('拼音')) {
          if (f.value.isNotEmpty) {
            p.name = f.value;
            break;
          }
        }
      }
    }

    // 分组：基本信息 + 其他信息。
    // 敏感字段在这里被丢弃（见 _sensitiveKeywords 的说明）——
    // 位置刻意放在「提取姓名/学号之后、分组之前」：
    // 万一将来把类别名加进黑名单，也不会影响姓名学号的提取。
    final List<ProfileField> basic = <ProfileField>[];
    final List<ProfileField> others = <ProfileField>[];
    for (final ProfileField f in dedup) {
      if (_isSensitive(f.label)) {
        continue;
      }
      if (_basicKeys.contains(f.label)) {
        basic.add(f);
      } else {
        others.add(f);
      }
    }
    basic.sort((ProfileField a, ProfileField b) =>
        _basicKeys.indexOf(a.label).compareTo(_basicKeys.indexOf(b.label)));

    if (basic.isNotEmpty) {
      p.sections.add(ProfileSection('基本信息', basic));
    }
    if (others.isNotEmpty) {
      p.sections.add(ProfileSection('其他信息', others));
    }
    return p;
  }

  /// 该行是否含「标签：值」形态的单元格
  static bool _hasColonCell(List<HtmlCell> cells) {
    for (final HtmlCell c in cells) {
      if (c.text.contains('：')) {
        return true;
      }
    }
    return false;
  }

  /// 是否是「子表节标题」行。
  ///
  /// 判据：单个非空单元格、3–16 字（**忽略字间空格**）、不含数字与冒号。
  /// 真实页面把标题写成 `学 籍 卡 片`（字间带空格），因此必须先去掉空白再判长度，
  /// 否则长度会虚高。
  static bool _isSectionTitleRow(List<HtmlCell> cells) {
    final List<String> nonEmpty = cells
        .map((HtmlCell c) => c.text.trim())
        .where((String t) => t.isNotEmpty)
        .toList();
    if (nonEmpty.length != 1) {
      return false;
    }
    final String t = nonEmpty.first.replaceAll(RegExp(r'\s+'), '');
    if (t.length < 3 || t.length > 16) {
      return false;
    }
    if (RegExp(r'\d').hasMatch(t) || t.contains('：')) {
      return false;
    }
    return true;
  }

  /// 单元格内 `标签：值 标签：值`
  static void _pullColonPairs(String text, List<ProfileField> out) {
    // 先按冒号切出「值」，再判断值里是否混入了下一个标签
    final List<String> segs = text.split('：');
    for (int i = 0; i < segs.length - 1; i++) {
      final String label = _lastLabel(segs[i]);
      String value = segs[i + 1];
      if (i + 1 < segs.length - 1) {
        // 值的尾部可能粘着下一个标签（如 `A 专业`）
        final RegExpMatch? m =
            RegExp(r'^(.+?)\s+([\u4e00-\u9fa5A-Za-z]{2,10})$').firstMatch(value);
        if (m != null) {
          value = m.group(1)!;
        }
      }
      final String v = value.trim();
      // 标签也要过同一套校验：页脚有「注：毕业生信息核对时间未到！」，
      // 它含全角冒号、会从这个通路进来 —— 单字标签被长度判据挡掉。
      if (_isPlausibleLabel(_cleanLabel(label)) && v.isNotEmpty) {
        out.add(ProfileField(_cleanLabel(label), v));
      }
    }
  }

  /// 取 `A：` 里的 A：按空白切分取最后一段，并限制长度
  static String _lastLabel(String seg) {
    final String t = seg.trim();
    if (t.isEmpty) {
      return '';
    }
    // 不能按冒号再切（调用方已切过），按空白取最后一段
    final List<String> parts = t.split(RegExp(r'\s+'));
    String last = parts.last.trim();
    if (last.length > 12) {
      return '';
    }
    // 含括号的标签要保留（如「毕(结)业证书号」），因此只做长度与空白校验
    if (last.isEmpty) {
      return '';
    }
    return last;
  }

  /// 这张表像不像「个人信息」表？
  ///
  /// 判据：**至少两行**出现「标签(可带冒号) + 值」的相邻配对，
  /// 且标签是简短中文。用「至少两行」而不是「一行」是为了避开
  /// 页面上的零碎小表（分页器、按钮条也会成对出现）。
  static bool _looksLikeProfileTable(HtmlTable t) {
    int hits = 0;
    for (final HtmlRow row in t.rows) {
      final List<HtmlCell> cells = row.cells;
      for (int i = 0; i + 1 < cells.length; i += 2) {
        final String label = _cleanLabel(cells[i].text);
        final String value = cells[i + 1].text.trim();
        if (_isPlausibleLabel(label) && value.isNotEmpty) {
          hits++;
          break;
        }
      }
      if (hits >= 2) {
        return true;
      }
    }
    return false;
  }

  /// 标签是否像字段名：2–10 个汉字（可含括号），不含数字与长串英文
  static bool _isPlausibleLabel(String label) {
    // 长度下限 2：页面页脚有一行「注：毕业生信息核对时间未到！」，
    // 它的标签只有一个「注」字 —— 长度判据正好把它挡在外面
    // （之前它作为「其他信息 → 注」出现在界面上）。
    if (label.length < 2 || label.length > 12) {
      return false;
    }
    if (RegExp(r'^\d+$').hasMatch(label)) {
      return false;
    }
    // 允许汉字与括号（「毕(结)业证书号」这类），不含数字与英文
    return RegExp(r'^[一-龥()（）]+$').hasMatch(label);
  }

  /// 去掉标签末尾的冒号与空白：`所属院系 :` → `所属院系`
  ///
  /// 只在末尾去：字段名内部不会出现冒号。
  static String _cleanLabel(String raw) {
    String s = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    while (s.isNotEmpty) {
      final String last = s.substring(s.length - 1);
      if (last == ':' || last == '：' || last == '﹕') {
        s = s.substring(0, s.length - 1).trim();
      } else {
        break;
      }
    }
    return s;
  }

  /// 相邻单元格成对
  ///
  /// **值为空也收**：学校会留空某些格（本校的「姓名」就是空的），
  /// 丢掉会让用户以为字段不存在。界面显示成 `姓名`（空值）才如实。
  static void _pullAdjacentPairs(List<HtmlCell> cells, List<ProfileField> out) {
    for (int i = 0; i + 1 < cells.length; i += 2) {
      // 统一清掉末尾冒号（本校页面写成 `所属院系 :`）
      final String label = _cleanLabel(cells[i].text);
      if (!_isPlausibleLabel(label)) {
        continue;
      }
      out.add(ProfileField(label, _cellValue(cells[i + 1])));
    }
  }

  /// 取一个单元格的「值」。
  ///
  /// ===== 为什么不能只读文本（本校踩过的坑）=====
  /// 本校页面把部分字段做成**可编辑输入框**，值在属性里而不在文本节点：
  /// ```html
  /// <td>姓名 :</td>
  /// <td><input type="text" id="xm" name="xm" value="李示例"></td>
  /// ```
  /// 只读 `cell.text` 会得到空串 —— 于是「姓名」永远为空，外壳只能显示
  /// 「未获取到姓名」，而**页面上明明有名字**。
  ///
  /// 取不到 input 时退回文本，两种版式都能用。
  static String _cellValue(HtmlCell cell) {
    final String text = cell.text.trim();
    if (text.isNotEmpty) {
      return text;
    }
    // 退而看 input 的 value（取第一个：一个格里可能有多个 input，
    // 但字段值通常就是第一个）
    final RegExp re = RegExp(
      r'''<input[^>]*\bvalue\s*=\s*(?:"([^"]*)"|'([^']*)')''',
      caseSensitive: false,
    );
    final RegExpMatch? m = re.firstMatch(cell.inner);
    if (m == null) {
      return '';
    }
    final String raw = m.group(1) ?? m.group(2) ?? '';
    return HtmlLite.decode(raw.trim());
  }
}
