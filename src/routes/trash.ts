/** 回收站（仅老板）：作废/红冲单据的快照列表、恢复、彻底删除。
 *  作废入口仍是 DELETE /sales|purchases|payments/:id?reason=...（删除前自动归档）。 */
import { Hono } from 'hono';
import { authMiddleware, adminOnly } from '../middleware/auth';
import { parsePage } from '../lib/paging';
import { applyChange, buildPayload, recordChange } from '../lib/sync';
import { expireSnapshots } from '../lib/snapshot';
import { recordAudit } from './audit';
import { entityExists, type VoidableEntity, type VoidedEntry } from '../services/voided';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const trashRouter = new Hono<{ Bindings: Env; Variables: V }>();
trashRouter.use('*', authMiddleware(), adminOnly());

const isVoidable = (s: string): s is VoidableEntity => ['sale', 'purchase', 'payment'].includes(s);

// GET /trash?entity_type=&limit=&offset= — 按作废时间倒序
trashRouter.get('/', async (c) => {
  const { limit, offset } = parsePage(c.req.query('limit'), c.req.query('offset'));
  const type = c.req.query('entity_type')?.trim() ?? '';
  if (type && !isVoidable(type)) return c.json({ error: 'entity_type 不合法' }, 400);
  const where = type ? 'WHERE entity_type = ?' : '';
  const params = type ? [type] : [];
  const total = await c.env.DB.prepare(`SELECT COUNT(*) AS cnt FROM voided_orders ${where}`)
    .bind(...params).first<{ cnt: number }>();
  const rows = await c.env.DB.prepare(
    `SELECT id, entity_type, reason, client_id, total, voided_at, voided_by FROM voided_orders
     ${where} ORDER BY voided_at DESC, id DESC LIMIT ? OFFSET ?`,
  ).bind(...params, limit, offset).all();
  return c.json({ total: total?.cnt ?? 0, items: rows.results });
});

// GET /trash/:id — 单条完整快照（前端预览用）
trashRouter.get('/:id', async (c) => {
  const row = await c.env.DB.prepare('SELECT * FROM voided_orders WHERE id = ?')
    .bind(c.req.param('id')).first<VoidedEntry>();
  if (!row) return c.json({ error: '回收站记录不存在' }, 404);
  let payload: unknown;
  try { payload = JSON.parse(row.payload); } catch (_) { payload = null; }
  return c.json({ ...row, payload });
});

// POST /trash/:id/restore — 回放快照（与 /sync/push 同一套库存/FIFO/变更流逻辑）
trashRouter.post('/:id/restore', async (c) => {
  const db = c.env.DB;
  const trashId = c.req.param('id');
  const row = await db.prepare('SELECT * FROM voided_orders WHERE id = ?').bind(trashId).first<VoidedEntry>();
  if (!row) return c.json({ error: '回收站记录不存在' }, 404);
  if (!isVoidable(row.entity_type)) return c.json({ error: '单据类型不合法' }, 400);
  let payload: Record<string, unknown>;
  try { payload = JSON.parse(row.payload) as Record<string, unknown>; } catch (_) {
    return c.json({ error: '作废快照已损坏，无法恢复' }, 400);
  }
  const orderId = String(payload.id ?? '');
  if (!orderId) return c.json({ error: '作废快照缺少单据 ID' }, 400);
  if (await entityExists(db, row.entity_type, orderId)) {
    return c.json({ error: '同 ID 单据已存在（可能已恢复或重新录入），不能覆盖' }, 409);
  }
  const res = await applyChange(db, c.env, {
    entity_type: row.entity_type, entity_sync_id: orderId, action: 'upsert', payload,
  }, c.get('user').username);
  if (!res.ok) return c.json({ error: res.error ?? '恢复失败' }, 400);

  // 进货恢复：applyChange 只重建行与库存，不建 FIFO 批次；补建以免后续成本快照丢失。
  if (row.entity_type === 'purchase' && Array.isArray(payload.items)) {
    const stmts = (payload.items as Array<Record<string, unknown>>)
      .filter((it) => it?.id && it?.item_id)
      .map((it) => db.prepare(
        `INSERT OR IGNORE INTO stock_batches (batch_id, item_id, unit, price, remaining, happened_at, expiry_date)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        String(it.id), String(it.item_id), String(it.unit ?? ''),
        Number(it.purchase_price) || 0, Number(it.quantity) || 0,
        String(it.happened_at ?? payload.happened_at ?? ''), String(it.expiry_date ?? ''),
      ));
    if (stmts.length) await db.batch(stmts);
  }

  await recordChange(db, {
    entity_type: row.entity_type, entity_sync_id: orderId,
    payload: await buildPayload(db, row.entity_type, orderId),
    updated_by_username: c.get('user').username,
  });
  await expireSnapshots(db);
  await recordAudit(db, {
    username: c.get('user').username, action: 'update', entity_type: row.entity_type, entity_id: orderId,
    detail: `从回收站恢复单据（原作废原因：${row.reason || '无'}）`,
  });
  await db.prepare('DELETE FROM voided_orders WHERE id = ?').bind(trashId).run();
  return c.json({ ok: true, entity_type: row.entity_type, id: orderId });
});

// DELETE /trash/:id — 彻底清除（不可再恢复）
trashRouter.delete('/:id', async (c) => {
  const res = await c.env.DB.prepare('DELETE FROM voided_orders WHERE id = ?').bind(c.req.param('id')).run();
  if (!res.meta.changes) return c.json({ error: '回收站记录不存在' }, 404);
  return c.body(null, 204);
});
