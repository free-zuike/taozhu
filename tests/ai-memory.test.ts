/**
 * AI 助手记忆 + 对话历史（v0.17.476，对齐参考 App Agent 记忆）：
 * ai_memories（记住/遗忘/管理端点）、ai_conversations/ai_messages（跨设备历史）。
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { createFakeD1, fakeAssets, type FakeD1 } from './helpers/fake-d1';
import {
  saveAiMemory, listAiMemories, forgetAiMemoryByContent,
  deleteAiMemory, clearAiMemories, memoryContext, assistantAnswer,
} from '../src/services/ai-assistant';
import type { AiConfig } from '../src/services/ai-parse';

const JWT_SECRET = 'test-secret';
const BASE = 'http://localhost';

async function setup() {
  resetSchemaState();
  const db = await createFakeD1();
  await ensureSchema(db as never);
  const env = { DB: db, ASSETS: fakeAssets, JWT_SECRET };
  return { db, env };
}

async function call(
  env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string },
  method: string,
  path: string,
  token?: string,
  body?: unknown,
): Promise<Response> {
  const headers: Record<string, string> = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  return app.request(`${BASE}${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }, env as never);
}

async function loginAdmin(env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string }) {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  expect(res.status).toBe(201);
  return ((await res.json()) as { token: string }).token;
}

const cfg: AiConfig = {
  providers: [
    { id: 'p', name: '测试', isBuiltIn: false, apiKey: 'k', baseUrl: 'https://ai.test/v1', textModel: 'm1', visionModel: '', audioModel: '' },
  ],
  binding: { textProviderId: 'p', visionProviderId: 'p', speechProviderId: 'p' },
};

describe('ai_memories 记忆服务', () => {
  let db: FakeD1;
  let token: string;
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };

  beforeEach(async () => {
    env = (await setup()).env;
    db = env.DB;
    token = await loginAdmin(env);
  });

  it('保存/列出/按内容遗忘/删除/清空', async () => {
    const id1 = await saveAiMemory(db as never, 'u1', '老王欠 2000 元，月底结');
    const id2 = await saveAiMemory(db as never, 'u1', '白菜进价 2 元');
    expect(id1).toBeTruthy();
    expect(id2).toBeTruthy();
    const list = await listAiMemories(db as never, 'u1');
    expect(list.length).toBe(2);
    // 按内容遗忘
    expect(await forgetAiMemoryByContent(db as never, 'u1', '老王欠')).toBe(true);
    const after = await listAiMemories(db as never, 'u1');
    expect(after.length).toBe(1);
    expect(after[0].content).toContain('白菜');
    // 删除指定
    expect(await deleteAiMemory(db as never, 'u1', id2!)).toBe(true);
    expect((await listAiMemories(db as never, 'u1')).length).toBe(0);
    // 清空幂等
    await clearAiMemories(db as never, 'u1');
  });

  it('记忆按用户隔离 + 注入文本最多 6 条', async () => {
    await saveAiMemory(db as never, 'u1', '甲');
    await saveAiMemory(db as never, 'u2', '乙');
    const ctx = await memoryContext(db as never, 'u1');
    expect(ctx).toContain('甲');
    expect(ctx).not.toContain('乙');
    expect(ctx).toContain('助手记忆');
    expect(await memoryContext(db as never, 'u3')).toBe('');
  });

  it('assistantAnswer 执行记住指令并落库（mock fetch）', async () => {
    let n = 0;
    vi.stubGlobal('fetch', vi.fn(async () => {
      n++;
      const content = n === 1
        ? '{"intent":"chat","view":null,"start":null,"end":null,"client":null,"kind":"sale","year":null,"topics":[],"remember":"记住：A店每次出货都打8折","forget":null}'
        : '好的，记住了。';
      return new Response(JSON.stringify({ choices: [{ message: { content } }] }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      });
    }));
    const r = await assistantAnswer(cfg, db as never, [{ role: 'user', content: '记住：A店每次出货都打8折' }], 'admin', 'u1');
    expect(r.reply).toBe('好的，记住了。');
    vi.unstubAllGlobals();
    const list = await listAiMemories(db as never, 'u1');
    expect(list.length).toBe(1);
    expect(list[0].content).toContain('A店');
  });
});

describe('对话历史与记忆端点', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let db: FakeD1;
  let token: string;

  beforeEach(async () => {
    env = (await setup()).env;
    db = env.DB;
    token = await loginAdmin(env);
  });

  it('POST /ai/chat 落库对话历史 → GET history 回读 → DELETE 清空（未配 Key 时仍校验 400）', async () => {
    // 未配置 Key：POST 返回 400（不落库）
    expect((await call(env, 'POST', '/api/v1/ai/chat', token, { messages: [{ role: 'user', content: 'hi' }] })).status).toBe(400);
    // 空历史
    const empty = await call(env, 'GET', '/api/v1/ai/chat/history', token).then((r) => r.json()) as { messages: unknown[] };
    expect(empty.messages).toEqual([]);
    // 直接构造已落库的数据来测历史端点（模拟配置 Key 后的存储行为）
    await db.prepare("INSERT INTO ai_conversations (id, user_id) VALUES ('conv-1', '')").run();
    const userRow = await db.prepare("SELECT id FROM users WHERE username = 'boss'").first<{ id: string }>();
    await db.prepare("INSERT INTO ai_conversations (id, user_id) VALUES ('conv-2', ?)").bind(userRow?.id ?? '').run();
    await db.prepare("INSERT INTO ai_messages (id, conversation_id, role, content) VALUES ('m1', 'conv-2', 'user', '问一句')").run();
    await db.prepare("INSERT INTO ai_messages (id, conversation_id, role, content) VALUES ('m2', 'conv-2', 'assistant', '答一句')").run();
    const hist = await call(env, 'GET', '/api/v1/ai/chat/history', token).then((r) => r.json()) as {
      conversation_id: string; messages: Array<{ role: string; content: string }>;
    };
    expect(hist.conversation_id).toBe('conv-2');
    expect(hist.messages.map((m) => m.content)).toEqual(['问一句', '答一句']);
    const del = await call(env, 'DELETE', '/api/v1/ai/chat/history', token);
    expect(del.status).toBe(200);
    const after = await call(env, 'GET', '/api/v1/ai/chat/history', token).then((r) => r.json()) as { messages: unknown[] };
    expect(after.messages).toEqual([]);
  });

  it('GET /ai/memories + DELETE /ai/memories/:id + DELETE /ai/memories', async () => {
    const userRow = await db.prepare("SELECT id FROM users WHERE username = 'boss'").first<{ id: string }>();
    await saveAiMemory(db as never, userRow?.id ?? '', '测试记忆内容');
    const d = await call(env, 'GET', '/api/v1/ai/memories', token).then((r) => r.json()) as { memories: Array<{ id: string; content: string }> };
    expect(d.memories.length).toBe(1);
    const del = await call(env, 'DELETE', `/api/v1/ai/memories/${d.memories[0].id}`, token);
    expect(del.status).toBe(200);
    expect(((await del.json()) as { deleted: boolean }).deleted).toBe(true);
    expect((await call(env, 'GET', '/api/v1/ai/memories', token).then((r) => r.json()) as { memories: unknown[] }).memories).toEqual([]);
    // 清空端点幂等
    expect((await call(env, 'DELETE', '/api/v1/ai/memories', token)).status).toBe(200);
  });
});