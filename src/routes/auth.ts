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

// GET /auth/latest-version — 检查更新（无鉴权）：Workers 代查 GitHub Release 最新版本。
// App/Web/小程序直连 api.github.com 在国内网络常被干扰（404/超时），走自己服务器更稳。
// 实现：请求 github.com/releases/latest 的 302 重定向，从 Location 解析版本号——
//   GitHub API 对共享出口 IP 限流严格（403），HTML 重定向宽松得多。
// GitHub 不可达时 latest 为空串，前端给出手动跳转兜底。
authRouter.get('/latest-version', async (c) => {
  let latest = '';
  try {
    const res = await Promise.race([
      fetch('https://github.com/free-zuike/taozhu/releases/latest', {
        headers: { 'User-Agent': 'Mozilla/5.0 taozhu-worker', Accept: 'text/html' },
        redirect: 'manual',
      }),
      new Promise<never>((_, rej) => setTimeout(() => rej(new Error('github timeout')), 5000)),
    ]);
    if (res.status === 302) {
      const loc = res.headers.get('location') ?? '';
      const tag = loc.split('/').pop() ?? '';
      latest = tag.replace(/^taozhu-v/, '');
    }
  } catch {
    latest = '';
  }
  return c.json({ current: APP_VERSION, latest });
});

// 统计系统是否已初始化（前端引导页判断）
authRouter.get('/bootstrap/status', async (c) => {
  const row = await c.env.DB.prepare('SELECT COUNT(*) as cnt FROM users').first<{ cnt: number }>();
  return c.json({ initialized: (row?.cnt ?? 0) > 0 });
});