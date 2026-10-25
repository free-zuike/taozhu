/**
 * 批量调价（v0.17.473）：POST /items/bulk-price/preview + /bulk-price，
 * 按百分比/固定值整体调进价/售价（价格组售价联动可选），逐商品变更流 + 审计；店员无权。
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
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }, env as never);
}

async function loginAdmin(env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string }) {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  expect(res.status).toBe(201);
  return ((await res.json()) as { token: string }).token;
}

interface ItemInfo { id: string; prices: Array<{ id: string; unit: string; purchase_price: number; sale_price: number }>; group_prices: Array<{ id: string; group_id: string; sale_price: number }> }

async function listItems(env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string }, token: string): Promise<ItemInfo[]> {
  const d = await call(env, 'GET', '/api/v1/items', token).then((r) => r.json()) as { items: ItemInfo[] };
  return d.items;
}

/** 建商品（含默认价格组售价） */
async function mkItem(env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string }, token: string, name: string, sale = 10, purchase = 5) {
  const create = await call(env, 'POST', '/api/v1/items', token, {
    name, prices: [{ unit: '斤', purchase_price: purchase, sale_price: sale }],
    group_prices: [
      { unit: '斤', group_id: 'pg_retail', sale_price: sale },
      { unit: '斤', group_id: 'pg_vip', sale_price: sale * 0.9 },
    ],
  });
  expect(create.status).toBe(201);
  const items = await listItems(env, token);
  return items.find((x) => x.name === name)!;
}

describe('批量调价（POST /items/bulk-price）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let db: FakeD1;
  let token: string;

  beforeEach(async () => {
    const s = await setup();
    env = s.env;
    db = s.db;
    token = await loginAdmin(env);
  });

  it('preview 百分比 +10 售价：old→new 计算正确；执行后价格落库+变更流+审计', async () => {
    await mkItem(env, token, '白菜', 10, 5);
    await mkItem(env, token, '土豆', 20, 10);
    const items = await listItems(env, token);
    const ids = items.map((x) => x.id);

    // 预览（不落库）：售价 +10% → 11 / 22；进价不变；价格组联动同比例（默认）
    const preview = await call(env, 'POST', '/api/v1/items/bulk-price/preview', token, {
      item_ids: ids, field: 'sale_price', mode: 'percent', value: 10,
    });
    expect(preview.status).toBe(200);
    const pv = (await preview.json()) as { rows: Array<{ item_name: string; old_sale: number; new_sale: number; old_purchase: number; new_purchase: number }>; group_rows: Array<{ item_name: string; group_name: string; old: number; new: number }>; items: number };
    expect(pv.items).toBe(2);
    const bailCai = pv.rows.find((r) => r.item_name === '白菜')!;
    expect(bailCai.old_sale).toBe(10);
    expect(bailCai.new_sale).toBe(11);
    expect(bailCai.old_purchase).toBe(5);
    expect(bailCai.new_purchase).toBe(5); // 只调售价
    const tuDou = pv.rows.find((r) => r.item_name === '土豆')!;
    expect(tuDou.new_sale).toBe(22);
    // 价格组联动：白菜 零售 10→11、VIP 9→9.9
    expect(pv.group_rows.some((g) => g.item_name === '白菜' && g.group_name === '零售' && g.new === 11)).toBe(true);
    expect(pv.group_rows.some((g) => g.item_name === '白菜' && g.group_name === 'VIP' && g.new === 9.9)).toBe(true);

    // 执行
    const exec = await call(env, 'POST', '/api/v1/items/bulk-price', token, {
      item_ids: ids, field: 'sale_price', mode: 'percent', value: 10,
    });
    expect(exec.status).toBe(200);
    expect(((await exec.json()) as { changed: number }).changed).toBe(6); // 2×基准价 + 2×2 组价格组

    const after = await listItems(env, token);
    expect(after.find((x) => x.name === '白菜')!.prices[0].sale_price).toBe(11);
    expect(after.find((x) => x.name === '土豆')!.prices[0].sale_price).toBe(22);
    expect(after.find((x) => x.name === '白菜')!.prices[0].purchase_price).toBe(5);
    expect(after.find((x) => x.name === '白菜')!.group_prices.find((g) => g.group_id === 'pg_vip')!.sale_price).toBe(9.9);
    // 变更流：每个商品一条 item 变更
    const ch = await db.prepare(
      "SELECT entity_sync_id FROM sync_changes WHERE entity_type = 'item' AND entity_sync_id IN (?, ?) ORDER BY id DESC LIMIT 2",
    ).bind(ids[0], ids[1]).all<{ entity_sync_id: string }>();
    expect(ch.results.length).toBe(2);
    // 审计
    const audit = await call(env, 'GET', '/api/v1/audit', token).then((r) => r.json()) as { logs: Array<{ action: string; detail: string }> };
    expect(audit.logs.some((l) => l.action === 'bulk_price' && l.detail.includes('+10%') && l.detail.includes('2 个商品'))).toBe(true);
  });

  it('fixed +0.5 进价且价格组不联动（apply_group_prices=false）', async () => {
    const it = await mkItem(env, token, '萝卜', 10, 5);
    const preview = await call(env, 'POST', '/api/v1/items/bulk-price/preview', token, {
      item_ids: [it.id], field: 'purchase_price', mode: 'fixed', value: 0.5, apply_group_prices: false,
    });
    const pv = (await preview.json()) as { rows: Array<{ new_purchase: number; new_sale: number }>; group_rows: unknown[] };
    expect(pv.rows[0].new_purchase).toBe(5.5);
    expect(pv.rows[0].new_sale).toBe(10);
    expect(pv.group_rows).toEqual([]); // 价格组不参与预览

    const exec = await call(env, 'POST', '/api/v1/items/bulk-price', token, {
      item_ids: [it.id], field: 'purchase_price', mode: 'fixed', value: 0.5, apply_group_prices: false,
    });
    expect(exec.status).toBe(200);
    const after = await listItems(env, token);
    const row = after.find((x) => x.id === it.id)!;
    expect(row.prices[0].purchase_price).toBe(5.5);
    expect(row.prices[0].sale_price).toBe(10);
    expect(row.group_prices.find((g) => g.group_id === 'pg_retail')!.sale_price).toBe(10); // 价格组未动
  });

  it('both + percent：进价售价同比例；价格组联动默认 true', async () => {
    const it = await mkItem(env, token, '洋葱', 10, 5);
    const exec = await call(env, 'POST', '/api/v1/items/bulk-price', token, {
      item_ids: [it.id], field: 'both', mode: 'percent', value: 50,
    });
    expect(exec.status).toBe(200);
    const after = await listItems(env, token);
    const row = after.find((x) => x.id === it.id)!;
    expect(row.prices[0].sale_price).toBe(15);
    expect(row.prices[0].purchase_price).toBe(7.5);
    expect(row.group_prices.find((g) => g.group_id === 'pg_retail')!.sale_price).toBe(15);
    expect(row.group_prices.find((g) => g.group_id === 'pg_vip')!.sale_price).toBe(13.5); // 9 × 1.5
  });

  it('校验：百分比超范围 400；未选商品 400；数值不合法 400', async () => {
    const it = await mkItem(env, token, '茄子', 10, 5);
    expect((await call(env, 'POST', '/api/v1/items/bulk-price', token, { item_ids: [it.id], mode: 'percent', value: 5000 })).status).toBe(400);
    expect((await call(env, 'POST', '/api/v1/items/bulk-price', token, { item_ids: [], mode: 'percent', value: 10 })).status).toBe(400);
    expect((await call(env, 'POST', '/api/v1/items/bulk-price', token, { item_ids: [it.id], mode: 'percent', value: 'abc' })).status).toBe(400);
    expect((await call(env, 'POST', '/api/v1/items/bulk-price', token, { item_ids: [it.id], mode: 'weird', value: 10 })).status).toBe(400);
    expect((await call(env, 'POST', '/api/v1/items/bulk-price', token, { item_ids: ['不存在'], mode: 'percent', value: 10 })).status).toBe(400);
  });

  it('价格未变化（0%）→ changed 0 不写变更流', async () => {
    const it = await mkItem(env, token, '南瓜', 10, 5);
    const exec = await call(env, 'POST', '/api/v1/items/bulk-price', token, {
      item_ids: [it.id], field: 'sale_price', mode: 'percent', value: 0,
    });
    expect(exec.status).toBe(200);
    expect(((await exec.json()) as { changed: number }).changed).toBe(0);
    const ch = await db.prepare(
      "SELECT COUNT(*) AS n FROM sync_changes WHERE entity_type = 'item' AND entity_sync_id = ?",
    ).bind(it.id).first<{ n: number }>();
    expect(ch?.n).toBe(1); // 仅建商品时的一条
  });

  it('店员无权批量调价（403）', async () => {
    const it = await mkItem(env, token, '青椒', 10, 5);
    await call(env, 'POST', '/api/v1/users', token, { username: 'staff1', password: 'staff1234', role: 'staff' });
    const staffToken = ((await (await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff1234' })).json()) as { token: string }).token;
    expect((await call(env, 'POST', '/api/v1/items/bulk-price', staffToken, { item_ids: [it.id], mode: 'percent', value: 10 })).status).toBe(403);
  });
});
