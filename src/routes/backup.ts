/** 全库备份 导出/导入（仅老板）：GET / 返回全部业务表 JSON；POST /import 合并恢复 */
import { Hono } from 'hono';
import { adminOnly, authMiddleware } from '../middleware/auth';
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

// 自动备份时间（settings 表 key）：用户可配置，格式 HH:MM（北京时间）；空=未设置
const KEY_BACKUP_TIME = 'backup_time';
export const DEFAULT_BACKUP_TIME = '03:05';

export async function getBackupTime(db: D1Database): Promise<string> {
  const row = await db.prepare('SELECT value FROM settings WHERE key = ?').bind(KEY_BACKUP_TIME).first<{ value: string }>();
  const v = (row?.value ?? '').trim();
  return /^\d{2}:\d{2}$/.test(v) ? v : DEFAULT_BACKUP_TIME;
}

/// 是否命中备份时刻：当前北京时间 HH:MM == 配置时间（精确到分钟，一天恰好命中一次）
export function isBackupTime(nowUtc: Date, configured: string): boolean {
  const bj = new Date(nowUtc.getTime() + 8 * 3600 * 1000);
  const hh = String(bj.getUTCHours()).padStart(2, '0');
  const mm = String(bj.getUTCMinutes()).padStart(2, '0');
  return `${hh}:${mm}` === configured;
}

// GET /backup/auto — 自动备份时间设置（当前生效值）
backupRouter.get('/auto', async (c) => {
  const row = await c.env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind(KEY_BACKUP_TIME).first<{ value: string }>();
  return c.json({ time: (row?.value ?? '').trim() || DEFAULT_BACKUP_TIME, configured: (row?.value ?? '').trim() !== '' });
});

// PUT /backup/auto — 设置自动备份时间（body: { time: 'HH:MM' }；北京时间；每日一次）
backupRouter.put('/auto', async (c) => {
  const body = await c.req.json().catch(() => null) as { time?: string } | null;
  const time = (body?.time ?? '').trim();
  if (!/^\d{2}:\d{2}$/.test(time)) return c.json({ error: '时间格式应为 HH:MM（如 03:05）' }, 400);
  const hh = Number(time.slice(0, 2));
  const mm = Number(time.slice(3, 5));
  if (hh > 23 || mm > 59) return c.json({ error: '时间超出范围' }, 400);
  await c.env.DB.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
    .bind(KEY_BACKUP_TIME, time).run();
  return c.json({ time });
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

// GET /backup — 全部数据 JSON
backupRouter.get('/', async (c) => {
  const data = await exportAllData(c.env.DB);
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
  if (!data || typeof data !== 'object') {
    return c.json({ error: '备份数据格式不正确（缺少 data 对象）' }, 400);
  }
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
      const cols = Object.keys(row);
      if (cols.length === 0) {
        skipped++;
        continue;
      }
      const sql = `INSERT OR IGNORE INTO ${t} (${cols.join(',')}) VALUES (${cols.map(() => '?').join(',')})`;
      try {
        const r = await c.env.DB.prepare(sql).bind(...cols.map((k) => row[k])).run();
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
  return c.json({ ok: true, report, total_inserted: totalInserted });
});