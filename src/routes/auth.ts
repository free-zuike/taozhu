/** 认证端点：登录 / 当前用户 / 首次管理员引导 / 个人资料（改名/改密/头像）/ 两步验证（TOTP） */
import { Hono } from 'hono';
import { signToken } from '../lib/jwt';
import { hashPassword, randomId, verifyPassword } from '../lib/password';
import { randomSecret, verifyTotp } from '../lib/totp';
import { authMiddleware } from '../middleware/auth';
import { createStorage } from '../services/storage';
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
  // 显示名默认取登录账号 @ 前部分（无 @ 取全名）
  const displayName = username.includes('@') ? username.split('@')[0] : username;
  await db.prepare('INSERT INTO users (id, username, display_name, password_hash, role) VALUES (?, ?, ?, ?, ?)')
    .bind(id, username, displayName, passwordHash, 'admin').run();
  const token = await signToken(c.env.JWT_SECRET, { sub: id, username, role: 'admin' });
  return c.json({ token, user: { id, username, display_name: displayName, role: 'admin' } }, 201);
});

// POST /auth/login
authRouter.post('/login', async (c) => {
  const body = await c.req.json().catch(() => null) as { username?: string; password?: string; code?: string } | null;
  const username = body?.username?.trim() ?? '';
  const password = body?.password ?? '';
  if (!username || !password) return c.json({ error: '请输入登录名和密码' }, 400);

  const user = await c.env.DB.prepare('SELECT * FROM users WHERE username = ?').bind(username).first<UserRow>();
  if (!user || !(await verifyPassword(password, user.password_hash))) {
    return c.json({ error: '用户名或密码错误' }, 401);
  }
  // 两步验证：已开启且未带验证码 → 返回 need_totp 让前端补输入（密码已校验，不额外暴露信息）
  if (user.totp_enabled) {
    if (!body?.code) return c.json({ need_totp: true });
    if (!(await verifyTotp(user.totp_secret ?? '', body.code))) {
      return c.json({ error: '两步验证码错误' }, 401);
    }
  }
  const token = await signToken(c.env.JWT_SECRET, { sub: user.id, username: user.username, role: user.role });
  return c.json({ token, user: { id: user.id, username: user.username, role: user.role } });
});

// GET /auth/me — 当前用户（登录账号/显示名/头像/两步验证；实时查库）
authRouter.get('/me', authMiddleware(), async (c) => {
  const u = c.get('user');
  const row = await c.env.DB.prepare(
    'SELECT id, username, display_name, role, avatar, totp_enabled FROM users WHERE id = ?',
  ).bind(u.id).first<{
    id: string; username: string; display_name: string | null; role: string; avatar: string | null; totp_enabled: number;
  }>();
  if (!row) return c.json({ error: '账号不存在' }, 404);
  return c.json({ user: row });
});

// PATCH /auth/profile — 自助修改显示名/密码（本人）。
// 登录账号（username）不可更改；改密码需旧密码。
authRouter.patch('/profile', authMiddleware(), async (c) => {
  const me = c.get('user');
  const body = await c.req.json().catch(() => null) as
    { display_name?: string; old_password?: string; password?: string } | null;
  const row = await c.env.DB.prepare('SELECT * FROM users WHERE id = ?').bind(me.id).first<UserRow>();
  if (!row) return c.json({ error: '账号不存在' }, 404);

  let displayName = row.display_name || row.username;
  if (body?.display_name !== undefined) {
    const dn = body.display_name.trim();
    if (dn.length < 1 || dn.length > 30) return c.json({ error: '用户名长度需在 1-30 个字符' }, 400);
    displayName = dn;
  }
  let passwordHash = row.password_hash;
  if (body?.password) {
    if (!body.old_password || !(await verifyPassword(body.old_password, row.password_hash))) {
      return c.json({ error: '旧密码不正确' }, 400);
    }
    if (body.password.length < 6) return c.json({ error: '密码至少 6 位' }, 400);
    passwordHash = await hashPassword(body.password);
  }
  await c.env.DB.prepare('UPDATE users SET display_name = ?, password_hash = ? WHERE id = ?')
    .bind(displayName, passwordHash, me.id).run();
  return c.json({ user: { id: me.id, username: row.username, display_name: displayName, role: row.role } });
});

// GET /auth/totp/setup — 获取两步验证密钥（未开启时；已生成过则复用，便于确认前重看）
authRouter.get('/totp/setup', authMiddleware(), async (c) => {
  const me = c.get('user');
  const row = await c.env.DB.prepare('SELECT username, totp_secret, totp_enabled FROM users WHERE id = ?')
    .bind(me.id).first<{ username: string; totp_secret: string | null; totp_enabled: number }>();
  if (!row) return c.json({ error: '账号不存在' }, 404);
  if (row.totp_enabled) return c.json({ error: '两步验证已开启' }, 409);
  let secret = row.totp_secret;
  if (!secret) {
    secret = randomSecret();
    await c.env.DB.prepare('UPDATE users SET totp_secret = ? WHERE id = ?').bind(secret, me.id).run();
  }
  const uri = `otpauth://totp/taozhu:${encodeURIComponent(row.username)}?secret=${secret}&issuer=taozhu&period=30&digits=6&algorithm=SHA1`;
  return c.json({ secret, otpauth: uri });
});

// POST /auth/totp/confirm — 输入验证码开启两步验证
authRouter.post('/totp/confirm', authMiddleware(), async (c) => {
  const me = c.get('user');
  const body = await c.req.json().catch(() => null) as { code?: string } | null;
  const row = await c.env.DB.prepare('SELECT totp_secret, totp_enabled FROM users WHERE id = ?')
    .bind(me.id).first<{ totp_secret: string | null; totp_enabled: number }>();
  if (!row) return c.json({ error: '账号不存在' }, 404);
  if (row.totp_enabled) return c.json({ error: '两步验证已开启' }, 409);
  if (!row.totp_secret) return c.json({ error: '请先获取验证密钥（重新打开两步验证开关）' }, 400);
  if (!(await verifyTotp(row.totp_secret, body?.code ?? ''))) {
    return c.json({ error: '验证码错误或已过期' }, 400);
  }
  await c.env.DB.prepare('UPDATE users SET totp_enabled = 1 WHERE id = ?').bind(me.id).run();
  return c.json({ ok: true });
});

// POST /auth/totp/disable — 输入验证码关闭两步验证
authRouter.post('/totp/disable', authMiddleware(), async (c) => {
  const me = c.get('user');
  const body = await c.req.json().catch(() => null) as { code?: string } | null;
  const row = await c.env.DB.prepare('SELECT totp_secret, totp_enabled FROM users WHERE id = ?')
    .bind(me.id).first<{ totp_secret: string | null; totp_enabled: number }>();
  if (!row) return c.json({ error: '账号不存在' }, 404);
  if (!row.totp_enabled) return c.json({ error: '两步验证未开启' }, 400);
  if (!(await verifyTotp(row.totp_secret ?? '', body?.code ?? ''))) {
    return c.json({ error: '验证码错误或已过期' }, 400);
  }
  await c.env.DB.prepare('UPDATE users SET totp_enabled = 0, totp_secret = NULL WHERE id = ?').bind(me.id).run();
  return c.json({ ok: true });
});

// POST /auth/avatar — 上传头像（multipart photo，存 R2；key 固定为 taozhu/images/avatars/{userId}.jpg）
authRouter.post('/avatar', authMiddleware(), async (c) => {
  const me = c.get('user');
  let file: File | null = null;
  try {
    const form = await c.req.formData();
    const f = form.get('photo');
    if (f && typeof f === 'object') file = f as unknown as File;
  } catch {
    return c.json({ error: '请以 multipart 上传 photo 字段（图片）' }, 400);
  }
  if (!file) return c.json({ error: '请选择图片上传' }, 400);
  if (file.size === 0 || file.size > 10 * 1024 * 1024) return c.json({ error: '图片过大（上限 10MB）' }, 400);
  const bytes = new Uint8Array(await file.arrayBuffer());
  const key = `taozhu/images/avatars/${me.id}.jpg`;
  await createStorage(c.env).put(key, bytes, file.type || 'image/jpeg');
  await c.env.DB.prepare('UPDATE users SET avatar = ? WHERE id = ?').bind(key, me.id).run();
  return c.json({ ok: true });
});

// GET /auth/avatar — 读取当前用户头像（带鉴权；前端 Image.network 加 Authorization 头）
authRouter.get('/avatar', authMiddleware(), async (c) => {
  const me = c.get('user');
  const row = await c.env.DB.prepare('SELECT avatar FROM users WHERE id = ?').bind(me.id).first<{ avatar: string | null }>();
  if (!row?.avatar) return c.json({ error: '未设置头像' }, 404);
  const obj = await createStorage(c.env).get(row.avatar);
  if (!obj) return c.json({ error: '头像不存在' }, 404);
  const headers = new Headers();
  headers.set('content-type', obj.contentType ?? 'image/jpeg');
  headers.set('Cache-Control', 'no-store');
  return new Response(obj.body, { headers });
});

// GET /auth/ping — 部署探活（无需认证）
authRouter.get('/ping', (c) => c.json({ ok: true, now: nowIso(), app: APP_NAME, version: APP_VERSION }));

// GET /auth/latest-version — 检查更新（无鉴权）：多源探测 + 短缓存。
// 源1 GitHub Release API（权威，可确认资产就绪）；源2 部署时生成的 /latest.json（本域静态，零网络依赖）；
// 源3 jsDelivr CDN 镜像读取仓库版本文件（GitHub API 不可达时的兜底，国内可达性好）。
// 返回 ready=false 表示该版本 release 已创建但安装包（CI 构建）尚未就绪——前端应提示"构建中"而非引导下载。
// 全部失败返回 latest=''，前端手动兜底。60 秒内复用成功结果（构建中→就绪切换更及时）。
let latestCache: { at: number; latest: string; ready: boolean; building: boolean; source: 'github' | 'backup'; notes: string } | null = null;
const LATEST_CACHE_MS = 60 * 1000;

interface VersionProbe {
  v: string;
  ready: boolean;
  building?: boolean;
  source: 'github' | 'backup'; // github=GitHub 实时确认（权威）；backup=备源兜底（无法确认安装文件）
  notes?: string;
}

authRouter.get('/latest-version', async (c) => {
  const now = Date.now();
  if (latestCache && now - latestCache.at < LATEST_CACHE_MS) {
    return c.json({
      current: APP_VERSION,
      latest: latestCache.latest,
      ready: latestCache.ready,
      building: latestCache.building ?? false,
      source: latestCache.source,
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
      // 语义：有安装文件才提示新版本。APK 资产存在 → 可更新；不存在 → 该版本不参与提示（返回 null，
      // 由后续源决定，前端最多提示"暂无可用更新"，绝不再报"构建中"）
      const assets = d.assets ?? [];
      // 拆包产物（flutter-app-{v}-{abi}.apk）任一存在即视为有安装文件；兼容旧版 universal 命名
      if (!assets.some((a) => String(a.name ?? '').startsWith(`flutter-app-${v}-`) && String(a.name ?? '').endsWith('.apk'))
          && !assets.some((a) => a.name === `flutter-app-${v}.apk`)) {
        return null;
      }
      return { v, ready: true, building: false, source: 'github', notes: d.body ?? '' };
    } catch {
      return null;
    }
  };
  // 备源（latest.json / jsDelivr）：无法验证安装文件是否存在 → ready=false（不提示可更新）且 source='backup'
  const probeVer = (v: string): VersionProbe | null =>
    v ? { v, ready: false, building: false, source: 'backup' } : null;
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
      latestCache = {
        at: now, latest: r.v, ready: r.ready, building: r.building ?? false,
        source: r.source, notes: r.notes ?? '',
      };
      return c.json({
        current: APP_VERSION,
        latest: r.v,
        ready: r.ready,
        building: r.building ?? false,
        source: r.source,
        notes: r.notes ?? '',
      });
    }
  }
  return c.json({ current: APP_VERSION, latest: '', ready: false, building: false, source: 'backup', notes: '' });
});

// 统计系统是否已初始化（前端引导页判断）
authRouter.get('/bootstrap/status', async (c) => {
  const row = await c.env.DB.prepare('SELECT COUNT(*) as cnt FROM users').first<{ cnt: number }>();
  return c.json({ initialized: (row?.cnt ?? 0) > 0 });
});