import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import 'router.dart';

class ClientsPage extends StatefulWidget {
  const ClientsPage({super.key});
  @override
  State<ClientsPage> createState() => _ClientsPageState();
}

class _ClientsPageState extends State<ClientsPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  List<Map<String, dynamic>> _clients = [];
  List<Map<String, dynamic>> _cats = [];
  Map<String, String> _catNameById = {}; // 本地分类 id → 名称（列表行显示分类用）
  bool _loading = true;
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    SyncService.version.addListener(_onSync);
    _load();
    _loadCats();
  }

  @override
  void dispose() {
    SyncService.version.removeListener(_onSync);
    _searchTimer?.cancel();
    super.dispose();
  }

  void _onSync() {
    if (mounted) {
      _load();
      _loadCats(); // 同步完成后刷新分类（本地库补全后，无网时店铺分类也不空白）
    }
  }

  Future<void> _loadCats() async {
    // 原生：本地镜像（同步驱动）；Web：直连服务器
    var rows = <Map<String, dynamic>>[];
    if (kIsWeb) {
      try {
        final d = await Api.instance.get('/categories?type=client');
        rows = ((d['categories'] as List?) ?? []).cast<Map<String, dynamic>>();
      } catch (_) {
        return;
      }
    } else {
      rows = (await LocalDb.getAll('categories'))
          .where((x) => '${x['type'] ?? ''}' == 'client')
          .toList();
    }
    if (mounted) setState(() {
      _cats = rows;
      // 本地分类 id → 名称映射（列表行显示分类用；本地镜像无 category_name 字段，需反查）
      _catNameById = {
        for (final x in rows) '${x['id']}': '${x['name'] ?? ''}',
      };
    });
  }

  List<Map<String, dynamic>> get _topCats =>
      _cats.where((c) => c['parent_id'] == null || '${c['parent_id']}' == '').toList();
  List<Map<String, dynamic>> _subCatsOf(String topId) =>
      _cats.where((c) => '${c['parent_id']}' == topId).toList();

  Future<void> _load({String q = ''}) async {
    final searching = q.isNotEmpty;
    if (kIsWeb) {
      // Web（无本地库）：普通加载本地秒开 + 网络刷新；搜索直连服务器
      if (!searching) {
        final local = await LocalDb.getAllByName('clients');
        // Web 端 LocalDb 恒空：跳过空渲染，避免 WS 通知时列表"空白→填充"跳动；仅本地有数据才先渲染
        if (local.isNotEmpty && mounted) {
          setState(() {
            _clients = local;
            _loading = false;
          });
        }
      }
      // ② 网络刷新 + 写本地库（静默；失败保留本地展示）
      try {
        final d = await Api.instance
            .get(searching ? '/clients?q=${Uri.encodeQueryComponent(q)}' : '/clients');
        final rows = ((d['clients'] as List?) ?? []).cast<Map<String, dynamic>>();
        // 本地已删除但尚未推送落地的店铺：过滤掉再展示/写库，防止"删了又出现"
        var visible = rows;
        if (!searching) {
          final hideIds = await SyncService.pendingDeletedIds('client');
          if (hideIds.isNotEmpty) {
            visible = rows.where((r) => !hideIds.contains('${r['id']}')).toList();
          }
          await LocalDb.upsertList('clients', visible);
        }
        if (!mounted) return;
        setState(() {
          _clients = visible;
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
    final local = await LocalDb.getAllByName('clients');
    // 本地计算各店欠款（Σ出货 − Σ收款，与服务端口径一致）：同步 payload 不含 sales_total/paid_total，
    // 列表行欠款若直接读这两个字段恒为 0
    if (!kIsWeb) {
      final s = <String, double>{};
      final p = <String, double>{};
      try {
        for (final x in await LocalDb.getAll('sales')) {
          final id = '${x['client_id']}';
          s[id] = (s[id] ?? 0) + ((x['total'] as num?)?.toDouble() ?? 0);
        }
        for (final x in await LocalDb.getAll('payments')) {
          final id = '${x['client_id']}';
          p[id] = (p[id] ?? 0) + ((x['amount'] as num?)?.toDouble() ?? 0) + ((x['waived'] as num?)?.toDouble() ?? 0);
        }
      } catch (_) {}
      _clientDebt = {
        for (final id in {...s.keys, ...p.keys}) id: (s[id] ?? 0) - (p[id] ?? 0),
      };
    }
    if (mounted) {
      setState(() {
        _clients = searching ? local.where((x) => '${x['name'] ?? ''}'.contains(q)).toList() : local;
        _loading = false;
      });
    }
  }

  /// 各店欠款（原生本地计算 map；Web 直接用服务端字段）
  Map<String, double> _clientDebt = {};

  double _debt(Map<String, dynamic> c) {
    final server = ((c['sales_total'] as num?)?.toDouble() ?? 0) - ((c['paid_total'] as num?)?.toDouble() ?? 0);
    return _clientDebt['${c['id']}'] ?? server;
  }

  /// 记账天数（今天 − 第一笔记账日期 + 1）
  int _bookDays(String firstDate) {
    final f = DateTime.tryParse(firstDate);
    if (f == null) return 0;
    final now = DateTime.now();
    final d = DateTime(now.year, now.month, now.day)
        .difference(DateTime(f.year, f.month, f.day))
        .inDays + 1;
    return d < 1 ? 1 : d;
  }

  Future<void> _edit([Map<String, dynamic>? c]) async {
    final nameCtrl = TextEditingController(text: c?['name'] as String? ?? '');
    final dayCtrl = TextEditingController(
        text: '${(((c?['month_start_day'] as num?) ?? 1)).toInt()}');
    String? selTopId;
    String? selSubId;
    // 编辑时按当前分类反推一级/二级
    final curId = c?['category_id'] as String? ?? '';
    if (curId.isNotEmpty) {
      final cur = _cats.where((x) => '${x['id']}' == curId).firstOrNull;
      if (cur != null && cur['parent_id'] != null && '${cur['parent_id']}' != '') {
        selTopId = '${cur['parent_id']}';
        selSubId = curId;
      } else if (cur != null) {
        selTopId = curId;
      }
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c == null ? '新增店铺' : '编辑店铺'),
        content: StatefulBuilder(
          builder: (ctx, setDlg) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '店铺名称 *')),
              const SizedBox(height: 8),
              // 每月起始日：直接填数字（1-28，1=自然月），结账周期从该日起算
              TextField(
                controller: dayCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '每月起始日', helperText: '填 1-28，1=自然月'),
              ),
              const SizedBox(height: 8),
              if (_topCats.isNotEmpty) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: selTopId,
                  decoration: const InputDecoration(labelText: '分类（可选）'),
                  hint: const Text('选择分类'),
                  items: _topCats
                      .map((x) => DropdownMenuItem(value: '${x['id']}', child: Text('${x['name']}')))
                      .toList(),
                  onChanged: (v) => setDlg(() {
                    selTopId = v;
                    selSubId = null;
                  }),
                ),
                if (selTopId != null && _subCatsOf(selTopId!).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: selSubId,
                    decoration: const InputDecoration(labelText: '子分类（可选）'),
                    hint: const Text('如 火锅店/中餐'),
                    items: _subCatsOf(selTopId!)
                        .map((x) => DropdownMenuItem(value: '${x['id']}', child: Text('${x['name']}')))
                        .toList(),
                    onChanged: (v) => setDlg(() => selSubId = v),
                  ),
                ],
              ] else ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('暂无店铺分类，可先在「我的 → 分类管理」创建',
                      style: TextStyle(color: _c.textSub, fontSize: 12)),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) {
      toast(context, '请填写店铺名称');
      return;
    }
    final msd = int.tryParse(dayCtrl.text.trim());
    if (msd == null || msd < 1 || msd > 28) {
      toast(context, '每月起始日须为 1-28 的整数');
      return;
    }
    final categoryId = selSubId ?? selTopId;
    if (kIsWeb) {
      // Web 无本地库/同步队列：直连服务端（App 走本地优先队列）
      try {
        if (c == null) {
          await Api.instance.post('/clients', {
            'name': name, 'month_start_day': msd, 'category_id': categoryId ?? '',
          });
        } else {
          await Api.instance.patch('/clients/${c['id']}', {
            'name': name, 'month_start_day': msd, 'category_id': categoryId ?? '',
          });
        }
        toast(context, '已保存');
      } catch (e) {
        toast(context, e.toString().replaceFirst('Exception: ', ''));
        return;
      }
      _load();
      return;
    }
    // 写本地优先
    if (c == null) {
      final id = 'c${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';
      final payload = {
        'id': id, 'name': name, 'contact': '', 'phone': '', 'note': '',
        'start_date': '', 'end_date': '', 'month_start_day': msd,
        'category_id': categoryId ?? '', 'deleted_at': null,
      };
      await LocalDb.upsertOne('clients', payload);
      await SyncService.enqueueChange(entityType: 'client', entitySyncId: id, payload: payload);
    } else {
      final payload = Map<String, dynamic>.from(c);
      payload['name'] = name;
      payload['month_start_day'] = msd;
      payload['category_id'] = categoryId ?? '';
      await LocalDb.upsertOne('clients', payload);
      await SyncService.enqueueChange(entityType: 'client', entitySyncId: '${c['id']}', payload: payload);
    }
    toast(context, '已保存，正在同步');
    _load();
  }

  Future<void> _delete(Map<String, dynamic> c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除店铺'),
        content: Text('确定删除「${c['name']}」吗？历史记账不受影响。'),
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
        await Api.instance.delete('/clients/${c['id']}');
        toast(context, '已删除');
      } catch (e) {
        toast(context, e.toString().replaceFirst('Exception: ', ''));
        return;
      }
    } else {
      // 软删：本地删行 + 队列推送 upsert 带 deleted_at（服务端软删，历史单据引用不断）
      final delPayload = Map<String, dynamic>.from(c);
      delPayload['deleted_at'] = DateTime.now().toIso8601String();
      await LocalDb.deleteOne('clients', '${c['id']}');
      await SyncService.enqueueChange(entityType: 'client', entitySyncId: '${c['id']}', payload: delPayload);
      toast(context, '已删除，正在同步');
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('店铺'),
        actions: [
          IconButton(onPressed: () => _edit(), icon: const Icon(Icons.add)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: '搜索店铺（名称关键字）',
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
                  for (final c in _clients)
                    Card(
                      child: ListTile(
                        title: Text('${c['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text([
                          if ('${c['category_name'] ?? ''}'.isNotEmpty) '${c['category_name']}'
                          else if ('${_catNameById['${c['category_id'] ?? ''}'] ?? ''}'.isNotEmpty)
                            '${_catNameById['${c['category_id'] ?? ''}']}',
                          if (((c['month_start_day'] as num?) ?? 1) > 1) '每月 ${c['month_start_day']} 日起算',
                          if ('${c['first_book_date'] ?? ''}'.isNotEmpty)
                            '记账 ${_bookDays('${c['first_book_date']}')} 天（自 ${c['first_book_date']}）',
                        ].join(' · ')),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text('欠款', style: TextStyle(fontSize: 11, color: _c.textSub)),
                                Text('¥${_debt(c).toStringAsFixed(2)}',
                                    style: TextStyle(
                                        color: _debt(c) > 0 ? _c.danger : _c.success,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 20),
                              onPressed: () => _edit(c),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline, size: 20, color: _c.danger),
                              onPressed: () => _delete(c),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_clients.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(child: Text('暂无店铺，点右上角 ＋ 添加', style: TextStyle(color: _c.textSub))),
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
