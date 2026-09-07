import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
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
    // ① 本地缓存秒开
    final cached = await Api.instance.getCached('/items/summary');
    if (cached != null) {
      setState(() => _items = ((cached['items'] as List?) ?? []).cast<Map<String, dynamic>>());
    }
    // ② 并行网络刷新 + 更新缓存
    try {
      final i = await Api.instance.get('/items/summary');
      await Api.instance.setCache('/items/summary', i);
      if (!mounted) return;
      setState(() => _items = ((i['items'] as List?) ?? []).cast<Map<String, dynamic>>());
    } catch (e) {
      if (cached == null) toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  double get _total => _rows.fold(0, (s, r) => s + r.quantity * r.purchasePrice);

  /// AI 拍照识别：拍照 → 后端解析 → 匹配已有商品填行
  Future<void> _aiParse() async {
    try {
      final picked = await ImagePicker()
          .pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 85);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      toast(context, '识别中…');
      final d = await Api.instance.uploadPhoto('/ai/parse-photo?purpose=purchase', bytes, 'photo.jpg');
      final items = (d['items'] as List?) ?? [];
      if (items.isEmpty) {
        toast(context, '未识别到商品，请手动填写');
        return;
      }
      var filled = 0;
      for (final raw in items) {
        final name = '${raw['name'] ?? ''}'.trim();
        final qty = (raw['quantity'] as num?)?.toDouble() ?? 0;
        final price = (raw['price'] as num?)?.toDouble() ?? 0;
        final unit = '${raw['unit'] ?? ''}'.trim();
        final match = _items
            .where((it) => '${it['name']}' == name ||
                '${it['name']}'.contains(name) ||
                name.contains('${it['name']}'))
            .firstOrNull;
        if (match == null) continue;
        final prices = ((match['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
        Map<String, dynamic>? pr;
        if (unit.isNotEmpty) {
          pr = prices.where((p) => '${p['unit']}' == unit).firstOrNull;
        }
        pr ??= prices.firstOrNull;
        if (pr == null) continue;
        setState(() {
          final row = (_rows.length == 1 && _rows.first.itemId == null)
              ? _rows.first
              : (_rows..add(_PRow())).last;
          row.itemId = '${match['id']}';
          row.priceId = pr!['id'] as String?;
          row.quantity = qty;
          row.purchasePrice = price > 0 ? price : (pr!['purchase_price'] as num).toDouble();
          filled++;
        });
      }
      toast(context, filled > 0 ? '已导入 $filled 项商品' : '识别结果未匹配到已有商品，请手动填写');
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

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
      appBar: AppBar(
        title: const Text('进货记单'),
        actions: [
          IconButton(
            tooltip: 'AI 拍照识别',
            icon: const Icon(Icons.camera_alt_outlined),
            onPressed: _busy ? null : _aiParse,
          ),
        ],
      ),
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