import 'dart:async';
import 'dart:math';
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
  bool _loading = true;
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _loadCats();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadCats() async {
    try {
      final d = await Api.instance.get('/categories?type=client');
      setState(() => _cats = ((d['categories'] as List?) ?? []).cast<Map<String, dynamic>>());
    } catch (_) {}
  }

  List<Map<String, dynamic>> get _topCats =>
      _cats.where((c) => c['parent_id'] == null || '${c['parent_id']}' == '').toList();
  List<Map<String, dynamic>> _subCatsOf(String topId) =>
      _cats.where((c) => '${c['parent_id']}' == topId).toList();

  Future<void> _load({String q = ''}) async {
    final searching = q.isNotEmpty;
    // 搜索时不读本地、不写本地，走最新网络结果
    if (!searching) {
      // ① 本地数据库秒开（离线可见）
      final local = await LocalDb.getAllByName('clients');
      if (local.isNotEmpty && mounted) {
        setState(() => _clients = local);
      }
    }
    // ② 网络刷新 + 写本地库
    try {
      final d = await Api.instance
          .get(searching ? '/clients?q=${Uri.encodeQueryComponent(q)}' : '/clients');
      final rows = ((d['clients'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (!searching) await LocalDb.upsertList('clients', rows);
      if (!mounted) return;
      setState(() {
        _clients = rows;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  double _debt(Map<String, dynamic> c) =>
      ((c['sales_total'] as num?)?.toDouble() ?? 0) - ((c['paid_total'] as num?)?.toDouble() ?? 0);

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
    // 软删：本地删行 + 队列推送 upsert 带 deleted_at（服务端软删，历史单据引用不断）
    final delPayload = Map<String, dynamic>.from(c);
    delPayload['deleted_at'] = DateTime.now().toIso8601String();
    await LocalDb.deleteOne('clients', '${c['id']}');
    await SyncService.enqueueChange(entityType: 'client', entitySyncId: '${c['id']}', payload: delPayload);
    toast(context, '已删除，正在同步');
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
                          if ('${c['category_name'] ?? ''}'.isNotEmpty) '${c['category_name']}',
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
