import 'package:flutter/material.dart';
import '../api.dart';
import 'router.dart';

class PaymentsPage extends StatefulWidget {
  const PaymentsPage({super.key});
  @override
  State<PaymentsPage> createState() => _PaymentsPageState();
}

class _PaymentsPageState extends State<PaymentsPage> {
  List<Map<String, dynamic>> _clients = [];
  List<Map<String, dynamic>> _payments = [];
  String? _clientId;
  final _amountCtrl = TextEditingController();
  bool _busy = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // ① 店铺下拉走本地缓存秒开；历史列表始终网络刷新
    final cached = await Api.instance.getCached('/clients');
    if (cached != null) {
      setState(() => _clients = ((cached['clients'] as List?) ?? []).cast<Map<String, dynamic>>());
    }
    // ② 网络刷新
    try {
      final results = await Future.wait([
        Api.instance.get('/clients'),
        Api.instance.get('/payments'),
      ]);
      await Api.instance.setCache('/clients', results[0]);
      if (!mounted) return;
      setState(() {
        _clients = ((results[0]['clients'] as List?) ?? []).cast<Map<String, dynamic>>();
        _payments = ((results[1]['payments'] as List?) ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _submit() async {
    final amount = double.tryParse(_amountCtrl.text) ?? 0;
    if (_clientId == null) {
      toast(context, '请选择店铺');
      return;
    }
    if (amount <= 0) {
      toast(context, '请输入有效金额');
      return;
    }
    setState(() => _busy = true);
    try {
      await Api.instance.post('/payments', {'client_id': _clientId, 'amount': amount});
      toast(context, '已登记收款 ¥${amount.toStringAsFixed(2)}');
      _amountCtrl.clear();
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
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
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFF56C6C)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.instance.delete('/payments/${p['id']}');
      toast(context, '已撤销');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  String _date(String? iso) {
    if (iso == null || iso.length < 10) return '';
    return iso.substring(0, 10);
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
                                    value: c['id'] as String, child: Text('${c['name']}')))
                                .toList(),
                            onChanged: (v) => setState(() => _clientId = v),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _amountCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: '收款金额（元）', prefixText: '¥ '),
                          ),
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
                        leading: const Icon(Icons.check_circle_outline, color: Color(0xFF67C23A)),
                        title: Text('${p['client_name']}'),
                        subtitle: Text('${_date(p['happened_at'])}${p['note'] != null && '${p['note']}'.isNotEmpty ? ' · ${p['note']}' : ''}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('¥${p['amount']}',
                                style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF67C23A))),
                            IconButton(
                              icon: const Icon(Icons.undo, size: 18, color: Color(0xFF909399)),
                              onPressed: () => _revoke(p),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_payments.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('暂无收款记录', style: TextStyle(color: Colors.grey))),
                    ),
                ],
              ),
            ),
    );
  }
}
