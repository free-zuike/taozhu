/// API 封装：服务器地址可手动设置 + token + 401 处理（http 包，三端通用）
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class Api {
  Api._();
  static final Api instance = Api._();

  static const _tokenKey = 'taozhu_token';
  static const _baseKey = 'taozhu_api_base';
  static const _roleKey = 'taozhu_role';
  static const _cachePrefix = 'taozhu_cache_';
  // 无内置默认地址：个人部署模式，登录页必须显式填写自己的服务器地址
  // （Web 生产构建通过 --dart-define=API_BASE 注入默认值，留空即连；App 不注入 → 必填）
  static const _envBase = String.fromEnvironment('API_BASE');

  /// 规范化服务器地址：去空格/尾斜杠，缺协议头自动补 https://
  static String _norm(String raw) {
    var b = raw.trim().replaceAll(RegExp(r'/+$'), '');
    if (b.isNotEmpty && !b.startsWith('http://') && !b.startsWith('https://')) {
      b = 'https://$b';
    }
    return b;
  }

  Future<String> _base() async {
    final p = await SharedPreferences.getInstance();
    final stored = p.getString(_baseKey);
    if (stored != null && stored.isNotEmpty) return _norm(stored);
    return _norm(_envBase);
  }

  Future<String?> _token() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_tokenKey);
  }

  /// 供图片加载等场景读 token（如 Image.network 的 Authorization 头）
  Future<String?> getTokenValue() => _token();

  Future<void> setToken(String t) async {
    (await SharedPreferences.getInstance()).setString(_tokenKey, t);
  }

  Future<void> clearToken() async {
    (await SharedPreferences.getInstance()).remove(_tokenKey);
  }

  Future<bool> hasToken() async => (await _token())?.isNotEmpty ?? false;

  /// 当前账号角色（登录时缓存；老板=admin / 店员=staff）
  Future<void> setRole(String role) async {
    (await SharedPreferences.getInstance()).setString(_roleKey, role);
  }

  Future<String> getRole() async =>
      (await SharedPreferences.getInstance()).getString(_roleKey) ?? '';

  Future<void> setBase(String u) async {
    (await SharedPreferences.getInstance()).setString(_baseKey, _norm(u));
  }

  Future<String> getBase() => _base();

  /// 通用请求：成功返回 data map；失败抛 Exception（message 为后端 error 或通用文案）
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final base = await _base();
    if (base.isEmpty) {
      throw Exception('未配置服务器地址：请在登录页填写您的服务器地址（如 https://您的域名）');
    }
    final url = '$base/api/v1$path';
    final headers = {'Content-Type': 'application/json'};
    final t = await _token();
    if (t != null && t.isNotEmpty) headers['Authorization'] = 'Bearer $t';

    http.Response res;
    try {
      switch (method) {
        case 'POST':
          res = await http.post(Uri.parse(url), headers: headers, body: jsonEncode(body ?? {}));
          break;
        case 'PUT':
          res = await http.put(Uri.parse(url), headers: headers, body: jsonEncode(body ?? {}));
          break;
        case 'PATCH':
          res = await http.patch(Uri.parse(url), headers: headers, body: jsonEncode(body ?? {}));
          break;
        case 'DELETE':
          res = await http.delete(Uri.parse(url), headers: headers);
          break;
        default:
          res = await http.get(Uri.parse(url), headers: headers);
      }
    } catch (e) {
      // 网络/DNS/连接异常：把请求的完整地址附上，便于定位地址填错/网络问题
      throw Exception('$e （地址: $url）');
    }

    if (res.statusCode == 401) {
      await clearToken();
      throw Exception('登录已过期，请重新登录');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.bodyBytes.isEmpty) return {};
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    String msg = '请求失败(${res.statusCode})';
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (d['error'] is String) msg = d['error'] as String;
    } catch (_) {}
    throw Exception(msg);
  }

  // 便捷方法
  Future<Map<String, dynamic>> get(String path) => request(path);
  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic>? body]) =>
      request(path, method: 'POST', body: body);
  Future<Map<String, dynamic>> put(String path, [Map<String, dynamic>? body]) =>
      request(path, method: 'PUT', body: body);
  Future<Map<String, dynamic>> patch(String path, [Map<String, dynamic>? body]) =>
      request(path, method: 'PATCH', body: body);
  Future<Map<String, dynamic>> delete(String path) => request(path, method: 'DELETE');

  /// 读本地缓存（TTL 内返回缓存，未命中/过期返回 null）——下拉等常用数据秒开
  Future<Map<String, dynamic>?> getCached(String path, {Duration ttl = const Duration(minutes: 10)}) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('$_cachePrefix$path');
    if (raw == null) return null;
    try {
      final d = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt = DateTime.tryParse('${d['_t'] ?? ''}');
      if (savedAt != null && DateTime.now().difference(savedAt) < ttl) {
        return d['data'] as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// 读本地缓存（忽略 TTL，任意旧数据都返回）——离线兜底用
  Future<Map<String, dynamic>?> getCachedRaw(String path) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('$_cachePrefix$path');
    if (raw == null) return null;
    try {
      final d = jsonDecode(raw) as Map<String, dynamic>;
      return d['data'] as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 网络优先 + 离线兜底：成功则写本地快照（永不过期）；网络失败读任意旧缓存并标记 offline；
  /// 既无网络又无缓存时抛出原始异常
  Future<({Map<String, dynamic> data, bool offline})> getWithFallback(String path) async {
    try {
      final d = await get(path);
      await setCache(path, d);
      return (data: d, offline: false);
    } catch (e) {
      final cached = await getCachedRaw(path);
      if (cached != null) return (data: cached, offline: true);
      rethrow;
    }
  }

  /// 写本地缓存
  Future<void> setCache(String path, Map<String, dynamic> data) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        '$_cachePrefix$path', jsonEncode({'_t': DateTime.now().toIso8601String(), 'data': data}));
  }

  /// multipart 图片上传（AI 拍照识别：POST /ai/parse-photo，字段 photo）
  Future<Map<String, dynamic>> uploadPhoto(String path, Uint8List bytes, String filename) async {
    final base = await _base();
    if (base.isEmpty) {
      throw Exception('未配置服务器地址：请在登录页填写您的服务器地址（如 https://您的域名）');
    }
    final url = '$base/api/v1$path';
    final req = http.MultipartRequest('POST', Uri.parse(url));
    req.files.add(http.MultipartFile.fromBytes('photo', bytes, filename: filename));
    final t = await _token();
    if (t != null && t.isNotEmpty) req.headers['Authorization'] = 'Bearer $t';
    http.Response res;
    try {
      final streamed = await req.send();
      res = await http.Response.fromStream(streamed);
    } catch (e) {
      throw Exception('$e （地址: $url）');
    }
    if (res.statusCode == 401) {
      await clearToken();
      throw Exception('登录已过期，请重新登录');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.bodyBytes.isEmpty) return {};
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    String msg = '请求失败(${res.statusCode})';
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (d['error'] is String) msg = d['error'] as String;
    } catch (_) {}
    throw Exception(msg);
  }

  // ---------- 离线记账队列（断网记单缓存，恢复后重放） ----------

  static const _pendingKey = 'taozhu_pending';

  /// 待同步队列（本地，[{id, type, body, ts}]）
  Future<List<Map<String, dynamic>>> pendingList() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_pendingKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return ((jsonDecode(raw) as List?) ?? []).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// 网络失败时把单据存入待同步队列
  Future<void> pendingAdd(String type, Map<String, dynamic> body) async {
    final list = await pendingList();
    list.add({
      'id': '${DateTime.now().millisecondsSinceEpoch}${list.length}',
      'type': type, // sale | purchase | payment
      'body': body,
      'ts': DateTime.now().toIso8601String(),
    });
    final p = await SharedPreferences.getInstance();
    await p.setString(_pendingKey, jsonEncode(list));
  }

  Future<void> pendingRemove(String id) async {
    final list = await pendingList();
    list.removeWhere((x) => '${x['id']}' == id);
    final p = await SharedPreferences.getInstance();
    await p.setString(_pendingKey, jsonEncode(list));
  }

  /// 重放待同步队列；返回成功条数
  Future<int> syncPending() async {
    final list = await pendingList();
    if (list.isEmpty) return 0;
    var ok = 0;
    for (final item in list) {
      final type = '${item['type']}';
      final path = type == 'purchase' ? '/purchases' : (type == 'payment' ? '/payments' : '/sales');
      try {
        await post(path, (item['body'] as Map?)?.cast<String, dynamic>());
        await pendingRemove('${item['id']}');
        ok++;
      } catch (_) {
        // 单条失败跳过（网络或校验），保留队列
      }
    }
    return ok;
  }
}