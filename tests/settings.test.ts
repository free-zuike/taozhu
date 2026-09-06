/** 系统设置测试：AI 配置（地址/Key/模型）后台存取（仅老板）、拍照识别未配置提示 */
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
  return { env: { DB: db, ASSETS: fakeAssets, JWT_SECRET } };
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
  return app.request(`${BASE}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }, env as never);
}

async function boot(env: Parameters<typeof call>[0]) {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  return ((await res.json()) as { token: string }).token;
}

async function staffToken(env: Parameters<typeof call>[0], adminToken: string) {
  await call(env, 'POST', '/api/v1/users', adminToken, { username: 'staff1', password: 'staff123', role: 'staff' });
  const r = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff123' });
  return ((await r.json()) as { token: string }).token;
}

describe('系统设置（AI 配置）', () => {
  let env: Parameters<typeof call>[0];
  let token: string;
  beforeEach(async () => { env = (await setup()).env; token = await boot(env); });

  it('初始未配置，返回默认地址与模型', async () => {
    const res = await call(env, 'GET', '/api/v1/settings/ai', token);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { has_key: boolean; base_url: string; model: string };
    expect(body.has_key).toBe(false);
    expect(body.base_url).toBe('https://open.bigmodel.cn/api/paas/v4');
    expect(body.model).toBe('glm-4v-flash');
  });

  it('老板保存 地址/Key/模型 后可回读（Key 不回显明文）', async () => {
    const put = await call(env, 'PUT', '/api/v1/settings/ai', token, {
      api_key: 'sk-1234567890abcdef',
      base_url: 'https://my-proxy.example/v1',
      model: 'my-vision-model',
    });
    expect(put.status).toBe(200);
    const get = await call(env, 'GET', '/api/v1/settings/ai', token);
    const body = (await get.json()) as { has_key: boolean; base_url: string; model: string };
    expect(body.has_key).toBe(true);
    expect(body.base_url).toBe('https://my-proxy.example/v1');
    expect(body.model).toBe('my-vision-model');
    expect(JSON.stringify(body)).not.toContain('sk-');
  });

  it('清空 Key 回到未配置', async () => {
    await call(env, 'PUT', '/api/v1/settings/ai', token, { api_key: 'sk-x' });
    const put = await call(env, 'PUT', '/api/v1/settings/ai', token, { api_key: '' });
    expect((put.status)).toBe(200);
    const get = (await (await call(env, 'GET', '/api/v1/settings/ai', token)).json()) as { has_key: boolean };
    expect(get.has_key).toBe(false);
  });

  it('店员不能访问系统设置（403）', async () => {
    const st = await staffToken(env, token);
    expect((await call(env, 'GET', '/api/v1/settings/ai', st)).status).toBe(403);
    expect((await call(env, 'PUT', '/api/v1/settings/ai', st, { api_key: 'x' })).status).toBe(403);
  });

  it('未配置 key 时拍照识别返回提示（400）', async () => {
    const res = await call(env, 'POST', '/api/v1/ai/parse-photo?purpose=purchase', token);
    const body = (await res.json()) as { error: string };
    expect(body.error).toContain('系统设置');
  });
});