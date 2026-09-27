/** AI 识别服务测试：草稿容错解析（多种 LLM 输出变体）+ 提示词构造 */
import { describe, expect, it } from 'vitest';
import { buildAiPrompt, normalizeDrafts, normalizeInvoice } from '../src/services/ai-parse';

describe('normalizeDrafts', () => {
  it('标准 JSON items', () => {
    const drafts = normalizeDrafts('{"items":[{"name":"白菜","unit":"斤","quantity":20,"price":2.5},{"name":"土豆","unit":"袋","quantity":3,"price":15}]}');
    expect(drafts).toEqual([
      { name: '白菜', unit: '斤', quantity: 20, price: 2.5 },
      { name: '土豆', unit: '袋', quantity: 3, price: 15 },
    ]);
  });

  it('Markdown 代码块围栏', () => {
    const drafts = normalizeDrafts('```json\n{"items":[{"name":"姜","quantity":2,"price":12} ]}\n```');
    expect(drafts[0].name).toBe('姜');
    expect(drafts[0].quantity).toBe(2);
  });

  it('顶层数组', () => {
    const drafts = normalizeDrafts('[{"name":"黄瓜","unit":"斤","quantity":5,"price":3}]');
    expect(drafts).toHaveLength(1);
    expect(drafts[0].name).toBe('黄瓜');
  });

  it('中文中文字段名', () => {
    const drafts = normalizeDrafts('{"items":[{"名称":"西红柿","单位":"斤","数量":"10","单价":3.5}]}');
    expect(drafts[0]).toEqual({ name: '西红柿', unit: '斤', quantity: 10, price: 3.5 });
  });

  it('数量带单位文本（"10斤"→10）', () => {
    const drafts = normalizeDrafts('{"items":[{"name":"葱","unit":"斤","quantity":"10斤","price":2}]}');
    expect(drafts[0].quantity).toBe(10);
  });

  it('模糊内容提取（含前言后记）', () => {
    const drafts = normalizeDrafts('好的，识别结果如下：{"items":[{"name":"香菇","quantity":4,"price":9}]} 以上是全部。');
    expect(drafts[0].name).toBe('香菇');
    expect(drafts[0].quantity).toBe(4);
  });

  it('空结果与非法输入', () => {
    expect(normalizeDrafts('')).toEqual([]);
    expect(normalizeDrafts('{"items":[]}')).toEqual([]);
    expect(normalizeDrafts('完全不是 JSON')).toEqual([]);
  });

  it('缺名称的项被过滤', () => {
    const drafts = normalizeDrafts('{"items":[{"name":"","quantity":1},{"name":"豆皮","quantity":2}]}');
    expect(drafts).toHaveLength(1);
    expect(drafts[0].name).toBe('豆皮');
  });
});

describe('normalizeInvoice', () => {
  it('解析单据级购货单位与日期 + 明细', () => {
    const inv = normalizeInvoice('{"client":"老王菜行","date":"2026-08-15","items":[{"name":"白菜","unit":"斤","quantity":20,"price":2.5}]}');
    expect(inv.client).toBe('老王菜行');
    expect(inv.date).toBe('2026-08-15');
    expect(inv.items).toEqual([{ name: '白菜', unit: '斤', quantity: 20, price: 2.5 }]);
  });

  it('中文字段名购货单位/日期', () => {
    const inv = normalizeInvoice('{"购货单位":"好再来超市","日期":"2026.8.3","items":[{"名称":"土豆","数量":"10","单价":3}]}');
    expect(inv.client).toBe('好再来超市');
    expect(inv.date).toBe('2026.8.3');
    expect(inv.items[0].name).toBe('土豆');
  });

  it('无单位/日期时为空串，模糊内容仍可提取', () => {
    const inv = normalizeInvoice('好的，识别结果：{"items":[{"name":"香菇","quantity":4,"price":9}]} done');
    expect(inv.client).toBe('');
    expect(inv.date).toBe('');
    expect(inv.items).toHaveLength(1);
  });

  it('空结果返回空对象', () => {
    expect(normalizeInvoice('')).toEqual({ client: '', date: '', items: [] });
    expect(normalizeInvoice('{"items":[]}')).toEqual({ client: '', date: '', items: [] });
  });
});

describe('buildAiPrompt', () => {
  it('按用途提示进价/售价', () => {
    expect(buildAiPrompt('purchase')).toContain('进货单价');
    expect(buildAiPrompt('sale')).toContain('出货单价');
  });
});