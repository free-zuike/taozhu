/** 交易附件（凭证图片）：公共图片存储（taozhu/images/attachments/...，MD5 内容去重）。
 *  entity ∈ sale|purchase|payment（单据级）| sale_item|purchase_item（明细行级）；零 D1 写。 */
import { Hono } from 'hono';
import { authMiddleware, adminOnly } from '../middleware/auth';
import { createStorage } from '../services/storage';
import { notifyClients } from '../services/sync-hub';
import { imageKey, LEGACY_IMAGE_PREFIXES, parseAttachmentKey } from '../lib/image-key';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const attachmentsRouter = new Hono<{ Bindings: Env; Variables: V }>();
attachmentsRouter.use('*', authMiddleware());

const VALID_ENTITY = ['sale', 'purchase', 'payment', 'sale_item', 'purchase_item'];
/** 单据级实体（counts 支持按店铺汇总；行级无店铺维度，仅按 ids） */
const ORDER_ENTITY = ['sale', 'purchase', 'payment'];

/** 当前规范前缀：taozhu/images/attachments/{entity}/{id}/ */
const prefixOf = (entity: string, id: string) => `taozhu/images/attachments/${entity}/${id}/`;
/** 兼容前缀列表（历史规范）：{前缀}{entity}/{id}/ */
const legacyPrefixesOf = (entity: string, id: string) =>
  LEGACY_IMAGE_PREFIXES.map((p) => `${p}${entity}/${id}/`);

// GET /attachments?entity=&id= — 列出某交易的全部附件（兼容历史前缀，按 key 去重排序）
attachmentsRouter.get('/', async (c) => {
  const entity = c.req.query('entity');
  const id = c.req.query('id');
  if (!entity || !VALID_ENTITY.includes(entity)) return c.json({ error: 'entity 必须为 sale/purchase/payment 或明细行级 sale_item/purchase_item' }, 400);
  if (!id) return c.json({ error: '缺少 id' }, 400);
  const store = createStorage(c.env);
  const prefixes = [prefixOf(entity, id), ...legacyPrefixesOf(entity, id)];
  const groups = await Promise.all(prefixes.map((p) => store.list(p)));
  const byKey = new Map<string, { key: string; size: number; uploaded?: Date }>();
  for (const group of groups) for (const o of group.objects) byKey.set(o.key, o);
  const attachments = [...byKey.values()].sort((a, b) => a.key.localeCompare(b.key));
  return c.json({
    attachments: attachments.map((o) => ({ key: o.key, size: o.size, uploaded: o.uploaded?.toISOString() ?? '' })),
  });
});

// POST /attachments?entity=&id= — multipart 上传 photo（上限 10MB；同内容 MD5 去重=同一 key）
attachmentsRouter.post('/', async (c) => {
  const entity = c.req.query('entity');
  const id = c.req.query('id');
  if (!entity || !VALID_ENTITY.includes(entity)) return c.json({ error: 'entity 必须为 sale/purchase/payment 或明细行级 sale_item/purchase_item' }, 400);
  if (!id) return c.json({ error: '缺少 id' }, 400);
  let file: File | null = null;
  try {
    const form = await c.req.formData();
    const f = form.get('photo');
    if (f && typeof f === 'object') file = f as unknown as File;
  } catch {
    return c.json({ error: '请以 multipart 上传 photo 字段（图片）' }, 400);
  }
  if (!file) return c.json({ error: '请选择图片上传' }, 400);
  if (file.size === 0 || file.size > 10 * 1024 * 1024) return c.json({ error: '图片过大（上限 10MB）' }, 400);

  const bytes = new Uint8Array(await file.arrayBuffer());
  const key = imageKey('attachments', [entity, id], bytes);
  await createStorage(c.env).put(key, bytes, file.type || 'image/jpeg');
  // 附件引用表（引用驱动）：记录"哪个实体引用了哪个文件"。幂等：同 entity+entity_id+key 已存在则跳过，
  // 不同实体引用同一内容（同 md5 不同 key）各自一行——多单共用不互相影响
  await c.env.DB.prepare(
    'INSERT OR IGNORE INTO attachment_refs (id, entity, entity_id, file_key, md5) VALUES (?, ?, ?, ?, ?)',
  ).bind(`${entity}:${id}:${key}`, entity, id, key, key.split('/').pop()?.replace('.jpg', '') ?? '').run();
  // 附件增删实时同步：广播 {type:'sync'}，其他在线端收到后拉取并刷新附件计数/图标
  await notifyClients();
  return c.json({ key }, 201);
});

// POST /attachments/counts — 统计一批单据/明细行的附件数（同步面板「当前店铺附件差异」用）。
// body: { entity, ids?: string[] } 或 { entity, client_id }（按店铺直接汇总，返回该店全部单据/明细行 id 便于前端对账本地副本）
attachmentsRouter.post('/counts', async (c) => {
  const body = await c.req.json().catch(() => null) as { entity?: string; ids?: string[]; client_id?: string } | null;
  const entity = body?.entity;
  if (!entity || !VALID_ENTITY.includes(entity)) return c.json({ error: 'entity 必须为 sale/purchase/payment 或明细行级 sale_item/purchase_item' }, 400);
  const store = createStorage(c.env);
  let ids: string[] = [];
  const clientId = body?.client_id?.trim();
  if (clientId && ORDER_ENTITY.includes(entity)) {
    const rows = await c.env.DB.prepare(`SELECT id FROM ${entity}s WHERE client_id = ?`).bind(clientId).all<{ id: string }>();
    ids = rows.results.map((r) => r.id);
  } else if (clientId && entity === 'sale_item') {
    // 行级附件按店铺聚合：JOIN sales 取该店全部出货单的明细行 id
    const rows = await c.env.DB.prepare(
      `SELECT si.id FROM sale_items si JOIN sales s ON s.id = si.sale_id WHERE s.client_id = ?`,
    ).bind(clientId).all<{ id: string }>();
    ids = rows.results.map((r) => r.id);
  } else {
    ids = (body?.ids ?? []).filter((x) => x.trim().length > 0).slice(0, 500);
  }
  if (ids.length === 0) return c.json({ counts: {}, total: 0, ids: [] });
  const counts: Record<string, number> = {};
  await Promise.all(ids.map(async (id) => {
    const prefixes = [prefixOf(entity, id), ...legacyPrefixesOf(entity, id)];
    const groups = await Promise.all(prefixes.map((p) => store.list(p)));
    const byKey = new Map<string, unknown>();
    for (const group of groups) for (const o of group.objects) byKey.set(o.key, o);
    counts[id] = byKey.size;
  }));
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  return c.json({ counts, total, ids });
});

// GET /attachments/total — 全部附件总数（同步面板「全部数据」附件差异行；含新旧前缀，分页统计）
attachmentsRouter.get('/total', async (c) => {
  const store = createStorage(c.env);
  // 规范前缀 + 历史前缀家族（taozhu/attachments/ 与根级 sale|purchase|payment/），互不重叠
  const prefixes = [
    'taozhu/images/attachments/',
    'taozhu/attachments/',
    'sale/',
    'purchase/',
    'payment/',
  ];
  let total = 0;
  await Promise.all(prefixes.map(async (p) => {
    let cursor: string | undefined;
    do {
      const r = await store.list(p, cursor);
      total += r.objects.length;
      cursor = r.truncated ? r.cursor : undefined;
    } while (cursor);
  }));
  return c.json({ total });
});

// GET /attachments/in-use — 列出云端"在用"附件（与 orphans 对称）：
// ① attachment_refs 引用表（引用表权威：上传即写引用行，实体删除即级联清引用，有引用行=在用）
// ② 兼容历史：R2 中尚未写引用行但仍有对应单据的 key（v0.17.84 之前上传的存量附件）
// 返回规范化三元组 {key, entity, id, file} —— 前端同步下载/清理页在用判定直接用三元组，
// 不再各自用正则解析 key（此前前后端正则不一致：历史根级前缀 sale/s1/a.jpg 前端匹配失败，
// 导致在用附件被清理页误列为孤儿、同步也不下载）。
attachmentsRouter.get('/in-use', async (c) => {
  const store = createStorage(c.env);
  const db = c.env.DB;
  const out: Array<{ key: string; entity: string; id: string; file: string; size: number }> = [];
  const seen = new Set<string>();
  // ① 引用表（权威）：entity/id/file 直接从表取，不做任何正则
  const refRows = await db.prepare('SELECT file_key, entity, entity_id FROM attachment_refs').all<{
    file_key: string; entity: string; entity_id: string;
  }>();
  for (const r of refRows.results) {
    const file = r.file_key.split('/').pop() ?? '';
    if (!file) continue;
    seen.add(r.file_key);
    out.push({ key: r.file_key, entity: r.entity, id: r.entity_id, file, size: 0 });
  }
  // ② 历史兜底：R2 所有附件 key 对照 D1 在用单据 id，未写入引用表的视为在用（仅一次性补列，不写表）
  const inUse = new Map<string, Set<string>>();
  const add = (entity: string, id: string) => {
    if (!id) return;
    let s = inUse.get(entity);
    if (!s) { s = new Set(); inUse.set(entity, s); }
    s.add(id);
  };
  const [sales, saleItems, purchases, purchaseItems, payments] = await Promise.all([
    db.prepare('SELECT id FROM sales').all<{ id: string }>(),
    db.prepare('SELECT id FROM sale_items').all<{ id: string }>(),
    db.prepare('SELECT id FROM purchases').all<{ id: string }>(),
    db.prepare('SELECT id FROM purchase_items').all<{ id: string }>(),
    db.prepare('SELECT id FROM payments').all<{ id: string }>(),
  ]);
  sales.results.forEach((r) => add('sale', r.id));
  saleItems.results.forEach((r) => add('sale_item', r.id));
  purchases.results.forEach((r) => add('purchase', r.id));
  purchaseItems.results.forEach((r) => add('purchase_item', r.id));
  payments.results.forEach((r) => add('payment', r.id));
  for (const prefix of ['taozhu/images/attachments/', 'taozhu/attachments/', '']) {
    let cursor: string | undefined;
    do {
      const r = await store.list(prefix, cursor);
      for (const o of r.objects) {
        if (seen.has(o.key)) continue; // 引用表已列
        const parsed = parseAttachmentKey(o.key);
        if (!parsed) continue;
        if ((inUse.get(parsed.entity) ?? new Set()).has(parsed.id)) {
          seen.add(o.key);
          out.push({
            key: o.key,
            entity: parsed.entity,
            id: parsed.id,
            file: o.key.split('/').pop() ?? '',
            size: o.size,
          });
        }
      }
      cursor = r.truncated ? r.cursor : undefined;
    } while (cursor);
  }
  return c.json({
    attachments: out,
    total: out.length,
  });
});

// GET /attachments/orphans — 扫描云端孤儿附件（参考原版实现 B1/B3）：
// R2 中所有附件 key 对照 D1 在用的单据/明细行 id —— 无对应单据的 = 孤儿（单据已删但 R2 残留）。
// 返回孤儿列表（key/entity/id/size），供清理页展示与删除；只读扫描不改数据。
attachmentsRouter.get('/orphans', async (c) => {
  const store = createStorage(c.env);
  const db = c.env.DB;
  // D1 在用附件单元 id 集合（entity → id set）
  const inUse = new Map<string, Set<string>>();
  const add = (entity: string, id: string) => {
    if (!id) return;
    let s = inUse.get(entity);
    if (!s) { s = new Set(); inUse.set(entity, s); }
    s.add(id);
  };
  const [sales, saleItems, purchases, purchaseItems, payments] = await Promise.all([
    db.prepare('SELECT id FROM sales').all<{ id: string }>(),
    db.prepare('SELECT id FROM sale_items').all<{ id: string }>(),
    db.prepare('SELECT id FROM purchases').all<{ id: string }>(),
    db.prepare('SELECT id FROM purchase_items').all<{ id: string }>(),
    db.prepare('SELECT id FROM payments').all<{ id: string }>(),
  ]);
  sales.results.forEach((r) => add('sale', r.id));
  saleItems.results.forEach((r) => add('sale_item', r.id));
  purchases.results.forEach((r) => add('purchase', r.id));
  purchaseItems.results.forEach((r) => add('purchase_item', r.id));
  payments.results.forEach((r) => add('payment', r.id));
  const orphans: Array<{ key: string; entity: string; id: string; size: number }> = [];
  for (const prefix of ['taozhu/images/attachments/', 'taozhu/attachments/', '']) {
    let cursor: string | undefined;
    do {
      const r = await store.list(prefix, cursor);
      for (const o of r.objects) {
        const parsed = parseAttachmentKey(o.key);
        if (!parsed) continue;
        if (!(inUse.get(parsed.entity) ?? new Set()).has(parsed.id)) {
          orphans.push({ key: o.key, entity: parsed.entity, id: parsed.id, size: o.size });
        }
      }
      cursor = r.truncated ? r.cursor : undefined;
    } while (cursor);
  }
  return c.json({
    orphans,
    total: orphans.length,
    bytes: orphans.reduce((s, o) => s + o.size, 0),
  });
});

// DELETE /attachments/orphans — 批量删除云端孤儿附件（body: { keys: string[] }）
// 参考原版 cleaner：删无引用的附件文件（孤儿）。best-effort 逐个删。
attachmentsRouter.delete('/orphans', adminOnly(), async (c) => {
  const body = await c.req.json().catch(() => null) as { keys?: string[] } | null;
  const keys = (body?.keys ?? []).filter((k) => typeof k === 'string' && k);
  if (keys.length === 0) return c.json({ error: '请提供要删除的附件 key 列表' }, 400);
  // 安全校验：只允许删除孤儿（再扫一遍确认键确属孤儿，防误删在用凭证）
  const store = createStorage(c.env);
  const db = c.env.DB;
  const inUse = new Map<string, Set<string>>();
  const add = (entity: string, id: string) => {
    if (!id) return;
    let s = inUse.get(entity);
    if (!s) { s = new Set(); inUse.set(entity, s); }
    s.add(id);
  };
  const [sales, saleItems, purchases, purchaseItems, payments] = await Promise.all([
    db.prepare('SELECT id FROM sales').all<{ id: string }>(),
    db.prepare('SELECT id FROM sale_items').all<{ id: string }>(),
    db.prepare('SELECT id FROM purchases').all<{ id: string }>(),
    db.prepare('SELECT id FROM purchase_items').all<{ id: string }>(),
    db.prepare('SELECT id FROM payments').all<{ id: string }>(),
  ]);
  sales.results.forEach((r) => add('sale', r.id));
  saleItems.results.forEach((r) => add('sale_item', r.id));
  purchases.results.forEach((r) => add('purchase', r.id));
  purchaseItems.results.forEach((r) => add('purchase_item', r.id));
  payments.results.forEach((r) => add('payment', r.id));
  let deleted = 0;
  for (const key of keys) {
    const parsed = parseAttachmentKey(key);
    if (!parsed) continue;
    if ((inUse.get(parsed.entity) ?? new Set()).has(parsed.id)) continue; // 在用防误删
    try {
      await store.delete(key);
      // 引用行同步清理（孤儿本来就不应存在引用；防御性删除防脏引用残留）
      await db.prepare('DELETE FROM attachment_refs WHERE file_key = ?').bind(key).run();
      deleted++;
    } catch (_) {}
  }
  if (deleted > 0) await notifyClients();
  return c.json({ deleted });
});

// GET /attachments/:key{.+} — 代理读取图片内容（key 含斜杠如 sale/s1/123.jpg，{.+} 捕获多段）
attachmentsRouter.get('/:key{.+}', async (c) => {
  const key = c.req.param('key');
  const obj = await createStorage(c.env).get(key);
  if (!obj) return c.json({ error: '附件不存在' }, 404);
  const headers = new Headers();
  if (obj.contentType) headers.set('content-type', obj.contentType);
  return new Response(obj.body, { headers });
});

// DELETE /attachments?key= — 删除附件（Web/直连路径：删该实体的引用行；共用文件被其他实体引用则保留 R2）
attachmentsRouter.delete('/', async (c) => {
  const key = c.req.query('key');
  if (!key) return c.json({ error: 'key 必填' }, 400);
  const store = createStorage(c.env);
  const db = c.env.DB;
  // 实体级引用删除：只删该 key 对应实体的引用行（共用图不误删其他实体引用）
  const parsed = parseAttachmentKey(key);
  if (parsed) {
    await db.prepare(
      'DELETE FROM attachment_refs WHERE file_key = ? AND entity = ? AND entity_id = ?',
    ).bind(key, parsed.entity, parsed.id).run();
  } else {
    try { await db.prepare('DELETE FROM attachment_refs WHERE file_key = ?').bind(key).run(); } catch (_) {}
  }
  // 该文件仍被其他实体引用（共用图）→ 保留 R2；零引用才物理删
  const cnt = await db.prepare('SELECT COUNT(*) AS n FROM attachment_refs WHERE file_key = ?').bind(key).first<{ n: number }>();
  if ((cnt?.n ?? 0) === 0) {
    await store.delete(key);
  }
  await notifyClients();
  return c.body(null, 204);
});