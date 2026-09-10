/** 全库备份导出（仅老板，只读）：返回全部业务表数据 JSON，供前端导出/存档 */
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

// GET /backup — 全部数据 JSON
backupRouter.get('/', async (c) => {
  const data: Record<string, unknown[]> = {};
  for (const t of TABLES) {
    const r = await c.env.DB.prepare(`SELECT * FROM ${t}`).all();
    data[t] = r.results;
  }
  return c.json({ exported_at: new Date().toISOString(), data });
});