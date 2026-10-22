/** 备份核心逻辑（纯函数，供 Worker 路由与 Durable Object 打包共用，无路由依赖）。
 *  备份产物 = ZIP 归档包（对齐 beecount 方案：数据 + 附件以原始文件流式入包，无 base64 内嵌
 *  JSON 的大小上限问题）：
 *    - meta.json          元信息（exported_at / app_version）
 *    - db.json            全库业务表数据（{exported_at, data}，恢复合并导入）
 *    - attachments/<key>  附件原始文件（key 与 attachment_refs.file_key 一致，恢复写回存储端）
 *  手动导出 JSON（GET /backup）仍保留：轻量存档/对账用，附件总大小 ≤ 上限时内嵌 base64。 */
import type { Env } from '../types';
import { createStorage, type AttachmentStorage } from './storage';
import { APP_VERSION } from '../version';

/** 备份排除表（内部/运行时，非业务数据）：login_attempts 限流/登录防爆破、schema_meta 建表标记、
 *  sync_changes 变更流(恢复后由 fullSync 重建，导入会导致客户端重放旧游标)、audit_logs 操作审计（量大且可再生成）
 */
const EXCLUDED_TABLES = new Set(['login_attempts', 'schema_meta', 'sync_changes', 'audit_logs']);

/// 动态枚举全部业务表（参考 sqlite_master 全量 - 内部表），不再硬编码——
/// 新增表（价格组/分享/账号/设备…）自动纳入备份，杜绝"备份不全"
export async function listBusinessTables(db: D1Database): Promise<string[]> {
  const r = await db.prepare(
    `SELECT name FROM sqlite_master WHERE type = 'table'
       AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name NOT LIKE 'd1_%'
     ORDER BY name`,
  ).all<{ name: string }>();
  return (r.results || []).map((x) => x.name).filter((n) => !EXCLUDED_TABLES.has(n));
}

/// 分页拉取单表（LIMIT 1000）：一次性 SELECT * 全表在大库超 Worker 内存/CPU → 503
export async function exportTablePages(db: D1Database, table: string): Promise<unknown[]> {
  const rows: unknown[] = [];
  let offset = 0;
  for (;;) {
    const r = await db.prepare(`SELECT * FROM ${table} LIMIT 1000 OFFSET ?`).bind(offset).all();
    rows.push(...r.results);
    if (r.results.length < 1000) break;
    offset += 1000;
  }
  return rows;
}

/// 导入顺序权重：父表(被引用)在前、子表在后，剩余表按字母序（动态枚举——新增表自动插入尾部不阻塞恢复）
const IMPORT_ORDER = [
  'categories', 'clients', 'items', 'item_prices', 'price_groups', 'item_group_prices',
  'sale_items', 'purchase_items', 'payments', 'settings', 'payment_accounts', 'stocks',
  'users', 'devices', 'share_links', 'attachment_refs',
] as const;

/// 按导入权重排序（未列入权重的新表按字母序追加在末尾）
async function sortImportTables(db: D1Database, data: Record<string, unknown[]>): Promise<string[]> {
  const names = Object.keys(data);
  const known = IMPORT_ORDER.filter((t) => names.includes(t));
  const rest = names.filter((n) => !(IMPORT_ORDER as readonly string[]).includes(n)).sort();
  const tables = [...known, ...rest];
  // 生产库可能因老版本缺表/导入包含且表存在才恢复——过滤掉当前库不存在的表
  const all = new Set(await listBusinessTables(db));
  return tables.filter((t) => all.has(t));
}

/// 合并导入备份数据（逐表逐行 INSERT OR IGNORE；JSON 导入与 ZIP 恢复共用）
/// 附件文件随备份内嵌：env 提供时写回存储端（恢复后附件本体在，不再是空引用）
export async function importBackupData(
  db: D1Database,
  data: Record<string, Record<string, unknown>[]>,
  env?: Env,
): Promise<{ report: Record<string, { inserted: number; skipped: number }>; total_inserted: number }> {
  const report: Record<string, { inserted: number; skipped: number }> = {};
  let totalInserted = 0;
  const order = await sortImportTables(db, data);
  for (const t of order) {
    const rows = data[t];
    if (!Array.isArray(rows)) continue;
    let inserted = 0;
    let skipped = 0;
    for (const row of rows) {
      if (!row || typeof row !== 'object' || !('id' in row)) {
        skipped++;
        continue;
      }
      const cols = Object.keys(row).filter((k) => /^[a-zA-Z_][a-zA-Z0-9_]*$/.test(k));
      if (cols.length === 0) {
        skipped++;
        continue;
      }
      const sql = `INSERT OR IGNORE INTO ${t} (${cols.join(',')}) VALUES (${cols.map(() => '?').join(',')})`;
      try {
        const r = await db.prepare(sql).bind(...cols.map((k) => row[k])).run();
        if ((r.meta.changes ?? 0) > 0) {
          inserted++;
          totalInserted++;
        } else {
          skipped++;
        }
      } catch {
        skipped++;
      }
    }
    report[t] = { inserted, skipped };
  }
  // 附件：JSON 备份为内嵌清单（{key,data}，有 data 才写回存储端——跨环境导入/旧备份留底）
  if (env) {
    const files = data['__attachments'];
    if (Array.isArray(files)) {
      const store = createStorage(env);
      let restored = 0;
      const list = files as Array<{ key?: string; data?: string }>;
      const putOne = async (f: { key?: string; data?: string }): Promise<boolean> => {
        const key = f?.key;
        if (!key) return false;
        if (!f.data) return true; // 引用模式：本体已在存储端，无需重传
        try {
          const bin = atob(f.data);
          const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
          await store.put(key, bytes, 'application/octet-stream');
          return true;
        } catch (_) {
          return false;
        }
      };
      for (let i = 0; i < list.length; i += 6) {
        const batch = await Promise.all(list.slice(i, i + 6).map(putOne));
        restored += batch.filter(Boolean).length;
      }
      report['__attachments'] = { inserted: restored, skipped: list.length - restored };
      totalInserted += restored;
    }
  }
  return { report, total_inserted: totalInserted };
}

/** 备份文件前缀（与附件同库同 R2，走 createStorage 工厂——STORAGE_DRIVER 可切换备份端） */
export const BACKUP_PREFIX = 'taozhu/backups/backup-';

// 自动备份保留份数（settings 表 key）：用户可配置（1-90），默认 14
export const KEY_BACKUP_KEEP = 'backup_keep';
export const DEFAULT_BACKUP_KEEP = 14;

export async function getBackupKeep(db: D1Database): Promise<number> {
  const row = await db.prepare('SELECT value FROM settings WHERE key = ?').bind(KEY_BACKUP_KEEP).first<{ value: string }>();
  const n = Number((row?.value ?? '').trim());
  return Number.isInteger(n) && n >= 1 && n <= 90 ? n : DEFAULT_BACKUP_KEEP;
}

/// 北京时间戳（YYYYMMDD-HHMMSSmmm），备份文件名唯一（定时/手动/同秒均不覆盖）
export function bjStamp(d: Date): string {
  const b = new Date(d.getTime() + 8 * 3600 * 1000);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${b.getUTCFullYear()}${p(b.getUTCMonth() + 1)}${p(b.getUTCDate())}-${p(b.getUTCHours())}${p(b.getUTCMinutes())}${p(b.getUTCSeconds())}${String(b.getUTCMilliseconds()).padStart(3, '0')}`;
}

/// 备份文件名统一显示：backup-2026-09-18 → 2026-09-18；backup-20260918-150505123.zip/json → 2026-09-18 15:05:05
export function formatBackupName(name: string): string {
  const clean = name.replace(/^backup-/, '').replace(/\.(json|zip)$/, '');
  const old = /^(\d{4})-(\d{2})-(\d{2})$/.exec(clean);
  if (old) return `${old[1]}-${old[2]}-${old[3]}`;
  const now = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})\d{3}$/.exec(clean);
  if (now) return `${now[1]}-${now[2]}-${now[3]} ${now[4]}:${now[5]}:${now[6]}`;
  return name;
}

/** Uint8Array → base64（分段拼接，防 String.fromCharCode.apply 参数栈溢出） */
function bytesToBase64(bytes: Uint8Array): string {
  let bin = '';
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    bin += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(bin);
}

/// 手动导出（GET /backup）附件内嵌上限：全量 base64 内嵌使备份 JSON 巨大 → Worker stringify
/// 内存/CPU 超限 503（用户曾报"备份 503"根因）。附件总大小 ≤ 上限才内嵌本体；超出仅引用清单。
const MAX_ATTACHMENT_EMBED_BYTES = 12 * 1024 * 1024;

/// 导出附件（手动导出 JSON 用）：总大小 ≤ 上限 → 内嵌本体 [{key, data(base64), size}]（跨环境恢复附件不丢）；
/// 超出 → 只列引用 [{key, size}]（同环境恢复仍完整），返回 omitted=true 供前端提示。
async function exportAttachments(env: Env): Promise<{
  files: Array<{ key: string; data?: string; size: number }>;
  count: number;
  bytes: number;
  embedded: boolean;
}> {
  const refs = await env.DB.prepare('SELECT DISTINCT file_key AS key FROM attachment_refs').all<{ key: string }>();
  const keys = refs.results.map((r) => r.key).filter((k): k is string => !!k);
  if (keys.length === 0) return { files: [], count: 0, bytes: 0, embedded: false };
  const store = createStorage(env);
  // 先汇总物理大小：超上限直接引用清单（不读内容，省内存防 503）
  const sizes = new Map<string, number>();
  let total = 0;
  for (let i = 0; i < keys.length; i += 100) {
    const part = keys.slice(i, i + 100);
    const groups = await Promise.all(part.map((k) => store.list(k)));
    for (let j = 0; j < part.length; j++) {
      const size = groups[j].objects[0]?.size ?? 0;
      sizes.set(part[j], size);
      total += size;
    }
  }
  if (total > MAX_ATTACHMENT_EMBED_BYTES) {
    return {
      files: keys.map((k) => ({ key: k, size: sizes.get(k) ?? 0 })),
      count: keys.length, bytes: total, embedded: false,
    };
  }
  // 读本体内嵌（并发 6 防存储端限流；单个失败降级为引用，不中断整体导出）
  const files: Array<{ key: string; data?: string; size: number }> = [];
  const one = async (k: string) => {
    try {
      const obj = await store.get(k);
      if (!obj) { files.push({ key: k, size: sizes.get(k) ?? 0 }); return; }
      const buf = await new Response(obj.body).arrayBuffer();
      files.push({ key: k, data: bytesToBase64(new Uint8Array(buf)), size: buf.byteLength });
    } catch {
      files.push({ key: k, size: sizes.get(k) ?? 0 });
    }
  };
  for (let i = 0; i < keys.length; i += 6) {
    await Promise.all(keys.slice(i, i + 6).map(one));
  }
  return { files, count: keys.length, bytes: total, embedded: true };
}

/// 导出全部业务表数据（手动导出 GET /backup）：附件总大小 ≤ 上限时内嵌本体（{key, data}），
/// 超出保持引用清单。返回 {data, attachments:{count,bytes,embedded}} 供响应提示。
export async function exportAllData(db: D1Database, env?: Env): Promise<{
  data: Record<string, unknown[]>;
  attachments: { count: number; bytes: number; embedded: boolean };
}> {
  const data: Record<string, unknown[]> = {};
  const tables = await listBusinessTables(db);
  for (const t of tables) {
    data[t] = await exportTablePages(db, t);
  }
  let attachments = { count: 0, bytes: 0, embedded: false };
  if (env) {
    try {
      const att = await exportAttachments(env);
      if (att.files.length > 0) data['__attachments'] = att.files;
      attachments = { count: att.count, bytes: att.bytes, embedded: att.embedded };
    } catch (_) {}
  }
  return { data, attachments };
}

/** 云备份归档结果（POST /backup/now 与定时共用返回形态） */
export interface BackupArchiveResult {
  key: string;
  size: number;
  status: 'succeeded' | 'failed';
  message: string;
  tables: { total: number; ok: number; failed: string[] };
  attachments: { total: number; ok: number; failed: number };
}

/// 云备份：生成 ZIP 归档包（meta.json + db.json + attachments/ 附件原始文件，流式入包无大小上限）
/// 并写入存储端，清理超保留份数。在 Durable Object（30s CPU 预算）内调用——附件多时 Worker
/// 10ms CPU 限制会超（对齐 beecount：打包放 DO，绕开 Worker 限制）。
export async function buildBackupArchive(
  db: D1Database,
  store: AttachmentStorage,
): Promise<BackupArchiveResult> {
  const keep = await getBackupKeep(db);
  // 1) 导出各表：单表失败不中断（收集 failed 表清单）
  const tables = await listBusinessTables(db);
  const data: Record<string, unknown[]> = {};
  const failedTables: string[] = [];
  for (const t of tables) {
    try {
      data[t] = await exportTablePages(db, t);
    } catch {
      failedTables.push(t);
    }
  }
  // 2) 附件清单（DISTINCT file_key；物理文件在存储端，恢复时按 key 写回）
  const refs = await db.prepare('SELECT DISTINCT file_key AS key FROM attachment_refs').all<{ key: string }>();
  const keys = refs.results.map((r) => r.key).filter((k): k is string => !!k);
  // 3) zip 打包：附件流式入包（zip.js useWebWorkers=false，Worker 环境不派生子 worker）
  const { ZipWriter, BlobWriter } = await import('@zip.js/zip.js');
  const zipWriter = new ZipWriter(new BlobWriter('application/zip'), { useWebWorkers: false });
  const now = new Date().toISOString();
  await zipWriter.add('meta.json', new Blob([JSON.stringify({ schemaVersion: 1, appVersion: APP_VERSION, exported_at: now }, null, 2)], { type: 'application/json' }).stream());
  await zipWriter.add('db.json', new Blob([JSON.stringify({ exported_at: now, data })], { type: 'application/json' }).stream());
  let attOk = 0;
  const attFailed: string[] = [];
  for (const k of keys) {
    try {
      const obj = await store.get(k);
      if (!obj) {
        attFailed.push(k);
        continue;
      }
      // 附件原始字节流式进 zip（不整体进内存）；zip 输出 Blob 由 close 汇总
      await zipWriter.add(`attachments/${k}`, obj.body);
      attOk++;
    } catch {
      attFailed.push(k);
    }
  }
  const blob = await zipWriter.close();
  const bytes = new Uint8Array(await blob.arrayBuffer());
  // 4) 写入存储端（失败=整体 failed）
  const key = `${BACKUP_PREFIX}${bjStamp(new Date())}.zip`;
  try {
    await store.put(key, bytes, 'application/zip');
  } catch (e) {
    return {
      key, size: 0, status: 'failed', message: `上传备份失败：${(e as Error).message}`,
      tables: { total: tables.length, ok: tables.length - failedTables.length, failed: failedTables },
      attachments: { total: keys.length, ok: attOk, failed: attFailed.length },
    };
  }
  // 5) 清理超保留份数（失败不改变备份结果，best-effort）
  try {
    const list = await store.list(BACKUP_PREFIX);
    if (list.objects.length > keep) {
      const keepSet = new Set(list.objects.map((o) => o.key).sort().slice(-keep));
      for (const o of list.objects) {
        if (!keepSet.has(o.key)) await store.delete(o.key);
      }
    }
  } catch (_) {}
  // 6) 汇总状态
  const tableOk = failedTables.length === 0;
  const attOkAll = attFailed.length === 0;
  const status: 'succeeded' | 'failed' = tableOk && attOkAll ? 'succeeded' : 'failed';
  const message = tableOk && attOkAll
    ? `备份成功：${tables.length} 张表 · 附件 ${attOk} 个`
    : `备份不完整：${failedTables.length > 0 ? `表 <${failedTables.join(', ')}> ` : ''}${attFailed.length > 0 ? `附件 ${attFailed.length} 个读取失败` : ''}导出失败`;
  return {
    key, size: bytes.length, status, message,
    tables: { total: tables.length, ok: tables.length - failedTables.length, failed: failedTables },
    attachments: { total: keys.length, ok: attOk, failed: attFailed.length },
  };
}

/// 从 ZIP 归档包恢复：解包 → db.json 合并导入 D1 → attachments/* 写回存储端（key 与引用表一致）
export async function restoreBackupArchive(
  db: D1Database,
  store: AttachmentStorage,
  zipBytes: Uint8Array,
): Promise<{ ok: boolean; error?: string; report?: Record<string, { inserted: number; skipped: number }>; total_inserted?: number; attachments?: number }> {
  const { ZipReader, BlobReader, TextWriter, Uint8ArrayWriter } = await import('@zip.js/zip.js');
  let data: Record<string, Record<string, unknown>[]> | null = null;
  const attachmentFiles: Array<{ path: string; bytes: Uint8Array }> = [];
  try {
    const reader = new ZipReader(new BlobReader(new Blob([zipBytes])));
    const entries = await reader.getEntries();
    for (const entry of entries) {
      const e = entry as { filename: string; getData(w: unknown): Promise<unknown> };
      if (e.filename === 'db.json') {
        const text = await e.getData(new TextWriter()) as string;
        const parsed = JSON.parse(text) as { data?: Record<string, Record<string, unknown>[]> };
        data = parsed.data ?? null;
      } else if (e.filename.startsWith('attachments/')) {
        const bytes = await e.getData(new Uint8ArrayWriter()) as Uint8Array;
        attachmentFiles.push({ path: e.filename.slice('attachments/'.length), bytes });
      }
    }
    await reader.close();
  } catch {
    return { ok: false, error: '备份文件内容损坏（无法解包）' };
  }
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    return { ok: false, error: '备份文件缺少 db.json' };
  }
  // 附件写回存储端（key 即 attachment_refs.file_key，引用行在 db.json 里恢复后直接可用）
  let restored = 0;
  for (const f of attachmentFiles) {
    try {
      await store.put(f.path, f.bytes, 'application/octet-stream');
      restored++;
    } catch (_) {}
  }
  const { report, total_inserted } = await importBackupData(db, data);
  return { ok: true, report, total_inserted, attachments: restored };
}
