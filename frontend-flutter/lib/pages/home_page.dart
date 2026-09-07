import 'package:flutter/material.dart';
import '../api.dart';
import 'sale_page.dart';
import 'purchase_page.dart';
import 'items_page.dart';

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
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  String _fmt(Object? n) {
    final v = (n is num ? n.toDouble() : double.tryParse(n?.toString() ?? '')) ?? 0;
    return v.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(title: const Text('工作台')),
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
                      _card('今日出货', '¥${_fmt(_today['sales_total'])}', Colors.black),
                      _card('今日毛利', '¥${_fmt(_today['gross_profit'])}', Colors.green.shade600),
                      _card('今日收款', '¥${_fmt(_today['paid_total'])}', Colors.black),
                      _card('今日进货', '¥${_fmt(_today['purchase_total'])}', Colors.red.shade600),
                      _card('总欠款', '¥${_fmt(_totals['debt'])}', Colors.red.shade600),
                      _card('饭店数', '${_totals['client_count'] ?? 0}', Colors.black),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SalePage())),
                        child: const Text('出货记单'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PurchasePage())),
                        child: const Text('进货记单'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ItemsPage())),
                        child: const Text('商品管理'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  const Text('欠款排行（前 5）', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(
                      children: [
                        for (final c in _topDebt)
                          ListTile(
                            dense: true,
                            title: Text('${c['name']}'),
                            trailing: Text('¥${_fmt(c['debt'])}',
                                style: TextStyle(color: Colors.red.shade600, fontWeight: FontWeight.bold)),
                          ),
                        if (_topDebt.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('暂无数据', style: TextStyle(color: Colors.grey)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _card(String label, String value, Color color) {
    return SizedBox(
      width: (MediaQuery.of(context).size.width - 16 * 2 - 12) / 2,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 6),
              Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}