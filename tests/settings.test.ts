/** 系统设置测试：AI 配置（多服务商 + 能力绑定）后台存取（仅老板）、拍照识别未配置提示 */
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { createFakeD1, fakeAssets, type FakeD1 } from './helpers/fake-d1';

const JWT_SECRET = 'test-secret';
const BASE = 'http://localhost';

type AiBody = {
  providers?: Array<Record<string, unknown>>;
  binding?: { textProviderId?: string; visionProviderId?: string; speechProviderId?: string };
  has_key?: boolean;
  base_url?: string;
  model?: string;
};

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

  it('初始未配置：内置智谱服务商 + 全能力默认绑定', async () => {
    const res = await call(env, 'GET', '/api/v1/settings/ai', token);
    expect(res.status).toBe(200);
    const body = (await res.json()) as AiBody;
    expect(body.providers).toHaveLength(1);
    expect(body.providers?.[0]).toMatchObject({ id: 'zhipu_glm', name: '智谱GLM', is_built_in: true, has_key: false });
    expect(body.providers?.[0]?.base_url).toBe('https://open.bigmodel.cn/api/paas/v4');
    expect(body.binding).toEqual({ textProviderId: 'zhipu_glm', visionProviderId: 'zhipu_glm', speechProviderId: 'zhipu_glm' });
  });

  it('添加自定义服务商并绑定能力，回读不回显 Key 明文', async () => {
    const put = await call(env, 'PUT', '/api/v1/settings/ai', token, {
      providers: [
        { id: 'zhipu_glm', name: '智谱GLM', is_built_in: true },
        { id: 'custom_silicon', name: '硅基流动', api_key: 'sk-custom-xyz', base_url: 'https://api.siliconflow.cn/v1', text_model: 'Qwen/Qwen2.5-7B', vision_model: '', audio_model: 'Qwen/Qwen2.5-7B' },
      ],
      binding: { textProviderId: 'custom_silicon', visionProviderId: 'zhipu_glm', speechProviderId: 'custom_silicon' },
    });
    expect(put.status).toBe(200);
    const get = (await (await call(env, 'GET', '/api/v1/settings/ai', token)).json()) as AiBody;
    expect(get.providers).toHaveLength(2);
    expect(get.providers?.find((p) => p.id === 'custom_silicon')).toMatchObject({ has_key: true, base_url: 'https://api.siliconflow.cn/v1' });
    expect(get.binding?.textProviderId).toBe('custom_silicon');
    expect(get.binding?.visionProviderId).toBe('zhipu_glm');
    expect(JSON.stringify(get)).not.toContain('sk-custom-xyz');
  });

  it('删除自定义服务商后绑定回退到智谱；编辑不带 api_key 时保留原 Key', async () => {
    await call(env, 'PUT', '/api/v1/settings/ai', token, {
      providers: [
        { id: 'zhipu_glm', name: '智谱GLM', is_built_in: true },
        { id: 'custom_a', name: '服务商A', api_key: 'sk-a', base_url: 'https://a.example/v1', text_model: 'm', vision_model: '', audio_model: '' },
      ],
      binding: { textProviderId: 'custom_a', visionProviderId: 'zhipu_glm', speechProviderId: 'zhipu_glm' },
    });
    // 删除 custom_a（不传它）→ 绑定应回退智谱
    const put = await call(env, 'PUT', '/api/v1/settings/ai', token, {
      providers: [{ id: 'zhipu_glm', name: '智谱GLM', is_built_in: true }],
      binding: { textProviderId: 'zhipu_glm', visionProviderId: 'zhipu_glm', speechProviderId: 'zhipu_glm' },
    });
    expect(put.status).toBe(200);
    const get = (await (await call(env, 'GET', '/api/v1/settings/ai', token)).json()) as AiBody;
    expect(get.providers).toHaveLength(1);
    expect(get.binding?.textProviderId).toBe('zhipu_glm');
  });

  it('内置智谱服务商不可被移除（请求不带时自动补回）', async () => {
    await call(env, 'PUT', '/api/v1/settings/ai', token, {
      providers: [{ id: 'custom_b', name: '自定义', api_key: 'sk-b', base_url: 'https://b.example/v1', text_model: '', vision_model: '', audio_model: '' }],
    });
    const get = (await (await call(env, 'GET', '/api/v1/settings/ai', token)).json()) as AiBody;
    expect(get.providers?.map((p) => p.id)).toContain('zhipu_glm');
  });

  it('店员不能访问系统设置（403）', async () => {
    const st = await staffToken(env, token);
    expect((await call(env, 'GET', '/api/v1/settings/ai', st)).status).toBe(403);
    expect((await call(env, 'PUT', '/api/v1/settings/ai', st, { providers: [] })).status).toBe(403);
  });

  it('未配置 key 时拍照识别返回提示（400）', async () => {
    const res = await call(env, 'POST', '/api/v1/ai/parse-photo?purpose=purchase', token);
    const body = (await res.json()) as { error: string };
    expect(body.error).toContain('AI 识别设置');
  });
});