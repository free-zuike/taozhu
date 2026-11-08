/** 同步路由：POST /push（批量变更 + LWW 冲突解决）、GET /pull（游标增量拉取）、GET /full（首同步全量快照）。
 *  taozhu 为单一数据域（admin/staff 共享同一批数据），无 ledger/scope 维度；
 *  变更流 sync_changes 全量共享，按 (entity_type, entity_sync_id) 的最新一条做 LWW 决胜。
 *  权限：staff 只能推 sale/purchase 的 upsert（送货员记单场景）；主数据与删除仅 admin。
 */
import { Hono } from 'hono';
import { authMiddleware } from '../middleware/auth';
import { chunkQuery } from '../lib/query';
import { applyChange, buildPayload, latestChange, maskPayload, maxCursor, recordChange } from '../lib/sync';
import { loadGlobalCounts } from '../lib/global-counts';
import { orderRefCountsFromLines, refCountByEntity } from '../lib/attachment-counts';
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
  const result = { accepted: 0, rejected: 0, conflict_count: 0, conflict_samples: [] as Array<Record<string, unknown>>, items: [] as Array<Record<string, unknown>> };
  const itemResult = (entityType: string, id: string, ok: boolean, reason?: string) => {
    result.items.push({ entity_type: entityType, entity_sync_id: id, ok, reason: reason ?? '' });
  };

  for (const ch of changes) {
    const entityType = String(ch?.entity_type ?? '').trim();
    const id = String(ch?.entity_sync_id ?? '').trim();
    const action = ch?.action === 'delete' ? 'delete' : 'upsert';
    const incomingTs = Date.parse(String(ch?.updated_at ?? ''));
    if (!entityType || !id) { result.rejected += 1; itemResult(entityType, id, false, 'missing_id'); continue; }
    if (!Number.isFinite(incomingTs)) { result.rejected += 1; itemResult(entityType, id, false, 'bad_timestamp'); continue; }
    // 权限：staff 仅可推 sale/purchase 的 upsert
    if (user.role === 'staff' && !staffPushAllowed(entityType, action)) { result.rejected += 1; itemResult(entityType, id, false, 'forbidden'); continue; }

    // LWW 决胜：比较该实体最新一条已收录变更
    const latest = await latestChange(c.env.DB, entityType, id);
    if (latest) {
      const existingTs = Date.parse(latest.updated_at);
      const isSameDevice = (latest.updated_by_device_id ?? '') === deviceId;
      if (existingTs > incomingTs) {
        result.rejected += 1; result.conflict_count += 1;
        itemResult(entityType, id, false, 'lww_rejected_older_change');
        if (result.conflict_samples.length < 10) {
          result.conflict_samples.push({ reason: 'lww_rejected_older_change', entity_type: entityType, entity_sync_id: id, existing_change_id: latest.id });
        }
        continue;
      }
      if (existingTs === incomingTs) {
        // 同设备幂等重放 → 接受但不重复应用；不同设备同时间戳按设备 id 字典序
        if (isSameDevice) { result.accepted += 1; itemResult(entityType, id, true); continue; }
        if ((latest.updated_by_device_id ?? '') > deviceId) {
          result.rejected += 1; result.conflict_count += 1;
          itemResult(entityType, id, false, 'lww_tie_lost');
          continue;
        }
        if ((latest.updated_by_device_id ?? '') === deviceId) { result.accepted += 1; itemResult(entityType, id, true); continue; }
      }
    }

    // 应用到业务表（投影；含库存联动与附件引用差集 GC），成功后追加变更流
    // username=push 认证用户 → 行级审计"谁干的"记实际登录人（同设备批量变更同人）
    const applied = await applyChange(c.env.DB, c.env, { entity_type: entityType, entity_sync_id: id, action, payload: ch.payload ?? {} }, user.username);
    if (!applied.ok) {
      result.rejected += 1;
      itemResult(entityType, id, false, applied.error || 'apply_failed');
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
    itemResult(entityType, id, true);
  }

  return c.json({ ...result, server_cursor: await maxCursor(c.env.DB), server_time: new Date().toISOString() });
});

// GET /sync/pull?since=&limit=&device_id= — 增量拉取（id 游标；排除自己设备的回声）
syncRouter.get('/pull', async (c) => {
  const user = c.get('user');
  const since = parseInt(c.req.query('since') ?? '0', 10) || 0;
  // clamp：parseInt('abc')=NaN 会让 `LIMIT NaN` 报错；limit=-1 会让 `LIMIT 0` 且 hasMore
  // = (0 > -1) 恒真，客户端陷入无限空拉。按 audit.ts 的写法统一钳制到 [1, 2000]。
  const limit = Math.min(Math.max(Number(c.req.query('limit')) || 500, 1), 2000);
  const deviceId = c.req.query('device_id')?.trim() ?? '';
  // 变更流按保留期清理后，旧游标可能落在已删除区间。不拦截的话客户端会「同步成功」
  // 却静默漏掉中间变更；此时明确要求改走 /sync/full 重建本地库。
  const wmRow = await c.env.DB.prepare("SELECT value FROM schema_meta WHERE key = 'sync_changes_watermark'")
    .first<{ value: string }>();
  const watermark = Number(wmRow?.value ?? 0);
  if (since > 0 && watermark > 0 && since < watermark - 1) {
    return c.json({ changes: [], server_cursor: since, has_more: false, need_full_sync: true });
  }

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

// GET /sync/full/chunk — 大账本分批全量：按实体名分页取行（白名单防 SQL 注入）
syncRouter.get('/full/chunk', async (c) => {
  const ALLOWED = [
    'sale_items', 'purchase_items', 'payments', 'clients', 'items', 'categories',
    'payment_accounts', 'price_groups', 'stock_batches', 'loss_records', 'stock_adjustments',
  ];
  const entity = c.req.query('entity') ?? '';
  if (!ALLOWED.includes(entity)) return c.json({ error: 'entity 不合法' }, 400);
  const offset = Math.max(Number(c.req.query('offset')) || 0, 0);
  const limit = Math.min(Math.max(Number(c.req.query('limit')) || 1000, 1), 5000);
  const rows = await c.env.DB.prepare(`SELECT * FROM ${entity} ORDER BY rowid LIMIT ? OFFSET ?`)
    .bind(limit, offset).all<Record<string, unknown>>();
  const isStaff = c.get('user').role !== 'admin';
  const out = isStaff
    ? rows.results.map((r) => {
      const o = { ...r };
      for (const k of ['purchase_price', 'cost_price', 'price', 'amount']) if (k in o) o[k] = 0;
      return o;
    })
    : rows.results;
  return c.json({ entity, offset, limit, rows: out, has_more: rows.results.length === limit });
});

// GET /sync/full — 首同步全量快照（新设备/重装：一次拉齐全部实体，比逐条 pull 快）
syncRouter.get('/full', async (c) => {
  const user = c.get('user');
  const db = c.env.DB;
  const isStaff = user.role === 'admin' ? false : true;
  // 大账本保护：下面是十几条全表 SELECT，超大会撞 Worker 内存/CPU 预算。
  // 预检走共享计数快照（命中只读 2 行），超限时明确引导改走分批端点，而不是 500 或半截数据。
  const maxRows = Math.min(Math.max(Number(c.req.query('max_rows')) || 50000, 1000), 200000);
  const { data: g } = await loadGlobalCounts(db);
  const rowCount = g.sale_items + g.purchase_items + g.payments;
  if (rowCount > maxRows) {
    return c.json({
      error: `全量快照 ${rowCount} 行超过上限 ${maxRows}，请改用 /sync/full/chunk 分批同步`,
      need_chunk: true, row_count: rowCount,
    }, 413);
  }

  const clientRows = await db.prepare('SELECT * FROM clients WHERE deleted_at IS NULL ORDER BY name').all();
  const clients = clientRows.results.map((x) => {
    const r = x as Record<string, unknown>;
    return {
      id: r.id, name: r.name, contact: r.contact ?? '', phone: r.phone ?? '', note: r.note ?? '',
      start_date: r.start_date ?? '', end_date: r.end_date ?? '', month_start_day: r.month_start_day ?? 1,
      round_stage: r.round_stage ?? 'none', round_unit: r.round_unit ?? 'yuan', round_carry: r.round_carry ?? null,
      category_id: r.category_id ?? '', price_group_id: r.price_group_id ?? '', deleted_at: r.deleted_at ?? null,
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
  const groupPriceRows = await db.prepare('SELECT * FROM item_group_prices ORDER BY unit, group_id').all();
  const byItemGroup = new Map<string, unknown[]>();
  for (const p of groupPriceRows.results) {
    const list = byItemGroup.get((p as { item_id: string }).item_id) ?? [];
    list.push(p);
    byItemGroup.set((p as { item_id: string }).item_id, list);
  }
  const items = itemRows.results.map((x) => {
    const r = x as Record<string, unknown>;
    const prices = (byItem.get(String(r.id)) ?? []).map((q) => {
      const p = q as Record<string, unknown>;
      return isStaff ? { ...p, purchase_price: 0 } : p;
    });
    return { id: r.id, name: r.name, category: r.category ?? '', category_id: r.category_id ?? '', deleted_at: r.deleted_at ?? null, prices, group_prices: byItemGroup.get(String(r.id)) ?? [] };
  });

  const catRows = await db.prepare('SELECT id, type, name, parent_id, sort FROM categories ORDER BY sort, name').all();
  const categories = catRows.results.map((x) => ({ ...(x as Record<string, unknown>) }));

  const paRows = await db.prepare('SELECT id, name, bank_name, card_last_four, sort FROM payment_accounts ORDER BY sort, name').all();
  const payment_accounts = paRows.results.map((x) => ({ ...(x as Record<string, unknown>) }));

  const pgRows = await db.prepare('SELECT id, name, sort FROM price_groups WHERE deleted_at IS NULL ORDER BY sort, name').all();
  const price_groups = pgRows.results.map((x) => ({ ...(x as Record<string, unknown>) }));

  // 收支单据：行级下发（去单据化——每条商品即主记录，自带店铺/日期/备注）
  // 旧字段 sales/purchases（整单嵌套）仅作兼容，新客户端优先读 sale_items/purchase_items 行数组
  const saleItems = await db.prepare(
    `SELECT si.id, si.sale_id, si.client_id, c.name AS client_name, si.item_id, i.name AS item_name,
            i.category AS item_category, si.unit, si.quantity, si.sale_price, si.cost_price, si.amount,
            si.happened_at, si.note, si.created_by, si.sync_key, si.sort
     FROM sale_items si
     JOIN items i ON i.id = si.item_id
     LEFT JOIN clients c ON c.id = si.client_id
     ORDER BY si.created_at`,
  ).all();
  // 行级数组排序：订单(批次)优先 → 批内 sort（用户"第一批在最上方，批内=扫描实际顺序"）。
  // 不按 sort 全局交错（每单 sort 都 0 起，全局排会 A1,B1,C1… 交错）。与 /sales saleItemRows 同口径。
  // 数字段 = 时间戳 + 随机尾（位数不定 1-10，参与比较会主导字典序=批次乱序根因）→ 只取时间戳段：
  // s/p 前缀=毫秒 13 位、si/pi 前缀=微秒 16 位；补零后字典序=时间序
  const rowIdNum = (id: string | null | undefined): string => {
    const m = /^(s|p|si|pi|sl|pl)?(\d+)/.exec(String(id ?? '').trim());
    if (!m) return String(id ?? '');
    const prefix = m[1] || '';
    const digits = m[2];
    const tsLen = prefix.includes('i') ? 16 : 13;
    const core = digits.length >= tsLen ? digits.slice(0, tsLen) : digits;
    return core.padStart(24, '0');
  };
  saleItems.results.sort((a, b) => {
    const oa = rowIdNum((a as { sale_id?: string }).sale_id);
    const ob = rowIdNum((b as { sale_id?: string }).sale_id);
    if (oa !== ob) return oa < ob ? -1 : 1;
    const sa = Number((a as { sort?: number }).sort ?? 0);
    const sb = Number((b as { sort?: number }).sort ?? 0);
    if (sa !== sb) return sa - sb;
    const ia = rowIdNum((a as { id?: string }).id);
    const ib = rowIdNum((b as { id?: string }).id);
    return ia < ib ? -1 : ia > ib ? 1 : 0;
  });
  // 去单据化：head 表已物理删除，整单兼容数组按 sale_id 从商品行聚合派生
  const salesRows = await db.prepare(
    `SELECT si.sale_id AS id, MAX(si.client_id) AS client_id, MAX(COALESCE(si.happened_at, '')) AS happened_at,
            SUM(si.amount) AS total, MIN(si.note) AS note
     FROM sale_items si GROUP BY si.sale_id ORDER BY happened_at DESC`,
  ).all();
  const clientIds = [...new Set(salesRows.results.map((r) => (r as { client_id: string }).client_id))];
  const clientNameRows = await chunkQuery(clientIds, (chunk) =>
    db.prepare(
      `SELECT id, name FROM clients WHERE id IN (${chunk.map(() => '?').join(',')})`,
    ).bind(...chunk).all<{ id: string; name: string }>().then((r) => r.results));
  const clientNameOf = new Map(clientNameRows.map((c) => [c.id, c.name]));
  // full 本来就要下发全部明细：一次平铺读 sale_items + 一张小表 Map 拼装即可。
  // 旧形态按 90 个 sale_id 分批 IN、且逐行 JOIN items 回表，是生产 Top #1 消耗源。
  // 保留原 INNER JOIN 口径：商品已不存在（无 items 行）的明细不下发。
  // 全表（含软删）：原明细 JOIN items 不带 deleted_at 条件，软删商品的明细仍要下发
  const allItemRows = await db.prepare('SELECT id, name, category FROM items')
    .all<{ id: string; name: string | null; category: string | null }>();
  const itemInfo = new Map(allItemRows.results.map((i) => [i.id, {
    name: i.name ?? '', category: i.category ?? '',
  }]));
  const saleFlat = await db.prepare(
    'SELECT si.* FROM sale_items si ORDER BY si.sort, si.created_at',
  ).all<Record<string, unknown>>();
  const saleDetail: Array<Record<string, unknown>> = [];
  for (const row of saleFlat.results) {
    const info = itemInfo.get(String(row.item_id));
    if (!info) continue;
    saleDetail.push({ ...row, item_name: info.name, item_category: info.category });
  }
  const bySale = new Map<string, unknown[]>();
  for (const d of saleDetail) {
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
            pi.happened_at, pi.note, pi.created_by, pi.sync_key, pi.sort
     FROM purchase_items pi
     JOIN items i ON i.id = pi.item_id
     ORDER BY pi.sort, pi.created_at`,
  ).all();
  const purchaseRows = await db.prepare(
    `SELECT pi.purchase_id AS id, MAX(COALESCE(pi.happened_at, '')) AS happened_at,
            SUM(pi.amount) AS total, MIN(pi.note) AS note
     FROM purchase_items pi GROUP BY pi.purchase_id ORDER BY happened_at DESC`,
  ).all();
  // 同样去掉按 purchase_id 分批 IN + JOIN items 回表，复用上面的商品小表 Map
  const purchaseFlat = await db.prepare(
    'SELECT pi.* FROM purchase_items pi ORDER BY pi.sort, pi.created_at',
  ).all<Record<string, unknown>>();
  const purchaseDetail: Array<Record<string, unknown>> = [];
  for (const row of purchaseFlat.results) {
    const info = itemInfo.get(String(row.item_id));
    if (!info) continue;
    purchaseDetail.push({ ...row, item_name: info.name });
  }
  const byPurchase = new Map<string, unknown[]>();
  for (const d of purchaseDetail) {
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
    `SELECT st.item_id, st.unit, st.quantity, st.min_stock, i.name AS item_name, i.count_unit FROM stocks st JOIN items i ON i.id = st.item_id ORDER BY i.name`,
  ).all();
  const stocks = stockRows.results.map((x) => {
    const r = x as Record<string, unknown>;
    return isStaff ? { ...r, cost_price: 0 } : r;
  });

  // 损耗流水（报损）：本地离线 FIFO 派生与库存显示需要（库存=进−出−损耗）
  const lossRows = await db.prepare(
    `SELECT lr.id, lr.item_id, lr.unit, lr.qty, lr.price, lr.amount, lr.happened_at, lr.note, lr.created_at, i.name AS item_name
     FROM loss_records lr JOIN items i ON i.id = lr.item_id ORDER BY lr.happened_at, lr.created_at`,
  ).all();
  const losses = lossRows.results.map((x) => {
    const r = x as Record<string, unknown>;
    return isStaff ? { ...r, price: 0, amount: 0 } : r;
  });

  // 盘点调整流水（v0.17.473）：本地库存聚合需要（库存=进−出−损耗±盘点调整）；金额/单价店员打码
  const adjRows = await db.prepare(
    `SELECT sa.id, sa.adjust_id, sa.item_id, sa.unit, sa.qty, sa.price, sa.amount, sa.happened_at, sa.note, sa.created_at, i.name AS item_name
     FROM stock_adjustments sa JOIN items i ON i.id = sa.item_id ORDER BY sa.happened_at, sa.created_at`,
  ).all();
  const adjustments = adjRows.results.map((x) => {
    const r = x as Record<string, unknown>;
    return isStaff ? { ...r, price: 0, amount: 0 } : r;
  });

  return c.json({ clients, items, categories, payment_accounts, price_groups,
    // 去单据化主结构：行级商品记录数组（前端 fullSync 主读数），sales/purchases 整单仅作兼容
    sale_items: saleItems.results, purchase_items: purchaseItems.results,
    sales, purchases, payments, stocks, loss_records: losses, stock_adjustments: adjustments, server_cursor: await maxCursor(db) });
});

// GET /sync/stats — 服务器端各实体计数 + 变更流游标（同步状态面板/差异诊断用）
// 支持可选 ?client_id=X：传入时 sales/payments 只统计该店铺（同步面板"当前店铺"差异行）
// 全局计数走版本化快照（与 /sync/panel、/attachments/total 共用）：命中时只读取游标+快照 2 行，
// 不再每次把 8 张表全表 COUNT 一遍；任何写操作 bump 游标 → 快照立即失效，数字保持精确。
syncRouter.get('/stats', async (c) => {
  const db = c.env.DB;
  const clientId = c.req.query('client_id')?.trim() ?? '';
  const { data: g, cursor } = await loadGlobalCounts(db);
  let saleItems = g.sale_items;
  let paymentCount = g.payments;
  if (clientId) {
    // 店铺级必须实时，且这两个字段在带 client_id 时语义变为「该店铺」——不能取全局快照
    const [cs, cp] = await Promise.all([
      db.prepare('SELECT COUNT(*) AS n FROM sale_items WHERE client_id = ?').bind(clientId).first<{ n: number }>(),
      db.prepare('SELECT COUNT(*) AS n FROM payments WHERE client_id = ?').bind(clientId).first<{ n: number }>(),
    ]);
    saleItems = cs?.n ?? 0;
    paymentCount = cp?.n ?? 0;
  }
  return c.json({
    clients: g.clients,
    items: g.items,
    categories_item: g.categories_item,
    categories_client: g.categories_client,
    payment_accounts: g.payment_accounts,
    // 出货/进货按商品明细行数（并非单据数）
    sale_items: saleItems,
    purchase_items: g.purchase_items,
    purchases: g.purchase_items, // 保留（进货单数，供需要时使用）
    payments: paymentCount,
    server_cursor: cursor,
  });
});

// GET /sync/panel — 同步面板单请求聚合（原 7 请求：/sync/stats 全局+店铺级、3×/attachments/counts、
// /attachments/total、/attachments/in-use 引用数 → 1 请求，更快且原子一致）。面板只读展示；
// 各单查端点保留供其他调用方（同步下载、清理页等）使用。
// 返回：全局计数同 /stats + attach_file_total/attach_ref_count；client_id 非空时附加
// client_sale_items/client_payments + client_*_attach（{counts,total,ids}，对齐 /attachments/counts）。
syncRouter.get('/panel', async (c) => {
  const db = c.env.DB;
  const clientId = c.req.query('client_id')?.trim() ?? '';
  // 附件计数（按店铺聚合，SQL 对齐 /attachments/counts：引用表计数 + 单据级叠加行级引用）
  const countAttach = async (entity: 'sale' | 'payment' | 'sale_item') => {
    let ids: string[] = [];
    if (entity === 'sale') {
      const rows = await db.prepare('SELECT DISTINCT sale_id AS id FROM sale_items WHERE client_id = ?').bind(clientId).all<{ id: string }>();
      ids = rows.results.map((r) => r.id);
    } else if (entity === 'payment') {
      const rows = await db.prepare('SELECT id FROM payments WHERE client_id = ?').bind(clientId).all<{ id: string }>();
      ids = rows.results.map((r) => r.id);
    } else {
      const rows = await db.prepare('SELECT id FROM sale_items WHERE client_id = ?').bind(clientId).all<{ id: string }>();
      ids = rows.results.map((r) => r.id);
    }
    if (ids.length === 0) return { counts: {}, total: 0, ids: [] };
    const counts: Record<string, number> = {};
    // 一次 GROUP BY 取全量引用计数（不再按 90 分批 IN，见 lib/attachment-counts.ts）
    const refCounts = await refCountByEntity(db, entity);
    for (const id of ids) {
      const n = refCounts.get(id);
      if (n) counts[id] = n;
    }
    // 单据级（sale）统计：计入该单全部明细行的行级引用（整单凭证实际挂行级）。
    // 单次 JOIN GROUP BY 按单据聚合，不再分批 IN 回表 sale_items。
    if (entity === 'sale') {
      const lineTotals = await orderRefCountsFromLines(db, 'sale_item', { clientId, orderIds: ids });
      for (const [orderId, n] of lineTotals) {
        if (n > 0) counts[orderId] = (counts[orderId] ?? 0) + n;
      }
    }
    return { counts, total: Object.values(counts).reduce((a, b) => a + b, 0), ids };
  };
  // 全局部分与 /sync/stats、/attachments/total 共用同一份版本化快照（10 条全表 COUNT 只在版本变化时重算）
  const { data: g, cursor } = await loadGlobalCounts(db);
  const out: Record<string, unknown> = {
    clients: g.clients,
    items: g.items,
    categories_item: g.categories_item,
    categories_client: g.categories_client,
    payment_accounts: g.payment_accounts,
    sale_items: g.sale_items,
    purchase_items: g.purchase_items,
    purchases: g.purchase_items,
    payments: g.payments,
    server_cursor: cursor,
    attach_file_total: g.attach_file_total,
    attach_ref_count: g.attach_ref_count,
  };
  if (clientId) {
    const [cSales, cPayments, saleAttach, payAttach, saleLineAttach] = await Promise.all([
      db.prepare('SELECT COUNT(*) AS n FROM sale_items WHERE client_id = ?').bind(clientId).first<{ n: number }>(),
      db.prepare('SELECT COUNT(*) AS n FROM payments WHERE client_id = ?').bind(clientId).first<{ n: number }>(),
      countAttach('sale'),
      countAttach('payment'),
      countAttach('sale_item'),
    ]);
    out.client_sale_items = cSales?.n ?? 0;
    out.client_payments = cPayments?.n ?? 0;
    out.client_sale_attach = saleAttach;
    out.client_payment_attach = payAttach;
    out.client_sale_item_attach = saleLineAttach;
  }
  return c.json(out);
});

export { buildPayload };