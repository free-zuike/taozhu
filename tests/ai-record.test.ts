/**
 * AI 一句话落单 + 权限体系（v0.17.478，对齐参考 App Agent 工具/权限/活动）：
 * record_transaction 授权门（ask → approve 后落库）、自动建商品、活动审计端点。
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { createFakeD1, fakeAssets, type FakeD1 } from './helpers/fake-d1';
import { resolveDraftItems, recordTransactionFromText } from '../src/services/ai-record';
import { setToolPolicy, toolPolicyFor } from '../src/services/ai-tools';
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

const PURCHASE_PARSE = '{"client":"","date":"","items":[{"name":"白菜","unit":"斤","quantity":2,"price":3},{"name":"土豆","unit":"斤","quantity":5,"price":2}]}';
const SALE_PARSE = '{"client":"老王批发部","date":"","items":[{"name":"白菜","unit":"斤","quantity":2,"price":3}]}';
const SALE_PARSE_MISSING = '{"client":"不存在的店","date":"","items":[{"name":"白菜","unit":"斤","quantity":2,"price":3}]}';

describe('resolveDraftItems 商品匹配/自动建', () => {
  let db: FakeD1;
  let token: string;
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };

  beforeEach(async () => {
    env = (await setup()).env;
    db = env.DB;
    token = await loginAdmin(env);
  });

  it('已存在商品精确匹配取价格；未匹配自动建商品（admin）', async () => {
    const item = await call(env, 'POST', '/api/v1/items', token, {
      name: '白菜', prices: [{ unit: '斤', purchase_price: 2.5, sale_price: 3.5 }],
    });
    expect(item.status).toBe(201);
    const drafts = [
      { name: '白菜', unit: '斤', quantity: 2, price: 3 },
      { name: '土豆', unit: '斤', quantity: 5, price: 2 },
    ];
    const resolved = await resolveDraftItems(db as never, 'purchase', drafts, 'admin');
    expect(resolved).toHaveLength(2);
    expect(resolved[0].auto_created).toBe(false);
    expect(resolved[1].auto_created).toBe(true);
    // 自动建的商品有价格行
    const row = await db.prepare('SELECT name FROM items WHERE id = ?').bind(resolved[1].item_id).first<{ name: string }>();
    expect(row?.name).toBe('土豆');
  });

  it('店员不自动建商品 → 抛错提示先添加', async () => {
    await expect(resolveDraftItems(db as never, 'purchase', [{ name: '新货', unit: '斤', quantity: 1, price: 9 }], 'staff'))
      .rejects.toThrow('不存在');
  });
});

describe('record_transaction 授权门与落单', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let db: FakeD1;
  let token: string;

  beforeEach(async () => {
    env = (await setup()).env;
    db = env.DB;
    token = await loginAdmin(env);
  });

  async function configureAi() {
    expect((await call(env, 'PUT', '/api/v1/settings/ai', token, {
      providers: [{ id: 'zhipu_glm', name: '智谱GLM', is_built_in: true, api_key: 'sk-test' }],
      binding: { textProviderId: 'zhipu_glm', visionProviderId: 'zhipu_glm', speechProviderId: 'zhipu_glm' },
    })).status).toBe(200);
  }

  /** 意图提取 → record JSON */
  function stubRecordIntent(text: string) {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      choices: [{ message: { content: `{"intent":"record","view":null,"start":null,"end":null,"client":null,"kind":"sale","year":null,"topics":[],"remember":null,"forget":null,"record":{"purpose":"purchase","text":"${text}"}}` } }],
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })));
  }

  /** approve 后：n=1 解析文本 → n=2 最终回答 */
  function stubApprove(parseJson: string, reply: string) {
    let n = 0;
    vi.stubGlobal('fetch', vi.fn(async () => {
      n++;
      const content = n === 1 ? parseJson : reply;
      return new Response(JSON.stringify({ choices: [{ message: { content } }] }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      });
    }));
  }

  it('POST /chat 记账意图 → need_approval；approve allow → 进货落库（自动建商品+FIFO批次+库存）', async () => {
    await configureAi();
    stubRecordIntent('记一笔进货：白菜2斤每斤3元，土豆5斤每斤2元');
    try {
      const post = await call(env, 'POST', '/api/v1/ai/chat', token, { messages: [{ role: 'user', content: '记一笔进货：白菜2斤每斤3元，土豆5斤每斤2元' }] });
      expect(post.status).toBe(200);
      const pend = (await post.json()) as { need_approval: boolean; approval_id: string; tool: { name: string }; preview: string };
      expect(pend.need_approval).toBe(true);
      expect(pend.tool.name).toBe('record_transaction');
      expect(pend.preview).toContain('一句话记账');

      stubApprove(PURCHASE_PARSE, '已记入账：进货 2 项。');
      const appr = await call(env, 'POST', '/api/v1/ai/chat/approve', token, {
        approval_id: pend.approval_id,
        decision: 'allow',
        messages: [{ role: 'user', content: '记一笔进货：白菜2斤每斤3元，土豆5斤每斤2元' }],
      });
      expect(appr.status).toBe(200);
      const body = (await appr.json()) as { ok: boolean; reply: string; order: { type: string; order_id: string; total: number; lines: unknown[] }; conversation_id: string };
      expect(body.ok).toBe(true);
      expect(body.order.type).toBe('purchase');
      expect(body.order.lines).toHaveLength(2);
      expect(body.conversation_id).toBeTruthy();

      // 落库验证：进货行 + FIFO 批次 + 库存
      const lines = await db.prepare('SELECT item_id, unit, quantity, purchase_price FROM purchase_items WHERE purchase_id = ?').bind(body.order.order_id).all<{ item_id: string; unit: string; quantity: number; purchase_price: number }>();
      expect(lines.results).toHaveLength(2);
      expect(lines.results[0].quantity).toBe(2);
      const batch = await db.prepare('SELECT remaining FROM stock_batches WHERE batch_id IN (SELECT id FROM purchase_items WHERE purchase_id = ?)').bind(body.order.order_id).all<{ remaining: number }>();
      expect(batch.results.reduce((s, b) => s + b.remaining, 0)).toBe(7);
      const stock = await db.prepare("SELECT COALESCE(SUM(quantity),0) AS q FROM stocks WHERE item_id = ?").bind(lines.results[0].item_id).first<{ q: number }>();
      expect(stock?.q).toBe(2);

      // 活动审计：run + 工具调用已记录
      const act = (await (await call(env, 'GET', '/api/v1/ai/activity', token)).json()) as { activity: Array<{ run: { intent: string }; tool_calls: Array<{ tool_name: string }> }> };
      expect(act.activity.length).toBeGreaterThan(0);
      expect(act.activity[0].tool_calls.map((t) => t.tool_name)).toContain('record_transaction');
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('出货落单需要店铺：不存在 → 400 提示；存在 → sale 落库（欠款联动）', async () => {
    await configureAi();
    await call(env, 'POST', '/api/v1/clients', token, { name: '老王批发部' });
    stubRecordIntent('给老王批发部记一笔：白菜2斤每斤3元');
    try {
      const post = await call(env, 'POST', '/api/v1/ai/chat', token, { messages: [{ role: 'user', content: '给老王批发部记一笔：白菜2斤每斤3元' }] });
      const pend = (await post.json()) as { approval_id: string; tool: { name: string } };
      expect(pend.tool.name).toBe('record_transaction');
      // 服务层 sale 分支：覆盖 fetch mock 为"解析文本"响应
      stubApprove(SALE_PARSE, '已入账。');
      const r = await recordTransactionFromText(db as never, { id: 'u1', username: 'boss', role: 'admin' }, 'sale', '给老王批发部记一笔：白菜2斤每斤3元');
      expect(r.type).toBe('sale');
      expect(r.client).toBe('老王批发部');
      const sale = await db.prepare('SELECT client_id FROM sale_items WHERE sale_id = ?').bind(r.order_id).first<{ client_id: string }>();
      expect(sale?.client_id).toBeTruthy();
      // 店铺不存在
      stubApprove(SALE_PARSE_MISSING, '已入账。');
      await expect(recordTransactionFromText(db as never, { id: 'u1', username: 'boss', role: 'admin' }, 'sale', '给不存在的店记一笔：白菜2斤每斤3元'))
        .rejects.toThrow('不存在');
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('always_allow 落单：写入策略免询问；always_deny 拒绝不落库', async () => {
    await configureAi();
    const uid = (await db.prepare("SELECT id FROM users WHERE username='boss'").first<{ id: string }>())!.id;
    await setToolPolicy(db as never, uid, 'record_transaction', 'allow');
    expect(await toolPolicyFor(db as never, uid, 'record_transaction')).toBe('allow');
    stubRecordIntent('记一笔进货：白菜2斤每斤3元');
    try {
      // allow 后 /chat 直接落单（不返回 need_approval）——意图 mock 的 record 路径直接执行
      // 这里 mock 只有 extractIntent 一次，后续 parseText 会再 fetch → 用多段 stub
      let n = 0;
      vi.stubGlobal('fetch', vi.fn(async () => {
        n++;
        const content = n === 1
          ? '{"intent":"record","view":null,"start":null,"end":null,"client":null,"kind":"sale","year":null,"topics":[],"remember":null,"forget":null,"record":{"purpose":"purchase","text":"记一笔进货：白菜2斤每斤3元"}}'
          : n === 2 ? PURCHASE_PARSE : '已入账。';
        return new Response(JSON.stringify({ choices: [{ message: { content } }] }), {
          status: 200, headers: { 'Content-Type': 'application/json' },
        });
      }));
      const post = await call(env, 'POST', '/api/v1/ai/chat', token, { messages: [{ role: 'user', content: '记一笔进货：白菜2斤每斤3元' }] });
      const body = JSON.parse(await post.text()) as { need_approval?: boolean; order?: { order_id: string }; ok: boolean };
      expect(body.need_approval).toBeUndefined();
      expect(body.order?.order_id).toBeTruthy();
      // always_deny：先恢复 ask 走授权门 → 拒绝后写入 deny 策略且不落库
      expect((await call(env, 'POST', '/api/v1/ai/tools/reset', token)).status).toBe(200);
      stubRecordIntent('记一笔进货：白菜2斤每斤3元');
      const post2 = await call(env, 'POST', '/api/v1/ai/chat', token, { messages: [{ role: 'user', content: '记一笔进货：白菜2斤每斤3元' }] });
      const pend2 = (await post2.json()) as { approval_id: string; tool: { name: string } };
      expect(pend2.tool.name).toBe('record_transaction');
      const appr = await call(env, 'POST', '/api/v1/ai/chat/approve', token, {
        approval_id: pend2.approval_id,
        decision: 'always_deny',
        messages: [{ role: 'user', content: '记一笔进货：白菜2斤每斤3元' }],
      });
      expect(appr.status).toBe(200);
      expect(((await appr.json()) as { reply: string }).reply).toContain('已取消');
      expect(await toolPolicyFor(db as never, uid, 'record_transaction')).toBe('deny');
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('GET /ai/tools 默认策略；PUT 设置 + reset 恢复默认', async () => {
    const t = (await (await call(env, 'GET', '/api/v1/ai/tools', token)).json()) as { tools: Array<{ name: string; permission: string; policy: string; default_policy: string }> };
    expect(t.tools.length).toBeGreaterThan(0);
    const rec = t.tools.find((x) => x.name === 'record_transaction');
    expect(rec?.permission).toBe('write');
    expect(rec?.policy).toBe('ask');
    const q = t.tools.find((x) => x.name === 'query_business_data');
    expect(q?.permission).toBe('read');
    expect(q?.policy).toBe('allow');
    expect((await call(env, 'PUT', '/api/v1/ai/tools/record_transaction', token, { policy: 'deny' })).status).toBe(200);
    expect((await call(env, 'PUT', '/api/v1/ai/tools/record_transaction', token, { policy: 'bogus' })).status).toBe(400);
    const after = (await (await call(env, 'GET', '/api/v1/ai/tools', token)).json()) as { tools: Array<{ name: string; policy: string }> };
    expect(after.tools.find((x) => x.name === 'record_transaction')?.policy).toBe('deny');
    expect((await call(env, 'POST', '/api/v1/ai/tools/reset', token)).status).toBe(200);
    const reset = (await (await call(env, 'GET', '/api/v1/ai/tools', token)).json()) as { tools: Array<{ name: string; policy: string; is_default: boolean }> };
    expect(reset.tools.find((x) => x.name === 'record_transaction')?.policy).toBe('ask');
    expect(reset.tools.every((x) => x.is_default)).toBe(true);
  });
});
