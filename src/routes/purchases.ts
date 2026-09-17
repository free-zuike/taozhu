/** 进货单：purchases + purchase_items（记成本） */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { adminOnly, authMiddleware } from '../middleware/auth';
import { parsePage } from '../lib/paging';
import { stockDelta } from '../lib/stock';
import { buildPayload, recordChange } from '../lib/sync';
import { deleteEntityAttachments } from '../lib/image-key';
import { recordAudit } from './audit';
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
  note?: string;             // 行级备注（缺省空）
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

  // 幂等：同一 sync_key 已存在（离线重放重复投递）→ 返回已有记录，不重复建单/不重复加库存
  // （去单据化后行即主记录：按行级 sync_key 查重，返回该批首行所在 purchase_id）
  if (syncKey) {
    const existed = await c.env.DB.prepare('SELECT purchase_id FROM purchase_items WHERE sync_key = ?').bind(syncKey).first<{ purchase_id: string }>();
    if (existed) {
      return c.json({ id: existed.purchase_id, dup: true, total: 0, items: 0 });
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
    // 去单据化：无 purchases 头表（已物理删除），行即主记录，进货批次由 purchase_id 关联
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
        'INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount, happened_at, note, created_by, sync_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ).bind(randomId(), purchaseId, price.item_id, price.unit, qty, effective, amount,
        item.happened_at?.trim() || happenedAt, item.note?.trim() ?? '', user.id, syncKey || null),
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
  const user = c.get('user');
  const dateFrom = c.req.query('date_from')?.trim();
  const dateTo = c.req.query('date_to')?.trim();
  const { limit, offset } = parsePage(c.req.query('limit'), c.req.query('offset'));

  let where = ' WHERE 1=1';
  const params: string[] = [];
  if (dateFrom) { where += ' AND pi.happened_at >= ?'; params.push(dateFrom); }
  if (dateTo) { where += ' AND pi.happened_at <= ?'; params.push(dateTo); }

  // 去单据化：head 表已物理删除，列表从商品行聚合组装（每单一行：日期/总额由行派生）
  const aggWhere = where.replace(/pi\.happened_at/g, 'happened_at');
  const countRow = await c.env.DB.prepare(
    `SELECT COUNT(*) AS cnt FROM (SELECT purchase_id FROM purchase_items pi ${aggWhere} GROUP BY purchase_id)`,
  ).bind(...params).first<{ cnt: number }>();

  const aggRows = await c.env.DB.prepare(
    `SELECT pi.purchase_id AS id,
            MAX(COALESCE(pi.happened_at, '')) AS happened_at,
            SUM(pi.amount) AS total,
            MIN(pi.note) AS note
     FROM purchase_items pi ${aggWhere}
     GROUP BY pi.purchase_id
     ORDER BY happened_at DESC, id DESC LIMIT ? OFFSET ?`,
  ).bind(...params, limit, offset).all<{ id: string; happened_at: string; total: number; note: string }>();
  if (aggRows.results.length === 0) return c.json({ purchases: [], total: 0, purchase_items: [] });

  const ids = aggRows.results.map((r) => r.id);
  const ph = ids.map(() => '?').join(',');
  const detail = await c.env.DB.prepare(
    `SELECT pi.*, i.name AS item_name, i.category AS item_category FROM purchase_items pi JOIN items i ON i.id = pi.item_id WHERE pi.purchase_id IN (${ph}) ORDER BY pi.created_at`,
  ).bind(...ids).all();
  const byId = new Map<string, unknown[]>();
  for (const d of detail.results) {
    const pid = (d as { purchase_id: string }).purchase_id;
    const list = byId.get(pid) ?? [];
    list.push(d);
    byId.set(pid, list);
  }
  // 行级主记录数组（去单据化：每条商品一行，自带日期/备注/金额——客户端主读数）
  const purchaseItemRows = await c.env.DB.prepare(
    `SELECT pi.id, pi.purchase_id, pi.item_id, i.name AS item_name, i.category AS item_category,
            pi.unit, pi.quantity, pi.purchase_price, pi.amount,
            pi.happened_at, pi.note, pi.created_by
     FROM purchase_items pi
     LEFT JOIN items i ON i.id = pi.item_id
     WHERE pi.purchase_id IN (${ph})
     ORDER BY pi.created_at`,
  ).bind(...ids).all();
  return c.json({
    total: countRow?.cnt ?? 0,
    purchases: aggRows.results.map((row) => ({
      id: row.id, happened_at: row.happened_at, note: row.note ?? '', total: row.total, items: byId.get(row.id) ?? [],
    })),
    // 去单据化主结构：行级商品记录（新客户端优先读，整单 purchases 字段兼容保留）
    purchase_items: purchaseItemRows.results.map((x) => {
      const r = x as Record<string, unknown>;
      return user.role === 'staff' ? { ...r, purchase_price: 0 } : r;
    }),
  });
});

// GET /purchases/:id — 单张进货记录详情（去单据化：头字段由商品行聚合，契约不变）
purchasesRouter.get('/:id', async (c) => {
  const id = c.req.param('id');
  const rows = await c.env.DB.prepare(
    `SELECT pi.*, i.name AS item_name, i.category AS item_category
     FROM purchase_items pi LEFT JOIN items i ON i.id = pi.item_id WHERE pi.purchase_id = ? ORDER BY pi.created_at`,
  ).bind(id).all<Record<string, unknown>>();
  if (rows.results.length === 0) return c.json({ error: '进货记录不存在' }, 404);
  const total = rows.results.reduce((s, r) => s + (Number(r.amount) || 0), 0);
  const first = rows.results[0];
  return c.json({
    id,
    happened_at: rows.results.map((r) => `${r.happened_at ?? ''}`).reduce((a, b) => (a >= b ? a : b), ''),
    note: `${first.note ?? ''}`,
    total,
    items: rows.results,
  });
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
  // 无头表：组装时 happened_at=明细行最大日期，无需再同步 head
  const purchaseIds = [...new Set(rows.results.map((r) => r.purchase_id))];
  for (const pid of purchaseIds) {
    await recordChange(c.env.DB, { entity_type: 'purchase', entity_sync_id: pid, payload: await buildPayload(c.env.DB, 'purchase', pid), updated_by_username: c.get('user').username });
  }
  return c.json({ updated: batch.length });
});

// PATCH /purchases/items/:id — 编辑单条进货明细行（数量/单位/进价/日期/备注；回滚旧库存再按新值增加，重算金额与单据日期）
purchasesRouter.patch('/items/:id', async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as {
    quantity?: number; unit?: string; purchase_price?: number; happened_at?: string; note?: string;
  } | null;
  const row = await c.env.DB.prepare(
    'SELECT id, purchase_id, item_id, unit, quantity, purchase_price, happened_at, note FROM purchase_items WHERE id = ?',
  ).bind(id).first<{ id: string; purchase_id: string; item_id: string; unit: string; quantity: number; purchase_price: number; happened_at: string | null; note: string | null }>();
  if (!row) return c.json({ error: '明细行不存在' }, 404);

  const qty = body?.quantity !== undefined ? Number(body.quantity) : row.quantity;
  if (!Number.isFinite(qty) || qty <= 0) return c.json({ error: '数量必须大于 0' }, 400);
  const unit = body?.unit?.trim() || row.unit;
  const pp = body?.purchase_price !== undefined ? Number(body.purchase_price) : row.purchase_price;
  const purchasePrice = Number.isFinite(pp) && pp > 0 ? pp : row.purchase_price;
  const happenedAt = body?.happened_at?.trim() || row.happened_at || '';
  if (happenedAt && !/^\d{4}-\d{2}-\d{2}$/.test(happenedAt)) return c.json({ error: '日期格式应为 YYYY-MM-DD' }, 400);
  const note = body?.note !== undefined ? (body.note ?? '').trim() : (row.note ?? '');

  const amount = Math.round(qty * purchasePrice * 100) / 100;
  const batch: D1PreparedStatement[] = [
    stockDelta(c.env.DB, row.item_id, row.unit, -row.quantity), // 进货增加恢复（旧值）
    stockDelta(c.env.DB, row.item_id, unit, qty),               // 按新值重新增加（不变时净零）
    c.env.DB.prepare(
      'UPDATE purchase_items SET quantity = ?, unit = ?, purchase_price = ?, amount = ?, happened_at = ?, note = ? WHERE id = ?',
    ).bind(qty, unit, purchasePrice, amount, happenedAt || null, note, id),
  ];
  await c.env.DB.batch(batch);
  // 无头表：组装时 happened_at=明细行最大日期，无需再同步 head
  const purchaseId = row.purchase_id;
  await recordChange(c.env.DB, { entity_type: 'purchase', entity_sync_id: purchaseId, payload: await buildPayload(c.env.DB, 'purchase', purchaseId), updated_by_username: c.get('user').username });
  return c.json({ id, purchase_id: purchaseId, item_id: row.item_id, unit, quantity: qty, purchase_price: purchasePrice, amount, happened_at: happenedAt || null });
});

// PATCH /purchases/:id — 编辑进货记录（改日期/备注；传 items 则整体替换明细，原子事务）
purchasesRouter.patch('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as {
    happened_at?: string; note?: string; items?: PurchaseItemInput[];
  } | null;
  // 去单据化：无 head 表，按该批是否存在商品行判断
  const exist = await c.env.DB.prepare('SELECT purchase_id FROM purchase_items WHERE purchase_id = ? LIMIT 1').bind(id).first();
  if (!exist) return c.json({ error: '进货记录不存在' }, 404);

  // 整单顶层字段（改日期/备注）应用到全部商品行：行即主记录，head 由行派生
  const batch: D1PreparedStatement[] = [];
  if (body?.happened_at !== undefined && body.happened_at.trim()) {
    batch.push(c.env.DB.prepare('UPDATE purchase_items SET happened_at = ? WHERE purchase_id = ?').bind(body.happened_at.trim(), id));
  }
  if (body?.note !== undefined) {
    batch.push(c.env.DB.prepare('UPDATE purchase_items SET note = ? WHERE purchase_id = ?').bind(body.note.trim() ?? '', id));
  }
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
          'INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount, happened_at, note, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        ).bind(randomId(), id, price.item_id, price.unit, qty, effective, amount,
          item.happened_at?.trim() || body?.happened_at?.trim() || '', item.note?.trim() ?? '', c.get('user').id),
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
  return c.json({ id, happened_at: body?.happened_at?.trim() ?? '', note: body?.note?.trim() ?? '', total: Math.round(total * 100) / 100 });
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
  // 该行若有凭证附件（行级 purchase_item 引用），级联删除引用+R2（best-effort 不阻塞删除）
  try {
    await deleteEntityAttachments(c.env, 'purchase_item', id);
  } catch (_) {}
  // 删的是该单最后一行商品 → 该批记录无商品，按用户语义（无单据概念）整体删除该条记录；
  // 无 head 表（已物理删除），只清行级附件引用，避免服务端残留"无明细"空壳
  const remain = await c.env.DB.prepare('SELECT COUNT(*) AS n FROM purchase_items WHERE purchase_id = ?').bind(purchaseId).first<{ n: number }>();
  if ((remain?.n ?? 0) === 0) {
    try {
      await deleteEntityAttachments(c.env, 'purchase', purchaseId);
    } catch (_) {}
    await recordChange(c.env.DB, { entity_type: 'purchase', entity_sync_id: purchaseId, action: 'delete', payload: {}, updated_by_username: c.get('user').username });
    return c.json({ ok: true, order_deleted: true });
  }
  // 无 head 表：组装时 happened_at=明细行最大日期，无需再同步 head
  await recordChange(c.env.DB, { entity_type: 'purchase', entity_sync_id: purchaseId, payload: await buildPayload(c.env.DB, 'purchase', purchaseId), updated_by_username: c.get('user').username });
  return c.json({ ok: true });
});

// DELETE /purchases/:id — 删除进货记录（回滚库存 + 删全部商品行，仅老板）
purchasesRouter.delete('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const oldItems = await c.env.DB.prepare(
    'SELECT item_id, unit, quantity FROM purchase_items WHERE purchase_id = ?').bind(id)
    .all<{ item_id: string; unit: string; quantity: number }>();
  // 行级凭证附件：删行前拿行 id 清理（行级附件按 purchase_item/{lineId}/ 存储）
  try {
    const lineRows = await c.env.DB.prepare('SELECT id FROM purchase_items WHERE purchase_id = ?').bind(id)
      .all<{ id: string }>();
    for (const lr of lineRows.results) {
      await deleteEntityAttachments(c.env, 'purchase_item', lr.id);
    }
  } catch (_) {}
  const batch: D1PreparedStatement[] = oldItems.results
    .map((it) => stockDelta(c.env.DB, it.item_id, it.unit, -it.quantity)); // 进货加的减回
  batch.push(c.env.DB.prepare('DELETE FROM purchase_items WHERE purchase_id = ?').bind(id));
  await c.env.DB.batch(batch);
  await recordChange(c.env.DB, { entity_type: 'purchase', entity_sync_id: id, action: 'delete', payload: {}, updated_by_username: c.get('user').username });
  await recordAudit(c.env.DB, { username: c.get('user').username, action: 'delete', entity_type: 'purchase', entity_id: id, detail: `删除进货记录（${oldItems.results.length} 件商品）` });
  // 删除进货单附带的凭证图片（单据级 + 全部明细行级，best-effort 不阻塞删除）
  try {
    await deleteEntityAttachments(c.env, 'purchase', id);
  } catch (_) {}
  return c.body(null, 204);
});