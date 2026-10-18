/** FIFO 批次成本：进货每行一个批次（stock_batches，batch_id=进货行 id），
 *  出货按 happened_at/created_at 先进先出逐批扣减 remaining 并加权算成本；
 *  批次不足部分由调用方按商品档案进价兜底。批次总量与 stocks 库存总量保持一致
 *  （出货无论成本是否手动指定都消耗批次，否则重建对不平）。 */

export interface FifoUse {
  batchId: string;
  qty: number;
}

export interface FifoResult {
  /** 已消耗批次的加权成本（Σ qty×批价） */
  cost: number;
  /** 批次不足的数量（需按档案进价兜底） */
  leftover: number;
  /** 各批次用量（出写入 use 表、回滚时按它恢复 remaining） */
  uses: FifoUse[];
}

/** 按先进先出消耗该商品+单位 qty，返回加权成本/用量/不足量（不写库，返回 statements 由调用方 batch 执行） */
export async function consumeFifoStatements(
  db: D1Database, itemId: string, unit: string, qty: number, saleItemId: string,
): Promise<{ result: FifoResult; stmts: D1PreparedStatement[] }> {
  const batches = await db.prepare(
    `SELECT batch_id, price, remaining FROM stock_batches
     WHERE item_id = ? AND unit = ? AND remaining > 0
     ORDER BY happened_at ASC, created_at ASC`,
  ).bind(itemId, unit).all<{ batch_id: string; price: number; remaining: number }>();
  let need = qty;
  let cost = 0;
  const uses: FifoUse[] = [];
  for (const b of batches.results) {
    if (need <= 0) break;
    const used = Math.min(need, b.remaining);
    uses.push({ batchId: b.batch_id, qty: used });
    cost += used * b.price;
    need -= used;
  }
  const stmts: D1PreparedStatement[] = [
    ...uses.map((u) => db.prepare('UPDATE stock_batches SET remaining = remaining - ? WHERE batch_id = ?').bind(u.qty, u.batchId)),
    ...uses.map((u) => db.prepare('INSERT OR REPLACE INTO sale_batch_uses (sale_item_id, batch_id, qty) VALUES (?, ?, ?)').bind(saleItemId, u.batchId, u.qty)),
  ];
  return { result: { cost, leftover: need, uses }, stmts };
}

/** 释放某出货行的批次占用（行编辑/删除/整单替换/删除时回滚 remaining 并清 use 记录） */
export async function releaseSaleUsesStatements(
  db: D1Database, saleItemId: string,
): Promise<D1PreparedStatement[]> {
  const uses = await db.prepare(
    'SELECT batch_id, qty FROM sale_batch_uses WHERE sale_item_id = ?',
  ).bind(saleItemId).all<{ batch_id: string; qty: number }>();
  if (uses.results.length === 0) return [db.prepare('DELETE FROM sale_batch_uses WHERE sale_item_id = ?').bind(saleItemId)];
  return [
    ...uses.results.map((u) => db.prepare('UPDATE stock_batches SET remaining = remaining + ? WHERE batch_id = ?').bind(u.qty, u.batch_id)),
    db.prepare('DELETE FROM sale_batch_uses WHERE sale_item_id = ?').bind(saleItemId),
  ];
}

/** 损耗（报损）扣减：按先进先出从最早批次扣 remaining，返回加权损耗金额与不足量（不写 uses——损耗不可回滚，只记流水） */
export async function consumeLossStatements(
  db: D1Database, itemId: string, unit: string, qty: number,
): Promise<{ amount: number; leftover: number; stmts: D1PreparedStatement[] }> {
  const batches = await db.prepare(
    `SELECT batch_id, price, remaining FROM stock_batches
     WHERE item_id = ? AND unit = ? AND remaining > 0
     ORDER BY happened_at ASC, created_at ASC`,
  ).bind(itemId, unit).all<{ batch_id: string; price: number; remaining: number }>();
  let need = qty;
  let amount = 0;
  const stmts: D1PreparedStatement[] = [];
  for (const b of batches.results) {
    if (need <= 0) break;
    const used = Math.min(need, b.remaining);
    stmts.push(db.prepare('UPDATE stock_batches SET remaining = remaining - ? WHERE batch_id = ?').bind(used, b.batch_id));
    amount += used * b.price;
    need -= used;
  }
  return { amount, leftover: need, stmts };
}