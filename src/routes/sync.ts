/** 同步路由：POST /push（批量变更 + LWW 冲突解决）、GET /pull（游标增量拉取）、GET /full（首同步全量快照）。
 *  taozhu 为单一数据域（admin/staff 共享同一批数据），无 ledger/scope 维度；
 *  变更流 sync_changes 全量共享，按 (entity_type, entity_sync_id) 的最新一条做 LWW 决胜。
 *  权限：staff 只能推 sale/purchase 的 upsert（送货员记单场景）；主数据与删除仅 admin。
 */
import { Hono } from 'hono';
import { authMiddleware } from '../middleware/auth';
import { applyChange, buildPayload, latestChange, maskPayload, maxCursor, recordChange } from '../lib/sync';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const syncRouter = new Hono<{ Bindings: Env; Variables: V }>();

syncRouter.use('*', authMiddleware());

// 实时同步 WebSocket 路由在 index.ts 顶层注册（浏览器 WebSocket 无法带 Authorization 请求头，
// 需绕过 syncRouter 的 authMiddleware，改用查询参数 token 校验）。

/** staff 仅可推的单据类型（upsert） */
function staffPushAllowed(entityType: string, action: string): boolean {
  return (entityType === 'sale' || entityType === 'purchase') && action === 'upsert';
}

// POST /sync/push — 批量推送本地变更（LWW：updated_at 决胜，同值按 device_id 字典序，同设备幂等）
syncRouter.post('/push', async (c) => {
  const user = c.get('user');
  const body = await c.req.json().catch(() => null) as {
    device_id?: string;
    changes?: Array<{
      entity_type?: string;
      entity_sync_id?: string;
      action?: string;
      payload?: unknown;
      updated_at?: string;
    }>;
  } | null;
  const deviceId = (body?.device_id as string) || 'unknown';
  const changes = Array.isArray(body?.changes) ? body.changes : [];
  const result = { accepted: 0, rejected: 0, conflict_count: 0, conflict_samples: [] as Array<Record<string, unknown>> };

  for (const ch of changes) {
    const entityType = String(ch?.entity_type ?? '').trim();
    const id = String(ch?.entity_sync_id ?? '').trim();
    const action = ch?.action === 'delete' ? 'delete' : 'upsert';
    const incomingTs = Date.parse(String(ch?.updated_at ?? ''));
    if (!entityType || !id) { result.rejected += 1; continue; }
    if (!Number.isFinite(incomingTs)) { result.rejected += 1; continue; }
    // 权限：staff 仅可推 sale/purchase 的 upsert
    if (user.role === 'staff' && !staffPushAllowed(entityType, action)) { result.rejected += 1; continue; }

    // LWW 决胜：比较该实体最新一条已收录变更
    const latest = await latestChange(c.env.DB, entityType, id);
    if (latest) {
      const existingTs = Date.parse(latest.updated_at);
      const isSameDevice = (latest.updated_by_device_id ?? '') === deviceId;
      if (existingTs > incomingTs) {
        result.rejected += 1; result.conflict_count += 1;
        if (result.conflict_samples.length < 10) {
          result.conflict_samples.push({ reason: 'lww_rejected_older_change', entity_type: entityType, entity_sync_id: id, existing_change_id: latest.id });
        }
        continue;
      }
      if (existingTs === incomingTs) {
        // 同设备幂等重放 → 接受但不重复应用；不同设备同时间戳按设备 id 字典序
        if (isSameDevice) { result.accepted += 1; continue; }
        if ((latest.updated_by_device_id ?? '') > deviceId) {
          result.rejected += 1; result.conflict_count += 1;
          continue;
        }
        if ((latest.updated_by_device_id ?? '') === deviceId) { result.accepted += 1; continue; }
      }
    }

    // 应用到业务表（投影；含库存联动与附件引用差集 GC），成功后追加变更流
    const applied = await applyChange(c.env.DB, c.env, { entity_type: entityType, entity_sync_id: id, action, payload: ch.payload ?? {} });
    if (!applied.ok) {
      result.rejected += 1;
      if (result.conflict_samples.length < 10) {
        result.conflict_samples.push({ reason: 'apply_failed', entity_type: entityType, entity_sync_id: id, error: applied.error });
      }
      continue;
    }
    await recordChange(c.env.DB, {
      entity_type: entityType, entity_sync_id: id, action,
      payload: action === 'upsert' ? (ch.payload ?? {}) : {},
      updated_at: new Date(incomingTs).toISOString(),
      updated_by_device_id: deviceId, updated_by_username: user.username,
    });
    result.accepted += 1;
  }

  return c.json({ ...result, server_cursor: await maxCursor(c.env.DB), server_time: new Date().toISOString() });
});

// GET /sync/pull?since=&limit=&device_id= — 增量拉取（id 游标；排除自己设备的回声）
syncRouter.get('/pull', async (c) => {
  const user = c.get('user');
  const since = parseInt(c.req.query('since') ?? '0', 10) || 0;
  const limit = Math.min(parseInt(c.req.query('limit') ?? '500', 10), 2000);
  const deviceId = c.req.query('device_id')?.trim() ?? '';

  let sql = 'SELECT id, entity_type, entity_sync_id, action, payload_json, updated_at, updated_by_device_id, updated_by_username FROM sync_changes WHERE id > ?';
  const params: (string | number)[] = [since];
  if (deviceId) {
    sql += ' AND (updated_by_device_id IS NULL OR updated_by_device_id != ?)';
    params.push(deviceId);
  }
  sql += ' ORDER BY id ASC LIMIT ?';
  params.push(limit + 1);

  const rows = await c.env.DB.prepare(sql).bind(...params).all<{
    id: number; entity_type: string; entity_sync_id: string; action: string;
    payload_json: string; updated_at: string; updated_by_device_id: string | null; updated_by_username: string | null;
  }>();
  const hasMore = rows.results.length > limit;
  const list = rows.results.slice(0, limit);
  let serverCursor = since;
  const isStaff = user.role === 'admin' ? false : true;
  const changes = list.map((r) => {
    serverCursor = Math.max(serverCursor, r.id);
    let payload: unknown = {};
    try { payload = JSON.parse(r.payload_json); } catch { payload = {}; }
    return {
      id: r.id, entity_type: r.entity_type, entity_sync_id: r.entity_sync_id,
      action: r.action, payload: isStaff ? maskPayload(r.entity_type, payload) : payload,
      updated_at: r.updated_at, updated_by_device_id: r.updated_by_device_id, updated_by_username: r.updated_by_username,
    };
  });
  return c.json({ changes, server_cursor: serverCursor, has_more: hasMore });
});

// GET /sync/full — 首同步全量快照（新设备/重装：一次拉齐全部实体，比逐条 pull 快）
syncRouter.get('/full', async (c) => {
  const user = c.get('user');
  const db = c.env.DB;
  const isStaff = user.role === 'admin' ? false : true;

  const clientRows = await db.prepare('SELECT * FROM clients WHERE deleted_at IS NULL ORDER BY name').all();
  const clients = clientRows.results.map((x) => {
    const r = x as Record<string, unknown>;
    return {
      id: r.id, name: r.name, contact: r.contact ?? '', phone: r.phone ?? '', note: r.note ?? '',
      start_date: r.start_date ?? '', end_date: r.end_date ?? '', month_start_day: r.month_start_day ?? 1,
      category_id: r.category_id ?? '', deleted_at: r.deleted_at ?? null,
    };
  });

  const itemRows = await db.prepare('SELECT * FROM items WHERE deleted_at IS NULL ORDER BY name').all();
  const priceRows = await db.prepare('SELECT * FROM item_prices ORDER BY unit').all();
  const byItem = new Map<string, unknown[]>();
  for (const p of priceRows.results) {
    const list = byItem.get((p as { item_id: string }).item_id) ?? [];
    list.push(p);
    byItem.set((p as { item_id: string }).item_id, list);
  }
  const items = itemRows.results.map((x) => {
    const r = x as Record<string, unknown>;
    const prices = (byItem.get(String(r.id)) ?? []).map((q) => {
      const p = q as Record<string, unknown>;
      return isStaff ? { ...p, purchase_price: 0 } : p;
    });
    return { id: r.id, name: r.name, category: r.category ?? '', category_id: r.category_id ?? '', deleted_at: r.deleted_at ?? null, prices };
  });

  const catRows = await db.prepare('SELECT id, type, name, parent_id, sort FROM categories ORDER BY sort, name').all();
  const categories = catRows.results.map((x) => ({ ...(x as Record<string, unknown>) }));

  const paRows = await db.prepare('SELECT id, name, bank_name, card_last_four, sort FROM payment_accounts ORDER BY sort, name').all();
  const payment_accounts = paRows.results.map((x) => ({ ...(x as Record<string, unknown>) }));

  // 收支单据：行级下发（去单据化——每条商品即主记录，自带店铺/日期/备注）
  // 旧字段 sales/purchases（整单嵌套）仅作兼容，新客户端优先读 sale_items/purchase_items 行数组
  const saleItems = await db.prepare(
    `SELECT si.id, si.sale_id, si.client_id, c.name AS client_name, si.item_id, i.name AS item_name,
            i.category AS item_category, si.unit, si.quantity, si.sale_price, si.cost_price, si.amount,
            si.happened_at, si.note, si.created_by, si.sync_key
     FROM sale_items si
     JOIN items i ON i.id = si.item_id
     LEFT JOIN clients c ON c.id = si.client_id
     ORDER BY si.created_at`,
  ).all();
  // 去单据化：head 表已物理删除，整单兼容数组按 sale_id 从商品行聚合派生
  const salesRows = await db.prepare(
    `SELECT si.sale_id AS id, MAX(si.client_id) AS client_id, MAX(COALESCE(si.happened_at, '')) AS happened_at,
            SUM(si.amount) AS total, MIN(si.note) AS note
     FROM sale_items si GROUP BY si.sale_id ORDER BY happened_at DESC`,
  ).all();
  const saleIds = salesRows.results.map((r) => (r as { id: string }).id);
  const clientNameRows = await db.prepare(
    `SELECT id, name FROM clients WHERE id IN (${[...new Set(salesRows.results.map((r) => (r as { client_id: string }).client_id))].map(() => '?').join(',')})`,
  ).bind(...[...new Set(salesRows.results.map((r) => (r as { client_id: string }).client_id))]).all<{ id: string; name: string }>();
  const clientNameOf = new Map(clientNameRows.results.map((c) => [c.id, c.name]));
  const saleDetail = saleIds.length > 0
    ? await db.prepare(
        `SELECT si.*, i.name AS item_name, i.category AS item_category FROM sale_items si JOIN items i ON i.id = si.item_id WHERE si.sale_id IN (${saleIds.map(() => '?').join(',')}) ORDER BY si.created_at`,
      ).bind(...saleIds).all()
    : { results: [] as unknown[] };
  const bySale = new Map<string, unknown[]>();
  for (const d of saleDetail.results) {
    const list = bySale.get((d as { sale_id: string }).sale_id) ?? [];
    list.push(d);
    bySale.set((d as { sale_id: string }).sale_id, list);
  }
  const sales = salesRows.results.map((x) => {
    const r = x as Record<string, unknown>;
    const items2 = (bySale.get(String(r.id)) ?? []).map((q) => {
      const p = q as Record<string, unknown>;
      return isStaff ? { ...p, cost_price: 0 } : p;
    });
    return { id: r.id, client_id: r.client_id, client_name: clientNameOf.get(String(r.client_id)) ?? '', happened_at: r.happened_at, note: r.note ?? '', total: r.total ?? 0, items: items2 };
  });

  const purchaseItems = await db.prepare(
    `SELECT pi.id, pi.purchase_id, pi.item_id, i.name AS item_name, i.category AS item_category,
            pi.unit, pi.quantity, pi.purchase_price, pi.amount,
            pi.happened_at, pi.note, pi.created_by, pi.sync_key
     FROM purchase_items pi
     JOIN items i ON i.id = pi.item_id
     ORDER BY pi.created_at`,
  ).all();
  const purchaseRows = await db.prepare(
    `SELECT pi.purchase_id AS id, MAX(COALESCE(pi.happened_at, '')) AS happened_at,
            SUM(pi.amount) AS total, MIN(pi.note) AS note
     FROM purchase_items pi GROUP BY pi.purchase_id ORDER BY happened_at DESC`,
  ).all();
  const purchaseIds = purchaseRows.results.map((r) => (r as { id: string }).id);
  const purchaseDetail = purchaseIds.length > 0
    ? await db.prepare(
        `SELECT pi.*, i.name AS item_name FROM purchase_items pi JOIN items i ON i.id = pi.item_id WHERE pi.purchase_id IN (${purchaseIds.map(() => '?').join(',')}) ORDER BY pi.created_at`,
      ).bind(...purchaseIds).all()
    : { results: [] as unknown[] };
  const byPurchase = new Map<string, unknown[]>();
  for (const d of purchaseDetail.results) {
    const list = byPurchase.get((d as { purchase_id: string }).purchase_id) ?? [];
    list.push(d);
    byPurchase.set((d as { purchase_id: string }).purchase_id, list);
  }
  const purchases = purchaseRows.results.map((x) => {
    const r = x as Record<string, unknown>;
    const items2 = (byPurchase.get(String(r.id)) ?? []).map((q) => {
      const p = q as Record<string, unknown>;
      return isStaff ? { ...p, purchase_price: 0 } : p;
    });
    return { id: r.id, happened_at: r.happened_at, note: r.note ?? '', total: r.total ?? 0, items: items2 };
  });

  const paymentRows = await db.prepare('SELECT * FROM payments ORDER BY happened_at').all();
  const payments = paymentRows.results.map((x) => {
    const r = x as Record<string, unknown>;
    return { id: r.id, client_id: r.client_id, happened_at: r.happened_at, amount: r.amount, waived: r.waived ?? 0, method: r.method ?? '', note: r.note ?? '' };
  });

  const stockRows = await db.prepare(
    `SELECT st.item_id, st.unit, st.quantity, st.min_stock, i.name AS item_name FROM stocks st JOIN items i ON i.id = st.item_id ORDER BY i.name`,
  ).all();
  const stocks = stockRows.results.map((x) => {
    const r = x as Record<string, unknown>;
    return isStaff ? { ...r, cost_price: 0 } : r;
  });

  return c.json({ clients, items, categories, payment_accounts,
    // 去单据化主结构：行级商品记录数组（前端 fullSync 主读数），sales/purchases 整单仅作兼容
    sale_items: saleItems.results, purchase_items: purchaseItems.results,
    sales, purchases, payments, stocks, server_cursor: await maxCursor(db) });
});

// GET /sync/stats — 服务器端各实体计数 + 变更流游标（同步状态面板/差异诊断用）
// 支持可选 ?client_id=X：传入时 sales/payments 只统计该店铺（同步面板"当前店铺"差异行）
syncRouter.get('/stats', async (c) => {
  const db = c.env.DB;
  const clientId = c.req.query('client_id')?.trim() ?? '';
  const [clients, items, catItems, catClients, paymentAccounts, saleItems, purchaseItems, purchases, payments] = await Promise.all([
    db.prepare('SELECT COUNT(*) AS n FROM clients WHERE deleted_at IS NULL').first<{ n: number }>(),
    db.prepare('SELECT COUNT(*) AS n FROM items WHERE deleted_at IS NULL').first<{ n: number }>(),
    db.prepare("SELECT COUNT(*) AS n FROM categories WHERE type = 'item'").first<{ n: number }>(),
    db.prepare("SELECT COUNT(*) AS n FROM categories WHERE type = 'client'").first<{ n: number }>(),
    db.prepare('SELECT COUNT(*) AS n FROM payment_accounts').first<{ n: number }>(),
    // 出货/进货按商品明细行数统计（不是单据数：一张单多商品 = 多明细行；商品行自带 client_id）
    clientId
      ? db.prepare('SELECT COUNT(*) AS n FROM sale_items WHERE client_id = ?').bind(clientId).first<{ n: number }>()
      : db.prepare('SELECT COUNT(*) AS n FROM sale_items').first<{ n: number }>(),
    db.prepare('SELECT COUNT(*) AS n FROM purchase_items').first<{ n: number }>(),
    // 去单据化：无 purchases 头表，保留字段语义=进货商品行数（与 purchase_items 一致）
    db.prepare('SELECT COUNT(*) AS n FROM purchase_items').first<{ n: number }>(),
    clientId
      ? db.prepare('SELECT COUNT(*) AS n FROM payments WHERE client_id = ?').bind(clientId).first<{ n: number }>()
      : db.prepare('SELECT COUNT(*) AS n FROM payments').first<{ n: number }>(),
  ]);
  return c.json({
    clients: clients?.n ?? 0,
    items: items?.n ?? 0,
    categories_item: catItems?.n ?? 0,
    categories_client: catClients?.n ?? 0,
    payment_accounts: paymentAccounts?.n ?? 0,
    // 出货/进货按商品明细行数（并非单据数）
    sale_items: saleItems?.n ?? 0,
    purchase_items: purchaseItems?.n ?? 0,
    purchases: purchases?.n ?? 0, // 保留（进货单数，供需要时使用）
    payments: payments?.n ?? 0,
    server_cursor: await maxCursor(db),
  });
});

export { buildPayload };