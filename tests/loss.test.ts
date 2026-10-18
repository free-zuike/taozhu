/**
 * 报损/损耗测试：进货建批 → 报损从最早批次扣减（金额=损量×批次进价），单独记 loss_records
 * （不计入出货毛利）；损耗纳入库存计算（GET /stocks UNION 减）；损耗超库存拒绝 400；
 * 报损后出货成本仍按剩余批次 FIFO 联动。
 */
import { describe, expect, it } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
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

interface Ctx { env: Env; token: string; clientId: string; priceId: string; itemId: string }

async function seed(): Promise<Ctx> {
  const env = (await setup()).env;
  const token = await loginAdmin(env);
  await call(env, 'POST', '/api/v1/clients', token, { name: '品味轩' });
  const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string; name: string }> };
  const clientId = clients.clients.find((c) => c.name === '品味轩')!.id;
  await call(env, 'POST', '/api/v1/items', token, { name: '白菜', prices: [{ unit: '斤', purchase_price: 12, sale_price: 15 }] });
  const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as { items: Array<{ id: string; prices: Array<{ id: string }> }> };
  const item = items.items[0];
  return { env, token, clientId, priceId: item.prices[0].id, itemId: item.id };
}

async function addPurchase(ctx: Ctx, price: number, qty: number, date: string) {
  await call(ctx.env, 'POST', '/api/v1/purchases', ctx.token, {
    happened_at: date, items: [{ price_id: ctx.priceId, quantity: qty, purchase_price: price }],
  });
}

async function batchRemainings(ctx: Ctx): Promise<number[]> {
  const rows = await (ctx.env.DB as FakeD1).prepare(
    'SELECT remaining FROM stock_batches WHERE item_id = ? AND unit = ? ORDER BY happened_at ASC',
  ).bind(ctx.itemId, '斤').all<{ remaining: number }>();
  return rows.results.map((r) => r.remaining);
}

async function stockQuantityOf(ctx: Ctx): Promise<number> {
  const d = (await (await call(ctx.env, 'GET', '/api/v1/stocks', ctx.token)).json()) as { stocks: Array<{ item_id: string; quantity: number }> };
  const s = d.stocks.find((x) => x.item_id === ctx.itemId);
  return s?.quantity ?? 0;
}

describe('报损/损耗', () => {
  it('报损扣最早批次，金额=损量×批次进价，单独记流水', async () => {
    const ctx = await seed();
    await addPurchase(ctx, 8, 50, '2026-09-01'); // 第一批 50@8
    await addPurchase(ctx, 10, 50, '2026-09-10'); // 第二批 50@10
    const res = await call(ctx.env, 'POST', '/api/v1/stocks/loss', ctx.token, {
      item_id: ctx.itemId, unit: '斤', qty: 30, happened_at: '2026-09-12', note: '菜叶损坏',
    });
    expect(res.status).toBe(201);
    const d = (await res.json()) as { amount: number; price: number; qty: number };
    // 从最早批次 8@50 扣 30 → 金额 240、单价 8
    expect(d.amount).toBe(240);
    expect(d.price).toBe(8);
    expect(await batchRemainings(ctx)).toEqual([20, 50]);
    // 库存 = 100 − 30 = 70
    expect(await stockQuantityOf(ctx)).toBe(70);
    // 损耗未写 sale_batch_uses（不计入出货毛利）
    const uses = await (ctx.env.DB as FakeD1).prepare('SELECT COUNT(*) AS n FROM sale_batch_uses').first<{ n: number }>();
    expect(uses?.n).toBe(0);
  });

  it('损耗超过当前库存（批次剩余不足）拒绝 400', async () => {
    const ctx = await seed();
    await addPurchase(ctx, 8, 50, '2026-09-01');
    const res = await call(ctx.env, 'POST', '/api/v1/stocks/loss', ctx.token, {
      item_id: ctx.itemId, unit: '斤', qty: 60,
    });
    expect(res.status).toBe(400);
    const d = (await res.json()) as { error: string };
    expect(d.error).toContain('还差 10');
    // 未扣减：批次原样
    expect(await batchRemainings(ctx)).toEqual([50]);
  });

  it('损耗流水列表 + 汇总（含商品名/备注/金额）', async () => {
    const ctx = await seed();
    await addPurchase(ctx, 8, 50, '2026-09-01');
    await call(ctx.env, 'POST', '/api/v1/stocks/loss', ctx.token, {
      item_id: ctx.itemId, unit: '斤', qty: 20, note: '挤压',
    });
    const d = (await (await call(ctx.env, 'GET', '/api/v1/stocks/loss', ctx.token)).json()) as {
      rows: Array<{ item_name: string; qty: number; amount: number; note: string }>;
      total_qty: number; total_amount: number;
    };
    expect(d.rows).toHaveLength(1);
    expect(d.rows[0].item_name).toBe('白菜');
    expect(d.rows[0].qty).toBe(20);
    expect(d.rows[0].amount).toBe(160);
    expect(d.rows[0].note).toBe('挤压');
    expect(d.total_qty).toBe(20);
    expect(d.total_amount).toBe(160);
  });

  it('报损后出货成本按剩余批次 FIFO 联动', async () => {
    const ctx = await seed();
    await addPurchase(ctx, 8, 50, '2026-09-01');
    await addPurchase(ctx, 10, 50, '2026-09-10');
    // 报损 30（吃最早批次 8@50 的 30）→ 剩余批：20@8、50@10
    await call(ctx.env, 'POST', '/api/v1/stocks/loss', ctx.token, {
      item_id: ctx.itemId, unit: '斤', qty: 30,
    });
    const created = await call(ctx.env, 'POST', '/api/v1/sales', ctx.token, {
      client_id: ctx.clientId, happened_at: '2026-09-15',
      items: [{ price_id: ctx.priceId, quantity: 70 }],
    });
    const { id } = (await created.json()) as { id: string };
    // cost = (20×8 + 50×10)/70 = 660/70 ≈ 9.428571
    const d = (await (await call(ctx.env, 'GET', `/api/v1/sales/${id}`, ctx.token)).json()) as { items: Array<{ cost_price: number }> };
    expect(d.items[0].cost_price).toBeCloseTo(660 / 70, 5);
    expect(await batchRemainings(ctx)).toEqual([0, 0]);
  });
});
