/// 对账单合计口径单测：perRound=true=每笔先舍入再累加（与单笔金额对账一致）；
/// perRound=false=原始浮点累加（2 位导出口径）。
/// 纯计算零依赖：round 回调注入 roundMoney(v, carry, digits) 任意口径。
import 'package:flutter_test/flutter_test.dart';
import 'package:taozhu_app/utils/money.dart' show roundMoney;
import 'package:taozhu_app/utils/statement_totals.dart';

void main() {
  // digits=0（元整数位）：两笔 1.6 单笔显示各 ¥2，逐笔舍入合计必须 ¥4，原始累加=3.2→¥3 对不上
  final round0 = (double v) => roundMoney(v, 0.5, 0);

  final sales = <Map<String, dynamic>>[
    {
      'happened_at': '2026-09-05',
      'items': [
        {'happened_at': '2026-09-05', 'amount': 1.6},
        {'happened_at': '2026-09-05', 'amount': 1.6},
      ],
    },
    // 行日期缺省回退单据日期
    {
      'happened_at': '2026-09-06',
      'items': [
        {'amount': 2.0},
      ],
    },
  ];

  test('出货合计=每笔舍入后累加（与单笔显示对账一致）', () {
    expect(saleTotalOf(sales, '2026-09-05', '2026-09-05', perRound: true, round: round0), 4);
  });

  test('出货合计=原始浮点累加（不纳入模式）', () {
    expect(
      saleTotalOf(sales, '2026-09-05', '2026-09-05', perRound: false, round: round0),
      closeTo(3.2, 1e-9),
    );
  });

  test('区间过滤：账期外的行不计入；行日期缺省回退单据日期', () {
    expect(saleTotalOf(sales, '2026-09-06', '2026-09-30', perRound: true, round: round0), 2);
  });

  test('收款合计/减免合计', () {
    final pays = <Map<String, dynamic>>[
      {'amount': 1.6, 'waived': 0},
      {'amount': 1.6, 'waived': 0.4},
    ];
    expect(payTotalOf(pays, 'amount', perRound: true, round: round0), 4);
    expect(payTotalOf(pays, 'waived', perRound: true, round: round0), 0); // 0.4 → 元整数位 → 0
    expect(
      payTotalOf(pays, 'amount', perRound: false, round: round0),
      closeTo(3.2, 1e-9),
    );
  });

  test('空数据合计为 0', () {
    expect(saleTotalOf(const [], '2026-09-01', '2026-09-30', perRound: true, round: round0), 0);
    expect(payTotalOf(const [], 'amount', perRound: true, round: round0), 0);
  });
}
