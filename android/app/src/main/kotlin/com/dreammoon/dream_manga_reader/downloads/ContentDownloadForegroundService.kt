package com.dreammoon.dream_manga_reader.downloads

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.dreammoon.dream_manga_reader.MainActivity
import com.dreammoon.dream_manga_reader.R

class ContentDownloadForegroundService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val staleStop = Runnable { stopService() }
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START, ACTION_UPDATE -> {
                val state = stateFrom(intent)
                startAsForeground(state)
                refreshWakeLock()
                refreshStaleTimeout()
            }
            ACTION_STOP -> stopService()
            else -> stopService()
        }
        return START_NOT_STICKY
    }

    private fun stateFrom(intent: Intent): ContentDownloadState =
        ContentDownloadState.fromMap(
            mapOf(
                "taskCount" to intent.getIntExtra(EXTRA_TASK_COUNT, 0),
                "completedBytes" to intent.getLongExtra(EXTRA_COMPLETED, 0L),
                "totalBytes" to intent.getLongExtra(EXTRA_TOTAL, 0L),
                "indeterminate" to intent.getBooleanExtra(EXTRA_INDETERMINATE, true),
                "currentTitle" to intent.getStringExtra(EXTRA_TITLE).orEmpty(),
                "currentItemTitle" to intent.getStringExtra(EXTRA_ITEM_TITLE).orEmpty(),
            ),
        )

    private fun startAsForeground(state: ContentDownloadState) {
        val notification = notification(state)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun notification(state: ContentDownloadState): Notification {
        val openIntent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val openPending = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val content = listOf(state.currentTitle, state.currentItemTitle)
            .filter { it.isNotBlank() }
            .joinToString(" · ")
            .ifBlank { "正在处理 ${state.taskCount} 个下载任务" }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("正在下载 ${state.taskCount} 个项目")
            .setContentText(content)
            .setContentIntent(openPending)
            .setProgress(100, state.percent, state.indeterminate || state.totalBytes <= 0L)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "内容下载",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "漫画、小说和番剧后台下载进度"
            setSound(null, null)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun refreshWakeLock() {
        releaseWakeLock()
        val manager = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = manager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:content-downloads",
        ).also { it.acquire(WAKE_LOCK_TIMEOUT_MS) }
    }

    private fun refreshStaleTimeout() {
        handler.removeCallbacks(staleStop)
        handler.postDelayed(staleStop, STALE_TIMEOUT_MS)
    }

    private fun releaseWakeLock() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }

    private fun stopService() {
        handler.removeCallbacks(staleStop)
        releaseWakeLock()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        handler.removeCallbacks(staleStop)
        releaseWakeLock()
        super.onDestroy()
    }

    companion object {
        const val ACTION_START = "com.dreammoon.dream_manga_reader.DOWNLOADS_START"
        const val ACTION_UPDATE = "com.dreammoon.dream_manga_reader.DOWNLOADS_UPDATE"
        const val ACTION_STOP = "com.dreammoon.dream_manga_reader.DOWNLOADS_STOP"
        const val EXTRA_TASK_COUNT = "task_count"
        const val EXTRA_COMPLETED = "completed_bytes"
        const val EXTRA_TOTAL = "total_bytes"
        const val EXTRA_INDETERMINATE = "indeterminate"
        const val EXTRA_TITLE = "current_title"
        const val EXTRA_ITEM_TITLE = "current_item_title"
        private const val CHANNEL_ID = "dream_manga_reader_content_downloads"
        private const val NOTIFICATION_ID = 7210
        private const val STALE_TIMEOUT_MS = 2L * 60L * 1000L
        private const val WAKE_LOCK_TIMEOUT_MS = 3L * 60L * 1000L
    }
}
