/** 统计：工作台概览 / 按店 / 按月 —— 毛利 = Σ(出价-进价快照)*数量 */
import { Hono } from 'hono';
import { authMiddleware } from '../middleware/auth';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const statsRouter = new Hono<{ Bindings: Env; Variables: V }>();

statsRouter.use('*', authMiddleware());

const nowIso = () => new Date().toISOString();

// GET /stats/overview?date=YYYY-MM-DD — 工作台卡片（今日出货/毛利/收款 + 全局欠款/规模）
statsRouter.get('/overview', async (c) => {
  const date = c.req.query('date')?.trim() || nowIso().slice(0, 10);
  const db = c.env.DB;

  const today = await db.prepare(
    `SELECT
      COALESCE((SELECT SUM(si.amount) FROM sale_items si JOIN sales s ON s.id = si.sale_id WHERE s.happened_at = ?), 0) AS sales_total,
      COALESCE((SELECT COUNT(*) FROM sales WHERE happened_at = ?), 0) AS sales_count,
      COALESCE((SELECT SUM((si.sale_price - si.cost_price) * si.quantity) FROM sale_items si JOIN sales s ON s.id = si.sale_id WHERE s.happened_at = ?), 0) AS gross_profit,
      COALESCE((SELECT SUM(amount) FROM payments WHERE happened_at = ?), 0) AS paid_total,
      COALESCE((SELECT SUM(pi.amount) FROM purchase_items pi JOIN purchases p ON p.id = pi.purchase_id WHERE p.happened_at = ?), 0) AS purchase_total`,
  ).bind(date, date, date, date, date).first<{
    sales_total: number; sales_count: number; gross_profit: number; paid_total: number; purchase_total: number;
  }>();

  const totals = await db.prepare(
    `SELECT
      COALESCE((SELECT SUM(amount) FROM sale_items), 0) AS all_sales,
      COALESCE((SELECT SUM(amount) FROM payments), 0) AS all_paid,
      COALESCE((SELECT COUNT(*) FROM clients WHERE deleted_at IS NULL), 0) AS client_count,
      COALESCE((SELECT COUNT(*) FROM items WHERE deleted_at IS NULL), 0) AS item_count`,
  ).first<{ all_sales: number; all_paid: number; client_count: number; item_count: number }>();

  const topDebt = await db.prepare(
    `SELECT c.id, c.name,
      COALESCE((SELECT SUM(si.amount) FROM sale_items si JOIN sales s ON s.id = si.sale_id AND s.client_id = c.id), 0) AS sales_total,
      COALESCE((SELECT SUM(amount) FROM payments WHERE client_id = c.id), 0) AS paid_total
     FROM clients c WHERE c.deleted_at IS NULL
     ORDER BY (sales_total - paid_total) DESC LIMIT 5`,
  ).all<{ id: string; name: string; sales_total: number; paid_total: number }>();

  const r = (n: unknown) => Math.round(Number(n || 0) * 100) / 100;
  return c.json({
    date,
    today: {
      sales_total: r(today?.sales_total), sales_count: today?.sales_count ?? 0,
      gross_profit: r(today?.gross_profit), paid_total: r(today?.paid_total),
      purchase_total: r(today?.purchase_total),
    },
    totals: {
      all_sales: r(totals?.all_sales), all_paid: r(totals?.all_paid),
      debt: r((totals?.all_sales ?? 0) - (totals?.all_paid ?? 0)),
      client_count: totals?.client_count ?? 0, item_count: totals?.item_count ?? 0,
    },
    top_debt_clients: topDebt.results.map((c2) => ({
      id: c2.id, name: c2.name, sales_total: r(c2.sales_total), paid_total: r(c2.paid_total),
      debt: r(c2.sales_total - c2.paid_total),
    })),
  });
});

// GET /stats/clients?start=&end= — 按店：出货/收款/欠款/毛利（可传起止日期过滤，缺省=全部历史）
statsRouter.get('/clients', async (c) => {
  const start = c.req.query('start')?.trim();
  const end = c.req.query('end')?.trim();
  const hasRange = !!(start && end);
  const saleCond = hasRange ? 'AND substr(s.happened_at, 1, 10) BETWEEN ? AND ?' : '';
  const payCond = hasRange ? 'AND substr(happened_at, 1, 10) BETWEEN ? AND ?' : '';
  const params: unknown[] = [];
  if (hasRange) params.push(start, end, start, end, start, end);
  const rows = await c.env.DB.prepare(
    `SELECT c.id, c.name,
      COALESCE((SELECT SUM(si.amount) FROM sale_items si JOIN sales s ON s.id = si.sale_id AND s.client_id = c.id ${saleCond}), 0) AS sales_total,
      COALESCE((SELECT SUM(amount) FROM payments WHERE client_id = c.id ${payCond}), 0) AS paid_total,
      COALESCE((SELECT SUM((si.sale_price - si.cost_price) * si.quantity) FROM sale_items si JOIN sales s ON s.id = si.sale_id AND s.client_id = c.id ${saleCond}), 0) AS gross_profit
     FROM clients c WHERE c.deleted_at IS NULL ORDER BY sales_total DESC`,
  ).bind(...params).all<{ id: string; name: string; sales_total: number; paid_total: number; gross_profit: number }>();
  const r = (n: unknown) => Math.round(Number(n || 0) * 100) / 100;
  return c.json({
    clients: rows.results.map((c2) => ({
      id: c2.id, name: c2.name, sales_total: r(c2.sales_total), paid_total: r(c2.paid_total),
      gross_profit: r(c2.gross_profit), debt: r(c2.sales_total - c2.paid_total),
    })),
  });
});

// GET /stats/monthly?year=2026 — 按月：出货额/毛利/收款
statsRouter.get('/monthly', async (c) => {
  const year = c.req.query('year')?.trim() || String(new Date().getUTCFullYear());
  const salesRows = await c.env.DB.prepare(
    `SELECT substr(s.happened_at, 1, 7) AS month,
      SUM(si.amount) AS sales_total,
      SUM((si.sale_price - si.cost_price) * si.quantity) AS gross_profit
     FROM sale_items si JOIN sales s ON s.id = si.sale_id
     WHERE substr(s.happened_at, 1, 4) = ?
     GROUP BY month ORDER BY month`,
  ).bind(year).all<{ month: string; sales_total: number; gross_profit: number }>();
  const paidRows = await c.env.DB.prepare(
    `SELECT substr(happened_at, 1, 7) AS month, SUM(amount) AS paid_total
     FROM payments WHERE substr(happened_at, 1, 4) = ? GROUP BY month ORDER BY month`,
  ).bind(year).all<{ month: string; paid_total: number }>();
  const paidMap = new Map(paidRows.results.map((p) => [p.month, p.paid_total]));
  const r = (n: unknown) => Math.round(Number(n || 0) * 100) / 100;
  return c.json({
    year,
    months: salesRows.results.map((s) => ({
      month: s.month, sales_total: r(s.sales_total), gross_profit: r(s.gross_profit),
      paid_total: r(paidMap.get(s.month) ?? 0),
    })),
  });
});

// GET /stats/years — 有数据的年份列表（出货/进货/收款并集，升序）
statsRouter.get('/years', async (c) => {
  const rows = await c.env.DB.prepare(
    `SELECT DISTINCT substr(happened_at, 1, 4) AS y FROM sales
     UNION SELECT DISTINCT substr(happened_at, 1, 4) FROM purchases
     UNION SELECT DISTINCT substr(happened_at, 1, 4) FROM payments
     ORDER BY y`,
  ).all<{ y: string }>();
  return c.json({ years: rows.results.map((r) => Number(r.y)).filter((n) => Number.isInteger(n) && n >= 2000) });
});

// GET /stats/summary?start=&end=&client_id= — 任意区间汇总（起止日都含；欠款=截止 end 累计出货−累计收款）
statsRouter.get('/summary', async (c) => {
  const start = c.req.query('start')?.trim();
  const end = c.req.query('end')?.trim();
  if (!start || !end) return c.json({ error: 'start/end 必填（YYYY-MM-DD）' }, 400);
  const clientId = c.req.query('client_id')?.trim();
  const db = c.env.DB;
  const r = (n: unknown) => Math.round(Number(n || 0) * 100) / 100;

  const salesParams: unknown[] = [start, end];
  const salesSql = `SELECT
      COALESCE(SUM(si.amount), 0) AS sales_total,
      COALESCE(SUM((si.sale_price - si.cost_price) * si.quantity), 0) AS gross_profit,
      COUNT(DISTINCT s.id) AS sales_count
     FROM sale_items si JOIN sales s ON s.id = si.sale_id
     WHERE substr(s.happened_at, 1, 10) BETWEEN ? AND ?${clientId ? ' AND s.client_id = ?' : ''}`;
  if (clientId) salesParams.push(clientId);
  const sales = await db.prepare(salesSql).bind(...salesParams).first<{
    sales_total: number; gross_profit: number; sales_count: number;
  }>();

  const paidParams: unknown[] = [start, end];
  const paidSql = `SELECT COALESCE(SUM(amount), 0) AS paid_total
     FROM payments WHERE substr(happened_at, 1, 10) BETWEEN ? AND ?${clientId ? ' AND client_id = ?' : ''}`;
  if (clientId) paidParams.push(clientId);
  const paid = await db.prepare(paidSql).bind(...paidParams).first<{ paid_total: number }>();

  const buyParams: unknown[] = [start, end];
  const buySql = `SELECT COALESCE(SUM(pi.amount), 0) AS purchase_total
     FROM purchase_items pi JOIN purchases p ON p.id = pi.purchase_id
     WHERE substr(p.happened_at, 1, 10) BETWEEN ? AND ?`;
  const buy = await db.prepare(buySql).bind(...buyParams).first<{ purchase_total: number }>();

  // 截止 end 的总欠款（区间前累计也计入：全部出货 − 全部收款，时间 ≤ end）
  // SQL 占位符顺序：all_sales(<=?, client=?) → all_paid(<=?, client=?)
  const debtParams: unknown[] = clientId ? [end, clientId, end, clientId] : [end, end];
  const debtSql = `SELECT
      COALESCE((SELECT SUM(si.amount) FROM sale_items si JOIN sales s ON s.id = si.sale_id
                WHERE substr(s.happened_at, 1, 10) <= ?${clientId ? ' AND s.client_id = ?' : ''}), 0) AS all_sales,
      COALESCE((SELECT SUM(amount) FROM payments
                WHERE substr(happened_at, 1, 10) <= ?${clientId ? ' AND client_id = ?' : ''}), 0) AS all_paid`;
  const debt = await db.prepare(debtSql).bind(...debtParams).first<{ all_sales: number; all_paid: number }>();

  return c.json({
    start, end,
    sales_total: r(sales?.sales_total), gross_profit: r(sales?.gross_profit),
    sales_count: sales?.sales_count ?? 0,
    paid_total: r(paid?.paid_total), purchase_total: r(buy?.purchase_total),
    debt: r((debt?.all_sales ?? 0) - (debt?.all_paid ?? 0)),
  });
});

// GET /stats/daily?start=&end=&client_id= — 区间内按日：出货/毛利/收款/进货（只含有数据的日，前端补零）
statsRouter.get('/daily', async (c) => {
  const start = c.req.query('start')?.trim();
  const end = c.req.query('end')?.trim();
  if (!start || !end) return c.json({ error: 'start/end 必填（YYYY-MM-DD）' }, 400);
  const clientId = c.req.query('client_id')?.trim();
  const db = c.env.DB;
  const r = (n: unknown) => Math.round(Number(n || 0) * 100) / 100;

  const sParams: unknown[] = [start, end];
  const sSql = `SELECT substr(s.happened_at, 1, 10) AS day,
      SUM(si.amount) AS sales_total,
      SUM((si.sale_price - si.cost_price) * si.quantity) AS gross_profit
     FROM sale_items si JOIN sales s ON s.id = si.sale_id
     WHERE substr(s.happened_at, 1, 10) BETWEEN ? AND ?${clientId ? ' AND s.client_id = ?' : ''}
     GROUP BY day ORDER BY day`;
  if (clientId) sParams.push(clientId);
  const salesRows = await db.prepare(sSql).bind(...sParams).all<{ day: string; sales_total: number; gross_profit: number }>();

  const pParams: unknown[] = [start, end];
  const pSql = `SELECT substr(happened_at, 1, 10) AS day, SUM(amount) AS paid_total
     FROM payments WHERE substr(happened_at, 1, 10) BETWEEN ? AND ?${clientId ? ' AND client_id = ?' : ''}
     GROUP BY day ORDER BY day`;
  if (clientId) pParams.push(clientId);
  const paidRows = await db.prepare(pSql).bind(...pParams).all<{ day: string; paid_total: number }>();

  const bParams: unknown[] = [start, end];
  const bSql = `SELECT substr(p.happened_at, 1, 10) AS day, SUM(pi.amount) AS purchase_total
     FROM purchase_items pi JOIN purchases p ON p.id = pi.purchase_id
     WHERE substr(p.happened_at, 1, 10) BETWEEN ? AND ?
     GROUP BY day ORDER BY day`;
  const buyRows = await db.prepare(bSql).bind(...bParams).all<{ day: string; purchase_total: number }>();

  const paidMap = new Map(paidRows.results.map((p) => [p.day, p.paid_total]));
  const buyMap = new Map(buyRows.results.map((p) => [p.day, p.purchase_total]));
  return c.json({
    start, end,
    days: salesRows.results.map((s) => ({
      day: s.day, sales_total: r(s.sales_total), gross_profit: r(s.gross_profit),
      paid_total: r(paidMap.get(s.day) ?? 0), purchase_total: r(buyMap.get(s.day) ?? 0),
    })),
  });
});

// GET /stats/items?start=&end=&client_id= — 区间内商品出货排行（按出货额降序，Top 15）
statsRouter.get('/items', async (c) => {
  const start = c.req.query('start')?.trim();
  const end = c.req.query('end')?.trim();
  if (!start || !end) return c.json({ error: 'start/end 必填（YYYY-MM-DD）' }, 400);
  const clientId = c.req.query('client_id')?.trim();
  const params: unknown[] = [start, end];
  if (clientId) params.push(clientId);
  const rows = await c.env.DB.prepare(
    `SELECT i.name, si.unit, SUM(si.quantity) AS quantity, SUM(si.amount) AS amount
     FROM sale_items si
     JOIN sales s ON s.id = si.sale_id
     JOIN items i ON i.id = si.item_id
     WHERE substr(s.happened_at, 1, 10) BETWEEN ? AND ?${clientId ? ' AND s.client_id = ?' : ''}
     GROUP BY si.item_id, si.unit
     ORDER BY amount DESC LIMIT 15`,
  ).bind(...params).all<{ name: string; unit: string; quantity: number; amount: number }>();
  const r = (n: unknown) => Math.round(Number(n || 0) * 100) / 100;
  return c.json({
    items: rows.results.map((x) => ({
      name: x.name, unit: x.unit,
      quantity: r(x.quantity), amount: r(x.amount),
    })),
  });
});