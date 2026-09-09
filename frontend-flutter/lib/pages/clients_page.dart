import 'dart:async';
import 'package:flutter/material.dart';
import '../api.dart';
import 'router.dart';

class ClientsPage extends StatefulWidget {
  const ClientsPage({super.key});
  @override
  State<ClientsPage> createState() => _ClientsPageState();
}

class _ClientsPageState extends State<ClientsPage> {
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
    Map<String, dynamic>? cached;
    // 搜索时不读缓存、不写缓存，走最新网络结果
    if (!searching) {
      // ① 本地缓存秒开
      cached = await Api.instance.getCached('/clients');
      if (cached != null) {
        setState(() => _clients = ((cached['clients'] as List?) ?? []).cast<Map<String, dynamic>>());
      }
    }
    // ② 网络刷新 + 更新缓存
    try {
      final d = await Api.instance
          .get(searching ? '/clients?q=${Uri.encodeQueryComponent(q)}' : '/clients');
      if (!searching) await Api.instance.setCache('/clients', d);
      if (!mounted) return;
      setState(() {
        _clients = ((d['clients'] as List?) ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (!searching && cached == null) toast(context, e.toString().replaceFirst('Exception: ', ''));
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
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('暂无店铺分类，可先在「我的 → 分类管理」创建',
                      style: TextStyle(color: Color(0xFF909399), fontSize: 12)),
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
    try {
      if (c == null) {
        await Api.instance.post('/clients', {
          'name': name,
          'month_start_day': msd,
          if (categoryId != null) 'category_id': categoryId,
        });
      } else {
        await Api.instance.patch('/clients/${c['id']}', {
          'name': name,
          'month_start_day': msd,
          'category_id': categoryId,
        });
      }
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
        title: const Text('删除店铺'),
        content: Text('确定删除「${c['name']}」吗？历史记账不受影响。'),
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
      await Api.instance.delete('/clients/${c['id']}');
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
                                const Text('欠款', style: TextStyle(fontSize: 11, color: Color(0xFF909399))),
                                Text('¥${_debt(c).toStringAsFixed(2)}',
                                    style: TextStyle(
                                        color: _debt(c) > 0 ? const Color(0xFFF56C6C) : const Color(0xFF67C23A),
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 20),
                              onPressed: () => _edit(c),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20, color: Color(0xFFF56C6C)),
                              onPressed: () => _delete(c),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_clients.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('暂无店铺，点右上角 ＋ 添加', style: TextStyle(color: Colors.grey))),
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
