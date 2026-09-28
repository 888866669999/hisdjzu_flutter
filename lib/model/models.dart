/// 数据模型
///
/// 从鸿蒙版 `model/Models.ets` 移植。字段名保持与本地缓存文件一致，
/// 便于两版互查（缓存不跨平台共用，但字段语义要能对上）。
library;

/// 一门课（课表格子里的一个条目）
class CourseEntry {
  CourseEntry({
    required this.id,
    required this.courseName,
    this.teacher = '',
    this.room = '',
    this.campus = '',
    this.weekText = '',
    this.startWeek = 1,
    this.endWeek = 18,
    this.parity = 0,
    this.local = false,
    this.rev = 0,
  });

  String id;
  String courseName;
  String teacher;
  String room;
  String campus;

  /// 原始周次文本（页面上的写法）
  String weekText;

  /// 起始周 / 结束周
  int startWeek;

  int endWeek;

  /// 0 = 每周，1 = 单周，2 = 双周
  int parity;

  /// 是否是用户在本地手工添加/修改的
  bool local;

  /// 修订号：本地编辑时自增，用于强制界面刷新
  int rev;

  /// 本周是否上这门课。
  ///
  /// 这是整个课表功能的核心判定，边界必须严格：
  ///   - 周次未知（<=0）时一律显示，宁可多显示也不要漏；
  ///   - 区间外不显示；
  ///   - 单周/双周按奇偶过滤。
  bool isActiveInWeek(int week) {
    if (week <= 0) {
      return true;
    }
    if (week < startWeek || week > endWeek) {
      return false;
    }
    if (parity == 1 && week % 2 == 0) {
      return false;
    }
    if (parity == 2 && week % 2 == 1) {
      return false;
    }
    return true;
  }

  String parityText() {
    if (parity == 1) {
      return '单周';
    }
    if (parity == 2) {
      return '双周';
    }
    return '';
  }

  /// 形如 `1-18周` / `1-18周(双周)`
  String weekSummary() {
    final String base = '$startWeek-$endWeek周';
    final String p = parityText();
    return p.isEmpty ? base : '$base($p)';
  }

  CourseEntry clone() => CourseEntry(
        id: id,
        courseName: courseName,
        teacher: teacher,
        room: room,
        campus: campus,
        weekText: weekText,
        startWeek: startWeek,
        endWeek: endWeek,
        parity: parity,
        local: local,
        rev: rev,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': courseName,
        'teacher': teacher,
        'room': room,
        'campus': campus,
        'startWeek': startWeek,
        'endWeek': endWeek,
        'parity': parity,
        'local': local,
        'rev': rev,
      };

  static CourseEntry fromJson(Map<String, dynamic> j) => CourseEntry(
        id: (j['id'] ?? '') as String,
        courseName: (j['name'] ?? '') as String,
        teacher: (j['teacher'] ?? '') as String,
        room: (j['room'] ?? '') as String,
        campus: (j['campus'] ?? '') as String,
        startWeek: (j['startWeek'] ?? 1) as int,
        endWeek: (j['endWeek'] ?? 18) as int,
        parity: (j['parity'] ?? 0) as int,
        local: (j['local'] ?? false) as bool,
        rev: (j['rev'] ?? 0) as int,
      );
}

/// 课表格子（第 row 节、第 col 天，都是 0 基）
class CellData {
  CellData({required this.row, required this.col, List<CourseEntry>? entries})
      : entries = entries ?? <CourseEntry>[];

  int row;
  int col;
  List<CourseEntry> entries;
}

/// 一张课表
class Timetable {
  Timetable({
    this.semester = '',
    this.week = '',
    List<String>? semesters,
    List<String>? weeks,
    List<CellData>? cells,
    this.remark = '',
    this.cachedAt = 0,
    this.edited = false,
    List<String>? serverIds,
  })  : semesters = semesters ?? <String>[],
        weeks = weeks ?? <String>[],
        cells = cells ?? <CellData>[],
        serverIds = serverIds ?? <String>[];

  String semester;

  /// 当前查看的周次（'' 表示全部）
  String week;
  List<String> semesters;
  List<String> weeks;
  List<CellData> cells;
  String remark;
  int cachedAt;

  /// 是否含本地改动
  bool edited;

  /// **服务器原始课程的 id 基线**（拉取那一刻记下，之后不再变）。
  ///
  /// ===== 为什么需要它 =====
  /// 早先判断「是否改过」只看每个条目自己的 `local` 标记
  /// （见 [hasLocalEdits]）。那个标记对「新增」和「修改」有效，
  /// 但**删除**服务器课程时，条目连同标记一起消失了 ——
  /// 于是删完之后一个 `local` 都不剩，界面判定为「未修改」，
  /// 「已修改」入口不出现，用户也没有办法恢复（真机反馈）。
  ///
  /// 有了这条基线就能表达「原本有什么、现在缺了什么」：
  /// 只要基线里有 id 在当前课表里找不到，就说明被删过。
  ///
  /// 只存 id 而不是整份原始数据：id 由「行/列/课名/周次」拼成，
  /// 已经足以标识一门课（见 TimetableParser 的 id 生成），
  /// 而整份副本会让缓存体积翻倍。
  List<String> serverIds;

  CellData? findCell(int row, int col) {
    for (final CellData c in cells) {
      if (c.row == row && c.col == col) {
        return c;
      }
    }
    return null;
  }

  CellData ensureCell(int row, int col) {
    final CellData? found = findCell(row, col);
    if (found != null) {
      return found;
    }
    final CellData c = CellData(row: row, col: col);
    cells.add(c);
    return c;
  }

  /// 删掉没有任何课程的格子（保持缓存干净）
  void pruneEmptyCells() {
    cells.removeWhere((CellData c) => c.entries.isEmpty);
  }

  bool hasAnyCourse(String week) {
    final int w = int.tryParse(week) ?? 0;
    for (final CellData c in cells) {
      for (final CourseEntry e in c.entries) {
        if (e.isActiveInWeek(w)) {
          return true;
        }
      }
    }
    return false;
  }

  /// 当前课表是否与「服务器给的那份」不同。
  ///
  /// 三种改动都要能识别出来：
  ///   1. **新增/修改** —— 条目带 `local` 标记（由编辑弹窗写入）；
  ///   2. **删除** —— 基线里的某个 id 在当前课表里已经不存在。
  ///      这是早先漏掉的一类：删除会把条目连标记一起去掉，
  ///      只看 `local` 就永远判定为「未修改」。
  ///
  /// 基线为空时（旧缓存、或还没从服务器取过）退化为只看 `local` ——
  /// 宁可少报，也不能把一份干净的服务器课表误判成「已修改」。
  bool hasLocalEdits() {
    final Set<String> alive = <String>{};
    for (final CellData c in cells) {
      for (final CourseEntry e in c.entries) {
        // 本地新增的课本来就不在基线里，不该参与「缺失」判定
        if (e.local) {
          return true;
        }
        alive.add(e.id);
      }
    }
    if (serverIds.isEmpty) {
      return false;
    }
    for (final String id in serverIds) {
      if (!alive.contains(id)) {
        return true; // 服务器有、现在没有 = 被删过
      }
    }
    return false;
  }

  /// 记录当前课表里的服务器课程作为基线。
  ///
  /// **只在从服务器新鲜拉取时调用一次**，之后不再覆盖 ——
  /// 否则每次保存都把「已删掉的那门课」从基线里抹掉，
  /// 删除就再也检测不出来了。
  void captureServerBaseline() {
    final List<String> ids = <String>[];
    for (final CellData c in cells) {
      for (final CourseEntry e in c.entries) {
        if (!e.local) {
          ids.add(e.id);
        }
      }
    }
    serverIds = ids;
  }
}

/// 一条成绩
class ScoreRecord {
  ScoreRecord({
    this.index = '',
    this.semester = '',
    this.courseCode = '',
    this.courseName = '',
    this.score = '',
    this.credit = '',
    this.gpa = '',
    this.examType = '',
    this.courseNature = '',
    this.courseAttr = '',
    this.minor = '',
  });

  String index;
  String semester;
  String courseCode;
  String courseName;
  String score;
  String credit;
  String gpa;
  String examType;
  String courseNature;
  String courseAttr;
  String minor;

  double creditNumber() => double.tryParse(credit) ?? 0;

  /// 绩点缺失时返回 -1（而不是 0），以便统计时区分「没绩点」与「绩点为 0」
  double gpaNumber() => double.tryParse(gpa) ?? -1;

  bool get isFail => (double.tryParse(score) ?? 100) < 60;
}

/// 成绩汇总
class ScoreSummary {
  ScoreSummary(this.count, this.totalCredit, this.averageGpa);

  final int count;
  final double totalCredit;

  /// **平均绩点**（各科绩点之和 ÷ 科目数）。
  ///
  /// 取值口径见 `ScoreParser.summarize`：本校不用学分加权，
  /// 且绩点由分数推出（`(分数 - 50) ÷ 10`）——页面上的「绩点」列整列是 0。
  final double averageGpa;
}

/// 个人信息字段
class ProfileField {
  ProfileField(this.label, this.value);

  final String label;
  final String value;
}

class ProfileSection {
  ProfileSection(this.title, this.fields);

  final String title;
  final List<ProfileField> fields;
}

class StudentProfile {
  StudentProfile({this.name = '', this.studentId = '', List<ProfileSection>? sections})
      : sections = sections ?? <ProfileSection>[];

  String name;
  String studentId;
  List<ProfileSection> sections;
}

/// 下拉项
class ChoiceItem {
  ChoiceItem(this.label, this.value);

  final String label;
  final String value;
}

/// 周次 → 该周周一日期（YYYY-MM-DD）
class WeekDate {
  WeekDate(this.week, this.monday);

  final int week;
  final String monday;
}

/// 培养方案里的一门课
class PlanCourse {
  PlanCourse({
    this.system = '',
    this.group = '',
    this.courseCode = '',
    this.courseName = '',
    this.category = '',
    this.credit = '',
    this.semester = '',
    this.lectureHours = '',
    this.practiceHours = '',
    this.seminarHours = '',
    this.labHours = '',
    this.computerHours = '',
    this.totalHours = '',
  });

  String system;
  String group;
  String courseCode;
  String courseName;
  String category;
  String credit;
  String semester;
  String lectureHours;
  String practiceHours;
  String seminarHours;
  String labHours;
  String computerHours;
  String totalHours;

  double creditNumber() => double.tryParse(credit) ?? 0;
}

class PlanGroup {
  PlanGroup(this.system, List<PlanCourse>? courses, this.totalCredit)
      : courses = courses ?? <PlanCourse>[];

  final String system;
  final List<PlanCourse> courses;
  double totalCredit;
}

/// 培养方案明细
class PlanDetail {
  PlanDetail({
    List<String>? introParagraphs,
    List<String>? detailParagraphs,
    List<PlanCourse>? courses,
    List<PlanGroup>? groups,
    this.totalCredit = 0,
    this.totalHours = 0,
  })  : introParagraphs = introParagraphs ?? <String>[],
        detailParagraphs = detailParagraphs ?? <String>[],
        courses = courses ?? <PlanCourse>[],
        groups = groups ?? <PlanGroup>[];

  List<String> introParagraphs;
  List<String> detailParagraphs;
  List<PlanCourse> courses;
  List<PlanGroup> groups;
  double totalCredit;
  double totalHours;

  void buildGroups() {
    final Map<String, PlanGroup> map = <String, PlanGroup>{};
    for (final PlanCourse c in courses) {
      final String key = c.system.isEmpty ? '未分类' : c.system;
      final PlanGroup g = map.putIfAbsent(key, () => PlanGroup(key, null, 0));
      g.courses.add(c);
      g.totalCredit += c.creditNumber();
    }
    groups = map.values.toList();
  }
}

/// 通选课类别
class ElectiveCategory {
  ElectiveCategory({
    required this.name,
    this.required = '',
    this.earned = '',
    this.ongoing = '',
    List<ElectiveCourse>? courses,
  }) : _courses = courses;

  /// 该大类下的课程明细。**按需加载**：只有用户展开时才去抓详情页，
  /// 首次进入通选页不会为 11 个大类打 11 个请求。
  ///
  /// `null` 表示还没加载过；空列表表示加载过但没有课程。
  List<ElectiveCourse>? _courses;

  List<ElectiveCourse> get courses => _courses ?? <ElectiveCourse>[];

  /// 是否已加载过（用于区分「还没取」与「取到空」）
  bool get coursesLoaded => _courses != null;

  set courses(List<ElectiveCourse> v) => _courses = v;

  /// 是否有课程可展开。未加载时**不算**没有 —— 界面据 coursesLoaded 决定
  /// 是「去取」还是「确实没有」。
  bool get hasCourses => courses.isNotEmpty;

  final String name;
  String required;
  String earned;
  String ongoing;

  /// 学校确实留空了「要求学分」（实测），此时不能判为「未达标」。
  bool satisfied() {
    final double req = double.tryParse(required) ?? -1;
    if (req < 0) {
      return false;
    }
    final double e = double.tryParse(earned) ?? 0;
    final double o = double.tryParse(ongoing) ?? 0;
    return e + o >= req;
  }

  bool get hasRequirement => (double.tryParse(required) ?? -1) >= 0;
}

/// 通选课记录
/// 通选大类下的一门课
///
/// 两个来源共用这个类：
///   · 参考实现那边是主页自带的「课程明细」子表；
///   · **本校**的明细在另一个页面 —— 每个大类的「详情」指向
///     `/jsxsd/xxwcqk/xxwcqkOnkctxByxq.do?kctxmc=<大类名>`，可直接 GET，
///     返回 8 列表格：`课程编号 | 课程名称 | 学分 | 课程属性 | 课程性质 |
///     总成绩 | 备注 | 是否学位课`。
class ElectiveCourse {
  ElectiveCourse({
    this.courseCode = '',
    this.courseName = '',
    this.credit = '',
    this.score = '',
    this.category = '',
    this.attr = '',
    this.remark = '',
  });

  String courseCode;
  String courseName;
  String credit;
  String score;
  String category;

  /// 课程属性（必修 / 选修 / 实践…）—— 本校详情页有这一列
  String attr;

  /// 备注列（本校详情页有，多数为空）
  String remark;

  bool get isOngoing => score.contains('正在修读');

  /// 已出成绩（界面据此把课程归到「已修」而不是「在读」）
  bool get hasScore => score.isNotEmpty && !isOngoing;

  double creditNumber() =>
      double.tryParse(credit.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0;
}

/// 一个大类 + 它下面的课程（界面按这个分组展示）
///
/// 学校原页面是两张独立的表：「类别修读情况」和「课程明细」，
/// 学生要自己按类别名对照。分组把两者合成一条时间线。
class ElectiveGroup {
  ElectiveGroup(this.name);

  final String name;
  final List<ElectiveCourse> courses = <ElectiveCourse>[];

  /// 汇总表里的要求信息；只在课程明细里出现、汇总表没有的大类为 null。
  ElectiveCategory? info;

  /// 用户自录的要求学分（>=0 时生效，-1 表示未设置）。
  ///
  /// 为什么要这个覆盖值：学校「要求学分（大于等于）」那一列实测是空的，
  /// 于是界面只能显示「学校未设置要求」、也画不出进度条 ——
  /// 学生明明可以从培养方案查到自己要修多少，App 却帮不上忙。
  /// 用户录一次后，达标判断与进度条都以这个值为准。
  ///
  /// 优先级：**用户自录 > 服务器**。用户手填的是他自己专业的准确要求，
  /// 而服务器那一列要么为空、要么是学校统一口径，以用户为准更符合预期。
  double customRequired = -1;

  bool get hasCourses => courses.isNotEmpty;

  /// 是否已尝试加载过课程明细。
  ///
  /// 本校的明细在**另一个页面**（每行的「详情」），所以是**按需拉取**：
  /// 用户点开哪个大类才去抓哪个 —— 首屏不为 11 个大类打 11 个请求。
  /// 这个标记用来区分「还没取」（可点开）与「取过但没有课程」（不可点）。
  bool coursesLoaded = false;

  /// 是否使用用户自录的要求（界面据此显示「修改」而不是「设置」）
  bool get hasCustomRequired => customRequired >= 0;

  /// 能画进度条的前提：有正的分母（分母为 0 画出来没有意义）
  bool get canShowProgress => requiredNumber > 0;

  double get requiredNumber {
    if (customRequired >= 0) {
      return customRequired;
    }
    final ElectiveCategory? c = info;
    if (c == null) {
      return -1;
    }
    return double.tryParse(c.required) ?? -1;
  }

  double get earnedNumber => double.tryParse(info?.earned ?? '') ?? 0;

  double get ongoingNumber => double.tryParse(info?.ongoing ?? '') ?? 0;
}

class ElectiveReport {
  ElectiveReport({
    List<ElectiveCategory>? categories,
    List<ElectiveCourse>? courses,
    this.totalEarned = '',
    this.totalOngoing = '',
  })  : categories = categories ?? <ElectiveCategory>[],
        courses = courses ?? <ElectiveCourse>[];

  List<ElectiveCategory> categories;
  List<ElectiveCourse> courses;
  String totalEarned;
  String totalOngoing;

  double earnedNumber() => double.tryParse(totalEarned) ?? 0;

  double ongoingNumber() => double.tryParse(totalOngoing) ?? 0;

  /// 按「大类 → 具体课程」归并。
  ///
  /// 两条刻意的规则：
  ///   1. 汇总表里的大类**全都保留**（即使本学期没有课）—— 修读要求挂在
  ///      大类上，藏起来学生就看不到还差多少学分；
  ///   2. 课程明细里出现、汇总表却没有的大类（学校数据不同步时会发生）
  ///      也追加进来，避免课程凭空消失。
  ///
  /// 两边都保持学校给出的原始顺序，不重排。
  List<ElectiveGroup> grouped() {
    final List<ElectiveGroup> out = <ElectiveGroup>[];
    final Map<String, ElectiveGroup> byName = <String, ElectiveGroup>{};
    for (final ElectiveCategory c in categories) {
      if (byName.containsKey(c.name)) {
        continue; // 汇总表出现重名时只认第一条，不重复建组
      }
      final ElectiveGroup g = ElectiveGroup(c.name)..info = c;
      byName[c.name] = g;
      out.add(g);
    }
    for (final ElectiveCourse c in courses) {
      final String key = c.category.isEmpty ? '未标注类别' : c.category;
      ElectiveGroup? g = byName[key];
      if (g == null) {
        g = ElectiveGroup(key);
        byName[key] = g;
        out.add(g);
      }
      g.courses.add(c);
    }
    return out;
  }
}

/// 培养方案分组 × 修读情况分组，按「课程体系」对齐后的一个区块。
///
/// 两边不一定齐全（实测可能只在一侧出现），因此两个字段都可空：
///   · [plan] 为空 → 这个体系只在修读情况里出现；
///   · [elective] 为空 → 这个体系只在培养方案里出现。
/// 两种都照常渲染（各自只有半边内容），不因为对不上就把谁丢掉。
class MergedPlanGroup {
  MergedPlanGroup(this.name, {this.plan, this.elective, this.planNote = ''});

  /// 归一后的体系名：卡片标题，也是展开状态与明细加载的键（见 [systemMergeKey]）
  final String name;

  /// 培养方案侧的分组（含该体系的课程与学分合计）
  final PlanGroup? plan;

  /// 修读情况侧的分组（含应修/已修/在修与按需加载的课程明细）
  final ElectiveGroup? elective;

  /// 培养方案「课程体系」格里附带的注记，如 `(应修 10 / 已修 6.5)`。
  ///
  /// 学校把它和体系名挤在同一格（用 `<br>` 分行），过去界面是连名字带注记
  /// 一起当标题显示。归一后名字单独作标题，这截注记必须继续显示 ——
  /// 它带着培养方案侧的应修/已修数字，在修读情况缺失时是用户唯一能看到的进度。
  /// 空串表示没有注记。
  final String planNote;
}

/// 「课程体系」列的配对/查询用键。
///
/// ===== 为什么不能直接按原样比对 =====
/// 两页的这一列都带装饰（实测语料）：
///   · 培养方案：单元格里是 `素质拓展必修课` + `<br>` + `(应修 10 / 已修 6.5)`，
///     解析出的 system 因此是两行；
///   · 修读情况：列名就写作「课程体系(属性)」，值形如 `素质拓展必修课(必修)`。
/// 去掉这层确定格式的装饰后，两边就是同一组体系名。这不是模糊匹配：
/// 归一后的名字仍按精确相等配对（见 [mergePlanAndElective]）。
///
/// 该页自己的「详情」链接用的也是裸名（`toShowxq('学科基础必修课')`），
/// 因此抓课程明细时同样用它作 kctxmc 参数。
String systemMergeKey(String name) {
  // 只取第一行：培养方案侧的注记从第二行开始
  final String first = name.split('\n').first.trim();
  // 剥掉尾部那一截括号注记（半角/全角都认）；整串都是括号内容时保留原样
  final RegExpMatch? m =
      RegExp(r'^(.*?)[（(][^（()）]*[)）]$').firstMatch(first);
  final String base = m?.group(1)?.trim() ?? '';
  return base.isEmpty ? first : base;
}

/// 取培养方案「课程体系」格中名字之外的那截注记（无则空串）。
///
/// 见 [MergedPlanGroup.planNote] 的说明：名字归一后，注记要单独展示。
String planNoteOf(String system) {
  final String raw = system.trim();
  final String key = systemMergeKey(raw);
  final int at = raw.indexOf(key);
  if (at < 0) {
    return '';
  }
  // 注记里可能有多余换行/空格（服务端源码缩进），压成一行再显示
  return raw.substring(at + key.length).replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 把培养方案分组与修读情况分组按体系名对齐。
///
/// ===== 三条刻意的规则 =====
///   1. 顺序以**培养方案**为准（本页是培养方案页）：方案里有几个体系就先排
///      几个，名字相同的修读分组挂进对应卡片；
///   2. 修读情况里多出来的体系（两边数据不同步时确实会发生）追加在后面，
///      不丢 —— 否则那些体系的已修/在修与修读记录会凭空消失；
///   3. 同一个归一名的分组只配**第一个**，其余不吞不并（宁可多出一张
///      半边内容的卡片，也不静默丢掉一条数据）。两边各自的重名都会走到这条。
List<MergedPlanGroup> mergePlanAndElective(
  List<PlanGroup> planGroups,
  List<ElectiveGroup> electiveGroups,
) {
  final Map<String, ElectiveGroup> byKey = <String, ElectiveGroup>{};
  for (final ElectiveGroup g in electiveGroups) {
    byKey.putIfAbsent(systemMergeKey(g.name), () => g);
  }
  final Set<ElectiveGroup> used = <ElectiveGroup>{};
  final List<MergedPlanGroup> out = <MergedPlanGroup>[];
  for (final PlanGroup p in planGroups) {
    final String key = systemMergeKey(p.system);
    // 已被前面某个同名分组配走的修读分组不再重复挂载（规则 3）
    final ElectiveGroup? candidate = byKey[key];
    final ElectiveGroup? e = used.contains(candidate) ? null : candidate;
    if (e != null) {
      used.add(e);
    }
    out.add(MergedPlanGroup(
      key,
      plan: p,
      elective: e,
      planNote: planNoteOf(p.system),
    ));
  }
  for (final ElectiveGroup e in electiveGroups) {
    if (used.contains(e)) {
      continue;
    }
    out.add(MergedPlanGroup(systemMergeKey(e.name), elective: e));
  }
  return out;
}
