package com.taozhu.app

import android.app.DownloadManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // 待处理分享图片（微信/相册「分享到陶朱」）：冷启动时 Dart 侧 getPending 领取，热启动由 onShare 推送
    companion object {
        private val pendingShares = java.util.Collections.synchronizedList(mutableListOf<String>())
    }
    private var shareChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShare(intent)
    }

    /** 接收系统/微信分享的图片：复制到应用缓存目录，路径经 MethodChannel 交给 Flutter 识别记账 */
    private fun handleShare(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val uri = if (android.os.Build.VERSION.SDK_INT >= 33)
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else
            @Suppress("DEPRECATION") intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        if (uri == null) return
        try {
            val dir = File(cacheDir, "shared_images")
            if (!dir.exists()) dir.mkdirs()
            // 按真实 MIME 存扩展名（PNG/WebP 分享存成 .jpg 后端/模型解析会失败 1210 同款问题）
            val type = intent?.type ?: "image/jpeg"
            val ext = when {
                type.contains("png") -> "png"
                type.contains("webp") -> "webp"
                else -> "jpg"
            }
            val name = "shared_${System.currentTimeMillis()}.$ext"
            val out = File(dir, name)
            contentResolver.openInputStream(uri)?.use { input ->
                out.outputStream().use { output -> input.copyTo(output) }
            }
            val path = out.absolutePath
            pendingShares.add(path)
            // 热启动（App 已在运行）：直接把路径推给 Dart；冷启动 Dart 稍后 getPending 领取
            shareChannel?.invokeMethod("onShare", path, null)
        } catch (_: Exception) {}
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "taozhu/download")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "enqueue" -> {
                            val url = call.argument<String>("url")
                            val fileName = call.argument<String>("fileName") ?: "taozhu-update.apk"
                            if (url.isNullOrEmpty()) result.error("no_url", "missing url", null)
                            else result.success(enqueue(url, fileName))
                        }
                        "status" -> {
                            val id = call.argument<Number>("id")?.toLong()
                            if (id == null) result.error("no_id", "missing id", null)
                            else result.success(queryStatus(id))
                        }
                        "abi" -> result.success(primaryAbi())
                        "listCache" -> result.success(listCache())
                        "deleteFiles" -> {
                            val names = call.argument<List<String>>("names") ?: emptyList()
                            result.success(deleteFiles(names))
                        }
                        "saveImage" -> {
                            val bytes = call.argument<ByteArray>("bytes")
                            val fileName = call.argument<String>("fileName") ?: "taozhu_${System.currentTimeMillis()}.jpg"
                            if (bytes == null || bytes.isEmpty()) result.error("no_bytes", "图片内容为空", null)
                            else result.success(saveImageToGallery(bytes, fileName))
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("dl_error", e.message, null)
                }
            }
        // 微信/系统分享图片 → App：Dart 侧 getPending 领取待处理图片路径列表（领完即清）
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "taozhu/share")
            .also { ch ->
                ch.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getPending" -> result.success(pendingShares.toList().also { pendingShares.clear() })
                        else -> result.notImplemented()
                    }
                }
            }
        // 系统代理跟随：Dart 侧 findProxy 需要当前系统代理地址（代理软件开/关即时反映）。
        // API 23+ 用 ConnectivityManager.defaultProxy（正规 API）；低版本兜底 Settings.Global
        // http_proxy（格式 host:port）与系统属性 http.proxyHost/Port。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "taozhu/proxy")
            .setMethodCallHandler { call, result ->
                if (call.method != "getProxy") { result.notImplemented(); return@setMethodCallHandler }
                val hostPort = systemProxy()
                if (hostPort == null) result.success(null)
                else result.success(mapOf("host" to hostPort.first, "port" to hostPort.second))
            }
    }

    /** 当前系统代理 {host, port}；无代理返回 null（不抛异常，Dart 侧保持直连） */
    private fun systemProxy(): Pair<String, Int>? {
        if (Build.VERSION.SDK_INT >= 23) {
            try {
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                // defaultProxy 返回 android.net.ProxyInfo（API 23+），属性 host/port
                val info = cm.defaultProxy
                val host = info?.host
                if (info != null && !host.isNullOrEmpty() && info.port > 0) {
                    return host to info.port
                }
            } catch (_: Exception) {}
        }
        // 低版本 / 默认代理为空：Settings.Global http_proxy（"host:port"）兜底
        try {
            val raw = Settings.Global.getString(contentResolver, "http_proxy")
            if (!raw.isNullOrEmpty()) {
                val clean = raw.split(",").firstOrNull()?.trim() ?: return null
                val host = clean.substringBefore(":")
                val port = clean.substringAfter(":", "").toIntOrNull()
                if (host.isNotEmpty() && port != null && port > 0) return host to port
            }
        } catch (_: Exception) {}
        try {
            val host = System.getProperty("http.proxyHost")
            val port = System.getProperty("http.proxyPort")?.toIntOrNull()
            if (!host.isNullOrEmpty() && port != null && port > 0) return host to port
        } catch (_: Exception) {}
        return null
    }

    /** 设备主 ABI（对应拆包下载：arm64-v8a / armeabi-v7a / x86_64），兼容模拟器（x86_64 优先） */
    private fun primaryAbi(): String {
        val abis = Build.SUPPORTED_ABIS
        if (abis.isEmpty()) return "arm64-v8a"
        // 模拟器（x86/x86_64）优先返回，真机取第一个
        return abis.firstOrNull { it.startsWith("x86") } ?: abis[0]
    }

    private fun enqueue(url: String, fileName: String): Long {
        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val req = DownloadManager.Request(Uri.parse(url))
        req.setTitle("陶朱更新")
        req.setDescription("正在下载新版本安装包…")
        // 通知栏可见进度条+百分比 + 下载完成通知；应用目录（免存储权限，各 Android 版本可用）
        req.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
        req.setDestinationInExternalFilesDir(applicationContext, Environment.DIRECTORY_DOWNLOADS, fileName)
        req.setMimeType("application/vnd.android.package-archive")
        req.setAllowedOverMetered(true)
        return dm.enqueue(req)
    }

    private fun queryStatus(id: Long): Map<String, Any> {
        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val q = DownloadManager.Query().setFilterById(id)
        dm.query(q).use { c ->
            if (c.moveToFirst()) {
                val downloaded = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                val total = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
                val status = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                return mapOf("downloaded" to downloaded, "total" to total, "status" to status)
            }
        }
        // 查询不到记录 = 下载已被移除（用户在通知栏取消）。与 STATUS_FAILED(16) 区分开，
        // 前端据此判定"用户取消"→ 停止下载，而不是误判失败换下一个源继续下载。
        return mapOf("downloaded" to 0L, "total" to 0L, "status" to -1)
    }

    /** 列出更新缓存文件（taozhu-*）：系统下载记录 + 应用下载目录，返回 [{name,size}] */
    private fun listCache(): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        val seen = mutableSetOf<String>()
        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        try {
            dm.query(DownloadManager.Query()).use { c ->
                val uriCol = c.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI)
                val sizeCol = c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
                while (c.moveToNext()) {
                    val u = c.getString(uriCol) ?: ""
                    val name = u.substring(u.lastIndexOf('/') + 1)
                    if (name.startsWith("taozhu-") && seen.add(name)) {
                        var size = c.getLong(sizeCol)
                        if (size <= 0) {
                            try { size = File(Uri.parse(u).path ?: "").length() } catch (_: Exception) {}
                        }
                        out.add(mapOf("name" to name, "size" to size, "path" to (Uri.parse(u).path ?: "")))
                    }
                }
            }
        } catch (_: Exception) {}
        // 兜底：应用下载目录残留（可能无下载记录）
        try {
            getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)?.listFiles()?.forEach { f ->
                if (f.name.startsWith("taozhu-") && f.exists() && seen.add(f.name)) {
                    out.add(mapOf("name" to f.name, "size" to f.length(), "path" to f.absolutePath))
                }
            }
        } catch (_: Exception) {}
        return out
    }

    /** 按文件名删除更新缓存：删文件 + 移除系统下载记录（通知栏通知一并消失） */
    private fun deleteFiles(names: List<String>): Int {
        var removed = 0
        val nameSet = names.toSet()
        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        try {
            dm.query(DownloadManager.Query()).use { c ->
                val idCol = c.getColumnIndexOrThrow(DownloadManager.COLUMN_ID)
                val uriCol = c.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI)
                while (c.moveToNext()) {
                    val u = c.getString(uriCol) ?: ""
                    val name = u.substring(u.lastIndexOf('/') + 1)
                    if (name in nameSet) {
                        try {
                            val p = Uri.parse(u).path
                            if (!p.isNullOrEmpty()) File(p).delete()
                        } catch (_: Exception) {}
                        dm.remove(c.getLong(idCol))
                        removed++
                    }
                }
            }
        } catch (_: Exception) {}
        try {
            getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)?.listFiles()?.forEach { f ->
                if (f.name in nameSet && f.exists()) { f.delete(); removed++ }
            }
        } catch (_: Exception) {}
        return removed
    }

    /** 保存图片到系统相册（附件"保存到本地"）：Android 10+ 走 MediaStore 免权限（RELATIVE_PATH
     *  存 Pictures/陶朱）；Android 9- 写公共 Pictures（前端 permission_handler 已请求存储权限）。
     *  返回保存路径/URI；失败抛异常给 Flutter 端提示。 */
    private fun saveImageToGallery(bytes: ByteArray, fileName: String): String {
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/陶朱")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw Exception("相册不可用，请检查存储权限")
            contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: throw Exception("写入相册失败")
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return uri.toString()
        } else {
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "陶朱")
            if (!dir.exists()) dir.mkdirs()
            val f = File(dir, fileName)
            f.writeBytes(bytes)
            // 广播扫描相册，让图库立即看到
            try { sendBroadcast(Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE, Uri.fromFile(f))) } catch (_: Exception) {}
            return f.absolutePath
        }
    }
}
