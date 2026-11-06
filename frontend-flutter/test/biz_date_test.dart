import 'package:flutter_test/flutter_test.dart';
import 'package:taozhu_app/utils/biz_date.dart';

void main() {
  group('业务日历日（UTC+8）', () {
    test('UTC 16:00 之后算次日，跨月跨年不落到上个月', () {
      expect(bizTodayISO(DateTime.utc(2026, 10, 31, 16, 30)), '2026-11-01');
      expect(bizTodayISO(DateTime.utc(2026, 12, 31, 17, 0)), '2027-01-01');
      expect(bizTodayISO(DateTime.utc(2026, 11, 6, 2, 0)), '2026-11-06');
    });

    test('相对业务日 ±N 天跨月跨年；非法输入原样返回', () {
      expect(bizAddDaysISO('2026-11-01', -1), '2026-10-31');
      expect(bizAddDaysISO('2026-01-01', -1), '2025-12-31');
      expect(bizAddDaysISO('2026-11-06', -30), '2026-10-07');
      expect(bizAddDaysISO('garbage', 7), 'garbage');
    });
  });
}
