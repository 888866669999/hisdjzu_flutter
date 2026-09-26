/// 强智教务系统接口封装
///
/// 从鸿蒙版 `network/QzApi.ets` 移植。
///
/// ===== 登录链路（三段式，缺一不可）=====
///   1. POST `/Logon.do?method=logon&flag=sess`  → 拿 `scode#sxh`
///   2. 用 [QzEncoder] 生成 `encoded`
///   3. POST `/Logon.do?method=logon` 提交
///      `userAccount / userPassword / RANDOMCODE / encoded`
/// 成功后服务器**不直接返回页面**，而是 302 + `Location` 里的 `ticket`；
/// 必须再 GET 一次该地址，才会换成 `/jsxsd/` 下的学生端会话。
///
/// ===== 判定结果不能只看状态码 =====
/// 登录成功恰恰是 404/302（带 Location）这种「非 200」响应，
/// 因此 [checkResponse] 只在「状态码 >= 400 **且没有 Location**」时才报错。
/// 早期实现见到非 200 就判会话失效，导致登录永远失败。
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../common/constants.dart';
import '../common/result.dart';
import '../crypto/qz_encoder.dart';
import '../model/classroom_models.dart';
import '../model/models.dart';
import '../parser/classroom_parser.dart';
import '../parser/elective_parser.dart';
import '../parser/html_lite.dart';
import '../parser/plan_parser.dart';
import '../parser/profile_parser.dart';
import '../parser/score_parser.dart';
import '../parser/timetable_parser.dart';
import '../parser/week_calendar_parser.dart';
import 'cookie_jar.dart';
import 'http_client.dart';

/// 登录失败类别（供重试决策使用）。
///
/// **必须机器可读**：自动登录重试只能发生在「验证码错」这类可恢复失败上。
/// 若靠比对界面文案判断，服务端措辞一变就会把「密码错误」误判为可重试，
/// 那就变成拿错误凭据反复提交，有把账号打到临时锁定的实际风险。
enum LoginFailKind {
  none,

  /// 验证码不对（可换图重试）
  captcha,

  /// 账号或密码不对（绝不重试）
  credential,

  /// 会话/握手异常
  session,

  /// 服务端拒绝本次登录（限流/维护等）
  rejected,

  unknown,
}

class LoginResult {
  LoginResult(this.success, this.message, [this.kind = LoginFailKind.none]);

  final bool success;
  final String message;
  final LoginFailKind kind;

  factory LoginResult.fail(String message, LoginFailKind kind) =>
      LoginResult(false, message, kind);
}

/// 教室查询页的可选项
class ClassroomOptions {
  ClassroomOptions(this.campuses, this.semesters);

  /// 元素形如 `3|章丘校区`（value|label）
  final List<String> campuses;
  final List<String> semesters;
}

class QzApi {
  QzApi(this.jar) : _client = HttpClient(jar);

  final CookieJar jar;
  final HttpClient _client;

  /// 并发探测去重。
  ///
  /// 启动时「恢复会话」与「静默续期」会各自探测一次会话。两条请求带着
  /// **同一个 JSESSIONID** 并发打到服务器，服务端一旦轮换会话，
  /// 后到的那条就被判未登录 —— 于是出现「假失效」，触发一次完全不必要的
  /// 重新登录，而这次登录又会再轮换会话、干扰在途请求。
  /// 鸿蒙版实测有此现象，这里从一开始就去重。
  Future<bool>? _probeInFlight;

  String get cookieHeader => jar.toHeader();

  // ==================== 登录 ====================

  /// 取验证码原图（JPEG 字节）。
  ///
  /// ===== 为什么要先访问一次登录页 =====
  /// 本校的会话是**按 URL 上下文分作用域**的：
  /// `/jsxsd/…` 下的资源用 `Path=/jsxsd` 的 JSESSIONID，
  /// 而根路径下的资源用 `Path=/` 的 —— 两者互不相认（实测：拿 `Path=/`
  /// 的会话去访问 `/jsxsd/`，服务端会直接换发一个新的）。
  ///
  /// 若冷启动后第一个请求就是验证码图片，服务端可能先给一个
  /// 根作用域的会话；之后提交登录（`/jsxsd/xk/LoginToXk`）时它不认，
  /// 又换一个 —— 验证码答案就丢了，表现为**永远报「验证码错误」**。
  ///
  /// 因此这里先 GET 一次登录页，让服务端在 `/jsxsd` 上下文里建立会话，
  /// 再取图。代价是一次很小的 HTML 请求，换来验证码与登录必定同会话。
  Future<Uint8List> fetchCaptcha() async {
    // 1) 建立 /jsxsd 作用域的会话（失败也继续：也许已有可用会话）
    try {
      await _client.get('$kBaseOrigin$kPathLoginPage');
    } catch (e) {
      // 忽略：取验证码那一步的错误处理会给出更贴切的提示
    }

    // 2) 取验证码图（与登录同一个 /jsxsd 上下文）
    final String before = jar.toHeader();
    final Uint8List buf = await _client.getBinary(
        '$kBaseOrigin$kPathCaptcha', 'image/*,*/*;q=0.8');
    final String after = jar.toHeader();
    if (before != after) {
      // 会话被轮换：正常现象，调用方无需处理（验证码与登录都读当前 jar）
      debugPrint('[api] captcha: session rotated');
    }
    return buf;
  }

  /// 登录
  ///
  /// ===== 本校的流程比参考实现短一步（不握手）=====
  /// 参考实现（山财）要先请求 `/Logon.do?...flag=sess` 拿 `scode#sxh`，
  /// 再按位插字符算出 `encoded`；本校的登录页根本没有这一步 ——
  /// 它的 `submitForm1()` 直接把账号/密码各做一次 Base64、用 `%%%` 拼起来。
  /// 见 [QzEncoder] 的说明。
  Future<LoginResult> login(String account, String password, String captcha) async {
    // 1) 算 encoded（纯本地计算，无网络往返）
    final String encoded = QzEncoder.buildEncoded(account, password);
    if (encoded.isEmpty) {
      // 账号或密码为空。界面本应先拦住，这里兜底防「用空凭据打接口」
      return LoginResult.fail('请输入账号与密码', LoginFailKind.session);
    }

    // 2) 提交登录（不自动跟随重定向，要自己读 Location）
    //
    // 字段与**真实表单逐字对齐**（少一个就会被判成无效登录）：
    //   · `loginMethod=LoginToXk` 是表单里的隐藏字段，必须带；
    //   · `userPassword` 要**原样提交**：页面 JS 里写着
    //     `userPassword.value = pwd`，服务端两者都读。留空会被回
    //     「账号或密码不能为空」——这不是靠推测，是实测踩过的。
    final HttpResponse res = await _client.postFormNoRedirect(
      '$kBaseOrigin$kPathLogon',
      <FormField>[
        const FormField(kLoginMethodName, kLoginMethodValue),
        FormField('userAccount', account),
        FormField('userPassword', password),
        FormField('RANDOMCODE', captcha),
        FormField('encoded', encoded),
      ],
    );

    // 3) 判定
    final String location = res.header('location');
    if (location.isNotEmpty) {
      final String target = _absolute(location);
      final HttpResponse uni = await _client.get(target);
      if (HtmlLite.isLoginPage(uni.body)) {
        return LoginResult.fail('登录未能建立会话，请重试', LoginFailKind.session);
      }
      return LoginResult(true, '登录成功');
    }
    if (HtmlLite.isLoginPage(res.body)) {
      final String hint = _extractError(res.body);
      return LoginResult.fail(
        hint.isNotEmpty ? hint : '账号或密码或验证码有误',
        _classifyFail(hint),
      );
    }
    if (res.body.contains('xsMain') ||
        res.body.contains('教学一体化服务平台') ||
        res.body.contains('framework')) {
      return LoginResult(true, '登录成功');
    }
    return LoginResult.fail('登录失败，请检查账号密码与验证码', LoginFailKind.unknown);
  }

  /// 会话是否仍然有效。
  ///
  /// - true：服务器返回正常页面（顺带刷新 cookie）
  /// - false：明确要求登录
  /// - 抛出：网络失败，调用方应保持原状态而不是登出
  Future<bool> isSessionAlive() async {
    if (_probeInFlight != null) {
      return _probeInFlight!;
    }
    _probeInFlight = _probeSession();
    try {
      return await _probeInFlight!;
    } finally {
      _probeInFlight = null;
    }
  }

  Future<bool> _probeSession() async {
    final HttpResponse res = await _client.get('$kBaseOrigin$kPathMain');
    final String loc = res.header('location');
    if (loc.isNotEmpty &&
        (loc.contains('Logon') || loc.contains('logon'))) {
      return false;
    }
    if (HtmlLite.isLoginPage(res.body)) {
      return false;
    }
    return true;
  }

  // ==================== 业务接口 ====================

  Future<TimetableParseResult> getTimetable(String semester, String week) async {
    final List<FormField> fields = <FormField>[];
    if (semester.isNotEmpty) {
      fields.add(FormField('xnxq01id', semester));
    }
    if (week.isNotEmpty) {
      fields.add(FormField('zc', week));
    }
    final HttpResponse res = fields.isEmpty
        ? await _client.get('$kBaseOrigin$kPathTimetable')
        : await _client.postForm('$kBaseOrigin$kPathTimetable', fields);
    _checkResponse(res);
    // 原文一并带回：课表页要用它同步作息时刻（见 TimetableParseResult.rawHtml）
    return TimetableParser.parse(res.body, semester, week);
  }

  // ==================== 「取原文」与「解析」分开 ====================
  //
  // 下面每个接口都成对出现：
  //   `getXxxHtml()` —— 发请求、检查响应、返回**未解析的页面原文**
  //   `getXxx()`     —— 把 `getXxxHtml()` 的结果解析成模型
  //
  // 拆开的原因是页面缓存（见 data/page_cache.dart）：缓存要存的是原文，
  // 而不是解析后的模型 —— 这样缓存层只依赖「请求」这一件事，
  // 解析器的任何修改都会自动作用于缓存的旧数据。
  // 只做解析的那一层保持原样，调用方（不含缓存的场景）不受影响。

  /// 成绩列表页原文
  Future<String> getScoresHtml(String semester) async {
    final String url = semester.isEmpty
        ? '$kBaseOrigin$kPathScoreList'
        : '$kBaseOrigin$kPathScoreList?kksj=${Uri.encodeQueryComponent(semester)}';
    final HttpResponse res = await _client.get(url);
    _checkResponse(res);
    return res.body;
  }

  Future<List<ScoreRecord>> getScores(String semester) async =>
      ScoreParser.parse(await getScoresHtml(semester));

  /// 成绩查询页原文（学期下拉的来源）
  Future<String> getScoreSemestersHtml() async {
    final HttpResponse res = await _client.get('$kBaseOrigin$kPathScoreQuery');
    _checkResponse(res);
    return res.body;
  }

  Future<List<ChoiceItem>> getScoreSemesters() async =>
      ScoreParser.readSemesters(await getScoreSemestersHtml());

  /// 学籍卡片原文
  Future<String> getProfileHtml() async {
    final String url = '$kBaseOrigin$kPathProfile';
    final HttpResponse res = await _client.get(url);

    _checkResponse(res);
    return res.body;
  }

  Future<StudentProfile> getProfile() async =>
      ProfileParser.parse(await getProfileHtml());

  /// 教学周历页原文。传 [semester] 则取指定学年的那学期。
  ///
  /// 这个页面是**唯一权威且能随年份自动更新**的校历数据源：
  /// 它给出「第 N 周 ←→ 周一日期」的完整对照，学校每学期排课时录入，
  /// 换学年后取到的自然是新数据。学校官网那张校历图只是它的图片版，
  /// 图里能算的（周次、起止、寒暑假边界）这里都有结构化字段。
  ///
  /// 服务端的表单是 `post xnxq01id=<学期>`（onchange 自动提交），
  /// 不传则返回当前学期。
  Future<String> getWeekCalendarHtml([String semester = '']) async {
    final HttpResponse res = semester.isEmpty
        ? await _client.get('$kBaseOrigin$kPathWeekCalendar')
        : await _client.postForm('$kBaseOrigin$kPathWeekCalendar', <FormField>[
            FormField('xnxq01id', semester),
          ]);
    _checkResponse(res);
    return res.body;
  }

  Future<List<WeekDate>> getWeekCalendar([String semester = '']) async =>
      WeekCalendarParser.parseWeekDates(await getWeekCalendarHtml(semester));

  /// 周历页上「可选学期」列表（形如 2026-2027-1）。
  ///
  /// 以服务端返回的为准，而不是自己按当前年份推算：只有真正排过课的学期
  /// 才会出现在这里，这样界面上就不会出现一个点进去空空如也的学期。
  Future<List<ChoiceItem>> getWeekCalendarSemesters() async =>
      WeekCalendarParser.parseSemesterOptions(await getWeekCalendarHtml());

  /// 培养方案明细页原文
  Future<String> getPlanHtml() async {
    final HttpResponse res = await _client.get('$kBaseOrigin$kPathPlanDetail');
    _checkResponse(res);
    return res.body;
  }

  Future<PlanDetail> getPlanDetail() async => PlanParser.parse(await getPlanHtml());

  /// 通选课修读情况原文
  Future<String> getElectiveHtml() async {
    final HttpResponse res = await _client.get('$kBaseOrigin$kPathElective');
    _checkResponse(res);
    return res.body;
  }

  Future<ElectiveReport> getElectiveReport() async =>
      ElectiveParser.parse(await getElectiveHtml());

  // ============ 空闲教室（本校接口与参考实现完全不同）============
  //
  // 本校是三段式：
  //   1. GET  /jsxsd/kbxx/jsjy_query         筛选器页面（校区/学期下拉来源）
  //   2. GET  /jsxsd/kbxx/jsjy_processAjax   联动下拉（教学区/教学楼/教室）→ JSON
  //   3. POST /jsxsd/kbxx/jsjy_query2        真正的查询 → 结果表
  //
  // 参考实现那边是「一张整周课表矩阵」，本校是「按条件筛出的列表」；
  // 但结果表的形态相近（星期表头 + 教室 × 节次），因此解析器复用一套。

  /// 空闲教室筛选器页面原文（校区/学期下拉的来源）
  Future<String> getClassroomOptionsHtml() async {
    final HttpResponse res = await _client.get('$kBaseOrigin$kPathClassroom');
    _checkResponse(res);
    return res.body;
  }

  Future<ClassroomOptions> getClassroomOptions() async =>
      parseClassroomOptions(await getClassroomOptionsHtml());

  /// 原文 → 选项。单独暴露是为了让缓存层用同一条解析路径
  /// （缓存里存的是原文，需要解析时用这个，而不是再走一遍网络方法）。
  static ClassroomOptions parseClassroomOptions(String body) =>
      ClassroomOptions(
        ClassroomParser.parseCampuses(body),
        ClassroomParser.parseSemesters(body),
      );

  /// 联动下拉：按校区取教学楼列表。
  ///
  /// ===== 本校不可用（实测）=====
  /// 正常形态是 GET `$kPathClassroomAjax?xqid=…&requestType=jxl`，
  /// 服务器返回 JSON 数组 `[{dm,dmmc},…]`。但本校这道门是关的：
  /// 无论怎么组合请求头（裸请求 / 加 `X-Requested-With` / 加 jQuery 的
  /// JSON `Accept` / 带发起页 Referer / 去掉 Origin / URL 加不加前导 `&`），
  /// 一律回「错误提示页面 / 提示：非法访问！」（HTTP 200，736 字节）。
  ///
  /// 因此**楼栋筛选改在客户端做**：服务端查询不带楼栋参数、返回该校区
  /// 全部教室，界面从结果里的教室名推导楼栋（见 ClassroomFinder.buildingOf
  /// 与 classroom_page 的 _deriveBuildings）。这个方法保留下来仅供
  /// 别校/未来复用，本端不再调用。
  Future<String> getBuildingsHtml(String campusId) async {
    final HttpResponse res = await _client.get(
      '$kBaseOrigin$kPathClassroomAjax?xqid=$campusId&requestType=jxl',
      ajax: true,
      referer: '$kBaseOrigin$kPathClassroom',
    );
    _checkResponse(res);
    return res.body;
  }

  Future<List<ChoiceItem>> getBuildings(String campusId) async =>
      parseBuildings(await getBuildingsHtml(campusId));

  /// 原文 → 教学楼选项。同样单独暴露给缓存层复用。
  static List<ChoiceItem> parseBuildings(String body) {
    final List<ChoiceItem> out = <ChoiceItem>[ChoiceItem('全部教学楼', '')];
    final RegExp re =
        RegExp(r'"dm"\s*:\s*"([^"]*)"\s*,\s*"dmmc"\s*:\s*"([^"]*)"');
    for (final RegExpMatch m in re.allMatches(body)) {
      out.add(ChoiceItem(m.group(2) ?? '', m.group(1) ?? ''));
    }
    return out;
  }

  /// 查询空闲教室。
  ///
  /// ===== 字段取自页面 Form1（少一个就会被判成「非法访问」）=====
  ///   · `typewhere=jszq` 是隐藏字段，**必需** —— 缺它服务端直接回
  ///     非法访问页（实测确认）；
  ///   · `jszt=8` 是「完全空闲」—— 这正是本页要找的；
  ///   · `kbjcmsid` 是「时间模式」，取值来自筛选器页面的下拉。
  ///
  /// 返回**原文**：解析要带 sectionRow（节次决定读哪几列），
  /// 所以缓存层存原文，取出时再按当前 sectionRow 解析。
  Future<String> getClassroomUsageHtml(
    String semester,
    String campusId,
    String buildingId,
    int sectionRow,
  ) async {
    final HttpResponse res = await _client.postForm(
      '$kBaseOrigin$kPathClassroomQuery',
      <FormField>[
        const FormField('typewhere', 'jszq'),
        FormField('xnxqh', semester),
        const FormField('gnq_mh', ''),
        const FormField('jsmc_mh', ''),
        const FormField('syjs0601id', ''),
        FormField('xqbh', campusId),
        const FormField('jxqbh', ''),
        FormField('jxlbh', buildingId),
        const FormField('jsbh', ''),
        const FormField('bjfh', '='),
        const FormField('rnrs', ''),
        // 教室状态留空 = **不限**，返回所选范围内的全部教室及其占用。
        //
        // 早先写 `jszt=8`（「完全空闲」），那是把服务器当筛选用 ——
        // 结果服务端只回「整周完全空闲」的教室，实测全校区只剩 1 间，
        // 而客户端本来就会按 isBusy(day, week) 自己判空闲（见 ClassroomFinder）。
        // 服务端预筛 + 客户端再筛 = 交集，只会把教室越筛越少。
        const FormField('jszt', ''),
        const FormField('zc', ''),
        const FormField('zc2', ''),
        const FormField('xq', ''),
        const FormField('xq2', ''),
        const FormField('jc', ''),
        const FormField('jc2', ''),
        FormField('kbjcmsid', kDefaultSectionModeId),
      ],
    );
    _checkResponse(res);
    return res.body;
  }

  Future<ClassroomResult> getClassroomUsage(
    String semester,
    String campusId,
    String buildingId,
    int sectionRow,
  ) async =>
      ClassroomParser.parseResult(
          await getClassroomUsageHtml(
              semester, campusId, buildingId, sectionRow),
          sectionRow);

  // ==================== 内部 ====================

  /// 业务响应统一校验
  void _checkResponse(HttpResponse res) {
    if (res.statusCode >= 400 && res.header('location').isEmpty) {
      throw AppError(
        ErrKind.server,
        '教务系统响应异常，请稍后重试',
        'http=${res.statusCode}',
      );
    }
    _ensureAuthed(res.body);
    _ensureNotIllegal(res.body);
  }

  /// 「非法访问」页也要当成错误。
  ///
  /// ===== 为什么必须识别它 =====
  /// 本校对「缺必需参数 / 路径不对」的请求，返回的是一个
  /// **HTTP 200** 的普通 HTML：「提示：非法访问！」。
  /// 状态码是 200，所以早先的检查全都放过它 —— 于是调用方拿到一页
  /// 与业务无关的 HTML，解析出空结果，界面显示成
  /// 「暂无数据 / 没有查到教室」。**接口错误被伪装成「真的没有数据」**，
  /// 排查时会一直往解析器方向找，找不到问题。
  ///
  /// 这类响应一律当成服务端错误抛出：宁可让界面显示「教务系统响应异常」，
  /// 也不要静默给出一个看起来正常的空列表。
  void _ensureNotIllegal(String body) {
    if (!body.contains('非法访问')) {
      return;
    }
    throw AppError(
      ErrKind.server,
      '教务系统拒绝了这次请求，请稍后重试',
      'illegal-access page',
    );
  }

  /// 业务请求返回登录页 = 会话确实失效。
  ///
  /// 这里只抛「需要重新验证」，**不退出登录**；由界面在需要时弹重新验证弹窗。
  /// 这样「只看课表」永远安静 —— 课表来自本地缓存，不需要联网。
  void _ensureAuthed(String body) {
    if (!HtmlLite.isLoginPage(body)) {
      return;
    }
    throw AppError(ErrKind.authExpired, '登录状态已失效，需要重新验证');
  }

  /// 按服务端错误原文判定失败类别（保守归类）
  static LoginFailKind _classifyFail(String hint) {
    if (hint.isEmpty) {
      return LoginFailKind.unknown;
    }
    if (hint.contains('验证码')) {
      return LoginFailKind.captcha;
    }
    if (hint.contains('密码') || hint.contains('账号') || hint.contains('用户名')) {
      return LoginFailKind.credential;
    }
    if (hint.contains('会话') || hint.contains('超时')) {
      return LoginFailKind.session;
    }
    return LoginFailKind.unknown;
  }

  static String _extractError(String body) {
    final RegExpMatch? m =
        RegExp(r'id="showMsg"[^>]*>([^<]*)<', caseSensitive: false)
            .firstMatch(body);
    if (m != null) {
      final String t = HtmlLite.decode(m.group(1) ?? '').trim();
      if (t.isNotEmpty) {
        return t;
      }
    }
    if (body.contains('验证码')) {
      return '验证码错误，请重新输入';
    }
    return '';
  }

  static String _absolute(String loc) {
    if (loc.startsWith('http://') || loc.startsWith('https://')) {
      return loc;
    }
    if (loc.startsWith('/')) {
      return '$kBaseOrigin$loc';
    }
    return '$kBaseOrigin/$loc';
  }
}
