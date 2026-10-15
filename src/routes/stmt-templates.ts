/** 对账单模板跨端同步：模板列表（XlsCfg JSON，与 App 设计器同一数据模型）存 settings 单行 KV，
 *  App 设计器/小程序共用同一份——一次设计、两端显示一致（用户"不要各端各写一套模板"）。
 *  读：所有登录用户（对账单页/打印需要）；写：仅老板（adminOnly，对齐 settings/theme_config）。
 *  变更广播 stmt_templates：其他端 WS 收到后重新拉取模板列表。 */
import { Hono } from 'hono';
import { authMiddleware, adminOnly } from '../middleware/auth';
import { notifyClients } from '../services/sync-hub';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const stmtTemplatesRouter = new Hono<{ Bindings: Env; Variables: V }>();

const KEY_TEMPLATES = 'stmt_templates';
const KEY_CURRENT = 'stmt_tpl_current';

async function getSetting(db: D1Database, key: string): Promise<string | null> {
  const row = await db.prepare('SELECT value FROM settings WHERE key = ?').bind(key).first<{ value: string }>();
  return row?.value ?? null;
}

async function upsertSetting(db: D1Database, key: string, value: string) {
  await db.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
    .bind(key, value).run();
}

// GET /api/v1/stmt-templates — 模板列表 + 当前选中名（无云端数据时返回空列表，客户端回退内置模板）
stmtTemplatesRouter.get('/', authMiddleware(), async (c) => {
  const [raw, current] = await Promise.all([
    getSetting(c.env.DB, KEY_TEMPLATES),
    getSetting(c.env.DB, KEY_CURRENT),
  ]);
  let templates: unknown[] = [];
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) templates = parsed;
    } catch {
      /* 损坏数据忽略，返回空列表（客户端回退内置） */
    }
  }
  return c.json({ templates, current: current ?? '' });
});

// PUT /api/v1/stmt-templates — 保存整份模板列表 + 当前选中名（body: { templates: object[], current: string }）
stmtTemplatesRouter.put('/', authMiddleware(), adminOnly(), async (c) => {
  const body = (await c.req.json().catch(() => null)) as { templates?: unknown[]; current?: string } | null;
  if (!body || !Array.isArray(body.templates)) {
    return c.json({ error: 'templates 需为数组' }, 400);
  }
  // 限制大小（网格模板 JSON 通常 <50KB/份；整份上限 500KB 防滥用）
  const json = JSON.stringify(body.templates);
  if (json.length > 512 * 1024) return c.json({ error: '模板数据过大' }, 400);
  await upsertSetting(c.env.DB, KEY_TEMPLATES, json);
  if (typeof body.current === 'string' && body.current.trim()) {
    await upsertSetting(c.env.DB, KEY_CURRENT, body.current.trim());
  }
  // 广播：其他端（App/Web/小程序）收到后重新拉取模板列表（对齐 theme_config 推送语义）
  await notifyClients('stmt_templates');
  return c.json({ ok: true });
});