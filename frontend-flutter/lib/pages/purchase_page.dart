import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../api.dart';
import '../local_freq.dart';
import 'router.dart';

class PurchasePage extends StatefulWidget {
  const PurchasePage({super.key, this.editId});
  /// 非空 = 编辑已有进货单（从账本进入），提交走 PATCH
  final String? editId;
  @override
  State<PurchasePage> createState() => _PurchasePageState();
}

class _PRow {
  String? itemId;
  String? priceId;
  double quantity = 0;
  double purchasePrice = 0;
  // 输入框控制器：行重建时保留已输入内容（无 controller 时下拉切换/刷新会丢输入）
  final qtyCtrl = TextEditingController();
  final priceCtrl = TextEditingController();
}

class _PurchasePageState extends State<PurchasePage> {
  List<Map<String, dynamic>> _items = [];
  // 商品下拉菜单项缓存：行组件不再每次 build 重建 items（目录大时明显降卡顿）
  List<DropdownMenuItem<String>> _itemMenus = [];
  final List<_PRow> _rows = [_PRow()];
  Map<String, double> _lastQty = {}; // price_id → 上次数量（选单位自动带出）
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
    for (final r in _rows) {
      r.qtyCtrl.dispose();
      r.priceCtrl.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // ① 本地缓存秒开
    final cached = await Api.instance.getCached('/items/summary');
    if (cached != null) {
      final freq = await Freq.load();
      final list = ((cached['items'] as List?) ?? []).cast<Map<String, dynamic>>()
        ..sort((a, b) => _freqOf(b, freq) - _freqOf(a, freq));
      setState(() {
        _items = list;
        _itemMenus = list
            .map((it) => DropdownMenuItem(
                value: it['id'] as String, child: Text(it['name'] as String)))
            .toList();
      });
    }
    // ② 并行网络刷新 + 更新缓存
    try {
      final i = await Api.instance.get('/items/summary');
      await Api.instance.setCache('/items/summary', i);
      if (!mounted) return;
      final freq = await Freq.load();
      final lastQty = await Freq.loadLastQty();
      final list = ((i['items'] as List?) ?? []).cast<Map<String, dynamic>>()
        ..sort((a, b) => _freqOf(b, freq) - _freqOf(a, freq));
      if (!mounted) return;
      setState(() {
        _items = list;
        _lastQty = lastQty;
        _itemMenus = list
            .map((it) => DropdownMenuItem(
                value: it['id'] as String, child: Text(it['name'] as String)))
            .toList();
      });
      // 编辑模式：商品目录就绪后预填原单据明细
      if (_editing) await _loadEdit();
    } catch (e) {
      if (cached == null) toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 商品在本地频率表中的最大使用次数（按价格组合取峰值，0=无记录）
  int _freqOf(Map<String, dynamic> item, Map<String, int> freq) {
    var max = 0;
    for (final p in ((item['prices'] as List?) ?? [])) {
      final f = freq['${(p as Map)['id']}'] ?? 0;
      if (f > max) max = f;
    }
    return max;
  }

  /// 编辑模式预填：GET /purchases/:id → 按 item_id+unit 匹配现有价格，回填行
  Future<void> _loadEdit() async {
    try {
      final d = await Api.instance.get('/purchases/${widget.editId}');
      if (!mounted) return;
      setState(() {
        final hd = '${d['happened_at'] ?? ''}';
        _dateCtrl.text = hd.length >= 10 ? hd.substring(0, 10) : _today();
        final items = ((d['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        _rows.clear();
        var skipped = 0;
        for (final it in items) {
          final itemId = '${it['item_id']}';
          final unit = '${it['unit'] ?? ''}';
          final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
          final pp = (it['purchase_price'] as num?)?.toDouble() ?? 0;
          final match = _items.where((x) => '${x['id']}' == itemId).firstOrNull;
          final prices = ((match?['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
          final price = prices.where((p) => '${p['unit']}' == unit).firstOrNull;
          if (match == null || price == null) {
            skipped++;
            continue;
          }
          _rows.add(_PRow()
            ..itemId = itemId
            ..priceId = price['id'] as String?
            ..quantity = qty
            ..purchasePrice = pp
            ..qtyCtrl.text = qty.toString()
            ..priceCtrl.text = pp.toStringAsFixed(2));
        }
        if (_rows.isEmpty) _rows.add(_PRow());
        if (skipped > 0) {
          toast(context, '原单 $skipped 条商品已删除或价格停用，保存后将移除');
        }
      });
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
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
          row.qtyCtrl.text = qty.toString();
          row.priceCtrl.text = (price > 0 ? price : (pr!['purchase_price'] as num).toDouble()).toStringAsFixed(2);
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
    final body = {
      'happened_at': _dateCtrl.text.trim(),
      'items': valid
          .map((r) => {'price_id': r.priceId, 'quantity': r.quantity, 'purchase_price': r.purchasePrice})
          .toList(),
    };
    try {
      if (_editing) {
        await Api.instance.patch('/purchases/${widget.editId}', body);
        toast(context, '已保存修改');
        if (mounted) Navigator.pop(context, true);
      } else {
        await Api.instance.post('/purchases', body);
        await Freq.bump(valid.map((r) => r.priceId ?? ''));
        for (final r in valid) {
          await Freq.saveLastQty(r.priceId ?? '', r.quantity);
        }
        toast(context, '已提交，合计 ¥${_total.toStringAsFixed(2)}');
        setState(() {
          _rows.clear();
          _rows.add(_PRow());
        });
      }
    } catch (e) {
      final msg = e.toString();
      // 网络异常：新增单据存入待同步队列（编辑模式不入队）
      if (msg.contains('地址') && !_editing) {
        await Api.instance.pendingAdd('purchase', body);
        toast(context, '网络异常，进货单已存入待同步队列');
      } else {
        toast(context, msg.replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 复制上一笔进货单：预填明细，可修改后提交
  Future<void> _copyLast() async {
    try {
      final d = await Api.instance.get('/purchases?limit=1');
      final list = ((d['purchases'] as List?) ?? []);
      if (list.isEmpty) {
        toast(context, '暂无历史进货单');
        return;
      }
      final last = list.first as Map<String, dynamic>;
      final items = ((last['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      setState(() {
        _rows.clear();
        for (final it in items) {
          final itemId = '${it['item_id']}';
          final unit = '${it['unit'] ?? ''}';
          final match = _items.where((x) => '${x['id']}' == itemId).firstOrNull;
          final prices = ((match?['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
          final price = prices.where((p) => '${p['unit']}' == unit).firstOrNull;
          if (match == null || price == null) continue;
          final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
          final pp = (it['purchase_price'] as num?)?.toDouble() ?? 0;
          final row = _PRow()
            ..itemId = itemId
            ..priceId = price['id'] as String?
            ..quantity = qty
            ..purchasePrice = pp
            ..qtyCtrl.text = qty.toString()
            ..priceCtrl.text = pp.toStringAsFixed(2);
          _rows.add(row);
        }
        if (_rows.isEmpty) _rows.add(_PRow());
      });
      toast(context, '已复制上一笔进货单，可修改后提交');
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? '编辑进货单' : '进货记单'),
        actions: [
          IconButton(
            tooltip: '复制上一单',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: _busy ? null : _copyLast,
          ),
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
              child: TextField(
                controller: _dateCtrl,
                decoration: const InputDecoration(
                    labelText: '进货日期（YYYY-MM-DD）', helperText: '默认今天，可改为补录历史'),
              ),
            ),
          ),
          const SizedBox(height: 12),
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
            child: Text(_busy ? '提交中…' : (_editing ? '保存修改' : '提交进货单')),
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
              items: _itemMenus,
              onChanged: (v) => setState(() {
                row.itemId = v;
                row.priceId = null;
              }),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: row.priceId,
              decoration: const InputDecoration(labelText: '单位', helperText: '选单位自动带出默认进价，可再改'),
              items: prices
                  .map((p) => DropdownMenuItem(
                        value: p['id'] as String,
                        child: Text('${p['unit']}（进 ¥${p['purchase_price']} · 库存 ${p['stock'] ?? 0}）'),
                      ))
                  .toList(),
              onChanged: (v) => setState(() {
                row.priceId = v;
                final pp = (prices.firstWhere((p) => p['id'] == v)['purchase_price'] as num).toDouble();
                row.purchasePrice = pp;
                row.priceCtrl.text = pp.toStringAsFixed(2);
                // 上次数量记忆：自动带出该单位上回进的数量
                final last = _lastQty[v] ?? 0;
                if (last > 0) {
                  row.quantity = last;
                  row.qtyCtrl.text = last.toString();
                }
              }),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: row.qtyCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: '数量'),
                    onChanged: (v) => row.quantity = double.tryParse(v) ?? 0,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: row.priceCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: '进价（可直接改）'),
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