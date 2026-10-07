/** 统计：工作台概览 / 按店 / 按月 —— 毛利 = Σ(售价-进价快照)*数量
 *  金额口径统一"每笔舍入后累加"（与单笔显示/账本对账一致）：原始浮点 SUM 后舍入
 *  在 digits=0/1 时（1.6+1.6=3.2→¥3）会与每笔显示（¥2+¥2）对不上。
 *  故各接口不再用 SQL SUM 聚合金额，改为取明细行 JS reduce roundMoney 逐笔累加。 */
import { Hono } from 'hono';
import { authMiddleware } from '../middleware/auth';
import { getRoundingConfig, roundMoney, normalizeRoundConfig, salesSideRounded, salesAggByConfig } from '../lib/money';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const statsRouter = new Hono<{ Bindings: Env; Variables: V }>();

statsRouter.use('*', authMiddleware());
// 店员可见统计但隐藏毛利：各接口已按 can_see_profit（admin 才 true）把 gross_profit 归零，
// 出货/收款/欠款对店员可见（送货视角需要）。不再全局 403（小程序工作台/统计页店员需能看）。
// 历史 v0.16.21 曾全挡 staff → 403，导致小程序店员「统计页没有权限查看」。

const nowIso = () => new Date().toISOString();

// GET /stats/overview?date=YYYY-MM-DD — 工作台卡片（今日出货/毛利/收款 + 全局欠款/规模）
statsRouter.get('/overview', async (c) => {
  const date = c.req.query('date')?.trim() || nowIso().slice(0, 10);
  const db = c.env.DB;
  const canSeeProfit = c.get('user').role === 'admin';
  const money = await getRoundingConfig(db);
  const r = (n: unknown) => roundMoney(Number(n || 0), money);

  const [todaySales, todayPays, todayBuys, allSales, allPays, counts] = await Promise.all([
    db.prepare(
      `SELECT si.amount AS amount, (si.sale_price - si.cost_price) * si.quantity AS gross
       FROM sale_items si WHERE si.happened_at = ?`,
    ).bind(date).all<{ amount: number; gross: number }>(),
    db.prepare(`SELECT amount, waived FROM payments WHERE happened_at = ?`).bind(date)
      .all<{ amount: number; waived: number }>(),
    db.prepare(`SELECT amount FROM purchase_items pi WHERE pi.happened_at = ?`).bind(date)
      .all<{ amount: number }>(),
    db.prepare(`SELECT client_id, sale_id, happened_at, amount FROM sale_items`).all<{ client_id: string; sale_id: string; happened_at: string | null; amount: number }>(),
    db.prepare(`SELECT amount, waived FROM payments`).all<{ amount: number; waived: number }>(),
    db.prepare(
      `SELECT
        (SELECT COUNT(*) FROM clients WHERE deleted_at IS NULL) AS client_count,
        (SELECT COUNT(*) FROM items WHERE deleted_at IS NULL) AS item_count`,
    ).first<{ client_count: number; item_count: number }>(),
  ]);
  const sales_total = todaySales.results.reduce((s, x) => s + r(x.amount), 0);
  const gross_profit = todaySales.results.reduce((s, x) => s + r(x.gross), 0);
  const paid_total = todayPays.results.reduce((s, x) => s + r((Number(x.amount) || 0) + (Number(x.waived) || 0)), 0);
  const purchase_total = todayBuys.results.reduce((s, x) => s + r(x.amount), 0);
  const all_sales = allSales.results.reduce((s, x) => s + r(x.amount), 0);
  const all_paid = allPays.results.reduce((s, x) => s + r((Number(x.amount) || 0) + (Number(x.waived) || 0)), 0);

  // 店铺欠款排行/全局欠款：各店按自身抹零配置算出货侧（无配置=None 逐笔舍入），收款侧逐笔舍入
  const [cSales, cPays, clientRows, cfgRows] = await Promise.all([
    db.prepare(`SELECT client_id, sale_id, happened_at, amount FROM sale_items`).all<{ client_id: string; sale_id: string; happened_at: string | null; amount: number }>(),
    db.prepare(`SELECT client_id, amount, waived FROM payments`).all<{ client_id: string; amount: number; waived: number }>(),
    db.prepare(`SELECT id, name FROM clients WHERE deleted_at IS NULL`).all<{ id: string; name: string }>(),
    db.prepare(`SELECT id, round_stage, round_unit FROM clients WHERE deleted_at IS NULL`).all<{ id: string; round_stage: string | null; round_unit: string | null }>(),
  ]);
  const roundCfgMap = new Map(cfgRows.results.map((r) => [r.id, normalizeRoundConfig(r.round_stage, r.round_unit)]));
  const salesMap = new Map<string, number>();
  const paidMap = new Map<string, number>();
  const saleByClient = new Map<string, Array<{ sale_id: string; happened_at: string | null; amount: number }>>();
  for (const x of cSales.results) {
    const arr = saleByClient.get(x.client_id) ?? [];
    arr.push({ sale_id: x.sale_id, happened_at: x.happened_at, amount: Number(x.amount) || 0 });
    saleByClient.set(x.client_id, arr);
  }
  for (const [cid, rows] of saleByClient) {
    const cfg = roundCfgMap.get(cid) ?? { stage: 'none' as const, unit: 'yuan' as const };
    salesMap.set(cid, salesSideRounded(rows, cfg.stage, cfg.unit, money));
  }
  for (const x of cPays.results) {
    paidMap.set(x.client_id, (paidMap.get(x.client_id) ?? 0) + r((Number(x.amount) || 0) + (Number(x.waived) || 0)));
  }
  const topDebt = clientRows.results
    .map((c2) => ({
      id: c2.id, name: c2.name,
      sales_total: salesMap.get(c2.id) ?? 0, paid_total: paidMap.get(c2.id) ?? 0,
    }))
    .sort((a, b) => (b.sales_total - b.paid_total) - (a.sales_total - a.paid_total))
    .slice(0, 5);

  return c.json({
    date,
    can_see_profit: canSeeProfit,
    today: {
      sales_total: r(sales_total), sales_count: todaySales.results.length,
      gross_profit: canSeeProfit ? r(gross_profit) : 0, paid_total: r(paid_total),
      purchase_total: r(purchase_total),
    },
    totals: {
      all_sales: r(all_sales), all_paid: r(all_paid),
      // 全局欠款 = Σ各店（按自身抹零配置算出货侧） − 全部收款（口径与每店欠款一致）
      debt: r([...salesMap.values()].reduce((s, v) => s + v, 0) - all_paid),
      client_count: counts?.client_count ?? 0, item_count: counts?.item_count ?? 0,
    },
    top_debt_clients: topDebt.map((c2) => ({
      id: c2.id, name: c2.name,
      sales_total: r(c2.sales_total), paid_total: r(c2.paid_total),
      debt: r(c2.sales_total - c2.paid_total),
    })),
  });
});

// GET /stats/clients?start=&end= — 按店：出货/收款/欠款/毛利（可传起止日期过滤，缺省=全部历史）
statsRouter.get('/clients', async (c) => {
  const canSeeProfit = c.get('user').role === 'admin';
  const start = c.req.query('start')?.trim();
  const end = c.req.query('end')?.trim();
  const hasRange = !!(start && end);
  const cond = hasRange ? 'AND happened_at >= ? AND happened_at <= ?' : '';
  const params: unknown[] = hasRange ? [start, end] : [];
  const [saleRows, payRows, clientRows, cfgRows] = await Promise.all([
    c.env.DB.prepare(
      `SELECT si.client_id AS cid, si.sale_id AS sale_id, si.happened_at AS happened_at, si.amount AS amount,
        (si.sale_price - si.cost_price) * si.quantity AS gross
       FROM sale_items si WHERE 1=1 ${cond}`,
    ).bind(...params).all<{ cid: string; sale_id: string; happened_at: string | null; amount: number; gross: number }>(),
    c.env.DB.prepare(
      `SELECT client_id AS cid, amount, waived FROM payments WHERE 1=1 ${cond}`,
    ).bind(...params).all<{ cid: string; amount: number; waived: number }>(),
    c.env.DB.prepare(`SELECT id, name FROM clients WHERE deleted_at IS NULL`).all<{ id: string; name: string }>(),
    c.env.DB.prepare(`SELECT id, round_stage, round_unit FROM clients WHERE deleted_at IS NULL`).all<{ id: string; round_stage: string | null; round_unit: string | null }>(),
  ]);
  const money = await getRoundingConfig(c.env.DB);
  const r = (n: unknown) => roundMoney(Number(n || 0), money);
  const roundCfgMap = new Map(cfgRows.results.map((r2) => [r2.id, normalizeRoundConfig(r2.round_stage, r2.round_unit)]));
  const salesMap = new Map<string, number>();
  const grossMap = new Map<string, number>();
  const paidMap = new Map<string, number>();
  // 出货侧按店抹零配置分组（txn=每单合计取整 / day=每日合计取整 / total=区间合计一次取整；None=逐笔舍入）
  const saleByClient = new Map<string, Array<{ sale_id: string; happened_at: string | null; amount: number }>>();
  for (const x of saleRows.results) {
    grossMap.set(x.cid, (grossMap.get(x.cid) ?? 0) + r(x.gross));
    const arr = saleByClient.get(x.cid) ?? [];
    arr.push({ sale_id: x.sale_id, happened_at: x.happened_at, amount: Number(x.amount) || 0 });
    saleByClient.set(x.cid, arr);
  }
  for (const [cid, rows] of saleByClient) {
    const cfg = roundCfgMap.get(cid) ?? { stage: 'none' as const, unit: 'yuan' as const };
    salesMap.set(cid, salesSideRounded(rows, cfg.stage, cfg.unit, money));
  }
  for (const x of payRows.results) {
    const id = x.cid;
    paidMap.set(id, (paidMap.get(id) ?? 0) + r((Number(x.amount) || 0) + (Number(x.waived) || 0)));
  }
  const clients = clientRows.results
    .map((c2) => ({
      id: c2.id, name: c2.name,
      sales_total: salesMap.get(c2.id) ?? 0, paid_total: paidMap.get(c2.id) ?? 0,
      gross_profit: grossMap.get(c2.id) ?? 0,
    }))
    .sort((a, b) => b.sales_total - a.sales_total);
  return c.json({
    can_see_profit: canSeeProfit,
    clients: clients.map((c2) => ({
      id: c2.id, name: c2.name, sales_total: r(c2.sales_total), paid_total: r(c2.paid_total),
      gross_profit: canSeeProfit ? r(c2.gross_profit) : 0, debt: r(c2.sales_total - c2.paid_total),
    })),
  });
});

// GET /stats/monthly?year=2026&kind=sale|purchase — 按月：出货额/毛利/收款（进货视图=按月进货额）
statsRouter.get('/monthly', async (c) => {
  const canSeeProfit = c.get('user').role === 'admin';
  const year = c.req.query('year')?.trim() || String(new Date().getUTCFullYear());
  const kind = c.req.query('kind') === 'purchase' ? 'purchase' : 'sale';
  const money = await getRoundingConfig(c.env.DB);
  const r = (n: unknown) => roundMoney(Number(n || 0), money);
  const [saleRows, payRows] = await Promise.all([
    c.env.DB.prepare(
      kind === 'purchase'
        ? `SELECT substr(pi.happened_at, 1, 7) AS month, pi.amount AS amount, 0 AS gross
           FROM purchase_items pi WHERE pi.happened_at >= ? AND pi.happened_at <= ?`
        : `SELECT substr(si.happened_at, 1, 7) AS month, si.amount AS amount,
            (si.sale_price - si.cost_price) * si.quantity AS gross
           FROM sale_items si WHERE si.happened_at >= ? AND si.happened_at <= ?`,
    ).bind(`${year}-01-01`, `${year}-12-31`).all<{ month: string; amount: number; gross: number }>(),
    kind === 'purchase'
      ? Promise.resolve({ results: [] as Array<{ month: string; amount: number; waived: number }> })
      : c.env.DB.prepare(
          `SELECT substr(happened_at, 1, 7) AS month, amount, waived
           FROM payments WHERE happened_at >= ? AND happened_at <= ?`,
        ).bind(`${year}-01-01`, `${year}-12-31`).all<{ month: string; amount: number; waived: number }>(),
  ]);
  const salesMap = new Map<string, number>();
  const grossMap = new Map<string, number>();
  const paidMap = new Map<string, number>();
  for (const x of saleRows.results) {
    salesMap.set(x.month, (salesMap.get(x.month) ?? 0) + r(x.amount));
    grossMap.set(x.month, (grossMap.get(x.month) ?? 0) + r(x.gross));
  }
  for (const x of payRows.results) {
    paidMap.set(x.month, (paidMap.get(x.month) ?? 0) + r((Number(x.amount) || 0) + (Number(x.waived) || 0)));
  }
  const months = [...salesMap.keys()].sort().map((m) => ({
    month: m,
    sales_total: r(salesMap.get(m) ?? 0),
    gross_profit: canSeeProfit ? r(grossMap.get(m) ?? 0) : 0,
    paid_total: r(paidMap.get(m) ?? 0),
  }));
  return c.json({ year, kind, can_see_profit: canSeeProfit, months });
});

// GET /stats/monthly-flow?year=2026 — 按月流式结余（类似参考首页卡片）：
// 支出 = 当月全部进货额，收入 = 当月全部出货额，结余 = 出货 − 进货。
// 进货不分店铺（全局），故本口径为全店汇总；供「月度结余」页流式展示。
statsRouter.get('/monthly-flow', async (c) => {
  const canSeeProfit = c.get('user').role === 'admin';
  const year = c.req.query('year')?.trim() || String(new Date().getUTCFullYear());
  const money = await getRoundingConfig(c.env.DB);
  const r = (n: unknown) => roundMoney(Number(n || 0), money);
  const [saleRows, buyRows] = await Promise.all([
    c.env.DB.prepare(
      `SELECT substr(si.happened_at, 1, 7) AS month, si.amount AS amount
       FROM sale_items si WHERE si.happened_at >= ? AND si.happened_at <= ?`,
    ).bind(`${year}-01-01`, `${year}-12-31`).all<{ month: string; amount: number }>(),
    c.env.DB.prepare(
      `SELECT substr(pi.happened_at, 1, 7) AS month, pi.amount AS amount
       FROM purchase_items pi WHERE pi.happened_at >= ? AND pi.happened_at <= ?`,
    ).bind(`${year}-01-01`, `${year}-12-31`).all<{ month: string; amount: number }>(),
  ]);
  const salesMap = new Map<string, number>();
  const buyMap = new Map<string, number>();
  for (const x of saleRows.results) salesMap.set(x.month, (salesMap.get(x.month) ?? 0) + r(x.amount));
  for (const x of buyRows.results) buyMap.set(x.month, (buyMap.get(x.month) ?? 0) + r(x.amount));
  const months = new Map<string, { month: string; sales_total: number; purchase_total: number; balance: number }>();
  for (const m of salesMap.keys()) {
    const sales = salesMap.get(m) ?? 0;
    const buys = buyMap.get(m) ?? 0;
    months.set(m, { month: m, sales_total: sales, purchase_total: buys, balance: r(sales - buys) });
  }
  // 无出货但有进货的月份也要展示（支出列非空）
  for (const [m, buys] of buyMap) {
    if (!months.has(m)) months.set(m, { month: m, sales_total: 0, purchase_total: buys, balance: r(-buys) });
  }
  return c.json({
    year, can_see_profit: canSeeProfit,
    months: [...months.values()].sort((a, b) => a.month.localeCompare(b.month)),
  });
});

// GET /stats/categories?start=&end=&client_id=&kind=sale|purchase — 区间内按商品分类聚合（出货额/进货额降序）
statsRouter.get('/categories', async (c) => {
  const start = c.req.query('start')?.trim();
  const end = c.req.query('end')?.trim();
  if (!start || !end) return c.json({ error: 'start/end 必填（YYYY-MM-DD）' }, 400);
  const clientId = c.req.query('client_id')?.trim();
  const kind = c.req.query('kind') === 'purchase' ? 'purchase' : 'sale';
  const params: unknown[] = [start, end];
  if (clientId && kind === 'sale') params.push(clientId);
  const rows = await c.env.DB.prepare(
    kind === 'purchase'
      ? `SELECT COALESCE(cat.name, '未分类') AS category, pi.quantity AS quantity, pi.amount AS amount
         FROM purchase_items pi
         JOIN items i ON i.id = pi.item_id
         LEFT JOIN categories cat ON cat.id = i.category_id
         WHERE pi.happened_at >= ? AND pi.happened_at <= ?`
      : `SELECT COALESCE(cat.name, '未分类') AS category, si.quantity AS quantity, si.amount AS amount
         FROM sale_items si
         JOIN items i ON i.id = si.item_id
         LEFT JOIN categories cat ON cat.id = i.category_id
         WHERE si.happened_at >= ? AND si.happened_at <= ?${clientId ? ' AND si.client_id = ?' : ''}`,
  ).bind(...params).all<{ category: string; quantity: number; amount: number }>();
  const money = await getRoundingConfig(c.env.DB);
  const r = (n: unknown) => roundMoney(Number(n || 0), money);
  const map = new Map<string, { quantity: number; amount: number }>();
  for (const x of rows.results) {
    const cur = map.get(x.category) ?? { quantity: 0, amount: 0 };
    cur.quantity += Number(x.quantity) || 0;
    cur.amount += r(x.amount);
    map.set(x.category, cur);
  }
  const categories = [...map.entries()]
    .map(([category, v]) => ({ category, quantity: v.quantity, amount: v.amount }))
    .sort((a, b) => b.amount - a.amount);
  return c.json({
    kind,
    categories: categories.map((x) => ({ category: x.category, quantity: r(x.quantity), amount: r(x.amount) })),
  });
});

// GET /stats/years — 有数据的年份列表（出货/进货/收款并集，升序）+ 最早记账日期（记账天数用）
statsRouter.get('/years', async (c) => {
  const rows = await c.env.DB.prepare(
    `SELECT DISTINCT substr(happened_at, 1, 4) AS y FROM sale_items
     UNION SELECT DISTINCT substr(happened_at, 1, 4) FROM purchase_items
     UNION SELECT DISTINCT substr(happened_at, 1, 4) FROM payments
     ORDER BY y`,
  ).all<{ y: string }>();
  const first = await c.env.DB.prepare(
    `SELECT MIN(d) AS d FROM (
       SELECT MIN(happened_at) AS d FROM sale_items WHERE happened_at IS NOT NULL AND happened_at != ''
       UNION ALL SELECT MIN(happened_at) FROM purchase_items WHERE happened_at IS NOT NULL AND happened_at != ''
       UNION ALL SELECT MIN(happened_at) FROM payments WHERE happened_at IS NOT NULL AND happened_at != ''
     )`,
  ).first<{ d: string }>();
  return c.json({
    years: rows.results.map((r) => Number(r.y)).filter((n) => Number.isInteger(n) && n >= 2000),
    first_date: first?.d ?? '',
  });
});

// GET /stats/summary?start=&end=&client_id=&kind=sale|purchase — 任意区间汇总（起止日都含；欠款=截止 end 累计出货−累计收款）
statsRouter.get('/summary', async (c) => {
  const canSeeProfit = c.get('user').role === 'admin';
  const start = c.req.query('start')?.trim();
  const end = c.req.query('end')?.trim();
  if (!start || !end) return c.json({ error: 'start/end 必填（YYYY-MM-DD）' }, 400);
  const clientId = c.req.query('client_id')?.trim();
  const db = c.env.DB;
  const money = await getRoundingConfig(c.env.DB);
  const r = (n: unknown) => roundMoney(Number(n || 0), money);
  const kind = c.req.query('kind') === 'purchase' ? 'purchase' : 'sale';

  // 出货（或进货）区间汇总：kind=purchase 走 purchase_items（无店铺维度、无毛利）。
  // 金额按"每笔舍入后累加"（与单笔显示/账本页对账一致）：原始浮点 SUM 后舍入在
  // digits=0/1 时（1.6+1.6=3.2→¥3）会与每笔显示（¥2+¥2）对不上。
  const salesParams: unknown[] = [start, end];
  const salesSql = kind === 'purchase'
    ? `SELECT pi.amount AS amount, 0 AS sale_price, 0 AS cost_price, 0 AS quantity
       FROM purchase_items pi WHERE pi.happened_at >= ? AND pi.happened_at <= ?`
    : `SELECT si.amount AS amount, si.sale_price AS sale_price, si.cost_price AS cost_price, si.quantity AS quantity
       FROM sale_items si
       WHERE si.happened_at >= ? AND si.happened_at <= ?${clientId ? ' AND si.client_id = ?' : ''}`;
  if (clientId && kind === 'sale') salesParams.push(clientId);
  const saleRows = await db.prepare(salesSql).bind(...salesParams).all<{
    amount: number; sale_price: number; cost_price: number; quantity: number;
  }>();
  const sales_total = saleRows.results.reduce((s, x) => s + roundMoney(Number(x.amount) || 0, money), 0);
  const gross_profit = kind === 'purchase'
    ? 0
    : saleRows.results.reduce((s, x) => s + roundMoney((Number(x.sale_price) - Number(x.cost_price)) * Number(x.quantity), money), 0);

  const paidParams: unknown[] = [start, end];
  const paidSql = `SELECT amount, waived
     FROM payments WHERE happened_at >= ? AND happened_at <= ?${clientId ? ' AND client_id = ?' : ''}`;
  if (clientId) paidParams.push(clientId);
  const paidRows = await db.prepare(paidSql).bind(...paidParams).all<{ amount: number; waived: number }>();
  const paid_total = paidRows.results.reduce((s, x) => s + roundMoney((Number(x.amount) || 0) + (Number(x.waived) || 0), money), 0);

  const buyParams: unknown[] = [start, end];
  const buySql = `SELECT amount
     FROM purchase_items pi WHERE pi.happened_at >= ? AND pi.happened_at <= ?`;
  const buyRows = await db.prepare(buySql).bind(...buyParams).all<{ amount: number }>();
  const purchase_total = buyRows.results.reduce((s, x) => s + roundMoney(Number(x.amount) || 0, money), 0);

  // 截止 end 的总欠款（区间前累计也计入：全部出货 − 全部收款，时间 ≤ end）；进货视图无欠款
  // 口径=每笔先舍入再累加（与区间统计/账本一致）：勿 SQL SUM 原始值后一次舍入——
  // 尾数会被"吞"（三间 10月 133.3+67.8+146.2+80.5=427.8，SUM=428.0→428，上层再统计继续进位放大）
  // 抹零店（round_stage≠none）：出货侧按该店配置分组向下取整（单店=该店配置；全店=各店各自配置），
  // 收款侧仍逐笔舍入（实收无抹零）。
  const debtParams: unknown[] = clientId ? [end, clientId] : [end];
  const [debtSaleRows, debtPayRows, roundRows] = kind === 'purchase'
    ? [{ results: [] as Array<{ client_id: string; sale_id: string; happened_at: string | null; amount: number }> }, { results: [] as Array<{ amount: number; waived: number }> }, { results: [] as Array<{ id: string; round_stage: string | null; round_unit: string | null }> }]
    : await Promise.all([
        db.prepare(
          `SELECT client_id, sale_id, happened_at, amount FROM sale_items WHERE happened_at <= ?${clientId ? ' AND client_id = ?' : ''}`,
        ).bind(...debtParams).all<{ client_id: string; sale_id: string; happened_at: string | null; amount: number }>(),
        db.prepare(
          `SELECT amount, waived FROM payments WHERE happened_at <= ?${clientId ? ' AND client_id = ?' : ''}`,
        ).bind(...debtParams).all<{ amount: number; waived: number }>(),
        db.prepare(
          clientId
            ? `SELECT id, round_stage, round_unit FROM clients WHERE id = ?`
            : `SELECT id, round_stage, round_unit FROM clients WHERE deleted_at IS NULL`,
        ).bind(...(clientId ? [clientId] : [])).all<{ id: string; round_stage: string | null; round_unit: string | null }>(),
      ]);
  const allPaid = debtPayRows.results.reduce((s, x) => s + r((Number(x.amount) || 0) + (Number(x.waived) || 0)), 0);
  let allSales: number;
  if (kind === 'purchase') {
    allSales = 0;
  } else if (clientId) {
    const cfg = normalizeRoundConfig(roundRows.results[0]?.round_stage, roundRows.results[0]?.round_unit);
    allSales = salesSideRounded(debtSaleRows.results, cfg.stage, cfg.unit, money);
  } else {
    // 全店：按各店抹零配置分别算出货侧再累加（None 店=逐笔舍入，行为不变）
    const cfgMap = new Map(roundRows.results.map((x) => [x.id, normalizeRoundConfig(x.round_stage, x.round_unit)]));
    allSales = salesAggByConfig(debtSaleRows.results, cfgMap, money);
  }

  return c.json({
    start, end, kind,
    can_see_profit: canSeeProfit,
    sales_total: r(sales_total), gross_profit: canSeeProfit ? r(gross_profit) : 0,
    sales_count: saleRows.results.length,
    paid_total: r(paid_total), purchase_total: r(purchase_total),
    debt: kind === 'purchase' ? 0 : r(allSales - allPaid),
  });
});

// GET /stats/daily?start=&end=&client_id=&kind=sale|purchase — 区间内按日：出货/毛利/收款/进货（只含有数据的日，前端补零）
statsRouter.get('/daily', async (c) => {
  const canSeeProfit = c.get('user').role === 'admin';
  const start = c.req.query('start')?.trim();
  const end = c.req.query('end')?.trim();
  if (!start || !end) return c.json({ error: 'start/end 必填（YYYY-MM-DD）' }, 400);
  const clientId = c.req.query('client_id')?.trim();
  const db = c.env.DB;
  const money = await getRoundingConfig(db);
  const r = (n: unknown) => roundMoney(Number(n || 0), money);
  const kind = c.req.query('kind') === 'purchase' ? 'purchase' : 'sale';

  const sParams: unknown[] = [start, end];
  const sSql = kind === 'purchase'
    ? `SELECT substr(pi.happened_at, 1, 10) AS day, pi.amount AS amount, 0 AS gross
       FROM purchase_items pi
       WHERE pi.happened_at >= ? AND pi.happened_at <= ?`
    : `SELECT substr(si.happened_at, 1, 10) AS day, si.amount AS amount,
        (si.sale_price - si.cost_price) * si.quantity AS gross
       FROM sale_items si
       WHERE si.happened_at >= ? AND si.happened_at <= ?${clientId ? ' AND si.client_id = ?' : ''}`;
  if (clientId && kind === 'sale') sParams.push(clientId);
  const saleRows = await db.prepare(sSql).bind(...sParams).all<{ day: string; amount: number; gross: number }>();

  const pParams: unknown[] = [start, end];
  const pSql = `SELECT substr(happened_at, 1, 10) AS day, amount, waived
     FROM payments WHERE happened_at >= ? AND happened_at <= ?${clientId ? ' AND client_id = ?' : ''}`;
  if (clientId) pParams.push(clientId);
  const paidRows = await db.prepare(pSql).bind(...pParams).all<{ day: string; amount: number; waived: number }>();

  const bParams: unknown[] = [start, end];
  const bSql = `SELECT substr(pi.happened_at, 1, 10) AS day, pi.amount AS amount
     FROM purchase_items pi
     WHERE pi.happened_at >= ? AND pi.happened_at <= ?`;
  const buyRows = await db.prepare(bSql).bind(...bParams).all<{ day: string; amount: number }>();

  const salesMap = new Map<string, number>();
  const grossMap = new Map<string, number>();
  for (const x of saleRows.results) {
    salesMap.set(x.day, (salesMap.get(x.day) ?? 0) + r(x.amount));
    grossMap.set(x.day, (grossMap.get(x.day) ?? 0) + r(x.gross));
  }
  const paidMap = new Map<string, number>();
  for (const x of paidRows.results) {
    paidMap.set(x.day, (paidMap.get(x.day) ?? 0) + r((Number(x.amount) || 0) + (Number(x.waived) || 0)));
  }
  const buyMap = new Map<string, number>();
  for (const x of buyRows.results) {
    buyMap.set(x.day, (buyMap.get(x.day) ?? 0) + r(x.amount));
  }
  const days = [...salesMap.keys()].sort().map((day) => ({
    day,
    sales_total: r(salesMap.get(day) ?? 0),
    gross_profit: canSeeProfit ? r(grossMap.get(day) ?? 0) : 0,
    paid_total: r(paidMap.get(day) ?? 0),
    purchase_total: r(buyMap.get(day) ?? 0),
  }));
  return c.json({ start, end, can_see_profit: canSeeProfit, days });
});

// GET /stats/items?start=&end=&client_id=&kind=sale|purchase — 区间内商品排行（出货额/进货额降序，Top 15）
statsRouter.get('/items', async (c) => {
  const start = c.req.query('start')?.trim();
  const end = c.req.query('end')?.trim();
  if (!start || !end) return c.json({ error: 'start/end 必填（YYYY-MM-DD）' }, 400);
  const clientId = c.req.query('client_id')?.trim();
  const kind = c.req.query('kind') === 'purchase' ? 'purchase' : 'sale';
  const params: unknown[] = [start, end];
  if (clientId && kind === 'sale') params.push(clientId);
  const rows = await c.env.DB.prepare(
    kind === 'purchase'
      ? `SELECT i.name, pi.unit, pi.quantity AS quantity, pi.amount AS amount
         FROM purchase_items pi
         JOIN items i ON i.id = pi.item_id
         WHERE pi.happened_at >= ? AND pi.happened_at <= ?`
      : `SELECT i.name, si.unit, si.quantity AS quantity, si.amount AS amount
         FROM sale_items si
         JOIN items i ON i.id = si.item_id
         WHERE si.happened_at >= ? AND si.happened_at <= ?${clientId ? ' AND si.client_id = ?' : ''}`,
  ).bind(...params).all<{ name: string; unit: string; quantity: number; amount: number }>();
  const money = await getRoundingConfig(c.env.DB);
  const r = (n: unknown) => roundMoney(Number(n || 0), money);
  const map = new Map<string, { name: string; unit: string; quantity: number; amount: number }>();
  for (const x of rows.results) {
    const key = `${x.name}|${x.unit}`;
    const cur = map.get(key) ?? { name: x.name, unit: x.unit, quantity: 0, amount: 0 };
    cur.quantity += Number(x.quantity) || 0;
    cur.amount += r(x.amount);
    map.set(key, cur);
  }
  const items = [...map.values()].sort((a, b) => b.amount - a.amount).slice(0, 15);
  return c.json({
    kind,
    items: items.map((x) => ({ name: x.name, unit: x.unit, quantity: r(x.quantity), amount: r(x.amount) })),
  });
});

// GET /stats/category-statement?category_id=&start=&end= — 按店铺分类（美食城多档口）汇总对账：
// 分类下每个档口的 出货/收款(含减免)/期末欠款 + 总合计。欠款口径 = 各档口独立结算再求和。
statsRouter.get('/category-statement', async (c) => {
  const categoryId = c.req.query('category_id')?.trim();
  const start = c.req.query('start')?.trim();
  const end = c.req.query('end')?.trim();
  if (!categoryId || !start || !end) return c.json({ error: 'category_id / start / end 必填' }, 400);
  const cat = await c.env.DB.prepare(
    "SELECT name FROM categories WHERE id = ? AND type = 'client'",
  ).bind(categoryId).first<{ name: string }>();
  if (!cat) return c.json({ error: '店铺分类不存在' }, 404);
  const money = await getRoundingConfig(c.env.DB);
  const r = (n: unknown) => roundMoney(Number(n || 0), money);
  const [saleRows, payRows, debtRows, debtPayRows, clientRows, roundRows] = await Promise.all([
    c.env.DB.prepare(
      `SELECT client_id, sale_id, happened_at, amount FROM sale_items
       WHERE client_id IN (SELECT id FROM clients WHERE category_id = ?)
         AND happened_at >= ? AND happened_at <= ?`,
    ).bind(categoryId, start, end).all<{ client_id: string; sale_id: string; happened_at: string | null; amount: number }>(),
    c.env.DB.prepare(
      `SELECT client_id, amount, waived FROM payments
       WHERE client_id IN (SELECT id FROM clients WHERE category_id = ?)
         AND happened_at >= ? AND happened_at <= ?`,
    ).bind(categoryId, start, end).all<{ client_id: string; amount: number; waived: number }>(),
    // 期末欠款：每笔先舍入再累加（口径与 /stats/summary 一致，勿 SQL SUM 原始后一次舍入——尾数进位放大）
    c.env.DB.prepare(
      `SELECT si.client_id AS cid, si.sale_id AS sale_id, si.happened_at AS happened_at, si.amount AS amount
       FROM sale_items si
       WHERE si.client_id IN (SELECT id FROM clients WHERE category_id = ? AND deleted_at IS NULL)
         AND si.happened_at <= ?`,
    ).bind(categoryId, end).all<{ cid: string; sale_id: string; happened_at: string | null; amount: number }>(),
    c.env.DB.prepare(
      `SELECT p.client_id AS cid, p.amount AS amount, p.waived AS waived
       FROM payments p
       WHERE p.client_id IN (SELECT id FROM clients WHERE category_id = ? AND deleted_at IS NULL)
         AND p.happened_at <= ?`,
    ).bind(categoryId, end).all<{ cid: string; amount: number; waived: number }>(),
    c.env.DB.prepare(
      `SELECT id, name FROM clients WHERE category_id = ? AND deleted_at IS NULL ORDER BY name`,
    ).bind(categoryId).all<{ id: string; name: string }>(),
    c.env.DB.prepare(
      `SELECT id, round_stage, round_unit FROM clients WHERE category_id = ? AND deleted_at IS NULL`,
    ).bind(categoryId).all<{ id: string; round_stage: string | null; round_unit: string | null }>(),
  ]);
  const roundCfgMap = new Map(roundRows.results.map((x) => [x.id, normalizeRoundConfig(x.round_stage, x.round_unit)]));
  // 区间出货/期末欠款出货侧均按各店自身抹零配置分组（None 店=逐笔舍入，历史口径不变）
  const salesMap = new Map<string, number>();
  const paidMap = new Map<string, number>();
  const waivedMap = new Map<string, number>();
  const saleByClient = new Map<string, Array<{ sale_id: string; happened_at: string | null; amount: number }>>();
  for (const x of saleRows.results) {
    const arr = saleByClient.get(x.client_id) ?? [];
    arr.push({ sale_id: x.sale_id, happened_at: x.happened_at, amount: Number(x.amount) || 0 });
    saleByClient.set(x.client_id, arr);
  }
  for (const [cid, rows] of saleByClient) {
    const cfg = roundCfgMap.get(cid) ?? { stage: 'none' as const, unit: 'yuan' as const };
    salesMap.set(cid, salesSideRounded(rows, cfg.stage, cfg.unit, money));
  }
  for (const x of payRows.results) {
    const id = x.client_id;
    paidMap.set(id, (paidMap.get(id) ?? 0) + r(Number(x.amount) || 0));
    waivedMap.set(id, (waivedMap.get(id) ?? 0) + r(Number(x.waived) || 0));
  }
  const debtMap = new Map<string, number>();
  const debtByClient = new Map<string, Array<{ sale_id: string; happened_at: string | null; amount: number }>>();
  for (const x of debtRows.results) {
    const arr = debtByClient.get(x.cid) ?? [];
    arr.push({ sale_id: x.sale_id, happened_at: x.happened_at, amount: Number(x.amount) || 0 });
    debtByClient.set(x.cid, arr);
  }
  for (const [cid, rows] of debtByClient) {
    const cfg = roundCfgMap.get(cid) ?? { stage: 'none' as const, unit: 'yuan' as const };
    debtMap.set(cid, salesSideRounded(rows, cfg.stage, cfg.unit, money));
  }
  for (const x of debtPayRows.results) {
    // 收款整笔 r(amount + waived) 后扣减（与区间统计/账本单笔显示一致；勿拆开各自舍入）
    debtMap.set(x.cid, (debtMap.get(x.cid) ?? 0) - r((Number(x.amount) || 0) + (Number(x.waived) || 0)));
  }
  const clients = clientRows.results.map((c2) => ({
    id: c2.id, name: c2.name,
    sales_total: salesMap.get(c2.id) ?? 0,
    paid_total: paidMap.get(c2.id) ?? 0,
    waived_total: waivedMap.get(c2.id) ?? 0,
    debt: debtMap.get(c2.id) ?? 0,
  }));
  const sum = (k: 'sales_total' | 'paid_total' | 'debt') => clients.reduce((s, x) => s + x[k], 0);
  return c.json({
    category_name: cat.name, from: start, to: end,
    clients: clients.map((x) => ({
      id: x.id, name: x.name,
      sales_total: r(x.sales_total), paid_total: r(x.paid_total),
      waived_total: r(x.waived_total), debt: r(x.debt),
    })),
    total: { sales_total: r(sum('sales_total')), paid_total: r(sum('paid_total')), debt: r(sum('debt')) },
  });
});
