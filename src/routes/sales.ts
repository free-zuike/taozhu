/** 出货单（送饭店记账）：sales + sale_items，进价快照计毛利 */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { authMiddleware } from '../middleware/auth';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const salesRouter = new Hono<{ Bindings: Env; Variables: V }>();

salesRouter.use('*', authMiddleware());

const nowIso = () => new Date().toISOString();

interface SaleItemInput {
  price_id: string;          // item_prices.id
  quantity: number;
  sale_price?: number;       // 可覆盖默认出价
}

// POST /sales — 记一张出货单（原子事务）
salesRouter.post('/', async (c) => {
  const user = c.get('user');
  const body = await c.req.json().catch(() => null) as {
    client_id?: string;
    happened_at?: string;
    note?: string;
    items?: SaleItemInput[];
  } | null;
  const clientId = body?.client_id;
  const items = body?.items ?? [];
  if (!clientId) return c.json({ error: '请选择饭店' }, 400);
  if (!Array.isArray(items) || items.length === 0) return c.json({ error: '请至少添加一种商品' }, 400);

  const client = await c.env.DB.prepare('SELECT id FROM clients WHERE id = ? AND deleted_at IS NULL').bind(clientId).first();
  if (!client) return c.json({ error: '饭店不存在' }, 404);

  // 校验商品价格并取进价快照
  const priceIds = items.map((i) => i.price_id);
  if (priceIds.some((p) => !p)) return c.json({ error: '商品缺单位价格' }, 400);
  const placeholders = priceIds.map(() => '?').join(',');
  const priceRows = await c.env.DB.prepare(
    `SELECT id, item_id, unit, purchase_price, sale_price, active FROM item_prices WHERE id IN (${placeholders})`,
  ).bind(...priceIds).all<{ id: string; item_id: string; unit: string; purchase_price: number; sale_price: number; active: number }>();

  const priceMap = new Map(priceRows.results.map((p) => [p.id, p]));
  const saleId = randomId();
  const happenedAt = body?.happened_at?.trim() || nowIso().slice(0, 10);
  const note = body?.note?.trim() ?? '';
  const saleItemIds: string[] = [];
  let total = 0;

  const batch = [
    c.env.DB.prepare('INSERT INTO sales (id, client_id, happened_at, note, created_by) VALUES (?, ?, ?, ?, ?)')
      .bind(saleId, clientId, happenedAt, note, user.id),
  ];

  for (const item of items) {
    const price = priceMap.get(item.price_id);
    if (!price || !price.active) {
      return c.json({ error: `价格不存在或已停用: ${item.price_id}` }, 400);
    }
    const qty = Number(item.quantity);
    if (!Number.isFinite(qty) || qty <= 0) return c.json({ error: '数量必须大于 0' }, 400);
    const salePrice = Number(item.sale_price);
    const effectiveSale = Number.isFinite(salePrice) && salePrice > 0 ? salePrice : price.sale_price;
    const amount = Math.round(qty * effectiveSale * 100) / 100;
    total += amount;
    const siId = randomId();
    saleItemIds.push(siId);
    batch.push(
      c.env.DB.prepare(
        'INSERT INTO sale_items (id, sale_id, item_id, unit, quantity, sale_price, cost_price, amount) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      ).bind(siId, saleId, price.item_id, price.unit, qty, effectiveSale, price.purchase_price, amount),
    );
  }

  await c.env.DB.batch(batch);
  return c.json({ id: saleId, client_id: clientId, happened_at: happenedAt, note, total: Math.round(total * 100) / 100, items: saleItemIds.length }, 201);
});

// GET /sales?client_id=&date_from=&date_to= — 出货单列表（含明细与总额）
salesRouter.get('/', async (c) => {
  const clientId = c.req.query('client_id')?.trim();
  const dateFrom = c.req.query('date_from')?.trim();
  const dateTo = c.req.query('date_to')?.trim();

  let sql = `SELECT s.*, c.name AS client_name,
    (SELECT COALESCE(SUM(si.amount),0) FROM sale_items si WHERE si.sale_id = s.id) AS total
    FROM sales s JOIN clients c ON c.id = s.client_id WHERE 1=1`;
  const params: string[] = [];
  if (clientId) { sql += ' AND s.client_id = ?'; params.push(clientId); }
  if (dateFrom) { sql += ' AND s.happened_at >= ?'; params.push(dateFrom); }
  if (dateTo) { sql += ' AND s.happened_at <= ?'; params.push(dateTo); }
  sql += ' ORDER BY s.happened_at DESC, s.created_at DESC';

  const rows = await c.env.DB.prepare(sql).bind(...params).all();
  if (rows.results.length === 0) return c.json({ sales: [] });

  const saleIds = rows.results.map((r) => (r as { id: string }).id);
  const placeholders = saleIds.map(() => '?').join(',');
  const detailRows = await c.env.DB.prepare(
    `SELECT si.*, i.name AS item_name FROM sale_items si JOIN items i ON i.id = si.item_id
     WHERE si.sale_id IN (${placeholders}) ORDER BY si.created_at`,
  ).bind(...saleIds).all();

  const bySale = new Map<string, unknown[]>();
  for (const d of detailRows.results) {
    const saleId2 = (d as { sale_id: string }).sale_id;
    const list = bySale.get(saleId2) ?? [];
    list.push(d);
    bySale.set(saleId2, list);
  }
  return c.json({
    sales: rows.results.map((r) => {
      const row = r as unknown as { id: string; client_id: string; client_name: string; happened_at: string; note: string; total: number };
      return {
        id: row.id, client_id: row.client_id, client_name: row.client_name,
        happened_at: row.happened_at, note: row.note ?? '', total: row.total,
        items: bySale.get(row.id) ?? [],
      };
    }),
  });
});

// GET /sales/:id — 单张出货单详情
salesRouter.get('/:id', async (c) => {
  const id = c.req.param('id');
  const row = await c.env.DB.prepare(
    `SELECT s.*, c.name AS client_name, (SELECT COALESCE(SUM(si.amount),0) FROM sale_items si WHERE si.sale_id = s.id) AS total
     FROM sales s JOIN clients c ON c.id = s.client_id WHERE s.id = ?`).bind(id).first();
  if (!row) return c.json({ error: '出货单不存在' }, 404);
  const detail = await c.env.DB.prepare(
    `SELECT si.*, i.name AS item_name FROM sale_items si JOIN items i ON i.id = si.item_id WHERE si.sale_id = ?`).bind(id).all();
  return c.json({
    id: (row as { id: string }).id, client_id: (row as { client_id: string }).client_id,
    client_name: (row as { client_name: string }).client_name,
    happened_at: (row as { happened_at: string }).happened_at, note: (row as { note: string }).note ?? '',
    total: (row as { total: number }).total,
    items: detail.results,
  });
});

// DELETE /sales/:id — 删除出货单（级联删明细）
salesRouter.delete('/:id', async (c) => {
  const id = c.req.param('id');
  await c.env.DB.prepare('DELETE FROM sales WHERE id = ?').bind(id).run();
  return c.body(null, 204);
});