import 'package:flutter/material.dart';
import '../api.dart';
import 'router.dart';

/// 分类管理：商品分类 / 店铺分类（两级）
class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key});
  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  String _type = 'item';
  List<Map<String, dynamic>> _cats = [];
  bool _loading = true;

  List<Map<String, dynamic>> get _top => _cats.where((c) => c['parent_id'] == null || '${c['parent_id']}' == '').toList();
  List<Map<String, dynamic>> _childrenOf(String id) =>
      _cats.where((c) => '${c['parent_id']}' == id).toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await Api.instance.get('/categories?type=$_type');
      setState(() {
        _cats = ((d['categories'] as List?) ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _add({String? parentId, String parentName = ''}) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(parentId == null ? '新增${_type == 'item' ? '商品' : '店铺'}分类' : '在「$parentName」下新增子分类'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: '分类名称')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty) {
      toast(context, '请填写分类名称');
      return;
    }
    try {
      await Api.instance.post('/categories', {'type': _type, 'name': name, 'parent_id': parentId});
      toast(context, '已添加');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _rename(Map<String, dynamic> c) async {
    final ctrl = TextEditingController(text: '${c['name']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分类'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: '分类名称')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty || name == c['name']) return;
    try {
      await Api.instance.patch('/categories/${c['id']}', {'name': name});
      toast(context, '已保存');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _delete(Map<String, dynamic> c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分类'),
        content: Text('确定删除「${c['name']}」吗？\n该分类下的商品/店铺将变为未分类。'),
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
      await Api.instance.delete('/categories/${c['id']}');
      toast(context, '已删除');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('分类管理'),
        actions: [
          IconButton(onPressed: () => _add(), icon: const Icon(Icons.add)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'item', label: Text('商品分类')),
                ButtonSegment(value: 'client', label: Text('店铺分类')),
              ],
              selected: {_type},
              onSelectionChanged: (s) {
                setState(() {
                  _type = s.first;
                  _loading = true;
                });
                _load();
              },
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: [
                        if (_top.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(
                                child: Text('暂无分类，点右上角 ＋ 添加', style: TextStyle(color: Colors.grey))),
                          ),
                        for (final c in _top) ...[
                          _itemTile(c, indent: false),
                          for (final child in _childrenOf('${c['id']}')) _itemTile(child, indent: true),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _itemTile(Map<String, dynamic> c, {required bool indent}) {
    final isParent = _childrenOf('${c['id']}').isNotEmpty;
    return Card(
      child: ListTile(
        contentPadding: EdgeInsets.only(left: indent ? 32 : 16, right: 8),
        leading: Icon(indent ? Icons.subdirectory_arrow_right : (isParent ? Icons.folder : Icons.label_outline),
            color: const Color(0xFF409EFF), size: 20),
        title: Text('${c['name']}', style: TextStyle(fontWeight: indent ? FontWeight.w400 : FontWeight.w600)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.add, size: 20),
              tooltip: '添加子分类',
              // 一级分类可添加任意多个子分类；仅禁止二级分类继续加（防三级）
              onPressed: indent ? null : () => _add(parentId: '${c['id']}', parentName: '${c['name']}'),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => _rename(c),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20, color: Color(0xFFF56C6C)),
              onPressed: () => _delete(c),
            ),
          ],
        ),
      ),
    );
  }
}
