/**
 * 更新通道回归：正式通道只认 /releases/latest，预发布通道只认带 APK 资产的 prerelease。
 * 独立测试文件（vitest 模块隔离）避免 /auth/latest-version 的 60s 模块级缓存串用例。
 */
import { afterEach, describe, expect, it, vi } from 'vitest';
import app from '../src/index';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { createFakeD1, fakeAssets } from './helpers/fake-d1';
import { APP_VERSION } from '../src/version';

const BASE = 'http://localhost';

const stableRelease = {
  tag_name: 'taozhu-v0.17.504',
  prerelease: false,
  body: '正式版说明',
  assets: [{ name: 'taozhu-app-0.17.504.apk' }],
};
const previewRelease = {
  tag_name: 'taozhu-v0.17.505',
  prerelease: true,
  body: '预发布说明',
  assets: [{ name: 'taozhu-app-0.17.505-arm64-v8a.apk' }],
};

describe('版本接口更新通道（stable / preview）', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('正式通道只取 releases/latest；预发布通道只取带 APK 的 prerelease，缓存互不污染', async () => {
    const urls: string[] = [];
    vi.stubGlobal('fetch', async (input: RequestInfo | URL) => {
      const url = String(input);
      urls.push(url);
      if (url.includes('/releases?')) {
        return new Response(JSON.stringify([previewRelease, stableRelease]), { status: 200 });
      }
      if (url.includes('/releases/latest')) {
        return new Response(JSON.stringify(stableRelease), { status: 200 });
      }
      return new Response('', { status: 404 });
    });
    resetSchemaState();
    const db = await createFakeD1();
    await ensureSchema(db as never);
    const env = { DB: db, ASSETS: fakeAssets, JWT_SECRET: 'test-secret' };
    const req = (path: string) => app.request(`${BASE}${path}`, {}, env as never);

    const s = (await (await req('/api/v1/auth/latest-version')).json()) as {
      current: string; latest: string; channel: string; notes: string;
    };
    expect(s.current).toBe(APP_VERSION);
    expect(s.latest).toBe('0.17.504');
    expect(s.channel).toBe('stable');
    expect(s.notes).toBe('正式版说明');

    const p = (await (await req('/api/v1/auth/latest-version?channel=preview')).json()) as {
      latest: string; channel: string; notes: string; source: string;
    };
    expect(p.latest).toBe('0.17.505');
    expect(p.channel).toBe('preview');
    expect(p.notes).toBe('预发布说明');
    expect(p.source).toBe('github');
    expect(urls.some((u) => u.includes('/releases?per_page='))).toBe(true);
  });
});
