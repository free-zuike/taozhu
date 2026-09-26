/** 系统设置（仅老板）：AI 配置（多服务商 + 能力绑定），供 AI 记账识别使用 */
import { Hono } from 'hono';
import { authMiddleware, adminOnly } from '../middleware/auth';
import { ZHIPU_PROVIDER, DEFAULT_BINDING, type AiConfig, type AiProviderConfig, type AiBinding } from '../services/ai-parse';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const settingsRouter = new Hono<{ Bindings: Env; Variables: V }>();

settingsRouter.use('*', authMiddleware(), adminOnly());

const KEY_PROVIDERS = 'ai_providers';
const KEY_BINDING = 'ai_binding';

async function getSetting(db: D1Database, key: string): Promise<string | null> {
  const row = await db.prepare('SELECT value FROM settings WHERE key = ?').bind(key).first<{ value: string }>();
  return row?.value ?? null;
}

async function upsertSetting(db: D1Database, key: string, value: string) {
  await db.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
    .bind(key, value).run();
}

/** 合并后台配置与默认值（多服务商 + 能力绑定；无配置时细粒度列表语义：services 全部默认智谱内置） */
export async function getAiConfig(db: D1Database): Promise<AiConfig> {
  const raw = await getSetting(db, KEY_PROVIDERS);
  let providers: AiProviderConfig[] = [];
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) providers = parsed as AiProviderConfig[];
    } catch {
      /* 损坏配置忽略，走默认 */
    }
  }
  // 兼容旧版单 Provider 字段（ai_api_key / ai_base_url / ai_model / ai_text_model / ai_audio_model）
  if (providers.length === 0) {
    const [apiKey, baseUrl, model, textModel, audioModel] = await Promise.all([
      getSetting(db, 'ai_api_key'),
      getSetting(db, 'ai_base_url'),
      getSetting(db, 'ai_model'),
      getSetting(db, 'ai_text_model'),
      getSetting(db, 'ai_audio_model'),
    ]);
    if (apiKey) {
      providers = [{
        ...ZHIPU_PROVIDER,
        apiKey,
        baseUrl: baseUrl?.trim() || ZHIPU_PROVIDER.baseUrl,
        textModel: textModel?.trim() || ZHIPU_PROVIDER.textModel,
        visionModel: model?.trim() || ZHIPU_PROVIDER.visionModel,
        audioModel: audioModel?.trim() || ZHIPU_PROVIDER.audioModel,
      }];
    }
  }
  // 智谱内置必须在列表首位（对齐参考项目：不可删除、始终存在）；避免重复
  if (!providers.some((p) => p.id === 'zhipu_glm')) {
    providers = [{ ...ZHIPU_PROVIDER }, ...providers];
  }
  const bindRaw = await getSetting(db, KEY_BINDING);
  let binding: AiBinding = { ...DEFAULT_BINDING };
  if (bindRaw) {
    try {
      const parsed = JSON.parse(bindRaw) as Partial<AiBinding>;
      binding = {
        textProviderId: parsed.textProviderId || DEFAULT_BINDING.textProviderId,
        visionProviderId: parsed.visionProviderId || DEFAULT_BINDING.visionProviderId,
        speechProviderId: parsed.speechProviderId || DEFAULT_BINDING.speechProviderId,
      };
    } catch {
      /* 损坏配置忽略，走默认 */
    }
  }
  // 绑定指向不存在的服务商 → 回退智谱（对齐参考项目 deleteProvider 重置逻辑）
  const ids = new Set(providers.map((p) => p.id));
  binding = {
    textProviderId: ids.has(binding.textProviderId) ? binding.textProviderId : 'zhipu_glm',
    visionProviderId: ids.has(binding.visionProviderId) ? binding.visionProviderId : 'zhipu_glm',
    speechProviderId: ids.has(binding.speechProviderId) ? binding.speechProviderId : 'zhipu_glm',
  };
  return { providers, binding };
}

/** 脱敏输出（不回显 Key 明文）：providers 列表 + has_key + 绑定 */
export function sanitizeAiConfig(cfg: AiConfig) {
  return {
    providers: cfg.providers.map((p) => ({
      id: p.id,
      name: p.name,
      is_built_in: Boolean(p.isBuiltIn),
      has_key: Boolean(p.apiKey),
      base_url: p.baseUrl,
      text_model: p.textModel,
      vision_model: p.visionModel,
      audio_model: p.audioModel,
    })),
    binding: cfg.binding,
  };
}

// GET /api/v1/settings/ai — 配置状态（不回显 Key 明文）
settingsRouter.get('/ai', async (c) => {
  const cfg = await getAiConfig(c.env.DB);
  return c.json(sanitizeAiConfig(cfg));
});

// PUT /api/v1/settings/ai — 保存（body: { providers?, binding? }；api_key 空字符串=保留原值/置空）
settingsRouter.put('/ai', async (c) => {
  const body = await c.req.json().catch(() => null) as {
    providers?: Array<{ id: string; name?: string; is_built_in?: boolean; api_key?: string; base_url?: string; text_model?: string; vision_model?: string; audio_model?: string }>;
    binding?: Partial<AiBinding>;
  } | null;
  if (!body) return c.json({ error: '请求体为空' }, 400);

  if (Array.isArray(body.providers)) {
    // 合并保留原 Key：列表内 api_key 未传或为空串时沿用旧值（避免前端必须持有明文）
    const prev = await getAiConfig(c.env.DB);
    const prevById = new Map(prev.providers.map((p) => [p.id, p]));
    const merged = body.providers.map((p) => {
      const old = prevById.get(p.id);
      // api_key: undefined=保留旧值；''=清空；非空=覆盖（前端不持有明文，未编辑过的服务商不带该字段）
      const apiKey = p.api_key === undefined ? (old?.apiKey ?? '') : p.api_key.trim();
      return {
        id: p.id,
        name: (p.name ?? '').trim() || old?.name || p.id,
        isBuiltIn: Boolean(p.is_built_in ?? old?.isBuiltIn ?? false),
        apiKey,
        baseUrl: p.base_url?.trim() || old?.baseUrl || ZHIPU_PROVIDER.baseUrl,
        textModel: p.text_model?.trim() || old?.textModel || ZHIPU_PROVIDER.textModel,
        visionModel: p.vision_model?.trim() || old?.visionModel || ZHIPU_PROVIDER.visionModel,
        audioModel: p.audio_model?.trim() || old?.audioModel || ZHIPU_PROVIDER.audioModel,
      };
    });
    // 智谱内置不可删除（对齐参考项目）：始终保底在列表（置顶）
    const finalProviders = merged.some((p) => p.id === 'zhipu_glm')
      ? merged
      : [{ ...ZHIPU_PROVIDER }, ...merged];
    await upsertSetting(c.env.DB, KEY_PROVIDERS, JSON.stringify(finalProviders));
  }
  if (body.binding) {
    const cfg = await getAiConfig(c.env.DB);
    const ids = new Set(cfg.providers.map((p) => p.id));
    const safe = (id?: string) => (id && ids.has(id) ? id : 'zhipu_glm');
    await upsertSetting(c.env.DB, KEY_BINDING, JSON.stringify({
      textProviderId: safe(body.binding.textProviderId),
      visionProviderId: safe(body.binding.visionProviderId),
      speechProviderId: safe(body.binding.speechProviderId),
    }));
  }
  const cfg = await getAiConfig(c.env.DB);
  return c.json(sanitizeAiConfig(cfg));
});