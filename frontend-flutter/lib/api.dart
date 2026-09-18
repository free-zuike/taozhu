/// API 封装：服务器地址可手动设置 + token + 401/426 处理（http 包，三端通用）
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'log.dart';
import 'version.dart';

/// GET 请求短缓存条目：进行中的 Future + 完成结果/错误（3 秒内复用）
class _GetEntry {
  _GetEntry(this.fut);
  final Future<Map<String, dynamic>> fut;
  Map<String, dynamic>? result;
  Object? error;
  bool done = false;
  DateTime? doneAt;
}

class Api {
  Api._();
  static final Api instance = Api._();

  /// 强制更新回调（服务端 426 / latest-version.min_supported 触发）：由 App 启动处注册，
  /// 弹出不可关闭的更新窗；参数 = 最低需更新到的最新版本号。Web 端无强制更新（部署即新），不注册。
  static void Function(String latest)? onForceUpdate;

  static const _tokenKey = 'taozhu_token';
  static const _baseKey = 'taozhu_api_base';
  static const _roleKey = 'taozhu_role';
  static const _usernameKey = 'taozhu_username';
  static const _accountKey = 'taozhu_account';
  static const _avatarKey = 'taozhu_avatar';
  static const _cachePrefix = 'taozhu_cache_';
  // 无内置默认地址：个人部署模式，登录页必须显式填写自己的服务器地址
  // （Web 生产构建通过 --dart-define=API_BASE 注入默认值，留空即连；App 不注入 → 必填）
  static const _envBase = String.fromEnvironment('API_BASE');

  /// 网络层离线标记：最近一次请求因网络异常失败 → true。
  /// 页面加载据此跳过无意义的网络刷新（本地优先：无网络时只用本地缓存/本地库，不发请求）
  static bool _offlineMarked = false;
  static bool get isOffline => _offlineMarked;

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

  /// 清除当前账号的本地数据（切换账号/退出时调用，防数据串号）：
  /// token、角色、用户名、登录账号、头像状态、接口缓存（taozhu_cache_*）、离线待同步队列
  Future<void> clearLocalData() async {
    final p = await SharedPreferences.getInstance();
    p.remove(_tokenKey);
    p.remove(_roleKey);
    p.remove(_usernameKey);
    p.remove(_accountKey);
    p.remove(_avatarKey);
    p.remove(_pendingKey);
    final keys = p.getKeys().where((k) => k.startsWith(_cachePrefix)).toList();
    for (final k in keys) {
      await p.remove(k);
    }
  }

  /// 当前账号角色（登录时缓存；老板=admin / 店员=staff）
  Future<void> setRole(String role) async {
    (await SharedPreferences.getInstance()).setString(_roleKey, role);
  }

  Future<String> getRole() async =>
      (await SharedPreferences.getInstance()).getString(_roleKey) ?? '';

  /// 当前账号登录名（登录/改用户名时缓存；我的页面显示）
  Future<void> setUsername(String u) async {
    (await SharedPreferences.getInstance()).setString(_usernameKey, u);
  }

  Future<String> getUsername() async =>
      (await SharedPreferences.getInstance()).getString(_usernameKey) ?? '';

  /// 登录账号（邮箱，不可改；离线时账号设置页也显示缓存值）
  Future<void> setAccount(String u) async {
    (await SharedPreferences.getInstance()).setString(_accountKey, u);
  }

  Future<String> getAccount() async =>
      (await SharedPreferences.getInstance()).getString(_accountKey) ?? '';

  /// 是否已设置头像（/auth/me 刷新）
  Future<void> setAvatar(bool has) async {
    (await SharedPreferences.getInstance()).setBool(_avatarKey, has);
  }

  Future<bool> hasAvatar() async =>
      (await SharedPreferences.getInstance()).getBool(_avatarKey) ?? false;

  /// 头像图片 URL（需 Authorization 头读取）
  Future<String> avatarUrl() async => '${await _base()}/api/v1/auth/avatar';

  /// 拉取当前头像图片字节；未设置（404）返回 null；网络异常抛错（供本地缓存用）
  Future<List<int>?> getAvatarBytes() async {
    final base = await _base();
    if (base.isEmpty) throw Exception('未配置服务器地址');
    final url = '$base/api/v1/auth/avatar';
    final headers = <String, String>{};
    final t = await _token();
    if (t != null && t.isNotEmpty) headers['Authorization'] = 'Bearer $t';
    final res = await http.get(Uri.parse(url), headers: headers);
    if (res.statusCode == 404) return null;
    if (res.statusCode == 401) {
      await clearToken();
      throw Exception('登录已过期，请重新登录');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return res.bodyBytes;
    throw Exception('获取头像失败(${res.statusCode})');
  }

  Future<void> setBase(String u) async {
    (await SharedPreferences.getInstance()).setString(_baseKey, _norm(u));
  }

  Future<String> getBase() => _base();

  /// 通用请求：成功返回 data map；失败抛 Exception（message 为后端 error 或通用文案）
  /// GET 去重 + 3 秒短缓存：进行中的同 path 请求共享同一个 Future；完成后 3 秒内再次请求
  /// 直接复用结果——消除 Web 端多页面/同步完成回调导致的"先后重复请求"（同一接口几秒内
  /// 只发一次）。写操作（POST/PUT/PATCH/DELETE）不缓存。
  static final Map<String, _GetEntry> _getCache = {};

  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) {
    if (method == 'GET' && body == null) {
      final now = DateTime.now();
      final ex = _getCache[path];
      if (ex != null) {
        if (!ex.done) return ex.fut; // 进行中：共享同一个 Future
        if (now.difference(ex.doneAt!) < const Duration(seconds: 3)) {
          if (ex.error != null) throw ex.error!;
          return Future.value(ex.result);
        }
        _getCache.remove(path); // 缓存过期，重新请求
      }
      final created = _requestInner(path, method: method, body: body);
      final entry = _GetEntry(created);
      _getCache[path] = entry;
      created.then((r) {
        entry.result = r;
        entry.done = true;
        entry.doneAt = DateTime.now();
      }, onError: (Object e) {
        entry.error = e;
        entry.done = true;
        entry.doneAt = DateTime.now();
      });
      return created;
    }
    return _requestInner(path, method: method, body: body);
  }

  Future<Map<String, dynamic>> _requestInner(
    String path, {
    required String method,
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
    headers['x-app-version'] = APP_VERSION;

    // 发起一次请求（按方法分发）；8s 超时防止网络不可达时页面无限转圈
    Future<http.Response> doReq() async {
      switch (method) {
        case 'POST':
          return http.post(Uri.parse(url), headers: headers, body: jsonEncode(body ?? {}))
              .timeout(const Duration(seconds: 8));
        case 'PUT':
          return http.put(Uri.parse(url), headers: headers, body: jsonEncode(body ?? {}))
              .timeout(const Duration(seconds: 8));
        case 'PATCH':
          return http.patch(Uri.parse(url), headers: headers, body: jsonEncode(body ?? {}))
              .timeout(const Duration(seconds: 8));
        case 'DELETE':
          return (body == null
                  ? http.delete(Uri.parse(url), headers: headers)
                  : http.delete(Uri.parse(url), headers: headers, body: jsonEncode(body)))
              .timeout(const Duration(seconds: 8));
        default:
          return http.get(Uri.parse(url), headers: headers)
              .timeout(const Duration(seconds: 8));
      }
    }

    // 网络异常自动重试（最多 3 次，递增退避：500ms/1s）：
    // TLS 握手瞬时中断（弱网/切网/代理抖动）等偶发失败，重试后多数能恢复
    Future<http.Response> retry() async {
      var attempts = 0;
      while (true) {
        try {
          return await doReq();
        } catch (_) {
          attempts++;
          if (attempts >= 3) rethrow;
          await Future.delayed(Duration(milliseconds: attempts == 1 ? 500 : 1000));
        }
      }
    }

    http.Response res;
    try {
      res = await retry();
    } catch (e) {
      // 网络/DNS/连接异常：记离线标志（供下载源探测等兜底判断），记日志，页面只给友好提示
      _offlineMarked = true;
      appLog('net', '$method $path → ${e.toString().split('\n').first}', level: 'error');
      throw Exception('无法连接服务器，请检查网络或服务器地址');
    }
    if (_offlineMarked) _offlineMarked = false;

    if (res.statusCode == 401) {
      await clearToken();
      throw Exception('登录已过期，请重新登录');
    }
    if (res.statusCode == 426) {
      // 服务端强制更新门禁：当前版本已低于最低支持版本 → 触发全局更新窗
      String latest = '';
      try {
        final d = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        latest = '${d['latest'] ?? ''}';
      } catch (_) {}
      onForceUpdate?.call(latest);
      throw Exception(latest.isEmpty ? '当前版本已停用，请更新到最新版本' : '当前版本已停用，必须更新到 v$latest');
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
    appLog('http', '$method $path → ${res.statusCode}: $msg', level: 'error');
    throw Exception(msg);
  }

  // 便捷方法
  Future<Map<String, dynamic>> get(String path) => request(path);

  /// 原始字节请求（全库备份导出等）：成功返回 bodyBytes，失败抛 Exception
  Future<List<int>> getRaw(String path) async {
    final base = await _base();
    if (base.isEmpty) throw Exception('未配置服务器地址');
    final url = '$base/api/v1$path';
    final headers = {'Content-Type': 'application/json'};
    final t = await _token();
    if (t != null && t.isNotEmpty) headers['Authorization'] = 'Bearer $t';
    headers['x-app-version'] = APP_VERSION;
    final res = await http.get(Uri.parse(url), headers: headers);
    if (res.statusCode == 401) {
      await clearToken();
      throw Exception('登录已过期，请重新登录');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return res.bodyBytes;
    String msg = '请求失败(${res.statusCode})';
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (d['error'] is String) msg = d['error'] as String;
    } catch (_) {}
    appLog('http', 'GET $path → ${res.statusCode}: $msg', level: 'error');
    throw Exception(msg);
  }
  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic>? body]) =>
      request(path, method: 'POST', body: body);
  Future<Map<String, dynamic>> put(String path, [Map<String, dynamic>? body]) =>
      request(path, method: 'PUT', body: body);
  Future<Map<String, dynamic>> patch(String path, [Map<String, dynamic>? body]) =>
      request(path, method: 'PATCH', body: body);
  Future<Map<String, dynamic>> delete(String path) => request(path, method: 'DELETE');
  Future<Map<String, dynamic>> deleteBody(String path, Map<String, dynamic> body) =>
      request(path, method: 'DELETE', body: body);

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
    if (res.statusCode == 426) {
      // 服务端强制更新门禁：当前版本已低于最低支持版本 → 触发全局更新窗
      String latest = '';
      try {
        final d = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        latest = '${d['latest'] ?? ''}';
      } catch (_) {}
      onForceUpdate?.call(latest);
      throw Exception(latest.isEmpty ? '当前版本已停用，请更新到最新版本' : '当前版本已停用，必须更新到 v$latest');
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
    appLog('http', 'POST $path → ${res.statusCode}: $msg', level: 'error');
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