import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import 'router.dart';

class ItemsPage extends StatefulWidget {
  const ItemsPage({super.key});
  @override
  State<ItemsPage> createState() => _ItemsPageState();
}

class _ItemsPageState extends State<ItemsPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  List<Map<String, dynamic>> _items = [];
  /// 本次会话内已删除商品 id（内存兜底）：本地库删除失败/未生效时，
  /// _load 读回也会被过滤，保证「点击删除」后 UI 一定消失（离线场景也生效）
  final Set<String> _deletedIds = {};
  bool _loading = true;
  bool _isStaff = false; // 店员不可见进价
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    Api.instance.getRole().then((r) {
      if (mounted) setState(() => _isStaff = r == 'staff');
    });
    SyncService.version.addListener(_onSync);
    _load();
  }

  @override
  void dispose() {
    SyncService.version.removeListener(_onSync);
    _searchTimer?.cancel();
    super.dispose();
  }

  void _onSync() {
    if (mounted) _load();
  }

  Future<void> _load({String q = ''}) async {
    final searching = q.isNotEmpty;
    // 本地库兜底：剔除 deleted_at 非空的行（旧版本全量同步可能把已软删商品写进本地库）
    List<Map<String, dynamic>> alive(List<Map<String, dynamic>> list) =>
        [for (final x in list) if ('${x['deleted_at'] ?? ''}'.isEmpty) x];
    // 本次会话已删商品（内存兜底）：任何加载路径都过滤，离线删除 UI 必消失
    List<Map<String, dynamic>> hideDeleted(List<Map<String, dynamic>> list) =>
        [for (final x in list) if (!_deletedIds.contains('${x['id']}')) x];
    if (kIsWeb) {
      // Web（无本地库）：普通加载本地秒开 + 网络刷新；搜索直连服务器
      if (!searching) {
        final local = hideDeleted(alive(await LocalDb.getAllByName('items')));
        if (mounted) {
          setState(() {
            _items = local;
            _loading = false;
          });
        }
      }
      // ② 网络刷新 + 写本地库（静默；失败保留本地展示）
      try {
        final d = await Api.instance
            .get(searching ? '/items?q=${Uri.encodeQueryComponent(q)}' : '/items');
        final rows = hideDeleted(alive(((d['items'] as List?) ?? []).cast<Map<String, dynamic>>()));
        // 本地已删除但尚未推送落地的商品：过滤掉再展示/写库，防止"删了又出现"
        //（推送成功后的 pull 会以 deleted_at 变化正式删除本地行）
        var visible = rows;
        if (!searching) {
          final hideIds = await SyncService.pendingDeletedIds('item');
          if (hideIds.isNotEmpty) {
            visible = rows.where((r) => !hideIds.contains('${r['id']}')).toList();
          }
          await LocalDb.upsertList('items', visible);
        }
        if (!mounted) return;
        setState(() {
          _items = visible;
          _loading = false;
        });
      } catch (_) {
        // 离线：本地缓存已展示，错误已记日志，不再弹提示
        if (!mounted || searching) return;
        setState(() => _loading = false);
      }
      return;
    }
    // 原生：列表页刷新只读本地库（同步只由「我的」页/进应用自动同步驱动）；搜索也搜本地镜像
    final local = hideDeleted(alive(await LocalDb.getAllByName('items')));
    // 本地已删除但尚未推送落地的商品：过滤掉，防止"删了又出现"（与 Web 分支口径一致）
    final hideIds = await SyncService.pendingDeletedIds('item');
    final visible = hideIds.isEmpty
        ? local
        : local.where((x) => !hideIds.contains('${x['id']}')).toList();
    if (mounted) {
      setState(() {
        _items = searching
            ? visible.where((x) => '${x['name'] ?? ''}'.contains(q)).toList()
            : visible;
        _loading = false;
      });
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
            style: FilledButton.styleFrom(backgroundColor: _c.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (kIsWeb) {
      // Web 无本地库/同步队列：直连接口软删（App 走本地优先队列）
      try {
        await Api.instance.delete('/items/$id');
        toast(context, '已删除');
      } catch (e) {
        toast(context, e.toString().replaceFirst('Exception: ', ''));
        return;
      }
    } else {
      // 本地优先删除：UI 立即反馈（内存隐藏 + 提示），本地写与队列后台尽力执行——
      // 即使本地库写入异常/挂起也不阻塞界面（异常记日志可查，联网后由队列推送服务端）
      final item = _items.where((x) => '${x['id']}' == id).firstOrNull; // 先取，随后内存移除
      _deletedIds.add(id);
      if (mounted) setState(() => _items.removeWhere((x) => '${x['id']}' == id));
      toast(context, '已删除，正在同步');
      try {
        if (item != null) {
          final delPayload = Map<String, dynamic>.from(item);
          delPayload['deleted_at'] = DateTime.now().toIso8601String();
          final prices = ((delPayload['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
          for (final p in prices) { p['active'] = 1; }
          delPayload['prices'] = prices;
          // 软删 tombstone 先写（保证重启不复活，不依赖物理删除完成）→ 物理删除后尽力 →
          // 入队推送服务端（本地优先、离线可用，全程不访问网络）
          await LocalDb.upsertOne('items', delPayload);
          try {
            await LocalDb.deleteOne('items', id);
          } catch (e) {
            appLog('delete', '物理删除失败 item=$id（tombstone 已写入，不影响删除）: ${e.toString().split('\n').first}', level: 'error');
          }
          await SyncService.enqueueChange(entityType: 'item', entitySyncId: id, payload: delPayload);
        } else {
          // 本地镜像找不到（可能已被删/未同步）→ 直接推删除 payload
          await SyncService.enqueueChange(entityType: 'item', entitySyncId: id, payload: {
            'id': id, 'name': name, 'deleted_at': DateTime.now().toIso8601String(),
          });
        }
      } catch (e) {
        appLog('delete', '删除商品本地写入异常 item=$id: ${e.toString().split('\n').first}', level: 'error');
      }
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('商品管理'),
        actions: [
          // 店员只读（隐藏新增入口）；新增统一在右上角（与店铺管理一致）
          if (!_isStaff)
            IconButton(
              tooltip: '新增商品',
              icon: const Icon(Icons.add),
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _ItemEditPage()));
                _load();
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: '搜索商品（名称关键字）',
                isDense: true,
              ),
              onChanged: (v) {
                _searchTimer?.cancel();
                final q = v.trim();
                _searchTimer =
                    Timer(const Duration(milliseconds: 350), () => _load(q: q));
              },
            ),
          ),
          Expanded(
            child: _loading
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
                                        style: TextStyle(color: _c.textSub)),
                                  ]),
                                  const SizedBox(height: 6),
                                  for (final p in (it['prices'] as List? ?? []))
                                    Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 2),
                                      child: Text(
                                          _isStaff
                                              ? '${p['unit']}：售价 ¥${p['sale_price']}'
                                              : '${p['unit']}：进价 ¥${p['purchase_price']} → 售价 ¥${p['sale_price']}',
                                          style: TextStyle(color: _c.textSub, fontSize: 13)),
                                    ),
                                ],
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!_isStaff) ...[
                                  IconButton(
                                    icon: Icon(Icons.edit_outlined, size: 20, color: _c.primary),
                                    tooltip: '编辑',
                                    onPressed: () async {
                                      await Navigator.of(context)
                                          .push(MaterialPageRoute(builder: (_) => _ItemEditPage(item: it)));
                                      _load();
                                    },
                                  ),
                                  IconButton(
                                    icon: Icon(Icons.delete_outline, color: _c.danger),
                                    onPressed: () => _delete('${it['id']}', '${it['name']}'),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(child: Text('暂无商品，点右上角 ＋ 添加', style: TextStyle(color: _c.textSub))),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemEditPage extends StatefulWidget {
  const _ItemEditPage({this.item});
  /// 非空 = 编辑已有商品（含价格组增删改），保存走 PATCH /items 相关接口
  final Map<String, dynamic>? item;
  @override
  State<_ItemEditPage> createState() => _ItemEditPageState();
}

class _ItemEditPageState extends State<_ItemEditPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  final _nameCtrl = TextEditingController();
  late final List<Map<String, TextEditingController>> _priceRows;
  late final List<String?> _priceIds; // 与 _priceRows 平行：null=新增行（编辑模式下用于区分增/改/删）
  List<Map<String, dynamic>> _cats = []; // 一级+二级全量（type=item）
  String? _topId; // 一级分类
  String? _subId; // 二级分类（依赖一级，可选）
  String? _pendingCid; // 编辑回显：_loadCats 完成后按 parent_id 反推一级/二级
  bool _busy = false;

  bool get _editing => widget.item != null;

  static Map<String, TextEditingController> _newRow(
      [String unit = '', String buy = '', String sell = '']) => {
        'unit': TextEditingController(text: unit),
        'buy': TextEditingController(text: buy),
        'sell': TextEditingController(text: sell),
      };

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    if (item != null) {
      _nameCtrl.text = '${item['name'] ?? ''}';
      final cid = '${item['category_id'] ?? ''}';
      _pendingCid = cid.isEmpty ? null : cid;
      final prices = ((item['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (prices.isEmpty) {
        _priceRows = [_newRow()];
        _priceIds = [null];
      } else {
        _priceRows = prices
            .map((p) => _newRow('${p['unit'] ?? ''}', '${p['purchase_price'] ?? ''}', '${p['sale_price'] ?? ''}'))
            .toList();
        _priceIds = prices
            .map((p) => '${p['id'] ?? ''}'.isEmpty ? null : '${p['id']}')
            .toList();
      }
    } else {
      _priceRows = [_newRow()];
      _priceIds = [null];
    }
    _loadCats();
  }

  Future<void> _loadCats() async {
    var cats = <Map<String, dynamic>>[];
    try {
      final d = await Api.instance.get('/categories?type=item');
      cats = ((d['categories'] as List?) ?? []).cast<Map<String, dynamic>>();
    } catch (_) {
      // 离线/网络失败：本地分类镜像兜底（Web 直连正常；App 弱网也有分类可选）
      final local = await LocalDb.getAll('categories');
      cats = [for (final c in local) if ('${c['type'] ?? ''}' == 'item') c];
    }
    if (!mounted) return;
    setState(() {
      _cats = cats; // 一级+二级全量
      // 编辑回显：按 category_id 反推一级/二级
      if (_pendingCid != null) {
        final c = cats.where((x) => '${x['id']}' == _pendingCid).firstOrNull;
        final pid = '${c?['parent_id'] ?? ''}';
        if (pid.isNotEmpty) {
          _topId = pid;
          _subId = _pendingCid;
        } else if (c != null) {
          _topId = _pendingCid;
          _subId = null;
        }
        _pendingCid = null;
      }
    });
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
    // 收集有效价格行（带 priceId 标记：null=新增）
    final rows = <Map<String, dynamic>>[];
    for (int i = 0; i < _priceRows.length; i++) {
      final unit = _priceRows[i]['unit']!.text.trim();
      final buy = double.tryParse(_priceRows[i]['buy']!.text) ?? 0;
      final sell = double.tryParse(_priceRows[i]['sell']!.text) ?? 0;
      if (unit == '' || (buy <= 0 && sell <= 0)) continue;
      rows.add({'unit': unit, 'buy': buy, 'sell': sell, 'priceId': _priceIds[i]});
    }
    if (rows.isEmpty) {
      toast(context, '请至少填写一个单位价格');
      return;
    }
    setState(() => _busy = true);
    // 写本地优先：构建完整 item payload（含 prices）→ 落本地库 → 入队列 → debounce push
    final selId = _subId ?? _topId;
    final catName = selId == null
        ? ''
        : _cats.where((c) => '${c['id']}' == selId).map((c) => '${c['name']}').firstOrNull ?? '';
    final itemId = _editing ? '${widget.item!['id']}' : 'i${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';
    final pricesPayload = <Map<String, dynamic>>[];
    for (final r in rows) {
      final pid = (r['priceId'] as String?) ?? 'pr${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';
      pricesPayload.add({
        'id': pid, 'item_id': itemId, 'unit': r['unit'],
        'purchase_price': r['buy'], 'sale_price': r['sell'], 'active': 1,
      });
    }
    final payload = {
      'id': itemId, 'name': name, 'category': catName,
      'category_id': selId ?? '', 'deleted_at': null,
      'prices': pricesPayload,
    };
    await LocalDb.upsertOne('items', payload);
    await SyncService.enqueueChange(entityType: 'item', entitySyncId: itemId, payload: payload);
    toast(context, _editing ? '已保存，正在同步' : '已添加，正在同步');
    if (mounted) Navigator.pop(context, true);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? '编辑商品' : '新增商品')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: '商品名称 *')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('top-$_topId'),
            initialValue: _topId,
            decoration: const InputDecoration(labelText: '分类（一级，可选）'),
            hint: const Text('选择一级分类'),
            items: _cats
                .where((c) => '${c['parent_id'] ?? ''}'.isEmpty)
                .map((c) => DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}')))
                .toList(),
            onChanged: (v) => setState(() {
              _topId = v;
              _subId = null; // 切换一级后二级重置
            }),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey('sub-$_topId-$_subId'),
            initialValue: _subId,
            decoration: const InputDecoration(labelText: '分类（二级，可选）'),
            hint: Text(_topId == null ? '先选一级分类' : '选择二级分类（可选）'),
            items: _cats
                .where((c) => '${c['parent_id']}' == _topId)
                .map((c) => DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}')))
                .toList(),
            onChanged: _topId == null ? null : (v) => setState(() => _subId = v),
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
                        decoration: const InputDecoration(labelText: '售价'),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, color: _c.textSub),
                      onPressed: _priceRows.length > 1
                          ? () => setState(() {
                                _priceRows.removeAt(i);
                                _priceIds.removeAt(i);
                              })
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() {
                _priceRows.add(_newRow());
                _priceIds.add(null);
              }),
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
