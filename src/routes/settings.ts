/** 系统设置（仅老板）：AI 配置（API 地址 / Key / 模型），供拍照识别使用 */
import { Hono } from 'hono';
import { authMiddleware, adminOnly } from '../middleware/auth';
import { DEFAULT_AI_CONFIG, type AiConfig } from '../services/ai-parse';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const settingsRouter = new Hono<{ Bindings: Env; Variables: V }>();

settingsRouter.use('*', authMiddleware(), adminOnly());

const KEY_API_KEY = 'ai_api_key';
const KEY_BASE_URL = 'ai_base_url';
const KEY_MODEL = 'ai_model';

async function getSetting(db: D1Database, key: string): Promise<string | null> {
  const row = await db.prepare('SELECT value FROM settings WHERE key = ?').bind(key).first<{ value: string }>();
  return row?.value ?? null;
}

/** 合并后台配置与默认值 */
export async function getAiConfig(db: D1Database): Promise<AiConfig> {
  const [apiKey, baseUrl, model] = await Promise.all([
    getSetting(db, KEY_API_KEY),
    getSetting(db, KEY_BASE_URL),
    getSetting(db, KEY_MODEL),
  ]);
  return {
    apiKey: apiKey?.trim() ?? '',
    baseUrl: baseUrl?.trim() || DEFAULT_AI_CONFIG.baseUrl,
    model: model?.trim() || DEFAULT_AI_CONFIG.model,
  };
}

// GET /api/v1/settings/ai — 配置状态（不回显 Key 明文）
settingsRouter.get('/ai', async (c) => {
  const cfg = await getAiConfig(c.env.DB);
  return c.json({ has_key: Boolean(cfg.apiKey), base_url: cfg.baseUrl, model: cfg.model });
});

// PUT /api/v1/settings/ai — 保存（body: { api_key?, base_url?, model? }；空字符串=清除该项回默认）
settingsRouter.put('/ai', async (c) => {
  const body = await c.req.json().catch(() => null) as { api_key?: string; base_url?: string; model?: string } | null;
  const upsert = async (key: string, value: string) => {
    await c.env.DB.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
      .bind(key, value).run();
  };
  if (body?.api_key !== undefined) await upsert(KEY_API_KEY, body.api_key.trim());
  if (body?.base_url !== undefined) await upsert(KEY_BASE_URL, body.base_url.trim());
  if (body?.model !== undefined) await upsert(KEY_MODEL, body.model.trim());
  const cfg = await getAiConfig(c.env.DB);
  return c.json({ has_key: Boolean(cfg.apiKey), base_url: cfg.baseUrl, model: cfg.model });
});