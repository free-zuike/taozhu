/** AI 识别路由：POST /api/v1/ai/parse-photo（multipart 图片 → 商品草稿） */
import { Hono } from 'hono';
import { authMiddleware } from '../middleware/auth';
import { parsePhoto } from '../services/ai-parse';
import { getZhipuKey } from './settings';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const aiRouter = new Hono<{ Bindings: Env; Variables: V }>();

aiRouter.use('*', authMiddleware());

// POST /api/v1/ai/parse-photo?purpose=purchase|sale  — multipart 字段 photo
aiRouter.post('/parse-photo', async (c) => {
  const purpose = c.req.query('purpose') === 'sale' ? 'sale' : 'purchase';
  const key = await getZhipuKey(c.env.DB, c.env.ZHIPU_API_KEY);
  if (!key) {
    return c.json({ error: 'AI 拍照识别未启用：请老板在「系统设置」中填写 AI Key（智谱免费模型）' }, 400);
  }
  let file: File | null = null;
  try {
    const form = await c.req.formData();
    const f = form.get('photo');
    // 后端无 DOM lib：用 typeof 区分 File（object）与 string
    if (f && typeof f === 'object') file = f as unknown as File;
  } catch {
    return c.json({ error: '请以 multipart 方式上传 photo 字段（图片）' }, 400);
  }
  if (!file) return c.json({ error: '请选择图片上传' }, 400);
  if (file.size === 0) return c.json({ error: '图片为空' }, 400);
  // 限制 10MB
  if (file.size > 10 * 1024 * 1024) return c.json({ error: '图片过大（上限 10MB）' }, 400);

  const bytes = new Uint8Array(await file.arrayBuffer());
  try {
    const drafts = await parsePhoto(key, file.type, bytes, purpose);
    return c.json({ ok: true, purpose, items: drafts });
  } catch (err) {
    const msg = err instanceof Error ? err.message : '识别失败';
    return c.json({ error: msg }, 502);
  }
});