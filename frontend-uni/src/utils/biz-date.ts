/**
 * 业务日期（东八区日历日），与后端 src/lib/biz-date.ts 口径一致。
 *
 * happened_at 存的是「业务日历日」字符串而不是时间戳，不能用 UTC 的
 * toISOString().slice(0, 10)：北京时间 00:00–08:00 时 UTC 仍是前一天，
 * 小程序直接提交默认日期会把单写到昨天（跨月时整月错位）。
 */
export const BIZ_UTC_OFFSET_MIN = 8 * 60;

/** 业务时区的今天（YYYY-MM-DD） */
export function localTodayISO(now: Date = new Date()): string {
  return new Date(now.getTime() + BIZ_UTC_OFFSET_MIN * 60_000).toISOString().slice(0, 10);
}

/** 业务日历日 ±N 天，区间一律用开区间上界（< 次日），不要用 <= 当日 */
export function addDaysISO(day: string, days: number): string {
  const d = new Date(`${day}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return day;
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}
