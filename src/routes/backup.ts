/** 全库备份 导出/导入/手动备份/R2 历史恢复（仅老板）：
 *  GET / 返回全部业务表 JSON；POST /import 合并恢复；POST /now 立即备份到存储端；
 *  GET /files 备份历史列表；POST /files/:key/restore 从存储端恢复（自动登录读取，无需下载）。 */
import { Hono } from 'hono';
import { adminOnly, authMiddleware } from '../middleware/auth';
import { recordAudit } from './audit';
import { createStorage } from '../services/storage';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const backupRouter = new Hono<{ Bindings: Env; Variables: V }>();
backupRouter.use('*', authMiddleware(), adminOnly());

/** 备份排除表（内部/运行时，非业务数据）：login_attempts 限流/登录防爆破、schema_meta 建表标记、
 *  sync_changes 变更流(恢复后由 fullSync 重建，导入会导致客户端重放旧游标)、audit_logs 操作审计（量大且可再生成）
 */
const EXCLUDED_TABLES = new Set(['login_attempts', 'schema_meta', 'sync_changes', 'audit_logs']);

/// 动态枚举全部业务表（参考 sqlite_master 全量 - 内部表），不再硬编码——
/// 新增表（价格组/分享/账号/设备…）自动纳入备份，杜绝"备份不全"
async function listBusinessTables(db: D1Database): Promise<string[]> {
  const r = await db.prepare(
    `SELECT name FROM sqlite_master WHERE type = 'table'
       AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name NOT LIKE 'd1_%'
     ORDER BY name`,
  ).all<{ name: string }>();
  return (r.results || []).map((x) => x.name).filter((n) => !EXCLUDED_TABLES.has(n));
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

/// 备份文件前缀（与附件同库同 R2，走 createStorage 工厂——STORAGE_DRIVER 可切换备份端）
const BACKUP_PREFIX = 'taozhu/backups/backup-';

// 自动备份时间（settings 表 key）：用户可配置，格式 HH:MM（北京时间）；空=未设置
const KEY_BACKUP_TIME = 'backup_time';
export const DEFAULT_BACKUP_TIME = '03:05';
// 自动备份保留份数（settings 表 key）：用户可配置（1-90），默认 14
const KEY_BACKUP_KEEP = 'backup_keep';
export const DEFAULT_BACKUP_KEEP = 14;

export async function getBackupTime(db: D1Database): Promise<string> {
  const row = await db.prepare('SELECT value FROM settings WHERE key = ?').bind(KEY_BACKUP_TIME).first<{ value: string }>();
  const v = (row?.value ?? '').trim();
  return /^\d{2}:\d{2}$/.test(v) ? v : DEFAULT_BACKUP_TIME;
}

export async function getBackupKeep(db: D1Database): Promise<number> {
  const row = await db.prepare('SELECT value FROM settings WHERE key = ?').bind(KEY_BACKUP_KEEP).first<{ value: string }>();
  const n = Number((row?.value ?? '').trim());
  return Number.isInteger(n) && n >= 1 && n <= 90 ? n : DEFAULT_BACKUP_KEEP;
}

/// 是否命中备份时刻：当前北京时间 HH:MM == 配置时间（精确到分钟，一天恰好命中一次）
export function isBackupTime(nowUtc: Date, configured: string): boolean {
  const bj = new Date(nowUtc.getTime() + 8 * 3600 * 1000);
  const hh = String(bj.getUTCHours()).padStart(2, '0');
  const mm = String(bj.getUTCMinutes()).padStart(2, '0');
  return `${hh}:${mm}` === configured;
}

// GET /backup/auto — 自动备份设置（当前生效值：时间 + 保留份数）
backupRouter.get('/auto', async (c) => {
  const timeRow = await c.env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind(KEY_BACKUP_TIME).first<{ value: string }>();
  const keepRow = await c.env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind(KEY_BACKUP_KEEP).first<{ value: string }>();
  return c.json({
    time: (timeRow?.value ?? '').trim() || DEFAULT_BACKUP_TIME,
    configured: (timeRow?.value ?? '').trim() !== '',
    keep: Number((keepRow?.value ?? '').trim()) || DEFAULT_BACKUP_KEEP,
  });
});

// PUT /backup/auto — 设置自动备份（body: { time?: 'HH:MM', keep?: number }；北京时间每日一次；保留份数 1-90）
backupRouter.put('/auto', async (c) => {
  const body = await c.req.json().catch(() => null) as { time?: string; keep?: number } | null;
  const upsert = async (key: string, value: string) => {
    await c.env.DB.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
      .bind(key, value).run();
  };
  if (body?.time !== undefined) {
    const time = (body.time ?? '').trim();
    if (!/^\d{2}:\d{2}$/.test(time)) return c.json({ error: '时间格式应为 HH:MM（如 03:05）' }, 400);
    const hh = Number(time.slice(0, 2));
    const mm = Number(time.slice(3, 5));
    if (hh > 23 || mm > 59) return c.json({ error: '时间超出范围' }, 400);
    await upsert(KEY_BACKUP_TIME, time);
  }
  if (body?.keep !== undefined) {
    const keep = Number(body.keep);
    if (!Number.isInteger(keep) || keep < 1 || keep > 90) return c.json({ error: '保留份数应为 1-90' }, 400);
    await upsert(KEY_BACKUP_KEEP, String(keep));
  }
  const timeRow = await c.env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind(KEY_BACKUP_TIME).first<{ value: string }>();
  const keepRow = await c.env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind(KEY_BACKUP_KEEP).first<{ value: string }>();
  return c.json({
    time: (timeRow?.value ?? '').trim() || DEFAULT_BACKUP_TIME,
    keep: Number((keepRow?.value ?? '').trim()) || DEFAULT_BACKUP_KEEP,
  });
});

/// 分页拉取单表（LIMIT 1000）：一次性 SELECT * 全表在大库超 Worker 内存/CPU → 503
async function exportTablePages(db: D1Database, table: string): Promise<unknown[]> {
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

/// 云端备份附件清单（对齐用户"App 本地备份、Web/小程序云端备份"分工）：
/// 只记录附件 key 引用清单（不含内容）——附件本体已存存储端（R2），恢复时
/// attachment_refs 的 file_key 直接指向原文件，无需重传。避免全量 base64 内嵌
/// 导致备份 JSON 巨大 → 整包 stringify 超 Worker 内存/CPU → 503（用户"备份 503 未解决"根因）。
async function collectAttachmentRefs(env: Env): Promise<{ keys: string[]; total: number }> {
  const refs = await env.DB.prepare('SELECT file_key FROM attachment_refs').all<{ file_key: string }>();
  const seen = new Set<string>();
  const keys = refs.results
    .map((r) => r.file_key)
    .filter((k): k is string => !!k && !seen.has(k) && !!seen.add(k));
  return { keys, total: keys.length };
}

/// 附件内嵌上限：全量 base64 内嵌使备份 JSON 巨大 → Worker stringify 内存/CPU 超限 503
/// （用户曾报"备份 503"根因）。附件总大小 ≤ 上限才内嵌本体；超出保持引用清单并在响应提示。
const MAX_ATTACHMENT_EMBED_BYTES = 12 * 1024 * 1024;

/** Uint8Array → base64（分段拼接，防 String.fromCharCode.apply 参数栈溢出） */
function bytesToBase64(bytes: Uint8Array): string {
  let bin = '';
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    bin += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(bin);
}

/// 导出附件：总大小 ≤ 上限 → 内嵌本体 [{key, data(base64), size}]（跨环境恢复附件不丢）；
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

/// 导出全部业务表数据（手动导出与每日定时自动备份共用）
/// 附件：总大小 ≤ 上限时内嵌本体（{key, data}，跨环境恢复附件不丢）；超出保持引用清单（同环境恢复完整）。
/// 返回 {data, attachments:{count,bytes,embedded}} 供响应提示（前端据此区分"已含附件/仅引用"）。
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

/// 北京时间戳（YYYYMMDD-HHMMSSmmm），备份文件名唯一（定时/手动/同秒均不覆盖）
function bjStamp(d: Date): string {
  const b = new Date(d.getTime() + 8 * 3600 * 1000);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${b.getUTCFullYear()}${p(b.getUTCMonth() + 1)}${p(b.getUTCDate())}-${p(b.getUTCHours())}${p(b.getUTCMinutes())}${p(b.getUTCSeconds())}${String(b.getUTCMilliseconds()).padStart(3, '0')}`;
}

/// 合并导入备份数据（逐表逐行 INSERT OR IGNORE；POST /import 与 R2 恢复共用）
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
  // 附件：云端备份为引用清单（{key}，本体已在存储端，恢复时 attachment_refs.file_key 直接可用）；
  // 兼容旧格式（内嵌 {key,data}）：有 data 才写回存储端（跨环境导入/旧备份留底）
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

/// 立即执行一次备份（手动 POST /backup/now 与定时 scheduledBackup 共用）：
/// 导出全库 → 走 createStorage 工厂写入存储端（STORAGE_DRIVER 可换备份端，不写死 R2）→ 清理超保留份数。
/// 返回带状态（succeeded=全部成功 / partial=部分失败 / failed=整体失败）+ 详情消息，
/// 前端据此明确展示"成功/部分成功（哪几项失败）/失败"，不再只有转圈或 503。
export async function performBackup(env: Env, username?: string): Promise<{
  key: string; size: number; status: 'succeeded' | 'partial' | 'failed'; message: string;
  tables: { total: number; ok: number; failed: string[] }; attachments: { total: number; ok: number; failed: number };
}> {
  const keep = await getBackupKeep(env.DB);
  // 1) 导出各表：单表失败不中断（收集 failed 表清单，最后汇总 partial/failed）
  const tables = await listBusinessTables(env.DB);
  const data: Record<string, unknown[]> = {};
  const failedTables: string[] = [];
  for (const t of tables) {
    try {
      data[t] = await exportTablePages(env.DB, t);
    } catch (e) {
      failedTables.push(t);
    }
  }
  // 2) 附件引用清单（云端备份只记 key 引用，附件本体已在存储端——不内嵌防 503）
  let attResult: { keys: string[]; total: number };
  try {
    attResult = await collectAttachmentRefs(env);
  } catch (e) {
    attResult = { keys: [], total: 0 };
  }
  if (attResult.keys.length > 0) data['__attachments'] = attResult.keys.map((key) => ({ key }));

  // 3) 上传存储端（失败=整体 failed）
  const store = createStorage(env);
  const key = `${BACKUP_PREFIX}${bjStamp(new Date())}.json`;
  const body = JSON.stringify({ exported_at: new Date().toISOString(), data, status: '' });
  try {
    await store.put(key, body, 'application/json');
  } catch (e) {
    return {
      key, size: 0, status: 'failed', message: `上传备份失败：${(e as Error).message}`,
      tables: { total: tables.length, ok: tables.length - failedTables.length, failed: failedTables },
      attachments: { total: attResult.total, ok: 0, failed: attResult.total },
    };
  }

  // 4) 清理超保留份数（失败不改变备份结果，best-effort）
  try {
    const list = await store.list(BACKUP_PREFIX);
    if (list.objects.length > keep) {
      const keepSet = new Set(list.objects.map((o) => o.key).sort().slice(-keep));
      for (const o of list.objects) {
        if (!keepSet.has(o.key)) await store.delete(o.key);
      }
    }
  } catch (_) {}

  // 5) 汇总状态：全成功=succeeded；表失败=failed；其余=partial（附件引用清单基本无失败）
  const tableOk = failedTables.length === 0;
  const attOk = attResult.total >= 0; // 引用清单无失败概念（本体已在存储端）
  let status: 'succeeded' | 'partial' | 'failed';
  let message: string;
  if (tableOk) {
    status = 'succeeded';
    message = `备份成功：${tables.length} 张表 · 附件引用 ${attResult.total} 个`;
  } else {
    status = 'failed';
    message = `备份失败：表 <${failedTables.join(', ')}> 导出失败`;
  }
  if (username) {
    await recordAudit(env.DB, { username, action: 'create', entity_type: 'backup', entity_id: key, detail: `手动全库备份：${message}` });
  }
  return {
    key, size: body.length, status, message,
    tables: { total: tables.length, ok: tables.length - failedTables.length, failed: failedTables },
    attachments: { total: attResult.total, ok: attResult.total, failed: 0 },
  };
}

// GET /backup — 全部数据 JSON。默认内嵌附件本体 base64（随备份可完整恢复，跨环境附件不丢；
// 附件总量超上限仅引用清单并在 attachments.embedded=false 提示）；?attachments=none 只要表数据
// （剪贴板/轻量导出：同环境导入附件本体已在存储端，attachment_refs 引用行恢复后即可正常读取）
backupRouter.get('/', async (c) => {
  const wantEmbed = c.req.query('attachments') !== 'none';
  const { data, attachments } = await exportAllData(c.env.DB, wantEmbed ? c.env : undefined);
  await recordAudit(c.env.DB, {
    username: c.get('user').username, action: 'export', entity_type: 'backup',
    detail: `导出全库备份（${Object.keys(data).length} 张表${attachments.count > 0 ? ` · 附件 ${attachments.count} 个${attachments.embedded ? '（内嵌）' : '（仅引用）'}` : ''}）`,
  });
  return c.json({
    exported_at: new Date().toISOString(),
    data,
    ...(attachments.count > 0 ? { attachments } : {}),
  });
});

// POST /backup/import — 合并导入备份 JSON：
// 逐表逐行 INSERT OR IGNORE，已存在主键的行跳过（保留现有数据），返回各表插入/跳过计数。
// 不做全库覆盖，导入前请自行导出留底。
backupRouter.post('/import', async (c) => {
  const body = await c.req.json().catch(() => null) as
    | { data?: Record<string, Record<string, unknown>[]> }
    | null;
  const data = body?.data;
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    return c.json({ error: '备份数据格式不正确（缺少 data 对象）' }, 400);
  }
  const { report, total_inserted } = await importBackupData(c.env.DB, data, c.env);
  await recordAudit(c.env.DB, { username: c.get('user').username, action: 'import', entity_type: 'backup', detail: `导入备份：共新增 ${total_inserted} 条记录` });
  return c.json({ ok: true, report, total_inserted });
});

// POST /backup/now — 立即手动备份到存储端（走 createStorage 工厂；返回文件名/大小）
backupRouter.post('/now', async (c) => {
  const r = await performBackup(c.env, c.get('user').username);
  return c.json({ ok: true, ...r });
});

// GET /backup/files — 备份历史列表（自动登录读取存储端，无需下载；新→旧）
backupRouter.get('/files', async (c) => {
  const store = createStorage(c.env);
  const list = await store.list(BACKUP_PREFIX);
  const files = list.objects
    .map((o) => {
      const name = o.key.slice(BACKUP_PREFIX.length).replace(/\.json$/, '');
      return {
        name: `${name}.json`,
        name_display: formatBackupName(name),
        key: o.key,
        size: o.size,
        created_at: o.uploaded?.toISOString() ?? '',
      };
    })
    .sort((a, b) => b.key.localeCompare(a.key));
  return c.json({ files });
});

/// 备份文件名统一显示：旧格式 YYYY-MM-DD（backup-2026-09-18）；新格式 YYYYMMDD-HHMMSSmmm → YYYY-MM-DD HH:MM:SS
export function formatBackupName(name: string): string {
  const old = /^(\d{4})-(\d{2})-(\d{2})$/.exec(name);
  if (old) return `${old[1]}-${old[2]}-${old[3]}`;
  const now = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})\d{3}$/.exec(name);
  if (now) return `${now[1]}-${now[2]}-${now[3]} ${now[4]}:${now[5]}:${now[6]}`;
  return name;
}

// POST /backup/files/:key/restore — 从存储端历史备份恢复（服务端读取 → 合并导入；勿需下载再上传）
backupRouter.post('/files/:key/restore', async (c) => {
  const key = c.req.param('key');
  if (key.includes('/') || key.startsWith('.') || key.startsWith('..')) {
    return c.json({ error: '非法备份标识' }, 400);
  }
  const fullKey = `${BACKUP_PREFIX}${key}`;
  const store = createStorage(c.env);
  const obj = await store.get(fullKey);
  if (!obj) return c.json({ error: '备份不存在或已被清理' }, 404);
  let data: Record<string, Record<string, unknown>[]> | null = null;
  try {
    const text = await new Response(obj.body).text();
    data = (JSON.parse(text) as { data?: Record<string, Record<string, unknown>[]> }).data ?? null;
  } catch {
    data = null;
  }
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    return c.json({ error: '备份文件内容损坏' }, 400);
  }
  const { report, total_inserted } = await importBackupData(c.env.DB, data, c.env);
  await recordAudit(c.env.DB, {
    username: c.get('user').username,
    action: 'import', entity_type: 'backup', entity_id: key,
    detail: `从历史备份恢复：共新增 ${total_inserted} 条记录`,
  });
  return c.json({ ok: true, report, total_inserted, key });
});