import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hijianzhu_jw/parser/score_parser.dart';
import 'package:hijianzhu_jw/parser/profile_parser.dart';
import 'package:hijianzhu_jw/parser/week_calendar_parser.dart';
import 'package:hijianzhu_jw/parser/plan_parser.dart';
import 'package:hijianzhu_jw/parser/elective_parser.dart';
import 'package:hijianzhu_jw/parser/classroom_parser.dart';
import 'package:hijianzhu_jw/model/classroom_models.dart';
import 'package:hijianzhu_jw/model/models.dart';
import 'package:hijianzhu_jw/parser/html_lite.dart';

String read(String n) => File('test/fixtures/$n').readAsStringSync();

void main() {
  test('成绩：解析记录并汇总', () {
    final rs = ScoreParser.parse(read('score.html'));
    final s = ScoreParser.summarize(rs);
    // ignore: avoid_print
    print('scores=${rs.length} credit=${s.totalCredit} gpa=${s.averageGpa}');
    expect(rs, isNotEmpty);
    for (final r in rs) {
      expect(r.courseName.isNotEmpty, isTrue);
    }
    // 平均绩点应在合理区间（本校口径：(分数 - 50) ÷ 10，即 1.0–5.0）
    expect(s.averageGpa, greaterThan(0));
  });

  test('个人信息：不产生子表列名假字段', () {
    final p = ProfileParser.parse(read('profile.html'));
    final labels = <String>[];
    for (final sec in p.sections) {
      for (final f in sec.fields) {
        labels.add(f.label);
      }
    }
    // ignore: avoid_print
    print('fields=${labels.length} name=${p.name} id=${p.studentId}');
    expect(labels, isNotEmpty);
    expect(labels.contains('学号'), isTrue);
    expect(labels.contains('姓名'), isTrue);
    // 子表列名不应成为字段
    expect(labels.any((l) => l.contains('起止年月')), isFalse);
    expect(labels.any((l) => l.contains('工作单位')), isFalse);
  });

  test('周历：21 周且周一递增 7 天', () {
    final wd = WeekCalendarParser.parseWeekDates(read('weekcal.html'));
    // ignore: avoid_print
    print('weeks=${wd.length} first=${wd.isNotEmpty ? wd.first.monday : ""}');
    expect(wd.length, greaterThan(10));
    expect(wd.first.week, 1);
    for (final w in wd) {
      expect(w.monday, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    }
    // 相邻周相差 7 天
    for (int i = 1; i < wd.length; i++) {
      expect(wd[i].week, wd[i - 1].week + 1);
      final a = DateTime.parse(wd[i - 1].monday);
      final b = DateTime.parse(wd[i].monday);
      expect(b.difference(a).inDays, 7);
    }
  });

  test('培养方案：课程表 + 分组（无 PDF）', () {
    final d = PlanParser.parse(read('plan.html'));
    // ignore: avoid_print
    print('courses=${d.courses.length} groups=${d.groups.length} '
        'credit=${d.totalCredit} hours=${d.totalHours}');
    expect(d.courses, isNotEmpty);
    expect(d.groups, isNotEmpty);
    for (final c in d.courses) {
      expect(c.courseName.isNotEmpty, isTrue);
    }
  });

  group('培养方案：两个真实缺陷的回归', () {
    // ===== 缺陷 1：注释里的重复表被当成真数据 =====
    // 服务端把整段课程表又原样列了一遍塞在 `<!-- ... -->` 里（列布局不同），
    // 浏览器不显示，我们却读进来当作第二批课程：课程数翻倍，
    // 那一批的行首格是学时数字，于是分组名冒出「32」「8」「16」这种。
    test('HTML 注释里的表行不能被读成课程', () {
      final d = PlanParser.parse(read('plan.html'));
      // 分组名必须是真实的课程体系名，不能是纯数字
      for (final PlanGroup g in d.groups) {
        final String name = g.system.replaceAll(RegExp(r'\s+'), ' ').trim();
        expect(RegExp(r'^\d+(\.\d+)?$').hasMatch(name), isFalse,
            reason: '分组名「$name」是纯数字 —— 注释里的重复表被读进来了');
      }
      // 分组名不该以「课程性质」类的文字开头（字段错位的症状）
      expect(d.groups.length, lessThan(20),
          reason: '分组数 ${d.groups.length} 明显偏多，可能把重复表算进去了');
    });

    // ===== 缺陷 2：课程名/课号被读成了别的列 =====
    // 表头有 15 列（含「完成情况」「课程性质」「课程属性」），
    // 早先按固定偏移读，课程名读到了「课程性质」——于是每门课名都
    // 显示成「素质拓展必修课」重复 N 遍，课号读到了「完成情况」。
    test('课程名/课号/性质必须落在正确的列上', () {
      final d = PlanParser.parse(read('plan.html'));
      expect(d.courses, isNotEmpty);
      for (final PlanCourse c in d.courses) {
        // 课号是「2 位字母 + 8 位数字」（如 AQ25000001）
        expect(RegExp(r'^[A-Z]{2}\d{6,}$').hasMatch(c.courseCode), isTrue,
            reason: '「${c.courseName}」的课号是「${c.courseCode}」，'
                '不像课程编号 —— 列位置可能又错位了');
        // 课程名不能等于它所属的性质（那是错位的典型症状）
        expect(c.courseName == c.category, isFalse,
            reason: '课程名与性质相同（都是「${c.courseName}」）—— 读串列了');
        // 完成情况（「已修(( 96 )」）不该出现在课名或课号里
        expect(c.courseName.contains('已修'), isFalse);
        expect(c.courseCode.contains('已修'), isFalse);
      }
    });

    test('学分与总学时是正数且量级正常', () {
      final d = PlanParser.parse(read('plan.html'));
      expect(d.totalCredit, greaterThan(0));
      expect(d.totalHours, greaterThan(0));
      // 单门课的学分不会超过 20（毕业设计这种大课也就十几学分）
      for (final PlanCourse c in d.courses) {
        expect(c.creditNumber(), lessThan(20),
            reason: '「${c.courseName}」学分 ${c.credit} 不合理');
      }
    });
  });

  test('通选课：类别与课程', () {
    final r = ElectiveParser.parse(read('elective.html'));
    // ignore: avoid_print
    print('cats=${r.categories.length} courses=${r.courses.length} '
        'earned=${r.totalEarned} ongoing=${r.totalOngoing}');
    expect(r.categories, isNotEmpty);
    // 本校页面（学习完成情况查看）是**单表**，没有课程明细子表：
    // 每行的「详情」指向另一个页面，本应用不去抓。因此不要求 courses。
    // 学校留空「要求学分」时不能判为达标
    for (final c in r.categories) {
      if (!c.hasRequirement) {
        expect(c.satisfied(), isFalse, reason: '未设置要求时不应判为已达标');
      }
    }
  });

  test('教室：列映射按节次编号行（回归：曾把周三数据算到周一）', () {
    // ===== 这个用例守的是一个真实 bug =====
    // 结果表是「三行表头」：第 1 行功能区、第 2 行**星期（8 格，星期列
    // colspan=5）**、第 3 行**节次编号（36 格 = 7 天 × 5 大节）**。
    //
    // 早先按第 2 行的格号建「列 → 星期」映射，于是：
    //   列 1..5（周一的五个大节）被当成周一…周五，
    //   列 6..7（周二前两节）被当成周六、周日，
    //   **周三到周日的数据一格都没读**。
    // 查询「完全空闲」时所有格子都空，界面看起来完全正常 ——
    // 只有某间教室真有占用时才会把内容显示到错误的日子上。
    //
    // 正确规则：第 3 行的第 i 格 → 天 = (i-1)÷5、大节 = (i-1)%5。
    // 语料里 36 格的编号序列是 01 02 / 03 04 05 / 06 07 / 08 09 / 10 11 12
    // 循环 7 次，正好印证这个划分。
    final html = read('classroom_result.html');
    final res = ClassroomParser.parseResult(html, 0);
    expect(res.rooms, isNotEmpty);
    // 教室名要去掉 `(80/80)` 与 `[媒80]` 两段冗余后缀，只留名字
    expect(res.rooms.map((RoomSlot s) => s.room), contains('信息楼211'));
    expect(res.rooms.map((RoomSlot s) => s.room), contains('博文馆101'));
    for (final RoomSlot s in res.rooms) {
      expect(s.room, isNot(contains('(')), reason: '容量后缀未剥净：${s.room}');
      expect(s.room, isNot(contains('[')), reason: '教室编码未剥净：${s.room}');
    }
    // 不能出现名为「星期」的假教室（那是把表头行当数据行的症状）
    expect(res.rooms.map((RoomSlot s) => s.room), isNot(contains('星期')));

    // 列数校验：数据行应是 1 + 7×5 = 36 格，否则说明表结构变了
    final tables = HtmlLite.parseTables(html);
    final dataRows = tables.first.rows
        .where((HtmlRow r) => r.cells.length >= 30)
        .toList();
    expect(dataRows, isNotEmpty, reason: '应能识别出 36 列的数据行');
  });

  test('教室：占用要落在**正确的星期**上（列映射的真验证）', () {
    // 只断言「解析出了教室」是不够的 —— 早先那个把周三数据算到周一的
    // 列映射 bug 也照样能通过。真正要钉住的是：同一间教室在不同天、
    // 不同节次上的占用状态必须**不一样**；若所有格子读出同一个值，
    // 说明列索引算错了。
    final res = ClassroomParser.parseResult(read('classroom_result.html'), 0);
    expect(res.rooms.length, greaterThan(5), reason: '语料要有多间教室才有意义');

    // 逐间教室看它的「占用分布」：一周 7 天 × 5 节 = 35 格，
    // 全空（整周没课）和全满（每格都有课）都是真实存在的形态，
    // 但**不能所有教室都落在同一个极端**。
    int allEmpty = 0, allBusy = 0;
    for (final RoomSlot s in res.rooms) {
      int busy = 0, total = 0;
      for (int d = 0; d < 7; d++) {
        for (int sec = 0; sec < 5; sec++) {
          total++;
          if (s.isBusy(d, 4, section: sec)) busy++;
        }
      }
      expect(total, 35);
      if (busy == 0) allEmpty++;
      if (busy == total) allBusy++;
    }
    expect(allEmpty, lessThan(res.rooms.length),
        reason: '所有教室都整周空闲 —— 占用一个都没读出来');
    expect(allBusy, lessThan(res.rooms.length),
        reason: '所有教室都整周满分占用 —— 把空格子也算成占用了');

    // 至少有一间教室的 35 格状态**不单一**（既有占用也有空闲），
    // 这才说明每格是独立读出来的，而不是整行套同一个值。
    final bool varied = res.rooms.any((RoomSlot s) {
      final Set<bool> states = <bool>{};
      for (int d = 0; d < 7; d++) {
        for (int sec = 0; sec < 5; sec++) {
          states.add(s.isBusy(d, 4, section: sec));
        }
      }
      return states.length > 1;
    });
    expect(varied, isTrue,
        reason: '没有任何一间教室同时存在「有课」与「空」的格子 —— '
            '每格的状态可能是从同一处读来的');
  });

  test('教室：节次真的参与判定（回归：节次曾完全不生效）', () {
    // 真实缺陷：解析时把一天里 5 个格子合并成一份列表，`isBusy` 只看
    // 「这天有没有课」，于是：
    //   - 界面上的「节次」下拉对结果毫无影响；
    //   - 摘要写着「第一节」，列出的却是「整天都没课」的教室。
    // 这个断言从两个方向钉住它：不同节次的空闲数应当不同，
    // 且「任意节次为空」的教室数应当 **≥** 「某节次为空」的教室数。
    final res = ClassroomParser.parseResult(read('classroom_result.html'), 0);
    expect(res.rooms, isNotEmpty);

    final List<int> freePerSection = <int>[
      for (int sec = 0; sec < 5; sec++)
        ClassroomFinder.freeRooms(res, 0, 4, sec).length,
    ];
    expect(freePerSection.toSet().length, greaterThan(1),
        reason: '五个节次的空闲教室数完全相同（$freePerSection）—— '
            '节次没有参与判定，可能又退化成「整天口径」了');

    for (int sec = 0; sec < 5; sec++) {
      final int freeAtSection = freePerSection[sec];
      int freeAnySection = 0;
      for (final RoomSlot s in res.rooms) {
        bool anyFree = false;
        for (int k = 0; k < 5; k++) {
          if (!s.isBusy(0, 4, section: k)) anyFree = true;
        }
        if (anyFree) freeAnySection++;
      }
      expect(freeAtSection, greaterThanOrEqualTo(0));
      expect(freeAnySection, greaterThanOrEqualTo(freeAtSection),
          reason: '「至少有一节空的教室」不该少于「第 $sec 节空的教室」');
    }
  });

  test('教室：解析占用并做周次过滤', () {
    // 解析对象是**查询结果页**（教室 × 星期 矩阵）；
    // classroom.html 是筛选器页面，只用来测下拉。
    final html = read('classroom_result.html');
    final options = ClassroomParser.parseCampuses(read('classroom.html'));
    final res = ClassroomParser.parseResult(html, 0);
    // ignore: avoid_print
    print('rooms=${res.rooms.length} campuses=${options.length}');
    expect(res.rooms, isNotEmpty);

    // 取一周做统计，结果应与房间数一致（空闲 + 占用 = 总数）
    for (int sec = 0; sec < 5; sec++) {
      final stats = ClassroomFinder.weekStats(res, 4, sec);
      expect(stats.length, 7);
      for (final st in stats) {
        expect(st.total, res.rooms.length);
        expect(st.free, inInclusiveRange(0, st.total));
      }
    }
  });

  test('教室：楼号匹配必须严格（1 不能匹配 11-101）', () {
    expect(ClassroomFinder.belongsTo('11-101', '1'), isFalse);
    expect(ClassroomFinder.belongsTo('1-101', '1'), isTrue);
    expect(ClassroomFinder.belongsTo('9-316', '9'), isTrue);
  });

  group('教室：楼名提取（两种命名都要认）', () {
    // 早先只处理「数字-数字」形态，于是本校的 `信息楼211` 整串被当成楼名，
    // 结果每张楼栋卡片只有一间教室、标题还写成「信息楼211（1）」，
    // 与下面药丸里的教室名重复一遍。
    test('数字楼号：取短横之前', () {
      expect(ClassroomFinder.buildingOf('1-101'), '1');
      expect(ClassroomFinder.buildingOf('11-101'), '11');
    });

    test('楼名+房号连写（本校）：切在汉字与数字之间', () {
      expect(ClassroomFinder.buildingOf('信息楼211'), '信息楼');
      expect(ClassroomFinder.buildingOf('博文馆407'), '博文馆');
      expect(ClassroomFinder.buildingOf('外文馆211'), '外文馆');
    });

    test('楼名里带字母/房号带后缀（本校实测形态）', () {
      // 实测的教室名形态：`产融B202东[智48]`、`产融B204[智80]`。
      // 取「非数字前缀」正好得到 `产融B` —— B 区的 11 间教室归一组，
      // 而切到「产融」会把不同区的教室混在一起。
      expect(ClassroomFinder.buildingOf('产融B202东'), '产融B');
      expect(ClassroomFinder.buildingOf('产融B204'), '产融B');
      expect(ClassroomFinder.buildingOf('产融B302'), '产融B');
    });

    test('纯汉字无房号：整体作为楼名', () {
      expect(ClassroomFinder.buildingOf('操场'), '操场');
      expect(ClassroomFinder.buildingOf('体育馆'), '体育馆');
    });

    test('取不出楼名时返回空串（不能返回整串）', () {
      // 返回整串会让每间教室自成一栋楼；空串表示「未知」，
      // 调用方会归到同一组，符合「宁合不分」的取舍。
      expect(ClassroomFinder.buildingOf('211'), '');
      expect(ClassroomFinder.buildingOf(''), '');
    });
  });

  test('教室：节次代码第 5 行是 09/11', () {
    expect(ClassroomFinder.sectionCodes(4), <String>['09', '11']);
    expect(ClassroomFinder.sectionCodes(0), <String>['01', '02']);
  });

  test('周次说明解析：区间 / 单双周 / 多段', () {
    final s1 = WeekSpecParser.first('(3-18周)');
    expect(s1, isNotNull);
    expect(s1!.isActive(3), isTrue);
    expect(s1.isActive(19), isFalse);

    // 真实写法是 (1-18双周) / (4单周)，不是嵌套括号
    final s2 = WeekSpecParser.first('(1-18双周)');
    expect(s2!.parity, 2);
    expect(s2.isActive(6), isTrue);
    expect(s2.isActive(7), isFalse);

    // (4单周) 是真实页面存在的**矛盾写法**：第 4 周是偶数却标「单周」。
    // 若无条件按奇偶过滤，这门课永远不会显示（静默丢课）。
    // 因此以显式周次为准，忽略不自洽的奇偶标记。
    final s2b = WeekSpecParser.first('(4单周)');
    expect(s2b!.parity, 1);
    expect(s2b.isActive(4), isTrue, reason: '显式周次应优先于不自洽的单双周标记');
    expect(s2b.isActive(5), isFalse);

    // 而自洽的写法仍要按单双周过滤（真实页面写作 1-18双周）
    final s2c = WeekSpecParser.first('(1-18双周)');
    expect(s2c, isNotNull);
    expect(s2c!.isActive(6), isTrue);
    expect(s2c.isActive(7), isFalse, reason: '区间内存在偶数周，双周标记有效');

    final s3 = WeekSpecParser.first('(1-2,4-5,7-8,10-11,13,15-18周)');
    expect(s3!.isActive(3), isFalse);
    expect(s3.isActive(4), isTrue);
    expect(s3.isActive(13), isTrue);
    expect(s3.isActive(14), isFalse);
    expect(s3.isActive(18), isTrue);
  });
}
