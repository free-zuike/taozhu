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
});