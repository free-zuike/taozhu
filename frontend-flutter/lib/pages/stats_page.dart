import 'package:flutter/material.dart';
import '../api.dart';
import 'router.dart';

/// 统计：店铺筛选 + 快捷时间（今日/本月/上月/滚动月/自定义区间） + 日/月/年视图
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});
  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  // 店铺筛选
  List<Map<String, dynamic>> _clients = [];
  String? _clientId;

  // 视图模式：range 区间 / month 月 / year 年
  String _mode = 'range';
  // 快捷区间标识
  String _quick = 'month';
  DateTime? _customStart;
  DateTime? _customEnd;

  // 月/年选择
  List<String> _years = [];
  String? _year;
  int _month = DateTime.now().month;

  // 数据
  Map<String, dynamic> _summary = {};
  List<dynamic> _days = [];
  List<dynamic> _months = [];
  List<dynamic> _clientsStats = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final now = DateTime.now();
    _year = '$now.year';
    // 店铺 + 年份并行（缓存优先）
    final cachedClients = await Api.instance.getCached('/clients');
    if (cachedClients != null) {
      _clients = ((cachedClients['clients'] as List?) ?? []).cast<Map<String, dynamic>>();
    }
    try {
      final results = await Future.wait([
        Api.instance.get('/clients'),
        Api.instance.get('/stats/years'),
      ]);
      await Api.instance.setCache('/clients', results[0]);
      if (!mounted) return;
      _clients = ((results[0]['clients'] as List?) ?? []).cast<Map<String, dynamic>>();
      _years = ((results[1]['years'] as List?) ?? []).map((e) => '$e').toList();
      if (_years.isNotEmpty && !_years.contains(_year)) _year = _years.last;
    } catch (e) {
      if (cachedClients == null) toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
    await _load();
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  DateTime _monthEnd(int y, int m) => DateTime(y, m + 1, 0);

  /// 当前快捷区间的起止（本地时区）
  (String, String) get _range {
    final now = DateTime.now();
    switch (_quick) {
      case 'today':
        final d = _fmtDate(now);
        return (d, d);
      case 'last':
        final first = DateTime(now.year, now.month - 1, 1);
        final last = DateTime(now.year, now.month, 0);
        return (_fmtDate(first), _fmtDate(last));
      case 'rolling':
        final end = DateTime(now.year, now.month + 1, now.day);
        return (_fmtDate(now), _fmtDate(end));
      case 'custom':
        if (_customStart != null && _customEnd != null) {
          return (_fmtDate(_customStart!), _fmtDate(_customEnd!));
        }
        return (_fmtDate(DateTime(now.year, now.month, 1)), _fmtDate(now));
      default: // month
        return (_fmtDate(DateTime(now.year, now.month, 1)), _fmtDate(now));
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      if (_mode == 'year') {
        final m = await Api.instance.get('/stats/monthly?year=$_year');
        setState(() {
          _months = ((m['months'] as List?) ?? []);
          _loading = false;
        });
        return;
      }
      final (start, end) = _mode == 'month'
          ? (_fmtDate(DateTime(int.parse(_year!), _month, 1)), _fmtDate(_monthEnd(int.parse(_year!), _month)))
          : _range;
      final cq = _clientId != null ? '&client_id=$_clientId' : '';
      final results = await Future.wait([
        Api.instance.get('/stats/summary?start=$start&end=$end$cq'),
        Api.instance.get('/stats/daily?start=$start&end=$end$cq'),
        if (_clientId == null) Api.instance.get('/stats/clients?start=$start&end=$end'),
      ]);
      setState(() {
        _summary = results[0];
        _days = (results[1]['days'] as List?) ?? [];
        _clientsStats = results.length > 2 ? ((results[2]['clients'] as List?) ?? []) : [];
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
    final (start, end) = _mode == 'month'
        ? (_fmtDate(DateTime(int.parse(_year!), _month, 1)), _fmtDate(_monthEnd(int.parse(_year!), _month)))
        : _range;
    return Scaffold(
      appBar: AppBar(title: const Text('统计报表')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // 店铺筛选
                  DropdownButtonFormField<String?>(
                    initialValue: _clientId,
                    decoration: const InputDecoration(labelText: '店铺'),
                    hint: const Text('全部店铺'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('全部店铺')),
                      for (final c in _clients)
                        DropdownMenuItem<String?>(value: '${c['id']}', child: Text('${c['name']}')),
                    ],
                    onChanged: (v) {
                      setState(() => _clientId = v);
                      _load();
                    },
                  ),
                  const SizedBox(height: 12),
                  // 视图模式
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'range', label: Text('区间')),
                      ButtonSegment(value: 'month', label: Text('月')),
                      ButtonSegment(value: 'year', label: Text('年')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) {
                      setState(() => _mode = s.first);
                      _load();
                    },
                  ),
                  const SizedBox(height: 12),
                  if (_mode == 'range') _quickBar(),
                  if (_mode == 'month') _monthBar(),
                  if (_mode == 'year') _yearBar(),
                  const SizedBox(height: 8),
                  Text('$start ~ $end', style: const TextStyle(color: Color(0xFF909399), fontSize: 13)),
                  const SizedBox(height: 12),
                  _summaryCards(),
                  const SizedBox(height: 16),
                  Text(_mode == 'year' ? '月度出货（元）' : '每日出货（元）',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 8),
                  _barChart(),
                  if (_clientId == null && _mode != 'year') ...[
                    const SizedBox(height: 20),
                    const Text('按店结账（元）', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    const SizedBox(height: 8),
                    for (final c in _clientsStats)
                      Card(
                        child: ListTile(
                          dense: true,
                          title: Text('${c['name']}'),
                          subtitle: Text(
                              '出货 ¥${_num(c['sales_total']).toStringAsFixed(0)} · 已收 ¥${_num(c['paid_total']).toStringAsFixed(0)}'),
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
                    if (_clientsStats.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('该区间暂无数据', style: TextStyle(color: Colors.grey))),
                      ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _quickBar() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _chip('今日', 'today'),
        _chip('本月', 'month'),
        _chip('上月', 'last'),
        _chip('滚动月(今~下月今)', 'rolling'),
        ActionChip(
          avatar: const Icon(Icons.date_range, size: 18),
          label: const Text('自定义'),
          onPressed: () async {
            final now = DateTime.now();
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(now.year - 3),
              lastDate: DateTime(now.year + 1, 12, 31),
              initialDateRange: DateTimeRange(
                start: _customStart ?? DateTime(now.year, now.month, 1),
                end: _customEnd ?? now,
              ),
            );
            if (picked != null) {
              setState(() {
                _quick = 'custom';
                _customStart = picked.start;
                _customEnd = picked.end;
              });
              _load();
            }
          },
        ),
      ],
    );
  }

  Widget _chip(String label, String value) {
    return ChoiceChip(
      label: Text(label),
      selected: _quick == value,
      onSelected: (_) {
        setState(() => _quick = value);
        _load();
      },
    );
  }

  Widget _monthBar() {
    return Row(
      children: [
        const Text('年：', style: TextStyle(fontWeight: FontWeight.w600)),
        DropdownButton<String>(
          value: _year,
          items: _years.map((y) => DropdownMenuItem(value: y, child: Text('$y'))).toList(),
          onChanged: (v) {
            setState(() => _year = v);
            _load();
          },
        ),
        const SizedBox(width: 16),
        const Text('月：', style: TextStyle(fontWeight: FontWeight.w600)),
        DropdownButton<int>(
          value: _month,
          items: [for (int i = 1; i <= 12; i++) DropdownMenuItem(value: i, child: Text('$i月'))],
          onChanged: (v) {
            setState(() => _month = v!);
            _load();
          },
        ),
      ],
    );
  }

  Widget _yearBar() {
    return Row(
      children: [
        const Text('年份：', style: TextStyle(fontWeight: FontWeight.w600)),
        DropdownButton<String>(
          value: _year,
          items: _years.map((y) => DropdownMenuItem(value: y, child: Text('$y 年'))).toList(),
          onChanged: (v) {
            setState(() => _year = v);
            _load();
          },
        ),
      ],
    );
  }

  Widget _summaryCards() {
    final data = _mode == 'year'
        ? {
            '出货': _months.fold<double>(0, (s, x) => s + _num(x['sales_total'])),
            '毛利': _months.fold<double>(0, (s, x) => s + _num(x['gross_profit'])),
            '收款': _months.fold<double>(0, (s, x) => s + _num(x['paid_total'])),
          }
        : {
            '出货': _num(_summary['sales_total']),
            '毛利': _num(_summary['gross_profit']),
            '收款': _num(_summary['paid_total']),
            '进货': _num(_summary['purchase_total']),
            '欠款': _num(_summary['debt']),
          };
    final w = MediaQuery.of(context).size.width;
    final itemW = (w.clamp(200.0, 900.0) - 16 * 2 - 12) / 2;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final e in data.entries)
          SizedBox(
            width: itemW,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.key, style: const TextStyle(color: Color(0xFF909399), fontSize: 13)),
                    const SizedBox(height: 6),
                    Text('¥${e.value.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: e.key == '欠款' && e.value > 0 ? const Color(0xFFF56C6C) : Colors.black,
                        )),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _barChart() {
    final items = _mode == 'year' ? _months : _days;
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('该区间暂无数据', style: TextStyle(color: Colors.grey))),
      );
    }
    final key = _mode == 'year' ? 'sales_total' : 'sales_total';
    final label = _mode == 'year' ? 'month' : 'day';
    final maxV = items.fold<double>(0, (m, x) => _num(x[key]) > m ? _num(x[key]) : m);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          height: 150,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final x in items)
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(_shortLabel('${x[label]}'),
                          style: const TextStyle(fontSize: 9, color: Color(0xFF909399))),
                      const SizedBox(height: 4),
                      Container(
                        height: maxV > 0 ? 110 * _num(x[key]) / maxV : 2,
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

  String _shortLabel(String s) {
    // '2026-09-07' → '9-7'；'2026-09' → '9月'
    if (s.length >= 10) {
      final m = int.tryParse(s.substring(5, 7)) ?? 0;
      final d = int.tryParse(s.substring(8, 10)) ?? 0;
      return '$m/$d';
    }
    if (s.length >= 7) {
      final m = int.tryParse(s.substring(5, 7)) ?? 0;
      return '$m月';
    }
    return s;
  }
}
