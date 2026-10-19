// 对账单模板渲染库（从 App statement_tmpl.dart 移植）：XlsCfg 网格 → 行集合。
// 预览/图片打印/Excel 共用；与 App 渲染结果同构（变量替换/日期点分/=sum 公式/尾列剪枝/标题去重）。

export interface GridCell {
  t: string; a: string; b: boolean; g: string;
  rs: number; cs: number; bt: boolean; br: boolean; bb: boolean; bl: boolean;
}

export interface TmplComp {
  type: string; text: string; align: string;
}

export interface XlsCfg {
  name: string; title: string; orientation: string;
  content: string; grid: GridCell[][]; colAligns: string[]; comps: TmplComp[];
  headClient: boolean; headPeriod: boolean; headSaleTotal: boolean;
  headPayTotal: boolean; headDebt: boolean; mode: string;
  colDate: boolean; colItem: boolean; colQty: boolean; colPrice: boolean; colAmount: boolean;
}

export interface TemplateData {
  sales: Array<Record<string, any>>;
  payments: Array<Record<string, any>>;
  from: string; to: string; clientName: string;
  debtEnd: number; debtUnit: string; roundMode: boolean; displayUnit: string;
}

export function gridCell(t = '', a = 'left', b = false, g = '', rs = 1, cs = 1,
    bt = true, br = true, bb = true, bl = true): GridCell {
  return { t, a, b, g, rs, cs, bt, br, bb, bl };
}

export function xlsCfgFromJson(j: Record<string, any>): XlsCfg {
  const rawGrid = j['grid'];
  const grid: GridCell[][] = [];
  if (Array.isArray(rawGrid)) {
    for (const row of rawGrid) {
      if (!Array.isArray(row)) continue;
      grid.push(row.filter((c): c is Record<string, any> => !!c && typeof c === 'object').map((c) => ({
        t: String(c['t'] ?? ''), a: String(c['a'] ?? 'left'), b: !!c['b'], g: String(c['g'] ?? ''),
        rs: Number(c['rs'] ?? 1) || 1, cs: Number(c['cs'] ?? 1) || 1,
        bt: c['bt'] !== false, br: c['br'] !== false, bb: c['bb'] !== false, bl: c['bl'] !== false,
      })));
    }
  }
  const rawComps = j['comps'];
  const comps: TmplComp[] = [];
  if (Array.isArray(rawComps)) {
    for (const c of rawComps) {
      if (c && typeof c === 'object') comps.push({ type: String(c['type'] ?? 'text'), text: String(c['text'] ?? ''), align: String(c['align'] ?? 'left') });
    }
  }
  return {
    name: String(j['name'] ?? '标准'), title: String(j['title'] ?? '陶朱对账单'),
    orientation: j['orientation'] === 'landscape' ? 'landscape' : 'portrait',
    content: String(j['content'] ?? ''), grid, comps,
    colAligns: Array.isArray(j['colAligns']) ? j['colAligns'].map((a: any) => String(a ?? 'left')) : [],
    headClient: j['headClient'] !== false, headPeriod: j['headPeriod'] !== false,
    headSaleTotal: j['headSaleTotal'] !== false, headPayTotal: j['headPayTotal'] !== false,
    headDebt: j['headDebt'] !== false, mode: String(j['mode'] ?? 'detail'),
    colDate: j['colDate'] !== false, colItem: j['colItem'] !== false,
    colQty: j['colQty'] !== false, colPrice: j['colPrice'] !== false, colAmount: j['colAmount'] !== false,
  };
}

// ── 工具 ────────────────────────────────

function dateOf(v: any): string {
  const s = String(v ?? '');
  return s.length >= 10 ? s.slice(0, 10) : s;
}

function numOf(v: any): number {
  const n = typeof v === 'number' ? v : parseFloat(String(v ?? ''));
  return isNaN(n) ? 0 : n;
}

function roundVal(d: TemplateData, v: number): number {
  return d.roundMode ? Math.round(v * 100) / 100 : v;
}

function fmtMoney(v: number): string {
  return (Math.round(v * 100) / 100).toFixed(2);
}

function fmtMoneyU(v: number, unit: string): string {
  if (unit === 'yuan') return `${Math.round(v)}`;
  if (unit === 'jiao') return v.toFixed(1);
  return fmtMoney(v);
}

function numU(v: number, unit: string): string {
  if (unit === 'yuan') return `${Math.round(v)}`;
  if (unit === 'jiao') return v.toFixed(1);
  return (Math.round(v * 100) / 100).toFixed(2);
}

/// 出货按日聚合（from 所在月 1..月末，无数据日=0）
function dailyOf(d: TemplateData): { days: number[]; total: number } {
  const y = parseInt(d.from.slice(0, 4), 10) || new Date().getFullYear();
  const m = parseInt(d.from.slice(5, 7), 10) || new Date().getMonth() + 1;
  const daysInMonth = new Date(y, m, 0).getDate();
  const arr = new Array<number>(daysInMonth).fill(0);
  let total = 0;
  for (const s of d.sales) {
    const orderDate = dateOf(s['happened_at']);
    const items = Array.isArray(s['items']) ? s['items'] : [];
    for (const it of items) {
      const id = String(it['happened_at'] ?? '');
      const dd = id.length >= 10 ? id.slice(0, 10) : orderDate;
      if (dd.length < 10) continue;
      const dy = parseInt(dd.slice(0, 4), 10) || 0;
      const dm = parseInt(dd.slice(5, 7), 10) || 0;
      if (dy !== y || dm !== m) continue;
      const day = parseInt(dd.slice(8, 10), 10) || 1;
      if (day < 1 || day > daysInMonth) continue;
      const v = roundVal(d, numOf(it['amount']));
      arr[day - 1] += v;
      total += v;
    }
  }
  return { days: arr, total };
}

/// 出货明细行（每件商品一行）
function detailLines(d: TemplateData): string[][] {
  const out: string[][] = [];
  for (const s of d.sales) {
    const orderDate = dateOf(s['happened_at']);
    const items = Array.isArray(s['items']) ? s['items'] : [];
    if (items.length === 0) {
      const note = String(s['note'] ?? '').trim();
      out.push([orderDate, note ? note : '（无明细）', '', fmtMoneyU(numOf(s['total']), d.displayUnit)]);
      continue;
    }
    for (const it of items) {
      const id = String(it['happened_at'] ?? '');
      const dstr = id.length >= 10 ? id.slice(0, 10) : orderDate;
      out.push([dstr, String(it['item_name'] ?? ''), `${it['quantity'] ?? ''}${it['unit'] ?? ''}`,
        fmtMoneyU(numOf(it['amount']), d.displayUnit)]);
    }
  }
  return out;
}

// ── 变量替换 ──────────────────────────────

function replaceVars(text: string, d: TemplateData): string {
  const now = new Date();
  const today = `${now.getFullYear()}.${now.getMonth() + 1}.${now.getDate()}`;
  const fromY = parseInt(d.from.slice(0, 4), 10) || now.getFullYear();
  const fromM = parseInt(d.from.slice(5, 7), 10) || now.getMonth() + 1;
  let saleTotal = 0;
  for (const s of d.sales) saleTotal += roundVal(d, numOf(s['total']));
  const daily = dailyOf(d);
  const payTotal = d.payments.reduce((a, p) => a + roundVal(d, numOf(p['amount']) + numOf(p['waived'])), 0);
  const segSum = (from: number, to: number) => {
    let s = 0;
    for (let i = from; i <= to && i <= daily.days.length; i++) s += daily.days[i - 1];
    return fmtMoneyU(s, d.displayUnit);
  };
  let line = text
      .replaceAll('{店铺}', d.clientName)
      .replaceAll('{账期}', `${d.from} 至 ${d.to}`)
      .replaceAll('{年}', `${fromY}`)
      .replaceAll('{月}', `${fromM}`)
      .replaceAll('{日}', `${now.getDate()}`)
      .replaceAll('{日期}', today)
      .replaceAll('{出货合计}', fmtMoneyU(saleTotal, d.displayUnit))
      .replaceAll('{收款合计}', fmtMoneyU(payTotal, d.displayUnit))
      .replaceAll('{期末欠款}', d.debtUnit === 'yuan' ? `${Math.round(d.debtEnd)}` : (d.debtUnit === 'jiao' ? d.debtEnd.toFixed(1) : fmtMoney(d.debtEnd)))
      .replaceAll('{出货笔数}', `${d.sales.length}`)
      .replaceAll('{月合计}', fmtMoneyU(daily.total, d.displayUnit))
      .replaceAll('{1-10日合计}', segSum(1, 10))
      .replaceAll('{11-20日合计}', segSum(11, 20))
      .replaceAll('{21-30日合计}', segSum(21, 30))
      .replaceAll('{21日以后合计}', segSum(21, 31));
  for (let dd = 1; dd <= 31; dd++) {
    const val = dd <= daily.days.length ? fmtMoneyU(daily.days[dd - 1], d.displayUnit) : '';
    line = line
        .replaceAll(`{${dd}日}`, val)
        .replaceAll(`{${dd}日销售额}`, val)
        .replaceAll(`${fromM}月${dd}日`, `${fromY}.${fromM}.${dd}`);
  }
  return line;
}

// ── =sum(...) 公式 ──────────────────────────────

function coordOf(ref: string): [number, number] | null {
  const m = /^([a-z]+)(\d+)$/i.exec(ref);
  if (!m) return null;
  let col = 0;
  for (const ch of m[1].toLowerCase()) col = col * 26 + (ch.charCodeAt(0) - 0x61 + 1);
  return [parseInt(m[2], 10) - 1, col - 1];
}

function numOfText(t: string): number | null {
  const s = t.replaceAll(',', '').replaceAll('¥', '').replaceAll('元', '').trim();
  if (!s) return 0;
  const n = parseFloat(s);
  return isNaN(n) ? null : n;
}

function cellValue(rows: GridCell[][], r: number, c: number, visiting: Set<string>, unit: string): number | null {
  if (r < 0 || r >= rows.length) return null;
  const row = rows[r];
  if (c < 0 || c >= row.length) return null;
  const key = `${r},${c}`;
  if (visiting.has(key)) return null;
  const t = row[c].t.trim();
  if (!t) return 0;
  if (t.startsWith('=')) {
    visiting.add(key);
    const ev = evalFormula(t, rows, visiting, unit);
    visiting.delete(key);
    return numOfText(ev);
  }
  return numOfText(t);
}

function evalFormula(text: string, rows: GridCell[][], visiting: Set<string>, unit: string): string {
  const m = /^=\s*([a-z]+)\s*\(([^)]*)\)\s*$/i.exec(text);
  if (!m) return text;
  if (m[1].toLowerCase() !== 'sum') return text;
  let total = 0;
  for (const part of m[2].split(',')) {
    const p = part.trim();
    if (!p) continue;
    if (p.includes(':')) {
      const seg = p.split(':');
      if (seg.length !== 2) return text;
      const a = coordOf(seg[0]);
      const b = coordOf(seg[1]);
      if (!a || !b) return text;
      for (let r = a[0]; r <= b[0]; r++) {
        for (let cc = a[1]; cc <= b[1]; cc++) {
          const v = cellValue(rows, r, cc, visiting, unit);
          if (v === null) return text;
          total += v;
        }
      }
    } else {
      const c = coordOf(p);
      if (!c) return text;
      const v = cellValue(rows, c[0], c[1], visiting, unit);
      if (v === null) return text;
      total += v;
    }
  }
  return fmtMoneyU(total, unit);
}

function evalFormulas(rows: GridCell[][], unit: string) {
  for (let r = 0; r < rows.length; r++) {
    for (let cc = 0; cc < rows[r].length; cc++) {
      const t = rows[r][cc].t.trim();
      if (!t.startsWith('=')) continue;
      const ev = evalFormula(t, rows, new Set<string>(), unit);
      if (ev !== t) rows[r][cc].t = ev;
    }
  }
}

// ── 尾列剪枝 ──────────────────────────────

function isTotalRow(row: GridCell[]): boolean {
  return row.length > 0 && (row[0].t.trim() === '合计' || row[0].t.trim() === '总计');
}

function pruneTailEmptyCols(rows: GridCell[][], dayRowIdx: Set<number>) {
  if (dayRowIdx.size === 0) return;
  let cols = 0;
  for (const r of rows) {
    let w = 0;
    for (const c of r) w += c.cs < 1 ? 1 : c.cs;
    cols = w > cols ? w : cols;
  }
  const colsToDelete = new Set<number>();
  for (let cc = cols - 1; cc >= 0; cc--) {
    let allEmpty = true;
    for (const ri of dayRowIdx) {
      if (ri >= rows.length) continue;
      const row = rows[ri];
      let acc = 0;
      let hit: GridCell | null = null;
      for (const c of row) {
        const sp = c.cs < 1 ? 1 : c.cs;
        if (cc >= acc && cc < acc + sp) { hit = c; break; }
        acc += sp;
      }
      if (hit && hit.t.trim()) { allEmpty = false; break; }
    }
    if (!allEmpty) break;
    colsToDelete.add(cc);
  }
  if (colsToDelete.size === 0) return;
  const targetWidth = cols - colsToDelete.size;
  for (let ri = 0; ri < rows.length; ri++) {
    const row = rows[ri];
    const newRow: GridCell[] = [];
    const deferred: GridCell[] = [];
    let acc = 0;
    for (const c of row) {
      const sp = c.cs < 1 ? 1 : c.cs;
      let overlap = 0;
      for (let i = acc; i < acc + sp; i++) if (colsToDelete.has(i)) overlap++;
      if (overlap > 0) {
        if (sp > 1) {
          if (sp - overlap > 0) {
            c.cs = sp - overlap;
            newRow.push(c);
          }
        } else if (isTotalRow(row) && c.t.trim()) {
          deferred.push(c);
        }
      } else {
        newRow.push(c);
      }
      acc += sp;
    }
    newRow.push(...deferred);
    while (newRow.length > targetWidth) {
      let removed = false;
      for (let i = newRow.length - 1; i >= 0; i--) {
        if (!newRow[i].t.trim() && newRow[i].cs === 1) {
          newRow.splice(i, 1);
          removed = true;
          break;
        }
      }
      if (!removed) break;
    }
    rows[ri] = newRow;
  }
}

// ── 渲染入口 ──────────────────────────────

function isTitleRow(r: GridCell[]): boolean {
  if (r.length !== 1) return false;
  const t = r[0].t.trim();
  return r[0].b && r[0].a === 'center' && (t.includes('对账单') || t.includes('月份账单') || t.includes('{店铺}'));
}

function finalizeRows(rows: GridCell[][], d: TemplateData): GridCell[][] {
  while (rows.length >= 2 && isTitleRow(rows[0]) && isTitleRow(rows[1])) rows.shift();
  const total = fmtMoneyU(dailyOf(d).total, d.displayUnit);
  for (const row of rows) {
    if (row.length === 0) continue;
    const label = row[0].t.trim();
    if (label === '合计' || label === '总计') {
      const hasOther = row.slice(1).some((c) => c.t.trim());
      if (!hasOther) {
        for (const c of row) {
          if (!c.t.trim()) { c.t = total; break; }
        }
      }
    }
  }
  return rows;
}

function multiColBill(d: TemplateData, perCol = 10, withTitle = true): GridCell[][] {
  const daily = dailyOf(d).days;
  const n = daily.length;
  const cols = Math.ceil(n / perCol);
  const y = parseInt(d.from.slice(0, 4), 10) || new Date().getFullYear();
  const m = parseInt(d.from.slice(5, 7), 10) || new Date().getMonth() + 1;
  const rows: GridCell[][] = [];
  if (withTitle) rows.push([gridCell(`${d.clientName}${m}月份账单`, 'center', true)]);
  rows.push(Array.from({ length: cols }, () => [gridCell('日期', 'center', true), gridCell('营业额', 'center', true)]).flat());
  for (let r = 0; r < perCol; r++) {
    const line: GridCell[] = [];
    for (let cc = 0; cc < cols; cc++) {
      const day = cc * perCol + r + 1;
      if (day <= n) {
        line.push(gridCell(`${y}.${m}.${day}`, 'center'));
        line.push(gridCell(numU(daily[day - 1], d.displayUnit), 'center'));
      } else {
        line.push(gridCell('', 'center'));
        line.push(gridCell('', 'center'));
      }
    }
    rows.push(line);
  }
  const subtotal: GridCell[] = [];
  let grand = 0;
  for (let cc = 0; cc < cols; cc++) {
    let s = 0;
    for (let dd = cc * perCol; dd < (cc + 1) * perCol && dd < n; dd++) s += daily[dd];
    grand += s;
    subtotal.push(gridCell('', 'center', true));
    subtotal.push(gridCell(numU(s, d.displayUnit), 'center', true));
  }
  rows.push(subtotal);
  rows.push([
    gridCell('总计', 'center', true),
    ...Array.from({ length: cols * 2 - 2 }, () => gridCell('', '')),
    gridCell(numU(grand, d.displayUnit), 'center', true),
  ]);
  return rows;
}

function renderComps(cfg: XlsCfg, d: TemplateData): GridCell[][] {
  const now = new Date();
  const today = `${now.getFullYear()}年${now.getMonth() + 1}月${now.getDate()}日`;
  const rows: GridCell[][] = [];
  let saleTotal = 0;
  for (const s of d.sales) saleTotal += roundVal(d, numOf(s['total']));
  const payTotal = d.payments.reduce((a, p) => a + roundVal(d, numOf(p['amount']) + numOf(p['waived'])), 0);
  const daily = dailyOf(d);
  for (const c of cfg.comps) {
    switch (c.type) {
      case 'title':
        rows.push([gridCell(replaceVars(c.text || '对账单', d), c.align)]);
        break;
      case 'fields':
        rows.push([gridCell(`店铺：${d.clientName}`, 'left')]);
        rows.push([gridCell(`账期：${d.from} 至 ${d.to}`, 'left')]);
        rows.push([gridCell(`日期：${today}`, 'left')]);
        break;
      case 'stats':
        rows.push([
          gridCell(`出货合计\n${fmtMoneyU(saleTotal, d.displayUnit)}`, 'center'),
          gridCell(`收款合计\n${fmtMoneyU(payTotal, d.displayUnit)}`, 'center'),
          gridCell(`期末欠款\n${fmtMoneyU(d.debtEnd, d.displayUnit)}`, 'center'),
        ]);
        break;
      case 'days':
        rows.push([gridCell('日期', 'center'), gridCell('销售额', 'center')]);
        let total = 0;
        for (let i = 0; i < daily.days.length; i++) {
          const v = daily.days[i];
          total += v;
          rows.push([gridCell(`${i + 1}日`, 'left'), gridCell(fmtMoneyU(v, d.displayUnit), 'center')]);
        }
        rows.push([gridCell('总计', 'center'), gridCell(fmtMoneyU(total, d.displayUnit), 'center')]);
        break;
      case 'multi':
        rows.push(...multiColBill(d));
        break;
      case 'detail':
        rows.push([gridCell('日期', 'center'), gridCell('商品', 'center'), gridCell('数量', 'center'), gridCell('金额', 'center')]);
        for (const r of detailLines(d)) {
          rows.push([gridCell(r[0], 'left'), gridCell(r[1], 'left'), gridCell(r[2], 'center'), gridCell(r[3], 'center')]);
        }
        break;
      default:
        for (const ln of replaceVars(c.text, d).split('\n')) rows.push([gridCell(ln, c.align)]);
    }
  }
  return rows;
}

function renderGrid(cfg: XlsCfg, d: TemplateData, evalSum = true): GridCell[][] {
  const out: GridCell[][] = [];
  const daily = dailyOf(d);
  const dayRowIdx = new Set<number>();
  const dayVarRe = /\{\d{1,2}日销售额\}|\{月\}月\d{1,2}日/;
  const hasMonthBill = cfg.grid.some((r) => r.some((c) => c.t.includes('{月账单}')));
  const maxDay = daily.days.length;
  const trimDay = (text: string): string => {
    let t = text.replace(/\{(\d{1,2})日销售额\}/g, (mm, g1) => {
      const n = parseInt(g1, 10) || 0;
      return n > maxDay ? '' : mm;
    });
    t = t.replace(/\{月\}月(\d{1,2})日/g, (mm, g1) => {
      const n = parseInt(g1, 10) || 0;
      return n > maxDay ? '' : mm;
    });
    return t;
  };
  for (let ri = 0; ri < cfg.grid.length; ri++) {
    const row = cfg.grid[ri];
    if (row.some((c) => c.t.includes('{月账单}'))) {
      const onlyRow = cfg.grid.length <= 1;
      out.push(...multiColBill(d, 10, onlyRow));
      continue;
    }
    if (row.some((c) => dayVarRe.test(c.t))) dayRowIdx.add(ri);
    const rendered = row.map((c, cc) => gridCell(
        replaceVars(trimDay(c.t), d),
        cc < cfg.colAligns.length && cfg.colAligns[cc] ? cfg.colAligns[cc] : c.a,
        c.b, c.g, c.rs, c.cs, c.bt, c.br, c.bb, c.bl));
    out.push(rendered);
  }
  if (evalSum) evalFormulas(out, d.displayUnit);
  if (!hasMonthBill) pruneTailEmptyCols(out, dayRowIdx);
  return out.filter((r) => r.some((c) => c.t.trim()));
}

/** 模板统一渲染入口：comps → grid → content → 默认；返回表格行集合（预览/图片打印/导出共用） */
export function renderTemplateRows(cfg: XlsCfg, d: TemplateData, evalSum = true): GridCell[][] {
  let rows: GridCell[][];
  if (cfg.comps.length > 0) {
    rows = renderComps(cfg, d);
  } else if (cfg.grid.length > 0) {
    rows = renderGrid(cfg, d, evalSum);
  } else if (cfg.content.trim()) {
    const day = dailyOf(d);
    rows = cfg.content.split('\n').map((raw) => [gridCell(replaceVars(raw, d), 'left')]);
  } else {
    const fallback: XlsCfg = { ...cfg, comps: [
      { type: 'title', text: cfg.title || '对账单', align: 'center' },
      { type: 'fields', text: '', align: 'left' },
      { type: 'days', text: '', align: 'left' },
    ] };
    rows = renderComps(fallback, d);
  }
  return finalizeRows(rows, d);
}

// ── 内置模板（对齐 App 内置「标准」「多栏」展开网格；无云端数据时回退）─────────────────

export function defaultStdTemplate(): XlsCfg {
  const grid: GridCell[][] = [
    [gridCell('{店铺} {月}月份账单', 'center', true, '', 1, 2)],
    [gridCell('日期', 'center', true), gridCell('营业额', 'center', true)],
    ...Array.from({ length: 31 }, (_, i) => [gridCell(`{月}月${i + 1}日`, 'center'), gridCell(`{${i + 1}日销售额}`, 'center')]),
    [gridCell('合计', 'center', true), gridCell('=sum(b3:b33)', 'center', true)],
  ];
  return {
    name: '标准', title: '陶朱对账单', orientation: 'portrait', content: '', grid,
    colAligns: [], comps: [], headClient: true, headPeriod: true, headSaleTotal: true,
    headPayTotal: true, headDebt: true, mode: 'detail', colDate: true, colItem: true,
    colQty: true, colPrice: true, colAmount: true,
  };
}

export function defaultMultiTemplate(): XlsCfg {
  const header = Array.from({ length: 4 }, () => [gridCell('日期', 'center', true), gridCell('营业额', 'center', true)]).flat();
  const body: GridCell[][] = [];
  for (let r = 0; r < 10; r++) {
    const line: GridCell[] = [];
    for (let cc = 0; cc < 4; cc++) {
      const day = cc * 10 + r + 1;
      if (day <= 31) {
        line.push(gridCell(`{月}月${day}日`, 'center'), gridCell(`{${day}日销售额}`, 'center'));
      } else {
        line.push(gridCell('', 'center'), gridCell('', 'center'));
      }
    }
    body.push(line);
  }
  const grid: GridCell[][] = [
    [gridCell('{店铺} {月}月份账单', 'center', true, '', 1, 8)],
    header,
    ...body,
    [
      gridCell('小计', 'center', true), gridCell('=sum(b3:b12)', 'center', true), gridCell('', ''),
      gridCell('=sum(d3:d12)', 'center', true), gridCell('', ''), gridCell('=sum(f3:f12)', 'center', true),
      gridCell('', ''), gridCell('=sum(h3:h3)', 'center', true),
    ],
    [
      gridCell('总计', 'center', true),
      ...Array.from({ length: 6 }, () => gridCell('', '')),
      gridCell('=sum(b13,d13,f13,h13)', 'center', true),
    ],
  ];
  return {
    name: '多栏', title: '陶朱对账单', orientation: 'portrait', content: '', grid,
    colAligns: [], comps: [], headClient: true, headPeriod: true, headSaleTotal: true,
    headPayTotal: true, headDebt: true, mode: 'detail', colDate: true, colItem: true,
    colQty: true, colPrice: true, colAmount: true,
  };
}
