/** 同步协议端到端测试：变更流 + LWW 冲突 + push/pull/full。 */
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { hashPassword, randomId } from '../src/lib/password';
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

async function loginStaff(env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string }) {
  await env.DB.prepare('INSERT INTO users (id, username, password_hash, role) VALUES (?, ?, ?, ?)')
    .bind(randomId(), 'staff1', await hashPassword('staff123'), 'staff').run();
  const res = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
  return ((await res.json()) as { token: string }).token;
}

describe('同步协议', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  beforeEach(async () => { env = (await setup()).env; token = await loginAdmin(env); });

  it('未登录访问 sync 接口返回 401', async () => {
    expect((await call(env, 'GET', '/api/v1/sync/pull')).status).toBe(401);
    expect((await call(env, 'POST', '/api/v1/sync/push', undefined, { device_id: 'd1', changes: [] })).status).toBe(401);
  });

  it('在线写路由产生变更流，pull 按游标增量下发', async () => {
    const create = await call(env, 'POST', '/api/v1/clients', token, { name: '老王家', month_start_day: 1 });
    expect(create.status).toBe(201);
    const clientId = ((await create.json()) as { id: string }).id;

    // 变更流应有 1 条 client upsert
    const pull1 = await call(env, 'GET', '/api/v1/sync/pull?since=0', token);
    const d1 = (await pull1.json()) as { changes: Array<{ entity_type: string; entity_sync_id: string; action: string; payload: { name: string } }>; server_cursor: number };
    expect(d1.changes).toHaveLength(1);
    expect(d1.changes[0].entity_type).toBe('client');
    expect(d1.changes[0].entity_sync_id).toBe(clientId);
    expect(d1.changes[0].payload.name).toBe('老王家');

    // 第二次拉取（since=已游标）→ 无新变更
    const pull2 = await call(env, 'GET', `/api/v1/sync/pull?since=${d1.server_cursor}`, token);
    const d2 = (await pull2.json()) as { changes: unknown[]; server_cursor: number };
    expect(d2.changes).toHaveLength(0);
    expect(d2.server_cursor).toBe(d1.server_cursor);

    // 修改店铺 → 新变更（同实体多条 append，id 递增）
    await call(env, 'PATCH', `/api/v1/clients/${clientId}`, token, { name: '老王家菜铺' });
    const pull3 = await call(env, 'GET', `/api/v1/sync/pull?since=${d1.server_cursor}`, token);
    const d3 = (await pull3.json()) as { changes: Array<{ entity_sync_id: string; payload: { name: string } }> };
    expect(d3.changes).toHaveLength(1);
    expect(d3.changes[0].entity_sync_id).toBe(clientId);
    expect(d3.changes[0].payload.name).toBe('老王家菜铺');
  });

  it('push 新实体（跨端建档）应用到业务表', async () => {
    const ts = new Date().toISOString();
    const res = await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'phone-a',
      changes: [{
        entity_type: 'client', entity_sync_id: 'c-remote-1', action: 'upsert',
        payload: { id: 'c-remote-1', name: '远程店', contact: '', phone: '', note: '', start_date: '', end_date: '', month_start_day: 1, category_id: '', deleted_at: null },
        updated_at: ts,
      }],
    });
    const d = (await res.json()) as { accepted: number; rejected: number; server_cursor: number };
    expect(d.accepted).toBe(1);
    expect(d.rejected).toBe(0);
    expect(d.server_cursor).toBeGreaterThan(0);

    const list = await call(env, 'GET', '/api/v1/clients', token);
    const clients = ((await list.json()) as { clients: Array<{ id: string; name: string }> }).clients;
    expect(clients.some((x) => x.id === 'c-remote-1' && x.name === '远程店')).toBe(true);
  });

  it('LWW：push 更旧时间戳被拒绝（conflict），更新时间戳覆盖', async () => {
    const ts = new Date().toISOString();
    const olderTs = new Date(Date.now() - 60_000).toISOString();
    const newerTs = new Date(Date.now() + 60_000).toISOString();

    await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'phone-a',
      changes: [{
        entity_type: 'client', entity_sync_id: 'c-1', action: 'upsert',
        payload: { id: 'c-1', name: '初版', month_start_day: 1 }, updated_at: ts,
      }],
    });

    // 旧时间戳 → 拒绝
    const old = await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'phone-a',
      changes: [{
        entity_type: 'client', entity_sync_id: 'c-1', action: 'upsert',
        payload: { id: 'c-1', name: '旧版本', month_start_day: 1 }, updated_at: olderTs,
      }],
    });
    const od = (await old.json()) as { accepted: number; rejected: number; conflict_count: number };
    expect(od.accepted).toBe(0);
    expect(od.rejected).toBe(1);
    expect(od.conflict_count).toBe(1);

    // 新时间戳 → 覆盖应用
    const newer = await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'phone-a',
      changes: [{
        entity_type: 'client', entity_sync_id: 'c-1', action: 'upsert',
        payload: { id: 'c-1', name: '终版', month_start_day: 1 }, updated_at: newerTs,
      }],
    });
    const nd = (await newer.json()) as { accepted: number };
    expect(nd.accepted).toBe(1);
    const list = await call(env, 'GET', '/api/v1/clients', token);
    const client = ((await list.json()) as { clients: Array<{ id: string; name: string }> }).clients.find((x) => x.id === 'c-1');
    expect(client?.name).toBe('终版');
  });

  it('幂等：同设备同时间戳重放 → 接受但不重复建行', async () => {
    const ts = new Date().toISOString();
    const ch = [{
      entity_type: 'client', entity_sync_id: 'c-idem', action: 'upsert',
      payload: { id: 'c-idem', name: '幂等店', month_start_day: 1 }, updated_at: ts,
    }];
    const r1 = await call(env, 'POST', '/api/v1/sync/push', token, { device_id: 'phone-a', changes: ch });
    const d1 = (await r1.json()) as { accepted: number };
    expect(d1.accepted).toBe(1);
    const r2 = await call(env, 'POST', '/api/v1/sync/push', token, { device_id: 'phone-a', changes: ch });
    const d2 = (await r2.json()) as { accepted: number; rejected: number };
    expect(d2.accepted).toBe(1); // 幂等接受
    expect(d2.rejected).toBe(0);
    // 变更流里该实体应只有 1 行，pull 不重复下发
    const pull = await call(env, 'GET', '/api/v1/sync/pull?since=0', token);
    const pd = (await pull.json()) as { changes: Array<{ entity_sync_id: string }> };
    expect(pd.changes.filter((x) => x.entity_sync_id === 'c-idem')).toHaveLength(1);
  });

  it('push 出货单：应用明细 + 扣减库存；push 删除：还原库存', async () => {
    // 先建商品（自动产生 item 变更）
    const create = await call(env, 'POST', '/api/v1/items', token, {
      name: '白菜', category: '蔬菜',
      prices: [{ unit: '斤', purchase_price: 2.0, sale_price: 2.5 }],
    });
    const item = ((await create.json()) as { id: string; prices: string[] });
    const priceId = item.prices[0];

    const ts = new Date().toISOString();
    const salePayload = {
      id: 's-1', client_id: 'c-sale', client_name: '档口A', happened_at: '2026-09-20',
      note: '', total: 25,
      items: [{
        id: 'si-1', sale_id: 's-1', item_id: item.id, item_name: '白菜',
        unit: '斤', quantity: 10, sale_price: 2.5, cost_price: 2.0, amount: 25,
      }],
    };
    // 先 push 一个店铺（sale upsert 需要 client 存在/外键；fake-d1 开外键）
    await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'phone-a',
      changes: [{
        entity_type: 'client', entity_sync_id: 'c-sale', action: 'upsert',
        payload: { id: 'c-sale', name: '档口A', month_start_day: 1 }, updated_at: ts,
      }],
    });

    const push = await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'phone-a',
      changes: [{ entity_type: 'sale', entity_sync_id: 's-1', action: 'upsert', payload: salePayload, updated_at: ts }],
    });
    const pd = (await push.json()) as { accepted: number; rejected: number };
    expect(pd.accepted).toBe(1);

    // 单据 + 库存：白菜 斤 库存 = -10（只有出货无进货）
    const stocks = await call(env, 'GET', '/api/v1/stocks', token);
    const list = ((await stocks.json()) as { stocks: Array<{ item_id: string; unit: string; quantity: number }> }).stocks;
    expect(list.find((x) => x.item_id === item.id && x.unit === '斤')?.quantity).toBe(-10);

    // 删除出货单（LWW 新时间戳）→ 库存还原为 0
    const delTs = new Date(Date.now() + 120_000).toISOString();
    const del = await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'phone-a',
      changes: [{ entity_type: 'sale', entity_sync_id: 's-1', action: 'delete', payload: {}, updated_at: delTs }],
    });
    const dd = (await del.json()) as { accepted: number };
    expect(dd.accepted).toBe(1);
    const stocks2 = await call(env, 'GET', '/api/v1/stocks', token);
    const list2 = ((await stocks2.json()) as { stocks: Array<{ item_id: string; unit: string; quantity: number }> }).stocks;
    expect(list2.find((x) => x.item_id === item.id && x.unit === '斤')?.quantity ?? 0).toBe(0);
  });

  it('pull 排除自己设备的回声（updated_by_device_id 过滤）', async () => {
    // 在线建店（无设备 id 的变更会下发到所有设备）
    await call(env, 'POST', '/api/v1/clients', token, { name: '线下店' });
    // push 一条 phone-a 自己的变更
    await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'phone-a',
      changes: [{
        entity_type: 'client', entity_sync_id: 'c-a', action: 'upsert',
        payload: { id: 'c-a', name: 'A店', month_start_day: 1 }, updated_at: new Date().toISOString(),
      }],
    });
    // phone-b 拉取：应包含 2 条（线下店 + c-a），不含 phone-a 回声
    const pullB = await call(env, 'GET', '/api/v1/sync/pull?since=0&device_id=phone-b', token);
    const db_ = (await pullB.json()) as { changes: Array<{ entity_sync_id: string }> };
    expect(db_.changes).toHaveLength(2);
    // phone-a 拉取：只看到线下店（自己的 c-a 被排除）
    const pullA = await call(env, 'GET', '/api/v1/sync/pull?since=0&device_id=phone-a', token);
    const da = (await pullA.json()) as { changes: Array<{ entity_sync_id: string }> };
    expect(da.changes.some((x) => x.entity_sync_id === 'c-a')).toBe(false);
    expect(da.changes).toHaveLength(1);
  });

  it('staff 只能推 sale/purchase upsert，主数据被拒', async () => {
    const staffToken = await loginStaff(env);
    const ts = new Date().toISOString();
    // staff 推 client → 拒绝
    const p1 = await call(env, 'POST', '/api/v1/sync/push', staffToken, {
      device_id: 'phone-s',
      changes: [{
        entity_type: 'client', entity_sync_id: 'c-x', action: 'upsert',
        payload: { id: 'c-x', name: 'X', month_start_day: 1 }, updated_at: ts,
      }],
    });
    const d1 = (await p1.json()) as { accepted: number; rejected: number };
    expect(d1.accepted).toBe(0);
    expect(d1.rejected).toBe(1);
    // 老板先在云端建店（真实场景店铺必已存在），staff 推 sale upsert → 接受（送货员记单）
    await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'phone-a',
      changes: [{
        entity_type: 'client', entity_sync_id: 'c-x', action: 'upsert',
        payload: { id: 'c-x', name: 'X', month_start_day: 1 }, updated_at: ts,
      }],
    });
    const p2 = await call(env, 'POST', '/api/v1/sync/push', staffToken, {
      device_id: 'phone-s',
      changes: [{
        entity_type: 'sale', entity_sync_id: 's-x', action: 'upsert',
        payload: { id: 's-x', client_id: 'c-x', happened_at: '2026-09-20', note: '', items: [] },
        updated_at: ts,
      }],
    });
    const d2 = (await p2.json()) as { accepted: number };
    expect(d2.accepted).toBe(1);
  });

  it('full 首同步快照：全量实体与台账', async () => {
    await call(env, 'POST', '/api/v1/clients', token, { name: '全量店' });
    const res = await call(env, 'GET', '/api/v1/sync/full', token);
    const d = (await res.json()) as { clients: unknown[]; items: unknown[]; categories: unknown[]; sales: unknown[]; purchases: unknown[]; payments: unknown[]; stocks: unknown[]; server_cursor: number };
    expect(d.clients).toHaveLength(1);
    expect(Array.isArray(d.items)).toBe(true);
    expect(Array.isArray(d.sales)).toBe(true);
    expect(d.server_cursor).toBeGreaterThan(0);
  });

  it('stats 返回服务器各实体计数与游标（差异面板数据源）', async () => {
    await call(env, 'POST', '/api/v1/clients', token, { name: '店A' });
    await call(env, 'POST', '/api/v1/clients', token, { name: '店B' });
    const res = await call(env, 'GET', '/api/v1/sync/stats', token);
    expect(res.status).toBe(200);
    const d = (await res.json()) as Record<string, number>;
    expect(d.clients).toBe(2);
    expect(d.items).toBe(0);
    expect(d.categories).toBe(0);
    expect(d.sales).toBe(0);
    expect(d.purchases).toBe(0);
    expect(d.payments).toBe(0);
    expect(d.server_cursor).toBeGreaterThanOrEqual(2);
  });

  it('staff full/拉取：item 进价与单据进价快照打码为 0', async () => {
    const staffToken = await loginStaff(env);
    await call(env, 'POST', '/api/v1/items', token, {
      name: '土豆', prices: [{ unit: '斤', purchase_price: 3.0, sale_price: 3.5 }],
    });
    const res = await call(env, 'GET', '/api/v1/sync/full', staffToken);
    const d = (await res.json()) as { items: Array<{ prices: Array<{ purchase_price: number }> }> };
    expect(d.items[0].prices[0].purchase_price).toBe(0);
    // pull 同样打码
    const pull = await call(env, 'GET', '/api/v1/sync/pull?since=0', staffToken);
    const pd = (await pull.json()) as { changes: Array<{ entity_type: string; payload: { prices?: Array<{ purchase_price: number }> } }> };
    const itemCh = pd.changes.find((x) => x.entity_type === 'item');
    expect(itemCh?.payload.prices?.[0].purchase_price).toBe(0);
  });
});