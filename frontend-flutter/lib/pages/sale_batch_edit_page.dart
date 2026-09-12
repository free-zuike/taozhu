import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'router.dart';

/// 日期栏批量编辑：该日全部出货明细行。
/// - 逐行：点行尾日期/图标，单独把这一行改到另一天（移出本组）；
/// - 整体：「改期」把该日全部明细一次改到同一天（批量改期）。
/// 保存：原生 = 本地库 + 同步队列（离线可用）；Web = 直连服务器（行级改期端点 / 单据改期）。
class SaleBatchEditPage extends StatefulWidget {
  const SaleBatchEditPage({super.key, required this.date, required this.lines});
  final String date;
  final List<Map<String, dynamic>> lines;

  @override
  State<SaleBatchEditPage> createState() => _SaleBatchEditPageState();
}

class _SaleBatchEditPageState extends State<SaleBatchEditPage> {
  late final List<_Line> _lines;
  bool _saving = false;

  String get _origDate => widget.date;
  int get _changedCount => _lines.where((l) => l.date != _origDate).length;

  @override
  void initState() {
    super.initState();
    _lines = [for (final l in widget.lines) _Line(l)];
  }

  static String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate(_Line l) async {
    final now = DateTime.now();
    final cur = DateTime.tryParse(l.date.isEmpty ? _origDate : l.date) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: cur,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 3, 12, 31),
    );
    if (picked == null) return;
    setState(() => l.date = _fmt(picked));
  }

  /// 一键整体改期：该日全部明细改到同一天
  Future<void> _pickAll() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 3, 12, 31),
    );
    if (picked == null) return;
    final nd = _fmt(picked);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('整体改期'),
        content: Text('把该日 ${_lines.length} 条明细全部改到 $nd？\n（按需逐行也可单独改期）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('全部改到这一天')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      for (final l in _lines) {
        l.date = nd;
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_changedCount == 0) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    try {
      // 按单据（order）分组：一次改一个单据内的相关行
      final byOrder = <String, List<_Line>>{};
      for (final l in _lines) {
        if (l.order == null || l.date == _origDate) continue;
        (byOrder['${l.order!['id']}'] ??= []).add(l);
      }
      for (final e in byOrder.entries) {
        final order = _lines.firstWhere((l) => '${l.order?['id']}' == e.key).order;
        if (order == null) continue;
        if (kIsWeb) {
          // Web 直连：行级改期端点 + 无明细单据走在线 PATCH 改单据日期
          final real = e.value.where((l) => l.itemId.isNotEmpty).toList();
          if (real.isNotEmpty) {
            await Api.instance.post('/sales/items/date', {
              'updates': [
                for (final l in real) {'item_id': l.itemId, 'happened_at': l.date},
              ],
            });
          }
          final notes = e.value.where((l) => l.itemId.isEmpty).toList();
          if (notes.isNotEmpty) {
            await Api.instance.patch('/sales/${order['id']}', {'happened_at': notes.first.date});
          }
        } else {
          // 原生：更新本地库镜像 + 入同步队列（离线可保存，服务器以整单快照应用）
          final items = ((order['items'] as List?) ?? []).cast<Map<String, dynamic>>();
          final updatedItems = <Map<String, dynamic>>[];
          for (final it in items) {
            final itMap = Map<String, dynamic>.from(it);
            for (final l in e.value) {
              if (l.itemId.isNotEmpty && '${it['id']}' == l.itemId) {
                itMap['happened_at'] = l.date;
              }
            }
            updatedItems.add(itMap);
          }
          final payload = Map<String, dynamic>.from(order)..['items'] = updatedItems;
          // 无明细单据：直接改单据日期
          for (final l in e.value) {
            if (l.itemId.isEmpty) payload['happened_at'] = l.date;
          }
          // 单据日期 = 明细最大日期（与记单页口径一致）
          final dates = [
            for (final it in updatedItems)
              '${it['happened_at'] ?? ''}'.isNotEmpty
                  ? '${it['happened_at']}'
                  : '${payload['happened_at'] ?? ''}',
          ];
          if (dates.isNotEmpty) {
            final maxD = dates.reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
            if (maxD.isNotEmpty) payload['happened_at'] = maxD;
          }
          await LocalDb.upsertOne('sales', payload);
          await SyncService.enqueueChange(
              entityType: 'sale', entitySyncId: '${order['id']}', action: 'upsert', payload: payload);
        }
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (err) {
      if (mounted) {
        setState(() => _saving = false);
        toast(context, err.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(
        title: Text('编辑 ${_origDate} · ${_lines.length} 条'),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _pickAll,
            icon: const Icon(Icons.date_range_outlined, size: 18),
            label: const Text('整体改期'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
            child: Text(
              '点行尾日期可单独改这一条；「整体改期」把该日全部明细改到同一天。改期不影响金额与库存。',
              style: TextStyle(fontSize: 12, color: c.textSub, height: 1.5),
            ),
          ),
          for (final l in _lines)
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _pickDate(l),
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 2),
                padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                decoration: BoxDecoration(
                  color: c.card,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: l.date != _origDate ? c.primary : c.primary.withOpacity(0.2)),
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
                            l.client.isEmpty ? l.name : '${l.client} · ${l.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textMain),
                          ),
                          Text(
                            l.itemId.isEmpty
                                ? '备注行 · ¥${fmtMoney(l.amount)}'
                                : '${l.name} ×${l.qty}${l.unit} · ¥${fmtMoney(l.amount)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: c.textSub),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      l.date == _origDate ? l.date : '→ ${l.date}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: l.date != _origDate ? c.danger : c.textSub,
                      ),
                    ),
                    IconButton(
                      tooltip: '改这一条的日期',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.edit_calendar_outlined, size: 18, color: c.primary),
                      onPressed: () => _pickDate(l),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: c.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _saving || _changedCount == 0 ? null : _save,
            child: Text(_saving
                ? '保存中…'
                : _changedCount > 0
                    ? '保存 $_changedCount 条改期'
                    : '未修改'),
          ),
        ),
      ),
    );
  }
}

/// 流水行副本（改动只在本页生效，保存时才写库）
class _Line {
  _Line(Map<String, dynamic> l)
      : order = l['order'] as Map<String, dynamic>?,
        itemId = '${l['item_id'] ?? ''}',
        name = '${l['item_name'] ?? ''}',
        client = '${l['client_name'] ?? ''}',
        qty = '${l['quantity'] ?? ''}',
        unit = '${l['unit'] ?? ''}',
        amount = ((l['amount'] as num?)?.toDouble() ?? 0),
        date = '${l['date'] ?? ''}';
  final Map<String, dynamic>? order;
  final String itemId;
  final String name;
  final String client;
  final String qty;
  final String unit;
  final double amount;
  String date;
}