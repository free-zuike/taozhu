/** 进货单：purchases + purchase_items（记成本） */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { adminOnly, authMiddleware } from '../middleware/auth';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const purchasesRouter = new Hono<{ Bindings: Env; Variables: V }>();

purchasesRouter.use('*', authMiddleware());

const nowIso = () => new Date().toISOString();

interface PurchaseItemInput {
  price_id: string;
  quantity: number;
  purchase_price?: number;   // 可覆盖默认进价
}

// POST /purchases
purchasesRouter.post('/', async (c) => {
  const user = c.get('user');
  const body = await c.req.json().catch(() => null) as {
    happened_at?: string;
    note?: string;
    items?: PurchaseItemInput[];
  } | null;
  const items = body?.items ?? [];
  if (!Array.isArray(items) || items.length === 0) return c.json({ error: '请至少添加一种商品' }, 400);

  const priceIds = items.map((i) => i.price_id);
  if (priceIds.some((p) => !p)) return c.json({ error: '商品缺单位价格' }, 400);
  const placeholders = priceIds.map(() => '?').join(',');
  const priceRows = await c.env.DB.prepare(
    `SELECT id, item_id, unit, purchase_price FROM item_prices WHERE id IN (${placeholders})`,
  ).bind(...priceIds).all<{ id: string; item_id: string; unit: string; purchase_price: number }>();

  const priceMap = new Map(priceRows.results.map((p) => [p.id, p]));
  const purchaseId = randomId();
  const happenedAt = body?.happened_at?.trim() || nowIso().slice(0, 10);
  const note = body?.note?.trim() ?? '';
  let total = 0;

  const batch = [
    c.env.DB.prepare('INSERT INTO purchases (id, happened_at, note, created_by) VALUES (?, ?, ?, ?)')
      .bind(purchaseId, happenedAt, note, user.id),
  ];

  for (const item of items) {
    const price = priceMap.get(item.price_id);
    if (!price) return c.json({ error: `价格不存在: ${item.price_id}` }, 400);
    const qty = Number(item.quantity);
    if (!Number.isFinite(qty) || qty <= 0) return c.json({ error: '数量必须大于 0' }, 400);
    const priceIn = Number(item.purchase_price);
    const effective = Number.isFinite(priceIn) && priceIn > 0 ? priceIn : price.purchase_price;
    const amount = Math.round(qty * effective * 100) / 100;
    total += amount;
    batch.push(
      c.env.DB.prepare(
        'INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount) VALUES (?, ?, ?, ?, ?, ?, ?)',
      ).bind(randomId(), purchaseId, price.item_id, price.unit, qty, effective, amount),
    );
  }

  await c.env.DB.batch(batch);
  return c.json({ id: purchaseId, happened_at: happenedAt, note, total: Math.round(total * 100) / 100, items: items.length }, 201);
});

// GET /purchases?date_from=&date_to=
purchasesRouter.get('/', async (c) => {
  const dateFrom = c.req.query('date_from')?.trim();
  const dateTo = c.req.query('date_to')?.trim();
  let sql = `SELECT p.*, (SELECT COALESCE(SUM(pi.amount),0) FROM purchase_items pi WHERE pi.purchase_id = p.id) AS total
    FROM purchases p WHERE 1=1`;
  const params: string[] = [];
  if (dateFrom) { sql += ' AND p.happened_at >= ?'; params.push(dateFrom); }
  if (dateTo) { sql += ' AND p.happened_at <= ?'; params.push(dateTo); }
  sql += ' ORDER BY p.happened_at DESC, p.created_at DESC';
  const rows = await c.env.DB.prepare(sql).bind(...params).all();
  if (rows.results.length === 0) return c.json({ purchases: [] });

  const ids = rows.results.map((r) => (r as { id: string }).id);
  const ph = ids.map(() => '?').join(',');
  const detail = await c.env.DB.prepare(
    `SELECT pi.*, i.name AS item_name FROM purchase_items pi JOIN items i ON i.id = pi.item_id WHERE pi.purchase_id IN (${ph}) ORDER BY pi.created_at`,
  ).bind(...ids).all();
  const byId = new Map<string, unknown[]>();
  for (const d of detail.results) {
    const pid = (d as { purchase_id: string }).purchase_id;
    const list = byId.get(pid) ?? [];
    list.push(d);
    byId.set(pid, list);
  }
  return c.json({
    purchases: rows.results.map((r) => {
      const row = r as unknown as { id: string; happened_at: string; note: string; total: number };
      return { id: row.id, happened_at: row.happened_at, note: row.note ?? '', total: row.total, items: byId.get(row.id) ?? [] };
    }),
  });
});

// GET /purchases/:id
purchasesRouter.get('/:id', async (c) => {
  const id = c.req.param('id');
  const row = await c.env.DB.prepare(
    `SELECT p.*, (SELECT COALESCE(SUM(pi.amount),0) FROM purchase_items pi WHERE pi.purchase_id = p.id) AS total FROM purchases p WHERE p.id = ?`,
  ).bind(id).first();
  if (!row) return c.json({ error: '进货单不存在' }, 404);
  const detail = await c.env.DB.prepare(
    `SELECT pi.*, i.name AS item_name FROM purchase_items pi JOIN items i ON i.id = pi.item_id WHERE pi.purchase_id = ?`,
  ).bind(id).all();
  return c.json({ ...(row as object), items: detail.results });
});

// DELETE /purchases/:id — 删除进货单（级联删明细，仅老板）
purchasesRouter.delete('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  await c.env.DB.prepare('DELETE FROM purchases WHERE id = ?').bind(id).run();
  return c.body(null, 204);
});