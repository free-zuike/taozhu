import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import 'router.dart';

/// 分类管理：商品分类 / 店铺分类（两级）
class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key});
  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  String _type = 'item';
  List<Map<String, dynamic>> _cats = [];
  bool _loading = true;
  /// 已收起的一级分类 id（二级分类默认展开，点一级标题折叠/展开）
  final Set<String> _collapsed = {};

  List<Map<String, dynamic>> get _top => _cats.where((c) => c['parent_id'] == null || '${c['parent_id']}' == '').toList();
  List<Map<String, dynamic>> _childrenOf(String id) =>
      _cats.where((c) => '${c['parent_id']}' == id).toList();

  @override
  void initState() {
    super.initState();
    SyncService.version.addListener(_onSync);
    _load();
  }

  @override
  void dispose() {
    SyncService.version.removeListener(_onSync);
    super.dispose();
  }

  void _onSync() {
    if (mounted) _load(network: true);
  }

  Future<void> _load({bool network = false}) async {
    // ① 本地库秒开（含空态；不再等网络转圈，页面加载零网络请求）
    final local = await LocalDb.getAll('categories');
    if (mounted) {
      setState(() {
        final byType = local.where((x) => '${x['type']}' == _type).toList();
        _cats = byType;
        _loading = false;
      });
    }
    // ② 网络刷新 + 写本地库（静默）：仅同步完成/下拉/Web 直连时执行
    if (!network && !kIsWeb) return;
    try {
      final d = await Api.instance.get('/categories?type=$_type');
      final rows = ((d['categories'] as List?) ?? []).cast<Map<String, dynamic>>();
      await LocalDb.upsertList('categories', rows);
      if (!mounted) return;
      setState(() {
        _cats = rows;
        _loading = false;
      });
    } catch (_) {
      // 离线：本地缓存已展示，错误已记日志，不再弹提示
      if (!mounted) return;
      setState(() => _loading = false);
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
      if (kIsWeb) {
        // Web 无本地库/同步队列：直连服务端
        await Api.instance.post('/categories', {'type': _type, 'name': name, 'parent_id': parentId});
        toast(context, '已添加');
        _load(network: true);
        return;
      }
      // 原生本地优先：本地写 + 队列推送（分类是同步实体，离线可用）
      final id = 'cat${DateTime.now().microsecondsSinceEpoch}';
      final payload = {
        'id': id, 'type': _type, 'name': name,
        'parent_id': parentId ?? null, 'sort': 0,
      };
      await LocalDb.upsertOne('categories', payload);
      await SyncService.enqueueChange(entityType: 'category', entitySyncId: id, payload: payload);
      toast(context, '已添加，正在同步');
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
      if (kIsWeb) {
        // Web 无本地库/同步队列：直连服务端
        await Api.instance.patch('/categories/${c['id']}', {'name': name});
        toast(context, '已保存');
        _load(network: true);
        return;
      }
      // 原生本地优先：本地镜像更新 + 队列推送
      final payload = Map<String, dynamic>.from(c);
      payload['name'] = name;
      await LocalDb.upsertOne('categories', payload);
      await SyncService.enqueueChange(entityType: 'category', entitySyncId: '${c['id']}', payload: payload);
      toast(context, '已保存，正在同步');
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
            style: FilledButton.styleFrom(backgroundColor: _c.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (kIsWeb) {
        // Web 无本地库/同步队列：直连服务端
        await Api.instance.delete('/categories/${c['id']}');
        toast(context, '已删除');
        _load(network: true);
        return;
      }
      // 原生本地优先：本地删行 + 队列推送 delete + 立即推送（删除即时生效，防复活）
      await LocalDb.deleteOne('categories', '${c['id']}');
      await SyncService.enqueueChange(
          entityType: 'category', entitySyncId: '${c['id']}',
          action: 'delete', payload: {});
      unawaited(SyncService.pushPending());
      toast(context, '已删除，正在同步');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = _c;
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
                    onRefresh: () => _load(network: true),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: [
                        if (_top.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Center(
                                child: Text('暂无分类，点右上角 ＋ 添加', style: TextStyle(color: colors.textSub))),
                          ),
                        for (final c in _top) ...[
                          _itemTile(c, indent: false),
                          if (!_collapsed.contains('${c['id']}'))
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
    final collapsed = _collapsed.contains('${c['id']}');
    return Card(
      child: ListTile(
        contentPadding: EdgeInsets.only(left: indent ? 32 : 16, right: 8),
        leading: Icon(indent ? Icons.subdirectory_arrow_right : (isParent ? Icons.folder : Icons.label_outline),
            color: _c.primary, size: 20),
        title: Text('${c['name']}', style: TextStyle(fontWeight: indent ? FontWeight.w400 : FontWeight.w600)),
        // 一级分类可点击折叠/展开子分类（有子分类时显示箭头）
        onTap: isParent && !indent
            ? () => setState(() {
                  if (!_collapsed.add('${c['id']}')) _collapsed.remove('${c['id']}');
                })
            : null,
        subtitle: (isParent && !indent)
            ? Text('${_childrenOf('${c['id']}').length} 个子分类 · ${collapsed ? '点击展开' : '点击收起'}',
                style: TextStyle(fontSize: 11, color: _c.textSub))
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isParent && !indent)
              Icon(collapsed ? Icons.expand_more : Icons.expand_less, size: 20, color: _c.textSub),
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
              icon: Icon(Icons.delete_outline, size: 20, color: _c.danger),
              onPressed: () => _delete(c),
            ),
          ],
        ),
      ),
    );
  }
}
