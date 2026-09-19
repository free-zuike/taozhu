/** 库存测试：进货自动入库、出货自动扣减、编辑/删除单据库存重算、盘点与预警 */
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

describe('库存（stocks）', () => {
  let env: Env;
  let token: string;
  let clientId: string;
  let priceId: string;

  beforeEach(async () => {
    env = (await setup()).env;
    token = await loginAdmin(env);
    await call(env, 'POST', '/api/v1/items', token, { name: '白菜', prices: [{ unit: '斤', purchase_price: 1, sale_price: 2 }] });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string; prices: Array<{ id: string; unit: string }> }>;
    };
    priceId = items.items[0].prices[0].id;
    await call(env, 'POST', '/api/v1/clients', token, { name: '品味轩' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as {
      clients: Array<{ id: string }>;
    };
    clientId = clients.clients[0].id;
  });

  const stockQty = async (): Promise<number> => {
    const d = (await (await call(env, 'GET', '/api/v1/stocks', token)).json()) as {
      stocks: Array<{ quantity: number }>;
    };
    return d.stocks[0]?.quantity ?? 0;
  };

  it('进货自动入库、出货自动扣减', async () => {
    await call(env, 'POST', '/api/v1/purchases', token, { items: [{ price_id: priceId, quantity: 30 }] });
    expect(await stockQty()).toBe(30);
    await call(env, 'POST', '/api/v1/sales', token, { client_id: clientId, items: [{ price_id: priceId, quantity: 12 }] });
    expect(await stockQty()).toBe(18);
  });

  it('编辑出货单替换明细后库存重算', async () => {
    await call(env, 'POST', '/api/v1/purchases', token, { items: [{ price_id: priceId, quantity: 50 }] });
    const sale = (await (await call(env, 'POST', '/api/v1/sales', token, { client_id: clientId, items: [{ price_id: priceId, quantity: 20 }] })).json()) as { id: string };
    expect(await stockQty()).toBe(30);
    // 改为 5 斤：回滚 20 再扣 5 → 50-5=45
    await call(env, 'PATCH', `/api/v1/sales/${sale.id}`, token, { items: [{ price_id: priceId, quantity: 5 }] });
    expect(await stockQty()).toBe(45);
  });

  it('删除出货单库存回滚', async () => {
    await call(env, 'POST', '/api/v1/purchases', token, { items: [{ price_id: priceId, quantity: 40 }] });
    const sale = (await (await call(env, 'POST', '/api/v1/sales', token, { client_id: clientId, items: [{ price_id: priceId, quantity: 10 }] })).json()) as { id: string };
    expect(await stockQty()).toBe(30);
    await call(env, 'DELETE', `/api/v1/sales/${sale.id}`, token);
    expect(await stockQty()).toBe(40);
  });

  it('盘点设置库存与阈值；below=1 预警过滤', async () => {
    // 用真实商品盘点
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string }>;
    };
    const itemId = items.items[0].id;
    await call(env, 'PUT', '/api/v1/stocks', token, {
      rows: [{ item_id: itemId, unit: '斤', quantity: 5, min_stock: 10 }],
    });
    const all = (await (await call(env, 'GET', '/api/v1/stocks', token)).json()) as {
      stocks: Array<{ quantity: number; min_stock: number; low: boolean }>;
    };
    expect(all.stocks[0].quantity).toBe(5);
    expect(all.stocks[0].min_stock).toBe(10);
    expect(all.stocks[0].low).toBe(true);
    expect(all.stocks[0].cost_price).toBe(1); // 白菜当前进价
    const below = (await (await call(env, 'GET', '/api/v1/stocks?below=1', token)).json()) as {
      stocks: unknown[];
    };
    expect(below.stocks.length).toBe(1);
  });

  it('盘点负数拒绝 400；单行 PATCH 调整', async () => {
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string }>;
    };
    const bad = await call(env, 'PUT', '/api/v1/stocks', token, {
      rows: [{ item_id: items.items[0].id, unit: '斤', quantity: -3 }],
    });
    expect(bad.status).toBe(400);
    await call(env, 'PUT', '/api/v1/stocks', token, {
      rows: [{ item_id: items.items[0].id, unit: '斤', quantity: 8, min_stock: 2 }],
    });
    const d = (await (await call(env, 'GET', '/api/v1/stocks', token)).json()) as {
      stocks: Array<{ id: string; quantity: number; min_stock: number }>;
    };
    const id = d.stocks[0].id;
    const patch = await call(env, 'PATCH', `/api/v1/stocks/${id}`, token, { quantity: 20 });
    expect(patch.status).toBe(200);
    const after = (await (await call(env, 'GET', '/api/v1/stocks', token)).json()) as {
      stocks: Array<{ quantity: number }>;
    };
    expect(after.stocks[0].quantity).toBe(20);
  });

  it('未登录访问库存 → 401', async () => {
    expect((await call(env, 'GET', '/api/v1/stocks')).status).toBe(401);
  });

  it('items/summary 记单目录返回当前库存', async () => {
    await call(env, 'POST', '/api/v1/purchases', token, { items: [{ price_id: priceId, quantity: 25 }] });
    const d = (await (await call(env, 'GET', '/api/v1/items/summary', token)).json()) as {
      items: Array<{ prices: Array<{ stock: number }> }>;
    };
    expect(d.items[0].prices[0].stock).toBe(25);
  });

  it('全量重算库存：从进货(+)出货(−)流水重建，保留阈值；店员 403', async () => {
    // 直接造历史流水（模拟 v0.17.144 前 App 行级同步：stocks 无联动）
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as { items: Array<{ id: string }> };
    const itemId = items.items[0].id;
    await env.DB.prepare('INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount, happened_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
      .bind('pi-r1', 'pu-r1', itemId, '斤', 40, 1, 40, '2026-09-01').run();
    await env.DB.prepare('INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount, happened_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
      .bind('pi-r2', 'pu-r2', itemId, '斤', 15, 1, 15, '2026-09-05').run();
    await env.DB.prepare('INSERT INTO sale_items (id, sale_id, client_id, item_id, unit, quantity, sale_price, cost_price, amount, happened_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
      .bind('si-r1', 's-r1', clientId, itemId, '斤', 10, 2, 1, 20, '2026-09-08').run();
    // 先设阈值：rebuild 后应保留
    await call(env, 'PUT', '/api/v1/stocks', token, { rows: [{ item_id: itemId, unit: '斤', quantity: 0, min_stock: 5 }] });
    const r = await call(env, 'POST', '/api/v1/stocks/rebuild', token);
    expect(r.status).toBe(200);
    const d = (await (await call(env, 'GET', '/api/v1/stocks', token)).json()) as {
      stocks: Array<{ quantity: number; min_stock: number }>;
    };
    expect(d.stocks[0].quantity).toBe(45); // 40 + 15 − 10
    expect(d.stocks[0].min_stock).toBe(5); // 阈值保留
    // 店员无权重算
    await call(env, 'POST', '/api/v1/users', token, { username: 'staff1', password: 'staff1234', role: 'staff' });
    const login = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff1234' });
    const staffToken = ((await login.json()) as { token: string }).token;
    expect((await call(env, 'POST', '/api/v1/stocks/rebuild', staffToken)).status).toBe(403);
  });

  it('负数库存显示为 0（用户口径：没有就是 0）', async () => {
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as { items: Array<{ id: string }> };
    const itemId = items.items[0].id;
    // 先建库存行（盘点 0），再只出货无进货 → DB 库存为负
    await call(env, 'PUT', '/api/v1/stocks', token, { rows: [{ item_id: itemId, unit: '斤', quantity: 0 }] });
    await env.DB.prepare('INSERT INTO sale_items (id, sale_id, client_id, item_id, unit, quantity, sale_price, cost_price, amount, happened_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
      .bind('si-neg', 's-neg', clientId, itemId, '斤', 8, 2, 1, 16, '2026-09-10').run();
    const d = (await (await call(env, 'GET', '/api/v1/stocks', token)).json()) as { stocks: Array<{ quantity: number }> };
    expect(d.stocks[0].quantity).toBe(0); // -8 → 显示 0
    // items/summary 记单目录同样不出现负数
    const sum = (await (await call(env, 'GET', '/api/v1/items/summary', token)).json()) as {
      items: Array<{ prices: Array<{ stock: number }> }>;
    };
    expect(sum.items[0].prices[0].stock).toBe(0);
  });

  it('进销单位换算：进箱(折合袋)按计数单位入库、出货按袋扣减、行编辑/删除折算回滚、rebuild 折算', async () => {
    // 商品：金针菇，计数单位=袋；价格行「箱」per=40（1 箱=40 袋）+「袋」per=null（出货按袋）
    await call(env, 'POST', '/api/v1/items', token, {
      name: '金针菇', count_unit: '袋',
      prices: [
        { unit: '箱', purchase_price: 30, sale_price: 40, per: 40 },
        { unit: '袋', purchase_price: 0.75, sale_price: 1, per: null },
      ],
    });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ id: string; name: string; count_unit: string; prices: Array<{ id: string; unit: string; per: number | null }> }>;
    };
    const box = items.items.find((i) => i.name === '金针菇')!;
    expect(box.count_unit).toBe('袋');
    const boxPriceId = box.prices.find((p) => p.unit === '箱')!.id;
    const bagPriceId = box.prices.find((p) => p.unit === '袋')!.id;
    expect(box.prices.find((p) => p.unit === '箱')!.per).toBe(40);

    // 进货 1 箱（记单显式 count_qty=40）→ 库存按计数单位「袋」+40
    const buy = await call(env, 'POST', '/api/v1/purchases', token, {
      items: [{ price_id: boxPriceId, quantity: 1, count_qty: 40 }],
    });
    expect(buy.status).toBe(201);
    let stock = await env.DB.prepare('SELECT quantity FROM stocks WHERE item_id = ? AND unit = ?').bind(box.id, '袋').first<{ quantity: number }>();
    expect(stock?.quantity).toBe(40);
    // 行记录 count_qty 落库
    let row = await env.DB.prepare('SELECT count_qty FROM purchase_items WHERE item_id = ?').bind(box.id).first<{ count_qty: number | null }>();
    expect(row?.count_qty).toBe(40);

    // 出货 5 袋（用袋价格行，无折合按数量）→ 库存 35 袋
    await call(env, 'POST', '/api/v1/sales', token, { client_id: clientId, items: [{ price_id: bagPriceId, quantity: 5 }] });
    stock = await env.DB.prepare('SELECT quantity FROM stocks WHERE item_id = ? AND unit = ?').bind(box.id, '袋').first<{ quantity: number }>();
    expect(stock?.quantity).toBe(35);
    // 箱单位无库存（全部折算到袋）
    const boxStock = await env.DB.prepare('SELECT quantity FROM stocks WHERE item_id = ? AND unit = ?').bind(box.id, '箱').first<{ quantity: number }>();
    expect(boxStock?.quantity ?? 0).toBe(0);

    // 删除出货行 → 库存回滚到 40 袋（折算回滚）
    const saleRow = await env.DB.prepare('SELECT id FROM sale_items WHERE item_id = ? LIMIT 1').bind(box.id).first<{ id: string }>();
    await call(env, 'DELETE', `/api/v1/sales/items/${saleRow!.id}`, token);
    stock = await env.DB.prepare('SELECT quantity FROM stocks WHERE item_id = ? AND unit = ?').bind(box.id, '袋').first<{ quantity: number }>();
    expect(stock?.quantity).toBe(40);

    // 行编辑把折合数改为 30 → 库存 30 袋
    const buyRow = await env.DB.prepare('SELECT id FROM purchase_items WHERE item_id = ? LIMIT 1').bind(box.id).first<{ id: string }>();
    await call(env, 'PATCH', `/api/v1/purchases/items/${buyRow!.id}`, token, { count_qty: 30 });
    stock = await env.DB.prepare('SELECT quantity FROM stocks WHERE item_id = ? AND unit = ?').bind(box.id, '袋').first<{ quantity: number }>();
    expect(stock?.quantity).toBe(30);

    // rebuild 全量重算：从流水重建（进货 count_qty=30 袋）→ 30 袋
    await call(env, 'POST', '/api/v1/stocks/rebuild', token);
    stock = await env.DB.prepare('SELECT quantity FROM stocks WHERE item_id = ? AND unit = ?').bind(box.id, '袋').first<{ quantity: number }>();
    expect(stock?.quantity).toBe(30);
  });

  it('比价口径：价格行 per 影响折合单价（进货页选规格时自动带出折合数）', async () => {
    await call(env, 'POST', '/api/v1/items', token, {
      name: '木耳', count_unit: '斤',
      prices: [
        { unit: '箱', purchase_price: 30, sale_price: 40, per: 10 },  // 30÷10=3 元/斤
        { unit: '件', purchase_price: 56, sale_price: 60, per: 20 },  // 56÷20=2.8 元/斤（便宜）
      ],
    });
    const items = (await (await call(env, 'GET', '/api/v1/items/summary', token)).json()) as {
      items: Array<{ prices: Array<{ unit: string; per: number | null }> }>;
    };
    const mp = items.items[0].prices;
    expect(mp).toHaveLength(2);
    const perBox = mp.find((p) => p.unit === '箱')!;
    const perPiece = mp.find((p) => p.unit === '件')!;
    expect(perBox.per).toBe(10);
    expect(perPiece.per).toBe(20);
  });
});