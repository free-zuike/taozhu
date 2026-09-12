/** 多用户账号管理（仅老板）：建店员 / 改角色密码 / 停用 */
import { Hono } from 'hono';
import { hashPassword, randomId } from '../lib/password';
import { authMiddleware, adminOnly } from '../middleware/auth';
import type { AuthUser, Env, UserRow } from '../types';

type V = { user: AuthUser };
export const usersRouter = new Hono<{ Bindings: Env; Variables: V }>();

usersRouter.use('*', authMiddleware(), adminOnly());

// GET /users — 账号列表（不含密码哈希）
usersRouter.get('/', async (c) => {
  const rows = await c.env.DB.prepare('SELECT id, username, display_name, role, created_at FROM users ORDER BY created_at').all();
  return c.json({ users: rows.results });
});

// POST /users — 新建账号（店员/老板）
usersRouter.post('/', async (c) => {
  const body = await c.req.json().catch(() => null) as { username?: string; password?: string; role?: string; display_name?: string } | null;
  const username = body?.username?.trim();
  const password = body?.password;
  if (!username) return c.json({ error: '登录名必填' }, 400);
  if (!password || password.length < 6) return c.json({ error: '密码至少 6 位' }, 400);
  const role = body?.role === 'admin' ? 'admin' : 'staff';
  const exists = await c.env.DB.prepare('SELECT id FROM users WHERE username = ?').bind(username).first();
  if (exists) return c.json({ error: '登录名已存在' }, 409);
  const id = randomId();
  // 显示名默认取登录账号 @ 前部分（无 @ 取全名）
  const displayName = body?.display_name?.trim() || (username.includes('@') ? username.split('@')[0] : username);
  await c.env.DB.prepare('INSERT INTO users (id, username, display_name, password_hash, role) VALUES (?, ?, ?, ?, ?)')
    .bind(id, username, displayName, await hashPassword(password), role).run();
  return c.json({ id, username, display_name: displayName, role }, 201);
});

// PATCH /users/:id — 改名/改显示名/改密码/改角色（老板不能降自己角色）
usersRouter.patch('/:id', async (c) => {
  const id = c.req.param('id');
  const me = c.get('user');
  const body = await c.req.json().catch(() => null) as
    { username?: string; display_name?: string; password?: string; role?: string } | null;
  const user = await c.env.DB.prepare('SELECT * FROM users WHERE id = ?').bind(id).first<UserRow>();
  if (!user) return c.json({ error: '账号不存在' }, 404);

  if (id === me.id) {
    if (body?.role && body.role !== 'admin') return c.json({ error: '不能降级自己的老板角色' }, 400);
  }
  const username = body?.username?.trim();
  if (username && username !== user.username) {
    const dup = await c.env.DB.prepare('SELECT id FROM users WHERE username = ? AND id != ?').bind(username, id).first();
    if (dup) return c.json({ error: '登录名已存在' }, 409);
  }
  const role = body?.role === 'admin' || body?.role === 'staff' ? body.role : user.role;
  const displayName = body?.display_name?.trim() || user.display_name || user.username;
  let sql = 'UPDATE users SET username = ?, role = ?, display_name = ?';
  const params: (string | number)[] = [username || user.username, role, displayName];
  if (body?.password) {
    if (body.password.length < 6) return c.json({ error: '密码至少 6 位' }, 400);
    sql += ', password_hash = ?';
    params.push(await hashPassword(body.password));
  }
  sql += ' WHERE id = ?';
  params.push(id);
  await c.env.DB.prepare(sql).bind(...params).run();
  return c.json({ id, username: username || user.username, display_name: displayName, role });
});

// DELETE /users/:id — 停用账号（不能删自己）
usersRouter.delete('/:id', async (c) => {
  const id = c.req.param('id');
  const me = c.get('user');
  if (id === me.id) return c.json({ error: '不能删除自己的账号' }, 400);
  await c.env.DB.prepare('DELETE FROM users WHERE id = ?').bind(id).run();
  return c.body(null, 204);
});