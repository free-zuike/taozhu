/** 收款 ↔ 出货单核销（v0.17.517）：FIFO 自动分摊、显式核销校验、编辑/撤销维护、老库补表 */
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { createFakeD1, fakeAssets, type FakeD1 } from './helpers/fake-d1';

const JWT_SECRET = 'test-secret';
const BASE = 'http://localhost';

type Env = { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };

async function setup() {
  resetSchemaState();
  const db = await createFakeD1();
  await ensureSchema(db as never);
  return { env: { DB: db, ASSETS: fakeAssets, JWT_SECRET } };
}

async function call(env: Env, method: string, path: string, token?: string, body?: unknown): Promise<Response> {
  const headers: Record<string, string> = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  return app.request(`${BASE}${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }, env as never);
}

async function boot(env: Env): Promise<string> {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  return ((await res.json()) as { token: string }).token;
}

/** 两张出货单：09-01 ¥100、09-02 ¥40，共 ¥140 */
async function seed(env: Env, token: string) {
  await call(env, 'POST', '/api/v1/items', token, {
    name: '白菜', prices: [{ unit: '斤', purchase_price: 2, sale_price: 3 }],
  });
  const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
    items: Array<{ prices: Array<{ id: string }> }>;
  };
  const priceId = items.items[0].prices[0].id;
  await call(env, 'POST', '/api/v1/clients', token, { name: '品味轩' });
  const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as {
    clients: Array<{ id: string }>;
  };
  const clientId = clients.clients[0].id;
  await call(env, 'POST', '/api/v1/sales', token, {
    client_id: clientId, happened_at: '2026-09-01', items: [{ price_id: priceId, quantity: 10, sale_price: 10 }],
  });
  await call(env, 'POST', '/api/v1/sales', token, {
    client_id: clientId, happened_at: '2026-09-02', items: [{ price_id: priceId, quantity: 4, sale_price: 10 }],
  });
  const rows = await env.DB.prepare(
    'SELECT sale_id, SUM(amount) AS total FROM sale_items GROUP BY sale_id ORDER BY MIN(happened_at)',
  ).all<{ sale_id: string; total: number }>();
  return { clientId, first: rows.results[0].sale_id, second: rows.results[1].sale_id };
}

interface Unsettled { sale_id: string; total: number; allocated: number; unsettled: number }
async function unsettled(env: Env, token: string, clientId: string) {
  const res = await call(env, 'GET', `/api/v1/payments/unsettled?client_id=${clientId}`, token);
  expect(res.status).toBe(200);
  return (await res.json()) as { total: number; orders: Unsettled[] };
}

describe('收款核销 payment_allocations', () => {
  let env: Env;
  let token: string;
  let clientId: string;
  let first: string;
  let second: string;
  beforeEach(async () => {
    ({ env } = await setup());
    token = await boot(env);
    ({ clientId, first, second } = await seed(env, token));
  });

  it('未指定时按最早未结清单据 FIFO 自动分摊，欠款口径不变', async () => {
    const r = await call(env, 'POST', '/api/v1/payments', token, { client_id: clientId, amount: 120 });
    expect(r.status).toBe(201);
    const { orders, total } = await unsettled(env, token, clientId);
    expect(total).toBe(20);
    expect(orders.find((o) => o.sale_id === first)).toMatchObject({ total: 100, allocated: 100, unsettled: 0 });
    expect(orders.find((o) => o.sale_id === second)).toMatchObject({ total: 40, allocated: 20, unsettled: 20 });
    const debts = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ debt: number }> };
    expect(debts.clients[0].debt).toBe(20);
  });

  it('第二笔收款接着分摊剩余待收额，最终全部结清', async () => {
    await call(env, 'POST', '/api/v1/payments', token, { client_id: clientId, amount: 100 });
    await call(env, 'POST', '/api/v1/payments', token, { client_id: clientId, amount: 40 });
    const { orders, total } = await unsettled(env, token, clientId);
    expect(total).toBe(0);
    expect(orders.every((o) => o.unsettled === 0)).toBe(true);
  });

  it('显式核销：只冲指定单据，且 GET /:id/allocations 可追溯', async () => {
    const r = await call(env, 'POST', '/api/v1/payments', token, {
      client_id: clientId, amount: 50, allocations: [{ sale_id: second, amount: 40 }],
    });
    expect(r.status).toBe(201);
    const id = ((await r.json()) as { id: string }).id;
    const detail = (await (await call(env, 'GET', `/api/v1/payments/${id}/allocations`, token)).json()) as {
      allocations: Array<{ sale_id: string; amount: number }>;
    };
    expect(detail.allocations).toEqual([{ id: expect.any(String), sale_id: second, amount: 40 }]);
    const { orders } = await unsettled(env, token, clientId);
    expect(orders.find((o) => o.sale_id === first)?.allocated).toBe(0);
    expect(orders.find((o) => o.sale_id === second)?.unsettled).toBe(0);
  });

  it('显式核销超额 / 非本店单据 / 超过待收额一律 400，且不产生收款', async () => {
    for (const allocations of [
      [{ sale_id: first, amount: 200 }],
      [{ sale_id: 'not-this-shop', amount: 10 }],
      [{ sale_id: first, amount: 101 }],
      { not: 'an array' },
    ]) {
      const r = await call(env, 'POST', '/api/v1/payments', token, { client_id: clientId, amount: 50, allocations });
      expect(r.status).toBe(400);
    }
    const count = await env.DB.prepare('SELECT COUNT(*) AS cnt FROM payments').first<{ cnt: number }>();
    expect(count?.cnt).toBe(0);
  });

  it('改金额后重算核销（排除本笔旧记录），改备注不动手工核销', async () => {
    const r = await call(env, 'POST', '/api/v1/payments', token, {
      client_id: clientId, amount: 50, allocations: [{ sale_id: second, amount: 40 }],
    });
    const id = ((await r.json()) as { id: string }).id;
    await call(env, 'PATCH', `/api/v1/payments/${id}`, token, { note: '备注' });
    const detail = (await (await call(env, 'GET', `/api/v1/payments/${id}/allocations`, token)).json()) as {
      allocations: Array<{ sale_id: string }>;
    };
    expect(detail.allocations.map((a) => a.sale_id)).toEqual([second]);

    const patch = await call(env, 'PATCH', `/api/v1/payments/${id}`, token, { amount: 130 });
    expect(patch.status).toBe(200);
    const after = await unsettled(env, token, clientId);
    expect(after.total).toBe(10);
    const alloc = await env.DB.prepare(
      'SELECT COUNT(*) AS cnt FROM payment_allocations WHERE payment_id = ?',
    ).bind(id).first<{ cnt: number }>();
    expect(alloc?.cnt).toBeGreaterThan(0);
  });

  it('撤销收款同批删除核销行，待收额回到原值', async () => {
    const r = await call(env, 'POST', '/api/v1/payments', token, { client_id: clientId, amount: 100 });
    const id = ((await r.json()) as { id: string }).id;
    const del = await call(env, 'DELETE', `/api/v1/payments/${id}`, token);
    expect(del.status).toBe(204);
    const alloc = await env.DB.prepare(
      'SELECT COUNT(*) AS cnt FROM payment_allocations WHERE payment_id = ?',
    ).bind(id).first<{ cnt: number }>();
    expect(alloc?.cnt).toBe(0);
    expect((await unsettled(env, token, clientId)).total).toBe(140);
  });
});

describe('已初始化老库补建新表（防版本快检短路回归）', () => {
  it('schema_version=17 的老库冷启动仍会补出 3 张新表与索引', async () => {
    const db = await createFakeD1();
    resetSchemaState();
    await ensureSchema(db as never);
    for (const t of ['idempotency_keys', 'payment_allocations', 'voided_orders']) {
      await db.prepare(`DROP TABLE ${t}`).run();
    }
    await db.prepare("UPDATE schema_meta SET value = '17' WHERE key = 'schema_version'").run();
    resetSchemaState();
    await ensureSchema(db as never);
    for (const t of ['idempotency_keys', 'payment_allocations', 'voided_orders']) {
      const row = await db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name = ?")
        .bind(t).first<{ name: string }>();
      expect(row, `老库应补出 ${t}`).toBeTruthy();
    }
    const cols = await db.prepare('PRAGMA table_info(share_links)').all<{ name: string }>();
    expect(cols.results.map((c) => c.name)).toContain('created_by');
  });
});
