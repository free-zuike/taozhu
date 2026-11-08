/** 收款登记（结账）：payments —— 店铺欠款 = Σ出货 − Σ收款 */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { authMiddleware, adminOnly } from '../middleware/auth';
import { parsePage } from '../lib/paging';
import { buildPayload, recordChange } from '../lib/sync';
import { deleteEntityAttachments } from '../lib/image-key';
import { normalizeAllocations, allocationStatements, listUnsettled } from '../lib/allocations';
import { recordAudit } from './audit';
import { archiveVoidedOrder } from '../services/voided';
import { localTodayISO } from '../lib/biz-date';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const paymentsRouter = new Hono<{ Bindings: Env; Variables: V }>();

paymentsRouter.use('*', authMiddleware());

// POST /payments — 登记收款（仅老板），可带 waived 平账减免（欠款 = Σ出货 − Σ(amount+waived)）
paymentsRouter.post('/', adminOnly(), async (c) => {
  const user = c.get('user');
  const body = await c.req.json().catch(() => null) as {
    client_id?: string; happened_at?: string; amount?: number; waived?: number; method?: string; note?: string; sync_key?: string;
    /** 可选：显式指定这笔收款冲哪几张出货单；不传则按最早未结清单据自动 FIFO 分摊 */
    allocations?: unknown;
  } | null;
  const clientId = body?.client_id;
  const amount = Number(body?.amount);
  const waived = Number(body?.waived) || 0;
  const syncKey = body?.sync_key?.trim() || '';
  if (!clientId) return c.json({ error: '请选择店铺' }, 400);
  if (!Number.isFinite(amount) || amount <= 0) return c.json({ error: '收款金额必须大于 0' }, 400);
  if (!Number.isFinite(waived) || waived < 0) return c.json({ error: '平账减免金额不能为负数' }, 400);
  // 幂等：同一 sync_key 已存在（离线重放重复投递）→ 返回已有，不重复登记
  if (syncKey) {
    const existed = await c.env.DB.prepare('SELECT id FROM payments WHERE sync_key = ?').bind(syncKey).first<{ id: string }>();
    if (existed) return c.json({ id: existed.id, client_id: clientId, dup: true });
  }
  const client = await c.env.DB.prepare('SELECT id FROM clients WHERE id = ? AND deleted_at IS NULL').bind(clientId).first();
  if (!client) return c.json({ error: '店铺不存在' }, 404);
  const id = randomId();
  const happenedAt = body?.happened_at?.trim() || localTodayISO();
  // 核销明细：不传则按最早未结清单据 FIFO 自动分摊；传了则严格校验总额与该店待收额。
  // 校验失败按 400 返回，绝不「先收款、后漏核销」或吞掉错误。
  let allocations;
  try {
    allocations = await normalizeAllocations(c.env.DB, clientId, amount + waived, body?.allocations);
  } catch (e) {
    return c.json({ error: (e as Error).message }, 400);
  }
  // 存储浮点原值（对齐参考项目 REAL：入库不取整；舍入配置只在统计/欠款/展示层换算）
  // payment 与 payment_allocations 同一 batch：要么一起成功，要么一起回滚，不留孤儿核销行。
  await c.env.DB.batch([
    c.env.DB.prepare(
      'INSERT INTO payments (id, client_id, happened_at, amount, waived, method, note, created_by, sync_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    ).bind(id, clientId, happenedAt, amount, waived, body?.method?.trim() ?? '', body?.note?.trim() ?? '', user.id, syncKey || null),
    ...allocationStatements(c.env.DB, id, allocations),
  ]);
  await recordChange(c.env.DB, { entity_type: 'payment', entity_sync_id: id, payload: await buildPayload(c.env.DB, 'payment', id), updated_by_username: user.username });
  return c.json({ id, client_id: clientId, happened_at: happenedAt, amount, waived, method: body?.method?.trim() ?? '', note: body?.note?.trim() ?? '' }, 201);
});

// GET /payments?client_id=&method=&date_from=&date_to=&limit=&offset=
// method=收款方式（账户详情页按账户拉流水用）
paymentsRouter.get('/', async (c) => {
  const clientId = c.req.query('client_id')?.trim();
  const method = c.req.query('method')?.trim();
  const dateFrom = c.req.query('date_from')?.trim();
  const dateTo = c.req.query('date_to')?.trim();
  const { limit, offset } = parsePage(c.req.query('limit'), c.req.query('offset'));

  let where = ' WHERE 1=1';
  const params: string[] = [];
  if (clientId) { where += ' AND p.client_id = ?'; params.push(clientId); }
  if (method) { where += ' AND p.method = ?'; params.push(method); }
  if (dateFrom) { where += ' AND p.happened_at >= ?'; params.push(dateFrom); }
  if (dateTo) { where += ' AND p.happened_at <= ?'; params.push(dateTo); }

  const countRow = await c.env.DB.prepare(
    `SELECT COUNT(*) AS cnt FROM payments p JOIN clients c ON c.id = p.client_id ${where}`).bind(...params).first<{ cnt: number }>();

  const rows = await c.env.DB.prepare(
    `SELECT p.*, c.name AS client_name FROM payments p JOIN clients c ON c.id = p.client_id ${where}
     ORDER BY p.happened_at DESC, p.created_at DESC LIMIT ? OFFSET ?`,
  ).bind(...params, limit, offset).all();
  return c.json({ total: countRow?.cnt ?? 0, payments: rows.results });
});

// GET /payments/unsettled?client_id= — 该店按 FIFO 核销后仍待收的出货单（对账页/AI 共用口径）
paymentsRouter.get('/unsettled', async (c) => {
  const clientId = c.req.query('client_id')?.trim() ?? '';
  if (!clientId) return c.json({ error: '请选择店铺' }, 400);
  const orders = await listUnsettled(c.env.DB, clientId);
  const total = Math.round(orders.reduce((s, o) => s + o.unsettled, 0) * 100) / 100;
  return c.json({ client_id: clientId, total, orders });
});

// GET /payments/:id/allocations — 某笔收款具体冲了哪几张单
paymentsRouter.get('/:id/allocations', async (c) => {
  const rows = await c.env.DB.prepare(
    'SELECT id, sale_id, amount FROM payment_allocations WHERE payment_id = ? ORDER BY created_at, id',
  ).bind(c.req.param('id')).all().catch(() => ({ results: [] as unknown[] }));
  return c.json({ allocations: rows.results });
});

// PATCH /payments/:id — 编辑收款（改店铺/日期/金额/平账/方式/备注，仅老板）
paymentsRouter.patch('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as {
    client_id?: string; happened_at?: string; amount?: number; waived?: number; method?: string; note?: string;
    /** 可选：重指定这笔收款冲哪几张出货单；金额/店铺变更时若不传则重新自动 FIFO 分摊 */
    allocations?: unknown;
  } | null;
  const pay = await c.env.DB.prepare('SELECT * FROM payments WHERE id = ?').bind(id)
    .first<{ client_id: string; happened_at: string; amount: number; waived: number; method: string; note: string }>();
  if (!pay) return c.json({ error: '收款记录不存在' }, 404);
  const clientId = body?.client_id ?? pay.client_id;
  const client = await c.env.DB.prepare('SELECT id FROM clients WHERE id = ? AND deleted_at IS NULL').bind(clientId).first();
  if (!client) return c.json({ error: '店铺不存在' }, 404);
  const amount = body?.amount !== undefined ? Number(body.amount) : pay.amount;
  if (!Number.isFinite(amount) || amount <= 0) return c.json({ error: '收款金额必须大于 0' }, 400);
  const waived = body?.waived !== undefined ? Number(body.waived) : pay.waived;
  if (!Number.isFinite(waived) || waived < 0) return c.json({ error: '平账减免金额不能为负数' }, 400);
  // 金额/减免/店铺变了（或显式传了 allocations）就必须重算核销，否则待收额会算错。
  // 纯改日期/方式/备注时保持原核销不动，避免无谓重排用户手工指定的分摊。
  const realloc = body?.allocations !== undefined
    || amount !== pay.amount || waived !== pay.waived || clientId !== pay.client_id;
  let allocations;
  if (realloc) {
    try {
      // 排除本笔旧核销，否则重算时会把同一张单当成已被别的收款占用。
      allocations = await normalizeAllocations(c.env.DB, clientId, amount + waived, body?.allocations, id);
    } catch (e) {
      return c.json({ error: (e as Error).message }, 400);
    }
  }
  // 存储浮点原值（对齐参考项目 REAL：入库不取整；舍入配置只在统计/欠款/展示层换算）
  const stmts = [
    c.env.DB.prepare(
      'UPDATE payments SET client_id = ?, happened_at = ?, amount = ?, waived = ?, method = ?, note = ? WHERE id = ?')
      .bind(clientId, body?.happened_at?.trim() || pay.happened_at, amount,
        waived, body?.method?.trim() ?? pay.method ?? '', body?.note?.trim() ?? pay.note ?? '', id),
  ];
  if (realloc && allocations) {
    stmts.push(c.env.DB.prepare('DELETE FROM payment_allocations WHERE payment_id = ?').bind(id));
    stmts.push(...allocationStatements(c.env.DB, id, allocations));
  }
  await c.env.DB.batch(stmts);
  await recordChange(c.env.DB, { entity_type: 'payment', entity_sync_id: id, payload: await buildPayload(c.env.DB, 'payment', id), updated_by_username: c.get('user').username });
  await recordAudit(c.env.DB, { username: c.get('user').username, action: 'update', entity_type: 'payment', entity_id: id, detail: `修改收款：金额 ¥${amount}${waived > 0 ? `、平账减免 ¥${waived}` : ''}` });
  return c.json({ ok: true });
});

// DELETE /payments/:id — 撤销一笔收款（仅老板）
paymentsRouter.delete('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  // 审计留痕带金额/方式（删前快照）
  const pay = await c.env.DB.prepare('SELECT amount, method FROM payments WHERE id = ?').bind(id).first<{ amount: number; method: string }>();
  await archiveVoidedOrder(c.env.DB, {
    entity_type: 'payment', id,
    reason: c.req.query('reason')?.trim() || '删除/作废', username: c.get('user').username,
  });
  // 核销行与收款同批删除，避免留下指向已撤销收款的孤儿记录（欠款口径不受影响，但待收额会）。
  try {
    await c.env.DB.batch([
      c.env.DB.prepare('DELETE FROM payment_allocations WHERE payment_id = ?').bind(id),
      c.env.DB.prepare('DELETE FROM payments WHERE id = ?').bind(id),
    ]);
  } catch (e) {
    // 老库迁移窗口内可能还没补建核销表：退化为原行为，不让撤销收款失败。
    if (!`${e}`.includes('no such table')) throw e;
    await c.env.DB.prepare('DELETE FROM payments WHERE id = ?').bind(id).run();
  }
  await recordChange(c.env.DB, { entity_type: 'payment', entity_sync_id: id, action: 'delete', payload: {}, updated_by_username: c.get('user').username });
  await recordAudit(c.env.DB, { username: c.get('user').username, action: 'delete', entity_type: 'payment', entity_id: id, detail: `撤销收款（¥${pay ? Math.round(pay.amount * 100) / 100 : 0}${pay?.method ? ` ${pay.method}` : ''}）` });
  // 撤销收款时一并清理其附件文件（孤儿文件清理，best-effort 不阻塞）
  try {
    await deleteEntityAttachments(c.env, 'payment', id);
  } catch (_) {}
  return c.body(null, 204);
});