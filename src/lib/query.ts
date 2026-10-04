/** D1 分批查询辅助：单条 SQL 绑定参数上限 100（Cloudflare 官方限制），
 * 动态 IN 列表超过 100 个 id 必须分批执行后合并结果，否则整条查询 500。
 * run 接收一批 id，执行带 IN 的查询并返回「行数组」（.all().results 在调用方提取）。
 */

export const D1_CHUNK = 90; // 留余量：实际上限 100，90 兜底（IN 外加其它绑定参数）

/** 按批执行查询并合并行：ids 为空直接返回空数组，不执行查询 */
export async function chunkQuery<T>(
  ids: string[],
  run: (chunk: string[]) => Promise<T[]>,
): Promise<T[]> {
  if (ids.length === 0) return [];
  const out: T[] = [];
  for (let i = 0; i < ids.length; i += D1_CHUNK) {
    const part = ids.slice(i, i + D1_CHUNK);
    const rows = await run(part);
    out.push(...rows);
  }
  return out;
}
