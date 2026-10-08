import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 系统代理跟随（App 自动走系统代理，用户 2026-10-08 需求）：
/// Dart 默认 HttpClient 只认环境变量（Windows/Android 都不读系统代理设置），
/// 这里用 HttpOverrides.global + findProxy 统一接管全部 HTTP 请求（package:http
/// 的 IOClient 内部构造 HttpClient() 会走 override，api.dart/sync_service 零侵入）。
/// - Windows：读注册表 HKCU\...\Internet Settings 的 ProxyEnable/ProxyServer
///   （Clash 等"系统代理"开关即写这两处）；每 30s 重读跟随开关变化
/// - Android：MethodChannel taozhu/proxy getProxy → ConnectivityManager.defaultProxy
///   （低版本兜底 Settings.Global http_proxy / 系统属性）
/// - Linux/macOS：读环境变量 HTTPS_PROXY/HTTP_PROXY（各自桌面环境惯例）
/// - Web：浏览器自带系统代理，无需处理（kIsWeb 直接返回直连）
class SystemProxy {
  static bool _enabled = false;
  static String? _server;

  /// findProxy 回调（HttpOverrides 注入）：命中直连白名单 → DIRECT，否则走系统代理
  static String resolve(Uri uri) {
    final host = uri.host;
    // 本地/回环地址直连（代理软件本身也监听 127.0.0.1，走代理反而打不开）
    if (host == 'localhost' || host == '127.0.0.1') return 'DIRECT';
    if (_enabled && _server != null && _server!.isNotEmpty) return 'PROXY $_server';
    return 'DIRECT';
  }

  /// 启动时 + 定时刷新系统代理缓存（跟随代理软件开关变化）
  static Future<void> refresh() async {
    try {
      if (kIsWeb) return; // 浏览器自带代理，dart:io 在 Web 不可用
      if (Platform.isAndroid) {
        await _refreshAndroid();
        return;
      }
      if (Platform.isWindows) {
        await _refreshWindows();
        return;
      }
      await _refreshEnv();
    } catch (_) {
      // 读取失败保持原状态（宁留直连不误配）
    }
  }

  /// Windows 系统代理：注册表 ProxyEnable + ProxyServer
  static Future<void> _refreshWindows() async {
    final enable = await _regQuery('ProxyEnable');
    final server = await _regQuery('ProxyServer');
    final enabled = enable.contains('0x1');
    final raw = server.trim();
    if (!enabled || raw.isEmpty) {
      _enabled = false;
      _server = null;
      return;
    }
    // ProxyServer 可能是 "host:port" 或 "http=host:port;https=host:port;ftp=..."
    String? hostPort;
    final m = RegExp(r'(?:^|;)\s*https?=([^;]+)').firstMatch(raw);
    if (m != null) {
      hostPort = m.group(1)!.trim();
    } else {
      hostPort = raw.split(';').first.trim();
    }
    if (hostPort.isEmpty || hostPort == '=*') {
      _enabled = false;
      _server = null;
      return;
    }
    _enabled = true;
    _server = hostPort;
  }

  static Future<String> _regQuery(String value) async {
    final r = await Process.run('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      '/v',
      value,
    ]);
    if (r.exitCode != 0) return '';
    // 输出形如：    ProxyEnable    REG_DWORD    0x1
    final re = RegExp('$value\\s+REG_[A-Z_]+\\s+(.+)$', multiLine: true);
    final m = re.firstMatch('${r.stdout}');
    return m?.group(1)?.trim() ?? '';
  }

  /// Android 系统代理：MainActivity 读 ConnectivityManager.defaultProxy（API 23+）
  static Future<void> _refreshAndroid() async {
    try {
      const ch = MethodChannel('taozhu/proxy');
      final r = await ch.invokeMapMethod<String, dynamic>('getProxy');
      final host = '${r?['host'] ?? ''}';
      final port = '${r?['port'] ?? ''}';
      if (host.isNotEmpty && port.isNotEmpty) {
        _enabled = true;
        _server = '$host:$port';
        return;
      }
    } catch (_) {}
    _enabled = false;
    _server = null;
  }

  /// Linux/macOS：环境变量代理（各自桌面环境惯例；macOS 系统代理读 scutil 较复杂，
  /// 且多数代理软件会同步写环境变量，够用）
  static Future<void> _refreshEnv() async {
    final env = Platform.environment;
    final s = env['HTTPS_PROXY'] ??
        env['https_proxy'] ??
        env['HTTP_PROXY'] ??
        env['http_proxy'] ??
        '';
    if (s.isEmpty) {
      _enabled = false;
      _server = null;
      return;
    }
    // 环境变量可能是 http://host:port，findProxy 只要 host:port
    var v = s.trim();
    if (v.contains('://')) v = v.split('://').last;
    if (v.endsWith('/')) v = v.substring(0, v.length - 1);
    _enabled = true;
    _server = v;
  }

  /// 全局 HttpOverrides：所有 HttpClient 创建都走 findProxy（Web 端 kIsWeb 不注册）
  static void install() {
    HttpOverrides.global = _SystemProxyOverrides();
  }
}

class _SystemProxyOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = SystemProxy.resolve;
    return client;
  }
  /// 当前生效的代理地址（调试展示用；null=直连）
  static String? get server => _server;

  static bool get enabled => _enabled;
}
