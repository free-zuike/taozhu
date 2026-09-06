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

// GET /stats/clients — 按店：出货/收款/欠款/毛利
statsRouter.get('/clients', async (c) => {
  const rows = await c.env.DB.prepare(
    `SELECT c.id, c.name,
      COALESCE((SELECT SUM(si.amount) FROM sale_items si JOIN sales s ON s.id = si.sale_id AND s.client_id = c.id), 0) AS sales_total,
      COALESCE((SELECT SUM(amount) FROM payments WHERE client_id = c.id), 0) AS paid_total,
      COALESCE((SELECT SUM((si.sale_price - si.cost_price) * si.quantity) FROM sale_items si JOIN sales s ON s.id = si.sale_id AND s.client_id = c.id), 0) AS gross_profit
     FROM clients c WHERE c.deleted_at IS NULL ORDER BY sales_total DESC`,
  ).all<{ id: string; name: string; sales_total: number; paid_total: number; gross_profit: number }>();
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