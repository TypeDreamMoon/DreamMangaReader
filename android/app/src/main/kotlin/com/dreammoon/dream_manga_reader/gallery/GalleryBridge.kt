package com.dreammoon.dream_manga_reader.gallery

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 把一张图片交给系统相册。
 *
 * 落点是 DCIM/ScreenShot:相册里看得到,文件管理器一眼找得到。写应用私有目录
 * (/storage/emulated/0/Android/data/<包名>/files/…)也能成、还不要权限,但那串路径
 * 报给用户等于没报 —— 念都念不完,相册里也永远不出现。
 *
 * Android 10 起 MediaStore 用 RELATIVE_PATH 落盘,应用写自己插入的条目不需要任何权限。
 * 再往前只能直接写公共目录,那就得要 WRITE_EXTERNAL_STORAGE —— 所以那条权限声明了
 * maxSdkVersion=28,新系统上根本不会出现在权限列表里。
 */
class GalleryBridge(private val activity: FlutterActivity) {
    private var channel: MethodChannel? = null

    /**
     * 等同一次权限结果的那些保存,先来先落盘。API 29 以下才可能有。
     *
     * 必须是队列而不是一个槽:连点两次保存时,后一次会把前一次挤掉,而 [MethodChannel.Result]
     * 一旦被丢掉就再没人回调它 —— Dart 那边的 future 永远挂着,界面卡在「保存中」。
     */
    private val pendingSaves = ArrayDeque<Pair<Image, MethodChannel.Result>>()

    private data class Image(val bytes: ByteArray, val fileName: String, val mimeType: String)

    fun configure(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveImage" -> saveImage(call, result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun saveImage(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        val fileName = call.argument<String>("fileName")
        if (bytes == null || bytes.isEmpty() || fileName.isNullOrBlank()) {
            result.error("invalid_argument", "Expected non-empty bytes and fileName", null)
            return
        }
        val image = Image(bytes, fileName, call.argument<String>("mimeType") ?: DEFAULT_MIME)
        if (needsLegacyPermission()) {
            pendingSaves.addLast(image to result)
            // 弹窗只由第一笔发起,后面的搭同一次结果的车,不去叠一堆系统对话框。
            if (pendingSaves.size == 1) {
                ActivityCompat.requestPermissions(
                    activity,
                    arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                    STORAGE_PERMISSION_REQUEST,
                )
            }
            return
        }
        complete(image, result)
    }

    private fun complete(image: Image, result: MethodChannel.Result) {
        runCatching { write(image) }.fold(
            onSuccess = { result.success(it) },
            onFailure = { result.error("save_failed", it.message, null) },
        )
    }

    private fun write(image: Image): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            writeViaMediaStore(image)
        } else {
            writeLegacyFile(image)
        }

    private fun writeViaMediaStore(image: Image): String {
        val resolver = activity.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, image.fileName)
            put(MediaStore.Images.Media.MIME_TYPE, image.mimeType)
            put(MediaStore.Images.Media.RELATIVE_PATH, RELATIVE_PATH)
            // 写完之前对相册不可见,免得扫描器抓到一个只写了一半的文件。
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore refused the insert")
        try {
            resolver.openOutputStream(uri)?.use { it.write(image.bytes) }
                ?: throw IllegalStateException("MediaStore gave no output stream")
        } catch (error: Throwable) {
            resolver.delete(uri, null, null)
            throw error
        }
        resolver.update(
            uri,
            ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) },
            null,
            null,
        )
        return "$RELATIVE_PATH/${image.fileName}"
    }

    private fun writeLegacyFile(image: Image): String {
        val directory = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM),
            ALBUM,
        )
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Cannot create ${directory.absolutePath}")
        }
        val file = File(directory, image.fileName)
        file.writeBytes(image.bytes)
        // 老系统没有 MediaStore 代劳,不扫一遍相册里就是不出现。
        MediaScannerConnection.scanFile(
            activity,
            arrayOf(file.absolutePath),
            arrayOf(image.mimeType),
            null,
        )
        return "$RELATIVE_PATH/${image.fileName}"
    }

    private fun needsLegacyPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ) != PackageManager.PERMISSION_GRANTED

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != STORAGE_PERMISSION_REQUEST) return false
        val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        // 排空:每一笔都得到答复,一笔都不能留在队列里。
        while (pendingSaves.isNotEmpty()) {
            val (image, result) = pendingSaves.removeFirst()
            if (granted) {
                complete(image, result)
            } else {
                result.error("permission_denied", "Storage permission denied", null)
            }
        }
        return true
    }

    fun dispose() {
        channel?.setMethodCallHandler(null)
        channel = null
        // 页面没了也要把还在等的那些回掉,否则 Dart 侧的 future 跟着一起消失在原地。
        while (pendingSaves.isNotEmpty()) {
            pendingSaves.removeFirst().second
                .error("cancelled", "Gallery bridge was disposed", null)
        }
    }

    companion object {
        private const val CHANNEL = "dream_manga_reader/gallery"
        private const val ALBUM = "ScreenShot"
        private const val DEFAULT_MIME = "image/jpeg"
        private const val STORAGE_PERMISSION_REQUEST = 0x6741
        private val RELATIVE_PATH = "${Environment.DIRECTORY_DCIM}/$ALBUM"
    }
}
