import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 自定义下载源存储键：jsonEncode([{'url': 'https://…/', 'enabled': true}])
const _sourcesKey = 'taozhu.update_sources';

/// 安装包最小可信大小：小于该值视为被代理/中间层拦截（返回了 HTML 拦截页而非安装包）。
/// APK 最小 ABI 包约 22MB，镜像/代理返回的拦截页通常只有几 KB。
const int minTrustedBytes = 1048576; // 1MB

/// 第三方/自定义下载源列表 [{url, enabled}]；官方 GitHub 源内置固定，不存这里
Future<List<Map<String, dynamic>>> loadUpdateSources() async {
  try {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_sourcesKey);
    if (raw == null || raw.isEmpty) return [];
    final d = jsonDecode(raw) as List? ?? [];
    return [
      for (final e in d)
        if (e is Map)
          {'url': '${e['url'] ?? ''}', 'enabled': e['enabled'] == true},
    ];
  } catch (_) {
    return [];
  }
}

Future<void> saveUpdateSources(List<Map<String, dynamic>> list) async {
  final p = await SharedPreferences.getInstance();
  await p.setString(_sourcesKey, jsonEncode(list));
}

/// 单源 HEAD 探测：响应 200/206 且 Content-Length ≥ 1MB 视为可达，返回耗时毫秒；否则 null。
/// Content-Length 下限用于识别代理拦截页（返回 200 但只有几 KB），避免把「拦截页」当可用源，
/// 也避免下载完成后才发现下的是 2KB 假安装包。
Future<int?> probeDownloadSource(String url) async {
  final t0 = DateTime.now();
  try {
    final client = http.Client();
    try {
      final req = http.Request('HEAD', Uri.parse(url));
      req.headers['Range'] = 'bytes=0-0';
      req.headers['User-Agent'] = 'Mozilla/5.0';
      final res = await client.send(req).timeout(const Duration(seconds: 8));
      final len = res.contentLength ?? -1;
      if ((res.statusCode == 200 || res.statusCode == 206) && len >= minTrustedBytes) {
        return DateTime.now().difference(t0).inMilliseconds;
      }
      return null;
    } finally {
      client.close();
    }
  } catch (_) {
    return null;
  }
}
