/// 业务日期（东八区日历日），与后端 src/lib/biz-date.ts 口径一致。
///
/// happened_at 存的是「业务日历日」字符串而不是时间戳。设备本地时区在
/// 海外或时区设置错误时会把单据写到昨天，故统一按 UTC+8 取日历日。
const int bizUtcOffsetMinutes = 8 * 60;

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// 业务时区的今天（YYYY-MM-DD）
String bizTodayISO([DateTime? now]) {
  final d = (now ?? DateTime.now())
      .toUtc()
      .add(const Duration(minutes: bizUtcOffsetMinutes));
  return _ymd(d);
}

/// 业务日历日 ±N 天
String bizAddDaysISO(String day, int days) {
  final d = DateTime.tryParse('${day}T00:00:00Z');
  if (d == null) return day;
  return _ymd(d.add(Duration(days: days)));
}
