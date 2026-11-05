/**
 * D1 不可用（免费额度耗尽 / 限流 / 连接失败）的识别与只读降级。
 *
 * D1 按 rows_read / rows_written 计费，额度耗尽后所有 db.prepare(...).run/all/first
 * 都会抛错。此前这些异常直接冒泡：ensureSchema 中间件把故障放大到全部 /api/v1/*，
 * Hono 默认返回裸 500，前端只显示「请求失败(500)」——用户完全不知道发生了什么。
 *
 * 这里统一：基础设施错误 → 中文 503；纯展示型只读接口 → 降级为空数据（页面仍可打开，
 * 沿用客户端本地缓存）。业务代码 bug 不匹配这些关键词，仍照常抛出以便暴露。
 */
const DB_UNAVAILABLE_RE = /d1_error|d1_database|quota|exceed|rate.?limit|too many|daily limit|rows_read|rows_written|connection|network|timeout|timed out|locked|unavailable|temporar|service unavailable/i;

export function isDbUnavailable(e: unknown): boolean {
  const msg = e instanceof Error ? `${e.name} ${e.message}` : String(e ?? '');
  return DB_UNAVAILABLE_RE.test(msg.toLowerCase());
}

export const DB_UNAVAILABLE_MESSAGE = '云端数据库额度已用尽或暂时不可用，请稍后再试；本机数据仍可查看';

/**
 * 只读展示接口降级：D1 不可用时返回空数据，避免整页 500。
 * 只用于「列表/历史/配置读取」这类返回空值不会产生错误操作的场景，切勿用于写路径。
 */
export async function readOrFallback<T>(
  label: string,
  fn: () => Promise<T>,
  fallback: T,
): Promise<T> {
  try {
    return await fn();
  } catch (e) {
    if (!isDbUnavailable(e)) throw e;
    console.warn(`[taozhu] ${label}: D1 不可用，降级为空数据`, e);
    return fallback;
  }
}
