/**
 * 运维自检端点：索引的查询结果与补建全部由代码完成，不依赖 D1 控制台手工 SQL。
 * 覆盖：关键索引清单 / EXPLAIN 走索引 / 删索引后由端点自动补建 / 权限。
 */
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
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
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  return app.request(`${BASE}${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }, env as never);
}

async function loginAdmin(env: TestEnv): Promise<string> {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  return ((await res.json()) as { token: string }).token;
}

describe('索引自检（/api/v1/maintenance/indexes）', () => {
  let env: TestEnv;
  let token: string;
  beforeEach(async () => { env = await setup(); token = await loginAdmin(env); });

  it('GET 返回关键索引清单 + EXPLAIN 计划，且关键查询走索引', async () => {
    const res = await call(env, 'GET', '/api/v1/maintenance/indexes', token);
    expect(res.status).toBe(200);
    const d = (await res.json()) as {
      critical: Array<{ name: string; present: boolean; sql: string | null }>;
      missing: string[];
      plans: Array<{ name: string; detail: string }>;
      totalIndexes: number;
    };
    expect(d.missing).toEqual([]);
    expect(d.critical.map((c) => c.name)).toContain('idx_attachment_refs_entity');
    expect(d.critical.every((c) => c.present)).toBe(true);
    expect(d.critical.find((c) => c.name === 'idx_attachment_refs_entity')?.sql)
      .toMatch(/entity\s*,\s*entity_id/i);
    expect(d.plans).toHaveLength(3);
    expect(d.plans.every((p) => p.detail.length > 0)).toBe(true);
    expect(d.plans.some((p) => /idx_attachment_refs/i.test(p.detail))).toBe(true);
    expect(d.totalIndexes).toBeGreaterThan(0);
  });

  it('关键索引被删后，POST /indexes/ensure 由代码自动补建', async () => {
    await env.DB.prepare('DROP INDEX idx_attachment_refs_entity').run();
    const before = (await (await call(env, 'GET', '/api/v1/maintenance/indexes', token)).json()) as { missing: string[] };
    expect(before.missing).toContain('idx_attachment_refs_entity');

    const res = await call(env, 'POST', '/api/v1/maintenance/indexes/ensure', token);
    expect(res.status).toBe(200);
    const d = (await res.json()) as {
      ok: boolean; missing_before: string[]; missing_after: string[];
    };
    expect(d.ok).toBe(true);
    expect(d.missing_before).toContain('idx_attachment_refs_entity');
    expect(d.missing_after).toEqual([]);
  });

  it('未登录 401；店员 403（运维端点仅 admin）', async () => {
    expect((await call(env, 'GET', '/api/v1/maintenance/indexes')).status).toBe(401);
    await call(env, 'POST', '/api/v1/users', token, { username: 'staff1', password: 'staff1234', role: 'staff' });
    const r = await call(env, 'POST', '/api/v1/auth/login', undefined, { username: 'staff1', password: 'staff1234' });
    const staffToken = ((await r.json()) as { token: string }).token;
    expect((await call(env, 'GET', '/api/v1/maintenance/indexes', staffToken)).status).toBe(403);
  });
});
