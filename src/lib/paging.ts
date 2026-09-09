/** 列表分页参数解析：limit 默认 500（上限 1000），offset 默认 0 */

export function parsePage(
  limitRaw: string | null | undefined,
  offsetRaw: string | null | undefined,
): { limit: number; offset: number } {
  const limit = Math.min(Math.max(parseInt(limitRaw ?? '', 10) || 500, 1), 1000);
  const offset = Math.max(parseInt(offsetRaw ?? '', 10) || 0, 0);
  return { limit, offset };
}