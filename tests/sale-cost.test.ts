/**
 * 出货成本（进价快照）取数测试：默认跟随最近一次进货价；老板显式传手动进价优先；
 * 无进货记录回退商品档案进价；店员不可传手动进价（强制跟随）。
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

type Env = { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };

async function call(env: Env, method: string, path: string, token?: string, body?: unknown): Promise<Response> {
  const headers: Record<string, string> = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  return app.request(`${BASE}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  }, env as never);
}

async function loginAdmin(env: Env) {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  const data = (await res.json()) as { token: string };
  return data.token;
}

async function loginStaff(env: Env) {
  const res = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff1234' });
  const data = (await res.json()) as { token: string };
  return data.token;
}

interface SeedCtx {
  env: Env;
  adminToken: string;
  clientId: string;
  priceId: string;
}

/** 建老板 + 店铺 + 商品（档案进价 archiveCost、售价 salePrice）*/
async function seed(archiveCost: number, salePrice = 3): Promise<SeedCtx> {
  const env = (await setup()).env;
  const adminToken = await loginAdmin(env);
  await call(env, 'POST', '/api/v1/clients', adminToken, { name: '品味轩' });
  const clients = (await (await call(env, 'GET', '/api/v1/clients', adminToken)).json()) as { clients: Array<{ id: string; name: string }> };
  const clientId = clients.clients.find((c) => c.name === '品味轩')!.id;
  await call(env, 'POST', '/api/v1/items', adminToken, { name: '白菜', prices: [{ unit: '斤', purchase_price: archiveCost, sale_price: salePrice }] });
  const items = (await (await call(env, 'GET', '/api/v1/items', adminToken)).json()) as { items: Array<{ id: string; prices: Array<{ id: string }> }> };
  const priceId = items.items[0].prices[0].id;
  return { env, adminToken, clientId, priceId };
}

async function addStaff(env: Env, adminToken: string) {
  await call(env, 'POST', '/api/v1/users', adminToken, { username: 'staff1', password: 'staff1234', role: 'staff' });
}

async function addPurchase(env: Env, token: string, priceId: string, purchasePrice: number) {
  await call(env, 'POST', '/api/v1/purchases', token, {
    happened_at: '2026-09-01', note: '市场进货',
    items: [{ price_id: priceId, quantity: 50, purchase_price: purchasePrice }],
  });
}

/** 创建出货并返回该行成本（adminToken 读回，避免重复 bootstrap 409）*/
async function saleCost(env: Env, token: string, adminToken: string, priceId: string, extraItems: Record<string, unknown> = {}, clientId?: string): Promise<number> {
  const cid = clientId ?? (await (await call(env, 'GET', '/api/v1/clients', token)).json() as { clients: Array<{ id: string }> }).clients[0].id;
  const created = await call(env, 'POST', '/api/v1/sales', token, {
    client_id: cid, happened_at: '2026-09-05',
    items: [{ price_id: priceId, quantity: 10, ...extraItems }],
  });
  const { id } = (await created.json()) as { id: string };
  const got = (await (await call(env, 'GET', `/api/v1/sales/${id}`, adminToken)).json()) as { items: Array<{ cost_price: number }> };
  return got.items[0].cost_price;
}

describe('出货成本（进价快照）取数', () => {
  it('默认跟随最近一次进货价（有进货记录时不用档案进价）', async () => {
    const { env, adminToken, priceId } = await seed(10); // 档案进价 10
    await addPurchase(env, adminToken, priceId, 8); // 最近进货价 8
    const cost = await saleCost(env, adminToken, adminToken, priceId);
    expect(cost).toBe(8);
  });

  it('无进货记录时回退商品档案进价', async () => {
    const { env, adminToken, priceId } = await seed(12);
    const cost = await saleCost(env, adminToken, adminToken, priceId);
    expect(cost).toBe(12);
  });

  it('老板显式传手动进价优先于最近进货价', async () => {
    const { env, adminToken, priceId } = await seed(10);
    await addPurchase(env, adminToken, priceId, 8);
    const cost = await saleCost(env, adminToken, adminToken, priceId, { cost_price: 7 });
    expect(cost).toBe(7);
  });

  it('店员传手动进价被忽略（强制跟随最近进货价）', async () => {
    const { env, adminToken, priceId } = await seed(10);
    await addPurchase(env, adminToken, priceId, 8);
    await addStaff(env, adminToken);
    const staffToken = await loginStaff(env);
    const cost = await saleCost(env, staffToken, adminToken, priceId, { cost_price: 5 });
    expect(cost).toBe(8); // 老板视角读回：8（跟随），不是 5 也不是 0
  });
});