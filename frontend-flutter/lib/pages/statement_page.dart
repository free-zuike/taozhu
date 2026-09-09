import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api.dart';
import 'router.dart';

/// 对账单：按店铺 + 周期汇总出货/收款/期末欠款，一键复制文本发送给客户
class StatementPage extends StatefulWidget {
  const StatementPage({super.key});
  @override
  State<StatementPage> createState() => _StatementPageState();
}

class _StatementPageState extends State<StatementPage> {
  List<Map<String, dynamic>> _clients = [];
  String? _clientId; // null = 全部店铺
  String _period = 'month'; // month | last | custom
  final _fromCtrl = TextEditingController();
  final _toCtrl = TextEditingController();
  List<Map<String, dynamic>> _sales = [];
  List<Map<String, dynamic>> _payments = [];
  double _debtEnd = 0;
  bool _loading = false;
  bool _loaded = false;

  static String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _loadClients();
    _applyPeriod('month');
  }

  @override
  void dispose() {
    _fromCtrl.dispose();
    _toCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadClients() async {
    try {
      final d = await Api.instance.get('/clients');
      if (!mounted) return;
      setState(() => _clients = ((d['clients'] as List?) ?? []).cast<Map<String, dynamic>>());
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _applyPeriod(String p) {
    setState(() {
      _period = p;
      final now = DateTime.now();
      if (p == 'month') {
        _fromCtrl.text = _fmt(DateTime(now.year, now.month, 1));
        _toCtrl.text = _fmt(now);
      } else if (p == 'last') {
        _fromCtrl.text = _fmt(DateTime(now.year, now.month - 1, 1));
        _toCtrl.text = _fmt(DateTime(now.year, now.month, 0));
      }
    });
  }

  Future<void> _load() async {
    final from = _fromCtrl.text.trim();
    final to = _toCtrl.text.trim();
    if (from.isEmpty || to.isEmpty) {
      toast(context, '请选择起止日期');
      return;
    }
    final cid = _clientId ?? '';
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        Api.instance.get('/sales?client_id=$cid&date_from=$from&date_to=$to&limit=1000'),
        Api.instance.get('/payments?client_id=$cid&date_from=$from&date_to=$to&limit=1000'),
        Api.instance.get('/stats/summary?start=$from&end=$to&client_id=$cid'),
      ]);
      if (!mounted) return;
      setState(() {
        _sales = ((results[0]['sales'] as List?) ?? []).cast<Map<String, dynamic>>();
        _payments = ((results[1]['payments'] as List?) ?? []).cast<Map<String, dynamic>>();
        _debtEnd = ((results[2]['debt'] as num?)?.toDouble() ?? 0);
        _loading = false;
        _loaded = true;
      });
    } catch (e) {
      setState(() => _loading = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  double get _saleTotal => _sales.fold(0, (s, x) => s + ((x['total'] as num?)?.toDouble() ?? 0));
  double get _payTotal => _payments.fold(0, (s, x) => s + ((x['amount'] as num?)?.toDouble() ?? 0));

  String _date(Object? v) {
    final s = '$v';
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  String _buildText() {
    final buf = StringBuffer();
    buf.writeln('【陶朱对账单】');
    final from = _fromCtrl.text.trim();
    final to = _toCtrl.text.trim();
    final clientName = _clients.where((c) => '${c['id']}' == _clientId).map((c) => '${c['name']}').firstOrNull;
    buf.writeln('客户：${clientName ?? '全部店铺'}');
    buf.writeln('周期：$from 至 $to');
    buf.writeln('出货合计：¥${_saleTotal.toStringAsFixed(2)}（${_sales.length} 笔）');
    buf.writeln('收款合计：¥${_payTotal.toStringAsFixed(2)}（${_payments.length} 笔）');
    buf.writeln('期末欠款：¥${_debtEnd.toStringAsFixed(2)}');
    buf.writeln('—— 出货明细 ——');
    for (final s in _sales) {
      buf.writeln('${_date(s['happened_at'])} 出货 ¥${(s['total'] as num?)?.toStringAsFixed(2) ?? '-'}');
    }
    buf.writeln('—— 收款明细 ——');
    for (final p in _payments) {
      final m = '${p['method'] ?? ''}';
      buf.writeln('${_date(p['happened_at'])}${m.isNotEmpty ? ' $m' : ''} ¥${(p['amount'] as num?)?.toStringAsFixed(2) ?? '-'}');
    }
    return buf.toString();
  }

  Future<void> _copy() async {
    if (!_loaded) {
      toast(context, '请先生成对账单');
      return;
    }
    await Clipboard.setData(ClipboardData(text: _buildText()));
    toast(context, '对账文本已复制，可直接粘贴发送');
  }

  /// CSV 字段转义：含逗号/引号/换行的加引号包裹（引号翻倍）
  String _csv(Object? v) {
    final s = '$v';
    return s.contains(',') || s.contains('"') || s.contains('\n') ? '"${s.replaceAll('"', '""')}"' : s;
  }

  /// 生成 CSV（UTF-8 BOM 前缀，Excel 直接打开不乱码）：出货明细 + 收款明细
  String _buildCsv() {
    final buf = StringBuffer('\uFEFF');
    buf.writeln('类型,日期,店铺,金额,明细');
    for (final s in _sales) {
      final items = (s['items'] as List? ?? []);
      final detail = items
          .map((it) => '${it['item_name']}${it['quantity']}${it['unit']}')
          .join(';');
      buf.writeln(
          '出货,${_csv(_date(s['happened_at']))},${_csv(s['client_name'])},${_csv(s['total'])},${_csv(detail)}');
    }
    for (final p in _payments) {
      buf.writeln(
          '收款,${_csv(_date(p['happened_at']))},${_csv(p['client_name'])},${_csv(p['amount'])},${_csv(p['method'])}');
    }
    return buf.toString();
  }

  Future<void> _copyCsv() async {
    if (!_loaded) {
      toast(context, '请先生成对账单');
      return;
    }
    await Clipboard.setData(ClipboardData(text: _buildCsv()));
    toast(context, 'CSV 已复制（带表头），粘贴到 Excel 即可');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('对账单'),
        actions: [
          IconButton(
            tooltip: '复制对账文本',
            icon: const Icon(Icons.copy_outlined),
            onPressed: _copy,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String?>(
                    initialValue: _clientId,
                    decoration: const InputDecoration(labelText: '店铺'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('全部店铺')),
                      ..._clients
                          .map((c) => DropdownMenuItem<String?>(
                              value: '${c['id']}', child: Text('${c['name']}')))
                          .toList(),
                    ],
                    onChanged: (v) => setState(() => _clientId = v),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'month', label: Text('本月')),
                      ButtonSegment(value: 'last', label: Text('上月')),
                      ButtonSegment(value: 'custom', label: Text('自定义')),
                    ],
                    selected: {_period},
                    onSelectionChanged: (s) => _applyPeriod(s.first),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _fromCtrl,
                          decoration: const InputDecoration(labelText: '开始日期', isDense: true),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text('至'),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _toCtrl,
                          decoration: const InputDecoration(labelText: '结束日期', isDense: true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                    onPressed: _loading ? null : _load,
                    child: Text(_loading ? '生成中…' : '生成对账单'),
                  ),
                ],
              ),
            ),
          ),
          if (_loaded) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _statCard('出货合计', '¥${_saleTotal.toStringAsFixed(2)}', const Color(0xFFF56C6C))),
                const SizedBox(width: 12),
                Expanded(child: _statCard('收款合计', '¥${_payTotal.toStringAsFixed(2)}', const Color(0xFF67C23A))),
              ],
            ),
            const SizedBox(height: 12),
            _statCard('期末欠款（累计）', '¥${_debtEnd.toStringAsFixed(2)}',
                _debtEnd > 0 ? const Color(0xFFF56C6C) : const Color(0xFF67C23A)),
            const SizedBox(height: 16),
            const Text('出货明细', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(height: 8),
            if (_sales.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('周期内无出货', style: TextStyle(color: Colors.grey)),
              ),
            for (final s in _sales)
              Card(
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.storefront, size: 20, color: Color(0xFF409EFF)),
                  title: Text('${s['client_name'] ?? ''}'),
                  subtitle: Text('${_date(s['happened_at'])} · ${(s['items'] as List? ?? []).length} 项'),
                  trailing: Text('¥${(s['total'] as num?)?.toStringAsFixed(2) ?? '-'}',
                      style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFF56C6C))),
                ),
              ),
            const SizedBox(height: 8),
            const Text('收款明细', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(height: 8),
            if (_payments.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('周期内无收款', style: TextStyle(color: Colors.grey)),
              ),
            for (final p in _payments)
              Card(
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.check_circle_outline, size: 20, color: Color(0xFF67C23A)),
                  title: Text('${p['client_name'] ?? ''}'),
                  subtitle: Text(
                      '${_date(p['happened_at'])}${(p['method'] as String? ?? '').isNotEmpty ? ' · ${p['method']}' : ''}'),
                  trailing: Text('¥${(p['amount'] as num?)?.toStringAsFixed(2) ?? '-'}',
                      style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF67C23A))),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _copy,
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    label: const Text('复制文本'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _copyCsv,
                    icon: const Icon(Icons.table_chart_outlined, size: 18),
                    label: const Text('复制 CSV'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _statCard(String label, String value, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Color(0xFF909399), fontSize: 13)),
            const SizedBox(height: 6),
            Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: color)),
          ],
        ),
      ),
    );
  }
}