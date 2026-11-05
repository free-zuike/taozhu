/// AI 助手本地降级问答（方案 A：客户端直连 + 本地业务快照，不经过服务器代理）。
///
/// 当云端数据库（D1）不可用 / 离线时，AI 助手不再依赖服务器：从本地 sembast 镜像
/// （由 /sync/full 同步而来）构造业务快照，用本地存储的 AI Key 直接调服务商
/// chat/completions 完成"问数"。
///
/// 能力边界（与服务器版对齐的部分）：今日/本月/总览、商品与店铺数、欠款 top5、低库存、临期预警。
/// 暂不支持（依赖服务端写库）：记忆读写、动态数据查询。一句话落单（出货/进货）已本地化。
/// Web 端无本地库，调用方不应降级到此。
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:intl/intl.dart';
import 'dart:math' show Random;
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart' show SyncService;
import '../utils/ai_local.dart' show aiLocalChat, aiLoadConfig, aiParseText;

String _fmt(num v) {
  if ((v.roundToDouble() - v).abs() < 0.005) return v.round().toString();
  return v.toStringAsFixed(2);
}

/// 从本地镜像构造业务快照（对齐后端 services/ai-assistant buildAssistantContext）。
/// role 为 'admin'/'staff'，店员屏蔽毛利与欠款金额。
Future<String> buildAssistantContextLocal(String role) async {
  final isStaff = role != 'admin';
  final now = DateTime.now();
  final today = DateFormat('yyyy-MM-dd').format(now);
  final month = '${today.substring(0, 7)}-01';

  final sales = await LocalDb.getAll('sale_items');
  final buys = await LocalDb.getAll('purchase_items');
  final pays = await LocalDb.getAll('payments');
  final items = await LocalDb.getAll('items');
  final clients = await LocalDb.getAll('clients');
  final stocks = await LocalDb.getAll('stocks');

  final itemName = <String, String>{};
  for (final it in items) {
    if ('${it['deleted_at'] ?? ''}'.isEmpty) itemName['${it['id']}'] = '${it['name'] ?? ''}';
  }
  final clientName = <String, String>{};
  for (final c in clients) {
    if ('${c['deleted_at'] ?? ''}'.isEmpty) clientName['${c['id']}'] = '${c['name'] ?? ''}';
  }

  double sumWhere(List<Map<String, dynamic>> rows, bool Function(Map) pick, String field) {
    double s = 0;
    for (final r in rows) {
      if (pick(r)) s += (r[field] is num ? (r[field] as num).toDouble() : 0);
    }
    return s;
  }

  final int saleTodayN = sales.where((r) => '${r['happened_at'] ?? ''}'.startsWith(today)).length;
  final double saleTodayS = sumWhere(sales, (r) => '${r['happened_at'] ?? ''}'.startsWith(today), 'amount');
  final double saleMonthS = sumWhere(sales, (r) => '${r['happened_at'] ?? ''}'.compareTo(month) >= 0, 'amount');
  double saleMonthCost = 0;
  for (final r in sales) {
    if ('${r['happened_at'] ?? ''}'.compareTo(month) >= 0) {
      final q = (r['quantity'] is num ? (r['quantity'] as num).toDouble() : 0);
      final c = (r['cost_price'] is num ? (r['cost_price'] as num).toDouble() : 0);
      saleMonthCost += q * c;
    }
  }
  final double payTodayS = sumWhere(pays, (r) => '${r['happened_at'] ?? ''}'.compareTo('$today 00:00:00') >= 0, 'amount') +
      sumWhere(pays, (r) => '${r['happened_at'] ?? ''}'.compareTo('$today 00:00:00') >= 0, 'waived');
  final double payMonthS = sumWhere(pays, (r) => '${r['happened_at'] ?? ''}'.compareTo('$month 00:00:00') >= 0, 'amount') +
      sumWhere(pays, (r) => '${r['happened_at'] ?? ''}'.compareTo('$month 00:00:00') >= 0, 'waived');
  final double buyTodayS = sumWhere(buys, (r) => '${r['happened_at'] ?? ''}'.startsWith(today), 'amount');
  final double buyMonthS = sumWhere(buys, (r) => '${r['happened_at'] ?? ''}'.compareTo(month) >= 0, 'amount');
  final int cntItem = items.where((it) => '${it['deleted_at'] ?? ''}'.isEmpty).length;
  final int cntClient = clients.where((c) => '${c['deleted_at'] ?? ''}'.isEmpty).length;

  final lines = <String>[];
  lines.add('业务概况（截至 $today）：商品 $cntItem 个，在记店铺 $cntClient 家。');
  lines.add('今日（$today）：出货 $saleTodayN 笔、金额 ${_fmt(saleTodayS)}；进货金额 ${_fmt(buyTodayS)}；收款 ${_fmt(payTodayS)}。');
  final monthProfit = saleMonthS - saleMonthCost;
  lines.add('本月（${today.substring(0, 7)} 起）：出货金额 ${_fmt(saleMonthS)}'
      '${!isStaff ? '、毛利 ${_fmt(monthProfit)}' : ''}；进货金额 ${_fmt(buyMonthS)}；收款 ${_fmt(payMonthS)}。');

  if (!isStaff) {
    final saleByClient = <String, double>{};
    for (final r in sales) {
      final cid = '${r['client_id'] ?? ''}';
      if (cid.isEmpty) continue;
      saleByClient[cid] = (saleByClient[cid] ?? 0) + (r['amount'] is num ? (r['amount'] as num).toDouble() : 0);
    }
    final payByClient = <String, double>{};
    for (final r in pays) {
      final cid = '${r['client_id'] ?? ''}';
      payByClient[cid] = (payByClient[cid] ?? 0) +
          (r['amount'] is num ? (r['amount'] as num).toDouble() : 0) +
          (r['waived'] is num ? (r['waived'] as num).toDouble() : 0);
    }
    final debts = <Map<String, dynamic>>[];
    saleByClient.forEach((cid, s) {
      final debt = s - (payByClient[cid] ?? 0);
      if (debt.abs() > 0.005) debts.add({'name': clientName[cid] ?? cid, 'debt': debt});
    });
    debts.sort((a, b) => (b['debt'] as double).compareTo(a['debt'] as double));
    if (debts.isNotEmpty) {
      lines.add('欠款 top5：${debts.take(5).map((d) => '${d['name']} ${_fmt(d['debt'] as double)}').join('；')}'
          '${debts.any((d) => (d['debt'] as double) < 0) ? '（负=预存/多收款）' : ''}。');
    } else {
      lines.add('欠款：当前无未结欠款。');
    }
  }

  // 低库存（剩余 ≤ 阈值，前 8）——店员也可见（库存核对是店员职责）
  final low = <Map<String, dynamic>>[];
  for (final r in stocks) {
    final qty = (r['quantity'] is num ? (r['quantity'] as num).toDouble() : 0);
    final min = (r['min_stock'] is num ? (r['min_stock'] as num).toDouble() : 0);
    if (min > 0 && qty <= min) {
      low.add({'name': itemName['${r['item_id']}'] ?? '${r['item_id']}', 'unit': '${r['unit'] ?? ''}', 'qty': qty, 'min': min});
    }
  }
  low.sort((a, b) => (a['qty'] as double).compareTo(b['qty'] as double));
  if (low.isNotEmpty) {
    lines.add('低库存（剩余≤阈值）：${low.take(8).map((r) => '${r['name']} 剩 ${_fmt(r['qty'] as double)}${r['unit']}/阈 ${_fmt(r['min'] as double)}').join('；')}。');
  }

  // 临期（最近批次到期日落在 近7天已过期 ~ 7天内到期 且剩余>0）——店员也可见。
  // 依赖本地 stocks 镜像含 expiry_date（后端 /stocks 已下行该字段；旧镜像无则跳过，不误导）。
  final expiring = <Map<String, dynamic>>[];
  final refNow = DateTime.now();
  final expLower = refNow.subtract(const Duration(days: 7));
  final expUpper = refNow.add(const Duration(days: 7));
  for (final r in stocks) {
    final exp = '${r['expiry_date'] ?? ''}'.trim();
    if (exp.isEmpty) continue;
    final expDate = DateTime.tryParse(exp);
    if (expDate == null) continue;
    final qty = (r['quantity'] is num ? (r['quantity'] as num).toDouble() : 0);
    if (qty <= 0) continue;
    if (expDate.isBefore(expLower) || expDate.isAfter(expUpper)) continue;
    expiring.add({'name': itemName['${r['item_id']}'] ?? '${r['item_id']}', 'unit': '${r['unit'] ?? ''}', 'qty': qty, 'exp': exp});
  }
  expiring.sort((a, b) => (a['exp'] as String).compareTo(b['exp'] as String));
  if (expiring.isNotEmpty) {
    lines.add('临期（7天内到期）：${expiring.take(8).map((r) => '${r['name']} 剩 ${_fmt(r['qty'] as double)}${r['unit']}（${r['exp']}到期）').join('；')}。');
  }

  return lines.join('\n');
}

/// 用本地业务快照 + 本地 Key 直接问数（不经过服务器代理，方案 A 降级路径）。
/// messages 为对话历史（含刚发送的用户消息）；返回模型回复文本。
Future<String> chatWithAssistantLocal(List<Map<String, dynamic>> messages) async {
  final role = await Api.instance.getRole();
  final context = await buildAssistantContextLocal(role);
  final system = [
    '你是「陶朱进销存」的 AI 助手，帮店主查看经营数据、管理库存。以下是当前业务数据快照（本地数据，以它为准）：',
    '--- 数据快照 ---',
    context,
    '--- 回答规则 ---',
    '1. 只依据上面的数据快照作答；快照里没有的，老实说"暂无这项数据"，绝不编造数字。',
    '2. 被问到"卖了多少/赚了多少/谁欠款/该补什么货"等经营问题时，直接给数字和清单，简洁、口语化。',
    '3. 如果用户想记一笔账/录单，告诉他可以直接在这里说"记一笔：老王拿了2箱苹果"或"进货：xx 两箱"（离线也能本地记账，联网后自动同步）；也可到「记单」页用 AI 识别（拍照/语音/文字）。',
    '4. 被问"怎么用/功能在哪"等使用问题时，用一两句话说明（记单在底部「记单」页、统计在「统计」页、库存盘点在「库存」页右上角、对账单在「对账单」、备份在「我的→备份」）。',
    '5. 回复用中文，尽量简短（一般 2-5 行）。',
  ].join('\n');
  return aiLocalChat([{'role': 'system', 'content': system}, ...messages]);
}

/// 本地离线落单（方案 A 第二阶段）：D1 不可用时，把"一句话记账"在端上完成。
/// 复用记单页的持久化路径（LocalDb.upsertOne 写镜像 + SyncService.enqueueChange 入队回推），
/// 不新建机制。流程：aiParseText 本地解析自然语言 → 匹配本地 items/clients 镜像拿 id →
/// 写 *_items 行级 + *sales/*purchases 整单镜像 → 逐行入队（恢复网络后由 /sync/push 回推到 D1）。
///
/// purpose 为 'sale'（出货）或 'purchase'（进货），决定实体类型、金额语义与冗余商品名快照。
/// 返回人类可读的确认文案；若解析不出任何商品（纯问句）返回 null，调用方可回退到问答。
/// Web 端无本地库，直接返回 null。
Future<String?> recordLocalSale(String text) => _recordLocal(text, 'sale');
Future<String?> recordLocalPurchase(String text) => _recordLocal(text, 'purchase');

Future<String?> _recordLocal(String text, String purpose) async {
  if (kIsWeb) return null;
  final isPurchase = purpose == 'purchase';
  final inv = await aiParseText(text, purpose: purpose);
  if (inv.items.isEmpty) return null;

  final items = await LocalDb.getAllByName('items');
  final clients = await LocalDb.getAllByName('clients');
  String? matchId(List<Map<String, dynamic>> rows, String name) {
    if (name.trim().isEmpty) return null;
    for (final r in rows) {
      if ('${r['name'] ?? ''}'.trim() == name.trim()) return '${r['id']}';
    }
    final lower = name.trim().toLowerCase();
    for (final r in rows) {
      if ('${r['name'] ?? ''}'.toLowerCase().contains(lower)) return '${r['id']}';
    }
    return null;
  }

  final now = DateTime.now();
  final prefix = isPurchase ? 'p' : 's';
  final orderId = '$prefix${now.millisecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';
  final happenedAt = inv.date.isNotEmpty ? '${inv.date} 00:00:00' : now.toIso8601String();
  final clientId = matchId(clients, inv.client) ?? '';

  final rowPayloads = <Map<String, dynamic>>[];
  var total = 0.0;
  for (var i = 0; i < inv.items.length; i++) {
    final it = inv.items[i];
    final itemId = matchId(items, it.name) ?? '';
    final amount = it.quantity * it.price;
    total += amount;
    final rowId = '$prefix${now.millisecondsSinceEpoch}${i}${Random().nextInt(0x7fffffff)}';
    rowPayloads.add(<String, dynamic>{
      'id': rowId,
      if (isPurchase) 'purchase_id': orderId else 'sale_id': orderId,
      'item_id': itemId,
      if (isPurchase) 'item_name': it.name, // 冗余商品名快照：item_id 匹配不到也不丢名
      'unit': it.unit,
      'quantity': it.quantity,
      if (isPurchase) 'purchase_price': it.price else 'sale_price': it.price,
      'amount': amount,
      'happened_at': happenedAt,
      if (!isPurchase) 'client_id': clientId,
      if (isPurchase) 'count_qty': null,
      if (isPurchase) 'expiry_date': null,
      if (isPurchase) 'note': '',
      'sort': i,
    });
  }
  // 整单镜像（对齐 sale_page 1739-1741 / purchase_page 1240：账本/统计/同步面板的"本店笔数"按整单镜像算）
  final order = <String, dynamic>{
    'id': orderId,
    'happened_at': happenedAt,
    'note': '',
    if (!isPurchase) 'client_id': clientId,
    if (isPurchase) 'total': total,
    'items': rowPayloads,
  };
  await LocalDb.upsertOne(isPurchase ? 'purchases' : 'sales', order);
  for (final row in rowPayloads) {
    await LocalDb.upsertOne(isPurchase ? 'purchase_items' : 'sale_items', row);
    await SyncService.enqueueChange(
      entityType: isPurchase ? 'purchase_item' : 'sale_item',
      entitySyncId: '${row['id']}',
      action: 'upsert',
      payload: row,
    );
  }
  final names = inv.items.map((e) => '${e.name} ${e.quantity}${e.unit}').join('、');
  final who = inv.client.isNotEmpty ? inv.client : (isPurchase ? '默认供应商' : '散客');
  final kind = isPurchase ? '进货' : '出货';
  return '已记到本机（联网后自动同步到云端）：$kind · $who · $names，合计 ${amountOf(rowPayloads)} 元。';
}

String amountOf(List<Map<String, dynamic>> rows) {
  var s = 0.0;
  for (final r in rows) {
    s += (r['amount'] is num ? (r['amount'] as num).toDouble() : 0);
  }
  return s.roundToDouble() == s ? s.round().toString() : s.toStringAsFixed(2);
}
