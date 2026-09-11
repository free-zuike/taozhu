/** 分类管理：商品分类(type=item) / 店铺分类(type=client)，支持两级（如 店铺 → 火锅店） */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { authMiddleware, adminOnly } from '../middleware/auth';
import { buildPayload, recordChange } from '../lib/sync';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const categoriesRouter = new Hono<{ Bindings: Env; Variables: V }>();
categoriesRouter.use('*', authMiddleware());

interface CategoryRow {
  id: string;
  type: string;
  name: string;
  parent_id: string | null;
  sort: number;
}

const VALID_TYPES = ['item', 'client'] as const;
type CategoryType = (typeof VALID_TYPES)[number];

function isType(v: unknown): v is CategoryType {
  return v === 'item' || v === 'client';
}

/** 校验父分类：必须存在、同 type、且本身是一级（防三级） */
async function checkParent(db: D1Database, type: CategoryType, parentId: string): Promise<string | null> {
  const parent = await db.prepare(
    'SELECT * FROM categories WHERE id = ? AND type = ?').bind(parentId, type).first<CategoryRow>();
  if (!parent) return '父分类不存在';
  if (parent.parent_id) return '最多支持两级分类';
  return null;
}

// GET /categories?type=item|client — 平铺列表（一级+二级），前端自行分组
categoriesRouter.get('/', async (c) => {
  const type = c.req.query('type');
  if (!isType(type)) return c.json({ error: 'type 必须为 item 或 client' }, 400);
  const rows = await c.env.DB.prepare(
    'SELECT id, type, name, parent_id, sort FROM categories WHERE type = ? ORDER BY sort, name').bind(type).all<CategoryRow>();
  return c.json({ categories: rows.results });
});

// POST /categories — 新建分类 {type, name, parent_id?}
categoriesRouter.post('/', adminOnly(), async (c) => {
  const body = await c.req.json().catch(() => null) as { type?: string; name?: string; parent_id?: string } | null;
  if (!isType(body?.type)) return c.json({ error: 'type 必须为 item 或 client' }, 400);
  const name = body?.name?.trim();
  if (!name) return c.json({ error: '分类名称必填' }, 400);
  if (body?.parent_id) {
    const err = await checkParent(c.env.DB, body.type, body.parent_id);
    if (err) return c.json({ error: err }, 400);
  }
  const id = randomId();
  await c.env.DB.prepare('INSERT INTO categories (id, type, name, parent_id) VALUES (?, ?, ?, ?)')
    .bind(id, body.type, name, body.parent_id ?? null).run();
  await recordChange(c.env.DB, { entity_type: 'category', entity_sync_id: id, payload: await buildPayload(c.env.DB, 'category', id), updated_by_username: c.get('user').username });
  return c.json({ id, type: body.type, name, parent_id: body.parent_id ?? null }, 201);
});

// PATCH /categories/:id — 改名 / 移动父级
categoriesRouter.patch('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { name?: string; parent_id?: string | null } | null;
  const cat = await c.env.DB.prepare('SELECT * FROM categories WHERE id = ?').bind(id).first<CategoryRow>();
  if (!cat) return c.json({ error: '分类不存在' }, 404);
  if (body?.parent_id !== undefined && body.parent_id !== null) {
    if (body.parent_id === id) return c.json({ error: '不能把自身设为父分类' }, 400);
    const err = await checkParent(c.env.DB, cat.type as CategoryType, body.parent_id);
    if (err) return c.json({ error: err }, 400);
    const child = await c.env.DB.prepare('SELECT id FROM categories WHERE parent_id = ? LIMIT 1').bind(id).first();
    if (child) return c.json({ error: '该分类下有子分类，不能降为二级' }, 400);
  }
  const name = body?.name?.trim();
  await c.env.DB.prepare('UPDATE categories SET name = ?, parent_id = ? WHERE id = ?')
    .bind(name || cat.name, body?.parent_id !== undefined ? body.parent_id : cat.parent_id, id).run();
  await recordChange(c.env.DB, { entity_type: 'category', entity_sync_id: id, payload: await buildPayload(c.env.DB, 'category', id), updated_by_username: c.get('user').username });
  return c.json({ ok: true });
});

// DELETE /categories/:id — 有子分类拒绝；被商品/店铺引用时把引用置空后删除
categoriesRouter.delete('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const cat = await c.env.DB.prepare('SELECT * FROM categories WHERE id = ?').bind(id).first<CategoryRow>();
  if (!cat) return c.json({ error: '分类不存在' }, 404);
  const child = await c.env.DB.prepare('SELECT id FROM categories WHERE parent_id = ? LIMIT 1').bind(id).first();
  if (child) return c.json({ error: '请先删除该分类下的子分类' }, 409);
  if (cat.type === 'client') {
    await c.env.DB.prepare('UPDATE clients SET category_id = NULL WHERE category_id = ?').bind(id).run();
  } else {
    // 同时清掉 items.category 冗余文本，避免列表残留旧分类名
    await c.env.DB.prepare("UPDATE items SET category_id = NULL, category = '' WHERE category_id = ?").bind(id).run();
  }
  await c.env.DB.prepare('DELETE FROM categories WHERE id = ?').bind(id).run();
  await recordChange(c.env.DB, { entity_type: 'category', entity_sync_id: id, action: 'delete', payload: {}, updated_by_username: c.get('user').username });
  return c.body(null, 204);
});
