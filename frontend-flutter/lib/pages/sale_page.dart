import 'package:flutter/material.dart';
import '../api.dart';

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
  String itemName = '';
  String priceLabel = '';
  double quantity = 0;
  double salePrice = 0;
}

class _SalePageState extends State<SalePage> {
  List<Map<String, dynamic>> _clients = [];
  List<_ItemOption> _items = [];
  String? _clientId;
  String _clientName = '';
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
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  double get _total => _rows.fold(0, (s, r) => s + r.quantity * r.salePrice);

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Future<void> _submit() async {
    if (_clientId == null) {
      _toast('请选择饭店');
      return;
    }
    final valid = _rows.where((r) => r.itemId != null && r.priceId != null && r.quantity > 0).toList();
    if (valid.isEmpty) {
      _toast('请填写完整的商品明细');
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
      _toast('已提交，合计 ¥${_total.toStringAsFixed(2)}');
      setState(() {
        _rows.clear();
        _rows.add(_Row());
      });
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('出货记单')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            initialValue: _clientId,
            decoration: const InputDecoration(labelText: '饭店', border: OutlineInputBorder()),
            items: _clients
                .map((c) => DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String)))
                .toList(),
            onChanged: (v) => setState(() {
              _clientId = v;
              _clientName = _clients.firstWhere((c) => c['id'] == v)['name'] as String;
            }),
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
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red)),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? '提交中…' : '提交出货单'),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(int i) {
    final row = _rows[i];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              initialValue: row.itemId,
              decoration: const InputDecoration(labelText: '商品', border: OutlineInputBorder()),
              items: _items
                  .map((it) => DropdownMenuItem(value: it.id, child: Text(it.name)))
                  .toList(),
              onChanged: (v) => setState(() {
                row.itemId = v;
                final it = _items.firstWhere((x) => x.id == v);
                row.itemName = it.name;
                row.priceId = null;
                row.priceLabel = '';
                row.salePrice = 0;
              }),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: row.priceId,
              decoration: const InputDecoration(labelText: '单位/出价', border: OutlineInputBorder()),
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
                row.priceLabel = '${p['unit']}';
                row.salePrice = (p['sale_price'] as num).toDouble();
              }),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: '数量', border: OutlineInputBorder()),
                    onChanged: (v) => row.quantity = double.tryParse(v) ?? 0,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: '单价', border: OutlineInputBorder()),
                    onChanged: (v) => row.salePrice = double.tryParse(v) ?? 0,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
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