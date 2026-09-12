/** 账号自助修改 / 两步验证（TOTP）/ 头像 / 附件按店铺统计 */
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { totpCode } from '../src/lib/totp';
import { createFakeD1, fakeAssets, type FakeD1 } from './helpers/fake-d1';

const JWT_SECRET = 'test-secret';
const BASE = 'http://localhost';

/** 内存 R2Bucket mock（头像/附件统计用） */
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
    const bytes = o.bytes;
    return {
      size: bytes.byteLength,
      get body() {
        return new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(bytes);
            controller.close();
          },
        });
      },
      writeHttpMetadata(headers: Headers) { headers.set('content-type', 'image/jpeg'); },
    } as unknown as R2ObjectBody;
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

type Env = { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string; BUCKET: FakeBucket };

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
    } else {
      reqBody = JSON.stringify(body);
      headers['Content-Type'] = 'application/json';
    }
  }
  return app.request(`${BASE}${path}`, { method, headers, body: reqBody }, env as never);
}

async function loginAdmin(env: Env) {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  expect(res.status).toBe(201);
  return ((await res.json()) as { token: string }).token;
}

function photoForm(): FormData {
  const fd = new FormData();
  fd.append('photo', new File([new Uint8Array([0xff, 0xd8, 0xff, 0x00])], 'photo.jpg', { type: 'image/jpeg' }));
  return fd;
}

describe('账号自助修改（/auth/profile）', () => {
  let env: Env;
  let token: string;

  beforeEach(async () => {
    env = await setup();
    token = await loginAdmin(env);
  });

  it('修改显示名：登录账号不变，/me 返回新显示名', async () => {
    const res = await call(env, 'PATCH', '/api/v1/auth/profile', token, { display_name: '老板小张' });
    expect(res.status).toBe(200);
    const d = (await res.json()) as { user: { username: string; display_name: string } };
    expect(d.user.username).toBe('boss'); // 登录账号不可改
    expect(d.user.display_name).toBe('老板小张');

    const me = await (await call(env, 'GET', '/api/v1/auth/me', token)).json() as { user: { username: string; display_name: string } };
    expect(me.user.display_name).toBe('老板小张');
    expect(me.user.username).toBe('boss');
  });

  it('登录账号不可通过 profile 修改（username 字段被忽略）', async () => {
    const res = await call(env, 'PATCH', '/api/v1/auth/profile', token, { username: 'hacked' });
    expect(res.status).toBe(200);
    const d = (await res.json()) as { user: { username: string } };
    expect(d.user.username).toBe('boss');
    // 登录仍用原账号
    expect((await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'boss', password: 'admin1234' })).status).toBe(200);
  });

  it('bootstrap 显示名默认取登录账号 @ 前部分', async () => {
    env = await setup();
    const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss@mail.com', password: 'admin1234' });
    expect(res.status).toBe(201);
    const d = (await res.json()) as { user: { username: string; display_name: string } };
    expect(d.user.display_name).toBe('boss');
    expect(d.user.username).toBe('boss@mail.com');
  });

  it('改密码：需旧密码，且旧密码错误被拒', async () => {
    expect((await call(env, 'PATCH', '/api/v1/auth/profile', token, { password: 'new1234' })).status).toBe(400);
    expect((await call(env, 'PATCH', '/api/v1/auth/profile', token, { old_password: 'wrong', password: 'new1234' })).status).toBe(400);
    const ok = await call(env, 'PATCH', '/api/v1/auth/profile', token, { old_password: 'admin1234', password: 'new1234' });
    expect(ok.status).toBe(200);
    // 新密码可登录，旧密码失效
    expect((await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'boss', password: 'new1234' })).status).toBe(200);
    expect((await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'boss', password: 'admin1234' })).status).toBe(401);
  });

  it('新密码至少 6 位', async () => {
    const res = await call(env, 'PATCH', '/api/v1/auth/profile', token, { old_password: 'admin1234', password: '123' });
    expect(res.status).toBe(400);
  });

  it('老板建账号显示名默认取 @ 前部分', async () => {
    const res = await call(env, 'POST', '/api/v1/users', token, { username: 'staff@shop.com', password: 'staff123', role: 'staff' });
    expect(res.status).toBe(201);
    const d = (await res.json()) as { display_name?: string };
    expect(d.display_name).toBe('staff');
  });

  it('头像：上传后 /auth/avatar 可读到，/me 返回 avatar', async () => {
    const up = await call(env, 'POST', '/api/v1/auth/avatar', token, photoForm(), true);
    expect(up.status).toBe(200);
    const me = await (await call(env, 'GET', '/api/v1/auth/me', token)).json() as { user: { avatar: string | null } };
    expect(me.user.avatar).toContain('taozhu/images/avatars/');
    const read = await call(env, 'GET', '/api/v1/auth/avatar', token);
    expect(read.status).toBe(200);
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(new Uint8Array([0xff, 0xd8, 0xff, 0x00]));
    // 未登录不可读头像
    expect((await call(env, 'GET', '/api/v1/auth/avatar')).status).toBe(401);
  });
});

describe('两步验证（TOTP）', () => {
  let env: Env;
  let token: string;

  beforeEach(async () => {
    env = await setup();
    token = await loginAdmin(env);
  });

  it('开启 → 登录需验证码 → 带码登录成功 → 关闭后免验证码', async () => {
    const setupRes = await (await call(env, 'GET', '/api/v1/auth/totp/setup', token)).json() as { secret: string; otpauth: string };
    expect(setupRes.secret.length).toBeGreaterThanOrEqual(16);
    expect(setupRes.otpauth).toContain('otpauth://totp/');

    // 错误验证码 → 400
    expect((await call(env, 'POST', '/api/v1/auth/totp/confirm', token, { code: '000000' })).status).toBe(400);

    const code = await totpCode(setupRes.secret);
    expect((await call(env, 'POST', '/api/v1/auth/totp/confirm', token, { code })).status).toBe(200);

    // 再次 setup → 409（已开启）
    expect((await call(env, 'GET', '/api/v1/auth/totp/setup', token)).status).toBe(409);

    // 登录：不带码 → need_totp；错码 → 401；对码 → 200
    const need = await (await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'boss', password: 'admin1234' })).json() as { need_totp?: boolean };
    expect(need.need_totp).toBe(true);
    expect((await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'boss', password: 'admin1234', code: '999999' })).status).toBe(401);
    expect((await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'boss', password: 'admin1234', code: await totpCode(setupRes.secret) })).status).toBe(200);

    // 关闭：错码 → 400；对码 → 200；之后登录免验证码
    expect((await call(env, 'POST', '/api/v1/auth/totp/disable', token, { code: '000000' })).status).toBe(400);
    expect((await call(env, 'POST', '/api/v1/auth/totp/disable', token, { code: await totpCode(setupRes.secret) })).status).toBe(200);
    const plain = await (await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'boss', password: 'admin1234' })).json() as { need_totp?: boolean; token?: string };
    expect(plain.need_totp).toBeUndefined();
    expect(typeof plain.token).toBe('string');
  });

  it('未登录访问 TOTP 接口 → 401', async () => {
    expect((await call(env, 'GET', '/api/v1/auth/totp/setup')).status).toBe(401);
    expect((await call(env, 'POST', '/api/v1/auth/totp/confirm', undefined, { code: '123456' })).status).toBe(401);
  });
});

describe('附件按店铺统计（/attachments/counts）', () => {
  let env: Env;
  let token: string;

  beforeEach(async () => {
    env = await setup();
    token = await loginAdmin(env);
    // 直插店铺 + 一张出货单 + 一张收款单（附件统计只依赖单据 id 归属）
    await env.DB.prepare('INSERT INTO clients (id, name) VALUES (?, ?)').bind('c1', '店A').run();
    await env.DB.prepare('INSERT INTO sales (id, client_id, happened_at) VALUES (?, ?, ?)').bind('s1', 'c1', '2026-01-01').run();
    await env.DB.prepare('INSERT INTO payments (id, client_id, happened_at, amount) VALUES (?, ?, ?, ?)').bind('p1', 'c1', '2026-01-01', 100).run();
  });

  it('按 client_id 汇总：只统计该店单据的附件，返回 total 与 ids', async () => {
    await call(env, 'POST', '/api/v1/attachments?entity=sale&id=s1', token, photoForm(), true);
    await call(env, 'POST', '/api/v1/attachments?entity=sale&id=s1', token, photoForm(), true); // 同内容 MD5 去重

    const sale = await (await call(env, 'POST', '/api/v1/attachments/counts', token, { entity: 'sale', client_id: 'c1' })).json() as {
      total: number; ids: string[]; counts: Record<string, number>;
    };
    expect(sale.total).toBe(1);
    expect(sale.ids).toEqual(['s1']);
    expect(sale.counts['s1']).toBe(1);

    const pay = await (await call(env, 'POST', '/api/v1/attachments/counts', token, { entity: 'payment', client_id: 'c1' })).json() as {
      total: number; ids: string[];
    };
    expect(pay.total).toBe(0);
    expect(pay.ids).toEqual(['p1']);
  });

  it('按 ids 统计：只统计给定单据', async () => {
    await call(env, 'POST', '/api/v1/attachments?entity=sale&id=s1', token, photoForm(), true);
    const res = await (await call(env, 'POST', '/api/v1/attachments/counts', token, { entity: 'sale', ids: ['s1'] })).json() as {
      total: number; counts: Record<string, number>;
    };
    expect(res.total).toBe(1);
    expect(res.counts['s1']).toBe(1);
  });

  it('总数统计 /attachments/total 含新旧前缀', async () => {
    await call(env, 'POST', '/api/v1/attachments?entity=sale&id=s1', token, photoForm(), true);
    await env.BUCKET.put('taozhu/attachments/sale/s1/old.jpg', new Uint8Array([1, 2, 3]));
    await env.BUCKET.put('sale/s1/bare.jpg', new Uint8Array([1, 2, 3]));
    const d = await (await call(env, 'GET', '/api/v1/attachments/total', token)).json() as { total: number };
    expect(d.total).toBe(3);
  });

  it('参数校验：非法 entity → 400', async () => {
    expect((await call(env, 'POST', '/api/v1/attachments/counts', token, { entity: 'xxx', client_id: 'c1' })).status).toBe(400);
  });
});
