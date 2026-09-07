import 'package:flutter/material.dart';
import '../api.dart';
import 'router.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});
  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  List<String> _years = [];
  String? _year;
  List<dynamic> _months = [];
  List<dynamic> _clients = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadYears();
  }

  Future<void> _loadYears() async {
    try {
      final d = await Api.instance.get('/stats/years');
      final years = ((d['years'] as List?) ?? []).map((e) => '$e').toList();
      setState(() {
        _years = years;
        _year = years.isNotEmpty ? years.last : null;
      });
      if (_year != null) {
        await _loadData();
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      setState(() => _loading = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _loadData() async {
    try {
      final m = await Api.instance.get('/stats/monthly?year=$_year');
      final c = await Api.instance.get('/stats/clients');
      setState(() {
        _months = ((m['months'] as List?) ?? []);
        _clients = ((c['clients'] as List?) ?? []);
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  double _num(Object? v) => (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('统计报表')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                if (_year != null) await _loadData();
              },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Row(
                    children: [
                      const Text('年份：', style: TextStyle(fontWeight: FontWeight.w600)),
                      DropdownButton<String>(
                        value: _year,
                        items: _years.map((y) => DropdownMenuItem(value: y, child: Text('$y 年'))).toList(),
                        onChanged: (v) {
                          setState(() {
                            _year = v;
                            _loading = true;
                          });
                          _loadData();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('月度出货（元）', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 8),
                  _monthlyBarChart(),
                  const SizedBox(height: 20),
                  const Text('按店结账（元）', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 8),
                  for (final c in _clients)
                    Card(
                      child: ListTile(
                        dense: true,
                        title: Text('${c['name']}'),
                        subtitle: Text('出货 ¥${_num(c['sales_total']).toStringAsFixed(0)} · 已收 ¥${_num(c['paid_total']).toStringAsFixed(0)}'),
                        trailing: Text(
                          '欠 ¥${(_num(c['sales_total']) - _num(c['paid_total'])).toStringAsFixed(2)}',
                          style: TextStyle(
                            color: _num(c['sales_total']) > _num(c['paid_total'])
                                ? const Color(0xFFF56C6C)
                                : const Color(0xFF67C23A),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  if (_clients.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('暂无数据', style: TextStyle(color: Colors.grey))),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _monthlyBarChart() {
    if (_months.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('该年暂无数据', style: TextStyle(color: Colors.grey))),
      );
    }
    final maxV = _months.fold<double>(0, (m, x) => _num(x['sales_total']) > m ? _num(x['sales_total']) : m);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final m in _months)
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text('${m['month']}',
                          style: const TextStyle(fontSize: 10, color: Color(0xFF909399))),
                      const SizedBox(height: 4),
                      Container(
                        height: maxV > 0 ? 100 * _num(m['sales_total']) / maxV : 2,
                        decoration: BoxDecoration(
                          color: const Color(0xFF409EFF).withOpacity(0.85),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
