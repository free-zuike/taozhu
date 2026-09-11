/** 统计区间测试：summary/daily/clients 的自定义起止日期、按店过滤、欠款含区间前累计 */
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

  it('clients 支持记账开始/结束日期 start_date/end_date', async () => {
    const post = await call(env, 'POST', '/api/v1/clients', token, { name: 'C店', start_date: '2026-09-07', end_date: '2026-10-07' });
    expect(post.status).toBe(201);
    const list = await (await call(env, 'GET', '/api/v1/clients', token)).json() as { clients: Array<{ id: string; name: string; start_date: string; end_date: string }> };
    const c3 = list.clients.find((x) => x.name === 'C店')!;
    expect(c3.start_date).toBe('2026-09-07');
    expect(c3.end_date).toBe('2026-10-07');
    // 编辑更新结束日期
    const id = c3.id;
    const patch = await call(env, 'PATCH', `/api/v1/clients/${id}`, token, { end_date: '2026-11-07' });
    expect(patch.status).toBe(200);
    const list2 = await (await call(env, 'GET', '/api/v1/clients', token)).json() as { clients: Array<{ name: string; end_date: string }> };
    expect(list2.clients.find((x) => x.name === 'C店')!.end_date).toBe('2026-11-07');
  });

  it('clients 每月起始日（默认1=自然月，可设1-28，非法拒绝）', async () => {
    const post = await call(env, 'POST', '/api/v1/clients', token, { name: 'D店' });
    expect(((await post.json()) as { month_start_day: number }).month_start_day).toBe(1);
    const post2 = await call(env, 'POST', '/api/v1/clients', token, { name: 'E店', month_start_day: 5 });
    expect(((await post2.json()) as { month_start_day: number }).month_start_day).toBe(5);
    const bad = await call(env, 'POST', '/api/v1/clients', token, { name: 'F店', month_start_day: 29 });
    expect(bad.status).toBe(400);
    const list = await (await call(env, 'GET', '/api/v1/clients', token)).json() as { clients: Array<{ id: string; name: string; month_start_day: number }> };
    const e5 = list.clients.find((x) => x.name === 'E店')!;
    expect(e5.month_start_day).toBe(5);
    const patch = await call(env, 'PATCH', `/api/v1/clients/${e5.id}`, token, { month_start_day: 15 });
    expect(patch.status).toBe(200);
    const list2 = await (await call(env, 'GET', '/api/v1/clients', token)).json() as { clients: Array<{ name: string; month_start_day: number }> };
    expect(list2.clients.find((x) => x.name === 'E店')!.month_start_day).toBe(15);
  });
});

describe('店员权限：统计接口拒绝访问（403，经营数据仅老板）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let adminToken: string;
  let staffToken: string;

  beforeEach(async () => {
    env = (await setup()).env;
    adminToken = await loginAdmin(env);
    await seed(env.DB);
    await env.DB.prepare('INSERT INTO users (id, username, password_hash, role) VALUES (?, ?, ?, ?)')
      .bind(randomId(), 'staff1', await hashPassword('staff123'), 'staff').run();
    const login = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
    staffToken = ((await login.json()) as { token: string }).token;
  });

  it('店员 overview → 403', async () => {
    const res = await call(env, 'GET', '/api/v1/stats/overview', staffToken);
    expect(res.status).toBe(403);
  });

  it('店员 summary/monthly/clients/daily 全部 403', async () => {
    const results = await Promise.all([
      call(env, 'GET', '/api/v1/stats/summary?start=2026-09-01&end=2026-09-30', staffToken),
      call(env, 'GET', '/api/v1/stats/monthly?year=2026', staffToken),
      call(env, 'GET', '/api/v1/stats/clients', staffToken),
      call(env, 'GET', '/api/v1/stats/daily?start=2026-09-01&end=2026-09-30', staffToken),
    ]);
    for (const res of results) expect(res.status).toBe(403);
  });

  it('老板正常访问统计（毛利可见）', async () => {
    const res = await call(env, 'GET', '/api/v1/stats/overview', adminToken);
    expect(res.status).toBe(200);
    const d = (await res.json()) as { can_see_profit: boolean };
    expect(d.can_see_profit).toBe(true);
  });
});

describe('按店铺分类汇总对账（美食城多档口总账）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    // 店铺分类「美食城」+ 两个档口（client）
    await env.DB.prepare("INSERT INTO categories (id, type, name) VALUES (?, 'client', ?)").bind('cat-food', '美食城').run();
    await env.DB.prepare("INSERT INTO clients (id, name, category_id) VALUES (?, ?, ?)").bind('stall-1', '1号档', 'cat-food').run();
    await env.DB.prepare("INSERT INTO clients (id, name, category_id) VALUES (?, ?, ?)").bind('stall-2', '2号档', 'cat-food').run();
    await env.DB.prepare('INSERT INTO items (id, name) VALUES (?, ?)').bind('i-1', '白菜').run();
    await env.DB.prepare('INSERT INTO item_prices (id, item_id, unit, purchase_price, sale_price) VALUES (?, ?, ?, ?, ?)')
      .bind('p-1', 'i-1', '斤', 1, 2).run();
  });

  it('聚合分类下各档口出货/收款/期末欠款与总合计', async () => {
    const today = new Date().toISOString().slice(0, 10);
    // 1号档出货 5 斤（100 元，单价 2 → sale_items amount=10，重复两次=20）、2号档出货 10 斤=20
    // 用直接插入保证可控金额
    await env.DB.prepare('INSERT INTO sales (id, client_id, happened_at) VALUES (?, ?, ?)').bind('s-1', 'stall-1', `${today}T08:00:00.000Z`).run();
    await env.DB.prepare('INSERT INTO sale_items (id, sale_id, item_id, unit, quantity, sale_price, cost_price, amount) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
      .bind('si-1', 's-1', 'i-1', '斤', 10, 2, 1, 20).run();
    await env.DB.prepare('INSERT INTO sales (id, client_id, happened_at) VALUES (?, ?, ?)').bind('s-2', 'stall-2', `${today}T09:00:00.000Z`).run();
    await env.DB.prepare('INSERT INTO sale_items (id, sale_id, item_id, unit, quantity, sale_price, cost_price, amount) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
      .bind('si-2', 's-2', 'i-1', '斤', 15, 2, 1, 30).run();
    // 1号档收款 8 元（欠 12）
    await env.DB.prepare('INSERT INTO payments (id, client_id, happened_at, amount) VALUES (?, ?, ?, ?)')
      .bind('pay-1', 'stall-1', `${today}T10:00:00.000Z`, 8).run();

    const d = (await (await call(env, 'GET', `/api/v1/stats/category-statement?category_id=cat-food&start=${today}&end=${today}`, token)).json()) as {
      category_name: string;
      clients: Array<{ id: string; sales_total: number; paid_total: number; debt: number }>;
      total: { sales_total: number; paid_total: number; debt: number };
    };
    expect(d.category_name).toBe('美食城');
    expect(d.clients.length).toBe(2);
    expect(d.total.sales_total).toBe(50); // 20 + 30
    expect(d.total.paid_total).toBe(8);
    expect(d.total.debt).toBe(42); // (20-8) + 30
    const stall1 = d.clients.find((x) => x.id === 'stall-1');
    expect(stall1?.sales_total).toBe(20);
    expect(stall1?.debt).toBe(12);
  });

  it('店员无权限查看分类总账（403）', async () => {
    await env.DB.prepare('INSERT INTO users (id, username, password_hash, role) VALUES (?, ?, ?, ?)')
      .bind(randomId(), 'staff1', await hashPassword('staff123'), 'staff').run();
    const login = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
    const staffToken = ((await login.json()) as { token: string }).token;
    const res = await call(env, 'GET', '/api/v1/stats/category-statement?category_id=cat-food&start=2026-09-01&end=2026-09-30', staffToken);
    expect(res.status).toBe(403);
  });
});
