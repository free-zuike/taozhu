/**
 * 版本化只读快照：验证「同版本复用 / 版本变化立即重算 / 损坏自愈 / 强制失效」，
 * 以及三个消费端点（sync/stats、sync/panel、attachments/total）在写后必须保持精确。
 */
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { versionedSnapshot, expireSnapshots } from '../src/lib/snapshot';
import { createFakeD1, fakeAssets, type FakeD1 } from './helpers/fake-d1';

const JWT_SECRET = 'test-secret';
const BASE = 'http://localhost';
type TestEnv = { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };

async function setup(): Promise<TestEnv> {
  resetSchemaState();
  const db = await createFakeD1();
  await ensureSchema(db as never);
  return { DB: db, ASSETS: fakeAssets, JWT_SECRET };
}

async function call(env: TestEnv, method: string, path: string, token?: string, body?: unknown): Promise<Response> {
  const headers: Record<string, string> = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  return app.request(`${BASE}${path}`, {
    method, headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  }, env as never);
}

async function login(env: TestEnv): Promise<string> {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  return ((await res.json()) as { token: string }).token;
}

/** 模拟一次业务写：变更流追加一行即让全局版本号前进 */
async function bumpCursor(db: FakeD1): Promise<void> {
  await db.prepare(
    "INSERT INTO sync_changes (entity_type, entity_sync_id, updated_at) VALUES ('test', 'x', '2026-01-01T00:00:00.000Z')",
  ).run();
}

describe('版本化只读快照', () => {
  let db: FakeD1;
  beforeEach(async () => { db = (await setup()).DB; });

  it('同一版本命中快照不重算；游标前进后立即重算', async () => {
    let calls = 0;
    const compute = async () => ({ n: ++calls });
    const a = await versionedSnapshot(db as never, 'unit', compute);
    expect(a.data.n).toBe(1);
    const b = await versionedSnapshot(db as never, 'unit', compute);
    expect(b.data.n).toBe(1);
    expect(calls).toBe(1);
    expect(b.cursor).toBe(a.cursor);

    await bumpCursor(db);
    const c = await versionedSnapshot(db as never, 'unit', compute);
    expect(c.data.n).toBe(2);
    expect(c.cursor).toBeGreaterThan(a.cursor);
  });

  it('快照损坏时自愈（重新计算而不是抛错）', async () => {
    await db.prepare("INSERT OR REPLACE INTO schema_meta (key, value) VALUES ('snapshot:unit', '{broken')").run();
    const r = await versionedSnapshot(db as never, 'unit', async () => ({ ok: true }));
    expect(r.data.ok).toBe(true);
    const row = await db.prepare("SELECT value FROM schema_meta WHERE key = 'snapshot:unit'").first<{ value: string }>();
    expect(JSON.parse(row?.value ?? '{}').v).toBe(1);
  });

  it('expireSnapshots 强制失效（供绕过变更流的通道使用）', async () => {
    let calls = 0;
    const compute = async () => ({ n: ++calls });
    await versionedSnapshot(db as never, 'unit', compute);
    await expireSnapshots(db as never);
    await versionedSnapshot(db as never, 'unit', compute);
    expect(calls).toBe(2);
  });

  it('配置指纹变化但游标不变时也强制重算（舍入配置只广播、不写变更流）', async () => {
    let calls = 0;
    const compute = async () => ({ n: ++calls });
    const a = await versionedSnapshot(db as never, 'unit', compute, 'carry=0.5|digits=2');
    await versionedSnapshot(db as never, 'unit', compute, 'carry=0.5|digits=2');
    expect(calls).toBe(1);
    const b = await versionedSnapshot(db as never, 'unit', compute, 'carry=0.6|digits=1');
    expect(b.data.n).toBe(2);
    expect(b.cursor).toBe(a.cursor);
  });

  it('快照写在 schema_meta、不与 schema_version 冲突（该表被备份排除）', async () => {
    await versionedSnapshot(db as never, 'unit', async () => ({ n: 1 }));
    const rows = await db.prepare("SELECT key FROM schema_meta WHERE key LIKE 'snapshot:%'").all<{ key: string }>();
    expect(rows.results.map((r) => r.key)).toEqual(['snapshot:unit']);
    const meta = await db.prepare("SELECT value FROM schema_meta WHERE key = 'schema_version'").first<{ value: string }>();
    expect(meta?.value).toBeTruthy();
  });
});

describe('快照消费端：写后必须精确、不得返回陈旧值', () => {
  let env: TestEnv;
  let token: string;
  beforeEach(async () => { env = await setup(); token = await login(env); });

  it('连续两次写入后 sync/stats 计数递增，且 panel / attachments/total 共用同一快照', async () => {
    const readStats = async () => (await (await call(env, 'GET', '/api/v1/sync/stats', token)).json()) as { clients: number };
    const r1 = await call(env, 'POST', '/api/v1/clients', token, { name: '店A' });
    expect(r1.status).toBe(201);
    expect((await readStats()).clients).toBe(1);

    const r2 = await call(env, 'POST', '/api/v1/clients', token, { name: '店B' });
    expect(r2.status).toBe(201);
    expect((await readStats()).clients).toBe(2);

    const panel = (await (await call(env, 'GET', '/api/v1/sync/panel', token)).json()) as { clients: number; attach_file_total: number };
    const total = (await (await call(env, 'GET', '/api/v1/attachments/total', token)).json()) as { total: number };
    expect(panel.clients).toBe(2);
    expect(total.total).toBe(panel.attach_file_total);

    // 三个端点只产生一份全局快照（不是各存一份）
    const rows = await env.DB.prepare("SELECT key FROM schema_meta WHERE key = 'snapshot:sync_counts'").all<{ key: string }>();
    expect(rows.results.length).toBe(1);
  });

  it('overview 欠款：写单（游标变）与改舍入配置（游标不变）都必须实时', async () => {
    const overview = async () => (await (await call(env, 'GET', '/api/v1/stats/overview', token)).json()) as {
      totals: { debt: number; all_sales: number };
    };
    expect((await overview()).totals.debt).toBe(0);

    await env.DB.prepare(
      `INSERT INTO sale_items (id, sale_id, item_id, client_id, unit, quantity, amount, happened_at)
       VALUES ('s1', 'S1', 'i1', 'c1', 'jin', 1, 1.65, '2026-01-01')`,
    ).run();
    await bumpCursor(env.DB);
    expect((await overview()).totals.all_sales).toBe(1.65);

    // PUT /settings/rounding 只做 WS 广播、不 append 变更流 → 游标不变；
    // 若没有配置指纹，这里会拿回旧口径的欠款（回归 v0.17.480 舍入口径事故）
    const put = await call(env, 'PUT', '/api/v1/settings/rounding', token, { carry: 0.6, digits: 1 });
    expect(put.status).toBe(200);
    const after = await overview();
    expect(after.totals.all_sales).toBe(1.6);
    expect(after.totals.debt).toBe(1.6);
  });

  it('overview 命中快照时不再全表读流水表（rows_read 回归护栏）', async () => {
    // 预热：首个请求完成建表迁移并生成快照，之后才开始记录 SQL
    await call(env, 'GET', '/api/v1/stats/overview', token);

    const sqls: string[] = [];
    const origPrepare = env.DB.prepare.bind(env.DB);
    const spy = { prepare: (sql: string) => { sqls.push(sql); return origPrepare(sql); } } as unknown as FakeD1;
    await call({ ...env, DB: spy }, 'GET', '/api/v1/stats/overview', token);

    const fullScans = sqls.filter((s) => /FROM\s+(sale_items|payments|clients)\b/i.test(s) && !/WHERE/i.test(s));
    expect(fullScans).toEqual([]);
    // 今日三项仍实时按日期过滤、走 idx_*_date 索引
    expect(sqls.some((s) => /FROM sale_items si WHERE si\.happened_at = \?/i.test(s))).toBe(true);
  });
});
