/// 学籍身份（姓名 / 学号）的自动获取
///
/// ===== 为什么需要单独一个服务 =====
/// 姓名与学号显示在**外壳**上（宽屏侧栏、顶栏右侧），但它们的唯一来源是
/// 「我的」页那次请求 —— 早先只有打开那一页时才会写进 `AppState`。
/// 于是用户装好应用、登录进来，**不进「我的」页就一直是空白的**，
/// 看起来像「没登录成功」。
///
/// 这两项数据在登录那一刻就已经可用（会话刚建立），没有理由等用户
/// 主动去某一页。因此这里提供两条自动路径：
///   · 登录成功后立刻取一次；
///   · 冷启动恢复会话后取一次（缓存优先，没有才联网）。
///
/// ===== 为什么按账号记「取到过」 =====
/// 换了账号必须重新取，否则会把上一个同学的姓名显示给下一个人。
/// 因此用「已取到姓名的是哪个账号」而不是布尔量 ——
/// 布尔量在换账号后会保持 true，姓名就再也不更新了。
library;

import 'package:flutter/foundation.dart';

import '../common/constants.dart';
import '../model/models.dart';
import 'app_state.dart';
import 'page_cache.dart';

class ProfileService {
  /// 已经取到过姓名的是哪个账号（空串 = 还没取到过）
  static String _loadedFor = '';

  /// 换账号 / 登出时清掉标记
  static void reset() {
    _loadedFor = '';
  }

  /// 补上姓名与学号。
  ///
  /// [allowNetwork] 为 false 时只读缓存：用于「不该打扰用户」的场合
  /// （启动时静默补一次，失败就等下次）。
  ///
  /// 失败静默：这只是给外壳补一行字，取不到不影响任何功能 ——
  /// 真正需要这些数据的「我的」页会自己报错。
  static Future<void> ensureIdentity({bool allowNetwork = true}) async {
    final AppState app = AppState.instance;
    final String account = app.account;
    if (account.isEmpty) {
      return;
    }
    // 同一个账号成功取到过一次就够了
    if (_loadedFor == account && app.studentName.isNotEmpty) {
      return;
    }
    try {
      if (!allowNetwork) {
        // 只看内存层：磁盘 IO 与网络都留给「允许联网」的那次
        final CachedPage? hit = PageCache.peek(
            PageCache.keyOf(account, kCacheProfile));
        if (hit == null) {
          return;
        }
      }
      final StudentProfile p = await app.api.getProfile();
      if (p.name.isNotEmpty) {
        app.studentName = p.name;
      }
      if (p.studentId.isNotEmpty) {
        app.studentId = p.studentId;
      }
      _loadedFor = account;
      debugPrint('[profile] identity loaded');
    } catch (e) {
      debugPrint('[profile] identity fetch failed: $e');
    }
  }
}
