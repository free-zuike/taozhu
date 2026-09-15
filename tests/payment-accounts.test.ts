/** 收款账户（payment_accounts）测试：默认预设、全量覆盖增删改、同步流 */
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

describe('收款账户（payment_accounts）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
  });

  it('无 token 返回 401', async () => {
    const res = await call(env, 'GET', '/api/v1/payment-accounts');
    expect(res.status).toBe(401);
  });

  it('默认预设账户（现金/微信/支付宝/银行卡/转账）', async () => {
    const res = await call(env, 'GET', '/api/v1/payment-accounts', token);
    expect(res.status).toBe(200);
    const d = (await res.json()) as { accounts: Array<{ name: string }> };
    expect(d.accounts.map((a) => a.name)).toContain('现金');
    expect(d.accounts.map((a) => a.name)).toContain('微信');
    expect(d.accounts.length).toBe(5);
  });

  it('PUT 全量覆盖：新增/保留/删除，同步流已记录', async () => {
    const res = await call(env, 'PUT', '/api/v1/payment-accounts', token, {
      accounts: [{ name: '现金' }, { name: '花呗' }],
    });
    expect(res.status).toBe(200);
    const d = (await res.json()) as { accounts: Array<{ name: string }> };
    expect(d.accounts.map((a) => a.name)).toEqual(['现金', '花呗']);
    // 同步变更流应包含新账户 upsert 与旧账户删除
    const rows = await env.DB.prepare("SELECT entity_type, entity_sync_id, action FROM sync_changes WHERE entity_type = 'payment_account'").all<{ entity_sync_id: string; action: string }>();
    const byId = new Map(rows.results.map((r) => [r.entity_sync_id, r.action]));
    const upserts = rows.results.filter((r) => r.action === 'upsert');
    const deletes = rows.results.filter((r) => r.action === 'delete');
    expect(upserts.length).toBeGreaterThanOrEqual(1);
    expect(deletes.length).toBeGreaterThanOrEqual(3);
  });

  it('PUT 空列表返回 400（至少保留一个账户）', async () => {
    const res = await call(env, 'PUT', '/api/v1/payment-accounts', token, { accounts: [] });
    expect(res.status).toBe(400);
  });

  it('PUT 未认证返回 401（adminOnly 保护）', async () => {
    const res = await call(env, 'PUT', '/api/v1/payment-accounts', undefined, { accounts: [{ name: '现金' }] });
    expect(res.status).toBe(401);
  });

  it('sync/full 全量返回 payment_accounts，sync/stats 计数含账户', async () => {
    const full = await call(env, 'GET', '/api/v1/sync/full', token);
    expect(full.status).toBe(200);
    const fd = (await full.json()) as { payment_accounts: Array<{ name: string }> };
    expect(fd.payment_accounts.map((a) => a.name)).toContain('现金');

    const stats = await call(env, 'GET', '/api/v1/sync/stats', token);
    const sd = (await stats.json()) as { payment_accounts: number };
    expect(sd.payment_accounts).toBeGreaterThanOrEqual(5);
  });

  it('GET /stats 按收款方式聚合进账总额与笔数（全部历史 + 本月）', async () => {
    // 建店铺 → 登记 3 笔收款：现金 100 / 微信 50 / 微信 25（默认当天，属本月）
    const c1 = await call(env, 'POST', '/api/v1/clients', token, { name: '测试店' });
    const client = (await c1.json()) as { id: string };
    await call(env, 'POST', '/api/v1/payments', token, { client_id: client.id, amount: 100, method: '现金' });
    await call(env, 'POST', '/api/v1/payments', token, { client_id: client.id, amount: 50, method: '微信' });
    await call(env, 'POST', '/api/v1/payments', token, { client_id: client.id, amount: 25, waived: 0, method: '微信' });
    // 上月一笔：本月统计不应包含
    const now = new Date();
    const lastMonth = new Date(now.getFullYear(), now.getMonth() - 1, 15);
    await call(env, 'POST', '/api/v1/payments', token, {
      client_id: client.id, amount: 999, method: '现金',
      happened_at: `${lastMonth.getFullYear()}-${String(lastMonth.getMonth() + 1).padStart(2, '0')}-15`,
    });

    const res = await call(env, 'GET', '/api/v1/payment-accounts/stats', token);
    expect(res.status).toBe(200);
    const d = (await res.json()) as { stats: Array<{ method: string; count: number; total: number; month_total: number; month_count: number }> };
    const byMethod = new Map(d.stats.map((s) => [s.method, s]));
    expect(byMethod.get('现金')?.count).toBe(2); // 本月1 + 上月1
    expect(byMethod.get('现金')?.total).toBe(1099);
    expect(byMethod.get('现金')?.month_count).toBe(1);
    expect(byMethod.get('现金')?.month_total).toBe(100);
    expect(byMethod.get('微信')?.count).toBe(2);
    expect(byMethod.get('微信')?.total).toBe(75);
    expect(byMethod.get('微信')?.month_total).toBe(75);
  });

  it('GET /stats 未认证返回 401', async () => {
    const res = await call(env, 'GET', '/api/v1/payment-accounts/stats');
    expect(res.status).toBe(401);
  });

  it('PUT 支持开户行/卡号后四位：保存读回 + 同步 payload 含新字段', async () => {
    const res = await call(env, 'PUT', '/api/v1/payment-accounts', token, {
      accounts: [
        { name: '现金' },
        { name: '银行卡', bank_name: '工商银行', card_last_four: '1234' },
        { name: '支付宝' },
      ],
    });
    expect(res.status).toBe(200);
    const d = (await res.json()) as { accounts: Array<{ name: string; bank_name?: string; card_last_four?: string }> };
    const bank = d.accounts.find((a) => a.name === '银行卡');
    expect(bank?.bank_name).toBe('工商银行');
    expect(bank?.card_last_four).toBe('1234');
    // GET 读回一致
    const again = (await (await call(env, 'GET', '/api/v1/payment-accounts', token)).json()) as {
      accounts: Array<{ name: string; bank_name?: string; card_last_four?: string }>;
    };
    expect(again.accounts.find((a) => a.name === '银行卡')?.bank_name).toBe('工商银行');
    // 同步 payload 含新字段（pull 合并后本地镜像可还原卡号）
    const changes = await env.DB.prepare(
      "SELECT payload_json FROM sync_changes WHERE entity_type = 'payment_account' AND action = 'upsert'",
    ).all<{ payload_json: string }>();
    const payloads = changes.results.map((r) => JSON.parse(r.payload_json)) as Array<{ name?: string; bank_name?: string; card_last_four?: string }>;
    // 按名字找到银行卡的 payload（id 动态生成，用 name 匹配）
    const bankPayload = payloads.find((p) => p.name === '银行卡');
    expect(bankPayload).toBeTruthy();
    expect(bankPayload?.bank_name).toBe('工商银行');
    expect(bankPayload?.card_last_four).toBe('1234');
  });

  it('同步 full 返回包含开户行/卡号', async () => {
    await call(env, 'PUT', '/api/v1/payment-accounts', token, {
      accounts: [{ name: '银行卡', bank_name: '建设银行', card_last_four: '8888' }],
    });
    const full = await call(env, 'GET', '/api/v1/sync/full', token);
    const fd = (await full.json()) as { payment_accounts: Array<{ name: string; bank_name?: string; card_last_four?: string }> };
    const bank = fd.payment_accounts.find((a) => a.name === '银行卡');
    expect(bank?.bank_name).toBe('建设银行');
    expect(bank?.card_last_four).toBe('8888');
  });
});