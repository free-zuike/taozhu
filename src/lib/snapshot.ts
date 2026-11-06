/**
 * 版本化只读快照：把「无 WHERE 全表 COUNT / 全量聚合」的结果按数据版本号缓存，
 * 命中时只读取 2 行（游标 + 快照），不再每次请求扫完整张流水表（D1 rows_read 主要开销）。
 *
 * 版本号 = sync_changes 的 MAX(id)。该表是 append-only 变更流，所有常规业务写都经
 * recordChange 追加一行，因此任何写操作都会让版本号变化 → 快照立即精确失效，
 * 不需要改 90+ 处写语句，也不需要 TTL 造成的「面板数字滞后」。
 * 只依赖部分表的聚合可传 affectedSince：游标前进时只检查增量变更里有没有相关写，
 * 无关写（改设置/客户/附件…）复用旧数据，避免高频同步反复触发昂贵的全表聚合。
 *
 * TTL 只是兜底：备份恢复 / schema 迁移等绕过变更流的通道不会 bump 游标，
 * 默认最多允许 60s 陈旧；只有「精确失效」的快照才可自定义放宽 TTL（如库存 5 分钟）。
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
export interface SnapshotOptions {
  /** 自定义版本号（默认全局 sync_changes 游标）。用于「只依赖部分表」的聚合：
   *  传该部分表的变更版本，无关表的写入就不再打掉快照。 */
  version?: () => Promise<number>;
  /** 兜底 TTL（默认 60s）。仅当版本号「精确」时才可放宽，避免绕过变更流的写入长期陈旧。 */
  ttlMs?: number;
  /** 精确失效判定：游标从 prev 前进到 next 期间，是否存在影响本快照的写入。
   *  返回 false（无相关写）时复用旧数据、只推进游标，避免无关写（改设置/客户/附件等）
   *  打掉一次昂贵的全表聚合。查询应走 sync_changes 主键范围 + LIMIT 1，读行数极小。 */
  affectedSince?: (prev: number, next: number) => Promise<boolean>;
}

export async function versionedSnapshot<T>(
  db: D1Database,
  name: string,
  compute: () => Promise<T>,
  fingerprint = '',
  opts: SnapshotOptions = {},
): Promise<{ data: T; cursor: number }> {
  const cursor = opts.version ? await opts.version() : await maxCursor(db);
  const ttlMs = opts.ttlMs ?? SNAPSHOT_TTL_MS;
  const key = SNAPSHOT_PREFIX + name;
  const row = await db.prepare('SELECT value FROM schema_meta WHERE key = ?')
    .bind(key).first<{ value: string }>();
  const now = Date.now();
  if (row) {
    try {
      const env = JSON.parse(row.value) as Envelope<T>;
      // env.ts <= now：时钟回拨时不把「未来」快照当成有效；ts 不随「复用」刷新，
      // 保证 TTL 仍从最初计算时刻起算（绕过变更流的写入最多陈旧一个 TTL）。
      const usable = env.v === 1 && (env.fp ?? '') === fingerprint
        && env.ts <= now && now - env.ts < ttlMs;
      if (usable) {
        if (env.cursor === cursor) return { data: env.data, cursor };
        // 游标前进了，但期间只有与本快照无关的写 → 复用旧数据，只把游标推进写回
        if (opts.affectedSince && !(await opts.affectedSince(env.cursor, cursor))) {
          await db.prepare('INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)')
            .bind(key, JSON.stringify({ ...env, cursor })).run();
          return { data: env.data, cursor };
        }
      }
    } catch {
      // 快照损坏/判定异常（旧格式、写一半、D1 瞬时失败）→ 保守重算，不影响接口
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

/**
 * 构造 affectedSince：游标从 prev 前进到 next 期间，是否存在「不在无关白名单里」的写。
 * 走 sync_changes 主键范围 + LIMIT 1，自身只读极少行；调用方可把 TTL 放宽到分钟级，
 * 避免「改设备/主题/附件」这类无关写打掉一次昂贵的全表聚合。
 *
 * 反向白名单是关键：未知或新增的 entity_type 一律判为「相关」→ 保守重算，
 * 宁可多重算一次，也绝不返回陈旧数字。
 */
export function unaffectedTypes(
  db: D1Database,
  unrelated: readonly string[],
): (prev: number, next: number) => Promise<boolean> {
  const ph = unrelated.map(() => '?').join(',');
  return async (prev: number, next: number): Promise<boolean> => {
    if (next <= prev) return true; // 游标回退/重置 → 保守重算
    const row = await db.prepare(
      `SELECT 1 AS hit FROM sync_changes WHERE id > ? AND id <= ?
         AND entity_type NOT IN (${ph}) LIMIT 1`,
    ).bind(prev, next, ...unrelated).first<{ hit: number }>();
    return !!row;
  };
}
