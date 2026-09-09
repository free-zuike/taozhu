import 'package:flutter/material.dart';
import '../api.dart';
import 'router.dart';
import 'stats_page.dart';

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
  bool _canSeeProfit = true; // 店员看不到毛利（后端 can_see_profit=false 时隐藏）

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
        _canSeeProfit = d['can_see_profit'] != false;
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
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Text('工作台', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => goPage(context, const StatsPage()),
                  icon: const Icon(Icons.bar_chart, size: 18),
                  label: const Text('统计'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
            else ...[
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _card('今日出货', '¥${_fmt(_today['sales_total'])}'),
                  if (_canSeeProfit) _card('今日毛利', '¥${_fmt(_today['gross_profit'])}', green: true),
                  _card('今日收款', '¥${_fmt(_today['paid_total'])}'),
                  _card('今日进货', '¥${_fmt(_today['purchase_total'])}', red: true),
                  _card('总欠款', '¥${_fmt(_totals['debt'])}', red: true),
                  _card('店铺数', '${_totals['client_count'] ?? 0}'),
                ],
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('欠款排行（前 5）', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                      const SizedBox(height: 4),
                      for (final c in _topDebt)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text('${c['name']}'),
                          trailing: Text('¥${_fmt(c['debt'])}',
                              style: const TextStyle(color: Color(0xFFF56C6C), fontWeight: FontWeight.w600)),
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
          ],
        ),
      ),
    );
  }

  Widget _card(String label, String value, {bool green = false, bool red = false}) {
    final color = green
        ? const Color(0xFF67C23A)
        : (red
            ? const Color(0xFFF56C6C)
            : (Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black));
    final w = MediaQuery.of(context).size.width;
    final itemW = (w.clamp(200.0, 900.0) - 16 * 2 - 12) / 2;
    return SizedBox(
      width: itemW,
      child: Card(
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
