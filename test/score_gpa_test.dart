/// 成绩与绩点计算（本校口径）
///
/// 学校页面上的「绩点」列整列是 0（没录入），因此绩点由**分数**推出：
///   `绩点 = (分数 - 50) ÷ 10`
/// 即 60 分 = 1.0、90 分 = 4.0、100 分 = 5.0 —— 国内高校常见的 5 分制。
///
/// 这些断言把**量纲**钉住。它很容易被无意改错：除以十之前，
/// 60 分算出 10 绩点、平均绩点显示成 40.72 这种不像绩点的数字，
/// 而界面不会报任何错。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hijianzhu_jw/model/models.dart';
import 'package:hijianzhu_jw/parser/score_parser.dart';

void main() {
  group('单科绩点 = (分数 - 50) ÷ 10', () {
    test('及格线 60 分 = 1.0 绩点', () {
      expect(ScoreParser.gpaFromScore('60'), closeTo(1.0, 0.0001));
    });

    test('常见分段', () {
      expect(ScoreParser.gpaFromScore('90'), closeTo(4.0, 0.0001));
      expect(ScoreParser.gpaFromScore('100'), closeTo(5.0, 0.0001));
      expect(ScoreParser.gpaFromScore('75'), closeTo(2.5, 0.0001));
      expect(ScoreParser.gpaFromScore('85.5'), closeTo(3.55, 0.0001));
    });

    test('不及格分数算出负数（< 50 分），调用方可据此识别', () {
      // 45 分 → -0.5。负数不是「算不出」（那是 -1），
      // 而是「真的低于及格线」——两个含义不能混。
      expect(ScoreParser.gpaFromScore('45'), closeTo(-0.5, 0.0001));
    });

    test('结果落在 5 分制的常见区间内（不是几十那种量纲）', () {
      for (final String s in <String>['60', '70', '80', '90', '100']) {
        final double g = ScoreParser.gpaFromScore(s);
        expect(g, greaterThanOrEqualTo(1.0));
        expect(g, lessThanOrEqualTo(5.0));
      }
    });
  });

  group('算不出绩点的情况返回 -1（与「绩点为 0」区分开）', () {
    test('非数字成绩', () {
      expect(ScoreParser.gpaFromScore('优秀'), -1);
      expect(ScoreParser.gpaFromScore('良好'), -1);
      expect(ScoreParser.gpaFromScore('合格'), -1);
      expect(ScoreParser.gpaFromScore(''), -1);
    });

    test('零分与负分视为无效（不是「0 绩点」）', () {
      expect(ScoreParser.gpaFromScore('0'), -1);
      expect(ScoreParser.gpaFromScore('-5'), -1);
    });
  });

  group('汇总：简单平均（不是学分加权）', () {
    ScoreRecord rec(String score, String credit) =>
        ScoreRecord(courseName: 'x', score: score, credit: credit);

    test('各科绩点直接平均，学分不参与权重', () {
      // 两门课：90 分（4.0，1 学分）、80 分（3.0，5 学分）
      // 简单平均 = (4.0 + 3.0) / 2 = 3.5
      // 若误用学分加权会得到 (4.0×1 + 3.0×5) / 6 = 3.1667
      final ScoreSummary s = ScoreParser.summarize(<ScoreRecord>[
        rec('90', '1'),
        rec('80', '5'),
      ]);
      expect(s.averageGpa, closeTo(3.5, 0.0001));
    });

    test('本学期没有可算的课时返回 0（而不是 NaN）', () {
      final ScoreSummary s = ScoreParser.summarize(<ScoreRecord>[
        rec('优秀', '2'),
      ]);
      expect(s.averageGpa, 0);
    });

    test('总学分只统计有分数的课以外也算——学分与绩点是两个独立口径', () {
      final ScoreSummary s = ScoreParser.summarize(<ScoreRecord>[
        rec('90', '3'),
        rec('优秀', '2'),
      ]);
      // 门数算全部
      expect(s.count, 2);
      // 平均绩点只按能算的那门算
      expect(s.averageGpa, closeTo(4.0, 0.0001));
    });
  });
}
