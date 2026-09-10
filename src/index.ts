/** taozhu 入口：静态托管 + /api/v1 路由 */
import { Hono } from 'hono';
import type { Env } from './types';
import { authRouter } from './routes/auth';
import { clientsRouter } from './routes/clients';
import { itemsRouter } from './routes/items';
import { paymentsRouter } from './routes/payments';
import { purchasesRouter } from './routes/purchases';
import { salesRouter } from './routes/sales';
import { statsRouter } from './routes/stats';
import { usersRouter } from './routes/users';
import { categoriesRouter } from './routes/categories';
import { aiRouter } from './routes/ai';
import { settingsRouter } from './routes/settings';
import { attachmentsRouter } from './routes/attachments';
import { stocksRouter } from './routes/stocks';
import { backupRouter } from './routes/backup';
import { shareRouter, renderShareHtml } from './routes/share';
import { ensureSchema } from './schema';

type AppEnv = { Bindings: Env; Variables: { user: import('./types').AuthUser } };

const app = new Hono<AppEnv>();

// CORS：允许跨域（Android App / 自托管端访问后端）
app.use('*', async (c, next) => {
  c.header('Access-Control-Allow-Origin', '*');
  c.header('Access-Control-Allow-Methods', 'GET, POST, PATCH, PUT, DELETE, OPTIONS');
  c.header('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (c.req.method === 'OPTIONS') return c.body(null, 204);
  await next();
});

app.get('/healthz', (c) => c.json({ ok: true }));

// 首次 API 请求触发幂等建表（不鉴权）
app.use('/api/v1/*', async (c, next) => {
  await ensureSchema(c.env.DB);
  await next();
});

app.route('/api/v1/auth', authRouter);
app.route('/api/v1/clients', clientsRouter);
app.route('/api/v1/items', itemsRouter);
app.route('/api/v1/sales', salesRouter);
app.route('/api/v1/purchases', purchasesRouter);
app.route('/api/v1/payments', paymentsRouter);
app.route('/api/v1/stats', statsRouter);
app.route('/api/v1/users', usersRouter);
app.route('/api/v1/categories', categoriesRouter);
app.route('/api/v1/ai', aiRouter);
app.route('/api/v1/settings', settingsRouter);
app.route('/api/v1/attachments', attachmentsRouter);
app.route('/api/v1/stocks', stocksRouter);
app.route('/api/v1/backup', backupRouter);
app.route('/api/v1/share', shareRouter);

// 对账单分享页（公开只读：token 随机且可选过期，数据为生成时快照）
app.get('/share/:token', async (c) => {
  const token = c.req.param('token');
  const row = await c.env.DB.prepare(
    'SELECT payload, expires_at FROM share_links WHERE token = ?',
  ).bind(token).first<{ payload: string; expires_at: string | null }>();
  if (!row) {
    return c.html('<meta charset="utf-8"><div style="font-family:sans-serif;padding:40px;text-align:center;color:#909399">分享不存在或已被删除</div>', 404);
  }
  if (row.expires_at && row.expires_at < new Date().toISOString()) {
    return c.html('<meta charset="utf-8"><div style="font-family:sans-serif;padding:40px;text-align:center;color:#909399">该分享已过期</div>', 410);
  }
  return c.html(renderShareHtml(row.payload));
});

// 静态资源回退：非 API 路径交给 ASSETS（前端 SPA）
app.all('*', async (c) => {
  if (c.req.path.startsWith('/api/')) {
    return c.json({ error: '接口不存在' }, 404);
  }
  return c.env.ASSETS.fetch(c.req.raw);
});

export default app;