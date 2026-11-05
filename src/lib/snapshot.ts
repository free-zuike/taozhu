/**
 * 版本化只读快照：把「无 WHERE 全表 COUNT / 全量聚合」的结果按数据版本号缓存，
 * 命中时只读取 2 行（游标 + 快照），不再每次请求扫完整张流水表（D1 rows_read 主要开销）。
 *
 * 版本号 = sync_changes 的 MAX(id)。该表是 append-only 变更流，所有常规业务写都经
 * recordChange 追加一行，因此任何写操作都会让版本号变化 → 快照立即精确失效，
 * 不需要改 90+ 处写语句，也不需要 TTL 造成的「面板数字滞后」。
 *
 * TTL 只是兜底：备份恢复 / schema 迁移等绕过变更流的通道不会 bump 游标，
 * 这些场景最多允许 60s 陈旧，超时强制重算。
 *
 * 载体选 schema_meta（现成 KV 表，且在 backup-core 的 EXCLUDED_TABLES 中）：
 * 不进备份、不被恢复覆盖、不出现在设置页，也不需要新增表或迁移。
 */
import { maxCursor } from './sync';

const SNAPSHOT_PREFIX = 'snapshot:';
const SNAPSHOT_TTL_MS = 60_000;

type Envelope<T> = { v: 1; cursor: number; ts: number; data: T; fp?: string };

/**
 * 取当前版本下的快照。命中条件：版本号一致 + 配置指纹一致 + 未超时 + JSON 完好；
 * 未命中则调用 compute 重算并写回（INSERT OR REPLACE 幂等，并发 isolate 同时重算无副作用）。
 * 返回的 cursor 与 data 属于同一版本，可直接作为接口的 server_cursor。
 *
 * fingerprint 用于「影响结果但绕过变更流的配置」：例如 /settings/rounding 只做 WS 广播、
 * 不 append sync_changes，游标不变却会改变所有金额。调用方把这类配置值拼成指纹传入，
 * 配置一变即强制重算。不传时与旧版快照兼容（fp 缺省视为空串）。
 */
export async function versionedSnapshot<T>(
  db: D1Database,
  name: string,
  compute: () => Promise<T>,
  fingerprint = '',
): Promise<{ data: T; cursor: number }> {
  const cursor = await maxCursor(db);
  const key = SNAPSHOT_PREFIX + name;
  const row = await db.prepare('SELECT value FROM schema_meta WHERE key = ?')
    .bind(key).first<{ value: string }>();
  const now = Date.now();
  if (row) {
    try {
      const env = JSON.parse(row.value) as Envelope<T>;
      // env.ts <= now：时钟回拨时不把「未来」快照当成有效
      if (env.v === 1 && env.cursor === cursor && (env.fp ?? '') === fingerprint
        && env.ts <= now && now - env.ts < SNAPSHOT_TTL_MS) {
        return { data: env.data, cursor };
      }
    } catch {
      // 快照损坏（旧格式 / 写一半）→ 直接重算，不影响接口
    }
  }
  const data = await compute();
  const envelope: Envelope<T> = { v: 1, cursor, ts: now, data, fp: fingerprint };
  await db.prepare('INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)')
    .bind(key, JSON.stringify(envelope)).run();
  return { data, cursor };
}

/** 仅供测试：让快照强制过期（模拟绕过变更流的写入通道） */
export async function expireSnapshots(db: D1Database): Promise<void> {
  await db.prepare('DELETE FROM schema_meta WHERE key LIKE ?').bind(`${SNAPSHOT_PREFIX}%`).run();
}
