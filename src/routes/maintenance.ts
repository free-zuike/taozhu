/**
 * 运维自检：索引的「查询结果」与「补建」全部由代码完成，不需要在 D1 控制台手工执行 SQL。
 *  - GET  /api/v1/maintenance/indexes         索引清单 + 关键索引缺失项 + EXPLAIN QUERY PLAN
 *  - POST /api/v1/maintenance/indexes/ensure  幂等补建缺失索引，并返回补建前后对比
 * 仅 admin；CI 部署时也会执行同一份 src/schema.sql，因此正常路径下这里应始终返回 missing=[]。
 */
import { Hono } from 'hono';
import { authMiddleware, adminOnly } from '../middleware/auth';
import { ensureIndexes, inspectIndexes } from '../schema';
import { runDailyMaintenance } from '../services/maintenance';
import { runFifoBackfillStep } from '../services/fifo-backfill';
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

// POST /api/v1/maintenance/prune — 手动执行每日清理（force=true，不受当天已跑过去重限制）
maintenanceRouter.post('/prune', async (c) => {
  return c.json(await runDailyMaintenance(c.env.DB, true, c.env));
});

// POST /api/v1/maintenance/fifo-backfill — 历史 FIFO 批次账回填（分批续跑/幂等）
// body: { max_groups?: number(0 只查状态), reset?: boolean }
// 用途：0.17.525 之前 App 行级进货/出货没有维护批次账；升级后由 App 管理员设备
// 在后台分批调用，直到 done。不动历史 cost_price（不改历史毛利），只修批次/占用。
maintenanceRouter.post('/fifo-backfill', async (c) => {
  const body = await c.req.json().catch(() => null) as {
    max_groups?: number; reset?: boolean; daily_work?: number;
  } | null;
  return c.json(await runFifoBackfillStep(c.env.DB, {
    maxGroups: Number(body?.max_groups) || 0,
    reset: body?.reset === true,
    dailyWork: Number(body?.daily_work) || undefined,
  }));
});
