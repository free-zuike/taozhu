/// 对账单合计（纯计算、零依赖，可单测）：
/// perRound=true（默认）=每笔先按当前舍入口径（round 回调）舍入再累加——合计与单笔金额
/// 对账一致（digits=0/1 时原始浮点累加后 2 位会与每笔显示对不上，1.6+1.6 单显 ¥2+¥2 合计却 ¥3）；
/// perRound=false=原始浮点累加（对账单按 2 位导出的旧口径）。
/// 页面调用传 round: Money.round；测试可传 roundMoney(v, carry, digits) 构造任意口径。
library;

/// 出货合计：仅统计明细行日期在 [from,to] 内的行；行日期缺省回退单据日期。
double saleTotalOf(
  List<Map<String, dynamic>> sales,
  String from,
  String to, {
  required bool perRound,
  required double Function(double) round,
}) {
  var t = 0.0;
  for (final s in sales) {
    final orderDate = _dateOf(s['happened_at']);
    for (final it in ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>()) {
      final id = '${it['happened_at'] ?? ''}';
      final d = id.length >= 10 ? id.substring(0, 10) : orderDate;
      if (d.compareTo(from) >= 0 && d.compareTo(to) <= 0) {
        final v = (it['amount'] as num?)?.toDouble() ?? 0;
        t += perRound ? round(v) : v;
      }
    }
  }
  return t;
}

/// 收款/减免合计：key=amount（实收）| waived（减免）。
double payTotalOf(
  List<Map<String, dynamic>> payments,
  String key, {
  required bool perRound,
  required double Function(double) round,
}) {
  var t = 0.0;
  for (final p in payments) {
    final v = (p[key] as num?)?.toDouble() ?? 0;
    t += perRound ? round(v) : v;
  }
  return t;
}

String _dateOf(Object? v) {
  final s = '$v';
  return s.length >= 10 ? s.substring(0, 10) : s;
}
