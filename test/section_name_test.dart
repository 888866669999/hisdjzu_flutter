/// 节次显示名（`第一大节` → `第一节`）—— 课表左侧列与空教室筛选共用
///
/// 用户要求把「一大／二大」这一列改成「第一节／第二节」的说法。本校源数据
/// 写的是「第一大节」/「第七节」，各校写法还不一样，必须都归到「第 X 节」；
/// 而设置页允许自定义节次名，那种名字不能被套上「第…节」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hijianzhu_jw/data/section_time_store.dart';

void main() {
  group('统一成「第 X 节」', () {
    test('本校的「第 N 大节」去掉「大」字', () {
      expect(sectionDisplayName('第一大节'), '第一节');
      expect(sectionDisplayName('第二大节'), '第二节');
      expect(sectionDisplayName('第五大节'), '第五节');
      expect(sectionDisplayName('第十二大节'), '第十二节');
    });

    test('别校的「第 N 节」原样保留（幂等）', () {
      expect(sectionDisplayName('第一节'), '第一节');
      expect(sectionDisplayName('第七节'), '第七节');
      // 幂等：反复调用不会再变
      expect(sectionDisplayName(sectionDisplayName('第七节')), '第七节');
      expect(sectionDisplayName(sectionDisplayName('第一大节')), '第一节');
    });

    test('阿拉伯数字', () {
      expect(sectionDisplayName('第1节'), '第1节');
      expect(sectionDisplayName('第12大节'), '第12节');
    });
  });

  group('自定义名称原样返回（不能变成「第早自习节」）', () {
    test('非序数的名字不动', () {
      expect(sectionDisplayName('早自习'), '早自习');
      expect(sectionDisplayName('上午第一节'), '上午第一节');
      expect(sectionDisplayName('晚自习'), '晚自习');
      expect(sectionDisplayName('午休'), '午休');
    });

    test('空串与纯符号不崩', () {
      expect(sectionDisplayName(''), '');
      expect(sectionDisplayName('第'), '第');
      expect(sectionDisplayName('节'), '节');
    });

    test('前后空白被去掉', () {
      expect(sectionDisplayName('  第一大节  '), '第一节');
      expect(sectionDisplayName('  早自习  '), '早自习');
    });
  });

  group('结果的显示宽度可控（这一列只有 34dp）', () {
    test('标准节次名的结果不超过 4 个字', () {
      for (final String s in <String>[
        '第一大节', '第二大节', '第五大节', '第十二大节',
        '第七节', '第1节', '第12大节',
      ]) {
        final String out = sectionDisplayName(s);
        expect(out.length, lessThanOrEqualTo(4),
            reason: '输入「$s」的结果「$out」太长，在 34dp 的列里会被缩到看不清');
      }
    });

    test('自定义名可能较长，但那是用户自己写的字，原样保留是对的', () {
      // 这一列的显示有 FittedBox 兜底（缩到放得下），
      // 所以自定义长名不会溢出 —— 只会变小。
      expect(sectionDisplayName('上午第一节'), '上午第一节');
    });
  });
}
