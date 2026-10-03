/** JWT 认证中间件：校验 Authorization: Bearer <token>，注入 c.set('user')。
 *  附带设备心跳：任何带 x-device-id 的认证请求都会节流更新该设备 last_active_at
 *  （设备"在线"判定依赖此字段——只靠登录/进设备页更新会让活跃设备显示离线）。 */

import type { MiddlewareHandler } from 'hono';
import { verifyTokenFull } from '../lib/jwt';
import type { AuthUser, Env } from '../types';

/** 设备心跳节流表（每设备 60s 内最多写一次，避免高频接口打爆 D1 写） */
const deviceLastWrite = new Map<string, number>();

/** 从请求识别平台/端名（与 routes/devices.ts deviceFromRequest 同规则，内联避免循环依赖） */
function platformOf(c: { req: { header(name: string): string | undefined } }): string {
  const ua = (c.req.header('user-agent') ?? '').toLowerCase();
  const client = c.req.header('x-client') ?? '';
  if (ua.includes('android')) return 'Android';
  if (ua.includes('iphone') || ua.includes('ipad')) return 'iOS';
  if (client.includes('miniprogram') || ua.includes('micromessenger')) return '小程序';
  return client.includes('web') || !/dart/.test(ua) ? 'Web' : 'App';
}

/** 认证通过后刷新设备最后活跃（失败静默，不影响主流程） */
function heartbeat(c: Parameters<MiddlewareHandler<{ Bindings: Env; Variables: { user: AuthUser } }>>[0], userId: string) {
  const deviceId = c.req.header('x-device-id') ?? '';
  if (!deviceId) return;
  const now = Date.now();
  const last = deviceLastWrite.get(deviceId) ?? 0;
  if (now - last < 60_000) return;
  deviceLastWrite.set(deviceId, now);
  const platform = platformOf(c);
  const ip = c.req.header('CF-Connecting-IP') ?? c.req.header('x-forwarded-for') ?? '';
  const ver = c.req.header('x-app-version') ?? '';
  c.executionCtx.waitUntil(
    c.env.DB.prepare(
      `INSERT INTO devices (id, user_id, device_name, platform, ip, version)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET last_active_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'),
         ip = COALESCE(?, ip), version = COALESCE(?, version)`,
    ).bind(deviceId, userId, `${platform}端`, platform, ip || null, ver || null, ip || null, ver || null).run().catch(() => {}),
  );
}

export const authMiddleware = (): MiddlewareHandler<{ Bindings: Env; Variables: { user: AuthUser } }> => {
  return async (c, next) => {
    const header = c.req.header('Authorization');
    if (!header?.startsWith('Bearer ')) {
      return c.json({ error: '未登录' }, 401);
    }
    const r = await verifyTokenFull(c.env.JWT_SECRET, header.slice(7));
    if (!r.ok) {
      // access 过期返回特定码 token_expired：前端 api 层识别后走静默刷新（换新 access 重放原请求）；
      // 无效/被篡改直接视为未登录（不触发刷新，避免死循环）
      if (r.expired) return c.json({ error: '登录已过期，请重新登录', code: 'token_expired' }, 401);
      return c.json({ error: '登录已过期，请重新登录' }, 401);
    }
    const payload = r.payload;
    c.set('user', { id: payload.sub, username: payload.username, role: payload.role });
    heartbeat(c, payload.sub);
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