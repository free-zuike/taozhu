/** 库存测试：进货自动入库、出货自动扣减、编辑/删除单据库存重算、盘点与预警 */
import { beforeEach, describe, expect, it } from 'vitest';
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

async function call(env: Env, method: string, path: string, token?: string, body?: unknown) {
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
  return ((await res.json()) as { token: string }).token;
}

describe('库存（stocks）', () => {
  let env: Env;
  let token: string;
  let clientId: string;
  let priceId: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    await call(env, 'POST', '/api/v1/items', token, { name: '白菜', prices: [{ unit: '斤', purchase_price: 1, sale_price: 2 }] });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string; prices: Array<{ id: string; unit: string }> }>;
    };
    priceId = items.items[0].prices[0].id;
    await call(env, 'POST', '/api/v1/clients', token, { name: '品味轩' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as {
      clients: Array<{ id: string }>;
    };
    clientId = clients.clients[0].id;
  });

  const stockQty = async (): Promise<number> => {
    const d = (await (await call(env, 'GET', '/api/v1/stocks', token)).json()) as {
      stocks: Array<{ quantity: number }>;
    };
    return d.stocks[0]?.quantity ?? 0;
  };

  it('进货自动入库、出货自动扣减', async () => {
    await call(env, 'POST', '/api/v1/purchases', token, { items: [{ price_id: priceId, quantity: 30 }] });
    expect(await stockQty()).toBe(30);
    await call(env, 'POST', '/api/v1/sales', token, { client_id: clientId, items: [{ price_id: priceId, quantity: 12 }] });
    expect(await stockQty()).toBe(18);
  });

  it('编辑出货单替换明细后库存重算', async () => {
    await call(env, 'POST', '/api/v1/purchases', token, { items: [{ price_id: priceId, quantity: 50 }] });
    const sale = (await (await call(env, 'POST', '/api/v1/sales', token, { client_id: clientId, items: [{ price_id: priceId, quantity: 20 }] })).json()) as { id: string };
    expect(await stockQty()).toBe(30);
    // 改为 5 斤：回滚 20 再扣 5 → 50-5=45
    await call(env, 'PATCH', `/api/v1/sales/${sale.id}`, token, { items: [{ price_id: priceId, quantity: 5 }] });
    expect(await stockQty()).toBe(45);
  });

  it('删除出货单库存回滚', async () => {
    await call(env, 'POST', '/api/v1/purchases', token, { items: [{ price_id: priceId, quantity: 40 }] });
    const sale = (await (await call(env, 'POST', '/api/v1/sales', token, { client_id: clientId, items: [{ price_id: priceId, quantity: 10 }] })).json()) as { id: string };
    expect(await stockQty()).toBe(30);
    await call(env, 'DELETE', `/api/v1/sales/${sale.id}`, token);
    expect(await stockQty()).toBe(40);
  });

  it('盘点设置库存与阈值；below=1 预警过滤', async () => {
    // 用真实商品盘点
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string }>;
    };
    const itemId = items.items[0].id;
    await call(env, 'PUT', '/api/v1/stocks', token, {
      rows: [{ item_id: itemId, unit: '斤', quantity: 5, min_stock: 10 }],
    });
    const all = (await (await call(env, 'GET', '/api/v1/stocks', token)).json()) as {
      stocks: Array<{ quantity: number; min_stock: number; low: boolean }>;
    };
    expect(all.stocks[0].quantity).toBe(5);
    expect(all.stocks[0].min_stock).toBe(10);
    expect(all.stocks[0].low).toBe(true);
    expect(all.stocks[0].cost_price).toBe(1); // 白菜当前进价
    const below = (await (await call(env, 'GET', '/api/v1/stocks?below=1', token)).json()) as {
      stocks: unknown[];
    };
    expect(below.stocks.length).toBe(1);
  });

  it('盘点负数拒绝 400；单行 PATCH 调整', async () => {
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string }>;
    };
    const bad = await call(env, 'PUT', '/api/v1/stocks', token, {
      rows: [{ item_id: items.items[0].id, unit: '斤', quantity: -3 }],
    });
    expect(bad.status).toBe(400);
    await call(env, 'PUT', '/api/v1/stocks', token, {
      rows: [{ item_id: items.items[0].id, unit: '斤', quantity: 8, min_stock: 2 }],
    });
    const d = (await (await call(env, 'GET', '/api/v1/stocks', token)).json()) as {
      stocks: Array<{ id: string; quantity: number; min_stock: number }>;
    };
    const id = d.stocks[0].id;
    const patch = await call(env, 'PATCH', `/api/v1/stocks/${id}`, token, { quantity: 20 });
    expect(patch.status).toBe(200);
    const after = (await (await call(env, 'GET', '/api/v1/stocks', token)).json()) as {
      stocks: Array<{ quantity: number }>;
    };
    expect(after.stocks[0].quantity).toBe(20);
  });

  it('未登录访问库存 → 401', async () => {
    expect((await call(env, 'GET', '/api/v1/stocks')).status).toBe(401);
  });

  it('items/summary 记单目录返回当前库存', async () => {
    await call(env, 'POST', '/api/v1/purchases', token, { items: [{ price_id: priceId, quantity: 25 }] });
    const d = (await (await call(env, 'GET', '/api/v1/items/summary', token)).json()) as {
      items: Array<{ prices: Array<{ stock: number }> }>;
    };
    expect(d.items[0].prices[0].stock).toBe(25);
  });
});