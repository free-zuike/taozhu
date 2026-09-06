/** vegbook 入口：静态托管 + /api/v1 路由 */
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
import { ensureSchema } from './schema';

type AppEnv = { Bindings: Env; Variables: { user: import('./types').AuthUser } };

const app = new Hono<AppEnv>();

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

// 静态资源回退：非 API 路径交给 ASSETS（前端 SPA）
app.all('*', async (c) => {
  if (c.req.path.startsWith('/api/')) {
    return c.json({ error: '接口不存在' }, 404);
  }
  return c.env.ASSETS.fetch(c.req.raw);
});

export default app;