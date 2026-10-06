package com.dreammoon.dream_manga_reader.net

import android.content.Context
import android.net.ConnectivityManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 把 Android 的系统代理读给 Dart。
 *
 * Dart 的 `HttpClient` 只认 `HTTP_PROXY` 之类的环境变量,而 Android 应用进程里根本
 * 没有这些变量:用户在 Wi-Fi 里手填的代理、VPN 类应用(Clash/Surfboard…)下发的代理、
 * 以及 `adb shell settings put global http_proxy` 设的全局代理,Dart 一个都看不见。
 * 结果是设置页明明有「使用系统代理」,Android 上却永远直连。
 *
 * 两个来源,按可靠性排:
 *  1. [ConnectivityManager.getDefaultProxy] —— 当前默认网络的代理,VPN 与 Wi-Fi 手动
 *     代理都会落到这里,还带排除名单。
 *  2. `http.proxyHost` / `http.proxyPort` 系统属性 —— 系统在设置全局代理时会同步写进来,
 *     部分 ROM 只更新这一处,留作兜底。
 *
 * 只读,不改任何系统状态;拿不到就返回 null,Dart 侧退回直连。
 */
class SystemProxyBridge(private val context: Context) {
    private var channel: MethodChannel? = null

    fun configure(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSystemProxy" -> result.success(readSystemProxy())
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun dispose() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    /** `{host, port, exclusions}`;没有代理返回 null。 */
    private fun readSystemProxy(): Map<String, Any?>? =
        defaultNetworkProxy() ?: systemPropertyProxy()

    private fun defaultNetworkProxy(): Map<String, Any?>? {
        val info = context.getSystemService(ConnectivityManager::class.java)?.defaultProxy
            ?: return null
        val host = info.host?.trim().orEmpty()
        if (host.isEmpty() || info.port <= 0) return null
        return mapOf(
            "host" to host,
            "port" to info.port,
            "exclusions" to info.exclusionList.orEmpty().toList(),
        )
    }

    private fun systemPropertyProxy(): Map<String, Any?>? {
        val host = System.getProperty("http.proxyHost")?.trim().orEmpty()
        if (host.isEmpty()) return null
        val port = System.getProperty("http.proxyPort")?.trim()?.toIntOrNull() ?: return null
        if (port <= 0) return null
        // http.nonProxyHosts 用 `|` 分隔,和 ProxyInfo 的排除名单归一成同一种形状。
        val exclusions = System.getProperty("http.nonProxyHosts").orEmpty()
            .split('|')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
        return mapOf("host" to host, "port" to port, "exclusions" to exclusions)
    }

    companion object {
        const val CHANNEL = "dream_manga_reader/system_proxy"
    }
}
