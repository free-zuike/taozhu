/// 本地 FIFO 批次派生（离线成本估值，与服务器 consumeLossStatements / sale_page 离线成本同口径）：
/// 进货建批 → 出货/报损按时间序消耗；再按同样顺序消耗本次要扣的数量。
/// 仅用于离线报损/盘亏的金额估值；联网推送后服务端按批次账重算权威金额。
/// 返回 (cost=按剩余批次能覆盖部分的成本, covered=覆盖数量)；不足部分由调用方按档案进价兜底。
({double cost, double covered}) localFifoConsume({
  required String itemId,
  required String unit,
  required double qty,
  required List<Map<String, dynamic>> buyRows,
  required List<Map<String, dynamic>> saleRows,
  required List<Map<String, dynamic>> lossRows,
}) {
  if (qty <= 0) return (cost: 0, covered: 0);
  // 批次：按进货时间/单号排序（与服务器 ORDER BY happened_at, created_at 近似）
  final batches = <({double price, double remaining, String t})>[];
  for (final p in buyRows) {
    if ('${p['item_id'] ?? ''}' != itemId || '${p['unit'] ?? ''}' != unit) continue;
    batches.add((
      price: (p['purchase_price'] as num?)?.toDouble() ?? 0,
      remaining: (p['quantity'] as num?)?.toDouble() ?? 0,
      t: '${p['happened_at'] ?? ''}|${p['id'] ?? ''}',
    ));
  }
  batches.sort((a, b) => a.t.compareTo(b.t));
  // 已发生的消耗事件：出货 + 报损（盘点调整由 qty 增/减批体现在批次剩余里，另由 stock_adjustments 派生）
  final events = <({double qty, String t})>[];
  for (final s in saleRows) {
    if ('${s['item_id'] ?? ''}' != itemId || '${s['unit'] ?? ''}' != unit) continue;
    events.add((qty: -((s['quantity'] as num?)?.toDouble() ?? 0), t: '${s['happened_at'] ?? ''}|${s['id'] ?? ''}'));
  }
  for (final l in lossRows) {
    if ('${l['item_id'] ?? ''}' != itemId || '${l['unit'] ?? ''}' != unit) continue;
    events.add((qty: -((l['qty'] as num?)?.toDouble() ?? 0), t: '${l['happened_at'] ?? ''}|${l['id'] ?? ''}'));
  }
  events.sort((a, b) => a.t.compareTo(b.t));
  for (final e in events) {
    var need = -e.qty;
    for (var i = 0; i < batches.length && need > 0; i++) {
      final b = batches[i];
      if (b.remaining <= 0) continue;
      final use = b.remaining < need ? b.remaining : need;
      batches[i] = (price: b.price, remaining: b.remaining - use, t: b.t);
      need -= use;
    }
  }
  // 本次消耗（剩余批次按先进先出）
  var need = qty;
  var cost = 0.0;
  var covered = 0.0;
  for (final b in batches) {
    if (need <= 0) break;
    if (b.remaining <= 0) continue;
    final use = b.remaining < need ? b.remaining : need;
    cost += use * b.price;
    covered += use;
    need -= use;
  }
  return (cost: cost, covered: covered);
}

/// 取商品某单位的档案进价（本地 items 镜像的 prices 数组；找不到返回 0）
double localArchivePrice(List<Map<String, dynamic>> items, String itemId, String unit) {
  for (final it in items) {
    if ('${it['id'] ?? ''}' != itemId) continue;
    for (final p in ((it['prices'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      if ('${p['unit'] ?? ''}' == unit) return (p['purchase_price'] as num?)?.toDouble() ?? 0;
    }
  }
  return 0;
}
