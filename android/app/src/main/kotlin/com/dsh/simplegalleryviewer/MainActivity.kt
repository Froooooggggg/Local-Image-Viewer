package com.dsh.simplegalleryviewer

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer

/// 简易图集查看器
///
/// 原生侧承担三件事：
///  1. **音量键拦截**（需求：+ 上一页 / − 下一页），通过 EventChannel 上报。
///  2. **Storage Access Framework 统一内容层**：自己起文件/目录选择器，
///     并申请 **可持久化** 的 URI 授权（`file_picker` 不申请，导致授权
///     一重启就失效，这正是「压缩包打不开」的根因）。
///  3. **按字节区间随机读**：让 Dart 侧可以像读本地文件一样读 `content://`
///     文档，从而直接解析 zip 中央目录、按需解压单张图片，无需复制副本。
///
/// 本应用不申请任何存储权限，也不修改/删除任何用户文件：
/// 对 `content://` 只做 openInputStream / openFileDescriptor 读取。
class MainActivity : FlutterActivity() {

    private var volumeKeySink: EventChannel.EventSink? = null

    /// 正在挂起的 SAF 选择结果回调。
    private var pendingPick: ((Uri?) -> Unit)? = null

    /// 选择器必须用 startActivityForResult 才能拿到持久化授权标志；
    /// 这里直接走老接口，避免 registerForActivityResult 与 Flutter 生命周期的耦合。
    private val pickRequestCode = 0x5AF1

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VOLUME_KEY_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                volumeKeySink = events
            }

            override fun onCancel(arguments: Any?) {
                volumeKeySink = null
            }
        })

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SAF_CHANNEL
        ).setMethodCallHandler { call, result -> handleSafCall(call, result) }
    }

    // ------------------------------------------------------------------ SAF

    /// 在后台线程执行阻塞 I/O，并把结果投递回主线程。
    ///
    /// 平台通道的结果必须在主线程回调，所以这里显式切回。
    private fun <T> runOffMainThread(
        result: MethodChannel.Result,
        errorCode: String,
        errorMessage: String,
        work: () -> T
    ) {
        ioExecutor.execute {
            try {
                val value = work()
                runOnUiThread { result.success(value) }
            } catch (e: Throwable) {
                // 捕获 Throwable 而不只是 Exception：大图读取时的分配失败是
                // OutOfMemoryError（属于 Error），若让它逃逸到线程外，
                // 进程会直接崩溃而不是让这一张图显示失败。
                Log.w(TAG, "$errorMessage：${e.message}", e)
                runOnUiThread {
                    // 异常名一起带上：UnsupportedOperationException 之类
                    // 常常没有 message，只回 errorMessage 等于把线索丢掉，
                    // 排查时只能靠猜（曾经就是这样多花了一轮）。
                    result.error(
                        errorCode,
                        e.message ?: "$errorMessage（${e.javaClass.simpleName}）",
                        null
                    )
                }
            }
        }
    }

    private fun handleSafCall(call: MethodCall, result: MethodChannel.Result) {
        Log.i(TAG, "SAF 调用: ${call.method}")
        when (call.method) {
            "pickZip" -> launchPicker(
                Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/zip"
                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/zip", "application/x-zip-compressed", "*/*"))
                    // 关键：允许把授权持久化，重启后仍可读取原文件。
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                },
                result
            )

            "pickFolder" -> launchPicker(
                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                },
                result
            )

            "readBytes" -> {
                val uri = Uri.parse(call.argument<String>("uri"))
                val offset = (call.argument<Number>("offset"))?.toLong() ?: 0L
                val length = (call.argument<Number>("length"))?.toInt() ?: 0
                // I/O 放到后台线程：平台通道默认在主线程回调，阻塞读会卡界面。
                runOffMainThread(result, "READ_FAILED", "读取失败") {
                    readBytes(uri, offset, length)
                }
            }

            "sizeOf" -> {
                val uri = Uri.parse(call.argument<String>("uri"))
                runOffMainThread(result, "SIZE_FAILED", "无法获取大小") {
                    sizeOf(uri)
                }
            }

            "listTree" -> {
                val uri = Uri.parse(call.argument<String>("uri"))
                runOffMainThread(result, "LIST_FAILED", "无法读取目录") {
                    listTree(uri)
                }
            }

            // 取一个目录的**上一级**目录的树 URI。
            //
            // SAF 的树 URI 没有"父目录"接口，必须自己算：树 URI 形如
            // content://authority/tree/<docId>，docId 是
            // "primary:便携存储/二次元/Eh本地" 这样的相对路径。
            // 去掉最后一段即得上一级；已经是顶层（如 "primary:"）时返回 null，
            // 由 Dart 侧据此停止上溯。
            "parentTreeUri" -> {
                val uri = Uri.parse(call.argument<String>("uri"))
                try {
                    result.success(parentTreeUri(uri))
                } catch (e: Exception) {
                    Log.w(TAG, "取上级目录失败：${e.message}")
                    result.success(null)
                }
            }

            "persistedPermissions" -> result.success(persistedPermissions())

            // ------------------------------------------------------------ 写入
            //
            // 既有约定是"不碰用户文件"。下面这组方法只服务于「批量翻译」：
            // 在用户**自己选的**输出目录里创建本应用产出的成品图与 manifest.json，
            // 覆盖的也只有同名产物，绝不删除或改写用户的原始图片。

            "pickOutputTree" -> launchPicker(
                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    // 写授权必须一起申请，否则后续 createDocument 会抛 SecurityException。
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                },
                // persistWrite=true 时把写授权也持久化，否则应用重启后无法续写。
                result,
                persistWrite = true
            )

            "createDirectory" -> {
                val parent = Uri.parse(call.argument<String>("parentUri"))
                val name = call.argument<String>("name") ?: ""
                runOffMainThread(result, "MKDIR_FAILED", "无法创建目录") {
                    createDirectory(parent, name)
                }
            }

            "createFile" -> {
                val parent = Uri.parse(call.argument<String>("parentUri"))
                val name = call.argument<String>("name") ?: ""
                val mime = call.argument<String>("mime") ?: "application/octet-stream"
                runOffMainThread(result, "MKFILE_FAILED", "无法创建文件") {
                    createFile(parent, name, mime)
                }
            }

            "writeBytes" -> {
                val uri = Uri.parse(call.argument<String>("uri"))
                val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                runOffMainThread(result, "WRITE_FAILED", "写入失败") {
                    writeBytes(uri, bytes)
                    true
                }
            }

            // 原子写：先写 .tmp 再改名。manifest.json 每页都要重写，
            // 中途被杀时宁可丢一份新 manifest，也不要留下半截 JSON。
            "writeFileAtomic" -> {
                val parent = Uri.parse(call.argument<String>("parentUri"))
                val name = call.argument<String>("name") ?: ""
                val mime = call.argument<String>("mime") ?: "application/octet-stream"
                val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                runOffMainThread(result, "WRITE_FAILED", "写入失败") {
                    writeFileAtomic(parent, name, mime, bytes)
                }
            }

            "exists" -> {
                val uri = Uri.parse(call.argument<String>("uri"))
                runOffMainThread(result, "EXISTS_FAILED", "无法判断文件是否存在") {
                    exists(uri)
                }
            }

            // 删除一个**文件**（不是目录）。
            //
            // 只有一个调用方：「重译第 N–M 页」在重翻之前先把这一段旧的
            // page-NNNN.jpg 删掉。Dart 侧只会传从译文目录 listTree 出来、
            // 且名字匹配 page-\\d+\\.(jpg|png|gif) 的子项，目录一律拒绝。
            "deleteFile" -> {
                val uri = Uri.parse(call.argument<String>("uri"))
                runOffMainThread(result, "DELETE_FAILED", "无法删除文件") {
                    deleteFile(uri)
                }
            }

            // 系统当前可用内存（字节）。
            //
            // 用途：播放动图前预判内存。播放一个 GIF 需要"帧数 × 单帧字节"的
            // 连续内存，若超过可用内存会直接把进程拖死（表现是界面卡住不动，
            // 连崩溃日志都没有）。用 ActivityManager 的这个值而不是自己估算，
            // 是因为它与内核判断"该不该杀进程"用的是同一个口径。
            "availableMemory" -> {
                try {
                    val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val info = ActivityManager.MemoryInfo()
                    am.getMemoryInfo(info)
                    result.success(info.availMem)
                } catch (e: Exception) {
                    Log.w(TAG, "取可用内存失败：${e.message}")
                    result.success(null)
                }
            }

            "releasePersistable" -> {
                val uri = Uri.parse(call.argument<String>("uri"))
                try {
                    contentResolver.releasePersistableUriPermission(
                        uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun launchPicker(
        intent: Intent,
        result: MethodChannel.Result,
        // 输出目录要写文件，需要连写授权一起持久化；读取类选择器保持原样。
        persistWrite: Boolean = false,
    ) {
        Log.i(TAG, "launchPicker action=${intent.action} type=${intent.type}")
        if (pendingPick != null) {
            Log.w(TAG, "launchPicker 被拒：已有选择器在打开")
            result.error("BUSY", "已有选择器正在打开", null)
            return
        }
        pendingPick = { uri ->
            Log.i(TAG, "picker 返回 uri=$uri")
            if (uri == null) {
                result.success(null)
            } else {
                // 把授权持久化：此后即便进程重启、缓存被清，也能继续读原文件。
                //
                // 树 URI 的读写授权已由 onActivityResult 里的
                // takeTreePermissionIfNeeded 按 data.flags 持久化过；这里若再
                // 用「只读」调一次，反而会把写权限降级成只读，所以跳过。
                var persisted = false
                try {
                    if (!persistWrite || !isTreeUri(uri)) {
                        contentResolver.takePersistableUriPermission(
                            uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                        )
                    }
                    persisted = true
                } catch (e: SecurityException) {
                    // 某些提供方不支持持久化授权，此时仍可在本次会话内读取。
                    Log.w(TAG, "takePersistableUriPermission 失败：${e.message}")
                }

                // 任何提供方异常都不允许冒泡到 onActivityResult —— 那会直接崩溃
                // 整个应用（曾经就因为对树 URI 调 query 而崩过）。
                val name = try {
                    displayName(uri)
                } catch (e: Exception) {
                    Log.w(TAG, "取显示名失败：${e.message}")
                    "未命名"
                }
                val isDir = try {
                    isTreeUri(uri)
                } catch (_: Exception) {
                    false
                }

                // 刻意**不**在这里取长度：sizeOf 可能要走二分探测，是阻塞 I/O，
                // 而现在处于 onActivityResult（主线程），会让"点导入"明显卡顿。
                // 长度改由 Dart 侧按需通过 sizeOf 通道获取（已在后台线程执行）。
                Log.i(TAG, "选择结果 name=$name persisted=$persisted isDirectory=$isDir")
                result.success(
                    mapOf(
                        "uri" to uri.toString(),
                        "name" to name,
                        "persisted" to persisted,
                        "isDirectory" to isDir
                    )
                )
            }
        }
        try {
            startActivityForResult(intent, pickRequestCode)
            Log.i(TAG, "startActivityForResult 已调用")
        } catch (e: Exception) {
            Log.e(TAG, "无法打开选择器", e)
            pendingPick = null
            result.error("NO_PICKER", e.message ?: "无法打开选择器", null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == pickRequestCode) {
            val callback = pendingPick
            pendingPick = null
            try {
                val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
                // 目录选择返回的树 URI 需要额外取回持久化标志
                uri?.let { takeTreePermissionIfNeeded(it, data) }
                callback?.invoke(uri)
            } catch (e: Throwable) {
                // 绝不能把异常抛回 Activity 生命周期：那会以
                // "Failure delivering result" 的形式让应用直接崩溃。
                // 出错时回一个 null，Dart 侧会当作「用户取消」优雅处理。
                Log.e(TAG, "处理选择结果失败", e)
                try {
                    callback?.invoke(null)
                } catch (_: Throwable) {
                }
            }
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun takeTreePermissionIfNeeded(uri: Uri, data: Intent?) {
        if (!isTreeUri(uri)) return
        val flags = data?.flags ?: 0
        // 按**提供方实际授予的**权限持久化，而不是硬编码成只读。
        //
        // 事故：输出目录（pickOutputTree）申请了读+写，这里却把写标志位与掉，
        // 只持久化了读权限 —— 于是「选一次就记住」只在本次进程内有效，
        // 应用重启后写产物会抛 SecurityException。读类选择器本来就只有读标志，
        // 走到这里行为不变。
        val takeFlags = flags and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        if (takeFlags == 0) return
        try {
            contentResolver.takePersistableUriPermission(uri, takeFlags)
        } catch (_: Exception) {
            // 已在 launchPicker 里尝试过，这里失败不影响会话内使用。
        }
    }

    /// 判断一个 URI 是不是**目录树** URI。
    ///
    /// 绝不能用 `DocumentsContract.isTreeUri`！它只看路径第一段是不是 "tree"，
    /// 而树里的**子文档** URI 形如
    /// `content://…/tree/primary%3ADownload/document/primary%3ADownload%2F1.jpg`，
    /// 第一段同样是 "tree"，于是子文档也被判成目录。
    ///
    /// 后果（真实事故）：[sizeOf] 开头的 `if (isTreeUri(uri)) return 0L` 会把
    /// 一张真实存在的图片报成 0 字节，批量翻译因此抛 `Bad state: 文件为空`。
    ///
    /// 也不能用「路径段正好两段」来判断（1.3.1~1.3.7 的错误）：树 URI 的
    /// documentId 里带子目录时会被编码成 `primary%3AEhViewer%2Fdownload%2F…`，
    /// 深度不同、解码方式不同，段数并不可靠。可靠的特征是**路径里有没有
    /// `/document/` 这一段**：树 URI 只有 `tree/<documentId>`，子文档 URI 才会
    /// 多出 `/document/<documentId>`。用 encodedPath 判断，避免 %2F 解码后
    /// 产生歧义。
    ///
    /// 真实事故 2：用户导入 `…/tree/primary%3AEhViewer%2Fdownload%2F1489…`
    /// 时被判成"非树"，接着调 `getDocumentId()` 抛 `Invalid URI`，导入直接报
    /// 「目录下没有图片」。
    private fun isTreeUri(uri: Uri): Boolean {
        val segments = uri.pathSegments
        if (segments.isEmpty() || segments[0] != "tree") return false
        return !(uri.encodedPath ?: "").contains("/document/")
    }

    /// 从任意目录 URI 取出它所属树的 documentId（不解码 %2F 再拼，直接从
    /// 编码路径里切）。取不到返回 null。
    private fun treeDocumentIdOf(uri: Uri): String? {
        val raw = uri.encodedPath ?: return null
        val marker = "/tree/"
        val i = raw.indexOf(marker)
        if (i < 0) return null
        val rest = raw.substring(i + marker.length)
        val cut = rest.indexOf("/document/")
        val idPart = if (cut < 0) rest else rest.substring(0, cut)
        if (idPart.isEmpty()) return null
        return try {
            Uri.decode(idPart)
        } catch (_: Exception) {
            null
        }
    }

    /// 目录自身的 documentId：树 URI 就是树 id；子文档 URI 取 `/document/`
    /// 之后那一段。
    private fun documentIdOf(uri: Uri): String? {
        val raw = uri.encodedPath ?: return null
        val marker = "/document/"
        val i = raw.lastIndexOf(marker)
        if (i < 0) return treeDocumentIdOf(uri)
        val idPart = raw.substring(i + marker.length)
        if (idPart.isEmpty()) return null
        return try {
            Uri.decode(idPart)
        } catch (_: Exception) {
            null
        }
    }

    private fun persistedPermissions(): List<Map<String, Any?>> =
        contentResolver.persistedUriPermissions.map {
            mapOf(
                "uri" to it.uri.toString(),
                "read" to it.isReadPermission,
                "write" to it.isWritePermission
            )
        }

    /// 单次读取的字节上限。
    ///
    /// 原生的 readBytes 会按请求长度一次性分配 ByteArray；过大的请求容易直接
    /// 触发 Java 侧分配失败，进而在引擎里表现为 JNI 异常崩溃。
    /// 因此这里对单次分配设上限。
    ///
    /// **必须 >= Dart 侧的 kMaxReadChunk**（byte_source.dart 里定义的 8 MB）：
    /// 两者不一致时，Dart 会发出超过本上限的请求，而本函数**静默返回较短的结果**，
    /// 于是 zip 条目被截断、解压出残缺数据，表现为"某些图片固定读不出来"。
    /// 这正是"超大压缩包里靠后的图片读不出来"的成因。
    private val maxReadChunk = 8 * 1024 * 1024

    /// 读取 `content://` 文档的 [offset, offset+length) 区间。
    ///
    /// 注意：**返回的数组可能短于请求长度**（被 [maxReadChunk] 钳制，或已到末尾）。
    /// 调用方必须自行判断长度是否满足，不能假定一定读满。
    private fun readBytes(uri: Uri, offset: Long, length: Int): ByteArray {
        if (length <= 0) return ByteArray(0)
        val want = if (length > maxReadChunk) maxReadChunk else length

        try {
            openSeekable(uri, offset, want)?.let { return it }
        } catch (_: Exception) {
            // 落到下面的顺序读回退
        }
        return readSequentially(uri, offset, want)
    }

    /// 快路径：可定位描述符 + FileChannel.position。
    private fun openSeekable(uri: Uri, offset: Long, length: Int): ByteArray? {
        val pfd = contentResolver.openFileDescriptor(uri, "r") ?: return null
        pfd.use { descriptor ->
            FileInputStream(descriptor.fileDescriptor).use { stream ->
                stream.channel.use { channel ->
                    channel.position(offset)
                    val buffer = ByteBuffer.allocate(length)
                    var total = 0
                    while (buffer.hasRemaining()) {
                        val read = channel.read(buffer)
                        if (read <= 0) break
                        total += read
                    }
                    return if (total == length) buffer.array() else buffer.array().copyOf(total)
                }
            }
        }
    }

    /// 慢路径：顺序 skip 到目标位置。
    private fun readSequentially(uri: Uri, offset: Long, length: Int): ByteArray {
        val input = contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("无法打开文档")
        input.use { stream ->
            var remaining = offset
            val scratch = ByteArray(64 * 1024)
            while (remaining > 0) {
                val skipped = stream.skip(remaining)
                if (skipped > 0) {
                    remaining -= skipped
                } else {
                    // skip 返回 0 时改为实读，避免死循环。
                    val want = minOf(remaining, scratch.size.toLong()).toInt()
                    if (stream.read(scratch, 0, want) <= 0) {
                        throw IllegalStateException("读取位置超出文件末尾")
                    }
                    remaining -= want
                }
            }
            val out = ByteArray(length)
            var filled = 0
            while (filled < length) {
                val read = stream.read(out, filled, length - filled)
                if (read <= 0) break
                filled += read
            }
            return if (filled == length) out else out.copyOf(filled)
        }
    }

    /// 只走**廉价元数据**的取长度：不做二分探测。
    ///
    /// 列出目录时对每个子项都要取大小，如果这里做重量级探测，
    /// 目录一多就会明显卡顿（这正是"点导入会卡一下"的来源之一）。
    private fun quickSizeOf(uri: Uri): Long {
        if (isTreeUri(uri)) return 0L
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    for (name in QUICK_SIZE_COLUMNS) {
                        val idx = cursor.getColumnIndex(name)
                        if (idx >= 0 && !cursor.isNull(idx)) {
                            val v = cursor.getLong(idx)
                            if (v > 0) return v
                        }
                    }
                }
            }
        } catch (_: Exception) {
        }
        try {
            val size = sizeViaDocumentFile(uri)
            if (size > 0) return size
        } catch (_: Exception) {
        }
        try {
            contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                if (pfd.statSize > 0) return pfd.statSize
            }
        } catch (_: Exception) {
        }
        return 0L
    }

    /// 取得文档的字节长度。
    ///
    /// 实测小米的 externalstorage 对**部分文档**不返回 `OpenableColumns.SIZE`，
    /// 单靠一次 query 会得到 0，进而被误判成"文件太小，不是有效的 zip"。
    ///
    /// 因此按可靠性递减多路尝试：
    ///   ① 逐个候选列名查询（SIZE / COLUMN_SIZE / 模糊匹配）
    ///   ② DocumentFile.length()
    ///   ③ 文件描述符 statSize
    ///   ④ **二分探测**（最后手段）
    ///
    /// ④ 必须是二分而不是顺序读：用户有 10 GB 的压缩包，顺序数一遍字节要读
    /// 10 GB —— 那正是之前"点导入会卡一下"的原因。
    /// 二分只需约 2·log2(size) 次探测，每次只读极小一段。
    private fun sizeOf(uri: Uri): Long {
        // 树 URI（目录）没有大小。
        if (isTreeUri(uri)) return 0L

        // ① 候选列名。不同提供方用的列名不一致，逐个试。
        val candidates = listOf(
            OpenableColumns.SIZE,
            DocumentsContract.Document.COLUMN_SIZE,
            "_size",
            "size"
        )
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    for (name in candidates) {
                        val idx = cursor.getColumnIndex(name)
                        if (idx >= 0 && !cursor.isNull(idx)) {
                            val v = cursor.getLong(idx)
                            if (v > 0) {
                                Log.i(TAG, "sizeOf 命中列 $name = $v")
                                return v
                            }
                        }
                    }
                    // 仍没有就模糊匹配一个名字里带 size 的数值列。
                    for (i in 0 until cursor.columnCount) {
                        val col = cursor.getColumnName(i) ?: continue
                        if (!col.contains("size", ignoreCase = true)) continue
                        if (cursor.isNull(i)) continue
                        val v = try {
                            cursor.getLong(i)
                        } catch (_: Exception) {
                            continue
                        }
                        if (v > 0) {
                            Log.i(TAG, "sizeOf 模糊命中列 $col = $v")
                            return v
                        }
                    }
                    Log.w(TAG, "sizeOf 查询成功但无可用大小列：" +
                            (0 until cursor.columnCount).joinToString(",") {
                                cursor.getColumnName(it) ?: "?"
                            })
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "sizeOf 查询失败：${e.message}")
        }

        // ② DocumentFile
        try {
            val size = sizeViaDocumentFile(uri)
            if (size > 0) {
                Log.i(TAG, "sizeOf 通过 DocumentFile 得到 $size")
                return size
            }
        } catch (e: Exception) {
            Log.w(TAG, "sizeOf DocumentFile 失败：${e.message}")
        }

        // ③ 文件描述符
        try {
            contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                if (pfd.statSize > 0) {
                    Log.i(TAG, "sizeOf 通过 statSize 得到 ${pfd.statSize}")
                    return pfd.statSize
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "sizeOf 打开描述符失败：${e.message}")
        }

        // ④ 二分探测
        val probed = sizeByBinaryProbe(uri)
        if (probed > 0) {
            Log.w(TAG, "sizeOf 通过二分探测得到 $probed")
        } else {
            Log.e(TAG, "sizeOf 全部手段失败，返回 0")
        }
        return probed
    }

    /// 用 DocumentsContract 直接取长度（比 DocumentFile.length 更底层一档）。
    private fun sizeViaDocumentFile(uri: Uri): Long {
        val doc = DocumentFile.fromSingleUri(this, uri) ?: return 0L
        if (doc.isDirectory) return 0L
        return doc.length()
    }

    /// 二分探测文档长度。
    ///
    /// 先用 1、2、4、8… 的偏移找上界（读到空即为越界），
    /// 再在上界与下界之间二分到精确值。
    /// 每次探测只读一小段，因此对 10 GB 的文件也只需几十次极小的读取。
    private fun sizeByBinaryProbe(uri: Uri): Long {
        // 读 [offset, offset+len) 是否至少能读到 1 字节
        fun hasDataAt(offset: Long): Boolean {
            if (offset <= 0) return true
            return try {
                val probe = readBytesSafe(uri, offset, 1)
                probe.isNotEmpty()
            } catch (_: Exception) {
                false
            }
        }

        var low = 0L
        var high = 1L
        // 找上界
        var guard = 0
        while (hasDataAt(high) && guard < 48) {
            low = high
            high *= 2
            guard++
        }
        if (guard >= 48) {
            // 极端情况：超过 2^48 字节，放弃。
            return 0L
        }
        if (low == 0L) {
            return if (hasDataAt(1L)) 1L else 0L
        }

        // 二分：找最后一个"有数据"的偏移
        while (high - low > 1) {
            val mid = low + (high - low) / 2
            if (hasDataAt(mid)) {
                low = mid
            } else {
                high = mid
            }
        }
        return low
    }

    /// 只读不抛的封装（供探测使用）。
    private fun readBytesSafe(uri: Uri, offset: Long, length: Int): ByteArray =
        readBytes(uri, offset, length)

    /// 取得文档或目录的显示名。
    ///
    /// **树 URI（目录）不能直接 query** —— 会抛
    /// `UnsupportedOperationException: Unsupported Uri .../tree/...`。
    /// 必须走 DocumentsContract（即 DocumentFile.getName()）。
    /// 这里同时兜底 query 与 URI 末段解析，确保任何提供方都不会让调用方崩溃。
    private fun displayName(uri: Uri): String {
        if (isTreeUri(uri)) {
            try {
                DocumentFile.fromTreeUri(this, uri)?.name?.let { return it }
            } catch (e: Exception) {
                Log.w(TAG, "树 URI 取名字失败：${e.message}")
            }
            return treeUriLabel(uri)
        }

        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0 && !cursor.isNull(idx)) return cursor.getString(idx)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "displayName 查询失败：${e.message}")
        }

        try {
            DocumentFile.fromSingleUri(this, uri)?.name?.let { return it }
        } catch (_: Exception) {
        }

        return treeUriLabel(uri)
    }

    /// 从 URI 末段解析出可读名字（树 URI 形如 .../tree/primary%3ADownload）。
    private fun treeUriLabel(uri: Uri): String {
        val raw = uri.lastPathSegment ?: return "未命名"
        val decoded = try {
            java.net.URLDecoder.decode(raw, "UTF-8")
        } catch (_: Exception) {
            raw
        }
        val slash = decoded.lastIndexOf('/')
        val colon = decoded.lastIndexOf(':')
        val cut = maxOf(slash, colon)
        return if (cut >= 0 && cut < decoded.length - 1) {
            decoded.substring(cut + 1)
        } else {
            decoded
        }
    }

    /// 计算一个树 URI 的上一级树 URI；已是顶层时返回 null。
    private fun parentTreeUri(uri: Uri): String? {
        if (!isTreeUri(uri)) return null
        val docId = treeDocumentIdOf(uri) ?: return null
        // docId = "<volumeId>:<相对路径>"，例如 "primary:便携存储/二次元/Eh本地"
        val colon = docId.indexOf(':')
        if (colon < 0) return null
        val volume = docId.substring(0, colon)
        val path = docId.substring(colon + 1).trim('/')
        if (path.isEmpty()) return null // 已经是该卷的顶层

        val slash = path.lastIndexOf('/')
        val parentPath = if (slash < 0) "" else path.substring(0, slash)
        val parentDocId = if (parentPath.isEmpty()) "$volume:" else "$volume:$parentPath"

        return try {
            DocumentsContract.buildTreeDocumentUri(uri.authority, parentDocId).toString()
        } catch (e: Exception) {
            Log.w(TAG, "构造上级树 URI 失败：${e.message}")
            null
        }
    }

    /// 列出一个 SAF 树（或一个目录文档）的直接子项。
    ///
    /// 坑：`DocumentFile.fromSingleUri(...).listFiles()` 也会抛
    /// `UnsupportedOperationException` —— `SingleDocumentFile` 根本不能枚举。
    /// 翻译产物目录正是「树里的子目录文档 URI」，用它枚举只会得到空列表，
    /// 于是翻译图集永远导不进来（"存不到翻译图集里"就是这个）。
    /// 现在两种情况统一走 `DocumentsContract` 的 children 查询。
    private fun listTree(uri: Uri): List<Map<String, Any?>> =
        childrenOfDirectory(uri).map {
            mapOf(
                "uri" to it.uri.toString(),
                "name" to it.name,
                "isDirectory" to it.isDirectory,
                "size" to it.size,
                // 文件夹图集按"图片时间"排序需要它；与 size 同一次查询取回。
                "lastModified" to it.lastModified
            )
        }

    /// 子项元数据。
    private data class ChildDoc(
        val uri: Uri,
        val name: String,
        val isDirectory: Boolean,
        val size: Long,
        val lastModified: Long
    )

    /// 查询任意目录（树 URI 或树内目录文档 URI）的直接子项。
    ///
    /// 注意不能先调 `DocumentsContract.getDocumentId()`：对「带子目录的树 URI」
    /// 它会抛 `Invalid URI`（1.3.8 之前导入深层目录直接报"没有图片"就是这个）。
    /// 一律自己从 encodedPath 里切 id。
    private fun childrenOfDirectory(parent: Uri): List<ChildDoc> {
        val treeUri: Uri
        val parentId: String
        try {
            val pid = documentIdOf(parent) ?: return emptyList()
            val treeId = treeDocumentIdOf(parent) ?: pid
            parentId = pid
            treeUri = DocumentsContract.buildTreeDocumentUri(parent.authority, treeId)
        } catch (e: Exception) {
            Log.w(TAG, "解析目录标识失败：${e.message}")
            return emptyList()
        }
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        val list = ArrayList<ChildDoc>()
        try {
            contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED
                ),
                null,
                null,
                null
            )?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0) ?: continue
                    val name = c.getString(1) ?: continue
                    val mime = if (c.isNull(2)) null else c.getString(2)
                    val isDir = mime == DocumentsContract.Document.MIME_TYPE_DIR
                    val size = if (isDir || c.isNull(3)) 0L else c.getLong(3)
                    val modified = if (c.isNull(4)) 0L else c.getLong(4)
                    list.add(
                        ChildDoc(
                            DocumentsContract.buildDocumentUriUsingTree(treeUri, id),
                            name,
                            isDir,
                            size,
                            modified
                        )
                    )
                }
            }
        } catch (e: Exception) {
            // 某些提供方不支持枚举时不要把导入整条链路打断。
            Log.w(TAG, "枚举目录失败：${e.message}")
        }
        return list
    }

    // ------------------------------------------------------- 写入（批量翻译产物）

    /// 把一个 URI 当 DocumentFile 用。
    ///
    /// 树 URI 用 fromTreeUri：它代表"已获授权的目录"，可枚举、可在里面创建；
    /// 其他 URI 用 fromSingleUri：只能读写自身，不能当目录用。
    private fun asDocumentFile(uri: Uri): DocumentFile =
        if (isTreeUri(uri)) {
            DocumentFile.fromTreeUri(this, uri)
                ?: throw IllegalArgumentException("无法访问目录：$uri")
        } else {
            DocumentFile.fromSingleUri(this, uri)
                ?: throw IllegalArgumentException("无法访问文件：$uri")
        }

    /// 在 [parent] 下建目录；同名目录已存在时直接复用它（续跑就靠这个）。
    ///
    /// 只支持树 URI 作为父目录：翻译的根目录就是用户选的树，子目录由
    /// [_createFile] 直接在文档 URI 上建，不会再走这里。
    private fun createDirectory(parent: Uri, name: String): String {
        val dir = DocumentFile.fromTreeUri(this, parent)
            ?: throw IllegalArgumentException("无法访问目录：$parent")
        val existing = dir.findFile(name)
        if (existing != null && existing.isDirectory) return existing.uri.toString()
        val created = dir.createDirectory(name)
            ?: throw java.io.IOException("创建目录失败：$name")
        return created.uri.toString()
    }

    /// 在 [parent] 下建文件，同名文件会被替换（覆盖的只是本应用上次的产物）。
    ///
    /// 坑：`DocumentFile.fromSingleUri()` 返回的是 `SingleDocumentFile`，
    /// 它的 `createFile()`/`findFile()` 直接抛 `UnsupportedOperationException`，
    /// 根本不能当目录用。翻译的产物目录恰恰是"树里的子目录文档 URI"，
    /// 于是每一页都报 `MKFILE_FAILED`。所以这里分两条路：
    ///   * 父是真树 URI（用户选的根） → 继续用 DocumentFile；
    ///   * 父是子目录文档 URI → 用 `DocumentsContract` 的文档级 API，
    ///     按 children 查询找到并删掉同名旧文件，再 `createDocument`。
    private fun createFile(parent: Uri, name: String, mime: String): String {
        if (isTreeUri(parent)) {
            val dir = DocumentFile.fromTreeUri(this, parent)
                ?: throw IllegalArgumentException("无法访问目录：$parent")
            dir.findFile(name)?.delete()
            val f = dir.createFile(mime, name)
                ?: throw java.io.IOException("创建文件失败：$name")
            return normalizeName(f, name) ?: f.uri.toString()
        }
        childUrisOf(parent, name).forEach { uri ->
            try {
                DocumentsContract.deleteDocument(contentResolver, uri)
            } catch (e: Exception) {
                Log.w(TAG, "删除同名旧文件失败：${e.message}")
            }
        }
        val created = DocumentsContract.createDocument(contentResolver, parent, mime, name)
            ?: throw java.io.IOException("创建文件失败：$name")
        val docFile = DocumentFile.fromSingleUri(this, created)
        return normalizeName(docFile, name) ?: created.toString()
    }
    /// 提供方按 MIME 自动补扩展名时（`page-0001.jpg.jpg`），把名字改回来。
    private fun normalizeName(f: DocumentFile?, name: String): String? {
        if (f == null) return null
        if (f.name != name) {
            val renamed = try {
                DocumentsContract.renameDocument(contentResolver, f.uri, name)
            } catch (e: Exception) {
                Log.w(TAG, "重命名失败（保留提供方给的名字）：${e.message}")
                null
            }
            return (renamed ?: f.uri).toString()
        }
        return f.uri.toString()
    }

    /// 列出 [parent] 下叫 [name] 的子文档 URI。
    ///
    /// 与 [childrenOfDirectory] 同一套查询，因此「树 URI」和「树内子目录文档
    /// URI」都能用（`DocumentFile` 的两种实现分别缺枚举或缺创建能力）。
    private fun childUrisOf(parent: Uri, name: String): List<Uri> =
        childrenOfDirectory(parent).filter { it.name == name }.map { it.uri }

    /// 覆盖写入整个文件（`wt` 模式会截断旧内容）。
    private fun writeBytes(uri: Uri, bytes: ByteArray) {
        require(bytes.size <= MAX_WRITE_BYTES) {
            "单次写入超过上限：${bytes.size} 字节"
        }
        val out = contentResolver.openOutputStream(uri, "wt")
            ?: throw java.io.IOException("无法打开输出流：$uri")
        out.use {
            it.write(bytes)
            it.flush()
        }
    }

    /// 原子写：先写 `<name>.tmp`，再把旧的 `<name>` 删掉并改名。
    ///
    /// manifest.json 每处理完一页就要重写一次。若直接覆盖，进程被杀可能留下
    /// 半截 JSON，续跑时就无法判断哪些页已完成；先写临时文件能保证
    /// 读到的那份总是完整的（最坏情况是丢最后一次进度）。
    private fun writeFileAtomic(
        parent: Uri,
        name: String,
        mime: String,
        bytes: ByteArray
    ): String {
        val tmpName = "$name.tmp"
        // 建临时文件也走 createFile：它会按父 URI 类型选对 API
        // （子目录文档 URI 不能用 DocumentFile 建文件）。
        val tmp = createFile(parent, tmpName, mime)
        writeBytes(Uri.parse(tmp), bytes)
        // DocumentsContract 的 rename 不允许目标已存在，先删旧文件。
        childUrisOf(parent, name).forEach { uri ->
            try {
                DocumentsContract.deleteDocument(contentResolver, uri)
            } catch (e: Exception) {
                Log.w(TAG, "删除旧文件失败：${e.message}")
            }
        }
        return DocumentsContract.renameDocument(contentResolver, Uri.parse(tmp), name)
            ?.toString()
            ?: throw java.io.IOException("重命名失败：$name")
    }

    private fun exists(uri: Uri): Boolean = try {
        asDocumentFile(uri).exists()
    } catch (e: Exception) {
        Log.w(TAG, "判断文件是否存在失败：${e.message}")
        false
    }

    /// 删除一个文件。**拒绝删目录**，也拒绝非 content:// 的 URI。
    ///
    /// 这是本应用唯一的删除入口，只服务于「重译」：把第 N–M 页已经生成
    /// 的译文图删掉，好让这批页重新翻。原始图集永远不经过这里。
    private fun deleteFile(uri: Uri): Boolean {
        require(uri.scheme == "content") { "只允许删除 content:// 文件：$uri" }
        val doc = asDocumentFile(uri)
        if (doc.isDirectory) throw IllegalArgumentException("拒绝删除目录：$uri")
        return try {
            val ok = DocumentsContract.deleteDocument(contentResolver, uri)
            Log.i(TAG, "删除文件（deleteDocument=$ok）：$uri")
            ok
        } catch (e: Exception) {
            Log.w(TAG, "deleteDocument 失败，改用 DocumentFile.delete：${e.message}")
            val ok = doc.delete()
            Log.i(TAG, "删除文件（DocumentFile=$ok）：$uri")
            ok
        }
    }

    /// 取文档的最后修改时间（毫秒）。取不到时返回 0。
    ///
    /// 与 [quickSizeOf] 一样走廉价的列查询：目录枚举时每个子项都会调用一次，
    /// 不能用重量级探测。
    private fun lastModifiedOf(uri: Uri): Long {
        try {
            contentResolver.query(
                uri,
                arrayOf(DocumentsContract.Document.COLUMN_LAST_MODIFIED),
                null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val i = cursor.getColumnIndex(
                        DocumentsContract.Document.COLUMN_LAST_MODIFIED
                    )
                    if (i >= 0 && !cursor.isNull(i)) return cursor.getLong(i)
                }
            }
        } catch (e: Exception) {
            Log.d(TAG, "取修改时间失败：${e.message}")
        }
        return 0L
    }

    // ------------------------------------------------------------- 音量键

    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent): Boolean {
        val sink = volumeKeySink
        if (sink != null) {
            when (keyCode) {
                android.view.KeyEvent.KEYCODE_VOLUME_UP -> {
                    sink.success("up")
                    return true
                }
                android.view.KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    sink.success("down")
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: android.view.KeyEvent): Boolean {
        if (volumeKeySink != null &&
            (keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP ||
                    keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN)
        ) {
            return true
        }
        return super.onKeyUp(keyCode, event)
    }

    companion object {
        private const val TAG = "SGV-SAF"
        private const val VOLUME_KEY_CHANNEL = "simple_gallery_viewer/volume_keys"
        private const val SAF_CHANNEL = "simple_gallery_viewer/saf"

        /// 单次写入上限，与 Dart 侧以及翻译服务端的 32 MiB 体量限制保持一致。
        private const val MAX_WRITE_BYTES = 32 * 1024 * 1024

        /// 取大小时优先尝试的列名。不同提供方用的列名不一致，
        /// 只试 OpenableColumns.SIZE 会漏（实测小米对部分文档不返回它）。
        private val QUICK_SIZE_COLUMNS = listOf(
            OpenableColumns.SIZE,
            DocumentsContract.Document.COLUMN_SIZE,
            "_size",
            "size"
        )

        /// 文件系统读写用的后台线程池。
        ///
        /// 平台通道的处理器默认在主线程上执行；`sizeOf` / `listTree` / `readBytes`
        /// 都是阻塞 I/O，放在主线程会让界面卡顿（用户反馈过"点导入会卡一下"）。
        private val ioExecutor: java.util.concurrent.ExecutorService =
            java.util.concurrent.Executors.newFixedThreadPool(2) { r ->
                Thread(r, "sgv-saf-io").apply { isDaemon = true }
            }
    }
}
