import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_accounts.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../widgets/date_field.dart';
import 'router.dart';

class PaymentsPage extends StatefulWidget {
  const PaymentsPage({super.key});
  @override
  State<PaymentsPage> createState() => _PaymentsPageState();
}

class _PaymentsPageState extends State<PaymentsPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  List<Map<String, dynamic>> _clients = [];
  List<Map<String, dynamic>> _payments = [];
  /// 本地计算的各店应收（欠款）：Σ出货 − Σ收款（原生本地化用；Web 用服务端 debt 字段）
  Map<String, double> _clientDebt = {};
  String? _clientId;
  double _selDebt = 0; // 当前选中店铺的应收（欠款）
  bool _waivedAuto = false; // 平账模式：false=手动（默认，不填减免=只记实收金额），true=自动（减免=应收-实收）
  final _amountCtrl = TextEditingController();
  final _waivedCtrl = TextEditingController(); // 平账减免（实收+减免=账面已收）
  final _dateCtrl = TextEditingController(text: _today());
  final _noteCtrl = TextEditingController();
  String _method = ''; // 收款方式（本地账户下拉选择）
  bool _busy = false;
  bool _loading = true;

  /// 今日日期（YYYY-MM-DD），登记默认值；可改=补录历史日期
  static String _today() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    SyncService.version.addListener(_onSync);
    _load();
  }

  @override
  void dispose() {
    SyncService.version.removeListener(_onSync);
    _amountCtrl.dispose();
    _waivedCtrl.dispose();
    _dateCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _onSync() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    // ① 本地数据库秒开（店铺目录 + 收款历史，离线可见；即使为空也先展示空态）
    final localClients = await LocalDb.getAllByName('clients');
    final localPays = await LocalDb.getAll('payments');
    // 原生本地化：列表页刷新只读本地，同步只由「我的」页/进应用自动同步驱动
    if (!kIsWeb) {
      // 本地计算各店应收（欠款）：Σ出货总额 − Σ收款金额（与后端口径一致）
      final s = <String, double>{};
      final p = <String, double>{};
      for (final x in await LocalDb.getAll('sales')) {
        final id = '${x['client_id']}';
        s[id] = (s[id] ?? 0) + ((x['total'] as num?)?.toDouble() ?? 0);
      }
      for (final x in await LocalDb.getAll('payments')) {
        final id = '${x['client_id']}';
        p[id] = (p[id] ?? 0) + ((x['amount'] as num?)?.toDouble() ?? 0);
      }
      _clientDebt = {
        for (final id in {...s.keys, ...p.keys}) id: (s[id] ?? 0) - (p[id] ?? 0),
      };
      if (mounted) {
        setState(() {
          _clients = localClients;
          _payments = localPays;
          _loading = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _clients = localClients;
        _payments = localPays;
        _loading = false;
      });
    }
    // ② Web（无本地库）：直连服务器刷新（静默；失败保留本地展示）
    try {
      final results = await Future.wait([
        Api.instance.get('/clients'),
        Api.instance.get('/payments?limit=50'),
      ]);
      final netClients = ((results[0]['clients'] as List?) ?? []).cast<Map<String, dynamic>>();
      final netPays = ((results[1]['payments'] as List?) ?? []).cast<Map<String, dynamic>>();
      await Future.wait([
        LocalDb.upsertList('clients', netClients),
        LocalDb.upsertList('payments', netPays),
      ]);
      if (!mounted) return;
      setState(() {
        _clients = netClients;
        _payments = netPays;
        _loading = false;
      });
    } catch (_) {
      // 离线：本地缓存已展示，错误已记日志，不再弹提示
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// 店铺欠款：服务端 debt 字段优先（Web），本地镜像缺失时用本地汇总兜底（原生）
  double _debtOf(Map<String, dynamic> c) {
    final v = (c['debt'] as num?)?.toDouble();
    if (v != null) return v;
    return _clientDebt['${c['id']}'] ?? 0;
  }

  /// 自动平账减免 = 应收 − 实收（非负；差几百几十直接抹平结账）
  double get _autoWaived {
    final amount = double.tryParse(_amountCtrl.text) ?? 0;
    return (_selDebt - amount).clamp(0, double.infinity).toDouble();
  }

  Future<void> _submit() async {
    final amount = double.tryParse(_amountCtrl.text) ?? 0;
    final waived = _waivedAuto ? _autoWaived : (double.tryParse(_waivedCtrl.text) ?? 0);
    if (_clientId == null) {
      toast(context, '请选择店铺');
      return;
    }
    if (amount <= 0) {
      toast(context, '请输入有效金额');
      return;
    }
    if (waived < 0) {
      toast(context, '减免金额不能为负数');
      return;
    }
    setState(() => _busy = true);
    if (kIsWeb) {
      // Web 无本地库/同步队列：直连服务端（sync_key 幂等）
      try {
        await Api.instance.post('/payments', {
          'client_id': _clientId,
          'amount': (amount * 100).round() / 100,
          'waived': (waived * 100).round() / 100,
          'happened_at': _dateCtrl.text.trim(),
          'method': _method,
          'note': _noteCtrl.text.trim(),
          'sync_key': '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0x7fffffff)}',
        });
        toast(context, waived > 0
            ? '已登记：实收 ¥${amount.toStringAsFixed(2)}，平账 ¥${waived.toStringAsFixed(2)}'
            : '已登记收款 ¥${amount.toStringAsFixed(2)}');
        _amountCtrl.clear();
        _waivedCtrl.clear();
      } catch (e) {
        toast(context, e.toString().replaceFirst('Exception: ', ''));
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    // 写本地优先：落本地库 + 入队列 → debounce push
    final payId = 'pay${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';
    final payload = {
      'id': payId,
      'client_id': _clientId,
      'amount': (amount * 100).round() / 100,
      'waived': (waived * 100).round() / 100,
      'happened_at': _dateCtrl.text.trim(),
      'method': _method,
      'note': _noteCtrl.text.trim(),
    };
    await LocalDb.upsertOne('payments', payload);
    await SyncService.enqueueChange(
      entityType: 'payment',
      entitySyncId: payId,
      action: 'upsert',
      payload: payload,
    );
    toast(context, waived > 0
        ? '已登记：实收 ¥${amount.toStringAsFixed(2)}，平账 ¥${waived.toStringAsFixed(2)}'
        : '已登记收款 ¥${amount.toStringAsFixed(2)}');
    _amountCtrl.clear();
    _waivedCtrl.clear();
    _waivedAuto = true;
    _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _edit(Map<String, dynamic> p) async {
    final amountCtrl = TextEditingController(text: '${p['amount']}');
    final waivedCtrl = TextEditingController(text: '${p['waived'] ?? 0}');
    final dateCtrl = TextEditingController(text: _date('${p['happened_at']}'));
    final noteCtrl = TextEditingController(text: '${p['note'] ?? ''}');
    var method = '${p['method'] ?? ''}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑收款'),
        content: StatefulBuilder(
          builder: (ctx, setDlg) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '金额（元）'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: waivedCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '平账减免（元，可改）'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: dateCtrl,
                decoration: const InputDecoration(labelText: '日期（YYYY-MM-DD）'),
              ),
              const SizedBox(height: 8),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () async {
                  final picked = await pickAccount(ctx, current: method);
                  if (picked != null && ctx.mounted) setDlg(() => method = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: '收款方式（账户）'),
                  child: Text(method.isEmpty ? '点击选择' : method,
                      style: TextStyle(color: Theme.of(ctx).brightness == Brightness.dark ? Colors.white : Colors.black)),
                ),
              ),
              const SizedBox(height: 8),
              TextField(controller: noteCtrl, decoration: const InputDecoration(labelText: '备注')),
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
    final amount = double.tryParse(amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      toast(context, '请输入有效金额');
      return;
    }
    final waived = double.tryParse(waivedCtrl.text.trim()) ?? 0;
    if (waived < 0) {
      toast(context, '减免金额不能为负数');
      return;
    }
    try {
      if (kIsWeb) {
        await Api.instance.patch('/payments/${p['id']}', {
          'amount': amount,
          'waived': waived,
          'happened_at': dateCtrl.text.trim(),
          'method': method,
          'note': noteCtrl.text.trim(),
        });
        toast(context, '已保存');
        _load();
        return;
      }
      // 原生本地优先：本地镜像更新 + 队列推送（保留原字段）
      final payload = Map<String, dynamic>.from(p)
        ..['amount'] = amount
        ..['waived'] = waived
        ..['happened_at'] = dateCtrl.text.trim()
        ..['method'] = method
        ..['note'] = noteCtrl.text.trim();
      await LocalDb.upsertOne('payments', payload);
      await SyncService.enqueueChange(entityType: 'payment', entitySyncId: '${p['id']}', payload: payload);
      toast(context, '已保存，正在同步');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _revoke(Map<String, dynamic> p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销收款'),
        content: Text('确定撤销 ${p['client_name']} 的 ¥${p['amount']} 这笔收款吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _c.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (kIsWeb) {
        await Api.instance.delete('/payments/${p['id']}');
      } else {
        // 原生本地优先：本地删行 + 队列推送 delete + 立即推送（删除即时生效，防复活）
        await LocalDb.deleteOne('payments', '${p['id']}');
        await SyncService.enqueueChange(
            entityType: 'payment', entitySyncId: '${p['id']}', action: 'delete', payload: {});
        unawaited(SyncService.pushPending());
      }
      toast(context, '已撤销，正在同步');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  String _date(String? iso) {
    if (iso == null || iso.length < 10) return '';
    return iso.substring(0, 10);
  }

  /// 收款记录所属店铺名：同步 payload 不含 client_name（本地镜像无此字段），用本地店铺镜像反查
  String _clientNameOf(Map<String, dynamic> p) {
    final direct = '${p['client_name'] ?? ''}'.trim();
    if (direct.isNotEmpty) return direct;
    final id = '${p['client_id'] ?? ''}';
    if (id.isEmpty) return '';
    return _clients.where((c) => '${c['id']}' == id).firstOrNull?['name'] as String? ?? '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('收款结账')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DropdownButtonFormField<String>(
                            initialValue: _clientId,
                            decoration: const InputDecoration(labelText: '店铺'),
                            items: _clients
                                .map((c) => DropdownMenuItem(
                                    value: c['id'] as String,
                                    child: Text('${c['name']}（欠 ¥${_debtOf(c).toStringAsFixed(2)}）')))
                                .toList(),
                            onChanged: (v) => setState(() {
                              _clientId = v;
                              final c = _clients.where((x) => x['id'] == v).firstOrNull;
                              _selDebt = c == null ? 0 : _debtOf(c);
                            }),
                          ),
                          if (_clientId != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6, bottom: 4),
                              child: Text('应收 ¥${_selDebt.toStringAsFixed(2)}',
                                  style: TextStyle(color: _c.danger, fontSize: 13)),
                            ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _amountCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: '实收金额（元）', prefixText: '¥ '),
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 8),
                          // 平账：默认自动（减免=应收−实收），可切换手动输入
                          if (_waivedAuto) ...[
                            Row(
                              children: [
                                Expanded(
                                  child: Text('平账减免（自动）：¥${_autoWaived.toStringAsFixed(2)}',
                                      style: TextStyle(fontSize: 14, color: _c.danger, fontWeight: FontWeight.w600)),
                                ),
                                TextButton(
                                  onPressed: () => setState(() => _waivedAuto = false),
                                  child: const Text('改手动'),
                                ),
                              ],
                            ),
                            Text('实收 + 减免 = 账面已收，减免后欠款自动结清',
                                style: TextStyle(fontSize: 12, color: _c.textSub)),
                          ] else ...[
                            TextField(
                              controller: _waivedCtrl,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: const InputDecoration(
                                  labelText: '平账减免（元）',
                                  helperText: '实收 + 减免 = 账面已收；减免后欠款自动结清'),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: () => setState(() => _waivedAuto = true),
                                child: const Text('改自动'),
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          DateField(
                            controller: _dateCtrl,
                            label: '日期',
                            hint: '默认今天，可补录历史',
                          ),
                          const SizedBox(height: 8),
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () async {
                              final picked = await pickAccount(context, current: _method);
                              if (picked != null && mounted) {
                                setState(() => _method = picked);
                              }
                            },
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: '收款方式（账户）',
                                suffixIcon: Icon(Icons.expand_more),
                              ),
                              child: Text(_method.isEmpty ? '点击选择账户' : _method,
                                  style: TextStyle(color: _c.textMain)),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(controller: _noteCtrl, decoration: const InputDecoration(labelText: '备注（可选）')),
                          const SizedBox(height: 12),
                          FilledButton(
                            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                            onPressed: _busy ? null : _submit,
                            child: Text(_busy ? '登记中…' : '登记收款'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('收款历史', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 8),
                  for (final p in _payments.take(50))
                    Card(
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.check_circle_outline, color: _c.success),
                        title: Text(_clientNameOf(p)),
                        subtitle: Text([
                          _date(p['happened_at']),
                          if (((p['waived'] as num?) ?? 0) > 0) '平账 ¥${p['waived']}',
                          if (p['note'] != null && '${p['note']}'.isNotEmpty) '${p['note']}',
                        ].join(' · ')),
                        trailing: Text('¥${p['amount']}',
                            style: TextStyle(fontWeight: FontWeight.w700, color: _c.success)),
                        // 交互与出货统一：点击=编辑、长按=撤销（不再放三个点菜单）
                        onTap: () => _edit(p),
                        onLongPress: () => _revoke(p),
                      ),
                    ),
                  if (_payments.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(child: Text('暂无收款记录', style: TextStyle(color: _c.textSub))),
                    ),
                ],
              ),
            ),
    );
  }
}
