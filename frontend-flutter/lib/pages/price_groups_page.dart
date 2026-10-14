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
    // ① 本地库秒开（页面加载零网络请求）；价格组是软删同步实体——本地镜像可能含
    // deleted_at 非空的已删组（删除后 pull 回本地），读取必须过滤（用户"删除了就出现"）
    final local = await LocalDb.getAll('price_groups');
    if (mounted) {
      setState(() {
        _groups = local.where((x) => '${x['deleted_at'] ?? ''}'.isEmpty).toList()
          ..sort((a, b) => ((a['sort'] as num?)?.toInt() ?? 0).compareTo((b['sort'] as num?)?.toInt() ?? 0));
        _loading = false;
      });
    }
    // ② 网络刷新 + 写本地库（静默）：仅同步完成/下拉/Web 直连时执行
    if (!network && !kIsWeb) return;
    try {
      final d = await Api.instance.get('/price-groups');
      final rows = ((d['price_groups'] as List?) ?? []).cast<Map<String, dynamic>>();
      // 本地已删除但尚未推送落地的组：过滤掉再展示/写库，防止"删了又出现"
      // （删除推送未落地时服务端还是未删状态，拉回会覆盖本地 deleteOne）
      final hideIds = await SyncService.pendingDeletedIds('price_group');
      final visible = hideIds.isEmpty
          ? rows
          : rows.where((r) => !hideIds.contains('${r['id']}')).toList();
      await LocalDb.upsertList('price_groups', visible);
      if (!mounted) return;
      setState(() {
        _groups = visible.where((x) => '${x['deleted_at'] ?? ''}'.isEmpty).toList()
          ..sort((a, b) => ((a['sort'] as num?)?.toInt() ?? 0).compareTo((b['sort'] as num?)?.toInt() ?? 0));
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

  /// 从现有店铺销售记录总结每商品最近成交单价，填充该价格组售价（用户"懒得去一个一个设置了"）。
  /// 原生本地优先：读本地镜像计算 → 写本地 items + 队列推送（离线可用）；Web 直连服务器接口。
  Future<void> _summarize(Map<String, dynamic> g) async {
    // 店铺列表：原生读本地镜像，Web 拉服务器（LocalDb 在 Web 为空操作）
    List<Map<String, dynamic>> clients;
    if (kIsWeb) {
      clients = [];
      try {
        final d = await Api.instance.get('/clients');
        clients = ((d['clients'] as List?) ?? []).cast<Map<String, dynamic>>();
      } catch (_) {}
    } else {
      clients = await LocalDb.getAll('clients');
    }
    var selClient = ''; // ''=全部店铺
    var overwrite = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text('「${g['name']}」从店铺总结售价'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('按商品取最近一次成交单价填充本组售价：', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: selClient,
                decoration: const InputDecoration(labelText: '参考店铺', isDense: true),
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部店铺')),
                  for (final c in clients)
                    DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}')),
                ],
                onChanged: (v) => setDlg(() => selClient = v ?? ''),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                dense: true, contentPadding: EdgeInsets.zero,
                title: const Text('覆盖已有售价', style: TextStyle(fontSize: 14)),
                subtitle: const Text('关闭=只补缺（已设置的售价不动）', style: TextStyle(fontSize: 12)),
                value: overwrite,
                onChanged: (v) => setDlg(() => overwrite = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('总结')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      if (kIsWeb) {
        final d = await Api.instance.post('/price-groups/${g['id']}/summarize',
            {'client_id': selClient, 'mode': overwrite ? 'overwrite' : 'fill'});
        toast(context, '已总结：新增 ${d['added']}、更新 ${d['updated']}（涉及 ${d['items']} 个商品）');
        _load(network: true);
        return;
      }
      // 原生本地：镜像 sales 计算 (item_id|unit) → 最近成交单价
      final sales = await LocalDb.getAll('sales');
      final ref = <String, double>{};
      final refDate = <String, String>{};
      for (final s in sales) {
        if (selClient.isNotEmpty && '${s['client_id']}' != selClient) continue;
        final sh = '${s['happened_at'] ?? ''}';
        for (final it in ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>()) {
          final itemId = '${it['item_id'] ?? ''}';
          final unit = '${it['unit'] ?? ''}';
          if (itemId.isEmpty || unit.isEmpty) continue;
          final key = '$itemId|$unit';
          final h = '${it['happened_at'] ?? ''}';
          final date = h.length >= 10 ? h : sh;
          if (refDate.containsKey(key) && (refDate[key] ?? '').compareTo(date) >= 0) continue;
          refDate[key] = date;
          ref[key] = (it['sale_price'] as num?)?.toDouble() ?? 0;
        }
      }
      if (ref.isEmpty) {
        toast(context, '所选范围暂无销售记录可总结');
        return;
      }
      var added = 0;
      var updated = 0;
      final items = await LocalDb.getAll('items');
      for (final item in items) {
        final itemId = '${item['id'] ?? ''}';
        final gps = ((item['group_prices'] as List?) ?? []).cast<Map<String, dynamic>>().toList();
        final ownMap = <String, Map<String, dynamic>>{
          for (final x in gps)
            if ('${x['group_id']}' == '${g['id']}')
              '${x['item_id'] ?? itemId}|${x['unit'] ?? ''}': x,
        };
        var changed = false;
        var idx = 0;
        for (final e in ref.entries) {
          if (!e.key.startsWith('$itemId|')) continue;
          final value = e.value;
          if (value <= 0) continue;
          final sep = e.key.indexOf('|');
          final unit = e.key.substring(sep + 1);
          final ex = ownMap[e.key];
          if (ex != null) {
            if (overwrite && ((ex['sale_price'] as num?)?.toDouble() ?? 0) != value) {
              ex['sale_price'] = value;
              changed = true;
              updated++;
            }
          } else {
            gps.add({
              'id': 'gp${DateTime.now().microsecondsSinceEpoch + idx}',
              'item_id': itemId, 'unit': unit, 'group_id': '${g['id']}', 'sale_price': value,
            });
            changed = true;
            added++;
          }
          idx++;
        }
        if (changed) {
          item['group_prices'] = gps;
          await LocalDb.upsertOne('items', item);
          await SyncService.enqueueChange(entityType: 'item', entitySyncId: itemId, payload: item);
        }
      }
      toast(context, added == 0 && updated == 0
          ? '该价格组商品价已是最新，无需总结'
          : '已总结：新增 $added、更新 $updated，正在同步');
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
                                  subtitle: Text('从店铺销售记录总结售价', style: TextStyle(fontSize: 11, color: colors.textSub)),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: Icon(Icons.auto_awesome, color: colors.primary),
                                        tooltip: '从店铺总结售价',
                                        onPressed: () => _summarize(g),
                                      ),
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
