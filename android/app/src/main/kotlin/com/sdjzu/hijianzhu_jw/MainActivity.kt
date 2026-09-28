package com.sdjzu.hijianzhu

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 原生通道：目前只保留「用系统浏览器打开链接」（设置页的「开源地址」一行）。
 *
 * ===== PDF 保存为什么删掉了 =====
 * 这里原本还有一条 `savePdf`（`ACTION_CREATE_DOCUMENT`，供培养方案页的
 * 「下载附件」走 SAF 另存）。实测本校的培养方案页面里**没有任何附件**
 * （`uploadfile` / `.pdf` / `附件` 均不出现），整套下载链路只服务一个
 * 本校不存在的功能，已随合并改版整块删除。
 *
 * ===== 为什么不引第三方插件 =====
 * 本项目在插件与 AGP / compileSdk 的兼容上已多次吃亏（device_calendar、
 * permission_handler、flutter_local_notifications 都回退过）。这里只需要
 * 一个系统 Intent（`ACTION_VIEW`），自己写通道比再引一个插件更可控，
 * 也不增加依赖风险。
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.sdjzu.hijianzhu/pdf"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 通道名沿用历史值（设置页那条 openUrl 仍按这个名字调用）。
        // 名字里带 pdf 只是既成事实，改名要动 Dart 侧且没有收益。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> openUrl(call.argument<String>("url"), result)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 用系统浏览器打开一个链接（目前用于「开源地址」那一行）。
     *
     * 为什么要自己写而不是引 url_launcher：本项目在插件兼容上多次踩坑
     * （见 pubspec 里 device_calendar / permission_handler 的记录），
     * 而这里只需要一个 `ACTION_VIEW` Intent —— 自己写比再引一个插件可控。
     *
     * **安全约束**：只允许 http/https。否则 `file://` 之类会被用来读本地文件
     * （Dart 侧传什么就开什么，等于把 Intent 的构造权交给了上游）。
     */
    private fun openUrl(url: String?, result: MethodChannel.Result) {
        if (url.isNullOrEmpty()) {
            result.error("NO_URL", "缺少网址", null)
            return
        }
        val uri = Uri.parse(url)
        if (uri.scheme != "http" && uri.scheme != "https") {
            result.error("BAD_SCHEME", "只允许 http/https 链接", null)
            return
        }
        try {
            startActivity(Intent(Intent.ACTION_VIEW, uri))
            result.success(true)
        } catch (e: Exception) {
            // 设备上没有浏览器（极罕见）
            result.error("NO_BROWSER", e.message, null)
        }
    }
}
