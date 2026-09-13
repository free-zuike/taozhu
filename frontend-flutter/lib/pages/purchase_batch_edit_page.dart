import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'purchase_page.dart';

/// 日期栏编辑页：该日进货单列表。
/// 点某张单 → 进货记单页（PurchasePage 编辑模式），该单所有商品明细完整展开、可直接修改并保存；
/// 底部「记一笔进货」可补录当天新单（日期已预填当天）；返回本页自动刷新。
class PurchaseBatchEditPage extends StatefulWidget {
  const PurchaseBatchEditPage({
    super.key,
    required this.date,
    required this.purchases,
  });
  final String date;
  final List<Map<String, dynamic>> purchases;

  @override
  State<PurchaseBatchEditPage> createState() => _PurchaseBatchEditPageState();
}

class _PurchaseBatchEditPageState extends State<PurchaseBatchEditPage> {
  late List<Map<String, dynamic>> _orders;

  @override
  void initState() {
    super.initState();
    _orders = List.of(widget.purchases);
  }

  /// 从进货记录页进入后已用过的新数据源：本页打开期间数据可能被记单页改过 → 返回时重新拉取
  Future<void> _refresh() async {
    var orders = <Map<String, dynamic>>[];
    try {
      if (kIsWeb) {
        final d = await Api.instance.get('/purchases?date_from=${widget.date}&date_to=${widget.date}&limit=500');
        orders = ((d['purchases'] as List?) ?? []).cast<Map<String, dynamic>>();
      } else {
        final all = await LocalDb.getAll('purchases');
        orders = [
          for (final o in all)
            if ('${o['happened_at'] ?? ''}'.startsWith(widget.date)) o,
        ];
      }
    } catch (_) {
      // 拉取失败：保留进入时的快照（至少能看/能改）
    }
    if (!mounted) return;
    if (orders.isEmpty) orders = List.of(widget.purchases);
    setState(() => _orders = orders);
  }

  Future<void> _openOrder(Map<String, dynamic> order) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => PurchasePage(editId: '${order['id']}')));
    _refresh();
  }

  Future<void> _addOrder() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => PurchasePage(initDate: widget.date)));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(
        title: Text('编辑 ${widget.date} · ${_orders.length} 张进货单'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
            child: Text(
              '点某张单 → 进货记单页：该单所有商品明细完整显示，可直接修改数量/进价/单位/日期并保存；返回自动刷新。',
              style: TextStyle(fontSize: 12, color: c.textSub, height: 1.5),
            ),
          ),
          if (_orders.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text('当天暂无进货单，可点下方「记一笔进货」补录',
                    style: TextStyle(fontSize: 13, color: c.textSub)),
              ),
            ),
          for (final o in _orders) _orderTile(c, o),
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

  Widget _orderTile(TaozhuColors c, Map<String, dynamic> o) {
    final items = ((o['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    final total = (o['total'] as num?)?.toDouble() ??
        items.fold<double>(0, (s, it) => s + ((it['amount'] as num?)?.toDouble() ?? 0));
    final note = '${o['note'] ?? ''}'.trim();
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _openOrder(o),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.success.withOpacity(0.3)),
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
                    note.isNotEmpty ? note : (items.isNotEmpty ? '${items.first['item_name']} 等 ${items.length} 项' : '进货单'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.textMain),
                  ),
                  Text(
                    items.isEmpty
                        ? '备注行${note.isNotEmpty ? ' · $note' : ''}'
                        : '${items.length} 种商品${note.isNotEmpty ? ' · $note' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.textSub),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text('¥${fmtMoney(total)}',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.danger)),
            const SizedBox(width: 2),
            Icon(Icons.chevron_right, size: 16, color: c.textSub),
          ],
        ),
      ),
    );
  }
}
