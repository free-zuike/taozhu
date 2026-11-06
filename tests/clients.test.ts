/** 店铺列表契约测试：锁定 GET /clients 响应字段
 *  sale_count / payment_count / first_book_date 由已全量加载的 sale_items/payments 在 JS 侧派生
 *  （非每店铺 3 个相关子查询）。回归防止改回冗余子查询，或破坏字段契约。 */
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
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  }, env as never);
}

async function loginAdmin(env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string }) {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  const data = (await res.json()) as { token: string };
  return data.token;
}

describe('店铺列表契约', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
  });

  it('无 token 访问返回 401', async () => {
    const res = await call(env, 'GET', '/api/v1/clients');
    expect(res.status).toBe(401);
  });

  it('GET /clients 派生字段数值正确（sale_count/payment_count/first_book_date 由内存数据派生，非相关子查询）', async () => {
    const cRes = await call(env, 'POST', '/api/v1/clients', token, { name: '测试店' });
    expect(cRes.status).toBe(201);
    const { id } = (await cRes.json()) as { id: string };

    // 直接插入出货行 / 收款（绕过完整开单，专注列表派生逻辑）
    await env.DB.prepare('INSERT INTO items (id, name, category, category_id, deleted_at) VALUES (?, ?, ?, ?, ?)')
      .bind('item-1', '商品A', '', null, null).run();
    const si = (sid: string, saleId: string, cid: string, amount: number, date: string) =>
      env.DB.prepare('INSERT INTO sale_items (id, sale_id, item_id, client_id, unit, quantity, sale_price, cost_price, amount, happened_at, sync_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
        .bind(sid, saleId, 'item-1', cid, '斤', 1, amount, 0, amount, `${date}T10:00:00Z`, `sk-${sid}`).run();
    await si('si-1', 'sale-1', id, 20, '2026-11-01');
    await si('si-2', 'sale-2', id, 5, '2026-11-05');
    await si('si-3', 'sale-3', 'other-client', 1, '2026-11-02'); // 别的店铺，不应计入

    const pay = (pid: string, cid: string, amount: number, waived: number, date: string) =>
      env.DB.prepare('INSERT INTO payments (id, client_id, happened_at, amount, waived) VALUES (?, ?, ?, ?, ?)')
        .bind(pid, cid, `${date}T10:00:00Z`, amount, waived).run();
    await pay('pay-1', id, 10, 0, '2026-11-03');
    await pay('pay-2', id, 5, 2, '2026-11-04');

    const res = await call(env, 'GET', '/api/v1/clients', token);
    expect(res.status).toBe(200);
    const data = (await res.json()) as {
      clients: Array<{
        id: string; sale_count: number; payment_count: number; first_book_date: string;
        sales_total: number; paid_total: number; debt: number;
      }>;
    };
    const client = data.clients.find((c) => c.id === id)!;
    expect(client).toBeTruthy();
    // 仅本店铺的 2 条出货行 / 2 条收款被计入（另一条属 other-client 不计入）
    expect(client.sale_count).toBe(2);
    expect(client.payment_count).toBe(2);
    // first_book_date = 本店铺出货行中最早的日期（2026-11-01）
    expect(client.first_book_date).toBe('2026-11-01');
    // sales_total = Σamount（20+5），paid_total = Σ(amount+waived)（(10+0)+(5+2)）
    expect(client.sales_total).toBe(25);
    expect(client.paid_total).toBe(17);
    // debt = 25 - 17 = 8（逐笔舍入口径，整数无进位）
    expect(client.debt).toBe(8);
  });
});
