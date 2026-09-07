import 'dart:math';
import 'package:flutter/material.dart';
import '../api.dart';
import '../utils/money.dart';
import 'router.dart';

/// 统计（仿 移动记账 洞察）：店铺胶囊选择 + 周期胶囊（今日/本月/上月/滚动月/自定义） + 日/月/年视图
/// 总览卡（含日均） + 折线图 + 商品排行 + 按店结账
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});
  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  List<Map<String, dynamic>> _clients = [];
  String? _clientId;
  String _clientName = '全部店铺';

  String _mode = 'range';
  String _quick = 'month';
  DateTime? _customStart;
  DateTime? _customEnd;

  List<String> _years = [];
  String? _year;
  int _month = DateTime.now().month;

  Map<String, dynamic> _summary = {};
  List<dynamic> _days = [];
  List<dynamic> _months = [];
  List<dynamic> _clientsStats = [];
  List<dynamic> _itemsStats = [];
  bool _loading = true;

  static const _primary = Color(0xFF409EFF);

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final now = DateTime.now();
    _year = '$now.year';
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

  (String, String) get _range {
    final now = DateTime.now();
    switch (_quick) {
      case 'today':
        final d = _fmtDate(now);
        return (d, d);
      case 'last':
        return (_fmtDate(DateTime(now.year, now.month - 1, 1)), _fmtDate(DateTime(now.year, now.month, 0)));
      case 'rolling':
        return (_fmtDate(now), _fmtDate(DateTime(now.year, now.month + 1, now.day)));
      case 'custom':
        if (_customStart != null && _customEnd != null) {
          return (_fmtDate(_customStart!), _fmtDate(_customEnd!));
        }
        return (_fmtDate(DateTime(now.year, now.month, 1)), _fmtDate(now));
      default:
        return (_fmtDate(DateTime(now.year, now.month, 1)), _fmtDate(now));
    }
  }

  (String, String) get _viewRange {
    if (_mode == 'month') {
      return (_fmtDate(DateTime(int.parse(_year!), _month, 1)), _fmtDate(_monthEnd(int.parse(_year!), _month)));
    }
    return _range;
  }

  /// 区间天数（含首尾）
  int get _spanDays {
    final (s, e) = _viewRange;
    final a = DateTime.tryParse(s);
    final b = DateTime.tryParse(e);
    if (a == null || b == null) return 1;
    return max(1, b.difference(a).inDays + 1);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final (start, end) = _viewRange;
      if (_mode == 'year') {
        final results = await Future.wait([
          Api.instance.get('/stats/monthly?year=$_year'),
        ]);
        setState(() {
          _months = (results[0]['months'] as List?) ?? [];
          _days = [];
          _itemsStats = [];
          _loading = false;
        });
        return;
      }
      final cq = _clientId != null ? '&client_id=$_clientId' : '';
      final results = await Future.wait([
        Api.instance.get('/stats/summary?start=$start&end=$end$cq'),
        Api.instance.get('/stats/daily?start=$start&end=$end$cq'),
        Api.instance.get('/stats/items?start=$start&end=$end$cq'),
        if (_clientId == null) Api.instance.get('/stats/clients?start=$start&end=$end'),
      ]);
      setState(() {
        _summary = results[0];
        _days = (results[1]['days'] as List?) ?? [];
        _itemsStats = ((results[2]['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        _clientsStats = results.length > 3 ? ((results[3]['clients'] as List?) ?? []) : [];
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  double _num(Object? v) => (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);

  Future<void> _pickShop() async {
    final picked = await showDialog<String?>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360, maxHeight: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('选择店铺', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    _shopItem(ctx, null, '全部店铺'),
                    for (final c in _clients) _shopItem(ctx, '${c['id']}', '${c['name']}'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != _clientId) {
      setState(() {
        _clientId = picked;
        _clientName = picked == null
            ? '全部店铺'
            : (_clients.where((c) => '${c['id']}' == picked).map((c) => '${c['name']}').firstOrNull ?? '全部店铺');
      });
      _load();
    }
  }

  Widget _shopItem(BuildContext ctx, String? id, String name) {
    final active = _clientId == id;
    return ListTile(
      dense: true,
      leading: Icon(active ? Icons.check_circle : Icons.store_outlined,
          color: active ? _primary : const Color(0xFF909399)),
      title: Text(name,
          style: TextStyle(
            color: active ? _primary : Colors.black,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          )),
      onTap: () => Navigator.pop(ctx, id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final (start, end) = _viewRange;
    return Scaffold(
      appBar: AppBar(title: const Text('统计报表')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // 店铺胶囊（仿 移动记账 账本选择）
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: _pickShop,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 2)),
                              ],
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.store_outlined, size: 18, color: Color(0xFF409EFF)),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(_clientName,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                                ),
                                const Icon(Icons.expand_more, size: 18, color: Color(0xFF909399)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SegmentedButton<String>(
                        style: const ButtonStyle(visualDensity: VisualDensity.compact),
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
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_mode == 'range') _quickBar(),
                  if (_mode == 'month') _monthBar(),
                  if (_mode == 'year') _yearBar(),
                  const SizedBox(height: 6),
                  Text('$start ~ $end（$ _spanDays 天）',
                      style: const TextStyle(color: Color(0xFF909399), fontSize: 12)),
                  const SizedBox(height: 12),
                  _summaryCards(),
                  const SizedBox(height: 16),
                  Text(_mode == 'year' ? '月度出货趋势（元）' : '每日出货趋势（元）',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 8),
                  _lineChart(),
                  const SizedBox(height: 20),
                  Text('商品排行（出货额）', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 8),
                  for (final (i, it) in _itemsStats.indexed)
                    Card(
                      child: ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 14,
                          backgroundColor: const Color(0xFF409EFF).withOpacity(0.12),
                          child: Text('${i + 1}',
                              style: const TextStyle(fontSize: 12, color: Color(0xFF409EFF), fontWeight: FontWeight.w700)),
                        ),
                        title: Text('${it['name']}'),
                        subtitle: Text('${it['quantity']} ${it['unit']}'),
                        trailing: Text('¥${fmtMoney(_num(it['amount']))}',
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  if (_itemsStats.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(child: Text('该区间暂无出货', style: TextStyle(color: Colors.grey))),
                    ),
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
                              '出货 ¥${fmtMoney(_num(c['sales_total']))} · 已收 ¥${fmtMoney(_num(c['paid_total']))}'),
                          trailing: Text(
                            '欠 ¥${fmtMoney(_num(c['sales_total']) - _num(c['paid_total']))}',
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
                        padding: EdgeInsets.all(20),
                        child: Center(child: Text('该区间暂无数据', style: TextStyle(color: Colors.grey))),
                      ),
                  ],
                ],
              ),
            ),
    );
  }

  // ── 周期胶囊（仿 移动记账 CapsuleSwitcher） ──
  Widget _quickBar() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _pill('今日', 'today'),
        _pill('本月', 'month'),
        _pill('上月', 'last'),
        _pill('滚动月', 'rolling'),
        _pill('自定义', 'custom', icon: Icons.date_range),
      ],
    );
  }

  Widget _pill(String label, String value, {IconData? icon}) {
    final active = _quick == value;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          if (value == 'custom') {
            _pickRange();
            return;
          }
          setState(() => _quick = value);
          _load();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: active ? _primary : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: active ? null : Border.all(color: const Color(0xFFDCDFE6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: active ? Colors.white : const Color(0xFF909399)),
                const SizedBox(width: 4),
              ],
              Text(label,
                  style: TextStyle(
                    color: active ? Colors.white : const Color(0xFF606266),
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    fontSize: 13,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickRange() async {
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
    final sales = _mode == 'year'
        ? _months.fold<double>(0, (s, x) => s + _num(x['sales_total']))
        : _num(_summary['sales_total']);
    final gross = _mode == 'year'
        ? _months.fold<double>(0, (s, x) => s + _num(x['gross_profit']))
        : _num(_summary['gross_profit']);
    final paid = _mode == 'year'
        ? _months.fold<double>(0, (s, x) => s + _num(x['paid_total']))
        : _num(_summary['paid_total']);
    final data = <String, double>{
      '出货': sales,
      '毛利': gross,
      '收款': paid,
      if (_mode != 'year') '进货': _num(_summary['purchase_total']),
      if (_mode != 'year') '欠款': _num(_summary['debt']),
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
                    Text('¥${fmtMoney(e.value)}',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: e.key == '欠款' && e.value > 0 ? const Color(0xFFF56C6C) : Colors.black,
                        )),
                    if (e.key == '出货')
                      Text('日均 ¥${fmtMoney(sales / _spanDays)}',
                          style: const TextStyle(color: Color(0xFF909399), fontSize: 12)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── 折线图（仿 移动记账 自绘 LineChart） ──
  Widget _lineChart() {
    final items = _mode == 'year' ? _months : _days;
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('该区间暂无数据', style: TextStyle(color: Colors.grey))),
      );
    }
    final values = items.map<double>((x) => _num(x['sales_total'])).toList();
    final labels = items.map((x) => '${x[_mode == 'year' ? 'month' : 'day']}').toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text('出货 ¥${fmtMoney(values.fold<double>(0, (a, b) => a + b))}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              width: double.infinity,
              child: CustomPaint(painter: _LineChartPainter(values, _primary)),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_shortLabel(labels.first), style: const TextStyle(fontSize: 10, color: Color(0xFF909399))),
                if (labels.length > 2)
                  Text(_shortLabel(labels[labels.length ~/ 2]),
                      style: const TextStyle(fontSize: 10, color: Color(0xFF909399))),
                Text(_shortLabel(labels.last), style: const TextStyle(fontSize: 10, color: Color(0xFF909399))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _shortLabel(String s) {
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

class _LineChartPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  _LineChartPainter(this.values, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final range = maxV <= 0 ? 1.0 : maxV;
    final n = values.length;
    final dx = n <= 1 ? size.width : size.width / (n - 1);
    double yAt(int i) => size.height - 4 - (values[i] / range) * (size.height - 10);

    final path = Path();
    for (int i = 0; i < n; i++) {
      final x = i * dx;
      final y = yAt(i);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    // 面积填充
    final fill = Path.from(path)
      ..lineTo((n - 1) * dx, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withOpacity(0.12)..style = PaintingStyle.fill);
    canvas.drawPath(path,
        Paint()..color = color..strokeWidth = 2.5..style = PaintingStyle.stroke..strokeJoin = StrokeJoin.round);
    // 数据点
    for (int i = 0; i < n; i++) {
      final c = Offset(i * dx, yAt(i));
      canvas.drawCircle(c, 3.2, Paint()..color = Colors.white);
      canvas.drawCircle(c, 3.2, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.6);
    }
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) =>
      oldDelegate.values.length != values.length ||
      (values.isNotEmpty && oldDelegate.values.first != values.first) ||
      (values.isNotEmpty && oldDelegate.values.last != values.last);
}
