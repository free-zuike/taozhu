import 'dart:convert';
import 'package:http/http.dart' as http;
import 'update_channel.dart';

/// 直连 GitHub Release API 获取最新版本（用户定案：检查更新不走服务器代理——
/// 服务器代理多一跳反而更慢/更容易被网络干扰；已有下载镜像加速 APK）。
///
/// channel=stable 用 /releases/latest（GitHub 自动跳过 prerelease）；
/// channel=preview 额外查 /releases 里带 APK 资产的 prerelease，并与正式版取较大者，
/// 保证「预发布」用户不会因为正式版已发得更新而停留在旧版本。
/// 返回 {latest, ready, source, notes, channel}；latest 为空=GitHub 不可达/无有效 Release。
const _repo = 'https://api.github.com/repos/free-zuike/taozhu';
const _headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'taozhu-app'};

bool _hasApk(String v, List assets) => assets.any((a) {
      final n = '${(a as Map)['name'] ?? ''}';
      return (n.startsWith('taozhu-app-$v-') && n.endsWith('.apk')) || n == 'taozhu-app-$v.apk';
    });

Map<String, dynamic> _release(String tag, bool ready, String notes, String channel) {
  return {
    'latest': tag.replaceFirst(RegExp(r'^taozhu-v'), ''),
    'ready': ready,
    'source': 'github',
    'notes': notes,
    'channel': channel,
  };
}

/// 三位版本号比较：a < b 返回 true（非法段按 0，不误伤）
bool _older(String a, String b) {
  List<int> parts(String s) => s.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  final pa = parts(a), pb = parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y;
  }
  return false;
}

Future<Map<String, dynamic>> _fetchStable() async {
  final resp = await http.get(
    Uri.parse('$_repo/releases/latest'),
    headers: _headers,
  ).timeout(const Duration(seconds: 15));
  if (resp.statusCode != 200) return {'latest': ''};
  final d = jsonDecode(resp.body) as Map<String, dynamic>;
  final tag = '${d['tag_name'] ?? ''}';
  if (tag.isEmpty) return {'latest': ''};
  final v = tag.replaceFirst(RegExp(r'^taozhu-v'), '');
  // 有安装文件才提示新版本（拆包产物 taozhu-app-{v}-{abi}.apk 或 universal 任一存在）
  return _release(tag, _hasApk(v, (d['assets'] as List?) ?? []), '${d['body'] ?? ''}', 'stable');
}

/// 取最新一个带 APK 资产的 prerelease（GitHub 列表按创建时间倒序，仍按版本号取最大兜底）
Future<Map<String, dynamic>?> _fetchPreview() async {
  final resp = await http.get(
    Uri.parse('$_repo/releases?per_page=20'),
    headers: _headers,
  ).timeout(const Duration(seconds: 15));
  if (resp.statusCode != 200) return null;
  final list = jsonDecode(resp.body) as List;
  Map<String, dynamic>? best;
  for (final raw in list) {
    final d = (raw as Map).cast<String, dynamic>();
    if (d['prerelease'] != true) continue;
    final tag = '${d['tag_name'] ?? ''}';
    if (tag.isEmpty) continue;
    final v = tag.replaceFirst(RegExp(r'^taozhu-v'), '');
    if (!_hasApk(v, (d['assets'] as List?) ?? [])) continue;
    final candidate = _release(tag, true, '${d['body'] ?? ''}', 'preview');
    if (best == null || _older('${best['latest']}', v)) best = candidate;
  }
  return best;
}

Future<Map<String, dynamic>> fetchLatestRelease({
  UpdateChannel channel = UpdateChannel.stable,
}) async {
  if (channel == UpdateChannel.stable) return _fetchStable();
  Map<String, dynamic>? preview;
  try {
    preview = await _fetchPreview();
  } catch (_) {
    // 预发布列表不可达不应阻断正式版检查
  }
  final stable = await _fetchStable();
  final pv = '${preview?['latest'] ?? ''}';
  final sv = '${stable['latest'] ?? ''}';
  if (pv.isEmpty) return stable;
  if (sv.isEmpty) return preview!;
  return _older(pv, sv) ? stable : preview!;
}
