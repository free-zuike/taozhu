/**
 * 端到端 API 测试：真实 Hono 路由 + sql.js 内存库（真 SQLite），覆盖核心业务路径。
 */
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { hashPassword, randomId } from '../src/lib/password';
import { createFakeD1, fakeAssets, type FakeD1 } from './helpers/fake-d1';
import { isBackupTime } from '../src/routes/backup';

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
  extraHeaders?: Record<string, string>,
): Promise<Response> {
  const headers: Record<string, string> = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (extraHeaders != null) Object.assign(headers, extraHeaders);
  return app.request(`${BASE}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  }, env as never);
}

async function loginAdmin(env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string }) {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  expect(res.status).toBe(201);
  const data = (await res.json()) as { token: string };
  return data.token;
}

describe('用户级下载源与服务器探测（/me）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
  });

  it('未登录访问返回 401', async () => {
    expect((await call(env, 'GET', '/api/v1/me/download-sources')).status).toBe(401);
    expect((await call(env, 'PUT', '/api/v1/me/download-sources', undefined, { sources: [] })).status).toBe(401);
  });

  it('未设置返回服务器默认镜像；PUT 后回读一致（含 specified）；清空回读 []', async () => {
    const none = (await (await call(env, 'GET', '/api/v1/me/download-sources', token)).json()) as { sources: unknown; specified: string };
    expect(none.sources).not.toBeNull();
    expect((none.sources as Array<{ url: string }>).length).toBeGreaterThan(0); // 服务器下发默认镜像
    expect(none.specified).toBe('');
    const put = await call(env, 'PUT', '/api/v1/me/download-sources', token, {
      sources: [
        { url: 'https://ghfast.top/', enabled: true },
        { url: 'https://ghproxy.com/', enabled: false },
      ],
      specified: 'https://ghfast.top/',
    });
    expect(put.status).toBe(200);
    const got = (await (await call(env, 'GET', '/api/v1/me/download-sources', token)).json()) as {
      sources: Array<{ url: string; enabled: boolean }>;
      specified: string;
    };
    expect(got.sources).toHaveLength(2);
    expect(got.sources[0]).toEqual({ url: 'https://ghfast.top/', enabled: true });
    expect(got.sources[1]).toEqual({ url: 'https://ghproxy.com/', enabled: false });
    expect(got.specified).toBe('https://ghfast.top/');
    // 非法条目剔除、超长截断、条目上限 20
    const dirty = await call(env, 'PUT', '/api/v1/me/download-sources', token, {
      sources: [
        { url: 123, enabled: true },
        { url: 'https://a.com/', enabled: 'yes' },
        { url: 'x'.repeat(600), enabled: true },
      ],
    });
    expect(dirty.status).toBe(200);
    const dd = (await dirty.json()) as { sources: Array<{ url: string; enabled: boolean }> };
    expect(dd.sources).toHaveLength(2); // 非字符串 url 被剔除
    expect(dd.sources[0].url.length).toBeLessThanOrEqual(500);
    // 清空后读回 []
    await call(env, 'PUT', '/api/v1/me/download-sources', token, { sources: [], specified: '' });
    const empty = (await (await call(env, 'GET', '/api/v1/me/download-sources', token)).json()) as { sources: unknown; specified: string };
    expect(empty.sources).toEqual([]);
    expect(empty.specified).toBe('');
  });

  it('probe-source：非法前缀 400；合法前缀返回结构化结果', async () => {
    expect((await call(env, 'POST', '/api/v1/me/probe-source', token, { prefix: 'ftp://x/' })).status).toBe(400);
    const res = await call(env, 'POST', '/api/v1/me/probe-source', token, { prefix: '' });
    expect(res.status).toBe(200);
    const d = (await res.json()) as { ok: boolean; ms: number; status: number; size: number };
    expect(typeof d.ok).toBe('boolean');
    expect(typeof d.ms).toBe('number');
    // 末尾第三个参数=用例超时：服务器端真实探测 GitHub 资产（本地无代理时 fetch 卡到 10s 超时），默认 5s 不够
  }, 30000);
});

describe('认证', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  beforeEach(async () => { env = (await setup()).env; });

  it('bootstrap 创建老板账号并返回 token', async () => {
    const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
    expect(res.status).toBe(201);
    const data = (await res.json()) as { token: string; user: { username: string; role: string } };
    expect(data.user.username).toBe('boss');
    expect(data.user.role).toBe('admin');
    expect(data.token.length).toBeGreaterThan(20);
  });

  it('系统已初始化后 bootstrap 返回 409', async () => {
    await loginAdmin(env);
    const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss2', password: 'admin1234' });
    expect(res.status).toBe(409);
  });

  it('登录成功与失败', async () => {
    await loginAdmin(env);
    const ok = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'boss', password: 'admin1234' });
    expect(ok.status).toBe(200);
    const bad = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'boss', password: 'wrong' });
    expect(bad.status).toBe(401);
  });

  it('无 token 访问业务接口返回 401', async () => {
    const res = await call(env, 'GET', '/api/v1/items');
    expect(res.status).toBe(401);
  });

  it('伪造/篡改 token 被拒绝', async () => {
    await loginAdmin(env);
    const res = await call(env, 'GET', '/api/v1/items', 'aaaa.bbbb.cccc');
    expect(res.status).toBe(401);
  });
});

describe('商品', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  beforeEach(async () => { env = (await setup()).env; token = await loginAdmin(env); });

  it('创建商品（多单位双价组合）并列表回显', async () => {
    const create = await call(env, 'POST', '/api/v1/items', token, {
      name: '白菜', category: '蔬菜',
      prices: [{ unit: '斤', purchase_price: 2.0, sale_price: 2.5 }, { unit: '袋', purchase_price: 18, sale_price: 20 }],
    });
    expect(create.status).toBe(201);
    const list = await call(env, 'GET', '/api/v1/items', token);
    const data = (await list.json()) as { items: Array<{ name: string; prices: unknown[] }> };
    expect(data.items).toHaveLength(1);
    expect(data.items[0].name).toBe('白菜');
    expect(data.items[0].prices).toHaveLength(2);
  });

  it('店员角色不能新建商品（403）', async () => {
    // 直接插入 staff 账号（多用户端点后续实现）
    await env.DB.prepare('INSERT INTO users (id, username, password_hash, role) VALUES (?, ?, ?, ?)')
      .bind(randomId(), 'staff1', await hashPassword('staff123'), 'staff').run();
    const login = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
    const staffToken = ((await login.json()) as { token: string }).token;
    const res = await call(env, 'POST', '/api/v1/items', staffToken, { name: '土豆', prices: [] });
    expect(res.status).toBe(403);
  });
});

describe('记单与欠款联动（核心业务）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  let clientId: string;
  let priceId: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    // 商品：白菜 斤 进2.0 出2.5
    await call(env, 'POST', '/api/v1/items', token, { name: '白菜', category: '蔬菜', prices: [{ unit: '斤', purchase_price: 2.0, sale_price: 2.5 }] });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as { items: Array<{ id: string; prices: Array<{ id: string }> }> };
    priceId = items.items[0].prices[0].id;
    // 店铺：品味轩
    await call(env, 'POST', '/api/v1/clients', token, { name: '品味轩', contact: '王老板' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string; debt: number }> };
    clientId = clients.clients[0].id;
  });

  it('出货单：总额=数量×单价，店铺欠款自动联动', async () => {
    const sale = await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clientId, happened_at: '2026-09-06', note: '早班送菜',
      items: [{ price_id: priceId, quantity: 20, sale_price: 2.6 }],
    });
    expect(sale.status).toBe(201);
    const saleData = (await sale.json()) as { total: number };
    expect(saleData.total).toBe(52);

    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ debt: number; sales_total: number }> };
    expect(clients.clients[0].sales_total).toBe(52);
    expect(clients.clients[0].debt).toBe(52);
  });

  it('出货明细记录进价快照（毛利可算）', async () => {
    await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clientId, happened_at: '2026-09-06',
      items: [{ price_id: priceId, quantity: 20 }],
    });
    const list = (await (await call(env, 'GET', '/api/v1/sales', token)).json()) as {
      sales: Array<{ total: number; items: Array<{ quantity: number; sale_price: number; cost_price: number }> }>;
    };
    expect(list.sales[0].total).toBe(50); // 20 × 默认售价 2.5
    expect(list.sales[0].items[0].cost_price).toBe(2); // 进价快照
  });

  it('进货单：总额=数量×进价', async () => {
    const purchase = await call(env, 'POST', '/api/v1/purchases', token, {
      happened_at: '2026-09-06', note: '市场进货',
      items: [{ price_id: priceId, quantity: 50, purchase_price: 1.9 }],
    });
    expect(purchase.status).toBe(201);
    const data = (await purchase.json()) as { total: number };
    expect(data.total).toBe(95);
  });

  it('出货单必须选店铺且至少一件商品', async () => {
    const noClient = await call(env, 'POST', '/api/v1/sales', token, { items: [{ price_id: priceId, quantity: 1 }] });
    expect(noClient.status).toBe(400);
    const noItems = await call(env, 'POST', '/api/v1/sales', token, { client_id: clientId, items: [] });
    expect(noItems.status).toBe(400);
  });
});

describe('出货明细行级操作（改期 / 单行删除，交易页流水行用）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  let clientId: string;
  let priceId: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    await call(env, 'POST', '/api/v1/items', token, { name: '白菜', prices: [{ unit: '斤', purchase_price: 2.0, sale_price: 2.5 }] });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as { items: Array<{ id: string; prices: Array<{ id: string }> }> };
    priceId = items.items[0].prices[0].id;
    await call(env, 'POST', '/api/v1/clients', token, { name: '品味轩' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string }> };
    clientId = clients.clients[0].id;
  });

  it('行级改期：只改目标行日期，单据日期随最大行日期', async () => {
    const sale = (await (await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clientId, happened_at: '2026-09-06',
      items: [
        { price_id: priceId, quantity: 10, happened_at: '2026-09-05' },
        { price_id: priceId, quantity: 20, happened_at: '2026-09-06' },
      ],
    })).json()) as { id: string };
    const list = (await (await call(env, 'GET', '/api/v1/sales', token)).json()) as {
      sales: Array<{ id: string; happened_at: string; items: Array<{ id: string; happened_at: string | null }> }>;
    };
    const detail = list.sales.find((s) => s.id === sale.id)!;
    expect(detail.happened_at).toBe('2026-09-06');
    const day5 = detail.items.find((i) => i.happened_at === '2026-09-05')!;
    // 把 09-05 那一行改到 09-04 → 单据日期仍为 09-06（最大行日期）
    const move = await call(env, 'POST', '/api/v1/sales/items/date', token, {
      updates: [{ item_id: day5.id, happened_at: '2026-09-04' }],
    });
    expect(move.status).toBe(200);
    const after = (await (await call(env, 'GET', '/api/v1/sales', token)).json()) as {
      sales: Array<{ id: string; happened_at: string; items: Array<{ id: string; happened_at: string | null }> }>;
    };
    const d2 = after.sales.find((s) => s.id === sale.id)!;
    expect(d2.happened_at).toBe('2026-09-06');
    expect(d2.items.map((i) => i.happened_at).sort()).toEqual(['2026-09-04', '2026-09-06']);
    // 全量改到同一天：单据日期跟随
    const moveAll = await call(env, 'POST', '/api/v1/sales/items/date', token, {
      updates: d2.items.map((i) => ({ item_id: i.id, happened_at: '2026-09-10' })),
    });
    expect(moveAll.status).toBe(200);
    const afterAll = (await (await call(env, 'GET', '/api/v1/sales', token)).json()) as {
      sales: Array<{ id: string; happened_at: string; items: Array<{ happened_at: string | null }> }>;
    };
    const d3 = afterAll.sales.find((s) => s.id === sale.id)!;
    expect(d3.happened_at).toBe('2026-09-10');
    // 空 updates / 坏日期 400
    expect((await call(env, 'POST', '/api/v1/sales/items/date', token, { updates: [] })).status).toBe(400);
    expect((await call(env, 'POST', '/api/v1/sales/items/date', token, { updates: [{ item_id: day5.id, happened_at: '09-06' }] })).status).toBe(400);
  });

  it('单行删除：只删该行，总额联动；不存在的行 404', async () => {
    const sale = (await (await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clientId, happened_at: '2026-09-06',
      items: [
        { price_id: priceId, quantity: 10, happened_at: '2026-09-05' },
        { price_id: priceId, quantity: 20, happened_at: '2026-09-06' },
      ],
    })).json()) as { id: string };
    const list = (await (await call(env, 'GET', '/api/v1/sales', token)).json()) as {
      sales: Array<{ id: string; items: Array<{ id: string; quantity: number }>; total: number }>;
    };
    const detail = list.sales.find((s) => s.id === sale.id)!;
    const first = detail.items[0];
    const del = await call(env, 'DELETE', `/api/v1/sales/items/${first.id}`, token);
    expect(del.status).toBe(200);
    const after = (await (await call(env, 'GET', '/api/v1/sales', token)).json()) as {
      sales: Array<{ id: string; items: Array<{ quantity: number }>; total: number }>;
    };
    const d2 = after.sales.find((s) => s.id === sale.id)!;
    expect(d2.items).toHaveLength(1); // 只删第一行，第二行保留
    expect(d2.items[0].quantity).toBe(20);
    expect(d2.total).toBe(50); // 20 × 2.5
    expect((await call(env, 'DELETE', '/api/v1/sales/items/nope', token)).status).toBe(404);
  });

  it('单行编辑：改数量/售价/日期只影响该行，总额与单据日期联动', async () => {
    const sale = (await (await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clientId, happened_at: '2026-09-06',
      items: [
        { price_id: priceId, quantity: 10, happened_at: '2026-09-05' },
        { price_id: priceId, quantity: 20, happened_at: '2026-09-06' },
      ],
    })).json()) as { id: string };
    const list = (await (await call(env, 'GET', '/api/v1/sales', token)).json()) as {
      sales: Array<{ id: string; happened_at: string; items: Array<{ id: string; quantity: number; sale_price: number; happened_at: string | null }>; total: number }>;
    };
    const detail = list.sales.find((s) => s.id === sale.id)!;
    const first = detail.items[0];
    // 改第一行：数量 10→15、售价 2.5→3、日期 09-05→09-07（单据日期取最大行日期 → 09-07）
    const edit = await call(env, 'PATCH', `/api/v1/sales/items/${first.id}`, token, {
      quantity: 15, sale_price: 3, happened_at: '2026-09-07',
    });
    expect(edit.status).toBe(200);
    const after = (await (await call(env, 'GET', '/api/v1/sales', token)).json()) as {
      sales: Array<{ id: string; happened_at: string; items: Array<{ quantity: number; sale_price: number; happened_at: string | null }>; total: number }>;
    };
    const d2 = after.sales.find((s) => s.id === sale.id)!;
    expect(d2.total).toBe(95); // 15 × 3 + 20 × 2.5
    expect(d2.happened_at).toBe('2026-09-07');
    expect(d2.items[0].quantity).toBe(15);
    expect(d2.items[0].sale_price).toBe(3);
    expect(d2.items[1].quantity).toBe(20); // 第二行不受影响
    expect(d2.items[1].sale_price).toBe(2.5);
    // 非法输入：数量 ≤ 0 → 400；不存在的行 → 404
    expect((await call(env, 'PATCH', `/api/v1/sales/items/${first.id}`, token, { quantity: 0 })).status).toBe(400);
    expect((await call(env, 'PATCH', `/api/v1/sales/items/${first.id}`, token, { happened_at: '09-08' })).status).toBe(400);
    expect((await call(env, 'PATCH', '/api/v1/sales/items/nope', token, { quantity: 1 })).status).toBe(404);
  });
});

describe('进货明细行级操作（改期 / 单行删除 / 单行编辑，进货记录页流水行用）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  let priceId: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    await call(env, 'POST', '/api/v1/items', token, { name: '白菜', prices: [{ unit: '斤', purchase_price: 2.0, sale_price: 2.5 }] });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as { items: Array<{ id: string; prices: Array<{ id: string }> }> };
    priceId = items.items[0].prices[0].id;
  });

  it('行级改期：只改目标行日期，单据日期随最大行日期', async () => {
    const purchase = (await (await call(env, 'POST', '/api/v1/purchases', token, {
      happened_at: '2026-09-06',
      items: [
        { price_id: priceId, quantity: 10, happened_at: '2026-09-05' },
        { price_id: priceId, quantity: 20, happened_at: '2026-09-06' },
      ],
    })).json()) as { id: string };
    const list = (await (await call(env, 'GET', '/api/v1/purchases', token)).json()) as {
      purchases: Array<{ id: string; happened_at: string; items: Array<{ id: string; happened_at: string | null }> }>;
    };
    const detail = list.purchases.find((s) => s.id === purchase.id)!;
    expect(detail.happened_at).toBe('2026-09-06');
    const day5 = detail.items.find((i) => i.happened_at === '2026-09-05')!;
    // 把 09-05 那一行改到 09-04 → 单据日期仍为 09-06（最大行日期）
    const move = await call(env, 'POST', '/api/v1/purchases/items/date', token, {
      updates: [{ item_id: day5.id, happened_at: '2026-09-04' }],
    });
    expect(move.status).toBe(200);
    const after = (await (await call(env, 'GET', '/api/v1/purchases', token)).json()) as {
      purchases: Array<{ id: string; happened_at: string; items: Array<{ id: string; happened_at: string | null }> }>;
    };
    const d2 = after.purchases.find((s) => s.id === purchase.id)!;
    expect(d2.happened_at).toBe('2026-09-06');
    expect(d2.items.map((i) => i.happened_at).sort()).toEqual(['2026-09-04', '2026-09-06']);
    // 全量改到同一天：单据日期跟随
    const moveAll = await call(env, 'POST', '/api/v1/purchases/items/date', token, {
      updates: d2.items.map((i) => ({ item_id: i.id, happened_at: '2026-09-10' })),
    });
    expect(moveAll.status).toBe(200);
    const afterAll = (await (await call(env, 'GET', '/api/v1/purchases', token)).json()) as {
      purchases: Array<{ id: string; happened_at: string; items: Array<{ happened_at: string | null }> }>;
    };
    const d3 = afterAll.purchases.find((s) => s.id === purchase.id)!;
    expect(d3.happened_at).toBe('2026-09-10');
    // 空 updates / 坏日期 400
    expect((await call(env, 'POST', '/api/v1/purchases/items/date', token, { updates: [] })).status).toBe(400);
    expect((await call(env, 'POST', '/api/v1/purchases/items/date', token, { updates: [{ item_id: day5.id, happened_at: '09-06' }] })).status).toBe(400);
  });

  it('单行删除：只删该行，总额联动；不存在的行 404', async () => {
    const purchase = (await (await call(env, 'POST', '/api/v1/purchases', token, {
      happened_at: '2026-09-06',
      items: [
        { price_id: priceId, quantity: 10, happened_at: '2026-09-05' },
        { price_id: priceId, quantity: 20, happened_at: '2026-09-06' },
      ],
    })).json()) as { id: string };
    const list = (await (await call(env, 'GET', '/api/v1/purchases', token)).json()) as {
      purchases: Array<{ id: string; items: Array<{ id: string; quantity: number }>; total: number }>;
    };
    const detail = list.purchases.find((s) => s.id === purchase.id)!;
    const first = detail.items[0];
    const del = await call(env, 'DELETE', `/api/v1/purchases/items/${first.id}`, token);
    expect(del.status).toBe(200);
    const after = (await (await call(env, 'GET', '/api/v1/purchases', token)).json()) as {
      purchases: Array<{ id: string; items: Array<{ quantity: number }>; total: number }>;
    };
    const d2 = after.purchases.find((s) => s.id === purchase.id)!;
    expect(d2.items).toHaveLength(1); // 只删第一行，第二行保留
    expect(d2.items[0].quantity).toBe(20);
    expect(d2.total).toBe(40); // 20 × 2.0
    expect((await call(env, 'DELETE', '/api/v1/purchases/items/nope', token)).status).toBe(404);
  });

  it('单行编辑：改数量/进价/日期只影响该行，总额与单据日期联动', async () => {
    const purchase = (await (await call(env, 'POST', '/api/v1/purchases', token, {
      happened_at: '2026-09-06',
      items: [
        { price_id: priceId, quantity: 10, happened_at: '2026-09-05' },
        { price_id: priceId, quantity: 20, happened_at: '2026-09-06' },
      ],
    })).json()) as { id: string };
    const list = (await (await call(env, 'GET', '/api/v1/purchases', token)).json()) as {
      purchases: Array<{ id: string; happened_at: string; items: Array<{ id: string; quantity: number; purchase_price: number; happened_at: string | null }>; total: number }>;
    };
    const detail = list.purchases.find((s) => s.id === purchase.id)!;
    const first = detail.items[0];
    // 改第一行：数量 10→15、进价 2→3、日期 09-05→09-07（单据日期取最大行日期 → 09-07）
    const edit = await call(env, 'PATCH', `/api/v1/purchases/items/${first.id}`, token, {
      quantity: 15, purchase_price: 3, happened_at: '2026-09-07',
    });
    expect(edit.status).toBe(200);
    const after = (await (await call(env, 'GET', '/api/v1/purchases', token)).json()) as {
      purchases: Array<{ id: string; happened_at: string; items: Array<{ quantity: number; purchase_price: number; happened_at: string | null }>; total: number }>;
    };
    const d2 = after.purchases.find((s) => s.id === purchase.id)!;
    expect(d2.total).toBe(85); // 15 × 3 + 20 × 2
    expect(d2.happened_at).toBe('2026-09-07');
    expect(d2.items[0].quantity).toBe(15);
    expect(d2.items[0].purchase_price).toBe(3);
    expect(d2.items[1].quantity).toBe(20); // 第二行不受影响
    expect(d2.items[1].purchase_price).toBe(2);
    // 非法输入：数量 ≤ 0 → 400；不存在的行 → 404
    expect((await call(env, 'PATCH', `/api/v1/purchases/items/${first.id}`, token, { quantity: 0 })).status).toBe(400);
    expect((await call(env, 'PATCH', `/api/v1/purchases/items/${first.id}`, token, { happened_at: '09-08' })).status).toBe(400);
    expect((await call(env, 'PATCH', '/api/v1/purchases/items/nope', token, { quantity: 1 })).status).toBe(404);
  });
});

describe('列表分页（limit/offset + total）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  let clientId: string;
  let priceId: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    await call(env, 'POST', '/api/v1/items', token, { name: '白菜', prices: [{ unit: '斤', purchase_price: 2.0, sale_price: 2.5 }] });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as { items: Array<{ id: string; prices: Array<{ id: string }> }> };
    priceId = items.items[0].prices[0].id;
    await call(env, 'POST', '/api/v1/clients', token, { name: '品味轩' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string }> };
    clientId = clients.clients[0].id;
    // 两笔出货 + 两笔收款 + 一笔进货（日期不同保证排序稳定）
    await call(env, 'POST', '/api/v1/sales', token, { client_id: clientId, happened_at: '2026-09-05', items: [{ price_id: priceId, quantity: 1 }] });
    await call(env, 'POST', '/api/v1/sales', token, { client_id: clientId, happened_at: '2026-09-06', items: [{ price_id: priceId, quantity: 2 }] });
    await call(env, 'POST', '/api/v1/purchases', token, { happened_at: '2026-09-05', items: [{ price_id: priceId, quantity: 3 }] });
    await call(env, 'POST', '/api/v1/payments', token, { client_id: clientId, happened_at: '2026-09-05', amount: 10 });
    await call(env, 'POST', '/api/v1/payments', token, { client_id: clientId, happened_at: '2026-09-06', amount: 20 });
  });

  it('出货单 limit=1 只回 1 条但 total 为 2', async () => {
    const res = await call(env, 'GET', '/api/v1/sales?limit=1', token);
    expect(res.status).toBe(200);
    const data = (await res.json()) as { total: number; sales: unknown[] };
    expect(data.total).toBe(2);
    expect(data.sales).toHaveLength(1);
  });

  it('收款 offset=1 跳过第一条，total 不变', async () => {
    const res = await call(env, 'GET', '/api/v1/payments?limit=1&offset=1', token);
    const data = (await res.json()) as { total: number; payments: Array<{ amount: number }> };
    expect(data.total).toBe(2);
    expect(data.payments).toHaveLength(1);
    expect(data.payments[0].amount).toBe(10); // offset 跳过了更新的 20
  });

  it('进货单 total 与 limit', async () => {
    const res = await call(env, 'GET', '/api/v1/purchases?limit=5', token);
    const data = (await res.json()) as { total: number; purchases: unknown[] };
    expect(data.total).toBe(1);
    expect(data.purchases).toHaveLength(1);
  });

  it('超上限 limit 被钳制在 1000，不报错', async () => {
    const res = await call(env, 'GET', '/api/v1/sales?limit=99999', token);
    expect(res.status).toBe(200);
    const data = (await res.json()) as { total: number };
    expect(data.total).toBe(2);
  });
});

describe('检查更新代理（/auth/latest-version）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  beforeEach(async () => { env = (await setup()).env; });

  it('无需登录返回 200，含 current 版本与 ready/building/source/notes 字段；GitHub 不可达时 latest 为空串不报错', async () => {
    const res = await call(env, 'GET', '/api/v1/auth/latest-version');
    expect(res.status).toBe(200);
    const d = (await res.json()) as { current: string; latest: string; ready: boolean; building: boolean; source: string; notes: string; min_supported: string };
    expect(d.current).toBe('0.17.164');
    expect(typeof d.latest).toBe('string');
    expect(typeof d.ready).toBe('boolean');
    expect(typeof d.building).toBe('boolean');
    expect(typeof d.source).toBe('string');
    expect(typeof d.notes).toBe('string');
    expect(typeof d.min_supported).toBe('string');
    // 末尾第三个参数=用例超时：GitHub/jsDelivr 探测各 6s 超时（测试环境境外网络不佳），默认 5s 不够
  }, 60000);
});

describe('强制更新门禁（x-app-version 低于最低支持版本 → 426）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  beforeEach(async () => {
    env = (await setup()).env;
    const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
    token = ((await res.json()) as { token: string }).token;
  });

  it('携带过旧版本头 → 426 FORCE_UPDATE（含 latest/min_supported）', async () => {
    const res = await call(env, 'GET', '/api/v1/clients', token, undefined, { 'x-app-version': '0.17.100' });
    expect(res.status).toBe(426);
    const d = (await res.json()) as { error: string; latest: string; min_supported: string };
    expect(d.error).toBe('FORCE_UPDATE');
    expect(typeof d.latest).toBe('string');
    expect(typeof d.min_supported).toBe('string');
  });

  it('携带当前版本头 → 放行；不带版本头（Web/小程序）→ 放行', async () => {
    const r1 = await call(env, 'GET', '/api/v1/clients', token, undefined, { 'x-app-version': '0.17.164' });
    expect(r1.status).toBe(200);
    const r2 = await call(env, 'GET', '/api/v1/clients', token);
    expect(r2.status).toBe(200);
  });

  it('更新检查接口不被门禁拦截（低版本也要能查到新版）', async () => {
    const res = await call(env, 'GET', '/api/v1/auth/latest-version', undefined, undefined, { 'x-app-version': '0.17.100' });
    expect(res.status).toBe(200);
    const d = (await res.json()) as { min_supported: string };
    expect(d.min_supported).toBe('0.17.114');
  });
});

describe('商品价格组（增/改/停用）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  let itemId: string;
  let priceId: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    await call(env, 'POST', '/api/v1/items', token, {
      name: '白菜', prices: [{ unit: '斤', purchase_price: 2.0, sale_price: 2.5 }],
    });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string; prices: Array<{ id: string; unit: string; sale_price: number }> }>;
    };
    itemId = items.items[0].id;
    priceId = items.items[0].prices[0].id;
  });

  it('新增价格组：POST /items/:id/prices 后列表出现两组', async () => {
    const res = await call(env, 'POST', `/api/v1/items/${itemId}/prices`, token, {
      unit: '袋', purchase_price: 18, sale_price: 20,
    });
    expect(res.status).toBe(201);
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ prices: Array<{ unit: string }> }>;
    };
    expect(items.items[0].prices.map((p) => p.unit)).toEqual(['斤', '袋']);
  });

  it('改价：PATCH /item-prices/:id 更新进价/售价', async () => {
    const res = await call(env, 'PATCH', `/api/v1/items/item-prices/${priceId}`, token, {
      purchase_price: 2.2, sale_price: 2.8,
    });
    expect(res.status).toBe(200);
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ prices: Array<{ purchase_price: number; sale_price: number }> }>;
    };
    expect(items.items[0].prices[0].purchase_price).toBe(2.2);
    expect(items.items[0].prices[0].sale_price).toBe(2.8);
  });

  it('停用：DELETE /item-prices/:id 后 summary 目录不再返回该价格', async () => {
    const res = await call(env, 'DELETE', `/api/v1/items/item-prices/${priceId}`, token);
    expect(res.status).toBe(204);
    const summary = (await (await call(env, 'GET', '/api/v1/items/summary', token)).json()) as {
      items: Array<{ prices: unknown[] }>;
    };
    expect(summary.items[0].prices).toHaveLength(0);
  });
});

describe('clients 交易笔数（账本选择弹层用）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  let clientId: string;
  let priceId: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    await call(env, 'POST', '/api/v1/items', token, { name: '白菜', prices: [{ unit: '斤', purchase_price: 1, sale_price: 2 }] });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string; prices: Array<{ id: string }> }>;
    };
    priceId = items.items[0].prices[0].id;
    await call(env, 'POST', '/api/v1/clients', token, { name: '品味轩' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as {
      clients: Array<{ id: string }>;
    };
    clientId = clients.clients[0].id;
    await call(env, 'POST', '/api/v1/sales', token, { client_id: clientId, items: [{ price_id: priceId, quantity: 10 }] });
    await call(env, 'POST', '/api/v1/payments', token, { client_id: clientId, amount: 5 });
  });

  it('返回 sale_count/payment_count', async () => {
    const d = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as {
      clients: Array<{ sale_count: number; payment_count: number }>;
    };
    expect(d.clients[0].sale_count).toBe(1);
    expect(d.clients[0].payment_count).toBe(1);
  });
});

describe('收款平账（waived）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  let clientId: string;
  let priceId: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    await call(env, 'POST', '/api/v1/items', token, { name: '白菜', prices: [{ unit: '斤', purchase_price: 1, sale_price: 2 }] });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string; prices: Array<{ id: string }> }>;
    };
    priceId = items.items[0].prices[0].id;
    await call(env, 'POST', '/api/v1/clients', token, { name: '品味轩' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as {
      clients: Array<{ id: string; debt: number }>;
    };
    clientId = clients.clients[0].id;
    // 出货 50 斤 × 2 = 欠款 100
    await call(env, 'POST', '/api/v1/sales', token, { client_id: clientId, items: [{ price_id: priceId, quantity: 50 }] });
  });

  it('实收 90 + 平账 10 → 欠款归零（paid_total 含减免）', async () => {
    const pay = await call(env, 'POST', '/api/v1/payments', token, { client_id: clientId, amount: 90, waived: 10 });
    expect(pay.status).toBe(201);
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as {
      clients: Array<{ paid_total: number; debt: number }>;
    };
    expect(clients.clients[0].paid_total).toBe(100); // 90 实收 + 10 减免
    expect(clients.clients[0].debt).toBe(0);
  });

  it('平账金额为负数 → 400，欠款不变', async () => {
    const pay = await call(env, 'POST', '/api/v1/payments', token, { client_id: clientId, amount: 50, waived: -5 });
    expect(pay.status).toBe(400);
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as {
      clients: Array<{ debt: number }>;
    };
    expect(clients.clients[0].debt).toBe(100);
  });

  it('编辑收款可修改平账金额', async () => {
    const pay = await (await call(env, 'POST', '/api/v1/payments', token, { client_id: clientId, amount: 80 })).json() as { id: string };
    const patch = await call(env, 'PATCH', `/api/v1/payments/${pay.id}`, token, { waived: 20 });
    expect(patch.status).toBe(200);
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as {
      clients: Array<{ debt: number }>;
    };
    expect(clients.clients[0].debt).toBe(0);
  });
});

describe('统计分类聚合 /stats/categories', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  let clientId: string;
  let priceId: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    // 商品分类「蔬菜」+ 白菜
    const cat = (await (await call(env, 'POST', '/api/v1/categories', token, { type: 'item', name: '蔬菜' })).json()) as { id: string };
    await call(env, 'POST', '/api/v1/items', token, { name: '白菜', category_id: cat.id, prices: [{ unit: '斤', purchase_price: 1, sale_price: 2 }] });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string; prices: Array<{ id: string }> }>;
    };
    priceId = items.items[0].prices[0].id;
    await call(env, 'POST', '/api/v1/clients', token, { name: '品味轩' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as {
      clients: Array<{ id: string }>;
    };
    clientId = clients.clients[0].id;
    await call(env, 'POST', '/api/v1/sales', token, { client_id: clientId, happened_at: '2026-09-10', items: [{ price_id: priceId, quantity: 20 }] });
  });

  it('按商品分类聚合出货额与数量', async () => {
    const d = (await (await call(env, 'GET', '/api/v1/stats/categories?start=2026-09-01&end=2026-09-30', token)).json()) as {
      categories: Array<{ category: string; quantity: number; amount: number }>;
    };
    expect(d.categories.length).toBe(1);
    expect(d.categories[0].category).toBe('蔬菜');
    expect(d.categories[0].quantity).toBe(20);
    expect(d.categories[0].amount).toBe(40);
  });

  it('无分类商品归入「未分类」', async () => {
    await call(env, 'POST', '/api/v1/items', token, { name: '散装蛋', prices: [{ unit: '个', purchase_price: 0.5, sale_price: 1 }] });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string; prices: Array<{ id: string }> }>;
    };
    const egg = items.items.find((x) => x.name === '散装蛋')!;
    await call(env, 'POST', '/api/v1/sales', token, { client_id: clientId, happened_at: '2026-09-11', items: [{ price_id: egg.prices[0].id, quantity: 10 }] });
    const d = (await (await call(env, 'GET', '/api/v1/stats/categories?start=2026-09-01&end=2026-09-30', token)).json()) as {
      categories: Array<{ category: string; quantity: number }>;
    };
    expect(d.categories.some((x) => x.category === '未分类')).toBe(true);
  });
});

describe('全库备份导出 /backup', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
  });

  it('老板导出全部业务表数据（含新表 payment_accounts/attachment_refs）', async () => {
    const res = await call(env, 'GET', '/api/v1/backup', token);
    expect(res.status).toBe(200);
    const d = (await res.json()) as { exported_at: string; data: Record<string, unknown[]> };
    expect(d.data).toHaveProperty('clients');
    expect(d.data).toHaveProperty('items');
    // 去单据化：头表已删，备份含行级主记录
    expect(d.data).toHaveProperty('sale_items');
    expect(d.data).toHaveProperty('stocks');
    expect(Array.isArray(d.data.payments)).toBe(true);
    // v0.17.68/84 新增同步实体必须纳入备份（否则导出存档缺收款账户/附件引用）
    expect(Array.isArray(d.data.payment_accounts)).toBe(true);
    expect(Array.isArray(d.data.attachment_refs)).toBe(true);
  });

  it('导入备份：payment_accounts/attachment_refs 同样合并（新表纳入恢复范围）', async () => {
    // 造一个含新表的备份 JSON
    await call(env, 'PUT', '/api/v1/payment-accounts', token, {
      accounts: [{ name: '现金' }, { name: '花呗', bank_name: '网商银行', card_last_four: '8888' }],
    });
    const exp = await call(env, 'GET', '/api/v1/backup', token);
    const ed = (await exp.json()) as { data: Record<string, unknown[]> };
    // 清掉一表后从备份合并恢复
    await env.DB.prepare('DELETE FROM payment_accounts').run();
    const imp = await call(env, 'POST', '/api/v1/backup/import', token, { data: ed.data });
    expect(imp.status).toBe(200);
    const rows = await env.DB.prepare('SELECT id, name, bank_name, card_last_four FROM payment_accounts ORDER BY sort').all<{ id: string; name: string; bank_name: string; card_last_four: string }>();
    expect(rows.results.map((r) => r.name)).toEqual(expect.arrayContaining(['现金', '花呗']));
    expect(rows.results.find((r) => r.name === '花呗')?.bank_name).toBe('网商银行');
  });

  it('店员无权限导出 → 403', async () => {
    await env.DB.prepare('INSERT INTO users (id, username, password_hash, role) VALUES (?, ?, ?, ?)')
      .bind(randomId(), 'staff1', await hashPassword('staff123'), 'staff').run();
    const login = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
    const staffToken = ((await login.json()) as { token: string }).token;
    expect((await call(env, 'GET', '/api/v1/backup', staffToken)).status).toBe(403);
  });
});

describe('对账单分享（/api/v1/share + /share/:token）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
  });

  const payload = JSON.stringify({
    client: '测试饭店',
    from: '2026-09-01',
    to: '2026-09-30',
    debt: 12.34,
    sales: [{ date: '2026-09-01', name: '测试饭店', items: '白菜 ×2斤', amount: 5 }],
    payments: [{ date: '2026-09-02', method: '微信', amount: 3, waived: 0 }],
  });

  it('未登录不能生成分享链接 → 401', async () => {
    const res = await call(env, 'POST', '/api/v1/share', undefined, { payload });
    expect(res.status).toBe(401);
  });

  it('老板生成分享链接（默认 3 天）并可渲染只读页面', async () => {
    const res = await call(env, 'POST', '/api/v1/share', token, { payload, ttl_hours: 72 });
    expect(res.status).toBe(201);
    const d = (await res.json()) as { token: string; url: string; expires_at: string };
    expect(d.url).toContain('/share/');
    expect(d.expires_at).toBeTruthy();
    const page = await app.request(`http://localhost/share/${d.token}`, {}, env as never);
    expect(page.status).toBe(200);
    const html = await page.text();
    expect(html).toContain('测试饭店');
    expect(html).toContain('期末欠款 ¥12.34');
    expect(html).toContain('白菜');
  });

  it('过期的分享返回 410', async () => {
    const res = await call(env, 'POST', '/api/v1/share', token, { payload, ttl_hours: 1 });
    const d = (await res.json()) as { token: string };
    await env.DB.prepare('UPDATE share_links SET expires_at = ? WHERE token = ?')
      .bind('2020-01-01T00:00:00.000Z', d.token).run();
    const page = await app.request(`http://localhost/share/${d.token}`, {}, env as never);
    expect(page.status).toBe(410);
  });

  it('不存在的 token 返回 404', async () => {
    const page = await app.request('http://localhost/share/no-such-token', {}, env as never);
    expect(page.status).toBe(404);
  });

  it('分享列表与取消（GET/DELETE /api/v1/share）', async () => {
    const mk = await call(env, 'POST', '/api/v1/share', token, { payload, ttl_hours: 72 });
    const created = (await mk.json()) as { token: string };
    const list = (await (await call(env, 'GET', '/api/v1/share', token)).json()) as {
      shares: Array<{ token: string; expired: boolean; url: string }>;
    };
    expect(list.shares.length).toBe(1);
    expect(list.shares[0].token).toBe(created.token);
    expect(list.shares[0].expired).toBe(false);
    const del = await call(env, 'DELETE', `/api/v1/share/${created.token}`, token);
    expect(del.status).toBe(200);
    const after = (await (await call(env, 'GET', '/api/v1/share', token)).json()) as { shares: unknown[] };
    expect(after.shares.length).toBe(0);
    const page = await app.request(`http://localhost/share/${created.token}`, {}, env as never);
    expect(page.status).toBe(404);
  });

  it('店员不能生成/管理分享（403）', async () => {
    await env.DB.prepare('INSERT INTO users (id, username, password_hash, role) VALUES (?, ?, ?, ?)')
      .bind(randomId(), 'staff1', await hashPassword('staff123'), 'staff').run();
    const login = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
    const staffToken = ((await login.json()) as { token: string }).token;
    expect((await call(env, 'POST', '/api/v1/share', staffToken, { payload })).status).toBe(403);
    expect((await call(env, 'GET', '/api/v1/share', staffToken)).status).toBe(403);
  });

  it('分享延期（PATCH extend_days / permanent）', async () => {
    const mk = await call(env, 'POST', '/api/v1/share', token, { payload, ttl_hours: 1 });
    const created = (await mk.json()) as { token: string };
    const p1 = await call(env, 'PATCH', `/api/v1/share/${created.token}`, token, { extend_days: 7 });
    expect(p1.status).toBe(200);
    const d1 = (await p1.json()) as { expires_at: string };
    expect(new Date(d1.expires_at).getTime()).toBeGreaterThan(Date.now() + 5 * 86400000);
    const p2 = await call(env, 'PATCH', `/api/v1/share/${created.token}`, token, { permanent: true });
    expect(((await p2.json()) as { expires_at: string | null }).expires_at).toBeNull();
    expect((await call(env, 'PATCH', '/api/v1/share/no-such-token', token, { extend_days: 7 })).status).toBe(404);
  });
});

describe('店员权限收窄（进价打码 / 仅当天出货）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  let staffToken: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    await env.DB.prepare('INSERT INTO users (id, username, password_hash, role) VALUES (?, ?, ?, ?)')
      .bind(randomId(), 'staff1', await hashPassword('staff123'), 'staff').run();
    const login = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
    staffToken = ((await login.json()) as { token: string }).token;
  });

  it('店员商品目录看不到进价（purchase_price 打码为 0），老板可见', async () => {
    const mk = await call(env, 'POST', '/api/v1/items', token, { name: '白菜', prices: [{ unit: '斤', purchase_price: 1.5, sale_price: 2.5 }] });
    expect(mk.status).toBe(201);
    const staffD = await call(env, 'GET', '/api/v1/items/summary', staffToken).then((r) => r.json()) as {
      items: Array<{ prices: Array<{ purchase_price: number }> }>;
    };
    expect(staffD.items[0].prices[0].purchase_price).toBe(0);
    const adminD = await call(env, 'GET', '/api/v1/items/summary', token).then((r) => r.json()) as {
      items: Array<{ prices: Array<{ purchase_price: number }> }>;
    };
    expect(adminD.items[0].prices[0].purchase_price).toBe(1.5);
  });

  it('店员库存看不到成本核算（cost_price 为 0 / can_see_cost=false），老板可见', async () => {
    await call(env, 'POST', '/api/v1/items', token, { name: '白菜', prices: [{ unit: '斤', purchase_price: 1.5, sale_price: 2.5 }] });
    const items = await call(env, 'GET', '/api/v1/items/summary', token).then((r) => r.json()) as {
      items: Array<{ id: string; prices: Array<{ id: string }> }>;
    };
    await call(env, 'POST', '/api/v1/purchases', token, {
      happened_at: new Date().toISOString().slice(0, 10),
      items: [{ price_id: items.items[0].prices[0].id, quantity: 10 }],
    });
    const staffD = await call(env, 'GET', '/api/v1/stocks', staffToken).then((r) => r.json()) as {
      stocks: Array<{ cost_price: number }>;
      can_see_cost: boolean;
    };
    expect(staffD.can_see_cost).toBe(false);
    expect(staffD.stocks[0].cost_price).toBe(0);
    const adminD = await call(env, 'GET', '/api/v1/stocks', token).then((r) => r.json()) as { can_see_cost: boolean };
    expect(adminD.can_see_cost).toBe(true);
  });

  it('店员只能看到当天的出货记录（忽略传入日期）', async () => {
    await env.DB.prepare("INSERT INTO clients (id, name) VALUES (?, ?)").bind('c1', '测试饭店').run();
    await call(env, 'POST', '/api/v1/items', token, { name: '白菜', prices: [{ unit: '斤', purchase_price: 1.5, sale_price: 2.5 }] });
    const items = await call(env, 'GET', '/api/v1/items/summary', token).then((r) => r.json()) as {
      items: Array<{ id: string; prices: Array<{ id: string }> }>;
    };
    const today = new Date().toISOString().slice(0, 10);
    const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    await call(env, 'POST', '/api/v1/sales', token, { client_id: 'c1', happened_at: yesterday, items: [{ price_id: items.items[0].prices[0].id, quantity: 2 }] });
    await call(env, 'POST', '/api/v1/sales', token, { client_id: 'c1', happened_at: today, items: [{ price_id: items.items[0].prices[0].id, quantity: 3 }] });
    const d = await call(env, 'GET', '/api/v1/sales?date_from=2020-01-01', staffToken).then((r) => r.json()) as {
      sales: Array<{ happened_at: string }>;
    };
    expect(d.sales.length).toBe(1);
    expect(d.sales[0].happened_at.slice(0, 10)).toBe(today);
  });
});
describe('单据幂等键（sync_key：离线重放/多端不重复）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    await env.DB.prepare("INSERT INTO clients (id, name) VALUES (?, ?)").bind('c1', '幂等店').run();
    await env.DB.prepare('INSERT INTO items (id, name) VALUES (?, ?)').bind('i1', '白菜').run();
    await env.DB.prepare('INSERT INTO item_prices (id, item_id, unit, purchase_price, sale_price) VALUES (?, ?, ?, ?, ?)')
      .bind('p1', 'i1', '斤', 1, 2).run();
  });

  it('同一 sync_key 重复提交出货只建一张单、库存只扣一次', async () => {
    const body = {
      client_id: 'c1',
      happened_at: new Date().toISOString().slice(0, 10),
      sync_key: 'dup-sale-001',
      items: [{ price_id: 'p1', quantity: 5 }],
    };
    const r1 = await call(env, 'POST', '/api/v1/sales', token, body);
    expect(r1.status).toBe(201);
    const r2 = await call(env, 'POST', '/api/v1/sales', token, body);
    expect(r2.status).toBe(200);
    const d2 = (await r2.json()) as { dup: boolean };
    expect(d2.dup).toBe(true);
    const rows = await env.DB.prepare('SELECT COUNT(DISTINCT sale_id) AS cnt FROM sale_items').all<{ cnt: number }>();
    expect(rows.results[0].cnt).toBe(1);
    const stock = await env.DB.prepare('SELECT quantity FROM stocks WHERE item_id = ? AND unit = ?').bind('i1', '斤').first<{ quantity: number }>();
    expect(stock?.quantity).toBe(-5); // 只扣一次
  });

  it('进货/收款同样幂等', async () => {
    const today = new Date().toISOString().slice(0, 10);
    const pb = { happened_at: today, sync_key: 'dup-pu-001', items: [{ price_id: 'p1', quantity: 3 }] };
    await call(env, 'POST', '/api/v1/purchases', token, pb);
    const p2 = await call(env, 'POST', '/api/v1/purchases', token, pb);
    expect(((await p2.json()) as { dup: boolean }).dup).toBe(true);
    const payBody = { client_id: 'c1', happened_at: today, amount: 10, sync_key: 'dup-pay-001' };
    await call(env, 'POST', '/api/v1/payments', token, payBody);
    const pay2 = await call(env, 'POST', '/api/v1/payments', token, payBody);
    expect(((await pay2.json()) as { dup: boolean }).dup).toBe(true);
    expect((await env.DB.prepare('SELECT COUNT(DISTINCT purchase_id) AS cnt FROM purchase_items').all<{ cnt: number }>()).results[0].cnt).toBe(1);
    expect((await env.DB.prepare('SELECT COUNT(*) AS cnt FROM payments').all<{ cnt: number }>()).results[0].cnt).toBe(1);
  });
});

describe('索引存在（sqlite_master）', () => {
  it('单据幂等/日期/明细索引齐全', async () => {
    const env = (await setup()).env;
    const idx = await env.DB.prepare("SELECT name FROM sqlite_master WHERE type = 'index'").all<{ name: string }>();
    const names = idx.results.map((r) => r.name);
    for (const want of ['idx_payments_sync_key', 'idx_payments_date', 'idx_sale_items_item', 'idx_sale_items_date', 'idx_purchase_items_purchase', 'idx_purchase_items_date']) {
      expect(names).toContain(want);
    }
  });
});

describe('自动备份时间设置（/backup/auto）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  beforeEach(async () => {
    env = (await setup()).env;
    const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
    token = ((await res.json()) as { token: string }).token;
  });

    it('默认 03:05 / 保留 14 份；PUT 保存时间与份数后读回', async () => {
    const d0 = (await (await call(env, 'GET', '/api/v1/backup/auto', token)).json()) as { time: string; configured: boolean; keep: number };
    expect(d0.time).toBe('03:05');
    expect(d0.configured).toBe(false);
    expect(d0.keep).toBe(14);
    expect((await call(env, 'PUT', '/api/v1/backup/auto', token, { time: '06:30' })).status).toBe(200);
    expect((await call(env, 'PUT', '/api/v1/backup/auto', token, { keep: 30 })).status).toBe(200);
    const d1 = (await (await call(env, 'GET', '/api/v1/backup/auto', token)).json()) as { time: string; configured: boolean; keep: number };
    expect(d1.time).toBe('06:30');
    expect(d1.configured).toBe(true);
    expect(d1.keep).toBe(30);
  });

  it('非法时间 400', async () => {
    expect((await call(env, 'PUT', '/api/v1/backup/auto', token, { time: '25:99' })).status).toBe(400);
    expect((await call(env, 'PUT', '/api/v1/backup/auto', token, { time: 'abc' })).status).toBe(400);
  });
});

describe('自动备份时刻命中（isBackupTime：北京时间）', () => {
  it('命中配置时刻；相邻分钟不命中', () => {
    // 2026-01-01T19:05:00Z = 北京时间 03:05
    expect(isBackupTime(new Date('2026-01-01T19:05:00Z'), '03:05')).toBe(true);
    expect(isBackupTime(new Date('2026-01-01T19:06:00Z'), '03:05')).toBe(false);
    expect(isBackupTime(new Date('2026-01-01T16:30:00Z'), '00:30')).toBe(true);
  });
});

describe('操作审计（audit_logs：登录/删除/导出留痕，admin 查看）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  beforeEach(async () => {
    env = (await setup()).env;
    const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
    token = ((await res.json()) as { token: string }).token;
  });

  it('登录与删除交易产生审计日志，GET /audit 可查（admin）', async () => {
    const login = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'boss', password: 'admin1234' });
    expect(login.status).toBe(200);
    await call(env, 'POST', '/api/v1/clients', token, { name: '店A' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string }> };
    await call(env, 'POST', '/api/v1/items', token, { name: '白菜', prices: [{ unit: '斤', purchase_price: 1, sale_price: 2 }] });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as { items: Array<{ prices: Array<{ id: string }> }> };
    const sale = await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clients.clients[0].id, happened_at: '2026-01-05',
      items: [{ price_id: items.items[0].prices[0].id, quantity: 1 }],
    });
    const saleId = ((await sale.json()) as { id: string }).id;
    await call(env, 'DELETE', `/api/v1/sales/${saleId}`, token);

    const d = (await (await call(env, 'GET', '/api/v1/audit', token)).json()) as {
      logs: Array<{ username: string; action: string; action_label?: string; entity_type: string | null; detail: string | null }>;
    };
    expect(d.logs.length).toBeGreaterThanOrEqual(2);
    expect(d.logs.some((l) => l.action === 'login' && l.username === 'boss')).toBe(true);
    // 中文标签（为多语言预留：action 值保持英文稳定，label 供前端显示）
    const loginLog = d.logs.find((l) => l.action === 'login');
    expect(loginLog?.action_label).toBe('登录');
    expect(d.logs.some((l) => l.action === 'delete' && l.entity_type === 'sale' && l.entity_id === saleId)).toBe(true);
  });

  it('店员无权查看审计（adminOnly）', async () => {
    await call(env, 'POST', '/api/v1/users', token, { username: 'staff1', password: 'staff1234', role: 'staff' });
    const login = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff1234' });
    const staffToken = ((await login.json()) as { token: string }).token;
    expect((await call(env, 'GET', '/api/v1/audit', staffToken)).status).toBe(403);
  });
});

describe('备份手动端点（/backup/now、/backup/files 鉴权）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  beforeEach(async () => {
    env = (await setup()).env;
    const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
    token = ((await res.json()) as { token: string }).token;
  });

  it('立即备份 / 备份历史 未登录一律 401；登录后已通过鉴权（无 R2 绑定则存储初始化失败非鉴权错误）', async () => {
    expect((await call(env, 'POST', '/api/v1/backup/now')).status).toBe(401);
    expect((await call(env, 'GET', '/api/v1/backup/files')).status).toBe(401);
    // 已登录：若走到存储初始化（无 R2 绑定抛错）则说明鉴权已放行（500 ≠ 401/403）
    const r = await call(env, 'GET', '/api/v1/backup/files', token);
    expect([500, 200]).toContain(r.status);
  });
});
