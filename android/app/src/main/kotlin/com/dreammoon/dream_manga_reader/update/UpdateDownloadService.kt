package com.dreammoon.dream_manga_reader.update

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.dreammoon.dream_manga_reader.MainActivity
import com.dreammoon.dream_manga_reader.R
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

class UpdateDownloadService : Service() {
    private val executor = Executors.newSingleThreadExecutor()
    private val running = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastProgressAt = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            cancelActiveTask()
            return START_NOT_STICKY
        }
        // 这条路径由 startForegroundService() 拉起,系统要求 5 秒内进入前台,否则抛
        // ForegroundServiceDidNotStartInTimeException。计划解析可能失败(例如 START_REDELIVER_INTENT
        // 重投递了一个 schema 已变的旧 intent),所以先用占位通知满足这个约定再解析。
        startAsForeground(null)
        val plan = runCatching {
            intent?.getStringExtra(EXTRA_PLAN)?.let { UpdateDownloadPlan.parse(org.json.JSONObject(it)) }
                ?: UpdateStateStore.readPlan(this)
                ?: throw IllegalArgumentException("No saved update plan")
        }.getOrElse {
            publishError(null, "invalid_plan", "更新下载计划无效")
            stopForegroundCompat()
            stopSelf(startId)
            return START_NOT_STICKY
        }

        startAsForeground(plan)
        if (!running.compareAndSet(false, true)) return START_REDELIVER_INTENT
        cancelled.set(false)
        executor.execute { runDownload(plan, startId) }
        return START_REDELIVER_INTENT
    }

    private fun runDownload(plan: UpdateDownloadPlan, startId: Int) {
        try {
            prepareTask(plan)
            acquireWakeLock()
            val apk = if (plan.direct != null) {
                downloadRemote(plan, plan.direct, 0L, finalApkFile(plan))
            } else {
                downloadAndAssembleParts(plan)
            }
            checkCancelled()
            publish(plan, "verifying", plan.sizeBytes, message = "正在校验安装包")
            verifyFile(apk, plan.sizeBytes, plan.sha256, deleteOnFailure = true)
            verifyApkPackage(apk)
            val ready = UpdateDownloadState(
                status = "ready",
                taskKey = plan.taskKey,
                versionName = plan.versionName,
                downloadedBytes = plan.sizeBytes,
                totalBytes = plan.sizeBytes,
                percent = 100.0,
                message = "更新已下载，点击安装",
                apkPath = apk.canonicalPath,
            )
            publishState(ready)
            showReadyNotification(ready)
        } catch (_: DownloadCancelledException) {
            // Explicit cancellation already cleared state and files.
        } catch (error: ExpiredUrlException) {
            if (!cancelled.get()) {
                publishError(plan, "expired_url", "下载地址已过期，请重试")
            }
        } catch (error: Throwable) {
            if (!cancelled.get()) {
                publishError(plan, "download_failed", safeMessage(error))
            }
        } finally {
            releaseWakeLock()
            running.set(false)
            stopForegroundCompat()
            stopSelf(startId)
        }
    }

    private fun prepareTask(plan: UpdateDownloadPlan) {
        val previous = UpdateStateStore.readState(this)
        if (previous.taskKey != null && previous.taskKey != plan.taskKey) {
            deleteRecursively(updateRoot())
            UpdateStateStore.clear(this)
        }
        taskDirectory(plan).mkdirs()
        UpdateStateStore.writePlan(this, plan)
        publish(plan, "downloading", completedBytes(plan), message = "准备下载更新")
    }

    private fun downloadAndAssembleParts(plan: UpdateDownloadPlan): File {
        val completed = mutableListOf<File>()
        var precedingBytes = 0L
        for (part in plan.parts) {
            checkCancelled()
            val target = verifiedRemoteFile(plan, part)
            val file = downloadRemote(plan, part, precedingBytes, target)
            completed += file
            precedingBytes += part.sizeBytes
        }
        val assembling = File(taskDirectory(plan), "${plan.fileName}.assembling")
        if (assembling.exists()) assembling.delete()
        publish(plan, "assembling", plan.sizeBytes, message = "正在合并安装包")
        BufferedOutputStream(FileOutputStream(assembling)).use { output ->
            completed.forEach { part ->
                BufferedInputStream(FileInputStream(part)).use { input ->
                    val buffer = ByteArray(BUFFER_SIZE)
                    while (true) {
                        checkCancelled()
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                    }
                }
            }
        }
        verifyFile(assembling, plan.sizeBytes, plan.sha256, deleteOnFailure = true)
        val final = finalApkFile(plan)
        if (final.exists()) final.delete()
        if (!assembling.renameTo(final)) {
            assembling.copyTo(final, overwrite = true)
            assembling.delete()
        }
        completed.forEach { it.delete() }
        return final
    }

    private fun downloadRemote(
        plan: UpdateDownloadPlan,
        remote: UpdateRemoteFile,
        precedingBytes: Long,
        target: File,
    ): File {
        if (target.exists()) {
            runCatching { verifyFile(target, remote.sizeBytes, remote.sha256, false) }
                .onSuccess {
                    publish(plan, "downloading", precedingBytes + remote.sizeBytes)
                    return target
                }
            target.delete()
        }
        val partial = File("${target.path}.download")
        if (partial.length() > remote.sizeBytes) partial.delete()
        var lastError: IOException? = null
        for (attempt in 1..MAX_ATTEMPTS) {
            checkCancelled()
            try {
                downloadOnce(plan, remote, partial, precedingBytes)
                verifyFile(partial, remote.sizeBytes, remote.sha256, deleteOnFailure = true)
                if (target.exists()) target.delete()
                if (!partial.renameTo(target)) {
                    partial.copyTo(target, overwrite = true)
                    partial.delete()
                }
                return target
            } catch (error: ExpiredUrlException) {
                throw error
            } catch (error: DownloadCancelledException) {
                throw error
            } catch (error: IOException) {
                lastError = error
                if (attempt == MAX_ATTEMPTS || !isRetryable(error)) throw error
                publish(
                    plan,
                    "retrying",
                    precedingBytes + partial.length(),
                    message = "连接中断，正在重试 ${attempt + 1} / $MAX_ATTEMPTS",
                    retryAttempt = attempt + 1,
                )
                Thread.sleep(500L * attempt)
            }
        }
        throw lastError ?: IOException("Download failed")
    }

    private fun downloadOnce(
        plan: UpdateDownloadPlan,
        remote: UpdateRemoteFile,
        partial: File,
        precedingBytes: Long,
    ) {
        val existing = partial.length()
        val connection = (URL(remote.url).openConnection() as HttpURLConnection).apply {
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            instanceFollowRedirects = true
            requestMethod = "GET"
            setRequestProperty("User-Agent", "DreamMangaReader-Updater")
            if (existing > 0L) setRequestProperty("Range", "bytes=$existing-")
        }
        try {
            val status = connection.responseCode
            if (status == HttpURLConnection.HTTP_UNAUTHORIZED ||
                status == HttpURLConnection.HTTP_FORBIDDEN
            ) throw ExpiredUrlException()
            if (status in 500..599) throw RetryableHttpException(status)
            if (status != HttpURLConnection.HTTP_OK && status != HttpURLConnection.HTTP_PARTIAL) {
                throw PermanentHttpException(status)
            }
            var append = status == HttpURLConnection.HTTP_PARTIAL && existing > 0L
            if (status == HttpURLConnection.HTTP_PARTIAL) {
                val contentRange = connection.getHeaderField("Content-Range") ?: ""
                val start = CONTENT_RANGE.find(contentRange)?.groupValues?.get(1)?.toLongOrNull()
                if (start != existing) throw IOException("Invalid Content-Range")
            } else {
                append = false
            }
            partial.parentFile?.mkdirs()
            RandomAccessFile(partial, "rw").use { output ->
                if (append) output.seek(existing) else output.setLength(0L)
                BufferedInputStream(connection.inputStream).use { input ->
                    val buffer = ByteArray(BUFFER_SIZE)
                    while (true) {
                        checkCancelled()
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                        val current = output.filePointer
                        if (current > remote.sizeBytes) throw IOException("Download exceeds expected size")
                        publishProgressThrottled(plan, precedingBytes + current)
                    }
                }
            }
            if (partial.length() != remote.sizeBytes) {
                throw IOException("Connection closed before download completed")
            }
            publish(plan, "downloading", precedingBytes + remote.sizeBytes)
        } finally {
            connection.disconnect()
        }
    }

    private fun verifyFile(file: File, size: Long, sha256: String, deleteOnFailure: Boolean) {
        try {
            require(file.length() == size) { "Update size mismatch" }
            val digest = MessageDigest.getInstance("SHA-256")
            BufferedInputStream(FileInputStream(file)).use { input ->
                val buffer = ByteArray(BUFFER_SIZE)
                while (true) {
                    checkCancelled()
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            require(actual.equals(sha256, ignoreCase = true)) { "Update SHA-256 mismatch" }
        } catch (error: Throwable) {
            if (deleteOnFailure && error !is DownloadCancelledException) file.delete()
            throw error
        }
    }

    @Suppress("DEPRECATION")
    private fun verifyApkPackage(apk: File) {
        // GET_SIGNING_CERTIFICATES also forces PackageManager to parse the signing block.
        val info = packageManager.getPackageArchiveInfo(
            apk.path,
            PackageManager.GET_SIGNING_CERTIFICATES,
        ) ?: throw IllegalArgumentException("Downloaded APK cannot be parsed")
        require(info.packageName == packageName) { "Downloaded APK package name does not match" }
    }

    private fun publishProgressThrottled(plan: UpdateDownloadPlan, downloaded: Long) {
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastProgressAt < PROGRESS_INTERVAL_MS) return
        lastProgressAt = now
        publish(plan, "downloading", downloaded)
    }

    private fun publish(
        plan: UpdateDownloadPlan,
        status: String,
        downloaded: Long,
        message: String? = null,
        retryAttempt: Int? = null,
    ) {
        val safeDownloaded = downloaded.coerceIn(0L, plan.sizeBytes)
        val state = UpdateDownloadState(
            status = status,
            taskKey = plan.taskKey,
            versionName = plan.versionName,
            downloadedBytes = safeDownloaded,
            totalBytes = plan.sizeBytes,
            percent = safeDownloaded.toDouble() * 100.0 / plan.sizeBytes.toDouble(),
            message = message,
            retryAttempt = retryAttempt,
        )
        publishState(state)
        NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, progressNotification(state))
    }

    private fun publishState(state: UpdateDownloadState) {
        UpdateStateStore.writeState(this, state)
        sendBroadcast(
            Intent(ACTION_STATE_CHANGED)
                .setPackage(packageName),
        )
    }

    private fun publishError(plan: UpdateDownloadPlan?, code: String, message: String) {
        val state = UpdateDownloadState(
            status = "error",
            taskKey = plan?.taskKey,
            versionName = plan?.versionName,
            downloadedBytes = plan?.let { completedBytes(it) } ?: 0L,
            totalBytes = plan?.sizeBytes ?: 0L,
            percent = plan?.let { completedBytes(it).toDouble() * 100.0 / it.sizeBytes } ?: 0.0,
            message = message,
            errorCode = code,
        )
        publishState(state)
        NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, errorNotification(state))
    }

    private fun startAsForeground(plan: UpdateDownloadPlan?) {
        val state = UpdateDownloadState(
            status = "downloading",
            taskKey = plan?.taskKey,
            versionName = plan?.versionName,
            totalBytes = plan?.sizeBytes ?: 0L,
            message = "准备下载更新",
        )
        val notification = progressNotification(state)
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

    private fun progressNotification(state: UpdateDownloadState): Notification {
        val percent = state.percent.roundToInt().coerceIn(0, 100)
        val cancelIntent = Intent(this, UpdateDownloadService::class.java).setAction(ACTION_CANCEL)
        val cancelPending = PendingIntent.getService(
            this,
            1,
            cancelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Dream Manga Reader ${state.versionName ?: ""}")
            .setContentText(state.message ?: "正在下载更新 $percent%")
            .setProgress(100, percent, state.totalBytes <= 0L)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(0, "取消", cancelPending)
            .build()
    }

    private fun showReadyNotification(state: UpdateDownloadState) {
        val intent = Intent(this, MainActivity::class.java)
            .setAction(UpdateDownloadBridge.ACTION_INSTALL_READY_UPDATE)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending = PendingIntent.getActivity(
            this,
            2,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("更新已下载")
            .setContentText("版本 ${state.versionName} 已就绪，点击安装")
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, notification)
    }

    private fun errorNotification(state: UpdateDownloadState): Notification {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending = PendingIntent.getActivity(
            this,
            3,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("更新下载失败")
            .setContentText(state.message ?: "请打开应用重试")
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(CHANNEL_ID, "应用更新", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun cancelActiveTask() {
        cancelled.set(true)
        deleteRecursively(updateRoot())
        UpdateStateStore.clear(this)
        publishState(UpdateDownloadState.IDLE)
        NotificationManagerCompat.from(this).cancel(NOTIFICATION_ID)
        stopForegroundCompat()
        stopSelf()
    }

    private fun acquireWakeLock() {
        val manager = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = manager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:background-update",
        ).also { it.acquire(WAKE_LOCK_TIMEOUT_MS) }
    }

    private fun releaseWakeLock() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_DETACH)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(false)
        }
    }

    private fun completedBytes(plan: UpdateDownloadPlan): Long {
        if (plan.direct != null) {
            val final = finalApkFile(plan)
            return if (final.exists()) plan.sizeBytes else File("${final.path}.download").length()
        }
        return plan.parts.sumOf { part ->
            val final = verifiedRemoteFile(plan, part)
            if (final.exists()) part.sizeBytes else File("${final.path}.download").length()
        }.coerceAtMost(plan.sizeBytes)
    }

    private fun taskDirectory(plan: UpdateDownloadPlan) = File(updateRoot(), plan.taskKey)
    private fun updateRoot() = File(filesDir, "updates")
    private fun finalApkFile(plan: UpdateDownloadPlan) = File(taskDirectory(plan), plan.fileName)
    private fun verifiedRemoteFile(plan: UpdateDownloadPlan, remote: UpdateRemoteFile) =
        File(taskDirectory(plan), "${remote.sha256}-${remote.fileName}")

    private fun checkCancelled() {
        if (cancelled.get() || Thread.currentThread().isInterrupted) {
            throw DownloadCancelledException()
        }
    }

    private fun isRetryable(error: IOException): Boolean = error !is PermanentHttpException

    private fun safeMessage(error: Throwable): String = when (error) {
        is IllegalArgumentException -> error.message ?: "更新文件校验失败"
        is IOException -> "网络连接中断，请重试"
        else -> "更新下载失败"
    }.replace(Regex("https?://\\S+"), "[download URL]")

    private fun deleteRecursively(file: File) {
        if (!file.exists()) return
        file.walkBottomUp().forEach { runCatching { it.delete() } }
    }

    override fun onDestroy() {
        releaseWakeLock()
        executor.shutdownNow()
        super.onDestroy()
    }

    companion object {
        const val ACTION_START = "com.dreammoon.dream_manga_reader.UPDATE_START"
        const val ACTION_CANCEL = "com.dreammoon.dream_manga_reader.UPDATE_CANCEL"
        const val ACTION_STATE_CHANGED = "com.dreammoon.dream_manga_reader.UPDATE_STATE"
        const val EXTRA_PLAN = "update_plan"
        private const val CHANNEL_ID = "dream_manga_reader_updates"
        private const val NOTIFICATION_ID = 7200
        private const val MAX_ATTEMPTS = 3
        private const val CONNECT_TIMEOUT_MS = 20_000
        private const val READ_TIMEOUT_MS = 60_000
        private const val PROGRESS_INTERVAL_MS = 350L
        private const val WAKE_LOCK_TIMEOUT_MS = 30L * 60L * 1000L
        private const val BUFFER_SIZE = 64 * 1024
        private val CONTENT_RANGE = Regex("bytes\\s+(\\d+)-\\d+/\\d+", RegexOption.IGNORE_CASE)
    }
}

private class DownloadCancelledException : RuntimeException()
private class ExpiredUrlException : IOException()
private class RetryableHttpException(val statusCode: Int) : IOException("HTTP $statusCode")
private class PermanentHttpException(val statusCode: Int) : IOException("HTTP $statusCode")
