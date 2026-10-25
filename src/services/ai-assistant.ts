/** AI 助手（对话问数）：POST /api/v1/ai/chat 调文字模型回答业务问题。
 *  对齐参考项目形态：业务数据以「快照注入」方式塞进 system prompt（loadLedgerContext 模式，
 *  不用 function calling）——后端先算好今日/本月/欠款/库存等指标，模型只做自然语言翻译。
 *  多轮历史由客户端携带（messages），服务端无状态、不建对话表（对齐参考项目）。
 *  店员角色打码：不含毛利/欠款金额/进价成本（对齐统计权限：店员毛利归零）。 */
import {
  capabilityEndpoint, _postChatAdaptive, DEFAULT_TEXT_MODEL,
  type AiConfig,
} from './ai-parse';
import type { D1Database } from '@cloudflare/workers-types';

const money = (v: number): string => `¥${Math.round((Number(v) || 0) * 100) / 100}`;
const qty = (v: number): string => {
  const n = Math.round((Number(v) || 0) * 100) / 100;
  return String(n);
};

/** 经营数据快照文本（塞进 system prompt；店员打码敏感字段） */
export async function buildAssistantContext(db: D1Database, role: string): Promise<string> {
  const isStaff = role !== 'admin';
  const now = new Date();
  const today = now.toISOString().slice(0, 10);
  const month = today.slice(0, 7) + '-01';
  const limitDate = new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10);

  const [saleToday, saleMonth, payToday, payMonth, buyToday, buyMonth, cntItem, cntClient] = await Promise.all([
    db.prepare('SELECT COUNT(*) AS n, COALESCE(SUM(amount),0) AS s FROM sale_items WHERE happened_at LIKE ?').bind(`${today}%`).first<{ n: number; s: number }>(),
    db.prepare('SELECT COUNT(*) AS n, COALESCE(SUM(amount),0) AS s, COALESCE(SUM(quantity * cost_price),0) AS c FROM sale_items WHERE happened_at >= ?').bind(month).first<{ n: number; s: number; c: number }>(),
    db.prepare('SELECT COUNT(*) AS n, COALESCE(SUM(amount + waived),0) AS s FROM payments WHERE happened_at >= ?').bind(`${today} 00:00:00`).first<{ n: number; s: number }>(),
    db.prepare('SELECT COUNT(*) AS n, COALESCE(SUM(amount + waived),0) AS s FROM payments WHERE happened_at >= ?').bind(`${month} 00:00:00`).first<{ n: number; s: number }>(),
    db.prepare('SELECT COUNT(*) AS n, COALESCE(SUM(amount),0) AS s FROM purchase_items WHERE happened_at LIKE ?').bind(`${today}%`).first<{ n: number; s: number }>(),
    db.prepare('SELECT COUNT(*) AS n, COALESCE(SUM(amount),0) AS s FROM purchase_items WHERE happened_at >= ?').bind(month).first<{ n: number; s: number }>(),
    db.prepare("SELECT COUNT(*) AS n FROM items WHERE deleted_at IS NULL").first<{ n: number }>(),
    db.prepare("SELECT COUNT(*) AS n FROM clients WHERE deleted_at IS NULL").first<{ n: number }>(),
  ]);

  const lines: string[] = [];
  lines.push(`业务概况（截至 ${today}）：商品 ${cntItem?.n ?? 0} 个，在记店铺 ${cntClient?.n ?? 0} 家。`);
  lines.push(`今日（${today}）：出货 ${(saleToday?.n ?? 0)} 笔、金额 ${money(saleToday?.s ?? 0)}；进货 ${(buyToday?.n ?? 0)} 笔、金额 ${money(buyToday?.s ?? 0)}；收款 ${(payToday?.n ?? 0)} 笔、${money(payToday?.s ?? 0)}。`);
  const monthProfit = isStaff ? null : ((saleMonth?.s ?? 0) - (saleMonth?.c ?? 0));
  lines.push(`本月（${month.slice(0, 7)} 起）：出货 ${(saleMonth?.n ?? 0)} 笔、金额 ${money(saleMonth?.s ?? 0)}${monthProfit !== null ? `、毛利 ${money(monthProfit)}` : ''}；进货金额 ${money(buyMonth?.s ?? 0)}；收款 ${(payMonth?.n ?? 0)} 笔、${money(payMonth?.s ?? 0)}。`);

  if (!isStaff) {
    // 欠款 top5（admin 专属：金额是经营敏感信息）
    const saleByClient = await db.prepare(
      `SELECT s.client_id, c.name AS name, COALESCE(SUM(s.amount),0) AS s
       FROM sale_items s JOIN clients c ON c.id = s.client_id
       WHERE s.client_id != '' AND c.deleted_at IS NULL
       GROUP BY s.client_id`,
    ).all<{ client_id: string; name: string; s: number }>();
    const payByClient = await db.prepare(
      `SELECT client_id, COALESCE(SUM(amount + waived),0) AS s FROM payments GROUP BY client_id`,
    ).all<{ client_id: string; s: number }>();
    const payMap = new Map(payByClient.results.map((r) => [r.client_id, r.s]));
    const debts = saleByClient.results
      .map((r) => ({ name: r.name, debt: Math.round((r.s - (payMap.get(r.client_id) ?? 0)) * 100) / 100 }))
      .filter((d) => Math.abs(d.debt) > 0.005)
      .sort((a, b) => b.debt - a.debt)
      .slice(0, 5);
    if (debts.length > 0) {
      lines.push(`欠款 top5：${debts.map((d) => `${d.name} ${money(d.debt)}`).join('；')}${debts.some((d) => d.debt < 0) ? '（负=预存/多收款）' : ''}。`);
    } else {
      lines.push('欠款：当前无未结欠款。');
    }
  }

  // 低库存（剩余 ≤ 阈值 且 阈值 > 0，前 8）+ 临期（7 天内批次，前 5）——店员也可见（库存核对是店员职责）
  const lowRows = await db.prepare(
    `SELECT i.name, sb.unit, COALESCE(SUM(sb.remaining),0) AS qty, COALESCE(st.min_stock,0) AS min_stock
     FROM stock_batches sb
     JOIN items i ON i.id = sb.item_id
     LEFT JOIN stocks st ON st.item_id = sb.item_id AND st.unit = sb.unit
     WHERE i.deleted_at IS NULL
     GROUP BY sb.item_id, sb.unit
     HAVING qty <= min_stock AND min_stock > 0
     ORDER BY qty ASC
     LIMIT 8`,
  ).all<{ name: string; unit: string; qty: number; min_stock: number }>();
  if (lowRows.results.length > 0) {
    lines.push(`低库存（剩余≤阈值）：${lowRows.results.map((r) => `${r.name} 剩 ${qty(r.qty)}${r.unit}/阈 ${qty(r.min_stock)}`).join('；')}。`);
  }
  const expRows = await db.prepare(
    `SELECT i.name, sb.unit, SUM(sb.remaining) AS qty, MIN(sb.expiry_date) AS exp
     FROM stock_batches sb JOIN items i ON i.id = sb.item_id
     WHERE sb.expiry_date IS NOT NULL AND sb.expiry_date != '' AND sb.expiry_date <= ? AND sb.remaining > 0 AND i.deleted_at IS NULL
     GROUP BY sb.item_id, sb.unit
     ORDER BY exp ASC
     LIMIT 5`,
  ).bind(limitDate).all<{ name: string; unit: string; qty: number; exp: string }>();
  if (expRows.results.length > 0) {
    lines.push(`临期（${limitDate} 前到期）：${expRows.results.map((r) => `${r.name} 剩 ${qty(r.qty)}${r.unit}（${r.exp} 到期）`).join('；')}。`);
  }
  return lines.join('\n');
}

/** 调文字模型对话（无 key 抛错带提示；返回模型回复文本） */
export async function chatWithAssistant(
  cfg: AiConfig,
  messages: Array<{ role: string; content: string }>,
  context: string,
): Promise<string> {
  const ep = capabilityEndpoint(cfg, 'text');
  if (!ep.apiKey.trim()) {
    throw new Error('AI 助手未启用：请老板在「我的 → AI 识别设置」配置 API Key 并绑定文字能力');
  }
  const baseUrl = ep.baseUrl.replace(/\/+$/, '');
  const chatUrl = baseUrl.endsWith('/chat/completions') ? baseUrl : `${baseUrl}/chat/completions`;
  const system = [
    '你是「陶朱进销存」的 AI 助手，帮店主查看经营数据、管理库存。以下是当前业务数据快照（不是编造，以它为准）：',
    '--- 数据快照 ---',
    context,
    '--- 回答规则 ---',
    '1. 只依据上面的数据快照作答；快照里没有的，老实说"暂无这项数据"，绝不编造数字。',
    '2. 被问到"卖了多少/赚了多少/谁欠款/该补什么货/有什么临期"等经营问题时，直接给数字和清单，简洁、口语化。',
    '3. 如果用户想记一笔账/录单（如"帮我记一笔：老王拿了2箱苹果"），委婉引导：请到「记单」页用 AI 识别记账（拍照/语音/文字），本助手专注问数与提醒，不能直接落单。',
    '4. 被问"怎么用/功能在哪"等使用问题时，用一两句话说明（记单在底部「记单」页、统计在「统计」页、库存盘点在「库存」页右上角、对账单在「对账单」、备份在「我的→备份」）。',
    '5. 回复用中文，尽量简短（一般 2-5 行）。',
  ].join('\n');
  const resp = await _postChatAdaptive(chatUrl, {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${ep.apiKey.trim()}`,
  }, {
    model: ep.model || DEFAULT_TEXT_MODEL,
    temperature: 0.3,
    messages: [{ role: 'system', content: system }, ...messages],
  }, 60000);
  if (!resp.ok) {
    const bodyText = await resp.text().catch(() => '');
    throw new Error(`AI 助手接口错误 HTTP ${resp.status}: ${bodyText.slice(0, 200)}`);
  }
  const data = (await resp.json()) as { choices?: Array<{ message?: { content?: string } }> };
  return (data.choices?.[0]?.message?.content ?? '').trim();
}