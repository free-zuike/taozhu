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
import 'attachment_panel.dart';
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
  final String category;
  final List<Map<String, dynamic>> prices;
  _ItemOption(this.id, this.name, this.category, this.prices);
}

class _Row {
  String? itemId;
  String? priceId;
  double quantity = 0;
  double salePrice = 0;
  // 输入框控制器：行重建时保留已输入内容（无 controller 时下拉切换/刷新会丢输入）
  final nameCtrl = TextEditingController();
  final unitCtrl = TextEditingController();
  final qtyCtrl = TextEditingController();
  final saleCtrl = TextEditingController();
}

class _SalePageState extends State<SalePage> {
  List<Map<String, dynamic>> _clients = [];
  List<_ItemOption> _items = [];
  // 商品下拉菜单项缓存：行组件不再每次 build 重建 items（目录大时明显降卡顿）
  List<DropdownMenuItem<String>> _itemMenus = [];
  String? _clientId;
  final List<_Row> _rows = [_Row()];
  final _dateCtrl = TextEditingController(text: _today());
  final _noteCtrl = TextEditingController();
  bool _busy = false;
  Map<String, double> _lastQty = {}; // price_id → 上次数量（选单位自动带出）

  bool get _editing => widget.editId != null;

  /// 单据 id：编辑模式用原单 id；新建模式提前生成（附件/提交都挂在这个 id 上）
  late final String _saleId =
      _editing ? widget.editId! : 's${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';

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
      r.saleCtrl.dispose();
    }
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
      final clientFreq = await Freq.loadClients();
      setState(() {
        if (cachedC != null) {
          _clients = (cachedC['clients'] as List?)?.cast<Map<String, dynamic>>() ?? []
            ..sort((a, b) =>
                (clientFreq['${b['id']}'] ?? 0) - (clientFreq['${a['id']}'] ?? 0));
        }
        if (cachedI != null) {
          _items = ((cachedI['items'] as List?) ?? [])
              .map((e) => _ItemOption(
                    e['id'] as String,
                    e['name'] as String,
                    '${e['category'] ?? ''}',
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
        final clientFreq = await Freq.loadClients();
        final lastQty = await Freq.loadLastQty();
        final items = ((results[1]['items'] as List?) ?? [])
            .map((e) => _ItemOption(
                  e['id'] as String,
                  e['name'] as String,
                  '${e['category'] ?? ''}',
                  ((e['prices'] as List?) ?? []).cast<Map<String, dynamic>>(),
                ))
            .toList()
          ..sort((a, b) => _freqOf(b, freq) - _freqOf(a, freq));
        final clients = (results[0]['clients'] as List?)?.cast<Map<String, dynamic>>() ?? []
          ..sort((a, b) =>
              (clientFreq['${b['id']}'] ?? 0) - (clientFreq['${a['id']}'] ?? 0));
        if (!mounted) return;
        setState(() {
          _clients = clients;
          _items = items;
          _lastQty = lastQty;
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

  /// 编辑模式预填：优先本地库回显（离线也能填原单），无本地副本再走网络
  Future<void> _loadEdit() async {
    Map<String, dynamic>? d;
    try {
      final sales = await LocalDb.getAll('sales');
      d = sales.where((s) => '${s['id']}' == widget.editId).firstOrNull;
    } catch (_) {}
    if (d == null) {
      try {
        d = await Api.instance.get('/sales/${widget.editId}');
      } catch (_) {
        // 无网络且本地无缓存：错误已记日志，表单留空由用户重新填写
        return;
      }
    }
    if (!mounted || d == null) return;
    final data = d;
    setState(() {
      _clientId = data['client_id'] as String?;
      final hd = '${data['happened_at'] ?? ''}';
      _dateCtrl.text = hd.length >= 10 ? hd.substring(0, 10) : _today();
      final items = ((data['items'] as List?) ?? []).cast<Map<String, dynamic>>();
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
          ..salePrice = sp
          ..nameCtrl.text = '${it['item_name'] ?? opt.name}'
          ..unitCtrl.text = unit
          ..qtyCtrl.text = qty.toString()
          ..saleCtrl.text = sp.toString());
      }
      if (_rows.isEmpty) _rows.add(_Row());
      if (skipped > 0) {
        toast(context, '原单 $skipped 条商品已删除或价格停用，保存后将移除');
      }
    });
  }

  /// 选中商品：填入名称/分类，带出默认单位与出价
  void _selectItem(_Row row, _ItemOption item) {
    row.itemId = item.id;
    row.nameCtrl.text = item.name;
    final price = item.prices.where((p) => (p['active'] as num?) != 0).firstOrNull ?? item.prices.firstOrNull;
    if (price != null) {
      row.priceId = price['id'] as String?;
      row.unitCtrl.text = '${price['unit'] ?? ''}';
      row.salePrice = (price['sale_price'] as num?)?.toDouble() ?? 0;
      row.saleCtrl.text = row.salePrice > 0 ? row.salePrice.toStringAsFixed(2) : '';
    }
  }

  /// 名称输入变化：精确匹配到已有商品 → 选中；否则视为新商品名（可点「新增」入库）
  void _onNameChanged(_Row row, String v) {
    final name = v.trim();
    final match = _items.where((x) => x.name == name).firstOrNull;
    if (match != null) {
      if (row.itemId != match.id) {
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

  /// 单位输入变化：匹配到该商品的价格组合 → 带出默认出价；否则保持手动出价
  void _onUnitChanged(_Row row, String v) {
    final unit = v.trim();
    final item = _items.where((x) => x.id == row.itemId).firstOrNull;
    final price = item?.prices.where((p) => '${p['unit']}' == unit).firstOrNull;
    row.unitCtrl.text = unit; // 保持用户输入（含非预设单位）
    if (price != null) {
      row.priceId = price['id'] as String?;
      row.salePrice = (price['sale_price'] as num?)?.toDouble() ?? 0;
      row.saleCtrl.text = row.salePrice > 0 ? row.salePrice.toStringAsFixed(2) : '';
    } else {
      row.priceId = null; // 自定义单位：价格手动填
    }
    setState(() {});
  }

  /// 商品选择弹层：搜索 + 列表选择（也可直接输入新名称走「新增商品」）
  Future<void> _pickItem(_Row row) async {
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
              : _items.where((x) => x.name.toLowerCase().contains(q)).toList();
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
                                  leading: const Icon(Icons.sell_outlined, size: 18, color: Color(0xFF409EFF)),
                                  title: Text(it.name),
                                  subtitle: it.category.isNotEmpty
                                      ? Text(it.category, style: const TextStyle(fontSize: 11))
                                      : null,
                                  onTap: () => Navigator.pop(ctx, it.id),
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
    final item = _items.where((x) => x.id == picked).firstOrNull;
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
          {'unit': u, 'purchase_price': 0, 'sale_price': price > 0 ? price : 0},
        ],
      });
      final id = '${d['id'] ?? ''}';
      if (id.isEmpty) return null;
      final pid = '${(d['prices'] as List?)?.firstOrNull?['id'] ?? ''}';
      _items.add(_ItemOption(id, name, category, [
        {'id': pid, 'unit': u, 'purchase_price': 0, 'sale_price': price > 0 ? price : 0, 'active': 1},
      ]));
      return id;
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
      return null;
    }
  }

  /// 新增商品入库：在线创建（仅老板；店员提示找老板添加）→ 加入本地目录并选中
  Future<bool> _quickAddItem(_Row row, String name) async {
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
            Text('单位与出价可在下方明细行直接填写', style: TextStyle(fontSize: 12, color: Theme.of(ctx).extension<TaozhuColors>()!.textSub)),
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
        unit: row.unitCtrl.text.trim(), price: row.salePrice, category: categoryCtrl.text.trim());
    if (id == null) return false;
    final opt = _items.where((x) => x.id == id).firstOrNull;
    if (opt != null) _selectItem(row, opt);
    setState(() {});
    toast(context, '已添加商品「$name」');
    return true;
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
          row.qtyCtrl.text = qty.toString();
          row.saleCtrl.text = (price > 0 ? price : (pr!['sale_price'] as num).toDouble()).toStringAsFixed(2);
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
    // 名称手动输入但未入库的新商品：老板自动入库（静默），店员提示找老板添加
    for (final r in _rows) {
      final name = r.nameCtrl.text.trim();
      if (name.isNotEmpty && r.itemId == null) {
        final role = await Api.instance.getRole();
        if (role == 'staff') {
          toast(context, '「$name」不在商品库，请让老板先添加');
          return;
        }
        final id = await _createItem(name,
            unit: r.unitCtrl.text.trim(), price: r.salePrice, category: '');
        if (id == null) return;
        final opt = _items.where((x) => x.id == id).firstOrNull;
        if (opt != null) _selectItem(r, opt);
      }
    }
    // 校验：有名称、有数量、有单位（默认件）即可提交；价格可直接手填
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
    // 库存不足软提醒（不拦截，可强交）
    final lowStocks = <String>[];
    for (final r in valid) {
      final opt = _items.where((x) => x.id == r.itemId).firstOrNull;
      final price = opt?.prices.where((p) => p['id'] == r.priceId).firstOrNull;
      final stock = ((price?['stock'] as num?)?.toDouble() ?? 0);
      if (stock > 0 && r.quantity > stock) {
        lowStocks.add('${opt?.name}（${r.quantity} > 库存 $stock${price?['unit']}）');
      }
    }
    if (lowStocks.isNotEmpty) {
      toast(context, '库存不足提醒：${lowStocks.take(2).join('；')}');
    }
    setState(() => _busy = true);
    // 写本地优先：构建完整 payload → 落本地库（立即可见）→ 入待推送队列 → debounce push
    final saleId = _saleId;
    final clientName = _clients.where((c) => c['id'] == _clientId).firstOrNull?['name'] as String? ?? '';
    final itemsPayload = <Map<String, dynamic>>[];
    var totalCalc = 0.0;
    for (final r in valid) {
      final opt = _items.where((x) => x.id == r.itemId).firstOrNull;
      final price = opt?.prices.where((p) => p['id'] == r.priceId).firstOrNull;
      final amount = (r.quantity * r.salePrice * 100).round() / 100;
      totalCalc += amount;
      itemsPayload.add({
        'id': 'si${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(0x7fffffff)}',
        'sale_id': saleId,
        'item_id': r.itemId,
        'item_name': opt?.name ?? r.nameCtrl.text.trim(),
        'unit': r.unitCtrl.text.trim(),
        'quantity': r.quantity,
        'sale_price': r.salePrice,
        'cost_price': price?['purchase_price'] ?? 0,
        'amount': amount,
      });
    }
    final payload = {
      'id': saleId,
      'client_id': _clientId,
      'client_name': clientName,
      'happened_at': _dateCtrl.text.trim(),
      'note': _noteCtrl.text.trim(),
      'total': (totalCalc * 100).round() / 100,
      'items': itemsPayload,
    };
    // 先写本地库（列表/账本立即可见，不卡网络）
    await LocalDb.upsertOne('sales', payload);
    // 入待推送队列（debounce 250ms 后批量 push 到服务端，LWW 幂等）
    await SyncService.enqueueChange(
      entityType: 'sale',
      entitySyncId: saleId,
      action: 'upsert',
      payload: payload,
    );
    // 使用频率计数（本地，影响记单页商品排序）
    await Freq.bump(valid.map((r) => r.priceId ?? ''));
    await Freq.bumpClient(_clientId ?? '');
    for (final r in valid) {
      await Freq.saveLastQty(r.priceId ?? '', r.quantity);
    }
    toast(context, _editing ? '已保存，正在同步' : '已提交，合计 ¥${_total.toStringAsFixed(2)}');
    if (mounted) Navigator.pop(context, true);
    if (mounted) setState(() => _busy = false);
  }

  /// 复制上一笔出货单：预填店铺与明细，可修改后提交
  Future<void> _copyLast() async {
    try {
      final d = await Api.instance.get('/sales?limit=1');
      final sales = ((d['sales'] as List?) ?? []);
      if (sales.isEmpty) {
        toast(context, '暂无历史出货单');
        return;
      }
      final last = sales.first as Map<String, dynamic>;
      final items = ((last['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      setState(() {
        _clientId = last['client_id'] as String?;
        _rows.clear();
        for (final it in items) {
          final itemId = '${it['item_id']}';
          final unit = '${it['unit'] ?? ''}';
          final opt = _items.where((x) => x.id == itemId).firstOrNull;
          final price = opt?.prices.where((p) => '${p['unit']}' == unit).firstOrNull;
          if (opt == null || price == null) continue;
          final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
          final sp = (it['sale_price'] as num?)?.toDouble() ?? 0;
          final row = _Row()
            ..itemId = itemId
            ..priceId = price['id'] as String?
            ..quantity = qty
            ..salePrice = sp
            ..nameCtrl.text = '${it['item_name'] ?? opt.name}'
            ..unitCtrl.text = unit
            ..qtyCtrl.text = qty.toString()
            ..saleCtrl.text = sp.toStringAsFixed(2);
          _rows.add(row);
        }
        if (_rows.isEmpty) _rows.add(_Row());
      });
      toast(context, '已复制上一笔出货单，可修改后提交');
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? '编辑出货单' : '出货记单'),
        actions: [
          IconButton(
            tooltip: '凭证附件',
            icon: const Icon(Icons.image_outlined),
            onPressed: _busy
                ? null
                : () => showAttachmentPanel(context, 'sale', _saleId, '出货单凭证附件'),
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
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          _infoCard(),
          const SizedBox(height: 10),
          for (int i = 0; i < _rows.length; i++) _buildRow(i),
          const SizedBox(height: 10),
          // 添加商品（提交栏固定在底部悬浮）
          OutlinedButton.icon(
            onPressed: () => setState(() => _rows.add(_Row())),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加商品'),
            style: OutlinedButton.styleFrom(
              foregroundColor: c.primary,
              side: BorderSide(color: c.primary.withOpacity(0.5)),
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
                  backgroundColor: c.primary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? '提交中…' : (_editing ? '保存修改' : '提交出货单')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 填充式输入框装饰（圆角 12、无边框、聚焦主色描边）
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
        borderSide: BorderSide(color: c.primary, width: 1.4),
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

  /// 店铺 + 日期信息卡
  Widget _infoCard() {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return _card(Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _clientId,
            decoration: _fieldDec(icon: Icons.storefront, label: '店铺'),
            items: _clients
                .map((c) => DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String)))
                .toList(),
            onChanged: (v) => setState(() => _clientId = v),
          ),
          const SizedBox(height: 10),
          DateField(
            controller: _dateCtrl,
            icon: Icons.calendar_today_outlined,
            label: '日期',
            hint: '点击选择日期（可补录历史）',
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
    final item = row.itemId == null ? null : _items.where((x) => x.id == row.itemId).firstOrNull;
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
                  color: c.primary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text('${i + 1}',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.primary)),
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
                icon: const Icon(Icons.search, size: 22, color: Color(0xFF409EFF)),
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
          if (item != null && item.category.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 44),
              child: Text('分类：${item.category}', style: TextStyle(fontSize: 11, color: c.textSub)),
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
          const SizedBox(height: 10),
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
                  controller: row.saleCtrl,
                  style: txtStyle,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _fieldDec(label: '出价（可直接改）'),
                  onChanged: (v) => row.salePrice = double.tryParse(v) ?? 0,
                ),
              ),
            ],
          ),
        ],
      ),
    ));
  }
}