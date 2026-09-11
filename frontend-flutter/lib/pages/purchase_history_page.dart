import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'router.dart';
import 'purchase_page.dart';
import 'attachment_panel.dart';

/// 进货记录：按日期分组的进货流水（不分店），卡片明细直接展开，可编辑/删除/附件
class PurchaseHistoryPage extends StatefulWidget {
  const PurchaseHistoryPage({super.key});
  @override
  State<PurchaseHistoryPage> createState() => _PurchaseHistoryPageState();
}

class _PurchaseHistoryPageState extends State<PurchaseHistoryPage> {
  String _range = 'month'; // month | 2m | 3m | all
  List<Map<String, dynamic>> _purchases = [];
  bool _loading = true;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    SyncService.version.addListener(_onSync);
    _load();
  }

  @override
  void dispose() {
    SyncService.version.removeListener(_onSync);
    super.dispose();
  }

  void _onSync() {
    if (mounted) _load();
  }

  String _dateQuery() {
    final now = DateTime.now();
    final today = _fmt(now);
    if (_range == 'all') return 'date_from=1970-01-01&date_to=$today';
    final months = _range == '2m' ? 1 : (_range == '3m' ? 2 : 0);
    final from = _fmt(DateTime(now.year, now.month - months, 1));
    return 'date_from=$from&date_to=$today';
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    // ① 本地库秒开（含空态；不再等网络转圈）
    final local = await LocalDb.getAll('purchases');
    if (mounted) {
      setState(() {
        _purchases = _filterByRange(local);
        _loading = false;
      });
    }
    // ② 网络刷新 + 写本地库（静默；失败保留本地展示）
    try {
      final d = await Api.instance.get('/purchases?${_dateQuery()}&limit=500');
      if (!mounted) return;
      final rows = ((d['purchases'] as List?) ?? []).cast<Map<String, dynamic>>();
      await LocalDb.upsertList('purchases', rows);
      if (!mounted) return;
      setState(() {
        _purchases = _filterByRange(rows);
        _loading = false;
        _offline = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _offline = local.isEmpty;
      });
      if (local.isEmpty) toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 本地全量镜像按当前范围过滤（与网络接口的 date_from/date_to 一致）
  List<Map<String, dynamic>> _filterByRange(List<Map<String, dynamic>> rows) {
    if (_range == 'all') return rows;
    final now = DateTime.now();
    final months = _range == '2m' ? 1 : (_range == '3m' ? 2 : 0);
    final from = _fmt(DateTime(now.year, now.month - months, 1));
    final to = _fmt(now);
    return rows.where((x) {
      final d = _date(x['happened_at']);
      return d.isNotEmpty && d.compareTo(from) >= 0 && d.compareTo(to) <= 0;
    }).toList();
  }

  String _date(Object? v) {
    final s = '$v';
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  Future<void> _editPurchase(Map<String, dynamic> p) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PurchasePage(editId: '${p['id']}')));
    _load();
  }

  Future<void> _deletePurchase(Map<String, dynamic> p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除进货单'),
        content: Text('删除 ${_date(p['happened_at'])} 的这笔进货单？库存将自动回滚。'),
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
      await Api.instance.delete('/purchases/${p['id']}');
      toast(context, '已删除，库存已回滚');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  String _weekday(String date) {
    final d = DateTime.tryParse(date);
    if (d == null) return date;
    const wd = ['一', '二', '三', '四', '五', '六', '日'];
    return '$date 周${wd[d.weekday - 1]}';
  }

  Widget _menu(Map<String, dynamic> p) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_vert, size: 18, color: c.textSub),
      onSelected: (v) {
        if (v == 'attach') showAttachmentPanel(context, 'purchase', '${p['id']}', '进货单附件');
        if (v == 'edit') _editPurchase(p);
        if (v == 'del') _deletePurchase(p);
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'attach', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.attachment_outlined, size: 18), title: Text('附件'))),
        PopupMenuItem(value: 'edit', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.edit_outlined, size: 18), title: Text('编辑'))),
        PopupMenuItem(value: 'del', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.delete_outline, size: 18, color: Color(0xFFEF4444)), title: Text('删除', style: TextStyle(color: Color(0xFFEF4444))))),
      ],
    );
  }

  Widget _card(Map<String, dynamic> p) {
    final items = ((p['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    final note = (p['note'] as String? ?? '').trim();
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      elevation: 0,
      color: c.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.success.withOpacity(0.3)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _editPurchase(p),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: c.success.withOpacity(0.12),
                child: Icon(Icons.shopping_cart, size: 16, color: c.success),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  note.isNotEmpty ? note : (items.isNotEmpty ? '${items.first['item_name']} 等 ${items.length} 项' : '进货单'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.textMain),
                ),
              ),
              Text('¥${fmtMoney(p['total'])}',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.danger)),
              _menu(p),
            ]),
            for (final it in items)
              Padding(
                padding: const EdgeInsets.only(left: 40, top: 2),
                child: Row(children: [
                  Expanded(
                    child: Text('${it['item_name']} ×${it['quantity']}${it['unit']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: c.textSub)),
                  ),
                  Text('¥${fmtMoney(it['amount'])}',
                      style: TextStyle(fontSize: 13, color: c.textSub)),
                  const SizedBox(width: 8),
                ]),
              ),
            if (note.isNotEmpty) const SizedBox(height: 2),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('进货记录')),
      body: Column(
        children: [
          if (_offline)
            Container(
              width: double.infinity,
              color: const Color(0xFFE6A23C).withOpacity(0.12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: const Row(
                children: [
                  Icon(Icons.wifi_off, size: 16, color: Color(0xFFE6A23C)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('无法连接服务器，请检查网络后重试',
                        style: TextStyle(fontSize: 12, color: Color(0xFFB88230))),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final r in const [
                    ('month', '当月'),
                    ('2m', '最近2个月'),
                    ('3m', '最近3个月'),
                    ('all', '全部'),
                  ])
                    ChoiceChip(
                      label: Text(r.$2, style: const TextStyle(fontSize: 13)),
                      visualDensity: VisualDensity.compact,
                      selected: _range == r.$1,
                      onSelected: (_) {
                        setState(() => _range = r.$1);
                        _load();
                      },
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _buildList(),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    if (_purchases.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.all(48),
              child: Column(
                children: [
                  const Icon(Icons.shopping_cart_outlined, size: 40, color: Color(0xFFD0D5DD)),
                  const SizedBox(height: 12),
                  Text('暂无进货记录', style: TextStyle(color: c.textSub)),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: c.success,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const PurchasePage()))
                        .then((_) => _load()),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('＋ 记一笔进货'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final r in _purchases) {
      final d = _date(r['happened_at']);
      (grouped[d] ??= []).add(r);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [
          for (final e in grouped.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 14, 4, 2),
              child: Row(
                children: [
                  Text(_weekday(e.key),
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: c.textMain)),
                  const Spacer(),
                  Text(
                    '${e.value.length} 笔 · 合计 ¥${fmtMoney(e.value.fold<double>(0, (s, r) => s + ((r['total'] as num?)?.toDouble() ?? 0)))}',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: c.textSub),
                  ),
                ],
              ),
            ),
            for (final r in e.value) _card(r),
          ],
        ],
      ),
    );
  }
}
