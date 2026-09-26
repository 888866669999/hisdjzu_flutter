/// 全局常量：域名、接口路径、断点、节次与作息
///
/// 从鸿蒙版 `common/Constants.ets` 移植。所有取值都经过真实抓包核对，
/// 改动前请先看 docs/技术笔记.md 的「接口与字段」。
library;

/// 教务系统基地址。
///
/// 注意：学校**只提供明文 HTTP**，没有可用的 HTTPS 入口，
/// 因此 Android 侧必须允许明文流量（见 AndroidManifest 的
/// `android:usesCleartextTraffic`），否则请求会被系统直接拦掉。
const String kBaseOrigin = 'http://xjwgl.sdjzu.edu.cn';

/// 登录相关
///
/// ===== 验证码路径必须与登录页**同一个上下文** =====
/// 本校同时存在 `/verifycode.servlet` 与 `/jsxsd/verifycode.servlet` 两个入口，
/// 它们返回**不同的 JSESSIONID、且 Cookie 的 Path 不同**：
///   · `/verifycode.servlet`      → `JSESSIONID=…; Path=/`
///   · `/jsxsd/verifycode.servlet` → `JSESSIONID=…; Path=/jsxsd`
///
/// 用前者取验证码，再提交到 `/jsxsd/xk/LoginToXk` 时，服务端**不认**那个会话，
/// 会换发一个新的 —— 验证码答案随之丢失，表现为**永远报「验证码错误」**
/// （实测：从 Path=/ 的会话访问 /jsxsd/ 会被换新会话；
///  从 Path=/jsxsd 的会话访问则沿用，见 docs/技术笔记.md）。
///
/// 因此取验证码必须用**带 `/jsxsd` 前缀**的那个地址 —— 登录页里的
/// `<img src="/jsxsd/verifycode.servlet">` 就是它。
///
/// 提交登录：`POST /jsxsd/xk/LoginToXk`（取自表单 action），
/// 并带上隐藏字段 `loginMethod=LoginToXk`。
const String kPathCaptcha = '/jsxsd/verifycode.servlet';

/// 登录页本身。取验证码前先访问它一次，以建立 `/jsxsd` 作用域的会话
/// （原因见 qz_api.dart 的 fetchCaptcha）。
const String kPathLoginPage = '/jsxsd/';
const String kPathLogon = '/jsxsd/xk/LoginToXk';

/// 登录表单的隐藏字段（必须一起提交，否则服务端不认这次登录）
const String kLoginMethodName = 'loginMethod';
const String kLoginMethodValue = 'LoginToXk';

/// 登录后的主页（仅用于「会话是否有效」的判断，不做跳转）
const String kPathMain = '/jsxsd/framework/xsMain.htmlx';

/// 业务页面
///
/// ===== 这些路径全部取自本校教务系统的**菜单实测地址** =====
/// 建大用的是新版强智（`xsMain_new_10430.htmlx`），功能路径与旧版
/// （参考实现所在的山财）**大面积不同**。照搬旧路径的结果是统一的
/// 「非法访问」页 —— 它返回 200，所以只能靠内容识别，很容易被当成
/// 「解析失败」而查错方向。
///
/// 下面是逐条比对确认过的对照（左=参考实现/旧，右=本校/新）：
///   个人信息   /grxx/xsxx              → /xsxj/xjxxgl.do
///   成绩查询页 /kscj/cjcx_query        → /kscj/cjcx_frm
///   修读情况   /xxwcqk/xstxkxdqk.do    → /xxwcqk/xxwcqkOnkctxBy.do
///   空教室     /kbcx/kbxx_classroom*   → /kbxx/jsjy_query（筛选器）
///                                        + POST /kbxx/jsjy_query2（结果）
const String kPathTimetable = '/jsxsd/xskb/xskb_list.do';
const String kPathScoreList = '/jsxsd/kscj/cjcx_list';

/// 成绩查询页 —— **学期下拉的来源**（与列表页不是同一个地址）。
///
/// ===== 不能用 `cjcx_frm`（踩过的坑）=====
/// 本校的成绩查询有**两层**：
///   · `/kscj/cjcx_frm`  —— 只是个外壳，里面嵌两个 iframe，**自己没有下拉**；
///   · `/kscj/cjcx_query` —— 真正的查询表单，`kksj`（学期）下拉在这里。
///
/// 早先指向 `cjcx_frm`，于是 `readSemesters` 永远解析出空列表 ——
/// 界面上学期滚轮里只剩「全部学期」一项，用户无法按学期筛选，
/// 而且**没有任何报错**（空列表被当成「服务端没给」静默接受了）。
const String kPathScoreQuery = '/jsxsd/kscj/cjcx_query';

/// 个人信息。
///
/// ===== 本校没有「学籍卡片」页，得用「毕业生信息核对」=====
/// 逐条试过所有候选（每个都拿真实会话请求、看内容）：
///   · `/grxx/xsxx`        → 非法访问（旧版路径，本校没有）
///   · `/xsxj/xjxxgl.do`   → 是「学籍修改申请」列表（序号/审核状态），**且当前无数据**
///   · `/grsz/grsz_xggrxx.do` → 可编辑的修改表单（真实姓名/电话/密码保护）
///   · `/bygl/bysxx`       → **学籍基本信息**：院系/专业/班级/培养层次/
///                            学制/性别/证件类型/证件号/学号/姓名/姓名拼音 ✓
/// 因此取最后这个。名字叫「毕业生信息核对」，但内容就是学籍卡片的字段，
/// 且对非毕业年级同样可访问（本账号是大一，实测有数据）。
const String kPathProfile = '/jsxsd/bygl/bysxx';

const String kPathWeekCalendar = '/jsxsd/jxzl/jxzl_query';

/// 培养方案与完成情况（一张大表，含「课程体系 / 毕业要求学分 / 已修学分」）
const String kPathPlanDetail = '/jsxsd/pyfa/topyfamx';

/// 修读情况（本校叫「学习完成情况查看」）
const String kPathElective = '/jsxsd/xxwcqk/xxwcqkOnkctxBy.do';

/// 空闲教室：筛选器页面（GET）。真正的查询是 POST 到 [kPathClassroomQuery]。
const String kPathClassroom = '/jsxsd/kbxx/jsjy_query';

/// 空闲教室查询结果（**POST**，表单字段见 ClassroomPage 的构造）
const String kPathClassroomQuery = '/jsxsd/kbxx/jsjy_query2';

/// 校区/教学区/教学楼/教室的**联动下拉**（返回 JSON）。
/// `requestType` 取 `jxq`（教学区）/`jxl`（教学楼）/`js`（教室）。
const String kPathClassroomAjax = '/jsxsd/kbxx/jsjy_processAjax';

/// 「默认节次模式」的 id —— 教室查询与课表页的 `kbjcmsid` 参数。
///
/// 取自页面下拉的默认项；换成「考试节次」会是另一个 id。
/// 写死一个常量而不是每次去页面里读：这个值由学校配置、极少变，
/// 而少带它服务端会拒绝查询（`请选择时间模式`）。
const String kDefaultSectionModeId = '6CFDEBADC0D341D885CB8F8970F7528C';

/// 请求超时
const Duration kConnectTimeout = Duration(seconds: 10);
const Duration kReadTimeout = Duration(seconds: 15);

/// 一学期最多周数
/// 周次的**容错上限**（不是学期长度）。
///
/// 用途仅限「挡住脏数据」：服务端偶尔把某行周次写成 99、日期写成 2099 年，
/// 有了上限就不会让它们把界面撑坏。
///
/// **展示与计算学期长度要用 `SemesterCalendarService.activeMaxWeeks()`**
/// （本校实际 22 周）—— 用这个 30 会让学期结束后仍显示第 23…30 周。
const int kMaxWeeks = 30;

/// 开源仓库地址（设置页「关于」组里展示，点按用系统浏览器打开）。
///
/// 只放**本端**（Flutter/Android）仓库：用户装的哪个端，想看的通常就是哪个端的源码。
///
/// ===== 为空时整行不显示 =====
/// 地址写错时用户点开是 404 页 —— 比「没有这一行」更糟（看起来像应用坏了）。
/// 因此这个值只在仓库确实可访问时才填。
const String kRepoUrl = 'https://github.com/888866669999/hisdjzu_flutter';

/// 响应式断点（逻辑像素）。与鸿蒙版保持同一组数值，
/// 便于对照两版布局；Material 3 的窗口尺寸等级也大致落在这两个点上。
const double kBpMedium = 600;
const double kBpLarge = 840;

/// 节次定义：与教务课表行一一对应。
///
/// 时刻取自**教务课表页面行首格**（本校唯一的权威来源，见
/// `data/academic_calendar.dart` 的说明）；这里是与 `kOfficialSections`
/// 内容一致的本地可改副本。
const List<String> kWeekdayLabels = <String>[
  '星期一',
  '星期二',
  '星期三',
  '星期四',
  '星期五',
  '星期六',
  '星期日',
];

/// 节次：索引 → 名称 → 起止时刻
class SectionDef {
  const SectionDef(this.index, this.label, this.start, this.end);

  final int index;
  final String label;
  final String start;
  final String end;
}

const List<SectionDef> kSections = <SectionDef>[
  SectionDef(0, '第一大节', '07:50', '09:25'),
  SectionDef(1, '第二大节', '09:40', '12:05'),
  SectionDef(2, '第三大节', '13:40', '15:15'),
  SectionDef(3, '第四大节', '15:30', '17:05'),
  SectionDef(4, '第五大节', '18:40', '21:05'),
];

/// 节次行数（课表的行数）
const int kSectionRows = 5;

/// 星期列数
const int kWeekdayCols = 7;

// ============ 本地存储键 ============
//
// 与鸿蒙版同名，便于两版对照排查。
const String kKeySessionCookie = 'session_cookie';
const String kKeyAccount = 'remembered_account';
const String kKeyRemember = 'remember_account';
const String kKeyLastSemester = 'last_semester';
const String kKeySemesterStart = 'semester_start_monday';
const String kKeyWeekAlignAt = 'week_align_at';
const String kKeyWeekAlignValue = 'week_align_value';
const String kKeyLastWeek = 'last_timetable_week';

/// 周次选择的「自动跟随本周」标记。
///
/// 为什么需要它：周次有三种状态 —— 自动跟随本周 / 全部 / 指定第 N 周，
/// 而「空串」只能表示其中一种。早先没有这个标记，于是「默认跟随本周」
/// 无法与「用户手动选了全部」区分：一旦把「默认」写成空串，
/// 用户选过「全部」之后就再也回不到自动跟随了。
const String kWeekAuto = 'auto';
const String kKeyLastScoreSemester = 'last_score_semester';

/// 桌面卡片数据快照
const String kKeyCardSnapshot = 'card_snapshot';

/// 桌面卡片的**周级**快照（应用侧留一份）。
///
/// 单独存一份的用途不是渲染（渲染那份走 home_widget 插件的 preferences），
/// 而是让 [CardSnapshotStore.refresh] 能判断「上一次写下的数据里有没有课」——
/// 从而在拿到一张**空表**时跳过写入，不把桌面卡片上的课程抹掉。
const String kKeyCardWeek = 'card_week_snapshot';

/// 节次作息（用户可自定义）
const String kKeySectionTimes = 'section_times';

/// 节次作息**是否被用户手动改过**（`'1'` = 改过）。
///
/// ===== 为什么必须单独存这个标记 =====
/// 早先靠「存储值是否等于包内常量 [kSections]」来判断有没有自定义。
/// 那个判据是错的：官网改了作息后我们会自动同步一次，同步完存储值就
/// **不再等于**包内常量 —— 于是下一次刷新被判成「用户自定义」而跳过，
/// 此后官网再改多少次都同步不进来。设置页还会错误地显示「已自定义」。
///
/// 现在把「谁写的」与「写了什么」分开记：用户在设置里保存时才置位，
/// 自动同步不置位，从而一直保持可同步。
const String kKeySectionTimesCustom = 'section_times_custom';

/// 上课提醒
const String kKeyReminderOn = 'reminder_enabled';
const String kKeyReminderAdvance = 'reminder_advance_min';


/// 外观材质：'m3'（默认）或 'glass'。
///
/// 见 theme/material_style.dart。只影响内容区的表面材质；
/// 底部 dock 与顶部渐变模糊不受它控制。
const String kKeySurfaceStyle = 'surface_style';

/// 用户自录的「通选课各大类要求学分」。
///
/// 学校页面的「要求学分（大于等于）」一列是空的，用户可按培养方案自行录入，
/// 见 data/elective_requirement_store.dart。按账号分片存储。
const String kKeyElectiveRequired = 'elective_required';

/// 校历与作息表的本地存储。
///
/// 作息（[kKeyCampusSections]）来自**课表页**解析（本校教务处不公开作息表），
/// 抓不到时退回内置值。
/// 校历附件地址由**用户自行填写**（见 [kKeyCalendarUrl]）——
/// 本校没有稳定的校历页，教务处是按年份发公告，地址每年都变。
const String kKeyCampusSections = 'campus_sections';
const String kKeyCampusImages = 'campus_images';
const String kKeyCampusImageUrls = 'campus_image_urls';
const String kKeyCampusUpdated = 'campus_updated';
const String kKeyCampusFetchedAt = 'campus_fetched_at';

/// 用户填写的**校历页地址**（空串 = 还没填）。
///
/// ===== 为什么是用户填而不是内置 =====
/// 本校教务处的校历是按年份发的公告（「山东建筑大学 2026 年校历」），
/// 地址里带内容 id，**每年都不一样**，且挂的是 PDF 而非图片。
/// 内置一个「当前年份」的地址，换年就静默失效 —— 而界面上看不出来，
/// 属于最危险的那类失败。改成用户填写后：
///   - 应用不假设任何具体网址，不会因学校改版而失效；
///   - 用户自己知道要看哪一年，也知道去哪里找（设置页给了引导入口）。
const String kKeyCalendarUrl = 'calendar_page_url';

/// 教务处「信息公开」列表页 —— 校历公告的**入口**，不是校历本身。
///
/// 只用来在设置页给一个「去哪儿找」的直达按钮：本校的校历按年份发公告，
/// 地址每年都变，应用无法预知当年那篇的地址。用户点开这个列表、
/// 找到当年那篇、把地址粘回应用即可。
///
/// 这是**唯一**内置的校历相关网址，且只用于「打开浏览器让用户自己看」——
/// 抓取永远只抓用户填的那个地址，不碰这里。
const String kCalendarIndexUrl =
    'https://www.sdjzu.edu.cn/jwc/xxgk.htm';


/// 上次「因系统时间已超出周历而自动拉取」的日期（`yyyy-MM-dd`）。
///
/// 用于把这种自动拉取限制为**每天一次**：触发条件（今天晚于周历最后一周）
/// 在放假期间持续成立，不限制就会每次启动/每次打开校历都联网。
const String kKeySemesterAutoFetchDay = 'semester_auto_fetch_day';

/// 周次与系统时间对齐的最小间隔（6 小时）
const Duration kWeekAlignInterval = Duration(hours: 6);

// ==================== 页面缓存 ====================
//
// 见 data/page_cache.dart。这里只放「缓存标识」与「新鲜期」。
// 集中定义的原因：这些值需要能一眼横向对比 —— 哪个页面缓存久、哪个短；
// 散在各页面里就只能一个个翻着看。

/// 缓存标识：页面名（参与缓存 key，不要随意改名，否则旧缓存会失配）
const String kCacheScoreList = 'score_list';
const String kCacheScoreSemesters = 'score_semesters';
const String kCachePlan = 'plan';
const String kCacheElective = 'elective';
const String kCacheProfile = 'profile';
const String kCacheClassroomOptions = 'classroom_options';
const String kCacheClassroomBuildings = 'classroom_buildings';
const String kCacheClassroomUsage = 'classroom_usage';
const String kCacheSemesterCalendar = 'semester_calendar';
const String kCacheSemesterList = 'semester_list';

/// 页面缓存的新鲜期（TTL）。
///
/// ===== 这些值是怎么定的 =====
/// 判据是「数据多久可能变一次」与「重复请求的代价」两者取平衡：
///   - **成绩 2 分钟**：出分时段学生会反复进来刷。2 分钟内连着切 tab
///     明显是同一件事的重复操作，没必要每次都打服务器；
///     超过 2 分钟又确实可能出新成绩，所以不能更长。
///   - **通选 10 分钟**：修读进度变动不频繁（一学期就那几门课）。
///   - **培养方案 / 个人信息 6 小时**：一学年才可能调整一次，
///     同一天内反复请求纯属浪费。培养方案页面还最大（70KB），
///     省下的流量最可观。
///   - **空教室**：选项（校区/学期/教学楼）是静态配置，给 6 小时；
///     查询结果反映「此刻哪间教室空着」，按节次变化，只给 2 分钟
///     且**仅做内存缓存**（见 classroom_page 的说明）。
///
/// 宁可偏保守（短）：实机观察后可调，而调长的风险只是多几次请求，
/// 调太长才会让用户看到过期数据。
const Duration kTtlScoreList = Duration(minutes: 2);
const Duration kTtlScoreSemesters = Duration(hours: 6);
const Duration kTtlElective = Duration(minutes: 10);
const Duration kTtlPlan = Duration(hours: 6);
const Duration kTtlProfile = Duration(hours: 6);
const Duration kTtlClassroomOptions = Duration(hours: 6);
const Duration kTtlClassroomBuildings = Duration(hours: 6);
const Duration kTtlClassroomUsage = Duration(minutes: 2);
const Duration kTtlSemesterCalendar = Duration(hours: 6);
const Duration kTtlSemesterList = Duration(hours: 6);
