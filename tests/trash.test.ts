/** 作废/红冲 → 回收站 → 恢复：全链路过滤、同 ID 防覆盖、进货批次清理回归 */
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

async function seed(env: Env, token: string) {
  await call(env, 'POST', '/api/v1/items', token, {
    name: '白菜', prices: [{ unit: '斤', purchase_price: 2, sale_price: 3 }],
  });
  const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
    items: Array<{ prices: Array<{ id: string }> }>;
  };
  const priceId = items.items[0].prices[0].id;
  await call(env, 'POST', '/api/v1/clients', token, { name: '品味轩' });
  const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string }> };
  const clientId = clients.clients[0].id;
  const purchase = await call(env, 'POST', '/api/v1/purchases', token, {
    happened_at: '2026-09-01', items: [{ price_id: priceId, quantity: 10, purchase_price: 2 }],
  });
  const purchaseId = ((await purchase.json()) as { id: string }).id;
  const sale = await call(env, 'POST', '/api/v1/sales', token, {
    client_id: clientId, happened_at: '2026-09-02',
    items: [{ price_id: priceId, quantity: 5, sale_price: 5 }],
  });
  const saleId = ((await sale.json()) as { id: string }).id;
  const payment = await call(env, 'POST', '/api/v1/payments', token, {
    client_id: clientId, happened_at: '2026-09-03', amount: 10,
  });
  const paymentId = ((await payment.json()) as { id: string }).id;
  return { clientId, priceId, purchaseId, saleId, paymentId };
}

interface TrashItem { id: string; entity_type: string; reason: string; total: number }
async function trash(env: Env, token: string, type?: string) {
  const res = await call(env, 'GET', `/api/v1/trash${type ? `?entity_type=${type}` : ''}`, token);
  expect(res.status).toBe(200);
  return (await res.json()) as { total: number; items: TrashItem[] };
}

describe('作废单据回收站', () => {
  let env: Env;
  let token: string;
  let ids: Awaited<ReturnType<typeof seed>>;
  beforeEach(async () => {
    ({ env } = await setup());
    token = await boot(env);
    ids = await seed(env, token);
  });

  it('删除出货/进货/收款都进回收站，且统计与 CSV 全链路不再包含作废行', async () => {
    expect((await call(env, 'DELETE', `/api/v1/sales/${ids.saleId}?reason=金额录错（红冲）`, token)).status).toBe(204);
    expect((await call(env, 'DELETE', `/api/v1/purchases/${ids.purchaseId}`, token)).status).toBe(204);
    expect((await call(env, 'DELETE', `/api/v1/payments/${ids.paymentId}`, token)).status).toBe(204);

    const list = await trash(env, token);
    expect(list.total).toBe(3);
    expect(list.items.map((x) => x.entity_type).sort()).toEqual(['payment', 'purchase', 'sale']);
    expect(list.items.find((x) => x.entity_type === 'sale')?.reason).toBe('金额录错（红冲）');

    const debts = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ debt: number }> };
    expect(debts.clients[0].debt).toBe(0);
    const csv = await (await call(env, 'GET', '/api/v1/export/transactions.csv', token)).text();
    expect(csv.trim().split('\r\n')).toHaveLength(1); // 只剩表头
    const counts = await env.DB.prepare('SELECT COUNT(*) AS cnt FROM sale_items').first<{ cnt: number }>();
    expect(counts?.cnt).toBe(0);
  });

  it('出货恢复：同 ID 单据重现、欠款恢复、回收站记录消失', async () => {
    await call(env, 'DELETE', `/api/v1/sales/${ids.saleId}`, token);
    const entry = (await trash(env, token, 'sale')).items[0];
    const preview = (await (await call(env, 'GET', `/api/v1/trash/${entry.id}`, token)).json()) as {
      payload: { id: string; items: unknown[] };
    };
    expect(preview.payload.id).toBe(ids.saleId);
    expect(preview.payload.items.length).toBeGreaterThan(0);

    const restore = await call(env, 'POST', `/api/v1/trash/${entry.id}/restore`, token);
    expect(restore.status).toBe(200);
    expect((await trash(env, token)).total).toBe(0);
    const debts = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ debt: number }> };
    expect(debts.clients[0].debt).toBe(15); // 出货 25 − 收款 10
    const sales = (await (await call(env, 'GET', '/api/v1/sales', token)).json()) as { sales: Array<{ id: string }> };
    expect(sales.sales.map((s) => s.id)).toContain(ids.saleId);
  });

  it('进货删除清掉 FIFO 批次（回归子查询失效），恢复时补回批次', async () => {
    const before = await env.DB.prepare('SELECT COUNT(*) AS cnt FROM stock_batches').first<{ cnt: number }>();
    expect(before?.cnt).toBe(1);
    await call(env, 'DELETE', `/api/v1/purchases/${ids.purchaseId}`, token);
    const after = await env.DB.prepare('SELECT COUNT(*) AS cnt FROM stock_batches').first<{ cnt: number }>();
    expect(after?.cnt).toBe(0);

    const entry = (await trash(env, token, 'purchase')).items[0];
    expect((await call(env, 'POST', `/api/v1/trash/${entry.id}/restore`, token)).status).toBe(200);
    const restored = await env.DB.prepare('SELECT COUNT(*) AS cnt FROM stock_batches').first<{ cnt: number }>();
    expect(restored?.cnt).toBe(1);
  });

  it('收款恢复金额一致；同 ID 已存在时拒绝覆盖（409）', async () => {
    await call(env, 'DELETE', `/api/v1/payments/${ids.paymentId}`, token);
    const entry = (await trash(env, token, 'payment')).items[0];
    await call(env, 'POST', '/api/v1/payments', token, {
      client_id: ids.clientId, happened_at: '2026-09-04', amount: 10, sync_key: '',
    });
    // 把新收款改成被作废单的同 ID，模拟恢复撞车
    await env.DB.prepare('UPDATE payments SET id = ?').bind(ids.paymentId).run();
    const conflict = await call(env, 'POST', `/api/v1/trash/${entry.id}/restore`, token);
    expect(conflict.status).toBe(409);
  });

  it('彻底删除回收站条目；店员不能访问回收站', async () => {
    await call(env, 'DELETE', `/api/v1/sales/${ids.saleId}`, token);
    const entry = (await trash(env, token)).items[0];
    expect((await call(env, 'DELETE', `/api/v1/trash/${entry.id}`, token)).status).toBe(204);
    expect((await trash(env, token)).total).toBe(0);

    await call(env, 'POST', '/api/v1/users', token, { username: 'staff1', password: 'staff123', role: 'staff' });
    const login = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
    const staffToken = ((await login.json()) as { token: string }).token;
    expect((await call(env, 'GET', '/api/v1/trash', staffToken)).status).toBe(403);
  });
});
