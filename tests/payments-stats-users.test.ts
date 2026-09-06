/** ④ 测试：收款欠款联动 / 统计（毛利·按月）/ 多用户账号与权限 */
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
  return { env: { DB: db, ASSETS: fakeAssets, JWT_SECRET } };
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
  return app.request(`${BASE}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }, env as never);
}

async function boot(env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string }) {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  return ((await res.json()) as { token: string }).token;
}

/** 准备：老板 + 白菜(斤 进2.0 出2.5) + 品味轩 + 出货 20 斤(2.6/斤=52) + 收款 30 */
async function seed(
  env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string },
  token: string,
): Promise<{ clientId: string; priceId: string }> {
  await call(env, 'POST', '/api/v1/items', token, { name: '白菜', category: '蔬菜', prices: [{ unit: '斤', purchase_price: 2.0, sale_price: 2.5 }] });
  const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as { items: Array<{ prices: Array<{ id: string }> }> };
  const priceId = items.items[0].prices[0].id;
  await call(env, 'POST', '/api/v1/clients', token, { name: '品味轩' });
  const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string }> };
  const clientId = clients.clients[0].id;
  await call(env, 'POST', '/api/v1/sales', token, {
    client_id: clientId, happened_at: '2026-09-06',
    items: [{ price_id: priceId, quantity: 20, sale_price: 2.6 }],
  });
  return { clientId, priceId };
}

describe('收款与欠款联动', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  let clientId: string;
  beforeEach(async () => { env = (await setup()).env; token = await boot(env); ({ clientId } = await seed(env, token)); });

  it('收款后欠款减少（52 → 收 30 → 欠 22）', async () => {
    const pay = await call(env, 'POST', '/api/v1/payments', token, { client_id: clientId, happened_at: '2026-09-08', amount: 30, method: '微信' });
    expect(pay.status).toBe(201);
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ debt: number; paid_total: number }> };
    expect(clients.clients[0].paid_total).toBe(30);
    expect(clients.clients[0].debt).toBe(22);
  });

  it('收款金额必须大于 0', async () => {
    const res = await call(env, 'POST', '/api/v1/payments', token, { client_id: clientId, amount: 0 });
    expect(res.status).toBe(400);
  });

  it('店员不能登记收款（403）', async () => {
    await call(env, 'POST', '/api/v1/users', token, { username: 'staff1', password: 'staff123', role: 'staff' });
    const login = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
    const staffToken = ((await login.json()) as { token: string }).token;
    const res = await call(env, 'POST', '/api/v1/payments', staffToken, { client_id: clientId, amount: 10 });
    expect(res.status).toBe(403);
  });
});

describe('统计', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  beforeEach(async () => { env = (await setup()).env; token = await boot(env); await seed(env, token); });

  it('工作台概览：今日出货 52 / 毛利 12 / 欠款 52', async () => {
    const overview = (await (await call(env, 'GET', '/api/v1/stats/overview?date=2026-09-06', token)).json()) as {
      today: { sales_total: number; sales_count: number; gross_profit: number };
      totals: { debt: number };
    };
    expect(overview.today.sales_total).toBe(52);
    expect(overview.today.sales_count).toBe(1);
    expect(overview.today.gross_profit).toBe(12); // (2.6 - 2.0) × 20
    expect(overview.totals.debt).toBe(52);
  });

  it('按店统计含毛利', async () => {
    const data = (await (await call(env, 'GET', '/api/v1/stats/clients', token)).json()) as {
      clients: Array<{ name: string; sales_total: number; gross_profit: number; debt: number }>;
    };
    expect(data.clients[0].name).toBe('品味轩');
    expect(data.clients[0].sales_total).toBe(52);
    expect(data.clients[0].gross_profit).toBe(12);
    expect(data.clients[0].debt).toBe(52);
  });

  it('按月统计 2026-09 出货 52 / 毛利 12', async () => {
    const data = (await (await call(env, 'GET', '/api/v1/stats/monthly?year=2026', token)).json()) as {
      months: Array<{ month: string; sales_total: number; gross_profit: number }>;
    };
    expect(data.months[0].month).toBe('2026-09');
    expect(data.months[0].sales_total).toBe(52);
    expect(data.months[0].gross_profit).toBe(12);
  });

  it('有数据年份列表（出货产生 2026）', async () => {
    const data = (await (await call(env, 'GET', '/api/v1/stats/years', token)).json()) as { years: number[] };
    expect(data.years).toContain(2026);
  });
});

describe('统计（空库）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  beforeEach(async () => { env = (await setup()).env; token = await boot(env); });

  it('无任何数据时年份列表为空数组', async () => {
    const data = (await (await call(env, 'GET', '/api/v1/stats/years', token)).json()) as { years: number[] };
    expect(data.years).toEqual([]);
  });
});

describe('多用户账号', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  beforeEach(async () => { env = (await setup()).env; token = await boot(env); });

  it('老板建店员 → 店员能登录但不能访问管理端点', async () => {
    const create = await call(env, 'POST', '/api/v1/users', token, { username: 'staff1', password: 'staff123', role: 'staff' });
    expect(create.status).toBe(201);
    const login = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
    expect(login.status).toBe(200);
    const staffToken = ((await login.json()) as { token: string }).token;
    // 店员访问用户管理 → 403
    const denied = await call(env, 'GET', '/api/v1/users', staffToken);
    expect(denied.status).toBe(403);
    // 店员仍可记单（出货单需要商品）——验证业务可用
    const items = await call(env, 'GET', '/api/v1/items/summary', staffToken);
    expect(items.status).toBe(200);
  });

  it('登录名重复 409', async () => {
    await call(env, 'POST', '/api/v1/users', token, { username: 'staff1', password: 'staff123' });
    const dup = await call(env, 'POST', '/api/v1/users', token, { username: 'staff1', password: 'other123' });
    expect(dup.status).toBe(409);
  });

  it('老板不能删除自己 / 不能降级自己', async () => {
    const me = await call(env, 'GET', '/api/v1/auth/me', token);
    const userId = ((await me.json()) as { user: { id: string } }).user.id;
    const del = await call(env, 'DELETE', `/api/v1/users/${userId}`, token);
    expect(del.status).toBe(400);
    const demote = await call(env, 'PATCH', `/api/v1/users/${userId}`, token, { role: 'staff' });
    expect(demote.status).toBe(400);
  });

  it('老板改店员密码后旧密码失效', async () => {
    await call(env, 'POST', '/api/v1/users', token, { username: 'staff1', password: 'staff123' });
    const users = (await (await call(env, 'GET', '/api/v1/users', token)).json()) as { users: Array<{ id: string; username: string }> };
    const staffId = users.users.find((u) => u.username === 'staff1')!.id;
    await call(env, 'PATCH', `/api/v1/users/${staffId}`, token, { password: 'newpass456' });
    const oldLogin = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
    expect(oldLogin.status).toBe(401);
    const newLogin = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'newpass456' });
    expect(newLogin.status).toBe(200);
  });
});