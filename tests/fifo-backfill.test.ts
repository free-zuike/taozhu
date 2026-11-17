/** 历史 FIFO 批次账回填：直接插入"没有批次"的旧数据 → 分批重放 → 校验批次/占用/幂等 */
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

/** 直接插旧流水（模拟 0.17.525 之前 App 写入：没有 stock_batches / sale_batch_uses） */
async function seedLegacy(env: Env) {
  const db = env.DB;
  // i1：进货 10@2（1-01）→ 盘盈 2@2.5（1-01 稍后）→ 进货 5@3（1-03）
  await db.prepare(
    `INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount, happened_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind('pi1', 'p1', 'i1', '斤', 10, 2, 20, '2026-01-01', '2026-01-01T00:00:01Z').run();
  await db.prepare(
    `INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount, happened_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind('pi2', 'p2', 'i1', '斤', 5, 3, 15, '2026-01-03', '2026-01-03T00:00:01Z').run();
  await db.prepare(
    `INSERT INTO stock_adjustments (id, adjust_id, item_id, unit, qty, price, amount, happened_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind('sa-p', 'c1', 'i1', '斤', 2, 2.5, 5, '2026-01-01', '2026-01-01T00:00:02Z').run();
  // 出货 4（1-02 早）、报损 1（1-02 晚）、出货 8（1-04）、盘亏 1（1-05）
  await db.prepare(
    `INSERT INTO sale_items (id, sale_id, item_id, client_id, unit, quantity, sale_price, cost_price, amount, happened_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind('si1', 's1', 'i1', 'c', '斤', 4, 3, 2, 12, '2026-01-02', '2026-01-02T00:00:01Z').run();
  await db.prepare(
    `INSERT INTO loss_records (id, item_id, unit, qty, price, amount, happened_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind('l1', 'i1', '斤', 1, 2, 2, '2026-01-02', '2026-01-02T00:00:02Z').run();
  await db.prepare(
    `INSERT INTO sale_items (id, sale_id, item_id, client_id, unit, quantity, sale_price, cost_price, amount, happened_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind('si2', 's2', 'i1', 'c', '斤', 8, 3, 2, 24, '2026-01-04', '2026-01-04T00:00:01Z').run();
  await db.prepare(
    `INSERT INTO stock_adjustments (id, adjust_id, item_id, unit, qty, price, amount, happened_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind('sa-m', 'c2', 'i1', '斤', -1, 3, 3, '2026-01-05', '2026-01-05T00:00:01Z').run();

  // i2：第二个分组（验证分批游标）
  await db.prepare(
    `INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount, happened_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind('pi3', 'p3', 'i2', '件', 3, 5, 15, '2026-02-01', '2026-02-01T00:00:01Z').run();
  await db.prepare(
    `INSERT INTO sale_items (id, sale_id, item_id, client_id, unit, quantity, sale_price, cost_price, amount, happened_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind('si3', 's3', 'i2', 'c', '件', 1, 6, 5, 6, '2026-02-02', '2026-02-02T00:00:01Z').run();
}

describe('历史 FIFO 批次账回填', () => {
  let env: Env;
  let token: string;
  beforeEach(async () => {
    env = await setup();
    token = await loginAdmin(env);
    await seedLegacy(env);
  });

  it('分批重放：建批/出货占用/报损/盘盈亏按时间序，游标可续跑，重复执行幂等', async () => {
    // 第一组 i1（item_id 字典序在前）
    const r1 = (await (await call(env, 'POST', '/api/v1/maintenance/fifo-backfill', token, { max_groups: 1 })).json()) as {
      done: boolean; processed: number;
    };
    expect(r1.done).toBe(false);
    expect(r1.processed).toBe(1);

    const b1 = await env.DB.prepare(
      'SELECT batch_id, remaining FROM stock_batches WHERE item_id = ? ORDER BY batch_id',
    ).bind('i1').all<{ batch_id: string; remaining: number }>();
    // 10@2 + 2@2.5 + 5@3：si1 4 + 报损 1 + si2 8 + 盘亏 1 = 消耗 14 → 剩 3（都在 pi2 批）
    expect(b1.results.length).toBe(3);
    const remain = Object.fromEntries(b1.results.map((x) => [x.batch_id, x.remaining]));
    expect(remain['pi1']).toBe(0);
    expect(remain['sa-p']).toBe(0);
    expect(remain['pi2']).toBe(3);

    const uses = await env.DB.prepare(
      `SELECT sale_item_id, batch_id, qty FROM sale_batch_uses ORDER BY sale_item_id, batch_id`,
    ).all<{ sale_item_id: string; batch_id: string; qty: number }>();
    // si1 用 pi1 4；si2 用 pi1 5 + sa-p 2 + pi2 1
    expect(uses.results.filter((u) => u.sale_item_id === 'si1').map((u) => [u.batch_id, u.qty]))
      .toEqual([['pi1', 4]]);
    const si2 = uses.results.filter((u) => u.sale_item_id === 'si2');
    expect(si2.reduce((s, u) => s + u.qty, 0)).toBe(8);
    // 消耗顺序 pi1(5) → sa-p(2) → pi2(1)；SQL 按 batch_id 排序返回，这里比对映射
    expect(Object.fromEntries(si2.map((u) => [u.batch_id, u.qty]))).toEqual({ pi1: 5, 'sa-p': 2, pi2: 1 });

    // 第二组 i2 → done
    const r2 = (await (await call(env, 'POST', '/api/v1/maintenance/fifo-backfill', token, { max_groups: 1 })).json()) as {
      done: boolean; processed: number;
    };
    expect(r2.done).toBe(true);
    expect(r2.processed).toBe(1);
    const b2 = await env.DB.prepare('SELECT remaining FROM stock_batches WHERE item_id = ?').bind('i2')
      .first<{ remaining: number }>();
    expect(b2?.remaining).toBe(2); // 3 进 - 1 出
    // 两组都处理完后的总占用行数：i1 的 4 行 + i2 的 1 行
    const totalUses = await env.DB.prepare('SELECT COUNT(*) AS n FROM sale_batch_uses').first<{ n: number }>();
    expect(totalUses?.n).toBe(5);

    // 已完成再调：不再处理
    const r3 = (await (await call(env, 'POST', '/api/v1/maintenance/fifo-backfill', token, { max_groups: 10 })).json()) as {
      done: boolean; processed: number;
    };
    expect(r3.done).toBe(true);
    expect(r3.processed).toBe(0);

    // 幂等：reset 后重跑，结果一致
    await call(env, 'POST', '/api/v1/maintenance/fifo-backfill', token, { reset: true });
    let done = false;
    while (!done) {
      const r = (await (await call(env, 'POST', '/api/v1/maintenance/fifo-backfill', token, { max_groups: 5 })).json()) as { done: boolean };
      done = r.done;
    }
    const b1b = await env.DB.prepare(
      'SELECT batch_id, remaining FROM stock_batches WHERE item_id = ? ORDER BY batch_id',
    ).bind('i1').all<{ batch_id: string; remaining: number }>();
    expect(Object.fromEntries(b1b.results.map((x) => [x.batch_id, x.remaining]))).toEqual(remain);
    const useCount = await env.DB.prepare('SELECT COUNT(*) AS n FROM sale_batch_uses').first<{ n: number }>();
    expect(useCount?.n).toBe(totalUses?.n);
  });

  it('每日预算：超出即暂停，预算放大后从断点续跑', async () => {
    // 两组数据；预算 1 行：第一组仍处理（防死锁），第二组因预算不足暂停
    const r1 = (await (await call(env, 'POST', '/api/v1/maintenance/fifo-backfill', token, {
      max_groups: 5, daily_work: 1,
    })).json()) as { done: boolean; paused: boolean; processed: number; remaining_groups: number };
    expect(r1.processed).toBe(1);
    expect(r1.paused).toBe(true);
    expect(r1.done).toBe(false);
    expect(r1.remaining_groups).toBe(1);

    // 预算放大 → 从断点继续，处理剩余组
    const r2 = (await (await call(env, 'POST', '/api/v1/maintenance/fifo-backfill', token, {
      max_groups: 5, daily_work: 100000,
    })).json()) as { done: boolean; paused: boolean; processed: number };
    expect(r2.processed).toBe(1);
    expect(r2.done).toBe(true);
    expect(r2.paused).toBe(false);
  });

  it('员工无权调用', async () => {
    await call(env, 'POST', '/api/v1/users', token, { username: 'staff1', password: 'staff123', role: 'staff' });
    const login = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
    const staffToken = ((await login.json()) as { token: string }).token;
    expect((await call(env, 'POST', '/api/v1/maintenance/fifo-backfill', staffToken, { max_groups: 1 })).status).toBe(403);
  });
});
