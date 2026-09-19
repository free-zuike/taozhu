/** 出货单（送店铺记账）：sales + sale_items，进价快照计毛利 */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { adminOnly, authMiddleware } from '../middleware/auth';
import { parsePage } from '../lib/paging';
import { stockDelta, stockDeltaFor } from '../lib/stock';
import { buildPayload, recordChange } from '../lib/sync';
import { deleteEntityAttachments } from '../lib/image-key';
import { recordAudit } from './audit';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const salesRouter = new Hono<{ Bindings: Env; Variables: V }>();

salesRouter.use('*', authMiddleware());

const nowIso = () => new Date().toISOString();

interface SaleItemInput {
  id?: string;               // 行 id（编辑/批量直编保留原行 id，缺省服务端生成）
  price_id: string;          // item_prices.id
  quantity: number;
  count_qty?: number;        // 本单折合计数数量（如卖 3 斤木瓜按个备货→填 2 个，库存按个扣；缺省=quantity 按原单位）
  sale_price?: number;       // 可覆盖默认售价
  happened_at?: string;      // 行独立日期（缺省用单据日期）
  note?: string;             // 行级备注（缺省空）
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
  // （去单据化后行即主记录：按行级 sync_key 查重，返回该批首行所在 sale_id）
  if (syncKey) {
    const existed = await c.env.DB.prepare('SELECT sale_id FROM sale_items WHERE sync_key = ?').bind(syncKey).first<{ sale_id: string }>();
    if (existed) {
      return c.json({ id: existed.sale_id, client_id: clientId, dup: true, total: 0, items: 0 });
    }
  }

  const client = await c.env.DB.prepare('SELECT id FROM clients WHERE id = ? AND deleted_at IS NULL').bind(clientId).first();
  if (!client) return c.json({ error: '店铺不存在' }, 404);

  // 校验商品价格并取进价快照
  const priceIds = items.map((i) => i.price_id);
  if (priceIds.some((p) => !p)) return c.json({ error: '商品缺单位价格' }, 400);
  const placeholders = priceIds.map(() => '?').join(',');
  const priceRows = await c.env.DB.prepare(
    `SELECT p.id, p.item_id, p.unit, p.purchase_price, p.sale_price, p.active, p.per, i.count_unit
     FROM item_prices p LEFT JOIN items i ON i.id = p.item_id WHERE p.id IN (${placeholders})`,
  ).bind(...priceIds).all<{ id: string; item_id: string; unit: string; purchase_price: number; sale_price: number; active: number; per?: number | null; count_unit?: string | null }>();

  const priceMap = new Map(priceRows.results.map((p) => [p.id, p]));
  const saleId = randomId();
  const happenedAt = body?.happened_at?.trim() || nowIso().slice(0, 10);
  const note = body?.note?.trim() ?? '';
  const saleItemIds: string[] = [];
  let total = 0;

  const batch = [
    // 去单据化：无 sales 头表（已物理删除），行即主记录，销售批次由 sale_id 关联
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
    // 折合计数数量：记单时显式填 > 价格行规格 per > 缺省 quantity（按原单位）
    const countQty = Number(item.count_qty);
    const per = Number(price.per ?? 0);
    const effCount = Number.isFinite(countQty) && countQty > 0 ? countQty : (per > 0 ? Math.round(qty * per * 100) / 100 : qty);
    batch.push(
      c.env.DB.prepare(
        'INSERT INTO sale_items (id, sale_id, client_id, item_id, unit, quantity, count_qty, sale_price, cost_price, amount, happened_at, note, created_by, sync_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ).bind(siId, saleId, clientId, price.item_id, price.unit, qty, effCount === qty ? null : effCount, effectiveSale, price.purchase_price, amount,
        item.happened_at?.trim() || happenedAt, item.note?.trim() ?? '', user.id, syncKey || null),
    );
    // 出货扣减库存（进销单位换算：折合过则按计数单位扣减，否则按原单位）
    batch.push(stockDeltaFor(c.env.DB, { item_id: price.item_id, unit: price.unit, quantity: qty, count_qty: effCount === qty ? null : effCount, count_unit: price.count_unit, per }, -1));
  }

  await c.env.DB.batch(batch);
  await recordChange(c.env.DB, { entity_type: 'sale', entity_sync_id: saleId, payload: await buildPayload(c.env.DB, 'sale', saleId), updated_by_username: user.username });
  await recordAudit(c.env.DB, { username: user.username, action: 'create', entity_type: 'sale', entity_id: saleId, detail: `添加出货：店铺 ${clientId}，${items.length} 件商品，合计 ¥${(Math.round(total * 100) / 100).toFixed(2)}` });
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
    where += ' AND si.happened_at >= ? AND si.happened_at <= ?';
    params.push(today, today);
  } else {
    if (clientId) { where += ' AND si.client_id = ?'; params.push(clientId); }
    if (dateFrom) { where += ' AND si.happened_at >= ?'; params.push(dateFrom); }
    if (dateTo) { where += ' AND si.happened_at <= ?'; params.push(dateTo); }
  }

  // 去单据化：head 表已物理删除，列表从商品行聚合组装（每单一行：店铺/日期/总额由行派生）
  const aggWhere = where.replace(/si\.happened_at/g, 'happened_at').replace(/si\.client_id/g, 'client_id');
  const countRow = await c.env.DB.prepare(
    `SELECT COUNT(*) AS cnt FROM (SELECT sale_id FROM sale_items si ${aggWhere} GROUP BY sale_id)`,
  ).bind(...params).first<{ cnt: number }>();

  const aggRows = await c.env.DB.prepare(
    `SELECT si.sale_id AS id,
            MAX(si.client_id) AS client_id,
            MAX(COALESCE(si.happened_at, '')) AS happened_at,
            SUM(si.amount) AS total,
            MIN(si.note) AS note
     FROM sale_items si ${aggWhere}
     GROUP BY si.sale_id
     ORDER BY happened_at DESC, id DESC LIMIT ? OFFSET ?`,
  ).bind(...params, limit, offset).all<{ id: string; client_id: string; happened_at: string; total: number; note: string }>();
  if (aggRows.results.length === 0) return c.json({ sales: [], total: 0, sale_items: [] });

  const saleIds = aggRows.results.map((r) => r.id);
  const placeholders = saleIds.map(() => '?').join(',');
  const clientRows = await c.env.DB.prepare(
    `SELECT id, name FROM clients WHERE id IN (${[...new Set(aggRows.results.map((r) => r.client_id))].map(() => '?').join(',')})`,
  ).bind(...[...new Set(aggRows.results.map((r) => r.client_id))]).all<{ id: string; name: string }>();
  const clientName = new Map(clientRows.results.map((c) => [c.id, c.name]));

  const detailRows = await c.env.DB.prepare(
    `SELECT si.*, i.name AS item_name, i.category AS item_category FROM sale_items si JOIN items i ON i.id = si.item_id
     WHERE si.sale_id IN (${placeholders}) ORDER BY si.created_at`,
  ).bind(...saleIds).all();

  const bySale = new Map<string, unknown[]>();
  for (const d of detailRows.results) {
    const saleId2 = (d as { sale_id: string }).sale_id;
    const list = bySale.get(saleId2) ?? [];
    list.push(d);
    bySale.set(saleId2, list);
  }
  // 行级主记录数组（去单据化：每条商品一行，自带店铺/日期/备注/金额——客户端主读数）
  const saleItemRows = await c.env.DB.prepare(
    `SELECT si.id, si.sale_id, si.client_id, c.name AS client_name, si.item_id, i.name AS item_name,
            i.category AS item_category, si.unit, si.quantity, si.sale_price, si.cost_price, si.amount,
            si.happened_at, si.note, si.created_by
     FROM sale_items si
     LEFT JOIN clients c ON c.id = si.client_id
     LEFT JOIN items i ON i.id = si.item_id
     WHERE si.sale_id IN (${placeholders})
     ORDER BY si.created_at`,
  ).bind(...saleIds).all();
  return c.json({
    total: countRow?.cnt ?? 0,
    sales: aggRows.results.map((row) => ({
      id: row.id, client_id: row.client_id, client_name: clientName.get(row.client_id) ?? '',
      happened_at: row.happened_at, note: row.note ?? '', total: row.total,
      items: bySale.get(row.id) ?? [],
    })),
    // 去单据化主结构：行级商品记录（新客户端优先读，整单 sales 字段兼容保留）
    sale_items: saleItemRows.results.map((x) => {
      const r = x as Record<string, unknown>;
      return user.role === 'staff' ? { ...r, cost_price: 0 } : r;
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
  // 无头表：组装时 happened_at=明细行最大日期，无需再同步 head
  const saleIds = [...new Set(rows.results.map((r) => r.sale_id))];
  for (const sid of saleIds) {
    await recordChange(c.env.DB, { entity_type: 'sale', entity_sync_id: sid, payload: await buildPayload(c.env.DB, 'sale', sid), updated_by_username: c.get('user').username });
  }
  await recordAudit(c.env.DB, { username: c.get('user').username, action: 'update', entity_type: 'sale_item', detail: `批量修改出货日期：${updates.length} 行` });
  return c.json({ updated: batch.length });
});

// GET /sales/:id — 单张出货记录详情（去单据化：头字段由商品行聚合，契约不变）
salesRouter.get('/:id', async (c) => {
  const id = c.req.param('id');
  const rows = await c.env.DB.prepare(
    `SELECT si.*, i.name AS item_name, i.category AS item_category
     FROM sale_items si LEFT JOIN items i ON i.id = si.item_id WHERE si.sale_id = ? ORDER BY si.created_at`,
  ).bind(id).all<Record<string, unknown>>();
  if (rows.results.length === 0) return c.json({ error: '出货记录不存在' }, 404);
  const first = rows.results[0];
  const clientRow = await c.env.DB.prepare('SELECT name FROM clients WHERE id = ?').bind(first.client_id).first<{ name: string }>();
  const total = rows.results.reduce((s, r) => s + (Number(r.amount) || 0), 0);
  return c.json({
    id,
    client_id: first.client_id ?? '',
    client_name: clientRow?.name ?? '',
    happened_at: rows.results.map((r) => `${r.happened_at ?? ''}`).reduce((a, b) => (a >= b ? a : b), ''),
    note: `${first.note ?? ''}`,
    total,
    items: rows.results,
  });
});

// PATCH /sales/items/:id — 编辑单条出货明细行（数量/单位/售价/日期/备注；回滚旧库存再按新值扣减，重算金额与单据日期）
salesRouter.patch('/items/:id', async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as {
    quantity?: number; unit?: string; sale_price?: number; happened_at?: string; note?: string; count_qty?: number;
  } | null;
  const row = await c.env.DB.prepare(
    `SELECT si.id, si.sale_id, si.item_id, si.unit, si.quantity, si.count_qty, si.sale_price, si.happened_at, si.note, i.count_unit
     FROM sale_items si LEFT JOIN items i ON i.id = si.item_id WHERE si.id = ?`,
  ).bind(id).first<{ id: string; sale_id: string; item_id: string; unit: string; quantity: number; count_qty: number | null; sale_price: number; happened_at: string | null; note: string | null; count_unit?: string | null }>();
  if (!row) return c.json({ error: '明细行不存在' }, 404);

  const qty = body?.quantity !== undefined ? Number(body.quantity) : row.quantity;
  if (!Number.isFinite(qty) || qty <= 0) return c.json({ error: '数量必须大于 0' }, 400);
  const unit = body?.unit?.trim() || row.unit;
  const countQty = body?.count_qty !== undefined ? Number(body.count_qty) : Number(row.count_qty ?? 0);
  const sp = body?.sale_price !== undefined ? Number(body.sale_price) : row.sale_price;
  const salePrice = Number.isFinite(sp) && sp > 0 ? sp : row.sale_price;
  const happenedAt = body?.happened_at?.trim() || row.happened_at || '';
  if (happenedAt && !/^\d{4}-\d{2}-\d{2}$/.test(happenedAt)) return c.json({ error: '日期格式应为 YYYY-MM-DD' }, 400);
  const note = body?.note !== undefined ? (body.note ?? '').trim() : (row.note ?? '');

  const amount = Math.round(qty * salePrice * 100) / 100;
  const batch: D1PreparedStatement[] = [
    stockDeltaFor(c.env.DB, { item_id: row.item_id, unit: row.unit, quantity: row.quantity, count_qty: row.count_qty, count_unit: row.count_unit }, 1),  // 出货扣减恢复（旧值）
    stockDeltaFor(c.env.DB, { item_id: row.item_id, unit, quantity: qty, count_qty: countQty > 0 ? countQty : null, count_unit: row.count_unit }, -1), // 按新值扣减
    c.env.DB.prepare(
      'UPDATE sale_items SET quantity = ?, unit = ?, count_qty = ?, sale_price = ?, amount = ?, happened_at = ?, note = ? WHERE id = ?',
    ).bind(qty, unit, countQty > 0 ? countQty : null, salePrice, amount, happenedAt || null, note, id),
  ];
  await c.env.DB.batch(batch);
  // 无头表：组装时 happened_at=明细行最大日期，无需再同步 head
  const saleId = row.sale_id;
  await recordChange(c.env.DB, { entity_type: 'sale', entity_sync_id: saleId, payload: await buildPayload(c.env.DB, 'sale', saleId), updated_by_username: c.get('user').username });
  await recordAudit(c.env.DB, {
    username: c.get('user').username, action: 'update', entity_type: 'sale_item', entity_id: id,
    detail: `修改出货商品行：${happenedAt ? `日期 ${happenedAt}` : ''} 数量 ${qty}${unit}${countQty > 0 ? ` ${countQty}${row.count_unit ?? '计'}` : ''}${body?.sale_price !== undefined ? ` 售价 ${salePrice}` : ''}`,
  });
  return c.json({ id, sale_id: saleId, item_id: row.item_id, unit, quantity: qty, count_qty: countQty > 0 ? countQty : null, sale_price: salePrice, amount, happened_at: happenedAt || null });
});

// PATCH /sales/:id — 编辑出货记录（改店铺/日期/备注；传 items 则整体替换明细，原子事务）
salesRouter.patch('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as {
    client_id?: string; happened_at?: string; note?: string; items?: SaleItemInput[];
  } | null;
  // 去单据化：无 head 表，按该批是否存在商品行判断
  const exist = await c.env.DB.prepare('SELECT client_id FROM sale_items WHERE sale_id = ? LIMIT 1').bind(id)
    .first<{ client_id: string }>();
  if (!exist) return c.json({ error: '出货记录不存在' }, 404);

  const clientId = body?.client_id ?? exist.client_id;
  const client = await c.env.DB.prepare('SELECT id FROM clients WHERE id = ? AND deleted_at IS NULL').bind(clientId).first();
  if (!client) return c.json({ error: '店铺不存在' }, 404);
  // 整单顶层字段（改日期/备注/店铺）应用到全部商品行：行即主记录，head 由行派生
  const batch: D1PreparedStatement[] = [];
  if (body?.client_id !== undefined) {
    batch.push(c.env.DB.prepare('UPDATE sale_items SET client_id = ? WHERE sale_id = ?').bind(clientId, id));
  }
  if (body?.happened_at !== undefined && body.happened_at.trim()) {
    batch.push(c.env.DB.prepare('UPDATE sale_items SET happened_at = ? WHERE sale_id = ?').bind(body.happened_at.trim(), id));
  }
  if (body?.note !== undefined) {
    batch.push(c.env.DB.prepare('UPDATE sale_items SET note = ? WHERE sale_id = ?').bind(body.note.trim() ?? '', id));
  }
  let total: number;
  if (body?.items !== undefined) {
    const items = body.items;
    if (!Array.isArray(items) || items.length === 0) return c.json({ error: '请至少添加一种商品' }, 400);
    // 编辑替换明细：先回滚原明细的库存（出货扣减恢复），再按新明细扣减
    const oldItems = await c.env.DB.prepare(
      `SELECT si.item_id, si.unit, si.quantity, si.count_qty, i.count_unit
       FROM sale_items si LEFT JOIN items i ON i.id = si.item_id WHERE si.sale_id = ?`).bind(id)
      .all<{ item_id: string; unit: string; quantity: number; count_qty: number | null; count_unit?: string | null }>();
    for (const it of oldItems.results) {
      batch.push(stockDeltaFor(c.env.DB, { item_id: it.item_id, unit: it.unit, quantity: it.quantity, count_qty: it.count_qty, count_unit: it.count_unit }, 1));
    }
    const priceIds = items.map((i) => i.price_id);
    if (priceIds.some((p) => !p)) return c.json({ error: '商品缺单位价格' }, 400);
    const placeholders = priceIds.map(() => '?').join(',');
    const priceRows = await c.env.DB.prepare(
      `SELECT p.id, p.item_id, p.unit, p.purchase_price, p.sale_price, p.active, p.per, i.count_unit
       FROM item_prices p LEFT JOIN items i ON i.id = p.item_id WHERE p.id IN (${placeholders})`,
    ).bind(...priceIds).all<{ id: string; item_id: string; unit: string; purchase_price: number; sale_price: number; active: number; per?: number | null; count_unit?: string | null }>();
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
    const happenedAt = body?.happened_at?.trim() || '';
    for (const item of items) {
      const price = priceMap.get(item.price_id);
      if (!price || !price.active) continue;
      const qty = Number(item.quantity);
      const salePrice = Number(item.sale_price);
      const effectiveSale = Number.isFinite(salePrice) && salePrice > 0 ? salePrice : price.sale_price;
      const amount = Math.round(qty * effectiveSale * 100) / 100;
      // 折合计数数量：记单时显式填 > 价格行规格 per > 缺省 quantity（按原单位）
      const countQty = Number(item.count_qty);
      const per = Number(price.per ?? 0);
      const effCount = Number.isFinite(countQty) && countQty > 0 ? countQty : (per > 0 ? Math.round(qty * per * 100) / 100 : qty);
      batch.push(
        c.env.DB.prepare(
          'INSERT INTO sale_items (id, sale_id, client_id, item_id, unit, quantity, count_qty, sale_price, cost_price, amount, happened_at, note, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        ).bind(item.id ?? randomId(), id, clientId, price.item_id, price.unit, qty, effCount === qty ? null : effCount, effectiveSale, price.purchase_price, amount,
          item.happened_at?.trim() || happenedAt, item.note?.trim() ?? '', c.get('user').id),
      );
      // 按新明细扣减库存（进销单位换算：折合过则按计数单位扣减）
      batch.push(stockDeltaFor(c.env.DB, { item_id: price.item_id, unit: price.unit, quantity: qty, count_qty: effCount === qty ? null : effCount, count_unit: price.count_unit, per }, -1));
    }
  } else {
    const tot = await c.env.DB.prepare('SELECT COALESCE(SUM(amount),0) AS total FROM sale_items WHERE sale_id = ?').bind(id).first<{ total: number }>();
    total = tot?.total ?? 0;
  }
  await c.env.DB.batch(batch);
  await recordChange(c.env.DB, { entity_type: 'sale', entity_sync_id: id, payload: await buildPayload(c.env.DB, 'sale', id), updated_by_username: c.get('user').username });
  await recordAudit(c.env.DB, {
    username: c.get('user').username, action: 'update', entity_type: 'sale', entity_id: id,
    detail: `修改出货记录${body?.happened_at ? `：日期 ${body.happened_at.trim()}` : ''}${body?.client_id ? ` 店铺 ${body.client_id}` : ''}${body?.items ? `（${body.items.length} 件商品）` : ''}`,
  });
  return c.json({ id, client_id: clientId, happened_at: body?.happened_at?.trim() || '', note: body?.note?.trim() ?? '', total: Math.round(total * 100) / 100 });
});

// DELETE /sales/items/:id — 删除单条出货明细行（出货流水行级删除；回滚该行库存，重算单据日期）
salesRouter.delete('/items/:id', async (c) => {
  const id = c.req.param('id');
  const row = await c.env.DB.prepare(
    `SELECT si.id, si.sale_id, si.item_id, si.unit, si.quantity, si.count_qty, i.count_unit
     FROM sale_items si LEFT JOIN items i ON i.id = si.item_id WHERE si.id = ?`,
  ).bind(id).first<{ id: string; sale_id: string; item_id: string; unit: string; quantity: number; count_qty: number | null; count_unit?: string | null }>();
  if (!row) return c.json({ error: '明细行不存在' }, 404);
  const saleId = row.sale_id;
  const batch: D1PreparedStatement[] = [
    stockDeltaFor(c.env.DB, { item_id: row.item_id, unit: row.unit, quantity: row.quantity, count_qty: row.count_qty, count_unit: row.count_unit }, 1), // 出货扣减恢复
    c.env.DB.prepare('DELETE FROM sale_items WHERE id = ?').bind(id),
  ];
  await c.env.DB.batch(batch);
  // 该行若有凭证附件（行级 sale_item 引用），级联删除引用+R2（best-effort 不阻塞删除）
  try {
    await deleteEntityAttachments(c.env, 'sale_item', id);
  } catch (_) {}
  // 删的是该单最后一行商品 → 该批记录无商品，按用户语义（无单据概念）整体删除该条记录；
  // 无 head 表（已物理删除），只清行级附件引用，避免服务端残留"无明细"空壳
  const remain = await c.env.DB.prepare('SELECT COUNT(*) AS n FROM sale_items WHERE sale_id = ?').bind(saleId).first<{ n: number }>();
  if ((remain?.n ?? 0) === 0) {
    try {
      await deleteEntityAttachments(c.env, 'sale', saleId);
    } catch (_) {}
    await recordChange(c.env.DB, { entity_type: 'sale', entity_sync_id: saleId, action: 'delete', payload: {}, updated_by_username: c.get('user').username });
    return c.json({ ok: true, order_deleted: true });
  }
  // 无 head 表：组装时 happened_at=明细行最大日期，无需再同步 head
  await recordChange(c.env.DB, { entity_type: 'sale', entity_sync_id: saleId, payload: await buildPayload(c.env.DB, 'sale', saleId), updated_by_username: c.get('user').username });
  return c.json({ ok: true });
});

// DELETE /sales/:id — 删除出货记录（回滚库存 + 删全部商品行，仅老板）
salesRouter.delete('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const oldItems = await c.env.DB.prepare(
    `SELECT si.item_id, si.unit, si.quantity, si.count_qty, i.count_unit
     FROM sale_items si LEFT JOIN items i ON i.id = si.item_id WHERE si.sale_id = ?`).bind(id)
    .all<{ item_id: string; unit: string; quantity: number; count_qty: number | null; count_unit?: string | null }>();
  // 行级凭证附件：删行前拿行 id 清理（行级附件按 sale_item/{lineId}/ 存储）
  try {
    const lineRows = await c.env.DB.prepare('SELECT id FROM sale_items WHERE sale_id = ?').bind(id)
      .all<{ id: string }>();
    for (const lr of lineRows.results) {
      await deleteEntityAttachments(c.env, 'sale_item', lr.id);
    }
  } catch (_) {}
  const batch: D1PreparedStatement[] = oldItems.results
    .map((it) => stockDeltaFor(c.env.DB, { item_id: it.item_id, unit: it.unit, quantity: it.quantity, count_qty: it.count_qty, count_unit: it.count_unit }, 1)); // 出货扣的加回
  batch.push(c.env.DB.prepare('DELETE FROM sale_items WHERE sale_id = ?').bind(id));
  await c.env.DB.batch(batch);
  await recordChange(c.env.DB, { entity_type: 'sale', entity_sync_id: id, action: 'delete', payload: {}, updated_by_username: c.get('user').username });
  await recordAudit(c.env.DB, { username: c.get('user').username, action: 'delete', entity_type: 'sale', entity_id: id, detail: `删除出货记录（${oldItems.results.length} 件商品）` });
  // 删除交易附带的凭证图片（单据级 + 全部明细行级，best-effort 不阻塞删除）
  try {
    await deleteEntityAttachments(c.env, 'sale', id);
  } catch (_) {}
  return c.body(null, 204);
});