/**
 * 对账差额 → 原始数据 + 算术校验：确定性枚举、方向事实、真实单价表。
 * 重点锁死用户场景「对方比我多 10 元 → 5 块 × 2 元豆腐 = 10 元」，
 * 以及「候选不是实际单据、差额不能变成补录金额」这两条护栏。
 */
import { describe, expect, it } from 'vitest';
import {
  extractDiffAmount, extractDiffSide, findDiffHints, formatDiffHints, formatPriceTable,
  loadClientUnitPrices, type UnitPrice,
} from '../src/lib/diff-hints';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { createFakeD1 } from './helpers/fake-d1';

function price(name: string, priceCents: number, patch: Partial<UnitPrice> = {}): UnitPrice {
  return {
    name, unit: '块', priceCents, source: '该店历史成交价',
    freq: 1, typicalQtys: [], ...patch,
  };
}

describe('差额与方向抽取', () => {
  it('从「对方比我多了 10 元」抽出 10，且不被后面的「5 块单价 2 元」干扰', () => {
    expect(extractDiffAmount('对方比我多了10元，是不是 5 块单价 2 元的豆腐')).toBe(10);
    expect(extractDiffAmount('某店对不上账，差 380 元')).toBe(380);
    expect(extractDiffAmount('对不上 1,200.5')).toBe(1200.5);
    expect(extractDiffAmount('今天卖了多少')).toBeNull();
  });

  it('方向：对方多 → 查我方漏记；我方多 / 对方少 → 查重复登记', () => {
    expect(extractDiffSide('对方比我多了 10 元')).toBe('theirs_more');
    expect(extractDiffSide('对我比我多了10元')).toBe('theirs_more');
    expect(extractDiffSide('对方账上比我多 10 元')).toBe('theirs_more');
    expect(extractDiffSide('我比对方多 10 元')).toBe('ours_more');
    expect(extractDiffSide('对方少了 10 元')).toBe('ours_more');
    expect(extractDiffSide('差 10 元')).toBeNull();
  });
});

describe('findDiffHints 确定性组合', () => {
  it('单商品精确解：5 块 × 2 元豆腐 = 10 元排第一', () => {
    const hints = findDiffHints(10, [price('豆腐', 200, { freq: 12, typicalQtys: [5, 10] })]);
    expect(hints.length).toBeGreaterThan(0);
    expect(hints[0].totalCents).toBe(1000);
    expect(hints[0].gapCents).toBe(0);
    expect(hints[0].parts).toHaveLength(1);
    expect(hints[0].parts[0]).toMatchObject({ name: '豆腐', qty: 5, priceCents: 200, subtotalCents: 1000 });
    const text = formatDiffHints(10, hints, 'theirs_more').join('\n');
    expect(text).toContain('豆腐 5 块 × 2.00 元 = 10.00 元');
    expect(text).toContain('本店按此单价出过 12 次');
    expect(text).toContain('不是标准答案');
  });

  it('同差额多种商品时，本店常卖的排前面', () => {
    const hints = findDiffHints(10, [
      price('白菜', 200, { freq: 1, unit: '斤', source: '通用价目表' }),
      price('豆腐', 200, { freq: 20, typicalQtys: [5] }),
    ]);
    expect(hints[0].parts).toHaveLength(1);
    expect(hints[0].parts[0].name).toBe('豆腐');
    expect(hints[0].score).toBeLessThan(hints.find((h) => h.parts[0].name === '白菜')!.score);
  });

  it('支持 0.5 步进数量（1.5 斤 × 2 元 = 3 元）', () => {
    const hints = findDiffHints(3, [price('豆腐', 200, { unit: '斤' })]);
    expect(hints.some((h) => h.parts.length === 1 && h.parts[0].qty === 1.5)).toBe(true);
  });

  it('两种商品叠加也能凑出差额', () => {
    const hints = findDiffHints(10, [price('豆腐', 200), price('萝卜', 300, { unit: '斤' })], { maxResults: 20 });
    expect(hints.some((h) => h.parts.length === 2 && h.totalCents === 1000)).toBe(true);
    expect(hints[0].parts).toHaveLength(1);
  });

  it('精确凑不出时给抹零近似，并显式标注差值', () => {
    const hints = findDiffHints(10, [price('豆腐', 300)]);
    expect(hints.length).toBeGreaterThan(0);
    expect(hints.every((h) => h.gapCents > 0)).toBe(true);
    expect(formatDiffHints(10, hints, null).join('\n')).toContain('可能抹零/舍入');
  });

  it('formatPriceTable 把原始单价交给模型推理，并标注来源与常见数量', () => {
    const text = formatPriceTable([
      price('豆腐', 200, { freq: 12, typicalQtys: [5] }),
      price('白菜', 300, { unit: '斤', source: '通用价目表', freq: 0 }),
    ]).join('\n');
    expect(text).toContain('可用单价表');
    expect(text).toContain('豆腐 / 块 / 2.00 元');
    expect(text).toContain('该店出过 12 次，常见数量 5');
    expect(text).toContain('白菜 / 斤 / 3.00 元（通用价目表）');
    expect(formatPriceTable([]).join('\n')).toContain('暂无商品单价数据');
  });

  it('差额为 0 / 无单价时不生成任何候选', () => {
    expect(findDiffHints(0, [price('豆腐', 200)])).toEqual([]);
    expect(findDiffHints(10, [])).toEqual([]);
    expect(formatDiffHints(10, [], null).join('\n')).toContain('凑不出这个数额');
  });

  it('格式化文本明确「只是线索、不自动补单」，并按方向给出核对建议', () => {
    const hints = findDiffHints(10, [price('豆腐', 200)]);
    const text = formatDiffHints(10, hints, 'theirs_more').join('\n');
    expect(text).toContain('不是账本里已发生的单据');
    expect(text).toContain('不要据此自动补单或把差额当作应收金额');
    expect(text).toContain('用户说「对方账比我们多 10.00 元」');
    expect(formatDiffHints(10, hints, 'ours_more').join('\n')).toContain('用户说「我们账比对方多 10.00 元」');
    expect(formatDiffHints(10, hints, null).join('\n')).toContain('用户未说明谁比谁多');
  });
});

describe('loadClientUnitPrices 真实单价来源', () => {
  it('该店历史成交价优先，未卖过的商品由通用价目表补位', async () => {
    resetSchemaState();
    const db = await createFakeD1();
    await ensureSchema(db as never);
    await db.prepare("INSERT INTO items (id, name) VALUES ('i1','豆腐'),('i2','白菜')").run();
    await db.prepare("INSERT INTO clients (id, name) VALUES ('c1','A店')").run();
    await db.prepare("INSERT INTO item_prices (id, item_id, unit, purchase_price, sale_price) VALUES ('ip1','i1','块',1,2),('ip2','i2','斤',1,3)").run();
    await db.prepare(
      "INSERT INTO sale_items (id, sale_id, client_id, item_id, unit, quantity, sale_price, cost_price, amount, happened_at) VALUES ('s1','sale1','c1','i1','块',5,2,1,10,'2026-11-08')",
    ).run();

    const prices = await loadClientUnitPrices(db as never, 'c1');
    expect(prices[0]).toMatchObject({
      name: '豆腐', unit: '块', priceCents: 200, source: '该店历史成交价', freq: 1,
    });
    expect(prices[0].typicalQtys).toContain(5);
    expect(prices.some((p) => p.name === '白菜' && p.priceCents === 300 && p.source === '通用价目表')).toBe(true);
    expect(prices.some((p) => p.name === '豆腐' && p.source === '通用价目表')).toBe(false);
    // 没说店名时退化为全库口径，仍取得到价目表里的单价
    const all = await loadClientUnitPrices(db as never, null);
    expect(all.some((p) => p.name === '白菜' && p.priceCents === 300)).toBe(true);
    expect(all.some((p) => p.name === '豆腐' && p.priceCents === 200)).toBe(true);
  });
});
