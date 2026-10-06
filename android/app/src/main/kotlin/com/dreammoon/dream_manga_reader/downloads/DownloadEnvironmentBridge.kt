package com.dreammoon.dream_manga_reader.downloads

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 下载策略要用的运行环境:当前网络是否计费/漫游,以及下载目录所在分区还剩多少空间。
 *
 * 网络变化通过 ConnectivityManager 的 NetworkCallback 走 EventChannel 推给 Dart —— 只推
 * 「变了」这一个信号,具体数值仍由 Dart 侧回头用 MethodChannel 拉一次,省得两条路的
 * 口径不一致。拉不到时 Dart 侧一律按「不限制」处理,不会因为探测失败把下载卡死。
 */
class DownloadEnvironmentBridge(
    private val activity: FlutterActivity,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private val main = Handler(Looper.getMainLooper())

    private val connectivity: ConnectivityManager?
        get() = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    fun configure(engine: FlutterEngine) {
        methods = MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        events = EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "network" -> result.success(networkState())
            "storage" -> result.success(storageState(call.argument<String>("path")))
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        val manager = connectivity ?: return
        val created = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = emitChanged()

            override fun onLost(network: Network) = emitChanged()

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) = emitChanged()
        }
        callback = created
        runCatching { manager.registerDefaultNetworkCallback(created) }
            .onFailure { callback = null }
    }

    override fun onCancel(arguments: Any?) {
        unregister()
        sink = null
    }

    fun dispose() {
        unregister()
        sink = null
        methods?.setMethodCallHandler(null)
        methods = null
        events?.setStreamHandler(null)
        events = null
    }

    private fun unregister() {
        val registered = callback ?: return
        callback = null
        runCatching { connectivity?.unregisterNetworkCallback(registered) }
    }

    /** NetworkCallback 跑在自己的线程上,平台通道只能在主线程发。 */
    private fun emitChanged() {
        main.post { sink?.success(true) }
    }

    private fun networkState(): Map<String, Any> {
        // API 23 以下拿不到 activeNetwork 的能力信息,按「不限制」交给 Dart 兜底。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return UNRESTRICTED_NETWORK
        val manager = connectivity ?: return UNRESTRICTED_NETWORK
        val capabilities = manager.activeNetwork?.let { manager.getNetworkCapabilities(it) }
            ?: return OFFLINE_NETWORK
        val roaming = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_ROAMING)
        } else {
            false
        }
        return mapOf(
            "connected" to capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
            "unmetered" to capabilities.hasCapability(
                NetworkCapabilities.NET_CAPABILITY_NOT_METERED,
            ),
            "roaming" to roaming,
        )
    }

    private fun storageState(path: String?): Map<String, Any> = runCatching {
        val target = path?.takeIf { it.isNotEmpty() }?.let { File(it) } ?: activity.filesDir
        val probe = firstExisting(target) ?: return@runCatching UNAVAILABLE_STORAGE
        val stat = StatFs(probe.absolutePath)
        mapOf<String, Any>("available" to true, "freeBytes" to stat.availableBytes)
    }.getOrElse { UNAVAILABLE_STORAGE }

    /** 下载目录可能还没建出来,沿父目录往上找第一个存在的,用它所在的分区。 */
    private fun firstExisting(file: File): File? {
        var current: File? = file
        while (current != null && !current.exists()) current = current.parentFile
        return current
    }

    companion object {
        private const val METHOD_CHANNEL = "dream_manga_reader/download_environment"
        private const val EVENT_CHANNEL = "dream_manga_reader/download_environment/events"

        private val UNRESTRICTED_NETWORK = mapOf<String, Any>(
            "connected" to true,
            "unmetered" to true,
            "roaming" to false,
        )
        private val OFFLINE_NETWORK = mapOf<String, Any>(
            "connected" to false,
            "unmetered" to false,
            "roaming" to false,
        )
        private val UNAVAILABLE_STORAGE = mapOf<String, Any>(
            "available" to false,
            "freeBytes" to 0L,
        )
    }
}
