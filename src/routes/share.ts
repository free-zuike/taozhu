/** 对账单分享：生成带失效时间的只读分享链接（仅老板），对方浏览器直接查看 */
import { Hono } from 'hono';
import { randomId } from '../lib/password';
import { adminOnly, authMiddleware } from '../middleware/auth';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const shareRouter = new Hono<{ Bindings: Env; Variables: V }>();

// POST /api/v1/share — 生成分享链接（body: { payload, ttl_hours }，payload 为对账单结构化 JSON）
shareRouter.post('/', authMiddleware(), adminOnly(), async (c) => {
  const body = await c.req.json().catch(() => null) as
    | { payload?: string; ttl_hours?: number }
    | null;
  const payload = typeof body?.payload === 'string' ? body.payload.slice(0, 200000) : '';
  if (!payload) return c.json({ error: '缺少分享内容' }, 400);
  const ttl = Number(body?.ttl_hours) || 72;
  const token = randomId();
  const expiresAt = ttl > 0 ? new Date(Date.now() + ttl * 3600 * 1000).toISOString() : null;
  await c.env.DB.prepare('INSERT INTO share_links (token, payload, expires_at) VALUES (?, ?, ?)')
    .bind(token, payload, expiresAt).run();
  const url = `${new URL(c.req.url).origin}/share/${token}`;
  return c.json({ token, url, expires_at: expiresAt }, 201);
});

// GET /api/v1/share — 我的分享列表（最近在前，含到期时间与预览），用于随时取消/删除
shareRouter.get('/', authMiddleware(), adminOnly(), async (c) => {
  const rows = await c.env.DB.prepare(
    `SELECT token, expires_at, created_at, substr(payload, 1, 120) AS preview
     FROM share_links ORDER BY created_at DESC LIMIT 100`,
  ).all<{ token: string; expires_at: string | null; created_at: string; preview: string }>();
  const origin = new URL(c.req.url).origin;
  const now = new Date().toISOString();
  return c.json({
    shares: rows.results.map((r) => ({
      token: r.token,
      url: `${origin}/share/${r.token}`,
      expires_at: r.expires_at,
      created_at: r.created_at,
      expired: r.expires_at !== null && r.expires_at < now,
      preview: r.preview,
    })),
  });
});

// DELETE /api/v1/share/:token — 取消分享（删除链接，页面随即 404）
shareRouter.delete('/:token', authMiddleware(), adminOnly(), async (c) => {
  const token = c.req.param('token');
  const r = await c.env.DB.prepare('DELETE FROM share_links WHERE token = ?').bind(token).run();
  if ((r.meta.changes ?? 0) === 0) return c.json({ error: '分享不存在' }, 404);
  return c.json({ ok: true });
});

/** 渲染分享页 HTML（payload 为前端构造的 { client, from, to, sales[], payments[], debt }） */
export function renderShareHtml(payloadJson: string): string {
  let data: Record<string, unknown> = {};
  try {
    data = JSON.parse(payloadJson) as Record<string, unknown>;
  } catch {
    data = {};
  }
  const esc = (v: unknown): string =>
    String(v ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  const fmt = (v: unknown): string => (Number(v || 0)).toFixed(2);
  const sales = Array.isArray(data.sales) ? (data.sales as Record<string, unknown>[]) : [];
  const payments = Array.isArray(data.payments) ? (data.payments as Record<string, unknown>[]) : [];
  const saleRows = sales
    .map((s) => `<tr><td>${esc(s.date)}</td><td>${esc(s.name)}</td><td>${esc(s.items)}</td><td class="num">¥${fmt(s.amount)}</td></tr>`)
    .join('');
  const payRows = payments
    .map((p) => {
      const w = Number(p.waived || 0);
      return `<tr><td>${esc(p.date)}</td><td>${esc(p.method || '—')}</td><td class="num">¥${fmt(p.amount)}</td>${w > 0 ? `<td class="num">¥${fmt(w)}</td>` : '<td class="num">—</td>'}</tr>`;
    })
    .join('');
  const totalSales = sales.reduce((s, x) => s + Number(x.amount || 0), 0);
  const totalPaid = payments.reduce((s, x) => s + Number(x.amount || 0), 0);
  return `<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>对账单 · 陶朱</title>
<style>
  body { font-family: -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif; margin: 0; padding: 16px; background: #F5F7FA; color: #111827; }
  .card { background: #fff; border-radius: 12px; padding: 18px; max-width: 640px; margin: 0 auto 12px; box-shadow: 0 2px 8px rgba(0,0,0,.05); }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .meta { color: #909399; font-size: 13px; margin-bottom: 4px; }
  .sum { font-size: 22px; font-weight: 800; color: #EF4444; }
  h2 { font-size: 15px; margin: 14px 0 8px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 6px 4px; border-bottom: 1px solid #f0f0f0; }
  th { color: #909399; font-weight: 500; }
  .num { text-align: right; font-variant-numeric: tabular-nums; }
  .footer { color: #909399; font-size: 12px; text-align: center; margin-top: 12px; }
</style>
</head>
<body>
  <div class="card">
    <h1>${esc(data.client || '对账单')}</h1>
    <div class="meta">账期：${esc(data.from || '')} 至 ${esc(data.to || '')}</div>
    <div class="sum">期末欠款 ¥${fmt(data.debt)}</div>
    <h2>出货明细（${sales.length} 笔）</h2>
    <table><thead><tr><th>日期</th><th>店铺/商品</th><th>明细</th><th class="num">金额</th></tr></thead><tbody>${saleRows || '<tr><td colspan="4">无</td></tr>'}</tbody></table>
    <h2>收款明细（${payments.length} 笔）</h2>
    <table><thead><tr><th>日期</th><th>方式</th><th class="num">实收</th><th class="num">平账</th></tr></thead><tbody>${payRows || '<tr><td colspan="4">无</td></tr>'}</tbody></table>
    <div class="meta" style="margin-top:12px">出货合计 ¥${fmt(totalSales)} · 收款合计 ¥${fmt(totalPaid)}</div>
    <div class="footer">由「陶朱进销存」生成 · 数据来自 ${esc(data.from || '')} 至 ${esc(data.to || '')}</div>
  </div>
</body>
</html>`;
}