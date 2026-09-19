/** 操作审计：关键写操作留痕（谁在什么时候对哪个实体做了什么）。
 *  记录点：登录/登出、删除交易/进货/收款、修改价格/店铺、导入导出备份、用户管理、设置变更。
 *  仅追加不删除（保留最近 500 条，超出清理最旧，防无限增长）。 */
import { Hono } from 'hono';
import { adminOnly, authMiddleware } from '../middleware/auth';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const auditRouter = new Hono<{ Bindings: Env; Variables: V }>();
auditRouter.use('*', authMiddleware(), adminOnly());

const MAX_KEEP = 500;

/// 动作中文标签（前端显示用；action 值保持英文稳定——后续多语言按 Accept-Language 返回对应语言，不改存储）
const ACTION_LABEL: Record<string, string> = {
  login: '登录', create: '新增', update: '修改', delete: '删除',
  export: '导出', import: '导入', rebuild: '重算',
};
/// 实体中文标签
const ENTITY_LABEL: Record<string, string> = {
  sale: '出货', purchase: '进货', sale_item: '出货商品', purchase_item: '进货商品',
  payment: '收款', backup: '备份', stocks: '库存', category: '分类',
  client: '店铺', item: '商品', payment_account: '收款方式', profile: '资料',
};

export interface AuditEntry {
  username: string;
  action: string;
  entity_type?: string;
  entity_id?: string;
  detail?: string;
}

/** 记录一条审计（best-effort：失败不阻断业务操作） */
export async function recordAudit(db: D1Database, e: AuditEntry): Promise<void> {
  try {
    await db.prepare(
      'INSERT INTO audit_logs (username, action, entity_type, entity_id, detail) VALUES (?, ?, ?, ?, ?)',
    ).bind(e.username, e.action, e.entity_type ?? null, e.entity_id ?? null, e.detail ?? null).run();
    // 超出上限清理最旧（低频操作，逐条删除可接受）
    await db.prepare(
      'DELETE FROM audit_logs WHERE id NOT IN (SELECT id FROM audit_logs ORDER BY id DESC LIMIT ?)',
    ).bind(MAX_KEEP).run();
  } catch (_) {
    // 审计失败不阻断业务
  }
}

// GET /audit?limit=&entity_type=&action= — 审计日志列表（仅老板，倒序）
auditRouter.get('/', async (c) => {
  const limit = Math.min(Math.max(Number(c.req.query('limit')) || 50, 1), 500);
  const entityType = c.req.query('entity_type')?.trim();
  const action = c.req.query('action')?.trim();
  let where = ' WHERE 1=1';
  const params: string[] = [];
  if (entityType) { where += ' AND entity_type = ?'; params.push(entityType); }
  if (action) { where += ' AND action = ?'; params.push(action); }
  const rows = await c.env.DB.prepare(
    `SELECT id, username, action, entity_type, entity_id, detail, created_at
     FROM audit_logs ${where} ORDER BY id DESC LIMIT ?`,
  ).bind(...params, limit).all();
  return c.json({
    logs: rows.results.map((r) => ({
      ...r,
      action_label: ACTION_LABEL[String(r.action)] ?? String(r.action ?? ''),
      entity_label: r.entity_type ? (ENTITY_LABEL[String(r.entity_type)] ?? String(r.entity_type)) : '',
    })),
  });
});