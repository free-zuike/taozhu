/** 价格组总结：从店铺销售记录总结每商品最近成交单价填充组价（fill 补缺 / overwrite 覆盖） */
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

async function call(env: Env, method: string, path: string, token?: string, body?: unknown) {
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
  return ((await res.json()) as { token: string }).token;
}

describe('价格组总结（summarize）', () => {
  let env: Env;
  let token: string;
  let clientA: string;
  let clientB: string;
  let groupId: string;
  let itemId: string;
  let priceId: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    await call(env, 'POST', '/api/v1/items', token, { name: '白菜', prices: [{ unit: '斤', purchase_price: 1, sale_price: 2 }] });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string; prices: Array<{ id: string; unit: string }> }>;
    };
    itemId = items.items[0].id;
    priceId = items.items[0].prices[0].id;
    const mkClient = async (name: string) => {
      await call(env, 'POST', '/api/v1/clients', token, { name });
      const d = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string; name: string }> };
      return d.clients.find((c) => c.name === name)!.id;
    };
    clientA = await mkClient('品味轩');
    clientB = await mkClient('福满楼');
    const g = (await (await call(env, 'POST', '/api/v1/price-groups', token, { name: '批发' })).json()) as { id: string };
    groupId = g.id;
  });

  const groupPrices = async (): Promise<Array<{ unit: string; group_id: string; sale_price: number }>> => {
    const d = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string; group_prices?: Array<{ unit: string; group_id: string; sale_price: number }> }>;
    };
    return d.items.find((i) => i.id === itemId)?.group_prices ?? [];
  };

  it('fill：无销售记录时返回 0；有销售按最近成交价补缺（含指定店铺过滤）', async () => {
    // 无销售 → 空
    const empty = (await (await call(env, 'POST', `/api/v1/price-groups/${groupId}/summarize`, token, {})).json()) as {
      ok: boolean; added: number;
    };
    expect(empty.ok).toBe(true);
    expect(empty.added).toBe(0);

    // 品味轩 09-01 卖 2.5；福满楼 09-05 卖 3.0 → 全部店铺最近 = 3.0
    await call(env, 'POST', '/api/v1/sales', token, { client_id: clientA, happened_at: '2026-09-01', items: [{ price_id: priceId, quantity: 10, sale_price: 2.5 }] });
    await call(env, 'POST', '/api/v1/sales', token, { client_id: clientB, happened_at: '2026-09-05', items: [{ price_id: priceId, quantity: 5, sale_price: 3 }] });

    const all = (await (await call(env, 'POST', `/api/v1/price-groups/${groupId}/summarize`, token, {})).json()) as {
      ok: boolean; added: number; updated: number; items: number;
    };
    expect(all.ok).toBe(true);
    expect(all.added).toBe(1);
    expect(all.updated).toBe(0);
    expect(all.items).toBe(1);
    let gp = await groupPrices();
    expect(gp).toHaveLength(1);
    expect(gp[0].unit).toBe('斤');
    expect(gp[0].group_id).toBe(groupId);
    expect(gp[0].sale_price).toBe(3);

    // 指定店铺：只按品味轩 → 2.5（该店已补过 → added 0 且不覆盖 3.0？fill 只补缺，已存在跳过）
    const byClient = (await (await call(env, 'POST', `/api/v1/price-groups/${groupId}/summarize`, token, { client_id: clientA })).json()) as {
      ok: boolean; added: number;
    };
    expect(byClient.ok).toBe(true);
    expect(byClient.added).toBe(0);
    gp = await groupPrices();
    expect(gp[0].sale_price).toBe(3);
  });

  it('fill 不覆盖已设组价；overwrite 才按最近成交价更新', async () => {
    // 预置手工价 99（新建商品时带 group_prices）
    const item2 = (await (await call(env, 'POST', '/api/v1/items', token, {
      name: '土豆', prices: [{ unit: '斤', purchase_price: 1, sale_price: 2 }],
      group_prices: [{ unit: '斤', group_id: groupId, sale_price: 99 }],
    })).json()) as { id: string };
    await call(env, 'POST', '/api/v1/sales', token, { client_id: clientA, happened_at: '2026-09-03', items: [{ price_id: priceId, quantity: 8, sale_price: 2.8 }] });
    await call(env, 'POST', '/api/v1/sales', token, { client_id: clientA, happened_at: '2026-09-03', items: [{ price_id: priceId, quantity: 8, sale_price: 2.8 }] });
    // 用土豆的 price 卖一单：需要土豆的 priceId
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string; name: string; prices: Array<{ id: string; unit: string }> }>;
    };
    const tPrice = items.items.find((i) => i.id === item2.id)!.prices[0].id;
    await call(env, 'POST', '/api/v1/sales', token, { client_id: clientA, happened_at: '2026-09-10', items: [{ price_id: tPrice, quantity: 20, sale_price: 2.6 }] });

    // fill：土豆已有 99 → 不动；白菜补 2.8
    const fill = (await (await call(env, 'POST', `/api/v1/price-groups/${groupId}/summarize`, token, { client_id: clientA })).json()) as {
      added: number; updated: number;
    };
    expect(fill.added).toBe(1);
    expect(fill.updated).toBe(0);
    const afterFill = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string; group_prices: Array<{ unit: string; sale_price: number }> }>;
    };
    const tRow = afterFill.items.find((i) => i.id === item2.id)!;
    expect(tRow.group_prices.find((g) => g.sale_price === 99)).toBeTruthy();

    // overwrite：土豆 99 → 2.6
    const overwrite = (await (await call(env, 'POST', `/api/v1/price-groups/${groupId}/summarize`, token, { client_id: clientA, mode: 'overwrite' })).json()) as {
      added: number; updated: number;
    };
    expect(overwrite.added).toBe(0);
    expect(overwrite.updated).toBe(1);
    const afterOv = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string; group_prices: Array<{ unit: string; sale_price: number }> }>;
    };
    const t2 = afterOv.items.find((i) => i.id === item2.id)!;
    expect(t2.group_prices.find((g) => g.sale_price === 2.6)).toBeTruthy();
  });

  it('无效店铺/价格组返回 404', async () => {
    const badGroup = await call(env, 'POST', '/api/v1/price-groups/nope/summarize', token, {});
    expect(badGroup.status).toBe(404);
    const badClient = await call(env, 'POST', `/api/v1/price-groups/${groupId}/summarize`, token, { client_id: 'nope' });
    expect(badClient.status).toBe(404);
  });

  it('同步推送 delete 变更 → 服务端软删价格组并清店铺引用（App 删除恢复根因）', async () => {
    // 建组 + 店铺绑定该组
    const g = (await (await call(env, 'POST', '/api/v1/price-groups', token, { name: '待删组' })).json()) as { id: string };
    await call(env, 'PATCH', `/api/v1/clients/${clientA}`, token, { price_group_id: g.id });
    // 模拟 App 本地删除的队列推送（action=delete，payload 空）
    const push = (await (await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'test-dev',
      changes: [{ entity_type: 'price_group', entity_sync_id: g.id, action: 'delete', payload: {}, updated_at: new Date().toISOString() }],
    })).json()) as { accepted: number };
    expect(push.accepted).toBe(1);
    // 列表不再返回该组
    const list = (await (await call(env, 'GET', '/api/v1/price-groups', token)).json()) as { price_groups: Array<{ id: string }> };
    expect(list.price_groups.find((x) => x.id === g.id)).toBeFalsy();
    // 店铺引用已清空
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as {
      clients: Array<{ id: string; price_group_id?: string }>;
    };
    expect(clients.clients.find((x) => x.id === clientA)?.price_group_id || '').toBe('');
  });
});
