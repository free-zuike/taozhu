/** CORS（App 跨域登录需要）+ ping 版本 测试 */
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { createFakeD1, fakeAssets } from './helpers/fake-d1';
import { APP_VERSION } from '../src/version';

const BASE = 'http://localhost';

async function setup() {
  resetSchemaState();
  const db = await createFakeD1();
  await ensureSchema(db as never);
  return { env: { DB: db, ASSETS: fakeAssets, JWT_SECRET: 'test-secret' } };
}

describe('CORS 与版本', () => {
  let env: { DB: import('./helpers/fake-d1').FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };
  beforeEach(async () => { env = (await setup()).env; });

  it('跨域请求返回 Access-Control-Allow-Origin: *（Android App 登录依赖）', async () => {
    const res = await app.request(`${BASE}/api/v1/auth/bootstrap/status`, {
      method: 'GET',
      headers: { Origin: 'capacitor://localhost' },
    }, env as never);
    expect(res.headers.get('access-control-allow-origin')).toBe('*');
    expect(res.headers.get('access-control-allow-methods')).toContain('POST');
  });

  it('OPTIONS 预检返回 204 + CORS 头', async () => {
    const res = await app.request(`${BASE}/api/v1/auth/login`, {
      method: 'OPTIONS',
      headers: { Origin: 'http://localhost:8100', 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'content-type,authorization' },
    }, env as never);
    expect(res.status).toBe(204);
    expect(res.headers.get('access-control-allow-origin')).toBe('*');
    expect(res.headers.get('access-control-allow-headers')?.toLowerCase()).toContain('authorization');
  });

  it('ping 返回应用名与三位版本号', async () => {
    const res = await app.request(`${BASE}/api/v1/auth/ping`, {}, env as never);
    const body = (await res.json()) as { app: string; version: string };
    expect(body.app).toBe('陶朱');
    expect(body.version).toBe(APP_VERSION);
    expect(body.version.split('.')).toHaveLength(3);
  });
});