/** 交易附件（凭证图片）：公共图片存储（taozhu/images/attachments/...，MD5 内容去重）。
 *  entity ∈ sale|purchase|payment（出货/进货/收款）；零 D1 写。 */
import { Hono } from 'hono';
import { authMiddleware } from '../middleware/auth';
import { createStorage } from '../services/storage';
import { imageKey, LEGACY_IMAGE_PREFIXES } from '../lib/image-key';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const attachmentsRouter = new Hono<{ Bindings: Env; Variables: V }>();
attachmentsRouter.use('*', authMiddleware());

const VALID_ENTITY = ['sale', 'purchase', 'payment'];

/** 当前规范前缀：taozhu/images/attachments/{entity}/{id}/ */
const prefixOf = (entity: string, id: string) => `taozhu/images/attachments/${entity}/${id}/`;
/** 兼容前缀列表（历史规范）：{前缀}{entity}/{id}/ */
const legacyPrefixesOf = (entity: string, id: string) =>
  LEGACY_IMAGE_PREFIXES.map((p) => `${p}${entity}/${id}/`);

// GET /attachments?entity=&id= — 列出某交易的全部附件（兼容历史前缀，按 key 去重排序）
attachmentsRouter.get('/', async (c) => {
  const entity = c.req.query('entity');
  const id = c.req.query('id');
  if (!entity || !VALID_ENTITY.includes(entity)) return c.json({ error: 'entity 必须为 sale/purchase/payment' }, 400);
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
  if (!entity || !VALID_ENTITY.includes(entity)) return c.json({ error: 'entity 必须为 sale/purchase/payment' }, 400);
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
  return c.json({ key }, 201);
});

// POST /attachments/counts — 统计一批单据的附件数（同步面板「当前店铺附件差异」用）。
// body: { entity, ids?: string[] } 或 { entity, client_id }（按店铺直接汇总，返回该店全部单据 id 便于前端对账本地副本）
attachmentsRouter.post('/counts', async (c) => {
  const body = await c.req.json().catch(() => null) as { entity?: string; ids?: string[]; client_id?: string } | null;
  const entity = body?.entity;
  if (!entity || !VALID_ENTITY.includes(entity)) return c.json({ error: 'entity 必须为 sale/purchase/payment' }, 400);
  const store = createStorage(c.env);
  let ids: string[] = [];
  const clientId = body?.client_id?.trim();
  if (clientId) {
    const rows = await c.env.DB.prepare(`SELECT id FROM ${entity}s WHERE client_id = ?`).bind(clientId).all<{ id: string }>();
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

// GET /attachments/:key{.+} — 代理读取图片内容（key 含斜杠如 sale/s1/123.jpg，{.+} 捕获多段）
attachmentsRouter.get('/:key{.+}', async (c) => {
  const key = c.req.param('key');
  const obj = await createStorage(c.env).get(key);
  if (!obj) return c.json({ error: '附件不存在' }, 404);
  const headers = new Headers();
  if (obj.contentType) headers.set('content-type', obj.contentType);
  return new Response(obj.body, { headers });
});

// DELETE /attachments?key= — 删除附件
attachmentsRouter.delete('/', async (c) => {
  const key = c.req.query('key');
  if (!key) return c.json({ error: 'key 必填' }, 400);
  await createStorage(c.env).delete(key);
  return c.body(null, 204);
});