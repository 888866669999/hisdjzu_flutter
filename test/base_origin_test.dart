/// 基地址必须走 https
///
/// 学校的教务系统 http / https **两个端口都通**，但登录表单里有
/// **明文密码**（`userPassword` 按页面 JS 原样提交），走 http 等于把它
/// 暴露在链路上。五个业务接口在 https 下实测全部 200，没有兼容问题。
///
/// 这条断言看着琐碎，但它守的是一件真事：鸿蒙端曾因为基地址写 http、
/// 而登录成功的 302 指向 https，跟随这条**跨协议重定向**时丢了会话 ——
/// 「登录成功」被误判成失败，而会话其实已经建立。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hijianzhu_jw/common/constants.dart';

void main() {
  test('基地址用 https', () {
    expect(kBaseOrigin.startsWith('https://'), isTrue,
        reason: '登录表单含明文密码，必须走加密链路；实际：$kBaseOrigin');
  });

  test('基地址不含端口与路径（路径常量单独拼接）', () {
    final Uri u = Uri.parse(kBaseOrigin);
    expect(u.hasPort, isFalse, reason: '基地址不该带端口');
    expect(u.path, isEmpty, reason: '基地址不该带路径');
  });

  test('各业务路径都以 / 开头（拼接后不会出现双斜杠或缺斜杠）', () {
    for (final String p in <String>[
      kPathLoginPage,
      kPathCaptcha,
      kPathLogon,
      kPathTimetable,
      kPathScoreList,
      kPathProfile,
      kPathClassroom,
      kPathElective,
      kPathElectiveDetail,
    ]) {
      expect(p.startsWith('/'), isTrue, reason: '$p 应以 / 开头');
      expect(p.contains('//'), isFalse, reason: '$p 不应含双斜杠');
    }
  });
}
