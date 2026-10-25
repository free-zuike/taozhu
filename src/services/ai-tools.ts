/** AI 助手工具注册表 + 权限策略 + 运行审计（v0.17.478，对齐参考 App Agent 体系：
 *  工具目录（写操作需授权）+ 权限三档（ask/allow/deny）+ 活动页运行记录）。
 *  协议层仍为意图提取（原生 OpenAI tools 留后续重构），工具注册表承载权限与审计。 */
import { randomId } from '../lib/password';
import type { D1Database } from '@cloudflare/workers-types';

export type ToolPermission = 'read' | 'write';
export type ToolPolicy = 'ask' | 'allow' | 'deny';

export interface AiToolDef {
  name: string;
  label: string;
  description: string;
  permission: ToolPermission;
  /** 缺省策略：读工具=allow（无需询问）；写工具=ask（执行前询问） */
  defaultPolicy: ToolPolicy;
}

/** 对齐参考 App 工具集（查询/记忆/一句话落单）；当前执行器复用意图提取的分支 */
export const AI_TOOLS: AiToolDef[] = [
  {
    name: 'query_business_data',
    label: '查经营数据',
    description: '查询区间汇总、按店出货、欠款、商品排行等历史经营数据',
    permission: 'read',
    defaultPolicy: 'allow',
  },
  {
    name: 'get_business_snapshot',
    label: '看今日概况',
    description: '获取今日/本月业务快照与低库存、临期预警',
    permission: 'read',
    defaultPolicy: 'allow',
  },
  {
    name: 'pick_kb_entry',
    label: '查使用说明',
    description: '回答"功能怎么用"（内置操作说明知识库）',
    permission: 'read',
    defaultPolicy: 'allow',
  },
  {
    name: 'record_transaction',
    label: '一句话记账',
    description: '把一句话或一张单据记成进货/出货单（会修改账本数据）',
    permission: 'write',
    defaultPolicy: 'ask',
  },
  {
    name: 'save_memory',
    label: '记住事项',
    description: '把用户让记住的事项写入助手记忆（会修改记忆）',
    permission: 'write',
    defaultPolicy: 'ask',
  },
  {
    name: 'forget_memory',
    label: '遗忘记忆',
    description: '按内容遗忘一条助手记忆（会修改记忆）',
    permission: 'write',
    defaultPolicy: 'ask',
  },
];

export function toolDef(name: string): AiToolDef | undefined {
  return AI_TOOLS.find((t) => t.name === name);
}

export interface ToolPolicyRow {
  tool_name: string;
  policy: ToolPolicy;
}

/** 某用户某工具的生效策略（有自定义行用行值，否则缺省） */
export async function toolPolicyFor(
  db: D1Database,
  userId: string,
  toolName: string,
): Promise<ToolPolicy> {
  const def = toolDef(toolName);
  if (!def) return 'deny';
  const row = await db.prepare(
    'SELECT policy FROM ai_tool_permissions WHERE user_id = ? AND tool_name = ? LIMIT 1',
  ).bind(userId, toolName).first<{ policy: string }>();
  return (row?.policy as ToolPolicy) || def.defaultPolicy;
}

/** 授权门：读工具恒放行；写工具按策略 → 'ask' 需用户确认 */
export async function gateFor(
  db: D1Database,
  userId: string,
  toolName: string,
): Promise<'allow' | 'deny' | 'ask'> {
  const def = toolDef(toolName);
  if (!def) return 'deny';
  if (def.permission === 'read') return 'allow';
  return toolPolicyFor(db, userId, toolName);
}

/** 用户全部工具策略（权限页用；is_default=是否缺省） */
export async function listToolPolicies(
  db: D1Database,
  userId: string,
): Promise<Array<{ tool_name: string; policy: ToolPolicy; is_default: boolean }>> {
  const rows = await db.prepare(
    'SELECT tool_name, policy FROM ai_tool_permissions WHERE user_id = ?',
  ).bind(userId).all<{ tool_name: string; policy: string }>();
  const custom = new Map(rows.results.map((r) => [r.tool_name, r.policy as ToolPolicy]));
  return AI_TOOLS.map((t) => ({
    tool_name: t.name,
    policy: custom.get(t.name) ?? t.defaultPolicy,
    is_default: !custom.has(t.name),
  }));
}

export async function setToolPolicy(
  db: D1Database,
  userId: string,
  toolName: string,
  policy: ToolPolicy,
): Promise<void> {
  const def = toolDef(toolName);
  if (!def) throw new Error(`未知工具: ${toolName}`);
  if (!['ask', 'allow', 'deny'].includes(policy)) throw new Error('非法策略');
  await db.prepare(
    `INSERT INTO ai_tool_permissions (id, user_id, tool_name, policy, updated_at)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT (user_id, tool_name) DO UPDATE SET policy = excluded.policy, updated_at = excluded.updated_at`,
  ).bind(randomId(), userId, toolName, policy, new Date().toISOString()).run();
}

export async function resetToolPolicies(db: D1Database, userId: string): Promise<void> {
  await db.prepare('DELETE FROM ai_tool_permissions WHERE user_id = ?').bind(userId).run();
}

// ---------------------------------------------------------------------------
// 运行审计（活动页：一次对话 = 一条 run + N 条工具调用）
// ---------------------------------------------------------------------------

export async function startAiRun(
  db: D1Database,
  userId: string,
  intent: string,
): Promise<string> {
  const id = randomId();
  await db.prepare(
    'INSERT INTO ai_runs (id, user_id, intent, status, started_at, finished_at, summary) VALUES (?, ?, ?, ?, ?, ?, ?)',
  ).bind(id, userId, intent, 'ok', new Date().toISOString(), new Date().toISOString(), '').run();
  return id;
}

export async function finishAiRun(
  db: D1Database,
  runId: string,
  status: 'ok' | 'error',
  summary: string,
): Promise<void> {
  await db.prepare(
    'UPDATE ai_runs SET status = ?, summary = ?, finished_at = ? WHERE id = ?',
  ).bind(status, summary.slice(0, 500), new Date().toISOString(), runId).run();
}

export async function recordToolCall(
  db: D1Database,
  input: {
    runId: string;
    userId: string;
    toolName: string;
    args: string;
    result: string;
    status?: 'ok' | 'error';
    durationMs?: number;
  },
): Promise<void> {
  await db.prepare(
    `INSERT INTO ai_tool_calls (id, run_id, user_id, tool_name, args, result, status, duration_ms, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(
    randomId(),
    input.runId,
    input.userId,
    input.toolName,
    input.args.slice(0, 2000),
    input.result.slice(0, 2000),
    input.status ?? 'ok',
    input.durationMs ?? 0,
    new Date().toISOString(),
  ).run();
}

export interface AiRunRow {
  id: string;
  intent: string;
  status: string;
  started_at: string;
  summary: string;
}

export interface AiToolCallRow {
  run_id: string;
  tool_name: string;
  args: string;
  result: string;
  status: string;
  duration_ms: number;
  created_at: string;
}

/** 最近运行（活动页）；每条含工具调用明细 */
export async function listAiRuns(
  db: D1Database,
  userId: string,
  limit = 30,
): Promise<Array<{ run: AiRunRow; tool_calls: AiToolCallRow[] }>> {
  const runs = await db.prepare(
    `SELECT id, intent, status, started_at, summary FROM ai_runs
     WHERE user_id = ? ORDER BY started_at DESC LIMIT ?`,
  ).bind(userId, limit).all<AiRunRow>();
  const calls = await db.prepare(
    `SELECT run_id, tool_name, args, result, status, duration_ms, created_at FROM ai_tool_calls
     WHERE user_id = ? ORDER BY created_at DESC LIMIT 200`,
  ).bind(userId).all<AiToolCallRow>();
  const byRun = new Map<string, AiToolCallRow[]>();
  for (const c of calls.results) {
    const list = byRun.get(c.run_id) ?? [];
    list.push(c);
    byRun.set(c.run_id, list);
  }
  return runs.results.map((r) => ({
    run: r,
    tool_calls: byRun.get(r.id) ?? [],
  }));
}

// ---------------------------------------------------------------------------
// 待授权动作（写工具执行前暂存，approval_id 一次性、5 分钟有效）
// ---------------------------------------------------------------------------

export async function createPendingAction(
  db: D1Database,
  userId: string,
  toolName: string,
  args: string,
  preview: string,
): Promise<string> {
  const id = randomId();
  const expires = new Date(Date.now() + 5 * 60 * 1000).toISOString();
  await db.prepare(
    'INSERT INTO ai_pending_actions (id, user_id, tool_name, args, preview, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
  ).bind(id, userId, toolName, args, preview.slice(0, 2000), new Date().toISOString(), expires).run();
  return id;
}

export async function takePendingAction(
  db: D1Database,
  userId: string,
  approvalId: string,
): Promise<{ tool_name: string; args: string; preview: string } | null> {
  const row = await db.prepare(
    'SELECT tool_name, args, preview, expires_at FROM ai_pending_actions WHERE id = ? AND user_id = ?',
  ).bind(approvalId, userId).first<{ tool_name: string; args: string; preview: string; expires_at: string }>();
  if (!row) return null;
  if (row.expires_at && row.expires_at < new Date().toISOString()) return null;
  await db.prepare('DELETE FROM ai_pending_actions WHERE id = ?').bind(approvalId).run();
  return { tool_name: row.tool_name, args: row.args, preview: row.preview };
}
