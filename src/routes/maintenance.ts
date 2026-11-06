/**
 * 运维自检：索引的「查询结果」与「补建」全部由代码完成，不需要在 D1 控制台手工执行 SQL。
 *  - GET  /api/v1/maintenance/indexes         索引清单 + 关键索引缺失项 + EXPLAIN QUERY PLAN
 *  - POST /api/v1/maintenance/indexes/ensure  幂等补建缺失索引，并返回补建前后对比
 * 仅 admin；CI 部署时也会执行同一份 src/schema.sql，因此正常路径下这里应始终返回 missing=[]。
 */
import { Hono } from 'hono';
import { authMiddleware, adminOnly } from '../middleware/auth';
import { ensureIndexes, inspectIndexes } from '../schema';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const maintenanceRouter = new Hono<{ Bindings: Env; Variables: V }>();
maintenanceRouter.use('*', authMiddleware(), adminOnly());

maintenanceRouter.get('/indexes', async (c) => {
  return c.json(await inspectIndexes(c.env.DB));
});

maintenanceRouter.post('/indexes/ensure', async (c) => {
  const before = await inspectIndexes(c.env.DB);
  const ok = await ensureIndexes(c.env.DB);
  const after = await inspectIndexes(c.env.DB);
  return c.json({
    ok,
    missing_before: before.missing,
    missing_after: after.missing,
    critical: after.critical,
    plans: after.plans,
    total_indexes: after.totalIndexes,
  });
});
