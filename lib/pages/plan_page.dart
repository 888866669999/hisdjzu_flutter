/// 培养方案页（培养方案 + 修读情况的合并页）
///
/// 由原「培养方案」页与原「通选课修读情况」页合并而来。两页的数据都以
/// 「课程体系」分组，实测两端给出的是同一组体系（11 个），于是按体系名
/// 对齐成一张列表：一个体系一张卡片，卡片里既是该体系的修读进度
/// （应修/已修/在修 + 进度条 + 「设置要求学分」），点开又是两组课程 ——
///   · 培养方案课程：该体系应修的课（原培养方案的可折叠课程表）；
///   · 修读记录：实际已修/在修的课（原通选页展开时才去抓的详情页）。
/// 合并的理由：学生看培养方案时最常接着问的就是「这个体系我还差多少」，
/// 之前要在两页之间来回按体系名对照。
///
/// ===== 两个数据源独立加载（本页最要紧的约束）=====
/// 培养方案（一个请求）与修读情况（另一个请求）各自走缓存、各自报错。
/// 合并页最容易写坏的地方就是「任何一边失败整页空白」——一边失败只少
/// 一块内容，顶部给一条非阻断提示，另一边照常显示。
///
/// ===== 为什么合并后不再有 PDF =====
/// 原页面带「培养方案 PDF 附件」的下载入口（从页面正则出附件路径、
/// 下载到沙箱、再走系统「另存为」）。实测本校的培养方案页面里没有任何
/// 附件（`uploadfile`、`.pdf`、`附件` 均不出现），整套代码只服务一个
/// 本校没有的功能，已整块删除（附件路径解析、data/pdf_store、
/// data/pdf_saver、MainActivity 的 savePdf 方法）。
library;

import 'package:flutter/material.dart';

import '../common/constants.dart';
import '../common/result.dart';
import '../data/app_state.dart';
import '../data/elective_requirement_store.dart';
import '../data/page_cache.dart';
import '../data/re_auth_service.dart';
import '../model/models.dart';
import '../parser/elective_parser.dart';
import '../parser/plan_parser.dart';
import '../theme/glass_kit.dart';
import '../theme/theme.dart';
import '../widgets/app_refresh.dart';
import '../widgets/requirement_editor_dialog.dart';
import '../widgets/state_views.dart';
import '../widgets/top_fade_blur.dart';

class PlanPage extends StatefulWidget {
  const PlanPage({super.key});

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  final AppState _app = AppState.instance;

  // ---------- 培养方案侧 ----------
  bool _planLoading = true;
  String _planError = '';
  PlanDetail? _detail;

  // ---------- 修读情况侧 ----------
  bool _electiveLoading = true;
  String _electiveError = '';
  ElectiveReport? _report;

  /// 修读情况分组（已叠加用户自录的要求学分）。
  ///
  /// 存下来而不是每次 build 现算：用户改过要求学分后要能**就地更新**
  /// 这一项并立刻反映到界面，不必为了一个数字再请求一次服务器。
  List<ElectiveGroup> _electiveGroups = <ElectiveGroup>[];

  /// 已展开的分组（按归一后的体系名记）。
  ///
  /// 存「展开」而不是「收起」：空集即**全部收起**，这正是期望的默认值 ——
  /// 一份 10 门课的分组一进页面就铺满好几屏，得先滚很久才看得到下一个。
  final Set<String> _expanded = <String>{};

  /// 正在按需抓课程明细的体系名（显示加载态）。
  ///
  /// 明细要**逐个按需**去抓（见 `_ensureCourses`），同一时刻通常只有一个；
  /// 用集合而不是单个字符串，是为了让用户快速连点几个体系时每个都能显示
  /// 自己的加载态、互不覆盖。
  final Set<String> _loadingCourses = <String>{};

  /// 页面级操作提示（保存要求学分的结果、明细抓取失败）。
  ///
  /// 为什么不用 SnackBar：本应用的壳是 `GlassScaffold`（内部
  /// `CupertinoPageScaffold`），树里**没有 Material 的 `Scaffold`**。
  /// `ScaffoldMessenger` 本身存在（`MaterialApp` 会建），但它的
  /// `showSnackBar` 断言「必须有已注册的 Scaffold」—— 缺了就 debug 抛断言、
  /// release 下静默不显示。改成页面自己的提示条，与设置页那种
  /// 「顶部一条横幅」的做法一致。
  String _hint = '';

  @override
  void initState() {
    super.initState();
    // 先用两个来源的内存缓存填首帧，再决定要不要联网（切页回来不闪加载态）
    _detail = _planLoader().peek();
    final ElectiveReport? cached = _electiveLoader().peek();
    if (cached != null) {
      _applyReport(cached);
    }
    // 「用户点导航进来」这个标记只取一次、两个加载共用：
    // 一次导航会发两个请求，不能只让其中一个有资格触发续期弹窗
    // （否则会话失效时续期失败，修读情况那侧会当自己是自动加载而保持沉默）。
    final bool interactive = ReAuthService.consumeUserIntent();
    _loadPlan(interactive: interactive);
    _loadElective(interactive: interactive);
  }

  PageDataLoader<PlanDetail> _planLoader() => PageDataLoader<PlanDetail>(
        key: PageCache.keyOf(AppState.instance.account, kCachePlan),
        fetch: _app.api.getPlanHtml,
        parse: PlanParser.parse,
        ttl: kTtlPlan,
      );

  PageDataLoader<ElectiveReport> _electiveLoader() =>
      PageDataLoader<ElectiveReport>(
        key: PageCache.keyOf(AppState.instance.account, kCacheElective),
        fetch: _app.api.getElectiveHtml,
        parse: ElectiveParser.parse,
        ttl: kTtlElective,
      );

  /// 归并分组 + 叠加用户自录要求，写进页面状态。
  ///
  /// 两件事分开做：`grouped()` 是纯计算（可单测），读本地配置是 IO ——
  /// 混在一起那个纯函数就不纯了。
  void _applyReport(ElectiveReport r) {
    final List<ElectiveGroup> groups = r.grouped();
    _applyCustomRequirements(groups);
    _report = r;
    _electiveGroups = groups;
  }

  /// 把用户自录的要求学分叠加到分组上（必须在 `grouped()` 之后单独做一步）。
  void _applyCustomRequirements(List<ElectiveGroup> groups) {
    final Map<String, double> saved =
        ElectiveRequirementStore.load(AppState.instance.account);
    if (saved.isEmpty) {
      return;
    }
    for (final ElectiveGroup g in groups) {
      final double? v = saved[g.name];
      if (v != null) {
        g.customRequired = v;
      }
    }
  }

  // ==================== 两个来源各自的加载 ====================
  //
  // 结构完全对称：先清自己的错误、拉数据、成功替换、失败走会话续期。
  // 刻意不共用一份状态 —— 共用的话一边失败会把另一边的错误/加载态也搅乱，
  // 而「互不影响」正是这次合并的硬要求。

  Future<void> _loadPlan({bool interactive = false, bool force = false}) async {
    // 已有内容时不铺整屏加载态：切页回来该立刻看到旧数据，新数据到了再替换
    setState(() {
      _planError = '';
      if (_detail == null) {
        _planLoading = true;
      }
    });
    try {
      final PageLoadResult<PlanDetail> r = await _planLoader().load(force: force);
      if (!mounted) {
        return;
      }
      setState(() {
        _detail = r.data;
        _planLoading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      // 会话失效时**先尝试静默续期**（用已保存的账号密码 + OCR 自动登录），
      // 成功就直接重载，用户完全无感；只有续期也失败才置弹窗标记。
      final bool renewed = await ReAuthService.handlePageError(e, (String msg) {
        setState(() {
          _planLoading = false;
          _planError = msg;
        });
      }, interactive: interactive);
      if (renewed && mounted) {
        await _loadPlan(force: force);
      }
    }
  }

  Future<void> _loadElective(
      {bool interactive = false, bool force = false}) async {
    setState(() {
      _electiveError = '';
      if (_report == null) {
        _electiveLoading = true;
      }
    });
    try {
      final PageLoadResult<ElectiveReport> r =
          await _electiveLoader().load(force: force);
      if (!mounted) {
        return;
      }
      setState(() {
        _applyReport(r.data);
        _electiveLoading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      final bool renewed = await ReAuthService.handlePageError(e, (String msg) {
        setState(() {
          _electiveLoading = false;
          _electiveError = msg;
        });
      }, interactive: interactive);
      if (renewed && mounted) {
        await _loadElective(force: force);
      }
    }
  }

  /// 下拉 / 重试：两个来源一起刷新。
  ///
  /// 两个 `_load*` 自己消化异常（末尾的 catch 不向外抛），因此这里
  /// `Future.wait` 不会因为一边失败而把另一边也中断。
  Future<void> _refreshAll() async {
    await Future.wait<void>(<Future<void>>[
      _loadPlan(force: true),
      _loadElective(force: true),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final PlanDetail? d = _detail;
    final bool hasPlan =
        d != null && !(d.courses.isEmpty && d.introParagraphs.isEmpty);
    final bool hasElective = _electiveGroups.isNotEmpty;

    // 只要**任一**来源有内容就渲染列表：刷新/加载失败只在列表顶部提示。
    // 整屏替换会把用户已经在看的另一边内容也清掉 —— 培养方案是基本不变的
    // 数据，修读情况也是历史累计，都没有「失败就整页变空」的道理。
    if (hasPlan || hasElective) {
      return Stack(
        children: <Widget>[
          Positioned.fill(
            child: AppRefresh(onRefresh: _refreshAll, child: _buildList(d)),
          ),
          const TopFadeBlur(),
        ],
      );
    }
    if (_planLoading || _electiveLoading) {
      return const RefreshableFill(child: LoadingView(message: '正在获取培养方案…'));
    }
    // 两边都不再加载、也都没有内容：错误优先，其次是「确实没有数据」
    final String msg = <String>[
      if (_planError.isNotEmpty) _planError,
      if (_electiveError.isNotEmpty) _electiveError,
    ].join('\n');
    if (msg.isEmpty) {
      // 两个请求都成功但都是空的（服务器上确实没有）：下拉仍然重新请求
      return AppRefresh(
        onRefresh: _refreshAll,
        child: const RefreshableFill(child: EmptyView(title: '暂无培养方案数据')),
      );
    }
    return AppRefresh(
      onRefresh: _refreshAll,
      child: RefreshableFill(
        child: ErrorView(
            message: msg,
            onRetry: () {
              _loadPlan(interactive: true, force: true);
              _loadElective(interactive: true, force: true);
            }),
      ),
    );
  }

  /// 归并后的分组（培养方案顺序优先，修读侧多出的追加在后）。
  ///
  /// 每次 build 现算：纯计算，而用户的操作（展开、保存要求）都是就地改
  /// 同一批对象，现算才能立刻反映。
  List<MergedPlanGroup> _mergedGroups() => mergePlanAndElective(
        _detail?.groups ?? const <PlanGroup>[],
        _electiveGroups,
      );

  /// 页面主体列表（原 build 的内容，抽出以便被 Stack 包裹）
  Widget _buildList(PlanDetail? d) {
    return ListView(
      // 内容不满一屏也要能下拉刷新
      physics: const AlwaysScrollableScrollPhysics(),
      // 底部额外留出玻璃导航栏的高度：extendBody 后内容会滚到 dock 下面，
      // 不留这段空白最后一项会被玻璃压住
      // 顶部让位放在**滚动内容**里（不是视口上），因此首项仍从顶栏下
      // 开始，而滚动时内容会经过顶栏区域、被顶部渐变模糊糊掉。
      // 外壳已对本页跳过它自己的让位，见 shell.dart 的 pageHandlesTopInset。
      padding: EdgeInsets.fromLTRB(Gaps.page, appBarInset(context) + Gaps.page,
          Gaps.page, Gaps.page + Gaps.scrollTail),
      children: <Widget>[
        // 操作结果提示（成功/失败都走这里，可点掉）
        if (_hint.isNotEmpty) ...<Widget>[
          _hintBanner(),
          const SizedBox(height: Gaps.m),
        ],
        // 有缓存内容但这次刷新失败：提示一下，但**不**清掉内容。
        // 两个来源分别报，谁失败就点谁的名 —— 只写「刷新失败」会让人
        // 分不清是培养方案没了还是修读情况没了。
        if (_planError.isNotEmpty || _electiveError.isNotEmpty) ...<Widget>[
          _staleBanner(),
          const SizedBox(height: Gaps.m),
        ],
        if (d != null &&
            (d.introParagraphs.isNotEmpty || d.detailParagraphs.isNotEmpty))
          _introCard(d),
        _summaryCard(d),
        const SizedBox(height: Gaps.m),
        Text('课程设置总表',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: context.textPrimary,
            )),
        const SizedBox(height: 8),
        for (final MergedPlanGroup g in _mergedGroups()) ...<Widget>[
          _groupCard(g),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: Gaps.s),
        Text('点分组标题可展开培养方案课程与修读记录',
            style: TextStyle(fontSize: 11, color: context.textTertiary)),
      ],
    );
  }

  /// 操作结果提示条：可点掉，与设置页的提示条同一形态
  Widget _hintBanner() {
    return GestureDetector(
      onTap: () => setState(() => _hint = ''),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.brandColor.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          _hint,
          style: TextStyle(fontSize: 12, color: context.brandColor),
        ),
      ),
    );
  }

  /// 「刷新失败，以下是已有内容」提示条（哪个来源失败就写哪个）
  Widget _staleBanner() {
    final List<String> parts = <String>[
      if (_planError.isNotEmpty) '培养方案：$_planError',
      if (_electiveError.isNotEmpty) '修读情况：$_electiveError',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.warningColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        parts.join('\n'),
        style: TextStyle(fontSize: 12, color: context.textSecondary),
      ),
    );
  }

  Widget _introCard(PlanDetail d) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('培养目标',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: context.textPrimary,
              )),
          const SizedBox(height: 8),
          for (final String p in <String>[...d.introParagraphs, ...d.detailParagraphs])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                p,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: context.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 顶部总览：培养方案一行（门数/学分/学时），修读情况一行（已修/在修/体系数）。
  ///
  /// 两块各自独立：哪一边的数据没拿到（或本身就是空的）就少哪一行，
  /// 另一边照常显示 —— 修读情况那侧有数据时，方案侧的空值不能显示成
  /// 一排 0，那会让人以为「培养方案有 0 门课」而不是「这次没取到」。
  Widget _summaryCard(PlanDetail? d) {
    Widget cell(String v, String label) => Expanded(
          child: Column(
            children: <Widget>[
              Text(v,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  )),
              Text(label,
                  style: TextStyle(fontSize: 11, color: context.textTertiary)),
            ],
          ),
        );
    final bool showPlan = d != null && d.courses.isNotEmpty;
    final bool showElective = _report != null && _electiveGroups.isNotEmpty;
    if (!showPlan && !showElective) {
      return const SizedBox.shrink();
    }
    final ElectiveReport r = _report ?? ElectiveReport();
    return SectionCard(
      child: Column(
        children: <Widget>[
          if (showPlan)
            Row(
              children: <Widget>[
                cell('${d.courses.length}', '门课程'),
                cell(_trimNum(d.totalCredit), '总学分'),
                cell(_trimNum(d.totalHours), '总学时'),
              ],
            ),
          if (showPlan && showElective) ...[
            const SizedBox(height: 10),
            Divider(height: 1, color: context.dividerColor),
            const SizedBox(height: 10),
          ],
          if (showElective)
            Row(
              children: <Widget>[
                cell(r.totalEarned.isEmpty ? '—' : r.totalEarned, '已修学分'),
                cell(r.totalOngoing.isEmpty ? '—' : r.totalOngoing, '正在修读'),
                // 这里**不显示「门课程」**：修读情况那一页本身不含课程明细
                // （明细在按需拉取的「详情」页里），该值恒为 0；而上一行
                // 已经给出了培养方案的课程门数。两个「门课程」并列时，
                // 一个 89、一个 0，看着像数据缺失，实际是重复指标。
                cell('${_electiveGroups.length}', '个体系'),
              ],
            ),
        ],
      ),
    );
  }

  /// 去掉无意义的小数尾巴：12.0 显示成 12
  static String _trimNum(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  /// 体系状态文案。
  ///
  /// **只看 `requiredNumber`**（它已经把「用户自录 > 服务器」的优先级算在内），
  /// 不要再单独判断 `info.hasRequirement` —— 用户自录了要求、而学校那一列是空时，
  /// 那个判断仍会成立，于是状态显示「请设置学分要求」、副标题却已经写着
  /// 「要求 ≥ X」，自相矛盾（实测踩到过）。
  ({String text, Color color}) _status(ElectiveGroup g) {
    // 没有要求时给一句行动指引。学校那一列实测是空的，「没有要求」是常态
    // 而非异常 —— 与其陈述「学校未设置」这个事实，不如告诉用户下一步能做什么。
    final double req = g.requiredNumber;
    if (req < 0) {
      return (text: '请设置学分要求', color: context.brandColor);
    }
    if (g.earnedNumber + g.ongoingNumber >= req) {
      return (text: '已达标', color: context.successColor);
    }
    return (
      text: '还差 ${(req - g.earnedNumber - g.ongoingNumber).toStringAsFixed(1)}',
      color: context.warningColor,
    );
  }

  /// 已修/在修/要求 一行。要求学分的来源要标出来：
  /// 用户自录的显示为「要求 ≥ X」，学校给了值的显示为「学校要求 ≥ X」，
  /// 都没有则只陈述已修/在修（「去设置」的指引交给状态位与左侧按钮）。
  String _statsLine(ElectiveGroup g) {
    final ElectiveCategory? c = g.info;
    final String earned = (c?.earned.isNotEmpty ?? false) ? c!.earned : '0';
    final String ongoing = (c?.ongoing.isNotEmpty ?? false) ? c!.ongoing : '0';
    String sub = '已修 $earned · 在修 $ongoing';
    if (g.hasCustomRequired) {
      sub += ' · 要求 ≥ ${_trimNum(g.requiredNumber)}';
    } else if (g.requiredNumber >= 0) {
      sub += ' · 学校要求 ≥ ${_trimNum(g.requiredNumber)}';
    }
    return sub;
  }

  // ==================== 分组卡片 ====================

  Widget _groupCard(MergedPlanGroup mg) {
    final PlanGroup? p = mg.plan;
    final ElectiveGroup? e = mg.elective;
    final bool open = _expanded.contains(mg.name);
    // ===== 可展开的判据 =====
    // 方案侧有课程，或修读明细「还没取过 / 取到了课程」。明细要按需去抓
    // （见 _ensureCourses），首次进来所有人都还没加载 —— 只看 hasCourses
    // 会让每个体系都点不开。
    final bool expandable = (p != null && p.courses.isNotEmpty) ||
        (e != null && (e.hasCourses || !e.coursesLoaded));
    final bool loadingCourses = e != null && _loadingCourses.contains(e.name);
    final ({String text, Color color})? st = e == null ? null : _status(e);

    return SectionCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 标题行整体可点：展开/收起该体系的课程
          InkWell(
            onTap: expandable ? () => _toggle(mg) : null,
            borderRadius: BorderRadius.circular(Gaps.radius),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gaps.m, Gaps.m, 8, Gaps.m),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(mg.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: context.textPrimary,
                            )),
                      ),
                      // 方案侧：门数与学分（原培养方案卡片右上角那一截）
                      if (p != null)
                        Text('${p.courses.length} 门 · ${_trimNum(p.totalCredit)} 学分',
                            style: TextStyle(
                                fontSize: 11, color: context.textTertiary)),
                      // 修读侧：达标状态（原通选卡片右上角那一截）
                      if (st != null) ...<Widget>[
                        const SizedBox(width: 8),
                        Text(st.text,
                            style: TextStyle(fontSize: 12, color: st.color)),
                      ],
                      if (expandable) ...<Widget>[
                        const SizedBox(width: 2),
                        // 收起时朝下（提示「点开」），展开时朝上（提示「收起」）
                        Icon(open ? Icons.expand_less : Icons.expand_more,
                            size: 18, color: context.textTertiary),
                      ] else
                        const SizedBox(width: 24),
                    ],
                  ),
                  // 培养方案格里附带的注记（如 `(应修 10 / 已修 6.5)`）：
                  // 归一后名字单独作标题，注记单独一行 —— 它是真实数字，不丢
                  if (mg.planNote.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(mg.planNote,
                        style:
                            TextStyle(fontSize: 11, color: context.textTertiary)),
                  ],
                  if (e != null) ...<Widget>[
                    const SizedBox(height: 6),
                    // 这一行刻意分成两个互不嵌套的可点区域：
                    // 上面那块负责展开/收起，这里放「设置/修改要求」按钮 +
                    // 学分统计。按钮在**左**、统计在右：按钮是行动入口，放左侧
                    // 更容易被扫到，也让各卡片的按钮纵向对齐；统计是结果，退到右边。
                    Row(
                      children: <Widget>[
                        // 药丸玻璃按钮，与弹窗里的次级按钮同一套语言
                        GlassKit.fieldBackdrop(
                          context,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(999),
                            onTap: () => _editRequirement(e, mg.name),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Icon(Icons.edit_outlined,
                                      size: 13, color: context.brandColor),
                                  const SizedBox(width: 3),
                                  Text(
                                    e.hasCustomRequired ? '修改要求' : '设置要求学分',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: context.brandColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_statsLine(e),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11, color: context.textTertiary)),
                        ),
                      ],
                    ),
                    // 只有有分母时才画进度条（学校会留空要求学分）
                    if (e.canShowProgress) ...<Widget>[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: ((e.earnedNumber + e.ongoingNumber) /
                                  e.requiredNumber)
                              .clamp(0.0, 1.0),
                          minHeight: 5,
                          backgroundColor: context.surfaceVariant,
                          color: (e.earnedNumber + e.ongoingNumber) >=
                                  e.requiredNumber
                              ? context.successColor
                              : context.brandColor,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          if (open) ...<Widget>[
            Divider(height: 1, color: context.dividerColor),
            // ---- 培养方案课程（保留原培养方案的「选课组 → 课程」层级）----
            if (p != null && p.courses.isNotEmpty) ...<Widget>[
              _sectionLabel('培养方案课程'),
              ..._planRows(p),
            ],
            // ---- 实际修读的课程（展开时才去抓详情页）----
            if (e != null) ...<Widget>[
              _sectionLabel('修读记录'),
              if (loadingCourses)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: context.brandColor),
                    ),
                  ),
                )
              else if (e.courses.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: Gaps.m, vertical: 12),
                  child: Text(
                    '该体系下暂无修读记录',
                    style: TextStyle(fontSize: 12, color: context.textTertiary),
                  ),
                )
              else
                for (int i = 0; i < e.courses.length; i++) ...<Widget>[
                  if (i > 0) Divider(height: 1, color: context.dividerColor),
                  _electiveCourseRow(e.courses[i]),
                ],
            ],
          ],
        ],
      ),
    );
  }

  /// 展开/收起一个分组；首次展开时顺手去抓修读明细
  void _toggle(MergedPlanGroup mg) {
    final bool open = _expanded.contains(mg.name);
    setState(() {
      if (open) {
        _expanded.remove(mg.name);
      } else {
        _expanded.add(mg.name);
      }
    });
    // 明细还没取过才去抓（取过则直接用，不重复打请求；失败后不设标记，
    // 再次展开还能重试）
    if (!open && mg.elective != null) {
      _ensureCourses(mg.elective!);
    }
  }

  /// 按需拉取某个体系的课程明细。
  ///
  /// 本校的通选主页只有学分统计，课程明细在**另一个页面**：每行的「详情」是
  /// `window.open('/jsxsd/xxwcqk/xxwcqkOnkctxByxq.do?kctxmc=…')`。
  /// 该地址可直接 GET，因此只在用户**展开时**才去抓 ——
  /// 首屏不为 11 个体系打 11 个请求，用户不关心的体系一个请求都不发。
  ///
  /// 查询用体系裸名（[systemMergeKey]）：页面自己的「详情」链接就是裸名，
  /// 名称里的 `(属性)` 后缀不属于 kctxmc。
  ///
  /// 失败只提示、不整屏报错：明细是展开后的补充信息，
  /// 拿不到不该把已经看到的进度统计一起换掉。
  Future<void> _ensureCourses(ElectiveGroup g) async {
    if (g.coursesLoaded || _loadingCourses.contains(g.name)) {
      return;
    }
    setState(() => _loadingCourses.add(g.name));
    try {
      final List<ElectiveCourse> list = await AppState.instance.api
          .getElectiveCourses(systemMergeKey(g.name));
      if (!mounted) {
        return;
      }
      setState(() {
        g.courses
          ..clear()
          ..addAll(list);
        // 取过就标记，避免每次展开都重抓；空结果也算取过（确实没有）
        g.coursesLoaded = true;
        _loadingCourses.remove(g.name);
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingCourses.remove(g.name);
        // 不设 coursesLoaded：下次展开可以再试一次
        _hint = AppError.describe(e);
      });
    }
  }

  /// 打开「要求学分」编辑弹窗，保存后**就地更新**（不重新联网）。
  ///
  /// [displayName] 是归一后的体系名（卡片标题那份），只用于弹窗展示；
  /// **存储键仍用 [ElectiveGroup.name] 原始值** —— 旧版通选页存的就是
  /// 带 `(必修)` 后缀的原名，换键会让用户已录的要求全部失配（要重录一遍）。
  Future<void> _editRequirement(ElectiveGroup g, String displayName) async {
    final RequirementEditResult? r = await showRequirementEditor(
      context,
      category: displayName,
      current: g.requiredNumber,
      hasCustom: g.hasCustomRequired,
    );
    if (r == null || !mounted) {
      return; // 用户取消
    }
    final String account = AppState.instance.account;
    if (account.isEmpty) {
      setState(() => _hint = '未获取到账号，无法保存');
      return;
    }
    final bool ok = await ElectiveRequirementStore.save(
      account,
      g.name,
      r.isClear ? -1 : r.value,
    );
    if (!mounted) {
      return;
    }
    if (!ok) {
      setState(() => _hint = '保存失败，请重试');
      return;
    }
    // 就地更新内存里的值，避免为了一个数字再请求一次服务器。
    //
    // 两件事都要做，缺一不可：
    //   1. 改**这个对象**的字段 —— 界面读的是它；
    //   2. 换一个**新列表** —— 只改字段不换列表时，Flutter 侧的可变字段
    //      改动虽然能被 setState 带出去，但保持「结构变化就换新容器」这个
    //      习惯更稳（与课程编辑、课表编辑的持久化路径一致）。
    g.customRequired = r.isClear ? -1 : r.value;
    setState(() {
      _electiveGroups = List<ElectiveGroup>.of(_electiveGroups);
      _hint = '';
    });
  }

  /// 小节标题（「培养方案课程 / 修读记录」），与分组卡片的标题拉开层级
  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gaps.m, 10, Gaps.m, 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.textSecondary,
        ),
      ),
    );
  }

  /// 把方案课程按**选课组**铺开（有组名时插一行小标题）。
  ///
  /// 网页上的表格是「课程体系 → 选课组 → 课程」三级，应用这里照它的层级
  /// 显示。但**本校的选课组列是空的**（学校没录入），因此按「有组名才插入
  /// 小标题」处理：全空时不出现任何多余层级，有值时自动出现。
  /// 保持原始顺序（不重排），与网页上看到的顺序一致。
  List<Widget> _planRows(PlanGroup g) {
    final List<Widget> out = <Widget>[];
    String lastGroup = '';
    for (final PlanCourse c in g.courses) {
      final String grp = c.group.trim();
      if (grp.isNotEmpty && grp != lastGroup) {
        out.add(_subGroupHeader(grp));
        lastGroup = grp;
      }
      out.add(_planCourseRow(c));
    }
    return out;
  }

  /// 选课组小标题（缩进 + 更淡的底色，与「课程体系」拉开层级）
  Widget _subGroupHeader(String name) {
    return Container(
      width: double.infinity,
      color: context.surfaceVariant.withValues(alpha: 0.5),
      padding: const EdgeInsets.only(
          left: Gaps.l, right: Gaps.m, top: 8, bottom: 8),
      child: Text(name,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: context.textSecondary,
          )),
    );
  }

  Widget _planCourseRow(PlanCourse c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gaps.m, vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(c.courseName,
                    style: TextStyle(
                        fontSize: 14, color: context.textPrimary)),
                const SizedBox(height: 3),
                Row(
                  children: <Widget>[
                    if (c.courseCode.isNotEmpty)
                      Text(c.courseCode,
                          style: TextStyle(
                              fontSize: 11, color: context.textTertiary)),
                    if (c.semester.isNotEmpty) ...<Widget>[
                      const SizedBox(width: 8),
                      Text('第${c.semester}学期',
                          style: TextStyle(
                              fontSize: 11, color: context.textTertiary)),
                    ],
                    if (c.category.isNotEmpty) ...<Widget>[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: context.surfaceVariant,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(c.category,
                            style: TextStyle(
                                fontSize: 10, color: context.textSecondary)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Text('${c.credit} 学分',
              style: TextStyle(fontSize: 13, color: context.textSecondary)),
        ],
      ),
    );
  }

  Widget _electiveCourseRow(ElectiveCourse c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gaps.m, vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(c.courseName,
                    style:
                        TextStyle(fontSize: 14, color: context.textPrimary)),
                if (c.courseCode.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(c.courseCode,
                      style:
                          TextStyle(fontSize: 11, color: context.textTertiary)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              if (c.credit.isNotEmpty)
                Text('${c.credit} 学分',
                    style: TextStyle(
                        fontSize: 12, color: context.textSecondary)),
              Text(
                c.isOngoing ? '在修' : c.score,
                style: TextStyle(
                  fontSize: c.isOngoing ? 12 : 15,
                  fontWeight: c.isOngoing ? FontWeight.w400 : FontWeight.w600,
                  color: c.isOngoing ? context.brandColor : context.textPrimary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
