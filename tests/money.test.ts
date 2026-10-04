import { describe, it, expect } from 'vitest';
import { roundMoney, getRoundingConfig, DEFAULT_ROUNDING } from '../src/lib/money';

describe('money.roundMoney（进位临界 + 精度）', () => {
  it('默认四舍五入 2 位（分）', () => {
    expect(roundMoney(1.234, { carry: 0.5, digits: 2 })).toBe(1.23);
    expect(roundMoney(1.235, { carry: 0.5, digits: 2 })).toBe(1.24);
    expect(roundMoney(1.245, { carry: 0.5, digits: 2 })).toBe(1.25); // 浮点边界
    expect(roundMoney(2.675, { carry: 0.5, digits: 2 })).toBe(2.68); // 经典浮点陷阱
  });

  it('5舍6入（carry=0.6）：尾数 5 舍去、6 及以上进位', () => {
    const cfg = { carry: 0.6, digits: 2 };
    expect(roundMoney(1.235, cfg)).toBe(1.23); // 5 舍
    expect(roundMoney(1.236, cfg)).toBe(1.24); // 6 入
    expect(roundMoney(1.239, cfg)).toBe(1.24);
    expect(roundMoney(1.234, cfg)).toBe(1.23);
  });

  it('精度三档：元(0)/角(1)/分(2)', () => {
    expect(roundMoney(1.45, { carry: 0.5, digits: 0 })).toBe(1); // 元：0.45<0.5 舍
    expect(roundMoney(1.55, { carry: 0.5, digits: 0 })).toBe(2);
    expect(roundMoney(1.45, { carry: 0.5, digits: 1 })).toBe(1.5); // 角
    expect(roundMoney(1.45, { carry: 0.5, digits: 2 })).toBe(1.45); // 分
  });

  it('负数对称（毛利可为负）', () => {
    expect(roundMoney(-1.235, { carry: 0.5, digits: 2 })).toBe(-1.24);
    expect(roundMoney(-1.234, { carry: 0.5, digits: 2 })).toBe(-1.23);
  });

  it('整数/零不动', () => {
    expect(roundMoney(0, { carry: 0.5, digits: 2 })).toBe(0);
    expect(roundMoney(5, { carry: 0.5, digits: 2 })).toBe(5);
  });
});

describe('money.getRoundingConfig（settings 表读取）', () => {
  it('无配置返回默认（四舍五入 2 位）', async () => {
    const rows: { key: string; value: string }[] = [];
    const db = {
      prepare: () => ({
        bind: () => ({
          all: async () => ({ results: rows }),
        }),
      }),
    } as unknown as D1Database;
    expect(await getRoundingConfig(db)).toEqual(DEFAULT_ROUNDING);
  });

  it('读取已存配置', async () => {
    let boundKeys: string[] = [];
    const db = {
      prepare: () => ({
        bind: (...args: string[]) => {
          boundKeys = args;
          return {
            all: async () => ({ results: [{ key: 'round_carry', value: '0.6' }, { key: 'round_digits', value: '1' }] }),
          };
        },
      }),
    } as unknown as D1Database;
    expect(await getRoundingConfig(db)).toEqual({ carry: 0.6, digits: 1 });
    expect(boundKeys).toContain('round_carry');
    expect(boundKeys).toContain('round_digits');
  });

  it('非法值回退默认', async () => {
    const db = {
      prepare: () => ({
        bind: () => ({
          all: async () => ({ results: [{ key: 'round_carry', value: '9' }, { key: 'round_digits', value: '7' }] }),
        }),
      }),
    } as unknown as D1Database;
    expect(await getRoundingConfig(db)).toEqual(DEFAULT_ROUNDING);
  });
});