/// 校历与作息表的获取
///
/// ===== 与参考实现的关键差别：校历地址由用户提供 =====
/// 参考实现把「学校官网校历页」写死成一个常量。对本校不可行：
///   1. 本校**没有稳定的校历页** —— 教务处是按年份发一篇公告
///      （「山东建筑大学 2026 年校历」），地址里带内容 id，每年都不一样；
///   2. 那个页面挂的是 **PDF 附件**，不是图片，无法直接显示；
///   3. 硬编码一个「当前年份」的地址，换年就静默失效 ——
///      而界面上看不出来，属于最危险的那类失败。
/// 因此改成**用户填地址**：设置页给一个输入框，引导用户到
/// 教务处「信息公开 → 校历」列表里找到当年那份，把地址粘进来。
/// 应用只负责抓取、缓存、解析，不假设任何具体网址。
///
/// ===== 作息表不靠官网 =====
/// 本校教务处不公开作息时刻表，但**教务课表页自己带时刻**
/// （节次行首格写作「第一大节 (01,02小节) 07:50-09:25」）。
/// 因此作息从**课表页**解析，见 [parseSectionTimesFromTimetable]，
/// 不依赖外网页面。
///
/// ===== 安全 =====
/// 用户填的地址属**不可信输入**，抓取前必须过 [UrlGuard]（拒绝环回/私有/
/// 保留地址，见其说明），并逐跳校验重定向 —— 否则一个恶意地址能把请求
/// 指向内网。同时**刻意不复用教务系统的 HttpClient**：那个客户端的
/// CookieJar 不带域名作用域、请求头还硬编码了教务 Origin/Referer，
/// 用它访问用户填的任意站点等于把会话 JSESSIONID 发出去。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../common/url_guard.dart';
import 'academic_calendar.dart';
import 'pref_store.dart';
import 'section_time_store.dart';
import '../common/constants.dart';

/// 抓取校历时允许的主机**后缀**白名单（留空表示不限制，仅做 SSRF 校验）。
///
/// 默认不限制具体域名：用户填的地址可能是学校官网、教务处子站、
/// 甚至校外镜像，写死一个清单会让「换了个地址就抓不到」。
/// 真正的安全边界是 [UrlGuard]（拒绝内网/环回/保留地址）与
/// 「只接受 http/https」这两条，与具体域名无关。
const Set<String> kCalendarAllowedHosts = <String>{};

/// 重定向上限：防止「A→B→A」循环把请求打成死循环
const int _maxRedirects = 5;

/// 抓取所用的 UA（不带任何 Cookie）
const String _userAgent =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// 抓取结果：作息行 + 可选的校历附件
class CampusCalendar {
  CampusCalendar({
    required this.sections,
    required this.images,
    required this.updated,
    required this.live,
  });

  /// 作息行（形如 `第一大节  07:50 - 09:25`）
  final List<String> sections;

  /// 校历附件的**本地文件路径**（图片直接存，PDF 也存下来交给外部应用打开）
  final List<String> images;

  /// 页面上标注的更新信息，如 `2026年9月`
  final String updated;

  /// true = 本次成功联网抓到的；false = 缓存的（或内置兜底）
  final bool live;

  /// 能否显示校历附件
  bool get hasImages => images.isNotEmpty;
}

class CampusCalendarService {
  static const Duration _timeout = Duration(seconds: 25);

  /// 缓存目录名（在应用私有目录下，不需要任何存储权限）
  static const String _dirName = 'campus';

  static CampusCalendar? _mem;

  /// 最近一次已知数据（内存 → 偏好 → 内置）
  static CampusCalendar? get current => _mem;

  /// 上次刷新的错误信息（供设置页展示，空表示没问题）
  static String lastError = '';

  static Future<Directory> _dir() async {
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory d =
        Directory('${base.path}${Platform.pathSeparator}$_dirName');
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    return d;
  }

  /// 从内置 / 缓存构造数据（不联网）
  static Future<CampusCalendar> _offline() async {
    final List<String> lines =
        _cachedSections() ?? AcademicCalendar.sectionLines();
    final List<String> files = await _cachedImages();
    return CampusCalendar(
      sections: lines,
      images: files,
      updated: _cachedUpdated(),
      live: false,
    );
  }

  /// 读取当前可用的校历（优先内存，其次缓存 + 内置兜底）
  static Future<CampusCalendar> load() async {
    if (_mem != null) {
      return _mem!;
    }
    _mem = await _offline();
    return _mem!;
  }

  /// 用户配置的校历页地址（空串 = 还没填）
  static String pageUrl() => PrefStore.getText(kKeyCalendarUrl);

  /// 保存用户填的地址（会先做基本校验，不合法则拒绝并返回 false）
  static Future<bool> setPageUrl(String url) async {
    final String u = url.trim();
    if (u.isEmpty) {
      await PrefStore.putText(kKeyCalendarUrl, '');
      return true;
    }
    final Uri? parsed = Uri.tryParse(u);
    if (parsed == null || !parsed.hasScheme || !parsed.hasAuthority) {
      return false;
    }
    if (parsed.scheme != 'http' && parsed.scheme != 'https') {
      return false;
    }
    await PrefStore.putText(kKeyCalendarUrl, u);
    return true;
  }

  /// 联网抓用户配置的校历页；成功则落盘并返回，失败返回 null（保留原缓存）
  ///
  /// 从不抛异常：校历抓不到不该影响任何主流程。
  static Future<CampusCalendar?> refresh() async {
    lastError = '';
    final String url = pageUrl();
    if (url.isEmpty) {
      lastError = '尚未设置校历地址';
      return null;
    }
    try {
      final http.Client client = http.Client();
      try {
        // 用户填的地址是不可信输入，必须过一次 UrlGuard
        UrlGuard.check(url, allowedHosts: kCalendarAllowedHosts);
        final http.Response res = await client.get(
          Uri.parse(url),
          headers: const <String, String>{
            'User-Agent': _userAgent,
            'Accept': 'text/html,application/xhtml+xml',
            'Accept-Language': 'zh-CN,zh;q=0.9',
          },
        ).timeout(_timeout);

        if (res.statusCode != 200) {
          lastError = '校历页返回 ${res.statusCode}';
          return null;
        }
        // 学校 CMS 的编码不统一，GBK 与 UTF-8 都见过：先按响应头判断，
        // 判不出来就按 UTF-8 容错解码（乱码不影响「抓附件地址」这件事）
        final String html = _decode(res);

        // 附件地址：图片与 PDF 都要 —— 本校校历是 PDF，
        // 而参考实现那边是图片，两种都得支持
        final List<String> urls = parseAttachmentUrls(html, url);
        final String updated = parseUpdated(html);

        final List<String> local = <String>[];
        for (int i = 0; i < urls.length && i < 4; i++) {
          final String name = _fileNameFor(urls[i], i);
          final String? p = await _downloadIfChanged(urls[i], name, i);
          if (p != null) {
            local.add(p);
          }
        }

        // 解析不到任何东西就不要覆盖已有缓存（学校改版时宁可继续用旧的）
        if (local.isEmpty) {
          lastError = '未能从该页面解析出校历附件';
          return null;
        }

        final CampusCalendar out = CampusCalendar(
          sections: (await _offline()).sections,
          images: local,
          updated: updated,
          live: true,
        );

        await _savePrefs(out, urls);
        _mem = out;
        return out;
      } finally {
        client.close();
      }
    } catch (e) {
      lastError = e.toString();
      return null;
    }
  }

  /// 解码响应体。
  ///
  /// 只做 UTF-8（容错模式）。**不引入 GBK 解码**：那需要额外的字符集表，
  /// 而这里真正要拿的是**附件地址**（纯 ASCII），即使正文乱码也不影响；
  /// 唯一的代价是「更新时间」这类展示文本可能显示成乱码 ——
  /// 为它引入一个依赖包不划算。乱码时用户仍能正常打开附件。
  static String _decode(http.Response res) {
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  /// 根据附件地址推断本地文件名（保留扩展名，图片/PDF 通用）
  static String _fileNameFor(String url, int index) {
    final String path = Uri.parse(url).path.toLowerCase();
    String ext = '.bin';
    for (final String e in <String>['.jpg', '.jpeg', '.png', '.gif', '.pdf']) {
      if (path.endsWith(e)) {
        ext = e;
        break;
      }
    }
    return 'calendar_${index + 1}$ext';
  }

  /// 下载一个附件；**地址与上次相同且本地文件还在时直接跳过**。
  ///
  /// 判据用 URL 而不是文件时间/大小：URL 变了才意味着学校换了附件，
  /// 这是「内容变了」的直接证据，比任何启发式都可靠。
  static Future<String?> _downloadIfChanged(
      String url, String name, int index) async {
    try {
      final Directory d = await _dir();
      final File f = File('${d.path}${Platform.pathSeparator}$name');
      final List<String> prev =
          _splitLines(PrefStore.getText(kKeyCampusImageUrls)) ?? <String>[];
      final bool sameUrl = index < prev.length && prev[index] == url;
      if (sameUrl && f.existsSync() && f.lengthSync() > 512) {
        return f.path;
      }
      return await _download(url, name);
    } catch (_) {
      return null;
    }
  }

  /// 下载一个附件到缓存目录。
  ///
  /// 地址来自**页面解析结果**，属不可信输入，因此：
  ///   1. 过 [UrlGuard]（拒绝环回/私有/保留地址）；
  ///   2. 手动跟随重定向并**逐跳校验** —— 否则合法主机可以 302 到内网。
  /// 只带 `Accept`，不带任何 Cookie。
  static Future<String?> _download(String url, String name) async {
    try {
      final Directory d = await _dir();
      final File f = File('${d.path}${Platform.pathSeparator}$name');

      final Uint8List b = await _getValidated(url, since: _lastFetchedAt());
      if (b.isEmpty) {
        // 服务端应答 304（未修改）：本地文件就是最新的
        return f.existsSync() ? f.path : null;
      }
      if (b.length < 512) {
        return f.existsSync() ? f.path : null;
      }
      // 内容校验：抓回来的可能是 HTML 错误页，别把错误页当附件存下来。
      // 允许两类：图片（JPEG/PNG/GIF）与 PDF。
      if (!_looksLikeAttachment(b)) {
        return f.existsSync() ? f.path : null;
      }
      await f.writeAsBytes(b, flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// 是否是受支持的附件（图片或 PDF）。
  static bool _looksLikeAttachment(Uint8List b) {
    if (b.length < 4) {
      return false;
    }
    // JPEG
    if (b[0] == 0xFF && b[1] == 0xD8) {
      return true;
    }
    // PNG
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return true;
    }
    // GIF
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      return true;
    }
    // PDF: "%PDF"
    if (b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46) {
      return true;
    }
    return false;
  }

  /// 上次成功抓取的时刻（毫秒）；从未抓过返回 0
  static int _lastFetchedAt() => PrefStore.getInt(kKeyCampusFetchedAt);

  /// 取字节，逐跳校验主机（SSRF 防护）。
  static Future<Uint8List> _getValidated(String url, {int since = 0}) async {
    final http.Client client = http.Client();
    try {
      String current = url;
      for (int hop = 0; hop <= _maxRedirects; hop++) {
        UrlGuard.check(current, allowedHosts: kCalendarAllowedHosts);
        final http.Request req = http.Request('GET', Uri.parse(current));
        req.headers['Accept'] = '*/*';
        req.headers['User-Agent'] = _userAgent;
        if (since > 0) {
          req.headers['If-Modified-Since'] =
              HttpDate.format(DateTime.fromMillisecondsSinceEpoch(since));
        }
        req.followRedirects = false;
        final http.StreamedResponse st = await req.send().timeout(_timeout);
        final http.Response res = await http.Response.fromStream(st);

        if (res.statusCode >= 300 && res.statusCode < 400) {
          final String loc = res.headers['location'] ?? '';
          if (loc.isEmpty) {
            throw const FormatException('redirect without location');
          }
          current = Uri.parse(current).resolve(loc).toString();
          continue;
        }
        if (res.statusCode == 304) {
          return Uint8List(0);
        }
        if (res.statusCode != 200) {
          throw FormatException('http=${res.statusCode}');
        }
        return res.bodyBytes;
      }
      throw const FormatException('too many redirects');
    } finally {
      client.close();
    }
  }

  static Future<void> _savePrefs(CampusCalendar c, List<String> urls) async {
    await PrefStore.putText(kKeyCampusSections, c.sections.join('\n'));
    await PrefStore.putText(kKeyCampusImages, c.images.join('\n'));
    await PrefStore.putText(kKeyCampusImageUrls, urls.join('\n'));
    await PrefStore.putText(kKeyCampusUpdated, c.updated);
    await PrefStore.putInt(
        kKeyCampusFetchedAt, DateTime.now().millisecondsSinceEpoch);
  }

  static List<String>? _cachedSections() =>
      _splitLines(PrefStore.getText(kKeyCampusSections));

  static String _cachedUpdated() => PrefStore.getText(kKeyCampusUpdated);

  static Future<List<String>> _cachedImages() async {
    final List<String> paths =
        _splitLines(PrefStore.getText(kKeyCampusImages)) ?? <String>[];
    final List<String> ok = <String>[];
    for (final String p in paths) {
      if (p.isNotEmpty && File(p).existsSync()) {
        ok.add(p);
      }
    }
    return ok;
  }

  static List<String>? _splitLines(String raw) {
    if (raw.trim().isEmpty) {
      return null;
    }
    final List<String> out = raw
        .split('\n')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    return out.isEmpty ? null : out;
  }

  static int lastFetchedAt() => PrefStore.getInt(kKeyCampusFetchedAt);

  /// 缓存是否已过期（从未抓过也算过期）。默认 7 天。
  static bool isStale({Duration maxAge = const Duration(days: 7)}) {
    final int at = lastFetchedAt();
    if (at <= 0) {
      return true;
    }
    final DateTime then =
        DateTime.fromMillisecondsSinceEpoch(at, isUtc: false);
    return DateTime.now().difference(then) > maxAge;
  }

  /// 设置页的副标题：只说「能不能看」，不暴露数据来源与缓存细节。
  static String hint(CampusCalendar c) {
    if (pageUrl().isEmpty) {
      return '选择要显示的校历';
    }
    if (c.updated.isEmpty) {
      return '查看已获取的校历';
    }
    return '官网 ${c.updated} 版';
  }

  /// 缓存占用（字节），供设置页展示
  static Future<int> cacheBytes() async {
    try {
      final Directory d = await _dir();
      int total = 0;
      await for (final FileSystemEntity e in d.list()) {
        if (e is File) {
          total += await e.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> clearCache() async {
    try {
      final Directory d = await _dir();
      if (await d.exists()) {
        await d.delete(recursive: true);
      }
    } catch (_) {}
    _mem = null;
    await PrefStore.putText(kKeyCampusSections, '');
    await PrefStore.putText(kKeyCampusImages, '');
    await PrefStore.putText(kKeyCampusImageUrls, '');
    await PrefStore.putText(kKeyCampusUpdated, '');
  }

  // ==================== 纯解析逻辑（可单测，不碰网络）====================

  /// 从课表页解析节次作息 —— 本校**唯一的**权威来源。
  ///
  /// 课表的每个节次行首格写作：
  ///   `第一大节 (01,02小节) 07:50-09:25`
  /// 从中取「节次名 + 起止时刻」。返回 `[label, start, end]` 列表。
  ///
  /// 为什么从课表页取而不是官网：本校教务处只发校历 PDF，
  /// 不公开作息表；而课表页本来就要抓（课表数据也来自它），
  /// 顺带解析没有额外请求。
  static List<List<String>> parseSectionTimesFromTimetable(String html) {
    final List<List<String>> out = <List<String>>[];
    // 行首格是 th（节次名所在格），里面含时刻
    final RegExp thRe = RegExp(r'<th[^>]*>([\s\S]{0,300}?)</th>',
        caseSensitive: false);
    final RegExp timeRe = RegExp(r'(\d{1,2}:\d{2})\s*[-—~～]\s*(\d{1,2}:\d{2})');
    for (final RegExpMatch m in thRe.allMatches(html)) {
      final String inner = m.group(1) ?? '';
      if (!inner.contains('节')) {
        continue;
      }
      final RegExpMatch? tm = timeRe.firstMatch(inner);
      if (tm == null) {
        continue;
      }
      final String text = HtmlLiteText.of(inner);
      // 节次名 = 「(…小节)」之前的那一段
      String label = text;
      final int paren = text.indexOf('(');
      if (paren > 0) {
        label = text.substring(0, paren);
      } else {
        // 全角括号
        final int p2 = text.indexOf('（');
        if (p2 > 0) {
          label = text.substring(0, p2);
        }
      }
      label = label.replaceAll(RegExp(r'\s+'), '').trim();
      if (label.isEmpty) {
        continue;
      }
      out.add(<String>[
        label,
        _two(tm.group(1)!),
        _two(tm.group(2)!),
      ]);
    }
    return out;
  }

  /// `7:50` → `07:50`
  static String _two(String t) {
    final int i = t.indexOf(':');
    if (i <= 0) {
      return t;
    }
    final String h = t.substring(0, i);
    return h.length == 1 ? '0$t' : t;
  }

  /// 从 HTML 里取可下载的**校历附件**地址（绝对化、去重、按出现顺序）。
  ///
  /// ===== 这里必须严格，否则会把站内装饰图当成校历 =====
  /// 对着真实页面核过：一篇校历公告里除了附件，还有几十个导航链接和
  /// 两三张站点 logo（`/images/logo_left.jpg`、`/__local/…png`）。
  /// 早先的实现「凡 .jpg/.png 都要」，结果校历页显示成一堆 logo。
  ///
  /// 因此只认三类**附件特征**：
  ///   1. 学校 CMS 的下载接口 —— `download.jsp?urltype=news.DownloadAttachUrl`
  ///      或带 `wbfileid=`（本校教务处用的就是这个）；
  ///   2. `/__local/` 下的附件（书院 CMS 把上传文件放这里，
  ///      与 `/images/`、`/__local/…/logo` 这类站点资源不同）；
  ///   3. 正文里指向 `.pdf` 的链接（很多学校直接给 PDF 地址）。
  ///
  /// 刻意**不**把「正文里的 .jpg」算进来：本站的校历是 PDF，
  /// 而参考实现那边的图片走的是专用附件路径（`virtual_attach_file`），
  /// 那个特征已单独识别。放宽到「任意图片」只会误收 logo。
  static List<String> parseAttachmentUrls(String html, String pageUrl) {
    final List<String> out = <String>[];

    void add(String raw) {
      final String cleaned = raw.replaceAll('&amp;', '&').trim();
      if (cleaned.isEmpty) {
        return;
      }
      final String abs = _absolutize(cleaned, pageUrl);
      if (!out.contains(abs)) {
        out.add(abs);
      }
    }

    // 遍历所有带 href 的 <a>（附件几乎都以链接形式给出）
    final RegExp aRe = RegExp(r'<a[^>]*>', caseSensitive: false);
    for (final RegExpMatch m in aRe.allMatches(html)) {
      final String tag = m.group(0) ?? '';
      final String? href = _attr(tag, 'href');
      if (href == null || href.isEmpty) {
        continue;
      }
      if (_isAttachmentUrl(href)) {
        add(href);
      }
    }

    // 参考实现那边的校历是图片、挂在专用附件路径上（`virtual_attach_file`），
    // 因此还要看 <img>，但**只认那一个特征**，不放宽到任意图片。
    final RegExp imgRe = RegExp(r'<img[^>]*>', caseSensitive: false);
    for (final RegExpMatch m in imgRe.allMatches(html)) {
      final String tag = m.group(0) ?? '';
      // 优先取原图属性（CMS 里拼作 orisrc，少一个 g 的写法也认）
      final String? ori = _attr(tag, 'origsrc') ?? _attr(tag, 'orisrc');
      final String? src = _attr(tag, 'src');
      final String? pick = (ori != null && ori.isNotEmpty) ? ori : src;
      if (pick == null || pick.isEmpty) {
        continue;
      }
      if (pick.contains('virtual_attach_file')) {
        add(pick);
      }
    }

    return out;
  }

  /// 这个链接是「可下载的校历附件」吗？
  ///
  /// 判据见 [parseAttachmentUrls] 的说明：只认 CMS 下载接口、
  /// `/__local/` 附件区、以及正文里的 `.pdf` 链接。
  static bool _isAttachmentUrl(String url) {
    final String u = url.toLowerCase();
    if (u.startsWith('javascript:') || u.startsWith('#')) {
      return false;
    }
    // 1) 学校 CMS 的下载接口（本校教务处）
    if (u.contains('downloadattachurl') || u.contains('wbfileid=')) {
      return true;
    }
    if (u.contains('download.jsp') && u.contains('urltype=news')) {
      return true;
    }
    // 2) 网站附件区（书院 CMS 把上传文件放 /__local/，站点图片在 /images/）
    if (u.contains('/__local/') && !u.contains('logo')) {
      return true;
    }
    // 3) 正文里直接指向 PDF
    if (u.endsWith('.pdf')) {
      return true;
    }
    return false;
  }

  /// 取页面上的更新信息（`更新时间：2026年9月` 或 `2025年12月19日`）
  static String parseUpdated(String html) {
    final String t = HtmlLiteText.of(html);
    // 形如「发布时间：2025年12月19日」
    final RegExpMatch? m =
        RegExp(r'(?:更新|发布)时间[:：]\s*([0-9]{4}\s*年\s*[0-9]{1,2}\s*月)')
            .firstMatch(t);
    if (m != null) {
      return (m.group(1) ?? '').replaceAll(RegExp(r'\s+'), '');
    }
    final RegExpMatch? m2 =
        RegExp(r'([0-9]{4}\s*年\s*[0-9]{1,2}\s*月)\s*[0-9]{1,2}\s*日')
            .firstMatch(t);
    if (m2 != null) {
      return (m2.group(1) ?? '').replaceAll(RegExp(r'\s+'), '');
    }
    return '';
  }

  /// 把解析出的作息行归并成课表的 5 行（`kSectionRows`），返回 `[start, end]`。
  ///
  ///   - 行数恰好等于 5 → 一一对应；
  ///   - 多于 5 → 前 4 行一一对应，多出来的并进第 5 行（取首行起点、末行终点）；
  ///   - 少于 5 → **不做映射**（返回 null），宁可继续用本地值，
  ///     也不要按错位的时间算提醒。
  static List<List<String>>? mapToGridRows(List<List<String>> sections) {
    if (sections.length < kSectionRows) {
      return null;
    }
    if (sections.length == kSectionRows) {
      return sections.map((List<String> s) => <String>[s[1], s[2]]).toList();
    }
    final List<List<String>> out = <List<String>>[];
    for (int i = 0; i < kSectionRows - 1; i++) {
      out.add(<String>[sections[i][1], sections[i][2]]);
    }
    out.add(<String>[
      sections[kSectionRows - 1][1],
      sections[sections.length - 1][2],
    ]);
    return out;
  }

  /// 若用户**没有自定义过**作息，就用从课表页解析到的时刻刷新本地作息。
  ///
  /// 只在 `SectionTimeStore.isDefault()` 为真时写入 —— 用户手动调过的时间
  /// 是用户意图，不能被一次联网静默覆盖。
  static Future<bool> applyOfficialSectionsIfDefault(
      List<List<String>> sections) async {
    final List<List<String>>? rows = mapToGridRows(sections);
    if (rows == null || rows.length != kSectionRows) {
      return false;
    }
    await SectionTimeStore.load();
    if (!SectionTimeStore.isDefault()) {
      return false;
    }
    bool changed = false;
    for (int i = 0; i < kSectionRows; i++) {
      if (kSections[i].start != rows[i][0] || kSections[i].end != rows[i][1]) {
        changed = true;
        break;
      }
    }
    if (!changed) {
      return false;
    }
    final List<SectionTime> list = <SectionTime>[];
    for (int i = 0; i < kSectionRows; i++) {
      list.add(SectionTime(i, kSections[i].label, rows[i][0], rows[i][1]));
    }
    // 用 saveOfficial 而不是 saveAll：这是**官网/教务**的值，
    // 不能置位「已自定义」标记 —— 否则同步一次就再也不跟随了。
    await SectionTimeStore.saveOfficial(list);
    return true;
  }

  // ---------- 小型 HTML 工具（不引入 DOM，够用即可）----------

  /// 取属性值（支持 `name="v"` 与 `name='v'`）。
  ///
  /// 用负向回顾断言保证 `src` **不会**匹配到 `data-src` 这类带前缀的属性。
  static String? _attr(String tag, String name) {
    final RegExpMatch? m = RegExp(
      '(?<![A-Za-z0-9_-])$name\\s*=\\s*("([^"]*)"|\'([^\']*)\')',
      caseSensitive: false,
    ).firstMatch(tag);
    if (m == null) {
      return null;
    }
    return m.group(2) ?? m.group(3) ?? '';
  }

  /// 相对地址 → 绝对地址
  static String _absolutize(String url, String pageUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    final Uri base = Uri.parse(pageUrl);
    if (url.startsWith('/')) {
      return '${base.scheme}://${base.authority}$url';
    }
    return base.resolve(url).toString();
  }
}

/// 极简 HTML 文本提取（本文件内部用；完整版见 parser/html_lite.dart）
class HtmlLiteText {
  /// 去标签 + 解实体 + 压空白
  static String of(String html) => html
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
