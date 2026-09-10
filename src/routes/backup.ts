/** 全库备份 导出/导入（仅老板）：GET / 返回全部业务表 JSON；POST /import 合并恢复 */
import { Hono } from 'hono';
import { adminOnly, authMiddleware } from '../middleware/auth';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const backupRouter = new Hono<{ Bindings: Env; Variables: V }>();
backupRouter.use('*', authMiddleware(), adminOnly());

const TABLES = [
  'clients', 'items', 'item_prices', 'purchases', 'purchase_items',
  'sales', 'sale_items', 'payments', 'categories', 'settings', 'stocks',
] as const;

/// 导入顺序：先父表再子表（弱外键，避免引用表尚未插入）
const IMPORT_ORDER = [
  'categories', 'clients', 'items', 'item_prices', 'stocks',
  'sales', 'sale_items', 'purchases', 'purchase_items', 'payments', 'settings',
] as const;

// GET /backup — 全部数据 JSON
backupRouter.get('/', async (c) => {
  const data: Record<string, unknown[]> = {};
  for (const t of TABLES) {
    const r = await c.env.DB.prepare(`SELECT * FROM ${t}`).all();
    data[t] = r.results;
  }
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