/** 变更流写入：从 sync.ts 抽出，避免 image-key ↔ sync 循环依赖
 *  （image-key 的 deleteEntityAttachments 也要写 attachment 删除变更，若直接 import sync 会形成环）。 */
import { notifyClients } from '../services/sync-hub';

export interface SyncChangeInput {
  entity_type: string;
  entity_sync_id: string;
  action?: 'upsert' | 'delete';
  payload: unknown;
  updated_by_device_id?: string | null;
  updated_by_username?: string | null;
  /** 变更时间（LWW 依据）：push 场景必须用客户端带来的 updated_at，否则服务端入库时间会盖过客户端时间戳破坏决断 */
  updated_at?: string | null;
}

/** 追加一条变更记录（返回新行的 id，即游标） */
export async function recordChange(db: D1Database, c: SyncChangeInput): Promise<number> {
  const updatedAt = c.updated_at && !Number.isNaN(Date.parse(c.updated_at)) ? c.updated_at : new Date().toISOString();
  const res = await db.prepare(
    `INSERT INTO sync_changes (entity_type, entity_sync_id, action, payload_json, updated_at, updated_by_device_id, updated_by_username)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  ).bind(
    c.entity_type, c.entity_sync_id, c.action ?? 'upsert',
    JSON.stringify(c.payload ?? {}), updatedAt,
    c.updated_by_device_id ?? null, c.updated_by_username ?? null,
  ).run();
  // 实时同步：变更已入流 → 通知所有在线客户端拉取（失败静默）
  await notifyClients();
  return Number(res.meta.last_row_id ?? 0);
}
