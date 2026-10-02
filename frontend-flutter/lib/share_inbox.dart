import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// 微信/系统「分享图片 → App」收件箱（对齐参考实现：原生 Kotlin + MethodChannel，无第三方插件）：
/// - Android 侧 MainActivity 把 ACTION_SEND 图片复制到 cacheDir/shared_images/，
///   通过 MethodChannel `taozhu/share` 交到 Dart：热启动用 `onShare` 推送路径，
///   冷启动（含未登录时分享）由 Dart 主动 `getPending` 领取（领完即清）。
/// - 收到后回调给记单页：识别填行为草稿，用户可修改确认后再保存（不自动直存）。
class ShareInbox {
  static const MethodChannel _ch = MethodChannel('taozhu/share');
  static void Function(Uint8List bytes, String mime)? _onImage;
  static bool _listening = false;

  /// 注册分享图片回调（bytes + 真实 MIME），并领取原生侧待处理分享。App 启动后调用一次。
  static Future<void> init(void Function(Uint8List bytes, String mime) onImage) async {
    if (kIsWeb) return;
    _onImage = onImage;
    if (!_listening) {
      _listening = true;
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'onShare') {
          final path = '${call.arguments ?? ''}';
          if (path.isNotEmpty) await _handle(path);
        }
      });
    }
    // 冷启动/登录前分享：图片已由原生复制到缓存，主动领取
    try {
      final pending = await _ch.invokeMethod<List<dynamic>>('getPending');
      for (final p in pending ?? const <dynamic>[]) {
        await _handle('$p');
      }
    } catch (_) {
      // iOS/桌面/Web 无原生端：静默（分享接收仅 Android）
    }
  }

  static Future<void> _handle(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return;
      final bytes = await f.readAsBytes();
      // 原生按真实 MIME 存扩展名，这里反推 mime（png/webp/jpg）
      final lower = path.toLowerCase();
      final mime = lower.endsWith('.png')
          ? 'image/png'
          : (lower.endsWith('.webp') ? 'image/webp' : 'image/jpeg');
      final cb = _onImage;
      if (cb != null) cb(bytes, mime);
      // 处理完清理缓存副本（下次分享同名覆盖即可，无残留积累）
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    } catch (_) {}
  }
}
