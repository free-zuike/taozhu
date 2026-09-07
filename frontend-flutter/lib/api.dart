/// API 封装：服务器地址可手动设置 + token + 401 处理（http 包，三端通用）
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class Api {
  Api._();
  static final Api instance = Api._();

  static const _tokenKey = 'taozhu_token';
  static const _baseKey = 'taozhu_api_base';
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

  Future<void> setToken(String t) async {
    (await SharedPreferences.getInstance()).setString(_tokenKey, t);
  }

  Future<void> clearToken() async {
    (await SharedPreferences.getInstance()).remove(_tokenKey);
  }

  Future<bool> hasToken() async => (await _token())?.isNotEmpty ?? false;

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
        case 'PUT':
          res = await http.put(Uri.parse(url), headers: headers, body: jsonEncode(body ?? {}));
        case 'PATCH':
          res = await http.patch(Uri.parse(url), headers: headers, body: jsonEncode(body ?? {}));
        case 'DELETE':
          res = await http.delete(Uri.parse(url), headers: headers);
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
}