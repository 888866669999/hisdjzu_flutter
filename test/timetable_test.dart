import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hijianzhu_jw/model/models.dart';
import 'package:hijianzhu_jw/parser/timetable_parser.dart';

void main() {
  test('课表解析（真实页面）', () {
    final html = File('test/fixtures/timetable.html').readAsStringSync();
    final r = TimetableParser.parse(html, '2026-2027-1', '');
    final tt = r.timetable;

    // 统计
    int courses = 0;
    for (final c in tt.cells) {
      courses += c.entries.length;
    }
    print('rows(section) with data: ${tt.cells.length}');
    print('total course entries: $courses');
    print('remark: "${tt.remark}"');
    print('semesters: ${r.semesters}');
    print('weeks(count): ${r.weeks.length}');

    // 逐格打印，便于肉眼核对
    for (final c in tt.cells) {
      for (final e in c.entries) {
        print('  [row=${c.row} col=${c.col}] "${e.courseName}" '
            'teacher="${e.teacher}" room="${e.room}" campus="${e.campus}" '
            'week=${e.startWeek}-${e.endWeek} parity=${e.parity}');
      }
    }

    expect(courses, greaterThan(0), reason: '应解析出课程');
    for (final c in tt.cells) {
      expect(c.row, inInclusiveRange(0, 4));
      expect(c.col, inInclusiveRange(0, 6));
      for (final e in c.entries) {
        expect(e.courseName.isNotEmpty, isTrue, reason: '课程名不应为空');
      }
    }
  });

  group('学期自动回填（回归）', () {
    // 首次启动时本地没有任何学期记录，请求会传 semester=''。
    // 服务端返回它认为的当前学期（<option ... selected="selected">）。
    // 若解析器不回填这个值，tt.semester 就是空串，而 TimetableStore.save
    // 对空学期直接返回 false —— 表现为「每次启动都要联网，且断网/会话失效时
    // 明明取到过课表却没有任何缓存」，是个静默的功能性缺陷。
    test('请求未指定学期时，取服务端 selected 的学期', () {
      final String html = File('test/fixtures/timetable.html').readAsStringSync();
      final TimetableParseResult r = TimetableParser.parse(html, '', '');
      expect(r.timetable.semester, '2026-2027-1',
          reason: '必须回填服务端选中的学期，否则缓存无法落盘');
    });

    test('请求显式指定学期时，以请求值为准（不信任服务端 selected）', () {
      final String html = File('test/fixtures/timetable.html').readAsStringSync();
      final TimetableParseResult r =
          TimetableParser.parse(html, '2025-2026-2', '');
      expect(r.timetable.semester, '2025-2026-2',
          reason: '用户主动切学期时，请求的学期才是权威');
    });

    test('没有任何 option 时返回空串而不是抛异常', () {
      final TimetableParseResult r =
          TimetableParser.parse('<html><body>无课表</body></html>', '', '');
      expect(r.timetable.semester, '');
      expect(r.timetable.week, '');
    });
  });

  group('教室解析（回归：教室不能被课名覆盖）', () {
    // 真实缺陷：`碳中和与碳循环（能创25）` 的「教室」标签写着 `外文馆211[媒159]`，
    // 但兜底逻辑（`room.isEmpty || campus.isEmpty`）在解析出无校区的教室后
    // 仍会运行，把 `能创25` 用「楼名+房号」正则切成 `能创25` 写进 room ——
    // 课表上那门课显示的地点纯属虚构。
    Timetable tt() => TimetableParser.parse(
          File('test/fixtures/timetable.html').readAsStringSync(),
          '2026-2027-1',
          '',
        ).timetable;

    test('语义标签给出的教室不被兜底覆盖', () {
      CourseEntry? found;
      for (final CellData c in tt().cells) {
        for (final CourseEntry e in c.entries) {
          if (e.courseName.contains('碳中和')) found = e;
        }
      }
      expect(found, isNotNull, reason: '语料里应有这门课');
      expect(found!.room, isNot(contains('能创')),
          reason: '课名里的「能创25」绝不能被当成教室');
      expect(found.room, contains('外文馆'),
          reason: '服务端写在「教室」标签里的值才是权威');
    });

    test('方括号里的数字编码不当校区（校区应是纯汉字）', () {
      for (final CellData c in tt().cells) {
        for (final CourseEntry e in c.entries) {
          expect(e.campus, isNot(matches(RegExp(r'\d'))),
              reason: '「${e.courseName}」的 campus=「${e.campus}」含数字，'
                  '那是教室编码不是校区名');
        }
      }
    });

    test('教室文本里不残留方括号编码', () {
      for (final CellData c in tt().cells) {
        for (final CourseEntry e in c.entries) {
          expect(e.room, isNot(contains('[')),
              reason: '「${e.courseName}」的教室残留了方括号：${e.room}');
        }
      }
    });

    test('课名里带数字的课不会被误判（大学英语3 / 大学物理A2）', () {
      bool sawNumericCourse = false;
      for (final CellData c in tt().cells) {
        for (final CourseEntry e in c.entries) {
          if (RegExp(r'\d').hasMatch(e.courseName)) {
            sawNumericCourse = true;
            expect(e.room, isNot(e.courseName),
                reason: '「${e.courseName}」的教室等于课名');
          }
        }
      }
      expect(sawNumericCourse, isTrue, reason: '语料里应有带数字的课名');
    });
  });
}
