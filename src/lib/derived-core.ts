/**
 * 业务账本核心明细快照：把 sale_items / payments / purchase_items 三张「大头流水表」的
 * 全量明细合并成一份快照，所有读端点（/clients、/stats/*、/sales 列表、/stats/overview）
 * 共用，只在出货/收款/进货写入时精确失效、重扫一次。
 *
 * 根因：原先每个读端点各自全扫这几张大表——一笔出货写入会触发 clients 余额、stocks、
 * 全局计数、出货单列表、stats 各视图各自重扫一遍，行读取被放大 4~5 倍。抽出 core 后，
 * 一次写入只扫一次，各端点从快照里用 JS 按日期/店铺过滤聚合（1545 行→读 1 行快照）。
 *
 * 仅出货/收款/进货三类写入会改变这三张表的数据；客户/商品/分类等写入不改流水数据，
 * 由各自的轻量小表扫描或上游缓存处理，不会打掉 core。
 */
import { versionedSnapshot, unaffectedTypes } from './snapshot';

export interface CoreSaleItem {
  id: string;
  sale_id: string;
  client_id: string;
  item_id: string;
  unit: string | null;
  quantity: number;
  sale_price: number;
  cost_price: number;
  amount: number;
  happened_at: string | null;
  note: string | null;
  created_by: string | null;
  sort: number | null;
  created_at: string;
}

export interface CorePayment {
  client_id: string;
  amount: number;
  waived: number;
  happened_at: string | null;
}

export interface CorePurchaseItem {
  id: string;
  item_id: string;
  unit: string | null;
  quantity: number;
  amount: number;
  happened_at: string | null;
}

export interface DerivedCore {
  saleItems: CoreSaleItem[];
  payments: CorePayment[];
  purchaseItems: CorePurchaseItem[];
}

/** 只列「不影响三张流水表数据」的写入；出货/收款/进货一律判为相关 → 重算。 */
const CORE_UNRELATED_TYPES = [
  'client', 'item', 'category', 'price_group', 'payment_account',
  'device', 'user', 'settings', 'setting', 'theme', 'ai_config',
  'attachment', 'share_link', 'stmt_template', 'loss_record', 'stock_adjustment',
];

export async function loadDerivedCore(db: D1Database): Promise<DerivedCore> {
  return versionedSnapshot<DerivedCore>(
    db, 'derived_core', async () => {
      const [si, py, pi] = await Promise.all([
        db.prepare(
          `SELECT id, sale_id, client_id, item_id, unit, quantity, sale_price, cost_price, amount, happened_at, note, created_by, sort, created_at
           FROM sale_items`,
        ).all<CoreSaleItem>(),
        db.prepare(
          `SELECT client_id, amount, waived, happened_at FROM payments`,
        ).all<CorePayment>(),
        db.prepare(
          `SELECT id, item_id, unit, quantity, amount, happened_at FROM purchase_items`,
        ).all<CorePurchaseItem>(),
      ]);
      return { saleItems: si.results, payments: py.results, purchaseItems: pi.results };
    },
    '',
    // 仅 book 写入生效：用反向白名单，未知/新增 entity_type 一律保守重算。
    // 精确失效 + steadyCursorReuse：出货/收款/进货写入立刻重算；游标没变（页面常开、
    // 零写入）则永不重算。TTL 只作「游标已前进」时的兜底——原先 60s/30min 的定时重算
    // 会让空闲期仍周期性全扫三张流水表，且 ts 不随命中刷新，是网页常开时 rows_read 的大头。
    // 绕过变更流的通道（备份恢复 / schema 迁移 / 库存重建 / 附件存量迁移）统一 expireSnapshots。
    {
      ttlMs: 30 * 60_000,
      affectedSince: unaffectedTypes(db, CORE_UNRELATED_TYPES),
      steadyCursorReuse: true,
    },
  ).then((x) => x.data);
}
