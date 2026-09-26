/// Cookie 管理
///
/// 从鸿蒙版 `network/CookieJar.ets` 移植，保留了当时踩过的两个坑的处理。
///
/// ===== 为什么需要自己管 Cookie =====
/// 教务系统的会话是 `JSESSIONID`，而且是 **HttpOnly** 的
/// （页面 JS 读不到 `document.cookie`）。因此：
///   1. 不能靠 WebView 自动带 Cookie，必须在网络层手动接住再回带；
///   2. 登录成功后服务器会**轮换** JSESSIONID，必须用新的替换旧的，
///      否则下一次请求就带着过期会话，表现为「刚登录就掉线」。
///
/// ===== 坑一：Set-Cookie 不是简单的 `name=value` =====
/// 响应里可能带 `Path=/; HttpOnly; SameSite=Lax` 这类属性段。
/// 早期实现把整串按 `name=value` 解析，结果 cookie 名变成了
/// `JSESSIONID; Path`，导致 JSESSIONID 从未真正进入 Cookie 头 ——
/// 症状是「登录接口返回成功，但后续请求全被当成未登录」。
/// 因此这里按 `;` 切分，**第一段一定是 cookie，其余段在命中已知属性名时跳过**。
///
/// ===== 坑二：不能用平行数组 =====
/// 早期用 `names[]` / `values[]` 两个数组分别 push。两个响应并发到达时，
/// 两次 push 会交错，产生 `NAME=undefined` 这种条目。
/// 改用 Map 后天然原子。
library;

/// 已知的 Cookie 属性名（小写比较）。出现在除第一段以外的位置时跳过。
const Set<String> _cookieAttrs = <String>{
  'path',
  'domain',
  'expires',
  'max-age',
  'secure',
  'httponly',
  'samesite',
  'version',
  'comment',
  'commenturl',
  'port',
  'discard',
};

class CookieJar {
  final Map<String, String> _jar = <String, String>{};

  bool get isEmpty => _jar.isEmpty;

  int get length => _jar.length;

  /// 吸收一条 `Set-Cookie` 内容。
  ///
  /// 兼容三种形态：
  ///   - `JSESSIONID=abc; Path=/; HttpOnly`      正常单条
  ///   - `name=value`                            裸键值
  ///   - `JSESSIONID=abc; HttpOnly, SERVERID=1`  **多条合并在一行**
  ///
  /// 值为空表示服务器要删除该 cookie（标准语义）。
  ///
  /// ===== 第三种是本校实际遇到的坑 =====
  /// 服务端（或其前面的反向代理）会把多条 Set-Cookie 用**逗号**拼在一行。
  /// 早先只按 `;` 切分，于是 `HttpOnly, SERVERID=1` 被当成一个整体 ——
  /// 产生一个键名叫 `HttpOnly, SERVERID` 的畸形 cookie，而真正的
  /// `SERVERID` 反而没进 jar。
  ///
  /// 后果不只是「少一个 cookie」：发出去的 `Cookie:` 头里出现
  /// `HttpOnly, SERVERID=1` 这种非法片段，服务端解析该头时可能整条丢弃 ——
  /// 表现为**部分页面一直返回登录页**（另一些页面恰好不校验，一切正常），
  /// 极难定位。实测症状就是这样：课表正常、个人信息读到的却是登录页。
  void absorbOne(String setCookie) {
    if (setCookie.isEmpty) {
      return;
    }
    for (final String one in _splitCombined(setCookie)) {
      _absorbSingle(one);
    }
  }

  /// 把「一行里塞了多条 cookie」拆开。
  ///
  /// 判据：逗号后面紧跟 `名字=` 形态（名字不含空格与等号）才算新的一条。
  ///
  /// 为什么不能简单 `split(',')`：`Expires` 属性里也有逗号
  /// （`Expires=Wed, 21 Oct 2026 07:28:00 GMT`），直接切会把日期劈成两半。
  /// 用「逗号 + `token=`」就能避开 —— 日期那段的逗号后面是 ` 21 Oct…`，
  /// 不是合法的 cookie 名。
  static List<String> _splitCombined(String raw) {
    final List<String> out = <String>[];
    final RegExp sep = RegExp(r',\s*(?=[A-Za-z0-9_\-]+\s*=)');
    int start = 0;
    for (final RegExpMatch m in sep.allMatches(raw)) {
      out.add(raw.substring(start, m.start));
      start = m.end;
    }
    out.add(raw.substring(start));
    return out;
  }

  /// 吸收单条 cookie 的 `name=value; attrs…`
  void _absorbSingle(String setCookie) {
    final List<String> segs = setCookie.split(';');
    for (int i = 0; i < segs.length; i++) {
      final String seg = segs[i].trim();
      if (seg.isEmpty) {
        continue;
      }
      // 只在非首段跳过属性；首段即使名字形似属性也必须当 cookie
      // （极少数服务器会把值写成 "path" 这种词）。
      if (i > 0) {
        final int eq = seg.indexOf('=');
        final String name = (eq >= 0 ? seg.substring(0, eq) : seg).trim().toLowerCase();
        if (_cookieAttrs.contains(name)) {
          continue;
        }
      }
      final int eq = seg.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      final String name = seg.substring(0, eq).trim();
      final String value = seg.substring(eq + 1).trim();
      if (name.isEmpty) {
        continue;
      }
      if (value.isEmpty) {
        _jar.remove(name);
      } else {
        _jar[name] = value;
      }
    }
  }

  /// 吸收整个响应头里所有 Set-Cookie
  void absorbAll(List<String> setCookies) {
    for (final String c in setCookies) {
      absorbOne(c);
    }
  }

  /// 生成请求用的 Cookie 头；无 cookie 时返回空串（此时不应带该头）
  /// 诊断用：列出持有的 cookie **键名与长度**（绝不打印值 —— 那是会话凭据）。
  ///
  /// 排查「明明登录了却读到登录页」时，第一件要确认的事就是
  /// 「手里到底有哪些 cookie、是不是空的」。
  String debugSummary() {
    if (_jar.isEmpty) {
      return '(空)';
    }
    return _jar.entries
        .map((MapEntry<String, String> e) => '${e.key}:${e.value.length}')
        .join(',');
  }

  String toHeader() {
    if (_jar.isEmpty) {
      return '';
    }
    return _jar.entries.map((MapEntry<String, String> e) => '${e.key}=${e.value}').join('; ');
  }

  /// 序列化用于持久化（就是 Cookie 头本身）
  String serialize() => toHeader();

  /// 从持久化内容恢复
  void deserialize(String raw) {
    _jar.clear();
    if (raw.isEmpty) {
      return;
    }
    for (final String part in raw.split(';')) {
      final String seg = part.trim();
      if (seg.isEmpty) {
        continue;
      }
      final int eq = seg.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      final String name = seg.substring(0, eq).trim();
      final String value = seg.substring(eq + 1).trim();
      if (name.isNotEmpty && value.isNotEmpty) {
        _jar[name] = value;
      }
    }
  }

  void clear() => _jar.clear();

  /// 取某个 cookie 的值（排查用）
  String? get(String name) => _jar[name];

  /// 便于单测与日志：当前所有 cookie 名
  List<String> names() => _jar.keys.toList();
}
