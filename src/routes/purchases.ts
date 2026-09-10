/** 进货单：purchases + purchase_items（记成本） */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { adminOnly, authMiddleware } from '../middleware/auth';
import { parsePage } from '../lib/paging';
import { stockDelta } from '../lib/stock';
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
    // 进货增加库存
    batch.push(stockDelta(c.env.DB, price.item_id, price.unit, qty));
  }

  await c.env.DB.batch(batch);
  return c.json({ id: purchaseId, happened_at: happenedAt, note, total: Math.round(total * 100) / 100, items: items.length }, 201);
});

// GET /purchases?date_from=&date_to=&limit=&offset=
purchasesRouter.get('/', async (c) => {
  const dateFrom = c.req.query('date_from')?.trim();
  const dateTo = c.req.query('date_to')?.trim();
  const { limit, offset } = parsePage(c.req.query('limit'), c.req.query('offset'));

  let where = ' WHERE 1=1';
  const params: string[] = [];
  if (dateFrom) { where += ' AND p.happened_at >= ?'; params.push(dateFrom); }
  if (dateTo) { where += ' AND p.happened_at <= ?'; params.push(dateTo); }

  const countRow = await c.env.DB.prepare(
    `SELECT COUNT(*) AS cnt FROM purchases p ${where}`).bind(...params).first<{ cnt: number }>();

  const rows = await c.env.DB.prepare(
    `SELECT p.*, (SELECT COALESCE(SUM(pi.amount),0) FROM purchase_items pi WHERE pi.purchase_id = p.id) AS total
    FROM purchases p ${where} ORDER BY p.happened_at DESC, p.created_at DESC LIMIT ? OFFSET ?`,
  ).bind(...params, limit, offset).all();
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
    total: countRow?.cnt ?? 0,
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

// PATCH /purchases/:id — 编辑进货单（改日期/备注；传 items 则整体替换明细，原子事务）
purchasesRouter.patch('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as {
    happened_at?: string; note?: string; items?: PurchaseItemInput[];
  } | null;
  const purchase = await c.env.DB.prepare('SELECT * FROM purchases WHERE id = ?').bind(id)
    .first<{ happened_at: string; note: string }>();
  if (!purchase) return c.json({ error: '进货单不存在' }, 404);

  const happenedAt = body?.happened_at?.trim() || purchase.happened_at;
  const note = body?.note?.trim() ?? purchase.note ?? '';

  const batch: D1PreparedStatement[] = [
    c.env.DB.prepare('UPDATE purchases SET happened_at = ?, note = ? WHERE id = ?')
      .bind(happenedAt, note, id),
  ];
  let total: number;
  if (body?.items !== undefined) {
    const items = body.items;
    if (!Array.isArray(items) || items.length === 0) return c.json({ error: '请至少添加一种商品' }, 400);
    // 编辑替换明细：先回滚原明细库存（进货加的减回），再按新明细增加
    const oldItems = await c.env.DB.prepare(
      'SELECT item_id, unit, quantity FROM purchase_items WHERE purchase_id = ?').bind(id)
      .all<{ item_id: string; unit: string; quantity: number }>();
    for (const it of oldItems.results) {
      batch.push(stockDelta(c.env.DB, it.item_id, it.unit, -it.quantity));
    }
    const priceIds = items.map((i) => i.price_id);
    if (priceIds.some((p) => !p)) return c.json({ error: '商品缺单位价格' }, 400);
    const placeholders = priceIds.map(() => '?').join(',');
    const priceRows = await c.env.DB.prepare(
      `SELECT id, item_id, unit, purchase_price FROM item_prices WHERE id IN (${placeholders})`,
    ).bind(...priceIds).all<{ id: string; item_id: string; unit: string; purchase_price: number }>();
    const priceMap = new Map(priceRows.results.map((p) => [p.id, p]));
    total = 0;
    for (const item of items) {
      const price = priceMap.get(item.price_id);
      if (!price) return c.json({ error: `价格不存在: ${item.price_id}` }, 400);
      const qty = Number(item.quantity);
      if (!Number.isFinite(qty) || qty <= 0) return c.json({ error: '数量必须大于 0' }, 400);
      const priceIn = Number(item.purchase_price);
      const effective = Number.isFinite(priceIn) && priceIn > 0 ? priceIn : price.purchase_price;
      total += Math.round(qty * effective * 100) / 100;
    }
    batch.push(c.env.DB.prepare('DELETE FROM purchase_items WHERE purchase_id = ?').bind(id));
    for (const item of items) {
      const price = priceMap.get(item.price_id);
      if (!price) continue;
      const qty = Number(item.quantity);
      const priceIn = Number(item.purchase_price);
      const effective = Number.isFinite(priceIn) && priceIn > 0 ? priceIn : price.purchase_price;
      const amount = Math.round(qty * effective * 100) / 100;
      batch.push(
        c.env.DB.prepare(
          'INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount) VALUES (?, ?, ?, ?, ?, ?, ?)',
        ).bind(randomId(), id, price.item_id, price.unit, qty, effective, amount),
      );
      // 按新明细增加库存
      batch.push(stockDelta(c.env.DB, price.item_id, price.unit, qty));
    }
  } else {
    const tot = await c.env.DB.prepare('SELECT COALESCE(SUM(amount),0) AS total FROM purchase_items WHERE purchase_id = ?').bind(id).first<{ total: number }>();
    total = tot?.total ?? 0;
  }
  await c.env.DB.batch(batch);
  return c.json({ id, happened_at: happenedAt, note, total: Math.round(total * 100) / 100 });
});

// DELETE /purchases/:id — 删除进货单（回滚库存 + 级联删明细，仅老板）
purchasesRouter.delete('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const oldItems = await c.env.DB.prepare(
    'SELECT item_id, unit, quantity FROM purchase_items WHERE purchase_id = ?').bind(id)
    .all<{ item_id: string; unit: string; quantity: number }>();
  const batch: D1PreparedStatement[] = oldItems.results
    .map((it) => stockDelta(c.env.DB, it.item_id, it.unit, -it.quantity)); // 进货加的减回
  batch.push(c.env.DB.prepare('DELETE FROM purchases WHERE id = ?').bind(id));
  await c.env.DB.batch(batch);
  return c.body(null, 204);
});