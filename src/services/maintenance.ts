/**
 * 每日维护：把过期数据清理从「每次写路径」挪到 cron 的低频任务里。
 *
 * 背景：recordAudit 原先每写一条审计就顺带跑一次 DELETE（写放大）；而
 * sync_changes / share_links / idempotency_keys 完全没有清理、无限增长，
 * 会持续推高备份包体积、/sync/full 成本与 D1 存储占用。
 * sync_changes 是 append-only 变更流，每行带实体完整快照，增长最快。
 */
export const AUDIT_KEEP_DAYS = 180;
export const SYNC_CHANGES_KEEP_DAYS = 180;
/** 回收站快照保留一年：留足人工核对/恢复窗口，又不让归档无限增长 */
export const VOIDED_KEEP_DAYS = 365;
const MAINT_KEY = 'daily_maintenance_date';
export const SYNC_WATERMARK_KEY = 'sync_changes_watermark';

export interface MaintenanceResult {
  ran: boolean;
  audit_logs: number;
  sync_changes: number;
  share_links: number;
  idempotency_keys: number;
  voided_orders: number;
  cutoff: string;
}

/**
 * 幂等：用 schema_meta 记日期，cron 每分钟触发但每天只真正执行一次。
 * force=true 供 admin 手动端点调用（可重复跑）。
 */
export async function runDailyMaintenance(db: D1Database, force = false): Promise<MaintenanceResult> {
  const zero = (): MaintenanceResult => ({
    ran: false, audit_logs: 0, sync_changes: 0, share_links: 0, idempotency_keys: 0, voided_orders: 0, cutoff: '',
  });
  const today = new Date().toISOString().slice(0, 10);
  if (!force) {
    const last = await db.prepare('SELECT value FROM schema_meta WHERE key = ?')
      .bind(MAINT_KEY).first<{ value: string }>();
    if (last?.value === today) return zero();
  }
  const cutoff = new Date(Date.now() - SYNC_CHANGES_KEEP_DAYS * 86400_000).toISOString();
  const auditCut = new Date(Date.now() - AUDIT_KEEP_DAYS * 86400_000).toISOString();
  const now = new Date().toISOString();
  const a = await db.prepare('DELETE FROM audit_logs WHERE created_at < ?').bind(auditCut).run();
  const s = await db.prepare('DELETE FROM sync_changes WHERE updated_at < ?').bind(cutoff).run();
  const sh = await db.prepare('DELETE FROM share_links WHERE expires_at IS NOT NULL AND expires_at < ?')
    .bind(now).run();
  const ik = await db.prepare('DELETE FROM idempotency_keys WHERE created_at < ?').bind(cutoff).run();
  // 回收站超期快照（老库可能还没补建 voided_orders 表，单条失败不影响其它清理）
  const voidCut = new Date(Date.now() - VOIDED_KEEP_DAYS * 86400_000).toISOString();
  let voided = 0;
  try {
    const v = await db.prepare('DELETE FROM voided_orders WHERE voided_at < ?').bind(voidCut).run();
    voided = v.meta.changes ?? 0;
  } catch (_) { /* no such table */ }
  // 水位：/sync/pull 用它判断客户端游标是否落在已删除区间，避免静默丢增量
  const minId = await db.prepare('SELECT MIN(id) AS m FROM sync_changes').first<{ m: number | null }>();
  await db.prepare("INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)")
    .bind(SYNC_WATERMARK_KEY, String(minId?.m ?? 0)).run();
  await db.prepare("INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)")
    .bind(MAINT_KEY, today).run();
  return {
    ran: true,
    audit_logs: a.meta.changes ?? 0,
    sync_changes: s.meta.changes ?? 0,
    share_links: sh.meta.changes ?? 0,
    idempotency_keys: ik.meta.changes ?? 0,
    voided_orders: voided,
    cutoff,
  };
}
