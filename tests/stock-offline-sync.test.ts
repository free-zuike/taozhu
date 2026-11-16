/** 库存操作离线推送：报损 / 盘点调整 / 安全库存阈值走 sync push（本地优先）。
 *  重点：FIFO 批次扣减/建批正确、同 id 重放幂等（不二次扣）、阈值按商品+单位落库。 */
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
  return { DB: db, ASSETS: fakeAssets, JWT_SECRET } as Env;
}

async function call(env: Env, method: string, path: string, token?: string, body?: unknown): Promise<Response> {
  const headers: Record<string, string> = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  return app.request(`${BASE}${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }, env as never);
}

async function loginAdmin(env: Env): Promise<string> {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  return ((await res.json()) as { token: string }).token;
}

/** 建商品 + 进货 10 斤 @2：产生 stock_batches 批次（remaining=10） */
async function seedBatch(env: Env, token: string): Promise<{ itemId: string; unit: string }> {
  const item = await call(env, 'POST', '/api/v1/items', token, {
    name: '白菜', prices: [{ unit: '斤', purchase_price: 2, sale_price: 3 }],
  });
  const itemId = ((await item.json()) as { id: string }).id;
  const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
    items: Array<{ id: string; prices: Array<{ id: string; unit: string }> }>;
  };
  const row = items.items.find((x) => x.id === itemId)!;
  const priceId = row.prices[0].id;
  const purchase = await call(env, 'POST', '/api/v1/purchases', token, {
    happened_at: '2026-09-01',
    items: [{ price_id: priceId, quantity: 10, purchase_price: 2 }],
  });
  expect(purchase.status).toBe(201);
  return { itemId, unit: row.prices[0].unit };
}

async function remaining(env: Env, itemId: string): Promise<number> {
  const r = await env.DB.prepare(
    'SELECT COALESCE(SUM(remaining), 0) AS n FROM stock_batches WHERE item_id = ?',
  ).bind(itemId).first<{ n: number }>();
  return Number(r?.n ?? 0);
}

async function push(env: Env, token: string, changes: unknown[], device = 'phone-a', updatedAt?: string) {
  return call(env, 'POST', '/api/v1/sync/push', token, {
    device_id: device,
    changes: changes.map((c) => ({
      ...(c as Record<string, unknown>),
      updated_at: updatedAt ?? new Date(Date.now() + 60_000).toISOString(),
    })),
  });
}

describe('库存操作离线推送（sync push）', () => {
  let env: Env;
  let token: string;
  beforeEach(async () => {
    env = await setup();
    token = await loginAdmin(env);
  });

  it('报损：扣 FIFO 批次、记流水；同 id 重试幂等不二次扣', async () => {
    const { itemId, unit } = await seedBatch(env, token);
    expect(await remaining(env, itemId)).toBe(10);

    const change = {
      entity_type: 'loss_record', entity_sync_id: 'loss-offline-1', action: 'upsert',
      payload: { id: 'loss-offline-1', item_id: itemId, unit, qty: 3, happened_at: '2026-09-02', note: '菜叶损坏' },
    };
    const first = await push(env, token, [change]);
    expect(((await first.json()) as { accepted: number }).accepted).toBe(1);
    expect(await remaining(env, itemId)).toBe(7);
    const rec = await env.DB.prepare("SELECT qty, amount FROM loss_records WHERE id = 'loss-offline-1'").first<{ qty: number; amount: number }>();
    expect(rec?.qty).toBe(3);
    expect(rec?.amount).toBe(6); // 3 斤 × 批次进价 2

    // 换设备更晚时间戳重放同一条（模拟推送成功但响应丢失后的重试）→ 已存在则幂等跳过批次扣减
    const retry = await push(env, token, [change], 'phone-b', new Date(Date.now() + 120_000).toISOString());
    expect(((await retry.json()) as { accepted: number }).accepted).toBe(1);
    expect(await remaining(env, itemId)).toBe(7);
  });

  it('盘点：盘盈建批、盘亏扣批，同 id 幂等', async () => {
    const { itemId, unit } = await seedBatch(env, token);

    // 盘盈 +5（按档案进价 2 建批）
    const surplus = {
      entity_type: 'stock_adjustment', entity_sync_id: 'adj-plus-1', action: 'upsert',
      payload: { id: 'adj-plus-1', adjust_id: 'count-1', item_id: itemId, unit, qty: 5, happened_at: '2026-09-02', note: '盘盈' },
    };
    expect(((await (await push(env, token, [surplus])).json()) as { accepted: number }).accepted).toBe(1);
    expect(await remaining(env, itemId)).toBe(15);
    const plus = await env.DB.prepare("SELECT qty, price, amount FROM stock_adjustments WHERE id = 'adj-plus-1'").first<{ qty: number; price: number; amount: number }>();
    expect(plus?.qty).toBe(5);
    expect(plus?.price).toBe(2);
    expect(plus?.amount).toBe(10);

    // 同 id 重放（不同设备更晚时间戳）→ 不重复建批
    await push(env, token, [surplus], 'phone-b', new Date(Date.now() + 120_000).toISOString());
    expect(await remaining(env, itemId)).toBe(15);

    // 盘亏 -4：从最早批（进价 2）扣
    const shortage = {
      entity_type: 'stock_adjustment', entity_sync_id: 'adj-minus-1', action: 'upsert',
      payload: { id: 'adj-minus-1', adjust_id: 'count-1', item_id: itemId, unit, qty: -4, happened_at: '2026-09-02', note: '盘亏' },
    };
    expect(((await (await push(env, token, [shortage])).json()) as { accepted: number }).accepted).toBe(1);
    expect(await remaining(env, itemId)).toBe(11);
    const minus = await env.DB.prepare("SELECT qty, amount FROM stock_adjustments WHERE id = 'adj-minus-1'").first<{ qty: number; amount: number }>();
    expect(minus?.qty).toBe(-4);
    expect(minus?.amount).toBe(8);
  });

  it('报损超过库存 → 拒绝（进不了业务表），队列变更不会被静默应用', async () => {
    const { itemId, unit } = await seedBatch(env, token);
    const res = await push(env, token, [{
      entity_type: 'loss_record', entity_sync_id: 'loss-too-much', action: 'upsert',
      payload: { id: 'loss-too-much', item_id: itemId, unit, qty: 99, happened_at: '2026-09-02' },
    }]);
    const d = (await res.json()) as { accepted: number; rejected: number };
    expect(d.accepted).toBe(0);
    expect(d.rejected).toBe(1);
    expect(await remaining(env, itemId)).toBe(10);
    const rec = await env.DB.prepare("SELECT COUNT(*) AS n FROM loss_records WHERE id = 'loss-too-much'").first<{ n: number }>();
    expect(rec?.n ?? 0).toBe(0);
  });

  it('安全库存阈值：upsert 落 stocks.min_stock，重复推送更新同值；pull 下发', async () => {
    const { itemId, unit } = await seedBatch(env, token);
    const id = `${itemId}::${unit}`;
    const mk = (min: number, ts: string) => ({
      entity_type: 'stock_threshold', entity_sync_id: id, action: 'upsert',
      payload: { id, item_id: itemId, unit, min_stock: min },
    });
    expect(((await (await push(env, token, [mk(5, new Date(Date.now() + 60_000).toISOString())])).json()) as { accepted: number }).accepted).toBe(1);
    let row = await env.DB.prepare('SELECT min_stock FROM stocks WHERE item_id = ? AND unit = ?').bind(itemId, unit).first<{ min_stock: number }>();
    expect(row?.min_stock).toBe(5);

    // 更晚时间戳再推 → 更新
    expect(((await (await push(env, token, [mk(8, new Date(Date.now() + 120_000).toISOString())], 'phone-b')).json()) as { accepted: number }).accepted).toBe(1);
    row = await env.DB.prepare('SELECT min_stock FROM stocks WHERE item_id = ? AND unit = ?').bind(itemId, unit).first<{ min_stock: number }>();
    expect(row?.min_stock).toBe(8);

    // pull 下发（其他设备收到阈值变更）
    const pull = (await (await call(env, 'GET', '/api/v1/sync/pull?since=0&device_id=phone-c', token)).json()) as {
      changes: Array<{ entity_type: string; payload: { min_stock?: number } }>;
    };
    const thr = pull.changes.filter((c) => c.entity_type === 'stock_threshold').at(-1);
    expect(thr?.payload.min_stock).toBe(8);
  });
});
