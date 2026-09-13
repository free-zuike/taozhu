/** 用户级配置：下载源跨端同步（Web 设置 App 可读）+ 服务器端下载源探测（Web 浏览器不能跨域 HEAD GitHub） */
import { Hono } from 'hono';
import { authMiddleware } from '../middleware/auth';
import { APP_VERSION } from '../version';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const meRouter = new Hono<{ Bindings: Env; Variables: V }>();

meRouter.use('*', authMiddleware());

const KEY_PREFIX = 'download_sources:';

/** 官方 release 下载基址（探测/下载共用）：universal APK 资产恒存在 */
const officialAsset = (ver: string) =>
  `https://github.com/free-zuike/taozhu/releases/download/taozhu-v${ver}/taozhu-app-${ver}.apk`;

/** 安装包最小可信大小：小于该值视为被代理/中间层拦截（返回 HTML 拦截页而非安装包） */
const MIN_TRUSTED_BYTES = 1048576;

// GET /me/download-sources — 当前用户的自定义下载源（null=从未设置过；[]=已清空）
meRouter.get('/download-sources', async (c) => {
  const key = `${KEY_PREFIX}${c.get('user').id}`;
  const row = await c.env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind(key).first<{ value: string }>();
  if (!row?.value) return c.json({ sources: null });
  try {
    const d = JSON.parse(row.value);
    return c.json({ sources: Array.isArray(d) ? d : null });
  } catch {
    return c.json({ sources: null });
  }
});

// PUT /me/download-sources — 保存当前用户的自定义下载源（body: { sources: [{url, enabled}] }，最多 20 条）
meRouter.put('/download-sources', async (c) => {
  const body = await c.req.json().catch(() => null) as { sources?: unknown } | null;
  const list = Array.isArray(body?.sources) ? body.sources : [];
  const clean = list
    .filter((s): s is { url: string; enabled?: boolean } =>
      !!s && typeof s === 'object' && typeof (s as { url?: unknown }).url === 'string')
    .slice(0, 20)
    .map((s) => ({ url: (s.url as string).trim().slice(0, 500), enabled: s.enabled === true }));
  const key = `${KEY_PREFIX}${c.get('user').id}`;
  await c.env.DB.prepare(
    'INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
  ).bind(key, JSON.stringify(clean)).run();
  return c.json({ sources: clean });
});

// POST /me/probe-source — 服务器端探测下载前缀（拼上官方 universal 资产做 HEAD，返回耗时与大小）
meRouter.post('/probe-source', async (c) => {
  const body = await c.req.json().catch(() => null) as { prefix?: string } | null;
  const prefix = (body?.prefix ?? '').trim().slice(0, 500);
  if (prefix && !/^https?:\/\//.test(prefix)) return c.json({ error: '前缀需以 http(s):// 开头' }, 400);
  const url = `${prefix}${officialAsset(APP_VERSION)}`;
  const t0 = Date.now();
  try {
    const res = await fetch(url, {
      method: 'HEAD',
      headers: { Range: 'bytes=0-0', 'User-Agent': 'Mozilla/5.0' },
      signal: AbortSignal.timeout(10000),
    });
    const ms = Date.now() - t0;
    const size = Number(res.headers.get('content-length') ?? 0);
    const ok = (res.status === 200 || res.status === 206) && size >= MIN_TRUSTED_BYTES;
    return c.json({ ok, ms, status: res.status, size });
  } catch {
    return c.json({ ok: false, ms: Date.now() - t0, status: 0, size: 0 });
  }
});