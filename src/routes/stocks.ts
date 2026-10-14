/** 库存：按 商品+单位 查看/盘点/设预警阈值。
 *  日常变动由 进货(+) / 出货(−) 单据在事务内自动增减（见 sales/purchases）。 */
import { Hono } from 'hono';
import { adminOnly, authMiddleware } from '../middleware/auth';
import { stockUpsert, stockUpsertMin } from '../lib/stock';
import { chunkQuery } from '../lib/query';
import { recordAudit } from './audit';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const stocksRouter = new Hono<{ Bindings: Env; Variables: V }>();
stocksRouter.use('*', authMiddleware());

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
     ) GROUP BY item_id, unit`,
  ).all<{ item_id: string; unit: string; quantity: number }>();
  const itemIds = [...new Set(agg.results.map((r) => r.item_id))];
  const [itemRows, stockRows, priceRows] = await Promise.all([
    itemIds.length
      ? chunkQuery(itemIds, (chunk) =>
          c.env.DB.prepare(
            `SELECT id, name, count_unit FROM items WHERE id IN (${chunk.map(() => '?').join(',')}) AND deleted_at IS NULL`,
          ).bind(...chunk).all<{ id: string; name: string; count_unit: string | null }>().then((r) => r.results))
      : Promise.resolve([] as Array<{ id: string; name: string; count_unit: string | null }>),
    c.env.DB.prepare('SELECT item_id, unit, id, min_stock FROM stocks').all<{ item_id: string; unit: string; id: string; min_stock: number }>(),
    c.env.DB.prepare('SELECT item_id, unit, purchase_price FROM item_prices WHERE active = 1').all<{ item_id: string; unit: string; purchase_price: number }>(),
  ]);
  const itemName = new Map(itemRows.map((x) => [x.id, x.name]));
  const itemCountUnit = new Map(itemRows.map((x) => [x.id, x.count_unit ?? '']));
  const stockCfg = new Map(stockRows.results.map((x) => [`${x.item_id}\u0000${x.unit}`, x]));
  const costMap = new Map(priceRows.results.map((x) => [`${x.item_id}\u0000${x.unit}`, Number(x.purchase_price) || 0]));
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
      cost_price: canSeeCost ? (costMap.get(`${r.item_id}\u0000${r.unit}`) ?? 0) : 0,
      low: (Number(r.quantity) || 0) <= (Number(r.min_stock) || 0),
    })),
    can_see_cost: canSeeCost,
  });
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
     ) GROUP BY item_id, unit`,
  ).all<{ item_id: string; unit: string; quantity: number }>();
  const batch = rows.results.map((r) => {
    const min = minMap.get(`${r.item_id}\u0000${r.unit}`) ?? 0;
    return stockUpsert(c.env.DB, r.item_id, r.unit, Math.round(Number(r.quantity) * 100) / 100, min);
  });
  await c.env.DB.batch(batch);
  await recordAudit(c.env.DB, {
    username: c.get('user').username, action: 'rebuild', entity_type: 'stocks',
    detail: `全量重算库存：${batch.length} 个商品+单位`,
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