/// 登录凭据编码测试
///
/// ===== 为什么这一条必须有测试 =====
/// `encoded` 是登录能否成功的关键，而它**各校算法完全不同**：
///   · 参考实现（山财）：先握手拿 `scode#sxh`，再按位插字符；
///   · 本校（建大）：标准 Base64，账号与密码各编一次、用 `%%%` 拼起来。
///
/// 移植时直接照搬了山财的算法，结果登录永远失败，而且**报错信息是
/// 「账号或密码不能为空」** —— 完全指不到真正的原因（字段其实都发了，
/// 只是 encoded 的算法不对、服务端解不出来）。这一条测试就是为了
/// 让「算法被误换回另一种」时立刻失败，而不是等到真机登录才发现。
///
/// 期望值取自**浏览器里的 `encodeInp` 实测输出**（见 docs/技术笔记.md），
/// 不是自己算一遍再对照自己 —— 那样只能证明代码自洽。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hijianzhu_jw/crypto/qz_encoder.dart';

void main() {
  group('encoded：Base64(账号) %%% Base64(密码)', () {
    test('与浏览器 encodeInp 的实测输出逐字一致', () {
      // 右边这些值是在真实登录页里调 `encodeInp(...)` 得到的
      const Map<String, String> browserOutput = <String, String>{
        '12345678': 'MTIzNDU2Nzg=',
        'admin': 'YWRtaW4=',
        'A': 'QQ==',
        'ab': 'YWI=',
        'abc': 'YWJj',
        '711621645Zz.': 'NzExNjIxNjQ1Wnou',
      };
      for (final MapEntry<String, String> e in browserOutput.entries) {
        final String got =
            QzEncoder.buildEncoded(e.key, 'x').split('%%%').first;
        expect(got, e.value, reason: '${e.key} 的 Base64 与页面不一致');
      }
    });

    test('整体形态：Base64(账号)%%%Base64(密码)', () {
      final String enc = QzEncoder.buildEncoded('202500000001', '711621645Zz.');
      expect(enc, 'MjAyNTAwMDAwMDAx%%%NzExNjIxNjQ1Wnou');
      // 分隔符恰好三个百分号 —— 少一个多一个都会被服务端解错
      expect(enc.split('%%%').length, 2);
    });

    test('账号或密码为空时返回空串（调用方据此拦住，不打无效请求）', () {
      expect(QzEncoder.buildEncoded('', 'pw'), isEmpty);
      expect(QzEncoder.buildEncoded('acc', ''), isEmpty);
      expect(QzEncoder.buildEncoded('', ''), isEmpty);
    });

    test('不包含握手逻辑（本校流程无需 scode#sxh）', () {
      // 若哪天有人把参考实现的握手算法搬回来，`#` 会出现在 encoded 里
      final String enc = QzEncoder.buildEncoded('202500000001', 'pw#with#hash');
      expect(enc.contains('#'), isFalse,
          reason: 'encoded 里出现 # 说明又走回「握手串」那套算法了');
      // 密码里的 % 也要能被安全编码（不能破坏分隔符语义）
      final String enc2 = QzEncoder.buildEncoded('acc', 'a%%%b');
      expect(enc2.split('%%%').length, 2,
          reason: '密码里的 %%% 被原样透出，说明没有先 Base64');
    });

    test('isRejected 恒为 false（本校没有握手表态）', () {
      expect(QzEncoder.isRejected('no'), isFalse);
      expect(QzEncoder.isRejected(''), isFalse);
    });

    test('maskTicket 隐去一次性凭据', () {
      expect(QzEncoder.maskTicket('http://x/t?ticket=ABC123&a=1'),
          'http://x/t?ticket=***');
      expect(QzEncoder.maskTicket('http://x/no-ticket'), 'http://x/no-ticket');
    });
  });
}
