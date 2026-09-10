/** 收款登记（结账）：payments —— 店铺欠款 = Σ出货 − Σ收款 */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { authMiddleware, adminOnly } from '../middleware/auth';
import { parsePage } from '../lib/paging';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const paymentsRouter = new Hono<{ Bindings: Env; Variables: V }>();

paymentsRouter.use('*', authMiddleware());

const nowIso = () => new Date().toISOString();

// POST /payments — 登记收款（仅老板），可带 waived 平账减免（欠款 = Σ出货 − Σ(amount+waived)）
paymentsRouter.post('/', adminOnly(), async (c) => {
  const user = c.get('user');
  const body = await c.req.json().catch(() => null) as {
    client_id?: string; happened_at?: string; amount?: number; waived?: number; method?: string; note?: string;
  } | null;
  const clientId = body?.client_id;
  const amount = Number(body?.amount);
  const waived = Number(body?.waived) || 0;
  if (!clientId) return c.json({ error: '请选择店铺' }, 400);
  if (!Number.isFinite(amount) || amount <= 0) return c.json({ error: '收款金额必须大于 0' }, 400);
  if (!Number.isFinite(waived) || waived < 0) return c.json({ error: '平账减免金额不能为负数' }, 400);
  const client = await c.env.DB.prepare('SELECT id FROM clients WHERE id = ? AND deleted_at IS NULL').bind(clientId).first();
  if (!client) return c.json({ error: '店铺不存在' }, 404);
  const id = randomId();
  const happenedAt = body?.happened_at?.trim() || nowIso().slice(0, 10);
  await c.env.DB.prepare(
    'INSERT INTO payments (id, client_id, happened_at, amount, waived, method, note, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
  ).bind(id, clientId, happenedAt, Math.round(amount * 100) / 100, Math.round(waived * 100) / 100, body?.method?.trim() ?? '', body?.note?.trim() ?? '', user.id).run();
  return c.json({ id, client_id: clientId, happened_at: happenedAt, amount: Math.round(amount * 100) / 100, waived: Math.round(waived * 100) / 100, method: body?.method?.trim() ?? '', note: body?.note?.trim() ?? '' }, 201);
});

// GET /payments?client_id=&date_from=&date_to=&limit=&offset=
paymentsRouter.get('/', async (c) => {
  const clientId = c.req.query('client_id')?.trim();
  const dateFrom = c.req.query('date_from')?.trim();
  const dateTo = c.req.query('date_to')?.trim();
  const { limit, offset } = parsePage(c.req.query('limit'), c.req.query('offset'));

  let where = ' WHERE 1=1';
  const params: string[] = [];
  if (clientId) { where += ' AND p.client_id = ?'; params.push(clientId); }
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

// PATCH /payments/:id — 编辑收款（改店铺/日期/金额/平账/方式/备注，仅老板）
paymentsRouter.patch('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as {
    client_id?: string; happened_at?: string; amount?: number; waived?: number; method?: string; note?: string;
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
  await c.env.DB.prepare(
    'UPDATE payments SET client_id = ?, happened_at = ?, amount = ?, waived = ?, method = ?, note = ? WHERE id = ?')
    .bind(clientId, body?.happened_at?.trim() || pay.happened_at, Math.round(amount * 100) / 100,
      Math.round(waived * 100) / 100, body?.method?.trim() ?? pay.method ?? '', body?.note?.trim() ?? pay.note ?? '', id).run();
  return c.json({ ok: true });
});

// DELETE /payments/:id — 撤销一笔收款（仅老板）
paymentsRouter.delete('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  await c.env.DB.prepare('DELETE FROM payments WHERE id = ?').bind(id).run();
  return c.body(null, 204);
});