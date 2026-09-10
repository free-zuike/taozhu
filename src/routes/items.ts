/** 商品管理：items + item_prices（单位+双价组合） */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { authMiddleware, adminOnly } from '../middleware/auth';
import type { AuthUser, Env, ItemRow } from '../types';

type V = { user: AuthUser };
export const itemsRouter = new Hono<{ Bindings: Env; Variables: V }>();

itemsRouter.use('*', authMiddleware());

const nowIso = () => new Date().toISOString();

function serialize(item: ItemRow & { category?: string | null; category_name?: string | null }, prices: unknown[], canSeeCost: boolean) {
  // 员工不可见进价（purchase_price 打码，防泄露采购成本）
  const list = canSeeCost
    ? prices
    : (prices as Record<string, unknown>[]).map((p) => ({ ...p, purchase_price: 0 }));
  return {
    id: item.id, name: item.name,
    category: item.category ?? '',
    category_id: item.category_id ?? '',
    category_name: item.category_name ?? '',
    prices: list,
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
  return c.json({ items: rows.results.map((r) => serialize(r, byItem.get(r.id) ?? [], canSeeCost)) });
});

// GET /items/summary — 记单用的简化目录（id/名称/价格组合/当前库存），全员可读、不含管理字段
itemsRouter.get('/summary', async (c) => {
  const canSeeCost = c.get('user').role === 'admin';
  const rows = await c.env.DB.prepare(
    `SELECT i.id, i.name, i.category,
            (SELECT json_group_array(json_object('id', p.id, 'unit', p.unit, 'sale_price', p.sale_price, 'purchase_price', p.purchase_price,
              'stock', COALESCE((SELECT st.quantity FROM stocks st WHERE st.item_id = i.id AND st.unit = p.unit), 0)))
             FROM item_prices p WHERE p.item_id = i.id AND p.active = 1) AS prices
     FROM items i WHERE i.deleted_at IS NULL ORDER BY i.name`).all();
  const items = rows.results.map((r) => {
    const pr = (r as { prices: string | null }).prices;
    const list = pr ? (JSON.parse(pr) as Record<string, unknown>[]) : [];
    return {
      id: r.id, name: r.name, category: r.category ?? '',
      prices: canSeeCost ? list : list.map((p) => ({ ...p, purchase_price: 0 })),
    };
  });
  return c.json({ items });
});

// POST /items — 新建商品（body: {name, category?, category_id?, prices:[{unit,purchase_price,sale_price}]}）
itemsRouter.post('/', adminOnly(), async (c) => {
  const body = await c.req.json().catch(() => null) as {
    name?: string; category?: string; category_id?: string;
    prices?: Array<{ unit: string; purchase_price: number; sale_price: number }>;
  } | null;
  const name = body?.name?.trim();
  if (!name) return c.json({ error: '商品名称必填' }, 400);
  if (body?.category_id) {
    const cat = await c.env.DB.prepare('SELECT id FROM categories WHERE id = ? AND type = ?').bind(body.category_id, 'item').first();
    if (!cat) return c.json({ error: '商品分类不存在' }, 400);
  }
  const id = randomId();
  await c.env.DB.prepare('INSERT INTO items (id, name, category, category_id) VALUES (?, ?, ?, ?)')
    .bind(id, name, body?.category?.trim() ?? '', body?.category_id ?? null).run();
  const priceIds: string[] = [];
  for (const p of body?.prices ?? []) {
    const unit = p.unit?.trim();
    if (!unit) continue;
    const pid = randomId();
    await c.env.DB.prepare(
      'INSERT INTO item_prices (id, item_id, unit, purchase_price, sale_price) VALUES (?, ?, ?, ?, ?)')
      .bind(pid, id, unit, Number(p.purchase_price) || 0, Number(p.sale_price) || 0).run();
    priceIds.push(pid);
  }
  return c.json({ id, name, category: body?.category?.trim() ?? '', category_id: body?.category_id ?? '', prices: priceIds }, 201);
});

// PATCH /items/:id — 改名称/分类
itemsRouter.patch('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { name?: string; category?: string; category_id?: string | null } | null;
  const item = await c.env.DB.prepare('SELECT * FROM items WHERE id = ? AND deleted_at IS NULL').bind(id).first<ItemRow>();
  if (!item) return c.json({ error: '商品不存在' }, 404);
  if (body?.category_id) {
    const cat = await c.env.DB.prepare('SELECT id FROM categories WHERE id = ? AND type = ?').bind(body.category_id, 'item').first();
    if (!cat) return c.json({ error: '商品分类不存在' }, 400);
  }
  const name = body?.name?.trim();
  await c.env.DB.prepare('UPDATE items SET name = ?, category = ?, category_id = ? WHERE id = ?')
    .bind(
      name || item.name,
      body?.category?.trim() ?? item.category ?? '',
      body?.category_id !== undefined ? body.category_id : item.category_id,
      id,
    ).run();
  return c.json({ id, name: name || item.name, category: body?.category?.trim() ?? item.category ?? '' });
});

// DELETE /items/:id — 软删
itemsRouter.delete('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  await c.env.DB.prepare(
    'UPDATE items SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL').bind(nowIso(), id).run();
  await c.env.DB.prepare('UPDATE item_prices SET active = 0 WHERE item_id = ?').bind(id).run();
  return c.body(null, 204);
});

// POST /items/:id/prices — 新增单位+双价
itemsRouter.post('/:id/prices', adminOnly(), async (c) => {
  const itemId = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { unit?: string; purchase_price?: number; sale_price?: number } | null;
  const unit = body?.unit?.trim();
  if (!unit) return c.json({ error: '单位必填' }, 400);
  const id = randomId();
  await c.env.DB.prepare(
    'INSERT INTO item_prices (id, item_id, unit, purchase_price, sale_price) VALUES (?, ?, ?, ?, ?)')
    .bind(id, itemId, unit, Number(body?.purchase_price) || 0, Number(body?.sale_price) || 0).run();
  return c.json({ id, item_id: itemId, unit, purchase_price: Number(body?.purchase_price) || 0, sale_price: Number(body?.sale_price) || 0 }, 201);
});

// PATCH /item-prices/:id — 改价
itemsRouter.patch('/item-prices/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { unit?: string; purchase_price?: number; sale_price?: number; active?: number } | null;
  const price = await c.env.DB.prepare('SELECT * FROM item_prices WHERE id = ?').bind(id).first();
  if (!price) return c.json({ error: '价格不存在' }, 404);
  await c.env.DB.prepare(
    'UPDATE item_prices SET unit = ?, purchase_price = ?, sale_price = ?, active = ? WHERE id = ?')
    .bind(
      body?.unit?.trim() ?? (price as { unit: string }).unit,
      body?.purchase_price !== undefined ? Number(body.purchase_price) : (price as { purchase_price: number }).purchase_price,
      body?.sale_price !== undefined ? Number(body.sale_price) : (price as { sale_price: number }).sale_price,
      body?.active !== undefined ? Number(body.active) : 1,
      id,
    ).run();
  return c.json({ ok: true });
});

// DELETE /item-prices/:id — 停用该单位价
itemsRouter.delete('/item-prices/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  await c.env.DB.prepare('UPDATE item_prices SET active = 0 WHERE id = ?').bind(id).run();
  return c.body(null, 204);
});