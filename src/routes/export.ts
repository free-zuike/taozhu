/** 流水 CSV 导出（v0.17.517）：出货 / 进货 / 收款三类明细合并成一张 Excel 可直接打开的表。
 *  - 只走只读查询，行数有硬上限，避免大账本把 Worker 内存与 D1 rows_read 一次打满；
 *  - 店员导出时成本/进价列置空，与在线 GET / sync pull 的打码口径一致；
 *  - 单元格做 CSV 转义 + 公式注入防护（= + - @ 开头前缀单引号），避免打开即执行公式。 */
import { Hono } from 'hono';
import { authMiddleware } from '../middleware/auth';
import { dayRangeEnd } from '../lib/biz-date';
import { recordAudit } from './audit';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const exportRouter = new Hono<{ Bindings: Env; Variables: V }>();

exportRouter.use('*', authMiddleware());

const MAX_ROWS = 20000;

type Row = Record<string, unknown>;

/** CSV 单元格：引号转义 + 防公式注入 */
export function csvCell(v: unknown): string {
  let s = v === null || v === undefined ? '' : String(v);
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return `"${s.replace(/"/g, '""')}"`;
}

function toCsv(headers: string[], rows: Row[], keys: string[]): string {
  const lines = [headers, ...rows.map((r) => keys.map((k) => r[k]))];
  return `\uFEFF${lines.map((r) => r.map(csvCell).join(',')).join('\r\n')}\r\n`;
}

const HEADERS = ['类型', '日期', '单号', '店铺', '商品', '单位', '数量', '单价', '金额', '成本价', '减免', '收款方式', '备注'];
const KEYS = ['kind', 'date', 'order_id', 'client', 'item', 'unit', 'quantity', 'price', 'amount', 'cost', 'waived', 'method', 'note'];

// GET /export/transactions.csv?kind=all|sale|purchase|payment&date_from=&date_to=&client_id=&limit=
exportRouter.get('/transactions.csv', async (c) => {
  const db = c.env.DB;
  const user = c.get('user');
  const isStaff = user.role !== 'admin';
  const kind = (c.req.query('kind') ?? 'all').trim();
  if (!['all', 'sale', 'purchase', 'payment'].includes(kind)) return c.json({ error: 'kind 不合法' }, 400);
  const start = (c.req.query('date_from') ?? '').trim();
  const end = (c.req.query('date_to') ?? '').trim();
  if ((start && !/^\d{4}-\d{2}-\d{2}$/.test(start)) || (end && !/^\d{4}-\d{2}-\d{2}$/.test(end))) {
    return c.json({ error: '日期格式应为 YYYY-MM-DD' }, 400);
  }
  if (start && end && start > end) return c.json({ error: '开始日期不能晚于结束日期' }, 400);
  const clientId = (c.req.query('client_id') ?? '').trim();
  const limit = Math.min(Math.max(Number(c.req.query('limit')) || MAX_ROWS, 1), MAX_ROWS);
  const range = [start, end ? dayRangeEnd(end) : ''] as const;
  const dateWhere = (col: string): string =>
    `${start ? ` AND ${col} >= ?` : ''}${end ? ` AND ${col} < ?` : ''}`;
  const dateParams = [...(start ? [range[0]] : []), ...(end ? [range[1]] : [])];

  const rows: Row[] = [];
  let truncated = false;

  if (kind === 'all' || kind === 'sale') {
    const sql = `SELECT substr(si.happened_at,1,10) AS date, si.sale_id AS order_id,
      COALESCE(cl.name,'') AS client, COALESCE(i.name,'') AS item, si.unit, si.quantity,
      si.sale_price AS price, si.amount, si.cost_price AS cost, si.note
      FROM sale_items si LEFT JOIN items i ON i.id = si.item_id
      LEFT JOIN clients cl ON cl.id = si.client_id
      WHERE 1=1${dateWhere('si.happened_at')}${clientId ? ' AND si.client_id = ?' : ''}
      ORDER BY si.happened_at DESC, si.sale_id DESC LIMIT ?`;
    const r = await db.prepare(sql).bind(...dateParams, ...(clientId ? [clientId] : []), limit).all<Row>();
    for (const x of r.results) rows.push({ ...x, kind: '出货', waived: '', method: '' });
    if (r.results.length >= limit) truncated = true;
  }
  if ((kind === 'all' || kind === 'purchase') && !clientId) {
    const sql = `SELECT substr(pi.happened_at,1,10) AS date, pi.purchase_id AS order_id,
      COALESCE(i.name,'') AS item, pi.unit, pi.quantity, pi.purchase_price AS price,
      pi.amount, pi.note FROM purchase_items pi LEFT JOIN items i ON i.id = pi.item_id
      WHERE 1=1${dateWhere('pi.happened_at')} ORDER BY pi.happened_at DESC, pi.purchase_id DESC LIMIT ?`;
    const r = await db.prepare(sql).bind(...dateParams, limit).all<Row>();
    for (const x of r.results) rows.push({ ...x, kind: '进货', client: '', waived: '', method: '' });
    if (r.results.length >= limit) truncated = true;
  }
  if (kind === 'all' || kind === 'payment') {
    const sql = `SELECT substr(p.happened_at,1,10) AS date, p.id AS order_id,
      COALESCE(cl.name,'') AS client, p.amount, p.waived, p.method, p.note
      FROM payments p LEFT JOIN clients cl ON cl.id = p.client_id
      WHERE 1=1${dateWhere('p.happened_at')}${clientId ? ' AND p.client_id = ?' : ''}
      ORDER BY p.happened_at DESC, p.id DESC LIMIT ?`;
    const r = await db.prepare(sql).bind(...dateParams, ...(clientId ? [clientId] : []), limit).all<Row>();
    for (const x of r.results) rows.push({ ...x, kind: '收款', item: '', unit: '', quantity: '', price: '' });
    if (r.results.length >= limit) truncated = true;
  }

  // 多类别合并时按日期倒序，保证导出表与页面列表顺序一致
  if (kind === 'all') rows.sort((a, b) => String(b.date ?? '').localeCompare(String(a.date ?? '')));
  const out = isStaff ? rows.map((r) => ({ ...r, cost: '', price: r.kind === '进货' ? '' : r.price })) : rows;
  const csv = toCsv(HEADERS, out, KEYS);
  await recordAudit(db, {
    username: user.username, action: 'export', entity_type: 'transactions', entity_id: '',
    detail: `导出流水 CSV（${kind}，${rows.length} 行${truncated ? '，已达行数上限' : ''}）`,
  });
  c.header('Content-Type', 'text/csv; charset=utf-8');
  c.header('Content-Disposition', `attachment; filename="transactions-${(start || 'all').replace(/-/g, '')}.csv"`);
  c.header('Cache-Control', 'no-store');
  c.header('X-Export-Rows', String(rows.length));
  c.header('X-Export-Truncated', truncated ? '1' : '0');
  return c.body(csv);
});
