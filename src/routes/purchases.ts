/** 进货单：purchases + purchase_items（记成本） */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { adminOnly, authMiddleware } from '../middleware/auth';
import { parsePage } from '../lib/paging';
import { stockDelta } from '../lib/stock';
import { buildPayload, recordChange } from '../lib/sync';
import { deleteEntityAttachments } from '../lib/image-key';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const purchasesRouter = new Hono<{ Bindings: Env; Variables: V }>();

purchasesRouter.use('*', authMiddleware());

const nowIso = () => new Date().toISOString();

interface PurchaseItemInput {
  price_id: string;
  quantity: number;
  purchase_price?: number;   // 可覆盖默认进价
  happened_at?: string;      // 行独立日期（缺省用单据日期）
}

// POST /purchases
purchasesRouter.post('/', async (c) => {
  const user = c.get('user');
  const body = await c.req.json().catch(() => null) as {
    happened_at?: string;
    note?: string;
    items?: PurchaseItemInput[];
    sync_key?: string;
  } | null;
  const items = body?.items ?? [];
  const syncKey = body?.sync_key?.trim() || '';
  if (!Array.isArray(items) || items.length === 0) return c.json({ error: '请至少添加一种商品' }, 400);

  // 幂等：同一 sync_key 已存在（离线重放重复投递）→ 返回已有单据，不重复建单/不重复加库存
  if (syncKey) {
    const existed = await c.env.DB.prepare('SELECT id FROM purchases WHERE sync_key = ?').bind(syncKey).first<{ id: string }>();
    if (existed) {
      return c.json({ id: existed.id, dup: true, total: 0, items: 0 });
    }
  }

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
    c.env.DB.prepare('INSERT INTO purchases (id, happened_at, note, created_by, sync_key) VALUES (?, ?, ?, ?, ?)')
      .bind(purchaseId, happenedAt, note, user.id, syncKey || null),
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
        'INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount, happened_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      ).bind(randomId(), purchaseId, price.item_id, price.unit, qty, effective, amount,
        item.happened_at?.trim() || happenedAt),
    );
    // 进货增加库存
    batch.push(stockDelta(c.env.DB, price.item_id, price.unit, qty));
  }

  await c.env.DB.batch(batch);
  await recordChange(c.env.DB, { entity_type: 'purchase', entity_sync_id: purchaseId, payload: await buildPayload(c.env.DB, 'purchase', purchaseId), updated_by_username: user.username });
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

// POST /purchases/items/date — 批量改明细行日期（进货记录「日期栏批量编辑」用；不改库存/金额）
purchasesRouter.post('/items/date', async (c) => {
  const body = await c.req.json().catch(() => null) as { updates?: Array<{ item_id?: string; happened_at?: string }> } | null;
  const updates = (body?.updates ?? []).filter((u) => u && u.item_id && u.happened_at).slice(0, 500);
  if (updates.length === 0) return c.json({ error: '请提供明细行 id 与目标日期' }, 400);
  for (const u of updates) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(u.happened_at!)) return c.json({ error: '日期格式应为 YYYY-MM-DD' }, 400);
  }
  const ids = updates.map((u) => u.item_id!);
  const rows = await c.env.DB.prepare(
    `SELECT id, purchase_id FROM purchase_items WHERE id IN (${ids.map(() => '?').join(',')})`,
  ).bind(...ids).all<{ id: string; purchase_id: string }>();
  if (rows.results.length === 0) return c.json({ error: '明细行不存在' }, 404);
  const byId = new Map(rows.results.map((r) => [r.id, r.purchase_id]));
  const batch: D1PreparedStatement[] = [];
  for (const u of updates) {
    const purchaseId = byId.get(u.item_id!);
    if (purchaseId) batch.push(c.env.DB.prepare('UPDATE purchase_items SET happened_at = ? WHERE id = ?').bind(u.happened_at, u.item_id));
  }
  await c.env.DB.batch(batch);
  // 单据日期自动取明细最大日期（与记单页 orderDate=最大行日期口径一致）
  const purchaseIds = [...new Set(rows.results.map((r) => r.purchase_id))];
  const dateBatch: D1PreparedStatement[] = purchaseIds.map((pid) =>
    c.env.DB.prepare(
      `UPDATE purchases SET happened_at = (
         SELECT MAX(COALESCE(happened_at, '')) FROM purchase_items WHERE purchase_id = ?
       ) WHERE id = ? AND EXISTS (SELECT 1 FROM purchase_items WHERE purchase_id = ?)`,
    ).bind(pid, pid, pid));
  await c.env.DB.batch(dateBatch);
  for (const pid of purchaseIds) {
    await recordChange(c.env.DB, { entity_type: 'purchase', entity_sync_id: pid, payload: await buildPayload(c.env.DB, 'purchase', pid), updated_by_username: c.get('user').username });
  }
  return c.json({ updated: batch.length });
});

// PATCH /purchases/items/:id — 编辑单条进货明细行（数量/单位/进价/日期；回滚旧库存再按新值增加，重算金额与单据日期）
purchasesRouter.patch('/items/:id', async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as {
    quantity?: number; unit?: string; purchase_price?: number; happened_at?: string;
  } | null;
  const row = await c.env.DB.prepare(
    'SELECT id, purchase_id, item_id, unit, quantity, purchase_price, happened_at FROM purchase_items WHERE id = ?',
  ).bind(id).first<{ id: string; purchase_id: string; item_id: string; unit: string; quantity: number; purchase_price: number; happened_at: string | null }>();
  if (!row) return c.json({ error: '明细行不存在' }, 404);

  const qty = body?.quantity !== undefined ? Number(body.quantity) : row.quantity;
  if (!Number.isFinite(qty) || qty <= 0) return c.json({ error: '数量必须大于 0' }, 400);
  const unit = body?.unit?.trim() || row.unit;
  const pp = body?.purchase_price !== undefined ? Number(body.purchase_price) : row.purchase_price;
  const purchasePrice = Number.isFinite(pp) && pp > 0 ? pp : row.purchase_price;
  const happenedAt = body?.happened_at?.trim() || row.happened_at || '';
  if (happenedAt && !/^\d{4}-\d{2}-\d{2}$/.test(happenedAt)) return c.json({ error: '日期格式应为 YYYY-MM-DD' }, 400);

  const amount = Math.round(qty * purchasePrice * 100) / 100;
  const batch: D1PreparedStatement[] = [
    stockDelta(c.env.DB, row.item_id, row.unit, -row.quantity), // 进货增加恢复（旧值）
    stockDelta(c.env.DB, row.item_id, unit, qty),               // 按新值重新增加（不变时净零）
    c.env.DB.prepare(
      'UPDATE purchase_items SET quantity = ?, unit = ?, purchase_price = ?, amount = ?, happened_at = ? WHERE id = ?',
    ).bind(qty, unit, purchasePrice, amount, happenedAt || null, id),
  ];
  await c.env.DB.batch(batch);
  // 单据日期自动取明细最大日期（与记单页 orderDate=最大行日期口径一致）
  const purchaseId = row.purchase_id;
  await c.env.DB.prepare(
    `UPDATE purchases SET happened_at = (
       SELECT MAX(COALESCE(happened_at, '')) FROM purchase_items WHERE purchase_id = ?
     ) WHERE id = ? AND EXISTS (SELECT 1 FROM purchase_items WHERE purchase_id = ?)`,
  ).bind(purchaseId, purchaseId, purchaseId).run();
  await recordChange(c.env.DB, { entity_type: 'purchase', entity_sync_id: purchaseId, payload: await buildPayload(c.env.DB, 'purchase', purchaseId), updated_by_username: c.get('user').username });
  return c.json({ id, purchase_id: purchaseId, item_id: row.item_id, unit, quantity: qty, purchase_price: purchasePrice, amount, happened_at: happenedAt || null });
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
          'INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount, happened_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        ).bind(randomId(), id, price.item_id, price.unit, qty, effective, amount,
          item.happened_at?.trim() || happenedAt),
      );
      // 按新明细增加库存
      batch.push(stockDelta(c.env.DB, price.item_id, price.unit, qty));
    }
  } else {
    const tot = await c.env.DB.prepare('SELECT COALESCE(SUM(amount),0) AS total FROM purchase_items WHERE purchase_id = ?').bind(id).first<{ total: number }>();
    total = tot?.total ?? 0;
  }
  await c.env.DB.batch(batch);
  await recordChange(c.env.DB, { entity_type: 'purchase', entity_sync_id: id, payload: await buildPayload(c.env.DB, 'purchase', id), updated_by_username: c.get('user').username });
  return c.json({ id, happened_at: happenedAt, note, total: Math.round(total * 100) / 100 });
});

// DELETE /purchases/items/:id — 删除单条进货明细行（进货记录行级删除；回滚该行库存，重算单据日期）
purchasesRouter.delete('/items/:id', async (c) => {
  const id = c.req.param('id');
  const row = await c.env.DB.prepare(
    'SELECT id, purchase_id, item_id, unit, quantity FROM purchase_items WHERE id = ?',
  ).bind(id).first<{ id: string; purchase_id: string; item_id: string; unit: string; quantity: number }>();
  if (!row) return c.json({ error: '明细行不存在' }, 404);
  const purchaseId = row.purchase_id;
  const batch: D1PreparedStatement[] = [
    stockDelta(c.env.DB, row.item_id, row.unit, -row.quantity), // 进货增加恢复
    c.env.DB.prepare('DELETE FROM purchase_items WHERE id = ?').bind(id),
  ];
  await c.env.DB.batch(batch);
  // 单据日期自动取剩余明细最大日期（空明细则保持原样）
  await c.env.DB.prepare(
    `UPDATE purchases SET happened_at = (
       SELECT MAX(COALESCE(happened_at, '')) FROM purchase_items WHERE purchase_id = ?
     ) WHERE id = ? AND EXISTS (SELECT 1 FROM purchase_items WHERE purchase_id = ?)`,
  ).bind(purchaseId, purchaseId, purchaseId).run();
  await recordChange(c.env.DB, { entity_type: 'purchase', entity_sync_id: purchaseId, payload: await buildPayload(c.env.DB, 'purchase', purchaseId), updated_by_username: c.get('user').username });
  return c.json({ ok: true });
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
  await recordChange(c.env.DB, { entity_type: 'purchase', entity_sync_id: id, action: 'delete', payload: {}, updated_by_username: c.get('user').username });
  // 删除进货单附带的凭证图片（孤儿文件清理，best-effort 不阻塞删除）
  try {
    await deleteEntityAttachments(c.env, 'purchase', id);
  } catch (_) {}
  return c.body(null, 204);
});