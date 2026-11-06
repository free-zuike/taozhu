/**
 * 业务日期（东八区）+ 日期区间开区间上界：AI 问「某个月」时日期口径的护栏。
 */
import { describe, expect, it } from 'vitest';
import { localTodayISO, addDaysISO, nextDayISO, dayRangeEnd, parseMonthRange } from '../src/lib/biz-date';

describe('业务日期（东八区日历日）', () => {
  it('UTC 16:00 之后算次日，跨月/跨年不落到上个月', () => {
    expect(localTodayISO(new Date('2026-10-31T16:30:00Z'))).toBe('2026-11-01');
    expect(localTodayISO(new Date('2026-12-31T17:00:00Z'))).toBe('2027-01-01');
    expect(localTodayISO(new Date('2026-11-06T02:00:00Z'))).toBe('2026-11-06');
  });

  it('次日：月末 / 年末 / 闰年', () => {
    expect(nextDayISO('2026-10-31')).toBe('2026-11-01');
    expect(nextDayISO('2026-12-31')).toBe('2027-01-01');
    expect(nextDayISO('2028-02-28')).toBe('2028-02-29');
    expect(nextDayISO('2026-02-28')).toBe('2026-03-01');
  });

  it('非法日期原样返回，不抛错打断 AI 回答', () => {
    expect(nextDayISO('garbage')).toBe('garbage');
    expect(nextDayISO('')).toBe('');
  });

  it('相对业务日 ±N 天：跨月/跨年；临期提醒与近 30 天窗口都按业务日算', () => {
    expect(addDaysISO('2026-11-01', -1)).toBe('2026-10-31');
    expect(addDaysISO('2026-10-31', 1)).toBe('2026-11-01');
    expect(addDaysISO('2026-01-01', -1)).toBe('2025-12-31');
    expect(addDaysISO('2026-11-06', -30)).toBe('2026-10-07');
    expect(addDaysISO('2026-11-06', 7)).toBe('2026-11-13');
    expect(addDaysISO('garbage', 7)).toBe('garbage');
  });

  it('开区间上界同时覆盖纯日期与带时分秒，并排除次日', () => {
    const ex = dayRangeEnd('2026-10-31');
    expect(ex).toBe('2026-11-01');
    expect('2026-10-31' < ex).toBe(true);
    expect('2026-10-31 08:20:00' < ex).toBe(true);
    expect('2026-10-31T23:59:59' < ex).toBe(true);
    expect('2026-11-01' < ex).toBe(false);
    expect('2026-11-01 00:00:00' < ex).toBe(false);
    // 旧闭区间 `<= '2026-10-31'` 会漏掉这两行（字符串比较更长者更大）
    expect('2026-10-31 08:20:00' <= '2026-10-31').toBe(false);
  });

  it('parseMonthRange：整月起止按真实天数，不让模型把 10 月算成 30 天', () => {
    const today = '2026-11-06';
    expect(parseMonthRange('10月的账一共多少', today)).toEqual({ start: '2026-10-01', end: '2026-10-31' });
    expect(parseMonthRange('2026年2月', today)).toEqual({ start: '2026-02-01', end: '2026-02-28' });
    expect(parseMonthRange('2024年2月', today)).toEqual({ start: '2024-02-01', end: '2024-02-29' });
    expect(parseMonthRange('上个月', today)).toEqual({ start: '2026-10-01', end: '2026-10-31' });
    // 北京时间 1 月 5 日：「上个月」必须跨年回退，而不是落到本年 0 月
    expect(parseMonthRange('上个月', '2026-01-05')).toEqual({ start: '2025-12-01', end: '2025-12-31' });
    expect(parseMonthRange('本月', today)).toEqual({ start: '2026-11-01', end: '2026-11-30' });
    expect(parseMonthRange('去年10月', today)).toEqual({ start: '2025-10-01', end: '2025-10-31' });
    expect(parseMonthRange('去年', today)).toEqual({ start: '2025-01-01', end: '2025-12-31' });
    expect(parseMonthRange('今天卖了多少', today)).toBeNull();
  });
});
