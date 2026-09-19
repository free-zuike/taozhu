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

/**
 * 进销单位换算后的库存联动（通用，按字段折算、不含商品名逻辑）：
 * - 商品配了计数单位 count_unit 且与行单位不同，且本行折合数 count_qty（或价格行 per×quantity）≠ quantity
 *   → 库存按 (count_unit, countQty) 累计（进 1 大单位 count_qty=40 → 库存 +40 计数单位）
 * - 否则按原 (unit, quantity)（未折合商品行为不变）
 * sign=1 进货增加 / -1 出货扣减或回滚，delta 数量取折合后值。
 */
export function stockDeltaFor(
  db: D1Database,
  o: { item_id: string; unit: string; quantity: number; count_qty?: number | null; count_unit?: string | null; per?: number | null },
  sign: 1 | -1,
): D1PreparedStatement {
  const cu = o.count_unit?.trim() || '';
  const per = Number(o.per ?? 0);
  const cq = Number(o.count_qty ?? 0);
  const effCount = cq > 0 ? cq : (per > 0 ? Math.round(o.quantity * per * 100) / 100 : 0);
  // 折合且折合单位≠行单位 → 按计数单位累计折合数；否则原单位原数量
  if (cu && cu !== o.unit && effCount > 0 && effCount !== o.quantity) {
    return stockDelta(db, o.item_id, cu, sign * effCount);
  }
  return stockDelta(db, o.item_id, o.unit, sign * o.quantity);
}