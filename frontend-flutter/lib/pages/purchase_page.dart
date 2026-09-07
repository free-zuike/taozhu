import 'package:flutter/material.dart';
import '../api.dart';
import 'router.dart';

class PurchasePage extends StatefulWidget {
  const PurchasePage({super.key});
  @override
  State<PurchasePage> createState() => _PurchasePageState();
}

class _PRow {
  String? itemId;
  String? priceId;
  double quantity = 0;
  double purchasePrice = 0;
}

class _PurchasePageState extends State<PurchasePage> {
  List<Map<String, dynamic>> _items = [];
  final List<_PRow> _rows = [_PRow()];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final i = await Api.instance.get('/items/summary');
      setState(() => _items = ((i['items'] as List?) ?? []).cast<Map<String, dynamic>>());
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  double get _total => _rows.fold(0, (s, r) => s + r.quantity * r.purchasePrice);

  Future<void> _submit() async {
    final valid = _rows.where((r) => r.itemId != null && r.priceId != null && r.quantity > 0).toList();
    if (valid.isEmpty) {
      toast(context, '请填写完整的商品明细');
      return;
    }
    setState(() => _busy = true);
    try {
      await Api.instance.post('/purchases', {
        'items': valid
            .map((r) => {'price_id': r.priceId, 'quantity': r.quantity, 'purchase_price': r.purchasePrice})
            .toList(),
      });
      toast(context, '已提交，合计 ¥${_total.toStringAsFixed(2)}');
      setState(() {
        _rows.clear();
        _rows.add(_PRow());
      });
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('进货记单')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (int i = 0; i < _rows.length; i++) _buildRow(i),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton(
                onPressed: () => setState(() => _rows.add(_PRow())),
                child: const Text('+ 添加商品'),
              ),
              const Spacer(),
              Text('合计 ¥${_total.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFFF56C6C))),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? '提交中…' : '提交进货单'),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(int i) {
    final row = _rows[i];
    final prices = row.itemId == null
        ? <Map<String, dynamic>>[]
        : ((_items.firstWhere((x) => x['id'] == row.itemId)['prices'] as List?) ?? [])
            .cast<Map<String, dynamic>>();
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              initialValue: row.itemId,
              decoration: const InputDecoration(labelText: '商品'),
              items: _items
                  .map((it) => DropdownMenuItem(value: it['id'] as String, child: Text(it['name'] as String)))
                  .toList(),
              onChanged: (v) => setState(() {
                row.itemId = v;
                row.priceId = null;
              }),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: row.priceId,
              decoration: const InputDecoration(labelText: '单位/进价'),
              items: prices
                  .map((p) => DropdownMenuItem(
                        value: p['id'] as String,
                        child: Text('${p['unit']}（进 ¥${p['purchase_price']}）'),
                      ))
                  .toList(),
              onChanged: (v) => setState(() {
                row.priceId = v;
                row.purchasePrice = (prices.firstWhere((p) => p['id'] == v)['purchase_price'] as num).toDouble();
              }),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: '数量'),
                    onChanged: (v) => row.quantity = double.tryParse(v) ?? 0,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: '进价'),
                    onChanged: (v) => row.purchasePrice = double.tryParse(v) ?? 0,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Color(0xFFF56C6C)),
                  onPressed: _rows.length > 1 ? () => setState(() => _rows.removeAt(i)) : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}