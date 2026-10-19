/// 欠款账期看板：每店截止今天的累计欠款 + 最近出货日（账期天数）+ 笔数。
/// App 本地优先聚合（LocalDb 行级，离线可用）；同步完成/回前台触发刷新。
import 'package:flutter/material.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';

class _DebtRow {
  final String name;
  final double debt;
  final int count;
  final String lastDate;
  final int days;
  _DebtRow({required this.name, required this.debt, required this.count, required this.lastDate, required this.days});
}

class DebtsPage extends StatefulWidget {
  const DebtsPage({super.key});
  @override
  State<DebtsPage> createState() => _DebtsPageState();
}

class _DebtsPageState extends State<DebtsPage> {
  List<_DebtRow> _rows = [];
  double _totalDebt = 0;
  bool _loading = true;

  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;

  @override
  void initState() {
    super.initState();
    SyncService.version.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    SyncService.version.removeListener(_load);
    super.dispose();
  }

  /// 本地聚合（口径与账本未回款一致：出货按各店抹零配置分组向下取整，收款每笔先舍入再累加）
  Future<void> _load() async {
    try {
      final sales = await LocalDb.getAll('sale_items');
      final pays = await LocalDb.getAll('payments');
      final clients = await LocalDb.getAllByName('clients');
      final cfgById = <String, ({String stage, String unit, double? carry})>{
        for (final c in clients)
          '${c['id']}': normalizeRoundConfig(c['round_stage'], c['round_unit'], c['round_carry']),
      };
      final nameById = {for (final c in clients) '${c['id']}': '${c['name'] ?? ''}'};
      final saleByClient = <String, List<Map<String, dynamic>>>{};
      final lastDate = <String, String>{};
      final lastAmt = <String, double>{};
      final cnt = <String, int>{};
      for (final s in sales) {
        final id = '${s['client_id'] ?? ''}';
        if (id.isEmpty) continue;
        saleByClient.putIfAbsent(id, () => []).add(s);
        cnt[id] = (cnt[id] ?? 0) + 1;
        final d = '${s['happened_at'] ?? ''}';
        if (d.length >= 10 && d.substring(0, 10).compareTo(lastDate[id] ?? '') > 0) {
          lastDate[id] = d.substring(0, 10);
          lastAmt[id] = (s['amount'] as num?)?.toDouble() ?? 0;
        }
      }
      final paySum = <String, double>{};
      for (final p in pays) {
        final id = '${p['client_id'] ?? ''}';
        if (id.isEmpty) continue;
        paySum[id] = (paySum[id] ?? 0) +
            Money.round((p['amount'] as num?)?.toDouble() ?? 0) +
            Money.round((p['waived'] as num?)?.toDouble() ?? 0);
      }
      final today = DateTime.now();
      final rows = <_DebtRow>[];
      var total = 0.0;
      for (final e in saleByClient.entries) {
        final cfg = cfgById[e.key] ?? (stage: 'none', unit: 'yuan', carry: null);
        final saleTotal = salesSideRoundedLocal(e.value, cfg.stage, cfg.unit, cfg.carry);
        final debt = saleTotal - (paySum[e.key] ?? 0);
        total += debt;
        final ld = lastDate[e.key] ?? '';
        final parsed = DateTime.tryParse(ld);
        final days = ld.isEmpty || parsed == null ? 0 : today.difference(parsed).inDays.clamp(0, 9999);
        rows.add(_DebtRow(
          name: nameById[e.key] ?? '',
          debt: debt,
          count: cnt[e.key] ?? 0,
          lastDate: ld,
          days: days,
        ));
      }
      rows.removeWhere((r) => r.name.isEmpty);
      rows.sort((a, b) => b.debt.compareTo(a.debt));
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _totalDebt = total;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: appBarBackground(context),
        title: const Text('欠款看板', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: themePageBackground(context)),
          _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    children: [
                      // 汇总卡：总欠款 + 欠款店铺数
                      Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        elevation: 0,
                        color: c.card,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: c.divider),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('累计欠款', style: TextStyle(fontSize: 12, color: c.textSub)),
                                  const SizedBox(height: 4),
                                  Text('¥${_fmt(_totalDebt)}',
                                      style: TextStyle(
                                          fontSize: 20, fontWeight: FontWeight.w700,
                                          color: _totalDebt > 0 ? c.danger : c.success)),
                                ],
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('欠款店铺', style: TextStyle(fontSize: 12, color: c.textSub)),
                                  const SizedBox(height: 4),
                                  Text('${_rows.where((r) => r.debt > 0).length} 家',
                                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                                ],
                              ),
                            ),
                          ]),
                        ),
                      ),
                      if (_rows.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 80),
                          child: Center(
                            child: Text('暂无欠款数据（进货/出货自动累计）',
                                style: TextStyle(fontSize: 13, color: c.textSub)),
                          ),
                        ),
                      for (final r in _rows)
                        Card(
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          elevation: 0,
                          color: r.debt > 0 && r.days >= 30 ? c.danger.withOpacity(0.06) : c.card,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                                color: r.debt > 0 && r.days >= 30 ? c.danger.withOpacity(0.4) : c.divider),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                            child: Row(children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: [
                                      Expanded(
                                        child: Text(r.name,
                                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                                      ),
                                      Text('${r.count} 笔',
                                          style: TextStyle(fontSize: 11, color: c.textSub)),
                                    ]),
                                    const SizedBox(height: 4),
                                    Text(
                                      r.lastDate.isEmpty
                                          ? '暂无出货记录'
                                          : '最近出货 ${r.lastDate}${r.days >= 30 ? ' · 已拖 ${r.days} 天' : ''}',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: r.days >= 30 ? c.danger : c.textSub),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '¥${_fmt(r.debt)}',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: r.debt > 0 ? c.danger : c.success,
                                ),
                              ),
                            ]),
                          ),
                        ),
                    ],
                  ),
                ),
        ],
      ),
    );
  }

  String _fmt(double v) => (v * 100).round() / 100 == v.round()
      ? '${v.round()}'
      : (v * 100).round() / 100 == (v * 10).round() / 10
          ? '${(v * 10).round() / 10}'
          : '${(v * 100).round() / 100}';
}
