/// 本地流水 CSV（出货 / 进货 / 收款三合一）——与后端 /export/transactions.csv 同列口径：
/// 类型,日期,单号,店铺,商品,单位,数量,单价,金额,成本价,减免,收款方式,备注
/// 原生端离线可用（读本地镜像）；Web 无本地库仍走服务端导出。
/// 列值做引号转义 + 公式注入防护（= + - @ 开头前缀单引号），BOM/CRLF 便于 Excel 直接打开。
import '../api.dart';
import '../local_db.dart';

const _csvHeaders = [
  '类型', '日期', '单号', '店铺', '商品', '单位', '数量', '单价', '金额', '成本价', '减免', '收款方式', '备注',
];

String _csvCell(Object? v) {
  var s = v == null ? '' : '$v';
  if (RegExp(r'^[=+\-@\t\r]').hasMatch(s)) s = "'$s";
  return '"${s.replaceAll('"', '""')}"';
}

String _date10(dynamic iso) {
  final s = '${iso ?? ''}';
  return s.length >= 10 ? s.substring(0, 10) : s;
}

/// 生成 CSV；kind: all|sale|purchase|payment；日期为 YYYY-MM-DD（含首尾）。
/// 返回 (csv 文本, 行数, 是否触达行数上限)；与服务器一致：按类别各自 LIMIT。
Future<({String csv, int rows, bool truncated})> buildLocalTransactionsCsv({
  String kind = 'all',
  String start = '',
  String end = '',
  String clientId = '',
  bool isStaff = false,
  int limit = 20000,
}) async {
  final itemNames = <String, String>{
    for (final i in await LocalDb.getAll('items')) '${i['id'] ?? ''}': '${i['name'] ?? ''}',
  };
  final clientNames = <String, String>{
    for (final c in await LocalDb.getAllByName('clients')) '${c['id'] ?? ''}': '${c['name'] ?? ''}',
  };
  bool inRange(dynamic iso) {
    final d = _date10(iso);
    if (d.isEmpty) return false;
    if (start.isNotEmpty && d.compareTo(start) < 0) return false;
    if (end.isNotEmpty && d.compareTo(end) > 0) return false;
    return true;
  }

  final rows = <List<Object?>>[];
  var truncated = false;
  final dateDesc = (Map<String, dynamic> a, Map<String, dynamic> b) =>
      _date10(b['happened_at']).compareTo(_date10(a['happened_at']));

  if (kind == 'all' || kind == 'sale') {
    var list = (await LocalDb.getAll('sale_items'))
        .where((r) =>
            inRange(r['happened_at']) &&
            (clientId.isEmpty || '${r['client_id'] ?? ''}' == clientId))
        .toList()
      ..sort(dateDesc);
    if (list.length >= limit) {
      truncated = true;
      list = list.take(limit).toList();
    }
    for (final r in list) {
      rows.add([
        '出货', _date10(r['happened_at']), '${r['sale_id'] ?? ''}',
        clientNames['${r['client_id'] ?? ''}'] ?? '', itemNames['${r['item_id'] ?? ''}'] ?? '',
        '${r['unit'] ?? ''}', r['quantity'], r['sale_price'], r['amount'],
        isStaff ? '' : r['cost_price'], '', '', '${r['note'] ?? ''}',
      ]);
    }
  }
  // 进货不分店铺（与服务器一致：指定 client_id 时不导出进货）
  if ((kind == 'all' || kind == 'purchase') && clientId.isEmpty) {
    var list = (await LocalDb.getAll('purchase_items'))
        .where((r) => inRange(r['happened_at']))
        .toList()
      ..sort(dateDesc);
    if (list.length >= limit) {
      truncated = true;
      list = list.take(limit).toList();
    }
    for (final r in list) {
      rows.add([
        '进货', _date10(r['happened_at']), '${r['purchase_id'] ?? ''}',
        '', itemNames['${r['item_id'] ?? ''}'] ?? '',
        '${r['unit'] ?? ''}', r['quantity'], isStaff ? '' : r['purchase_price'], r['amount'],
        '', '', '', '${r['note'] ?? ''}',
      ]);
    }
  }
  if (kind == 'all' || kind == 'payment') {
    var list = (await LocalDb.getAll('payments'))
        .where((r) =>
            inRange(r['happened_at']) &&
            (clientId.isEmpty || '${r['client_id'] ?? ''}' == clientId))
        .toList()
      ..sort(dateDesc);
    if (list.length >= limit) {
      truncated = true;
      list = list.take(limit).toList();
    }
    for (final r in list) {
      rows.add([
        '收款', _date10(r['happened_at']), '${r['id'] ?? ''}',
        clientNames['${r['client_id'] ?? ''}'] ?? '', '', '',
        '', '', r['amount'], '', r['waived'], '${r['method'] ?? ''}', '${r['note'] ?? ''}',
      ]);
    }
  }
  if (kind == 'all') {
    rows.sort((a, b) => '${b[1]}'.compareTo('${a[1]}'));
  }

  final buf = StringBuffer('\uFEFF');
  buf.writeln(_csvHeaders.map(_csvCell).join(','));
  for (final r in rows) {
    buf.writeln(r.map(_csvCell).join(','));
  }
  return (csv: buf.toString(), rows: rows.length, truncated: truncated);
}

/// 当前角色是否店员（本地缓存；未登录/未知按普通用户处理=不打码）
Future<bool> localIsStaff() async => (await Api.instance.getRole()) != 'admin';
