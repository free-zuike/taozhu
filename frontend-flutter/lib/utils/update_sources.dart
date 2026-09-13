import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../api.dart';
import '../version.dart';

const _sourcesKey = 'taozhu.update_sources';

/// 安装包最小可信大小：小于该值视为被代理/中间层拦截（返回 HTML 拦截页而非安装包）。
/// APK 最小 ABI 包约 22MB，镜像/代理返回的拦截页通常只有几 KB。
const int minTrustedBytes = 1048576; // 1MB

/// 官方 release 下载基址（探测/管理页共用）：universal APK 资产恒存在
String officialAssetUrl(String ver) =>
    'https://github.com/free-zuike/taozhu/releases/download/taozhu-v$ver/taozhu-app-$ver.apk';

/// 第三方/自定义下载源列表 [{url, enabled}]；官方 GitHub 源内置固定，不存这里。
/// 服务器为权威（跨端同步：Web 设置 App 可读），本地缓存兜底（离线秒开/可用）。
Future<List<Map<String, dynamic>>> loadUpdateSources() async {
  var local = <Map<String, dynamic>>[];
  try {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_sourcesKey);
    if (raw != null && raw.isNotEmpty) {
      final d = jsonDecode(raw) as List? ?? [];
      local = [
        for (final e in d)
          if (e is Map) {'url': '${e['url'] ?? ''}', 'enabled': e['enabled'] == true},
      ];
    }
  } catch (_) {}
  try {
    final d = await Api.instance.get('/me/download-sources');
    // sources != null 表示服务器有记录（含已清空 []）：以服务器为准并同步本地缓存
    if (d['sources'] != null) {
      final server = [
        for (final e in ((d['sources'] as List?) ?? []))
          if (e is Map) {'url': '${e['url'] ?? ''}', 'enabled': e['enabled'] == true},
      ];
      try {
        final p = await SharedPreferences.getInstance();
        final raw = jsonEncode(server);
        if (raw == '[]') {
          await p.remove(_sourcesKey); // 服务器已清空：本地同步清掉
        } else {
          await p.setString(_sourcesKey, raw);
        }
      } catch (_) {}
      return server;
    }
  } catch (_) {
    // 离线/服务器不可达：保留本地缓存
  }
  return local;
}

Future<void> saveUpdateSources(List<Map<String, dynamic>> list) async {
  final clean = [
    for (final s in list) {'url': '${s['url'] ?? ''}', 'enabled': s['enabled'] == true},
  ];
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(_sourcesKey, jsonEncode(clean));
  } catch (_) {}
  try {
    await Api.instance.put('/me/download-sources', {'sources': clean});
  } catch (_) {
    // 离线：仅本地缓存，下次在线加载时以服务器覆盖（简化同步，不做推送队列）
  }
}

/// 单源探测：传入下载前缀（'' = 官方直连），可达返回耗时毫秒，不可达/异常返回 null。
/// Web 端浏览器不能跨域 HEAD GitHub，借服务器探测（/me/probe-source）；
/// 原生端本地 HEAD 直连（无 CORS 限制）。两端统一要求响应 ≥ 1MB 才算可达（识别代理拦截页）。
Future<int?> probeDownloadSource(String prefix) async {
  if (kIsWeb) {
    try {
      final d = await Api.instance.post('/me/probe-source', {'prefix': prefix});
      return d['ok'] == true ? (d['ms'] as num?)?.toInt() : null;
    } catch (_) {
      return null;
    }
  }
  final t0 = DateTime.now();
  try {
    final client = http.Client();
    try {
      final req = http.Request('HEAD', Uri.parse('$prefix${officialAssetUrl(APP_VERSION)}'));
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