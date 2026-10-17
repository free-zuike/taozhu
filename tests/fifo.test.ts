/**
 * FIFO 批次库存成本测试：进货逐行建批 → 出货按先进先出消耗批次并加权算成本；
 * 行编辑/删除释放批次；rebuild 全量重建批次并重写成本；手动进价优先且仍消耗批次。
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

async function saleCostOf(ctx: Ctx, saleId: string): Promise<number> {
  const d = (await (await call(ctx.env, 'GET', `/api/v1/sales/${saleId}`, ctx.token)).json()) as { items: Array<{ id: string; cost_price: number }> };
  return d.items[0].cost_price;
}

async function saleItemIdOf(ctx: Ctx, saleId: string): Promise<string> {
  const d = (await (await call(ctx.env, 'GET', `/api/v1/sales/${saleId}`, ctx.token)).json()) as { items: Array<{ id: string }> };
  return d.items[0].id;
}

async function batchRemainings(ctx: Ctx, unit = '斤'): Promise<number[]> {
  const rows = await (ctx.env.DB as FakeD1).prepare(
    'SELECT remaining FROM stock_batches WHERE item_id = ? AND unit = ? ORDER BY happened_at ASC',
  ).bind(ctx.itemId, unit).all<{ remaining: number }>();
  return rows.results.map((r) => r.remaining);
}

describe('FIFO 批次库存成本', () => {
  it('出货按先进先出跨批次消耗并加权算成本', async () => {
    const ctx = await seed();
    await addPurchase(ctx, 8, 50, '2026-09-01'); // 第一批 50@8
    await addPurchase(ctx, 10, 50, '2026-09-10'); // 第二批 50@10
    const created = await call(ctx.env, 'POST', '/api/v1/sales', ctx.token, {
      client_id: ctx.clientId, happened_at: '2026-09-15',
      items: [{ price_id: ctx.priceId, quantity: 80 }],
    });
    const { id } = (await created.json()) as { id: string };
    // cost = (50×8 + 30×10)/80 = 8.75；批次剩余：批1=0、批2=20
    expect(await saleCostOf(ctx, id)).toBe(8.75);
    expect(await batchRemainings(ctx)).toEqual([0, 20]);
  });

  it('出货只消耗最早批次，未触及的批次剩余不变', async () => {
    const ctx = await seed();
    await addPurchase(ctx, 8, 50, '2026-09-01');
    await addPurchase(ctx, 10, 50, '2026-09-10');
    const created = await call(ctx.env, 'POST', '/api/v1/sales', ctx.token, {
      client_id: ctx.clientId, happened_at: '2026-09-15',
      items: [{ price_id: ctx.priceId, quantity: 30 }],
    });
    const { id } = (await created.json()) as { id: string };
    expect(await saleCostOf(ctx, id)).toBe(8);
    expect(await batchRemainings(ctx)).toEqual([20, 50]);
  });

  it('出货行编辑（数量增加）释放旧占用并按新量重新消耗', async () => {
    const ctx = await seed();
    await addPurchase(ctx, 8, 50, '2026-09-01');
    await addPurchase(ctx, 10, 50, '2026-09-10');
    const created = await call(ctx.env, 'POST', '/api/v1/sales', ctx.token, {
      client_id: ctx.clientId, happened_at: '2026-09-15',
      items: [{ price_id: ctx.priceId, quantity: 30 }],
    });
    const { id } = (await created.json()) as { id: string };
    const lineId = await saleItemIdOf(ctx, id);
    await call(ctx.env, 'PATCH', `/api/v1/sales/items/${lineId}`, ctx.token, { quantity: 100 });
    // 100 = 50×8 + 50×10 → 9；批次全空
    const d = (await (await call(ctx.env, 'GET', `/api/v1/sales/${id}`, ctx.token)).json()) as { items: Array<{ cost_price: number }> };
    expect(d.items[0].cost_price).toBe(9);
    expect(await batchRemainings(ctx)).toEqual([0, 0]);
  });

  it('出货行删除释放批次占用（剩余恢复）', async () => {
    const ctx = await seed();
    await addPurchase(ctx, 8, 50, '2026-09-01');
    const created = await call(ctx.env, 'POST', '/api/v1/sales', ctx.token, {
      client_id: ctx.clientId, happened_at: '2026-09-15',
      items: [{ price_id: ctx.priceId, quantity: 30 }],
    });
    const { id } = (await created.json()) as { id: string };
    const lineId = await saleItemIdOf(ctx, id);
    await call(ctx.env, 'DELETE', `/api/v1/sales/items/${lineId}`, ctx.token);
    expect(await batchRemainings(ctx)).toEqual([50]);
  });

  it('老板手动进价优先，且仍消耗批次', async () => {
    const ctx = await seed();
    await addPurchase(ctx, 8, 50, '2026-09-01');
    const created = await call(ctx.env, 'POST', '/api/v1/sales', ctx.token, {
      client_id: ctx.clientId, happened_at: '2026-09-15',
      items: [{ price_id: ctx.priceId, quantity: 10, cost_price: 7 }],
    });
    const { id } = (await created.json()) as { id: string };
    expect(await saleCostOf(ctx, id)).toBe(7);
    expect(await batchRemainings(ctx)).toEqual([40]); // 批次仍被消耗
  });

  it('rebuild 全量重建批次并重写成本', async () => {
    const ctx = await seed();
    await addPurchase(ctx, 8, 50, '2026-09-01');
    await addPurchase(ctx, 10, 50, '2026-09-10');
    const created = await call(ctx.env, 'POST', '/api/v1/sales', ctx.token, {
      client_id: ctx.clientId, happened_at: '2026-09-15',
      items: [{ price_id: ctx.priceId, quantity: 80 }],
    });
    const { id } = (await created.json()) as { id: string };
    // 破坏批次账后 rebuild 应恢复
    await (ctx.env.DB as FakeD1).prepare('DELETE FROM stock_batches').run();
    await call(ctx.env, 'POST', '/api/v1/stocks/rebuild', ctx.token);
    expect(await saleCostOf(ctx, id)).toBe(8.75);
    expect(await batchRemainings(ctx)).toEqual([0, 20]);
  });
});