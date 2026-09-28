/** 登录设备管理：登录时 upsert 设备（名称/平台/最后活跃），设备页可查看/删除。
 *  删除设备 = 从设备列表移除（下次该设备登录重新记录）；仅老板可管理。 */
import { Hono } from 'hono';
import { adminOnly, authMiddleware } from '../middleware/auth';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const devicesRouter = new Hono<{ Bindings: Env; Variables: V }>();
devicesRouter.use('*', authMiddleware(), adminOnly());

/// 设备每台上报（前端 x-device-id 设备唯一 id）：同一台设备归并刷新 IP/版本/最后活跃；平台+端名作显示名
export async function upsertDevice(
  db: D1Database,
  userId: string,
  deviceId: string,
  deviceName: string,
  platform: string,
  ip?: string,
  version?: string,
): Promise<void> {
  const id = deviceId || `dev_${userId}_${deviceName}_${platform}`.replace(/[^a-zA-Z0-9_\-]/g, '_').slice(0, 80);
  await db.prepare(
    `INSERT INTO devices (id, user_id, device_name, platform, ip, version) VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET last_active_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'),
       ip = COALESCE(?, ip), version = COALESCE(?, version)`,
  ).bind(id, userId, deviceName, platform, ip ?? null, version ?? null, ip ?? null, version ?? null).run();
}

/** 从请求识别平台/端名（UA + x-client 头） */
export function deviceFromRequest(c: { req: { header(name: string): string | undefined } }): { platform: string; deviceName: string } {
  const ua = (c.req.header('user-agent') ?? '').toLowerCase();
  const client = c.req.header('x-client') ?? '';
  const platform = ua.includes('android')
    ? 'Android'
    : ua.includes('iphone') || ua.includes('ipad')
      ? 'iOS'
      : client.includes('miniprogram') || ua.includes('micromessenger')
        ? '小程序'
        : client.includes('web') || !/dart/.test(ua)
          ? 'Web'
          : 'App';
  return { platform, deviceName: `${platform}端` };
}

// GET /devices — 当前账号登录设备列表（倒序：最近活跃在前）；进入即记录当前设备（老会话无登录记录也可见）
devicesRouter.get('/', async (c) => {
  const { id } = c.get('user');
  const dev = deviceFromRequest(c);
  const ip = c.req.header('CF-Connecting-IP') ?? c.req.header('x-forwarded-for') ?? '';
  const ver = c.req.header('x-app-version') ?? '';
  await upsertDevice(c.env.DB, id, c.req.header('x-device-id') ?? '', dev.deviceName, dev.platform, ip, ver).catch(() => {});
  const rows = await c.env.DB.prepare(
    'SELECT id, device_name, platform, ip, version, last_active_at, created_at FROM devices WHERE user_id = ? ORDER BY last_active_at DESC',
  ).bind(id).all();
  return c.json({ devices: rows.results });
});

// DELETE /devices/:id — 删除设备（仅本人设备；删除登录设备记录）
devicesRouter.delete('/:id', async (c) => {
  const { id: userId } = c.get('user');
  const devId = c.req.param('id');
  const r = await c.env.DB.prepare('DELETE FROM devices WHERE id = ? AND user_id = ?')
    .bind(devId, userId).run();
  if ((r.meta.changes ?? 0) === 0) return c.json({ error: '设备不存在' }, 404);
  return c.json({ ok: true });
});