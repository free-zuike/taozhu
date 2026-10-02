package com.taozhu.app

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
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
}
