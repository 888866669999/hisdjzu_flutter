/// 登录凭据编码（**山东建筑大学**的 `encoded` 算法）
///
/// ===== 本校与参考实现完全不同，不要照搬 =====
/// 实测从登录页取出的 `encodeInp()` 源码就是**标准 Base64**
/// （与浏览器原生 `btoa` 对 ASCII 输入逐字符一致，已核对）：
///
/// ```js
/// var account = encodeInp(xh);       // Base64(账号)
/// var passwd  = encodeInp(pwd);      // Base64(密码)
/// var encoded = account + "%%%" + passwd;
/// document.getElementById("userPassword").value = pwd;   // 明文也一起提交
/// document.getElementById("loginForm").submit();          // POST /jsxsd/xk/LoginToXk
/// ```
///
/// 三点与参考实现（山财）截然不同：
///   1. **不需要会话握手** —— 山财要先取 `scode#sxh` 再按位插字符；
///      本校直接 Base64，省掉一次往返。
///   2. **密码要原样提交**（不是留空）。页面 JS 明确写了
///      `userPassword.value = pwd`，服务端两者都读。
///      早先按参考实现改成留空，服务端直接回「账号或密码不能为空」。
///   3. 只编码**账号与密码**；验证码 `RANDOMCODE` 保持明文。
///
/// ===== 关于编码表 =====
/// 用 Dart 自带的 `base64` 而不是手抄页面里那份 `keyStr`：
/// 它就是标准字母表（`A-Za-z0-9+/` + `=` 补齐），与页面一致。
/// 手写一份只会在细节上引入难以察觉的差异。
library;

import 'dart:convert';

class QzEncoder {
  /// 构造 `encoded` = `Base64(账号) + "%%%" + Base64(密码)`。
  ///
  /// 返回空串表示参数不合法（账号或密码为空），调用方应直接报错 ——
  /// 用空凭据去打登录接口只会白白记一次失败。
  static String buildEncoded(String account, String password) {
    if (account.isEmpty || password.isEmpty) {
      return '';
    }
    return '${_b64(account)}%%%${_b64(password)}';
  }

  /// 页面里的 `encodeInp` 用 `charCodeAt` 按**单字节**取值；
  /// 账号与密码都是 ASCII（学号是数字、密码是 ASCII 字符），
  /// 因此 UTF-8 编码的结果与页面一致。
  static String _b64(String s) => base64.encode(utf8.encode(s));

  /// 本校**没有**「服务端拒绝登录」的握手表态（因为不握手）。
  ///
  /// 保留这个方法是让调用方代码形状不变（改动面最小），恒返回 false。
  static bool isRejected(String sessText) => false;

  /// 日志用：隐去 ticket，避免一次性凭据进日志
  static String maskTicket(String url) {
    final int i = url.indexOf('ticket=');
    if (i < 0) {
      return url;
    }
    return '${url.substring(0, i + 7)}***';
  }
}
