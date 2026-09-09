/** 交易附件（凭证图片）：R2 存储，key = {entity}/{id}/{时间戳}.jpg
 *  实体 entity ∈ sale|purchase|payment，按前缀关联交易；零 D1 写（R2 配额独立）。 */
import { Hono } from 'hono';
import { authMiddleware } from '../middleware/auth';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const attachmentsRouter = new Hono<{ Bindings: Env; Variables: V }>();
attachmentsRouter.use('*', authMiddleware());

const VALID_ENTITY = ['sale', 'purchase', 'payment'];

// GET /attachments?entity=&id= — 列出某交易的全部附件
attachmentsRouter.get('/', async (c) => {
  const entity = c.req.query('entity');
  const id = c.req.query('id');
  if (!entity || !VALID_ENTITY.includes(entity)) return c.json({ error: 'entity 必须为 sale/purchase/payment' }, 400);
  if (!id) return c.json({ error: '缺少 id' }, 400);
  const list = await c.env.BUCKET.list({ prefix: `${entity}/${id}/` });
  return c.json({
    attachments: list.objects.map((o) => ({ key: o.key, size: o.size, uploaded: o.uploaded?.toISOString() ?? '' })),
  });
});

// POST /attachments?entity=&id= — multipart 上传 photo（上限 10MB）
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

  const key = `${entity}/${id}/${Date.now()}.jpg`;
  await c.env.BUCKET.put(key, file.stream(), {
    httpMetadata: { contentType: file.type || 'image/jpeg' },
  });
  return c.json({ key }, 201);
});

// GET /attachments/:key{.+} — 代理读取图片内容（key 含斜杠如 sale/s1/123.jpg，{.+} 捕获多段）
attachmentsRouter.get('/:key{.+}', async (c) => {
  const key = c.req.param('key');
  const obj = await c.env.BUCKET.get(key);
  if (!obj) return c.json({ error: '附件不存在' }, 404);
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set('etag', obj.httpEtag);
  return new Response(obj.body, { headers });
});

// DELETE /attachments?key= — 删除附件
attachmentsRouter.delete('/', async (c) => {
  const key = c.req.query('key');
  if (!key) return c.json({ error: 'key 必填' }, 400);
  await c.env.BUCKET.delete(key);
  return c.body(null, 204);
});