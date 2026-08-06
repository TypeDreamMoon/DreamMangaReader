package com.dreammoon.dream_manga_reader.downloads

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class ContentDownloadBridge(
    private val activity: FlutterActivity,
) : MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var pendingStart: Pair<ContentDownloadState, MethodChannel.Result>? = null

    fun configure(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call, result)
            "update" -> send(call, result, ContentDownloadForegroundService.ACTION_UPDATE)
            "stop" -> {
                activity.stopService(
                    Intent(activity, ContentDownloadForegroundService::class.java),
                )
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val state = parse(call)
        if (needsNotificationPermission()) {
            if (pendingStart != null) {
                result.error("permission_pending", "Notification permission request is active", null)
                return
            }
            pendingStart = state to result
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST,
            )
            return
        }
        startService(state, ContentDownloadForegroundService.ACTION_START)
        result.success(null)
    }

    private fun send(call: MethodCall, result: MethodChannel.Result, action: String) {
        startService(parse(call), action)
        result.success(null)
    }

    private fun parse(call: MethodCall): ContentDownloadState {
        val arguments = call.arguments as? Map<*, *>
            ?: throw IllegalArgumentException("Missing content download state")
        return ContentDownloadState.fromMap(arguments)
    }

    private fun startService(state: ContentDownloadState, action: String) {
        val intent = Intent(activity, ContentDownloadForegroundService::class.java)
            .setAction(action)
            .putExtra(ContentDownloadForegroundService.EXTRA_TASK_COUNT, state.taskCount)
            .putExtra(ContentDownloadForegroundService.EXTRA_COMPLETED, state.completedBytes)
            .putExtra(ContentDownloadForegroundService.EXTRA_TOTAL, state.totalBytes)
            .putExtra(ContentDownloadForegroundService.EXTRA_INDETERMINATE, state.indeterminate)
            .putExtra(ContentDownloadForegroundService.EXTRA_TITLE, state.currentTitle)
            .putExtra(ContentDownloadForegroundService.EXTRA_ITEM_TITLE, state.currentItemTitle)
        ContextCompat.startForegroundService(activity, intent)
    }

    private fun needsNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return false
        val pending = pendingStart ?: return true
        pendingStart = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            runCatching {
                startService(pending.first, ContentDownloadForegroundService.ACTION_START)
            }.fold(
                onSuccess = { pending.second.success(null) },
                onFailure = { pending.second.error("foreground_start_failed", it.message, null) },
            )
        } else {
            pending.second.error(
                "notification_permission_denied",
                "Notification permission is required for background downloads",
                null,
            )
        }
        return true
    }

    fun dispose() {
        channel?.setMethodCallHandler(null)
        channel = null
        pendingStart?.second?.error("activity_destroyed", "Activity was destroyed", null)
        pendingStart = null
    }

    companion object {
        private const val METHOD_CHANNEL = "dream_manga_reader/downloads"
        private const val NOTIFICATION_PERMISSION_REQUEST = 7302
    }
}
