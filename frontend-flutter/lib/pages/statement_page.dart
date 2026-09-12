import 'dart:convert';
import 'package:excel/excel.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api.dart';
import '../local_db.dart';
import '../log.dart';
import '../utils/download.dart';
import '../utils/money.dart';
import '../theme.dart';
import '../widgets/date_field.dart';
import 'router.dart';

/// 对账单：按店铺 + 周期汇总出货/收款/期末欠款，一键复制文本发送给客户
class StatementPage extends StatefulWidget {
  const StatementPage({super.key});
  @override
  State<StatementPage> createState() => _StatementPageState();
}

class _StatementPageState extends State<StatementPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
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
  /// Excel 导出排版配置（前端自定义，本机持久化）
  _XlsCfg _xls = _XlsCfg();

  static String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _loadClients();
    _applyPeriod('month');
    _loadXlsCfg();
  }

  @override
  void dispose() {
    _fromCtrl.dispose();
    _toCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadClients() async {
    // 本地优先：店铺列表立即显示（离线/慢网不再只有"全部店铺"）
    try {
      final local = await LocalDb.getAllByName('clients');
      if (local.isNotEmpty && mounted) {
        setState(() => _clients = local);
      }
    } catch (_) {}
    // 网络刷新（静默：失败仅记日志）
    try {
      final d = await Api.instance.get('/clients').timeout(const Duration(seconds: 6));
      if (!mounted) return;
      final list = ((d['clients'] as List?) ?? []).cast<Map<String, dynamic>>();
      setState(() => _clients = list);
      LocalDb.upsertList('clients', list);
    } catch (e) {
      appLog('net', '对账单店铺列表刷新失败: ${e.toString().split('\n').first}', level: 'error');
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

  double get _saleTotal {
    // 按明细行独立日期统计（行日期缺省回退单据日期）
    final from = _fromCtrl.text.trim();
    final to = _toCtrl.text.trim();
    var t = 0.0;
    for (final s in _sales) {
      final orderDate = _date(s['happened_at']);
      for (final it in ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>()) {
        final id = '${it['happened_at'] ?? ''}';
        final d = id.length >= 10 ? id.substring(0, 10) : orderDate;
        if (d.compareTo(from) >= 0 && d.compareTo(to) <= 0) {
          t += ((it['amount'] as num?)?.toDouble() ?? 0);
        }
      }
    }
    return t;
  }

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

/// 导出 Excel：排版前端自定义（标题/表头信息行/明细粒度/明细列，本机记忆）
  Future<void> _exportXls() async {
    if (!_loaded) {
      toast(context, '请先生成对账单');
      return;
    }
    final clientName = _clients.where((c) => '${c['id']}' == _clientId).map((c) => '${c['name']}').firstOrNull ?? '全部店铺';
    final cfg = _xls.copy();
    final titleCtrl = TextEditingController(text: cfg.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('导出排版设置'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(labelText: '标题（Excel 首行）'),
              ),
              const SizedBox(height: 4),
              const Text('表头信息行',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              SwitchListTile(
                dense: true, contentPadding: EdgeInsets.zero,
                title: const Text('客户', style: TextStyle(fontSize: 14)),
                value: cfg.headClient, onChanged: (v) => setDlg(() => cfg.headClient = v),
              ),
              SwitchListTile(
                dense: true, contentPadding: EdgeInsets.zero,
                title: const Text('账期', style: TextStyle(fontSize: 14)),
                value: cfg.headPeriod, onChanged: (v) => setDlg(() => cfg.headPeriod = v),
              ),
              SwitchListTile(
                dense: true, contentPadding: EdgeInsets.zero,
                title: const Text('出货合计', style: TextStyle(fontSize: 14)),
                value: cfg.headSaleTotal, onChanged: (v) => setDlg(() => cfg.headSaleTotal = v),
              ),
              SwitchListTile(
                dense: true, contentPadding: EdgeInsets.zero,
                title: const Text('收款合计', style: TextStyle(fontSize: 14)),
                value: cfg.headPayTotal, onChanged: (v) => setDlg(() => cfg.headPayTotal = v),
              ),
              SwitchListTile(
                dense: true, contentPadding: EdgeInsets.zero,
                title: const Text('期末欠款', style: TextStyle(fontSize: 14)),
                value: cfg.headDebt, onChanged: (v) => setDlg(() => cfg.headDebt = v),
              ),
              const SizedBox(height: 4),
              const Text('明细粒度',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'detail', label: Text('逐行明细')),
                  ButtonSegment(value: 'daily', label: Text('按日汇总')),
                  ButtonSegment(value: 'item', label: Text('按商品汇总')),
                ],
                selected: {cfg.mode},
                onSelectionChanged: (s) => setDlg(() => cfg.mode = s.first),
              ),
              if (cfg.mode != 'daily') ...[
                const SizedBox(height: 4),
                const Text('出货明细列',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                SwitchListTile(
                  dense: true, contentPadding: EdgeInsets.zero,
                  title: const Text('日期', style: TextStyle(fontSize: 14)),
                  value: cfg.colDate, onChanged: (v) => setDlg(() => cfg.colDate = v),
                ),
                SwitchListTile(
                  dense: true, contentPadding: EdgeInsets.zero,
                  title: const Text('商品', style: TextStyle(fontSize: 14)),
                  value: cfg.colItem, onChanged: (v) => setDlg(() => cfg.colItem = v),
                ),
                SwitchListTile(
                  dense: true, contentPadding: EdgeInsets.zero,
                  title: const Text('数量', style: TextStyle(fontSize: 14)),
                  value: cfg.colQty, onChanged: (v) => setDlg(() => cfg.colQty = v),
                ),
                SwitchListTile(
                  dense: true, contentPadding: EdgeInsets.zero,
                  title: const Text('单价', style: TextStyle(fontSize: 14)),
                  value: cfg.colPrice, onChanged: (v) => setDlg(() => cfg.colPrice = v),
                ),
                SwitchListTile(
                  dense: true, contentPadding: EdgeInsets.zero,
                  title: const Text('金额', style: TextStyle(fontSize: 14)),
                  value: cfg.colAmount, onChanged: (v) => setDlg(() => cfg.colAmount = v),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('导出')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    cfg.title = titleCtrl.text.trim().isEmpty ? '对账单' : titleCtrl.text.trim();
    _xls = cfg;
    _saveXlsCfg(cfg);
    final excel = _buildExcel(cfg, clientName);
    final bytes = excel.encode();
    if (bytes == null) {
      toast(context, '导出失败，请重试');
      return;
    }
    // 预览确认
    final preview = _previewText(cfg.mode, clientName);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出预览'),
        content: SingleChildScrollView(
          child: Text(preview, style: const TextStyle(fontSize: 12, height: 1.6)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('导出')),
        ],
      ),
    );
    if (go != true) return;
    // 文件名 = 店铺-开始日期-结束日期（用户指定格式；saveBytes 已保证 App 端文件名不变形）
    final name = '$clientName-${_fromCtrl.text.trim()}-${_toCtrl.text.trim()}.xlsx';
    await saveBytes(
        Uint8List.fromList(bytes), name, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', '陶朱对账单');
    if (kIsWeb) toast(context, '对账单已导出（浏览器下载）');
  }

  /// 按排版配置生成 Excel：标题 + 可选表头信息行 + 明细（三种粒度）
  Excel _buildExcel(_XlsCfg cfg, String clientName) {
    final excel = Excel.createExcel();
    final sheet = excel['对账单'];
    sheet.setColumnWidth(0, 14);
    sheet.setColumnWidth(1, 32);
    sheet.setColumnWidth(2, 14);
    sheet.setColumnWidth(3, 14);
    sheet.setColumnWidth(4, 14);
    sheet.appendRow([TextCellValue(cfg.title)]);
    if (cfg.headClient) sheet.appendRow([TextCellValue('客户'), TextCellValue(clientName)]);
    if (cfg.headPeriod) {
      sheet.appendRow([
        TextCellValue('账期'),
        TextCellValue('${_fromCtrl.text.trim()} 至 ${_toCtrl.text.trim()}'),
      ]);
    }
    if (cfg.headSaleTotal) {
      sheet.appendRow([
        TextCellValue('出货合计'),
        TextCellValue('¥${_saleTotal.toStringAsFixed(2)}（${_sales.length} 笔）'),
      ]);
    }
    if (cfg.headPayTotal) {
      sheet.appendRow([
        TextCellValue('收款合计'),
        TextCellValue('¥${_payTotal.toStringAsFixed(2)}（${_payments.length} 笔）'),
      ]);
    }
    if (cfg.headDebt) {
      sheet.appendRow([TextCellValue('期末欠款'), TextCellValue('¥${_debtEnd.toStringAsFixed(2)}')]);
    }
    sheet.appendRow([TextCellValue('')]);
    switch (cfg.mode) {
      case 'daily':
        _sheetDaily(sheet, cfg);
        break;
      case 'item':
        _sheetItems(sheet, cfg);
        break;
      default:
        _sheetDetail(sheet, cfg);
    }
    return excel;
  }

  /// 出货明细列（按配置勾选）
  List<String> _detailCols(_XlsCfg cfg) => [
        if (cfg.colDate) '日期',
        if (cfg.colItem) '商品',
        if (cfg.colQty) '数量',
        if (cfg.colPrice) '单价',
        if (cfg.colAmount) '金额',
      ];

  /// 逐行明细：出货按明细行（行日期独立，缺省回退单据日期）+ 收款明细（固定列）
  void _sheetDetail(Sheet sheet, _XlsCfg cfg) {
    sheet.appendRow([for (final h in _detailCols(cfg)) TextCellValue(h)]);
    for (final s in _sales) {
      final orderDate = _date(s['happened_at']);
      final items = (s['items'] as List? ?? []).cast<Map<String, dynamic>>();
      if (items.isEmpty) {
        sheet.appendRow([
          if (cfg.colDate) TextCellValue(orderDate),
          if (cfg.colItem) TextCellValue('${s['note'] ?? ''}'),
          if (cfg.colQty) TextCellValue(''),
          if (cfg.colPrice) TextCellValue(''),
          if (cfg.colAmount) TextCellValue('¥${((s['total'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}'),
        ]);
      }
      for (final it in items) {
        final id = '${it['happened_at'] ?? ''}';
        final d = id.length >= 10 ? id.substring(0, 10) : orderDate;
        sheet.appendRow([
          if (cfg.colDate) TextCellValue(d),
          if (cfg.colItem) TextCellValue('${it['item_name']}'),
          if (cfg.colQty) TextCellValue('${it['quantity']}${it['unit']}'),
          if (cfg.colPrice) TextCellValue('¥${((it['sale_price'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}'),
          if (cfg.colAmount) TextCellValue('¥${((it['amount'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}'),
        ]);
      }
    }
    sheet.appendRow([TextCellValue('')]);
    sheet.appendRow([
      TextCellValue('日期'), TextCellValue('收款方式'), TextCellValue('实收'), TextCellValue('平账'),
    ]);
    for (final p in _payments) {
      final w = ((p['waived'] as num?)?.toDouble() ?? 0);
      sheet.appendRow([
        TextCellValue(_date(p['happened_at'])),
        TextCellValue('${p['method'] ?? ''}'),
        TextCellValue('¥${((p['amount'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}'),
        TextCellValue(w > 0 ? '¥${w.toStringAsFixed(2)}' : ''),
      ]);
    }
  }

  /// 按日汇总：每天销售总额（按明细行日期）
  void _sheetDaily(Sheet sheet, _XlsCfg cfg) {
    sheet.appendRow([TextCellValue('日期'), TextCellValue('金额')]);
    final byDay = _salesByDay();
    if (byDay.isEmpty) {
      sheet.appendRow([TextCellValue('本期无出货'), TextCellValue('')]);
      return;
    }
    double total = 0;
    for (final d in byDay.keys.toList()..sort()) {
      final v = byDay[d] ?? 0;
      total += v;
      sheet.appendRow([TextCellValue(d), TextCellValue('¥${v.toStringAsFixed(2)}')]);
    }
    sheet.appendRow([TextCellValue('销售总额'), TextCellValue('¥${total.toStringAsFixed(2)}')]);
  }

  /// 按商品汇总：每种商品的总数量与总金额
  void _sheetItems(Sheet sheet, _XlsCfg cfg) {
    sheet.appendRow([
      if (cfg.colItem) TextCellValue('商品'),
      if (cfg.colQty) TextCellValue('数量'),
      if (cfg.colAmount) TextCellValue('金额'),
    ]);
    final agg = <String, ({double qty, double amount})>{};
    for (final s in _sales) {
      for (final it in ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>()) {
        final name = '${it['item_name'] ?? ''}';
        final prev = agg[name] ?? (qty: 0, amount: 0);
        agg[name] = (
          qty: prev.qty + ((it['quantity'] as num?)?.toDouble() ?? 0),
          amount: prev.amount + ((it['amount'] as num?)?.toDouble() ?? 0),
        );
      }
    }
    if (agg.isEmpty) {
      sheet.appendRow([TextCellValue('本期无出货'), TextCellValue(''), TextCellValue('')]);
      return;
    }
    double total = 0;
    for (final e in agg.entries) {
      total += e.value.amount;
      sheet.appendRow([
        if (cfg.colItem) TextCellValue(e.key),
        if (cfg.colQty) TextCellValue(e.value.qty.toStringAsFixed(1)),
        if (cfg.colAmount) TextCellValue('¥${e.value.amount.toStringAsFixed(2)}'),
      ]);
    }
    sheet.appendRow([
      if (cfg.colItem) TextCellValue('合计'),
      if (cfg.colQty) TextCellValue(''),
      if (cfg.colAmount) TextCellValue('¥${total.toStringAsFixed(2)}'),
    ]);
  }

  /// 读取本机保存的导出排版配置
  Future<void> _loadXlsCfg() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('taozhu_stmt_xls_cfg');
      if (raw != null && raw.isNotEmpty) {
        _xls = _XlsCfg.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {}
  }

  /// 保存导出排版配置到本机（下次导出沿用）
  Future<void> _saveXlsCfg(_XlsCfg cfg) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('taozhu_stmt_xls_cfg', jsonEncode(cfg.toJson()));
    } catch (_) {}
  }

  /// 出货按日聚合（按明细行日期；行日期缺省回退单据日期）
  Map<String, double> _salesByDay() {
    final byDay = <String, double>{};
    for (final s in _sales) {
      final orderDate = _date(s['happened_at']);
      for (final it in ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>()) {
        final id = '${it['happened_at'] ?? ''}';
        final d = id.length >= 10 ? id.substring(0, 10) : orderDate;
        byDay[d] = (byDay[d] ?? 0) + ((it['amount'] as num?)?.toDouble() ?? 0);
      }
    }
    return byDay;
  }

  /// 导出预览文本（按排版模式：逐行明细 / 按日汇总 / 按商品汇总）
  String _previewText(String mode, String clientName) {
    final buf = StringBuffer()
      ..writeln('客户：$clientName')
      ..writeln('账期：${_fromCtrl.text.trim()} 至 ${_toCtrl.text.trim()}');
    if (mode == 'daily') {
      buf.writeln('—— 按日汇总（销售总额）——');
      final byDay = _salesByDay();
      final days = byDay.keys.toList()..sort();
      for (final d in days.take(12)) {
        buf.writeln('$d  ¥${(byDay[d] ?? 0).toStringAsFixed(2)}');
      }
      if (days.length > 12) buf.writeln('… 共 ${days.length} 天');
      final total = byDay.values.fold<double>(0, (a, b) => a + b);
      buf.writeln('销售总额 ¥${total.toStringAsFixed(2)}');
    } else if (mode == 'item') {
      buf.writeln('—— 按商品汇总 ——');
      final agg = <String, double>{};
      for (final s in _sales) {
        for (final it in ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>()) {
          final n = '${it['item_name'] ?? ''}';
          agg[n] = (agg[n] ?? 0) + ((it['amount'] as num?)?.toDouble() ?? 0);
        }
      }
      var shown = 0;
      for (final e in agg.entries) {
        if (shown >= 8) break;
        buf.writeln('${e.key}  ¥${e.value.toStringAsFixed(2)}');
        shown++;
      }
      final total = agg.values.fold<double>(0, (a, b) => a + b);
      buf.writeln('共 ${agg.length} 种商品 · 总额 ¥${total.toStringAsFixed(2)}');
    } else {
      buf.writeln('—— 出货明细（${_sales.length} 笔）——');
      var shown = 0;
      for (final s in _sales) {
        if (shown >= 8) break;
        final items = (s['items'] as List? ?? []).cast<Map<String, dynamic>>();
        final first = items.isEmpty ? '${s['note'] ?? ''}' : '${items.first['item_name']} 等 ${items.length} 项';
        buf.writeln('${_date(s['happened_at'])} $first ¥${((s['total'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}');
        shown++;
      }
      if (_sales.length > 8) buf.writeln('… 共 ${_sales.length} 笔');
      buf.writeln('收款 ${_payments.length} 笔 · 期末欠款 ¥${_debtEnd.toStringAsFixed(2)}');
    }
    return buf.toString();
  }

  /// 我的分享管理：列出历史分享链接（含到期/已过期），可随时取消（删除）
  Future<void> _manageShares() async {
    List<Map<String, dynamic>> shares = [];
    try {
      final d = await Api.instance.get('/share');
      shares = ((d['shares'] as List?) ?? []).cast<Map<String, dynamic>>();
    } catch (e) {
      toast(context, '获取分享列表失败：${e.toString().replaceFirst('Exception: ', '')}');
      return;
    }
    if (!mounted) return;
    String fmtExp(String? e) {
      if (e == null) return '永久有效';
      final d = DateTime.tryParse(e);
      return d == null ? '未知' : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} 到期';
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('我的分享（可取消）'),
        content: SizedBox(
          width: double.maxFinite,
          height: 340,
          child: shares.isEmpty
              ? Center(child: Text('暂无分享记录', style: TextStyle(color: _c.textSub)))
              : ListView(
                  children: [
                    for (final s in shares)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${s['expired'] == true ? '已过期 · ' : ''}${fmtExp('${s['expires_at']}')}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: s['expired'] == true
                                          ? _c.textSub
                                          : null,
                                    ),
                                  ),
                                  Text('${s['url']}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 11, color: _c.textSub)),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '复制链接',
                              icon: const Icon(Icons.copy_outlined, size: 18),
                              onPressed: () async {
                                await Clipboard.setData(ClipboardData(text: '${s['url']}'));
                                toast(ctx, '链接已复制');
                              },
                            ),
                            if (s['expired'] != true)
                              IconButton(
                                tooltip: '延期',
                                icon: Icon(Icons.update_outlined, size: 18, color: _c.primary),
                                onPressed: () async {
                                  const opts = [('+3 天', 3), ('+7 天', 7), ('+30 天', 30), ('永久', 0)];
                                  final sel = await showDialog<String>(
                                    context: ctx,
                                    builder: (dctx) => SimpleDialog(
                                      title: const Text('延长分享有效期'),
                                      children: [
                                        for (final o in opts)
                                          SimpleDialogOption(
                                            onPressed: () => Navigator.pop(dctx, '${o.$2}'),
                                            child: Text(o.$1, style: const TextStyle(fontSize: 15)),
                                          ),
                                      ],
                                    ),
                                  );
                                  if (sel == null) return;
                                  try {
                                    final body = sel == '0'
                                        ? {'permanent': true}
                                        : {'extend_days': int.parse(sel)};
                                    await Api.instance.patch('/share/${s['token']}', body);
                                    toast(ctx, '已延期');
                                    if (ctx.mounted) Navigator.pop(ctx);
                                    _manageShares();
                                  } catch (e) {
                                    toast(ctx, '延期失败：${e.toString().replaceFirst('Exception: ', '')}');
                                  }
                                },
                              ),
                            IconButton(
                              tooltip: '取消分享',
                              icon: Icon(Icons.delete_outline, size: 18, color: _c.danger),
                              onPressed: () async {
                                try {
                                  await Api.instance.delete('/share/${s['token']}');
                                  toast(ctx, '已取消该分享');
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  _manageShares();
                                } catch (e) {
                                  toast(ctx, '取消失败：${e.toString().replaceFirst('Exception: ', '')}');
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
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
    final c = _c;
    return Scaffold(
      appBar: AppBar(
        title: const Text('对账单'),
        actions: [
          IconButton(
            tooltip: '我的分享',
            icon: const Icon(Icons.link_outlined),
            onPressed: _manageShares,
          ),
          IconButton(
            tooltip: '分享对账单',
            icon: const Icon(Icons.share_outlined),
            onPressed: _share,
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
                  // 账期（自定义时）：日期选择器竖排，避免并排截断日期
                  DateField(
                    controller: _fromCtrl,
                    label: '开始日期',
                    lastDate: DateTime(DateTime.now().year + 5, 12, 31),
                  ),
                  const SizedBox(height: 8),
                  DateField(
                    controller: _toCtrl,
                    label: '结束日期',
                    lastDate: DateTime(DateTime.now().year + 5, 12, 31),
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
                Expanded(child: _statCard('出货合计', '¥${_saleTotal.toStringAsFixed(2)}', c.danger)),
                const SizedBox(width: 12),
                Expanded(child: _statCard('收款合计（实收）', '¥${_payTotal.toStringAsFixed(2)}', c.success)),
              ],
            ),
            if (_waivedTotal > 0) ...[
              const SizedBox(height: 12),
              _statCard('减免合计（平账）', '¥${_waivedTotal.toStringAsFixed(2)}', c.warning),
            ],
            const SizedBox(height: 12),
            _statCard('期末欠款（累计）', '¥${_debtEnd.toStringAsFixed(2)}',
                _debtEnd > 0 ? c.danger : c.success),
            const SizedBox(height: 16),
            const Text('出货明细', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(height: 8),
            if (_sales.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('周期内无出货', style: TextStyle(color: c.textSub)),
              ),
            for (final s in _sales)
              Card(
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.storefront, size: 20, color: _c.primary),
                  title: Text('${s['client_name'] ?? ''}'),
                  subtitle: Text('${_date(s['happened_at'])} · ${(s['items'] as List? ?? []).length} 项'),
                  trailing: Text('¥${(s['total'] as num?)?.toStringAsFixed(2) ?? '-'}',
                      style: TextStyle(fontWeight: FontWeight.w700, color: c.danger)),
                ),
              ),
            const SizedBox(height: 8),
            const Text('收款明细', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(height: 8),
            if (_payments.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('周期内无收款', style: TextStyle(color: c.textSub)),
              ),
            for (final p in _payments)
              Card(
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.check_circle_outline, size: 20, color: c.success),
                  title: Text('${p['client_name'] ?? ''}'),
                  subtitle: Text(
                      '${_date(p['happened_at'])}${(p['method'] as String? ?? '').isNotEmpty ? ' · ${p['method']}' : ''}'),
                  trailing: Text('¥${(p['amount'] as num?)?.toStringAsFixed(2) ?? '-'}',
                      style: TextStyle(fontWeight: FontWeight.w700, color: c.success)),
                ),
              ),
            const SizedBox(height: 8),
            // 导出 Excel（支持格式选择：完整明细 / 按日汇总打印版）
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _exportXls,
              icon: const Icon(Icons.table_chart_outlined, size: 18),
              label: const Text('导出 Excel'),
            ),
          ],
        ],
      ),
    );
  }

  double _num(Object? v) => (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);

  Widget _statCard(String label, String value, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: _c.textSub, fontSize: 13)),
            const SizedBox(height: 6),
            Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: color)),
          ],
        ),
      ),
    );
  }
}

/// 对账单 Excel 导出排版配置（前端自定义，本机持久化）
class _XlsCfg {
  _XlsCfg();

  String title = '陶朱对账单';
  bool headClient = true;
  bool headPeriod = true;
  bool headSaleTotal = true;
  bool headPayTotal = true;
  bool headDebt = true;
  String mode = 'detail'; // detail | daily | item
  bool colDate = true;
  bool colItem = true;
  bool colQty = true;
  bool colPrice = true;
  bool colAmount = true;

  Map<String, dynamic> toJson() => {
        'title': title,
        'headClient': headClient,
        'headPeriod': headPeriod,
        'headSaleTotal': headSaleTotal,
        'headPayTotal': headPayTotal,
        'headDebt': headDebt,
        'mode': mode,
        'colDate': colDate,
        'colItem': colItem,
        'colQty': colQty,
        'colPrice': colPrice,
        'colAmount': colAmount,
      };

  _XlsCfg.fromJson(Map<String, dynamic> j) {
    title = '${j['title'] ?? '陶朱对账单'}';
    headClient = j['headClient'] != false;
    headPeriod = j['headPeriod'] != false;
    headSaleTotal = j['headSaleTotal'] != false;
    headPayTotal = j['headPayTotal'] != false;
    headDebt = j['headDebt'] != false;
    mode = '${j['mode'] ?? 'detail'}';
    colDate = j['colDate'] != false;
    colItem = j['colItem'] != false;
    colQty = j['colQty'] != false;
    colPrice = j['colPrice'] != false;
    colAmount = j['colAmount'] != false;
  }

  _XlsCfg copy() => _XlsCfg.fromJson(toJson());
}