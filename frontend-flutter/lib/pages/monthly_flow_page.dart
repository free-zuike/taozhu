import 'package:flutter/material.dart';
import '../api.dart';
import '../log.dart';
import '../theme.dart';
import '../utils/money.dart';

/// 月度结余（beecount 式流式卡片）：一页展示某年全部月份，逐月向下排列，
/// 无月份下拉选择（"不是选择，流式的"）。每月卡片：支出=进货 · 收入=出货 · 结余=出货−进货。
class MonthlyFlowPage extends StatefulWidget {
  const MonthlyFlowPage({super.key});
  @override
  State<MonthlyFlowPage> createState() => _MonthlyFlowPageState();
}

class _MonthlyFlowPageState extends State<MonthlyFlowPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  List<int> _years = [];
  int? _year;
  List<Map<String, dynamic>> _months = [];
  bool _loading = true;
  bool _loadedOnce = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final now = DateTime.now();
    _year = now.year;
    final cachedYears = await Api.instance.getCachedRaw('/stats/years');
    if (cachedYears != null) {
      _years = ((cachedYears['years'] as List?) ?? []).map((e) => int.tryParse('$e') ?? 0).toList();
    }
    await _load();
    try {
      final d = await Api.instance.get('/stats/years');
      await Api.instance.setCache('/stats/years', d);
      if (mounted) {
        setState(() {
          _years = ((d['years'] as List?) ?? []).map((e) => int.tryParse('$e') ?? 0).toList();
          if (_years.isNotEmpty && _year != null && !_years.contains(_year)) {
            _year = _years.last;
          }
        });
      }
      await _load();
    } catch (e) {
      appLog('net', '月度结余年份刷新失败: ${e.toString().split('\n').first}', level: 'error');
    }
  }

  Future<void> _load({bool network = false}) async {
    final y = _year;
    if (y == null) return;
    // 本地优先：有缓存先渲染（秒开）；网络刷新仅下拉时执行
    final cached = await Api.instance.getCachedRaw('/stats/monthly-flow?year=$y');
    if (cached != null && mounted) {
      _apply(cached);
      _loadedOnce = true;
    } else if (!_loadedOnce && mounted) {
      setState(() => _loading = true);
    }
    // 仅首次无缓存时网络加载；有缓存时依赖下拉刷新
    if (cached == null && !_loadedOnce) {
      await _fetchNetwork(y);
    }
  }

  Future<void> _refresh() => _fetchNetwork(_year!);

  Future<void> _fetchNetwork(int y) async {
    try {
      final d = await Api.instance.get('/stats/monthly-flow?year=$y');
      await Api.instance.setCache('/stats/monthly-flow?year=$y', d);
      if (!mounted) return;
      _apply(d);
      _loadedOnce = true;
    } catch (e) {
      appLog('net', '月度结余加载失败: ${e.toString().split('\n').first}', level: 'error');
      if (!mounted) return;
      // 无缓存且失败 → 显示空态说明
      if (!_loadedOnce) {
        setState(() {
          _months = [];
          _loading = false;
        });
      }
    }
  }

  void _apply(Map<String, dynamic> d) {
    // 新月份在前（流式向下=时间倒序）
    final list = ((d['months'] as List?) ?? []).cast<Map<String, dynamic>>().toList()
      ..sort((a, b) => '${b['month']}'.compareTo('${a['month']}'));
    setState(() {
      _months = list;
      _loading = false;
    });
  }

  String _monthLabel(String m) {
    // 如 2026-09 → 2026年9月
    final parts = m.split('-');
    if (parts.length == 2 && parts[0].length == 4) {
      return '${parts[0]}年${int.tryParse(parts[1])?.toString() ?? parts[1]}月';
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      appBar: AppBar(title: const Text('月度结余')),
      body: Column(
        children: [
          // 年份胶囊（仅仅是年份切换，月份全列出，非月份选择）
          if (_years.isNotEmpty)
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                children: [
                  for (final y in _years.reversed)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text('$y 年', style: const TextStyle(fontSize: 13)),
                        visualDensity: VisualDensity.compact,
                        selected: _year == y,
                        onSelected: (_) {
                          setState(() {
                            _year = y;
                            _loading = true;
                          });
                          _load();
                        },
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        for (final (i, m) in _months.indexed) ...[
                          if (i > 0) const SizedBox(height: 10),
                          _monthCard(m),
                        ],
                        if (_months.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(48),
                            child: Column(
                              children: [
                                const Icon(Icons.trending_up, size: 40, color: Color(0xFFD0D5DD)),
                                const SizedBox(height: 12),
                                Text('该年暂无交易记录', style: TextStyle(color: c.textSub)),
                              ],
                            ),
                          ),
                        const SizedBox(height: 8),
                        Center(
                          child: Text('支出=进货 · 收入=出货 · 结余=出货−进货（全店汇总）',
                              style: TextStyle(fontSize: 11, color: c.textSub)),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _monthCard(Map<String, dynamic> m) {
    final c = _c;
    final sales = (m['sales_total'] as num?)?.toDouble() ?? 0;
    final buys = (m['purchase_total'] as num?)?.toDouble() ?? 0;
    final balance = (m['balance'] as num?)?.toDouble() ?? (sales - buys);
    final balColor = balance >= 0 ? c.success : c.danger;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 16,
                decoration: BoxDecoration(color: balColor, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 8),
              Text(_monthLabel('${m['month']}'),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const Spacer(),
              Text('结余 ¥${fmtMoney(balance)}',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800, color: balColor)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _statCell('支出（进货）', '¥${fmtMoney(buys)}', c.danger),
              ),
              Expanded(
                child: _statCell('收入（出货）', '¥${fmtMoney(sales)}', c.primary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statCell(String label, String value, Color color) {
    final c = _c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: c.textSub)),
          const SizedBox(height: 3),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}