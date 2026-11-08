/** AI 工具时间线摘要 + 每日维护回收站清理 */
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { createFakeD1, fakeAssets, type FakeD1 } from './helpers/fake-d1';
import { runDailyMaintenance } from '../src/services/maintenance';

const JWT_SECRET = 'test-secret';
const BASE = 'http://localhost';
type Env = { DB: FakeD1; ASSETS: typeof fakeAssets; JWT_SECRET: string };

async function setup() {
  resetSchemaState();
  const db = await createFakeD1();
  await ensureSchema(db as never);
  return { env: { DB: db, ASSETS: fakeAssets, JWT_SECRET } };
}

async function call(env: Env, method: string, path: string, token?: string, body?: unknown): Promise<Response> {
  const headers: Record<string, string> = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  return app.request(`${BASE}${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }, env as never);
}

async function boot(env: Env): Promise<{ token: string; userId: string }> {
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  const token = ((await res.json()) as { token: string }).token;
  const userId = (await env.DB.prepare('SELECT id FROM users LIMIT 1').first<{ id: string }>())!.id;
  return { token, userId };
}

async function seedRuns(env: Env, userId: string) {
  const now = new Date().toISOString();
  const old = new Date(Date.now() - 400 * 86400_000).toISOString();
  await env.DB.prepare(
    'INSERT INTO ai_runs (id, user_id, intent, status, started_at) VALUES (?,?,?,?,?)',
  ).bind('r1', userId, 'query', 'ok', now).run();
  await env.DB.prepare(
    'INSERT INTO ai_runs (id, user_id, intent, status, started_at) VALUES (?,?,?,?,?)',
  ).bind('r2', userId, 'record', 'error', old).run();
  for (const [id, name, status, at] of [
    ['c1', 'query_business_data', 'ok', now],
    ['c2', 'query_business_data', 'ok', now],
    ['c3', 'create_payment', 'error', now],
    ['c4', 'save_memory', 'ok', old],
  ] as Array<[string, string, string, string]>) {
    await env.DB.prepare(
      `INSERT INTO ai_tool_calls (id, run_id, user_id, tool_name, status, created_at)
       VALUES (?, 'r1', ?, ?, ?, ?)`,
    ).bind(id, userId, name, status, at).run();
  }
}

describe('AI 工具时间线摘要', () => {
  let env: Env;
  let token: string;
  let userId: string;
  beforeEach(async () => {
    ({ env } = await setup());
    ({ token, userId } = await boot(env));
    await seedRuns(env, userId);
  });

  it('GET /ai/activity/summary 只统计窗口内记录，按工具/按天确定性聚合', async () => {
    const res = await call(env, 'GET', '/api/v1/ai/activity/summary?days=30', token);
    expect(res.status).toBe(200);
    const s = (await res.json()) as {
      days: number; runs: number; calls: number; errors: number;
      by_tool: Array<{ tool_name: string; count: number; errors: number }>;
      by_day: Array<{ day: string; runs: number; calls: number }>;
      recent: unknown[]; text: string;
    };
    expect(s.days).toBe(30);
    expect(s.runs).toBe(1); // 400 天前的 r2 被排除
    expect(s.calls).toBe(3);
    expect(s.errors).toBe(1);
    expect(s.by_tool[0]).toMatchObject({ tool_name: 'query_business_data', count: 2, errors: 0 });
    expect(s.by_tool.find((t) => t.tool_name === 'create_payment')).toMatchObject({ count: 1, errors: 1 });
    expect(s.by_day).toHaveLength(1);
    expect(s.recent).toHaveLength(3);
    expect(s.text).toContain('1 次运行、3 次工具调用');
  });

  it('days 被钳制到 [1,365]；工具清单含 activity_timeline 且为只读免授权', async () => {
    const r = await call(env, 'GET', '/api/v1/ai/activity/summary?days=9999', token);
    expect(((await r.json()) as { days: number }).days).toBe(365);
    const tools = (await (await call(env, 'GET', '/api/v1/ai/tools', token)).json()) as {
      tools: Array<{ name: string; permission: string; policy: string }>;
    };
    const t = tools.tools.find((x) => x.name === 'activity_timeline');
    expect(t).toMatchObject({ permission: 'read', policy: 'allow' });
  });

  it('每日维护清理超期回收站快照，保留近期可恢复记录', async () => {
    await env.DB.prepare(
      `INSERT INTO voided_orders (id, entity_type, payload, reason, voided_at, voided_by)
       VALUES ('old1','sale','{}','过期',?, 'boss'), ('new1','sale','{}','近期',?, 'boss')`,
    ).bind(new Date(Date.now() - 400 * 86400_000).toISOString(), new Date().toISOString()).run();
    const out = await runDailyMaintenance(env.DB, true);
    expect(out.ran).toBe(true);
    expect(out.voided_orders).toBe(1);
    const row = await env.DB.prepare('SELECT COUNT(*) AS cnt FROM voided_orders').first<{ cnt: number }>();
    expect(row?.cnt).toBe(1);
    const manual = await call(env, 'POST', '/api/v1/maintenance/prune', token);
    expect(manual.status).toBe(200);
  });
});
