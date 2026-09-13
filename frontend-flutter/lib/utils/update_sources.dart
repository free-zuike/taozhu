import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../api.dart';
import '../version.dart';

const _sourcesKey = 'taozhu.update_sources';

/// 当前指定的主要下载源前缀（'' = 未指定，官方直连优先使用）
String _specified = '';
String get specifiedSource => _specified;

/// 安装包最小可信大小：小于该值视为被代理/中间层拦截（返回 HTML 拦截页而非安装包）。
/// APK 最小 ABI 包约 22MB，镜像/代理返回的拦截页通常只有几 KB。
const int minTrustedBytes = 1048576; // 1MB

/// 官方 release 下载基址（探测/管理页共用）：universal APK 资产恒存在
String officialAssetUrl(String ver) =>
    'https://github.com/free-zuike/taozhu/releases/download/taozhu-v$ver/taozhu-app-$ver.apk';

/// 解析存储结构：兼容 {sources:[...], specified} 与旧版纯数组
List<Map<String, dynamic>> _parseSources(dynamic d) {
  if (d is List) {
    return [
      for (final e in d)
        if (e is Map) {'url': '${e['url'] ?? ''}', 'enabled': e['enabled'] == true},
    ];
  }
  if (d is Map && d['sources'] is List) return _parseSources(d['sources']);
  return [];
}

/// 第三方/自定义下载源列表 [{url, enabled}]（含服务器下发的默认镜像，可删改）；
/// 官方 GitHub 源内置固定，不存这里。服务器为权威（跨端同步），本地缓存兜底。
Future<List<Map<String, dynamic>>> loadUpdateSources() async {
  var local = <Map<String, dynamic>>[];
  var localSpecified = '';
  try {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_sourcesKey);
    if (raw != null && raw.isNotEmpty) {
      final d = jsonDecode(raw);
      local = _parseSources(d);
      if (d is Map && d['specified'] is String) localSpecified = d['specified'] as String;
    }
  } catch (_) {}
  _specified = localSpecified;
  try {
    final d = await Api.instance.get('/me/download-sources');
    // sources != null 表示服务器有记录：以服务器为准并同步本地缓存
    if (d['sources'] != null) {
      final server = _parseSources(d['sources']);
      final serverSpecified = '${d['specified'] ?? ''}';
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString(_sourcesKey, jsonEncode({'sources': server, 'specified': serverSpecified}));
      } catch (_) {}
      _specified = serverSpecified;
      return server;
    }
  } catch (_) {
    // 离线/服务器不可达：保留本地缓存
  }
  return local;
}

Future<void> saveUpdateSources(List<Map<String, dynamic>> list, {String specified = ''}) async {
  final clean = [
    for (final s in list) {'url': '${s['url'] ?? ''}', 'enabled': s['enabled'] == true},
  ];
  _specified = specified;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(_sourcesKey, jsonEncode({'sources': clean, 'specified': specified}));
  } catch (_) {}
  try {
    await Api.instance.put('/me/download-sources', {'sources': clean, 'specified': specified});
  } catch (_) {
    // 离线：仅本地缓存，下次在线加载时以服务器覆盖（简化同步，不做推送队列）
  }
}

/// 单源探测：传入下载前缀（'' = 官方直连），可达返回耗时毫秒，不可达/异常返回 null。
/// Web 端浏览器不能跨域直连 GitHub，借服务器探测（/me/probe-source）；
/// 原生端本地 GET + Range 前 1KB 直连（镜像普遍拒绝 HEAD 或 HEAD 不带 Content-Length，
/// GET 与真实下载同一路径才不误判；用 Content-Range 的总大小 ≥ 1MB 判定，拦截页仍会被识别）。
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
  http.StreamedResponse? res;
  try {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse('$prefix${officialAssetUrl(APP_VERSION)}'));
      req.headers['Range'] = 'bytes=0-1023';
      req.headers['User-Agent'] = 'Mozilla/5.0';
      res = await client.send(req).timeout(const Duration(seconds: 10));
      // Content-Range: bytes 0-1023/6566030 → 总大小 = 斜杠后数字（206 时 Content-Length 只是 Range 段长）
      var total = -1;
      final cr = res.headers['content-range'];
      if (cr != null) {
        final slash = cr.lastIndexOf('/');
        if (slash >= 0) total = int.tryParse(cr.substring(slash + 1).trim()) ?? -1;
      }
      final len = res.contentLength ?? -1;
      final size = total >= 0 ? total : (res.statusCode == 200 ? len : -1);
      final ok = (res.statusCode == 200 || res.statusCode == 206) && size >= minTrustedBytes;
      return ok ? DateTime.now().difference(t0).inMilliseconds : null;
    } finally {
      // 释放连接：读完响应体（Range 仅 1KB）
      try {
        await res?.stream.drain();
      } catch (_) {}
      client.close();
    }
  } catch (_) {
    return null;
  }
}