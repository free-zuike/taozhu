/** 进货/出货记单核心（v0.17.478 抽出）：POST /purchases、POST /sales 与 AI 助手
 *  「一句话落单」工具共用同一套落库逻辑（FIFO 批次/欠款联动/审计/变更流不漂移）。
 *  行为与迁移前路由 handler 逐字节一致（校验顺序、错误消息、返回字段），路由仅作薄包装。 */
import { orderIdWith, randomId } from '../lib/password';
import { chunkQuery } from '../lib/query';
import { stockDeltaFor } from '../lib/stock';
import { buildPayload, recordChange } from '../lib/sync';
import { consumeFifoStatements } from '../lib/fifo';
import { getRoundingConfig, roundMoney } from '../lib/money';
import { recordAudit } from '../routes/audit';
import { ApiError } from '../lib/api-error';
import type { D1Database } from '@cloudflare/workers-types';

const nowIso = () => new Date().toISOString();

export interface PurchaseLineInput {
  price_id: string;
  quantity: number;
  purchase_price?: number;
  count_qty?: number;
  happened_at?: string;
  note?: string;
  expiry_date?: string;
  sort?: number;
}

export interface PurchaseOrderInput {
  happened_at?: string;
  note?: string;
  sync_key?: string;
  items: PurchaseLineInput[];
}

export interface SaleLineInput {
  price_id: string;
  quantity: number;
  sale_price?: number;
  cost_price?: number;
  count_qty?: number;
  happened_at?: string;
  note?: string;
  sort?: number;
}

export interface SaleOrderInput {
  client_id: string;
  happened_at?: string;
  note?: string;
  sync_key?: string;
  items: SaleLineInput[];
}

/** 创建进货单（原 POST /purchases 核心；失败抛 ApiError） */
export async function createPurchaseOrder(
  db: D1Database,
  user: { id: string; username: string },
  input: PurchaseOrderInput,
): Promise<{ id: string; happened_at: string; note: string; total: number; items: number; dup?: boolean }> {
  const items = input.items ?? [];
  const syncKey = input.sync_key?.trim() || '';
  if (!Array.isArray(items) || items.length === 0) throw new ApiError('请至少添加一种商品', 400);

  // 幂等：同一 sync_key 已存在（离线重放重复投递）→ 返回已有记录，不重复建单/不重复加库存
  if (syncKey) {
    const existed = await db.prepare('SELECT purchase_id FROM purchase_items WHERE sync_key = ?').bind(syncKey).first<{ purchase_id: string }>();
    if (existed) return { id: existed.purchase_id, happened_at: '', note: '', total: 0, items: 0, dup: true };
  }

  const priceIds = items.map((i) => i.price_id);
  if (priceIds.some((p) => !p)) throw new ApiError('商品缺单位价格', 400);
  const priceRows = await chunkQuery(priceIds, (chunk) =>
    db.prepare(
      `SELECT p.id, p.item_id, p.unit, p.purchase_price, p.per, i.count_unit
       FROM item_prices p LEFT JOIN items i ON i.id = p.item_id WHERE p.id IN (${chunk.map(() => '?').join(',')})`,
    ).bind(...chunk).all<{ id: string; item_id: string; unit: string; purchase_price: number; per?: number | null; count_unit?: string | null }>().then((r) => r.results));

  const priceMap = new Map(priceRows.map((p) => [p.id, p]));
  const purchaseId = orderIdWith('p');
  const happenedAt = input.happened_at?.trim() || nowIso().slice(0, 10);
  const note = input.note?.trim() ?? '';
  let total = 0;
  const money = await getRoundingConfig(db);

  const batch: D1PreparedStatement[] = [];
  for (const [i, item] of items.entries()) {
    const price = priceMap.get(item.price_id);
    if (!price) throw new ApiError(`价格不存在: ${item.price_id}`, 400);
    const qty = Number(item.quantity);
    if (!Number.isFinite(qty) || qty <= 0) throw new ApiError('数量必须大于 0', 400);
    const priceIn = Number(item.purchase_price);
    const effective = Number.isFinite(priceIn) && priceIn > 0 ? priceIn : price.purchase_price;
    const amount = qty * effective;
    total += amount;
    const countQty = Number((item as { count_qty?: number }).count_qty);
    const per = Number(price.per ?? 0);
    const effCount = Number.isFinite(countQty) && countQty > 0
      ? countQty
      : (per > 0 ? Math.round(qty * per * 100) / 100 : qty);
    const lineSort = Number.isFinite(Number(item.sort)) && Number(item.sort) >= 0 ? Number(item.sort) : i;
    const piId = randomId();
    batch.push(
      db.prepare(
        'INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, count_qty, purchase_price, amount, happened_at, note, expiry_date, created_by, sync_key, sort) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ).bind(piId, purchaseId, price.item_id, price.unit, qty, effCount === qty ? null : effCount, effective, amount,
        item.happened_at?.trim() || happenedAt, item.note?.trim() ?? '', item.expiry_date?.trim() ?? '', user.id, syncKey || null, lineSort),
    );
    batch.push(
      db.prepare(
        'INSERT INTO stock_batches (batch_id, item_id, unit, price, remaining, happened_at, expiry_date) VALUES (?, ?, ?, ?, ?, ?, ?)',
      ).bind(piId, price.item_id, price.unit, effective, qty, item.happened_at?.trim() || happenedAt, item.expiry_date?.trim() || ''),
    );
    batch.push(stockDeltaFor(db, { item_id: price.item_id, unit: price.unit, quantity: qty, count_qty: effCount === qty ? null : effCount, count_unit: price.count_unit, per }, 1));
  }

  await db.batch(batch);
  await recordChange(db, { entity_type: 'purchase', entity_sync_id: purchaseId, payload: await buildPayload(db, 'purchase', purchaseId), updated_by_username: user.username });
  await recordAudit(db, { username: user.username, action: 'create', entity_type: 'purchase', entity_id: purchaseId, detail: `添加进货：${items.length} 件商品，合计 ¥${roundMoney(total, money).toFixed(money.digits)}` });
  return { id: purchaseId, happened_at: happenedAt, note, total: roundMoney(total, money), items: items.length };
}

/** 创建出货单（原 POST /sales 核心；失败抛 ApiError） */
export async function createSaleOrder(
  db: D1Database,
  user: { id: string; username: string; role: string },
  input: SaleOrderInput,
): Promise<{ id: string; client_id: string; happened_at: string; note: string; total: number; items: number; dup?: boolean }> {
  const clientId = input.client_id;
  const items = input.items ?? [];
  const syncKey = input.sync_key?.trim() || '';
  if (!clientId) throw new ApiError('请选择店铺', 400);
  if (!Array.isArray(items) || items.length === 0) throw new ApiError('请至少添加一种商品', 400);

  if (syncKey) {
    const existed = await db.prepare('SELECT sale_id FROM sale_items WHERE sync_key = ?').bind(syncKey).first<{ sale_id: string }>();
    if (existed) return { id: existed.sale_id, client_id: clientId, happened_at: '', note: '', total: 0, items: 0, dup: true };
  }

  const client = await db.prepare('SELECT id FROM clients WHERE id = ? AND deleted_at IS NULL').bind(clientId).first();
  if (!client) throw new ApiError('店铺不存在', 404);

  const priceIds = items.map((i) => i.price_id);
  if (priceIds.some((p) => !p)) throw new ApiError('商品缺单位价格', 400);
  const priceRows = await chunkQuery(priceIds, (chunk) =>
    db.prepare(
      `SELECT p.id, p.item_id, p.unit, p.purchase_price, p.sale_price, p.active, p.per, i.count_unit
       FROM item_prices p LEFT JOIN items i ON i.id = p.item_id WHERE p.id IN (${chunk.map(() => '?').join(',')})`,
    ).bind(...chunk).all<{ id: string; item_id: string; unit: string; purchase_price: number; sale_price: number; active: number; per?: number | null; count_unit?: string | null }>().then((r) => r.results));

  const priceMap = new Map(priceRows.map((p) => [p.id, p]));
  const saleId = orderIdWith('s');
  const happenedAt = input.happened_at?.trim() || nowIso().slice(0, 10);
  const note = input.note?.trim() ?? '';
  const saleItemIds: string[] = [];
  let total = 0;
  const money = await getRoundingConfig(db);

  const batch: D1PreparedStatement[] = [];
  for (const [i, item] of items.entries()) {
    const price = priceMap.get(item.price_id);
    if (!price || !price.active) throw new ApiError(`价格不存在或已停用: ${item.price_id}`, 400);
    const qty = Number(item.quantity);
    if (!Number.isFinite(qty) || qty <= 0) throw new ApiError('数量必须大于 0', 400);
    const salePrice = Number(item.sale_price);
    const effectiveSale = Number.isFinite(salePrice) && salePrice > 0 ? salePrice : price.sale_price;
    const amount = qty * effectiveSale;
    total += amount;
    const siId = randomId();
    saleItemIds.push(siId);
    const { result: fifo, stmts: fifoStmts } = await consumeFifoStatements(db, price.item_id, price.unit, qty, siId);
    const manualCost = item.cost_price !== undefined && Number(item.cost_price) > 0 ? Number(item.cost_price) : null;
    const costPrice = user.role === 'admin' && manualCost !== null
      ? manualCost
      : (fifo.leftover > 0 ? (fifo.cost + fifo.leftover * price.purchase_price) / qty : fifo.cost / qty);
    batch.push(...fifoStmts);
    const countQty = Number((item as { count_qty?: number }).count_qty);
    const per = Number(price.per ?? 0);
    const effCount = Number.isFinite(countQty) && countQty > 0 ? countQty : (per > 0 ? Math.round(qty * per * 100) / 100 : qty);
    const lineSort = Number.isFinite(Number(item.sort)) && Number(item.sort) >= 0 ? Number(item.sort) : i;
    batch.push(
      db.prepare(
        'INSERT INTO sale_items (id, sale_id, client_id, item_id, unit, quantity, count_qty, sale_price, cost_price, amount, happened_at, note, created_by, sync_key, sort) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ).bind(siId, saleId, clientId, price.item_id, price.unit, qty, effCount === qty ? null : effCount, effectiveSale, costPrice, amount,
        item.happened_at?.trim() || happenedAt, item.note?.trim() ?? '', user.id, syncKey || null, lineSort),
    );
    batch.push(stockDeltaFor(db, { item_id: price.item_id, unit: price.unit, quantity: qty, count_qty: effCount === qty ? null : effCount, count_unit: price.count_unit, per }, -1));
  }

  await db.batch(batch);
  await recordChange(db, { entity_type: 'sale', entity_sync_id: saleId, payload: await buildPayload(db, 'sale', saleId), updated_by_username: user.username });
  const clientName = (await db.prepare('SELECT name FROM clients WHERE id = ?').bind(clientId).first<{ name: string }>())?.name ?? clientId;
  await recordAudit(db, { username: user.username, action: 'create', entity_type: 'sale', entity_id: saleId, detail: `添加出货：店铺 ${clientName}，${items.length} 件商品，合计 ¥${roundMoney(total, money).toFixed(money.digits)}` });
  return { id: saleId, client_id: clientId, happened_at: happenedAt, note, total: roundMoney(total, money), items: saleItemIds.length };
}
