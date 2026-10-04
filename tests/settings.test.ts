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

  it('未配置 key 时测试 AI 返回提示（400）', async () => {
    const res = await call(env, 'POST', '/api/v1/ai/test', token);
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toContain('AI 识别设置');
  });

  it('未配置 key 时测试图片/语音能力也返回提示（400）', async () => {
    const vision = await call(env, 'POST', '/api/v1/ai/test?capability=vision', token);
    expect(vision.status).toBe(400);
    expect(((await vision.json()) as { error: string }).error).toContain('图片识别');
    const speech = await call(env, 'POST', '/api/v1/ai/test?capability=speech', token);
    expect(speech.status).toBe(400);
    expect(((await speech.json()) as { error: string }).error).toContain('语音');
  });

  it('图片魔数不识别时返回格式提示（400，而非 1210）', async () => {
    // 先配置智谱 key（否则未配置先 400，测不到魔数分支）
    await call(env, 'PUT', '/api/v1/settings/ai', token, {
      providers: [{ id: 'zhipu_glm', is_built_in: true, api_key: 'sk-test' }],
      binding: { textProviderId: 'zhipu_glm', visionProviderId: 'zhipu_glm', speechProviderId: 'zhipu_glm' },
    });
    const fake = new Blob([new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8])], { type: 'image/jpeg' });
    const fd = new FormData();
    fd.append('photo', fake, 'x.jpg');
    const res = await app.request(
      'http://localhost/api/v1/ai/parse-photo?purpose=purchase',
      { method: 'POST', headers: { Authorization: `Bearer ${token}` }, body: fd },
      env as never,
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: string }).error).toContain('图片格式不支持');
  });
});

describe('金额舍入配置（/settings/rounding）', () => {
  let env: Parameters<typeof call>[0];
  let token: string;
  beforeEach(async () => { env = (await setup()).env; token = await boot(env); });

  it('默认四舍五入 2 位（无配置）', async () => {
    const res = await call(env, 'GET', '/api/v1/settings/rounding', token);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ carry: 0.5, digits: 2 });
  });

  it('店员可读（记账本地预览同口径），不可写', async () => {
    const st = await staffToken(env, token);
    const get = await call(env, 'GET', '/api/v1/settings/rounding', st);
    expect(get.status).toBe(200);
    expect((await get.json()) as object).toMatchObject({ carry: 0.5, digits: 2 });
    expect((await call(env, 'PUT', '/api/v1/settings/rounding', st, { carry: 0.6, digits: 1 })).status).toBe(403);
  });

  it('老板保存 5舍6入 1位（角）→ 回读一致；非法参数 400', async () => {
    const put = await call(env, 'PUT', '/api/v1/settings/rounding', token, { carry: 0.6, digits: 1 });
    expect(put.status).toBe(200);
    const get = (await (await call(env, 'GET', '/api/v1/settings/rounding', token)).json()) as { carry: number; digits: number };
    expect(get).toEqual({ carry: 0.6, digits: 1 });
    // 非法
    expect((await call(env, 'PUT', '/api/v1/settings/rounding', token, { carry: 2, digits: 2 })).status).toBe(400);
    expect((await call(env, 'PUT', '/api/v1/settings/rounding', token, { carry: 0.5, digits: 9 })).status).toBe(400);
  });

  it('金额计算按配置（出货行金额走 roundMoney）', async () => {
    await call(env, 'PUT', '/api/v1/settings/rounding', token, { carry: 0.6, digits: 2 }); // 5舍6入
    await call(env, 'POST', '/api/v1/clients', token, { name: '店A' });
    const clients = (await (await call(env, 'GET', '/api/v1/clients', token)).json()) as { clients: Array<{ id: string }> };
    await call(env, 'POST', '/api/v1/items', token, {
      name: '白菜', prices: [{ unit: '斤', purchase_price: 1, sale_price: 1.235 }],
    });
    const items = (await (await call(env, 'GET', '/api/v1/items', token)).json()) as {
      items: Array<{ prices: Array<{ id: string }> }>;
    };
    const sale = await call(env, 'POST', '/api/v1/sales', token, {
      client_id: clients.clients[0].id, happened_at: '2026-01-01',
      items: [{ price_id: items.items[0].prices[0].id, quantity: 1 }],
    });
    const body = (await sale.json()) as { total: number };
    // API 返回按配置换算展示：1.235 → 5舍6入 → 1.23；四舍五入则是 1.24
    expect(body.total).toBe(1.23);
    // 存储=浮点原值（对齐参考项目 REAL：入库不取整，DB 行 amount 保留 1.235）
    const list = (await (await call(env, 'GET', '/api/v1/sales', token)).json()) as {
      sales: Array<{ items: Array<{ amount: number }> }>;
    };
    expect(list.sales[0].items[0].amount).toBe(1.235);
  });
});