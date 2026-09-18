/// 本地统计聚合（原生端零网络：所有统计从本地镜像计算，秒开；Web 无本地库 → 直连 API）。
/// 与后端 /stats/* 响应字段同形，页面渲染零改动。去单据化后主记录=行级（sale_items/purchase_items）。
import 'local_db.dart';

/// 本地镜像按区间+店铺聚合出货/毛利/收款/进货/欠款（与 /stats/summary 同形）
Future<Map<String, dynamic>?> localSummary(String start, String end, String? clientId) async {
  final rows = await LocalDb.getAll('sale_items');
  final pays = await LocalDb.getAll('payments');
  final buys = await LocalDb.getAll('purchase_items');
  final sel = clientId ?? '';
  final inRange = (String h) => h.isNotEmpty && h.compareTo(start) >= 0 && h.compareTo(end) <= 0;
  double sold = 0, gross = 0, paid = 0, purchase = 0, debt = 0;
  var count = 0;
  for (final r in rows) {
    final cid = '${r['client_id'] ?? ''}';
    if (sel.isNotEmpty && cid != sel) continue;
    final h = '${r['happened_at'] ?? ''}';
    final amt = (r['amount'] as num?)?.toDouble() ?? 0;
    if (h.isNotEmpty && h.compareTo(end) <= 0) debt += amt; // 截止 end 累计出货
    if (!inRange(h)) continue;
    sold += amt;
    count++;
    final qty = (r['quantity'] as num?)?.toDouble() ?? 0;
    gross += (((r['sale_price'] as num?)?.toDouble() ?? 0) - ((r['cost_price'] as num?)?.toDouble() ?? 0)) * qty;
  }
  for (final p in pays) {
    final cid = '${p['client_id'] ?? ''}';
    if (sel.isNotEmpty && cid != sel) continue;
    final amt = ((p['amount'] as num?)?.toDouble() ?? 0) + ((p['waived'] as num?)?.toDouble() ?? 0);
    final h = '${p['happened_at'] ?? ''}';
    if (h.isNotEmpty && h.compareTo(end) <= 0) debt -= amt;
    if (inRange(h)) paid += amt;
  }
  for (final b in buys) {
    final h = '${b['happened_at'] ?? ''}';
    if (inRange(h)) purchase += (b['amount'] as num?)?.toDouble() ?? 0;
  }
  return {
    'sales_total': _r(sold), 'gross_profit': _r(gross), 'paid_total': _r(paid),
    'purchase_total': _r(purchase), 'debt': _r(debt), 'sales_count': count, 'can_see_profit': true,
  };
}

/// 每日聚合（与 /stats/daily 同形）：days: [{day, sales_total, gross_profit, paid_total}]
Future<Map<String, dynamic>> localDaily(String start, String end, String? clientId) async {
  final rows = await LocalDb.getAll('sale_items');
  final pays = await LocalDb.getAll('payments');
  final byDay = <String, Map<String, double>>{};
  void acc(String day, String k, double v) {
    (byDay[day] ??= {'sales_total': 0, 'gross_profit': 0, 'paid_total': 0})[k] =
        (byDay[day]![k] ?? 0) + v;
  }
  for (final r in rows) {
    if (clientId != null && '${r['client_id'] ?? ''}' != clientId) continue;
    final h = '${r['happened_at'] ?? ''}';
    if (h.isEmpty || h.compareTo(start) < 0 || h.compareTo(end) > 0) continue;
    final day = h.substring(0, 10);
    acc(day, 'sales_total', (r['amount'] as num?)?.toDouble() ?? 0);
    acc(day, 'gross_profit', ((r['sale_price'] as num?)?.toDouble() ?? 0) - ((r['cost_price'] as num?)?.toDouble() ?? 0) * ((r['quantity'] as num?)?.toDouble() ?? 0));
  }
  for (final p in pays) {
    if (clientId != null && '${p['client_id'] ?? ''}' != clientId) continue;
    final h = '${p['happened_at'] ?? ''}';
    if (h.isEmpty || h.compareTo(start) < 0 || h.compareTo(end) > 0) continue;
    acc(h.substring(0, 10), 'paid_total', ((p['amount'] as num?)?.toDouble() ?? 0) + ((p['waived'] as num?)?.toDouble() ?? 0));
  }
  final days = byDay.entries.map((e) => <String, dynamic>{
    'day': e.key, 'sales_total': _r(e.value['sales_total'] ?? 0),
    'gross_profit': _r(e.value['gross_profit'] ?? 0), 'paid_total': _r(e.value['paid_total'] ?? 0),
  }).toList()..sort((a, b) => '${a['day']}'.compareTo('${b['day']}'));
  return {'days': days};
}

/// 商品排行（与 /stats/items 同形）：items: [{name, unit, quantity, amount}]（按 商品+单位 分组）
Future<Map<String, dynamic>> localItems(String start, String end, String? clientId) async {
  final rows = await LocalDb.getAll('sale_items');
  final items = await LocalDb.getAllByName('items');
  final nameOf = {for (final it in items) '${it['id']}': '${it['name'] ?? ''}'};
  final agg = <String, Map<String, dynamic>>{};
  for (final r in rows) {
    if (clientId != null && '${r['client_id'] ?? ''}' != clientId) continue;
    final h = '${r['happened_at'] ?? ''}';
    if (h.isEmpty || h.compareTo(start) < 0 || h.compareTo(end) > 0) continue;
    final itemId = '${r['item_id'] ?? ''}';
    final unit = '${r['unit'] ?? ''}';
    final key = '$itemId|$unit';
    final a = agg[key] ??= {'item_id': itemId, 'unit': unit, 'quantity': 0.0, 'amount': 0.0};
    final qty = (r['quantity'] as num?)?.toDouble() ?? 0;
    a['quantity'] = (a['quantity'] as double) + qty;
    a['amount'] = (a['amount'] as double) + ((r['amount'] as num?)?.toDouble() ?? 0);
  }
  final items2 = agg.values.map((a) => <String, dynamic>{
    'name': nameOf['${a['item_id']}'] ?? '',
    'unit': a['unit'],
    'quantity': _r(a['quantity'] as double),
    'amount': _r(a['amount'] as double),
  }).toList()..sort((a, b) => ((b['amount'] as num) - (a['amount'] as num)).toInt());
  return {'items': items2};
}

/// 分类聚合（与 /stats/categories 同形）：categories: [{category, quantity, amount}]
Future<Map<String, dynamic>> localCategories(String start, String end, String? clientId) async {
  final rows = await LocalDb.getAll('sale_items');
  final items = await LocalDb.getAllByName('items');
  final catOf = <String, String>{};
  for (final it in items) {
    final c = '${it['category'] ?? ''}';
    if (c.isNotEmpty) catOf['${it['id']}'] = c;
  }
  final agg = <String, Map<String, dynamic>>{};
  for (final r in rows) {
    if (clientId != null && '${r['client_id'] ?? ''}' != clientId) continue;
    final h = '${r['happened_at'] ?? ''}';
    if (h.isEmpty || h.compareTo(start) < 0 || h.compareTo(end) > 0) continue;
    final cat = catOf['${r['item_id'] ?? ''}']?.trim().isNotEmpty == true
        ? catOf['${r['item_id'] ?? ''}']!
        : ('${r['item_category'] ?? ''}'.trim().isNotEmpty ? '${r['item_category']}' : '未分类');
    final a = agg[cat] ??= {'quantity': 0.0, 'amount': 0.0};
    a['quantity'] = (a['quantity'] as double) + ((r['quantity'] as num?)?.toDouble() ?? 0);
    a['amount'] = (a['amount'] as double) + ((r['amount'] as num?)?.toDouble() ?? 0);
  }
  final cats = agg.entries.map((e) => <String, dynamic>{
    'category': e.key,
    'quantity': _r(e.value['quantity'] as double),
    'amount': _r(e.value['amount'] as double),
  }).toList()..sort((a, b) => ((b['amount'] as num) - (a['amount'] as num)).toInt());
  return {'categories': cats};
}

/// 按月聚合（与 /stats/monthly 同形）：months: [{month, sales_total, gross_profit}]
Future<Map<String, dynamic>> localMonthly(String year, String? clientId) async {
  final rows = await LocalDb.getAll('sale_items');
  final agg = <String, Map<String, double>>{};
  for (final r in rows) {
    if (clientId != null && '${r['client_id'] ?? ''}' != clientId) continue;
    final h = '${r['happened_at'] ?? ''}';
    if (h.length < 7 || !h.startsWith(year)) continue;
    final month = h.substring(0, 7);
    final a = agg[month] ??= {'sales_total': 0, 'gross_profit': 0};
    a['sales_total'] = (a['sales_total'] ?? 0) + ((r['amount'] as num?)?.toDouble() ?? 0);
    a['gross_profit'] = (a['gross_profit'] ?? 0) +
        (((r['sale_price'] as num?)?.toDouble() ?? 0) - ((r['cost_price'] as num?)?.toDouble() ?? 0)) * ((r['quantity'] as num?)?.toDouble() ?? 0);
  }
  final months = agg.entries.map((e) => <String, dynamic>{
    'month': e.key, 'sales_total': _r(e.value['sales_total'] ?? 0), 'gross_profit': _r(e.value['gross_profit'] ?? 0),
  }).toList()..sort((a, b) => '${a['month']}'.compareTo('${b['month']}'));
  return {'months': months};
}

/// 按店结账（与 /stats/clients 同形；含欠款与毛利）
Future<Map<String, dynamic>> localClientStats(String start, String end) async {
  final rows = await LocalDb.getAll('sale_items');
  final pays = await LocalDb.getAll('payments');
  final clients = await LocalDb.getAllByName('clients');
  final nameOf = {for (final c in clients) '${c['id']}': '${c['name'] ?? ''}'};
  final agg = <String, Map<String, double>>{};
  for (final r in rows) {
    final cid = '${r['client_id'] ?? ''}';
    final h = '${r['happened_at'] ?? ''}';
    if (h.isEmpty) continue;
    final a = agg[cid] ??= {'sales_total': 0, 'paid_total': 0, 'gross_profit': 0, 'all_sales': 0, 'all_paid': 0};
    a['all_sales'] = (a['all_sales'] ?? 0) + ((r['amount'] as num?)?.toDouble() ?? 0);
    if (h.compareTo(start) >= 0 && h.compareTo(end) <= 0) {
      a['sales_total'] = (a['sales_total'] ?? 0) + ((r['amount'] as num?)?.toDouble() ?? 0);
      a['gross_profit'] = (a['gross_profit'] ?? 0) +
          (((r['sale_price'] as num?)?.toDouble() ?? 0) - ((r['cost_price'] as num?)?.toDouble() ?? 0)) * ((r['quantity'] as num?)?.toDouble() ?? 0);
    }
  }
  for (final p in pays) {
    final cid = '${p['client_id'] ?? ''}';
    final h = '${p['happened_at'] ?? ''}';
    if (h.isEmpty) continue;
    final amt = ((p['amount'] as num?)?.toDouble() ?? 0) + ((p['waived'] as num?)?.toDouble() ?? 0);
    final a = agg[cid] ??= {'sales_total': 0, 'paid_total': 0, 'gross_profit': 0, 'all_sales': 0, 'all_paid': 0};
    a['all_paid'] = (a['all_paid'] ?? 0) + amt;
    if (h.compareTo(start) >= 0 && h.compareTo(end) <= 0) a['paid_total'] = (a['paid_total'] ?? 0) + amt;
  }
  final list = agg.entries.map((e) => <String, dynamic>{
    'id': e.key, 'name': nameOf[e.key] ?? '',
    'sales_total': _r(e.value['sales_total'] ?? 0), 'paid_total': _r(e.value['paid_total'] ?? 0),
    'gross_profit': _r(e.value['gross_profit'] ?? 0),
    'debt': _r((e.value['all_sales'] ?? 0) - (e.value['all_paid'] ?? 0)),
  }).toList()..sort((a, b) => ((b['sales_total'] as num) - (a['sales_total'] as num)).toInt());
  return {'clients': list};
}

/// 有数据年份（与 /stats/years 同形）+ 最早记账日期
Future<Map<String, dynamic>> localYears() async {
  final rows = await LocalDb.getAll('sale_items');
  final pays = await LocalDb.getAll('payments');
  final buys = await LocalDb.getAll('purchase_items');
  final years = <String>{};
  String? first;
  void add(String h) {
    if (h.length < 4) return;
    years.add(h.substring(0, 4));
    if (first == null || h.compareTo(first!) < 0) first = h;
  }
  for (final r in rows) add('${r['happened_at'] ?? ''}');
  for (final p in pays) add('${p['happened_at'] ?? ''}');
  for (final b in buys) add('${b['happened_at'] ?? ''}');
  final list = years.map((y) => int.tryParse(y)).whereType<int>().where((n) => n >= 2000).toList()..sort();
  return {'years': list, 'first_date': first?.substring(0, 10) ?? ''};
}

/// 出货明细（商品级，按日期升序每行一件）：本地镜像直算，供统计页「出货明细」分区
Future<List<Map<String, dynamic>>> localSaleDetail(String start, String end, String? clientId) async {
  final rows = await LocalDb.getAll('sale_items');
  final clients = await LocalDb.getAllByName('clients');
  final items = await LocalDb.getAllByName('items');
  final clientName = {for (final c in clients) '${c['id']}': '${c['name'] ?? ''}'};
  final itemName = {for (final it in items) '${it['id']}': '${it['name'] ?? ''}'};
  final out = <Map<String, dynamic>>[];
  for (final r in rows) {
    final cid = '${r['client_id'] ?? ''}';
    if (clientId != null && cid != clientId) continue;
    final h = '${r['happened_at'] ?? ''}';
    if (h.isEmpty || h.compareTo(start) < 0 || h.compareTo(end) > 0) continue;
    final itemId = '${r['item_id'] ?? ''}';
    out.add(<String, dynamic>{
      'date': h.substring(0, 10),
      'client_name': clientName[cid] ?? '',
      'name': itemName[itemId] ?? '${r['item_name'] ?? ''}',
      'quantity': (r['quantity'] as num?)?.toDouble() ?? 0,
      'unit': '${r['unit'] ?? ''}',
      'amount': (r['amount'] as num?)?.toDouble() ?? 0,
    });
  }
  out.sort((a, b) => '${a['date']}'.compareTo('${b['date']}'));
  return out;
}

double _r(num? v) => (v ?? 0) * 100.roundToDouble() >= 0 ? double.parse(((v ?? 0) * 100).round().toString()) / 100 : 0;