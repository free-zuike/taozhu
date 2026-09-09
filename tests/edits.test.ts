/**
 * 编辑类接口测试：PATCH /sales/:id、/purchases/:id、/payments/:id
 * 覆盖：改主表字段、整体替换明细（原子事务）、权限、错误分支、欠款联动。
 */
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { hashPassword, randomId } from '../src/lib/password';
import { createFakeD1, fakeAssets, type FakeD1 } from './helpers/fake-d1';

const JWT_SECRET = 'test-secret';
const BASE = 'http://localhost';

async function setup() {
  resetSchemaState();
  const db = await createFakeD1();
  await ensureSchema(db as never);
  const env = { DB: db, ASSETS: fakeAssets, JWT_SECRET };
  return { db, env };
}

type Env = { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };

async function call(env: Env, method: string, path: string, token?: string, body?: unknown): Promise<Response> {
  const headers: Record<string, string> = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  return app.request(`${BASE}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  }, env as never);
}

async function loginAdmin(env: Env) {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  const data = (await res.json()) as { token: string };
  return data.token;
}

interface SetupCtx {
  env: Env;
  token: string;
  clientA: string;
  clientB: string;
  priceId: string;
  saleId: string;
  purchaseId: string;
  paymentId: string;
}

/** 造一套完整数据：2 店铺 + 1 商品（斤 进2.0 出2.5）+ 1 出货单 + 1 进货单 + 1 收款 */
async function seed(): Promise<SetupCtx> {
  const env = (await setup()).env;
  const token = await loginAdmin(env);

  await call(env, 'POST', '/api/v1/items', token, { name: '白菜', prices: [{ unit: '斤', purchase_price: 2.0, sale_price: 2.5 }] });
  const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as { items: Array<{ id: string; prices: Array<{ id: string }> }> };
  const priceId = items.items[0].prices[0].id;

  await call(env, 'POST', '/api/v1/clients', token, { name: '品味轩' });
  await call(env, 'POST', '/api/v1/clients', token, { name: '川味居' });
  const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string; name: string }> };
  const clientA = clients.clients.find((c) => c.name === '品味轩')!.id;
  const clientB = clients.clients.find((c) => c.name === '川味居')!.id;

  const sale = await call(env, 'POST', '/api/v1/sales', token, {
    client_id: clientA, happened_at: '2026-09-06', note: '早班',
    items: [{ price_id: priceId, quantity: 20, sale_price: 2.6 }],
  });
  const saleId = ((await sale.json()) as { id: string }).id;

  const purchase = await call(env, 'POST', '/api/v1/purchases', token, {
    happened_at: '2026-09-06', note: '市场进货',
    items: [{ price_id: priceId, quantity: 50, purchase_price: 1.9 }],
  });
  const purchaseId = ((await purchase.json()) as { id: string }).id;

  const payment = await call(env, 'POST', '/api/v1/payments', token, {
    client_id: clientA, amount: 30, method: '微信', note: '结一部分',
  });
  const paymentId = ((await payment.json()) as { id: string }).id;

  return { env, token, clientA, clientB, priceId, saleId, purchaseId, paymentId };
}

describe('出货单编辑 PATCH /sales/:id', () => {
  let ctx: SetupCtx;

  beforeEach(async () => { ctx = await seed(); });

  it('改备注与日期，明细不变，总额不变', async () => {
    const res = await call(ctx.env, 'PATCH', `/api/v1/sales/${ctx.saleId}`, ctx.token, {
      note: '改过备注', happened_at: '2026-09-07',
    });
    expect(res.status).toBe(200);
    const detail = (await (await call(ctx.env, 'GET', `/api/v1/sales/${ctx.saleId}`, ctx.token)).json()) as {
      note: string; happened_at: string; total: number; items: unknown[];
    };
    expect(detail.note).toBe('改过备注');
    expect(detail.happened_at).toBe('2026-09-07');
    expect(detail.total).toBe(52); // 20 × 2.6
    expect(detail.items).toHaveLength(1);
  });

  it('整体替换明细：旧明细删除、总额与进价快照按新明细重算', async () => {
    const res = await call(ctx.env, 'PATCH', `/api/v1/sales/${ctx.saleId}`, ctx.token, {
      items: [{ price_id: ctx.priceId, quantity: 10, sale_price: 3.0 }],
    });
    expect(res.status).toBe(200);
    const data = (await res.json()) as { total: number };
    expect(data.total).toBe(30); // 10 × 3.0

    const detail = (await (await call(ctx.env, 'GET', `/api/v1/sales/${ctx.saleId}`, ctx.token)).json()) as {
      total: number; items: Array<{ quantity: number; sale_price: number; cost_price: number }>;
    };
    expect(detail.total).toBe(30);
    expect(detail.items).toHaveLength(1);
    expect(detail.items[0].quantity).toBe(10);
    expect(detail.items[0].sale_price).toBe(3);
    expect(detail.items[0].cost_price).toBe(2); // 进价快照仍是当前进价 2
  });

  it('换店铺：欠款从 A 转到 B', async () => {
    await call(ctx.env, 'PATCH', `/api/v1/sales/${ctx.saleId}`, ctx.token, { client_id: ctx.clientB });
    const clients = (await (await call(ctx.env, 'GET', '/api/v1/clients', ctx.token)).json()) as {
      clients: Array<{ id: string; sales_total: number }>;
    };
    const a = clients.clients.find((c) => c.id === ctx.clientA)!;
    const b = clients.clients.find((c) => c.id === ctx.clientB)!;
    expect(a.sales_total).toBe(0);
    expect(b.sales_total).toBe(52);
  });

  it('明细为空 / 数量非法 → 400', async () => {
    const empty = await call(ctx.env, 'PATCH', `/api/v1/sales/${ctx.saleId}`, ctx.token, { items: [] });
    expect(empty.status).toBe(400);
    const badQty = await call(ctx.env, 'PATCH', `/api/v1/sales/${ctx.saleId}`, ctx.token, {
      items: [{ price_id: ctx.priceId, quantity: 0 }],
    });
    expect(badQty.status).toBe(400);
  });

  it('不存在/店员权限 → 404 / 403', async () => {
    const nf = await call(ctx.env, 'PATCH', '/api/v1/sales/nope', ctx.token, { note: 'x' });
    expect(nf.status).toBe(404);

    await ctx.env.DB.prepare('INSERT INTO users (id, username, password_hash, role) VALUES (?, ?, ?, ?)')
      .bind(randomId(), 'staff1', await hashPassword('staff123'), 'staff').run();
    const login = await call(ctx.env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
    const staffToken = ((await login.json()) as { token: string }).token;
    const forbidden = await call(ctx.env, 'PATCH', `/api/v1/sales/${ctx.saleId}`, staffToken, { note: 'x' });
    expect(forbidden.status).toBe(403);
  });
});

describe('进货单编辑 PATCH /purchases/:id', () => {
  let ctx: SetupCtx;

  beforeEach(async () => { ctx = await seed(); });

  it('改备注/日期，明细与总额不变', async () => {
    const res = await call(ctx.env, 'PATCH', `/api/v1/purchases/${ctx.purchaseId}`, ctx.token, {
      note: '晚市进货', happened_at: '2026-09-08',
    });
    expect(res.status).toBe(200);
    const detail = (await (await call(ctx.env, 'GET', `/api/v1/purchases/${ctx.purchaseId}`, ctx.token)).json()) as {
      happened_at: string; note: string; total: number; items: unknown[];
    };
    expect(detail.happened_at).toBe('2026-09-08');
    expect(detail.note).toBe('晚市进货');
    expect(detail.total).toBe(95); // 50 × 1.9
    expect(detail.items).toHaveLength(1);
  });

  it('整体替换明细：总额按新明细重算', async () => {
    const res = await call(ctx.env, 'PATCH', `/api/v1/purchases/${ctx.purchaseId}`, ctx.token, {
      items: [{ price_id: ctx.priceId, quantity: 100, purchase_price: 2.2 }],
    });
    expect(res.status).toBe(200);
    const data = (await res.json()) as { total: number };
    expect(data.total).toBe(220);

    const detail = (await (await call(ctx.env, 'GET', `/api/v1/purchases/${ctx.purchaseId}`, ctx.token)).json()) as {
      total: number; items: Array<{ quantity: number; purchase_price: number }>;
    };
    expect(detail.total).toBe(220);
    expect(detail.items).toHaveLength(1);
    expect(detail.items[0].quantity).toBe(100);
    expect(detail.items[0].purchase_price).toBe(2.2);
  });

  it('明细为空 → 400', async () => {
    const res = await call(ctx.env, 'PATCH', `/api/v1/purchases/${ctx.purchaseId}`, ctx.token, { items: [] });
    expect(res.status).toBe(400);
  });
});

describe('收款编辑 PATCH /payments/:id', () => {
  let ctx: SetupCtx;

  beforeEach(async () => { ctx = await seed(); });

  it('改金额/方式/日期，欠款联动更新', async () => {
    const res = await call(ctx.env, 'PATCH', `/api/v1/payments/${ctx.paymentId}`, ctx.token, {
      amount: 40, method: '现金', happened_at: '2026-09-07',
    });
    expect(res.status).toBe(200);
    const clients = (await (await call(ctx.env, 'GET', '/api/v1/clients', ctx.token)).json()) as {
      clients: Array<{ name: string; paid_total: number; debt: number }>;
    };
    const a = clients.clients.find((c) => c.name === '品味轩')!;
    expect(a.paid_total).toBe(40);
    expect(a.debt).toBe(12); // 52 − 40
  });

  it('换店铺：收款从 A 移到 B，A 欠款恢复', async () => {
    await call(ctx.env, 'PATCH', `/api/v1/payments/${ctx.paymentId}`, ctx.token, { client_id: ctx.clientB });
    const clients = (await (await call(ctx.env, 'GET', '/api/v1/clients', ctx.token)).json()) as {
      clients: Array<{ id: string; paid_total: number; debt: number }>;
    };
    const a = clients.clients.find((c) => c.id === ctx.clientA)!;
    const b = clients.clients.find((c) => c.id === ctx.clientB)!;
    expect(a.paid_total).toBe(0);
    expect(a.debt).toBe(52);
    expect(b.paid_total).toBe(30);
    expect(b.debt).toBe(-30);
  });

  it('金额非法/不存在 → 400 / 404', async () => {
    const bad = await call(ctx.env, 'PATCH', `/api/v1/payments/${ctx.paymentId}`, ctx.token, { amount: 0 });
    expect(bad.status).toBe(400);
    const nf = await call(ctx.env, 'PATCH', '/api/v1/payments/nope', ctx.token, { amount: 10 });
    expect(nf.status).toBe(404);
  });
});