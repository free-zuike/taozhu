/**
 * AI 助手（对话问数）：buildAssistantContext 业务快照（店员打码）+ POST /ai/chat
 * 校验规则 + 请求体构造（mock fetch 验证 system 注入业务快照、多轮历史完整）。
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { createFakeD1, fakeAssets, type FakeD1 } from './helpers/fake-d1';
import {
  buildAssistantContext, chatWithAssistant, extractIntent, runBusinessQuery,
  pickKbEntries, assistantAnswer,
  saveAiMemory, listAiMemories, forgetAiMemoryByContent, deleteAiMemory, clearAiMemories,
} from '../src/services/ai-assistant';
import { DEFAULT_AI_CONFIG, type AiConfig } from '../src/services/ai-parse';
import { createAiPayment } from '../src/services/ai-record';
import { localTodayISO, parseMonthRange } from '../src/lib/biz-date';

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
    const today = localTodayISO();
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

describe('动态查询与知识库（0.17.475）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let db: FakeD1;
  let token: string;

  beforeEach(async () => {
    env = (await setup()).env;
    db = env.DB;
    token = await loginAdmin(env);
  });

  async function mkItem(name: string, sale = 3, purchase = 2) {
    await call(env, 'POST', '/api/v1/items', token, { name, prices: [{ unit: '斤', purchase_price: purchase, sale_price: sale }] });
    const list = await call(env, 'GET', '/api/v1/items', token).then((r) => r.json()) as {
      items: Array<{ id: string; prices: Array<{ id: string }> }>;
    };
    return list.items.find((x) => x.name === name)!;
  }

  it('runBusinessQuery summary：任意区间出货/毛利/收款/进货；staff 无毛利', async () => {
    const it = await mkItem('白菜', 3, 2);
    await call(env, 'POST', '/api/v1/clients', token, { name: 'A店' });
    const cl = ((await call(env, 'GET', '/api/v1/clients', token).then((r) => r.json())) as { clients: Array<{ id: string }> }).clients[0];
    await call(env, 'POST', '/api/v1/purchases', token, { happened_at: '2026-08-01', items: [{ price_id: it.prices[0].id, quantity: 10 }] });
    await call(env, 'POST', '/api/v1/sales', token, { client_id: cl.id, happened_at: '2026-08-05', items: [{ price_id: it.prices[0].id, quantity: 4 }] });

    const admin = await runBusinessQuery(db as never, 'admin', {
      intent: 'query', view: 'summary', start: '2026-08-01', end: '2026-08-31',
      client: null, kind: 'sale', year: null, topics: [],
    });
    expect(admin).toContain('出货 1 笔');
    expect(admin).toContain('¥12'); // 4×3
    expect(admin).toContain('毛利');
    expect(admin).toContain('¥4'); // 4×(3-2)

    const staff = await runBusinessQuery(db as never, 'staff', {
      intent: 'query', view: 'summary', start: '2026-08-01', end: '2026-08-31',
      client: null, kind: 'sale', year: null, topics: [],
    });
    expect(staff).toContain('出货 1 笔');
    expect(staff).not.toContain('毛利');
  });

  it('runBusinessQuery clients：按店出货+欠款；debts staff 无权返回 null；items 排行', async () => {
    const it = await mkItem('土豆', 5, 3);
    await call(env, 'POST', '/api/v1/clients', token, { name: 'B店' });
    const cl = ((await call(env, 'GET', '/api/v1/clients', token).then((r) => r.json())) as { clients: Array<{ id: string }> }).clients[0];
    await call(env, 'POST', '/api/v1/sales', token, { client_id: cl.id, happened_at: '2026-09-01', items: [{ price_id: it.prices[0].id, quantity: 2 }] });

    const byClient = await runBusinessQuery(db as never, 'admin', {
      intent: 'query', view: 'clients', start: '2026-09-01', end: '2026-09-30',
      client: null, kind: 'sale', year: null, topics: [],
    });
    expect(byClient).toContain('B店');
    expect(byClient).toContain('¥10');
    expect(byClient).toContain('欠款');

    const debts = await runBusinessQuery(db as never, 'admin', {
      intent: 'query', view: 'debts', start: null, end: null, client: null, kind: 'sale', year: null, topics: [],
    });
    expect(debts).toContain('B店');
    const staffDebts = await runBusinessQuery(db as never, 'staff', {
      intent: 'query', view: 'debts', start: null, end: null, client: null, kind: 'sale', year: null, topics: [],
    });
    expect(staffDebts).toBeNull();

    const items = await runBusinessQuery(db as never, 'admin', {
      intent: 'query', view: 'items', start: '2026-09-01', end: '2026-09-30',
      client: null, kind: 'sale', year: null, topics: [],
    });
    expect(items).toContain('土豆');
    expect(items).toContain('¥10');
  });

  it('runBusinessQuery 指定店铺时各视角只返回该店（修：clients/debts/monthly/daily/items 不再忽略 client_id）', async () => {
    const it = await mkItem('萝卜', 4, 2);
    await call(env, 'POST', '/api/v1/clients', token, { name: '甲店' });
    await call(env, 'POST', '/api/v1/clients', token, { name: '乙店' });
    const cls = ((await call(env, 'GET', '/api/v1/clients', token).then((r) => r.json())) as { clients: Array<{ name: string; id: string }> }).clients;
    const a = cls.find((c) => c.name === '甲店')!;
    const b = cls.find((c) => c.name === '乙店')!;
    await call(env, 'POST', '/api/v1/sales', token, { client_id: a.id, happened_at: '2026-10-05', items: [{ price_id: it.prices[0].id, quantity: 3 }] }); // ¥12
    await call(env, 'POST', '/api/v1/sales', token, { client_id: b.id, happened_at: '2026-10-06', items: [{ price_id: it.prices[0].id, quantity: 5 }] }); // ¥20

    const base = { intent: 'query' as const, start: '2026-10-01', end: '2026-10-31', client: '甲店', kind: 'sale' as const, year: null, topics: [] };

    const byClient = await runBusinessQuery(db as never, 'admin', { ...base, view: 'clients' });
    expect(byClient).toContain('甲店');
    expect(byClient).not.toContain('乙店');
    expect(byClient).toContain('¥12');

    const monthly = await runBusinessQuery(db as never, 'admin', { ...base, view: 'monthly', year: 2026 });
    expect(monthly).toContain('10月 ¥12');
    expect(monthly).not.toContain('乙店');

    const daily = await runBusinessQuery(db as never, 'admin', { ...base, view: 'daily' });
    expect(daily).toContain('2026-10-05');
    expect(daily).toContain('¥12');
    expect(daily).not.toContain('2026-10-06'); // 乙店那天不应混入

    const debts = await runBusinessQuery(db as never, 'admin', { ...base, view: 'debts', start: null, end: null });
    expect(debts).toContain('甲店');
    expect(debts).not.toContain('乙店');

    const items = await runBusinessQuery(db as never, 'admin', { ...base, view: 'items' });
    expect(items).toContain('萝卜');
    expect(items).toContain('¥12');
    expect(items).not.toContain('¥20'); // 乙店的出货不应混入
  });

  it('runBusinessQuery clients 视角欠款按累计算（修：误用区间出货减累计收款）', async () => {
    const it = await mkItem('债测品', 1, 1);
    await call(env, 'POST', '/api/v1/clients', token, { name: '债测店甲' });
    const a = ((await call(env, 'GET', '/api/v1/clients', token).then((r) => r.json())) as { clients: Array<{ name: string; id: string }> }).clients.find((c) => c.name === '债测店甲')!;
    await call(env, 'POST', '/api/v1/sales', token, { client_id: a.id, happened_at: '2026-08-05', items: [{ price_id: it.prices[0].id, quantity: 20 }] }); // ¥20（8月）
    await call(env, 'POST', '/api/v1/sales', token, { client_id: a.id, happened_at: '2026-09-05', items: [{ price_id: it.prices[0].id, quantity: 10 }] }); // ¥10（9月）

    // 只查 9 月区间：区间出货应为 ¥10，但欠款（累计出货−累计收款）应为 ¥30，不能误用区间 ¥10。
    const r = await runBusinessQuery(db as never, 'admin', {
      intent: 'query', view: 'clients', start: '2026-09-01', end: '2026-09-30', client: null, kind: 'sale', year: null, topics: [],
    });
    expect(r).toContain('债测店甲');
    expect(r).toContain('¥10'); // 9 月区间出货
    expect(r).toContain('¥30'); // 累计欠款（8月20 + 9月10，无收款）
  });

  it('client_ledger：单店真实流水 + 差额/重复单线索；店员无权查看', async () => {
    const it = await mkItem('对账品', 10, 5);
    await call(env, 'POST', '/api/v1/clients', token, { name: '对账店' });
    const cl = ((await call(env, 'GET', '/api/v1/clients', token).then((r) => r.json())) as { clients: Array<{ id: string }> }).clients[0];
    await call(env, 'POST', '/api/v1/sales', token, { client_id: cl.id, happened_at: '2026-11-01', items: [{ price_id: it.prices[0].id, quantity: 2 }] });
    await call(env, 'POST', '/api/v1/sales', token, { client_id: cl.id, happened_at: '2026-11-02', items: [{ price_id: it.prices[0].id, quantity: 2 }] });
    await call(env, 'POST', '/api/v1/payments', token, { client_id: cl.id, happened_at: '2026-11-03', amount: 20 });
    const q = {
      intent: 'query' as const, view: 'client_ledger', start: '2026-11-01', end: '2026-11-30',
      client: '对账店', kind: 'sale' as const, year: null, topics: [], diff: 20,
      remember: null, forget: null, record: null, payment: null,
    };
    const r = await runBusinessQuery(db as never, 'admin', q);
    expect(r).toContain('对账店 对账明细');
    expect(r).toContain('出货单 2 张');
    expect(r).toContain('收款 1 笔');
    expect(r).toContain('金额接近差额 ¥20');
    expect(r).toContain('同金额重复出现的单据');
    expect(r).toContain('仅供人工核对');
    const staff = await runBusinessQuery(db as never, 'staff', q);
    expect(staff).toBeNull();
  });

  it('createAiPayment：补录收款写库 + 变更流 + 快照失效，金额绝不臆造', async () => {
    await call(env, 'POST', '/api/v1/clients', token, { name: '补录店' });
    await call(env, 'GET', '/api/v1/clients', token); // 预热一份派生快照
    const before = await db.prepare("SELECT COUNT(*) AS n FROM schema_meta WHERE key LIKE 'snapshot:%'").first<{ n: number }>();
    expect(before!.n).toBeGreaterThan(0);

    const u = await db.prepare('SELECT id, username FROM users LIMIT 1').first<{ id: string; username: string }>();
    const user = { id: u!.id, username: u!.username, role: 'admin' }; // created_by 有外键，必须用真实用户
    const r = await createAiPayment(db as never, user, {
      client: '补录店', amount: 380, date: '2026-11-07', note: '对方说已付',
    });
    expect(r.client).toBe('补录店');
    const row = await db.prepare('SELECT amount, happened_at, note FROM payments WHERE id = ?')
      .bind(r.id).first<{ amount: number; happened_at: string; note: string }>();
    expect(row!.amount).toBe(380);
    expect(row!.happened_at).toContain('2026-11-07');
    expect(row!.note).toContain('待核对');
    const changes = await db.prepare("SELECT COUNT(*) AS n FROM sync_changes WHERE entity_type = 'payment'").first<{ n: number }>();
    expect(changes!.n).toBeGreaterThan(0);
    const after = await db.prepare("SELECT COUNT(*) AS n FROM schema_meta WHERE key LIKE 'snapshot:%'").first<{ n: number }>();
    expect(after!.n).toBe(0); // 欠款/计数快照已失效，下次请求必重算

    await expect(createAiPayment(db as never, user, { client: '不存在的店', amount: 1, date: null, note: null })).rejects.toThrow(/不存在/);
    await expect(createAiPayment(db as never, user, { client: '补录店', amount: 0, date: null, note: null })).rejects.toThrow(/大于 0/);
  });

  it('runBusinessQuery monthly/daily/years 基本形状', async () => {
    const it = await mkItem('茄子', 4, 2);
    await call(env, 'POST', '/api/v1/clients', token, { name: 'C店' });
    const cl = ((await call(env, 'GET', '/api/v1/clients', token).then((r) => r.json())) as { clients: Array<{ id: string }> }).clients[0];
    await call(env, 'POST', '/api/v1/purchases', token, { happened_at: '2026-07-01', items: [{ price_id: it.prices[0].id, quantity: 5 }] });
    await call(env, 'POST', '/api/v1/sales', token, { client_id: cl.id, happened_at: '2026-07-15', items: [{ price_id: it.prices[0].id, quantity: 3 }] });

    const monthly = await runBusinessQuery(db as never, 'admin', {
      intent: 'query', view: 'monthly', start: null, end: null, client: null, kind: 'sale', year: 2026, topics: [],
    });
    expect(monthly).toContain('2026');
    expect(monthly).toContain('¥12');

    const daily = await runBusinessQuery(db as never, 'admin', {
      intent: 'query', view: 'daily', start: '2026-07-01', end: '2026-07-31',
      client: null, kind: 'sale', year: null, topics: [],
    });
    expect(daily).toContain('2026-07-15');

    const years = await runBusinessQuery(db as never, 'admin', {
      intent: 'query', view: 'years', start: null, end: null, client: null, kind: 'sale', year: null, topics: [],
    });
    expect(years).toContain('2026');
  });

  it('extractIntent 解析模型 JSON（mock fetch）；非法输出返回 null', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(
      JSON.stringify({ choices: [{ message: { content: '```json\n{"intent":"query","view":"summary","start":"2026-09-01","end":"2026-09-30","client":"A店","kind":"sale","year":null,"topics":[]}\n```' } }] }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    )));
    const intent = await extractIntent(cfg, '上个月卖了多少钱？', '业务概况（截至 2026-10-25）：');
    expect(intent?.intent).toBe('query');
    expect(intent?.view).toBe('summary');
    expect(intent?.start).toBe('2026-09-01');
    expect(intent?.client).toBe('A店');
    vi.unstubAllGlobals();

    vi.stubGlobal('fetch', vi.fn(async () => new Response('not json', { status: 500 })));
    expect(await extractIntent(cfg, 'hi', 'ctx')).toBeNull();
    vi.unstubAllGlobals();
  });

  it('pickKbEntries 关键词匹配：命中条目按数量排序截断', () => {
    const picked = pickKbEntries('库存怎么盘点？', 3);
    expect(picked.length).toBeGreaterThan(0);
    expect(picked[0].title).toContain('库存');
    const none = pickKbEntries('完全无关的内容', 3);
    expect(none).toEqual([]);
  });

  it('assistantAnswer：意图 query → 查数据注入 → 最终回答；sources 仅在知识库命中时返回', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => {
      return new Response(JSON.stringify({ choices: [{ message: { content: '没有更多内容' } }] }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      });
    }));
    // 意图提取返回 chat（第二次调用即 final 回答需要真实文本）——用调用序号区分
    let n = 0;
    vi.stubGlobal('fetch', vi.fn(async () => {
      n++;
      const content = n === 1
        ? '{"intent":"kb","view":null,"start":null,"end":null,"client":null,"kind":"sale","year":null,"topics":["库存"]}'
        : '盘点在库存页右上角，按实际数量校对，差异自动调整。';
      return new Response(JSON.stringify({ choices: [{ message: { content } }] }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      });
    }));
    const r = await assistantAnswer(cfg, db as never, [{ role: 'user', content: '库存怎么盘点？' }], 'admin', 'user-1');
    expect(r.reply).toContain('盘点');
    expect(r.sources).toContain('库存与盘点');
    vi.unstubAllGlobals();
  });
});

describe('AI 记忆与对话历史（0.17.476）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let db: FakeD1;
  let token: string;

  beforeEach(async () => {
    env = (await setup()).env;
    db = env.DB;
    token = await loginAdmin(env);
  });

  /** 配置文字能力 Key（路由层 /ai/chat 依赖） */
  async function configureAi() {
    const r = await call(env, 'PUT', '/api/v1/settings/ai', token, {
      providers: [{ id: 'zhipu_glm', name: '智谱GLM', is_built_in: true, api_key: 'sk-test' }],
      binding: { textProviderId: 'zhipu_glm', visionProviderId: 'zhipu_glm', speechProviderId: 'zhipu_glm' },
    });
    expect(r.status).toBe(200);
  }

  /** mock fetch：第 1 次调用（意图提取）返回 intentJson，第 2 次（最终回答）返回 reply */
  function stubTwoStep(intentJson: string, reply: string) {
    let n = 0;
    vi.stubGlobal('fetch', vi.fn(async () => {
      n++;
      const content = n === 1 ? intentJson : reply;
      return new Response(JSON.stringify({ choices: [{ message: { content } }] }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      });
    }));
  }

  /** mock fetch：所有调用都返回同一文本（approve 流程只需最终回答一次） */
  function stubReply(text: string) {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(
      JSON.stringify({ choices: [{ message: { content: text } }] }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    )));
  }

  const chatIntent = '{"intent":"chat","view":null,"start":null,"end":null,"client":null,"kind":"sale","year":null,"topics":[],"remember":null,"forget":null}';

  it('记忆 service：保存/列出/按内容遗忘/删除/清空 + 用户隔离', async () => {
    const id1 = await saveAiMemory(db as never, 'u1', '老王欠款 2000 元');
    expect(id1).toBeTruthy();
    await saveAiMemory(db as never, 'u1', '老张喜欢 3 号箱苹果');
    await saveAiMemory(db as never, 'u2', '用户二的私密记忆');

    let list = await listAiMemories(db as never, 'u1');
    expect(list).toHaveLength(2);
    expect(list.map((m) => m.content)).toContain('老王欠款 2000 元');
    // 用户隔离：u1 看不到 u2 的记忆
    const listU2 = await listAiMemories(db as never, 'u2');
    expect(listU2).toHaveLength(1);
    expect(listU2[0].content).toBe('用户二的私密记忆');

    // 按内容模糊匹配遗忘（软删）
    expect(await forgetAiMemoryByContent(db as never, 'u1', '老王欠款')).toBe(true);
    list = await listAiMemories(db as never, 'u1');
    expect(list).toHaveLength(1);
    expect(list[0].content).toBe('老张喜欢 3 号箱苹果');

    // 删除指定 id；别人的 id 删不动
    expect(await deleteAiMemory(db as never, 'u1', list[0].id)).toBe(true);
    expect(await deleteAiMemory(db as never, 'u1', listU2[0].id)).toBe(false);
    expect(await listAiMemories(db as never, 'u1')).toHaveLength(0);

    // 清空
    await saveAiMemory(db as never, 'u2', '再来一条');
    await clearAiMemories(db as never, 'u2');
    expect(await listAiMemories(db as never, 'u2')).toHaveLength(0);
  });

  it('POST /ai/chat 落库对话历史 → GET /ai/chat/history 回读 → DELETE /ai/chat/history 清空', async () => {
    await configureAi();
    stubTwoStep(chatIntent, '你好！有什么经营问题想问我？');
    try {
      const post = await call(env, 'POST', '/api/v1/ai/chat', token, {
        messages: [
          { role: 'user', content: '你好' },
          { role: 'assistant', content: '你好！' },
          { role: 'user', content: '今天生意怎么样？' },
        ],
      });
      expect(post.status).toBe(200);
      const postBody = (await post.json()) as { ok: boolean; reply: string; conversation_id: string };
      expect(postBody.ok).toBe(true);
      expect(postBody.conversation_id).toBeTruthy();

      const hist = (await (await call(env, 'GET', '/api/v1/ai/chat/history', token)).json()) as {
        conversation_id: string | null;
        messages: Array<{ role: string; content: string }>;
      };
      expect(hist.conversation_id).toBe(postBody.conversation_id);
      // 落库最后一条 user 消息 + 助手回复（created_at 同毫秒时顺序不定，按内容断言）
      expect(hist.messages.filter((m) => m.role === 'user')).toHaveLength(1);
      expect(hist.messages.filter((m) => m.role === 'assistant')).toHaveLength(1);
      expect(hist.messages.map((m) => `${m.role}:${m.content}`)).toContain('user:今天生意怎么样？');
      expect(hist.messages.map((m) => `${m.role}:${m.content}`)).toContain(`assistant:${postBody.reply}`);

      expect((await call(env, 'DELETE', '/api/v1/ai/chat/history', token)).status).toBe(200);
      const after = (await (await call(env, 'GET', '/api/v1/ai/chat/history', token)).json()) as {
        conversation_id: string | null; messages: unknown[];
      };
      expect(after.conversation_id).toBeNull();
      expect(after.messages).toEqual([]);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('补录收款走授权门：未确认绝不入账，approve 后写入 payments', async () => {
    await configureAi();
    await call(env, 'POST', '/api/v1/clients', token, { name: 'AI补录店' });
    try {
      const msg = '给AI补录店补录一笔 380 元收款';
      stubTwoStep(
        '{"intent":"chat","view":null,"start":null,"end":null,"client":null,"kind":"sale","year":null,"topics":[],"remember":null,"forget":null,"record":null,"diff":null,"payment":{"client":"AI补录店","amount":380,"date":"2026-11-07","note":null}}',
        '已补录。',
      );
      const post = await call(env, 'POST', '/api/v1/ai/chat', token, { messages: [{ role: 'user', content: msg }] });
      expect(post.status).toBe(200);
      const pend = (await post.json()) as { need_approval: boolean; approval_id: string; tool: { name: string; label: string } };
      expect(pend.need_approval).toBe(true);
      expect(pend.tool.name).toBe('create_payment');
      expect(pend.tool.label).toBe('补录收款');
      // 确认前绝不入账（不能让 AI 自己平账）
      const before = await db.prepare('SELECT COUNT(*) AS n FROM payments').first<{ n: number }>();
      expect(before!.n).toBe(0);

      stubReply('已补录收款 ¥380，请与对方核对。');
      const appr = await call(env, 'POST', '/api/v1/ai/chat/approve', token, {
        approval_id: pend.approval_id, decision: 'allow', messages: [{ role: 'user', content: msg }],
      });
      expect(appr.status).toBe(200);
      const after = await db.prepare('SELECT amount, note FROM payments').first<{ amount: number; note: string }>();
      expect(after!.amount).toBe(380);
      expect(after!.note).toContain('待核对');
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('对话"记住/忘记"走授权门（ask → approve 后落库）；管理端点单删与清空', async () => {
    await configureAi();
    try {
      // 记住：POST /chat 返回 need_approval → approve allow 后落库
      stubTwoStep(
        '{"intent":"chat","view":null,"start":null,"end":null,"client":null,"kind":"sale","year":null,"topics":[],"remember":"老王欠款 2000 元","forget":null,"record":null}',
        '好的，我记住了。',
      );
      const post1 = await call(env, 'POST', '/api/v1/ai/chat', token, { messages: [{ role: 'user', content: '记住：老王欠款 2000 元' }] });
      expect(post1.status).toBe(200);
      const pend = (await post1.json()) as { need_approval: boolean; approval_id: string; tool: { name: string } };
      expect(pend.need_approval).toBe(true);
      expect(pend.tool.name).toBe('save_memory');
      expect(pend.approval_id).toBeTruthy();
      stubReply('好的，我记住了。');
      const appr1 = await call(env, 'POST', '/api/v1/ai/chat/approve', token, {
        approval_id: pend.approval_id,
        decision: 'allow',
        messages: [{ role: 'user', content: '记住：老王欠款 2000 元' }],
      });
      expect(appr1.status).toBe(200);
      expect(((await appr1.json()) as { reply: string }).reply).toContain('记住');
      const mem1 = (await (await call(env, 'GET', '/api/v1/ai/memories', token)).json()) as { memories: Array<{ id: string; content: string }> };
      expect(mem1.memories).toHaveLength(1);
      expect(mem1.memories[0].content).toBe('老王欠款 2000 元');

      // 忘记（同样走授权门）
      stubTwoStep(
        '{"intent":"chat","view":null,"start":null,"end":null,"client":null,"kind":"sale","year":null,"topics":[],"remember":null,"forget":"老王欠款","record":null}',
        '好的，已忘记。',
      );
      const post2 = await call(env, 'POST', '/api/v1/ai/chat', token, { messages: [{ role: 'user', content: '忘记老王欠款' }] });
      const pend2 = (await post2.json()) as { approval_id: string; tool: { name: string } };
      expect(pend2.tool.name).toBe('forget_memory');
      stubReply('好的，已忘记。');
      await call(env, 'POST', '/api/v1/ai/chat/approve', token, {
        approval_id: pend2.approval_id,
        decision: 'allow',
        messages: [{ role: 'user', content: '忘记老王欠款' }],
      });
      const mem2 = (await (await call(env, 'GET', '/api/v1/ai/memories', token)).json()) as { memories: unknown[] };
      expect(mem2.memories).toHaveLength(0);

      // always_allow：写入策略，后续免询问
      stubTwoStep(
        '{"intent":"chat","view":null,"start":null,"end":null,"client":null,"kind":"sale","year":null,"topics":[],"remember":"临时事项","forget":null,"record":null}',
        '好的。',
      );
      const post3 = await call(env, 'POST', '/api/v1/ai/chat', token, { messages: [{ role: 'user', content: '记住：临时事项' }] });
      const pend3 = (await post3.json()) as { approval_id: string };
      stubReply('好的。');
      await call(env, 'POST', '/api/v1/ai/chat/approve', token, {
        approval_id: pend3.approval_id,
        decision: 'always_allow',
        messages: [{ role: 'user', content: '记住：临时事项' }],
      });
      const tools = (await (await call(env, 'GET', '/api/v1/ai/tools', token)).json()) as { tools: Array<{ name: string; policy: string }> };
      expect(tools.tools.find((t) => t.name === 'save_memory')?.policy).toBe('allow');

      // 管理端点：单删
      const mem3 = (await (await call(env, 'GET', '/api/v1/ai/memories', token)).json()) as { memories: Array<{ id: string }> };
      expect(mem3.memories).toHaveLength(1);
      const delOne = await call(env, 'DELETE', `/api/v1/ai/memories/${mem3.memories[0].id}`, token);
      expect(delOne.status).toBe(200);
      const mem4 = (await (await call(env, 'GET', '/api/v1/ai/memories', token)).json()) as { memories: unknown[] };
      expect(mem4.memories).toHaveLength(0);

      // 管理端点：清空全部（策略 allow 后免询问直接记住）
      stubTwoStep(
        '{"intent":"chat","view":null,"start":null,"end":null,"client":null,"kind":"sale","year":null,"topics":[],"remember":"再来一条","forget":null,"record":null}',
        '好的。',
      );
      await call(env, 'POST', '/api/v1/ai/chat', token, { messages: [{ role: 'user', content: '记住：再来一条' }] });
      const mem5 = (await (await call(env, 'GET', '/api/v1/ai/memories', token)).json()) as { memories: unknown[] };
      expect(mem5.memories).toHaveLength(1);
      expect((await call(env, 'DELETE', '/api/v1/ai/memories', token)).status).toBe(200);
      const mem6 = (await (await call(env, 'GET', '/api/v1/ai/memories', token)).json()) as { memories: unknown[] };
      expect(mem6.memories).toHaveLength(0);
    } finally {
      vi.unstubAllGlobals();
    }
  });
});

describe('AI 月度问数：日期与金额口径（v0.17.504）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let db: FakeD1;
  let token: string;

  beforeEach(async () => {
    env = (await setup()).env;
    db = env.DB;
    token = await loginAdmin(env);
  });

  const summaryIntent = (start: string, end: string) => ({
    intent: 'query' as const, view: 'summary' as const, start, end,
    client: null, kind: 'sale' as const, year: null, topics: [],
  });

  const insSale = (id: string, date: string, amount = 10, cost = 5) =>
    db.prepare(
      `INSERT INTO sale_items (id, sale_id, client_id, item_id, unit, quantity, sale_price, cost_price, amount, happened_at)
       VALUES (?, ?, NULL, 'i-x', '斤', 1, ?, ?, ?, ?)`,
    ).bind(id, id, amount, cost, amount, date).run();

  it('区间末日的单据计入、次日不计入（含带时分秒的历史/导入格式）', async () => {
    await insSale('r1', '2026-10-31');
    await insSale('r2', '2026-10-31 08:20:00');
    await insSale('r3', '2026-11-01 00:00:00');
    const out = await runBusinessQuery(db as never, 'admin', summaryIntent('2026-10-01', '2026-10-31'));
    expect(out).toContain('出货 2 笔');
    expect(out).toContain('¥20');
  });

  it('出货总额与 /stats/summary 同口径：逐笔舍入（digits=0 时 1.6+1.6=¥4，不是 ¥3）', async () => {
    await db.prepare("INSERT OR REPLACE INTO settings (key, value) VALUES ('round_digits','0')").run();
    await insSale('a1', '2026-10-15', 1.6, 0);
    await insSale('a2', '2026-10-16', 1.6, 0);
    const out = await runBusinessQuery(db as never, 'admin', summaryIntent('2026-10-01', '2026-10-31'));
    expect(out).toContain('¥4');
    const stat = await call(env, 'GET', '/api/v1/stats/summary?start=2026-10-01&end=2026-10-31', token)
      .then((r) => r.json()) as { sales_total: number };
    expect(stat.sales_total).toBe(4);
  });

  it('今日/本月收款：纯日期 happened_at 不再被 `00:00:00` 下界排除', async () => {
    await call(env, 'POST', '/api/v1/clients', token, { name: 'A店' });
    const cl = ((await call(env, 'GET', '/api/v1/clients', token).then((r) => r.json())) as {
      clients: Array<{ id: string }>;
    }).clients[0];
    await db.prepare('INSERT INTO payments (id, client_id, happened_at, amount, waived) VALUES (?, ?, ?, ?, 0)')
      .bind('p1', cl.id, localTodayISO(), 88).run();
    const ctx = await buildAssistantContext(db as never, 'admin');
    expect(ctx).toContain('¥88');
  });

  it('问「上个月」即使模型没识别出 query，也按业务时区的确定性区间查数', async () => {
    const bodies: string[] = [];
    vi.stubGlobal('fetch', vi.fn(async (_url: string, init: { body: string }) => {
      bodies.push(init.body);
      const content = bodies.length === 1
        ? '{"intent":"chat","view":null,"start":null,"end":null,"client":null,"kind":"sale","year":null,"topics":[],"remember":null,"forget":null,"record":null}'
        : '好的。';
      return new Response(JSON.stringify({ choices: [{ message: { content } }] }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      });
    }));
    try {
      // 直接调编排入口，传入内存 cfg，绕开 /ai/chat 对 settings 里 API Key 的要求
      const outcome = await assistantAnswer(cfg, db as never, [
        { role: 'user', content: '上个月一共卖了多少钱' },
      ], 'admin', 'u-test');
      expect(outcome.reply).toBeTruthy();
      const m = parseMonthRange('上个月', localTodayISO())!;
      expect(bodies.join('\n')).toContain(`区间 ${m.start} ~ ${m.end}`);
    } finally {
      vi.unstubAllGlobals();
    }
  });
});