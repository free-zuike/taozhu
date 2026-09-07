import 'package:flutter/material.dart';
import '../api.dart';
import 'router.dart';

class ItemsPage extends StatefulWidget {
  const ItemsPage({super.key});
  @override
  State<ItemsPage> createState() => _ItemsPageState();
}

class _ItemsPageState extends State<ItemsPage> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // ① 本地缓存秒开
    final cached = await Api.instance.getCached('/items');
    if (cached != null) {
      setState(() {
        _items = ((cached['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    }
    // ② 网络刷新 + 更新缓存
    try {
      final d = await Api.instance.get('/items');
      await Api.instance.setCache('/items', d);
      if (!mounted) return;
      setState(() {
        _items = ((d['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (cached == null) toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _delete(String id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除商品'),
        content: Text('确定删除「$name」吗？相关历史记录不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFF56C6C)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.instance.delete('/items/$id');
      toast(context, '已删除');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('商品管理')),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _ItemEditPage()));
          _load();
        },
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final it in _items)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    Text('${it['name']}',
                                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                                    const SizedBox(width: 8),
                                    Text('${it['category_name'] ?? ''}${((it['category_name'] as String?) ?? '').isEmpty ? (it['category'] ?? '') : ''}',
                                        style: const TextStyle(color: Color(0xFF909399))),
                                  ]),
                                  const SizedBox(height: 6),
                                  for (final p in (it['prices'] as List? ?? []))
                                    Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 2),
                                      child: Text(
                                          '${p['unit']}：进 ¥${p['purchase_price']} → 出 ¥${p['sale_price']}',
                                          style: const TextStyle(color: Color(0xFF606266), fontSize: 13)),
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Color(0xFFF56C6C)),
                              onPressed: () => _delete(it['id'] as String, '${it['name']}'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('暂无商品，点右下角 + 添加', style: TextStyle(color: Colors.grey))),
                    ),
                ],
              ),
            ),
    );
  }
}

class _ItemEditPage extends StatefulWidget {
  const _ItemEditPage();
  @override
  State<_ItemEditPage> createState() => _ItemEditPageState();
}

class _ItemEditPageState extends State<_ItemEditPage> {
  final _nameCtrl = TextEditingController();
  final List<Map<String, TextEditingController>> _priceRows = [_newRow()];
  List<Map<String, dynamic>> _cats = [];
  String? _categoryId;
  bool _busy = false;

  static Map<String, TextEditingController> _newRow() => {
        'unit': TextEditingController(),
        'buy': TextEditingController(),
        'sell': TextEditingController(),
      };

  @override
  void initState() {
    super.initState();
    _loadCats();
  }

  Future<void> _loadCats() async {
    try {
      final d = await Api.instance.get('/categories?type=item');
      setState(() {
        _cats = ((d['categories'] as List?) ?? [])
            .cast<Map<String, dynamic>>()
            .where((c) => c['parent_id'] == null || '${c['parent_id']}' == '')
            .toList();
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final r in _priceRows) {
      r['unit']?.dispose();
      r['buy']?.dispose();
      r['sell']?.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      toast(context, '请填写商品名称');
      return;
    }
    final prices = _priceRows
        .map((r) => {
              'unit': r['unit']!.text.trim(),
              'purchase_price': double.tryParse(r['buy']!.text) ?? 0,
              'sale_price': double.tryParse(r['sell']!.text) ?? 0,
            })
        .where((p) =>
            p['unit'] != '' && ((p['purchase_price'] as double) > 0 || (p['sale_price'] as double) > 0))
        .toList();
    if (prices.isEmpty) {
      toast(context, '请至少填写一个单位价格');
      return;
    }
    setState(() => _busy = true);
    try {
      final catName = _cats.where((c) => c['id'] == _categoryId).map((c) => '${c['name']}').firstOrNull;
      await Api.instance.post('/items', {
        'name': name,
        'category': catName ?? '',
        'category_id': _categoryId,
        'prices': prices,
      });
      toast(context, '已添加');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新增商品')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: '商品名称 *')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _categoryId,
            decoration: const InputDecoration(labelText: '分类（可选）'),
            hint: const Text('选择分类'),
            items: _cats
                .map((c) => DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}')))
                .toList(),
            onChanged: (v) => setState(() => _categoryId = v),
          ),
          const SizedBox(height: 16),
          const Text('单位价格（可多组，如 斤/包/箱）', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (int i = 0; i < _priceRows.length; i++)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _priceRows[i]['unit'],
                        decoration: const InputDecoration(labelText: '单位'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _priceRows[i]['buy'],
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: '进价'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _priceRows[i]['sell'],
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: '出价'),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Color(0xFF909399)),
                      onPressed: _priceRows.length > 1 ? () => setState(() => _priceRows.removeAt(i)) : null,
                    ),
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _priceRows.add(_newRow())),
              icon: const Icon(Icons.add),
              label: const Text('添加价格组'),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _busy ? null : _save,
            child: Text(_busy ? '保存中…' : '保存'),
          ),
        ],
      ),
    );
  }
}
