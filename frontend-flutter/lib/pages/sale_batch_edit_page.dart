import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'sale_page.dart';

/// 日期栏编辑页：该日出货单列表（跨店铺）。
/// 点某张单 → 进出货记单页（SalePage 编辑模式），该单所有商品明细完整展开、可直接修改并保存；
/// 底部「记一笔出货」可补录当天新单（日期已预填当天）；返回本页自动刷新。
class SaleBatchEditPage extends StatefulWidget {
  const SaleBatchEditPage({
    super.key,
    required this.date,
    required this.lines,
    this.clientId,
  });
  final String date;
  final List<Map<String, dynamic>> lines;
  /// 账本当前店铺筛选（刷新时按同店查询，保持与账本页口径一致）
  final String? clientId;

  @override
  State<SaleBatchEditPage> createState() => _SaleBatchEditPageState();
}

class _SaleBatchEditPageState extends State<SaleBatchEditPage> {
  late List<Map<String, dynamic>> _orders;

  @override
  void initState() {
    super.initState();
    _orders = _groupOrders(widget.lines);
  }

  /// 传入的明细行 → 去重成订单列表（保持账本分组顺序：日期+店名）
  static List<Map<String, dynamic>> _groupOrders(List<Map<String, dynamic>> lines) {
    final orders = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final l in lines) {
      final o = l['order'] as Map<String, dynamic>?;
      if (o == null) continue;
      final id = '${o['id']}';
      if (id.isEmpty || seen.contains(id)) continue;
      seen.add(id);
      orders.add(o);
    }
    return orders;
  }

  /// 订单是否含当天明细（行日期匹配，与账本页按行日期分组的口径一致）
  static bool _inDay(Map<String, dynamic> order, String day) {
    if ('${order['happened_at'] ?? ''}'.startsWith(day)) return true;
    for (final raw in ((order['items'] as List?) ?? [])) {
      final it = raw as Map<String, dynamic>;
      if ('${it['happened_at'] ?? ''}'.startsWith(day)) return true;
    }
    return false;
  }

  /// 从账本页进入后已用过的新数据源：本页打开期间数据可能被记单页改过 → 返回时重新拉取
  Future<void> _refresh() async {
    var orders = <Map<String, dynamic>>[];
    try {
      if (kIsWeb) {
        final params = <String>[
          'date_from=${widget.date}',
          'date_to=${widget.date}',
          if (widget.clientId != null) 'client_id=${widget.clientId}',
        ];
        final d = await Api.instance.get('/sales?${params.join('&')}');
        orders = ((d['sales'] as List?) ?? []).cast<Map<String, dynamic>>();
      } else {
        final all = await LocalDb.getAll('sales');
        orders = [
          for (final o in all)
            if ((widget.clientId == null || '${o['client_id']}' == widget.clientId) && _inDay(o, widget.date))
              o,
        ];
      }
    } catch (_) {
      // 拉取失败：保留进入时的快照（至少能看/能改）
    }
    if (!mounted) return;
    if (orders.isEmpty) orders = _groupOrders(widget.lines);
    setState(() => _orders = orders);
  }

  Future<void> _openOrder(Map<String, dynamic> order) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SalePage(editId: '${order['id']}')));
    _refresh();
  }

  Future<void> _addOrder() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SalePage(initDate: widget.date)));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(
        title: Text('编辑 ${widget.date} · ${_orders.length} 张出货单'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
            child: Text(
              '点某张单 → 进出货记单页：该单所有商品明细完整显示，可直接修改数量/售价/单位/日期/分类并保存；返回自动刷新。',
              style: TextStyle(fontSize: 12, color: c.textSub, height: 1.5),
            ),
          ),
          if (_orders.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text('当天暂无出货单，可点下方「记一笔出货」补录',
                    style: TextStyle(fontSize: 13, color: c.textSub)),
              ),
            ),
          for (final o in _orders) _orderTile(c, o),
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

  Widget _orderTile(TaozhuColors c, Map<String, dynamic> o) {
    final items = ((o['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    final total = (o['total'] as num?)?.toDouble() ??
        items.fold<double>(0, (s, it) => s + ((it['amount'] as num?)?.toDouble() ?? 0));
    final note = '${o['note'] ?? ''}'.trim();
    final name = '${o['client_name'] ?? ''}';
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _openOrder(o),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.primary.withOpacity(0.2)),
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
                  Text(name.isEmpty ? '（未命名店铺）' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.textMain)),
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