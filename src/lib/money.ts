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