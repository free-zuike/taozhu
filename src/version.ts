/** 项目版本号（三位：主版本.功能版本.修复版本；微信小程序不支持四段）——发版时手动递增 */
export const APP_VERSION = '0.17.146';
export const APP_NAME = '陶朱';

/**
 * 最低支持版本：低于此版本的原生客户端（携带 x-app-version 头）调用 API 返回 426 强制更新。
 * 服务端协议/存储有破坏性变更（如彻底删除 sales/purchases 头表）时提升到最新版；普通修复版不升。
 * 已安装的旧版 App 不带版本头（头是本机制引入后才有的）——由新版 App 启动时对比
 * /auth/latest-version 的 min_supported 弹不可关闭的强制更新窗（更新后即进入门禁体系）。
 */
export const MIN_SUPPORTED_VERSION = '0.17.114';

/** 三位版本号比较：a < b ? true（版本号格式非法时按相等处理，不误伤） */
export function versionBelow(a: string, b: string): boolean {
  const pa = a.split('.').map((x) => parseInt(x, 10));
  const pb = b.split('.').map((x) => parseInt(x, 10));
  if (pa.some((x) => Number.isNaN(x)) || pb.some((x) => Number.isNaN(x))) return false;
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] ?? 0;
    const y = pb[i] ?? 0;
    if (x !== y) return x < y;
  }
  return false;
}