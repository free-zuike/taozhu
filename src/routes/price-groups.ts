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

// POST /price-groups/:id/summarize — 从现有店铺销售记录总结每商品最近成交单价，填充该价格组售价
// （用户"从现有的店铺中总结金额，懒得去一个一个设置了"）
// body: { client_id?: string（不传=全部店铺的销售记录）, mode?: 'fill'|'overwrite' }
//   fill=只补缺（已有组价不动，安全默认）；overwrite=按最近成交价覆盖该商品×单位已有组价。
// 规则：每个 (item_id, unit) 取**最近一次**成交单价（happened_at 最新；同日取行序大者）。
// 结果走 items 变更流（item payload 含 group_prices，受影响商品逐个 recordChange）。
priceGroupsRouter.post('/:id/summarize', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { client_id?: string; mode?: string } | null;
  const group = await c.env.DB.prepare('SELECT id FROM price_groups WHERE id = ? AND deleted_at IS NULL').bind(id).first<{ id: string }>();
  if (!group) return c.json({ error: '价格组不存在' }, 404);
  const clientId = body?.client_id?.trim() || '';
  const overwrite = body?.mode === 'overwrite';
  if (clientId) {
    const client = await c.env.DB.prepare('SELECT id FROM clients WHERE id = ? AND deleted_at IS NULL').bind(clientId).first();
    if (!client) return c.json({ error: '店铺不存在' }, 404);
  }
  // 参考价：每 (item_id, unit) 最新一条成交单价（first-wins，JS 去重）
  const sql = clientId
    ? 'SELECT item_id, unit, sale_price FROM sale_items WHERE client_id = ? AND item_id IS NOT NULL AND unit IS NOT NULL ORDER BY happened_at DESC, sort DESC, id DESC'
    : 'SELECT item_id, unit, sale_price FROM sale_items WHERE item_id IS NOT NULL AND unit IS NOT NULL ORDER BY happened_at DESC, sort DESC, id DESC';
  const rows = clientId
    ? await c.env.DB.prepare(sql).bind(clientId).all<{ item_id: string; unit: string; sale_price: number }>()
    : await c.env.DB.prepare(sql).all<{ item_id: string; unit: string; sale_price: number }>();
  const ref = new Map<string, number>();
  for (const r of rows.results) {
    const key = `${r.item_id}|${r.unit}`;
    if (!ref.has(key)) ref.set(key, Number(r.sale_price) || 0);
  }
  if (ref.size === 0) {
    return c.json({ ok: true, added: 0, updated: 0, items: 0, message: '所选范围暂无销售记录可总结' });
  }
  // 现有组价（fill 模式跳过已设的商品×单位）
  const existRows = await c.env.DB.prepare(
    'SELECT id, item_id, unit, sale_price FROM item_group_prices WHERE group_id = ?',
  ).bind(id).all<{ id: string; item_id: string; unit: string; sale_price: number }>();
  const existing = new Map<string, { id: string; sale_price: number }>();
  for (const r of existRows.results) existing.set(`${r.item_id}|${r.unit}`, { id: r.id, sale_price: Number(r.sale_price) || 0 });

  const touchedItems = new Set<string>();
  const batch = [];
  let added = 0;
  let updated = 0;
  for (const [key, price] of ref) {
    if (!Number.isFinite(price) || price <= 0) continue;
    const sep = key.indexOf('|');
    const itemId = key.slice(0, sep);
    const unit = key.slice(sep + 1);
    touchedItems.add(itemId);
    const ex = existing.get(key);
    if (ex) {
      if (overwrite && Math.abs(ex.sale_price - price) > 1e-9) {
        batch.push(c.env.DB.prepare('UPDATE item_group_prices SET sale_price = ? WHERE id = ?').bind(price, ex.id));
        updated++;
      }
    } else {
      batch.push(
        c.env.DB.prepare('INSERT INTO item_group_prices (id, item_id, unit, group_id, sale_price) VALUES (?, ?, ?, ?, ?)')
          .bind(randomId(), itemId, unit, id, price),
      );
      added++;
    }
  }
  if (batch.length > 0) await c.env.DB.batch(batch);
  // 变更流：受影响商品逐个 recordChange（item payload 含 group_prices，前端同步整体替换）
  for (const itemId of touchedItems) {
    const payload = await buildPayload(c.env.DB, 'item', itemId);
    if (payload) {
      await recordChange(c.env.DB, { entity_type: 'item', entity_sync_id: itemId, payload, updated_by_username: c.get('user').username });
    }
  }
  return c.json({ ok: true, added, updated, items: touchedItems.size });
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
