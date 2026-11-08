/** 流水 CSV 导出：BOM/表头/三类明细、日期与店铺过滤、店员打码、公式注入防护 */
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
  await call(env, 'POST', '/api/v1/sales', token, {
    client_id: clientId, happened_at: '2026-09-01',
    items: [{ price_id: priceId, quantity: 10, sale_price: 5, note: '=1+1' }],
  });
  await call(env, 'POST', '/api/v1/purchases', token, {
    happened_at: '2026-09-02', items: [{ price_id: priceId, quantity: 10, purchase_price: 2 }],
  });
  await call(env, 'POST', '/api/v1/payments', token, {
    client_id: clientId, happened_at: '2026-09-03', amount: 30, waived: 2, method: '微信',
  });
  return { clientId };
}

describe('GET /api/v1/export/transactions.csv', () => {
  let env: Env;
  let token: string;
  let clientId: string;
  beforeEach(async () => {
    ({ env } = await setup());
    token = await boot(env);
    ({ clientId } = await seed(env, token));
  });

  it('返回 UTF-8 BOM + 表头 + 出货/进货/收款三类明细', async () => {
    const res = await call(env, 'GET', '/api/v1/export/transactions.csv', token);
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toContain('text/csv');
    // Response.text() 按 UTF-8 解码规范会吞掉 BOM，必须用原始字节校验
    const bytes = new Uint8Array(await res.arrayBuffer());
    expect([...bytes.slice(0, 3)]).toEqual([0xef, 0xbb, 0xbf]);
    const text = new TextDecoder().decode(bytes);
    const lines = text.replace(/^\uFEFF/, '').trim().split('\r\n');
    expect(lines[0]).toBe('"类型","日期","单号","店铺","商品","单位","数量","单价","金额","成本价","减免","收款方式","备注"');
    expect(lines).toHaveLength(4);
    expect(text).toContain('"出货"');
    expect(text).toContain('"进货"');
    expect(text).toContain('"收款"');
    expect(text).toContain('"品味轩"');
    expect(res.headers.get('x-export-rows')).toBe('3');
  });

  it('公式注入前缀单引号、CSV 内引号被转义', async () => {
    const text = await (await call(env, 'GET', '/api/v1/export/transactions.csv?kind=sale', token)).text();
    expect(text).toContain('"\'=1+1"');
  });

  it('日期区间与店铺过滤正确（店铺过滤不含进货）', async () => {
    const ranged = await (await call(env, 'GET', '/api/v1/export/transactions.csv?date_from=2026-09-02&date_to=2026-09-03', token)).text();
    expect(ranged).not.toContain('"出货"');
    expect(ranged).toContain('"进货"');
    expect(ranged).toContain('"收款"');

    const byClient = await (await call(env, 'GET', `/api/v1/export/transactions.csv?client_id=${clientId}`, token)).text();
    expect(byClient).not.toContain('"进货"');
    expect(byClient).toContain('"出货"');
    expect(byClient).toContain('"收款"');
  });

  it('店员导出打码进价/成本，老板可见', async () => {
    await call(env, 'POST', '/api/v1/users', token, { username: 'staff1', password: 'staff123', role: 'staff' });
    const login = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
    const staffToken = ((await login.json()) as { token: string }).token;
    const staffCsv = await (await call(env, 'GET', '/api/v1/export/transactions.csv?kind=purchase', staffToken)).text();
    const purchaseLine = staffCsv.trim().split('\r\n')[1];
    // 单价（第 8 列）与成本（第 10 列）都为空
    expect(purchaseLine).toContain('""');
    expect(purchaseLine.split(',')[7]).toBe('""');
    const bossCsv = await (await call(env, 'GET', '/api/v1/export/transactions.csv?kind=purchase', token)).text();
    expect(bossCsv.trim().split('\r\n')[1].split(',')[7]).toBe('"2"');
  });

  it('非法 kind / 日期 / 逆序区间一律 400', async () => {
    for (const q of ['kind=nope', 'date_from=2026/09/01', 'date_from=2026-09-05&date_to=2026-09-01']) {
      expect((await call(env, 'GET', `/api/v1/export/transactions.csv?${q}`, token)).status).toBe(400);
    }
  });

  it('limit 达到上限时给出截断标记', async () => {
    const res = await call(env, 'GET', '/api/v1/export/transactions.csv?kind=sale&limit=1', token);
    expect(res.headers.get('x-export-rows')).toBe('1');
    expect(res.headers.get('x-export-truncated')).toBe('1');
  });
});
