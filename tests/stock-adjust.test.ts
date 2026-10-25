/**
 * 库存盘点（v0.17.473）：POST /stocks/adjust 按实际数量校对，
 * 盘盈(+) 往 FIFO 批次加批 / 盘亏(−) 从最早批次扣减，差异记 stock_adjustments 流水
 * （变更流同步 + 审计留痕；防重复提交；店员无权限 + 金额打码）。
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

/** 建商品+价格，返回 { id, price_id } */
async function mkItem(env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string }, token: string, name: string) {
  const create = await call(env, 'POST', '/api/v1/items', token, {
    name, prices: [{ unit: '斤', purchase_price: 2, sale_price: 3 }],
  });
  expect(create.status).toBe(201);
  const list = await call(env, 'GET', '/api/v1/items', token).then((r) => r.json()) as {
    items: Array<{ id: string; prices: Array<{ id: string }> }>;
  };
  const item = list.items.find((x) => x.name === name)!;
  return { id: item.id, price_id: item.prices[0].id };
}

describe('库存盘点（POST /stocks/adjust）', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let db: FakeD1;
  let token: string;

  beforeEach(async () => {
    const s = await setup();
    env = s.env;
    db = s.db;
    token = await loginAdmin(env);
  });

  async function stockQty(itemId: string, unit = '斤'): Promise<number> {
    const d = await call(env, 'GET', '/api/v1/stocks', token).then((r) => r.json()) as {
      stocks: Array<{ item_id: string; unit: string; quantity: number }>;
    };
    const row = d.stocks.find((x) => x.item_id === itemId && x.unit === unit);
    return row?.quantity ?? 0;
  }

  it('盘盈：进 10 实际 15 → 库存 15、新增批次剩余 5、流水/变更流/审计齐', async () => {
    const it = await mkItem(env, token, '土豆');
    await call(env, 'POST', '/api/v1/purchases', token, {
      happened_at: '2026-10-01',
      items: [{ price_id: it.price_id, quantity: 10 }],
    });
    expect(await stockQty(it.id)).toBe(10);

    const r = await call(env, 'POST', '/api/v1/stocks/adjust', token, {
      id: 'ADJ-1',
      rows: [{ item_id: it.id, unit: '斤', actual_qty: 15, note: '盘点多了 5 斤（漏记进货）' }],
      happened_at: '2026-10-20',
    });
    expect(r.status).toBe(200);
    const body = (await r.json()) as { ok: boolean; adjusted: number; surplus: number };
    expect(body.ok).toBe(true);
    expect(body.adjusted).toBe(1);
    expect(body.surplus).toBe(5);

    // 库存=进 10 + 盘盈 5
    expect(await stockQty(it.id)).toBe(15);
    // FIFO 新增批次（盘盈批 remaining=5，价格=档案进价 2）
    const batch = await db.prepare(
      "SELECT batch_id, price, remaining FROM stock_batches WHERE item_id = ? AND unit = '斤'",
    ).bind(it.id).all<{ batch_id: string; price: number; remaining: number }>();
    expect(batch.results.length).toBe(2);
    expect(batch.results.some((b) => b.remaining === 5 && b.price === 2)).toBe(true);
    // 调整流水
    const adj = await db.prepare(
      "SELECT adjust_id, qty, price, amount, happened_at FROM stock_adjustments WHERE item_id = ?",
    ).bind(it.id).first<{ adjust_id: string; qty: number; price: number; amount: number; happened_at: string }>();
    expect(adj?.adjust_id).toBe('ADJ-1');
    expect(adj?.qty).toBe(5);
    expect(adj?.amount).toBe(10);
    expect(adj?.happened_at).toBe('2026-10-20');
    // 变更流
    const ch = await db.prepare(
      "SELECT entity_type, entity_sync_id, action FROM sync_changes WHERE entity_type = 'stock_adjustment'",
    ).all<{ entity_type: string; entity_sync_id: string; action: string }>();
    expect(ch.results.length).toBe(1);
    // 审计
    const audit = await call(env, 'GET', '/api/v1/audit', token).then((r) => r.json()) as {
      logs: Array<{ action: string; entity_type: string }>;
    };
    expect(audit.logs.some((l) => l.action === 'adjust' && l.entity_type === 'stocks')).toBe(true);
  });

  it('盘亏：进 10 实际 7 → 库存 7、最早批次扣 3', async () => {
    const it = await mkItem(env, token, '白菜');
    await call(env, 'POST', '/api/v1/purchases', token, {
      happened_at: '2026-10-01',
      items: [{ price_id: it.price_id, quantity: 10 }],
    });
    const r = await call(env, 'POST', '/api/v1/stocks/adjust', token, {
      id: 'ADJ-2',
      rows: [{ item_id: it.id, unit: '斤', actual_qty: 7 }],
    });
    expect(r.status).toBe(200);
    expect(((await r.json()) as { shortage: number }).shortage).toBe(3);
    expect(await stockQty(it.id)).toBe(7);
    const batch = await db.prepare(
      "SELECT remaining FROM stock_batches WHERE item_id = ? AND unit = '斤'",
    ).bind(it.id).all<{ remaining: number }>();
    expect(batch.results[0]?.remaining).toBe(7);
    // 盘亏金额=3×批价 2=6
    const adj = await db.prepare("SELECT qty, amount FROM stock_adjustments WHERE item_id = ?").bind(it.id).first<{ qty: number; amount: number }>();
    expect(adj?.qty).toBe(-3);
    expect(adj?.amount).toBe(6);
  });

  it('批次不足（批次账与流水不一致）→ 400 拒绝（不静默扣负）', async () => {
    const it = await mkItem(env, token, '芹菜');
    await call(env, 'POST', '/api/v1/purchases', token, {
      happened_at: '2026-10-01',
      items: [{ price_id: it.price_id, quantity: 5 }],
    });
    // 模拟批次账与流水不一致：删掉批次（流水聚合账面仍 5，但无批可扣）
    await db.prepare('DELETE FROM stock_batches WHERE item_id = ?').bind(it.id).run();
    const r = await call(env, 'POST', '/api/v1/stocks/adjust', token, {
      id: 'ADJ-3',
      rows: [{ item_id: it.id, unit: '斤', actual_qty: 2 }], // 盘亏 3 > 批次剩余 0
    });
    expect(r.status).toBe(400);
    expect(((await r.json()) as { error: string }).error).toContain('盘亏超过账面库存');
    // 正常盘点不落任何流水（整单被拒）
    const cnt = await db.prepare('SELECT COUNT(*) AS n FROM stock_adjustments').first<{ n: number }>();
    expect(cnt?.n).toBe(0);
  });

  it('盘亏扣到账面为 0 合法；再盘 0 → 无需调整', async () => {
    const it = await mkItem(env, token, '青菜');
    await call(env, 'POST', '/api/v1/purchases', token, {
      happened_at: '2026-10-01',
      items: [{ price_id: it.price_id, quantity: 5 }],
    });
    // 一次盘到 0（亏 5 = 账面 5，扣光合法）
    const r = await call(env, 'POST', '/api/v1/stocks/adjust', token, {
      id: 'ADJ-4',
      rows: [{ item_id: it.id, unit: '斤', actual_qty: 0 }],
    });
    expect(r.status).toBe(200);
    expect(((await r.json()) as { shortage: number }).shortage).toBe(5);
    // 账面已 0，再盘 0 → 无需调整
    const zero = await call(env, 'POST', '/api/v1/stocks/adjust', token, {
      id: 'ADJ-5',
      rows: [{ item_id: it.id, unit: '斤', actual_qty: 0 }],
    });
    expect(zero.status).toBe(200);
    expect(((await zero.json()) as { adjusted: number }).adjusted).toBe(0);
  });

  it('同一盘点单防重复提交：第二次 400', async () => {
    const it = await mkItem(env, token, '萝卜');
    await call(env, 'POST', '/api/v1/purchases', token, {
      happened_at: '2026-10-01',
      items: [{ price_id: it.price_id, quantity: 8 }],
    });
    const body = { id: 'ADJ-DUP', rows: [{ item_id: it.id, unit: '斤', actual_qty: 10 }] };
    expect((await call(env, 'POST', '/api/v1/stocks/adjust', token, body)).status).toBe(200);
    const dup = await call(env, 'POST', '/api/v1/stocks/adjust', token, body);
    expect(dup.status).toBe(400);
    expect((await dup.json()) as { error: string }).toMatchObject({ error: expect.stringContaining('已提交过') });
    // 库存只调了一次（进 8 + 盘盈 2 = 10，重复提交不会 12）
    expect(await stockQty(it.id)).toBe(10);
  });

  it('账面=实际 → adjusted 0 不落流水', async () => {
    const it = await mkItem(env, token, '洋葱');
    await call(env, 'POST', '/api/v1/purchases', token, {
      happened_at: '2026-10-01',
      items: [{ price_id: it.price_id, quantity: 6 }],
    });
    const r = await call(env, 'POST', '/api/v1/stocks/adjust', token, {
      id: 'ADJ-SAME',
      rows: [{ item_id: it.id, unit: '斤', actual_qty: 6 }],
    });
    expect(r.status).toBe(200);
    expect(((await r.json()) as { adjusted: number }).adjusted).toBe(0);
    const cnt = await db.prepare('SELECT COUNT(*) AS n FROM stock_adjustments').first<{ n: number }>();
    expect(cnt?.n).toBe(0);
  });

  it('店员无权盘点（403）；店员看调整流水金额打码', async () => {
    const it = await mkItem(env, token, '冬瓜');
    await call(env, 'POST', '/api/v1/purchases', token, {
      happened_at: '2026-10-01',
      items: [{ price_id: it.price_id, quantity: 4 }],
    });
    await call(env, 'POST', '/api/v1/users', token, { username: 'staff1', password: 'staff1234', role: 'staff' });
    const staffToken = ((await (await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff1234' })).json()) as { token: string }).token;
    const denied = await call(env, 'POST', '/api/v1/stocks/adjust', staffToken, {
      id: 'ADJ-STAFF',
      rows: [{ item_id: it.id, unit: '斤', actual_qty: 5 }],
    });
    expect(denied.status).toBe(403);
    // 老板盘一次后店员查看流水：金额/单价打码
    await call(env, 'POST', '/api/v1/stocks/adjust', token, {
      id: 'ADJ-6',
      rows: [{ item_id: it.id, unit: '斤', actual_qty: 6 }],
    });
    const d = await call(env, 'GET', '/api/v1/stocks/adjustments', staffToken).then((r) => r.json()) as {
      rows: Array<{ qty: number; cost_visible: boolean }>;
      surplus_qty: number;
      surplus_amount: number;
      shortage_amount: number;
    };
    expect(d.rows.length).toBeGreaterThan(0);
    // 数量可见；成本/金额按 cost_visible 标志由前端控制显示（对齐损耗流水模式），汇总金额店员打码
    expect(d.rows[0].cost_visible).toBe(false);
    expect(d.surplus_qty).toBe(2);
    expect(d.surplus_amount).toBe(0);
    expect(d.shortage_amount).toBe(0);
  });
});
