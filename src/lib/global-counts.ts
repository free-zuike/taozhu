/**
 * 同步面板的全局计数口径（无 WHERE / 常量 WHERE 的 10 条全表 COUNT 集中到一处）。
 * /sync/stats、/sync/panel、/attachments/total 共用同一份版本化快照：
 * 一次重算服务三个端点，命中后三者都是单行读。
 *
 * 店铺级计数（带 client_id）不在此列——它们本来就能走 idx_*_client_date 索引，
 * 且必须实时，不能进全局快照。
 */
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

export async function computeGlobalCounts(db: D1Database): Promise<GlobalCounts> {
  const [
    clients, items, catItems, catClients, paymentAccounts,
    saleItems, purchaseItems, payments, fileTotal, refCount,
  ] = await Promise.all([
    db.prepare('SELECT COUNT(*) AS n FROM clients WHERE deleted_at IS NULL').first<{ n: number }>(),
    db.prepare('SELECT COUNT(*) AS n FROM items WHERE deleted_at IS NULL').first<{ n: number }>(),
    db.prepare("SELECT COUNT(*) AS n FROM categories WHERE type = 'item'").first<{ n: number }>(),
    db.prepare("SELECT COUNT(*) AS n FROM categories WHERE type = 'client'").first<{ n: number }>(),
    db.prepare('SELECT COUNT(*) AS n FROM payment_accounts').first<{ n: number }>(),
    db.prepare('SELECT COUNT(*) AS n FROM sale_items').first<{ n: number }>(),
    db.prepare('SELECT COUNT(*) AS n FROM purchase_items').first<{ n: number }>(),
    db.prepare('SELECT COUNT(*) AS n FROM payments').first<{ n: number }>(),
    db.prepare('SELECT COUNT(DISTINCT file_key) AS n FROM attachment_refs').first<{ n: number }>(),
    db.prepare('SELECT COUNT(*) AS n FROM attachment_refs').first<{ n: number }>(),
  ]);
  return {
    clients: clients?.n ?? 0,
    items: items?.n ?? 0,
    categories_item: catItems?.n ?? 0,
    categories_client: catClients?.n ?? 0,
    payment_accounts: paymentAccounts?.n ?? 0,
    sale_items: saleItems?.n ?? 0,
    purchase_items: purchaseItems?.n ?? 0,
    payments: payments?.n ?? 0,
    attach_file_total: fileTotal?.n ?? 0,
    attach_ref_count: refCount?.n ?? 0,
  };
}
