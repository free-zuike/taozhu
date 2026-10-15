import 'dart:convert';
import 'package:http/http.dart' as http;

/// 直连 GitHub Release API 获取最新版本（用户定案：检查更新不走服务器代理——
/// 服务器代理多一跳反而更慢/更容易被网络干扰；已有下载镜像加速 APK）。
/// 返回 {latest, ready, source, notes}；latest 为空=GitHub 不可达/无有效 Release。
Future<Map<String, dynamic>> fetchLatestRelease() async {
  final resp = await http.get(
    Uri.parse('https://api.github.com/repos/free-zuike/taozhu/releases/latest'),
    headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'taozhu-app'},
  ).timeout(const Duration(seconds: 15));
  if (resp.statusCode != 200) return {'latest': ''};
  final d = jsonDecode(resp.body) as Map<String, dynamic>;
  final tag = '${d['tag_name'] ?? ''}'.replaceFirst(RegExp(r'^taozhu-v'), '');
  if (tag.isEmpty) return {'latest': ''};
  final assets = ((d['assets'] as List?) ?? []).cast<Map<String, dynamic>>();
  // 有安装文件才提示新版本（拆包产物 taozhu-app-{v}-{abi}.apk 或 universal 任一存在）
  final hasApk = assets.any((a) {
    final n = '${a['name'] ?? ''}';
    return (n.startsWith('taozhu-app-$tag-') && n.endsWith('.apk')) || n == 'taozhu-app-$tag.apk';
  });
  return {
    'latest': tag,
    'ready': hasApk,
    'source': 'github',
    'notes': '${d['body'] ?? ''}',
  };
}
