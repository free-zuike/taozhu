/** 作废单据归档（软删 / 红冲 / 回收站的存储层）。
 *
 * 口径：作废不是给业务表加 voided_at 再让十几处统计各自加过滤条件（漏一处就串账），
 * 而是「先把整单快照存进 voided_orders，再按原有删除路径物理移除业务行」。
 * 因此统计、欠款、库存、同步、CSV 全链路天然只看到有效单据；回收站里只剩快照，
 * 恢复时通过 sync.applyChange 回放，库存/FIFO/变更流都走同一套已验证逻辑。 */
import { randomId } from '../lib/password';
import { buildPayload } from '../lib/sync';
import type { D1Database } from '@cloudflare/workers-types';

export type VoidableEntity = 'sale' | 'purchase' | 'payment';

export interface VoidedEntry {
  id: string;
  entity_type: VoidableEntity;
  payload: string;
  reason: string;
  client_id: string;
  total: number;
  voided_at: string;
  voided_by: string;
}

/** 删除前归档。表未迁移的极端情况下只记日志、不阻断删除（宁可少一条回收站记录）。 */
export async function archiveVoidedOrder(
  db: D1Database,
  input: { entity_type: VoidableEntity; id: string; reason?: string; username: string },
): Promise<string | null> {
  try {
    const payload = await buildPayload(db, input.entity_type, input.id);
    if (!payload) return null;
    const p = payload as Record<string, unknown>;
    const trashId = randomId();
    await db.prepare(
      `INSERT INTO voided_orders (id, entity_type, payload, reason, client_id, total, voided_at, voided_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(
      trashId, input.entity_type, JSON.stringify(payload),
      (input.reason ?? '').slice(0, 200),
      String(p.client_id ?? ''), Number(p.total ?? p.amount ?? 0) || 0,
      new Date().toISOString(), input.username,
    ).run();
    return trashId;
  } catch (e) {
    console.error('[taozhu] 归档作废单据失败:', e);
    return null;
  }
}

/** 该实体是否仍存在（恢复前防覆盖同 id 的新单据） */
export async function entityExists(db: D1Database, entityType: VoidableEntity, id: string): Promise<boolean> {
  const sql = entityType === 'sale'
    ? 'SELECT 1 FROM sale_items WHERE sale_id = ? LIMIT 1'
    : entityType === 'purchase'
      ? 'SELECT 1 FROM purchase_items WHERE purchase_id = ? LIMIT 1'
      : 'SELECT 1 FROM payments WHERE id = ? LIMIT 1';
  return Boolean(await db.prepare(sql).bind(id).first());
}
