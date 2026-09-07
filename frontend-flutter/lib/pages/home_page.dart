import 'package:flutter/material.dart';
import '../api.dart';
import '../widgets/admin_scaffold.dart';
import 'router.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Map<String, dynamic> _today = {};
  Map<String, dynamic> _totals = {};
  List<dynamic> _topDebt = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await Api.instance.get('/stats/overview');
      setState(() {
        _today = (d['today'] as Map?)?.cast<String, dynamic>() ?? {};
        _totals = (d['totals'] as Map?)?.cast<String, dynamic>() ?? {};
        _topDebt = (d['top_debt_clients'] as List?) ?? [];
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  String _fmt(Object? n) {
    final v = (n is num ? n.toDouble() : double.tryParse(n?.toString() ?? '')) ?? 0;
    return v.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    return AdminScaffold(
      selectedIndex: 0,
      title: '工作台',
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _card('今日出货', '¥${_fmt(_today['sales_total'])}'),
                      _card('今日毛利', '¥${_fmt(_today['gross_profit'])}', green: true),
                      _card('今日收款', '¥${_fmt(_today['paid_total'])}'),
                      _card('今日进货', '¥${_fmt(_today['purchase_total'])}', red: true),
                      _card('总欠款', '¥${_fmt(_totals['debt'])}', red: true),
                      _card('饭店数', '${_totals['client_count'] ?? 0}'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                          onPressed: () => goPage(context, 1),
                          child: const Text('出货记单'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                          onPressed: () => goPage(context, 2),
                          child: const Text('进货记单'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                          onPressed: () => goPage(context, 3),
                          child: const Text('商品管理'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('欠款排行（前 5）',
                              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                          const SizedBox(height: 4),
                          for (final c in _topDebt)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text('${c['name']}'),
                              trailing: Text('¥${_fmt(c['debt'])}',
                                  style: const TextStyle(
                                      color: Color(0xFFF56C6C), fontWeight: FontWeight.w600)),
                            ),
                          if (_topDebt.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('暂无数据', style: TextStyle(color: Colors.grey)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
      onSelect: (i) => goPage(context, i),
    );
  }

  Widget _card(String label, String value, {bool green = false, bool red = false}) {
    final color = green ? const Color(0xFF67C23A) : (red ? const Color(0xFFF56C6C) : Colors.black);
    final w = MediaQuery.of(context).size.width;
    final itemW = (w.clamp(200.0, 900.0) - 16 * 2 - 12) / 2;
    return SizedBox(
      width: itemW,
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: Color(0xFF909399), fontSize: 13)),
              const SizedBox(height: 6),
              Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}