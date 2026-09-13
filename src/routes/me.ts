/** 用户级配置：下载源跨端同步（Web 设置 App 可读）+ 服务器端下载源探测（Web 浏览器不能跨域 HEAD GitHub） */
import { Hono } from 'hono';
import { authMiddleware } from '../middleware/auth';
import { notifyClients } from '../services/sync-hub';
import { APP_VERSION } from '../version';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const meRouter = new Hono<{ Bindings: Env; Variables: V }>();

meRouter.use('*', authMiddleware());

/// 下载源为全局配置（Web/App/任意账号共享同一份；小商户场景按账号隔离反而"设置不生效"）
const KEY_SOURCES = 'download_sources';

/** 默认镜像列表（服务器下发，App/Web 管理页可见可删改，不写死在前端）
 *  官方直连在国内网络多数不可达，镜像为更新下载的主要通道；默认停用、用户测试后启用或指定 */
const DEFAULT_SOURCES = [
  { url: 'https://ghfast.top/', enabled: false },
  { url: 'https://gh-proxy.com/', enabled: false },
  { url: 'https://githubproxy.cc/', enabled: false },
  { url: 'https://ghproxy.homeboyc.cn/', enabled: false },
  { url: 'https://gh.ddlc.top/', enabled: false },
];

interface SourceCfg { sources: Array<{ url: string; enabled: boolean }>; specified: string }

/** 官方 release 下载基址（探测/下载共用）：universal APK 资产恒存在 */
const officialAsset = (ver: string) =>
  `https://github.com/free-zuike/taozhu/releases/download/taozhu-v${ver}/taozhu-app-${ver}.apk`;

/** 安装包最小可信大小：小于该值视为被代理/中间层拦截（返回 HTML 拦截页而非安装包） */
const MIN_TRUSTED_BYTES = 1048576;

// GET /me/download-sources — 全局下载源（从未设置过返回默认镜像列表，可删改后保存）
meRouter.get('/download-sources', async (c) => {
  const row = await c.env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind(KEY_SOURCES).first<{ value: string }>();
  let cfg: SourceCfg = { sources: DEFAULT_SOURCES, specified: '' };
  if (row?.value) {
    try {
      const d = JSON.parse(row.value) as unknown;
      if (Array.isArray(d)) {
        cfg = { sources: d as Array<{ url: string; enabled: boolean }>, specified: '' };
      } else if (d && typeof d === 'object' && Array.isArray((d as SourceCfg).sources)) {
        cfg = { sources: (d as SourceCfg).sources, specified: typeof (d as SourceCfg).specified === 'string' ? (d as SourceCfg).specified : '' };
      }
    } catch {
      // 解析失败：回退默认
    }
  }
  return c.json({ sources: cfg.sources, specified: cfg.specified });
});

// PUT /me/download-sources — 保存全局下载源（body: { sources: [{url, enabled}], specified? }，最多 20 条）
meRouter.put('/download-sources', async (c) => {
  const body = await c.req.json().catch(() => null) as { sources?: unknown; specified?: unknown } | null;
  const list = Array.isArray(body?.sources) ? body.sources : [];
  const clean = list
    .filter((s): s is { url: string; enabled?: boolean } =>
      !!s && typeof s === 'object' && typeof (s as { url?: unknown }).url === 'string')
    .slice(0, 20)
    .map((s) => ({ url: (s.url as string).trim().slice(0, 500), enabled: s.enabled === true }));
  // 指定源必须存在于列表中，否则落空（'' = 未指定，官方直连优先）
  const specified = typeof body?.specified === 'string' && clean.some((s) => s.url === body!.specified)
    ? body!.specified.slice(0, 500)
    : '';
  await c.env.DB.prepare(
    'INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
  ).bind(KEY_SOURCES, JSON.stringify({ sources: clean, specified })).run();
  // 下载源变更实时推送：其他在线端（App/Web）收到后重新拉取全局配置
  await notifyClients();
  return c.json({ sources: clean, specified });
});

// POST /me/probe-source — 服务器端探测下载前缀（拼上官方 universal 资产做 HEAD，返回耗时与大小）
meRouter.post('/probe-source', async (c) => {
  const body = await c.req.json().catch(() => null) as { prefix?: string } | null;
  const prefix = (body?.prefix ?? '').trim().slice(0, 500);
  if (prefix && !/^https?:\/\//.test(prefix)) return c.json({ error: '前缀需以 http(s):// 开头' }, 400);
  const url = `${prefix}${officialAsset(APP_VERSION)}`;
  const t0 = Date.now();
  try {
    // GET + Range 前 1KB：镜像普遍拒绝 HEAD 或 HEAD 不带 Content-Length，GET 与真实下载同一路径；
    // 用 Content-Range 总大小 ≥ 1MB 判定（206 时 Content-Length 只是 Range 段长，拦截页仍会被识别）
    const res = await fetch(url, {
      method: 'GET',
      headers: { Range: 'bytes=0-1023', 'User-Agent': 'Mozilla/5.0' },
      signal: AbortSignal.timeout(10000),
    });
    const ms = Date.now() - t0;
    let total = -1;
    const cr = res.headers.get('content-range');
    if (cr) {
      const slash = cr.lastIndexOf('/');
      if (slash >= 0) total = Number(cr.slice(slash + 1).trim());
      if (!Number.isFinite(total)) total = -1;
    }
    const len = Number(res.headers.get('content-length') ?? 0);
    const size = total >= 0 ? total : (res.status === 200 ? len : -1);
    const ok = (res.status === 200 || res.status === 206) && size >= MIN_TRUSTED_BYTES;
    await res.arrayBuffer().catch(() => null); // 释放连接（Range 仅 1KB）
    return c.json({ ok, ms, status: res.status, size });
  } catch {
    return c.json({ ok: false, ms: Date.now() - t0, status: 0, size: 0 });
  }
});