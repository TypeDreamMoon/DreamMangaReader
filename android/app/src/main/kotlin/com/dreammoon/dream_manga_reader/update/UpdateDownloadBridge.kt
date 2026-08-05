package com.dreammoon.dream_manga_reader.update

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File

class UpdateDownloadBridge(private val activity: Activity) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null
    private var resumed = false
    private var pendingInstall = false
    private var pendingPlan: UpdateDownloadPlan? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var lastAutoInstalledTask: String? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val state = UpdateStateStore.readState(activity)
            eventSink?.success(state.toJson().toMap())
            if (state.status == "ready" && resumed && state.taskKey != lastAutoInstalledTask) {
                installReady(state)
            }
        }
    }

    fun configure(flutterEngine: FlutterEngine) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
        ContextCompat.registerReceiver(
            activity,
            receiver,
            IntentFilter(UpdateDownloadService.ACTION_STATE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        handleIntent(activity.intent)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startUpdateDownload" -> start(call, result)
            "cancelUpdateDownload" -> {
                activity.startService(
                    Intent(activity, UpdateDownloadService::class.java)
                        .setAction(UpdateDownloadService.ACTION_CANCEL),
                )
                result.success(null)
            }
            "getUpdateDownloadState" ->
                result.success(UpdateStateStore.readState(activity).toJson().toMap())
            "installReadyUpdate" -> runCatching {
                installReady(UpdateStateStore.readState(activity))
            }.fold(
                onSuccess = { result.success(null) },
                onFailure = { result.error("install_failed", safeMessage(it), null) },
            )
            else -> result.notImplemented()
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val plan = runCatching {
            val arguments = call.arguments as? Map<*, *>
                ?: throw IllegalArgumentException("Missing update plan")
            UpdateDownloadPlan.parse(JSONObject(arguments))
        }.getOrElse {
            result.error("invalid_plan", safeMessage(it), null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            if (pendingPermissionResult != null) {
                result.error("permission_pending", "Notification permission is already pending", null)
                return
            }
            pendingPlan = plan
            pendingPermissionResult = result
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST,
            )
            return
        }
        startService(plan)
        result.success(null)
    }

    private fun startService(plan: UpdateDownloadPlan) {
        val intent = Intent(activity, UpdateDownloadService::class.java)
            .setAction(UpdateDownloadService.ACTION_START)
            .putExtra(UpdateDownloadService.EXTRA_PLAN, plan.toJson().toString())
        ContextCompat.startForegroundService(activity, intent)
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return false
        val result = pendingPermissionResult ?: return true
        val plan = pendingPlan
        pendingPermissionResult = null
        pendingPlan = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED && plan != null) {
            runCatching { startService(plan) }.fold(
                onSuccess = { result.success(null) },
                onFailure = { result.error("start_failed", safeMessage(it), null) },
            )
        } else {
            result.error(
                "notification_permission_denied",
                "Notification permission is required for background update downloads",
                null,
            )
        }
        return true
    }

    fun onResume() {
        resumed = true
        if (pendingInstall) {
            pendingInstall = false
            val state = UpdateStateStore.readState(activity)
            if (state.taskKey != lastAutoInstalledTask) installReady(state)
        }
    }

    fun onPause() {
        resumed = false
    }

    fun onNewIntent(intent: Intent) {
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action != ACTION_INSTALL_READY_UPDATE) return
        if (resumed) installReady(UpdateStateStore.readState(activity)) else pendingInstall = true
        intent.action = null
    }

    private fun installReady(state: UpdateDownloadState) {
        require(state.status == "ready") { "No verified update is ready" }
        val path = requireNotNull(state.apkPath)
        val root = File(activity.filesDir, "updates").canonicalFile
        val apk = File(path).canonicalFile
        require(apk.isFile && apk.path.startsWith(root.path + File.separator))
        val uri = FileProvider.getUriForFile(
            activity,
            "${activity.packageName}.update_provider",
            apk,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.startActivity(intent)
        lastAutoInstalledTask = state.taskKey
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        events.success(UpdateStateStore.readState(activity).toJson().toMap())
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun dispose() {
        runCatching { activity.unregisterReceiver(receiver) }
        eventSink = null
        pendingPermissionResult?.error("activity_destroyed", "Activity was destroyed", null)
        pendingPermissionResult = null
        pendingPlan = null
    }

    companion object {
        const val ACTION_INSTALL_READY_UPDATE =
            "com.dreammoon.dream_manga_reader.INSTALL_READY_UPDATE"
        private const val METHOD_CHANNEL = "dream_manga_reader/update"
        private const val EVENT_CHANNEL = "dream_manga_reader/update_events"
        private const val NOTIFICATION_PERMISSION_REQUEST = 7201

        private fun safeMessage(error: Throwable): String =
            error.message?.replace(Regex("https?://\\S+"), "[download URL]")
                ?: error.javaClass.simpleName
    }
}

private fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { key ->
    when (val value = get(key)) {
        JSONObject.NULL -> null
        is JSONObject -> value.toMap()
        else -> value
    }
}
