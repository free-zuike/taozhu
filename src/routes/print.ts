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
  .order { page-break-after: always; }
  .order:last-child { page-break-after: auto; }
  .sub-title { font-size: 14px; font-weight: 700; margin: 14px 0 6px; }
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

printRouter.get('/template', async (c) => {
  const token = c.req.query('token') ?? '';
  const payload = await verifyToken(c.env.JWT_SECRET, token);
  if (!payload) return c.json({ error: '未授权' }, 401);
  const title = c.req.query('title')?.trim() || '对账单';
  const rowsB64 = c.req.query('rows') ?? '';
  if (!rowsB64) return c.json({ error: 'rows 缺失' }, 400);
  let rows: [string, string, boolean, string, number, number][][];
  try {
    const b64 = rowsB64.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(rowsB64.length / 4) * 4, '=');
    // 前端是 utf8.encode + base64 编码的 UTF-8 字节；atob 返回 Latin-1 字符串会把中文误解码（寻牛→å¯»ç）
    const bytes = Uint8Array.from(atob(b64), (ch) => ch.charCodeAt(0));
    const decoded = JSON.parse(new TextDecoder('utf-8').decode(bytes));
    if (!Array.isArray(decoded)) return c.json({ error: 'rows 格式错误' }, 400);
    rows = (decoded as unknown[][]).map((row) =>
      (row as unknown[][]).map((cell) => {
        const t = cell.length > 0 ? String(cell[0] ?? '') : '';
        const a = cell.length > 1 ? String(cell[1] ?? 'left') : 'left';
        const b = cell.length > 2 ? cell[2] === true : false;
        const g = cell.length > 3 ? String(cell[3] ?? '') : '';
        const rs = cell.length > 4 ? Number(cell[4]) || 1 : 1;
        const cs = cell.length > 5 ? Number(cell[5]) || 1 : 1;
        return [t, a, b, g, rs, cs];
      }),
    );
  } catch (_) {
    return c.json({ error: 'rows 解码失败' }, 400);
  }
  // 合并单元格渲染：colSpan/rowSpan > 1 → 该格扩张，被覆盖的格跳过（空 td 占位防错位）
  const covered = new Set<string>();
  const bodyRows = rows.map((row, r) => {
    if (covered.has(`r${r}`)) return ''; // 整行被上方 rowSpan 覆盖
    const cells: string[] = [];
    row.forEach((cell, c) => {
      const [t, a, b, g, rs, cs] = cell;
      if (covered.has(`${r}:${c}`)) return; // 已被左方 colSpan 覆盖
      for (let rr = r; rr < r + rs; rr++) covered.add(`r${rr}`);
      for (let cc = c; cc < c + cs; cc++) covered.add(`${r}:${cc}`);
      const ta = a === 'center' ? 'center' : a === 'right' ? 'right' : 'left';
      const fw = b ? 'font-weight:700;' : '';
      const bg = g === 'grey' ? 'background:#f2f2f2;' : '';
      const span = `${rs > 1 ? `rowspan="${rs}" ` : ''}${cs > 1 ? `colspan="${cs}" ` : ''}`.trim();
      cells.push(`<td ${span} style="text-align:${ta};${fw}${bg}">${esc(t) || ''}</td>`);
    });
    return cells.length ? '<tr>' + cells.join('') + '</tr>' : '';
  }).filter((x) => x !== '').join('\n');
  return c.html(page(title, `<h1>${esc(title)}</h1>
<table>
${bodyRows}
</table>`));
});

// GET /print/monthly?kind=sale|purchase&month=YYYY-MM&mode=detail|daily|period&client_id=&token=
// 按月打印：detail=当月逐单明细分页（每单一页）；daily=每日汇总（日期/笔数/件数/金额）；
// period=旬段汇总模板（标题"店名M月销售"居中 + 打印日期 + 1-10/11-20/21-30/31 日各配销售额列 + 总计）
printRouter.get('/monthly', async (c) => {
  const token = c.req.query('token') ?? '';
  const payload = await verifyToken(c.env.JWT_SECRET, token);
  if (!payload) return c.json({ error: '未授权' }, 401);
  const kind = c.req.query('kind') === 'purchase' ? 'purchase' : 'sale';
  const month = c.req.query('month')?.trim() ?? '';
  const mode = c.req.query('mode') ?? 'detail';
  const clientId = c.req.query('client_id')?.trim() ?? '';
  if (!/^\d{4}-\d{2}$/.test(month)) return c.json({ error: 'month 格式 YYYY-MM' }, 400);
  const mInt = Number(month.slice(5, 7));
  if (mInt < 1 || mInt > 12) return c.json({ error: 'month 月份超出 1-12' }, 400);
  const [y, m] = month.split('-').map(Number);
  const nextMonth = m === 12 ? `${y + 1}-01` : `${month.slice(0, 4)}-${String(m + 1).padStart(2, '0')}`;
  const table = kind === 'sale' ? 'sale_items' : 'purchase_items';
  const gidCol = kind === 'sale' ? 'sale_id' : 'purchase_id';
  const priceCol = kind === 'sale' ? 'sale_price' : 'purchase_price';
  const title = kind === 'sale' ? '出货' : '进货';
  const params: string[] = [`${month}-01`, nextMonth];
  let where = 'si.happened_at >= ? AND si.happened_at < ?';
  if (clientId && kind === 'sale') {
    where += ' AND si.client_id = ?';
    params.push(clientId);
  }

  // 旬段汇总模板（按实际日期逐日展开）：1日、2日…月末每天一行（无数据日=0）+ 全月总计
  if (mode === 'period') {
    const rows = await c.env.DB.prepare(
      `SELECT CAST(substr(si.happened_at, 9, 2) AS INTEGER) AS day, SUM(si.amount) AS total
       FROM ${table} si WHERE ${where}
       GROUP BY day ORDER BY day`,
    ).bind(...params).all<{ day: number; total: number }>();
    const client = clientId
      ? await c.env.DB.prepare('SELECT name FROM clients WHERE id = ?').bind(clientId).first<{ name: string }>()
      : null;
    const storeName = client?.name || '全部店铺';
    const now = new Date();
    const today = `${now.getFullYear()}年${now.getMonth() + 1}月${now.getDate()}日`;
    const dayMap = new Map(rows.results.map((r) => [r.day, Number(r.total) || 0]));
    const daysInMonth = new Date(y, m, 0).getDate();
    let grand = 0;
    const bodyRows: string[] = [];
    for (let d = 1; d <= daysInMonth; d++) {
      const v = dayMap.get(d) ?? 0;
      grand += v;
      bodyRows.push(`            <tr>
              <td>${d}日</td>
              <td class="num">${fmtMoney(v)}</td>
            </tr>`);
    }
    return c.html(page(`${storeName}${m}月${title}`, `<h1>${esc(storeName)}${m}月${title}</h1>
<div class="meta">${esc(today)}</div>
<table>
  <thead><tr><th>日期</th><th style="width:140px" class="num">销售额</th></tr></thead>
  <tbody>
${bodyRows.join('\n')}
  </tbody>
  <tfoot>
    <tr class="total-row"><td style="text-align:right">总计</td><td class="num">${fmtMoney(grand)}</td></tr>
  </tfoot>
</table>`));
  }

  if (mode === 'daily') {
    const rows = await c.env.DB.prepare(
      `SELECT substr(si.happened_at, 1, 10) AS d,
              COUNT(DISTINCT si.${gidCol}) AS cnt,
              COUNT(*) AS items,
              SUM(si.amount) AS total
       FROM ${table} si WHERE ${where}
       GROUP BY d ORDER BY d`,
    ).bind(...params).all<{ d: string; cnt: number; items: number; total: number }>();
    const body = rows.results.length === 0
      ? '<p style="text-align:center;color:#888">该月暂无记录</p>'
      : `<table>
  <thead><tr><th>日期</th><th style="width:80px" class="num">笔数</th><th style="width:80px" class="num">件数</th><th style="width:120px" class="num">金额</th></tr></thead>
  <tbody>
${rows.results.map((r) => `            <tr>
      <td>${esc(r.d)}</td>
      <td class="num">${r.cnt}</td>
      <td class="num">${r.items}</td>
      <td class="num">${fmtMoney(Number(r.total) || 0)}</td>
    </tr>`).join('\n')}
  </tbody>
  <tfoot>
    <tr class="total-row"><td colspan="3" style="text-align:right">合计</td><td class="num">${fmtMoney(rows.results.reduce((s, r) => s + (Number(r.total) || 0), 0))}</td></tr>
  </tfoot>
</table>`;
    return c.html(page(`${title}月报 ${month}（每日汇总）`, `<h1>${title}月报（每日汇总）</h1>
<div class="meta">月份：${esc(month)}${clientId ? '　单店' : '　全店'}</div>
${body}`));
  }

  // detail：逐单明细分页
  const rows = await c.env.DB.prepare(
    `SELECT si.*, i.name AS item_name, c.name AS client_name
     FROM ${table} si
     LEFT JOIN items i ON i.id = si.item_id
     LEFT JOIN clients c ON c.id = si.client_id
     WHERE ${where}
     ORDER BY si.happened_at, si.${gidCol}, si.created_at`,
  ).bind(...params).all<Record<string, unknown>>();
  if (rows.results.length === 0) {
    return c.html(page(`${title}月报 ${month}`, `<h1>${title}月报</h1>
<div class="meta">月份：${esc(month)}${clientId ? '　单店' : '　全店'}</div>
<p style="text-align:center;color:#888">该月暂无记录</p>`));
  }
  const orders = new Map<string, Record<string, unknown>[]>();
  const orderMeta = new Map<string, { happened_at: string; client_name: string; note: string }>();
  for (const r of rows.results) {
    const oid = `${r[gidCol] ?? ''}`;
    if (oid === '') continue;
    const list = orders.get(oid) ?? [];
    list.push(r);
    orders.set(oid, list);
    const prev = orderMeta.get(oid);
    const h = `${r.happened_at ?? ''}`;
    const cn = `${r.client_name ?? ''}`;
    const note = `${r.note ?? ''}`;
    if (!prev || h >= prev.happened_at) {
      orderMeta.set(oid, { happened_at: h, client_name: cn, note });
    }
  }
  const orderHtml = [...orders.entries()].map(([oid, items], i) => {
    const meta = orderMeta.get(oid)!;
    const total = items.reduce((s, r) => s + (Number(r.amount) || 0), 0);
    const rowsHtml = items.map((r) => `            <tr>
              <td>${esc(r.item_name || '（无明细）')}</td>
              <td>${esc(r.unit)}</td>
              <td class="num">${Number(r.quantity) || 0}</td>
              <td class="num">${fmtMoney(Number(r[priceCol]) || 0)}</td>
              <td class="num">${fmtMoney(Number(r.amount) || 0)}</td>
            </tr>`).join('\n');
    return `<div class="sub-title">${title}单 ${i + 1} / ${orders.size}</div>
<div class="meta" style="text-align:left">店铺：${esc(meta.client_name || '（全部）')}　日期：${esc(meta.happened_at.slice(0, 10))}　单号：${esc(oid.slice(0, 8))}</div>
<table>
  <thead><tr><th>商品</th><th>单位</th><th style="width:70px">数量</th><th style="width:90px" class="num">单价</th><th style="width:100px" class="num">金额</th></tr></thead>
  <tbody>
${rowsHtml}
  </tbody>
  <tfoot>
    <tr class="total-row"><td colspan="4" style="text-align:right">合计</td><td class="num">${fmtMoney(total)}</td></tr>
  </tfoot>
</table>
${String(meta.note).trim() ? `<div class="note">备注：${esc(meta.note)}</div>` : ''}
${i < orders.size - 1 ? '<div class="order"></div>' : ''}`;
  }).join('\n');
  return c.html(page(`${title}月报 ${month}（逐单明细）`, `<h1>${title}月报（逐单明细）</h1>
<div class="meta">月份：${esc(month)}${clientId ? '　单店' : '　全店'}　共 ${orders.size} 单</div>
${orderHtml}`));
});