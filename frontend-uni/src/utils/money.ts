/**
 * 金额舍入口径（与服务器 /settings/rounding 一致）：carry 进位临界（0.5=四舍五入、
 * 0.6=5舍6入，可自定义 0~1）+ digits 精度（0=元/1=角/2=分，默认 2）。
 * 展示层/本地预览按口径换算；服务器为最终权威（后端计算同口径）。
 */
import { request } from '../api';

export type RoundingCfg = { carry: number; digits: number };

const KEY = 'taozhu_rounding';
const DEFAULT: RoundingCfg = { carry: 0.5, digits: 2 };

let cached: RoundingCfg | null = null;

/** 读取本地缓存（页面计算用，无网络；启动时已由 initRounding 填充） */
export function roundingCfg(): RoundingCfg {
  if (cached) return cached;
  try {
    const raw = uni.getStorageSync(KEY) as string;
    if (raw) cached = JSON.parse(raw) as RoundingCfg;
  } catch (_) {}
  return cached || { ...DEFAULT };
}

/** 初始化：读缓存 + 后台拉服务器（登录后/页面 onShow 调用一次） */
export async function initRounding() {
  try {
    const d = await request<RoundingCfg>('/settings/rounding', 'GET');
    const carry = Number(d?.carry);
    const digits = Number(d?.digits);
    if (carry > 0 && carry <= 1 && [0, 1, 2].includes(digits)) {
      cached = { carry, digits };
      try { uni.setStorageSync(KEY, JSON.stringify(cached)); } catch (_) {}
    }
  } catch (_) {}
}

/** 保存成功后同步写本地口径（不依赖网络回读——网络抖动失败也会静默，导致重进读旧缓存） */
export function applyRounding(carry: number, digits: number) {
  if (!(carry > 0 && carry <= 1) || ![0, 1, 2].includes(digits)) return;
  cached = { carry, digits };
  try { uni.setStorageSync(KEY, JSON.stringify(cached)); } catch (_) {}
}

/** 按配置舍入金额（进位临界 + 精度）；负数对称 */
export function roundMoney(value: number, carry: number, digits: number): number {
  const f = Math.pow(10, digits);
  const sign = value < 0 ? -1 : 1;
  const abs = Math.abs(value);
  const scaled = abs * f;
  const next = Math.floor(scaled * 10 + 1e-9) % 10;
  const threshold = Math.round(carry * 10);
  const base = Math.floor(scaled + 1e-9);
  const out = next >= threshold ? base + 1 : base;
  return (sign * out) / f;
}

/** 当前口径舍入 */
export function roundAmount(v: number): number {
  const c = roundingCfg();
  return roundMoney(v, c.carry, c.digits);
}

/** 按当前口径格式化显示金额（保留该档位数小数，如分=2 位） */
export function fmtAmount(v: number): string {
  const c = roundingCfg();
  return roundMoney(v, c.carry, c.digits).toFixed(c.digits);
}

/** 单价/进价显示：原始值最多 2 位去尾零（不进位、不跟随舍入位数——价格是输入值，2.58 不能显示成 2.6） */
export function fmtPrice(v: number): string {
  let t = v.toFixed(2);
  if (t.includes('.')) {
    t = t.replace(/0+$/, '').replace(/\.$/, '');
  }
  return t;
}