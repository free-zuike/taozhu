import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import 'router.dart';

/// 价格组管理：店铺等级→取价档（零售/批发/VIP 等）。
/// 记单时按店铺所属价格组带出该商品的组价（优先级：识别 → 最近成交 → 等级价 → 商品库兜底）。
class PriceGroupsPage extends StatefulWidget {
  const PriceGroupsPage({super.key});
  @override
  State<PriceGroupsPage> createState() => _PriceGroupsPageState();
}

class _PriceGroupsPageState extends State<PriceGroupsPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  List<Map<String, dynamic>> _groups = [];
  bool _loading = true;

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
    // ① 本地库秒开（页面加载零网络请求）
    final local = await LocalDb.getAll('price_groups');
    if (mounted) {
      setState(() {
        _groups = local..sort((a, b) => ((a['sort'] as num?)?.toInt() ?? 0).compareTo((b['sort'] as num?)?.toInt() ?? 0));
        _loading = false;
      });
    }
    // ② 网络刷新 + 写本地库（静默）：仅同步完成/下拉/Web 直连时执行
    if (!network && !kIsWeb) return;
    try {
      final d = await Api.instance.get('/price-groups');
      final rows = ((d['price_groups'] as List?) ?? []).cast<Map<String, dynamic>>();
      await LocalDb.upsertList('price_groups', rows);
      if (!mounted) return;
      setState(() {
        _groups = rows..sort((a, b) => ((a['sort'] as num?)?.toInt() ?? 0).compareTo((b['sort'] as num?)?.toInt() ?? 0));
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增价格组'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: '价格组名称（如 零售/批发/VIP）')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty) {
      toast(context, '请填写价格组名称');
      return;
    }
    try {
      if (kIsWeb) {
        await Api.instance.post('/price-groups', {'name': name});
        toast(context, '已添加');
        _load(network: true);
        return;
      }
      // 原生本地优先：本地写 + 队列推送（价格组是同步实体，离线可用）
      final id = 'pg${DateTime.now().microsecondsSinceEpoch}';
      final payload = {'id': id, 'name': name, 'sort': _groups.length};
      await LocalDb.upsertOne('price_groups', payload);
      await SyncService.enqueueChange(entityType: 'price_group', entitySyncId: id, payload: payload);
      toast(context, '已添加，正在同步');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _rename(Map<String, dynamic> g) async {
    final ctrl = TextEditingController(text: '${g['name']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名价格组'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: '价格组名称')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty || name == g['name']) return;
    try {
      if (kIsWeb) {
        await Api.instance.patch('/price-groups/${g['id']}', {'name': name});
        toast(context, '已保存');
        _load(network: true);
        return;
      }
      final payload = Map<String, dynamic>.from(g);
      payload['name'] = name;
      await LocalDb.upsertOne('price_groups', payload);
      await SyncService.enqueueChange(entityType: 'price_group', entitySyncId: '${g['id']}', payload: payload);
      toast(context, '已保存，正在同步');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _delete(Map<String, dynamic> g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除价格组'),
        content: Text('确定删除「${g['name']}」吗？\n引用该价格组的店铺将变为未分级，记单按默认价。'),
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
        await Api.instance.delete('/price-groups/${g['id']}');
        toast(context, '已删除');
        _load(network: true);
        return;
      }
      await LocalDb.deleteOne('price_groups', '${g['id']}');
      await SyncService.enqueueChange(
          entityType: 'price_group', entitySyncId: '${g['id']}',
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
        flexibleSpace: appBarBackground(context), // 顶部露出主题背景（无标题文字）
        actions: [
          IconButton(onPressed: () => _add(), icon: const Icon(Icons.add)),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: themePageBackground(context)),
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  '店铺按价格组分级，记单时自动带出该等级的售价（识别价 → 最近成交 → 等级价 → 商品库兜底）。',
                  style: TextStyle(fontSize: 12, color: colors.textSub),
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: () => _load(network: true),
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          children: [
                            if (_groups.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(32),
                                child: Center(
                                    child: Text('暂无价格组，点右上角 ＋ 添加', style: TextStyle(color: colors.textSub))),
                              ),
                            for (final g in _groups)
                              Card(
                                child: ListTile(
                                  leading: Icon(Icons.local_offer_outlined, color: colors.primary),
                                  title: Text('${g['name']}'),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: Icon(Icons.edit, color: colors.textSub),
                                        onPressed: () => _rename(g),
                                      ),
                                      IconButton(
                                        icon: Icon(Icons.delete_outline, color: colors.danger),
                                        onPressed: () => _delete(g),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
