/** 分类体系测试：两级限制、商品/店铺关联、删除保护 */
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

describe('分类体系', () => {
  let env: { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  let token: string;
  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
  });

  it('无 token 访问分类接口返回 401', async () => {
    const res = await call(env, 'GET', '/api/v1/categories?type=item');
    expect(res.status).toBe(401);
  });

  it('type 非法返回 400', async () => {
    const res = await call(env, 'GET', '/api/v1/categories?type=xxx', token);
    expect(res.status).toBe(400);
  });

  it('新建商品分类/店铺分类并列表返回', async () => {
    const r1 = await call(env, 'POST', '/api/v1/categories', token, { type: 'item', name: '蔬菜' });
    expect(r1.status).toBe(201);
    const r2 = await call(env, 'POST', '/api/v1/categories', token, { type: 'client', name: '店铺' });
    expect(r2.status).toBe(201);
    const itemList = await (await call(env, 'GET', '/api/v1/categories?type=item', token)).json() as { categories: Array<{ name: string }> };
    expect(itemList.categories.map((c) => c.name)).toContain('蔬菜');
    const clientList = await (await call(env, 'GET', '/api/v1/categories?type=client', token)).json() as { categories: Array<{ name: string }> };
    expect(clientList.categories.map((c) => c.name)).toContain('店铺');
    expect(clientList.categories.map((c) => c.name)).not.toContain('蔬菜');
  });

  it('店铺分类支持两级（店铺 → 火锅店），禁止三级', async () => {
    const p = await (await call(env, 'POST', '/api/v1/categories', token, { type: 'client', name: '店铺' })).json() as { id: string };
    const child = await call(env, 'POST', '/api/v1/categories', token, { type: 'client', name: '火锅店', parent_id: p.id });
    expect(child.status).toBe(201);
    const grand = await call(env, 'POST', '/api/v1/categories', token, { type: 'client', name: '重庆火锅', parent_id: (await child.json() as { id: string }).id });
    expect(grand.status).toBe(400);
    expect(((await grand.json()) as { error: string }).error).toContain('两级');
  });

  it('父分类不存在/type 不匹配拒绝', async () => {
    const r = await call(env, 'POST', '/api/v1/categories', token, { type: 'client', name: '孤儿', parent_id: 'nonexist' });
    expect(r.status).toBe(400);
  });

  it('商品关联分类：列表返回 category_id 与 category_name', async () => {
    const cat = await (await call(env, 'POST', '/api/v1/categories', token, { type: 'item', name: '蔬菜' })).json() as { id: string };
    await call(env, 'POST', '/api/v1/items', token, {
      name: '白菜', category_id: cat.id,
      prices: [{ unit: '斤', purchase_price: 1, sale_price: 2 }],
    });
    const list = await (await call(env, 'GET', '/api/v1/items', token)).json() as { items: Array<{ name: string; category_id: string; category_name: string }> };
    const it = list.items.find((x) => x.name === '白菜');
    expect(it?.category_id).toBe(cat.id);
    expect(it?.category_name).toBe('蔬菜');
  });

  it('商品分类不存在时拒绝创建商品', async () => {
    const r = await call(env, 'POST', '/api/v1/items', token, { name: '白菜', category_id: 'nope' });
    expect(r.status).toBe(400);
  });

  it('店铺关联分类：列表返回 category_name（二级也生效）', async () => {
    const p = await (await call(env, 'POST', '/api/v1/categories', token, { type: 'client', name: '店铺' })).json() as { id: string };
    const c = await (await call(env, 'POST', '/api/v1/categories', token, { type: 'client', name: '火锅店', parent_id: p.id })).json() as { id: string };
    await call(env, 'POST', '/api/v1/clients', token, { name: '老灶火锅', category_id: c.id });
    const list = await (await call(env, 'GET', '/api/v1/clients', token)).json() as { clients: Array<{ name: string; category_id: string; category_name: string }> };
    const cl = list.clients.find((x) => x.name === '老灶火锅');
    expect(cl?.category_id).toBe(c.id);
    expect(cl?.category_name).toBe('火锅店');
  });

  it('店铺分类不存在时拒绝创建店铺', async () => {
    const r = await call(env, 'POST', '/api/v1/clients', token, { name: 'X店', category_id: 'nope' });
    expect(r.status).toBe(400);
  });

  it('有子分类时删除父分类返回 409', async () => {
    const p = await (await call(env, 'POST', '/api/v1/categories', token, { type: 'client', name: '店铺' })).json() as { id: string };
    await call(env, 'POST', '/api/v1/categories', token, { type: 'client', name: '火锅店', parent_id: p.id });
    const r = await call(env, 'DELETE', `/api/v1/categories/${p.id}`, token);
    expect(r.status).toBe(409);
  });

  it('删除分类后商品/店铺引用置空，且商品冗余分类文本一并清理', async () => {
    const cat = await (await call(env, 'POST', '/api/v1/categories', token, { type: 'item', name: '蔬菜' })).json() as { id: string };
    await call(env, 'POST', '/api/v1/items', token, {
      name: '白菜', category_id: cat.id, category: '蔬菜',
      prices: [{ unit: '斤', purchase_price: 1, sale_price: 2 }],
    });
    const del = await call(env, 'DELETE', `/api/v1/categories/${cat.id}`, token);
    expect(del.status).toBe(204);
    const list = await (await call(env, 'GET', '/api/v1/items', token)).json() as { items: Array<{ name: string; category_id: string; category_name: string; category: string }> };
    const it = list.items.find((x) => x.name === '白菜');
    expect(it?.category_id).toBe('');
    expect(it?.category_name).toBe('');
    expect(it?.category).toBe(''); // 冗余文本同步清空
  });

  it('重命名与移动父级；有子分类不能降为二级', async () => {
    const a = await (await call(env, 'POST', '/api/v1/categories', token, { type: 'client', name: '食堂' })).json() as { id: string };
    const b = await (await call(env, 'POST', '/api/v1/categories', token, { type: 'client', name: '店铺' })).json() as { id: string };
    const child = await (await call(env, 'POST', '/api/v1/categories', token, { type: 'client', name: '火锅店', parent_id: b.id })).json() as { id: string };
    // 重命名子分类
    const rename = await call(env, 'PATCH', `/api/v1/categories/${child.id}`, token, { name: '川味火锅' });
    expect(rename.status).toBe(200);
    // 把 b(有子分类) 降为 a 的子分类 → 400
    const downgrade = await call(env, 'PATCH', `/api/v1/categories/${b.id}`, token, { parent_id: a.id });
    expect(downgrade.status).toBe(400);
    // 子分类移动到 a 下 → 200（仍是二级）
    const move = await call(env, 'PATCH', `/api/v1/categories/${child.id}`, token, { parent_id: a.id });
    expect(move.status).toBe(200);
  });
});
