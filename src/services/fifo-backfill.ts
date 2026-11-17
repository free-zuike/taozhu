/** 历史 FIFO 批次账回填（一次性、可分批续跑、幂等、带 D1 每日预算）。
 *
 * 背景：去单据化后 App 主写入是行级 sale_item/purchase_item upsert，但 0.17.525 之前
 * 服务端只在整单/REST 路径维护 stock_batches/sale_batch_uses → 历史 App 进货没有批次、
 * 出货没有批次占用。影响库存金额（按剩余批次成本）、Web 出货成本、盘点盘亏扣批。
 *
 * 成本控制（免费 D1：500 万行读/天、10 万行写/天）：
 *  - 第一次调用只做一次「需要修复的组」清单（进货缺批次 / 出货缺占用且已有批次），
 *    结果存 schema_meta，后续按组处理，不再反复全表扫描；
 *  - 每组只读该「商品+单位」的流水（purchase_items 补了 (item_id,unit) 索引）；
 *  - 每日预算按「流水行数」估算写入量（≈2×行数：删旧批次/占用 + 写新），
 *    超过预算即暂停，次日自动续跑；不会为了补账把当天额度一次烧穿。
 *
 * 算法（与 App 本地 FIFO 同口径）：
 *   进货行 + 盘盈行 → 建批（batch_id=流水行 id，remaining=数量）
 *   出货/报损/盘亏 → 按 happened_at/created_at/id 时间序从最早批次扣减
 *   出货扣减写 sale_batch_uses（行编辑/删除时能正确释放）
 * 不改 sale_items.cost_price（不动历史毛利快照，只修批次账/库存估值）。
 */
import type { D1Database, D1PreparedStatement } from '@cloudflare/workers-types';

const STATE_KEY = 'fifo_backfill_state';
const MAX_GROUPS_LIMIT = 50;
/** 每日最多处理的流水行数估算（写入≈2×该值；默认留足正常记账的写入额度） */
const DEFAULT_DAILY_WORK = 30000;

interface BackfillState {
  /** 待修复组清单（itemId\u0000unit）；null=尚未扫描 */
  groups: string[] | null;
  index: number;
  processed: number;
  batches: number;
  uses: number;
  done: boolean;
  /** 预算日期（UTC YYYY-MM-DD）与当日已处理流水行数 */
  day: string;
  day_work: number;
}

const EMPTY_STATE: BackfillState = {
  groups: null, index: 0, processed: 0, batches: 0, uses: 0, done: false, day: '', day_work: 0,
};

async function loadState(db: D1Database): Promise<BackfillState> {
  try {
    const row = await db.prepare('SELECT value FROM schema_meta WHERE key = ?').bind(STATE_KEY)
      .first<{ value: string }>();
    if (!row?.value) return { ...EMPTY_STATE };
    const s = JSON.parse(row.value) as Partial<BackfillState>;
    return {
      groups: Array.isArray(s.groups) ? (s.groups as string[]).map(String) : null,
      index: Math.max(0, Number(s.index) || 0),
      processed: Number(s.processed) || 0,
      batches: Number(s.batches) || 0,
      uses: Number(s.uses) || 0,
      done: s.done === true,
      day: String(s.day ?? ''),
      day_work: Number(s.day_work) || 0,
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

/** 一次性扫描：只挑真正需要修复的组（避免对已正确维护的组做无谓重写） */
async function scanGroups(db: D1Database): Promise<string[]> {
  const rows = await db.prepare(
    `SELECT item_id, unit FROM (
       SELECT pi.item_id, pi.unit FROM purchase_items pi
       WHERE NOT EXISTS (SELECT 1 FROM stock_batches b WHERE b.batch_id = pi.id)
       UNION
       SELECT si.item_id, si.unit FROM sale_items si
       WHERE NOT EXISTS (SELECT 1 FROM sale_batch_uses u WHERE u.sale_item_id = si.id)
         AND EXISTS (SELECT 1 FROM stock_batches b WHERE b.item_id = si.item_id AND b.unit = si.unit)
     ) ORDER BY item_id, unit`,
  ).all<{ item_id: string; unit: string }>();
  return rows.results.map((r) => `${r.item_id}\u0000${r.unit}`);
}

/** 处理一个「商品+单位」分组：重建该组的批次与出货占用，返回处理的流水行数 */
async function rebuildGroup(
  db: D1Database, itemId: string, unit: string,
): Promise<{ work: number; batches: number; uses: number }> {
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

  // 内存模拟 FIFO（不逐行打 DB，避免子请求爆炸）
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
  return { work: buys.results.length + events.results.length, batches: batches.length, uses: uses.length };
}

/** 跑一步回填：处理至多 maxGroups 个分组，受每日写入预算限制。
 *  maxGroups<=0 时只返回当前状态（客户端判断是否完成用）。 */
export async function runFifoBackfillStep(
  db: D1Database,
  opts: { maxGroups?: number; reset?: boolean; dailyWork?: number } = {},
): Promise<{
  done: boolean; paused: boolean; processed: number; total_processed: number;
  batches: number; uses: number; total_groups: number; remaining_groups: number;
  day_work: number; daily_budget: number;
}> {
  if (opts.reset) {
    await db.prepare('DELETE FROM schema_meta WHERE key = ?').bind(STATE_KEY).run();
  }
  const budget = Math.max(1, Math.min(Number(opts.dailyWork) || DEFAULT_DAILY_WORK, 200000));
  let state = await loadState(db);
  const today = new Date().toISOString().slice(0, 10);
  if (state.day !== today) {
    state = { ...state, day: today, day_work: 0 };
  }
  const maxGroups = Math.min(Math.max(Number(opts.maxGroups) || 0, 0), MAX_GROUPS_LIMIT);
  if (state.done || maxGroups === 0) {
    return {
      done: state.done, paused: false, processed: 0, total_processed: state.processed,
      batches: state.batches, uses: state.uses,
      total_groups: state.groups?.length ?? 0,
      remaining_groups: state.groups ? Math.max(0, state.groups.length - state.index) : 0,
      day_work: state.day_work, daily_budget: budget,
    };
  }
  // 首次：一次性生成待修复组清单（之后按索引推进，不再全表扫描）
  if (state.groups == null) {
    state = { ...state, groups: await scanGroups(db), index: 0 };
  }
  const groups = state.groups ?? [];
  let processed = 0;
  let batches = 0;
  let uses = 0;
  let paused = false;
  while (processed < maxGroups && state.index < groups.length) {
    const key = groups[state.index];
    const [itemId, unit] = key.split('\u0000');
    if (!itemId || unit === undefined) {
      state.index += 1;
      continue;
    }
    // 预算检查放在处理前：预算不足则保留该组，次日继续
    // 先读组流水行数（rebuildGroup 会再读一次；两组 SELECT 都很轻，避免为估预算先处理）
    const cnt = await db.prepare(
      `SELECT (
         (SELECT COUNT(*) FROM purchase_items WHERE item_id = ? AND unit = ?) +
         (SELECT COUNT(*) FROM stock_adjustments WHERE item_id = ? AND unit = ?) +
         (SELECT COUNT(*) FROM sale_items WHERE item_id = ? AND unit = ?) +
         (SELECT COUNT(*) FROM loss_records WHERE item_id = ? AND unit = ?) +
         (SELECT COUNT(*) FROM stock_adjustments WHERE item_id = ? AND unit = ? AND qty < 0)
       ) AS n`,
    ).bind(itemId, unit, itemId, unit, itemId, unit, itemId, unit, itemId, unit)
      .first<{ n: number }>();
    const work = Number(cnt?.n) || 0;
    if (state.day_work + work > budget && state.day_work > 0) {
      paused = true;
      break;
    }
    const rows = await rebuildGroup(db, itemId, unit);
    state = {
      ...state,
      index: state.index + 1,
      processed: state.processed + 1,
      batches: state.batches + rows.batches,
      uses: state.uses + rows.uses,
      day_work: state.day_work + Math.max(work, rows.work),
    };
    batches += rows.batches;
    uses += rows.uses;
    processed += 1;
  }
  state = { ...state, done: state.index >= groups.length };
  await saveState(db, state);
  return {
    done: state.done,
    paused,
    processed,
    total_processed: state.processed,
    batches: state.batches,
    uses: state.uses,
    total_groups: groups.length,
    remaining_groups: Math.max(0, groups.length - state.index),
    day_work: state.day_work,
    daily_budget: budget,
  };
}
