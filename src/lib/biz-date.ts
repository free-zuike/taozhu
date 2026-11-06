/**
 * 业务日期（东八区日历日）。
 *
 * DB 里 happened_at 存的是「业务日历日」字符串（YYYY-MM-DD，历史/导入数据也可能带
 * 时分秒：YYYY-MM-DD HH:mm:ss 或 ISO YYYY-MM-DDTHH:mm:ss），不是时间戳。因此所有
 * 「今天 / 月初 / 月末 / 相对月份」都必须按业务时区取日历日，不能用 UTC 的
 * toISOString().slice(0, 10)：北京时间 00:00–08:00 时 UTC 仍是前一天，跨月时
 * 会把 1 日凌晨的单算进上个月，AI 问「某个月」就会整月错位。
 */
export const BIZ_UTC_OFFSET_MIN = 8 * 60;

/** 业务时区的今天（YYYY-MM-DD） */
export function localTodayISO(now: Date = new Date()): string {
  return new Date(now.getTime() + BIZ_UTC_OFFSET_MIN * 60_000).toISOString().slice(0, 10);
}

/**
 * 纯日历次日（YYYY-MM-DD），用 UTC 构造避免运行环境时区二次偏移。
 * 非法输入原样返回，避免 AI/前端传来的脏日期打断整段回答。
 */
export function nextDayISO(day: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day);
  if (!m) return day;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

/**
 * 日期区间上界一律用开区间 `happened_at < nextDay(end)`，不要用 `<= end`：
 * 字符串比较下 '2026-10-31 08:00:00' > '2026-10-31'，闭区间会漏掉区间最后一天
 * 所有带时分秒的单；开区间对纯日期与带时分秒两种格式都正确，且仍能走日期索引。
 */
export function dayRangeEnd(end: string): string {
  return nextDayISO(end);
}

/**
 * 确定性解析「某个月」的整月起止日，不让 LLM 自己算月末天数。
 *
 * 之前 start/end 全靠意图模型换算，实测会把「10月」写成 10-01~10-30、
 * 把「上个月」按 UTC 今天算错整月；后端按业务时区算一次即可根治。
 * 支持：2026年10月 / 10月 / 去年10月 / 上个月 / 本月 / 去年 / 今年。
 */
export function parseMonthRange(
  text: string,
  today: string = localTodayISO(),
): { start: string; end: string } | null {
  const t = text.replace(/\s+/g, '');
  const thisYear = Number(today.slice(0, 4));
  const thisMonth = Number(today.slice(5, 7));
  const isLastYear = /去年/.test(t);
  const relPrev = /上个月|上月|前一个月/.test(t);
  const relThis = /这个月|本月|当月/.test(t);
  const num = /(\d{4})年(\d{1,2})月|(\d{1,2})月/.exec(t);
  const fullYear = /全年|整年|这一年/.test(t);

  const wholeYear = (y: number) => ({ start: `${y}-01-01`, end: `${y}-12-31` });
  if (fullYear && !num) return wholeYear(isLastYear ? thisYear - 1 : thisYear);

  let year = thisYear;
  let month = thisMonth;
  if (relPrev) {
    month -= 1;
  } else if (num) {
    year = num[1] ? Number(num[1]) : (isLastYear ? thisYear - 1 : thisYear);
    month = Number(num[2] ?? num[3]);
  } else if (isLastYear) {
    return wholeYear(thisYear - 1); // 「去年」单独出现 → 去年全年
  } else if (!relThis) {
    return null;
  }
  while (month < 1) { month += 12; year -= 1; }
  while (month > 12) { month -= 12; year += 1; }
  const mm = String(month).padStart(2, '0');
  const lastDay = new Date(Date.UTC(year, month, 0)).getUTCDate();
  return { start: `${year}-${mm}-01`, end: `${year}-${mm}-${String(lastDay).padStart(2, '0')}` };
}
