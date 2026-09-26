/// 修读情况解析（课程体系 → 要求学分 / 已修 / 在修）
///
/// ===== 本校与参考实现的页面结构不同，这里两种都支持 =====
///
/// 参考实现（两表）：
///   - 类别表：表头含「要求学分」，列 = 名称 / 要求 / 已修 / 在修
///   - 课程表：表头含「通选课类别」，列 = 编号 / 名称 / 学分 / 成绩 / 类别
///
/// 本校（单表，`/xxwcqk/xxwcqkOnkctxBy.do`「学习完成情况查看」）：
///   - 只有一张表，表头是
///     `课程体系(属性) | 毕业要求学分 | 已修学分 | 正修读学分 | 毕业还需学分 | 详情`
///   - **没有课程明细**（每行的「详情」是另一个页面，本应用不去抓）
///
/// 因此这里**不写死列号**，而是先找到表头行、按表头文字定位各列。
/// 写死列号的代价很高：两校列数不同（参考实现 4 列、本校 5 列），
/// 而且列顺序也可能变，一处错位就会把「已修学分」显示成「毕业还需学分」——
/// 数字看着正常，结论完全相反。
///
/// ===== 必须保留的产品行为 =====
/// 参考实现那边学校**确实留空了「要求学分」**，界面不能判成「未达标」，
/// 而要显示「学校未设置要求」。本校这一列是有值的，但那条逻辑仍然保留 ——
/// 只要读到空值就走「未设置」分支，不假设哪所学校有值。
library;

import '../model/models.dart';
import 'html_lite.dart';

/// 表头里可能出现的列名（各校写法不同，按顺序尝试）
const List<String> _kNameHeaders = <String>['课程体系', '类别', '课程类别'];
const List<String> _kRequiredHeaders = <String>['毕业要求学分', '要求学分'];
const List<String> _kEarnedHeaders = <String>['已修学分', '已修'];
const List<String> _kOngoingHeaders = <String>['正修读学分', '在修学分', '在修'];

class ElectiveParser {
  static ElectiveReport parse(String html) {
    final ElectiveReport r = ElectiveReport();

    // 类别表：表头里出现「要求学分」的那张（两校都是这个特征）
    final HtmlTable? cat = HtmlLite.findTableByHeader(html, '要求学分');
    if (cat != null) {
      _readCategories(cat, r);
    }

    // 课程明细表：只有参考实现那边有；本校没有，取不到就跳过
    final HtmlTable? course = HtmlLite.findTableByHeader(html, '通选课类别');
    if (course != null) {
      _readCourses(course, r);
    }
    return r;
  }

  /// 在表头行里找出某个列名对应的列号；找不到返回 -1
  static int _findColumn(List<HtmlCell> header, List<String> names) {
    for (final String want in names) {
      for (int i = 0; i < header.length; i++) {
        if (header[i].text.contains(want)) {
          return i;
        }
      }
    }
    return -1;
  }

  /// 这张表的表头行是第几行？（含「要求学分」的那行）
  static int _headerRowOf(HtmlTable table, String keyword) {
    final int limit = table.rows.length < 4 ? table.rows.length : 4;
    for (int i = 0; i < limit; i++) {
      if (table.rows[i].text.contains(keyword)) {
        return i;
      }
    }
    return -1;
  }

  static void _readCategories(HtmlTable table, ElectiveReport r) {
    final int headerRow = _headerRowOf(table, '要求学分');
    if (headerRow < 0) {
      return;
    }
    final List<HtmlCell> header = table.rows[headerRow].cells;

    // 按表头文字定位列，而不是写死列号（见文件头说明）
    final int colName = _findColumn(header, _kNameHeaders);
    final int colReq = _findColumn(header, _kRequiredHeaders);
    final int colEarned = _findColumn(header, _kEarnedHeaders);
    final int colOngoing = _findColumn(header, _kOngoingHeaders);
    if (colName < 0 || colEarned < 0) {
      return;
    }

    for (int i = headerRow + 1; i < table.rows.length; i++) {
      final List<HtmlCell> cells = table.rows[i].cells;
      if (cells.length <= colName) {
        continue;
      }
      String at(int n) => (n >= 0 && n < cells.length) ? cells[n].text.trim() : '';
      final String name = at(colName);
      if (name.isEmpty) {
        continue;
      }
      // 「合计 / 总学分」这类汇总行单独取，不算一个类别
      if (name.contains('总学分') || name == '合计') {
        r.totalEarned = at(colEarned);
        r.totalOngoing = at(colOngoing);
        continue;
      }
      r.categories.add(ElectiveCategory(
        name: name,
        required: at(colReq),
        earned: at(colEarned),
        ongoing: at(colOngoing),
      ));
    }
  }

  static void _readCourses(HtmlTable table, ElectiveReport r) {
    final int headerRow = _headerRowOf(table, '通选课类别');
    if (headerRow < 0) {
      return;
    }
    for (int i = headerRow + 1; i < table.rows.length; i++) {
      final List<HtmlCell> cells = table.rows[i].cells;
      if (cells.length < 5) {
        continue;
      }
      String at(int n) => n < cells.length ? cells[n].text.trim() : '';
      final String name = at(1);
      if (name.isEmpty || name == '课程名称') {
        continue;
      }
      r.courses.add(ElectiveCourse(
        courseCode: at(0),
        courseName: name,
        credit: at(2),
        score: at(3),
        category: at(4),
      ));
    }
  }
}
