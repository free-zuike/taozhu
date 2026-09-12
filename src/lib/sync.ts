/** 同步协议核心：变更流（append-only 日志，业务表即投影）+ LWW 冲突解决。
 *  - 变更流 sync_changes：id 自增即拉取游标；同一实体多次变更按行递增，pull 按游标增量下发。
 *  - 冲突 LWW（Last-Write-Wins）：updated_at 决胜，时间戳相同按 device_id 字典序，同设备=幂等重放。
 *  - payload 为实体完整快照（admin 视角，pull 时按角色打码敏感价）；push 时服务端应用到业务表。
 *  - 单据（sale/purchase）upsert/delete 复用与在线路由一致的库存联动（stockDelta 进 batch）。
 */
import { stockDelta } from './stock';
import { randomId } from './password';
import { notifyClients } from '../services/sync-hub';

export const SYNC_ENTITIES = ['client', 'item', 'category', 'sale', 'purchase', 'payment'] as const;
export type SyncEntityType = (typeof SYNC_ENTITIES)[number];

export interface SyncChangeInput {
  entity_type: string;
  entity_sync_id: string;
  action?: 'upsert' | 'delete';
  payload: unknown;
  updated_by_device_id?: string | null;
  updated_by_username?: string | null;
  /** 变更时间（LWW 依据）：push 场景必须用客户端带来的 updated_at，否则服务端入库时间会盖过客户端时间戳破坏决断 */
  updated_at?: string | null;
}

/** 追加一条变更记录（返回新行的 id，即游标） */
export async function recordChange(db: D1Database, c: SyncChangeInput): Promise<number> {
  const updatedAt = c.updated_at && !Number.isNaN(Date.parse(c.updated_at)) ? c.updated_at : new Date().toISOString();
  const res = await db.prepare(
    `INSERT INTO sync_changes (entity_type, entity_sync_id, action, payload_json, updated_at, updated_by_device_id, updated_by_username)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  ).bind(
    c.entity_type, c.entity_sync_id, c.action ?? 'upsert',
    JSON.stringify(c.payload ?? {}), updatedAt,
    c.updated_by_device_id ?? null, c.updated_by_username ?? null,
  ).run();
  // 实时同步：变更已入流 → 通知所有在线客户端拉取（失败静默）
  await notifyClients();
  return Number(res.meta.last_row_id ?? 0);
}

/** 查询某实体的最新一条变更（LWW 比较与幂等判断用） */
export async function latestChange(
  db: D1Database,
  entityType: string,
  entitySyncId: string,
): Promise<{ id: number; action: string; updated_at: string; updated_by_device_id: string | null } | null> {
  return db.prepare(
    'SELECT id, action, updated_at, updated_by_device_id FROM sync_changes WHERE entity_type = ? AND entity_sync_id = ? ORDER BY id DESC LIMIT 1',
  ).bind(entityType, entitySyncId).first<{ id: number; action: string; updated_at: string; updated_by_device_id: string | null }>();
}

/** 当前变更流最大游标 */
export async function maxCursor(db: D1Database): Promise<number> {
  const row = await db.prepare('SELECT MAX(id) AS m FROM sync_changes').first<{ m: number | null }>();
  return row?.m ?? 0;
}

/** 构建实体当前完整快照（admin 视角；不存在返回 null） */
export async function buildPayload(db: D1Database, entityType: string, id: string): Promise<Record<string, unknown> | null> {
  switch (entityType) {
    case 'client': {
      const r = await db.prepare('SELECT * FROM clients WHERE id = ?').bind(id).first<Record<string, unknown>>();
      if (!r) return null;
      return {
        id: r.id, name: r.name, contact: r.contact ?? '', phone: r.phone ?? '', note: r.note ?? '',
        start_date: r.start_date ?? '', end_date: r.end_date ?? '', month_start_day: r.month_start_day ?? 1,
        category_id: r.category_id ?? '', deleted_at: r.deleted_at ?? null,
      };
    }
    case 'item': {
      const r = await db.prepare('SELECT * FROM items WHERE id = ?').bind(id).first<Record<string, unknown>>();
      if (!r) return null;
      const prices = await db.prepare('SELECT * FROM item_prices WHERE item_id = ? ORDER BY unit').bind(id).all();
      return {
        id: r.id, name: r.name, category: r.category ?? '', category_id: r.category_id ?? '',
        deleted_at: r.deleted_at ?? null, prices: prices.results,
      };
    }
    case 'category': {
      const r = await db.prepare('SELECT * FROM categories WHERE id = ?').bind(id).first<Record<string, unknown>>();
      if (!r) return null;
      return { id: r.id, type: r.type, name: r.name, parent_id: r.parent_id ?? null, sort: r.sort ?? 0 };
    }
    case 'sale': {
      const r = await db.prepare(
        `SELECT s.*, c.name AS client_name,
           (SELECT COALESCE(SUM(si.amount),0) FROM sale_items si WHERE si.sale_id = s.id) AS total
         FROM sales s JOIN clients c ON c.id = s.client_id WHERE s.id = ?`,
      ).bind(id).first<Record<string, unknown>>();
      if (!r) return null;
      const detail = await db.prepare(
        `SELECT si.*, i.name AS item_name FROM sale_items si JOIN items i ON i.id = si.item_id WHERE si.sale_id = ?`,
      ).bind(id).all();
      return {
        id: r.id, client_id: r.client_id, client_name: r.client_name,
        happened_at: r.happened_at, note: r.note ?? '', total: r.total ?? 0,
        items: detail.results,
      };
    }
    case 'purchase': {
      const r = await db.prepare(
        `SELECT p.*, (SELECT COALESCE(SUM(pi.amount),0) FROM purchase_items pi WHERE pi.purchase_id = p.id) AS total
         FROM purchases p WHERE p.id = ?`,
      ).bind(id).first<Record<string, unknown>>();
      if (!r) return null;
      const detail = await db.prepare(
        `SELECT pi.*, i.name AS item_name FROM purchase_items pi JOIN items i ON i.id = pi.item_id WHERE pi.purchase_id = ?`,
      ).bind(id).all();
      return {
        id: r.id, happened_at: r.happened_at, note: r.note ?? '', total: r.total ?? 0,
        items: detail.results,
      };
    }
    case 'payment': {
      const r = await db.prepare('SELECT * FROM payments WHERE id = ?').bind(id).first<Record<string, unknown>>();
      if (!r) return null;
      return {
        id: r.id, client_id: r.client_id, happened_at: r.happened_at,
        amount: r.amount, waived: r.waived ?? 0, method: r.method ?? '', note: r.note ?? '',
      };
    }
    default:
      return null;
  }
}

/** staff 拉取时对敏感价打码（item 进价、单据进价快照——与在线 GET 打码口径一致） */
export function maskPayload(entityType: string, payload: unknown): unknown {
  if (entityType === 'item') {
    const p = payload as { prices?: Array<Record<string, unknown>> };
    if (!Array.isArray(p.prices)) return payload;
    return { ...p, prices: p.prices.map((x) => ({ ...x, purchase_price: 0 })) };
  }
  if (entityType === 'sale' || entityType === 'purchase') {
    const p = payload as { items?: Array<Record<string, unknown>> };
    if (!Array.isArray(p.items)) return payload;
    const costKey = entityType === 'sale' ? 'cost_price' : 'purchase_price';
    return { ...p, items: p.items.map((x) => ({ ...x, [costKey]: 0 })) };
  }
  return payload;
}

// ---------------------------------------------------------------------------
// push 应用到业务表（业务表 = 投影）。与在线路由一致的校验与库存联动。
// ---------------------------------------------------------------------------

async function applySaleUpsert(db: D1Database, id: string, p: Record<string, any>): Promise<void> {
  await db.prepare(
    `INSERT INTO sales (id, client_id, happened_at, note) VALUES (?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET client_id = excluded.client_id, happened_at = excluded.happened_at, note = excluded.note`,
  ).bind(id, p.client_id ?? '', p.happened_at ?? '', p.note ?? '').run();
  // 已有旧明细：回滚其库存（出货扣减恢复），再整体替换
  const old = await db.prepare('SELECT item_id, unit, quantity FROM sale_items WHERE sale_id = ?').bind(id)
    .all<{ item_id: string; unit: string; quantity: number }>();
  const batch: D1PreparedStatement[] = old.results.map((it) => stockDelta(db, it.item_id, it.unit, it.quantity));
  batch.push(db.prepare('DELETE FROM sale_items WHERE sale_id = ?').bind(id));
  for (const it of ((p.items as Record<string, any>[]) ?? [])) {
    const qty = Number(it.quantity) || 0;
    if (qty <= 0) continue;
    const amount = Number(it.amount) || Math.round(qty * (Number(it.sale_price) || 0) * 100) / 100;
    batch.push(db.prepare(
      'INSERT INTO sale_items (id, sale_id, item_id, unit, quantity, sale_price, cost_price, amount, happened_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    ).bind(it.id ?? randomId(), id, it.item_id ?? '', it.unit ?? '', qty,
      Number(it.sale_price) || 0, Number(it.cost_price) || 0, Math.round(amount * 100) / 100,
      it.happened_at || p.happened_at || null));
    batch.push(stockDelta(db, it.item_id ?? '', it.unit ?? '', -qty));
  }
  await db.batch(batch);
}

async function applyPurchaseUpsert(db: D1Database, id: string, p: Record<string, any>): Promise<void> {
  await db.prepare(
    `INSERT INTO purchases (id, happened_at, note) VALUES (?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET happened_at = excluded.happened_at, note = excluded.note`,
  ).bind(id, p.happened_at ?? '', p.note ?? '').run();
  const old = await db.prepare('SELECT item_id, unit, quantity FROM purchase_items WHERE purchase_id = ?').bind(id)
    .all<{ item_id: string; unit: string; quantity: number }>();
  const batch: D1PreparedStatement[] = old.results.map((it) => stockDelta(db, it.item_id, it.unit, -it.quantity));
  batch.push(db.prepare('DELETE FROM purchase_items WHERE purchase_id = ?').bind(id));
  for (const it of ((p.items as Record<string, any>[]) ?? [])) {
    const qty = Number(it.quantity) || 0;
    if (qty <= 0) continue;
    const amount = Number(it.amount) || Math.round(qty * (Number(it.purchase_price) || 0) * 100) / 100;
    batch.push(db.prepare(
      'INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount, happened_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    ).bind(it.id ?? randomId(), id, it.item_id ?? '', it.unit ?? '', qty,
      Number(it.purchase_price) || 0, Math.round(amount * 100) / 100,
      it.happened_at || p.happened_at || null));
    batch.push(stockDelta(db, it.item_id ?? '', it.unit ?? '', qty));
  }
  await db.batch(batch);
}

/** 把一条变更应用到业务表；返回是否成功（校验/异常失败 → rejected） */
export async function applyChange(
  db: D1Database,
  ch: { entity_type: string; entity_sync_id: string; action: string; payload: unknown },
): Promise<{ ok: boolean; error?: string }> {
  const { entity_type, entity_sync_id: id, action } = ch;
  const p = (ch.payload ?? {}) as Record<string, any>;
  try {
    switch (entity_type) {
      case 'client':
        if (action === 'delete') break; // 店铺为软删（deleted_at），不做物理删除
        await db.prepare(
          `INSERT INTO clients (id, name, contact, phone, note, start_date, end_date, month_start_day, category_id, deleted_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(id) DO UPDATE SET name = excluded.name, contact = excluded.contact, phone = excluded.phone,
             note = excluded.note, start_date = excluded.start_date, end_date = excluded.end_date,
             month_start_day = excluded.month_start_day, category_id = excluded.category_id, deleted_at = excluded.deleted_at`,
        ).bind(id, p.name ?? '', p.contact ?? '', p.phone ?? '', p.note ?? '',
          p.start_date ?? null, p.end_date ?? null, Number(p.month_start_day) || 1,
          p.category_id ?? null, p.deleted_at ?? null).run();
        break;
      case 'item': {
        if (action === 'delete') break; // 商品为软删（deleted_at），不做物理删除
        await db.prepare(
          `INSERT INTO items (id, name, category, category_id, deleted_at) VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(id) DO UPDATE SET name = excluded.name, category = excluded.category,
             category_id = excluded.category_id, deleted_at = excluded.deleted_at`,
        ).bind(id, p.name ?? '', p.category ?? '', p.category_id ?? null, p.deleted_at ?? null).run();
        // 整体替换价格组合：先停用旧行，再恢复 payload 中 active 的行（保留原 id 防单据引用断裂）
        await db.prepare('UPDATE item_prices SET active = 0 WHERE item_id = ?').bind(id).run();
        for (const price of ((p.prices as Record<string, any>[]) ?? [])) {
          const pid = String(price?.id ?? '');
          if (!pid || Number(price.active) !== 1) continue;
          await db.prepare(
            `INSERT INTO item_prices (id, item_id, unit, purchase_price, sale_price, active) VALUES (?, ?, ?, ?, ?, 1)
             ON CONFLICT(id) DO UPDATE SET item_id = excluded.item_id, unit = excluded.unit,
               purchase_price = excluded.purchase_price, sale_price = excluded.sale_price, active = 1`,
          ).bind(pid, id, price.unit ?? '', Number(price.purchase_price) || 0, Number(price.sale_price) || 0).run();
        }
        break;
      }
      case 'category':
        if (action === 'delete') {
          await db.prepare('UPDATE clients SET category_id = NULL WHERE category_id = ?').bind(id).run();
          await db.prepare("UPDATE items SET category_id = NULL, category = '' WHERE category_id = ?").bind(id).run();
          await db.prepare('DELETE FROM categories WHERE id = ?').bind(id).run();
        } else {
          await db.prepare(
            `INSERT INTO categories (id, type, name, parent_id, sort) VALUES (?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET type = excluded.type, name = excluded.name,
               parent_id = excluded.parent_id, sort = excluded.sort`,
          ).bind(id, p.type ?? 'item', p.name ?? '', p.parent_id ?? null, Number(p.sort) || 0).run();
        }
        break;
      case 'sale':
        if (action === 'delete') {
          const old = await db.prepare('SELECT item_id, unit, quantity FROM sale_items WHERE sale_id = ?').bind(id)
            .all<{ item_id: string; unit: string; quantity: number }>();
          const bt: D1PreparedStatement[] = old.results.map((it) => stockDelta(db, it.item_id, it.unit, it.quantity));
          bt.push(db.prepare('DELETE FROM sales WHERE id = ?').bind(id));
          await db.batch(bt);
        } else {
          await applySaleUpsert(db, id, p);
        }
        break;
      case 'purchase':
        if (action === 'delete') {
          const old = await db.prepare('SELECT item_id, unit, quantity FROM purchase_items WHERE purchase_id = ?').bind(id)
            .all<{ item_id: string; unit: string; quantity: number }>();
          const bt: D1PreparedStatement[] = old.results.map((it) => stockDelta(db, it.item_id, it.unit, -it.quantity));
          bt.push(db.prepare('DELETE FROM purchases WHERE id = ?').bind(id));
          await db.batch(bt);
        } else {
          await applyPurchaseUpsert(db, id, p);
        }
        break;
      case 'payment':
        if (action === 'delete') {
          await db.prepare('DELETE FROM payments WHERE id = ?').bind(id).run();
        } else {
          await db.prepare(
            `INSERT INTO payments (id, client_id, happened_at, amount, waived, method, note) VALUES (?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET client_id = excluded.client_id, happened_at = excluded.happened_at,
               amount = excluded.amount, waived = excluded.waived, method = excluded.method, note = excluded.note`,
          ).bind(id, p.client_id ?? '', p.happened_at ?? '', Number(p.amount) || 0, Number(p.waived) || 0,
            p.method ?? '', p.note ?? '').run();
        }
        break;
      default:
        return { ok: false, error: `未知实体类型: ${entity_type}` };
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}