/// 学校官方的作息数据
///
/// ===== 数据来源（本校与参考实现不同，务必注意）=====
/// 山东建筑大学的教务处官网**没有公开作息时刻表页**（只有校历 PDF），
/// 但**教务系统的课表页自己就带时刻** —— 每个节次行的行首格写作：
///   `第一大节 (01,02小节) 07:50-09:25`
/// 这是校内唯一的权威来源，因此：
///   1. 下面这份内置值是照它抄的（仅作冷启动/离线兜底）；
///   2. 正常路径是 [CampusCalendarService] 从课表页解析后覆盖它
///      —— 见 `parseSectionTimesFromTimetable`。
///
/// 为什么内置兜底也要有：作息决定「上课提醒」的触发时刻，
/// 首次安装、没网、还没打开过课表时，必须有个合理值可用。
///
/// ===== 这里只有作息，没有校历日期 =====
/// 校历日期（开学日、总周数）必须能随年份更新，由教务系统的**教学周历**
/// 实时提供 —— 见 [SemesterCalendarService]。任何硬编码的日期都会在换学年
/// 后静默变错，而界面上看不出来。
library;

/// 节次作息的权威默认值（照本校课表页的行首格抄录）
class OfficialSection {
  const OfficialSection(this.row, this.label, this.start, this.end);

  /// 课表中的行号（0 起）
  final int row;
  final String label;
  final String start;
  final String end;
}

/// 本校课表的 5 个大节（时刻取自课表页行首格）。
///
///   第一大节  01,02 小节      07:50-09:25
///   第二大节  03,04,05 小节   09:40-12:05
///   第三大节  06,07 小节      13:40-15:15
///   第四大节  08,09 小节      15:30-17:05
///   第五大节  10,11,12 小节   18:40-21:05
///
/// 与 `kSections`（本地可改的那份默认值）内容一致；这里保留一份，
/// 是为了让「官方值」这个概念在代码里是独立可引用的 —— 设置页里
/// 「恢复官方默认」要有明确的对象。
const List<OfficialSection> kOfficialSections = <OfficialSection>[
  OfficialSection(0, '第一大节', '07:50', '09:25'),
  OfficialSection(1, '第二大节', '09:40', '12:05'),
  OfficialSection(2, '第三大节', '13:40', '15:15'),
  OfficialSection(3, '第四大节', '15:30', '17:05'),
  OfficialSection(4, '第五大节', '18:40', '21:05'),
];

/// 课间休息。
/// 用 `followsRow` 指向「排在哪个节次之后」，而不是按名称匹配 ——
/// 节次名各校写法不同（本校是「第一大节」），按名称匹配容易漏。
class OfficialBreak {
  const OfficialBreak(this.followsRow, this.start, this.end);

  /// 排在第几行（0 起的课表行号）之后
  final int followsRow;
  final String start;
  final String end;
}

/// 课间休息（由相邻两节的「上一节止 → 下一节起」推出）
const List<OfficialBreak> kOfficialBreaks = <OfficialBreak>[
  OfficialBreak(0, '09:25', '09:40'),
  OfficialBreak(1, '12:05', '13:40'),
  OfficialBreak(2, '15:15', '15:30'),
  OfficialBreak(3, '17:05', '18:40'),
];

/// 官方作息数据访问。
///
/// **只负责作息时刻**。校历日期（开学日、周次）不在这里 ——
/// 那份数据必须能随年份更新，见 [SemesterCalendarService]。
class AcademicCalendar {
  /// 官方作息表的纯文本行，用于设置页与课表页展示。
  /// 课间休息插在对应节次之后（按行号匹配，见 [OfficialBreak] 的说明）。
  static List<String> sectionLines() {
    final List<String> out = <String>[];
    for (int i = 0; i < kOfficialSections.length; i++) {
      final OfficialSection s = kOfficialSections[i];
      out.add('${s.label}  ${s.start} - ${s.end}');
      for (final OfficialBreak b in kOfficialBreaks) {
        if (b.followsRow == i) {
          out.add('课间休息  ${b.start} - ${b.end}');
        }
      }
    }
    return out;
  }
}
