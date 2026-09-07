/** 收款登记（结账）：payments —— 店铺欠款 = Σ出货 − Σ收款 */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { authMiddleware, adminOnly } from '../middleware/auth';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const paymentsRouter = new Hono<{ Bindings: Env; Variables: V }>();

paymentsRouter.use('*', authMiddleware());

const nowIso = () => new Date().toISOString();

// POST /payments — 登记收款（仅老板）
paymentsRouter.post('/', adminOnly(), async (c) => {
  const user = c.get('user');
  const body = await c.req.json().catch(() => null) as {
    client_id?: string; happened_at?: string; amount?: number; method?: string; note?: string;
  } | null;
  const clientId = body?.client_id;
  const amount = Number(body?.amount);
  if (!clientId) return c.json({ error: '请选择店铺' }, 400);
  if (!Number.isFinite(amount) || amount <= 0) return c.json({ error: '收款金额必须大于 0' }, 400);
  const client = await c.env.DB.prepare('SELECT id FROM clients WHERE id = ? AND deleted_at IS NULL').bind(clientId).first();
  if (!client) return c.json({ error: '店铺不存在' }, 404);
  const id = randomId();
  const happenedAt = body?.happened_at?.trim() || nowIso().slice(0, 10);
  await c.env.DB.prepare(
    'INSERT INTO payments (id, client_id, happened_at, amount, method, note, created_by) VALUES (?, ?, ?, ?, ?, ?, ?)',
  ).bind(id, clientId, happenedAt, Math.round(amount * 100) / 100, body?.method?.trim() ?? '', body?.note?.trim() ?? '', user.id).run();
  return c.json({ id, client_id: clientId, happened_at: happenedAt, amount: Math.round(amount * 100) / 100, method: body?.method?.trim() ?? '', note: body?.note?.trim() ?? '' }, 201);
});

// GET /payments?client_id=&date_from=&date_to=
paymentsRouter.get('/', async (c) => {
  const clientId = c.req.query('client_id')?.trim();
  const dateFrom = c.req.query('date_from')?.trim();
  const dateTo = c.req.query('date_to')?.trim();
  let sql = 'SELECT p.*, c.name AS client_name FROM payments p JOIN clients c ON c.id = p.client_id WHERE 1=1';
  const params: string[] = [];
  if (clientId) { sql += ' AND p.client_id = ?'; params.push(clientId); }
  if (dateFrom) { sql += ' AND p.happened_at >= ?'; params.push(dateFrom); }
  if (dateTo) { sql += ' AND p.happened_at <= ?'; params.push(dateTo); }
  sql += ' ORDER BY p.happened_at DESC, p.created_at DESC';
  const rows = await c.env.DB.prepare(sql).bind(...params).all();
  return c.json({ payments: rows.results });
});

// DELETE /payments/:id — 撤销一笔收款（仅老板）
paymentsRouter.delete('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  await c.env.DB.prepare('DELETE FROM payments WHERE id = ?').bind(id).run();
  return c.body(null, 204);
});