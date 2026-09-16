import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'router.dart';
import 'sale_line_edit.dart';
import 'sale_page.dart';

/// 日期栏编辑页：**该日全部出货商品明细行**（非单据列表——没有"出货单"概念，只有一条条商品记录）。
/// 点某行 → 只编辑该商品（数量/售价/单位/日期弹窗即时保存）；长按 → 删除该商品行；
/// 底部「记一笔出货」可补录当天（日期已预填当天）；返回本页自动刷新。
class SaleBatchEditPage extends StatefulWidget {
  const SaleBatchEditPage({
    super.key,
    required this.date,
    required this.lines,
    this.clientId,
  });
  final String date;
  /// 该日全部出货明细行（含 order 引用；跨单据平铺）
  final List<Map<String, dynamic>> lines;
  /// 账本当前店铺筛选（刷新时按同店查询，保持与账本页口径一致）
  final String? clientId;

  @override
  State<SaleBatchEditPage> createState() => _SaleBatchEditPageState();
}

class _SaleBatchEditPageState extends State<SaleBatchEditPage> {
  late List<Map<String, dynamic>> _lines;

  @override
  void initState() {
    super.initState();
    _lines = List.of(widget.lines);
  }

  /// 本页打开期间数据可能被改过 → 返回时重新拉取该日明细行（按行日期匹配）
  Future<void> _refresh() async {
    var lines = <Map<String, dynamic>>[];
    try {
      if (kIsWeb) {
        final params = <String>[
          'date_from=${widget.date}',
          'date_to=${widget.date}',
          'limit=500',
          if (widget.clientId != null) 'client_id=${widget.clientId}',
        ];
        final d = await Api.instance.get('/sales?${params.join('&')}');
        final orders = ((d['sales'] as List?) ?? []).cast<Map<String, dynamic>>();
        for (final o in orders) {
          for (final it in ((o['items'] as List?) ?? []).cast<Map<String, dynamic>>()) {
            final d2 = '${it['happened_at'] ?? o['happened_at'] ?? ''}';
            if (d2.startsWith(widget.date)) lines.add(_lineOf(o, it));
          }
        }
      } else {
        final all = await LocalDb.getAll('sales');
        for (final o in all) {
          if (widget.clientId != null && '${o['client_id']}' != widget.clientId) continue;
          final orderDate = '${o['happened_at'] ?? ''}';
          for (final it in ((o['items'] as List?) ?? []).cast<Map<String, dynamic>>()) {
            final d2 = '${it['happened_at'] ?? orderDate}';
            if (d2.startsWith(widget.date)) lines.add(_lineOf(o, it));
          }
        }
      }
    } catch (_) {
      // 拉取失败：保留进入时的快照（至少能看/能改）
    }
    if (!mounted) return;
    if (lines.isEmpty) lines = List.of(widget.lines);
    setState(() => _lines = lines);
  }

  /// 明细行 → 流水行（与账本页 _buildSaleFlow 同构）
  static Map<String, dynamic> _lineOf(Map<String, dynamic> o, Map<String, dynamic> it) {
    final orderDate = '${o['happened_at'] ?? ''}';
    final lineDate = '${it['happened_at'] ?? ''}';
    return {
      'date': lineDate.length >= 10 ? lineDate.substring(0, 10) : orderDate,
      'order': o,
      'client_name': '${o['client_name'] ?? ''}',
      'item_name': '${it['item_name'] ?? ''}',
      'category': '${it['item_category'] ?? it['category'] ?? ''}'.trim(),
      'note': '${it['note'] ?? ''}'.trim(),
      'quantity': '${it['quantity'] ?? ''}',
      'unit': '${it['unit'] ?? ''}',
      'amount': ((it['amount'] as num?)?.toDouble() ?? 0),
      'item_id': '${it['id'] ?? ''}',          // 明细行 id（行级编辑/删除端点用）
      'goods_id': '${it['item_id'] ?? ''}',    // 真实商品 id
      'sale_price': (it['sale_price'] as num?)?.toDouble(),
      'cost_price': (it['cost_price'] as num?)?.toDouble(),
      'qty_num': (it['quantity'] as num?)?.toDouble() ?? 0,
      'happened_at': lineDate.isEmpty ? orderDate : lineDate,
    };
  }

  Future<void> _addOrder() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SalePage(initDate: widget.date)));
    _refresh();
  }

  /// 删除单个商品行（长按）：不再有整单删除——只有"删除该商品"
  Future<void> _deleteLine(Map<String, dynamic> l) async {
    final order = l['order'] as Map<String, dynamic>;
    final itemId = '${l['item_id'] ?? ''}';
    final name = '${l['item_name'] ?? ''}'.isNotEmpty ? '「${l['item_name']}」' : '该商品';
    if (itemId.isEmpty) {
      toast(context, '该行无独立明细，无法单独删除');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除商品'),
        content: Text('确定删除 $name 这一行吗？仅删除该商品，其余商品保留；库存自动回滚。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (kIsWeb) {
        final r = await Api.instance.delete('/sales/items/$itemId');
        if (r is Map && r['order_deleted'] == true) {
          toast(context, '已删除该商品（本条记录已无商品）');
          _refresh();
          return;
        }
      } else {
        final items = ((order['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        final updatedItems = items.where((it) => '${it['id']}' != itemId).toList();
        if (updatedItems.isEmpty) {
          // 删的是该条记录最后一商品 → 整条记录删除（不留空壳，与 Web 级联语义一致）
          await LocalDb.deleteOne('sales', '${order['id']}');
          await SyncService.enqueueChange(
              entityType: 'sale', entitySyncId: '${order['id']}', action: 'delete', payload: {});
          toast(context, '已删除该商品（本条记录已无商品）');
          _refresh();
          return;
        }
        final payload = Map<String, dynamic>.from(order)..['items'] = updatedItems;
        payload['total'] = updatedItems.fold<double>(
            0, (s, it) => s + ((it['amount'] as num?)?.toDouble() ?? 0));
        await LocalDb.upsertOne('sales', payload);
        // 去单据化：删除走行级 sale_item delete（服务端删行 + 空则级联整条）
        await SyncService.enqueueChange(
            entityType: 'sale_item', entitySyncId: itemId, action: 'delete', payload: {
          'id': itemId, 'sale_id': '${order['id']}', 'client_id': '${order['client_id'] ?? ''}',
        });
        unawaited(SyncService.pushPending());
      }
      toast(context, '已删除该商品');
      _refresh();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.date} 出货商品')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
            child: Text(
              '点击某行 = 编辑该商品；长按 = 删除该商品。出货只是当天送货记录，每条商品独立保存。',
              style: TextStyle(fontSize: 12, color: c.textSub, height: 1.5),
            ),
          ),
          if (_lines.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text('当天暂无出货商品，可点下方「记一笔出货」补录',
                    style: TextStyle(fontSize: 13, color: c.textSub)),
              ),
            ),
          for (final l in _lines) _lineTile(c, l),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _addOrder,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('记一笔出货（补录当天）'),
          ),
        ],
      ),
    );
  }

  Widget _lineTile(TaozhuColors c, Map<String, dynamic> l) {
    final itemName = '${l['item_name'] ?? ''}';
    final qty = '${l['quantity'] ?? ''}';
    final unit = '${l['unit'] ?? ''}';
    final note = '${l['note'] ?? ''}'.trim();
    final sp = (l['sale_price'] as num?)?.toDouble() ?? 0;
    final date = '${l['date'] ?? ''}';
    final clientName = '${l['client_name'] ?? ''}';
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      // 点行 = 只编辑当前商品（数量/售价/单位/日期）；长按 = 删除该商品行
      onTap: () async {
        await editSaleLine(context, l);
        _refresh();
      },
      onLongPress: () => _deleteLine(l),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.primary.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: c.primary.withOpacity(0.12),
              child: Icon(Icons.storefront, size: 14, color: c.primary),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    clientName.isEmpty ? (itemName.isEmpty ? '（无明细）' : itemName) : '$clientName · $itemName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.textMain),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (sp > 0) '售价 ¥${fmtMoney(sp)}',
                      '数量 ×$qty$unit',
                      if (date.isNotEmpty) date,
                      if (note.isNotEmpty) note,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: c.textSub),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text('¥${fmtMoney((l['amount'] as num?)?.toDouble() ?? 0)}',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.danger)),
            const SizedBox(width: 2),
            Icon(Icons.chevron_right, size: 16, color: c.textSub),
          ],
        ),
      ),
    );
  }
}