import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import '../widgets/center_sheet.dart';
import 'router.dart';

/// 库存：按 商品+单位 查看/预警/调整（进货自动入库、出货自动扣减，见单据页）
class StocksPage extends StatefulWidget {
  const StocksPage({super.key});
  @override
  State<StocksPage> createState() => _StocksPageState();
}

class _StocksPageState extends State<StocksPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  List<Map<String, dynamic>> _stocks = [];
  bool _canSeeCost = true; // 店员不可见成本核算（后端 cost_price 打码）
  bool _loading = true;
  bool _belowOnly = false; // 只看预警（低于阈值）
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    // 本地优先：页面加载只读本地库镜像（零网络）；同步完成后（version 通知）再刷新。
    // 库存以服务端为准（盘点/多端变动），但本地有 fullSync 写入的 stocks 镜像，先秒开再静默校准
    SyncService.version.addListener(_onSync);
    _load();
  }

  @override
  void dispose() {
    SyncService.version.removeListener(_onSync);
    _searchTimer?.cancel();
    super.dispose();
  }

  void _onSync() {
    if (mounted) _load(network: true);
  }

  Future<void> _load({bool network = false, String q = '', bool below = false}) async {
    // 原生：零网络读本地库镜像（fullSync 写入的 stocks 行），离线/慢网秒开
    if (!kIsWeb) {
      try {
        var local = await LocalDb.getAll('stocks');
        if (q.isNotEmpty) {
          local = local.where((s) => '${s['item_name'] ?? ''}'.contains(q)).toList();
        }
        if (below) {
          local = local.where((s) => ((s['low'] == true))).toList();
        }
        local.sort((a, b) => '${a['item_name'] ?? ''}'.compareTo('${b['item_name'] ?? ''}'));
        if (mounted) {
          setState(() {
            _stocks = local;
            _loading = false;
          });
        }
        if (!network) return; // 页面加载不加网络；同步完成（version 通知）传 network:true 才校准
      } catch (_) {
        setState(() => _loading = false);
      }
    }
    // ① 缓存兜底秒开（Web/原生无本地镜像时先展示上次数据，不再无限转圈）
    if (!below && q.isEmpty) {
      final cached = await Api.instance.getCachedRaw('/stocks');
      if (cached != null && mounted) {
        _canSeeCost = cached['can_see_cost'] != false;
        setState(() {
          _stocks = ((cached['stocks'] as List?) ?? []).cast<Map<String, dynamic>>();
          _loading = false;
        });
      }
    }
    // ② 网络刷新 + 写缓存：仅同步完成/下拉/Web 直连时执行，页面加载不发请求（本地优先）
    if (!network && !kIsWeb) return;
    try {
      final params = <String>[];
      if (q.isNotEmpty) params.add('q=${Uri.encodeQueryComponent(q)}');
      if (below) params.add('below=1');
      final query = params.isEmpty ? '' : '?${params.join('&')}';
      final d = await Api.instance.get('/stocks$query');
      if (!below && q.isEmpty) await Api.instance.setCache('/stocks', d);
      // 网络结果同时回写本地镜像（下次离线秒开）
      if (!kIsWeb) {
        try {
          await LocalDb.putAll('stocks', ((d['stocks'] as List?) ?? []).cast<Map<String, dynamic>>());
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _stocks = ((d['stocks'] as List?) ?? []).cast<Map<String, dynamic>>();
        _canSeeCost = d['can_see_cost'] != false;
        _loading = false;
      });
    } catch (_) {
      // 离线：本地镜像/缓存已展示，错误已记日志，不再弹提示
      setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    if (kIsWeb) {
      await _load(network: true, q: '', below: _belowOnly);
    } else {
      // 原生下拉刷新：优先本地镜像，再静默网络校准（同步动作仍走同步状态页，此处仅展示刷新）
      await _load(network: true, q: '', below: _belowOnly);
    }
  }

  /// 盘点阈值默认值：已有手设阈值（>0）保留；未设置且库存≥1 时自动带出建议值
  /// （后端 suggest_min = 近 30 天平均每笔出货量 × 40%，无出货记录为 0）；既不设也无建议 → 0
  static String _defaultMin(Map<String, dynamic>? cur) {
    final hand = (cur?['min_stock'] as num?)?.toDouble() ?? 0;
    if (hand > 0) return hand.toString();
    final suggest = (cur?['suggest_min'] as num?)?.toDouble() ?? 0;
    if (suggest > 0) return suggest.toString();
    return '0';
  }

  /// 单行编辑：数量 / 预警阈值
  Future<void> _edit(Map<String, dynamic> s) async {
    final qtyCtrl = TextEditingController(text: '${s['quantity']}');
    final minCtrl = TextEditingController(text: '${s['min_stock']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${s['item_name']}（${s['unit']}）'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: qtyCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: '库存数量'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: minCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: '低库存预警阈值'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final qty = double.tryParse(qtyCtrl.text.trim());
    final min = double.tryParse(minCtrl.text.trim());
    if (qty == null || qty < 0 || min == null || min < 0) {
      toast(context, '数量与阈值须为非负数字');
      return;
    }
    try {
      await Api.instance.patch('/stocks/${s['id']}', {'quantity': qty, 'min_stock': min});
      toast(context, '已保存');
      SyncService.notifyStockChanged(); // 我的页低库存红字实时刷新
      _refresh();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 盘点弹层：列出所有商品价格单位，填写/修改库存与阈值，批量保存（可初始化期初库存）
  Future<void> _count() async {
    try {
      final items = await Api.instance.get('/items');
      final stocks = await Api.instance.get('/stocks');
      final itemRows = ((items['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      final stockMap = <String, Map<String, dynamic>>{};
      for (final s in ((stocks['stocks'] as List?) ?? []).cast<Map<String, dynamic>>()) {
        stockMap['${s['item_id']}/${s['unit']}'] = s;
      }
      // 展开 商品×单位
      final rows = <Map<String, dynamic>>[];
      for (final it in itemRows) {
        for (final p in ((it['prices'] as List?) ?? []).cast<Map<String, dynamic>>()) {
          final key = '${it['id']}/${p['unit']}';
          final cur = stockMap[key];
          rows.add({
            'item_id': it['id'],
            'item_name': it['name'],
            'unit': p['unit'],
            'quantity': cur?['quantity'] ?? '0',
            // 阈值：已有手设值保留；未设置（0）且库存≥1 时自动带出建议值（近30天平均出货×40%）
            'min_stock': _defaultMin(cur),
          });
        }
      }
      if (rows.isEmpty) {
        toast(context, '暂无商品，请先添加商品与价格');
        return;
      }
      // 弹层内用本地可变状态
      final ctrls = rows
          .map((r) => {
                'qty': TextEditingController(text: '${r['quantity']}'),
                'min': TextEditingController(text: '${r['min_stock']}'),
              })
          .toList();
      final saved = await showCenterSheet<bool>(
        context: context,
        maxHeightFactor: 0.9,
        builder: (ctx) => Column(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('库存盘点', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            ),
            Flexible(
              child: ListView.builder(
                itemCount: rows.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('${rows[i]['item_name']}（${rows[i]['unit']}）',
                            style: const TextStyle(fontSize: 13)),
                      ),
                      SizedBox(
                        width: 84,
                        child: TextField(
                          controller: ctrls[i]['qty'],
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: '库存', isDense: true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 84,
                        child: TextField(
                          controller: ctrls[i]['min'],
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: '阈值', isDense: true),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存盘点'),
              ),
            ),
          ],
        ),
      );
      if (saved != true) {
        for (final c in ctrls) {
          c['qty']!.dispose();
          c['min']!.dispose();
        }
        return;
      }
      final payload = <Map<String, dynamic>>[];
      for (var i = 0; i < rows.length; i++) {
        final qty = double.tryParse(ctrls[i]['qty']!.text.trim());
        final min = double.tryParse(ctrls[i]['min']!.text.trim());
        if (qty == null || qty < 0) continue;
        payload.add({
          'item_id': rows[i]['item_id'],
          'unit': rows[i]['unit'],
          'quantity': qty,
          'min_stock': (min == null || min < 0) ? 0 : min,
        });
      }
      for (final c in ctrls) {
        c['qty']!.dispose();
        c['min']!.dispose();
      }
      if (payload.isEmpty) {
        toast(context, '没有有效的盘点数据');
        return;
      }
      await Api.instance.put('/stocks', {'rows': payload});
      toast(context, '盘点已保存');
      SyncService.notifyStockChanged(); // 我的页低库存红字实时刷新
      _refresh();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

    /// 全量重算库存：从进货(+)出货(−)流水重建（历史 App 行级同步在旧版无库存联动，升级后一次性回补）
  Future<void> _rebuildStock() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重算库存'),
        content: const Text('按全部进货/出货流水重新计算每个商品+单位的库存（保留预警阈值）。\n用于修复历史数据：旧版本 App 端添加的进货/出货未联动库存。\n\n确认重算？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重算'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 本地优先：原生端从本地行级流水（进货/出货，含换算 count_qty 折算）本地重算，不访问网络；
    // Web 无本地库才走服务端全量重算端点。
    if (!kIsWeb) {
      try {
        final rebuilt = await _localRebuild();
        await LocalDb.putAll('stocks', rebuilt);
        if (mounted) {
          setState(() {
            _stocks = rebuilt;
            _loading = false;
          });
        }
        toast(context, '已本地重算 ${rebuilt.length} 个商品库存');
        SyncService.notifyStockChanged();
        return;
      } catch (e) {
        toast(context, '本地重算失败：${e.toString().replaceFirst('Exception: ', '')}');
        return;
      }
    }
    try {
      final r = await Api.instance.post('/stocks/rebuild', {});
      toast(context, '已重算 ${r['rebuilt'] ?? 0} 个商品库存');
      SyncService.notifyStockChanged();
      _refresh();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 本地重算库存：从本地进货(+)出货(−)流水聚合（含单位换算 count_qty 折算、计数单位归并），保留旧阈值。
  /// 与服务器 rebuild 口径一致：单位=商品计数单位（无则行单位），数量=count_qty（无则 quantity）。
  Future<List<Map<String, dynamic>>> _localRebuild() async {
    final items = await LocalDb.getAll('items');
    final countUnitOf = {for (final it in items) '${it['id']}': '${it['count_unit'] ?? ''}'};
    final nameOf = {for (final it in items) '${it['id']}': '${it['name'] ?? ''}'};
    // old 阈值保留 key = item\0unit（按重算后的单位维度）
    final oldStocks = await LocalDb.getAll('stocks');
    final minMap = <String, double>{};
    for (final s in oldStocks) {
      minMap['${s['item_id']}\u0000${s['unit']}'] = ((s['min_stock'] as num?)?.toDouble() ?? 0);
    }
    // 聚合：进货 + / 出货 −（按 商品+计数单位 维度）
    final agg = <String, double>{};
    void add(String itemId, String rowUnit, double qty) {
      final cu = countUnitOf[itemId]?.isNotEmpty == true ? countUnitOf[itemId]! : rowUnit;
      final key = '$itemId\u0000$cu';
      agg[key] = (agg[key] ?? 0) + qty;
    }
    for (final b in await LocalDb.getAll('purchase_items')) {
      final qty = (double.tryParse('${b['count_qty'] ?? ''}') ?? 0) > 0
          ? double.parse('${b['count_qty']}')
          : ((b['quantity'] as num?)?.toDouble() ?? 0);
      add('${b['item_id']}', '${b['unit'] ?? ''}', qty);
    }
    for (final s in await LocalDb.getAll('sale_items')) {
      final qty = (double.tryParse('${s['count_qty'] ?? ''}') ?? 0) > 0
          ? double.parse('${s['count_qty']}')
          : ((s['quantity'] as num?)?.toDouble() ?? 0);
      add('${s['item_id']}', '${s['unit'] ?? ''}', -qty);
    }
    final out = <Map<String, dynamic>>[];
    for (final e in agg.entries) {
      final sep = e.key.indexOf('\u0000');
      final itemId = e.key.substring(0, sep);
      final unit = e.key.substring(sep + 1);
      final min = minMap[e.key] ?? 0;
      out.add({
        'id': null,
        'item_id': itemId,
        'unit': unit,
        'item_name': nameOf[itemId] ?? '',
        'quantity': e.value,
        'min_stock': min,
        'low': e.value < min,
        'cost_price': 0,
        'can_see_cost': true,
      });
    }
    out.sort((a, b) => '${a['item_name'] ?? ''}'.compareTo('${b['item_name'] ?? ''}'));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('库存'),
        actions: [
          IconButton(tooltip: '盘点', icon: const Icon(Icons.edit_note_outlined), onPressed: _count),
          IconButton(
            tooltip: '重算库存（从进货/出货流水重建，保留阈值）',
            icon: const Icon(Icons.autorenew),
            onPressed: _rebuildStock,
          ),
          IconButton(
            tooltip: '只看预警',
            icon: Icon(Icons.notification_important_outlined,
                color: _belowOnly ? _c.danger : null),
            onPressed: () => setState(() {
              _belowOnly = !_belowOnly;
              _refresh();
            }),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: '搜索商品',
                isDense: true,
              ),
              onChanged: (v) {
                _searchTimer?.cancel();
                _searchTimer = Timer(const Duration(milliseconds: 350), () {
                  _load(q: v.trim(), below: _belowOnly);
                });
              },
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_stocks.isNotEmpty && _canSeeCost)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                Text('库存金额合计（按当前进价）',
                                    style: TextStyle(fontSize: 12, color: _c.textSub)),
                                const Spacer(),
                                Text(
                                  '¥${fmtMoney(_stocks.fold<double>(0, (s, x) => s + (((x['quantity'] as num?)?.toDouble() ?? 0) * ((x['cost_price'] as num?)?.toDouble() ?? 0))))}',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _c.success),
                                ),
                              ],
                            ),
                          ),
                        if (_stocks.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Center(child: Text('暂无库存记录\n进货后自动入库，可点右上角盘点初始化', textAlign: TextAlign.center, style: TextStyle(color: _c.textSub))),
                          ),
                        for (final s in _stocks)
                          Card(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            elevation: 0,
                            color: (s['low'] == true)
                                ? _c.danger.withOpacity(0.1)
                                : _c.card,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                  color: s['low'] == true ? _c.danger.withOpacity(0.5) : _c.divider),
                            ),
                            child: ListTile(
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundColor: (s['low'] == true
                                        ? _c.danger
                                        : _c.success)
                                    .withOpacity(0.12),
                                child: Icon(
                                  s['low'] == true ? Icons.warning_amber_outlined : Icons.inventory_2_outlined,
                                  size: 16,
                                  color: s['low'] == true ? _c.danger : _c.success,
                                ),
                              ),
                              title: Text('${s['item_name']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                              subtitle: Text('还剩 ${s['quantity']} ${s['unit']} · 阈值 ${s['min_stock']} ${s['unit']}',
                                  style: TextStyle(fontSize: 12, color: _c.textSub)),
                              trailing: Text(
                                '${s['quantity']} ${s['unit']}',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: s['low'] == true ? _c.danger : _c.success,
                                ),
                              ),
                              onTap: () => _edit(s),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}