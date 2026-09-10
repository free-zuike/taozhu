import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api.dart';
import '../utils/download.dart';
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
  String _period = 'month'; // month | last | cycle | cycleLast | custom

  /// 选中店铺的每月起始日（1=自然月）
  int get _msd {
    if (_clientId != null) {
      final c = _clients.where((x) => '${x['id']}' == _clientId).firstOrNull;
      final v = c?['month_start_day'];
      if (v is num && v.toInt() >= 1 && v.toInt() <= 28) return v.toInt();
    }
    return 1;
  }

  /// 结账周期（按起始日）：[起始日, 次月起始日-1]；起始日=1 时按自然月
  (String, String) _cyclePeriod(int startDay, DateTime anchor) {
    if (startDay <= 1) {
      return (
        _fmt(DateTime(anchor.year, anchor.month, 1)),
        _fmt(DateTime(anchor.year, anchor.month + 1, 0)),
      );
    }
    final thisStart = DateTime(anchor.year, anchor.month, startDay);
    final (s, e) = anchor.day >= startDay
        ? (thisStart, DateTime(anchor.year, anchor.month + 1, startDay))
        : (DateTime(anchor.year, anchor.month - 1, startDay), thisStart);
    return (_fmt(s), _fmt(e.subtract(const Duration(days: 1))));
  }
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
      } else if (p == 'cycle' || p == 'cycleLast') {
        // 按店铺结账周期（month_start_day）：本期/上期
        final anchor = p == 'cycle' ? now : DateTime(now.year, now.month - 1, now.day.clamp(1, 28));
        final (s, e) = _cyclePeriod(_msd, anchor);
        _fromCtrl.text = s;
        _toCtrl.text = e;
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
  double get _waivedTotal => _payments.fold(0, (s, x) => s + (((x['waived'] as num?)?.toDouble()) ?? 0));

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
      final w = ((p['waived'] as num?) ?? 0) > 0 ? ' 平账¥${p['waived']}' : '';
      buf.writeln('${_date(p['happened_at'])}${m.isNotEmpty ? ' $m' : ''}$w ¥${(p['amount'] as num?)?.toStringAsFixed(2) ?? '-'}');
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

  /// 生成 .xls（HTML 表格，Excel/微信可直接打开）内容，UTF-8 BOM 保证中文不乱码
  String _buildXls() {
    final esc = (String s) => s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final clientName = _clients.where((c) => '${c['id']}' == _clientId).map((c) => '${c['name']}').firstOrNull ?? '全部店铺';
    final buf = StringBuffer()
      ..writeln('<html><head><meta charset="utf-8"><title>陶朱对账单</title></head><body>')
      ..writeln('<h3>陶朱对账单</h3>')
      ..writeln('<table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse">')
      ..writeln('<tr><td><b>客户</b></td><td>${esc(clientName)}</td><td><b>账期</b></td><td>${esc(_fromCtrl.text.trim())} 至 ${esc(_toCtrl.text.trim())}</td></tr>')
      ..writeln('<tr><td><b>出货合计</b></td><td>¥${_saleTotal.toStringAsFixed(2)}（${_sales.length} 笔）</td><td><b>收款合计</b></td><td>¥${_payTotal.toStringAsFixed(2)}（${_payments.length} 笔）</td></tr>')
      ..writeln('<tr><td><b>期末欠款</b></td><td colspan="3">¥${_debtEnd.toStringAsFixed(2)}</td></tr>')
      ..writeln('<tr><th>日期</th><th>出货明细</th><th>数量</th><th>金额</th></tr>');
    for (final s in _sales) {
      final items = (s['items'] as List? ?? []).cast<Map<String, dynamic>>();
      if (items.isEmpty) {
        buf.writeln('<tr><td>${_date(s['happened_at'])}</td><td>${esc('${s['note'] ?? ''}')}</td><td></td><td>¥${((s['total'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}</td></tr>');
      }
      for (final it in items) {
        buf.writeln('<tr><td>${_date(s['happened_at'])}</td><td>${esc('${it['item_name']}')}</td><td>${it['quantity']}${esc('${it['unit']}')}</td><td>¥${((it['amount'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}</td></tr>');
      }
    }
    buf.writeln('<tr><th>日期</th><th>收款方式</th><th>实收</th><th>平账</th></tr>');
    for (final p in _payments) {
      final w = ((p['waived'] as num?)?.toDouble() ?? 0);
      buf.writeln('<tr><td>${_date(p['happened_at'])}</td><td>${esc('${p['method'] ?? ''}')}</td><td>¥${((p['amount'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}</td><td>${w > 0 ? '¥${w.toStringAsFixed(2)}' : ''}</td></tr>');
    }
    buf.writeln('</table></body></html>');
    return buf.toString();
  }

  /// 导出 Excel（.xls，HTML 表格格式，微信/Excel 可直接打开）
  Future<void> _exportXls() async {
    if (!_loaded) {
      toast(context, '请先生成对账单');
      return;
    }
    final bytes = Uint8List.fromList(utf8.encode('\ufeff${_buildXls()}'));
    final name = 'taozhu-对账单-${_fromCtrl.text.trim()}-${_toCtrl.text.trim()}.xls';
    await saveBytes(bytes, name, 'application/vnd.ms-excel', '陶朱对账单');
    if (kIsWeb) toast(context, '对账单已导出（浏览器下载）');
  }

  /// 生成可分享的对账单页面链接（可选失效时间：3 天 / 7 天 / 1 个月 / 永久）
  Future<void> _share() async {
    if (!_loaded) {
      toast(context, '请先生成对账单');
      return;
    }
    const ttlOptions = [('3 天', 72), ('7 天', 168), ('1 个月', 720), ('永久', 0)];
    final sel = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('分享对账单（设置失效时间）'),
        children: [
          for (final o in ttlOptions)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '${o.$2}'),
              child: Text(o.$1, style: const TextStyle(fontSize: 15)),
            ),
        ],
      ),
    );
    if (sel == null) return;
    final clientName = _clients.where((c) => '${c['id']}' == _clientId).map((c) => '${c['name']}').firstOrNull ?? '全部店铺';
    final payload = jsonEncode({
      'client': clientName,
      'from': _fromCtrl.text.trim(),
      'to': _toCtrl.text.trim(),
      'debt': _debtEnd,
      'sales': _sales.map((s) {
        final items = (s['items'] as List? ?? []).cast<Map<String, dynamic>>();
        return {
          'date': _date(s['happened_at']),
          'name': s['client_name'] ?? clientName,
          'items': items.map((it) => '${it['item_name']} ×${it['quantity']}${it['unit']}').join('、'),
          'amount': s['total'],
        };
      }).toList(),
      'payments': _payments.map((p) => {
            'date': _date(p['happened_at']),
            'method': p['method'] ?? '',
            'amount': p['amount'],
            'waived': p['waived'] ?? 0,
          }).toList(),
    });
    try {
      final d = await Api.instance.post('/share', {'payload': payload, 'ttl_hours': int.parse(sel)});
      final url = '${d['url'] ?? ''}';
      if (!mounted) return;
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('分享链接已生成'),
          content: Text('对方用浏览器打开即可查看对账单：\n\n$url\n\n链接在选定时间后自动失效。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'copy'), child: const Text('复制链接')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'ok'), child: const Text('好')),
          ],
        ),
      );
      if (action == 'copy') {
        await Clipboard.setData(ClipboardData(text: url));
        toast(context, '链接已复制');
      }
    } catch (e) {
      toast(context, '生成分享失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('对账单'),
        actions: [
          IconButton(
            tooltip: '分享对账单',
            icon: const Icon(Icons.share_outlined),
            onPressed: _share,
          ),
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
                    segments: [
                      const ButtonSegment(value: 'month', label: Text('本月')),
                      const ButtonSegment(value: 'last', label: Text('上月')),
                      if (_msd > 1) ...[
                        const ButtonSegment(value: 'cycle', label: Text('账期本期')),
                        const ButtonSegment(value: 'cycleLast', label: Text('账期上期')),
                      ],
                      const ButtonSegment(value: 'custom', label: Text('自定义')),
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
                Expanded(child: _statCard('收款合计（实收）', '¥${_payTotal.toStringAsFixed(2)}', const Color(0xFF67C23A))),
              ],
            ),
            if (_waivedTotal > 0) ...[
              const SizedBox(height: 12),
              _statCard('减免合计（平账）', '¥${_waivedTotal.toStringAsFixed(2)}', const Color(0xFFE6A23C)),
            ],
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
                    onPressed: _exportXls,
                    icon: const Icon(Icons.table_chart_outlined, size: 18),
                    label: const Text('导出 Excel'),
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