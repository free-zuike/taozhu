/** JWT 认证中间件：校验 Authorization: Bearer <token>，注入 c.set('user') */

import type { MiddlewareHandler } from 'hono';
import { verifyToken } from '../lib/jwt';
import type { AuthUser, Env } from '../types';

export const authMiddleware = (): MiddlewareHandler<{ Bindings: Env; Variables: { user: AuthUser } }> => {
  return async (c, next) => {
    const header = c.req.header('Authorization');
    if (!header?.startsWith('Bearer ')) {
      return c.json({ error: '未登录' }, 401);
    }
    const payload = await verifyToken(c.env.JWT_SECRET, header.slice(7));
    if (!payload) {
      return c.json({ error: '登录已过期，请重新登录' }, 401);
    }
    c.set('user', { id: payload.sub, username: payload.username, role: payload.role });
    await next();
  };
};

/** 仅管理员可用 */
export const adminOnly = (): MiddlewareHandler<{ Bindings: Env; Variables: { user: AuthUser } }> => {
  return async (c, next) => {
    const user = c.get('user');
    if (user.role !== 'admin') {
      return c.json({ error: '仅老板账号可操作' }, 403);
    }
    await next();
  };
};