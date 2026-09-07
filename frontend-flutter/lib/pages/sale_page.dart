import 'package:flutter/material.dart';
import '../api.dart';
import '../widgets/admin_scaffold.dart';
import 'router.dart';

class SalePage extends StatefulWidget {
  const SalePage({super.key});
  @override
  State<SalePage> createState() => _SalePageState();
}

class _ItemOption {
  final String id;
  final String name;
  final List<Map<String, dynamic>> prices;
  _ItemOption(this.id, this.name, this.prices);
}

class _Row {
  String? itemId;
  String? priceId;
  double quantity = 0;
  double salePrice = 0;
}

class _SalePageState extends State<SalePage> {
  List<Map<String, dynamic>> _clients = [];
  List<_ItemOption> _items = [];
  String? _clientId;
  final List<_Row> _rows = [_Row()];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await Api.instance.get('/clients');
      final i = await Api.instance.get('/items/summary');
      setState(() {
        _clients = (c['clients'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        _items = ((i['items'] as List?) ?? [])
            .map((e) => _ItemOption(
                  e['id'] as String,
                  e['name'] as String,
                  ((e['prices'] as List?) ?? []).cast<Map<String, dynamic>>(),
                ))
            .toList();
      });
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  double get _total => _rows.fold(0, (s, r) => s + r.quantity * r.salePrice);

  Future<void> _submit() async {
    if (_clientId == null) {
      toast(context, '请选择饭店');
      return;
    }
    final valid = _rows.where((r) => r.itemId != null && r.priceId != null && r.quantity > 0).toList();
    if (valid.isEmpty) {
      toast(context, '请填写完整的商品明细');
      return;
    }
    setState(() => _busy = true);
    try {
      await Api.instance.post('/sales', {
        'client_id': _clientId,
        'items': valid
            .map((r) => {'price_id': r.priceId, 'quantity': r.quantity, 'sale_price': r.salePrice})
            .toList(),
      });
      toast(context, '已提交，合计 ¥${_total.toStringAsFixed(2)}');
      setState(() {
        _rows.clear();
        _rows.add(_Row());
      });
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdminScaffold(
      selectedIndex: 1,
      title: '出货记单',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: DropdownButtonFormField<String>(
                initialValue: _clientId,
                decoration: const InputDecoration(labelText: '饭店'),
                items: _clients
                    .map((c) => DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String)))
                    .toList(),
                onChanged: (v) => setState(() => _clientId = v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (int i = 0; i < _rows.length; i++) _buildRow(i),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton(
                onPressed: () => setState(() => _rows.add(_Row())),
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
            child: Text(_busy ? '提交中…' : '提交出货单'),
          ),
        ],
      ),
      onSelect: (i) => goPage(context, i),
    );
  }

  Widget _buildRow(int i) {
    final row = _rows[i];
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
              items: _items.map((it) => DropdownMenuItem(value: it.id, child: Text(it.name))).toList(),
              onChanged: (v) => setState(() {
                row.itemId = v;
                row.priceId = null;
                row.salePrice = 0;
              }),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: row.priceId,
              decoration: const InputDecoration(labelText: '单位/出价'),
              items: (_items.where((x) => x.id == row.itemId).isEmpty
                      ? <_ItemOption>[]
                      : [_items.firstWhere((x) => x.id == row.itemId)])
                  .expand((it) => it.prices.map((p) => DropdownMenuItem(
                        value: p['id'] as String,
                        child: Text('${p['unit']}（¥${p['sale_price']}）'),
                      )))
                  .toList(),
              onChanged: (v) => setState(() {
                row.priceId = v;
                final p = _items
                    .where((x) => x.id == row.itemId)
                    .expand((x) => x.prices)
                    .firstWhere((p) => p['id'] == v);
                row.salePrice = (p['sale_price'] as num).toDouble();
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
                    decoration: const InputDecoration(labelText: '单价'),
                    onChanged: (v) => row.salePrice = double.tryParse(v) ?? 0,
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