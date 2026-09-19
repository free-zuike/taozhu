/** 库存：按 商品+单位 查看/盘点/设预警阈值。
 *  日常变动由 进货(+) / 出货(−) 单据在事务内自动增减（见 sales/purchases）。 */
import { Hono } from 'hono';
import { adminOnly, authMiddleware } from '../middleware/auth';
import { stockUpsert } from '../lib/stock';
import { recordAudit } from './audit';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const stocksRouter = new Hono<{ Bindings: Env; Variables: V }>();
stocksRouter.use('*', authMiddleware());

// GET /stocks?q=&below=1 — 库存列表（含商品名；below=1 仅低于阈值）
stocksRouter.get('/', async (c) => {
  const canSeeCost = c.get('user').role === 'admin';
  const q = c.req.query('q')?.trim() ?? '';
  const belowOnly = c.req.query('below') === '1';
  let sql = `SELECT st.id, st.item_id, st.unit, st.quantity, st.min_stock, i.name AS item_name,
      (SELECT p.purchase_price FROM item_prices p WHERE p.item_id = st.item_id AND p.unit = st.unit AND p.active = 1 LIMIT 1) AS cost_price
    FROM stocks st JOIN items i ON i.id = st.item_id
    WHERE i.deleted_at IS NULL`;
  const params: string[] = [];
  if (q) { sql += ' AND i.name LIKE ?'; params.push(`%${q}%`); }
  if (belowOnly) { sql += ' AND st.quantity < st.min_stock'; }
  sql += ' ORDER BY i.name, st.unit';
  const rows = await c.env.DB.prepare(sql).bind(...params).all<{
    id: string; item_id: string; unit: string; quantity: number; min_stock: number; item_name: string; cost_price: number | null;
  }>();
  // 建议预警阈值 = 近 30 天平均每笔出货量 × 40%（无出货记录则 0）。
  // 前端仅"阈值未手动设置（min_stock=0）且库存 ≥1"时自动填充，不覆盖用户手设值。
  const keys = rows.results.map((r) => `${r.item_id}\u0000${r.unit}`);
  let suggest = new Map<string, number>();
  if (keys.length > 0) {
    const ph = new Set(keys);
    const itemIds = [...ph].map((k) => k.split('\u0000')[0]);
    const units = [...ph].map((k) => k.split('\u0000')[1]);
    // 按 商品+单位 近 30 天出货行均值（避免跨单位混算；商品行自带日期，不再 JOIN 单据头）
    const avgRows = await c.env.DB.prepare(
      `SELECT si.item_id, si.unit, AVG(si.quantity) AS avg_qty
       FROM sale_items si
       WHERE si.happened_at >= date('now','-30 day')
         AND si.item_id IN (${itemIds.map(() => '?').join(',')})
       GROUP BY si.item_id, si.unit`,
    ).bind(...itemIds).all<{ item_id: string; unit: string; avg_qty: number }>();
    suggest = new Map(avgRows.results.map((r) => [
      `${r.item_id}\u0000${r.unit}`,
      Math.round((Number(r.avg_qty) || 0) * 0.4 * 100) / 100,
    ]));
  }
  return c.json({
    stocks: rows.results.map((r) => ({
      id: r.id, item_id: r.item_id, item_name: r.item_name, unit: r.unit,
      // 负数库存（卖出多于进）按 0 展示：没有就是 0
      quantity: Math.max(Number(r.quantity) || 0, 0), min_stock: r.min_stock,
      suggest_min: suggest.get(`${r.item_id}\u0000${r.unit}`) ?? 0,
      cost_price: canSeeCost ? (r.cost_price ?? 0) : 0,
      low: (Number(r.quantity) || 0) < r.min_stock,
    })),
    can_see_cost: canSeeCost,
  });
});

// PUT /stocks — 盘点/批量设置（body: {rows:[{item_id, unit, quantity, min_stock?}]}）
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
    const quantity = Number(r.quantity);
    const minStock = Number(r.min_stock) || 0;
    if (!Number.isFinite(quantity) || quantity < 0) return null;
    return stockUpsert(c.env.DB, itemId, unit, Math.round(quantity * 100) / 100, minStock);
  }).filter((s): s is NonNullable<typeof s> => s !== null);
  if (batch.length === 0) return c.json({ error: '盘点数据不合法（需 item_id/unit/数量≥0）' }, 400);
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

// PATCH /stocks/:id — 调整单行库存/阈值
stocksRouter.patch('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { quantity?: number; min_stock?: number } | null;
  const cur = await c.env.DB.prepare('SELECT * FROM stocks WHERE id = ?').bind(id)
    .first<{ quantity: number; min_stock: number }>();
  if (!cur) return c.json({ error: '库存记录不存在' }, 404);
  const quantity = body?.quantity !== undefined ? Number(body.quantity) : cur.quantity;
  if (!Number.isFinite(quantity) || quantity < 0) return c.json({ error: '库存数量不能为负数' }, 400);
  const minStock = body?.min_stock !== undefined ? Number(body.min_stock) : cur.min_stock;
  if (!Number.isFinite(minStock) || minStock < 0) return c.json({ error: '预警阈值不能为负数' }, 400);
  await c.env.DB.prepare('UPDATE stocks SET quantity = ?, min_stock = ? WHERE id = ?')
    .bind(Math.round(quantity * 100) / 100, Math.round(minStock * 100) / 100, id).run();
  return c.json({ ok: true });
});