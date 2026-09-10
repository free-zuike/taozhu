import { randomId } from './password';

/**
 * 库存变动（原子 UPSERT，按 商品+单位）：
 * 进货 delta>0、出货 delta<0；行不存在则创建（min_stock 默认 0），存在则增减。
 * 返回 D1PreparedStatement，供单据路由放入 batch 保证与明细同事务。
 */
export function stockDelta(db: D1Database, itemId: string, unit: string, delta: number): D1PreparedStatement {
  return db.prepare(
    `INSERT INTO stocks (id, item_id, unit, quantity, min_stock) VALUES (?, ?, ?, ?, 0)
     ON CONFLICT(item_id, unit) DO UPDATE SET quantity = quantity + excluded.quantity`,
  ).bind(randomId(), itemId, unit, delta);
}

/** 盘点/设阈值（全量覆盖单行） */
export function stockUpsert(
  db: D1Database,
  itemId: string,
  unit: string,
  quantity: number,
  minStock: number,
): D1PreparedStatement {
  return db.prepare(
    `INSERT INTO stocks (id, item_id, unit, quantity, min_stock) VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(item_id, unit) DO UPDATE SET quantity = excluded.quantity, min_stock = excluded.min_stock`,
  ).bind(randomId(), itemId, unit, quantity, minStock);
}