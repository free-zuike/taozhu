/** 金额舍入配置（settings 表）：进位临界 carry（0.5=四舍五入、0.6=5舍6入，可自定义）
 *  + 精度 digits（0=元、1=角、2=分，默认 2）。
 *  所有金额计算（行金额/合计/毛利/统计/欠款）统一走 roundMoney，跨端同口径。 */

export interface RoundingConfig {
  /** 进位临界（0~1）：小数下一位 >= carry 进位，否则舍去。0.5=四舍五入、0.6=5舍6入 */
  carry: number;
  /** 精度：0=元、1=角、2=分 */
  digits: number;
}

export const DEFAULT_ROUNDING: RoundingConfig = { carry: 0.5, digits: 2 };

const KEY_CARRY = 'round_carry';
const KEY_DIGITS = 'round_digits';

/** 从 settings 表读取舍入配置（缺失/非法回退默认） */
export async function getRoundingConfig(db: D1Database): Promise<RoundingConfig> {
  try {
    const rows = await db
      .prepare("SELECT key, value FROM settings WHERE key IN (?, ?)")
      .bind(KEY_CARRY, KEY_DIGITS)
      .all<{ key: string; value: string }>();
    const m = new Map(rows.results.map((r) => [r.key, r.value]));
    let carry = Number(m.get(KEY_CARRY) ?? 0.5);
    if (!Number.isFinite(carry) || carry <= 0 || carry > 1) carry = 0.5;
    const digit = m.get(KEY_DIGITS);
    let digits = digit === undefined ? 2 : Number(digit);
    if (![0, 1, 2].includes(digits)) digits = 2;
    return { carry, digits };
  } catch {
    return { ...DEFAULT_ROUNDING };
  }
}

/** 按配置舍入金额（进位临界 + 精度）。负数对称处理（毛利可为负）。
 *  临界位判定用放大取整，避免浮点误差（如 1.005*100=100.4999…）。 */
export function roundMoney(value: number, cfg: RoundingConfig): number {
  const f = Math.pow(10, cfg.digits);
  const sign = value < 0 ? -1 : 1;
  const abs = Math.abs(value);
  const scaled = abs * f;
  // 第 digits+1 位数字（决定进/舍）；浮点误差加 1e-9 纠正
  const next = Math.floor(scaled * 10 + 1e-9) % 10;
  const threshold = Math.round(cfg.carry * 10); // 0.5→5、0.6→6
  const base = Math.floor(scaled + 1e-9);
  const out = next >= threshold ? base + 1 : base;
  return (sign * out) / f;
}

/** 店铺结账抹零配置（clients.round_stage + clients.round_unit）：
 *  stage：none=不抹零（按现有逐笔舍入口径）；txn=每笔出货单合计向下抹零；day=每日出货合计向下抹零；total=全部欠款结算时向下抹零。
 *  unit：向下取整到该档（yuan=元、jiao=角、fen=分）。 */
export type RoundStage = 'none' | 'txn' | 'day' | 'total';
export type RoundUnit = 'yuan' | 'jiao' | 'fen';

export const DEFAULT_ROUND_STAGE: RoundStage = 'none';
export const DEFAULT_ROUND_UNIT: RoundUnit = 'yuan';

/** 校验店铺抹零配置，非法回退默认（配置来自旧端/手工改库时的兜底） */
export function normalizeRoundConfig(stage: unknown, unit: unknown): { stage: RoundStage; unit: RoundUnit } {
  const s = String(stage ?? '');
  const u = String(unit ?? '');
  const st: RoundStage = s === 'txn' || s === 'day' || s === 'total' ? s : 'none';
  const un: RoundUnit = u === 'jiao' || u === 'fen' ? u : 'yuan';
  return { stage: st, unit: un };
}

/** 向下取整到指定档位（负数向零取整：-12.9 元 → -12；出货侧恒正，负值仅"多付"理论边角） */
export function floorToUnit(value: number, unit: RoundUnit): number {
  const f = unit === 'yuan' ? 1 : unit === 'jiao' ? 10 : 100;
  const sign = value < 0 ? -1 : 1;
  const scaled = Math.abs(value) * f + 1e-9; // 浮点误差纠正（12.9*10=128.999…）
  return (sign * Math.floor(scaled)) / f;
}

/** 出货侧按店铺抹零配置的欠款口径：
 *  - none：保持现有「每笔 roundMoney 累加」（勿改，历史口径）；
 *  - txn：按 sale_id 分组合计后每组向下抹零（每张单合计取整）再累加；
 *  - day：按 happened_at 日期分组合计后每组向下抹零（每日总账取整）再累加；
 *  - total：全部合计一次向下抹零（结账总额取整，平时按准确金额积累）。
 *  rows 为 sale_items 行（amount 已按全局舍入口径生成）。 */
export function salesSideRounded(rows: readonly { sale_id?: string | null; client_id?: string | null; happened_at?: string | null; amount?: number | null }[], stage: RoundStage, unit: RoundUnit, money: RoundingConfig): number {
  if (stage === 'none') {
    return rows.reduce((s, x) => s + roundMoney(Number(x.amount) || 0, money), 0);
  }
  if (stage === 'total') {
    const total = rows.reduce((s, x) => s + roundMoney(Number(x.amount) || 0, money), 0);
    return floorToUnit(total, unit);
  }
  const keyOf = stage === 'txn'
    ? (x: { sale_id?: string | null }) => `s:${x.sale_id ?? ''}`
    : (x: { happened_at?: string | null }) => `d:${(x.happened_at ?? '').slice(0, 10)}`;
  const groups = new Map<string, number>();
  for (const x of rows) {
    const k = keyOf(x as never);
    // 组内按「每笔先舍入再累加」铁律累加（与 none/total 及统计/账本口径一致；勿原始 SUM 后一次 floor）
    groups.set(k, (groups.get(k) ?? 0) + roundMoney(Number(x.amount) || 0, money));
  }
  let sum = 0;
  for (const v of groups.values()) sum += floorToUnit(v, unit);
  return sum;
}

/** 全量出货行按各店抹零配置分别计算出货侧合计，再累加（多店混合统计用：
 *  /stats/overview、/stats/clients、/stats/summary（无 client_id）、/stats/category-statement）。
 *  unknownId=true 的店（配置未查到=数据库异常兜底）按 none 逐笔舍入。 */
export function salesAggByConfig(
  rows: readonly { client_id?: string | null; sale_id?: string | null; happened_at?: string | null; amount?: number | null }[],
  cfgMap: Map<string, { stage: RoundStage; unit: RoundUnit }>,
  money: RoundingConfig,
): number {
  const byClient = new Map<string, Array<{ sale_id: string | null; happened_at: string | null; amount: number }>>();
  for (const x of rows) {
    const cid = String(x.client_id ?? '');
    const arr = byClient.get(cid) ?? [];
    arr.push({ sale_id: x.sale_id ?? null, happened_at: x.happened_at ?? null, amount: Number(x.amount) || 0 });
    byClient.set(cid, arr);
  }
  let sum = 0;
  for (const [cid, arr] of byClient) {
    const cfg = cfgMap.get(cid) ?? { stage: 'none' as RoundStage, unit: 'yuan' as RoundUnit };
    sum += salesSideRounded(arr, cfg.stage, cfg.unit, money);
  }
  return sum;
}