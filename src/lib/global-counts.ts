/**
 * 同步面板的全局计数口径（无 WHERE / 常量 WHERE 的全表 COUNT 集中到一处）。
 * /sync/stats、/sync/panel、/attachments/total 共用同一份版本化快照：
 * 一次重算服务三个端点，命中后三者都是单行读。
 *
 * 店铺级计数（带 client_id）不在此列——它们本来就能走 idx_*_client_date 索引，
 * 且必须实时，不能进全局快照。
 */
import { versionedSnapshot, unaffectedTypes } from './snapshot';
import { loadDerivedCore } from './derived-core';

export type GlobalCounts = {
  clients: number;
  items: number;
  categories_item: number;
  categories_client: number;
  payment_accounts: number;
  sale_items: number;
  purchase_items: number;
  payments: number;
  attach_file_total: number;
  attach_ref_count: number;
};

/** 只列「不影响任何一项全局计数」的写入；未知/新增 entity_type 一律保守重算。
 *  client/item/category/payment_account/attachment/sale/payment/purchase 都会改变计数，
 *  故意不列入——反向白名单按「确认无关」逐项挑，不是按「看起来相关」偷懒全放行。 */
const SYNC_COUNTS_UNRELATED_TYPES = [
  'price_group', 'device', 'user', 'settings', 'setting', 'theme', 'ai_config',
  'share_link', 'stmt_template', 'loss_record', 'stock_adjustment',
];

export async function computeGlobalCounts(db: D1Database): Promise<GlobalCounts> {
  // 三张流水表的行数直接取自共享派生快照：derived_core 缓存的就是这三张表的全量明细，
  // 长度即行数，口径与 COUNT(*) 完全一致。命中快照只读「游标 + 快照」2 行，
  // 避免每 60s TTL 到期就为拿三个数字把三张最大的表各扫一遍。
  const core = await loadDerivedCore(db);
  const [
    clients, items, catItems, catClients, paymentAccounts, fileTotal, refCount,
  ] = await Promise.all([
    db.prepare('SELECT COUNT(*) AS n FROM clients WHERE deleted_at IS NULL').first<{ n: number }>(),
    db.prepare('SELECT COUNT(*) AS n FROM items WHERE deleted_at IS NULL').first<{ n: number }>(),
    db.prepare("SELECT COUNT(*) AS n FROM categories WHERE type = 'item'").first<{ n: number }>(),
    db.prepare("SELECT COUNT(*) AS n FROM categories WHERE type = 'client'").first<{ n: number }>(),
    db.prepare('SELECT COUNT(*) AS n FROM payment_accounts').first<{ n: number }>(),
    db.prepare('SELECT COUNT(DISTINCT file_key) AS n FROM attachment_refs').first<{ n: number }>(),
    db.prepare('SELECT COUNT(*) AS n FROM attachment_refs').first<{ n: number }>(),
  ]);
  return {
    clients: clients?.n ?? 0,
    items: items?.n ?? 0,
    categories_item: catItems?.n ?? 0,
    categories_client: catClients?.n ?? 0,
    payment_accounts: paymentAccounts?.n ?? 0,
    sale_items: core.saleItems.length,
    purchase_items: core.purchaseItems.length,
    payments: core.payments.length,
    attach_file_total: fileTotal?.n ?? 0,
    attach_ref_count: refCount?.n ?? 0,
  };
}

/** 三个消费端统一入口：精确失效 + 游标未变不重算。
 *  原先这里用默认 60s TTL 且不带 affectedSince——空闲期每 60s 重算 10 条全表 COUNT，
 *  并且任何无关写（改设备/主题/设置）都会 bump 游标触发重算，是 D1 rows_read 的主要漏点。 */
export function loadGlobalCounts(db: D1Database) {
  return versionedSnapshot<GlobalCounts>(db, 'sync_counts', () => computeGlobalCounts(db), '', {
    ttlMs: 30 * 60_000,
    affectedSince: unaffectedTypes(db, SYNC_COUNTS_UNRELATED_TYPES),
    steadyCursorReuse: true,
  });
}
