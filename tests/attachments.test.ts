/** 附件路由测试：R2 用内存 mock（put/get/list/delete），验证上传/列表/代理读取/删除与参数校验 */
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
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
    expect(key.startsWith('sale/s1/')).toBe(true);

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

  it('未登录 → 401', async () => {
    expect((await call(env, 'GET', '/api/v1/attachments?entity=sale&id=a')).status).toBe(401);
  });
});