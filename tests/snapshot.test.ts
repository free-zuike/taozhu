/**
 * 版本化只读快照：验证「同版本复用 / 版本变化立即重算 / 损坏自愈 / 强制失效」，
 * 以及三个消费端点（sync/stats、sync/panel、attachments/total）在写后必须保持精确。
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { versionedSnapshot, expireSnapshots, unaffectedTypes } from '../src/lib/snapshot';
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

  it('affectedSince：无关写推进游标时复用旧数据，并只把快照游标推进写回', async () => {
    let calls = 0;
    const compute = async () => ({ n: ++calls });
    const opts = { affectedSince: async () => false };
    const a = await versionedSnapshot(db as never, 'unit', compute, '', opts);
    expect(a.data.n).toBe(1);

    await bumpCursor(db);
    const b = await versionedSnapshot(db as never, 'unit', compute, '', opts);
    expect(b.data.n).toBe(1);
    expect(calls).toBe(1);
    expect(b.cursor).toBeGreaterThan(a.cursor);

    // 复用时写回的 envelope 必须带上新游标，否则下一次会重复判定
    const row = await db.prepare("SELECT value FROM schema_meta WHERE key = 'snapshot:unit'").first<{ value: string }>();
    expect(JSON.parse(row?.value ?? '{}').cursor).toBe(b.cursor);
    const c = await versionedSnapshot(db as never, 'unit', compute, '', opts);
    expect(c.data.n).toBe(1);
    expect(calls).toBe(1);
  });

  it('affectedSince：判定相关或判定抛错时一律保守重算（绝不返回陈旧值）', async () => {
    let calls = 0;
    const compute = async () => ({ n: ++calls });
    const related = { affectedSince: async () => true };
    await versionedSnapshot(db as never, 'unit', compute, '', related);
    await bumpCursor(db);
    expect((await versionedSnapshot(db as never, 'unit', compute, '', related)).data.n).toBe(2);

    const broken = { affectedSince: async () => { throw new Error('D1 瞬时失败'); } };
    await bumpCursor(db);
    expect((await versionedSnapshot(db as never, 'unit', compute, '', broken)).data.n).toBe(3);
  });

  it('affectedSince 复用不刷新 TTL：超过 TTL 后仍强制重算（兜底绕过变更流的写入）', async () => {
    let calls = 0;
    const compute = async () => ({ n: ++calls });
    const opts = { ttlMs: 60_000, affectedSince: async () => false };
    const nowSpy = vi.spyOn(Date, 'now');
    try {
      nowSpy.mockReturnValue(1_000_000);
      await versionedSnapshot(db as never, 'unit', compute, '', opts);
      nowSpy.mockReturnValue(1_030_000);
      await bumpCursor(db);
      const b = await versionedSnapshot(db as never, 'unit', compute, '', opts);
      expect(b.data.n).toBe(1);
      expect(calls).toBe(1);
      const row = await db.prepare("SELECT value FROM schema_meta WHERE key = 'snapshot:unit'").first<{ value: string }>();
      expect(JSON.parse(row?.value ?? '{}').ts).toBe(1_000_000);
      nowSpy.mockReturnValue(1_070_000);
      const c = await versionedSnapshot(db as never, 'unit', compute, '', opts);
      expect(c.data.n).toBe(2);
    } finally {
      nowSpy.mockRestore();
    }
  });

  it('unaffectedTypes：白名单内的写不重算，未知 entity_type 保守重算', async () => {
    let calls = 0;
    const compute = async () => ({ n: ++calls });
    const opts = { affectedSince: unaffectedTypes(db as never, ['client', 'device']) };
    await versionedSnapshot(db as never, 'unit', compute, '', opts);
    await db.prepare(
      "INSERT INTO sync_changes (entity_type, entity_sync_id, updated_at) VALUES ('client', 'c1', '2026-01-01')",
    ).run();
    expect((await versionedSnapshot(db as never, 'unit', compute, '', opts)).data.n).toBe(1);
    await db.prepare(
      "INSERT INTO sync_changes (entity_type, entity_sync_id, updated_at) VALUES ('future_entity', 'x', '2026-01-01')",
    ).run();
    expect((await versionedSnapshot(db as never, 'unit', compute, '', opts)).data.n).toBe(2);
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

  it('clients 列表：命中快照不再全表读流水表；写单/改舍入配置/q 搜索都正确', async () => {
    const readClients = async (q = '') => {
      const path = q ? `/api/v1/clients?q=${q}` : '/api/v1/clients';
      return (await (await call(env, 'GET', path, token)).json()) as {
        clients: Array<{ id: string; name: string; debt: number; sales_total: number }>;
      };
    };
    const created = await call(env, 'POST', '/api/v1/clients', token, { name: 'Alpha' });
    const { id } = (await created.json()) as { id: string };
    await call(env, 'POST', '/api/v1/clients', token, { name: 'Beta' });
    // 预热：首次请求生成快照
    expect((await readClients()).clients).toHaveLength(2);

    // 命中快照时不再全表读 sale_items / payments / clients
    const sqls: string[] = [];
    const origPrepare = env.DB.prepare.bind(env.DB);
    const spy = { prepare: (sql: string) => { sqls.push(sql); return origPrepare(sql); } } as unknown as FakeD1;
    await call({ ...env, DB: spy }, 'GET', '/api/v1/clients', token);
    const fullScans = sqls.filter((s) => /FROM\s+(sale_items|payments|clients)\b/i.test(s) && !/WHERE/i.test(s));
    expect(fullScans).toEqual([]);

    // 写单（游标前进）→ 快照失效，欠款/出货额实时
    await env.DB.prepare(
      `INSERT INTO sale_items (id, sale_id, item_id, client_id, unit, quantity, amount, happened_at)
       VALUES ('s1', 'S1', 'i1', ?, 'jin', 1, 1.65, '2026-01-01')`,
    ).bind(id).run();
    await bumpCursor(env.DB);
    const afterWrite = (await readClients()).clients.find((c) => c.id === id)!;
    expect(afterWrite.sales_total).toBe(1.65);
    expect(afterWrite.debt).toBe(1.65);

    // 改舍入配置（只 WS 广播、游标不变）→ fingerprint 变化强制重算
    const put = await call(env, 'PUT', '/api/v1/settings/rounding', token, { carry: 0.6, digits: 1 });
    expect(put.status).toBe(200);
    expect((await readClients()).clients.find((c) => c.id === id)!.debt).toBe(1.6);

    // q 搜索从 SQL 过滤改为缓存后 JS 过滤，语义保持
    const searched = await readClients('Beta');
    expect(searched.clients.map((c) => c.name)).toEqual(['Beta']);
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

  it('clients 派生取消两个全表聚合子查询（rows_read 护栏）', async () => {
    const sqls: string[] = [];
    const orig = env.DB.prepare.bind(env.DB);
    const spy = vi.spyOn(env.DB, 'prepare').mockImplementation(((sql: string) => {
      sqls.push(sql);
      return orig(sql);
    }) as typeof env.DB.prepare);
    try {
      expect((await call(env, 'GET', '/api/v1/clients', token)).status).toBe(200);
    } finally {
      spy.mockRestore();
    }
    expect(sqls.some((s) => /GROUP BY client_id/i.test(s))).toBe(false);
    // clients 派生现复用 derived_core 一次取回流水明细（sale_items + payments 各一条全扫），
    // 不再有旧版的逐笔聚合子查询；数据由各端点用 JS 过滤聚合
    const saleScans = sqls.filter((s) => /FROM sale_items/i.test(s));
    expect(saleScans).toHaveLength(1);
    expect(saleScans[0]).toMatch(
      /SELECT id, sale_id, client_id, item_id, unit, quantity, sale_price, cost_price, amount, happened_at, note, created_by, sort, created_at[\s]*FROM sale_items/i,
    );
    expect(sqls.filter((s) => /FROM payments/i.test(s))).toHaveLength(1);
  });

  it('clients 与 overview 共用账本派生：预热一次后另一端不再全表扫流水表', async () => {
    expect((await call(env, 'GET', '/api/v1/clients', token)).status).toBe(200); // 预热共享快照
    const sqls: string[] = [];
    const orig = env.DB.prepare.bind(env.DB);
    const spy = vi.spyOn(env.DB, 'prepare').mockImplementation(((sql: string) => {
      sqls.push(sql);
      return orig(sql);
    }) as typeof env.DB.prepare);
    try {
      expect((await call(env, 'GET', '/api/v1/stats/overview', token)).status).toBe(200);
      expect((await call(env, 'GET', '/api/v1/clients', token)).status).toBe(200);
    } finally {
      spy.mockRestore();
    }
    expect(sqls.some((s) => /FROM sale_items/i.test(s) && !/WHERE/i.test(s))).toBe(false);
    expect(sqls.some((s) => /FROM payments/i.test(s) && !/WHERE/i.test(s))).toBe(false);
  });

  it('items/summary 不再用 json_group_array 相关子查询（rows_read 护栏）', async () => {
    const sqls: string[] = [];
    const orig = env.DB.prepare.bind(env.DB);
    const spy = vi.spyOn(env.DB, 'prepare').mockImplementation(((sql: string) => {
      sqls.push(sql);
      return orig(sql);
    }) as typeof env.DB.prepare);
    try {
      expect((await call(env, 'GET', '/api/v1/items/summary', token)).status).toBe(200);
    } finally {
      spy.mockRestore();
    }
    expect(sqls.some((s) => /json_group_array|json_object/i.test(s))).toBe(false);
    expect(sqls.filter((s) => /FROM item_prices/i.test(s))).toHaveLength(1);
    expect(sqls.filter((s) => /FROM item_group_prices/i.test(s))).toHaveLength(1);
    expect(sqls.filter((s) => /FROM stocks/i.test(s))).toHaveLength(1);
  });

  it('stats/summary 与 stats/debts 命中快照后不再全表扫截止明细', async () => {
    const url = '/api/v1/stats/summary?start=2026-09-01&end=2026-09-30';
    expect((await call(env, 'GET', url, token)).status).toBe(200); // 预热两份快照
    expect((await call(env, 'GET', '/api/v1/stats/debts', token)).status).toBe(200);

    const sqls: string[] = [];
    const orig = env.DB.prepare.bind(env.DB);
    const spy = vi.spyOn(env.DB, 'prepare').mockImplementation(((sql: string) => {
      sqls.push(sql);
      return orig(sql);
    }) as typeof env.DB.prepare);
    try {
      expect((await call(env, 'GET', url, token)).status).toBe(200);
      expect((await call(env, 'GET', '/api/v1/stats/debts', token)).status).toBe(200);
    } finally {
      spy.mockRestore();
    }
    expect(sqls.some((s) => /FROM sale_items WHERE happened_at <= \?/i.test(s))).toBe(false);
    expect(sqls.some((s) => /FROM payments WHERE happened_at <= \?/i.test(s))).toBe(false);
  });
});
