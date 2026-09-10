/** 库存：按 商品+单位 查看/盘点/设预警阈值。
 *  日常变动由 进货(+) / 出货(−) 单据在事务内自动增减（见 sales/purchases）。 */
import { Hono } from 'hono';
import { adminOnly, authMiddleware } from '../middleware/auth';
import { stockUpsert } from '../lib/stock';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const stocksRouter = new Hono<{ Bindings: Env; Variables: V }>();
stocksRouter.use('*', authMiddleware());

// GET /stocks?q=&below=1 — 库存列表（含商品名；below=1 仅低于阈值）
stocksRouter.get('/', async (c) => {
  const q = c.req.query('q')?.trim() ?? '';
  const belowOnly = c.req.query('below') === '1';
  let sql = `SELECT st.id, st.item_id, st.unit, st.quantity, st.min_stock, i.name AS item_name
    FROM stocks st JOIN items i ON i.id = st.item_id
    WHERE i.deleted_at IS NULL`;
  const params: string[] = [];
  if (q) { sql += ' AND i.name LIKE ?'; params.push(`%${q}%`); }
  if (belowOnly) { sql += ' AND st.quantity < st.min_stock'; }
  sql += ' ORDER BY i.name, st.unit';
  const rows = await c.env.DB.prepare(sql).bind(...params).all<{
    id: string; item_id: string; unit: string; quantity: number; min_stock: number; item_name: string;
  }>();
  return c.json({
    stocks: rows.results.map((r) => ({
      id: r.id, item_id: r.item_id, item_name: r.item_name, unit: r.unit,
      quantity: r.quantity, min_stock: r.min_stock,
      low: r.quantity < r.min_stock,
    })),
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