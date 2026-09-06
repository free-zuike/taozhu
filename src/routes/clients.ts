/** 饭店（客户）管理 */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { authMiddleware, adminOnly } from '../middleware/auth';
import type { AuthUser, ClientRow, Env } from '../types';

type V = { user: AuthUser };
export const clientsRouter = new Hono<{ Bindings: Env; Variables: V }>();

clientsRouter.use('*', authMiddleware());

const nowIso = () => new Date().toISOString();

// GET /clients?q= — 列表（含欠款余额）
const SALES_TOTAL_SUB = '(SELECT sa.client_id, SUM(si.amount) AS total FROM sale_items si JOIN sales sa ON sa.id = si.sale_id GROUP BY sa.client_id)';
clientsRouter.get('/', async (c) => {
  const q = c.req.query('q')?.trim() ?? '';
  const rows = q
    ? await c.env.DB.prepare(
        `SELECT c.*, COALESCE(s.total, 0) AS sales_total, COALESCE(p.total, 0) AS paid_total FROM clients c LEFT JOIN ${SALES_TOTAL_SUB} s ON s.client_id = c.id LEFT JOIN (SELECT client_id, SUM(amount) AS total FROM payments GROUP BY client_id) p ON p.client_id = c.id WHERE c.deleted_at IS NULL AND c.name LIKE ? ORDER BY c.name`)
        .bind(`%${q}%`).all()
    : await c.env.DB.prepare(
        `SELECT c.*, COALESCE(s.total, 0) AS sales_total, COALESCE(p.total, 0) AS paid_total FROM clients c LEFT JOIN ${SALES_TOTAL_SUB} s ON s.client_id = c.id LEFT JOIN (SELECT client_id, SUM(amount) AS total FROM payments GROUP BY client_id) p ON p.client_id = c.id WHERE c.deleted_at IS NULL ORDER BY c.name`).all();
  return c.json({ clients: rows.results.map((r) => {
    const row = r as unknown as ClientRow & { sales_total: number; paid_total: number };
    return {
      id: row.id, name: row.name, contact: row.contact ?? '', phone: row.phone ?? '', note: row.note ?? '',
      sales_total: row.sales_total, paid_total: row.paid_total,
      debt: Number((row.sales_total - row.paid_total).toFixed(2)),
    };
  }) });
});

// POST /clients — 新建饭店
clientsRouter.post('/', adminOnly(), async (c) => {
  const body = await c.req.json().catch(() => null) as { name?: string; contact?: string; phone?: string; note?: string } | null;
  const name = body?.name?.trim();
  if (!name) return c.json({ error: '饭店名称必填' }, 400);
  const id = randomId();
  await c.env.DB.prepare('INSERT INTO clients (id, name, contact, phone, note) VALUES (?, ?, ?, ?, ?)')
    .bind(id, name, body?.contact?.trim() ?? '', body?.phone?.trim() ?? '', body?.note?.trim() ?? '').run();
  return c.json({ id, name, contact: body?.contact?.trim() ?? '', phone: body?.phone?.trim() ?? '', note: body?.note?.trim() ?? '', debt: 0 }, 201);
});

// PATCH /clients/:id
clientsRouter.patch('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { name?: string; contact?: string; phone?: string; note?: string } | null;
  const client = await c.env.DB.prepare('SELECT * FROM clients WHERE id = ? AND deleted_at IS NULL').bind(id).first<ClientRow>();
  if (!client) return c.json({ error: '饭店不存在' }, 404);
  await c.env.DB.prepare('UPDATE clients SET name = ?, contact = ?, phone = ?, note = ? WHERE id = ?')
    .bind(body?.name?.trim() || client.name, body?.contact?.trim() ?? client.contact ?? '', body?.phone?.trim() ?? client.phone ?? '', body?.note?.trim() ?? client.note ?? '', id).run();
  return c.json({ ok: true });
});

// DELETE /clients/:id — 软删
clientsRouter.delete('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  await c.env.DB.prepare('UPDATE clients SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL').bind(nowIso(), id).run();
  return c.body(null, 204);
});