import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../api.dart';
import '../local_freq.dart';
import 'router.dart';

class SalePage extends StatefulWidget {
  const SalePage({super.key, this.editId});
  /// 非空 = 编辑已有出货单（从账本进入），提交走 PATCH
  final String? editId;
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
  // 商品下拉菜单项缓存：行组件不再每次 build 重建 items（目录大时明显降卡顿）
  List<DropdownMenuItem<String>> _itemMenus = [];
  String? _clientId;
  final List<_Row> _rows = [_Row()];
  final _dateCtrl = TextEditingController(text: _today());
  bool _busy = false;

  bool get _editing => widget.editId != null;

  /// 今日日期（YYYY-MM-DD），表单默认值；可改=补录历史日期
  static String _today() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _dateCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // ① 本地缓存秒开（下拉立即有数据，不卡网络）
    final cachedC = await Api.instance.getCached('/clients');
    final cachedI = await Api.instance.getCached('/items/summary');
    if (cachedC != null || cachedI != null) {
      final freq = await Freq.load();
      setState(() {
        if (cachedC != null) {
          _clients = (cachedC['clients'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        }
        if (cachedI != null) {
          _items = ((cachedI['items'] as List?) ?? [])
              .map((e) => _ItemOption(
                    e['id'] as String,
                    e['name'] as String,
                    ((e['prices'] as List?) ?? []).cast<Map<String, dynamic>>(),
                  ))
              .toList()
            ..sort((a, b) => _freqOf(b, freq) - _freqOf(a, freq));
          _itemMenus = _items
              .map((it) => DropdownMenuItem(value: it.id, child: Text(it.name)))
              .toList();
        }
      });
    }
    // ② 并行网络刷新 + 更新缓存
    try {
      final results = await Future.wait([
        Api.instance.get('/clients'),
        Api.instance.get('/items/summary'),
      ]);
      await Future.wait([
        Api.instance.setCache('/clients', results[0]),
        Api.instance.setCache('/items/summary', results[1]),
      ]);
      if (mounted) {
        final freq = await Freq.load();
        final items = ((results[1]['items'] as List?) ?? [])
            .map((e) => _ItemOption(
                  e['id'] as String,
                  e['name'] as String,
                  ((e['prices'] as List?) ?? []).cast<Map<String, dynamic>>(),
                ))
            .toList()
          ..sort((a, b) => _freqOf(b, freq) - _freqOf(a, freq));
        if (!mounted) return;
        setState(() {
          _clients = (results[0]['clients'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          _items = items;
          _itemMenus = items
              .map((it) => DropdownMenuItem(value: it.id, child: Text(it.name)))
              .toList();
        });
        // 编辑模式：商品目录就绪后预填原单据明细
        if (_editing) await _loadEdit();
      }
    } catch (e) {
      if (cachedC == null && cachedI == null) {
        toast(context, e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  /// 商品在本地频率表中的最大使用次数（按价格组合取峰值，0=无记录）
  int _freqOf(_ItemOption item, Map<String, int> freq) {
    var max = 0;
    for (final p in item.prices) {
      final f = freq['${p['id']}'] ?? 0;
      if (f > max) max = f;
    }
    return max;
  }

  /// 编辑模式预填：GET /sales/:id → 按 item_id+unit 匹配现有价格，回填行
  Future<void> _loadEdit() async {
    try {
      final d = await Api.instance.get('/sales/${widget.editId}');
      if (!mounted) return;
      setState(() {
        _clientId = d['client_id'] as String?;
        final hd = '${d['happened_at'] ?? ''}';
        _dateCtrl.text = hd.length >= 10 ? hd.substring(0, 10) : _today();
        final items = ((d['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        _rows.clear();
        var skipped = 0;
        for (final it in items) {
          final itemId = '${it['item_id']}';
          final unit = '${it['unit'] ?? ''}';
          final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
          final sp = (it['sale_price'] as num?)?.toDouble() ?? 0;
          final opt = _items.where((x) => x.id == itemId).firstOrNull;
          final price = opt?.prices.where((p) => '${p['unit']}' == unit).firstOrNull;
          if (opt == null || price == null) {
            skipped++;
            continue;
          }
          _rows.add(_Row()
            ..itemId = itemId
            ..priceId = price['id'] as String?
            ..quantity = qty
            ..salePrice = sp);
        }
        if (_rows.isEmpty) _rows.add(_Row());
        if (skipped > 0) {
          toast(context, '原单 $skipped 条商品已删除或价格停用，保存后将移除');
        }
      });
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  double get _total => _rows.fold(0, (s, r) => s + r.quantity * r.salePrice);

  /// AI 拍照识别：拍照 → 后端解析 → 匹配已有商品填行
  Future<void> _aiParse() async {
    try {
      final picked = await ImagePicker()
          .pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 85);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      toast(context, '识别中…');
      final d = await Api.instance.uploadPhoto('/ai/parse-photo?purpose=sale', bytes, 'photo.jpg');
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
            .where((it) => it.name == name || it.name.contains(name) || name.contains(it.name))
            .firstOrNull;
        if (match == null) continue;
        Map<String, dynamic>? pr;
        if (unit.isNotEmpty) {
          pr = match.prices.where((p) => '${p['unit']}' == unit).firstOrNull;
        }
        pr ??= match.prices.firstOrNull;
        if (pr == null) continue;
        setState(() {
          final row = (_rows.length == 1 && _rows.first.itemId == null)
              ? _rows.first
              : (_rows..add(_Row())).last;
          row.itemId = match.id;
          row.priceId = pr!['id'] as String?;
          row.quantity = qty;
          row.salePrice = price > 0 ? price : (pr!['sale_price'] as num).toDouble();
          filled++;
        });
      }
      toast(context, filled > 0 ? '已导入 $filled 项商品' : '识别结果未匹配到已有商品，请手动填写');
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _submit() async {
    if (_clientId == null) {
      toast(context, '请选择店铺');
      return;
    }
    final valid = _rows.where((r) => r.itemId != null && r.priceId != null && r.quantity > 0).toList();
    if (valid.isEmpty) {
      toast(context, '请填写完整的商品明细');
      return;
    }
    setState(() => _busy = true);
    try {
      final body = {
        'client_id': _clientId,
        'happened_at': _dateCtrl.text.trim(),
        'items': valid
            .map((r) => {'price_id': r.priceId, 'quantity': r.quantity, 'sale_price': r.salePrice})
            .toList(),
      };
      if (_editing) {
        await Api.instance.patch('/sales/${widget.editId}', body);
        toast(context, '已保存修改');
        if (mounted) Navigator.pop(context, true);
      } else {
        await Api.instance.post('/sales', body);
        await Freq.bump(valid.map((r) => r.priceId ?? ''));
        toast(context, '已提交，合计 ¥${_total.toStringAsFixed(2)}');
        setState(() {
          _rows.clear();
          _rows.add(_Row());
        });
      }
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
        title: Text(_editing ? '编辑出货单' : '出货记单'),
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
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _clientId,
                    decoration: const InputDecoration(labelText: '店铺'),
                    items: _clients
                        .map((c) => DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String)))
                        .toList(),
                    onChanged: (v) => setState(() => _clientId = v),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _dateCtrl,
                    decoration: const InputDecoration(
                        labelText: '日期（YYYY-MM-DD）', helperText: '默认今天，可改为补录历史'),
                  ),
                ],
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
            child: Text(_busy ? '提交中…' : (_editing ? '保存修改' : '提交出货单')),
          ),
        ],
      ),
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
              items: _itemMenus,
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