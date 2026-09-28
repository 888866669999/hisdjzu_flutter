/// 通选课修读情况的解析、归并，以及与培养方案的合并（按课程体系）
///
/// 语料是真实抓取的页面（`test/fixtures/elective.html` 与 `plan.html`）。
///
/// 覆盖的是这次改版最容易被改错的三件事：
///   1. 两个来源按**归一后的体系名**精确配对 —— 配对不能靠模糊包含，
///      但两边的原始数据都带装饰（方案侧 `(应修 10 / 已修 6.5)` 的注记、
///      修读侧 `(必修)` 的性质后缀），所以归一化本身要单独钉住；
///   2. 一边有一边没有时两边都不能丢（合并页的硬要求）；
///   3. 学校留空「要求学分」时**不能画进度条**，也不能判成未达标。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hijianzhu_jw/model/models.dart';
import 'package:hijianzhu_jw/parser/elective_parser.dart';
import 'package:hijianzhu_jw/parser/plan_parser.dart';

String _html() => File('test/fixtures/elective.html').readAsStringSync();

String _planHtml() => File('test/fixtures/plan.html').readAsStringSync();

void main() {
  group('解析真实页面', () {
    test('课程体系与要求/已修/在修学分都能解析出来', () {
      final ElectiveReport r = ElectiveParser.parse(_html());
      expect(r.categories.length, greaterThan(5));
      // 本校页面是单表结构（「学习完成情况查看」），**没有课程明细子表**
      // —— 每行的「详情」是另一个页面（展开分组时才去抓）。因此这里不要求 courses。
      //
      // 11 个课程体系 + 一行汇总（写作「总计」）。汇总行**不算类别** ——
      // 早先只认「总学分 / 合计」，于是它不仅没被识别成汇总
      // （顶部「已修学分」显示 0，而表里明明写着 159.0），
      // 还冒充了第 12 个类别、渲染成一张可以「设置要求学分」的卡片。
      expect(r.categories.length, 11, reason: '本校页面里有 11 个课程体系');
      expect(r.categories.map((ElectiveCategory c) => c.name),
          isNot(contains('总计')),
          reason: '「总计」是汇总行，不是课程类别');
      // 要求学分与已修学分都必须读到（列名与参考实现不同，靠表头定位）
      final ElectiveCategory first = r.categories.first;
      expect(first.name, contains('学科基础必修课'));
      expect(first.required, '38');
      expect(first.earned, '14.0');
      expect(first.ongoing, '9.5');
      // 总学分行不能被当成一个类别
      expect(r.categories.map((ElectiveCategory c) => c.name),
          isNot(contains('总学分')));
    });
  });

  group('大类归并（修读情况内部）', () {
    test('汇总表里的大类全部保留，课程挂到对应大类下', () {
      final ElectiveReport r = ElectiveParser.parse(_html());
      final List<ElectiveGroup> g = r.grouped();

      // 每个汇总类别都在（即使本学期没有课）
      for (final ElectiveCategory c in r.categories) {
        expect(g.map((ElectiveGroup x) => x.name), contains(c.name),
            reason: '${c.name} 是有修读要求的大类，不能被隐藏');
      }

      // 每门课程都恰好落在自己的大类下
      for (final ElectiveCourse c in r.courses) {
        final String key = c.category.isEmpty ? '未标注类别' : c.category;
        final ElectiveGroup? group =
            g.where((ElectiveGroup x) => x.name == key).firstOrNull;
        expect(group, isNotNull, reason: '${c.courseName} 的类别 $key 应有对应分组');
        expect(group!.courses.contains(c), isTrue);
      }

      // 不丢课：分组内课程总数 == 原课程数
      final int total =
          g.fold<int>(0, (int s, ElectiveGroup x) => s + x.courses.length);
      expect(total, r.courses.length);
    });

    test('课程明细里出现、汇总表没有的大类会被追加（课程不能凭空消失）', () {
      final ElectiveReport r = ElectiveReport(
        categories: <ElectiveCategory>[
          ElectiveCategory(name: '人文艺术类', required: '4', earned: '4'),
        ],
        courses: <ElectiveCourse>[
          ElectiveCourse(
              courseName: '旅游文化学', category: '人文艺术类', credit: '2'),
          ElectiveCourse(
              courseName: '某新增课程', category: '新增大类', credit: '2'),
        ],
      );
      final List<ElectiveGroup> g = r.grouped();
      expect(g.length, 2);
      expect(g[1].name, '新增大类');
      expect(g[1].info, isNull);
      expect(g[1].courses.length, 1);
    });

    test('课程类别为空时归入「未标注类别」，不会丢掉', () {
      final ElectiveReport r = ElectiveReport(
        courses: <ElectiveCourse>[
          ElectiveCourse(courseName: '无类别课程', category: ''),
        ],
      );
      final List<ElectiveGroup> g = r.grouped();
      expect(g.length, 1);
      expect(g.first.name, '未标注类别');
      expect(g.first.courses.length, 1);
    });

    test('汇总表重名时只建一组，不重复', () {
      final ElectiveReport r = ElectiveReport(
        categories: <ElectiveCategory>[
          ElectiveCategory(name: '体育保健类', required: '', earned: '1'),
          ElectiveCategory(name: '体育保健类', required: '', earned: '1'),
        ],
      );
      expect(r.grouped().length, 1);
    });

    test('空报表不产生任何分组', () {
      expect(ElectiveReport().grouped(), isEmpty);
    });
  });

  group('与培养方案合并（按课程体系）', () {
    test('归一化：剥掉方案侧的注记与修读侧的性质后缀', () {
      // 修读情况侧：列名就写作「课程体系(属性)」，值形如 `学科基础必修课(必修)`
      expect(systemMergeKey('学科基础必修课(必修)'), '学科基础必修课');
      expect(systemMergeKey('专业实践课(实践)'), '专业实践课');
      // 方案侧：同一格里体系名与 `(应修 10 / 已修 6.5)` 用换行隔开
      expect(systemMergeKey('素质拓展必修课\n(应修 10 / 已修 6.5)'), '素质拓展必修课');
      // 全角括号也要认
      expect(systemMergeKey('公共必修课（必修）'), '公共必修课');
      // 没有装饰的名字原样返回
      expect(systemMergeKey('未标注类别'), '未标注类别');
      expect(systemMergeKey(' 体育保健类 '), '体育保健类');
      // 括号里就是全部内容时不能剥成空串
      expect(systemMergeKey('(待定)'), '(待定)');
    });

    test('注记单独取出：名字归一后那截应修/已修数字不能丢', () {
      expect(planNoteOf('素质拓展必修课\n(应修 10 / 已修  6.5)'), '(应修 10 / 已修 6.5)');
      expect(planNoteOf('公共必修课'), '');
    });

    test('真实语料：两个来源按体系名对齐，课程与进度合并到一张卡片', () {
      final PlanDetail plan = PlanParser.parse(_planHtml());
      final List<ElectiveGroup> elective =
          ElectiveParser.parse(_html()).grouped();
      final List<MergedPlanGroup> merged =
          mergePlanAndElective(plan.groups, elective);

      // 语料里培养方案只有 2 个体系（截取过的真实片段），两个都配上了
      final MergedPlanGroup sz = merged
          .firstWhere((MergedPlanGroup g) => g.name == '素质拓展必修课');
      expect(sz.plan, isNotNull);
      expect(sz.plan!.courses.length, 13);
      expect(sz.elective, isNotNull);
      expect(sz.elective!.requiredNumber, 10, reason: '修读侧的应修学分要能读到');
      expect(sz.planNote, '(应修 10 / 已修 6.5)', reason: '方案格里的注记要保留');

      // 关键：11 个体系一个不丢 —— 2 个配上的 + 9 个只有修读情况的追加
      expect(merged.length, 11);
      for (final ElectiveGroup g in elective) {
        expect(merged.any((MergedPlanGroup m) => m.elective == g), isTrue,
            reason: '${g.name} 在合并结果里消失了');
      }
      // 培养方案侧也不丢
      for (final PlanGroup g in plan.groups) {
        expect(merged.any((MergedPlanGroup m) => m.plan == g), isTrue,
            reason: '${g.system} 在合并结果里消失了');
      }
    });

    test('一边有一边没有：都要渲染，不能被丢掉', () {
      final List<MergedPlanGroup> merged = mergePlanAndElective(
        <PlanGroup>[
          PlanGroup('只在方案的体系', <PlanCourse>[PlanCourse(courseName: '课A')], 3),
        ],
        <ElectiveGroup>[
          ElectiveGroup('只在修读的体系')
            ..info = ElectiveCategory(
                name: '只在修读的体系', required: '4', earned: '2'),
        ],
      );
      expect(merged.length, 2);
      // 顺序以培养方案为准，修读侧多出的追加在后
      expect(merged[0].name, '只在方案的体系');
      expect(merged[0].plan, isNotNull);
      expect(merged[0].elective, isNull);
      expect(merged[1].name, '只在修读的体系');
      expect(merged[1].plan, isNull);
      expect(merged[1].elective, isNotNull);
    });

    test('两边都空时不产生分组（页面显示空态）', () {
      expect(mergePlanAndElective(<PlanGroup>[], <ElectiveGroup>[]), isEmpty);
    });

    test('重复名字只配第一个，多出来的不吞掉（追加在后）', () {
      final ElectiveGroup a = ElectiveGroup('某体系(必修)');
      final ElectiveGroup b = ElectiveGroup('某体系(限选)');
      final List<MergedPlanGroup> merged = mergePlanAndElective(
        <PlanGroup>[PlanGroup('某体系', null, 0)],
        <ElectiveGroup>[a, b],
      );
      expect(merged.length, 2);
      expect(merged[0].elective, same(a));
      expect(merged[1].elective, same(b));
    });

    test('方案侧重名时同一修读分组不重复挂载（第二个只有方案半边）', () {
      final ElectiveGroup e = ElectiveGroup('某体系(必修)');
      final List<MergedPlanGroup> merged = mergePlanAndElective(
        <PlanGroup>[
          PlanGroup('某体系', null, 0),
          PlanGroup('某体系 ', null, 0),
        ],
        <ElectiveGroup>[e],
      );
      expect(merged.length, 2);
      expect(merged[0].elective, same(e));
      expect(merged[1].elective, isNull,
          reason: '同一份进度在一张卡上显示两次会让人以为有两套要求');
    });
  });

  group('进度条与达标判定', () {
    test('学校留空要求学分时：不画进度条，也不算未达标', () {
      final ElectiveReport r = ElectiveParser.parse(_html());
      // 真实页面里要求学分全为空
      for (final ElectiveGroup g in r.grouped()) {
        if (g.info != null && g.info!.required.isEmpty) {
          expect(g.canShowProgress, isFalse,
              reason: '${g.name} 没有分母，画进度条长度没有意义');
        }
      }
    });

    test('有要求学分且能解析成数字才画进度条', () {
      final ElectiveGroup ok = ElectiveGroup('人文艺术类')
        ..info = ElectiveCategory(name: '人文艺术类', required: '4', earned: '4');
      expect(ok.canShowProgress, isTrue);
      expect(ok.requiredNumber, 4);
      expect(ok.earnedNumber, 4);

      final ElectiveGroup blank = ElectiveGroup('财经特色类')
        ..info = ElectiveCategory(name: '财经特色类', required: '');
      expect(blank.canShowProgress, isFalse);

      final ElectiveGroup zero = ElectiveGroup('零要求')
        ..info = ElectiveCategory(name: '零要求', required: '0');
      expect(zero.canShowProgress, isFalse, reason: '分母为 0 会算出 NaN/Inf');

      final ElectiveGroup noInfo = ElectiveGroup('没有汇总信息');
      expect(noInfo.canShowProgress, isFalse);
    });
  });
}
