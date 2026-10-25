/** 商品管理：items + item_prices（单位+双价组合）+ item_group_prices（价格组售价） */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { authMiddleware, adminOnly } from '../middleware/auth';
import { buildPayload, recordChange } from '../lib/sync';
import { recordAudit } from './audit';
import type { AuthUser, Env, ItemRow } from '../types';

type V = { user: AuthUser };
export const itemsRouter = new Hono<{ Bindings: Env; Variables: V }>();

itemsRouter.use('*', authMiddleware());

/** 记录商品变更（价格组合改动也视为商品整体变更，payload 为最新快照） */
async function noteItemChange(db: D1Database, itemId: string, username: string): Promise<void> {
  const payload = await buildPayload(db, 'item', itemId);
  if (payload) await recordChange(db, { entity_type: 'item', entity_sync_id: itemId, payload, updated_by_username: username });
}

const nowIso = () => new Date().toISOString();

function serialize(item: ItemRow & { category?: string | null; category_name?: string | null }, prices: unknown[], groupPrices: unknown[], canSeeCost: boolean) {
  // 员工不可见进价（purchase_price 打码，防泄露采购成本）；价格组售价非成本可全见
  const list = canSeeCost
    ? prices
    : (prices as Record<string, unknown>[]).map((p) => ({ ...p, purchase_price: 0 }));
  return {
    id: item.id, name: item.name,
    category: item.category ?? '',
    category_id: item.category_id ?? '',
    category_name: item.category_name ?? '',
    count_unit: item.count_unit ?? '',
    prices: list,
    group_prices: groupPrices,
  };
}

// GET /items?q= — 商品列表（含价格组合，不含已删）
itemsRouter.get('/', async (c) => {
  const canSeeCost = c.get('user').role === 'admin';
  const q = c.req.query('q')?.trim() ?? '';
  const rows = q
    ? await c.env.DB.prepare(
        'SELECT i.*, cat.name AS category_name FROM items i LEFT JOIN categories cat ON cat.id = i.category_id WHERE i.deleted_at IS NULL AND i.name LIKE ? ORDER BY i.name').bind(`%${q}%`).all<ItemRow & { category_name: string | null }>()
    : await c.env.DB.prepare(
        'SELECT i.*, cat.name AS category_name FROM items i LEFT JOIN categories cat ON cat.id = i.category_id WHERE i.deleted_at IS NULL ORDER BY i.name').all<ItemRow & { category_name: string | null }>();
  const priceRows = await c.env.DB.prepare(
    'SELECT * FROM item_prices WHERE active = 1 AND item_id IN (SELECT id FROM items WHERE deleted_at IS NULL) ORDER BY unit').all();
  const byItem = new Map<string, unknown[]>();
  for (const p of priceRows.results) {
    const list = byItem.get((p as { item_id: string }).item_id) ?? [];
    list.push(p);
    byItem.set((p as { item_id: string }).item_id, list);
  }
  const groupPriceRows = await c.env.DB.prepare(
    'SELECT * FROM item_group_prices WHERE item_id IN (SELECT id FROM items WHERE deleted_at IS NULL) ORDER BY unit, group_id').all();
  const byItemGroup = new Map<string, unknown[]>();
  for (const p of groupPriceRows.results) {
    const list = byItemGroup.get((p as { item_id: string }).item_id) ?? [];
    list.push(p);
    byItemGroup.set((p as { item_id: string }).item_id, list);
  }
  return c.json({ items: rows.results.map((r) => serialize(r, byItem.get(r.id) ?? [], byItemGroup.get(r.id) ?? [], canSeeCost)) });
});

// GET /items/summary — 记单用的简化目录（id/名称/价格组合/当前库存），全员可读、不含管理字段
itemsRouter.get('/summary', async (c) => {
  const canSeeCost = c.get('user').role === 'admin';
  const rows = await c.env.DB.prepare(
    `SELECT i.id, i.name, i.category, i.count_unit,
            (SELECT json_group_array(json_object('id', p.id, 'unit', p.unit, 'sale_price', p.sale_price, 'purchase_price', p.purchase_price, 'per', p.per,
              'stock', COALESCE((SELECT CASE WHEN st.quantity < 0 THEN 0 ELSE st.quantity END FROM stocks st WHERE st.item_id = i.id AND st.unit = p.unit), 0)))
             FROM item_prices p WHERE p.item_id = i.id AND p.active = 1) AS prices,
            (SELECT json_group_array(json_object('id', gp.id, 'unit', gp.unit, 'group_id', gp.group_id, 'sale_price', gp.sale_price))
             FROM item_group_prices gp WHERE gp.item_id = i.id) AS group_prices
     FROM items i WHERE i.deleted_at IS NULL ORDER BY i.name`).all();
  const items = rows.results.map((r) => {
    const pr = (r as { prices: string | null }).prices;
    const list = pr ? (JSON.parse(pr) as Record<string, unknown>[]) : [];
    const gp = (r as { group_prices: string | null }).group_prices;
    const glist = gp ? (JSON.parse(gp) as Record<string, unknown>[]) : [];
    return {
      id: r.id, name: r.name, category: r.category ?? '', count_unit: (r as { count_unit: string | null }).count_unit ?? '',
      prices: canSeeCost ? list : list.map((p) => ({ ...p, purchase_price: 0 })),
      group_prices: glist,
    };
  });
  return c.json({ items });
});

// GET /items/:id — 单商品详情（分类兜底/编辑预填用；已软删返回 404）
itemsRouter.get('/:id', async (c) => {
  const id = c.req.param('id');
  const canSeeCost = c.get('user').role === 'admin';
  const row = await c.env.DB.prepare(
    'SELECT i.*, cat.name AS category_name FROM items i LEFT JOIN categories cat ON cat.id = i.category_id WHERE i.id = ? AND i.deleted_at IS NULL',
  ).bind(id).first<Record<string, unknown>>();
  if (!row) return c.json({ error: '商品不存在' }, 404);
  const prices = await c.env.DB.prepare(
    'SELECT * FROM item_prices WHERE item_id = ? AND active = 1 ORDER BY unit').bind(id).all();
  const groupPrices = await c.env.DB.prepare(
    'SELECT * FROM item_group_prices WHERE item_id = ? ORDER BY unit, group_id').bind(id).all();
  return c.json({ item: serialize(row as never, prices.results, groupPrices.results, canSeeCost) });
});

// POST /items — 新建商品（body: {name, category?, category_id?, count_unit?, prices:[{unit,purchase_price,sale_price,per?}], group_prices?:[{unit,group_id,sale_price}]}）
itemsRouter.post('/', adminOnly(), async (c) => {
  const body = await c.req.json().catch(() => null) as {
    name?: string; category?: string; category_id?: string; count_unit?: string;
    prices?: Array<{ unit: string; purchase_price: number; sale_price: number; per?: number }>;
    group_prices?: Array<{ unit: string; group_id: string; sale_price: number }>;
  } | null;
  const name = body?.name?.trim();
  if (!name) return c.json({ error: '商品名称必填' }, 400);
  if (body?.category_id) {
    const cat = await c.env.DB.prepare('SELECT id FROM categories WHERE id = ? AND type = ?').bind(body.category_id, 'item').first();
    if (!cat) return c.json({ error: '商品分类不存在' }, 400);
  }
  const id = randomId();
  await c.env.DB.prepare('INSERT INTO items (id, name, category, category_id, count_unit) VALUES (?, ?, ?, ?, ?)')
    .bind(id, name, body?.category?.trim() ?? '', body?.category_id ?? null, body?.count_unit?.trim() ?? '').run();
  const priceIds: string[] = [];
  for (const p of body?.prices ?? []) {
    const unit = p.unit?.trim();
    if (!unit) continue;
    const pid = randomId();
    const per = Number(p.per);
    await c.env.DB.prepare(
      'INSERT INTO item_prices (id, item_id, unit, purchase_price, sale_price, per) VALUES (?, ?, ?, ?, ?, ?)')
      .bind(pid, id, unit, Number(p.purchase_price) || 0, Number(p.sale_price) || 0, per > 0 ? per : null).run();
    priceIds.push(pid);
  }
  for (const gp of body?.group_prices ?? []) {
    const unit = gp.unit?.trim();
    if (!unit || !gp.group_id) continue;
    await c.env.DB.prepare(
      'INSERT INTO item_group_prices (id, item_id, unit, group_id, sale_price) VALUES (?, ?, ?, ?, ?)')
      .bind(randomId(), id, unit, gp.group_id, Number(gp.sale_price) || 0).run();
  }
  await noteItemChange(c.env.DB, id, c.get('user').username);
  return c.json({ id, name, category: body?.category?.trim() ?? '', category_id: body?.category_id ?? '', count_unit: body?.count_unit?.trim() ?? '', prices: priceIds }, 201);
});

// PATCH /items/:id — 改名称/分类/计数单位
itemsRouter.patch('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { name?: string; category?: string; category_id?: string | null; count_unit?: string } | null;
  const item = await c.env.DB.prepare('SELECT * FROM items WHERE id = ? AND deleted_at IS NULL').bind(id).first<ItemRow>();
  if (!item) return c.json({ error: '商品不存在' }, 404);
  if (body?.category_id) {
    const cat = await c.env.DB.prepare('SELECT id FROM categories WHERE id = ? AND type = ?').bind(body.category_id, 'item').first();
    if (!cat) return c.json({ error: '商品分类不存在' }, 400);
  }
  const name = body?.name?.trim();
  await c.env.DB.prepare('UPDATE items SET name = ?, category = ?, category_id = ?, count_unit = ? WHERE id = ?')
    .bind(
      name || item.name,
      body?.category?.trim() ?? item.category ?? '',
      body?.category_id !== undefined ? body.category_id : item.category_id,
      body?.count_unit !== undefined ? body.count_unit.trim() : item.count_unit ?? '',
      id,
    ).run();
  await noteItemChange(c.env.DB, id, c.get('user').username);
  return c.json({ id, name: name || item.name, category: body?.category?.trim() ?? item.category ?? '', count_unit: body?.count_unit !== undefined ? body.count_unit.trim() : item.count_unit ?? '' });
});

// DELETE /items/:id — 软删
itemsRouter.delete('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  // 审计留痕带商品名（删除后目录不可见，名称在删除时快照）
  const item = await c.env.DB.prepare('SELECT name FROM items WHERE id = ? AND deleted_at IS NULL').bind(id).first<{ name: string }>();
  await c.env.DB.prepare(
    'UPDATE items SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL').bind(nowIso(), id).run();
  await c.env.DB.prepare('UPDATE item_prices SET active = 0 WHERE item_id = ?').bind(id).run();
  await noteItemChange(c.env.DB, id, c.get('user').username);
  await recordAudit(c.env.DB, { username: c.get('user').username, action: 'delete', entity_type: 'item', entity_id: id, detail: item ? `删除商品：${item.name}` : '删除商品（已不存在）' });
  return c.body(null, 204);
});

// POST /items/:id/prices — 新增单位+双价（per：该单位 1 单位折合计数单位数，如 1 箱=40 袋；空=不折）
itemsRouter.post('/:id/prices', adminOnly(), async (c) => {
  const itemId = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { unit?: string; purchase_price?: number; sale_price?: number; per?: number } | null;
  const unit = body?.unit?.trim();
  if (!unit) return c.json({ error: '单位必填' }, 400);
  const id = randomId();
  const per = Number(body?.per);
  await c.env.DB.prepare(
    'INSERT INTO item_prices (id, item_id, unit, purchase_price, sale_price, per) VALUES (?, ?, ?, ?, ?, ?)')
    .bind(id, itemId, unit, Number(body?.purchase_price) || 0, Number(body?.sale_price) || 0, per > 0 ? per : null).run();
  await noteItemChange(c.env.DB, itemId, c.get('user').username);
  return c.json({ id, item_id: itemId, unit, purchase_price: Number(body?.purchase_price) || 0, sale_price: Number(body?.sale_price) || 0, per: per > 0 ? per : null }, 201);
});

// PATCH /item-prices/:id — 改价/改折合数
itemsRouter.patch('/item-prices/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { unit?: string; purchase_price?: number; sale_price?: number; active?: number; per?: number | null } | null;
  const price = await c.env.DB.prepare('SELECT * FROM item_prices WHERE id = ?').bind(id).first();
  if (!price) return c.json({ error: '价格不存在' }, 404);
  const per = body?.per !== undefined ? (Number(body.per) > 0 ? Number(body.per) : null) : (price as { per: number | null }).per ?? null;
  await c.env.DB.prepare(
    'UPDATE item_prices SET unit = ?, purchase_price = ?, sale_price = ?, active = ?, per = ? WHERE id = ?')
    .bind(
      body?.unit?.trim() ?? (price as { unit: string }).unit,
      body?.purchase_price !== undefined ? Number(body.purchase_price) : (price as { purchase_price: number }).purchase_price,
      body?.sale_price !== undefined ? Number(body.sale_price) : (price as { sale_price: number }).sale_price,
      body?.active !== undefined ? Number(body.active) : 1,
      per,
      id,
    ).run();
  await noteItemChange(c.env.DB, (price as { item_id: string }).item_id, c.get('user').username);
  return c.json({ ok: true });
});

// DELETE /item-prices/:id — 停用该单位价
itemsRouter.delete('/item-prices/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const price = await c.env.DB.prepare('SELECT item_id FROM item_prices WHERE id = ?').bind(id).first<{ item_id: string }>();
  if (price) {
    await c.env.DB.prepare('UPDATE item_prices SET active = 0 WHERE id = ?').bind(id).run();
    await noteItemChange(c.env.DB, price.item_id, c.get('user').username);
  }
  return c.body(null, 204);
});

// POST /items/:id/group-prices — 新增该商品某价格组某单位售价（body: {unit, group_id, sale_price}）
itemsRouter.post('/:id/group-prices', adminOnly(), async (c) => {
  const itemId = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { unit?: string; group_id?: string; sale_price?: number } | null;
  const unit = body?.unit?.trim();
  const groupId = body?.group_id?.trim();
  if (!unit || !groupId) return c.json({ error: '单位与价格组必填' }, 400);
  const group = await c.env.DB.prepare('SELECT id FROM price_groups WHERE id = ? AND deleted_at IS NULL').bind(groupId).first();
  if (!group) return c.json({ error: '价格组不存在' }, 400);
  const id = randomId();
  await c.env.DB.prepare(
    'INSERT INTO item_group_prices (id, item_id, unit, group_id, sale_price) VALUES (?, ?, ?, ?, ?)')
    .bind(id, itemId, unit, groupId, Number(body?.sale_price) || 0).run();
  await noteItemChange(c.env.DB, itemId, c.get('user').username);
  return c.json({ id, item_id: itemId, unit, group_id: groupId, sale_price: Number(body?.sale_price) || 0 }, 201);
});

// PATCH /item-group-prices/:id — 改该价格组售价
itemsRouter.patch('/item-group-prices/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { unit?: string; group_id?: string; sale_price?: number } | null;
  const gp = await c.env.DB.prepare('SELECT * FROM item_group_prices WHERE id = ?').bind(id).first<{ item_id: string; unit: string; group_id: string }>();
  if (!gp) return c.json({ error: '价格不存在' }, 404);
  if (body?.group_id) {
    const group = await c.env.DB.prepare('SELECT id FROM price_groups WHERE id = ? AND deleted_at IS NULL').bind(body.group_id).first();
    if (!group) return c.json({ error: '价格组不存在' }, 400);
  }
  await c.env.DB.prepare('UPDATE item_group_prices SET unit = ?, group_id = ?, sale_price = ? WHERE id = ?')
    .bind(
      body?.unit?.trim() || gp.unit,
      body?.group_id?.trim() || gp.group_id,
      body?.sale_price !== undefined ? Number(body.sale_price) : (await c.env.DB.prepare('SELECT sale_price FROM item_group_prices WHERE id = ?').bind(id).first<{ sale_price: number }>())?.sale_price ?? 0,
      id,
    ).run();
  await noteItemChange(c.env.DB, gp.item_id, c.get('user').username);
  return c.json({ ok: true });
});

// DELETE /item-group-prices/:id — 删除该价格组售价
itemsRouter.delete('/item-group-prices/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const gp = await c.env.DB.prepare('SELECT item_id FROM item_group_prices WHERE id = ?').bind(id).first<{ item_id: string }>();
  if (gp) {
    await c.env.DB.prepare('DELETE FROM item_group_prices WHERE id = ?').bind(id).run();
    await noteItemChange(c.env.DB, gp.item_id, c.get('user').username);
  }
  return c.body(null, 204);
});

// ---------------------------------------------------------------------------
// 批量调价（v0.17.473）：一次选多个商品，按百分比/固定值整体调进价/售价（价格组售价联动可选）。
// 两段式：preview 返回"原价→新价"清单（执行前确认），执行时服务端重算（不信任预览值）。
// ---------------------------------------------------------------------------

interface BulkPriceBody {
  item_ids?: string[];
  field?: 'sale_price' | 'purchase_price' | 'both';
  mode?: 'percent' | 'fixed';
  value?: number;
  apply_group_prices?: boolean;
}

function calcNewPrice(old: number, mode: 'percent' | 'fixed', value: number): number {
  const v = mode === 'percent' ? old * (1 + value / 100) : old + value;
  return Math.round(v * 100) / 100;
}

/** 校验批量调价请求；非法返回错误信息，合法返回规范化参数 */
function parseBulkPrice(body: BulkPriceBody | null): { err?: string; field: 'sale_price' | 'purchase_price' | 'both'; mode: 'percent' | 'fixed'; value: number; applyGroup: boolean; itemIds: string[] } {
  const itemIds = (body?.item_ids ?? []).map((x) => String(x).trim()).filter((x) => x.length > 0);
  if (itemIds.length === 0) return { err: '未选择商品', field: 'sale_price', mode: 'percent', value: 0, applyGroup: true, itemIds };
  const field = body?.field ?? 'sale_price';
  if (!['sale_price', 'purchase_price', 'both'].includes(field)) return { err: '调价字段不合法（sale_price/purchase_price/both）', field: 'sale_price', mode: 'percent', value: 0, applyGroup: true, itemIds };
  const mode = body?.mode ?? 'percent';
  if (!['percent', 'fixed'].includes(mode)) return { err: '调价方式不合法（percent/fixed）', field, mode: 'percent', value: 0, applyGroup: true, itemIds };
  const value = Number(body?.value);
  if (!Number.isFinite(value)) return { err: '调价数值不合法', field, mode, value: 0, applyGroup: true, itemIds };
  if (mode === 'percent' && (value < -100 || value > 1000)) return { err: '百分比范围应为 -100 ~ 1000', field, mode, value, applyGroup: true, itemIds };
  if (mode === 'fixed' && (value < -1000000 || value > 1000000)) return { err: '固定值超出合理范围', field, mode, value, applyGroup: true, itemIds };
  return { field, mode, value, applyGroup: body?.apply_group_prices !== false, itemIds };
}

// POST /items/bulk-price/preview — 批量调价预览（不落库）：返回每个价格行/价格组行的 原价→新价
itemsRouter.post('/bulk-price/preview', adminOnly(), async (c) => {
  const body = await c.req.json().catch(() => null) as BulkPriceBody | null;
  const p = parseBulkPrice(body);
  if (p.err) return c.json({ error: p.err }, 400);
  const ids = p.itemIds;
  const itemName = new Map((await c.env.DB.prepare(
    `SELECT id, name FROM items WHERE id IN (${ids.map(() => '?').join(',')}) AND deleted_at IS NULL`,
  ).bind(...ids).all<{ id: string; name: string }>()).results.map((r) => [r.id, r.name]));
  const validIds = [...itemName.keys()];
  if (validIds.length === 0) return c.json({ error: '所选商品不存在或已删除' }, 400);
  const rows = (await c.env.DB.prepare(
    `SELECT * FROM item_prices WHERE active = 1 AND item_id IN (${validIds.map(() => '?').join(',')}) ORDER BY unit`,
  ).bind(...validIds).all()).results.map((r) => {
    const x = r as { id: string; item_id: string; unit: string; purchase_price: number; sale_price: number };
    const saleNew = p.field === 'purchase_price' ? x.sale_price : calcNewPrice(Number(x.sale_price) || 0, p.mode, p.value);
    const purchaseNew = p.field === 'sale_price' ? x.purchase_price : calcNewPrice(Number(x.purchase_price) || 0, p.mode, p.value);
    return {
      price_id: x.id, item_id: x.item_id, item_name: itemName.get(x.item_id) ?? '', unit: x.unit,
      old_sale: Number(x.sale_price) || 0, new_sale: saleNew,
      old_purchase: Number(x.purchase_price) || 0, new_purchase: purchaseNew,
    };
  });
  const groupRows = p.applyGroup
    ? (await c.env.DB.prepare(
      `SELECT gp.*, g.name AS group_name FROM item_group_prices gp JOIN price_groups g ON g.id = gp.group_id
       WHERE gp.item_id IN (${validIds.map(() => '?').join(',')}) ORDER BY gp.unit, gp.group_id`,
    ).bind(...validIds).all()).results.map((r) => {
      const x = r as { id: string; item_id: string; unit: string; group_id: string; group_name: string; sale_price: number };
      return {
        price_id: x.id, item_id: x.item_id, item_name: itemName.get(x.item_id) ?? '', unit: x.unit,
        group_id: x.group_id, group_name: x.group_name,
        old: Number(x.sale_price) || 0, new: calcNewPrice(Number(x.sale_price) || 0, p.mode, p.value),
      };
    })
    : [];
  return c.json({ items: validIds.length, rows, group_rows: groupRows });
});

// POST /items/bulk-price — 批量调价执行：按规则重算并落库（item_prices + 可选价格组售价），
// 逐商品记变更流（App/小程序本地价格目录同步更新）+ 审计留痕
itemsRouter.post('/bulk-price', adminOnly(), async (c) => {
  const body = await c.req.json().catch(() => null) as BulkPriceBody | null;
  const p = parseBulkPrice(body);
  if (p.err) return c.json({ error: p.err }, 400);
  const ids = p.itemIds;
  const itemName = new Map((await c.env.DB.prepare(
    `SELECT id, name FROM items WHERE id IN (${ids.map(() => '?').join(',')}) AND deleted_at IS NULL`,
  ).bind(...ids).all<{ id: string; name: string }>()).results.map((r) => [r.id, r.name]));
  const validIds = [...itemName.keys()];
  if (validIds.length === 0) return c.json({ error: '所选商品不存在或已删除' }, 400);
  // 落库（服务端重算，与预览同规则）
  const priceRows = await c.env.DB.prepare(
    `SELECT * FROM item_prices WHERE active = 1 AND item_id IN (${validIds.map(() => '?').join(',')})`,
  ).bind(...validIds).all();
  const stmts: D1PreparedStatement[] = [];
  let changedPrices = 0;
  for (const r of priceRows.results) {
    const x = r as { id: string; sale_price: number; purchase_price: number };
    const saleNew = p.field === 'purchase_price' ? Number(x.sale_price) || 0 : calcNewPrice(Number(x.sale_price) || 0, p.mode, p.value);
    const purchaseNew = p.field === 'sale_price' ? Number(x.purchase_price) || 0 : calcNewPrice(Number(x.purchase_price) || 0, p.mode, p.value);
    if (saleNew === (Number(x.sale_price) || 0) && purchaseNew === (Number(x.purchase_price) || 0)) continue;
    stmts.push(c.env.DB.prepare('UPDATE item_prices SET sale_price = ?, purchase_price = ? WHERE id = ?')
      .bind(saleNew, purchaseNew, x.id));
    changedPrices += 1;
  }
  if (p.applyGroup) {
    const groupRows = await c.env.DB.prepare(
      `SELECT id, sale_price FROM item_group_prices WHERE item_id IN (${validIds.map(() => '?').join(',')})`,
    ).bind(...validIds).all();
    for (const r of groupRows.results) {
      const x = r as { id: string; sale_price: number };
      const gNew = calcNewPrice(Number(x.sale_price) || 0, p.mode, p.value);
      if (gNew === (Number(x.sale_price) || 0)) continue;
      stmts.push(c.env.DB.prepare('UPDATE item_group_prices SET sale_price = ? WHERE id = ?').bind(gNew, x.id));
      changedPrices += 1;
    }
  }
  if (stmts.length === 0) return c.json({ ok: true, items: validIds.length, changed: 0, message: '价格未变化' });
  await c.env.DB.batch(stmts);
  // 逐商品变更流（价格目录同步到 App/小程序本地）
  for (const id of validIds) await noteItemChange(c.env.DB, id, c.get('user').username);
  await recordAudit(c.env.DB, {
    username: c.get('user').username, action: 'bulk_price', entity_type: 'item',
    detail: `批量调价：${validIds.length} 个商品${p.field === 'both' ? '（进价+售价）' : p.field === 'purchase_price' ? '（进价）' : '（售价）'}，${p.mode === 'percent' ? `${p.value > 0 ? '+' : ''}${p.value}%` : `±${p.value}元`}${p.applyGroup ? '（含价格组）' : ''}，共改 ${changedPrices} 条价格`,
  });
  return c.json({ ok: true, items: validIds.length, changed: changedPrices });
});