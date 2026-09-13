import 'package:flutter/material.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'sale_line_edit.dart';
import 'sale_page.dart';

/// 日期栏编辑页：该日全部出货明细行（跨店铺）。
/// 点某一行 → 弹窗编辑该商品（数量/售价/单位/日期），修改即时保存（Web 行级端点 / 原生本地库+同步队列）；
/// 返回后账本页自动刷新分组。
class SaleBatchEditPage extends StatefulWidget {
  const SaleBatchEditPage({super.key, required this.date, required this.lines});
  final String date;
  final List<Map<String, dynamic>> lines;

  @override
  State<SaleBatchEditPage> createState() => _SaleBatchEditPageState();
}

class _SaleBatchEditPageState extends State<SaleBatchEditPage> {
  late final List<Map<String, dynamic>> _lines;

  @override
  void initState() {
    super.initState();
    _lines = widget.lines;
  }

  /// 点行 → 编辑该商品；保存后用最新整单快照回填同单的所有行（金额/日期可能已联动变化，
  /// 同单其他行的 order 引用也要换成新快照，避免后续编辑基于旧快照覆盖本次改动）
  Future<void> _editLine(Map<String, dynamic> l) async {
    // 无明细的备注行没有可编辑的商品：回退整单编辑，保存后关闭本页由账本页刷新
    if ('${l['item_id'] ?? ''}'.isEmpty) {
      final order = l['order'] as Map<String, dynamic>;
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => SalePage(editId: '${order['id']}')));
      if (mounted) Navigator.of(context).pop(true);
      return;
    }
    final updated = await editSaleLine(context, l);
    if (updated == null || !mounted) return;
    setState(() {
      final orderId = '${updated['id']}';
      for (final line in _lines) {
        final o = line['order'] as Map<String, dynamic>?;
        if ('${o?['id']}' != orderId) continue;
        line['order'] = updated;
        final itemId = '${line['item_id'] ?? ''}';
        if (itemId.isEmpty) continue;
        for (final raw in ((updated['items'] as List?) ?? [])) {
          final it = raw as Map<String, dynamic>;
          if ('${it['id']}' != itemId) continue;
          line['quantity'] = '${it['quantity'] ?? ''}';
          line['unit'] = '${it['unit'] ?? ''}';
          line['amount'] = (it['amount'] as num?)?.toDouble() ?? 0;
          line['sale_price'] = (it['sale_price'] as num?)?.toDouble();
          final h = '${it['happened_at'] ?? ''}';
          line['happened_at'] = h;
          line['date'] = h.length >= 10 ? h.substring(0, 10) : '${line['date']}';
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(
        title: Text('编辑 ${widget.date} · ${_lines.length} 条'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
            child: Text(
              '点某一行可修改该商品的数量、售价、单位或日期，修改即时保存；返回后账本页自动刷新。',
              style: TextStyle(fontSize: 12, color: c.textSub, height: 1.5),
            ),
          ),
          for (final l in _lines)
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _editLine(l),
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 2),
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
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
                          Text(
                            '${l['client_name'] ?? ''}'.isEmpty
                                ? '${l['item_name'] ?? ''}'
                                : '${l['client_name']} · ${l['item_name']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textMain),
                          ),
                          Text(
                            '${l['item_id'] ?? ''}'.isEmpty
                                ? '备注行 · ¥${fmtMoney((l['amount'] as num?)?.toDouble() ?? 0)}'
                                : '×${l['quantity'] ?? ''}${l['unit'] ?? ''} · ¥${fmtMoney((l['amount'] as num?)?.toDouble() ?? 0)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: c.textSub),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${l['date'] ?? widget.date}',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.textSub),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right, size: 16, color: c.textSub),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
