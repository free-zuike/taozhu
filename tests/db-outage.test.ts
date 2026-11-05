/**
 * D1 免费额度耗尽 / 不可用时的降级回归（生产事故：打开 AI 助手全部 500）。
 * - 建表中间件不能把 DB 故障放大到全部 /api/v1/*
 * - AI 只读页面仍能以空数据打开，由前端本地缓存兜底
 * - 确实需要 DB 的接口返回可读的中文 503，而不是裸 500
 */
import { describe, expect, it } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { isDbUnavailable, DB_UNAVAILABLE_MESSAGE } from '../src/lib/db-availability';
import { createFakeD1, fakeAssets, type FakeD1 } from './helpers/fake-d1';

const JWT_SECRET = 'test-secret';
const BASE = 'http://localhost';

/** 模拟 Cloudflare D1 额度耗尽：任何查询都抛 D1_ERROR */
class BrokenDb {
  prepare(): never { throw new Error('D1_ERROR: quota exceeded: rows_read daily limit'); }
  batch(): never { throw new Error('D1_ERROR: quota exceeded'); }
}

type TestEnv = { DB: FakeD1 | BrokenDb; ASSETS: typeof fakeAssets; JWT_SECRET: string };

async function call(env: TestEnv, method: string, path: string, token?: string, body?: unknown): Promise<Response> {
  const headers: Record<string, string> = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  return app.request(
    `${BASE}${path}`,
    { method, headers, body: body === undefined ? undefined : JSON.stringify(body) },
    env as never,
  );
}

async function setup(): Promise<{ token: string; env: TestEnv }> {
  resetSchemaState();
  const db = await createFakeD1();
  await ensureSchema(db as never);
  const env: TestEnv = { DB: db, ASSETS: fakeAssets, JWT_SECRET };
  const res = await call(env, 'POST', '/api/v1/auth/bootstrap', undefined, { username: 'boss', password: 'admin1234' });
  const token = ((await res.json()) as { token: string }).token;
  return { token, env };
}

describe('D1 额度耗尽降级', () => {
  it('只识别基础设施错误，业务异常照常抛出', () => {
    expect(isDbUnavailable(new Error('D1_ERROR: quota exceeded'))).toBe(true);
    expect(isDbUnavailable(new Error('Network connection lost'))).toBe(true);
    expect(isDbUnavailable(new Error('too many requests'))).toBe(true);
    expect(isDbUnavailable(new Error('金额不能为负'))).toBe(false);
  });

  it('AI 助手只读页面不再 500，返回空数据由本地缓存兜底', async () => {
    const { token, env } = await setup();
    const broken: TestEnv = { ...env, DB: new BrokenDb() };
    for (const [path, key] of [
      ['/api/v1/ai/tools', 'tools'],
      ['/api/v1/ai/activity', 'activity'],
      ['/api/v1/ai/memories', 'memories'],
    ] as const) {
      const res = await call(broken, 'GET', path, token);
      expect(res.status, path).toBe(200);
      expect(((await res.json()) as Record<string, unknown>)[key], path).toEqual([]);
    }
    const hist = await call(broken, 'GET', '/api/v1/ai/chat/history', token);
    expect(hist.status).toBe(200);
    expect(await hist.json()).toEqual({ conversation_id: null, messages: [] });
  });

  it('需要 DB 的业务接口返回中文 503 + 错误码，不再是裸 500', async () => {
    const { token, env } = await setup();
    const broken: TestEnv = { ...env, DB: new BrokenDb() };
    const res = await call(broken, 'GET', '/api/v1/clients', token);
    expect(res.status).toBe(503);
    const body = (await res.json()) as { code: string; error: string };
    expect(body.code).toBe('DB_UNAVAILABLE');
    expect(body.error).toBe(DB_UNAVAILABLE_MESSAGE);
  });

  // 放在最后：该用例会触发 60s 建表失败冷却，避免影响同文件其他用例
  it('ensureSchema 失败不会把故障放大到全部 API', async () => {
    const { token, env } = await setup();
    resetSchemaState(); // 强制下个请求真的重跑建表（这次会失败）
    const broken: TestEnv = { ...env, DB: new BrokenDb() };
    const res = await call(broken, 'GET', '/api/v1/ai/tools', token);
    expect(res.status).toBe(200);
    expect(((await res.json()) as { tools: unknown[] }).tools).toEqual([]);
  });
});
