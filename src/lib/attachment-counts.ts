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

/**
 * 单据级附件统计里的「明细行引用」计数（order_id → 该单全部明细行的引用条数）。
 *
 * 旧实现按 90 个单据 id 分批 `SELECT id, sale_id AS order_id FROM sale_items WHERE sale_id IN (...)`
 * 回表，再用行级计数 Map 逐行累加：单据数一多就是 N 次索引查找，生产 Top SQL 里长期在榜。
 * 改为以 attachment_refs 的 (entity, entity_id) 覆盖索引为驱动，一次 JOIN + GROUP BY 只聚合
 * 「确实有引用」的明细行——SQL 条数恒为 1，读行数≈引用条数而非全表明细，且不受 100 绑定参数上限。
 * 表名/列名只由内部字面量推导，不拼接外部输入。
 */
export async function orderRefCountsFromLines(
  db: D1Database,
  lineEntity: 'sale_item' | 'purchase_item',
  opts: { clientId?: string; orderIds: readonly string[] },
): Promise<Map<string, number>> {
  const table = lineEntity === 'sale_item' ? 'sale_items' : 'purchase_items';
  const orderCol = lineEntity === 'sale_item' ? 'sale_id' : 'purchase_id';
  // purchase_items 无 client_id 列；按店铺过滤仅在出货明细上生效（与旧分批查询口径一致）
  const scoped = lineEntity === 'sale_item' && !!opts.clientId;
  const rows = await db.prepare(
    `SELECT si.${orderCol} AS order_id, COUNT(*) AS cnt
     FROM attachment_refs ar JOIN ${table} si ON si.id = ar.entity_id
     WHERE ar.entity = ?${scoped ? ' AND si.client_id = ?' : ''}
     GROUP BY si.${orderCol}`,
  ).bind(lineEntity, ...(scoped ? [opts.clientId] : [])).all<{ order_id: string; cnt: number }>();
  const wanted = new Set(opts.orderIds);
  const counts = new Map<string, number>();
  for (const r of rows.results) {
    // 只回填请求/当前店铺范围内的单据，避免把别的单据计数塞进返回体
    if (wanted.has(r.order_id)) counts.set(r.order_id, Number(r.cnt) || 0);
  }
  return counts;
}
