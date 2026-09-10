import 'dart:async';
import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';
import '../utils/money.dart';
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
  bool _loading = true;
  bool _belowOnly = false; // 只看预警（低于阈值）
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({String q = '', bool below = false}) async {
    try {
      final params = <String>[];
      if (q.isNotEmpty) params.add('q=${Uri.encodeQueryComponent(q)}');
      if (below) params.add('below=1');
      final query = params.isEmpty ? '' : '?${params.join('&')}';
      final d = await Api.instance.get('/stocks$query');
      if (!mounted) return;
      setState(() {
        _stocks = ((d['stocks'] as List?) ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _refresh() => _load(q: '', below: _belowOnly);

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
            'min_stock': cur?['min_stock'] ?? '0',
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
      final saved = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (ctx) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.85,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('库存盘点', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                ),
                Expanded(
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
          ),
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
      _refresh();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('库存'),
        actions: [
          IconButton(tooltip: '盘点', icon: const Icon(Icons.edit_note_outlined), onPressed: _count),
          IconButton(
            tooltip: '只看预警',
            icon: Icon(Icons.notification_important_outlined,
                color: _belowOnly ? const Color(0xFFF56C6C) : null),
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
                        if (_stocks.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                const Text('库存金额合计（按当前进价）',
                                    style: TextStyle(fontSize: 12, color: _c.textSub)),
                                const Spacer(),
                                Text(
                                  '¥${fmtMoney(_stocks.fold<double>(0, (s, x) => s + (((x['quantity'] as num?)?.toDouble() ?? 0) * ((x['cost_price'] as num?)?.toDouble() ?? 0))))}',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF67C23A)),
                                ),
                              ],
                            ),
                          ),
                        if (_stocks.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: Text('暂无库存记录\n进货后自动入库，可点右上角盘点初始化', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))),
                          ),
                        for (final s in _stocks)
                          Card(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            elevation: 0,
                            color: (s['low'] == true)
                                ? const Color(0xFFFEF0F0)
                                : (Theme.of(context).brightness == Brightness.dark
                                    ? const Color(0xFF1C1C1E)
                                    : Colors.white),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                  color: s['low'] == true ? const Color(0xFFF56C6C).withOpacity(0.5) : const Color(0x0F000000)),
                            ),
                            child: ListTile(
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundColor: (s['low'] == true
                                        ? const Color(0xFFF56C6C)
                                        : const Color(0xFF67C23A))
                                    .withOpacity(0.12),
                                child: Icon(
                                  s['low'] == true ? Icons.warning_amber_outlined : Icons.inventory_2_outlined,
                                  size: 16,
                                  color: s['low'] == true ? const Color(0xFFF56C6C) : const Color(0xFF67C23A),
                                ),
                              ),
                              title: Text('${s['item_name']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                              subtitle: Text('单位 ${s['unit']} · 阈值 ${s['min_stock']}',
                                  style: TextStyle(fontSize: 12, color: _c.textSub)),
                              trailing: Text(
                                '${s['quantity']}',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: s['low'] == true ? const Color(0xFFF56C6C) : const Color(0xFF67C23A),
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