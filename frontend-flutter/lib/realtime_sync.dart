import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api.dart';
import 'sync_service.dart';

/// 实时同步：保持一条 WebSocket 连接（SyncHub Durable Object），
/// 服务端推送类型化消息（对齐参考架构 WS 分发模型）：
/// - {type:'sync'}：业务实体变更 → 防抖触发增量同步（pull/push）
/// - {type:'profile_change'}：资料/头像变更 → syncMyProfile（按头像版本比对下载）
/// - {type:'ai_config'}：AI 配置（服务商/能力绑定）变更 → 通知 AI 设置页重新拉取
/// 连接建立（首连/断线重连）后自动触发一次完整同步，冲刷离线期间累积的本地变更。
/// 断线自动重连（指数退避 1/3/8/20/60s）。
class RealtimeSync {
  RealtimeSync._();
  static final RealtimeSync instance = RealtimeSync._();

  WebSocketChannel? _channel;
  Timer? _retry;
  Timer? _autoSync;
  int _failCount = 0;
  bool _closed = true;
  DateTime _lastTrigger = DateTime.fromMillisecondsSinceEpoch(0);

  /// 登录后调用：开始连接（登录页 → BottomShell 时）
  Future<void> start() async {
    _closed = false;
    _failCount = 0;
    await _connect();
  }

  /// 退出/切账号时调用：断开并停止重连
  void stop() {
    _closed = true;
    _retry?.cancel();
    _autoSync?.cancel();
    _channel?.sink.close();
    _channel = null;
  }

  Future<void> _connect() async {
    if (_closed) return;
    _retry?.cancel();
    try {
      final base = await Api.instance.getBase();
      final token = await Api.instance.getTokenValue() ?? '';
      if (base.isEmpty || token.isEmpty) return;
      final wsBase = base.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://');
      final uri = '$wsBase/api/v1/sync/ws?token=$token';
      final channel = WebSocketChannel.connect(Uri.parse(uri));
      _channel = channel;
      _failCount = 0;
      channel.stream.listen(
        (msg) => _onMessage('$msg'),
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
      );
      // 连接建立（首连/重连）：防抖触发一次完整同步——离线期间累积的本地变更在此冲刷，
      // 服务端错过的推送也由这次同步补齐（对齐参考架构 ws_connected → autoSync 语义）
      _scheduleAutoSync();
    } catch (_) {
      _scheduleReconnect();
    }
  }

  /// 2 秒防抖的自动同步：连续上线信号（重连/切网）只触发一次
  void _scheduleAutoSync() {
    if (_closed) return;
    _autoSync?.cancel();
    _autoSync = Timer(const Duration(seconds: 2), () {
      if (_closed) return;
      if (kIsWeb) {
        SyncService.version.notifyListeners();
        return;
      }
      SyncService.sync();
    });
  }

  void _onMessage(String msg) {
    try {
      final d = jsonDecode(msg);
      if (d is! Map) return;
      final type = '${d['type'] ?? 'sync'}';
      if (type == 'profile_change') {
        _triggerProfile();
      } else if (type == 'ai_config') {
        // AI 配置变更：通知 AI 设置页等监听方重新拉取（不触发业务数据同步）
        SyncService.aiConfigChanged.notifyListeners();
      } else {
        _trigger();
      }
    } catch (_) {}
  }

  /// 资料/头像变更：其他端改了显示名/头像 → 拉 /auth/me 回写本地（头像按版本比对下载）
  void _triggerProfile() {
    final now = DateTime.now();
    if (now.difference(_lastTrigger).inMilliseconds < 1000) return;
    _lastTrigger = now;
    if (kIsWeb) {
      // Web 无本地库：通知页面重新直连拉取资料
      SyncService.version.notifyListeners();
      return;
    }
    SyncService.syncMyProfile();
  }

  /// 防抖：1 秒内多次通知合并为一次同步
  void _trigger() {
    final now = DateTime.now();
    if (now.difference(_lastTrigger).inMilliseconds < 1000) return;
    _lastTrigger = now;
    if (kIsWeb) {
      // Web 无本地库/同步流程：同步定级为 version 通知，各页面监听后重新直连拉取（App→Web 实时刷新）
      SyncService.version.notifyListeners();
      return;
    }
    SyncService.sync();
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _channel?.sink.close();
    _channel = null;
    _failCount++;
    final delay = [1, 3, 8, 20, 60][min(_failCount, 5) - 1];
    _retry = Timer(Duration(seconds: delay), _connect);
  }
}
