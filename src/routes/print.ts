/** 单据打印：生成自包含 HTML（出货单/进货单），Web 端用 query token 打开后自动打印。
 *  类似对账单分享的渲染方式，但带鉴权（token 必填）且聚焦单条记录。 */
import { Hono } from 'hono';
import { verifyToken } from '../lib/jwt';
import type { Env } from '../types';

export const printRouter = new Hono<{ Bindings: Env }>();

const fmtMoney = (n: number) => (Number.isFinite(n) ? n.toFixed(2) : '0.00');

const esc = (s: unknown) =>
  String(s ?? '').replace(/[&<>"']/g, (ch) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch] as string
  ));

const page = (title: string, bodyHtml: string) => `<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8">
<title>${esc(title)}</title>
<style>
  body { font-family: "PingFang SC","Microsoft YaHei",sans-serif; margin: 24px; color: #222; }
  h1 { font-size: 20px; text-align: center; margin: 0 0 4px; }
  .meta { text-align: center; color: #666; font-size: 13px; margin-bottom: 16px; }
  table { width: 100%; border-collapse: collapse; font-size: 14px; }
  th, td { border: 1px solid #ccc; padding: 7px 8px; text-align: left; }
  th { background: #f5f5f5; }
  .num { text-align: right; }
  .total-row td { font-weight: 700; background: #fafafa; }
  .note { margin-top: 12px; font-size: 13px; color: #555; }
  .actions { margin-top: 24px; text-align: center; }
  .actions button { padding: 10px 28px; font-size: 15px; }
  @media print { .actions { display: none; } }
</style></head>
<body>
${bodyHtml}
<div class="actions"><button onclick="window.print()">打印 / 另存为 PDF</button></div>
<script>window.addEventListener('load', () => setTimeout(() => window.print(), 300));</script>
</body></html>`;

const fmtDate = (d: unknown) => {
  const s = String(d ?? '').slice(0, 10);
  return s || '-';
};

printRouter.get('/sale/:id', async (c) => {
  const token = c.req.query('token') ?? '';
  const payload = await verifyToken(c.env.JWT_SECRET, token);
  if (!payload) return c.json({ error: '未授权' }, 401);
  const id = c.req.param('id');
  // 行级主记录查询（去单据化：头字段由行聚合）
  const rows = await c.env.DB.prepare(
    `SELECT si.*, i.name AS item_name FROM sale_items si LEFT JOIN items i ON i.id = si.item_id
     WHERE si.sale_id = ? ORDER BY si.created_at`,
  ).bind(id).all<Record<string, unknown>>();
  if (rows.results.length === 0) return c.json({ error: '记录不存在' }, 404);
  const first = rows.results[0];
  const client = await c.env.DB.prepare('SELECT name FROM clients WHERE id = ?')
    .bind(first.client_id).first<{ name: string }>();
  const clientName = client?.name ?? '';
  const happenedAt = rows.results.map((r) => `${r.happened_at ?? ''}`).reduce((a, b) => (a >= b ? a : b), '');
  const total = rows.results.reduce((s, r) => s + (Number(r.amount) || 0), 0);
  const itemsHtml = rows.results.map((r) => `            <tr>
              <td>${esc(r.item_name || '（无明细）')}</td>
              <td>${esc(r.unit)}</td>
              <td class="num">${Number(r.quantity) || 0}</td>
              <td class="num">${fmtMoney(Number(r.sale_price) || 0)}</td>
              <td class="num">${fmtMoney(Number(r.amount) || 0)}</td>
            </tr>`).join('\n');
  return c.html(page(`出货单 ${clientName}`, `
<h1>出货单</h1>
<div class="meta">店铺：${esc(clientName)}　日期：${esc(happenedAt)}　单号：${esc(id.slice(0, 8))}</div>
<table>
  <thead><tr><th>商品</th><th>单位</th><th style="width:70px">数量</th><th style="width:90px" class="num">单价</th><th style="width:100px" class="num">金额</th></tr></thead>
  <tbody>
${itemsHtml}
  </tbody>
  <tfoot>
    <tr class="total-row"><td colspan="4" style="text-align:right">合计</td><td class="num">${fmtMoney(total)}</td></tr>
  </tfoot>
</table>
${String(first.note ?? '').trim() ? `<div class="note">备注：${esc(first.note)}</div>` : ''}`));
});

printRouter.get('/purchase/:id', async (c) => {
  const token = c.req.query('token') ?? '';
  const payload = await verifyToken(c.env.JWT_SECRET, token);
  if (!payload) return c.json({ error: '未授权' }, 401);
  const id = c.req.param('id');
  const rows = await c.env.DB.prepare(
    `SELECT pi.*, i.name AS item_name FROM purchase_items pi LEFT JOIN items i ON i.id = pi.item_id
     WHERE pi.purchase_id = ? ORDER BY pi.created_at`,
  ).bind(id).all<Record<string, unknown>>();
  if (rows.results.length === 0) return c.json({ error: '记录不存在' }, 404);
  const first = rows.results[0];
  const happenedAt = rows.results.map((r) => `${r.happened_at ?? ''}`).reduce((a, b) => (a >= b ? a : b), '');
  const total = rows.results.reduce((s, r) => s + (Number(r.amount) || 0), 0);
  const itemsHtml = rows.results.map((r) => `            <tr>
              <td>${esc(r.item_name || '（无明细）')}</td>
              <td>${esc(r.unit)}</td>
              <td class="num">${Number(r.quantity) || 0}</td>
              <td class="num">${fmtMoney(Number(r.purchase_price) || 0)}</td>
              <td class="num">${fmtMoney(Number(r.amount) || 0)}</td>
            </tr>`).join('\n');
  return c.html(page(`进货单 - ${happenedAt}`, `
<h1>进货单</h1>
<div class="meta">日期：${esc(happenedAt)}　单号：${esc(id.slice(0, 8))}</div>
<table>
  <thead><tr><th>商品</th><th>单位</th><th style="width:70px">数量</th><th style="width:90px" class="num">单价</th><th style="width:100px" class="num">金额</th></tr></thead>
  <tbody>
${itemsHtml}
  </tbody>
  <tfoot>
    <tr class="total-row"><td colspan="4" style="text-align:right">合计</td><td class="num">${fmtMoney(total)}</td></tr>
  </tfoot>
</table>
${String(first.note ?? '').trim() ? `<div class="note">备注：${esc(first.note)}</div>` : ''}`));
});