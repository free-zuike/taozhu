/**
 * 收款 ↔ 出货单核销：把「欠款 = Σ出货 − Σ收款」这条累计差值，
 * 变成能追到具体单据的台账。欠款口径完全不变，核销只是附加的对账信息。
 *
 * 未显式指定 allocations 时按「最早未结清单据」FIFO 自动分摊，
 * 因此现有前端不改也能逐步积累核销数据；显式传入则完全按用户指定。
 */
import { randomId } from './password';

export interface AllocationInput { sale_id: string; amount: number }
export interface UnsettledOrder {
  sale_id: string;
  date: string;
  total: number;
  allocated: number;
  unsettled: number;
}

const round2 = (n: number): number => Math.round(n * 100) / 100;

/** 该店每张出货单的金额、已核销额、待收额（按日期升序，便于 FIFO）
 *  excludePaymentId：编辑某笔收款时要先把它自己的旧核销排除，否则会被重复计入「已核销」。 */
export async function listUnsettled(
  db: D1Database, clientId: string, excludePaymentId?: string,
): Promise<UnsettledOrder[]> {
  const [sales, alloc] = await Promise.all([
    db.prepare(
      `SELECT sale_id, substr(MAX(happened_at),1,10) AS d, SUM(amount) AS t
       FROM sale_items WHERE client_id = ? GROUP BY sale_id ORDER BY d ASC, sale_id ASC`,
    ).bind(clientId).all<{ sale_id: string; d: string; t: number }>(),
    // 老库迁移窗口内该表可能尚未补建：宁可退化为「无核销数据」，也不能让登记收款失败。
    db.prepare(
      `SELECT a.sale_id, SUM(a.amount) AS a FROM payment_allocations a
       JOIN payments p ON p.id = a.payment_id
       WHERE p.client_id = ?${excludePaymentId ? ' AND a.payment_id <> ?' : ''} GROUP BY a.sale_id`,
    ).bind(clientId, ...(excludePaymentId ? [excludePaymentId] : [])).all<{ sale_id: string; a: number }>()
      .catch(() => ({ results: [] as { sale_id: string; a: number }[] })),
  ]);
  const am = new Map(alloc.results.map((r) => [r.sale_id, Number(r.a) || 0]));
  return sales.results.map((r) => {
    const total = round2(Number(r.t) || 0);
    const allocated = round2(Math.min(am.get(r.sale_id) ?? 0, total));
    return {
      sale_id: r.sale_id, date: r.d, total, allocated,
      unsettled: round2(Math.max(total - allocated, 0)),
    };
  });
}

/** 未显式指定时自动分摊本次可核销额（= 实收 + 减免） */
export async function autoAllocate(
  db: D1Database, clientId: string, cap: number, excludePaymentId?: string,
): Promise<AllocationInput[]> {
  if (!(cap > 0)) return [];
  let rest = round2(cap);
  const out: AllocationInput[] = [];
  for (const o of await listUnsettled(db, clientId, excludePaymentId)) {
    if (rest <= 0.005 || o.unsettled <= 0) continue;
    const v = round2(Math.min(rest, o.unsettled));
    out.push({ sale_id: o.sale_id, amount: v });
    rest = round2(rest - v);
  }
  return out;
}

/** 校验并返回归一化核销明细；失败抛 Error（路由层转 400） */
export async function normalizeAllocations(
  db: D1Database, clientId: string, cap: number, input: unknown, excludePaymentId?: string,
): Promise<AllocationInput[]> {
  if (input === undefined || input === null) return autoAllocate(db, clientId, cap, excludePaymentId);
  if (!Array.isArray(input)) throw new Error('allocations 必须是数组');
  const list = input.map((x) => {
    const o = x as { sale_id?: unknown; amount?: unknown };
    return { sale_id: String(o.sale_id ?? ''), amount: Number(o.amount) };
  });
  if (list.some((x) => !x.sale_id || !Number.isFinite(x.amount) || x.amount <= 0)) {
    throw new Error('allocations 的 sale_id / amount 不合法');
  }
  const sum = round2(list.reduce((s, x) => s + x.amount, 0));
  if (sum > cap + 0.005) throw new Error('核销总额不能超过本次收款金额（含减免）');
  const unsettled = new Map(
    (await listUnsettled(db, clientId, excludePaymentId)).map((o) => [o.sale_id, o.unsettled]),
  );
  const perSale = new Map<string, number>();
  for (const x of list) {
    if (!unsettled.has(x.sale_id)) throw new Error(`出货单 ${x.sale_id} 不属于该店铺或不存在`);
    const acc = (perSale.get(x.sale_id) ?? 0) + x.amount;
    if (acc > (unsettled.get(x.sale_id) ?? 0) + 0.005) throw new Error(`出货单 ${x.sale_id} 核销额超过待收额`);
    perSale.set(x.sale_id, acc);
  }
  return list;
}

/** 生成插入语句，供与 payments 写入同一个 db.batch 原子执行 */
export function allocationStatements(
  db: D1Database, paymentId: string, list: AllocationInput[],
): D1PreparedStatement[] {
  return list.map((x) => db.prepare(
    'INSERT INTO payment_allocations (id, payment_id, sale_id, amount) VALUES (?, ?, ?, ?)',
  ).bind(randomId(), paymentId, x.sale_id, x.amount));
}
