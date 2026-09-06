/** 通用工具 */

/** 今天（本地时区）的 YYYY-MM-DD —— 记单默认日期必须按本地，不能用 UTC 截断（北京时间 0-8 点会显示成昨天） */
export function todayLocal(): string {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}