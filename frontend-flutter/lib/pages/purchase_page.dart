import 'dart:math';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../api.dart';
import '../local_db.dart';
import '../local_freq.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import '../widgets/date_field.dart';
import 'attachment_viewer.dart';
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
  String happenedAt = ''; // 该行商品的独立日期（空=用单据日期）
  // 输入框控制器：行重建时保留已输入内容（无 controller 时下拉切换/刷新会丢输入）
  final nameCtrl = TextEditingController();
  final unitCtrl = TextEditingController();
  final qtyCtrl = TextEditingController();
  final priceCtrl = TextEditingController();
}

class _PurchasePageState extends State<PurchasePage> {
  List<Map<String, dynamic>> _items = [];
  bool _isStaff = false; // 店员不可见进价（进货价手填）
  final List<_PRow> _rows = [_PRow()];
  Map<String, double> _lastQty = {}; // price_id → 上次数量（选单位自动带出）
  final _dateCtrl = TextEditingController(text: _today());
  final _noteCtrl = TextEditingController();
  bool _busy = false;

  bool get _editing => widget.editId != null;

  /// 单据 id：编辑模式用原单 id；新建模式提前生成（附件/提交都挂在这个 id 上）
  late final String _purchaseId =
      _editing ? widget.editId! : 'p${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';

  /// 今日日期（YYYY-MM-DD），表单默认值；可改=补录历史日期
  static String _today() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _dateCtrl.dispose();
    _noteCtrl.dispose();
    for (final r in _rows) {
      r.nameCtrl.dispose();
      r.unitCtrl.dispose();
      r.qtyCtrl.dispose();
      r.priceCtrl.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    Api.instance.getRole().then((r) {
      if (mounted) setState(() => _isStaff = r == 'staff');
    });
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
      });
      // 编辑模式：商品目录就绪后预填原单据明细
      if (_editing) await _loadEdit();
    } catch (_) {
      // 离线：本地缓存已展示，错误已记日志，不再弹提示
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

  /// 编辑模式预填：优先本地库回显（离线也能填原单），无本地副本再走网络
  Future<void> _loadEdit() async {
    Map<String, dynamic>? d;
    try {
      final list = await LocalDb.getAll('purchases');
      d = list.where((s) => '${s['id']}' == widget.editId).firstOrNull;
    } catch (_) {}
    if (d == null) {
      try {
        d = await Api.instance.get('/purchases/${widget.editId}');
      } catch (_) {
        // 无网络且本地无缓存：错误已记日志，表单留空由用户重新填写
        return;
      }
    }
    if (!mounted || d == null) return;
    final data = d;
    setState(() {
      final hd = '${data['happened_at'] ?? ''}';
      _dateCtrl.text = hd.length >= 10 ? hd.substring(0, 10) : _today();
      _noteCtrl.text = '${data['note'] ?? ''}';
      final items = ((data['items'] as List?) ?? []).cast<Map<String, dynamic>>();
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
          ..happenedAt = '${it['happened_at'] ?? hd}'
          ..nameCtrl.text = '${it['item_name'] ?? match['name']}'
          ..unitCtrl.text = unit
          ..qtyCtrl.text = qty.toString()
          ..priceCtrl.text = pp.toStringAsFixed(2));
      }
      if (_rows.isEmpty) _rows.add(_PRow());
      if (skipped > 0) {
        toast(context, '原单 $skipped 条商品已删除或价格停用，保存后将移除');
      }
    });
  }

  /// 选中商品：填入名称/分类，带出默认单位与进价
  void _selectItem(_PRow row, Map<String, dynamic> item) {
    row.itemId = '${item['id']}';
    row.nameCtrl.text = '${item['name'] ?? ''}';
    final prices = ((item['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
    final price = prices.where((p) => (p['active'] as num?) != 0).firstOrNull ?? prices.firstOrNull;
    if (price != null) {
      row.priceId = price['id'] as String?;
      row.unitCtrl.text = '${price['unit'] ?? ''}';
      row.purchasePrice = (price['purchase_price'] as num?)?.toDouble() ?? 0;
      row.priceCtrl.text = row.purchasePrice > 0 ? row.purchasePrice.toStringAsFixed(2) : '';
    }
  }

  /// 名称输入变化：精确匹配到已有商品 → 选中；否则视为新商品名（可点「新增」入库）
  void _onNameChanged(_PRow row, String v) {
    final name = v.trim();
    final match = _items.where((x) => '${x['name']}' == name).firstOrNull;
    if (match != null) {
      if (row.itemId != '${match['id']}') {
        _selectItem(row, match);
        setState(() {});
      }
      return;
    }
    if (row.itemId != null) {
      row.itemId = null;
      row.priceId = null;
    }
    setState(() {});
  }

  /// 单位输入变化：匹配到该商品的价格组合 → 带出默认进价；否则保持手动进价
  void _onUnitChanged(_PRow row, String v) {
    final unit = v.trim();
    final item = _items.where((x) => x['id'] == row.itemId).firstOrNull;
    final prices = ((item?['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
    final price = prices.where((p) => '${p['unit']}' == unit).firstOrNull;
    row.unitCtrl.text = unit; // 保持用户输入（含非预设单位）
    if (price != null) {
      row.priceId = price['id'] as String?;
      row.purchasePrice = (price['purchase_price'] as num?)?.toDouble() ?? 0;
      row.priceCtrl.text = row.purchasePrice > 0 ? row.purchasePrice.toStringAsFixed(2) : '';
    } else {
      row.priceId = null; // 自定义单位：进价手动填
    }
    setState(() {});
  }

  /// 商品选择弹层：搜索 + 列表选择（也可直接输入新名称走「新增商品」）
  Future<void> _pickItem(_PRow row) async {
    final searchCtrl = TextEditingController();
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final q = searchCtrl.text.trim().toLowerCase();
          final list = q.isEmpty
              ? _items
              : _items.where((x) => '${x['name']}'.toLowerCase().contains(q)).toList();
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.6,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child: TextField(
                      controller: searchCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search, size: 20),
                        hintText: '搜索商品名称',
                        isDense: true,
                      ),
                      onChanged: (_) => setSheet(() {}),
                    ),
                  ),
                  Expanded(
                    child: list.isEmpty
                        ? Center(child: Text('没有匹配商品，可直接在上方输入新名称', style: TextStyle(color: Theme.of(ctx).extension<TaozhuColors>()!.textSub)))
                        : ListView(
                            children: [
                              for (final it in list)
                                ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.sell_outlined, size: 18, color: Color(0xFF67C23A)),
                                  title: Text('${it['name']}'),
                                  subtitle: '${it['category'] ?? ''}'.isNotEmpty
                                      ? Text('${it['category']}', style: const TextStyle(fontSize: 11))
                                      : null,
                                  onTap: () => Navigator.pop(ctx, '${it['id']}'),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (picked == null) return;
    final item = _items.where((x) => '${x['id']}' == picked).firstOrNull;
    if (item != null) _selectItem(row, item);
    setState(() {});
  }

  /// 创建商品（在线；老板可建，店员被后端 403）：成功加入本地目录并返回 id
  Future<String?> _createItem(String name, {String unit = '', double price = 0, String category = ''}) async {
    final u = unit.isEmpty ? '件' : unit;
    try {
      final d = await Api.instance.post('/items', {
        'name': name,
        'category': category,
        'prices': [
          {'unit': u, 'purchase_price': price > 0 ? price : 0, 'sale_price': 0},
        ],
      });
      final id = '${d['id'] ?? ''}';
      if (id.isEmpty) return null;
      final pid = '${(d['prices'] as List?)?.firstOrNull?['id'] ?? ''}';
      _items.add({
        'id': id,
        'name': name,
        'category': category,
        'prices': [
          {'id': pid, 'unit': u, 'purchase_price': price > 0 ? price : 0, 'sale_price': 0, 'active': 1},
        ],
      });
      return id;
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
      return null;
    }
  }

  /// 新增商品入库：在线创建（仅老板；店员提示找老板添加）→ 加入本地目录并选中
  Future<bool> _quickAddItem(_PRow row, String name) async {
    final categoryCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('新增商品「$name」'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: categoryCtrl,
              decoration: const InputDecoration(labelText: '分类（可留空）'),
            ),
            const SizedBox(height: 8),
            Text('单位与进价可在下方明细行直接填写', style: TextStyle(fontSize: 12, color: Theme.of(ctx).extension<TaozhuColors>()!.textSub)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('添加商品')),
        ],
      ),
    );
    if (ok != true) return false;
    final id = await _createItem(name,
        unit: row.unitCtrl.text.trim(), price: row.purchasePrice, category: categoryCtrl.text.trim());
    if (id == null) return false;
    final opt = _items.where((x) => '${x['id']}' == id).firstOrNull;
    if (opt != null) _selectItem(row, opt);
    setState(() {});
    toast(context, '已添加商品「$name」');
    return true;
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
              : (_rows..add(_PRow()..happenedAt = _dateCtrl.text.trim())).last;
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
    // 名称手动输入但未入库的新商品：老板自动入库（静默），店员提示找老板添加
    for (final r in _rows) {
      final name = r.nameCtrl.text.trim();
      if (name.isNotEmpty && r.itemId == null) {
        if (_isStaff) {
          toast(context, '「$name」不在商品库，请让老板先添加');
          return;
        }
        final id = await _createItem(name,
            unit: r.unitCtrl.text.trim(), price: r.purchasePrice, category: '');
        if (id == null) return;
        final opt = _items.where((x) => '${x['id']}' == id).firstOrNull;
        if (opt != null) _selectItem(r, opt);
      }
    }
    // 校验：有名称、有数量、有单位（默认件）即可提交；进价可直接手填
    for (final r in _rows) {
      final name = r.nameCtrl.text.trim();
      if (name.isEmpty && r.itemId == null) continue; // 空行忽略
      if (r.itemId == null) {
        toast(context, '「$name」尚未添加到商品库，提交失败');
        return;
      }
      if (r.quantity <= 0) {
        toast(context, '请填写「${name.isNotEmpty ? name : '商品'}」的数量');
        return;
      }
      if (r.unitCtrl.text.trim().isEmpty) r.unitCtrl.text = '件';
    }
    final valid = _rows.where((r) => r.itemId != null && r.quantity > 0).toList();
    if (valid.isEmpty) {
      toast(context, '请填写完整的商品明细');
      return;
    }
    setState(() => _busy = true);
    // 写本地优先：构建完整 payload → 落本地库 → 入队列 → debounce push
    final purchaseId = _purchaseId;
    // 单据日期 = 明细行最大日期
    final orderDate = valid
        .map((r) => r.happenedAt.trim().isEmpty ? _dateCtrl.text.trim() : r.happenedAt.trim())
        .reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
    final itemsPayload = <Map<String, dynamic>>[];
    var totalCalc = 0.0;
    for (final r in valid) {
      final opt = _items.where((x) => x['id'] == r.itemId).firstOrNull;
      final prices = ((opt?['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
      final price = prices.where((p) => p['id'] == r.priceId).firstOrNull;
      final amount = (r.quantity * r.purchasePrice * 100).round() / 100;
      totalCalc += amount;
      itemsPayload.add({
        'id': 'pi${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(0x7fffffff)}',
        'purchase_id': purchaseId,
        'item_id': r.itemId,
        'item_name': opt?['name'] ?? r.nameCtrl.text.trim(),
        'unit': r.unitCtrl.text.trim(),
        'quantity': r.quantity,
        'purchase_price': r.purchasePrice,
        'amount': amount,
        'happened_at': r.happenedAt.trim().isEmpty ? orderDate : r.happenedAt.trim(),
      });
    }
    final payload = {
      'id': purchaseId,
      'happened_at': orderDate,
      'note': _noteCtrl.text.trim(),
      'total': (totalCalc * 100).round() / 100,
      'items': itemsPayload,
    };
    await LocalDb.upsertOne('purchases', payload);
    await SyncService.enqueueChange(
      entityType: 'purchase',
      entitySyncId: purchaseId,
      action: 'upsert',
      payload: payload,
    );
    await Freq.bump(valid.map((r) => r.priceId ?? ''));
    for (final r in valid) {
      await Freq.saveLastQty(r.priceId ?? '', r.quantity);
    }
    toast(context, _editing ? '已保存，正在同步' : '已提交，合计 ¥${_total.toStringAsFixed(2)}');
    if (mounted) Navigator.pop(context, true);
    if (mounted) setState(() => _busy = false);
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
            ..happenedAt = '${it['happened_at'] ?? ''}'
            ..nameCtrl.text = '${it['item_name'] ?? match['name']}'
            ..unitCtrl.text = unit
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
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? '编辑进货单' : '进货记单'),
        actions: [
          IconButton(
            tooltip: '凭证附件',
            icon: const Icon(Icons.image_outlined),
            onPressed: _busy
                ? null
                : () => showAttachmentViewer(context, 'purchase', _purchaseId, '进货单凭证附件'),
          ),
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
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _infoCard(),
          const SizedBox(height: 10),
          for (int i = 0; i < _rows.length; i++) _buildRow(i),
          const SizedBox(height: 10),
          // 添加商品（提交栏固定在底部悬浮）
          OutlinedButton.icon(
            onPressed: () => setState(
                () => _rows.add(_PRow()..happenedAt = _dateCtrl.text.trim())),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加商品'),
            style: OutlinedButton.styleFrom(
              foregroundColor: c.success,
              side: BorderSide(color: c.success.withOpacity(0.5)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
      // 底部悬浮栏：合计 + 提交 固定可见，长单无需滚到底
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(
            color: c.card,
            border: Border(top: BorderSide(color: c.divider)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('合计', style: TextStyle(fontSize: 12, color: c.textSub)),
                    Text('¥${fmtMoney(_total)}',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: c.danger)),
                  ],
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(140, 48),
                  backgroundColor: c.success,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? '提交中…' : (_editing ? '保存修改' : '提交进货单')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 填充式输入框装饰（圆角 12、无边框、聚焦成功色描边）
  InputDecoration _fieldDec({IconData? icon, String? label, String? hint}) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: icon == null ? null : Icon(icon, size: 20, color: c.textSub),
      filled: true,
      fillColor: c.field,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.success, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }

  /// 卡片（主题卡片底、radius 16）
  Widget _card(Widget child) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  /// 修改某一行商品的独立日期（不影响其他行）
  Future<void> _pickRowDate(_PRow row) async {
    final cur = DateTime.tryParse(row.happenedAt.trim().isEmpty ? _dateCtrl.text.trim() : row.happenedAt.trim());
    final picked = await showDatePicker(
      context: context,
      initialDate: cur ?? DateTime.now(),
      firstDate: DateTime(DateTime.now().year - 5),
      lastDate: DateTime(DateTime.now().year + 5, 12, 31),
    );
    if (picked == null) return;
    setState(() => row.happenedAt =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
  }

  /// 进货日期信息卡
  Widget _infoCard() {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return _card(Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DateField(
            controller: _dateCtrl,
            icon: Icons.calendar_today_outlined,
            label: _editing ? '日期（新加商品默认）' : '进货日期',
            hint: '点击选择日期（可补录历史）',
            focusColor: c.success,
          ),
          if (_editing)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('每行商品可有自己的日期：点行内日期可单独修改，改某一行的日期不影响其他行。',
                  style: TextStyle(fontSize: 11, color: c.textSub, height: 1.4)),
            ),
          const SizedBox(height: 10),
          TextField(
            controller: _noteCtrl,
            style: TextStyle(color: c.textMain),
            decoration: _fieldDec(icon: Icons.notes_outlined, label: '备注（可留空）'),
          ),
        ],
      ),
    ));
  }

  Widget _buildRow(int i) {
    final row = _rows[i];
    final c = Theme.of(context).extension<TaozhuColors>()!;
    final txtStyle = TextStyle(color: c.textMain);
    final item = row.itemId == null
        ? null
        : _items.where((x) => '${x['id']}' == row.itemId).firstOrNull;
    final name = row.nameCtrl.text.trim();
    final unmatched = name.isNotEmpty && item == null;
    return _card(Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: c.success.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text('${i + 1}',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.success)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: row.nameCtrl,
                  style: txtStyle,
                  decoration: _fieldDec(label: '商品名称（可输入或选择）'),
                  onChanged: (v) => _onNameChanged(row, v),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '选择商品',
                icon: const Icon(Icons.search, size: 22, color: Color(0xFF67C23A)),
                onPressed: () => _pickItem(row),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '删除此商品',
                icon: Icon(Icons.delete_outline, color: c.danger),
                onPressed: _rows.length > 1 ? () => setState(() => _rows.removeAt(i)) : null,
              ),
            ],
          ),
          if (item != null && '${item['category'] ?? ''}'.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 44),
              child: Text('分类：${item['category']}', style: TextStyle(fontSize: 11, color: c.textSub)),
            ),
          if (unmatched)
            Padding(
              padding: const EdgeInsets.only(left: 44, top: 2),
              child: Row(children: [
                Text('未在商品库：', style: TextStyle(fontSize: 12, color: c.warning)),
                InkWell(
                  onTap: () => _quickAddItem(row, name),
                  child: Text('新增商品「$name」',
                      style: TextStyle(fontSize: 12, color: c.primary, fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          const SizedBox(height: 6),
          TextField(
            controller: row.unitCtrl,
            style: txtStyle,
            decoration: _fieldDec(label: '单位（可手动填写）'),
            onChanged: (v) => _onUnitChanged(row, v),
          ),
          const SizedBox(height: 4),
          // 行独立日期：点此修改，只影响本行
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _pickRowDate(row),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Icon(Icons.event_outlined, size: 16, color: c.textSub),
                const SizedBox(width: 6),
                Text('该行日期：${row.happenedAt.trim().isEmpty ? _dateCtrl.text.trim() : row.happenedAt.trim()}',
                    style: TextStyle(fontSize: 13, color: c.primary, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('点此修改（不影响其他行）', style: TextStyle(fontSize: 11, color: c.textSub)),
              ]),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: row.qtyCtrl,
                  style: txtStyle,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _fieldDec(label: '数量'),
                  onChanged: (v) => row.quantity = double.tryParse(v) ?? 0,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: row.priceCtrl,
                  style: txtStyle,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _fieldDec(label: _isStaff ? '进价（手工填写）' : '进价（可直接改）'),
                  onChanged: (v) => row.purchasePrice = double.tryParse(v) ?? 0,
                ),
              ),
            ],
          ),
        ],
      ),
    ));
  }
}