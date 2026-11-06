import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 一次应用内更新下载的进度记录。中断（断网 / 退出 App / 页面销毁）后仍保留，
/// 下次点「检查更新 → 继续下载」从断点恢复，不再从头重下，也不会「再也不下」。
///
/// Android：下载由系统 DownloadManager 负责，它自身支持断点；这里只保存下载 id，
/// 让 App 重启/切页后能重新接上轮询（旧实现轮询一停就彻底忘了这个下载）。
/// 桌面：保存未完成文件（.part）与下载源 URL，用 HTTP Range 从已落盘字节续传。
class PendingDownload {
  const PendingDownload({
    required this.ver,
    required this.fileName,
    required this.url,
    this.androidId,
  });

  final String ver;
  final String fileName;
  final String url;
  final int? androidId;

  Map<String, dynamic> toJson() => {
        'ver': ver,
        'fileName': fileName,
        'url': url,
        if (androidId != null) 'androidId': androidId,
      };

  static PendingDownload? fromJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final d = jsonDecode(raw) as Map;
      final ver = '${d['ver'] ?? ''}';
      final fileName = '${d['fileName'] ?? ''}';
      if (ver.isEmpty || fileName.isEmpty) return null;
      return PendingDownload(
        ver: ver,
        fileName: fileName,
        url: '${d['url'] ?? ''}',
        androidId: (d['androidId'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }
}

const _pendingKey = 'taozhu.pending_download';

Future<PendingDownload?> loadPendingDownload() async {
  try {
    final p = await SharedPreferences.getInstance();
    return PendingDownload.fromJson(p.getString(_pendingKey));
  } catch (_) {
    return null;
  }
}

Future<void> savePendingDownload(PendingDownload pending) async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(_pendingKey, jsonEncode(pending.toJson()));
  } catch (_) {}
}

Future<void> clearPendingDownload() async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.remove(_pendingKey);
  } catch (_) {}
}
