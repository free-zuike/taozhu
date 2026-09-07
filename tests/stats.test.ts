/** 统计区间测试：summary/daily/clients 的自定义起止日期、按店过滤、欠款含区间前累计 */
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
  return ((await res.json()) as { token: string }).token;
}

/** 直接造多日期数据（绕过 POST 接口的 now 日期限制） */
async function seed(db: FakeD1) {
  // 店铺 A/B
  await db.prepare('INSERT INTO clients (id, name) VALUES (?, ?)').bind('c-a', 'A店').run();
  await db.prepare('INSERT INTO clients (id, name) VALUES (?, ?)').bind('c-b', 'B店').run();
  // 商品白菜（进1出2）
  await db.prepare('INSERT INTO items (id, name) VALUES (?, ?)').bind('i-1', '白菜').run();
  await db.prepare('INSERT INTO item_prices (id, item_id, unit, purchase_price, sale_price) VALUES (?, ?, ?, ?, ?)')
    .bind('p-1', 'i-1', '斤', 1, 2).run();
  // 7月：A店出货100（区间前，计入截止欠款）
  await db.prepare('INSERT INTO sales (id, client_id, happened_at) VALUES (?, ?, ?)').bind('s-0', 'c-a', '2026-07-01T08:00:00.000Z').run();
  await db.prepare('INSERT INTO sale_items (id, sale_id, item_id, unit, quantity, sale_price, cost_price, amount) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
    .bind('si-0', 's-0', 'i-1', '斤', 50, 2, 1, 100).run();
  // 9月1日：A店出货50（毛利50）、9月2日 B店出货40
  await db.prepare('INSERT INTO sales (id, client_id, happened_at) VALUES (?, ?, ?)').bind('s-1', 'c-a', '2026-09-01T08:00:00.000Z').run();
  await db.prepare('INSERT INTO sale_items (id, sale_id, item_id, unit, quantity, sale_price, cost_price, amount) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
    .bind('si-1', 's-1', 'i-1', '斤', 25, 2, 1, 50).run();
  await db.prepare('INSERT INTO sales (id, client_id, happened_at) VALUES (?, ?, ?)').bind('s-2', 'c-b', '2026-09-02T08:00:00.000Z').run();
  await db.prepare('INSERT INTO sale_items (id, sale_id, item_id, unit, quantity, sale_price, cost_price, amount) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
    .bind('si-2', 's-2', 'i-1', '斤', 20, 2, 1, 40).run();
  // 9月3日：进货30
  await db.prepare('INSERT INTO purchases (id, happened_at) VALUES (?, ?)').bind('pu-1', '2026-09-03T08:00:00.000Z').run();
  await db.prepare('INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount) VALUES (?, ?, ?, ?, ?, ?, ?)')
    .bind('pi-1', 'pu-1', 'i-1', '斤', 30, 1, 30).run();
  // 9月4日：A店收款30
  await db.prepare('INSERT INTO payments (id, client_id, happened_at, amount) VALUES (?, ?, ?, ?)')
    .bind('pay-1', 'c-a', '2026-09-04T08:00:00.000Z', 30).run();
}

describe('统计区间', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    await seed(env.DB);
  });

  it('summary 区间汇总（出货/毛利/收款/进货）', async () => {
    const res = await call(env, 'GET', '/api/v1/stats/summary?start=2026-09-01&end=2026-09-30', token);
    expect(res.status).toBe(200);
    const d = (await res.json()) as Record<string, number>;
    expect(d.sales_total).toBe(90);      // 50 + 40
    expect(d.gross_profit).toBe(45);     // 毛利 = (2-1)*45
    expect(d.paid_total).toBe(30);
    expect(d.purchase_total).toBe(30);
    expect(d.sales_count).toBe(2);
  });

  it('summary 欠款含区间前累计（截止 end 全部出货−收款）', async () => {
    const res = await call(env, 'GET', '/api/v1/stats/summary?start=2026-09-01&end=2026-09-30', token);
    const d = (await res.json()) as Record<string, number>;
    expect(d.debt).toBe(160); // (100+50+40) − 30
  });

  it('summary 区间外无数据', async () => {
    const res = await call(env, 'GET', '/api/v1/stats/summary?start=2026-10-01&end=2026-10-31', token);
    const d = (await res.json()) as Record<string, number>;
    expect(d.sales_total).toBe(0);
    expect(d.debt).toBe(160); // 截止10-31：190−30（区间后仍累计到 end）
  });

  it('summary 按店铺过滤', async () => {
    const res = await call(env, 'GET', '/api/v1/stats/summary?start=2026-09-01&end=2026-09-30&client_id=c-a', token);
    const d = (await res.json()) as Record<string, number>;
    expect(d.sales_total).toBe(50);   // 仅 A 店 9月1日那笔
    expect(d.paid_total).toBe(30);
    expect(d.debt).toBe(120);         // (100+50) − 30
  });

  it('daily 按日序列', async () => {
    const res = await call(env, 'GET', '/api/v1/stats/daily?start=2026-09-01&end=2026-09-04', token);
    expect(res.status).toBe(200);
    const d = (await res.json()) as { days: Array<Record<string, number | string>> };
    const days = d.days.map((x) => x.day);
    expect(days).toEqual(['2026-09-01', '2026-09-02']);
    const day1 = d.days.find((x) => x.day === '2026-09-01')!;
    expect(day1.sales_total).toBe(50);
    expect(day1.gross_profit).toBe(25);
  });

  it('daily 按店铺过滤', async () => {
    const res = await call(env, 'GET', '/api/v1/stats/daily?start=2026-09-01&end=2026-09-04&client_id=c-b', token);
    const d = (await res.json()) as { days: Array<Record<string, number | string>> };
    expect(d.days.length).toBe(1);
    expect(d.days[0].day).toBe('2026-09-02');
    expect(d.days[0].sales_total).toBe(40);
  });

  it('clients 区间过滤（全部店铺）', async () => {
    const res = await call(env, 'GET', '/api/v1/stats/clients?start=2026-09-01&end=2026-09-30', token);
    const d = (await res.json()) as { clients: Array<{ name: string; sales_total: number; paid_total: number; gross_profit: number }> };
    const a = d.clients.find((x) => x.name === 'A店')!;
    const b = d.clients.find((x) => x.name === 'B店')!;
    expect(a.sales_total).toBe(50);
    expect(a.paid_total).toBe(30);
    expect(a.gross_profit).toBe(25);
    expect(b.sales_total).toBe(40);
  });

  it('clients 无区间=全部历史累计', async () => {
    const res = await call(env, 'GET', '/api/v1/stats/clients', token);
    const d = (await res.json()) as { clients: Array<{ name: string; sales_total: number }> };
    const a = d.clients.find((x) => x.name === 'A店')!;
    expect(a.sales_total).toBe(150); // 100 + 50
  });

  it('summary 缺 start/end 返回 400', async () => {
    const res = await call(env, 'GET', '/api/v1/stats/summary', token);
    expect(res.status).toBe(400);
  });

  it('items 商品排行（区间内出货额 Top）', async () => {
    const res = await call(env, 'GET', '/api/v1/stats/items?start=2026-09-01&end=2026-09-30', token);
    expect(res.status).toBe(200);
    const d = (await res.json()) as { items: Array<{ name: string; unit: string; quantity: number; amount: number }> };
    expect(d.items.length).toBe(1); // 只有白菜
    expect(d.items[0].name).toBe('白菜');
    expect(d.items[0].quantity).toBe(45); // 25 + 20 斤
    expect(d.items[0].amount).toBe(90);
  });

  it('items 按店铺过滤', async () => {
    const res = await call(env, 'GET', '/api/v1/stats/items?start=2026-09-01&end=2026-09-30&client_id=c-b', token);
    const d = (await res.json()) as { items: Array<{ quantity: number; amount: number }> };
    expect(d.items[0].quantity).toBe(20);
    expect(d.items[0].amount).toBe(40);
  });
});
