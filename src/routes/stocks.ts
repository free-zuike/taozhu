/** 库存：按 商品+单位 查看/盘点/设预警阈值。
 *  日常变动由 进货(+) / 出货(−) 单据在事务内自动增减（见 sales/purchases）。 */
import { Hono } from 'hono';
import { adminOnly, authMiddleware } from '../middleware/auth';
import { stockUpsert, stockUpsertMin } from '../lib/stock';
import { chunkQuery } from '../lib/query';
import { consumeFifoStatements, consumeLossStatements } from '../lib/fifo';
import { randomId } from '../lib/password';
import { recordChange } from '../lib/sync';
import { recordAudit } from './audit';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const stocksRouter = new Hono<{ Bindings: Env; Variables: V }>();
stocksRouter.use('*', authMiddleware());

const nowIso = () => new Date().toISOString();

// GET /stocks?q=&below=1 — 库存列表（含商品名；below=1 仅低于阈值）
// 库存 = 计算值：Σ进货(+)/出货(−) 流水按 商品+单位 累计（用户"库存应该是计算出来的不是写入数据库"）；
// 不再读取 stocks.quantity（旧盘点/手动填写残留=没进货却显示正数根因）；阈值 min_stock 保留。
stocksRouter.get('/', async (c) => {
  const canSeeCost = c.get('user').role === 'admin';
  const q = c.req.query('q')?.trim() ?? '';
  const belowOnly = c.req.query('below') === '1';
  // 库存 = 计算值：Σ进货(+)/出货(−) 流水按 商品+单位 累计（用户"库存应该是计算出来的不是写入数据库"）；
  // 与 /rebuild 同构（一层 UNION ALL + GROUP BY，兼容 FakeD1/生产），商品名/阈值/进价在 JS 侧合并，
  // stocks.quantity 不再读取（旧盘点/手动填写残留=没进货却显示正数根因），min_stock 阈值保留。
  const agg = await c.env.DB.prepare(
    `SELECT item_id, unit, SUM(qty) AS quantity FROM (
       SELECT item_id, unit, COALESCE(quantity, 0) AS qty FROM purchase_items
       UNION ALL
       SELECT item_id, unit, -COALESCE(quantity, 0) AS qty FROM sale_items
       UNION ALL
       SELECT item_id, unit, -COALESCE(qty, 0) AS qty FROM loss_records
     ) GROUP BY item_id, unit`,
  ).all<{ item_id: string; unit: string; quantity: number }>();
  const itemIds = [...new Set(agg.results.map((r) => r.item_id))];
  const [itemRows, stockRows, batchCostRows, priceRows] = await Promise.all([
    itemIds.length
      ? chunkQuery(itemIds, (chunk) =>
          c.env.DB.prepare(
            `SELECT id, name, count_unit FROM items WHERE id IN (${chunk.map(() => '?').join(',')}) AND deleted_at IS NULL`,
          ).bind(...chunk).all<{ id: string; name: string; count_unit: string | null }>().then((r) => r.results))
      : Promise.resolve([] as Array<{ id: string; name: string; count_unit: string | null }>),
    c.env.DB.prepare('SELECT item_id, unit, id, min_stock FROM stocks').all<{ item_id: string; unit: string; id: string; min_stock: number }>(),
    // 库存成本 = 剩余批次加权单价（FIFO：剩多少批、每批什么价 → 平均成本）；无批次用档案进价兜底
    c.env.DB.prepare(
      'SELECT item_id, unit, SUM(price * remaining) AS amount, SUM(remaining) AS qty FROM stock_batches GROUP BY item_id, unit',
    ).all<{ item_id: string; unit: string; amount: number; qty: number }>(),
    c.env.DB.prepare('SELECT item_id, unit, purchase_price FROM item_prices WHERE active = 1').all<{ item_id: string; unit: string; purchase_price: number }>(),
  ]);
  const itemName = new Map(itemRows.map((x) => [x.id, x.name]));
  const itemCountUnit = new Map(itemRows.map((x) => [x.id, x.count_unit ?? '']));
  const stockCfg = new Map(stockRows.results.map((x) => [`${x.item_id}\u0000${x.unit}`, x]));
  const batchCost = new Map(batchCostRows.results.map((x) => [`${x.item_id}\u0000${x.unit}`, Number(x.qty) > 0 ? Number(x.amount) / Number(x.qty) : 0]));
  const archiveCost = new Map(priceRows.results.map((x) => [`${x.item_id}\u0000${x.unit}`, Number(x.purchase_price) || 0]));
  const merged = agg.results
    .map((r) => ({ ...r, item_name: itemName.get(r.item_id) ?? '', count_unit: itemCountUnit.get(r.item_id) ?? '' }))
    .filter((r) => r.item_name !== '') // 商品已删除（deleted_at）→ 不显示
    .filter((r) => !q || r.item_name.includes(q))
    .sort((a, b) => a.item_name.localeCompare(b.item_name) || a.unit.localeCompare(b.unit));
  // 建议预警阈值 = 近 30 天平均每笔出货量 × 40%（无出货记录则 0）。
  // 前端仅"阈值未手动设置（min_stock=0）且库存 ≥1"时自动填充，不覆盖用户手设值。
  const keys = merged.map((r) => `${r.item_id}\u0000${r.unit}`);
  let suggest = new Map<string, number>();
  if (keys.length > 0) {
    const ph = new Set(keys);
    const sid = [...ph].map((k) => k.split('\u0000')[0]);
    const sunit = [...ph].map((k) => k.split('\u0000')[1]);
    // 按 商品+单位 近 30 天出货行均值（避免跨单位混算；商品行自带日期，不再 JOIN 单据头）
    const avgRows = await chunkQuery(sid, (chunk) =>
      c.env.DB.prepare(
        `SELECT si.item_id, si.unit, AVG(si.quantity) AS avg_qty
         FROM sale_items si
         WHERE si.happened_at >= date('now','-30 day')
           AND si.item_id IN (${chunk.map(() => '?').join(',')})
         GROUP BY si.item_id, si.unit`,
      ).bind(...chunk).all<{ item_id: string; unit: string; avg_qty: number }>().then((r) => r.results));
    suggest = new Map(avgRows.map((r) => [
      `${r.item_id}\u0000${r.unit}`,
      Math.round((Number(r.avg_qty) || 0) * 0.4 * 100) / 100,
    ]));
  }
  const rows = merged
    .map((r) => {
      const cfg = stockCfg.get(`${r.item_id}\u0000${r.unit}`);
      return { ...r, id: cfg?.id ?? null, min_stock: cfg?.min_stock ?? 0 };
    })
    .filter((r) => !belowOnly || (Number(r.quantity) || 0) <= (Number(r.min_stock) || 0));
  return c.json({
    stocks: rows.map((r) => ({
      id: r.id ?? '', item_id: r.item_id, item_name: r.item_name, unit: r.unit, count_unit: r.count_unit,
      // 负数库存（卖出多于进）按 0 展示：没有就是 0；两位小数防浮点尾数（1.7000000000000002 斤）
      quantity: Math.round(Math.max(Number(r.quantity) || 0, 0) * 100) / 100,
      min_stock: Number(r.min_stock) || 0,
      suggest_min: suggest.get(`${r.item_id}\u0000${r.unit}`) ?? 0,
      cost_price: canSeeCost ? (batchCost.get(`${r.item_id}\u0000${r.unit}`) || archiveCost.get(`${r.item_id}\u0000${r.unit}`) || 0) : 0,
      low: (Number(r.quantity) || 0) <= (Number(r.min_stock) || 0),
    })),
    can_see_cost: canSeeCost,
  });
});

// GET /stocks/alerts?days=7 — 库存预警聚合：低库存（库存≤阈值）+ 临期（批次到期 ≤ 今天+days 且剩余>0）。
// 首页/「我的」提醒用；同商品+单位多批合并显示最早到期批，剩余量=各批合计。
stocksRouter.get('/alerts', async (c) => {
  const days = Math.min(Math.max(Number(c.req.query('days')) || 7, 1), 90);
  const today = new Date().toISOString().slice(0, 10);
  const limitDate = new Date(Date.now() + days * 86400000).toISOString().slice(0, 10);
  const [agg, stockRows, itemRows, expRows] = await Promise.all([
    c.env.DB.prepare(
      `SELECT item_id, unit, SUM(qty) AS quantity FROM (
         SELECT item_id, unit, COALESCE(quantity, 0) AS qty FROM purchase_items
         UNION ALL
         SELECT item_id, unit, -COALESCE(quantity, 0) AS qty FROM sale_items
         UNION ALL
         SELECT item_id, unit, -COALESCE(qty, 0) AS qty FROM loss_records
       ) GROUP BY item_id, unit`,
    ).all<{ item_id: string; unit: string; quantity: number }>(),
    c.env.DB.prepare('SELECT item_id, unit, min_stock FROM stocks').all<{ item_id: string; unit: string; min_stock: number }>(),
    c.env.DB.prepare('SELECT id, name FROM items WHERE deleted_at IS NULL').all<{ id: string; name: string }>(),
    c.env.DB.prepare(
      `SELECT sb.item_id, sb.unit, sb.batch_id, sb.remaining, sb.expiry_date, i.name AS item_name
       FROM stock_batches sb JOIN items i ON i.id = sb.item_id
       WHERE sb.expiry_date IS NOT NULL AND sb.expiry_date != '' AND sb.expiry_date <= ?
         AND sb.remaining > 0
       ORDER BY sb.expiry_date ASC, sb.happened_at ASC`,
    ).bind(limitDate).all<{ item_id: string; unit: string; batch_id: string; remaining: number; expiry_date: string; item_name: string }>(),
  ]);
  const itemName = new Map(itemRows.results.map((x) => [x.id, x.name]));
  const minMap = new Map(stockRows.results.map((x) => [`${x.item_id}\u0000${x.unit}`, x.min_stock]));
  const low = agg.results
    .map((r) => {
      const min = minMap.get(`${r.item_id}\u0000${r.unit}`) ?? 0;
      const qty = Math.max(Number(r.quantity) || 0, 0);
      return {
        item_id: r.item_id, item_name: itemName.get(r.item_id) ?? '', unit: r.unit,
        quantity: Math.round(qty * 100) / 100, min_stock: Number(min) || 0, low: qty <= (Number(min) || 0),
      };
    })
    .filter((r) => r.item_name !== '' && r.low);
  const expMap = new Map<string, { item_id: string; unit: string; remaining: number; expiry_date: string }>();
  for (const e of expRows.results) {
    const key = `${e.item_id}\u0000${e.unit}`;
    const cur = expMap.get(key);
    if (!cur) {
      expMap.set(key, { item_id: e.item_id, unit: e.unit, remaining: Number(e.remaining) || 0, expiry_date: e.expiry_date });
    } else {
      cur.remaining += Number(e.remaining) || 0;
    }
  }
  const expiring = [...expMap.values()].map((e) => ({
    item_id: e.item_id, item_name: itemName.get(e.item_id) ?? '', unit: e.unit,
    remaining: Math.round(e.remaining * 100) / 100, expiry_date: e.expiry_date,
  })).filter((e) => e.item_name !== '');
  return c.json({ low, expiring, days, today, limit_date: limitDate });
});

// GET /stocks/trace?item_id=&limit= — 该商品的进货/出货流水分录（数量来源明细；行级主记录，无需 JOIN 单据头）
stocksRouter.get('/trace', async (c) => {
  const itemId = c.req.query('item_id')?.trim() ?? '';
  if (!itemId) return c.json({ error: '缺少 item_id' }, 400);
  const limit = Math.min(Math.max(Number(c.req.query('limit')) || 50, 1), 200);
  const out = await c.env.DB.prepare(
    `SELECT * FROM (
       SELECT 'in' AS kind, pi.happened_at, pi.quantity, pi.unit, COALESCE(pi.count_qty, pi.quantity) AS eff_qty, pi.count_qty,
              i.name AS item_name, pi.purchase_id AS ref_id, pi.note
         FROM purchase_items pi JOIN items i ON i.id = pi.item_id
        WHERE pi.item_id = ?
       UNION ALL
       SELECT 'out' AS kind, si.happened_at, si.quantity, si.unit, COALESCE(si.count_qty, si.quantity) AS eff_qty, si.count_qty,
              i.name AS item_name, si.sale_id AS ref_id, si.note
         FROM sale_items si JOIN items i ON i.id = si.item_id
        WHERE si.item_id = ?
     )
     ORDER BY happened_at DESC, ref_id DESC
     LIMIT ?`,
  ).bind(itemId, itemId, limit).all<{ kind: string; happened_at: string; quantity: number; unit: string; eff_qty: number; count_qty: number | null; item_name: string; ref_id: string; note: string | null }>();
  return c.json({ rows: out.results });
});

// PUT /stocks — 盘点/批量设置预警阈值（库存=流水自动计算，quantity 不再写入——旧盘点
// 残留=没进货却显示正数根因；此接口仅用 min_stock）
stocksRouter.put('/', adminOnly(), async (c) => {
  const body = await c.req.json().catch(() => null) as {
    rows?: Array<{ item_id?: string; unit?: string; quantity?: number; min_stock?: number }>;
  } | null;
  const rows = body?.rows ?? [];
  if (!Array.isArray(rows) || rows.length === 0) return c.json({ error: '缺少 rows' }, 400);
  const batch = rows.map((r) => {
    const itemId = r.item_id;
    const unit = r.unit?.trim();
    if (!itemId || !unit) return null;
    const minStock = Number(r.min_stock) || 0;
    if (!Number.isFinite(minStock) || minStock < 0) return null;
    return stockUpsertMin(c.env.DB, itemId, unit, minStock);
  }).filter((s): s is NonNullable<typeof s> => s !== null);
  if (batch.length === 0) return c.json({ error: '盘点数据不合法（需 item_id/unit/阈值≥0）' }, 400);
  await c.env.DB.batch(batch);
  return c.json({ ok: true, updated: batch.length });
});

// POST /stocks/rebuild — 全量重算库存：从进货(+)出货(−)流水重建（保留预警阈值）。
// 用途：历史 App 行级同步路径在旧版（v0.17.144 前）无库存联动，此端点在升级后一次性回补存量。
// 进销单位换算：商品有计数单位且行有折合数（count_qty）→ 库存按计数单位累计（进 1 大单位 count_qty=40 → 库存 +40 计数单位）；
// 未换算行（count_qty 空）与原行为不变。单位用商品计数单位（无则行单位），保证相同商品换算/未换算行归并到同一维度。
stocksRouter.post('/rebuild', adminOnly(), async (c) => {
  const old = await c.env.DB.prepare('SELECT item_id, unit, min_stock FROM stocks')
    .all<{ item_id: string; unit: string; min_stock: number }>();
  const minMap = new Map(old.results.map((r) => [`${r.item_id}\u0000${r.unit}`, r.min_stock]));
  await c.env.DB.prepare('DELETE FROM stocks').run();
  const rows = await c.env.DB.prepare(
    `SELECT item_id, unit, SUM(qty) AS quantity FROM (
       SELECT i.id AS item_id, COALESCE(NULLIF(i.count_unit, ''), pi.unit) AS unit, COALESCE(pi.count_qty, pi.quantity) AS qty
         FROM purchase_items pi JOIN items i ON i.id = pi.item_id
       UNION ALL
       SELECT i.id AS item_id, COALESCE(NULLIF(i.count_unit, ''), si.unit) AS unit, -COALESCE(si.count_qty, si.quantity) AS qty
         FROM sale_items si JOIN items i ON i.id = si.item_id
       UNION ALL
       SELECT i.id AS item_id, COALESCE(NULLIF(i.count_unit, ''), lr.unit) AS unit, -COALESCE(lr.qty, 0) AS qty
         FROM loss_records lr JOIN items i ON i.id = lr.item_id
     ) GROUP BY item_id, unit`,
  ).all<{ item_id: string; unit: string; quantity: number }>();
  const batch = rows.results.map((r) => {
    const min = minMap.get(`${r.item_id}\u0000${r.unit}`) ?? 0;
    return stockUpsert(c.env.DB, r.item_id, r.unit, Math.round(Number(r.quantity) * 100) / 100, min);
  });
  // FIFO 批次重建：清空批次账 → 按进货流水（时间序）建批 → 按出货流水（时间序）重放消耗并重写成本
  batch.push(
    c.env.DB.prepare('DELETE FROM stock_batches'),
    c.env.DB.prepare('DELETE FROM sale_batch_uses'),
  );
  await c.env.DB.batch(batch);
  const purchaseRows = await c.env.DB.prepare(
    `SELECT id, item_id, unit, purchase_price, quantity, happened_at, created_at
     FROM purchase_items ORDER BY happened_at ASC, created_at ASC, id ASC`,
  ).all<{ id: string; item_id: string; unit: string | null; purchase_price: number; quantity: number; happened_at: string | null; created_at: string }>();
  const batchP: D1PreparedStatement[] = purchaseRows.results.map((r) => c.env.DB.prepare(
    'INSERT INTO stock_batches (batch_id, item_id, unit, price, remaining, happened_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
  ).bind(r.id, r.item_id, r.unit ?? '', Number(r.purchase_price) || 0, Number(r.quantity) || 0, r.happened_at ?? '', r.created_at ?? ''));
  for (let i = 0; i < batchP.length; i += 200) {
    await c.env.DB.batch(batchP.slice(i, i + 200));
  }
  const saleRows = await c.env.DB.prepare(
    `SELECT id, item_id, unit, quantity FROM sale_items
     ORDER BY happened_at ASC, created_at ASC, sort ASC, id ASC`,
  ).all<{ id: string; item_id: string; unit: string | null; quantity: number }>();
  const saleBatch: D1PreparedStatement[] = [];
  for (const s of saleRows.results) {
    const qty = Number(s.quantity) || 0;
    if (qty <= 0) continue;
    const { result: fifo, stmts } = await consumeFifoStatements(c.env.DB, s.item_id, s.unit ?? '', qty, s.id);
    saleBatch.push(...stmts);
    if (fifo.leftover > 0) {
      // 批次不足：未消耗部分按商品当前档案进价兜底（无档案则 0）
      const archive = (await c.env.DB.prepare(
        'SELECT purchase_price FROM item_prices WHERE item_id = ? AND unit = ? AND active = 1 ORDER BY created_at DESC LIMIT 1',
      ).bind(s.item_id, s.unit ?? '').first<{ purchase_price: number }>())?.purchase_price ?? 0;
      saleBatch.push(c.env.DB.prepare('UPDATE sale_items SET cost_price = ? WHERE id = ?').bind((fifo.cost + fifo.leftover * archive) / qty, s.id));
    } else if (fifo.cost > 0) {
      saleBatch.push(c.env.DB.prepare('UPDATE sale_items SET cost_price = ? WHERE id = ?').bind(fifo.cost / qty, s.id));
    }
    if (saleBatch.length >= 200) {
      await c.env.DB.batch(saleBatch);
      saleBatch.length = 0;
    }
  }
  if (saleBatch.length > 0) await c.env.DB.batch(saleBatch);
  // 损耗重放：按时间序报损从剩余批次扣减（不写 uses）
  const lossRows = await c.env.DB.prepare(
    `SELECT id, item_id, unit, qty FROM loss_records
     ORDER BY happened_at ASC, created_at ASC, id ASC`,
  ).all<{ id: string; item_id: string; unit: string | null; qty: number }>();
  const lossBatch: D1PreparedStatement[] = [];
  for (const l of lossRows.results) {
    const qty = Number(l.qty) || 0;
    if (qty <= 0) continue;
    const { stmts } = await consumeLossStatements(c.env.DB, l.item_id, l.unit ?? '', qty);
    lossBatch.push(...stmts);
    if (lossBatch.length >= 200) {
      await c.env.DB.batch(lossBatch);
      lossBatch.length = 0;
    }
  }
  if (lossBatch.length > 0) await c.env.DB.batch(lossBatch);
  await recordAudit(c.env.DB, {
    username: c.get('user').username, action: 'rebuild', entity_type: 'stocks',
    detail: `全量重算库存+批次成本：${batch.length} 个商品+单位、${purchaseRows.results.length} 个进货批次、${saleRows.results.length} 个出货行、${lossRows.results.length} 条损耗`,
  });
  return c.json({ ok: true, rebuilt: batch.length });
});

// PATCH /stocks/:id — 调整预警阈值（库存=流水自动计算，quantity 不再写入）
stocksRouter.patch('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { min_stock?: number } | null;
  const cur = await c.env.DB.prepare('SELECT id, min_stock FROM stocks WHERE id = ?').bind(id)
    .first<{ id: string; min_stock: number }>();
  if (!cur) return c.json({ error: '库存记录不存在' }, 404);
  const minStock = body?.min_stock !== undefined ? Number(body.min_stock) : cur.min_stock;
  if (!Number.isFinite(minStock) || minStock < 0) return c.json({ error: '预警阈值不能为负数' }, 400);
  await c.env.DB.prepare('UPDATE stocks SET min_stock = ? WHERE id = ?')
    .bind(Math.round(minStock * 100) / 100, id).run();
  return c.json({ ok: true });
});

// POST /stocks/loss — 报损（损耗）：从 FIFO 批次最早批扣减 remaining，金额=损量×批次进价（加权），
// 单独记 loss_records 流水（不计入出货毛利）；损耗超过当前库存（批次剩余不足）拒绝。
stocksRouter.post('/loss', adminOnly(), async (c) => {
  const body = await c.req.json().catch(() => null) as {
    item_id?: string; unit?: string; qty?: number; happened_at?: string; note?: string;
  } | null;
  const itemId = body?.item_id?.trim() ?? '';
  const unit = body?.unit?.trim() ?? '';
  const qty = Number(body?.qty);
  if (!itemId || !unit || !Number.isFinite(qty) || qty <= 0) {
    return c.json({ error: '请填写商品/单位/损耗数量（>0）' }, 400);
  }
  const happenedAt = body?.happened_at?.trim() || nowIso().slice(0, 10);
  const { amount, leftover, stmts } = await consumeLossStatements(c.env.DB, itemId, unit, qty);
  if (leftover > 0) {
    return c.json({ error: `损耗数量超过当前库存（还差 ${Math.round(leftover * 100) / 100}${unit}）` }, 400);
  }
  const lossId = randomId();
  const unitPrice = amount / qty;
  const batch: D1PreparedStatement[] = [
    ...stmts,
    c.env.DB.prepare(
      'INSERT INTO loss_records (id, item_id, unit, qty, price, amount, happened_at, note, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    ).bind(lossId, itemId, unit, qty, unitPrice, amount, happenedAt, body?.note?.trim() ?? '', c.get('user').id),
  ];
  await c.env.DB.batch(batch);
  await recordChange(c.env.DB, { entity_type: 'loss_record', entity_sync_id: lossId, payload: {
    id: lossId, item_id: itemId, unit, qty, price: unitPrice, amount, happened_at: happenedAt, note: body?.note?.trim() ?? '',
  }, updated_by_username: c.get('user').username });
  await recordAudit(c.env.DB, {
    username: c.get('user').username, action: 'loss', entity_type: 'stocks',
    detail: `报损：${itemId} ${unit} ${qty}，金额 ¥${Math.round(amount * 100) / 100}${body?.note?.trim() ? `（${body.note.trim()}）` : ''}`,
  });
  return c.json({ id: lossId, item_id: itemId, unit, qty, price: unitPrice, amount, happened_at: happenedAt }, 201);
});

// GET /stocks/loss?date_from=&date_to=&q= — 损耗流水列表（含商品名）+ 区间汇总金额
stocksRouter.get('/loss', async (c) => {
  const canSeeCost = c.get('user').role === 'admin';
  const dateFrom = c.req.query('date_from')?.trim();
  const dateTo = c.req.query('date_to')?.trim();
  const q = c.req.query('q')?.trim() ?? '';
  let where = ' WHERE 1=1';
  const params: string[] = [];
  if (dateFrom) { where += ' AND lr.happened_at >= ?'; params.push(dateFrom); }
  if (dateTo) { where += ' AND lr.happened_at <= ?'; params.push(dateTo); }
  if (q) { where += ' AND i.name LIKE ?'; params.push(`%${q}%`); }
  const rows = await c.env.DB.prepare(
    `SELECT lr.id, lr.item_id, lr.unit, lr.qty, lr.price, lr.amount, lr.happened_at, lr.note, lr.created_at, i.name AS item_name
     FROM loss_records lr JOIN items i ON i.id = lr.item_id${where}
     ORDER BY lr.happened_at DESC, lr.created_at DESC`,
  ).bind(...params).all<{ id: string; item_id: string; unit: string; qty: number; price: number; amount: number; happened_at: string; note: string | null; created_at: string; item_name: string }>();
  const sum = await c.env.DB.prepare(
    `SELECT COALESCE(SUM(lr.amount), 0) AS amount, COALESCE(SUM(lr.qty), 0) AS qty FROM loss_records lr JOIN items i ON i.id = lr.item_id${where}`,
  ).bind(...params).first<{ amount: number; qty: number }>();
  return c.json({
    rows: rows.results.map((r) => ({
      id: r.id, item_id: r.item_id, item_name: r.item_name, unit: r.unit,
      qty: Math.round(r.qty * 100) / 100,
      amount: Math.round(r.amount * 100) / 100,
      price: Math.round(r.price * 100) / 100,
      happened_at: r.happened_at, note: r.note ?? '',
      // 店员不可见成本：金额/单价打码（损耗金额是老板看的成本信息）
      cost_visible: canSeeCost,
    })),
    total_amount: canSeeCost ? Math.round((sum?.amount ?? 0) * 100) / 100 : 0,
    total_qty: Math.round((sum?.qty ?? 0) * 100) / 100,
  });
});