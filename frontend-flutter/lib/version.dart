/// Flutter 应用版本号（三位：主版本.功能版本.修复版本；微信不支持四段）——发版时递增，与 src/version.ts 语义同步
const APP_VERSION = '0.17.463';
const APP_NAME = '陶朱';

/// 最低支持版本（与 src/version.ts MIN_SUPPORTED_VERSION 同步）：App 启动时直连 GitHub
/// 检查更新，低于此版本弹不可关闭的强制更新窗；服务端 426 门禁仍独立生效（携带版本头过低时拒接口）。
const MIN_SUPPORTED_VERSION = '0.17.114';

/// 三位版本号比较：a < b ? true（版本号格式非法时按相等处理，不误伤）——与服务端 src/version.ts 同逻辑
bool versionBelow(String a, String b) {
  final pa = a.split('.').map(int.tryParse).toList();
  final pb = b.split('.').map(int.tryParse).toList();
  if (pa.any((x) => x == null) || pb.any((x) => x == null)) return false;
  for (var i = 0; i < (pa.length > pb.length ? pa.length : pb.length); i++) {
    final x = (i < pa.length ? pa[i] : 0) ?? 0;
    final y = (i < pb.length ? pb[i] : 0) ?? 0;
    if (x != y) return x < y;
  }
  return false;
}

