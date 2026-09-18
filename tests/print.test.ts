/**
 * 单据打印路由测试：按单（/print/sale/:id、/print/purchase/:id）与按月（/print/monthly）鉴权与渲染。
 */
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
  expect(res.status).toBe(201);
  return ((await res.json()) as { token: string }).token;
}

describe('单据打印（/print）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let db: FakeD1;
  let token: string;

  beforeEach(async () => {
    ({ db, env } = await setup());
    token = await loginAdmin(env);
    await db.prepare('INSERT INTO clients (id, name) VALUES (?, ?)').bind('c1', '老王菜铺').run();
    await db.prepare('INSERT INTO items (id, name) VALUES (?, ?)').bind('i1', '白菜').run();
    // 出货两行同单（2026-09-10）+ 一行另一单（2026-09-12）
    await db.prepare(
      "INSERT INTO sale_items (id, sale_id, client_id, item_id, unit, quantity, sale_price, cost_price, amount, happened_at, note, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    ).bind('si1', 's1', 'c1', 'i1', '斤', 5, 2, 1, 10, '2026-09-10', '', '2026-09-10T00:00:00Z').run();
    await db.prepare(
      "INSERT INTO sale_items (id, sale_id, client_id, item_id, unit, quantity, sale_price, cost_price, amount, happened_at, note, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    ).bind('si2', 's1', 'c1', 'i1', '斤', 3, 2, 1, 6, '2026-09-10', '', '2026-09-10T00:00:01Z').run();
    await db.prepare(
      "INSERT INTO sale_items (id, sale_id, client_id, item_id, unit, quantity, sale_price, cost_price, amount, happened_at, note, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    ).bind('si3', 's2', 'c1', 'i1', '斤', 4, 2, 1, 8, '2026-09-12', '', '2026-09-12T00:00:00Z').run();
    await db.prepare(
      "INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount, happened_at, note, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    ).bind('pi1', 'p1', 'i1', '斤', 10, 1, 10, '2026-09-11', '', '2026-09-11T00:00:00Z').run();
  });

  it('无 token 一律 401', async () => {
    expect((await call(env, 'GET', '/api/v1/print/sale/s1')).status).toBe(401);
    expect((await call(env, 'GET', '/api/v1/print/monthly?kind=sale&month=2026-09&mode=daily')).status).toBe(401);
  });

  it('按单打印出货：渲染商品行与合计', async () => {
    const res = await call(env, 'GET', `/api/v1/print/sale/s1?token=${token}`);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('出货单');
    expect(html).toContain('白菜');
    expect(html).toContain('16.00'); // 10 + 6 合计
  });

  it('按月每日汇总：两日各一行 + 合计', async () => {
    const res = await call(env, 'GET', `/api/v1/print/monthly?kind=sale&month=2026-09&mode=daily&token=${token}`);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('出货月报（每日汇总）');
    expect(html).toContain('2026-09-10');
    expect(html).toContain('2026-09-12');
    expect(html).toContain('24.00'); // 16 + 8
  });

  it('按月逐单明细：每单一段含商品与分页标记', async () => {
    const res = await call(env, 'GET', `/api/v1/print/monthly?kind=sale&month=2026-09&mode=detail&token=${token}`);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('出货月报（逐单明细）');
    expect(html).toContain('共 2 单');
    expect(html).toContain('白菜');
    expect(html).toContain('page-break-after');
  });

  it('按月旬段汇总模板：标题含店名月销售 + 8 列 + 总计（1-10/11-20/21-30/31 日）', async () => {
    // 现有 seed：9/10 两行 16 元（1-10 段）、9/12 一行 8 元（11-20 段）→ 段1=16、段2=8、总计 24
    const res = await call(env, 'GET', `/api/v1/print/monthly?kind=sale&month=2026-09&mode=period&client_id=c1&token=${token}`);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('老王菜铺9月出货');
    expect(html).toContain('1日到10日');
    expect(html).toContain('11日到20日');
    expect(html).toContain('21日到30日');
    expect(html).toContain('31日');
    expect(html).toContain('总计：¥24.00');
  });

  it('按月进货打印 + 非法月份 400 + 空月提示', async () => {
    const bad = await call(env, 'GET', `/api/v1/print/monthly?kind=sale&month=2026-9&mode=daily&token=${token}`);
    expect(bad.status).toBe(400);
    const res = await call(env, 'GET', `/api/v1/print/monthly?kind=purchase&month=2026-09&mode=daily&token=${token}`);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('进货月报（每日汇总）');
    expect(html).toContain('10.00'); // 进货 10
    const empty = await call(env, 'GET', `/api/v1/print/monthly?kind=sale&month=2026-08&mode=daily&token=${token}`);
    expect((await empty.text())).toContain('该月暂无记录');
  });
});
