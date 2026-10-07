import { describe, it, expect } from 'vitest';
import {
  roundMoney, getRoundingConfig, DEFAULT_ROUNDING,
  normalizeRoundConfig, floorToUnit, salesSideRounded, salesAggByConfig,
} from '../src/lib/money';

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

describe('money 店铺结账抹零 helper（round_stage/round_unit）', () => {
  const M = { carry: 0.5, digits: 2 };

  it('normalizeRoundConfig：合法档位保留、非法/缺省回退默认', () => {
    expect(normalizeRoundConfig('day', 'yuan')).toEqual({ stage: 'day', unit: 'yuan' });
    expect(normalizeRoundConfig('txn', 'jiao')).toEqual({ stage: 'txn', unit: 'jiao' });
    expect(normalizeRoundConfig('total', 'fen')).toEqual({ stage: 'total', unit: 'fen' });
    expect(normalizeRoundConfig('bogus', 'bogus')).toEqual({ stage: 'none', unit: 'yuan' });
    expect(normalizeRoundConfig(null, undefined)).toEqual({ stage: 'none', unit: 'yuan' });
  });

  it('floorToUnit：元/角/分向下取整，负数向零取整', () => {
    expect(floorToUnit(12.9, 'yuan')).toBe(12);
    expect(floorToUnit(12.99, 'jiao')).toBe(12.9);
    expect(floorToUnit(12.999, 'fen')).toBe(12.99);
    expect(floorToUnit(-12.9, 'yuan')).toBe(-12); // 向零取整（出货侧恒正，负值仅"多付"理论边角）
  });

  it('salesSideRounded：none=逐笔舍入累加不取整（历史口径不变）', () => {
    const rows = [
      { sale_id: 'a', happened_at: '2026-10-01', amount: 6.45 },
      { sale_id: 'a', happened_at: '2026-10-01', amount: 6.45 },
      { sale_id: 'b', happened_at: '2026-10-02', amount: 3 },
    ];
    expect(salesSideRounded(rows, 'none', 'yuan', M)).toBe(15.9);
  });

  it('salesSideRounded：txn=每张出货单合计向下取整再累加', () => {
    const rows = [
      { sale_id: 'a', happened_at: '2026-10-01', amount: 6.45 },
      { sale_id: 'a', happened_at: '2026-10-01', amount: 6.45 },
      { sale_id: 'b', happened_at: '2026-10-01', amount: 3.5 },
    ];
    // 单 a 合计 12.9 → 12；单 b 3.5 → 3；合计 15
    expect(salesSideRounded(rows, 'txn', 'yuan', M)).toBe(15);
  });

  it('salesSideRounded：day=每日出货合计向下取整（用户 12.9→12 语义）', () => {
    const rows = [
      { sale_id: 'a', happened_at: '2026-10-01', amount: 6.45 },
      { sale_id: 'b', happened_at: '2026-10-01', amount: 6.45 },
      { sale_id: 'c', happened_at: '2026-10-02', amount: 8.7 },
    ];
    // 10-01 合计 12.9 → 12；10-02 8.7 → 8；合计 20
    expect(salesSideRounded(rows, 'day', 'yuan', M)).toBe(20);
  });

  it('salesSideRounded：day 组内每笔先舍入再累加（勿原始 SUM 后 floor）', () => {
    // digits=0（元口径）：0.96 每笔先舍入=1 → 日合计 2 → floor 2；原始 SUM 1.92 → floor 1
    const M0 = { carry: 0.5, digits: 0 };
    const rows = [
      { sale_id: 'a', happened_at: '2026-10-01', amount: 0.96 },
      { sale_id: 'b', happened_at: '2026-10-01', amount: 0.96 },
    ];
    expect(salesSideRounded(rows, 'day', 'yuan', M0)).toBe(2);
  });

  it('salesSideRounded：total=全部合计一次向下取整', () => {
    const rows = [
      { sale_id: 'a', happened_at: '2026-10-01', amount: 6.45 },
      { sale_id: 'b', happened_at: '2026-10-02', amount: 9.5 },
    ];
    expect(salesSideRounded(rows, 'total', 'yuan', M)).toBe(15); // 15.95 → 15
  });

  it('salesAggByConfig：多店按各自配置分别算再累加（查不到配置的店按 none）', () => {
    const rows = [
      { client_id: 'c1', sale_id: 'a', happened_at: '2026-10-01', amount: 12.9 },
      { client_id: 'c2', sale_id: 'b', happened_at: '2026-10-01', amount: 12.9 },
    ];
    const cfgMap = new Map([['c1', { stage: 'day', unit: 'yuan' }]]);
    // c1: 12.9→12；c2 无配置 none=12.9；合计 24.9
    expect(salesAggByConfig(rows, cfgMap, M)).toBe(24.9);
  });
});