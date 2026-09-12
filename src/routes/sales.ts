/** 出货单（送店铺记账）：sales + sale_items，进价快照计毛利 */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { adminOnly, authMiddleware } from '../middleware/auth';
import { parsePage } from '../lib/paging';
import { stockDelta } from '../lib/stock';
import { buildPayload, recordChange } from '../lib/sync';
import { deleteEntityAttachments } from '../lib/image-key';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const salesRouter = new Hono<{ Bindings: Env; Variables: V }>();

salesRouter.use('*', authMiddleware());

const nowIso = () => new Date().toISOString();

interface SaleItemInput {
  price_id: string;          // item_prices.id
  quantity: number;
  sale_price?: number;       // 可覆盖默认出价
  happened_at?: string;      // 行独立日期（缺省用单据日期）
}

// POST /sales — 记一张出货单（原子事务）
salesRouter.post('/', async (c) => {
  const user = c.get('user');
  const body = await c.req.json().catch(() => null) as {
    client_id?: string;
    happened_at?: string;
    note?: string;
    sync_key?: string; // 客户端幂等键（离线重放/多端提交不重复建单）
    items?: SaleItemInput[];
  } | null;
  const clientId = body?.client_id;
  const items = body?.items ?? [];
  const syncKey = body?.sync_key?.trim() || '';
  if (!clientId) return c.json({ error: '请选择店铺' }, 400);
  if (!Array.isArray(items) || items.length === 0) return c.json({ error: '请至少添加一种商品' }, 400);

  // 幂等：同一 sync_key 已存在（如离线重放重复投递）→ 直接返回已有单据，不重复建单/不重复扣库存
  if (syncKey) {
    const existed = await c.env.DB.prepare('SELECT id FROM sales WHERE sync_key = ?').bind(syncKey).first<{ id: string }>();
    if (existed) {
      return c.json({ id: existed.id, client_id: clientId, dup: true, total: 0, items: 0 });
    }
  }

  const client = await c.env.DB.prepare('SELECT id FROM clients WHERE id = ? AND deleted_at IS NULL').bind(clientId).first();
  if (!client) return c.json({ error: '店铺不存在' }, 404);

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
    c.env.DB.prepare('INSERT INTO sales (id, client_id, happened_at, note, created_by, sync_key) VALUES (?, ?, ?, ?, ?, ?)')
      .bind(saleId, clientId, happenedAt, note, user.id, syncKey || null),
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
        'INSERT INTO sale_items (id, sale_id, item_id, unit, quantity, sale_price, cost_price, amount, happened_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ).bind(siId, saleId, price.item_id, price.unit, qty, effectiveSale, price.purchase_price, amount,
        item.happened_at?.trim() || happenedAt),
    );
    // 出货扣减库存
    batch.push(stockDelta(c.env.DB, price.item_id, price.unit, -qty));
  }

  await c.env.DB.batch(batch);
  await recordChange(c.env.DB, { entity_type: 'sale', entity_sync_id: saleId, payload: await buildPayload(c.env.DB, 'sale', saleId), updated_by_username: user.username });
  return c.json({ id: saleId, client_id: clientId, happened_at: happenedAt, note, total: Math.round(total * 100) / 100, items: saleItemIds.length }, 201);
});

// GET /sales?client_id=&date_from=&date_to=&limit=&offset= — 出货单列表（含明细与总额，分页）
salesRouter.get('/', async (c) => {
  const user = c.get('user');
  const clientId = c.req.query('client_id')?.trim();
  const dateFrom = c.req.query('date_from')?.trim();
  const dateTo = c.req.query('date_to')?.trim();
  const { limit, offset } = parsePage(c.req.query('limit'), c.req.query('offset'));

  let where = ' WHERE 1=1';
  const params: string[] = [];
  // 店员权限：仅可见当天送货记录（送货对单场景），强制锁定当天，忽略传入日期
  if (user.role === 'staff') {
    const today = new Date().toISOString().slice(0, 10);
    where += ' AND s.happened_at >= ? AND s.happened_at <= ?';
    params.push(today, today);
  } else {
    if (clientId) { where += ' AND s.client_id = ?'; params.push(clientId); }
    if (dateFrom) { where += ' AND s.happened_at >= ?'; params.push(dateFrom); }
    if (dateTo) { where += ' AND s.happened_at <= ?'; params.push(dateTo); }
  }

  const countRow = await c.env.DB.prepare(
    `SELECT COUNT(*) AS cnt FROM sales s ${where}`).bind(...params).first<{ cnt: number }>();

  const rows = await c.env.DB.prepare(
    `SELECT s.*, c.name AS client_name,
      (SELECT COALESCE(SUM(si.amount),0) FROM sale_items si WHERE si.sale_id = s.id) AS total
     FROM sales s JOIN clients c ON c.id = s.client_id ${where}
     ORDER BY s.happened_at DESC, s.created_at DESC LIMIT ? OFFSET ?`,
  ).bind(...params, limit, offset).all();
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
    total: countRow?.cnt ?? 0,
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

// POST /sales/items/date — 批量改明细行日期（出货流水「日期栏批量编辑」用；不改库存/金额/店铺）
salesRouter.post('/items/date', async (c) => {
  const body = await c.req.json().catch(() => null) as { updates?: Array<{ item_id?: string; happened_at?: string }> } | null;
  const updates = (body?.updates ?? []).filter((u) => u && u.item_id && u.happened_at).slice(0, 500);
  if (updates.length === 0) return c.json({ error: '请提供明细行 id 与目标日期' }, 400);
  for (const u of updates) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(u.happened_at!)) return c.json({ error: '日期格式应为 YYYY-MM-DD' }, 400);
  }
  const ids = updates.map((u) => u.item_id!);
  const rows = await c.env.DB.prepare(
    `SELECT id, sale_id FROM sale_items WHERE id IN (${ids.map(() => '?').join(',')})`,
  ).bind(...ids).all<{ id: string; sale_id: string }>();
  if (rows.results.length === 0) return c.json({ error: '明细行不存在' }, 404);
  const byId = new Map(rows.results.map((r) => [r.id, r.sale_id]));
  const batch: D1PreparedStatement[] = [];
  for (const u of updates) {
    const saleId = byId.get(u.item_id!);
    if (saleId) batch.push(c.env.DB.prepare('UPDATE sale_items SET happened_at = ? WHERE id = ?').bind(u.happened_at, u.item_id));
  }
  await c.env.DB.batch(batch);
  // 单据日期自动取明细最大日期（与记单页 orderDate=最大行日期口径一致）
  const saleIds = [...new Set(rows.results.map((r) => r.sale_id))];
  const dateBatch: D1PreparedStatement[] = saleIds.map((sid) =>
    c.env.DB.prepare(
      `UPDATE sales SET happened_at = (
         SELECT MAX(COALESCE(happened_at, '')) FROM sale_items WHERE sale_id = ?
       ) WHERE id = ? AND EXISTS (SELECT 1 FROM sale_items WHERE sale_id = ?)`,
    ).bind(sid, sid, sid));
  await c.env.DB.batch(dateBatch);
  for (const sid of saleIds) {
    await recordChange(c.env.DB, { entity_type: 'sale', entity_sync_id: sid, payload: await buildPayload(c.env.DB, 'sale', sid), updated_by_username: c.get('user').username });
  }
  return c.json({ updated: batch.length });
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

// PATCH /sales/:id — 编辑出货单（改店铺/日期/备注；传 items 则整体替换明细，原子事务）
salesRouter.patch('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as {
    client_id?: string; happened_at?: string; note?: string; items?: SaleItemInput[];
  } | null;
  const sale = await c.env.DB.prepare('SELECT * FROM sales WHERE id = ?').bind(id)
    .first<{ client_id: string; happened_at: string; note: string }>();
  if (!sale) return c.json({ error: '出货单不存在' }, 404);

  const clientId = body?.client_id ?? sale.client_id;
  const client = await c.env.DB.prepare('SELECT id FROM clients WHERE id = ? AND deleted_at IS NULL').bind(clientId).first();
  if (!client) return c.json({ error: '店铺不存在' }, 404);
  const happenedAt = body?.happened_at?.trim() || sale.happened_at;
  const note = body?.note?.trim() ?? sale.note ?? '';

  const batch: D1PreparedStatement[] = [
    c.env.DB.prepare('UPDATE sales SET client_id = ?, happened_at = ?, note = ? WHERE id = ?')
      .bind(clientId, happenedAt, note, id),
  ];
  let total: number;
  if (body?.items !== undefined) {
    const items = body.items;
    if (!Array.isArray(items) || items.length === 0) return c.json({ error: '请至少添加一种商品' }, 400);
    // 编辑替换明细：先回滚原明细的库存（出货扣减恢复），再按新明细扣减
    const oldItems = await c.env.DB.prepare(
      'SELECT item_id, unit, quantity FROM sale_items WHERE sale_id = ?').bind(id)
      .all<{ item_id: string; unit: string; quantity: number }>();
    for (const it of oldItems.results) {
      batch.push(stockDelta(c.env.DB, it.item_id, it.unit, it.quantity));
    }
    const priceIds = items.map((i) => i.price_id);
    if (priceIds.some((p) => !p)) return c.json({ error: '商品缺单位价格' }, 400);
    const placeholders = priceIds.map(() => '?').join(',');
    const priceRows = await c.env.DB.prepare(
      `SELECT id, item_id, unit, purchase_price, sale_price, active FROM item_prices WHERE id IN (${placeholders})`,
    ).bind(...priceIds).all<{ id: string; item_id: string; unit: string; purchase_price: number; sale_price: number; active: number }>();
    const priceMap = new Map(priceRows.results.map((p) => [p.id, p]));
    total = 0;
    for (const item of items) {
      const price = priceMap.get(item.price_id);
      if (!price || !price.active) return c.json({ error: `价格不存在或已停用: ${item.price_id}` }, 400);
      const qty = Number(item.quantity);
      if (!Number.isFinite(qty) || qty <= 0) return c.json({ error: '数量必须大于 0' }, 400);
      const salePrice = Number(item.sale_price);
      const effectiveSale = Number.isFinite(salePrice) && salePrice > 0 ? salePrice : price.sale_price;
      total += Math.round(qty * effectiveSale * 100) / 100;
    }
    batch.push(c.env.DB.prepare('DELETE FROM sale_items WHERE sale_id = ?').bind(id));
    for (const item of items) {
      const price = priceMap.get(item.price_id);
      if (!price || !price.active) continue;
      const qty = Number(item.quantity);
      const salePrice = Number(item.sale_price);
      const effectiveSale = Number.isFinite(salePrice) && salePrice > 0 ? salePrice : price.sale_price;
      const amount = Math.round(qty * effectiveSale * 100) / 100;
      batch.push(
        c.env.DB.prepare(
          'INSERT INTO sale_items (id, sale_id, item_id, unit, quantity, sale_price, cost_price, amount, happened_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        ).bind(randomId(), id, price.item_id, price.unit, qty, effectiveSale, price.purchase_price, amount,
          item.happened_at?.trim() || happenedAt),
      );
      // 按新明细扣减库存
      batch.push(stockDelta(c.env.DB, price.item_id, price.unit, -qty));
    }
  } else {
    const tot = await c.env.DB.prepare('SELECT COALESCE(SUM(amount),0) AS total FROM sale_items WHERE sale_id = ?').bind(id).first<{ total: number }>();
    total = tot?.total ?? 0;
  }
  await c.env.DB.batch(batch);
  await recordChange(c.env.DB, { entity_type: 'sale', entity_sync_id: id, payload: await buildPayload(c.env.DB, 'sale', id), updated_by_username: c.get('user').username });
  return c.json({ id, client_id: clientId, happened_at: happenedAt, note, total: Math.round(total * 100) / 100 });
});

// DELETE /sales/items/:id — 删除单条出货明细行（出货流水行级删除；回滚该行库存，重算单据日期）
salesRouter.delete('/items/:id', async (c) => {
  const id = c.req.param('id');
  const row = await c.env.DB.prepare(
    'SELECT id, sale_id, item_id, unit, quantity FROM sale_items WHERE id = ?',
  ).bind(id).first<{ id: string; sale_id: string; item_id: string; unit: string; quantity: number }>();
  if (!row) return c.json({ error: '明细行不存在' }, 404);
  const saleId = row.sale_id;
  const batch: D1PreparedStatement[] = [
    stockDelta(c.env.DB, row.item_id, row.unit, row.quantity), // 出货扣减恢复
    c.env.DB.prepare('DELETE FROM sale_items WHERE id = ?').bind(id),
  ];
  await c.env.DB.batch(batch);
  // 单据日期自动取剩余明细最大日期（空明细则保持原样）
  await c.env.DB.prepare(
    `UPDATE sales SET happened_at = (
       SELECT MAX(COALESCE(happened_at, '')) FROM sale_items WHERE sale_id = ?
     ) WHERE id = ? AND EXISTS (SELECT 1 FROM sale_items WHERE sale_id = ?)`,
  ).bind(saleId, saleId, saleId).run();
  await recordChange(c.env.DB, { entity_type: 'sale', entity_sync_id: saleId, payload: await buildPayload(c.env.DB, 'sale', saleId), updated_by_username: c.get('user').username });
  return c.json({ ok: true });
});

// DELETE /sales/:id — 删除出货单（回滚库存 + 级联删明细，仅老板）
salesRouter.delete('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const oldItems = await c.env.DB.prepare(
    'SELECT item_id, unit, quantity FROM sale_items WHERE sale_id = ?').bind(id)
    .all<{ item_id: string; unit: string; quantity: number }>();
  const batch: D1PreparedStatement[] = oldItems.results
    .map((it) => stockDelta(c.env.DB, it.item_id, it.unit, it.quantity)); // 出货扣的加回
  batch.push(c.env.DB.prepare('DELETE FROM sales WHERE id = ?').bind(id));
  await c.env.DB.batch(batch);
  await recordChange(c.env.DB, { entity_type: 'sale', entity_sync_id: id, action: 'delete', payload: {}, updated_by_username: c.get('user').username });
  // 删除交易附带的凭证图片（孤儿文件清理，best-effort 不阻塞删除）
  try {
    await deleteEntityAttachments(c.env, 'sale', id);
  } catch (_) {}
  return c.body(null, 204);
});