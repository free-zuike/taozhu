/** 收款账户（收款方式预设）：现金/微信/支付宝/银行卡/转账 等。
 *  纯同步实体（与 clients/items 同级）：GET 读全部、PUT 全量覆盖（增删改由前端整表提交）。
 *  数据以服务端为准，App 本地库镜像 + 增量同步；Web/小程序云端直连。 */
import { Hono } from 'hono';
import { authMiddleware, adminOnly } from '../middleware/auth';
import { recordChange } from '../lib/sync';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const paymentAccountsRouter = new Hono<{ Bindings: Env; Variables: V }>();
paymentAccountsRouter.use('*', authMiddleware());

// GET /payment-accounts — 全部账户（按 sort 排序）
paymentAccountsRouter.get('/', async (c) => {
  const rows = await c.env.DB.prepare(
    'SELECT id, name, bank_name, card_last_four, sort FROM payment_accounts ORDER BY sort, name',
  ).all<{ id: string; name: string; bank_name: string; card_last_four: string; sort: number }>();
  return c.json({ accounts: rows.results });
});

// GET /payment-accounts/stats — 每账户进账统计（按 method 聚合全部历史收款；无支出口径，账户仅收款用）
// total=累计进账（含平账减免）、count=累计笔数、month_total/month_count=本月进账/笔数（happened_at 前缀当月）
paymentAccountsRouter.get('/stats', async (c) => {
  const now = new Date();
  const ym = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
  const rows = await c.env.DB.prepare(
    `SELECT method, COUNT(*) AS cnt, SUM(amount + waived) AS total,
       SUM(CASE WHEN substr(happened_at,1,7) = ? THEN amount + waived ELSE 0 END) AS month_total,
       SUM(CASE WHEN substr(happened_at,1,7) = ? THEN 1 ELSE 0 END) AS month_count
     FROM payments WHERE method IS NOT NULL AND method != ''
     GROUP BY method ORDER BY total DESC`,
  ).bind(ym, ym).all<{ method: string; cnt: number; total: number; month_total: number; month_count: number }>();
  return c.json({
    stats: rows.results.map((r) => ({
      method: r.method,
      count: r.cnt,
      total: Math.round(Number(r.total || 0) * 100) / 100,
      month_total: Math.round(Number(r.month_total || 0) * 100) / 100,
      month_count: r.month_count || 0,
    })),
  });
});

// PUT /payment-accounts — 全量覆盖账户列表（body: { accounts: [{name, bank_name?, card_last_four?}] }，admin）
// 词义：改名 = 旧账户删除 + 新账户新增（历史收款的 method 是文本快照，无引用问题）；
// 同名（未改名）账户复用 id，同时更新开户行/卡号后四位。
// 每处变更入同步流（LWW 决胜），pull 端按 upsert/delete 合并本地镜像。
paymentAccountsRouter.put('/', adminOnly(), async (c) => {
  const body = await c.req.json().catch(() => null) as { accounts?: Array<{ name?: string; bank_name?: string; card_last_four?: string }> } | null;
  const items = (body?.accounts ?? [])
    .map((a) => ({
      name: a.name?.trim() ?? '',
      bankName: (a.bank_name ?? '').trim().slice(0, 50),
      cardLastFour: (a.card_last_four ?? '').trim().slice(0, 4),
    }))
    .filter((x) => x.name.length > 0);
  if (items.length === 0) return c.json({ error: '至少保留一个账户' }, 400);
  const existing = await c.env.DB.prepare('SELECT id, name, bank_name, card_last_four FROM payment_accounts ORDER BY sort, name')
    .all<{ id: string; name: string; bank_name: string; card_last_four: string }>();
  const batch: D1PreparedStatement[] = [];
  const upserts: Array<{ id: string; name: string; bankName: string; cardLastFour: string; sort: number }> = [];
  const deletes: string[] = [];
  const finalNames = new Set(items.map((x) => x.name));

  // 保留且名字未变的账户：复用 id（重排 sort + 更新开户行/卡号）
  const nameToId = new Map(existing.results.map((r) => [r.name, r.id]));
  items.forEach((x, idx) => {
    const existed = nameToId.get(x.name);
    if (existed) {
      batch.push(
        c.env.DB.prepare('UPDATE payment_accounts SET sort = ?, bank_name = ?, card_last_four = ? WHERE id = ?')
          .bind(idx, x.bankName, x.cardLastFour, existed),
      );
      upserts.push({ id: existed, name: x.name, bankName: x.bankName, cardLastFour: x.cardLastFour, sort: idx });
    } else {
      const id = `acct_${Date.now()}_${idx}`;
      batch.push(
        c.env.DB.prepare('INSERT INTO payment_accounts (id, name, bank_name, card_last_four, sort) VALUES (?, ?, ?, ?, ?)')
          .bind(id, x.name, x.bankName, x.cardLastFour, idx),
      );
      upserts.push({ id, name: x.name, bankName: x.bankName, cardLastFour: x.cardLastFour, sort: idx });
    }
  });
  // 不在最终列表中的旧账户：删除
  for (const r of existing.results) {
    if (!finalNames.has(r.name)) {
      batch.push(c.env.DB.prepare('DELETE FROM payment_accounts WHERE id = ?').bind(r.id));
      deletes.push(r.id);
    }
  }
  await c.env.DB.batch(batch);
  // 入同步流：upsert 从服务端当前快照重新构建（确保变更字段最新）
  for (const u of upserts) {
    const payload = { id: u.id, name: u.name, bank_name: u.bankName, card_last_four: u.cardLastFour, sort: u.sort };
    // 名字未变的变更（仅改卡号/重排）也推快照，幂等合并
    await recordChange(c.env.DB, { entity_type: 'payment_account', entity_sync_id: u.id, payload, updated_by_username: c.get('user').username });
  }
  for (const id of deletes) {
    await recordChange(c.env.DB, { entity_type: 'payment_account', entity_sync_id: id, action: 'delete', payload: {}, updated_by_username: c.get('user').username });
  }
  const rows = await c.env.DB.prepare('SELECT id, name, bank_name, card_last_four, sort FROM payment_accounts ORDER BY sort, name')
    .all<{ id: string; name: string; bank_name: string; card_last_four: string; sort: number }>();
  return c.json({ accounts: rows.results });
});