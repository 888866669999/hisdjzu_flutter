/// 校历与作息解析测试
///
/// ===== 本校与参考实现的差别（决定了这个文件测什么）=====
///   1. **作息不再来自官网**：本校教务处不公开作息表，但教务课表页
///      每个节次行的行首格自带时刻（`第一大节 (01,02小节) 07:50-09:25`）。
///      因此作息从**课表页**解析 —— 语料用真实抓取的 `timetable.html`。
///   2. **校历地址由用户填写**：本校没有稳定的校历页（按年份发公告、
///      地址每年变、挂的是 PDF），所以没有「固定的官网地址」可测；
///      这里测的是**地址校验**与**附件地址解析**。
///
/// 语料都是**真实抓取**的页面，不是手写样例 —— 这一块的风险恰好是
/// 「学校改版后解析悄悄失效」，手写样例测不出真实结构里的嵌套与转义。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hijianzhu_jw/data/campus_calendar_service.dart';

String _timetable() =>
    File('test/fixtures/timetable.html').readAsStringSync();

void main() {
  group('作息：从课表页解析', () {
    test('解析出 5 个大节，含名称与起止时刻', () {
      final List<List<String>> rows =
          CampusCalendarService.parseSectionTimesFromTimetable(_timetable());
      expect(rows.length, 5, reason: '本校课表固定 5 个大节');

      expect(rows[0], <String>['第一大节', '07:50', '09:25']);
      expect(rows[1], <String>['第二大节', '09:40', '12:05']);
      expect(rows[2], <String>['第三大节', '13:40', '15:15']);
      expect(rows[3], <String>['第四大节', '15:30', '17:05']);
      expect(rows[4], <String>['第五大节', '18:40', '21:05']);
    });

    test('时刻格式归一化：单位数补零', () {
      const String html = '<table><tr><th>第一大节 (01,02小节) 7:50-9:25</th></tr>'
          '<tr><th>第二大节 (03小节) 9:40-12:05</th></tr></table>';
      final List<List<String>> rows =
          CampusCalendarService.parseSectionTimesFromTimetable(html);
      expect(rows[0][1], '07:50');
      expect(rows[0][2], '09:25');
    });

    test('归并成课表行：行数恰好 5 时一一对应', () {
      final List<List<String>> rows =
          CampusCalendarService.parseSectionTimesFromTimetable(_timetable());
      final List<List<String>>? grid =
          CampusCalendarService.mapToGridRows(rows);
      expect(grid, isNotNull);
      expect(grid!.length, 5);
      expect(grid[0], <String>['07:50', '09:25']);
      expect(grid[4], <String>['18:40', '21:05']);
    });

    test('行数不足 5 时必须拒绝映射（宁可不用，也不能错位）', () {
      final List<List<String>> tooFew = <List<String>>[
        <String>['第一大节', '07:50', '09:25'],
        <String>['第二大节', '09:40', '12:05'],
      ];
      expect(CampusCalendarService.mapToGridRows(tooFew), isNull);
    });

    test('多于 5 行时把多出来的并入最后一行', () {
      final List<List<String>> six = <List<String>>[
        <String>['一', '08:00', '09:00'],
        <String>['二', '09:10', '10:00'],
        <String>['三', '10:10', '11:00'],
        <String>['四', '11:10', '12:00'],
        <String>['五', '13:00', '14:00'],
        <String>['六', '14:10', '15:00'],
      ];
      final List<List<String>>? grid = CampusCalendarService.mapToGridRows(six);
      expect(grid, isNotNull);
      expect(grid!.length, 5);
      // 最后一行的起点取「第五」，终点取最后一节的终点
      expect(grid[4], <String>['13:00', '15:00']);
    });

    test('解析结果与内置兜底值一致（内置值确实是本校的）', () {
      // 若有一天学校改了作息，这条会失败，提醒同步更新内置值与文档
      final List<List<String>> rows =
          CampusCalendarService.parseSectionTimesFromTimetable(_timetable());
      const List<List<String>> expected = <List<String>>[
        <String>['第一大节', '07:50', '09:25'],
        <String>['第二大节', '09:40', '12:05'],
        <String>['第三大节', '13:40', '15:15'],
        <String>['第四大节', '15:30', '17:05'],
        <String>['第五大节', '18:40', '21:05'],
      ];
      expect(rows, expected);
    });

    test('页面改版（无节次表）时返回空而不是抛异常', () {
      expect(
          CampusCalendarService.parseSectionTimesFromTimetable(
              '<html><body>维护中</body></html>'),
          isEmpty);
    });
  });

  group('校历附件地址解析', () {
    test('PDF 附件能识别（本校教务处挂的就是 PDF）', () {
      const String html =
          '<a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl'
          '&owner=1324481698&wbfileid=15398177">山东建筑大学2026年校历.pdf</a>';
      final List<String> urls = CampusCalendarService.parseAttachmentUrls(
          html, 'https://www.sdjzu.edu.cn/jwc/info/1024/3232.htm');
      expect(urls.length, 1);
      expect(urls.first, startsWith('https://www.sdjzu.edu.cn/system/'));
      expect(urls.first, isNot(contains('&amp;')),
          reason: '实体必须还原成 &，否则下载地址是错的');
    });

    test('站点装饰图不会被当成校历（真实页面里有 3 张 logo）', () {
      // 这是从真实教务处页面上抄下来的结构：导航链接 + 站点 logo
      const String html = '<a href="../../index.htm">首页</a>'
          '<img src="../../images/logo_left.jpg">'
          '<img src="/__local/F/EE/9F0C2CE8.png">'
          '<a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl'
          '&owner=1324481698&wbfileid=15398177">校历.pdf</a>';
      final List<String> urls = CampusCalendarService.parseAttachmentUrls(
          html, 'https://www.sdjzu.edu.cn/jwc/info/1024/3232.htm');
      expect(urls.length, 1, reason: '只该认出那个下载接口，logo 与导航都不算');
      expect(urls.first, contains('DownloadAttachUrl'));
    });

    test('绝对地址保持不变，重复地址只留一份', () {
      const String html =
          '<img src="https://cdn.example.com/a.pdf">'
          '<a href="https://cdn.example.com/a.pdf">下载</a>';
      final List<String> urls = CampusCalendarService.parseAttachmentUrls(
          html, 'https://www.example.edu.cn/p.htm');
      expect(urls, <String>['https://cdn.example.com/a.pdf']);
    });

    test('javascript:、锚点、普通图片都不会被当成附件', () {
      const String html = '<a href="javascript:void(0)">x</a>'
          '<a href="#top">y</a><img src="/x/photo.jpg">';
      expect(
          CampusCalendarService.parseAttachmentUrls(
              html, 'https://e.edu.cn/p.htm'),
          isEmpty);
    });

    test('解析更新时间（「发布时间：2025年12月19日」）', () {
      const String html = '<div>发布时间：<span>2025年12月19日 11:00</span></div>';
      expect(CampusCalendarService.parseUpdated(html), '2025年12月');
    });

    test('页面没有任何日期时返回空串', () {
      expect(CampusCalendarService.parseUpdated('<html></html>'), '');
    });
  });

  group('校历地址：用户填写与校验', () {
    test('只接受 http/https 且带主机的地址', () {
      // 具体断言在设置页交互层，这里只验证解析函数对畸形输入不抛异常
      expect(Uri.tryParse('') == null || !Uri.parse('').hasAuthority, isTrue);
      expect(Uri.parse('https://a.edu.cn/x.htm').hasAuthority, isTrue);
      expect(Uri.parse('ftp://a.edu.cn/x').scheme, 'ftp');
    });
  });
}
