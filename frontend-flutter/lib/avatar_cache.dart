import 'dart:io';
import 'package:flutter/foundation.dart' show ChangeNotifier, kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';

/// 头像本地缓存（App/桌面端）：本地副本文件 avatar.jpg，断网也能显示旧头像。
/// 版本驱动（对齐参考架构 syncMyProfile 的 avatar 段）：服务器 avatar_version 与本地记录一致
/// 且本地副本存在 → 跳过下载；有新版才下载覆盖；服务器无头像 → 清本地副本与版本；
/// 网络失败保留旧缓存。真正下载/清除后 bump avatarChanged 通知页面刷新（无需手动刷新）。

/// 头像变更通知器：新版本下载落盘 / 服务器头像移除后触发（页面监听后重读本地副本）
final ChangeNotifier avatarChanged = ChangeNotifier();

const _verKey = 'taozhu_avatar_remote_version';

/// 本地记录的服务器头像版本（0=无/未知）
Future<int> storedAvatarVersion() async {
  try {
    return (await SharedPreferences.getInstance()).getInt(_verKey) ?? 0;
  } catch (_) {
    return 0;
  }
}

Future<void> setStoredAvatarVersion(int v) async {
  try {
    await (await SharedPreferences.getInstance()).setInt(_verKey, v);
  } catch (_) {}
}

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

Future<void> saveAvatarLocal(List<int> bytes) async {
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

/// 版本驱动头像同步：
/// [profile] 为 /auth/me 的 user 对象（含 avatar/avatar_version），调用方已拉过时传入避免重复请求；
/// 不传则自行拉取（WS profile_change 触发等独立场景）。
/// 返回 true=服务器有头像（本地副本可用）/ null=服务器无头像（已清本地）/ false=网络失败（保留旧缓存）。
Future<bool?> syncAvatarCache([Map<String, dynamic>? profile]) async {
  if (kIsWeb) return null;
  try {
    final u = profile ?? (await Api.instance.get('/auth/me'))['user'] as Map<String, dynamic>?;
    if (u == null) return false;
    final hasRemote = u['avatar'] != null && '${u['avatar']}'.isNotEmpty;
    final remoteVer = (u['avatar_version'] as num?)?.toInt() ?? 0;
    if (!hasRemote) {
      // 服务器无头像 → 清本地副本与版本，通知页面移除头像显示
      final hadLocal = (await avatarLocalFile()) != null || (await storedAvatarVersion()) > 0;
      await clearAvatarLocal();
      await setStoredAvatarVersion(0);
      if (hadLocal) avatarChanged.notifyListeners();
      return null;
    }
    final localVer = await storedAvatarVersion();
    final localFile = await avatarLocalFile();
    // 版本一致且本地副本存在 → 跳过下载（省流量）；版本为 0（历史数据）时按内容下载一次后记录
    if (remoteVer > 0 && remoteVer == localVer && localFile != null) return true;
    final bytes = await Api.instance.getAvatarBytes();
    if (bytes == null) {
      // 服务器列有引用但文件缺失：清空本地，按无头像处理
      await clearAvatarLocal();
      await setStoredAvatarVersion(0);
      avatarChanged.notifyListeners();
      return null;
    }
    await saveAvatarLocal(bytes);
    await setStoredAvatarVersion(remoteVer);
    // 真下载了新头像才通知（版本一致/无头像分支不触发，避免冷启动多余刷新）
    avatarChanged.notifyListeners();
    return true;
  } catch (_) {
    // 网络失败：保留旧缓存
    return false;
  }
}
