/** AI 识别服务测试：草稿容错解析（多种 LLM 输出变体）+ 提示词构造 */
import { describe, expect, it } from 'vitest';
import { buildAiPrompt, normalizeDrafts } from '../src/services/ai-parse';

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

describe('buildAiPrompt', () => {
  it('按用途提示进价/售价', () => {
    expect(buildAiPrompt('purchase')).toContain('进货单价');
    expect(buildAiPrompt('sale')).toContain('出货单价');
  });
});