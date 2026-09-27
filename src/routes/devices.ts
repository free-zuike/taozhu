/** 登录设备管理：登录时 upsert 设备（名称/平台/最后活跃），设备页可查看/删除。
 *  删除设备 = 从设备列表移除（下次该设备登录重新记录）；仅老板可管理。 */
import { Hono } from 'hono';
import { adminOnly, authMiddleware } from '../middleware/auth';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const devicesRouter = new Hono<{ Bindings: Env; Variables: V }>();
devicesRouter.use('*', authMiddleware(), adminOnly());

/// 登录时 upsert 当前设备的活跃记录（幂等：同设备名+平台归并，刷新最后活跃）
export async function upsertDevice(
  db: D1Database,
  userId: string,
  deviceName: string,
  platform: string,
): Promise<void> {
  const id = `dev_${userId}_${deviceName}_${platform}`.replace(/[^a-zA-Z0-9_\-]/g, '_').slice(0, 80);
  await db.prepare(
    `INSERT INTO devices (id, user_id, device_name, platform) VALUES (?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET last_active_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
  ).bind(id, userId, deviceName, platform).run();
}

// GET /devices — 当前账号登录设备列表（倒序：最近活跃在前）
devicesRouter.get('/', async (c) => {
  const { id } = c.get('user');
  const rows = await c.env.DB.prepare(
    'SELECT id, device_name, platform, last_active_at, created_at FROM devices WHERE user_id = ? ORDER BY last_active_at DESC',
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