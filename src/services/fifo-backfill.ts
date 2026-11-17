/** 历史 FIFO 批次账回填（一次性、可分批续跑、幂等）。
 *
 * 背景：去单据化后 App 主写入是行级 sale_item/purchase_item upsert，但 0.17.525 之前
 * 服务端只在整单/REST 路径维护 stock_batches/sale_batch_uses → 历史 App 进货没有批次、
 * 出货没有批次占用。影响库存金额（按剩余批次成本）、Web 出货成本、盘点盘亏扣批。
 *
 * 做法：按「商品+单位」分组重放全历史（本地 App 的 FIFO 同算法）：
 *   进货行 + 盘盈行 → 建批（batch_id=流水行 id，remaining=数量）
 *   出货/报损/盘亏 → 按 happened_at/created_at/id 时间序从最早批次扣减
 *   出货的扣减写入 sale_batch_uses（行编辑/删除时能正确释放）
 * 每次请求处理有限分组，游标存 schema_meta，可断点续跑；重复执行结果一致。
 * 不改 sale_items.cost_price（不动历史毛利快照，只修批次账/库存估值）。
 */
import type { D1Database, D1PreparedStatement } from '@cloudflare/workers-types';

const STATE_KEY = 'fifo_backfill_state';
const MAX_GROUPS_LIMIT = 50;

interface BackfillState {
  cursor_id: string;
  cursor_unit: string;
  processed: number;
  batches: number;
  uses: number;
  done: boolean;
}

const EMPTY_STATE: BackfillState = {
  cursor_id: '', cursor_unit: '', processed: 0, batches: 0, uses: 0, done: false,
};

async function loadState(db: D1Database): Promise<BackfillState> {
  try {
    const row = await db.prepare('SELECT value FROM schema_meta WHERE key = ?').bind(STATE_KEY)
      .first<{ value: string }>();
    if (!row?.value) return { ...EMPTY_STATE };
    const s = JSON.parse(row.value) as Partial<BackfillState>;
    return {
      cursor_id: String(s.cursor_id ?? ''),
      cursor_unit: String(s.cursor_unit ?? ''),
      processed: Number(s.processed) || 0,
      batches: Number(s.batches) || 0,
      uses: Number(s.uses) || 0,
      done: s.done === true,
    };
  } catch (_) {
    return { ...EMPTY_STATE };
  }
}

async function saveState(db: D1Database, s: BackfillState): Promise<void> {
  await db.prepare('INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)')
    .bind(STATE_KEY, JSON.stringify(s)).run();
}

async function runChunks(db: D1Database, stmts: D1PreparedStatement[], size = 100): Promise<void> {
  for (let i = 0; i < stmts.length; i += size) {
    await db.batch(stmts.slice(i, i + size));
  }
}

/** 处理一个「商品+单位」分组：重建该组的批次与出货占用 */
async function rebuildGroup(db: D1Database, itemId: string, unit: string): Promise<{ batches: number; uses: number }> {
  // 建批来源：进货行 + 盘盈行（时间序）
  const buys = await db.prepare(
    `SELECT id, price, quantity, happened_at, created_at FROM (
       SELECT id, purchase_price AS price, quantity, happened_at, created_at
         FROM purchase_items WHERE item_id = ? AND unit = ?
       UNION ALL
       SELECT id, price, qty AS quantity, happened_at, created_at
         FROM stock_adjustments WHERE item_id = ? AND unit = ? AND qty > 0
     ) ORDER BY happened_at ASC, created_at ASC, id ASC`,
  ).bind(itemId, unit, itemId, unit).all<{
    id: string; price: number; quantity: number; happened_at: string | null; created_at: string | null;
  }>();

  // 消耗事件：出货 + 报损 + 盘亏（时间序）
  const events = await db.prepare(
    `SELECT id, qty, kind, happened_at, created_at FROM (
       SELECT id, quantity AS qty, 'sale' AS kind, happened_at, created_at
         FROM sale_items WHERE item_id = ? AND unit = ?
       UNION ALL
       SELECT id, qty, 'loss' AS kind, happened_at, created_at
         FROM loss_records WHERE item_id = ? AND unit = ?
       UNION ALL
       SELECT id, -qty AS qty, 'adjust' AS kind, happened_at, created_at
         FROM stock_adjustments WHERE item_id = ? AND unit = ? AND qty < 0
     ) ORDER BY happened_at ASC, created_at ASC, id ASC`,
  ).bind(itemId, unit, itemId, unit, itemId, unit).all<{
    id: string; qty: number; kind: 'sale' | 'loss' | 'adjust';
    happened_at: string | null; created_at: string | null;
  }>();

  // 内存里模拟 FIFO（不逐行打 DB，避免子请求爆炸）
  const batches = buys.results.map((b) => ({
    id: b.id,
    price: Number(b.price) || 0,
    remaining: Number(b.quantity) || 0,
    happened_at: b.happened_at ?? '',
    created_at: b.created_at ?? '',
  }));
  const uses: Array<{ saleId: string; batchId: string; qty: number }> = [];
  for (const e of events.results) {
    let need = Number(e.qty) || 0;
    if (!(need > 0)) continue;
    for (const b of batches) {
      if (need <= 0) break;
      if (!(b.remaining > 0)) continue;
      const used = Math.min(need, b.remaining);
      b.remaining -= used;
      need -= used;
      if (e.kind === 'sale') uses.push({ saleId: e.id, batchId: b.id, qty: used });
    }
    // 批次不足（历史缺进货/超卖）：剩余部分忽略，与服务器 consumeFifo 同口径
  }

  const stmts: D1PreparedStatement[] = [
    db.prepare('DELETE FROM stock_batches WHERE item_id = ? AND unit = ?').bind(itemId, unit),
    db.prepare(
      'DELETE FROM sale_batch_uses WHERE sale_item_id IN (SELECT id FROM sale_items WHERE item_id = ? AND unit = ?)',
    ).bind(itemId, unit),
  ];
  for (const b of batches) {
    stmts.push(db.prepare(
      'INSERT INTO stock_batches (batch_id, item_id, unit, price, remaining, happened_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
    ).bind(b.id, itemId, unit, b.price, Math.max(0, b.remaining), b.happened_at, b.created_at));
  }
  for (const u of uses) {
    stmts.push(db.prepare(
      'INSERT OR REPLACE INTO sale_batch_uses (sale_item_id, batch_id, qty) VALUES (?, ?, ?)',
    ).bind(u.saleId, u.batchId, u.qty));
  }
  await runChunks(db, stmts);
  return { batches: batches.length, uses: uses.length };
}

/** 跑一步回填：处理至多 maxGroups 个「商品+单位」分组。
 *  maxGroups<=0 时只返回当前状态（客户端判断是否已完成用）。 */
export async function runFifoBackfillStep(
  db: D1Database,
  opts: { maxGroups?: number; reset?: boolean } = {},
): Promise<{
  done: boolean; processed: number; total_processed: number;
  batches: number; uses: number; cursor: string; groups_left?: number;
}> {
  if (opts.reset) {
    await db.prepare('DELETE FROM schema_meta WHERE key = ?').bind(STATE_KEY).run();
  }
  let state = await loadState(db);
  const maxGroups = Math.min(Math.max(Number(opts.maxGroups) || 0, 0), MAX_GROUPS_LIMIT);
  if (state.done || maxGroups === 0) {
    return {
      done: state.done, processed: 0, total_processed: state.processed,
      batches: state.batches, uses: state.uses,
      cursor: state.cursor_id ? `${state.cursor_id}\u0000${state.cursor_unit}` : '',
    };
  }

  const groups = await db.prepare(
    `SELECT item_id, unit FROM (
       SELECT item_id, unit FROM purchase_items
       UNION SELECT item_id, unit FROM sale_items
       UNION SELECT item_id, unit FROM loss_records
       UNION SELECT item_id, unit FROM stock_adjustments
     )
     WHERE ? = '' OR item_id > ? OR (item_id = ? AND unit > ?)
     ORDER BY item_id, unit LIMIT ?`,
  ).bind(state.cursor_id, state.cursor_id, state.cursor_id, state.cursor_unit, maxGroups + 1)
    .all<{ item_id: string; unit: string }>();
  // 多取 1 个判断是否还有后续（否则"剩余数恰好=上限"会误判未完成，多跑一轮空请求）
  const todo = groups.results.slice(0, maxGroups);
  const hasMore = groups.results.length > maxGroups;

  let processed = 0;
  let batches = 0;
  let uses = 0;
  for (const g of todo) {
    const r = await rebuildGroup(db, g.item_id, g.unit);
    batches += r.batches;
    uses += r.uses;
    processed += 1;
    state = { ...state, cursor_id: g.item_id, cursor_unit: g.unit };
  }
  state = {
    ...state,
    processed: state.processed + processed,
    batches: state.batches + batches,
    uses: state.uses + uses,
    done: !hasMore,
  };
  await saveState(db, state);
  return {
    done: state.done,
    processed,
    total_processed: state.processed,
    batches: state.batches,
    uses: state.uses,
    cursor: state.cursor_id ? `${state.cursor_id}\u0000${state.cursor_unit}` : '',
  };
}
