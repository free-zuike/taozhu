/** AI 识别路由：POST /api/v1/ai/parse-photo（multipart 图片 → 商品草稿）
 *   POST /api/v1/ai/parse-text（JSON 文本 → 商品草稿，一句话记账）
 *   POST /api/v1/ai/parse-voice（multipart 音频 → 语音转文字后再解析，语音记账） */
import { Hono } from 'hono';
import { authMiddleware } from '../middleware/auth';
import {
  parsePhoto,
  parseText,
  parseVoice,
  speechToText,
  capabilityEndpoint,
  testVisionChannel,
  minimalWavBytes,
} from '../services/ai-parse';
import { getAiConfig } from './settings';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const aiRouter = new Hono<{ Bindings: Env; Variables: V }>();

aiRouter.use('*', authMiddleware());

// POST /api/v1/ai/parse-photo?purpose=purchase|sale  — multipart 字段 photo
aiRouter.post('/parse-photo', async (c) => {
  const purpose = c.req.query('purpose') === 'sale' ? 'sale' : 'purchase';
  const cfg = await getAiConfig(c.env.DB);
  const ep = capabilityEndpoint(cfg, 'vision');
  if (!ep.apiKey) {
    return c.json({ error: 'AI 拍照识别未启用：请老板在「我的 → AI 识别设置」配置 API Key 并绑定图片识别能力' }, 400);
  }
  let file: File | null = null;
  try {
    const form = await c.req.formData();
    const f = form.get('photo');
    // 后端无 DOM lib：用 typeof 区分 File（object）与 string
    if (f && typeof f === 'object') file = f as unknown as File;
  } catch {
    return c.json({ error: '请以 multipart 方式上传 photo 字段（图片）' }, 400);
  }
  if (!file) return c.json({ error: '请选择图片上传' }, 400);
  if (file.size === 0) return c.json({ error: '图片为空' }, 400);
  // 限制 10MB
  if (file.size > 10 * 1024 * 1024) return c.json({ error: '图片过大（上限 10MB）' }, 400);

  const bytes = new Uint8Array(await file.arrayBuffer());
  try {
    const drafts = await parsePhoto(ep, file.type, bytes, purpose);
    return c.json({ ok: true, purpose, items: drafts });
  } catch (err) {
    const msg = err instanceof Error ? err.message : '识别失败';
    return c.json({ error: msg }, 502);
  }
});

// POST /api/v1/ai/parse-text?purpose=purchase|sale — JSON { text }
aiRouter.post('/parse-text', async (c) => {
  const purpose = c.req.query('purpose') === 'sale' ? 'sale' : 'purchase';
  const cfg = await getAiConfig(c.env.DB);
  const ep = capabilityEndpoint(cfg, 'text');
  if (!ep.apiKey) {
    return c.json({ error: 'AI 记账未启用：请老板在「我的 → AI 识别设置」配置 API Key 并绑定文字记账能力' }, 400);
  }
  const body = await c.req.json().catch(() => null) as { text?: string } | null;
  const text = body?.text?.trim() ?? '';
  if (!text) return c.json({ error: '请输入要记账的文字（如：白菜50斤 3元一斤，土豆30斤 2元一斤）' }, 400);
  if (text.length > 2000) return c.json({ error: '文字过长（上限 2000 字）' }, 400);
  try {
    const items = await parseText(ep, text, purpose);
    return c.json({ ok: true, purpose, text, items });
  } catch (err) {
    const msg = err instanceof Error ? err.message : '识别失败';
    return c.json({ error: msg }, 502);
  }
});

// POST /api/v1/ai/parse-voice?purpose=purchase|sale — multipart 字段 audio
aiRouter.post('/parse-voice', async (c) => {
  const purpose = c.req.query('purpose') === 'sale' ? 'sale' : 'purchase';
  const cfg = await getAiConfig(c.env.DB);
  const sttEp = capabilityEndpoint(cfg, 'speech');
  const textEp = capabilityEndpoint(cfg, 'text');
  if (!sttEp.apiKey) {
    return c.json({ error: 'AI 语音记账未启用：请老板在「我的 → AI 识别设置」配置 API Key 并绑定语音记账能力' }, 400);
  }
  let file: File | null = null;
  try {
    const form = await c.req.formData();
    const f = form.get('audio');
    if (f && typeof f === 'object') file = f as unknown as File;
  } catch {
    return c.json({ error: '请以 multipart 方式上传 audio 字段（音频）' }, 400);
  }
  if (!file) return c.json({ error: '请选择录音上传' }, 400);
  if (file.size === 0) return c.json({ error: '音频为空' }, 400);
  if (file.size > 10 * 1024 * 1024) return c.json({ error: '音频过大（上限 10MB）' }, 400);
  const bytes = new Uint8Array(await file.arrayBuffer());
  try {
    const { text, items } = await parseVoice(sttEp, textEp, file.type, bytes, file.name || 'audio.webm', purpose);
    return c.json({ ok: true, purpose, text, items });
  } catch (err) {
    const msg = err instanceof Error ? err.message : '识别失败';
    return c.json({ error: msg }, 502);
  }
});

// POST /api/v1/ai/test?capability=text|vision|speech — 连通性测试（对齐参考项目 validate 三能力）：
//   用内置固定素材（文本话术 / 64x64 测试图 / 1 秒静音 WAV）各调一次对应模型，验证 Key/地址/模型可用。
//   不传 capability = 仅测文字记账（兼容旧前端）。
aiRouter.post('/test', async (c) => {
  const capability = c.req.query('capability') || 'text';
  const cfg = await getAiConfig(c.env.DB);
  try {
    if (capability === 'vision') {
      const ep = capabilityEndpoint(cfg, 'vision');
      if (!ep.apiKey) {
        return c.json({ error: '图片识别能力未启用：请先在「AI 识别设置」配置 API Key 并绑定图片识别能力' }, 400);
      }
      if (!ep.model) {
        return c.json({ error: '图片识别模型为空：请在「AI 识别设置」该服务商的编辑弹窗中填写图片识别模型' }, 400);
      }
      const reply = await testVisionChannel(ep);
      return c.json({ ok: true, capability, reply });
    }
    if (capability === 'speech') {
      const ep = capabilityEndpoint(cfg, 'speech');
      if (!ep.apiKey) {
        return c.json({ error: '语音记账能力未启用：请先在「AI 识别设置」配置 API Key 并绑定语音记账能力' }, 400);
      }
      if (!ep.model) {
        return c.json({ error: '语音记账模型为空：请在「AI 识别设置」该服务商的编辑弹窗中填写语音记账模型' }, 400);
      }
      // 静音 WAV 只验证通道连通（参考项目：静音返回空也算成功）
      await speechToText(ep, 'audio/wav', minimalWavBytes(), 'test.wav');
      return c.json({ ok: true, capability });
    }
    // text（默认）：跑一条固定话术，验证文字记账通道 + 解析能力
    const ep = capabilityEndpoint(cfg, 'text');
    if (!ep.apiKey) {
      return c.json({ error: 'AI 记账未启用：请先在「AI 识别设置」配置 API Key 并绑定文字记账能力' }, 400);
    }
    if (!ep.model) {
      return c.json({ error: '文字记账模型为空：请在「AI 识别设置」该服务商的编辑弹窗中填写文字记账模型' }, 400);
    }
    const items = await parseText(ep, '白菜2斤每斤3元，土豆1斤每斤5元', 'purchase');
    return c.json({ ok: true, capability, items, count: items.length });
  } catch (err) {
    const msg = err instanceof Error ? err.message : '测试失败';
    return c.json({ error: msg }, 502);
  }
});