/** 店铺（客户）管理 */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { authMiddleware, adminOnly } from '../middleware/auth';
import type { AuthUser, ClientRow, Env } from '../types';

type V = { user: AuthUser };
export const clientsRouter = new Hono<{ Bindings: Env; Variables: V }>();

clientsRouter.use('*', authMiddleware());

const nowIso = () => new Date().toISOString();

/** 校验店铺分类（可选）：必须存在且 type='client' */
async function categoryErr(db: D1Database, categoryId: string | null | undefined): Promise<string | null> {
  if (!categoryId) return null;
  const cat = await db.prepare('SELECT id FROM categories WHERE id = ? AND type = ?').bind(categoryId, 'client').first();
  return cat ? null : '店铺分类不存在';
}

// GET /clients?q= — 列表（含欠款余额、分类名）
const SALES_TOTAL_SUB = '(SELECT sa.client_id, SUM(si.amount) AS total FROM sale_items si JOIN sales sa ON sa.id = si.sale_id GROUP BY sa.client_id)';
clientsRouter.get('/', async (c) => {
  const q = c.req.query('q')?.trim() ?? '';
  const sql = `SELECT c.*, cat.name AS category_name, COALESCE(s.total, 0) AS sales_total, COALESCE(p.total, 0) AS paid_total,
      (SELECT MIN(substr(s2.happened_at, 1, 10)) FROM sales s2 WHERE s2.client_id = c.id) AS first_book_date
      FROM clients c LEFT JOIN categories cat ON cat.id = c.category_id LEFT JOIN ${SALES_TOTAL_SUB} s ON s.client_id = c.id LEFT JOIN (SELECT client_id, SUM(amount) AS total FROM payments GROUP BY client_id) p ON p.client_id = c.id WHERE c.deleted_at IS NULL`;
  const rows = q
    ? await c.env.DB.prepare(`${sql} AND c.name LIKE ? ORDER BY c.name`).bind(`%${q}%`).all()
    : await c.env.DB.prepare(`${sql} ORDER BY c.name`).all();
  return c.json({ clients: rows.results.map((r) => {
    const row = r as unknown as ClientRow & { sales_total: number; paid_total: number; category_name: string | null; first_book_date: string | null };
    return {
      id: row.id, name: row.name, contact: row.contact ?? '', phone: row.phone ?? '', note: row.note ?? '',
      start_date: row.start_date ?? '', end_date: row.end_date ?? '',
      month_start_day: row.month_start_day ?? 1,
      first_book_date: row.first_book_date ?? '',
      category_id: row.category_id ?? '', category_name: row.category_name ?? '',
      sales_total: row.sales_total, paid_total: row.paid_total,
      debt: Number((row.sales_total - row.paid_total).toFixed(2)),
    };
  }) });
});

// POST /clients — 新建店铺
clientsRouter.post('/', adminOnly(), async (c) => {
  const body = await c.req.json().catch(() => null) as { name?: string; contact?: string; phone?: string; note?: string; category_id?: string; start_date?: string; end_date?: string; month_start_day?: number } | null;
  const name = body?.name?.trim();
  if (!name) return c.json({ error: '店铺名称必填' }, 400);
  const catErr = await categoryErr(c.env.DB, body?.category_id);
  if (catErr) return c.json({ error: catErr }, 400);
  const msd = normalizeStartDay(body?.month_start_day);
  if (msd === null) return c.json({ error: '每月起始日须为 1-28 的整数' }, 400);
  const id = randomId();
  await c.env.DB.prepare('INSERT INTO clients (id, name, contact, phone, note, category_id, start_date, end_date, month_start_day) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)')
    .bind(id, name, body?.contact?.trim() ?? '', body?.phone?.trim() ?? '', body?.note?.trim() ?? '', body?.category_id ?? null, body?.start_date?.trim() ?? null, body?.end_date?.trim() ?? null, msd).run();
  return c.json({ id, name, contact: body?.contact?.trim() ?? '', phone: body?.phone?.trim() ?? '', note: body?.note?.trim() ?? '', category_id: body?.category_id ?? '', start_date: body?.start_date?.trim() ?? '', end_date: body?.end_date?.trim() ?? '', month_start_day: msd, debt: 0 }, 201);
});

// PATCH /clients/:id
clientsRouter.patch('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json().catch(() => null) as { name?: string; contact?: string; phone?: string; note?: string; category_id?: string | null; start_date?: string | null; end_date?: string | null; month_start_day?: number } | null;
  const client = await c.env.DB.prepare('SELECT * FROM clients WHERE id = ? AND deleted_at IS NULL').bind(id).first<ClientRow>();
  if (!client) return c.json({ error: '店铺不存在' }, 404);
  const catErr = await categoryErr(c.env.DB, body?.category_id);
  if (catErr) return c.json({ error: catErr }, 400);
  const msd = body?.month_start_day !== undefined ? normalizeStartDay(body.month_start_day) : client.month_start_day;
  if (msd === null) return c.json({ error: '每月起始日须为 1-28 的整数' }, 400);
  await c.env.DB.prepare('UPDATE clients SET name = ?, contact = ?, phone = ?, note = ?, category_id = ?, start_date = ?, end_date = ?, month_start_day = ? WHERE id = ?')
    .bind(
      body?.name?.trim() || client.name,
      body?.contact?.trim() ?? client.contact ?? '',
      body?.phone?.trim() ?? client.phone ?? '',
      body?.note?.trim() ?? client.note ?? '',
      body?.category_id !== undefined ? body.category_id : client.category_id,
      body?.start_date !== undefined ? (body.start_date?.trim() ?? null) : client.start_date,
      body?.end_date !== undefined ? (body.end_date?.trim() ?? null) : client.end_date,
      msd,
      id,
    ).run();
  return c.json({ ok: true });
});

/** 校验并规范化每月起始日（1-28，缺省 1=自然月）；非法返回 null */
function normalizeStartDay(v: unknown): number | null {
  if (v === undefined || v === null || v === '') return 1;
  const n = Number(v);
  if (!Number.isInteger(n) || n < 1 || n > 28) return null;
  return n;
}

// DELETE /clients/:id — 软删
clientsRouter.delete('/:id', adminOnly(), async (c) => {
  const id = c.req.param('id');
  await c.env.DB.prepare('UPDATE clients SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL').bind(nowIso(), id).run();
  return c.body(null, 204);
});