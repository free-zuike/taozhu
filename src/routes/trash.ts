/** 回收站（仅老板）：作废/红冲单据的快照列表、恢复、彻底删除。
 *  作废入口仍是 DELETE /sales|purchases|payments/:id?reason=...（删除前自动归档）。 */
import { Hono } from 'hono';
import { authMiddleware, adminOnly } from '../middleware/auth';
import { parsePage } from '../lib/paging';
import { applyChange, buildPayload, recordChange } from '../lib/sync';
import { expireSnapshots } from '../lib/snapshot';
import { recordAudit } from './audit';
import { entityExists, type VoidableEntity, type VoidedEntry } from '../services/voided';
import { deleteEntityAttachments } from '../lib/image-key';
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
    `SELECT id, entity_type, payload, reason, client_id, total, voided_at, voided_by FROM voided_orders
     ${where} ORDER BY voided_at DESC, id DESC LIMIT ? OFFSET ?`,
  ).bind(...params, limit, offset).all<{
    id: string; entity_type: string; payload: string; reason: string; client_id: string;
    total: number; voided_at: string; voided_by: string;
  }>();
  // entity_id：快照里的业务单据 id。离线恢复/彻底删除需要按 单据 id 与本地快照对账
  //（本地优先删除时 id 由客户端预生成、两边一致；历史/Web 删除也能靠它匹配）。
  const items = rows.results.map((r) => {
    let entityId = '';
    try { entityId = String((JSON.parse(r.payload) as Record<string, unknown>)?.id ?? ''); } catch (_) {}
    return {
      id: r.id, entity_id: entityId, entity_type: r.entity_type, reason: r.reason,
      client_id: r.client_id, total: r.total, voided_at: r.voided_at, voided_by: r.voided_by,
    };
  });
  return c.json({ total: total?.cnt ?? 0, items });
});

// GET /trash/find?entity_type=&entity_id= — 按业务单据 id 查归档（离线恢复/彻底删除对账用）
// 页面列表分页可能截断，不能用列表匹配；这里按 entity_type 粗筛后 JS 精确比对 payload.id。
trashRouter.get('/find', async (c) => {
  const type = c.req.query('entity_type')?.trim() ?? '';
  const eid = c.req.query('entity_id')?.trim() ?? '';
  if (!isVoidable(type)) return c.json({ error: 'entity_type 不合法' }, 400);
  if (!eid) return c.json({ error: '缺少 entity_id' }, 400);
  const rows = await c.env.DB.prepare(
    'SELECT id, payload FROM voided_orders WHERE entity_type = ? ORDER BY voided_at DESC LIMIT 500',
  ).bind(type).all<{ id: string; payload: string }>();
  for (const r of rows.results) {
    try {
      if (String((JSON.parse(r.payload) as Record<string, unknown>)?.id ?? '') === eid) {
        return c.json({ id: r.id });
      }
    } catch (_) {}
  }
  return c.json({ id: null });
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
  // 恢复后补发附件 upsert 变更：作废时附件引用/R2 文件被保留（未删），但执行删除的客户端
  // 写过本地删除墓碑——没有 upsert 变更墓碑不会自动清除，恢复后的凭证仍被墓碑挡住不显示。
  try {
    const lineEntity = row.entity_type === 'sale' ? 'sale_item'
      : row.entity_type === 'purchase' ? 'purchase_item' : '';
    const lineTable = row.entity_type === 'sale' ? 'sale_items'
      : row.entity_type === 'purchase' ? 'purchase_items' : '';
    const refs: Array<{ entity: string; entity_id: string; file_key: string }> = [];
    const orderRefs = await db.prepare(
      'SELECT entity, entity_id, file_key FROM attachment_refs WHERE entity = ? AND entity_id = ?',
    ).bind(row.entity_type, orderId).all<{ entity: string; entity_id: string; file_key: string }>();
    refs.push(...orderRefs.results);
    if (lineEntity && lineTable) {
      const orderCol = row.entity_type === 'sale' ? 'sale_id' : 'purchase_id';
      const lineRefs = await db.prepare(
        `SELECT r.entity, r.entity_id, r.file_key FROM attachment_refs r
         JOIN ${lineTable} l ON l.id = r.entity_id
         WHERE r.entity = ? AND l.${orderCol} = ?`,
      ).bind(lineEntity, orderId).all<{ entity: string; entity_id: string; file_key: string }>();
      refs.push(...lineRefs.results);
    }
    for (const r of refs) {
      await recordChange(db, {
        entity_type: 'attachment',
        entity_sync_id: `${r.entity}:${r.entity_id}:${r.file_key}`,
        action: 'upsert',
        payload: {
          file_key: r.file_key, file: r.file_key.split('/').pop() ?? '',
          entity: r.entity, id: r.entity_id,
        },
        updated_by_username: c.get('user').username,
      });
    }
  } catch (_) { /* 补发失败不影响恢复主流程（附件在 in-use 中仍可被下载收敛） */ }
  await expireSnapshots(db);
  await recordAudit(db, {
    username: c.get('user').username, action: 'update', entity_type: row.entity_type, entity_id: orderId,
    detail: `从回收站恢复单据（原作废原因：${row.reason || '无'}）`,
  });
  await db.prepare('DELETE FROM voided_orders WHERE id = ?').bind(trashId).run();
  return c.json({ ok: true, entity_type: row.entity_type, id: orderId });
});

// DELETE /trash/:id — 彻底清除（不可再恢复）
// 作废时附件引用/R2 文件被保留（供恢复），这里才是真正清理点：删引用 + 补发 attachment 删除变更，
// 零引用文件物理删除。同 ID 单据若已被新单占用（entityExists）→ 绝不能清附件（属于新单）。
trashRouter.delete('/:id', async (c) => {
  const trashId = c.req.param('id');
  const row = await c.env.DB.prepare('SELECT * FROM voided_orders WHERE id = ?')
    .bind(trashId).first<VoidedEntry>();
  if (!row || !isVoidable(row.entity_type)) return c.json({ error: '回收站记录不存在' }, 404);
  let payload: Record<string, unknown> = {};
  try { payload = JSON.parse(row.payload) as Record<string, unknown>; } catch (_) {}
  const orderId = String(payload.id ?? '');
  try {
    if (orderId && !(await entityExists(c.env.DB, row.entity_type, orderId))) {
      const lineEntity = row.entity_type === 'sale' ? 'sale_item'
        : row.entity_type === 'purchase' ? 'purchase_item' : '';
      if (lineEntity && Array.isArray(payload.items)) {
        for (const it of payload.items as Array<Record<string, unknown>>) {
          const lineId = String(it?.id ?? '');
          if (lineId) await deleteEntityAttachments(c.env, lineEntity, lineId);
        }
      }
      await deleteEntityAttachments(c.env, row.entity_type, orderId);
    }
  } catch (e) {
    console.error('[taozhu] 彻底删除回收站记录时清理附件失败:', e);
  }
  const res = await c.env.DB.prepare('DELETE FROM voided_orders WHERE id = ?').bind(trashId).run();
  if (!res.meta.changes) return c.json({ error: '回收站记录不存在' }, 404);
  return c.body(null, 204);
});
