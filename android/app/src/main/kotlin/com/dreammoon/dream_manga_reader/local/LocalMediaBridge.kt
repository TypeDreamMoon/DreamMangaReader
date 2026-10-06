package com.dreammoon.dream_manga_reader.local

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 本地播放的 Android 选文件/读文件桥(SAF)。
 *
 * **为什么不用 file_picker 的 video 类型**:它的 `FileUtils.kt:533-575 openFileStream`
 * 会把选中的文件整份复制到 `cacheDir/file_picker/<时间戳>/<名字>`。挑一个 4GB 的电影
 * 会先复制 4GB —— 空间和时间都不可接受。所以自己走 SAF:系统文件选择器给的是
 * document/tree uri,读的时候是流,不落第二份拷贝。
 *
 * 本桥不申请任何权限:SAF 的授权随 uri 走(READ + takePersistableUriPermission),
 * manifest 里也不需要新增 `READ_MEDIA_VIDEO`/`MANAGE_EXTERNAL_STORAGE`(规格 §7.2/§7.3)。
 *
 * 播放路径(路线 A,规格 §7.2):[openFd] 把 `ContentResolver` 打开的描述符**留在桥里不关**,
 * 交给 Dart 的是 `/proc/self/fd/<fd>`。mpv 与我们同进程,读的是同一个 fd 表,所以这条路
 * 不需要复制文件;真机是否被 mpv 的文件探测接受由单独的 spike 验证(本文件不做假设)。
 */
class LocalMediaBridge(private val activity: FlutterActivity) {
    private var channel: MethodChannel? = null

    /** 所有 [MethodChannel.Result] 与 [openFds] 的访问都收敛在主线程。 */
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 等系统文件选择器回来的那一次调用;同一时刻只允许一个。 */
    private var pendingPick: PendingPick? = null

    /**
     * fd -> 打开中的描述符。
     *
     * 必须持有强引用:[ParcelFileDescriptor] 有终结器,没人引用时 GC 会把 fd 关掉,
     * 播放器随后读到的就是一个失效路径。只有 Dart 侧 `releaseFd` 或 [dispose] 才关。
     */
    private val openFds = HashMap<Int, ParcelFileDescriptor>()

    /** [dispose] 置位:长扫描看到它就在目录边界停下,已收到的条目照常返回(规格 §9)。 */
    private val cancelled = AtomicBoolean(false)

    private data class PendingPick(val requestCode: Int, val result: MethodChannel.Result)

    private data class DocumentInfo(
        val name: String,
        val size: Long,
        val mime: String,
        val lastModified: Long,
    )

    fun configure(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickDirectory" -> pick(result, REQUEST_PICK_DIRECTORY)
                    "pickFiles" -> pick(result, REQUEST_PICK_FILES)
                    "listChildren" -> listChildren(call, result)
                    "stat" -> stat(call, result)
                    "openFd" -> openFd(call, result)
                    "releaseFd" -> releaseFd(call, result)
                    "deleteTree" -> deleteTree(call, result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    // ---- 选择 ----

    private fun pick(result: MethodChannel.Result, requestCode: Int) {
        if (pendingPick != null) {
            result.error("pick_pending", "Another picker is already open", null)
            return
        }
        val intent = if (requestCode == REQUEST_PICK_DIRECTORY) {
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                // 持久授权:重启后这个 tree uri 仍然可读,否则每次启动都要用户重新授权。
                addFlags(GRANT_FLAGS)
            }
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = VIDEO_MIME
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                addFlags(GRANT_FLAGS)
            }
        }
        pendingPick = PendingPick(requestCode, result)
        runCatching { startForResult(intent, requestCode) }.onFailure {
            pendingPick = null
            result.error("picker_unavailable", it.message, null)
        }
    }

    /**
     * FlutterActivity 继承的是 `android.app.Activity`(不是 `ComponentActivity`),
     * 拿不到 `registerForActivityResult`,所以走老的 startActivityForResult +
     * [onActivityResult] —— 与仓库里权限结果交给 `MainActivity.onRequestPermissionsResult`
     * 委派的屋风一致。
     */
    @Suppress("DEPRECATION")
    private fun startForResult(intent: Intent, requestCode: Int) {
        activity.startActivityForResult(intent, requestCode)
    }

    /** @return true 表示这次结果归本桥,MainActivity 不必再往上传。 */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val pending = pendingPick ?: return false
        if (requestCode != pending.requestCode) return false
        pendingPick = null
        if (resultCode != Activity.RESULT_OK) {
            // 用户取消不是错误:目录给 null,多选给空列表(契约如此,Dart 侧照此判断)。
            if (requestCode == REQUEST_PICK_DIRECTORY) {
                pending.result.success(null)
            } else {
                pending.result.success(emptyList<Map<String, Any?>>())
            }
            return true
        }
        if (requestCode == REQUEST_PICK_DIRECTORY) {
            val uri = data?.data
            if (uri == null) {
                pending.result.success(null)
                return true
            }
            takePersistableRead(uri)
            offMain(
                work = { documentInfo(uri) },
                done = { outcome ->
                    outcome.fold(
                        onSuccess = { info ->
                            pending.result.success(
                                mapOf(
                                    "uri" to uri.toString(),
                                    "name" to (info?.name ?: uri.lastPathSegment.orEmpty()),
                                ),
                            )
                        },
                        onFailure = { pending.result.error("pick_failed", it.message, null) },
                    )
                },
            )
            return true
        }

        val uris = documentUris(data)
        if (uris.isEmpty()) {
            pending.result.success(emptyList<Map<String, Any?>>())
            return true
        }
        offMain(
            work = {
                // 多个 uri 的查询是 binder 往返,别放主线程。
                uris.forEach { takePersistableRead(it) }
                uris.map { uri ->
                    val info = documentInfo(uri)
                    mapOf(
                        "uri" to uri.toString(),
                        "name" to (info?.name ?: uri.lastPathSegment.orEmpty()),
                        "size" to (info?.size ?: 0L),
                        "mime" to (info?.mime ?: VIDEO_MIME),
                    )
                }
            },
            done = { outcome ->
                outcome.fold(
                    onSuccess = { pending.result.success(it) },
                    onFailure = { pending.result.error("pick_failed", it.message, null) },
                )
            },
        )
        return true
    }

    /**
     * 取持久读授权。
     *
     * 个别第三方 provider 不给持久授权(或返回的压根不是 DocumentsProvider),
     * 拿不到不该让「选中」这一步失败 —— 真失效了,上层重扫时会发现文件读不出来。
     */
    private fun takePersistableRead(uri: Uri) {
        runCatching {
            activity.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
    }

    private fun documentUris(data: Intent?): List<Uri> {
        val clip = data?.clipData
        if (clip != null) {
            return (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
        }
        // 只挑了一个文件时走 data.data,多选才走 clipData。
        return listOfNotNull(data?.data)
    }

    // ---- 读取 ----

    private fun listChildren(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.argument<String>("treeUri")?.let(Uri::parse)
        if (treeUri == null) {
            result.error("invalid_argument", "Expected a tree uri", null)
            return
        }
        cancelled.set(false)
        offMain(
            work = { collectChildren(treeUri) },
            done = { outcome ->
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error("scan_failed", it.message, null) },
                )
            },
        )
    }

    /**
     * 递归收集 [treeUri] 下的文件条目(子目录一路走下去,目录本身不入结果)。
     *
     * 扫到一半没有权限了(SecurityException)只保留已收到的条目正常返回 —— 规格 §9:
     * 扫描中断不该让整次扫描失败,用户至少能看到已经扫出来的那些。
     */
    private fun collectChildren(treeUri: Uri): List<Map<String, Any?>> {
        val entries = mutableListOf<Map<String, Any?>>()
        val directories = ArrayDeque<String>()
        // tree uri 自己不是文档,得先换成根文档 id 才能列子项。
        directories.add(DocumentsContract.getTreeDocumentId(treeUri))
        while (directories.isNotEmpty()) {
            if (cancelled.get()) break
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri,
                directories.removeFirst(),
            )
            var query: Cursor? = null
            try {
                query = activity.contentResolver.query(
                    childrenUri,
                    CHILD_PROJECTION,
                    null,
                    null,
                    null,
                )
            } catch (error: SecurityException) {
                // 授权中途失效:保留已收到的条目正常返回(规格 §9),别让整次扫描失败。
                break
            }
            // provider 列不出这个目录就跳过它,继续扫别的兄弟目录。
            val rows = query ?: continue
            rows.use { cursor ->
                while (!cancelled.get() && cursor.moveToNext()) {
                    val documentId = cursor.stringAt(CHILD_ID) ?: continue
                    val mime = cursor.stringAt(CHILD_MIME).orEmpty()
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        directories.add(documentId)
                        continue
                    }
                    entries.add(
                        mapOf(
                            "uri" to DocumentsContract.buildDocumentUriUsingTree(
                                treeUri,
                                documentId,
                            ).toString(),
                            "name" to cursor.stringAt(CHILD_NAME).orEmpty(),
                            "size" to cursor.longAt(CHILD_SIZE),
                            "mime" to mime,
                            "lastModified" to cursor.longAt(CHILD_MODIFIED),
                        ),
                    )
                }
            }
        }
        return entries
    }

    private fun stat(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        if (uri == null) {
            result.error("invalid_argument", "Expected a document uri", null)
            return
        }
        offMain(
            work = { documentInfo(uri) },
            done = { outcome ->
                outcome.fold(
                    // 拿不到(已删除/没授权/不是文档 uri)按契约返回 null,不抛异常 ——
                    // Dart 侧用 null 表示「这个文件现在不可用」,由上层决定是重新授权还是标失效。
                    onSuccess = { info ->
                        result.success(
                            info?.let {
                                mapOf(
                                    "name" to it.name,
                                    "size" to it.size,
                                    "mime" to it.mime,
                                    "lastModified" to it.lastModified,
                                )
                            },
                        )
                    },
                    onFailure = { result.error("stat_failed", it.message, null) },
                )
            },
        )
    }

    /**
     * 查一个文档的展示信息。
     *
     * 一次 query 就够:`OpenableColumns` 与 `DocumentsContract.Document` 在
     * DocumentsProvider 的光标上是同一批列名(`_display_name`/`_size`/`mime_type`/
     * `last_modified`),所以列名可以混着用。
     *
     * 取不到(没有授权、已被删除、根本不是 SAF uri)一律返回 null。注意 size 在有些
     * provider 上是字符串列,`getLong` 会自己转;为 null 时给 0。
     */
    private fun documentInfo(uri: Uri): DocumentInfo? = runCatching {
        // tree uri 要换成根文档 uri 才查得到显示名;document uri 直接用。
        val queryUri = if (DocumentsContract.isDocumentUri(activity, uri)) {
            uri
        } else {
            DocumentsContract.buildDocumentUriUsingTree(
                uri,
                DocumentsContract.getTreeDocumentId(uri),
            )
        }
        activity.contentResolver.query(queryUri, INFO_PROJECTION, null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) {
                null
            } else {
                DocumentInfo(
                    name = cursor.stringAt(INFO_NAME)
                        ?: uri.lastPathSegment.orEmpty(),
                    size = cursor.longAt(INFO_SIZE),
                    mime = cursor.stringAt(INFO_MIME).orEmpty(),
                    lastModified = cursor.longAt(INFO_MODIFIED),
                )
            }
        }
    }.getOrNull()

    // ---- 播放用的描述符 ----

    private fun openFd(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        if (uri == null) {
            result.error("invalid_argument", "Expected a document uri", null)
            return
        }
        offMain(
            work = { openDescriptor(uri) },
            done = { outcome ->
                outcome.fold(
                    onSuccess = { (fd, descriptor) ->
                        // 存进 map 就是「桥持有」:GC 不会关它,只有 releaseFd/dispose 才关。
                        openFds[fd] = descriptor
                        result.success(
                            mapOf("fd" to fd, "path" to "/proc/self/fd/$fd"),
                        )
                    },
                    onFailure = { result.error("open_fd_failed", it.message, null) },
                )
            },
        )
    }

    private fun openDescriptor(uri: Uri): Pair<Int, ParcelFileDescriptor> {
        val descriptor = activity.contentResolver.openFileDescriptor(uri, "r")
            ?: throw IllegalStateException("Provider returned no file descriptor")
        // 不 detach:描述符对象由桥留着,fd 号在它的生命周期内一直有效。
        return descriptor.fd to descriptor
    }

    private fun releaseFd(call: MethodCall, result: MethodChannel.Result) {
        // Dart 的 int 到这边可能是 Integer 也可能是 Long,统一走 Number。
        val fd = call.argument<Number>("fd")?.toInt()
        if (fd == null) {
            result.error("invalid_argument", "Expected a descriptor id", null)
            return
        }
        // 幂等:同一个 fd 释放两次(播放页异常路径上会这么干)只是没事发生,不能抛。
        val descriptor = openFds.remove(fd)
        runCatching { descriptor?.close() }
        result.success(null)
    }

    // ---- 删除源文件 ----

    private fun deleteTree(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        if (uri == null) {
            result.error("invalid_argument", "Expected a document uri", null)
            return
        }
        offMain(
            work = { deleteDocument(uri) },
            done = { outcome ->
                outcome.fold(
                    onSuccess = { deleted ->
                        // 只在「应用内移除库 + 用户显式确认删源文件」时才会走到这里(默认不调);
                        // provider 拒绝删除时必须报错,否则用户以为文件已经删了。
                        if (deleted) {
                            result.success(null)
                        } else {
                            result.error("delete_refused", "Provider refused the delete", null)
                        }
                    },
                    onFailure = { result.error("delete_failed", it.message, null) },
                )
            },
        )
    }

    private fun deleteDocument(uri: Uri): Boolean {
        // deleteDocument 只吃文档 uri;用户授权拿到的是 tree uri,换一个再删。
        val documentUri = if (DocumentsContract.isDocumentUri(activity, uri)) {
            uri
        } else {
            DocumentsContract.buildDocumentUriUsingTree(
                uri,
                DocumentsContract.getTreeDocumentId(uri),
            )
        }
        return DocumentsContract.deleteDocument(activity.contentResolver, documentUri)
    }

    // ---- 收尾 ----

    fun dispose() {
        cancelled.set(true)
        channel?.setMethodCallHandler(null)
        channel = null
        pendingPick?.result?.error("activity_destroyed", "Activity was destroyed", null)
        pendingPick = null
        // 引擎都没了,播放器也一起没了;这时还留着的描述符是纯泄漏。
        openFds.values.forEach { runCatching { it.close() } }
        openFds.clear()
    }

    /**
     * 把 query/遍历挪到后台线程,结果一律回主线程再交给 [MethodChannel.Result]
     * —— result 必须在主线程上调用,否则 Flutter 会报线程错误。
     */
    private fun <T> offMain(work: () -> T, done: (Result<T>) -> Unit) {
        Thread {
            val outcome = runCatching(work)
            mainHandler.post { done(outcome) }
        }.start()
    }

    private fun Cursor.stringAt(index: Int): String? =
        if (index < 0 || isNull(index)) null else getString(index)

    private fun Cursor.longAt(index: Int): Long =
        if (index < 0 || isNull(index)) 0L else getLong(index)

    companion object {
        private const val METHOD_CHANNEL = "dream_manga_reader/local_media"
        private const val VIDEO_MIME = "video/*"
        private const val REQUEST_PICK_DIRECTORY = 0x4C01
        private const val REQUEST_PICK_FILES = 0x4C02
        private val GRANT_FLAGS =
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION

        /**
         * 单个文档的展示信息。一次查全:`OpenableColumns` 与 `DocumentsContract.Document`
         * 在 DocumentsProvider 的光标上是同一批列名,混着用没问题。
         */
        private val INFO_PROJECTION = arrayOf(
            OpenableColumns.DISPLAY_NAME,
            OpenableColumns.SIZE,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )

        /** 列一个目录的子项:上面的四个再加 document id(拼子 uri、判断是不是目录都要它)。 */
        private val CHILD_PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )

        // 下标与上面两个投影一一对应,别串了。
        private const val INFO_NAME = 0
        private const val INFO_SIZE = 1
        private const val INFO_MIME = 2
        private const val INFO_MODIFIED = 3
        private const val CHILD_ID = 0
        private const val CHILD_NAME = 1
        private const val CHILD_MIME = 2
        private const val CHILD_SIZE = 3
        private const val CHILD_MODIFIED = 4
    }
}
