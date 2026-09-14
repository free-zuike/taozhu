import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'router.dart';
import 'purchase_page.dart';
import 'purchase_line_edit.dart';
import 'purchase_batch_edit_page.dart';
import 'attachment_viewer.dart';

/// 进货记录：按日期分组的进货流水（不分店），卡片明细直接展开，可编辑/删除/附件
class PurchaseHistoryPage extends StatefulWidget {
  const PurchaseHistoryPage({super.key});
  @override
  State<PurchaseHistoryPage> createState() => _PurchaseHistoryPageState();
}

class _PurchaseHistoryPageState extends State<PurchaseHistoryPage> {
  String _range = 'month'; // month | all
  List<Map<String, dynamic>> _purchases = [];
  bool _loading = true;
  bool _offline = false;
  /// 商品 id → 分类名（流水行分类显示：优先查询商品设置分类，明细行快照仅兜底）
  Map<String, String> _itemCategory = {};

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
    final from = _fmt(DateTime(now.year, now.month, 1));
    return 'date_from=$from&date_to=$today';
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    // ① 本地库秒开（含空态；不再等网络转圈）
    final local = await LocalDb.getAll('purchases');
    // 商品目录分类映射：流水行分类优先查询商品设置分类（改动即时生效），明细快照仅兜底
    final catMap = <String, String>{};
    try {
      for (final x in await LocalDb.getAllByName('items')) {
        catMap['${x['id']}'] = '${x['category'] ?? ''}';
      }
    } catch (_) {}
    // Web 端 LocalDb 恒空：跳过空渲染，避免删除/同步通知时列表"空白→填充"跳动；仅本地有数据才先渲染
    if ((!kIsWeb || local.isNotEmpty) && mounted) {
      setState(() {
        _purchases = _filterByRange(local);
        _itemCategory = catMap;
        _loading = false;
      });
    }
    // 原生本地化：列表页刷新只读本地，同步只由「我的」页/进应用自动同步驱动。
    if (kIsWeb) {
      // ② Web（无本地库）：直连服务器刷新（静默；失败保留本地展示）
      try {
        final d = await Api.instance.get('/purchases?${_dateQuery()}&limit=500');
        if (!mounted) return;
        final rows = ((d['purchases'] as List?) ?? []).cast<Map<String, dynamic>>();
        await LocalDb.upsertList('purchases', rows);
        if (!mounted) return;
        setState(() {
          _purchases = _filterByRange(rows);
          _itemCategory = catMap;
          _loading = false;
          _offline = false;
        });
      } catch (_) {
        // 离线：本地缓存已展示，错误已记日志，不再弹提示
        if (!mounted) return;
        setState(() {
          _loading = false;
          _offline = local.isEmpty;
        });
      }
    }
  }

  /// 本地全量镜像按当前范围过滤（与网络接口的 date_from/date_to 一致）
  List<Map<String, dynamic>> _filterByRange(List<Map<String, dynamic>> rows) {
    if (_range == 'all') return rows;
    final now = DateTime.now();
    final from = _fmt(DateTime(now.year, now.month, 1));
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

  /// 点明细行 → 只编辑当前商品（数量/进价/单位/日期，弹窗即时保存）
  Future<void> _editPurchaseLine(Map<String, dynamic> p, Map<String, dynamic> it) async {
    await editPurchaseLine(context, p, it);
    _load();
  }

  /// 日期栏 → 该日进货单列表（点单进进货记单页编辑该单全部商品明细）
  Future<void> _openBatchEdit(String date, List<Map<String, dynamic>> purchases) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PurchaseBatchEditPage(date: date, purchases: purchases)));
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
      // 同步删本地库镜像行（否则残留 → 下次打开"删不掉"，本地与 Web 不一致）
      await LocalDb.deleteOne('purchases', '${p['id']}');
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

  /// 进货流水行：三行卡片 —— ①商品名称+备注 ②商品分类+行级附件（常驻入口）③数量·进价·金额
  Widget _lineTile(TaozhuColors c, Map<String, dynamic> l) {
    final order = l['order'] as Map<String, dynamic>;
    final itemName = '${l['item_name'] ?? ''}';
    final qty = '${l['quantity'] ?? ''}';
    final unit = '${l['unit'] ?? ''}';
    final note = '${l['note'] ?? ''}'.trim();
    final category = '${l['category'] ?? ''}'.trim();
    final rowId = '${l['row_id'] ?? ''}';
    final pp = (l['purchase_price'] as num?)?.toDouble() ?? 0;
    final priceLine = StringBuffer();
    if (pp > 0) priceLine.write('进价 ¥${fmtMoney(pp)} · ');
    priceLine.write('数量 ×$qty$unit');
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      // 点行 = 只编辑当前商品（数量/进价/单位/日期）；长按 = 删除整单
      onTap: () {
        final line = Map<String, dynamic>.from(l)..['id'] = rowId;
        if (rowId.isEmpty) {
          _editPurchase(order);
        } else {
          _editPurchaseLine(order, line);
        }
      },
      onLongPress: () => _deletePurchase(order),
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
                  // ① 商品名称 + 备注
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: itemName.isEmpty ? '（无明细）' : itemName,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.textMain),
                      ),
                      if (note.isNotEmpty)
                        TextSpan(
                          text: '  $note',
                          style: TextStyle(fontSize: 11, color: c.textSub),
                        ),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // ② 商品分类 + 行级附件（常驻入口：点开查看/添加该行独立凭证）
                  Row(
                    children: [
                      Icon(Icons.label_outline, size: 12, color: c.textSub),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          category.isEmpty ? '未分类' : category,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: c.textSub),
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () async {
                          await showAttachmentViewer(
                              context, rowId.isEmpty ? 'purchase' : 'purchase_item',
                              rowId.isEmpty ? '${order['id']}' : rowId,
                              rowId.isEmpty ? '进货单附件' : '进货明细行附件');
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(Icons.image_outlined, size: 15, color: c.textSub.withOpacity(0.5)),
                        ),
                      ),
                    ],
                  ),
                  // ③ 进价 · 数量单位（允许换行）
                  Text(priceLine.toString(),
                      style: TextStyle(fontSize: 12, color: c.textSub)),
                ],
              ),
            ),
            Text('¥${fmtMoney((l['amount'] as num?)?.toDouble() ?? 0)}',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.danger)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 14, color: c.textSub),
          ],
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

  /// 进货流水行（商品明细铺开）：按明细行日期分组，每行一条商品。
  /// 点行编辑该商品；长按=删除整单；行内附件=该条商品独立凭证。
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
    // 展开为明细行：行日期回退单据日期；无明细的单据显示备注/占位行
    final lines = <Map<String, dynamic>>[];
    for (final p in _purchases) {
      final orderDate = _date(p['happened_at']);
      final orderNote = '${p['note'] ?? ''}'.trim();
      final items = ((p['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (items.isEmpty) {
        lines.add({
          'date': orderDate, 'order': p,
          'item_name': '（无明细）', 'note': orderNote, 'category': '',
          'quantity': '', 'unit': '', 'amount': ((p['total'] as num?)?.toDouble() ?? 0),
          'id': '', 'row_id': '', 'purchase_price': 0,
          'happened_at': '${p['happened_at'] ?? orderDate}',
        });
      }
      for (final it in items) {
        final id = '${it['happened_at'] ?? ''}';
        final itemId = '${it['item_id'] ?? ''}';
        // 分类：优先查询商品设置分类（目录映射，改分类即时生效），明细快照仅兜底
        final dirCat = _itemCategory[itemId] ?? '';
        final catInline = '${it['item_category'] ?? ''}'.trim();
        lines.add({
          'date': id.length >= 10 ? id.substring(0, 10) : orderDate,
          'order': p,
          'item_name': '${it['item_name'] ?? ''}',
          'item_id': itemId,  // 真实商品 id（改分类等商品级操作用）
          'note': orderNote,
          'category': dirCat.isNotEmpty ? dirCat : catInline,
          'quantity': '${it['quantity'] ?? ''}',
          'unit': '${it['unit'] ?? ''}',
          'amount': ((it['amount'] as num?)?.toDouble() ?? 0),
          'id': '${it['id'] ?? ''}',       // 明细行 id（行级附件/编辑用）
          'row_id': '${it['id'] ?? ''}',   // 同 id，行级附件回退判断用
          'purchase_price': (it['purchase_price'] as num?)?.toDouble() ?? 0,
          'happened_at': '${it['happened_at'] ?? p['happened_at'] ?? orderDate}',
        });
      }
    }
    // 按行日期分组
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final l in lines) {
      (grouped['${l['date']}'] ??= []).add(l);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [
          for (final e in grouped.entries) ...[
            // 日期栏 = 该日进货单列表编辑入口（点单整单编辑；点明细行单笔编辑）
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _openBatchEdit(e.key, _ordersOfDay(e.value)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 4, 2),
                child: Row(
                  children: [
                    Icon(Icons.edit_calendar_outlined, size: 15, color: c.success),
                    const SizedBox(width: 4),
                    Text(_weekday(e.key),
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: c.textMain)),
                    const Spacer(),
                    Text(
                      '${e.value.length} 条 · 合计 ¥${fmtMoney(e.value.fold<double>(0, (s, l) => s + ((l['amount'] as num?)?.toDouble() ?? 0)))}',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: c.textSub),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right, size: 16, color: c.textSub),
                  ],
                ),
              ),
            ),
            for (final l in e.value) _lineTile(c, l),
          ],
        ],
      ),
    );
  }

  /// 由该日明细行还原所属进货单列表（日期栏批量编辑页按整单展示）
  List<Map<String, dynamic>> _ordersOfDay(List<Map<String, dynamic>> lines) {
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
}
