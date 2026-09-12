import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api.dart';
import 'sync_service.dart';

/// 实时同步：保持一条 WebSocket 连接（SyncHub Durable Object），
/// 服务端在数据变更后推送 {type:'sync'}，客户端收到后触发增量同步（pull），
/// 实现"一端改动、多端实时同步"。断线自动重连（指数退避 1/3/8/20/60s）。
class RealtimeSync {
  RealtimeSync._();
  static final RealtimeSync instance = RealtimeSync._();

  WebSocketChannel? _channel;
  Timer? _retry;
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
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onMessage(String msg) {
    try {
      final d = jsonDecode(msg);
      if (d is Map && d['type'] == 'sync') _trigger();
    } catch (_) {}
  }

  /// 防抖：1 秒内多次通知合并为一次同步
  void _trigger() {
    final now = DateTime.now();
    if (now.difference(_lastTrigger).inMilliseconds < 1000) return;
    _lastTrigger = now;
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
