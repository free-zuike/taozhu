/**
 * 全局账本派生：/stats/overview 与 /clients 共享同一份按店聚合结果。
 *
 * 逐笔舍入口径（每笔先 roundMoney 再累加）不允许 SQL SUM，两端原本各拉一次
 * sale_items + payments 全表明细；合并后每次快照失效只扫一次，而不是两次。
 * 快照里存的是「按店聚合」的小结果，不是全量明细（明细太大，不能塞进 schema_meta）。
 */
import {
  roundMoney, normalizeRoundConfig, salesSideRounded, type RoundingConfig,
} from './money';
import { versionedSnapshot, unaffectedTypes } from './snapshot';
import { loadDerivedCore } from './derived-core';

/** 只列「同时不影响 overview 与 /clients」的写入。
 *  item 会影响 overview 的 item_count、category 会影响 /clients 的 category_name，都不列入；
 *  未知或新增 entity_type 一律判为相关 → 保守重算。 */
const LEDGER_UNRELATED_TYPES = [
  'price_group', 'payment_account', 'device', 'user',
  'settings', 'setting', 'theme', 'ai_config', 'attachment',
  'share_link', 'stmt_template', 'loss_record', 'stock_adjustment',
];

export interface ClientStat {
  id: string;
  sales_total: number;   // 原始未舍入 SUM(amount)
  paid_total: number;    // 原始未舍入 SUM(amount + waived)
  debt: number;          // 逐笔舍入/抹零后的出货侧 − 逐笔舍入的收款侧
  sale_count: number;
  first_book_date: string;
  payment_count: number;
}

export interface LedgerDerived {
  all_sales: number;
  all_paid: number;
  debt: number;
  client_count: number;
  item_count: number;
  top_debt_clients: Array<{ id: string; name: string; sales_total: number; paid_total: number; debt: number }>;
  client_stats: ClientStat[];
}

export async function loadLedgerDerived(db: D1Database, money: RoundingConfig): Promise<LedgerDerived> {
  return versionedSnapshot<LedgerDerived>(
    db, 'ledger_derived', async () => {
      const core = await loadDerivedCore(db);
      return compute(db, money, core);
    },
    `${money.carry}|${money.digits}`,
    { ttlMs: 5 * 60_000, affectedSince: unaffectedTypes(db, LEDGER_UNRELATED_TYPES) },
  ).then((x) => x.data);
}

async function compute(db: D1Database, money: RoundingConfig, core: Awaited<ReturnType<typeof loadDerivedCore>>): Promise<LedgerDerived> {
  const r = (n: unknown) => roundMoney(Number(n || 0), money);
  const [clientRows, counts] = await Promise.all([
    db.prepare(`SELECT id, name, round_stage, round_unit, round_carry FROM clients WHERE deleted_at IS NULL`)
      .all<{ id: string; name: string; round_stage: string | null; round_unit: string | null; round_carry: number | null }>(),
    db.prepare(
      `SELECT
        (SELECT COUNT(*) FROM clients WHERE deleted_at IS NULL) AS client_count,
        (SELECT COUNT(*) FROM items WHERE deleted_at IS NULL) AS item_count`,
    ).first<{ client_count: number; item_count: number }>(),
  ]);
  const salesRows = { results: core.saleItems };
  const payRows = { results: core.payments };

  const roundCfgMap = new Map(clientRows.results.map((x) => [x.id, normalizeRoundConfig(x.round_stage, x.round_unit, x.round_carry)]));
  const byClient = new Map<string, Array<{ sale_id: string; happened_at: string | null; amount: number }>>();
  const salesRawMap = new Map<string, number>();
  let allSales = 0;
  for (const x of salesRows.results) {
    const amt = Number(x.amount) || 0;
    allSales += r(amt);
    salesRawMap.set(x.client_id, (salesRawMap.get(x.client_id) ?? 0) + amt);
    const arr = byClient.get(x.client_id) ?? [];
    arr.push({ sale_id: x.sale_id, happened_at: x.happened_at, amount: amt });
    byClient.set(x.client_id, arr);
  }

  const salesMap = new Map<string, number>();
  const firstBookMap = new Map<string, string>();
  for (const [cid, rows] of byClient) {
    const cfg = roundCfgMap.get(cid) ?? { stage: 'none' as const, unit: 'yuan' as const, carry: null };
    salesMap.set(cid, salesSideRounded(rows, cfg.stage, cfg.unit, cfg.carry, money));
    let min = '';
    for (const x of rows) {
      const d = (x.happened_at ?? '').slice(0, 10);
      if (d && (min === '' || d < min)) min = d;
    }
    if (min) firstBookMap.set(cid, min);
  }

  let allPaid = 0;
  const paidMap = new Map<string, number>();     // 逐笔舍入后累加
  const paidRawMap = new Map<string, number>(); // 原始未舍入
  const payCountMap = new Map<string, number>();
  for (const x of payRows.results) {
    const raw = (Number(x.amount) || 0) + (Number(x.waived) || 0);
    const rounded = r(raw);
    allPaid += rounded;
    paidMap.set(x.client_id, (paidMap.get(x.client_id) ?? 0) + rounded);
    paidRawMap.set(x.client_id, (paidRawMap.get(x.client_id) ?? 0) + raw);
    payCountMap.set(x.client_id, (payCountMap.get(x.client_id) ?? 0) + 1);
  }

  const client_stats: ClientStat[] = [...new Set([...byClient.keys(), ...paidMap.keys()])].map((id) => {
    const sales = salesMap.get(id) ?? 0;
    const paid = paidMap.get(id) ?? 0;
    return {
      id,
      sales_total: salesRawMap.get(id) ?? 0,
      paid_total: paidRawMap.get(id) ?? 0,
      debt: r(sales - paid),
      sale_count: byClient.get(id)?.length ?? 0,
      first_book_date: firstBookMap.get(id) ?? '',
      payment_count: payCountMap.get(id) ?? 0,
    };
  });

  const topDebt = clientRows.results
    .map((x) => ({
      id: x.id, name: x.name,
      sales_total: salesMap.get(x.id) ?? 0, paid_total: paidMap.get(x.id) ?? 0,
    }))
    .sort((a, b) => (b.sales_total - b.paid_total) - (a.sales_total - a.paid_total))
    .slice(0, 5);

  return {
    all_sales: r(allSales),
    all_paid: r(allPaid),
    // 全局欠款 = Σ各店（按自身抹零配置算出货侧） − 全部收款（与每店欠款口径一致）
    debt: r([...salesMap.values()].reduce((s, v) => s + v, 0) - allPaid),
    client_count: counts?.client_count ?? 0,
    item_count: counts?.item_count ?? 0,
    top_debt_clients: topDebt.map((x) => ({
      id: x.id, name: x.name,
      sales_total: r(x.sales_total), paid_total: r(x.paid_total),
      debt: r(x.sales_total - x.paid_total),
    })),
    client_stats,
  };
}
