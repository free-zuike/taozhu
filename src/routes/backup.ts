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

const TABLES = [
  'clients', 'items', 'item_prices', 'purchase_items',
  'sale_items', 'payments', 'categories', 'settings', 'stocks',
  'payment_accounts', 'attachment_refs',
] as const;

/// 导入顺序：先父表再子表（弱外键，避免引用表尚未插入）
const IMPORT_ORDER = [
  'categories', 'clients', 'items', 'item_prices', 'stocks',
  'sale_items', 'purchase_items', 'payments', 'settings',
  'payment_accounts', 'attachment_refs',
] as const;

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

/// 导出全部业务表数据（手动导出与每日定时自动备份共用）
export async function exportAllData(db: D1Database): Promise<Record<string, unknown[]>> {
  const data: Record<string, unknown[]> = {};
  for (const t of TABLES) {
    const r = await db.prepare(`SELECT * FROM ${t}`).all();
    data[t] = r.results;
  }
  return data;
}

/// 北京时间戳（YYYYMMDD-HHMMSSmmm），备份文件名唯一（定时/手动/同秒均不覆盖）
function bjStamp(d: Date): string {
  const b = new Date(d.getTime() + 8 * 3600 * 1000);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${b.getUTCFullYear()}${p(b.getUTCMonth() + 1)}${p(b.getUTCDate())}-${p(b.getUTCHours())}${p(b.getUTCMinutes())}${p(b.getUTCSeconds())}${String(b.getUTCMilliseconds()).padStart(3, '0')}`;
}

/// 合并导入备份数据（逐表逐行 INSERT OR IGNORE；POST /import 与 R2 恢复共用）
export async function importBackupData(
  db: D1Database,
  data: Record<string, Record<string, unknown>[]>,
): Promise<{ report: Record<string, { inserted: number; skipped: number }>; total_inserted: number }> {
  const report: Record<string, { inserted: number; skipped: number }> = {};
  let totalInserted = 0;
  for (const t of IMPORT_ORDER) {
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
  return { report, total_inserted: totalInserted };
}

/// 立即执行一次备份（手动 POST /backup/now 与定时 scheduledBackup 共用）：
/// 导出全库 → 走 createStorage 工厂写入存储端（STORAGE_DRIVER 可换备份端，不写死 R2）→ 清理超保留份数。
export async function performBackup(env: Env, username?: string): Promise<{ key: string; size: number }> {
  const keep = await getBackupKeep(env.DB);
  const data = await exportAllData(env.DB);
  const store = createStorage(env);
  const key = `${BACKUP_PREFIX}${bjStamp(new Date())}.json`;
  const body = JSON.stringify({ exported_at: new Date().toISOString(), data });
  await store.put(key, body, 'application/json');
  const list = await store.list(BACKUP_PREFIX);
  if (list.objects.length > keep) {
    const keepSet = new Set(list.objects.map((o) => o.key).sort().slice(-keep));
    for (const o of list.objects) {
      if (!keepSet.has(o.key)) await store.delete(o.key);
    }
  }
  if (username) {
    await recordAudit(env.DB, { username, action: 'create', entity_type: 'backup', entity_id: key, detail: `手动全库备份（${Object.keys(data).length} 张表）` });
  }
  return { key, size: body.length };
}

// GET /backup — 全部数据 JSON
backupRouter.get('/', async (c) => {
  const data = await exportAllData(c.env.DB);
  await recordAudit(c.env.DB, { username: c.get('user').username, action: 'export', entity_type: 'backup', detail: `导出全库备份（${Object.keys(data).length} 张表）` });
  return c.json({ exported_at: new Date().toISOString(), data });
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
  const { report, total_inserted } = await importBackupData(c.env.DB, data);
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
    .map((o) => ({
      name: o.key.slice(BACKUP_PREFIX.length),
      key: o.key,
      size: o.size,
      created_at: o.uploaded?.toISOString() ?? '',
    }))
    .sort((a, b) => b.key.localeCompare(a.key));
  return c.json({ files });
});

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
  const { report, total_inserted } = await importBackupData(c.env.DB, data);
  await recordAudit(c.env.DB, {
    username: c.get('user').username,
    action: 'import', entity_type: 'backup', entity_id: key,
    detail: `从历史备份恢复：共新增 ${total_inserted} 条记录`,
  });
  return c.json({ ok: true, report, total_inserted, key });
});