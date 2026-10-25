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
  sniffImageMime,
} from '../services/ai-parse';
import { assistantAnswer, listAiMemories, deleteAiMemory, clearAiMemories } from '../services/ai-assistant';
import { randomId } from '../lib/password';
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
  // 智谱视觉对图片字节数有上限（实测几 MB 即 1210"图片输入格式/解析错误"）；前端已压缩
  // （App aiPreparePhoto / 小程序 compressImage），超限直接拒并提示而非透传智谱再报错
  if (file.size > 1536 * 1024) {
    return c.json({ error: '图片过大（智谱识别上限约 1.5MB）：请重新拍照或换压缩后的图片再试' }, 400);
  }

  const bytes = new Uint8Array(await file.arrayBuffer());
  // 魔数识别真实格式（multipart Content-Type 可能被前端标错，如 PNG 标成 JPEG → 智谱 1210）
  const mime = sniffImageMime(bytes);
  if (!mime) {
    return c.json({ error: '图片格式不支持：请使用 JPG/PNG/WEBP 图片（iPhone 的 HEIC 请先转成 JPG）' }, 400);
  }
  try {
    const inv = await parsePhoto(ep, mime, bytes, purpose);
    return c.json({ ok: true, purpose, client: inv.client, date: inv.date, items: inv.items });
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
    const inv = await parseText(ep, text, purpose);
    return c.json({ ok: true, purpose, text, client: inv.client, date: inv.date, items: inv.items });
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
    const { text, client, date, items } = await parseVoice(sttEp, textEp, file.type, bytes, file.name || 'audio.webm', purpose);
    return c.json({ ok: true, purpose, text, client, date, items });
  } catch (err) {
    const msg = err instanceof Error ? err.message : '识别失败';
    return c.json({ error: msg }, 502);
  }
});

// POST /api/v1/ai/chat — AI 助手对话（问数+记忆）：客户端带多轮历史（messages），
// 服务端注入业务快照/动态查询/知识库/记忆后调文字模型回答；
// 对话历史服务端持久化（ai_conversations/ai_messages，跨设备续聊）；
// 支持"记住/忘记"指令（ai_memories，对齐参考 App Agent 记忆）；未配置 Key 返回 400。
aiRouter.post('/chat', async (c) => {
  const body = await c.req.json().catch(() => null) as {
    messages?: Array<{ role?: string; content?: string }>;
  } | null;
  const msgs = (body?.messages ?? [])
    .filter((m) => (m.role === 'user' || m.role === 'assistant') && (m.content ?? '').trim().length > 0)
    .map((m) => ({ role: m.role as 'user' | 'assistant', content: (m.content ?? '').trim().slice(0, 2000) }))
    .slice(-12);
  if (msgs.length === 0) return c.json({ error: '请输入要说的话' }, 400);
  const totalLen = msgs.reduce((s, m) => s + m.content.length, 0);
  if (totalLen > 10000) return c.json({ error: '内容过长（多轮合计上限 10000 字）' }, 400);
  const cfg = await getAiConfig(c.env.DB);
  const userId = c.get('user').id;
  const nowIso = () => new Date().toISOString();
  try {
    const { reply, sources } = await assistantAnswer(cfg, c.env.DB, msgs, c.get('user').role, userId);
    // 对话历史落库（用户级单会话）：取或建会话 → 追加 user 消息 + 助手回复
    const cur = await c.env.DB.prepare(
      'SELECT id FROM ai_conversations WHERE user_id = ? ORDER BY updated_at DESC LIMIT 1',
    ).bind(userId).first<{ id: string }>();
    let conversationId = cur?.id ?? '';
    if (!conversationId) {
      conversationId = randomId();
      await c.env.DB.prepare('INSERT INTO ai_conversations (id, user_id) VALUES (?, ?)')
        .bind(conversationId, userId).run();
    }
    const lastUserMsg = [...msgs].reverse().find((m) => m.role === 'user');
    const batch: D1PreparedStatement[] = [];
    if (lastUserMsg) {
      batch.push(c.env.DB.prepare(
        'INSERT INTO ai_messages (id, conversation_id, role, content, created_at) VALUES (?, ?, ?, ?, ?)',
      ).bind(randomId(), conversationId, 'user', lastUserMsg.content, nowIso()));
    }
    batch.push(c.env.DB.prepare(
      'INSERT INTO ai_messages (id, conversation_id, role, content, created_at) VALUES (?, ?, ?, ?, ?)',
    ).bind(randomId(), conversationId, 'assistant', reply, nowIso()));
    batch.push(c.env.DB.prepare('UPDATE ai_conversations SET updated_at = ? WHERE id = ?')
      .bind(nowIso(), conversationId));
    await c.env.DB.batch(batch);
    return c.json({
      ok: true, reply, conversation_id: conversationId,
      ...(sources.length > 0 ? { sources } : {}),
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'AI 助手接口错误';
    return c.json({ error: msg }, msg.includes('未启用') ? 400 : 502);
  }
});

// GET /api/v1/ai/chat/history — 最近对话历史（跨设备续聊；无会话返回空）
aiRouter.get('/chat/history', async (c) => {
  const userId = c.get('user').id;
  const cur = await c.env.DB.prepare(
    'SELECT id FROM ai_conversations WHERE user_id = ? ORDER BY updated_at DESC LIMIT 1',
  ).bind(userId).first<{ id: string }>();
  if (!cur) return c.json({ conversation_id: null, messages: [] });
  const rows = await c.env.DB.prepare(
    `SELECT role, content FROM ai_messages WHERE conversation_id = ?
     ORDER BY created_at ASC LIMIT 120`,
  ).bind(cur.id).all<{ role: string; content: string }>();
  return c.json({ conversation_id: cur.id, messages: rows.results });
});

// DELETE /api/v1/ai/chat/history — 清空对话历史（删会话+消息）
aiRouter.delete('/chat/history', async (c) => {
  const userId = c.get('user').id;
  const cur = await c.env.DB.prepare(
    'SELECT id FROM ai_conversations WHERE user_id = ? ORDER BY updated_at DESC LIMIT 1',
  ).bind(userId).first<{ id: string }>();
  if (cur) {
    await c.env.DB.prepare('DELETE FROM ai_messages WHERE conversation_id = ?').bind(cur.id).run();
    await c.env.DB.prepare('DELETE FROM ai_conversations WHERE id = ?').bind(cur.id).run();
  }
  return c.json({ ok: true });
});

// GET /api/v1/ai/memories — 助手记忆列表（记住的事项，管理页用）
aiRouter.get('/memories', async (c) => {
  const memories = await listAiMemories(c.env.DB, c.get('user').id);
  return c.json({ memories });
});

// DELETE /api/v1/ai/memories/:id — 遗忘一条记忆
aiRouter.delete('/memories/:id', async (c) => {
  const deleted = await deleteAiMemory(c.env.DB, c.get('user').id, c.req.param('id'));
  return c.json({ ok: true, deleted });
});

// DELETE /api/v1/ai/memories — 清空全部记忆
aiRouter.delete('/memories', async (c) => {
  await clearAiMemories(c.env.DB, c.get('user').id);
  return c.json({ ok: true });
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
    const inv = await parseText(ep, '白菜2斤每斤3元，土豆1斤每斤5元', 'purchase');
    return c.json({ ok: true, capability, items: inv.items, count: inv.items.length });
  } catch (err) {
    const msg = err instanceof Error ? err.message : '测试失败';
    return c.json({ error: msg }, 502);
  }
});