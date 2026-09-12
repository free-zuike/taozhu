import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'api.dart';

/// 头像本地缓存（App/桌面端）：本地副本文件 avatar.jpg，断网也能显示旧头像。
/// 后台校验（syncAvatarCache）只做"服务器是否变化"——有则下载覆盖，无则清空，网络失败保留旧缓存。

/// 本地头像文件（不存在返回 null；Web 无文件系统返回 null）
Future<File?> avatarLocalFile() async {
  if (kIsWeb) return null;
  try {
    final root = await getApplicationDocumentsDirectory();
    final f = File('${root.path}/avatar.jpg');
    return f.existsSync() ? f : null;
  } catch (_) {
    return null;
  }
}

Future<void> saveAvatarLocal(Uint8List bytes) async {
  if (kIsWeb) return;
  try {
    final root = await getApplicationDocumentsDirectory();
    await File('${root.path}/avatar.jpg').writeAsBytes(bytes);
  } catch (_) {}
}

Future<void> clearAvatarLocal() async {
  if (kIsWeb) return;
  try {
    final root = await getApplicationDocumentsDirectory();
    final f = File('${root.path}/avatar.jpg');
    if (f.existsSync()) await f.delete();
  } catch (_) {}
}

/// 后台校验头像缓存：
/// - 服务器有头像 → 下载覆盖本地副本，返回 true
/// - 服务器未设置（404）→ 清本地副本，返回 null
/// - 网络失败 → 保留旧缓存，返回 false
Future<bool?> syncAvatarCache() async {
  if (kIsWeb) return null;
  try {
    final bytes = await Api.instance.getAvatarBytes();
    if (bytes == null) {
      await clearAvatarLocal();
      return null;
    }
    await saveAvatarLocal(bytes);
    return true;
  } catch (_) {
    return false;
  }
}
