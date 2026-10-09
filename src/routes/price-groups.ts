/** 价格组（店铺等级→取价档）：CRUD + 同步变更流 */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { authMiddleware, adminOnly } from '../middleware/auth';
import { buildPayload, recordChange } from '../lib/sync';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const priceGroupsRouter = new Hono<{ Bindings: Env; Variables: V }>();

priceGroupsRouter.use('*', authMiddleware());

const nowIso = () => new Date().toISOString();

// GET /price-groups — 价格组列表（含已删？不含，软删即隐藏；店铺引用 price_group_id 指向已删组时显示「（已停用）」由前端兜底）
priceGroupsRouter.get('/', async (c) => {
  const rows = await c.env.DB.prepare('SELECT id, name, sort FROM price_groups WHERE deleted_at IS NULL ORDER BY sort, name').all();
  return c.json({ price_groups: rows.results });
});

// POST /price-groups — 新建（body: {name}）
priceGroupsRouter.post('/', adminOnly(), async (c) => {
  const body = await c.req.json().catch(() => null) as { name?: string } | null;
  const name = body?.name?.trim();
  if (!name) return c.json({ error: '价格组名称必填' }, 400);
  const maxRow = await c.env.DB.prepare('SELECT COALESCE(MAX(sort), -1) + 1 AS next FROM price_groups WHERE deleted_at IS NULL').first<{ next: number }>();
  const id = randomId();
  const sort = maxRow?.next ?? 0;
  await c.env.DB.prepare('INSERT INTO price_groups (id, name, sort) VALUES (?, ?, ?)').bind(id, name, sort).run();
  await recordChange(c.env.DB, { entity_type: 'price_group', entity_sync_id: id, payload: await buildPayload(c.env.DB, 'price_group', id), updated_by_username: c.get('user').username });
  return c.json({ id, name, sort }, 201);
});

// PATCH /price-groups/:id — 改名/排序
priceGroupsRouter.patch('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { name?: string; sort?: number } | null;
  const group = await c.env.DB.prepare('SELECT * FROM price_groups WHERE id = ? AND deleted_at IS NULL').bind(id).first<{ name: string; sort: number }>();
  if (!group) return c.json({ error: '价格组不存在' }, 404);
  const name = body?.name?.trim();
  await c.env.DB.prepare('UPDATE price_groups SET name = ?, sort = ? WHERE id = ?')
    .bind(name || group.name, body?.sort !== undefined ? Number(body.sort) : group.sort, id).run();
  await recordChange(c.env.DB, { entity_type: 'price_group', entity_sync_id: id, payload: await buildPayload(c.env.DB, 'price_group', id), updated_by_username: c.get('user').username });
  return c.json({ ok: true });
});

// DELETE /price-groups/:id — 软删（店铺引用清空；商品组价保留但取价时按引用不到跳过）
priceGroupsRouter.delete('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const group = await c.env.DB.prepare('SELECT name FROM price_groups WHERE id = ? AND deleted_at IS NULL').bind(id).first<{ name: string }>();
  if (group) {
    await c.env.DB.prepare('UPDATE price_groups SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL').bind(nowIso(), id).run();
    await c.env.DB.prepare('UPDATE clients SET price_group_id = NULL WHERE price_group_id = ?').bind(id).run();
    await recordChange(c.env.DB, { entity_type: 'price_group', entity_sync_id: id, payload: await buildPayload(c.env.DB, 'price_group', id), updated_by_username: c.get('user').username });
  }
  return c.body(null, 204);
});
