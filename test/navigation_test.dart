/// 导航结构的契约测试
///
/// 锁定两个决定：
///   1. 「空教室只有一个入口」：底部 dock / 宽屏侧栏都不列它，
///      但页面本身仍在（可从课表页顶栏进入），且顶栏标题必须正确。
///   2. 「培养与修读情况已合并」：dock 上仍是「培养」一格，但顶栏标题
///      用全称「培养方案」；旧的「修读情况」页与它的路由键都不存在了，
///      不会有任何入口再把人带到一张只有半个功能的页面上。
///
/// 为什么值得写测试：这两件事很容易在后续改动里悄悄退化 ——
/// 有人把空教室加回导航列表（入口又变重复），或忘了给页面配标题
/// （顶栏落到「hi建大」这个兜底文案上，看起来像进错了页面）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hijianzhu_jw/pages/shell.dart';

void main() {
  group('底部 dock / 侧栏的导航项', () {
    test('不含空教室（它只保留课表页顶栏一个入口）', () {
      expect(
        kNavItems.any((NavItem n) => n.key == 'classroom'),
        isFalse,
        reason: '空教室不该再出现在 dock/侧栏里，否则入口重复',
      );
    });

    test('包含四个主页面（修读情况不再是独立页面）', () {
      final List<String> keys =
          kNavItems.map((NavItem n) => n.key).toList();
      // 「修读情况」已并入培养方案页（按课程体系对齐展示），
      // 因此既没有 'elective' 导航项，也没有它的路由键。
      expect(keys, <String>['schedule', 'score', 'plan', 'profile']);
      expect(keys.contains('elective'), isFalse);
    });

    test('key 唯一（重复会让选中态错位）', () {
      final Set<String> seen = <String>{};
      for (final NavItem n in kNavItems) {
        expect(seen.add(n.key), isTrue, reason: '重复的 key: ${n.key}');
      }
    });
  });

  group('不在导航项里、但有独立标题的页面', () {
    test('空教室与设置都有标题', () {
      expect(kExtraPageTitles['classroom'], '空教室');
      expect(kExtraPageTitles['settings'], '设置');
    });

    test('这些页面确实不在导航项里（否则标题会重复两处维护）', () {
      for (final String key in kExtraPageTitles.keys) {
        expect(
          kNavItems.any((NavItem n) => n.key == key),
          isFalse,
          reason: '$key 同时出现在两处，标题来源会打架',
        );
      }
    });
  });

  group('顶栏标题推导', () {
    test('培养页顶栏用全称「培养方案」（dock 上仍是两字「培养」）', () {
      // 合并后的这一页同时承载培养方案与各体系修读情况，两字标签说不清；
      // dock 受宽度限制才用「培养」，顶栏没有这个限制。
      expect(pageTitleOf('plan'), '培养方案');
      expect(kNavItems.firstWhere((NavItem n) => n.key == 'plan').label, '培养');
    });

    test('其余页面：导航项取标签、额外页面取标题表', () {
      expect(pageTitleOf('schedule'), '课表');
      expect(pageTitleOf('score'), '成绩');
      expect(pageTitleOf('profile'), '我的');
      expect(pageTitleOf('classroom'), '空教室');
      expect(pageTitleOf('settings'), '设置');
    });

    test('未知 key 落到兜底文案（不能是空白）', () {
      expect(pageTitleOf('nope'), 'hi建大');
      // 已删除的修读情况路由也不再有专属标题
      expect(pageTitleOf('elective'), 'hi建大');
    });
  });
}
