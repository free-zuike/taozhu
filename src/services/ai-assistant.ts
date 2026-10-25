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

// ---------------------------------------------------------------------------
// 动态查询 + 内置知识库（0.17.475：对齐参考项目 RAG 文档问答的轻量版 + 经营历史问数）
// 两步式：先让模型提取意图（JSON），后端按参数查 stats 数据层/匹配知识库，再组织最终回答。
// ---------------------------------------------------------------------------

/** 内置操作说明知识库（对齐参考项目 RAG 观感的轻量版：条目量小，关键词匹配注入而非向量检索） */
const KB_ENTRIES: Array<{ keywords: string[]; title: string; body: string }> = [
  { keywords: ['记单', '记账', '出货', '进货', '录入', '开单', '怎么记'], title: '记单（出入货记账）', body: '底部「记单」页：选店铺/日期 → 扫价签或搜索选商品 → 填数量（可拍凭证照）→ 保存。也可点页内 AI 记账：拍照识别小票、文字或语音一句话记账，识别后确认入库。' },
  { keywords: ['统计', '报表', '销售', '卖了', '赚了'], title: '统计', body: '底部「统计」页：日/周/月/年/自定义区间五档，含出货额、毛利、收款、进货；支持按店铺过滤与多店对比折线图；「计价天数」统计记账覆盖率。' },
  { keywords: ['库存', '盘点', '补货', '预警', '临期', '到期'], title: '库存与盘点', body: '「库存」页：库存=进货−出货−损耗−盘点调整自动计算；右上角「盘点」按实际数量校对（差异=盘盈/盘亏自动调整，可留痕）；行内「报损」登记损耗；「只看预警」筛低库存；卡片「来源」看每笔进出。' },
  { keywords: ['对账', '对账单', '结账', '月结', '期末'], title: '对账单', body: '「对账单」页：选店铺+结账周期生成明细（出货/收款/欠款），可一键复制发微信、导出 Excel、生成图片打印；按店铺「编辑」可设结账方式（抹零到单笔/日/月结）。' },
  { keywords: ['欠款', '账期', '催', '赊'], title: '欠款看板', body: '「欠款看板」：每店累计欠款（出货−收款）与账期，超 30 天标红提醒；欠款=各店铺独立，可按店对账。' },
  { keywords: ['收款', '收钱', '还款', '平账'], title: '收款结账', body: '「收款结账」：登记某店收到的钱（选收款方式：现金/微信/支付宝…），自动冲减欠款；收款历史可查，支持减免（抹零尾款）。' },
  { keywords: ['商品', '新增商品', '价格', '调价', '单位', '多单位'], title: '商品管理', body: '「商品管理」：新增商品可设多单位双价（如 箱+斤），配计数单位折合；右上「批量调价」一次选多个商品按百分比/固定值调价（价格组联动可选）；价格组（零售/批发/VIP）按店铺等级带价。' },
  { keywords: ['店铺', '客户', '新增店铺', '客户管理'], title: '店铺管理', body: '「店铺管理」：新增/编辑店铺（联系人/电话/结账方式抹零/所属分类/价格组等级）；删除为软删，历史单据保留。' },
  { keywords: ['备份', '恢复', '存档'], title: '数据备份', body: '「我的 → 数据备份」：自动备份可按时间设置、保留份数；「立即备份」生成云端归档包（含附件原图）；恢复=从历史备份合并导入数据，跨设备迁移保险。' },
  { keywords: ['分类', '分组'], title: '分类管理', body: '「分类管理」：商品分类与店铺分类各两级（一级/二级），记单按分类快速找商品与店铺。' },
  { keywords: ['AI', '识别', '语音', '拍照', '设置', 'key', '配置'], title: 'AI 识别设置', body: '「我的 → AI 识别设置」：配置服务商 Key 与模型（文字/图片/语音三能力分别绑定），每个能力可一键测试；未配置时记单页 AI 记账会提示去配置。' },
  { keywords: ['同步', '离线', '多设备'], title: '同步', body: 'App 双端数据自动同步（本地优先：离线可用，联网后合并上传+增量拉取）；「我的 → 同步状态」查看待同步/异常明细，异常记录可查日志；小程序与 App 同账号共享数据。' },
  { keywords: ['价格组', '等级', 'vip', '批发', '零售'], title: '价格组', body: '「价格组」：默认零售/批发/VIP 三组，可增删；每个商品在每个价格组有独立售价，店铺「价格组等级」决定记单自动取哪档价。' },
  { keywords: ['报损', '损耗', '坏', '变质'], title: '报损', body: '「库存」页行内「报损」：登记损坏/变质损耗，从最早进货批次扣减并按进价计损耗金额，单独统计不混入毛利；「损耗记录」可查流水。' },
  { keywords: ['审计', '操作记录', '谁改'], title: '操作审计', body: '「操作审计」（老板）：登录/删除/改价/调价/盘点等关键操作留痕，含操作人、时间、对象与详情。' },
  { keywords: ['成员', '店员', '账号', '权限'], title: '成员与权限', body: '「成员」：可创建店员账号（送货/记账视角，少经营类功能）、老板账号；店员不可见进价/成本/毛利/欠款金额（AI 助手问数同样打码）。' },
  { keywords: ['抹零', '舍入', '进位', '金额精度'], title: '结账抹零', body: '店铺「编辑」→ 金额规则：结账方式选 单笔/按日/月结抹零到 元/角/分，进位临界 0.5 或 0.6 可配；未设置的店跟随全局。' },
  { keywords: ['临期', '01不看', 'renew'], title: '临期提醒', body: '进货时给商品填到期日，到期前 7 天「库存」卡与「我的」页标红提示；「只看预警」可筛临期商品。' },
  { keywords: ['主题', '背景', '皮肤', '暗色', '深色', '亮色'], title: '主题设置', body: '「主题设置」：配色主题/明暗模式/背景图案（静态主题可跨端同步）。' },
];

/** 按关键词命中数挑知识库条目（对齐参考 RAG top-K：这里 K=3） */
export function pickKbEntries(text: string, limit = 3): Array<{ title: string; body: string }> {
  const hit = (e: { keywords: string[] }): number => e.keywords.filter((k) => text.includes(k)).length;
  return KB_ENTRIES
    .map((e) => ({ e, n: hit(e) }))
    .filter((x) => x.n > 0)
    .sort((a, b) => b.n - a.n)
    .slice(0, limit)
    .map((x) => ({ title: x.e.title, body: x.e.body }));
}

interface Intent {
  intent: 'query' | 'kb' | 'chat';
  view: string | null;
  start: string | null;
  end: string | null;
  client: string | null;
  kind: 'sale' | 'purchase' | null;
  year: number | null;
  topics: string[];
}

/** 意图提取（JSON 模式；宽松解析，失败返回 null 走兜底） */
export async function extractIntent(cfg: AiConfig, userText: string, ctxText: string): Promise<Intent | null> {
  const ep = capabilityEndpoint(cfg, 'text');
  if (!ep.apiKey.trim()) return null;
  const baseUrl = ep.baseUrl.replace(/\/+$/, '');
  const chatUrl = baseUrl.endsWith('/chat/completions') ? baseUrl : `${baseUrl}/chat/completions`;
  const system = [
    '你是数据查询意图识别器。用户输入可能问三类：',
    '(a) 经营数据（金额/销售/欠款/进货/库存相关）→ intent="query"，并填 view 与参数；',
    '(b) 功能用法（怎么用/功能在哪/说明）→ intent="kb"，topics 填相关主题词；',
    '(c) 其他（问候/闲聊）→ intent="chat"。',
    `今天日期 ${ctxText.split('\n')[0] ?? ''}。`,
    'view 可选："summary"(任意区间汇总)/"clients"(区间按店出货与欠款)/"debts"(当前欠款)/"items"(区间商品销量排行)/"monthly"(某年按月)/"daily"(区间按日)/"years"(有哪些年份数据)。',
    'start/end 必须是 YYYY-MM-DD（用户说相对时间如"上个月/去年/今年"时换算成具体起止日）；clients 的 client 填店铺名称（没有则为 null）；year 是数字年份（没有为 null）；kind 为 sale 或 purchase（进货相关填 purchase，默认 sale）。',
    '只输出一个 JSON 对象（不要多余文字）：{"intent":"query"|"kb"|"chat","view":null,"start":null,"end":null,"client":null,"kind":"sale","year":null,"topics":[]}',
    '无法归类/不确定→ intent="chat"。',
  ].join('\n');
  try {
    const resp = await _postChatAdaptive(chatUrl, {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${ep.apiKey.trim()}`,
    }, {
      model: ep.model || DEFAULT_TEXT_MODEL,
      temperature: 0.1,
      messages: [{
        role: 'user',
        content: `${system}\n\n用户输入：${userText.slice(0, 500)}`,
      }],
    }, 60000);
    if (!resp.ok) return null;
    const data = (await resp.json()) as { choices?: Array<{ message?: { content?: string } }> };
    const raw = (data.choices?.[0]?.message?.content ?? '').trim();
    const m = raw.match(/\{[\s\S]*\}/);
    if (!m) return null;
    const parsed = JSON.parse(m[0]) as Partial<Intent>;
    return {
      intent: parsed.intent === 'query' || parsed.intent === 'kb' ? parsed.intent : 'chat',
      view: typeof parsed.view === 'string' ? parsed.view : null,
      start: typeof parsed.start === 'string' ? parsed.start : null,
      end: typeof parsed.end === 'string' ? parsed.end : null,
      client: typeof parsed.client === 'string' ? parsed.client || null : null,
      kind: parsed.kind === 'purchase' ? 'purchase' : 'sale',
      year: typeof parsed.year === 'number' ? parsed.year : null,
      topics: Array.isArray(parsed.topics) && parsed.topics.every((t) => typeof t === 'string') ? parsed.topics as string[] : [],
    };
  } catch (_) {
    return null;
  }
}

/** 按意图参数查业务数据 → 文本（数据层数字给模型，模型只翻译）；店员打码；返回 null=无法执行 */
export async function runBusinessQuery(
  db: D1Database, role: string, q: Intent,
): Promise<string | null> {
  const isStaff = role !== 'admin';
  const today = new Date().toISOString().slice(0, 10);
  let clientId: string | null = null;
  if (q.client) {
    const row = await db.prepare(
      "SELECT id FROM clients WHERE deleted_at IS NULL AND (name = ? OR name LIKE ?) LIMIT 1",
    ).bind(q.client, `%${q.client}%`).first<{ id: string }>();
    if (row) clientId = row.id;
  }
  const lines: string[] = [];

  switch (q.view) {
    case 'summary': {
      const start = q.start || `${today.slice(0, 4)}-01-01`;
      const end = q.end || today;
      if (end < start) return `${start} 至 ${end} 区间无效（开始晚于结束）`;
      const where = `happened_at >= ? AND happened_at <= ?${clientId ? ' AND client_id = ?' : ''}`;
      const params: string[] = [start, end, ...(clientId ? [clientId] : [])];
      const [sale, pay, buy] = await Promise.all([
        db.prepare(`SELECT COUNT(*) AS n, COALESCE(SUM(amount),0) AS s, COALESCE(SUM(quantity * cost_price),0) AS c FROM sale_items WHERE ${where}`).bind(...params).first<{ n: number; s: number; c: number }>(),
        db.prepare(`SELECT COALESCE(SUM(amount + waived),0) AS s, COUNT(*) AS n FROM payments WHERE happened_at >= ? AND happened_at <= ?${clientId ? ' AND client_id = ?' : ''}`).bind(...params).first<{ s: number; n: number }>(),
        db.prepare(`SELECT COALESCE(SUM(amount),0) AS s FROM purchase_items WHERE happened_at >= ? AND happened_at <= ?`).bind(start, end).first<{ s: number }>(),
      ]);
      const profit = isStaff ? null : ((sale?.s ?? 0) - (sale?.c ?? 0));
      lines.push(`区间 ${start} ~ ${end}${clientId ? '（指定店铺）' : ''}：`);
      lines.push(`出货 ${sale?.n ?? 0} 笔、${money(sale?.s ?? 0)}${profit !== null ? `，毛利 ${money(profit)}` : ''}；`);
      lines.push(`进货 ${money(buy?.s ?? 0)}；收款 ${pay?.n ?? 0} 笔、${money(pay?.s ?? 0)}。`);
      return lines.join('\n');
    }
    case 'clients': {
      const start = q.start || '2000-01-01';
      const end = q.end || today;
      const saleRows = await db.prepare(
        `SELECT s.client_id, c.name, COALESCE(SUM(s.amount),0) AS s
         FROM sale_items s JOIN clients c ON c.id = s.client_id
         WHERE s.client_id != '' AND s.happened_at >= ? AND s.happened_at <= ? AND c.deleted_at IS NULL
         GROUP BY s.client_id ORDER BY s DESC LIMIT 10`,
      ).bind(start, end).all<{ client_id: string; name: string; s: number }>();
      if (saleRows.results.length === 0) return '该区间没有出货记录';
      // 欠款=截止 end 全部出货−全部收款
      const cids = saleRows.results.map((r) => r.client_id);
      const payRows = await db.prepare(
        `SELECT client_id, COALESCE(SUM(amount + waived),0) AS s FROM payments WHERE happened_at <= ? AND client_id IN (${cids.map(() => '?').join(',')}) GROUP BY client_id`,
      ).bind(end, ...cids).all<{ client_id: string; s: number }>();
      const payMap = new Map(payRows.results.map((r) => [r.client_id, r.s]));
      lines.push(`区间 ${start} ~ ${end} 各店出货额：`);
      for (const r of saleRows.results) {
        const debt = Math.round((r.s - (payMap.get(r.client_id) ?? 0)) * 100) / 100;
        lines.push(`${r.name}：出货 ${money(r.s)}${isStaff ? '' : `，欠款 ${money(debt)}`}`);
      }
      return lines.join('\n');
    }
    case 'debts': {
      if (isStaff) return null; // 欠款金额老板专属
      const [saleRows, payRows] = await Promise.all([
        db.prepare(
          `SELECT s.client_id, c.name, COALESCE(SUM(s.amount),0) AS s
           FROM sale_items s JOIN clients c ON c.id = s.client_id
           WHERE s.client_id != '' AND c.deleted_at IS NULL
           GROUP BY s.client_id`,
        ).all<{ client_id: string; name: string; s: number }>(),
        db.prepare('SELECT client_id, COALESCE(SUM(amount + waived),0) AS s FROM payments GROUP BY client_id').all<{ client_id: string; s: number }>(),
      ]);
      const payMap = new Map(payRows.results.map((r) => [r.client_id, r.s]));
      const debts = saleRows.results
        .map((r) => ({ name: r.name, debt: Math.round((r.s - (payMap.get(r.client_id) ?? 0)) * 100) / 100 }))
        .filter((d) => Math.abs(d.debt) > 0.005)
        .sort((a, b) => b.debt - a.debt)
        .slice(0, 10);
      if (debts.length === 0) return '当前没有未结欠款。';
      lines.push('当前欠款（高→低）：');
      lines.push(debts.map((d) => `${d.name} ${money(d.debt)}`).join('；'));
      return lines.join('\n');
    }
    case 'items': {
      const start = q.start || `${today.slice(0, 4)}-01-01`;
      const end = q.end || today;
      const rows = await db.prepare(
        `SELECT i.name, s.unit, COALESCE(SUM(s.quantity),0) AS q, COALESCE(SUM(s.amount),0) AS a
         FROM sale_items s JOIN items i ON i.id = s.item_id
         WHERE s.happened_at >= ? AND s.happened_at <= ? AND i.deleted_at IS NULL
         GROUP BY s.item_id, s.unit ORDER BY a DESC LIMIT 10`,
      ).bind(start, end).all<{ name: string; unit: string; q: number; a: number }>();
      if (rows.results.length === 0) return '该区间没有出货记录';
      lines.push(`区间 ${start} ~ ${end} 出货排行（按金额）：`);
      lines.push(rows.results.map((r) => `${r.name} ${qty(r.q)}${r.unit} · ${money(r.a)}`).join('；'));
      return lines.join('\n');
    }
    case 'monthly': {
      const year = q.year || Number(today.slice(0, 4));
      const rows = await db.prepare(
        `SELECT substr(happened_at,1,7) AS m, COALESCE(SUM(amount),0) AS s, COALESCE(SUM(quantity*cost_price),0) AS c
         FROM sale_items WHERE happened_at >= ? AND happened_at <= ?
         GROUP BY m ORDER BY m`,
      ).bind(`${year}-01-01`, `${year}-12-31`).all<{ m: string; s: number; c: number }>();
      if (rows.results.length === 0) return `暂无 ${year} 年的出货数据`;
      lines.push(`${year} 年各月出货额：`);
      lines.push(rows.results.map((r) => `${r.m.slice(5)}月 ${money(r.s)}${isStaff ? '' : `（毛利 ${money(r.s - r.c)}）`}`).join('；'));
      return lines.join('\n');
    }
    case 'daily': {
      const start = q.start || `${today.slice(0, 4)}-01-01`;
      const end = q.end || today;
      const rows = await db.prepare(
        `SELECT substr(happened_at,1,10) AS d, COALESCE(SUM(amount),0) AS s
         FROM sale_items WHERE happened_at >= ? AND happened_at <= ?
         GROUP BY d ORDER BY d LIMIT 31`,
      ).bind(start, end).all<{ d: string; s: number }>();
      if (rows.results.length === 0) return '该区间没有出货记录';
      lines.push(`区间 ${start} ~ ${end} 每日出货额：`);
      lines.push(rows.results.map((r) => `${r.d} ${money(r.s)}`).join('；'));
      return lines.join('\n');
    }
    case 'years': {
      const rows = await db.prepare(
        `SELECT DISTINCT substr(happened_at,1,4) AS y FROM sale_items
         UNION SELECT DISTINCT substr(happened_at,1,4) FROM purchase_items
         UNION SELECT DISTINCT substr(happened_at,1,4) FROM payments ORDER BY y`,
      ).all<{ y: string }>();
      const years = rows.results.map((r) => Number(r.y)).filter((n) => Number.isInteger(n) && n >= 2000);
      return years.length ? `有数据的年份：${years.join('、')}。` : '暂无历史数据。';
    }
    default:
      return null;
  }
}

/** 编排入口：意图 → 动态查询/知识库 → 组装最终回答 */
export async function assistantAnswer(
  cfg: AiConfig,
  db: D1Database,
  messages: Array<{ role: string; content: string }>,
  role: string,
): Promise<{ reply: string; sources: string[] }> {
  const lastUser = [...messages].reverse().find((m) => m.role === 'user');
  const userText = lastUser?.content ?? '';
  const ctxText = await (async () => (await buildAssistantContext(db, role)).split('\n')[0])();
  const intent = await extractIntent(cfg, userText, ctxText);
  const sources: string[] = [];
  const extras: string[] = [];

  if (intent?.intent === 'query' && intent.view) {
    const data = await runBusinessQuery(db, role, intent);
    if (data != null) {
      extras.push('--- 查询结果（本次问数按你口吻查出的数据，以此为准） ---', data);
    } else {
      extras.push('--- 查询结果 ---', '（该查询当前暂不支持或权限不足）');
    }
  }
  if (intent?.intent === 'kb' && intent.topics) {
    const picked = pickKbEntries(intent.topics.join(' '), 3);
    if (picked.length > 0) {
      extras.push('--- 功能使用说明（内置知识库） ---');
      for (const p of picked) {
        extras.push(`【${p.title}】${p.body}`);
        sources.push(p.title);
      }
    }
  }
  // 兜底：问数据但没识别出来 → 带每日快照；否则不带（省 token）
  let context = extras.length > 0 ? extras.join('\n') : '';
  if (context === '') {
    context = (await buildAssistantContext(db, role))
      + '\n\n（注：以上为当前最新数据快照；如需历史区间数据，请用带时间的问题重问）';
  }
  const reply = await chatWithAssistant(cfg, messages, context);
  return { reply, sources };
}