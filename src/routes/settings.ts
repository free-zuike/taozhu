/** 系统设置（仅老板）：存智谱 AI Key 等，供拍照识别等后台服务使用 */
import { Hono } from 'hono';
import { authMiddleware, adminOnly } from '../middleware/auth';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const settingsRouter = new Hono<{ Bindings: Env; Variables: V }>();

settingsRouter.use('*', authMiddleware(), adminOnly());

const KEY_ZHIPU = 'zhipu_api_key';

async function getSetting(db: D1Database, key: string): Promise<string | null> {
  const row = await db.prepare('SELECT value FROM settings WHERE key = ?').bind(key).first<{ value: string }>();
  return row?.value ?? null;
}

export async function getZhipuKey(db: D1Database, envKey?: string): Promise<string | null> {
  const stored = await getSetting(db, KEY_ZHIPU);
  return stored?.trim() || envKey?.trim() || null;
}

// GET /api/v1/settings/ai — 是否已配置（不返回明文）
settingsRouter.get('/ai', async (c) => {
  const key = await getSetting(c.env.DB, KEY_ZHIPU);
  return c.json({ has_zhipu_key: Boolean(key?.trim()) });
});

// PUT /api/v1/settings/ai — 保存/更新（body: { zhipu_api_key?: string }；传空或 missing 视为清除）
settingsRouter.put('/ai', async (c) => {
  const body = await c.req.json().catch(() => null) as { zhipu_api_key?: string } | null;
  const key = body?.zhipu_api_key?.trim() ?? '';
  await c.env.DB.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
    .bind(KEY_ZHIPU, key).run();
  return c.json({ has_zhipu_key: Boolean(key) });
});