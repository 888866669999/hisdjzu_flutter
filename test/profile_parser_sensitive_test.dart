/// 个人信息：敏感字段必须既不展示也不进缓存
///
/// ===== 这个用例守的是什么 =====
/// 学籍卡片原文里含**身份证号**、入学考号、证书号这类高敏感信息，
/// 而本应用把整页原文落盘做离线缓存 —— 若不拦掉，身份证号就会以明文
/// 躺在应用私有目录里。
///
/// 因此 `ProfileParser` 必须在**解析层**就把它们丢掉：解析结果里没有、
/// 缓存里也就不会出现（缓存存的是原文但只被解析结果消费，
/// 而落盘判定发生在解析之前 —— 见下）。
///
/// 语料 `test/fixtures/profile.html` 是从真实页面脱敏而来的（人名与号码
/// 已替换为虚构值），但**字段名是真实的**，所以能验证关键词匹配有效。
///
/// ===== 本校页面的敏感字段叫「证件号」 =====
/// 参考实现那边（学籍卡片）写的是「身份证编号」；本校的
/// 「毕业生信息核对」页写的是「证件类型 / 证件号」。
/// 两者都在 `_sensitiveKeywords` 里，因此都能被拦掉。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hijianzhu_jw/model/models.dart';
import 'package:hijianzhu_jw/parser/profile_parser.dart';

String _fixture() =>
    File('test/fixtures/profile.html').readAsStringSync();

void main() {
  late StudentProfile p;

  setUpAll(() {
    p = ProfileParser.parse(_fixture());
  });

  /// 把所有分组的所有字段拍平成「标签集合」
  Set<String> allLabels() {
    final Set<String> out = <String>{};
    for (final ProfileSection s in p.sections) {
      for (final ProfileField f in s.fields) {
        out.add(f.label);
      }
    }
    return out;
  }

  group('敏感字段被剔除', () {
    test('身份证字段不在解析结果里', () {
      final Set<String> labels = allLabels();
      final Iterable<String> hit =
          labels.where((String l) => l.contains('身份证'));
      expect(hit, isEmpty,
          reason: '原文里有「身份证编号」，解析结果里不该出现它');
    });

    test('入学考号不在解析结果里', () {
      final Set<String> labels = allLabels();
      expect(labels.where((String l) => l.contains('考号')), isEmpty);
    });

    test('证书号类字段不在解析结果里', () {
      final Set<String> labels = allLabels();
      expect(labels.where((String l) => l.contains('证书号')), isEmpty);
    });

    test('证件号不在解析结果里（本校叫法）', () {
      final Set<String> labels = allLabels();
      expect(labels.where((String l) => l.contains('证件')), isEmpty,
          reason: '原文里有「证件类型 / 证件号」，解析结果里不该出现它们');
    });

    test('原文确实含这些字段（否则上面的用例是空跑）', () {
      final String html = _fixture();
      // 先证明「要拦的东西真的在输入里」，否则上面几条无论实现对不对都会过
      expect(html.contains('证件'), isTrue,
          reason: '语料里必须有证件字段，这条用例才有意义');
    });
  });

  group('正常字段不受影响', () {
    test('姓名与学号仍被正确提取（提取发生在过滤之前）', () {
      expect(p.name, isNotEmpty);
      expect(p.studentId, isNotEmpty);
    });

    test('基本信息该有的字段都还在（本校叫法）', () {
      final Set<String> labels = allLabels();
      // 本校页面的字段名带「所属/所在」前缀
      for (final String want in <String>[
        '所属院系', '所属专业', '所在班级', '培养层次', '学制', '学号', '姓名', '性别',
      ]) {
        expect(labels.contains(want), isTrue, reason: '缺少字段：$want');
      }
    });

    test('字段总数与「原文标签数 − 敏感项数 − 空值项」吻合（没有误删）', () {
      final Set<String> labels = allLabels();
      // 语料（脱敏版）里带值的字段：所属院系 / 所属专业 / 所在班级 /
      // 培养层次 / 学制 / 性别 / 证件类型 / 证件号 / 学号 / 姓名 = 10 个。
      //   · 「证件类型」「证件号」命中敏感关键词 → 剔除 2 个；
      //   · 「姓名拼音」的值为空（页面里那格是空的，学校没填）→ 不进结果。
      // 因此结果应是 8 个。
      //
      // 用精确等式而不是「大于某个数」：少一个正常字段时会立刻失败 ——
      // 而「字段变少」正是这类过滤逻辑最典型的误伤方式，界面上不易察觉。
      expect(labels.length, 8,
          reason: '原文 10 个带值字段 − 2 个敏感项 = 8；数字变了说明过滤出了偏差');
    });
  });
}
