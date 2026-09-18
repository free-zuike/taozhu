import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'purchase_line_edit.dart';
import 'purchase_page.dart';
import 'attachment_viewer.dart';
import 'router.dart';

/// 日期栏编辑页：**该日全部进货商品明细行**（非单据列表——没有"进货单"概念，只有一条条商品记录）。
/// 点某行 → 只编辑该商品（数量/进价/单位/日期弹窗即时保存）；长按 → 删除该商品行；
/// 底部「记一笔进货」可补录当天（日期已预填当天）；返回本页自动刷新。
class PurchaseBatchEditPage extends StatefulWidget {
  const PurchaseBatchEditPage({
    super.key,
    required this.date,
    required this.lines,
  });
  final String date;
  /// 该日全部进货明细行（含 order 引用；跨单据平铺）
  final List<Map<String, dynamic>> lines;

  @override
  State<PurchaseBatchEditPage> createState() => _PurchaseBatchEditPageState();
}

class _PurchaseBatchEditPageState extends State<PurchaseBatchEditPage> {
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
        final d = await Api.instance.get('/purchases?date_from=${widget.date}&date_to=${widget.date}&limit=500');
        final orders = ((d['purchases'] as List?) ?? []).cast<Map<String, dynamic>>();
        for (final o in orders) {
          for (final it in ((o['items'] as List?) ?? []).cast<Map<String, dynamic>>()) {
            final d2 = '${it['happened_at'] ?? o['happened_at'] ?? ''}';
            if (d2.startsWith(widget.date)) {
              lines.add(_lineOf(o, it));
            }
          }
        }
      } else {
        final all = await LocalDb.getAll('purchases');
        for (final o in all) {
          final orderDate = '${o['happened_at'] ?? ''}';
          for (final it in ((o['items'] as List?) ?? []).cast<Map<String, dynamic>>()) {
            final d2 = '${it['happened_at'] ?? orderDate}';
            if (d2.startsWith(widget.date)) {
              lines.add(_lineOf(o, it));
            }
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

  /// 明细行 → 流水行（与进货记录页 _buildList 同构）
  static Map<String, dynamic> _lineOf(Map<String, dynamic> o, Map<String, dynamic> it) {
    final orderDate = '${o['happened_at'] ?? ''}';
    final lineDate = '${it['happened_at'] ?? ''}';
    return {
      'date': lineDate.length >= 10 ? lineDate.substring(0, 10) : orderDate,
      'order': o,
      'item_name': '${it['item_name'] ?? ''}',
      'item_id': '${it['item_id'] ?? ''}',
      'category': '${it['item_category'] ?? it['category'] ?? ''}'.trim(),
      'note': '${it['note'] ?? ''}'.trim(),
      'quantity': '${it['quantity'] ?? ''}',
      'unit': '${it['unit'] ?? ''}',
      'amount': ((it['amount'] as num?)?.toDouble() ?? 0),
      'id': '${it['id'] ?? ''}',
      'row_id': '${it['id'] ?? ''}',
      'purchase_price': (it['purchase_price'] as num?)?.toDouble() ?? 0,
      'happened_at': lineDate.isEmpty ? orderDate : lineDate,
    };
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// 批量添加附件：凭证一次挂到该日每行商品（各自独立一份），不经单改
  Future<void> _addBatchAttachments() async {
    final lineIds = [
      for (final l in _lines)
        if ('${l['row_id'] ?? ''}'.isNotEmpty) '${l['row_id']}',
    ];
    if (lineIds.isEmpty) {
      toast(context, '当天无商品明细，无法批量挂图');
      return;
    }
    await showAttachmentViewer(context, 'purchase_item', widget.date,
        '批量添加附件（该日每行商品各一份）', lineIds: lineIds);
    _refresh();
  }

  Future<void> _addOrder() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => PurchasePage(initDate: widget.date)));
    _refresh();
  }

  /// 删除单个商品行（长按）：不再有整单删除——只有"删除该商品"
  Future<void> _deleteLine(Map<String, dynamic> l) async {
    final order = l['order'] as Map<String, dynamic>;
    final rowId = '${l['row_id'] ?? ''}';
    final name = '${l['item_name'] ?? ''}'.isNotEmpty ? '「${l['item_name']}」' : '该商品';
    if (rowId.isEmpty) {
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
        final r = await Api.instance.delete('/purchases/items/$rowId');
        if (r is Map && r['order_deleted'] == true) {
          toast(context, '已删除该商品（本条记录已无商品）');
          _refresh();
          return;
        }
      } else {
        final items = ((order['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        final updatedItems = items.where((it) => '${it['id']}' != rowId).toList();
        if (updatedItems.isEmpty) {
          // 删的是该条记录最后一商品 → 整条记录删除（不留空壳，与 Web 级联语义一致）
          await SyncService.cleanupLocalAttachmentsOf('purchase_item', rowId);
          await SyncService.cleanupLocalAttachmentsOf('purchase', '${order['id']}');
          await LocalDb.deleteOne('purchases', '${order['id']}');
          await SyncService.enqueueChange(
              entityType: 'purchase', entitySyncId: '${order['id']}', action: 'delete', payload: {});
          toast(context, '已删除该商品（本条记录已无商品）');
          _refresh();
          return;
        }
        // 非末行：该行凭证附件副本一并清（attachments/purchase_item/{rowId}/），再镜像移除该行
        await SyncService.cleanupLocalAttachmentsOf('purchase_item', rowId);
        final payload = Map<String, dynamic>.from(order)..['items'] = updatedItems;
        payload['total'] = updatedItems.fold<double>(
            0, (s, it) => s + ((it['amount'] as num?)?.toDouble() ?? 0));
        await LocalDb.upsertOne('purchases', payload);
        // 去单据化：删除走行级 purchase_item delete（服务端删行 + 空则级联整条）
        await SyncService.enqueueChange(
            entityType: 'purchase_item', entitySyncId: rowId, action: 'delete', payload: {
          'id': rowId, 'purchase_id': '${order['id']}',
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
      appBar: AppBar(title: Text('${widget.date} 进货商品')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
            child: Text(
              '点击某行 = 编辑该商品；长按 = 删除该商品。进货只是当天补货记录，每条商品独立保存。',
              style: TextStyle(fontSize: 12, color: c.textSub, height: 1.5),
            ),
          ),
          if (_lines.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text('当天暂无进货商品，可点下方「记一笔进货」补录',
                    style: TextStyle(fontSize: 13, color: c.textSub)),
              ),
            ),
          // 批量添加附件：整日凭证一次挂到该日每行商品（各自独立一份）
          if (_lines.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton.icon(
                onPressed: _addBatchAttachments,
                icon: const Icon(Icons.image_outlined, size: 18),
                label: const Text('批量添加附件（该日每行商品各一份）'),
              ),
            ),
          for (final l in _lines) _lineTile(c, l),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _addOrder,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('记一笔进货（补录当天）'),
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
    final pp = (l['purchase_price'] as num?)?.toDouble() ?? 0;
    final date = '${l['date'] ?? ''}';
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      // 点行 = 只编辑当前商品（数量/进价/单位/日期）；长按 = 删除该商品行
      onTap: () async {
        final order = l['order'] as Map<String, dynamic>;
        final line = Map<String, dynamic>.from(l)..['id'] = '${l['row_id'] ?? ''}';
        await editPurchaseLine(context, order, line);
        _refresh();
      },
      onLongPress: () => _deleteLine(l),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.success.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: c.success.withOpacity(0.12),
              child: Icon(Icons.shopping_cart, size: 14, color: c.success),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    itemName.isEmpty ? '（无明细）' : itemName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.textMain),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (pp > 0) '进价 ¥${fmtMoney(pp)}',
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