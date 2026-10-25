/**
 * AI 助手（对话问数）：buildAssistantContext 业务快照（店员打码）+ POST /ai/chat
 * 校验规则 + 请求体构造（mock fetch 验证 system 注入业务快照、多轮历史完整）。
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { createFakeD1, fakeAssets, type FakeD1 } from './helpers/fake-d1';
import { buildAssistantContext, chatWithAssistant } from '../src/services/ai-assistant';
import { DEFAULT_AI_CONFIG, type AiConfig } from '../src/services/ai-parse';

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
    { id: 'test_p', name: '测试', isBuiltIn: false, apiKey: 'k', baseUrl: 'https://ai.test/v1', textModel: 'm1', visionModel: '', audioModel: '' },
  ],
  binding: { textProviderId: 'test_p', visionProviderId: 'test_p', speechProviderId: 'test_p' },
};

describe('buildAssistantContext 业务快照', () => {
  let db: FakeD1;
  let token: string;
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };

  beforeEach(async () => {
    env = (await setup()).env;
    db = env.DB;
    token = await loginAdmin(env);
  });

  async function mkItem(name: string) {
    const create = await call(env, 'POST', '/api/v1/items', token, {
      name, prices: [{ unit: '斤', purchase_price: 2, sale_price: 3 }],
    });
    expect(create.status).toBe(201);
    const list = await call(env, 'GET', '/api/v1/items', token).then((r) => r.json()) as {
      items: Array<{ id: string; prices: Array<{ id: string }> }>;
    };
    const it = list.items.find((x) => x.name === name)!;
    return { id: it.id, price_id: it.prices[0].id };
  }

  it('admin 快照含毛利与欠款；店员快照打码不含', async () => {
    await call(env, 'POST', '/api/v1/clients', token, { name: 'A店' });
    const it = await mkItem('白菜');
    const today = new Date().toISOString().slice(0, 10);
    await call(env, 'POST', '/api/v1/purchases', token, { happened_at: today, items: [{ price_id: it.price_id, quantity: 10 }] });
    await call(env, 'POST', '/api/v1/sales', token, { client_id: '', happened_at: today, items: [{ price_id: it.price_id, quantity: 2 }] });
    // 出货指定 A 店（欠款）：直接插行更可控
    await db.prepare("INSERT INTO sale_items (id, sale_id, client_id, item_id, unit, quantity, sale_price, cost_price, amount, happened_at) VALUES ('s1','s1','c1','i1','斤',5,3,2,15,?)")
      .bind(today).run();
    await db.prepare("UPDATE clients SET id = 'c1' WHERE name = 'A店'").run();

    const adminCtx = await buildAssistantContext(db as never, 'admin');
    expect(adminCtx).toContain('毛利');
    expect(adminCtx).toContain('欠款');
    expect(adminCtx).toContain('A店');

    const staffCtx = await buildAssistantContext(db as never, 'staff');
    expect(staffCtx).not.toContain('毛利');
    expect(staffCtx).not.toContain('欠款');
    expect(staffCtx).toContain('出货');
  });

  it('快照含库存数据段（低库存/临期在无数据时不输出该段）', async () => {
    const ctx = await buildAssistantContext(db as never, 'admin');
    expect(ctx).toContain('业务概况');
    expect(ctx).toContain('今日');
    expect(ctx).not.toContain('低库存');
    expect(ctx).not.toContain('临期');
  });
});

describe('POST /api/v1/ai/chat', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let db: FakeD1;
  let token: string;

  beforeEach(async () => {
    env = (await setup()).env;
    db = env.DB;
    token = await loginAdmin(env);
  });

  it('未配置 Key → 400 引导到设置页', async () => {
    const r = await call(env, 'POST', '/api/v1/ai/chat', token, { messages: [{ role: 'user', content: '今天卖了多少？' }] });
    expect(r.status).toBe(400);
    expect(((await r.json()) as { error: string }).error).toContain('未启用');
  });

  it('空消息 / 内容过长 → 400；未登录 → 401', async () => {
    expect((await call(env, 'POST', '/api/v1/ai/chat', token, { messages: [] })).status).toBe(400);
    expect((await call(env, 'POST', '/api/v1/ai/chat', token, { messages: [{ role: 'user', content: '  ' }] })).status).toBe(400);
    expect((await call(env, 'POST', '/api/v1/ai/chat', token, { messages: [{ role: 'user', content: '好'.repeat(20001) }] })).status).toBe(400);
    expect((await call(env, 'POST', '/api/v1/ai/chat', undefined, { messages: [{ role: 'user', content: 'hi' }] })).status).toBe(401);
  });
});

describe('chatWithAssistant 请求构造（mock fetch）', () => {
  it('system 注入业务快照 + 多轮历史完整 + temperature 0.3', async () => {
    let captured: { body: Record<string, unknown>; url: string; headers: Record<string, string> } | null = null;
    vi.stubGlobal('fetch', vi.fn(async (url: string, init: RequestInit) => {
      captured = {
        url,
        body: JSON.parse(String(init.body)),
        headers: init.headers as Record<string, string>,
      };
      return new Response(JSON.stringify({ choices: [{ message: { content: '今天出货 3 笔，金额 ¥15。' } }] }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      });
    }));
    try {
      const reply = await chatWithAssistant(cfg, [
        { role: 'user', content: '今天卖了多少？' },
        { role: 'assistant', content: '让我查一下。' },
      ], '业务快照：测试数据\n本月出货 ¥100');
      expect(reply).toBe('今天出货 3 笔，金额 ¥15。');
      expect(captured).not.toBeNull();
      expect(captured!.url).toBe('https://ai.test/v1/chat/completions');
      expect(captured!.headers['Authorization']).toBe('Bearer k');
      const body = captured!.body as { model: string; temperature: number; messages: Array<{ role: string; content: string }> };
      expect(body.model).toBe('m1');
      expect(body.temperature).toBe(0.3);
      expect(body.messages.length).toBe(3); // system + 2 历史
      expect(body.messages[0].role).toBe('system');
      expect(body.messages[0].content).toContain('业务快照：测试数据');
      expect(body.messages[1]).toEqual({ role: 'user', content: '今天卖了多少？' });
      expect(body.messages[2]).toEqual({ role: 'assistant', content: '让我查一下。' });
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('无 Key → 抛错带配置提示；baseUrl 带 /chat/completions 后缀不重复拼', async () => {
    const cfgNoKey: AiConfig = {
      providers: [
        { id: 'a', name: 'x', isBuiltIn: false, apiKey: '', baseUrl: 'https://x/v1/chat/completions', textModel: 'm', visionModel: '', audioModel: '' },
      ],
      binding: { textProviderId: 'a', visionProviderId: 'a', speechProviderId: 'a' },
    };
    await expect(chatWithAssistant(cfgNoKey, [{ role: 'user', content: 'hi' }], 'ctx')).rejects.toThrow('未启用');
  });
});