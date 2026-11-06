/**
 * 附件引用计数（entity_id → 引用条数）。
 *
 * 旧实现按 90 个 id 分批 IN 查询（D1 单条绑定参数上限 100）：账本页 / 进货历史页每次列渲染、
 * 同步面板每次刷新，都会产生几十~上百条 `attachment_refs WHERE entity=? AND entity_id IN (...)`
 * 查询。若 idx_attachment_refs_entity 未建成（额度耗尽时 ensureIndexes 补建会失败），
 * 每一批都是 attachment_refs 全表扫 —— 曾单日累计 39 万 rows_read，是 #1 消耗源。
 *
 * 改为一次 GROUP BY 取该实体类型的全部计数，JS 侧按 ids 集合过滤：
 *  - 有 (entity, entity_id) 索引时是覆盖索引扫描，无需回表；
 *  - 索引缺失时也只是读一次表，而不是读 N 批 × 全表；
 * 因此不再依赖「索引到底建没建成功」，且 SQL 条数从上百条降到 1 条。
 */
export async function refCountByEntity(
  db: D1Database,
  entity: string,
): Promise<Map<string, number>> {
  const rows = await db.prepare(
    'SELECT entity_id, COUNT(*) AS cnt FROM attachment_refs WHERE entity = ? GROUP BY entity_id',
  ).bind(entity).all<{ entity_id: string; cnt: number }>();
  const counts = new Map<string, number>();
  for (const r of rows.results) counts.set(r.entity_id, Number(r.cnt) || 0);
  return counts;
}
