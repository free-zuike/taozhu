/// 交易 CSV 导出/导入公共工具（账本页与店铺管理页共用）。
/// 导出：全部/单店铺 出货+收款 → CSV（类型,日期,店铺,商品,数量,单位,单价,金额,备注）。
/// 导入：解析 CSV → 按行构建 sale_item/payment 本地入队同步（与记单提交同链路）。
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import 'download.dart';

/// 导出交易 CSV 文本（sales: 整单数组含 items；payments: 收款数组）
/// [onlyClientId] 非空时只导出该店铺（店铺管理页单店导出）；空=全部（账本页按当前筛选已过滤）
String buildTradesCsv(List<Map<String, dynamic>> sales, List<Map<String, dynamic>> payments,
    {String? onlyClientId}) {
  String csv(Object? v) {
    final s = '$v';
    return s.contains(',') || s.contains('"') || s.contains('\n') ? '"${s.replaceAll('"', '""')}"' : s;
  }
  final buf = StringBuffer('\uFEFF');
  buf.writeln('类型,日期,店铺,商品,数量,单位,单价,金额,备注');
  for (final s in sales) {
    if (onlyClientId != null && '${s['client_id'] ?? ''}' != onlyClientId) continue;
    final items = (s['items'] as List? ?? []);
    for (final it in items) {
      buf.writeln([
        '出货', csv(_date(s['happened_at'])), csv(s['client_name']),
        csv(it['item_name']), csv(it['quantity']), csv(it['unit']),
        csv(it['sale_price']), csv(it['amount']), csv(s['note']),
      ].join(','));
    }
  }
  for (final p in payments) {
    if (onlyClientId != null && '${p['client_id'] ?? ''}' != onlyClientId) continue;
    buf.writeln([
      '收款', csv(_date(p['happened_at'])), csv(p['client_name']),
      '', '', '', '', csv(p['amount']), csv(p['method']),
    ].join(','));
  }
  return buf.toString();
}

String _date(Object? v) {
  final s = '$v';
  return s.length >= 10 ? s.substring(0, 10) : s;
}

/// 从本地镜像读取交易数据（导出用；Web 无本地库直连服务器）
Future<({List<Map<String, dynamic>> sales, List<Map<String, dynamic>> payments})> loadTradesLocal() async {
  if (kIsWeb) {
    try {
      final d = await Api.instance.get('/sales?limit=1000');
      final sales = ((d['sales'] as List?) ?? []).cast<Map<String, dynamic>>();
      final pays = ((await Api.instance.get('/payments?limit=1000'))['payments'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      return (sales: sales, payments: pays);
    } catch (_) {
      return (sales: <Map<String, dynamic>>[], payments: <Map<String, dynamic>>[]);
    }
  }
  try {
    final itemRows = await LocalDb.getAll('sale_items');
    final byOrder = <String, List<Map<String, dynamic>>>{};
    final meta = <String, Map<String, dynamic>>{};
    for (final r in itemRows) {
      final oid = '${r['sale_id'] ?? ''}';
      if (oid.isEmpty) continue;
      (byOrder[oid] ??= []).add(r);
      final prev = meta[oid];
      final h = '${r['happened_at'] ?? ''}';
      meta[oid] = {
        'id': oid,
        'client_id': '${r['client_id'] ?? ''}',
        'client_name': '${r['client_name'] ?? ''}',
        'happened_at': '${prev?['happened_at'] ?? ''}'.compareTo(h) >= 0 ? '${prev?['happened_at'] ?? ''}' : h,
        'note': '${r['note'] ?? ''}',
      };
    }
    final sales = byOrder.entries.map((e) {
      final m = meta[e.key]!;
      final items = e.value..sort((a, b) => '${a['id'] ?? ''}'.compareTo('${b['id'] ?? ''}'));
      final total = items.fold<double>(0, (s, it) => s + ((it['amount'] as num?)?.toDouble() ?? 0));
      return {...m, 'total': total, 'items': items};
    }).toList();
    final payments = await LocalDb.getAll('payments');
    return (sales: sales, payments: payments);
  } catch (_) {
    return (sales: <Map<String, dynamic>>[], payments: <Map<String, dynamic>>[]);
  }
}

/// 导入交易 CSV（[storeId] 目标店铺 id，[storeName] 店铺名）：出货/收款行 → 本地入队同步。
/// [onProgress] 每行回调（可选）；返回 (新增, 跳过)
Future<({int ok, int skip})> importTradesCsv(
  String text,
  String storeId,
  String storeName,
) async {
  final lines = text.trim().split('\n');
  if (lines.length < 2) return (ok: 0, skip: 0);
  final rows = <Map<String, String>>[];
  for (var i = 1; i < lines.length; i++) {
    final cells = splitCsvLine(lines[i]);
    if (cells.length < 7) continue;
    rows.add({
      'type': cells[0].trim(),
      'date': cells[1].trim(),
      'client': cells[2].trim(),
      'item': cells[3].trim(),
      'qty': cells[4].trim(),
      'unit': cells[5].trim(),
      'price': cells[6].trim(),
      'amount': cells.length > 7 ? cells[7].trim() : '',
      'note': cells.length > 8 ? cells[8].trim() : '',
    });
  }
  var ok = 0;
  var skip = 0;
  final items = await LocalDb.getAllByName('items');
  for (final r in rows) {
    final type = r['type'] ?? '';
    final date = r['date'] ?? '';
    final itemName = r['item'] ?? '';
    final unitIn = r['unit'] ?? '';
    final noteIn = r['note'] ?? '';
    final qty = double.tryParse(r['qty'] ?? '');
    final price = double.tryParse(r['price'] ?? '');
    final amount = double.tryParse(r['amount'] ?? '');
    if (qty == null || qty <= 0) {
      skip++;
      continue;
    }
    final h = date.length >= 10 ? date.substring(0, 10) : date;
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(h)) {
      skip++;
      continue;
    }
    if (type == '出货' || type == 'sale') {
      final match = items.where((it) =>
          '${it['name']}' == itemName || '${it['name']}'.contains(itemName) || itemName.contains('${it['name']}')).firstOrNull;
      if (match == null) {
        skip++;
        continue;
      }
      final prices = ((match['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
      final unit = unitIn.isNotEmpty ? unitIn : '${prices.firstOrNull?['unit'] ?? ''}';
      final pr = prices.where((p) => '${p['unit']}' == unit).firstOrNull ?? prices.firstOrNull;
      final salePrice = price ?? ((pr?['sale_price'] as num?)?.toDouble() ?? 0);
      final rid = 'si${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';
      final saleId = 's${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';
      final rowPayload = {
        'id': rid, 'sale_id': saleId, 'client_id': storeId,
        'item_id': '${match['id']}', 'item_name': '${match['name']}',
        'unit': unit, 'quantity': qty,
        'sale_price': salePrice, 'cost_price': (pr?['purchase_price'] as num?)?.toDouble() ?? 0,
        'amount': amount ?? qty * salePrice,
        'happened_at': h, 'note': noteIn, 'sort': 0,
      };
      await LocalDb.upsertOne('sale_items', rowPayload);
      await SyncService.enqueueChange(
          entityType: 'sale_item', entitySyncId: rid, action: 'upsert', payload: rowPayload);
      await LocalDb.upsertOne('sales', {
        'id': saleId, 'client_id': storeId, 'client_name': storeName,
        'happened_at': h, 'note': noteIn, 'total': qty * salePrice, 'items': [rowPayload],
      });
      ok++;
    } else if (type == '收款' || type == 'payment') {
      final pid = 'pay${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';
      await LocalDb.upsertOne('payments', {
        'id': pid, 'client_id': storeId, 'happened_at': h,
        'amount': amount ?? 0, 'waived': 0, 'method': '', 'note': noteIn,
      });
      await SyncService.enqueueChange(
          entityType: 'payment', entitySyncId: pid, action: 'upsert',
          payload: {
            'id': pid, 'client_id': storeId, 'happened_at': h,
            'amount': amount ?? 0, 'waived': 0, 'method': '', 'note': noteIn,
          });
      ok++;
    } else {
      skip++;
    }
  }
  return (ok: ok, skip: skip);
}

/// CSV 行按逗号拆分（支持引号包裹含逗号的字段）
List<String> splitCsvLine(String line) {
  final out = <String>[];
  var cur = StringBuffer();
  var inQuote = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (inQuote) {
      if (ch == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          cur.write('"');
          i++;
        } else {
          inQuote = false;
        }
      } else {
        cur.write(ch);
      }
    } else if (ch == '"') {
      inQuote = true;
    } else if (ch == ',') {
      out.add(cur.toString());
      cur = StringBuffer();
    } else {
      cur.write(ch);
    }
  }
  out.add(cur.toString());
  return out;
}

/// 选择 CSV 文件读文本（Web 支持；原生返回 null 由调用方提示）
Future<String?> pickTradesCsv() => pickTextFile();