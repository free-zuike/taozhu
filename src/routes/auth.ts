/** 认证端点：登录 / 当前用户 / 首次管理员引导 */
import { Hono } from 'hono';
import { signToken } from '../lib/jwt';
import { hashPassword, randomId, verifyPassword } from '../lib/password';
import { authMiddleware } from '../middleware/auth';
import { APP_NAME, APP_VERSION } from '../version';
import type { Env, UserRow } from '../types';

export const authRouter = new Hono<{ Bindings: Env; Variables: { user: UserRow } }>();

const nowIso = () => new Date().toISOString();

// POST /auth/bootstrap — 仅当系统无任何用户时可用，创建第一个老板账号
authRouter.post('/bootstrap', async (c) => {
  const db = c.env.DB;
  const row = await db.prepare('SELECT COUNT(*) as cnt FROM users').first<{ cnt: number }>();
  if ((row?.cnt ?? 0) > 0) return c.json({ error: '系统已初始化' }, 409);

  const body = await c.req.json().catch(() => null) as { username?: string; password?: string } | null;
  const username = body?.username?.trim();
  const password = body?.password;
  if (!username || !password) return c.json({ error: '请输入登录名和密码' }, 400);
  if (password.length < 6) return c.json({ error: '密码至少 6 位' }, 400);

  const id = randomId();
  const passwordHash = await hashPassword(password);
  await db.prepare('INSERT INTO users (id, username, password_hash, role) VALUES (?, ?, ?, ?)')
    .bind(id, username, passwordHash, 'admin').run();
  const token = await signToken(c.env.JWT_SECRET, { sub: id, username, role: 'admin' });
  return c.json({ token, user: { id, username, role: 'admin' } }, 201);
});

// POST /auth/login
authRouter.post('/login', async (c) => {
  const body = await c.req.json().catch(() => null) as { username?: string; password?: string } | null;
  const username = body?.username?.trim() ?? '';
  const password = body?.password ?? '';
  if (!username || !password) return c.json({ error: '请输入登录名和密码' }, 400);

  const user = await c.env.DB.prepare('SELECT * FROM users WHERE username = ?').bind(username).first<UserRow>();
  if (!user || !(await verifyPassword(password, user.password_hash))) {
    return c.json({ error: '用户名或密码错误' }, 401);
  }
  const token = await signToken(c.env.JWT_SECRET, { sub: user.id, username: user.username, role: user.role });
  return c.json({ token, user: { id: user.id, username: user.username, role: user.role } });
});

// GET /auth/me
authRouter.get('/me', authMiddleware(), async (c) => {
  const u = c.get('user');
  return c.json({ user: u });
});

// GET /auth/ping — 部署探活（无需认证）
authRouter.get('/ping', (c) => c.json({ ok: true, now: nowIso(), app: APP_NAME, version: APP_VERSION }));

// GET /auth/latest-version — 检查更新（无鉴权）：多源探测 + 短缓存。
// 源1 GitHub Release API（权威，可确认资产就绪）；源2 部署时生成的 /latest.json（本域静态，零网络依赖）；
// 源3 jsDelivr CDN 镜像读取仓库版本文件（GitHub API 不可达时的兜底，国内可达性好）。
// 返回 ready=false 表示该版本 release 已创建但安装包（CI 构建）尚未就绪——前端应提示"构建中"而非引导下载。
// 全部失败返回 latest=''，前端手动兜底。60 秒内复用成功结果（构建中→就绪切换更及时）。
let latestCache: { at: number; latest: string; ready: boolean; notes: string } | null = null;
const LATEST_CACHE_MS = 60 * 1000;

interface VersionProbe {
  v: string;
  ready: boolean;
  notes?: string;
}

authRouter.get('/latest-version', async (c) => {
  const now = Date.now();
  if (latestCache && now - latestCache.at < LATEST_CACHE_MS) {
    return c.json({
      current: APP_VERSION,
      latest: latestCache.latest,
      ready: latestCache.ready,
      notes: latestCache.notes,
    });
  }
  const checkGitHub = async (): Promise<VersionProbe | null> => {
    try {
      const res = await fetch('https://api.github.com/repos/free-zuike/taozhu/releases/latest', {
        headers: { 'User-Agent': 'taozhu-worker', Accept: 'application/vnd.github+json' },
        signal: AbortSignal.timeout(6000),
      });
      if (!res.ok) return null;
      const d = (await res.json()) as {
        tag_name?: string;
        assets?: Array<{ name?: string }>;
        body?: string;
      };
      const v = String(d.tag_name ?? '').replace(/^taozhu-v/, '');
      if (!v) return null;
      // 安装包资产（flutter-app-<ver>.apk）已上传才算就绪，否则是 CI 构建中的空 release
      const assets = d.assets ?? [];
      const ready = assets.some((a) => a.name === `flutter-app-${v}.apk`);
      return { v, ready, notes: d.body ?? '' };
    } catch {
      return null;
    }
  };
  // 备源（latest.json / jsDelivr）无法验证安装包资产，保守返回 ready=false——
  // 避免误报"可下载"导致下载失败；GitHub 可达时以 GitHub 资产检测为准
  const probeVer = (v: string): VersionProbe | null => (v ? { v, ready: false } : null);
  const checkAsset = async (): Promise<VersionProbe | null> => {
    try {
      const r = await c.env.ASSETS.fetch(new Request(new URL('/latest.json', c.req.url)));
      if (!r.ok) return null;
      const d = (await r.json()) as { version?: string };
      return probeVer(String(d.version ?? '').trim());
    } catch {
      return null;
    }
  };
  const checkJsDelivr = async (): Promise<VersionProbe | null> => {
    try {
      const res = await fetch('https://fastly.jsdelivr.net/gh/free-zuike/taozhu@main/frontend-flutter/lib/version.dart', {
        signal: AbortSignal.timeout(6000),
      });
      if (!res.ok) return null;
      const m = /APP_VERSION = '([^']+)'/.exec(await res.text());
      return probeVer(m?.[1] ?? '');
    } catch {
      return null;
    }
  };
  for (const check of [checkGitHub, checkAsset, checkJsDelivr]) {
    const r = await check();
    if (r) {
      latestCache = { at: now, latest: r.v, ready: r.ready, notes: r.notes ?? '' };
      return c.json({ current: APP_VERSION, latest: r.v, ready: r.ready, notes: r.notes ?? '' });
    }
  }
  return c.json({ current: APP_VERSION, latest: '', ready: false, notes: '' });
});

// 统计系统是否已初始化（前端引导页判断）
authRouter.get('/bootstrap/status', async (c) => {
  const row = await c.env.DB.prepare('SELECT COUNT(*) as cnt FROM users').first<{ cnt: number }>();
  return c.json({ initialized: (row?.cnt ?? 0) > 0 });
});