/** 附件路由测试：R2 用内存 mock（put/get/list/delete），验证上传/列表/代理读取/删除与参数校验 */
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { createStorage } from '../src/services/storage';
import { createFakeD1, fakeAssets } from './helpers/fake-d1';

const JWT_SECRET = 'test-secret';
const BASE = 'http://localhost';

/** 内存 R2Bucket mock（仅实现本路由用到的接口） */
class FakeBucket {
  private store = new Map<string, { bytes: Uint8Array }>();
  async put(key: string, value: BodyInit) {
    const bytes = new Uint8Array(await new Response(value).arrayBuffer());
    this.store.set(key, { bytes });
    return {} as R2Object;
  }
  async get(key: string) {
    const o = this.store.get(key);
    if (!o) return null;
    return new R2TestObject(o.bytes) as unknown as R2ObjectBody;
  }
  async list(opts?: { prefix?: string }) {
    const prefix = opts?.prefix ?? '';
    return {
      objects: [...this.store.keys()].filter((k) => k.startsWith(prefix)).map((k) => ({
        key: k, size: this.store.get(k)!.bytes.byteLength, uploaded: new Date(),
      })),
      truncated: false,
    } as R2Objects;
  }
  async delete(key: string) {
    this.store.delete(key);
  }
}

class R2TestObject {
  constructor(private bytes: Uint8Array) {}
  get size() { return this.bytes.byteLength; }
  get uploaded() { return new Date(); }
  get httpEtag() { return 'test-etag'; }
  get body() {
    const bytes = this.bytes;
    return new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(bytes);
        controller.close();
      },
    });
  }
  writeHttpMetadata(headers: Headers) { headers.set('content-type', 'image/jpeg'); }
}

type Env = { DB: unknown; ASSETS: typeof fakeAssets; JWT_SECRET: string; BUCKET: FakeBucket };

async function setup() {
  resetSchemaState();
  const db = await createFakeD1();
  await ensureSchema(db as never);
  const env: Env = { DB: db, ASSETS: fakeAssets, JWT_SECRET, BUCKET: new FakeBucket() };
  return env;
}

async function call(env: Env, method: string, path: string, token?: string, body?: unknown, isForm = false) {
  const headers: Record<string, string> = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  let reqBody: BodyInit | undefined;
  if (body !== undefined) {
    if (isForm) {
      reqBody = body as FormData;
      // 不手动设 Content-Type：由 fetch/undici 自动附加 multipart boundary，否则解析失败
    } else {
      reqBody = JSON.stringify(body);
      headers['Content-Type'] = 'application/json';
    }
  }
  return app.request(`${BASE}${path}`, { method, headers, body: reqBody }, env as never);
}

async function loginAdmin(env: Env) {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  return ((await res.json()) as { token: string }).token;
}

function photoForm(): FormData {
  const fd = new FormData();
  fd.append('photo', new File([new Uint8Array([0xff, 0xd8, 0xff, 0x00])], 'photo.jpg', { type: 'image/jpeg' }));
  return fd;
}

describe('交易附件（R2）', () => {
  let env: Env;
  let token: string;

  beforeEach(async () => {
    env = await setup();
    token = await loginAdmin(env);
  });

  it('上传、列表、代理读取、删除全链路', async () => {
    const up = await call(env, 'POST', '/api/v1/attachments?entity=sale&id=s1', token, photoForm(), true);
    if (up.status !== 201) console.log('DEBUG upload:', up.status, await up.text());
    expect(up.status).toBe(201);
    const { key } = (await up.json()) as { key: string };
    expect(key.startsWith('taozhu/images/attachments/sale/s1/')).toBe(true);

    const list = await (await call(env, 'GET', '/api/v1/attachments?entity=sale&id=s1', token)).json() as {
      attachments: Array<{ key: string; size: number }>;
    };
    expect(list.attachments).toHaveLength(1);
    expect(list.attachments[0].key).toBe(key);
    expect(list.attachments[0].size).toBe(4);

    const read = await call(env, 'GET', `/api/v1/attachments/${key}`, token);
    expect(read.status).toBe(200);
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(new Uint8Array([0xff, 0xd8, 0xff, 0x00]));

    const del = await call(env, 'DELETE', `/api/v1/attachments?key=${key}`, token);
    expect(del.status).toBe(204);
    const after = await (await call(env, 'GET', '/api/v1/attachments?entity=sale&id=s1', token)).json() as {
      attachments: unknown[];
    };
    expect(after.attachments).toHaveLength(0);
  });

  it('按前缀隔离：不同交易互不可见', async () => {
    await call(env, 'POST', '/api/v1/attachments?entity=sale&id=a', token, photoForm(), true);
    const other = await (await call(env, 'GET', '/api/v1/attachments?entity=sale&id=b', token)).json() as {
      attachments: unknown[];
    };
    expect(other.attachments).toHaveLength(0);
    const self = await (await call(env, 'GET', '/api/v1/attachments?entity=sale&id=a', token)).json() as {
      attachments: unknown[];
    };
    expect(self.attachments).toHaveLength(1);
  });

  it('参数校验：entity 非法 / 缺 id / 无文件 → 400', async () => {
    expect((await call(env, 'POST', '/api/v1/attachments?entity=xxx&id=a', token, photoForm())).status).toBe(400);
    expect((await call(env, 'GET', '/api/v1/attachments?entity=sale', token)).status).toBe(400);
    const empty = new FormData();
    const up = await call(env, 'POST', '/api/v1/attachments?entity=sale&id=a', token, empty);
    expect(up.status).toBe(400);
  });

  it('MD5 去重：同一张图重复上传 → 同一 key，列表只有一份', async () => {
    const up1 = await call(env, 'POST', '/api/v1/attachments?entity=sale&id=s1', token, photoForm(), true);
    const up2 = await call(env, 'POST', '/api/v1/attachments?entity=sale&id=s1', token, photoForm(), true);
    const k1 = ((await up1.json()) as { key: string }).key;
    const k2 = ((await up2.json()) as { key: string }).key;
    expect(k1).toBe(k2); // 同内容 → 同 MD5 → 同 key（幂等覆盖）
    const list = await (await call(env, 'GET', '/api/v1/attachments?entity=sale&id=s1', token)).json() as {
      attachments: unknown[];
    };
    expect(list.attachments).toHaveLength(1);
  });

  it('旧前缀兼容：taozhu 前缀上线前的遗留附件仍可列出', async () => {
    // 模拟旧规范（v0.13.1 前 key=sale/id/xx.jpg）遗留数据
    await env.BUCKET.put('sale/a/legacy.jpg', new Uint8Array([1, 2, 3]));
    const list = await (await call(env, 'GET', '/api/v1/attachments?entity=sale&id=a', token)).json() as {
      attachments: Array<{ key: string }>;
    };
    expect(list.attachments).toHaveLength(1);
    expect(list.attachments[0].key).toBe('sale/a/legacy.jpg');
  });

  it('未登录 → 401', async () => {
    expect((await call(env, 'GET', '/api/v1/attachments?entity=sale&id=a')).status).toBe(401);
  });

  it('云端孤儿扫描：R2 附件对照 D1 单据，无对应单据的列为孤儿', async () => {
    // 建一笔真实出货单 s1（在用），附件挂上去 → 不算孤儿
    await call(env, 'POST', '/api/v1/clients', token, { name: '店A' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string }> };
    await call(env, 'POST', '/api/v1/items', token, {
      name: '白菜', prices: [{ unit: '斤', purchase_price: 2, sale_price: 2.5 }],
    });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ prices: Array<{ id: string }> }>;
    };
    const sale = await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clients.clients[0].id, happened_at: '2026-01-02',
      items: [{ price_id: items.items[0].prices[0].id, quantity: 1 }],
    });
    const saleId = ((await sale.json()) as { id: string }).id;
    // 上传到在用 sale（不算孤儿）
    const up1 = await (await call(env, 'POST', `/api/v1/attachments?entity=sale&id=${saleId}`, token, photoForm(), true)).json() as { key: string };
    // 直接塞孤儿附件：挂在不存在的 sale/ghost（单据已删的残留）
    const ghostKey = 'taozhu/images/attachments/sale/ghost123/deadbeef.jpg';
    await env.BUCKET.put(ghostKey, new Uint8Array([9, 9, 9]));
    // 历史前缀孤儿
    const legacyGhost = 'sale/olddeleted/legacy.jpg';
    await env.BUCKET.put(legacyGhost, new Uint8Array([8, 8, 8]));

    const scan = await (await call(env, 'GET', '/api/v1/attachments/orphans', token)).json() as {
      orphans: Array<{ key: string; id: string }>;
      total: number;
    };
    // 在用 sale 的附件不出现；2 个孤儿出现
    expect(scan.orphans.some((o) => o.key === up1.key)).toBe(false);
    expect(scan.orphans.some((o) => o.key === ghostKey)).toBe(true);
    expect(scan.orphans.some((o) => o.key === legacyGhost)).toBe(true);
    // 在用 sale 的 id 不出现在孤儿列表
    expect(scan.orphans.every((o) => o.id !== saleId)).toBe(true);
  });

  it('在用附件扫描：R2 附件对照 D1 单据，有对应单据的列为在用（同步后据此下载本地副本）', async () => {
    await call(env, 'POST', '/api/v1/clients', token, { name: '店A' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string }> };
    await call(env, 'POST', '/api/v1/items', token, {
      name: '白菜', prices: [{ unit: '斤', purchase_price: 2, sale_price: 2.5 }],
    });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ prices: Array<{ id: string }> }>;
    };
    const sale = await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clients.clients[0].id, happened_at: '2026-01-02',
      items: [{ price_id: items.items[0].prices[0].id, quantity: 1 }],
    });
    const saleId = ((await sale.json()) as { id: string }).id;
    // 上传到在用 sale（在用）
    const up1 = await (await call(env, 'POST', `/api/v1/attachments?entity=sale&id=${saleId}`, token, photoForm(), true)).json() as { key: string };
    // 孤儿：不存在的 sale/ghost（不应出现在在用列表）
    const ghostKey = 'taozhu/images/attachments/sale/ghost123/deadbeef.jpg';
    await env.BUCKET.put(ghostKey, new Uint8Array([9, 9, 9]));

    const scan = await (await call(env, 'GET', '/api/v1/attachments/in-use', token)).json() as {
      attachments: Array<{ key: string; id: string; entity: string; file: string }>;
      total: number;
    };
    // 在用 sale 的附件出现在列表；孤儿不出现
    expect(scan.attachments.some((o) => o.key === up1.key)).toBe(true);
    expect(scan.attachments.some((o) => o.key === ghostKey)).toBe(false);
    expect(scan.attachments.length).toBe(1);
    // 规范化三元组：entity/id/file 与 key 对照（前端同步下载/清理页在用判定直接用，不做正则）
    const hit = scan.attachments[0];
    expect(hit.entity).toBe('sale');
    expect(hit.id).toBe(saleId);
    expect(hit.file).toBe(up1.key.split('/').pop());
  });

  it('附件引用表：上传写引用、删附件清引用、删单据级联清引用', async () => {
    // 建真实单据
    await call(env, 'POST', '/api/v1/clients', token, { name: '店A' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string }> };
    await call(env, 'POST', '/api/v1/items', token, {
      name: '白菜', prices: [{ unit: '斤', purchase_price: 2, sale_price: 2.5 }],
    });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ prices: Array<{ id: string }> }>;
    };
    const sale = await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clients.clients[0].id, happened_at: '2026-01-05',
      items: [{ price_id: items.items[0].prices[0].id, quantity: 1 }],
    });
    const saleId = ((await sale.json()) as { id: string }).id;

    // 上传 → refs 表有对应行
    const up = await (await call(env, 'POST', `/api/v1/attachments?entity=sale&id=${saleId}`, token, photoForm(), true)).json() as { key: string };
    const refs = await (env.DB as FakeD1).prepare(
      "SELECT id, entity, entity_id, file_key FROM attachment_refs WHERE entity = 'sale' AND entity_id = ?",
    ).bind(saleId).all<{ id: string; entity: string; entity_id: string; file_key: string }>();
    expect(refs.results.length).toBe(1);
    expect(refs.results[0].file_key).toBe(up.key);

    // 删除单个附件 → refs 行被清
    await call(env, 'DELETE', `/api/v1/attachments?key=${up.key}`, token);
    const afterDel = await (env.DB as FakeD1).prepare(
      "SELECT COUNT(*) AS n FROM attachment_refs WHERE entity = 'sale' AND entity_id = ?",
    ).bind(saleId).first<{ n: number }>();
    expect(afterDel?.n ?? 0).toBe(0);

    // 重新上传，删单据 → 级联清引用
    const up2 = (await (await call(env, 'POST', `/api/v1/attachments?entity=sale&id=${saleId}`, token, photoForm(), true)).json()) as { key: string };
    const delSale = await call(env, 'DELETE', `/api/v1/sales/${saleId}`, token);
    expect(delSale.status).toBe(204);
    const afterSale = await (env.DB as FakeD1).prepare("SELECT COUNT(*) AS n FROM attachment_refs").first<{ n: number }>();
    expect(afterSale?.n ?? 0).toBe(0);
  });

  it('删除孤儿：仅删无引用的附件，在用附件不动；非 admin 拒绝', async () => {
    // 塞孤儿 + 在用
    await call(env, 'POST', '/api/v1/clients', token, { name: '店B' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string }> };
    await call(env, 'POST', '/api/v1/items', token, {
      name: '土豆', prices: [{ unit: '斤', purchase_price: 1, sale_price: 1.5 }],
    });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ prices: Array<{ id: string }> }>;
    };
    const sale = await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clients.clients[0].id, happened_at: '2026-01-03',
      items: [{ price_id: items.items[0].prices[0].id, quantity: 2 }],
    });
    const saleId = ((await sale.json()) as { id: string }).id;
    const inUseKey = ((await (await call(env, 'POST', `/api/v1/attachments?entity=sale&id=${saleId}`, token, photoForm(), true)).json()) as { key: string }).key;
    const ghostKey = 'taozhu/images/attachments/sale/ghost999/x.jpg';
    await env.BUCKET.put(ghostKey, new Uint8Array([7]));

    // 非 admin（无 token）→ 401
    expect((await call(env, 'DELETE', '/api/v1/attachments/orphans', undefined, { keys: [ghostKey] })).status).toBe(401);

    // admin 删除孤儿
    const del = await (await call(env, 'DELETE', '/api/v1/attachments/orphans', token, { keys: [ghostKey, inUseKey] })).json() as { deleted: number };
    expect(del.deleted).toBe(1); // 只删了孤儿，在用 sale 的没删

    // ghost 已删，在用仍可用
    const ghostStill = await env.BUCKET.get(ghostKey);
    expect(ghostStill).toBeNull();
    const inUseStill = await env.BUCKET.get(inUseKey);
    expect(inUseStill).not.toBeNull();
  });
});

describe('附件删除走同步变更流（引用变更流驱动：本地删 → push → 云端删引用+GC → 其他端 pull 同步删）', () => {
  let env: Env;
  let token: string;

  beforeEach(async () => {
    env = await setup();
    token = await loginAdmin(env);
  });

  it('push attachment delete 后：引用表被清、R2 文件被 GC、in-use 不再列出', async () => {
    // 建真实单据 + 上传两附件 → 2 条引用
    await call(env, 'POST', '/api/v1/clients', token, { name: '店A' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string }> };
    await call(env, 'POST', '/api/v1/items', token, {
      name: '白菜', prices: [{ unit: '斤', purchase_price: 2, sale_price: 2.5 }],
    });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ prices: Array<{ id: string }> }>;
    };
    const sale = await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clients.clients[0].id, happened_at: '2026-01-06',
      items: [{ price_id: items.items[0].prices[0].id, quantity: 1 }],
    });
    const saleId = ((await sale.json()) as { id: string }).id;
    const up1 = (await (await call(env, 'POST', `/api/v1/attachments?entity=sale&id=${saleId}`, token, photoForm(), true)).json()) as { key: string };
    const fd2 = new FormData();
    fd2.append('photo', new File([new Uint8Array([0xff, 0xd8, 0xff, 0x01])], 'photo2.jpg', { type: 'image/jpeg' }));
    const up2 = (await (await call(env, 'POST', `/api/v1/attachments?entity=sale&id=${saleId}`, token, fd2, true)).json()) as { key: string };
    expect(up1.key).not.toBe(up2.key); // 不同内容 → 不同 key
    const refs0 = await (env.DB as FakeD1).prepare('SELECT COUNT(*) AS n FROM attachment_refs').first<{ n: number }>();
    expect(refs0?.n).toBe(2);

    // 模拟 App 删除其中一张：push attachment delete 变更（payload.file_key）→ 云端删该引用 + GC 文件
    const delPush = await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'dev-delete-test',
      changes: [
        {
          entity_type: 'attachment', entity_sync_id: up1.key, action: 'delete',
          updated_at: new Date().toISOString(),
          payload: { file_key: up1.key },
        },
      ],
    });
    const delRes = (await delPush.json()) as { accepted: number; rejected: number };
    expect(delRes.accepted).toBe(1);
    expect(delRes.rejected).toBe(0);

    // 引用表只剩 up2；up1 R2 文件被 GC（零引用）；in-use 只列 up2
    const refs1 = await (env.DB as FakeD1).prepare('SELECT file_key FROM attachment_refs').all<{ file_key: string }>();
    expect(refs1.results.length).toBe(1);
    expect(refs1.results[0].file_key).toBe(up2.key);
    expect(await env.BUCKET.get(up1.key)).toBeNull();
    expect(await env.BUCKET.get(up2.key)).not.toBeNull();

    const inUse = await (await call(env, 'GET', '/api/v1/attachments/in-use', token)).json() as {
      attachments: Array<{ key: string }>;
    };
    expect(inUse.attachments.some((a) => a.key === up1.key)).toBe(false);
    expect(inUse.attachments.some((a) => a.key === up2.key)).toBe(true);
  });

  it('一图多单共用：删除一个实体的引用，文件与其他实体的引用行都保留', async () => {
    // 建两个单据，同一内容（同 md5）各传一次（不同 entity_id → 两个 key）
    await call(env, 'POST', '/api/v1/clients', token, { name: '店A' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string }> };
    await call(env, 'POST', '/api/v1/items', token, {
      name: '白菜', prices: [{ unit: '斤', purchase_price: 2, sale_price: 2.5 }],
    });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ prices: Array<{ id: string }> }>;
    };
    const sale = await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clients.clients[0].id, happened_at: '2026-01-07',
      items: [{ price_id: items.items[0].prices[0].id, quantity: 1 }],
    });
    const saleId = ((await sale.json()) as { id: string }).id;
    const upA = (await (await call(env, 'POST', `/api/v1/attachments?entity=sale&id=${saleId}`, token, photoForm(), true)).json()) as { key: string };

    // 另一实体也引用同一文件（共用图场景）
    await (env.DB as FakeD1).prepare(
      "INSERT INTO attachment_refs (id, entity, entity_id, file_key, md5) VALUES (?, 'sale', 'other-sale', ?, 'deadbeef')",
    ).bind('ref-other', upA.key).run();
    const delPush = await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'dev-c',
      changes: [{
        entity_type: 'attachment', entity_sync_id: upA.key, action: 'delete',
        updated_at: new Date().toISOString(), payload: { file_key: upA.key },
      }],
    });
    expect(((await delPush.json()) as { accepted: number }).accepted).toBe(1);
    // 文件保留，且其他实体的引用行也保留（实体级删除，不伤共用引用）
    expect(await env.BUCKET.get(upA.key)).not.toBeNull();
    const refs = await (env.DB as FakeD1).prepare('SELECT id, entity, entity_id FROM attachment_refs').all<{ id: string; entity: string; entity_id: string }>();
    expect(refs.results).toHaveLength(1);
    expect(refs.results[0].id).toBe('ref-other');
  });

  it('attachment delete 带 entity/id：只删该实体引用，共用文件与其他实体引用保留', async () => {
    // 同一文件被两个实体引用（共用图），从一端删除（payload 带 entity/id，新客户端）
    await (env.DB as FakeD1).prepare(
      "INSERT INTO attachment_refs (id, entity, entity_id, file_key, md5) VALUES (?, 'sale', 's-a', 'taozhu/images/attachments/sale/s-a/f.jpg', 'm1')",
    ).bind('r1').run();
    await (env.DB as FakeD1).prepare(
      "INSERT INTO attachment_refs (id, entity, entity_id, file_key, md5) VALUES (?, 'sale', 's-b', 'taozhu/images/attachments/sale/s-a/f.jpg', 'm1')",
    ).bind('r2').run();
    await env.BUCKET.put('taozhu/images/attachments/sale/s-a/f.jpg', new Uint8Array([1]));
    const delPush = await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'dev-d',
      changes: [{
        entity_type: 'attachment', entity_sync_id: 'taozhu/images/attachments/sale/s-a/f.jpg', action: 'delete',
        updated_at: new Date().toISOString(),
        payload: { file_key: 'taozhu/images/attachments/sale/s-a/f.jpg', entity: 'sale', id: 's-a' },
      }],
    });
    expect(((await delPush.json()) as { accepted: number }).accepted).toBe(1);
    // 只删了 s-a 的引用；s-b 引用行与 R2 文件都保留
    const refs = await (env.DB as FakeD1).prepare('SELECT id FROM attachment_refs').all<{ id: string }>();
    expect(refs.results.map((r) => r.id)).toEqual(['r2']);
    expect(await env.BUCKET.get('taozhu/images/attachments/sale/s-a/f.jpg')).not.toBeNull();
  });

  it('DELETE /attachments?key= 共用图：只删本实体引用行，文件与其他实体引用保留', async () => {
    await (env.DB as FakeD1).prepare(
      "INSERT INTO attachment_refs (id, entity, entity_id, file_key, md5) VALUES (?, 'sale', 's-a', 'taozhu/images/attachments/sale/s-a/f.jpg', 'm1')",
    ).bind('ra').run();
    await (env.DB as FakeD1).prepare(
      "INSERT INTO attachment_refs (id, entity, entity_id, file_key, md5) VALUES (?, 'sale', 's-b', 'taozhu/images/attachments/sale/s-a/f.jpg', 'm1')",
    ).bind('rb').run();
    await env.BUCKET.put('taozhu/images/attachments/sale/s-a/f.jpg', new Uint8Array([1]));
    const del = await call(env, 'DELETE', '/api/v1/attachments?key=taozhu/images/attachments/sale/s-a/f.jpg', token);
    expect(del.status).toBe(204);
    const refs = await (env.DB as FakeD1).prepare('SELECT id FROM attachment_refs').all<{ id: string }>();
    expect(refs.results.map((r) => r.id)).toEqual(['rb']);
    expect(await env.BUCKET.get('taozhu/images/attachments/sale/s-a/f.jpg')).not.toBeNull();
  });

  it('单据 upsert 不带 attachments 字段 → 现有附件引用保留（不收敛不误删）', async () => {
    // 建单据 + 上传附件（引用行在）
    await call(env, 'POST', '/api/v1/clients', token, { name: '店A' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string }> };
    await call(env, 'POST', '/api/v1/items', token, {
      name: '白菜', prices: [{ unit: '斤', purchase_price: 2, sale_price: 2.5 }],
    });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ prices: Array<{ id: string }> }>;
    };
    const sale = await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clients.clients[0].id, happened_at: '2026-01-08',
      items: [{ price_id: items.items[0].prices[0].id, quantity: 1 }],
    });
    const saleId = ((await sale.json()) as { id: string }).id;
    const up = (await (await call(env, 'POST', `/api/v1/attachments?entity=sale&id=${saleId}`, token, photoForm(), true)).json()) as { key: string };
    // push 单据 upsert（payload 无 attachments 字段——历史/页面保存快照形态）
    const ts = new Date().toISOString();
    const push = await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'dev-e',
      changes: [{
        entity_type: 'sale', entity_sync_id: saleId, action: 'upsert',
        updated_at: ts,
        payload: { id: saleId, client_id: clients.clients[0].id, happened_at: '2026-01-08', note: '', items: [] },
      }],
    });
    expect(((await push.json()) as { accepted: number }).accepted).toBe(1);
    // 引用保留、文件保留、in-use 仍列出（附件不被误删）
    const refs = await (env.DB as FakeD1).prepare("SELECT COUNT(*) AS n FROM attachment_refs WHERE entity = 'sale' AND entity_id = ?").bind(saleId).first<{ n: number }>();
    expect(refs?.n ?? 0).toBe(1);
    expect(await env.BUCKET.get(up.key)).not.toBeNull();
  });

  it('单据 upsert 带 attachments 差集 → 只删本单据移出的引用；共用文件被其他实体引用则保留', async () => {
    await call(env, 'POST', '/api/v1/clients', token, { name: '店A' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string }> };
    await call(env, 'POST', '/api/v1/items', token, {
      name: '白菜', prices: [{ unit: '斤', purchase_price: 2, sale_price: 2.5 }],
    });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ prices: Array<{ id: string }> }>;
    };
    const sale = await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clients.clients[0].id, happened_at: '2026-01-09',
      items: [{ price_id: items.items[0].prices[0].id, quantity: 1 }],
    });
    const saleId = ((await sale.json()) as { id: string }).id;
    // 挂两张附件（不同内容 → 不同 key）
    const up1 = (await (await call(env, 'POST', `/api/v1/attachments?entity=sale&id=${saleId}`, token, photoForm(), true)).json()) as { key: string };
    const fd2 = new FormData();
    fd2.append('photo', new File([new Uint8Array([0xff, 0xd8, 0xff, 0x02])], 'photo2.jpg', { type: 'image/jpeg' }));
    const up2 = (await (await call(env, 'POST', `/api/v1/attachments?entity=sale&id=${saleId}`, token, fd2, true)).json()) as { key: string };
    // 共用场景：up1 也被另一实体引用（保护文件）
    await (env.DB as FakeD1).prepare(
      "INSERT INTO attachment_refs (id, entity, entity_id, file_key, md5) VALUES (?, 'sale', 'shared-x', ?, 'm2')",
    ).bind('ref-shared', up1.key).run();
    // push 单据 upsert：attachments 只保留 up2（up1 被移出）→ 只删本单据 up1 引用；文件因共用保留
    const ts = new Date().toISOString();
    const push = await call(env, 'POST', '/api/v1/sync/push', token, {
      device_id: 'dev-f',
      changes: [{
        entity_type: 'sale', entity_sync_id: saleId, action: 'upsert',
        updated_at: ts,
        payload: { id: saleId, client_id: clients.clients[0].id, happened_at: '2026-01-09', note: '', items: [], attachments: [up2.key] },
      }],
    });
    expect(((await push.json()) as { accepted: number }).accepted).toBe(1);
    // 本单据只剩 up2 引用；共用引用 ref-shared 保留；up1 文件保留
    const refs = await (env.DB as FakeD1).prepare("SELECT id, file_key FROM attachment_refs WHERE entity = 'sale' AND entity_id = ?").bind(saleId).all<{ id: string; file_key: string }>();
    expect(refs.results.map((r) => r.file_key)).toEqual([up2.key]);
    const shared = await (env.DB as FakeD1).prepare("SELECT COUNT(*) AS n FROM attachment_refs WHERE file_key = ?").bind(up1.key).first<{ n: number }>();
    expect(shared?.n ?? 0).toBe(1); // 只剩 shared-x 的引用
    expect(await env.BUCKET.get(up1.key)).not.toBeNull();
    expect(await env.BUCKET.get(up2.key)).not.toBeNull();
  });
});

describe('附件存储工厂（createStorage）', () => {
  it('r2 驱动返回 R2Storage；不支持的驱动抛错', () => {
    const base = { DB: {}, ASSETS: fakeAssets, JWT_SECRET: 'x', BUCKET: new FakeBucket() } as never;
    expect(createStorage({ ...base, STORAGE_DRIVER: 'r2' } as never)).toBeTruthy();
    expect(() => createStorage({ ...base, STORAGE_DRIVER: 'webdav' } as never)).toThrow(/不支持|webdav/);
    // 缺省默认 r2
    expect(createStorage(base)).toBeTruthy();
  });
});