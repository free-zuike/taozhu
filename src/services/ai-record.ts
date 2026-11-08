/** AI 一句话落单（v0.17.478，对齐参考 App record_transaction_from_text）：
 *  解析文本 → 按名称匹配/自动建商品 → 复用 services/records 落库（FIFO/欠款/审计一致）。
 *  写操作：经授权门（默认 ask），授权后由执行器调用 recordTransactionFromText。 */
import { randomId } from '../lib/password';
import { capabilityEndpoint, parseText } from './ai-parse';
import { createPurchaseOrder, createSaleOrder, type PurchaseLineInput, type SaleLineInput } from './records';
import { ApiError } from '../lib/api-error';
import { normalizeAllocations, allocationStatements } from '../lib/allocations';
import { localTodayISO } from '../lib/biz-date';
import type { D1Database } from '@cloudflare/workers-types';

// ai-parse 未导出 getAiConfig；此处从 settings 读取
async function loadCfg(db: D1Database) {
  const { getAiConfig } = await import('../routes/settings');
  return getAiConfig(db);
}

export interface ResolvedLine {
  name: string;
  unit: string;
  quantity: number;
  price: number;
  price_id: string;
  item_id: string;
  auto_created: boolean;
}

/** 草稿商品 → price_id：精确名匹配（单位优先），未匹配自动建商品（店员不自动建，抛错提示） */
export async function resolveDraftItems(
  db: D1Database,
  purpose: 'purchase' | 'sale',
  drafts: Array<{ name: string; unit: string; quantity: number; price: number }>,
  role: string,
): Promise<ResolvedLine[]> {
  const resolved: ResolvedLine[] = [];
  for (const d of drafts) {
    const name = (d.name ?? '').trim();
    if (!name) continue;
    const unit = (d.unit ?? '').trim();
    const qty = Number(d.quantity);
    const price = Number(d.price);
    if (!Number.isFinite(qty) || qty <= 0) continue;
    const effPrice = Number.isFinite(price) && price > 0 ? price : 0;

    const item = await db.prepare(
      'SELECT id FROM items WHERE name = ? AND deleted_at IS NULL LIMIT 1',
    ).bind(name).first<{ id: string }>();
    if (item) {
      // 已有商品：取价格行（同单位优先，无则第一个启用价格）
      const prices = await db.prepare(
        `SELECT id, unit FROM item_prices WHERE item_id = ? AND active = 1 ORDER BY (unit = ?) DESC, unit ASC LIMIT 1`,
      ).bind(item.id, unit).first<{ id: string; unit: string }>();
      if (!prices) throw new ApiError(`商品「${name}」还没有单位价格，请先在「商品管理」补充`, 400);
      resolved.push({
        name, unit: prices.unit, quantity: qty, price: effPrice,
        price_id: prices.id, item_id: item.id, auto_created: false,
      });
    } else {
      if (role !== 'admin') {
        throw new ApiError(`商品「${name}」不存在，请先请老板在「商品管理」添加`, 400);
      }
      // 自动建商品（对齐记单页"提交时自动入库"）：名称 + 单一单位价格
      const itemId = randomId();
      const priceId = randomId();
      await db.prepare('INSERT INTO items (id, name, category, category_id, count_unit) VALUES (?, ?, ?, ?, ?)')
        .bind(itemId, name, '', null, '').run();
      await db.prepare(
        'INSERT INTO item_prices (id, item_id, unit, purchase_price, sale_price, per) VALUES (?, ?, ?, ?, ?, ?)',
      ).bind(
        priceId, itemId, unit || '件',
        purpose === 'purchase' ? effPrice : 0,
        purpose === 'sale' ? effPrice : 0,
        null,
      ).run();
      resolved.push({
        name, unit: unit || '件', quantity: qty, price: effPrice,
        price_id: priceId, item_id: itemId, auto_created: true,
      });
    }
  }
  if (resolved.length === 0) throw new ApiError('没有识别到可记账的商品，请说得更具体些（如：白菜2斤每斤3元）', 400);
  return resolved;
}

export interface RecordResult {
  type: 'purchase' | 'sale';
  order_id: string;
  client: string;
  date: string;
  total: number;
  lines: Array<{ name: string; unit: string; quantity: number; price: number; auto_created: boolean }>;
}

/** 执行落单（授权后调用）：解析文本 → 匹配/建商品 → 落库 */
export async function recordTransactionFromText(
  db: D1Database,
  user: { id: string; username: string; role: string },
  purpose: 'purchase' | 'sale',
  text: string,
): Promise<RecordResult> {
  const cfg = await loadCfg(db);
  const ep = capabilityEndpoint(cfg, 'text');
  if (!ep.apiKey.trim()) throw new ApiError('AI 记账未启用：请老板在「我的 → AI 识别设置」配置 API Key', 400);
  const inv = await parseText(ep, text, purpose);
  const drafts = inv.items.filter((i) => (i.name ?? '').trim());
  if (drafts.length === 0) throw new ApiError('没有识别到可记账的商品，请说得更具体些（如：白菜2斤每斤3元）', 400);

  const resolved = await resolveDraftItems(db, purpose, drafts, user.role);
  const date = /^\d{4}-\d{2}-\d{2}$/.test(inv.date) ? inv.date : localTodayISO();

  if (purpose === 'purchase') {
    const lines: PurchaseLineInput[] = resolved.map((r) => ({
      price_id: r.price_id,
      quantity: r.quantity,
      purchase_price: r.price > 0 ? r.price : undefined,
      happened_at: date,
    }));
    const order = await createPurchaseOrder(db, user, { happened_at: date, items: lines });
    return {
      type: 'purchase', order_id: order.id, client: '', date, total: order.total,
      lines: resolved.map((r) => ({ name: r.name, unit: r.unit, quantity: r.quantity, price: r.price, auto_created: r.auto_created })),
    };
  }

  // sale：店铺必须匹配（不自动建店——店铺是老板专属配置且名称匹配不可靠）
  const clientName = inv.client?.trim() || '';
  const client = clientName
    ? await db.prepare("SELECT id, name FROM clients WHERE deleted_at IS NULL AND (name = ? OR name LIKE ?) LIMIT 1").bind(clientName, `%${clientName}%`).first<{ id: string; name: string }>()
    : null;
  if (!client) throw new ApiError(clientName ? `店铺「${clientName}」不存在，请先在「店铺管理」添加` : '出货单需要店铺：请带上店名（如：给老王记一笔…）', 400);
  const lines: SaleLineInput[] = resolved.map((r) => ({
    price_id: r.price_id,
    quantity: r.quantity,
    sale_price: r.price > 0 ? r.price : undefined,
    happened_at: date,
  }));
  const order = await createSaleOrder(db, user, { client_id: client.id, happened_at: date, items: lines });
  return {
    type: 'sale', order_id: order.id, client: client.name, date, total: order.total,
    lines: resolved.map((r) => ({ name: r.name, unit: r.unit, quantity: r.quantity, price: r.price, auto_created: r.auto_created })),
  };
}

/**
 * AI 对账补录：登记一笔收款（写 payments + 变更流 + 快照失效 + 审计）。
 * 金额与日期必须由用户明确给出，绝不从对账差额反推；备注统一标注「待核对」便于追溯。
 * 与 /payments 路由口径一致（欠款 = Σ出货 − Σ(amount + waived)，waived 恒为 0）。
 */
export async function createAiPayment(
  db: D1Database,
  user: { id: string; username: string; role: string },
  input: { client: string; amount: number; date: string | null; note: string | null; allocations?: unknown },
): Promise<{ id: string; client: string; amount: number; date: string; note: string }> {
  const name = (input.client ?? '').trim();
  const amount = Number(input.amount);
  if (!name) throw new ApiError('补录收款需要店铺名', 400);
  if (!Number.isFinite(amount) || amount <= 0) throw new ApiError('收款金额必须大于 0', 400);
  const client = await db.prepare(
    "SELECT id, name FROM clients WHERE deleted_at IS NULL AND (name = ? OR name LIKE ? OR ? LIKE '%' || name || '%') LIMIT 1",
  ).bind(name, `%${name}%`, name).first<{ id: string; name: string }>();
  if (!client) throw new ApiError(`店铺「${name}」不存在，请先在「店铺管理」添加`, 400);
  const date = input.date && /^\d{4}-\d{2}-\d{2}$/.test(input.date) ? input.date : localTodayISO();
  const note = `AI 对账补录（待核对）${input.note ? `：${input.note}` : ''}`.slice(0, 200);
  const id = randomId();
  // 与 /payments 同口径：默认把这笔收款按最早未结清单据 FIFO 核销，
  // 让对账能指出「哪张单还没结清」，而不是只有累计欠款一个数字。
  let allocations;
  try {
    allocations = await normalizeAllocations(db, client.id, amount, input.allocations);
  } catch (e) {
    throw new ApiError((e as Error).message, 400);
  }
  await db.batch([
    db.prepare(
      'INSERT INTO payments (id, client_id, happened_at, amount, waived, method, note, created_by) VALUES (?, ?, ?, ?, 0, ?, ?, ?)',
    ).bind(id, client.id, date, amount, '', note, user.id),
    ...allocationStatements(db, id, allocations),
  ]);
  // 动态 import 避免与 records → sync → routes 的静态依赖成环
  const [{ buildPayload, recordChange }, { expireSnapshots }, { recordAudit }] = await Promise.all([
    import('../lib/sync'), import('../lib/snapshot'), import('../routes/audit'),
  ]);
  await recordChange(db, {
    entity_type: 'payment', entity_sync_id: id,
    payload: await buildPayload(db, 'payment', id), updated_by_username: user.username,
  });
  // 新快照用「游标 + affectedSince」精确失效；这里显式全失效，兜住任何白名单遗漏，
  // 保证欠款/计数在补录后立刻准确（低频写，一次重算可接受）。
  await expireSnapshots(db);
  await recordAudit(db, {
    username: user.username, action: 'create', entity_type: 'payment', entity_id: id,
    detail: `AI 对账补录收款：${client.name} ${date} ¥${amount}`,
  });
  return { id, client: client.name, amount, date, note };
}

/** 授权弹窗预览文本（存 pending 时生成） */
export function recordPreview(purpose: 'purchase' | 'sale', text: string, linesCount: number, total: number): string {
  const kind = purpose === 'purchase' ? '进货' : '出货';
  const totalText = total > 0 ? `，合计 ¥${Math.round(total * 100) / 100}` : '';
  return `一句话记账：${kind}「${text.slice(0, 60)}」识别 ${linesCount} 项${totalText}，确认后将直接入账`;
}
