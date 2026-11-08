/**
 * 对账差额 → 商品级「可能漏记行」的确定性推断。
 *
 * 场景：「对方比我多 10 元」→ 用该店真实存在过的单价反推出
 * 「豆腐 5 块 × 2 元 = 10 元」这类候选，帮人快速翻小票找漏记的那一行。
 *
 * 边界（刻意如此，别放宽）：
 *  - 单价只来自库里真实存在的三种来源：该店历史成交价 / 店铺价格组 / 通用价目表；
 *  - 组合由整数分枚举算出，绝不交给大模型心算，也绝不生成任何单据、金额或商品名；
 *  - 结果是「按单价反推的猜测」，不是账本里发生过的业务，必须显式标注待核对；
 *  - 差额绝不反向变成补录金额，补录仍需用户明说店铺 + 金额 + 日期并确认。
 */
import type { D1Database } from '@cloudflare/workers-types';

export type PriceSource = '该店历史成交价' | '店铺专属价' | '通用价目表';
/** theirs_more = 对方账比我们多（多半我方漏记/少记）；ours_more = 我们账比对方多（多半重复录/多记） */
export type DiffSide = 'theirs_more' | 'ours_more' | null;

export interface UnitPrice {
  name: string;
  unit: string;
  priceCents: number;
  source: PriceSource;
  /** 该店历史按此单价出货的次数（价目表来源为 0） */
  freq: number;
  /** 该店历史最常见的数量，用来给候选排序 */
  typicalQtys: number[];
}

export interface DiffPart {
  name: string;
  unit: string;
  qty: number;
  priceCents: number;
  subtotalCents: number;
  source: PriceSource;
  freq: number;
  typicalQtys: number[];
}

export interface DiffHint {
  parts: DiffPart[];
  totalCents: number;
  /** 0 = 精确等于差额；>0 = 与差额的差值（抹零/舍入容差内） */
  gapCents: number;
  score: number;
}

type PriceRow = { name: string; unit: string; price_cents: number };

export function toCents(v: number): number {
  const n = Math.round((Number(v) || 0) * 100);
  return Number.isFinite(n) ? n : 0;
}

export function fmtCents(c: number): string {
  return (Math.round(c) / 100).toFixed(2);
}

export function fmtQty(q: number): string {
  return String(Math.round(q * 100) / 100);
}

/** 兜底从用户原话抽差额（「差 380」「对方比我多了 10 元」「对不上 1,200」） */
export function extractDiffAmount(text: string): number | null {
  const m = text.match(/(?:差|对不上|差额|相差|多|少)[^\d]{0,8}([\d,]+(?:\.\d+)?)/);
  if (!m) return null;
  const n = Number(m[1].replace(/,/g, ''));
  return Number.isFinite(n) && n > 0 && n < 10_000_000 ? n : null;
}

/** 兜底判断差额方向；判断不出返回 null，输出里两种方向都提示 */
export function extractDiffSide(text: string): DiffSide {
  // 「我比对方多 / 对方少」优先，避免被下面「对方…多」的宽匹配反过来吃掉。
  // 「我」必须处在句首或标点之后：否则「对方比我多了 10 元」里的「我多了」会被误当成我方更多。
  const ours = /(?:^|[，。；！？\s])我(?:方|们)?(?:的?账)?(?:上)?比(?:对方|他|客户|那边|他们)|对方(?:的?账)?(?:上)?(?:比我)?(?:少|低)|(?:^|[，。；！？\s])我(?:方|们)?(?:的?账|这边)?(?:上)?多(?:了|出)/;
  if (ours.test(text)) return 'ours_more';
  if (/(?:对方|他|客户|那边|他们)(?:的?账)?(?:上)?(?:比我)?(?:多|高)|比我多|比我高/.test(text)) {
    return 'theirs_more';
  }
  return null;
}

/**
 * 取可用于反推的真实单价：clientId 为空时退化为全库口径（用户没说店名也能给线索）。
 * 店史取最近 300 行（一次对账查询，成本可控），再补店铺专属价与通用价目表，
 * 让「这个店今天没卖过、但价目表里有」的商品也能参与推断。
 */
export async function loadClientUnitPrices(db: D1Database, clientId: string | null): Promise<UnitPrice[]> {
  type HistRow = PriceRow & { quantity: number };
  const [hist, group, general] = await Promise.all([
    db.prepare(
      `SELECT COALESCE(i.name, '商品#' || si.item_id) AS name, si.unit AS unit,
              CAST(ROUND(si.sale_price * 100) AS INTEGER) AS price_cents, si.quantity AS quantity
       FROM sale_items si LEFT JOIN items i ON i.id = si.item_id
       WHERE (? IS NULL OR si.client_id = ?) AND si.sale_price > 0
       ORDER BY si.happened_at DESC, si.created_at DESC LIMIT 300`,
    ).bind(clientId, clientId).all<HistRow>(),
    db.prepare(
      `SELECT DISTINCT i.name AS name, g.unit AS unit, CAST(ROUND(g.sale_price * 100) AS INTEGER) AS price_cents
       FROM item_group_prices g JOIN items i ON i.id = g.item_id
       WHERE g.sale_price > 0 AND i.deleted_at IS NULL
         AND (? IS NULL OR g.group_id = (SELECT price_group_id FROM clients WHERE id = ?))
       LIMIT 60`,
    ).bind(clientId, clientId).all<PriceRow>(),
    db.prepare(
      `SELECT i.name AS name, ip.unit AS unit, CAST(ROUND(ip.sale_price * 100) AS INTEGER) AS price_cents
       FROM item_prices ip JOIN items i ON i.id = ip.item_id
       WHERE ip.active = 1 AND ip.sale_price > 0 AND i.deleted_at IS NULL LIMIT 80`,
    ).all<PriceRow>(),
  ]);

  const keyOf = (name: string, unit: string, priceCents: number) => `${name}|${unit}|${priceCents}`;
  const acc = new Map<string, UnitPrice & { qtyCount: Map<number, number> }>();
  for (const r of hist.results) {
    const priceCents = Math.round(Number(r.price_cents) || 0);
    if (priceCents <= 0) continue;
    const name = String(r.name || '未知商品').trim();
    const unit = String(r.unit || '').trim();
    const key = keyOf(name, unit, priceCents);
    let e = acc.get(key);
    if (!e) {
      e = {
        name, unit, priceCents, source: '该店历史成交价', freq: 0,
        typicalQtys: [], qtyCount: new Map<number, number>(),
      };
      acc.set(key, e);
    }
    e.freq += 1;
    const q = Number(r.quantity);
    if (Number.isFinite(q) && q > 0) e.qtyCount.set(q, (e.qtyCount.get(q) ?? 0) + 1);
  }
  const prices: UnitPrice[] = [...acc.values()].map((e) => ({
    name: e.name, unit: e.unit, priceCents: e.priceCents, source: e.source, freq: e.freq,
    typicalQtys: [...e.qtyCount.entries()].sort((a, b) => b[1] - a[1]).slice(0, 3).map((x) => x[0]),
  }));

  const seen = new Set(acc.keys());
  const addCatalog = (rows: PriceRow[], source: PriceSource) => {
    for (const r of rows) {
      const priceCents = Math.round(Number(r.price_cents) || 0);
      if (priceCents <= 0) continue;
      const name = String(r.name || '未知商品').trim();
      const unit = String(r.unit || '').trim();
      const key = keyOf(name, unit, priceCents);
      if (!name || seen.has(key)) continue;
      seen.add(key);
      prices.push({ name, unit, priceCents, source, freq: 0, typicalQtys: [] });
    }
  };
  addCatalog(group.results, '店铺专属价');
  addCatalog(general.results, '通用价目表');

  // 店史优先（按出现次数），价目表补位；单一店铺最多 36 种单价，避免组合爆炸
  return prices
    .sort((a, b) => b.freq - a.freq || a.priceCents - b.priceCents || a.name.localeCompare(b.name))
    .slice(0, 36);
}

/** 单价能整除目标金额时返回数量（允许 0.5 步进，覆盖 1.5 斤这类称重商品） */
function exactQty(targetCents: number, priceCents: number): number | null {
  if (priceCents <= 0 || targetCents <= 0) return null;
  const twice = targetCents * 2;
  if (twice % priceCents !== 0) return null;
  return twice / priceCents / 2;
}

function partOf(p: UnitPrice, qty: number): DiffPart {
  return {
    name: p.name, unit: p.unit, qty, priceCents: p.priceCents,
    subtotalCents: Math.round(p.priceCents * qty), source: p.source,
    freq: p.freq, typicalQtys: p.typicalQtys,
  };
}

function scoreOf(parts: DiffPart[], gapCents: number): number {
  let s = parts.length * 100 + gapCents * 3;
  for (const p of parts) {
    if (p.source === '该店历史成交价') s -= 30;
    else if (p.source === '店铺专属价') s -= 15;
    s -= Math.min(p.freq, 20) * 2;
    s += Math.floor(p.qty / 10) * 2;
    if (p.typicalQtys.includes(p.qty)) s -= 20;
    else if (p.typicalQtys.length && p.qty > Math.max(...p.typicalQtys) * 4) s += 25;
  }
  return s;
}

function hintKey(parts: DiffPart[]): string {
  return parts
    .map((p) => `${p.name}|${p.unit}|${p.priceCents}|${p.qty}`)
    .sort()
    .join('+');
}

/**
 * 枚举「数量 × 真实单价 = 差额」的组合。
 * 单商品优先、该店常卖的优先、数量接近历史习惯的优先；
 * 精确凑不出时才给 ±0.5 / ±1 元的近似候选（抹零/舍入），并显式标注差值。
 */
export function findDiffHints(
  diff: number,
  prices: UnitPrice[],
  opts: { maxQty?: number; maxResults?: number } = {},
): DiffHint[] {
  const target = toCents(diff);
  const maxQty = Math.min(Math.max(opts.maxQty ?? 60, 1), 200);
  const maxResults = Math.min(Math.max(opts.maxResults ?? 6, 1), 20);
  if (target <= 0 || prices.length === 0) return [];
  const pool = prices.filter((p) => p.priceCents > 0).slice(0, 36);

  const enumerate = (want: number, gapCents: number): DiffHint[] => {
    const out = new Map<string, DiffHint>();
    const push = (parts: DiffPart[]) => {
      const key = hintKey(parts);
      if (out.has(key)) return;
      out.set(key, {
        parts, totalCents: parts.reduce((s, p) => s + p.subtotalCents, 0),
        gapCents, score: scoreOf(parts, gapCents),
      });
    };
    // ① 单商品：数量自动由除法得出，覆盖「5 块 × 2 元 = 10 元」
    for (const p of pool) {
      const q = exactQty(want, p.priceCents);
      if (q !== null && q >= 0.5 && q <= maxQty) push([partOf(p, q)]);
    }
    // ② 两种商品叠加：只对整数数量枚举，且限制候选总量防噪声
    outer: for (const a of pool) {
      for (let qa = 1; qa <= maxQty; qa += 1) {
        const sub = a.priceCents * qa;
        if (sub >= want) break;
        const rest = want - sub;
        for (const b of pool) {
          if (b === a || rest % b.priceCents !== 0) continue;
          const qb = rest / b.priceCents;
          if (qb < 1 || qb > maxQty) continue;
          push([partOf(a, qa), partOf(b, qb)]);
          if (out.size >= 600) break outer;
        }
      }
    }
    return [...out.values()];
  };

  let all = enumerate(target, 0);
  if (all.length === 0) {
    // 抹零/进位常造成 0.5 / 1 元的零头差；只在精确无解时给近似，并明确标注
    for (const delta of [50, -50, 100, -100]) {
      const want = target + delta;
      if (want > 0) all.push(...enumerate(want, Math.abs(delta)));
    }
  }
  return all.sort((a, b) => a.score - b.score || a.gapCents - b.gapCents || a.totalCents - b.totalCents)
    .slice(0, maxResults);
}

/** 可用单价表：把「原始数据」交给模型，让模型自己按数量 × 单价推理组合，而不是只复述算好的结论 */
export function formatPriceTable(prices: UnitPrice[], limit = 24): string[] {
  const lines = [
    `--- 可用单价表（库里真实存在的单价，共 ${prices.length} 种；可用「数量 × 单价」自由组合推理）---`,
  ];
  if (!prices.length) {
    lines.push('（暂无商品单价数据，请先在商品/价目表维护单价）');
    return lines;
  }
  for (const p of prices.slice(0, limit)) {
    const src = p.source === '该店历史成交价'
      ? `该店出过 ${p.freq} 次${p.typicalQtys.length ? `，常见数量 ${p.typicalQtys.map(fmtQty).join('/')}` : ''}`
      : p.source;
    lines.push(`- ${p.name} / ${p.unit || '无单位'} / ${fmtCents(p.priceCents)} 元（${src}）`);
  }
  if (prices.length > limit) {
    lines.push(`（其余 ${prices.length - limit} 种单价略；可让用户指定商品或缩小日期区间后再查）`);
  }
  return lines;
}

/**
 * 算术校验表：服务端枚举只用于「核对模型算得对不对」，不是标准答案，也不限制推理范围。
 * 模型应基于原始商品行明细 + 单价表自主推理（含表外的多笔叠加、重复登记、抹零等），
 * 但任何「数量 × 单价 = 差额」的说法都必须能用单价表里的真实单价算出来。
 */
export function formatDiffHints(diff: number, hints: DiffHint[], side: DiffSide): string[] {
  const lines = [
    `--- 差额 ${fmtCents(toCents(diff))} 元的算术校验表（服务端按真实单价枚举，用来核对推理，不是标准答案）---`,
  ];
  if (!hints.length) {
    lines.push('按现有单价凑不出这个数额；请结合原始明细自行判断是不是单价录错、跨店/跨区间、抹零或双方口径不同，不要硬凑。');
    return lines;
  }
  for (const h of hints) {
    const expr = h.parts
      .map((p) => `${p.name} ${fmtQty(p.qty)}${p.unit ? ` ${p.unit}` : ''} × ${fmtCents(p.priceCents)} 元 = ${fmtCents(p.subtotalCents)} 元`)
      .join(' + ');
    const src = h.parts.map((p) => {
      if (p.source === '该店历史成交价') {
        return `本店按此单价出过 ${p.freq} 次${p.typicalQtys.length ? `、常见数量 ${p.typicalQtys.map(fmtQty).join('/')}` : ''}`;
      }
      return `${p.source}（本店暂无此单价的成交记录）`;
    }).join('；');
    lines.push(`- ${expr}${h.gapCents ? `，与差额相差 ${fmtCents(h.gapCents)} 元（可能抹零/舍入）` : ''}；${src}。`);
  }
  lines.push('此表仅用于核对算术：表里的组合只是算术可能、不是账本里已发生的单据，也不必逐条复述。请结合上面的「原始商品行明细 + 可用单价表」自行推理其他可能（多笔叠加、重复登记、边界日、抹零等）；任何「数量 × 单价 = 差额」的说法都必须能用单价表里的真实单价算出，不得编造商品、单价或单据。结论一律标注待核对，不要据此自动补单或把差额当作应收金额。');
  // 方向只陈述用户原话这个事实，「谁多意味着该查漏记还是重复登记」属于推理，交给模型
  if (side === 'theirs_more') {
    lines.push(`方向：用户说「对方账比我们多 ${fmtCents(toCents(diff))} 元」。`);
  } else if (side === 'ours_more') {
    lines.push(`方向：用户说「我们账比对方多 ${fmtCents(toCents(diff))} 元」。`);
  } else {
    lines.push('方向：用户未说明谁比谁多。');
  }
  return lines;
}
