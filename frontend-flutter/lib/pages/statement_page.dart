import 'dart:convert';
import 'package:excel/excel.dart' hide Border;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api.dart';
import '../sync_service.dart';
import '../local_db.dart';
import '../log.dart';
import '../utils/download.dart';
import '../utils/money.dart';
import '../utils/open_print.dart';
import '../theme.dart';
import '../widgets/date_field.dart';
import '../statement_tmpl.dart';
import 'router.dart';
import 'statement_template_page.dart';

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
  /// 当前排版模板（导出/打印用）
  _XlsCfg _xls = _XlsCfg();
  /// 全部模板（本机持久化：可添加/修改/删除；内置「标准」「旬段汇总」不可删）
  List<_XlsCfg> _templates = [];
  /// 公共库模板（renderTemplateRows 渲染成品唯一数据源；开箱即用预设 + 用户模板）
  List<XlsCfg> _pubTpls = [];
  /// 当前选中的成品样式名（默认「标准」=多栏月账单，生成后直接展示无需设计）
  String _selTplName = '标准';

  static String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _loadClients();
    _loadTemplates();
    _initLoad(); // 先恢复记忆店铺，再生成对账单（避免首载默认全店数据串店）
  }

  /// 恢复全局记忆的当前店铺后生成对账单（本地 prefs 读取，秒回；无记忆则全部店铺）
  Future<void> _initLoad() async {
    try {
      final sel = await SyncService.selectedClientId();
      if (sel != null && mounted) setState(() => _clientId = sel);
    } catch (_) {}
    _applyPeriod('month');
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
    _load(); // 切换周期立即重新生成对账单
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
      // 并行拉数据 + 加载公共模板（成品预览/导出/打印同源）
      final results = await Future.wait([
        Api.instance.get('/sales?client_id=$cid&date_from=$from&date_to=$to&limit=1000'),
        Api.instance.get('/payments?client_id=$cid&date_from=$from&date_to=$to&limit=1000'),
        Api.instance.get('/stats/summary?start=$from&end=$to&client_id=$cid'),
      ]);
      List<XlsCfg> tpls;
      try {
        tpls = await loadTemplates();
        if (tpls.isEmpty) tpls = [XlsCfg()..name = '标准'];
      } catch (_) {
        tpls = [XlsCfg()..name = '标准'];
      }
      if (!mounted) return;
      setState(() {
        _sales = ((results[0]['sales'] as List?) ?? []).cast<Map<String, dynamic>>();
        _payments = ((results[1]['payments'] as List?) ?? []).cast<Map<String, dynamic>>();
        _debtEnd = ((results[2]['debt'] as num?)?.toDouble() ?? 0);
        _pubTpls = tpls;
        // 首次选中「标准」（多栏月账单开箱即用）；用户之后手动切换则在 chips 中持久化
        if (!tpls.any((t) => t.name == _selTplName)) _selTplName = tpls.first.name;
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

  /// 对账单数据快照（公共渲染库输入）
  TemplateData _td(String clientName) => TemplateData(
        sales: _sales,
        payments: _payments,
        from: _fromCtrl.text.trim(),
        to: _toCtrl.text.trim(),
        clientName: clientName,
        debtEnd: _debtEnd,
      );

  /// 当前选中成品样式（公共库模板；缺省第一条）
  XlsCfg get _curPubTpl {
    final t = _pubTpls.where((t) => t.name == _selTplName).firstOrNull;
    return t ?? (_pubTpls.isNotEmpty ? _pubTpls.first : XlsCfg()..name = '标准');
  }

  /// 当前店铺名（成品标题用；全部店铺时为空串由默认模板兜底）
  String get clientNameForTpl =>
      _clients.where((c) => '${c['id']}' == _clientId).map((c) => '${c['name']}').firstOrNull ?? '';

  /// 模板行集合 → 表格预览（公共渲染结果，组件/网格/正文/默认通吃；加粗/底纹随行渲染）
  Widget _previewTplRows(List<List<GridCell>> rows) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        border: TableBorder.all(color: const Color(0xFF9E9E9E), width: 0.5),
        defaultColumnWidth: const IntrinsicColumnWidth(),
        children: [
          for (final row in rows)
            TableRow(children: [
              for (final c in row)
                Container(
                  color: c.bg == 'grey' ? const Color(0xFFF2F2F2) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  child: Text(c.text,
                      textAlign: c.align == 'center'
                          ? TextAlign.center
                          : (c.align == 'right' ? TextAlign.right : TextAlign.left),
                      style: TextStyle(fontSize: 12, fontWeight: c.bold ? FontWeight.w700 : FontWeight.normal)),
                ),
            ]),
        ],
      ),
    );
  }

  /// 导出对账单（模板化：默认当前选中样式 → 预览 → 导出；样式在页面上方 chips 切换）
  Future<void> _exportTpl() async {
    if (!_loaded) {
      toast(context, '请先生成对账单');
      return;
    }
    final clientName = clientNameForTpl.isEmpty ? '全部店铺' : clientNameForTpl;
    List<XlsCfg> templates;
    try {
      templates = await loadTemplates();
      if (templates.isEmpty) templates = [XlsCfg()..name = '标准'];
    } catch (_) {
      templates = [XlsCfg()..name = '标准'];
    }
    // 默认跟随页面当前选中样式（开箱即用：页面上方已实时预览，此处只是确认导出）
    if (_selTplName.isNotEmpty && templates.any((t) => t.name == _selTplName)) {
      // 保持页面选择
    }
    String selName = _selTplName.isNotEmpty && templates.any((t) => t.name == _selTplName)
        ? _selTplName
        : templates.first.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('导出对账单'),
          scrollable: true,
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('选择样式', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final t in templates)
                    ChoiceChip(
                      label: Text(t.name, style: const TextStyle(fontSize: 12)),
                      selected: t.name == selName,
                      onSelected: (_) => setDlg(() => selName = t.name),
                    ),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  OutlinedButton.icon(
                      icon: const Icon(Icons.visibility_outlined, size: 16), label: const Text('预览'),
                      onPressed: () {
                        final sel = templates.firstWhere((t) => t.name == selName, orElse: () => templates.first);
                        showDialog<void>(
                          context: ctx,
                          builder: (c2) => AlertDialog(
                            title: Text('预览：${sel.name}'),
                            content: SizedBox(width: 560, child: _previewTplRows(renderTemplateRows(sel, _td(clientName)))),
                            actions: [TextButton(onPressed: () => Navigator.pop(c2), child: const Text('关闭'))],
                          ),
                        );
                      }),
                  const SizedBox(width: 12),
                  Text('需要调整样式？返回页面上方「样式」chips 选择', style: TextStyle(fontSize: 11, color: _c.textSub)),
                ]),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('导出')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    // 弹窗所选样式同步回页面（下次生成仍用该样式）
    if (selName != _selTplName) setState(() => _selTplName = selName);
    final sel = templates.firstWhere((t) => t.name == selName, orElse: () => templates.first);
    final excel = Excel.createExcel();
    excel.rename('Sheet1', '对账单');
    final sheet = excel['对账单'];
    final trows = renderTemplateRows(sel, _td(clientName));
    var ri = 0;
    for (final row in trows) {
      sheet.appendRow([for (final c in row) TextCellValue(c.text)]);
      // 样式（加粗/底纹/对齐）→ 单元格 cellStyle，与预览/打印同源
      for (var cc = 0; cc < row.length; cc++) {
        final c = row[cc];
        if (c.align == 'left' && !c.bold && c.bg.isEmpty) continue;
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: cc, rowIndex: ri)).cellStyle = CellStyle(
              horizontalAlign: c.align == 'center'
                  ? HorizontalAlign.Center
                  : (c.align == 'right' ? HorizontalAlign.Right : HorizontalAlign.Left),
              bold: c.bold,
              backgroundColorHex: c.bg == 'grey' ? ExcelColor.grey100 : ExcelColor.none,
            );
      }
      ri++;
    }
    final bytes = excel.encode();
    if (bytes == null) {
      toast(context, '导出失败，请重试');
      return;
    }
    final name = '$clientName-${_fromCtrl.text.trim()}-${_toCtrl.text.trim()}.xlsx';
    await saveBytes(
        Uint8List.fromList(bytes), name, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', '陶朱对账单');
    if (kIsWeb) toast(context, '对账单已导出（浏览器下载）');
  }

  /// 导出 Excel + 排版模板管理：模板选择/自定义/另存新模板/修改/删除 + 所见即所得版式预览
  Future<void> _exportXls() async {
    if (!_loaded) {
      toast(context, '请先生成对账单');
      return;
    }
    final clientName = _clients.where((c) => '${c['id']}' == _clientId).map((c) => '${c['name']}').firstOrNull ?? '全部店铺';
    var cfg = _xls.copy();
    final nameCtrl = TextEditingController(text: cfg.name);
    final titleCtrl = TextEditingController(text: cfg.title);
    final contentCtrl = TextEditingController(text: cfg.content);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('对账单模板'),
          scrollable: true,
          content: SizedBox(
            width: 430,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 模板列表：点选即载入该模板排版
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final t in _templates)
                      ChoiceChip(
                        label: Text(t.name, style: const TextStyle(fontSize: 12)),
                        selected: t.name == cfg.name,
                        onSelected: (_) => setDlg(() {
                          cfg = t.copy();
                          nameCtrl.text = cfg.name;
                          titleCtrl.text = cfg.title;
                          contentCtrl.text = cfg.content; // 同步正文，避免陈旧文本覆盖新模板
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: '模板名', isDense: true),
                  onChanged: (v) => cfg.name = v.trim().isEmpty ? cfg.name : v.trim(),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(labelText: '标题（首行）', isDense: true),
                  onChanged: (v) => cfg.title = v,
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
                    ButtonSegment(value: 'item', label: Text('按商品')),
                    ButtonSegment(value: 'period', label: Text('旬段汇总')),
                  ],
                  selected: {cfg.mode},
                  onSelectionChanged: (s) => setDlg(() => cfg.mode = s.first),
                ),
                if (cfg.mode == 'detail' || cfg.mode == 'item') ...[
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
                const SizedBox(height: 8),
                // 模板正文（自由编排 + 变量占位；空=按上方结构化字段生成）
                const Text('模板正文（可插入变量；预览/导出/打印同源渲染）',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                TextField(
                  controller: contentCtrl,
                  maxLines: 6,
                  minLines: 3,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '留空 = 按上方结构化字段生成\n\n示例：\n对账单\n店铺：{店铺}\n账期：{账期}\n出货合计：{出货合计}　期末欠款：{期末欠款}\n\n明细：\n{明细}',
                  ),
                  onChanged: (v) => cfg.content = v,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  children: [
                    for (final v in const ['店铺', '账期', '日期', '出货合计', '收款合计', '期末欠款', '出货笔数', '明细', '旬段表'])
                      ActionChip(
                        label: Text('{$v}', style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          final t = contentCtrl.text;
                          final idx = contentCtrl.selection.isValid ? contentCtrl.selection.start : t.length;
                          contentCtrl.text = t.replaceRange(idx, idx, '{$v}');
                          contentCtrl.selection = TextSelection.collapsed(offset: idx + '{$v}'.length);
                          cfg.content = contentCtrl.text;
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                // 模板操作 + 预览
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('另存为新模板'),
                      onPressed: () async {
                        final ctrl = TextEditingController(text: '${cfg.name} 副本');
                        final newName = await showDialog<String>(
                          context: ctx,
                          builder: (c3) => AlertDialog(
                            title: const Text('另存为新模板'),
                            content: TextField(
                              autofocus: true,
                              controller: ctrl,
                              decoration: const InputDecoration(labelText: '模板名'),
                              onSubmitted: (v) => Navigator.pop(c3, v.trim()),
                            ),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(c3), child: const Text('取消')),
                              FilledButton(
                                onPressed: () => Navigator.pop(c3, ctrl.text.trim()),
                                child: const Text('保存'),
                              ),
                            ],
                          ),
                        );
                        if (newName == null || newName.isEmpty) return;
                        setDlg(() {
                          cfg.name = newName;
                          nameCtrl.text = newName;
                          _upsertTemplate(cfg);
                          _saveTemplates();
                        });
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('删除'),
                      onPressed: () {
                        final wasBuiltin = cfg.name == '标准' || cfg.name == '旬段汇总';
                        setDlg(() {
                          if (wasBuiltin) {
                            toast(ctx, '内置模板不可删除');
                          } else {
                            _deleteTemplate(cfg.name);
                            _saveTemplates();
                            cfg = _templates.first.copy();
                            nameCtrl.text = cfg.name;
                            titleCtrl.text = cfg.title;
                            contentCtrl.text = cfg.content;
                          }
                        });
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.visibility_outlined, size: 16),
                      label: const Text('预览'),
                      onPressed: () {
                        // 网格模板优先（Excel 式：变量替换+对齐）；否则正文文本/结构化表格
                        final useGrid = _templateRows(cfg, clientName) != null; // 组件/网格模板优先
                        final contentLines = !useGrid && cfg.content.trim().isNotEmpty
                            ? _renderContentLines(cfg.content, clientName)
                            : null;
                        showDialog<void>(
                          context: ctx,
                          builder: (c2) => AlertDialog(
                            title: Text('预览：${cfg.name}'),
                            content: SizedBox(
                              width: 460,
                              child: useGrid
                                  ? _gridPreview(cfg, clientName)
                                  : contentLines != null
                                      ? SingleChildScrollView(
                                          child: Text(contentLines.join('\n'),
                                              style: const TextStyle(fontSize: 12, height: 1.7)),
                                        )
                                      : _previewTable(cfg, clientName),
                            ),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(c2), child: const Text('关闭')),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.grid_on_outlined, size: 16),
                      label: const Text('网格模板'),
                      onPressed: () => _gridEditorDialog(ctx, cfg, clientName),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.widgets_outlined, size: 16),
                      label: const Text('组件模板'),
                      onPressed: () => _compEditorDialog(ctx, cfg, clientName),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存并导出')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    cfg.title = titleCtrl.text.trim().isEmpty ? '对账单' : titleCtrl.text.trim();
    _xls = cfg;
    _upsertTemplate(cfg);
    await _saveTemplates();
    final excel = _buildExcel(cfg, clientName);
    final bytes = excel.encode();
    if (bytes == null) {
      toast(context, '导出失败，请重试');
      return;
    }
    // 导出前版式预览确认（网格模板优先，所见即所得）
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出预览'),
        content: SizedBox(
          width: 460,
          child: _templateRows(cfg, clientName) != null
              ? _gridPreview(cfg, clientName)
              : _previewTable(cfg, clientName),
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

  /// 按排版配置生成 Excel：网格模板优先（每格变量替换后逐行写入），否则标题 + 可选表头信息行 + 明细（三种粒度）
  Excel _buildExcel(_XlsCfg cfg, String clientName) {
    final excel = Excel.createExcel();
    // 复用默认空 sheet 并改名，避免多余的 Sheet1（v0.17.142：导出只留一个"对账单"页）
    excel.rename('Sheet1', '对账单'); // excel 4.x rename 直接改名（返回 void），默认 sheet 恒存在
    final sheet = excel['对账单'];
    // 组件/网格模板：统一渲染入口，每格变量替换后逐行写入（内容与预览/打印同源；对齐样式后续补 cellStyle）
    final trows = _templateRows(cfg, clientName);
    if (trows != null) {
      for (final row in trows) {
        sheet.appendRow([for (final c in row) TextCellValue(c.text)]);
      }
      return excel;
    }
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
      case 'period':
        _sheetPeriod(sheet, cfg);
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

  /// 读取本机模板列表（含上次选中的模板）；无记录时用内置模板兜底（标准 + 旬段汇总）
  Future<void> _loadTemplates() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('taozhu_stmt_templates');
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(_XlsCfg.fromJson)
            .toList();
        if (list.isNotEmpty) {
          _templates = list;
          final last = p.getString('taozhu_stmt_xls_name') ?? '';
          _xls = _templates.where((t) => t.name == last).firstOrNull?.copy() ?? _templates.first.copy();
          return;
        }
      }
    } catch (_) {}
    // 兼容旧版单模板存储（v0.17.140 之前：taozhu_stmt_xls_cfg）
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('taozhu_stmt_xls_cfg');
      if (raw != null && raw.isNotEmpty) {
        _xls = _XlsCfg.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {}
    // 内置兜底模板
    _templates = [_xls.copy()..name = '标准', _periodTemplate()];
  }

  /// 内置旬段汇总模板（1-10 / 11-20 / 21-30 / 31 日 8 列 + 总计）
  _XlsCfg _periodTemplate() => _XlsCfg()
    ..name = '旬段汇总'
    ..title = '销售月报'
    ..mode = 'period';

  /// 当前模板合并回列表（修改/另存共用）：同名覆盖，否则追加
  void _upsertTemplate(_XlsCfg cfg) {
    final i = _templates.indexWhere((t) => t.name == cfg.name);
    if (i >= 0) {
      _templates[i] = cfg.copy();
    } else {
      _templates.add(cfg.copy());
    }
  }

  /// 删除模板（内置不可删）
  void _deleteTemplate(String name) {
    if (name == '标准' || name == '旬段汇总') return;
    _templates.removeWhere((t) => t.name == name);
  }

  /// 保存模板列表 + 当前选中模板名到本机
  Future<void> _saveTemplates() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('taozhu_stmt_templates', jsonEncode([for (final t in _templates) t.toJson()]));
      await p.setString('taozhu_stmt_xls_name', _xls.name);
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

  /// 该月每天销售额（1日→月末逐日，无数据日=0）——旬段模板实为按日展开，非段合计
  List<double> _salesByDayOfMonth() {
    final from = _fromCtrl.text.trim();
    final y = int.tryParse(from.length >= 7 ? from.substring(0, 4) : '') ?? DateTime.now().year;
    final m = int.tryParse(from.length >= 7 ? from.substring(5, 7) : '') ?? DateTime.now().month;
    final daysInMonth = DateTime(y, m + 1, 0).day;
    final arr = List<double>.filled(daysInMonth, 0);
    for (final s in _sales) {
      final orderDate = _date(s['happened_at']);
      for (final it in ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>()) {
        final id = '${it['happened_at'] ?? ''}';
        final d = id.length >= 10 ? id.substring(0, 10) : orderDate;
        if (d.length < 10) continue;
        // 仅统计账期月份内的行（跨月账期忽略非本月行）
        final dy = int.tryParse(d.substring(0, 4)) ?? 0;
        final dm = int.tryParse(d.substring(5, 7)) ?? 0;
        if (dy != y || dm != m) continue;
        final day = int.tryParse(d.substring(8, 10)) ?? 1;
        if (day < 1 || day > daysInMonth) continue;
        arr[day - 1] += (it['amount'] as num?)?.toDouble() ?? 0;
      }
    }
    return arr;
  }

  /// 旬段汇总表（Excel）：按实际日期逐日展开（1日、2日、…月末，每天一行日期+销售额，无数据日=0）+ 总计
  void _sheetPeriod(Sheet sheet, _XlsCfg cfg) {
    sheet.appendRow([TextCellValue('日期'), TextCellValue('销售额')]);
    final daily = _salesByDayOfMonth();
    double total = 0;
    for (var i = 0; i < daily.length; i++) {
      final v = daily[i];
      total += v;
      sheet.appendRow([TextCellValue('${i + 1}日'), TextCellValue('¥${v.toStringAsFixed(2)}')]);
    }
    sheet.appendRow([TextCellValue('总计'), TextCellValue('¥${total.toStringAsFixed(2)}')]);
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

  /// 模板统一渲染入口（组件 → 网格 → null；null 时用正文/结构化渲染）
  List<List<_GridCell>>? _templateRows(_XlsCfg cfg, String clientName) {
    if (cfg.comps.isNotEmpty) return _renderComps(cfg, clientName);
    if (cfg.grid.isNotEmpty) return _renderGrid(cfg, clientName);
    return null;
  }

  /// 网格/组件模板预览（Excel 式：变量替换后按对齐渲染，所见即所得）
  Widget _gridPreview(_XlsCfg cfg, String clientName) {
    final rows = _templateRows(cfg, clientName) ?? [];
    return SingleChildScrollView(
      child: Table(
        border: TableBorder.all(color: Colors.black26, width: 0.5),
        defaultColumnWidth: const IntrinsicColumnWidth(),
        children: [
          for (final row in rows)
            TableRow(children: [
              for (final c in row)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Text(c.text,
                      textAlign: _alignOf(c.align), style: const TextStyle(fontSize: 11)),
                ),
            ]),
        ],
      ),
    );
  }

  static TextAlign _alignOf(String a) =>
      a == 'center' ? TextAlign.center : (a == 'right' ? TextAlign.right : TextAlign.left);

  static IconData _alignIcon(String a) =>
      a == 'center' ? Icons.format_align_center : (a == 'right' ? Icons.format_align_right : Icons.format_align_left);

  /// Excel 式网格模板编辑器：行列可调、每格可放变量（{店铺}…{明细}、{1日}…{31日}）+ 对齐（左/中/右），实时预览
  Future<void> _gridEditorDialog(BuildContext ctx, _XlsCfg cfg, String clientName) async {
    if (cfg.grid.isEmpty) {
      cfg.grid = [
        [_GridCell('对账单', 'center'), _GridCell(), _GridCell()],
        [_GridCell('店铺：{店铺}'), _GridCell(), _GridCell()],
        [_GridCell('账期：{账期}'), _GridCell(), _GridCell()],
      ];
    }
    final ctrls = <String, TextEditingController>{};
    TextEditingController ctrlFor(int r, int c) =>
        ctrls.putIfAbsent('$r-$c', () => TextEditingController(text: cfg.grid[r][c].text));
    var focusR = 0, focusC = 0;
    final genVars = const ['店铺', '账期', '日期', '出货合计', '收款合计', '期末欠款', '出货笔数', '明细', '旬段表'];
    await showDialog<void>(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDlg) {
          final rows = cfg.grid.length;
          final cols = cfg.grid.isEmpty ? 0 : cfg.grid[0].length;
          // 补齐矩形（初始/加列后各行等列数）
          for (final r in cfg.grid) {
            while (r.length < cols) r.add(_GridCell());
          }
          void insertVar(String v) {
            final cell = cfg.grid[focusR][focusC];
            cell.text += v;
            ctrlFor(focusR, focusC).text = cell.text;
          }
          return AlertDialog(
            title: const Text('网格模板编辑'),
            scrollable: true,
            content: SizedBox(
              width: 620,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(spacing: 6, children: [
                    OutlinedButton.icon(
                        icon: const Icon(Icons.add, size: 14), label: const Text('加行'),
                        onPressed: () => setDlg(() => cfg.grid.add([for (var c = 0; c < cols; c++) _GridCell()]))),
                    OutlinedButton.icon(
                        icon: const Icon(Icons.remove, size: 14), label: const Text('删行'),
                        onPressed: rows > 1 ? () => setDlg(() => cfg.grid.removeLast()) : null),
                    OutlinedButton.icon(
                        icon: const Icon(Icons.playlist_add, size: 14), label: const Text('加列'),
                        onPressed: () => setDlg(() { for (final r in cfg.grid) r.add(_GridCell()); })),
                    OutlinedButton.icon(
                        icon: const Icon(Icons.playlist_remove, size: 14), label: const Text('删列'),
                        onPressed: cols > 1 ? () => setDlg(() { for (final r in cfg.grid) r.removeLast(); }) : null),
                    const SizedBox(width: 8),
                    Text('点击格子选中，再插入变量/切对齐', style: TextStyle(fontSize: 11, color: _c.textSub)),
                  ]),
                  const SizedBox(height: 6),
                  // 变量插入（通用 + 按日 1-31，插入到选中格）
                  Wrap(spacing: 4, runSpacing: 2, children: [
                    for (final v in genVars)
                      ActionChip(
                        label: Text('{$v}', style: const TextStyle(fontSize: 10)),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setDlg(() => insertVar('{$v}')),
                      ),
                    ActionChip(
                      label: const Text('{N日}', style: TextStyle(fontSize: 10)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () async {
                        final day = await showDialog<int>(
                          context: dctx,
                          builder: (c3) => SimpleDialog(
                            title: const Text('插入日期变量（该日销售额）'),
                            children: [
                              for (var d = 1; d <= 31; d++)
                                SimpleDialogOption(
                                  onPressed: () => Navigator.pop(c3, d),
                                  child: Text('{$d日}', style: const TextStyle(fontSize: 13)),
                                ),
                            ],
                          ),
                        );
                        if (day != null && day >= 1) setDlg(() => insertVar('{$day日}'));
                      },
                    ),
                    OutlinedButton.icon(
                        icon: const Icon(Icons.visibility_outlined, size: 14), label: const Text('预览'),
                        onPressed: () => showDialog<void>(
                            context: dctx,
                            builder: (c3) => AlertDialog(
                                title: Text('预览：${cfg.name}'),
                                content: SizedBox(width: 580, child: _gridPreview(cfg, clientName)),
                                actions: [TextButton(onPressed: () => Navigator.pop(c3), child: const Text('关闭'))]))),
                  ]),
                  const SizedBox(height: 8),
                  // 网格编辑表格：每格输入 + 对齐切换（点击格子选中后插入变量）
                  SingleChildScrollView(
                    child: Table(
                      border: TableBorder.all(color: Colors.black26, width: 0.5),
                      defaultColumnWidth: const IntrinsicColumnWidth(),
                      children: [
                        for (var r = 0; r < rows; r++)
                          TableRow(children: [
                            for (var c = 0; c < cfg.grid[r].length; c++)
                              Padding(
                                padding: const EdgeInsets.all(2),
                                child: TextField(
                                  key: ValueKey('g-$r-$c'),
                                  controller: ctrlFor(r, c),
                                  style: const TextStyle(fontSize: 12),
                                  onTap: () => setDlg(() { focusR = r; focusC = c; }),
                                  onChanged: (v) => cfg.grid[r][c].text = v,
                                  decoration: InputDecoration(
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                    border: const OutlineInputBorder(),
                                    suffixIcon: IconButton(
                                      iconSize: 14,
                                      padding: EdgeInsets.zero,
                                      tooltip: '切换对齐（左/中/右）',
                                      icon: Icon(_alignIcon(cfg.grid[r][c].align), size: 14, color: _c.primary),
                                      onPressed: () => setDlg(() {
                                        cfg.grid[r][c].align = cfg.grid[r][c].align == 'left'
                                            ? 'center'
                                            : (cfg.grid[r][c].align == 'center' ? 'right' : 'left');
                                      }),
                                    ),
                                  ),
                                ),
                              ),
                          ]),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dctx), child: const Text('完成')),
            ],
          );
        },
      ),
    );
  }

  /// 组件式模板编辑器：添加/排序/配置组件（title/fields/stats/days/detail/text）+ 实时预览
  Future<void> _compEditorDialog(BuildContext ctx, _XlsCfg cfg, String clientName) async {
    const typeNames = <String, String>{
      'title': '标题', 'fields': '信息字段', 'stats': '统计',
      'days': '按日金额表（1-31）', 'detail': '出货明细', 'text': '自定义文本',
    };
    if (cfg.comps.isEmpty) {
      cfg.comps = [
        _TmplComp(type: 'title', text: '对账单', align: 'center'),
        _TmplComp(type: 'fields'),
        _TmplComp(type: 'days'),
      ];
    }
    await showDialog<void>(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDlg) {
          void move(int i, int delta) {
            final ni = i + delta;
            if (ni < 0 || ni >= cfg.comps.length) return;
            final t = cfg.comps.removeAt(i);
            cfg.comps.insert(ni, t);
          }
          Future<void> addComp() async {
            final type = await showDialog<String>(
              context: dctx,
              builder: (c3) => SimpleDialog(
                title: const Text('添加组件'),
                children: [
                  for (final e in typeNames.entries)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(c3, e.key),
                      child: Text(e.value, style: const TextStyle(fontSize: 14)),
                    ),
                ],
              ),
            );
            if (type == null) return;
            setDlg(() => cfg.comps.add(_TmplComp(type: type)));
          }
          Future<void> config(int i) async {
            final c = cfg.comps[i];
            final textCtrl = TextEditingController(text: c.text);
            var align = c.align;
            await showDialog<void>(
              context: dctx,
              builder: (c4) => StatefulBuilder(
                builder: (c4, setC) => AlertDialog(
                  title: Text('配置：${typeNames[c.type] ?? c.type}'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (c.type == 'text' || c.type == 'title')
                      TextField(
                        controller: textCtrl,
                        maxLines: 3,
                        decoration: const InputDecoration(labelText: '内容（可含变量 {店铺}{明细}{1日}…）'),
                      ),
                    Wrap(spacing: 4, children: [
                      for (final a in const ['left', 'center', 'right'])
                        ChoiceChip(
                          label: Text(a == 'left' ? '左' : a == 'center' ? '中' : '右'),
                          selected: align == a,
                          onSelected: (_) => setC(() => align = a),
                        ),
                    ]),
                  ]),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c4), child: const Text('取消')),
                    FilledButton(
                      onPressed: () {
                        c.text = textCtrl.text;
                        c.align = align;
                        Navigator.pop(c4);
                      },
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ),
            );
            setDlg(() {});
          }
          return AlertDialog(
            title: const Text('组件模板编辑'),
            scrollable: true,
            content: SizedBox(
              width: 430,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 6, runSpacing: 4, children: [
                  OutlinedButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('添加组件'), onPressed: addComp),
                  OutlinedButton.icon(
                      icon: const Icon(Icons.visibility_outlined, size: 16), label: const Text('预览'),
                      onPressed: () => showDialog<void>(
                          context: dctx,
                          builder: (c3) => AlertDialog(
                              title: Text('预览：${cfg.name}'),
                              content: SizedBox(width: 580, child: _gridPreview(cfg, clientName)),
                              actions: [TextButton(onPressed: () => Navigator.pop(c3), child: const Text('关闭'))]))),
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('组件按顺序渲染：点条目配置、↑↓排序、×删除', style: TextStyle(fontSize: 11, color: _c.textSub)),
                  ),
                ]),
                const SizedBox(height: 4),
                for (var i = 0; i < cfg.comps.length; i++)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                        color: _c.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: _c.divider)),
                    child: Row(children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => config(i),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${i + 1}. ${typeNames[cfg.comps[i].type] ?? cfg.comps[i].type}',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _c.textMain)),
                            if (cfg.comps[i].text.isNotEmpty)
                              Text('${cfg.comps[i].text}', maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11, color: _c.textSub)),
                          ]),
                        ),
                      ),
                      IconButton(iconSize: 18, icon: const Icon(Icons.arrow_upward), onPressed: () => setDlg(() => move(i, -1))),
                      IconButton(iconSize: 18, icon: const Icon(Icons.arrow_downward), onPressed: () => setDlg(() => move(i, 1))),
                      IconButton(iconSize: 18, icon: const Icon(Icons.close), onPressed: () => setDlg(() => cfg.comps.removeAt(i))),
                    ]),
                  ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dctx), child: const Text('完成')),
            ],
          );
        },
      ),
    );
  }

/// 版式预览（所见即所得）：标题居中 + 表头信息行 + 明细表格 + 总计——与导出/打印同源排版
  Widget _previewTable(_XlsCfg cfg, String clientName) {
    final infoRows = <String>[
      if (cfg.headClient) '客户：$clientName',
      if (cfg.headPeriod) '账期：${_fromCtrl.text.trim()} 至 ${_toCtrl.text.trim()}',
      if (cfg.headSaleTotal) '出货合计：¥${_saleTotal.toStringAsFixed(2)}（${_sales.length} 笔）',
      if (cfg.headPayTotal) '收款合计：¥${_payTotal.toStringAsFixed(2)}（${_payments.length} 笔）',
      if (cfg.headDebt) '期末欠款：¥${_debtEnd.toStringAsFixed(2)}',
    ];
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Text(cfg.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 6),
          for (final r in infoRows) Text(r, style: const TextStyle(fontSize: 12)),
          if (infoRows.isNotEmpty) const SizedBox(height: 8),
          _previewTableBody(cfg),
        ],
      ),
    );
  }

  /// 明细表格主体（按模板模式）：逐行明细 / 按日汇总 / 按商品汇总 / 旬段汇总
  Widget _previewTableBody(_XlsCfg cfg) {
    final textStyle = const TextStyle(fontSize: 11);
    final headStyle = const TextStyle(fontSize: 11, fontWeight: FontWeight.w700);
    TableRow row(List<String> cells, {bool head = false}) => TableRow(
          children: [
            for (final t in cells)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(t, style: head ? headStyle : textStyle),
              ),
          ],
        );
    final rows = <TableRow>[];
    if (cfg.mode == 'period') {
      // 按实际日期逐日展开（1日、2日…月末，每天一行，无数据日=0）
      rows.add(row(['日期', '销售额'], head: true));
      final daily = _salesByDayOfMonth();
      double total = 0;
      for (var i = 0; i < daily.length; i++) {
        final v = daily[i];
        total += v;
        rows.add(row(['${i + 1}日', '¥${v.toStringAsFixed(2)}']));
      }
      rows.add(row(['总计', '¥${total.toStringAsFixed(2)}']));
    } else if (cfg.mode == 'daily') {
      rows.add(row(['日期', '金额'], head: true));
      final byDay = _salesByDay();
      final days = byDay.keys.toList()..sort();
      var shown = 0;
      for (final d in days) {
        if (shown >= 14) break;
        rows.add(row([d, '¥${(byDay[d] ?? 0).toStringAsFixed(2)}']));
        shown++;
      }
      if (days.length > 14) rows.add(row(['… 共 ${days.length} 天', '']));
      rows.add(row(['销售总额', '¥${byDay.values.fold<double>(0, (a, b) => a + b).toStringAsFixed(2)}']));
    } else if (cfg.mode == 'item') {
      rows.add(row([if (cfg.colItem) '商品', if (cfg.colQty) '数量', if (cfg.colAmount) '金额'], head: true));
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
      var shown = 0;
      for (final e in agg.entries) {
        if (shown >= 14) break;
        rows.add(row([
          if (cfg.colItem) e.key,
          if (cfg.colQty) e.value.qty.toStringAsFixed(1),
          if (cfg.colAmount) '¥${e.value.amount.toStringAsFixed(2)}',
        ]));
        shown++;
      }
      if (agg.length > 14) rows.add(row(['… 共 ${agg.length} 种商品', '', '']));
      rows.add(row([
        if (cfg.colItem) '合计',
        if (cfg.colQty) '',
        if (cfg.colAmount) '¥${agg.values.fold<double>(0, (a, b) => a + b.amount).toStringAsFixed(2)}',
      ]));
    } else {
      final cols = _detailCols(cfg);
      rows.add(row(cols, head: true));
      var shown = 0;
      for (final s in _sales) {
        if (shown >= 10) break;
        final orderDate = _date(s['happened_at']);
        final items = (s['items'] as List? ?? []).cast<Map<String, dynamic>>();
        if (items.isEmpty) {
          rows.add(row([
            if (cfg.colDate) orderDate,
            if (cfg.colItem) '${s['note'] ?? ''}',
            if (cfg.colQty) '',
            if (cfg.colPrice) '',
            if (cfg.colAmount) '¥${((s['total'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}',
          ]));
          shown++;
        }
        for (final it in items) {
          if (shown >= 10) break;
          final id = '${it['happened_at'] ?? ''}';
          final d = id.length >= 10 ? id.substring(0, 10) : orderDate;
          rows.add(row([
            if (cfg.colDate) d,
            if (cfg.colItem) '${it['item_name']}',
            if (cfg.colQty) '${it['quantity']}${it['unit']}',
            if (cfg.colPrice) '¥${((it['sale_price'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}',
            if (cfg.colAmount) '¥${((it['amount'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}',
          ]));
          shown++;
        }
      }
      if (_sales.length > 10) rows.add(row(['… 共 ${_sales.length} 笔出货', '', '', '', '']));
      rows.add(row(['收款 ${_payments.length} 笔 · 期末欠款 ¥${_debtEnd.toStringAsFixed(2)}', '', '', '', '']));
    }
    return Table(
      border: TableBorder.all(color: Colors.black26, width: 0.5),
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: rows,
    );
  }

  /// 模板正文变量渲染（预览/导出/打印三端同源数据）：
  /// 单文本变量替换（正文/网格共用）：{店铺}{账期}{日期}{出货合计}{收款合计}{期末欠款}{出货笔数} + {1日}…{31日}按日
  String _replaceVars(String text, String clientName) {
    final now = DateTime.now();
    final today = '${now.year}年${now.month}月${now.day}日';
    var line = text
        .replaceAll('{店铺}', clientName)
        .replaceAll('{账期}', '${_fromCtrl.text.trim()} 至 ${_toCtrl.text.trim()}')
        .replaceAll('{日期}', today)
        .replaceAll('{出货合计}', '¥${_saleTotal.toStringAsFixed(2)}')
        .replaceAll('{收款合计}', '¥${_payTotal.toStringAsFixed(2)}')
        .replaceAll('{期末欠款}', '¥${_debtEnd.toStringAsFixed(2)}')
        .replaceAll('{出货笔数}', '${_sales.length}');
    final daily = _salesByDayOfMonth();
    for (var d = 1; d <= daily.length; d++) {
      line = line.replaceAll('{$d日}', '¥${daily[d - 1].toStringAsFixed(2)}');
    }
    return line;
  }

  /// 渲染网格模板（Excel 式：每格变量替换 + 对齐）——预览/导出/打印同源
  List<List<_GridCell>> _renderGrid(_XlsCfg cfg, String clientName) {
    return [
      for (final row in cfg.grid)
        [for (final c in row) _GridCell(_replaceVars(c.text, clientName), c.align)],
    ];
  }

  /// 渲染组件式模板（每个组件展开为表格行块；预览/导出/打印同源）
  List<List<_GridCell>> _renderComps(_XlsCfg cfg, String clientName) {
    final now = DateTime.now();
    final today = '${now.year}年${now.month}月${now.day}日';
    final rows = <List<_GridCell>>[];
    final daily = _salesByDayOfMonth();
    for (final c in cfg.comps) {
      switch (c.type) {
        case 'title':
          rows.add([_GridCell(_replaceVars(c.text.isEmpty ? '对账单' : c.text, clientName), c.align)]);
          break;
        case 'fields':
          rows.add([_GridCell('店铺：$clientName', 'left')]);
          rows.add([_GridCell('账期：${_fromCtrl.text.trim()} 至 ${_toCtrl.text.trim()}', 'left')]);
          rows.add([_GridCell('日期：$today', 'left')]);
          break;
        case 'stats':
          rows.add([
            _GridCell('出货合计\n¥${_saleTotal.toStringAsFixed(2)}', 'center'),
            _GridCell('收款合计\n¥${_payTotal.toStringAsFixed(2)}', 'center'),
            _GridCell('期末欠款\n¥${_debtEnd.toStringAsFixed(2)}', 'center'),
          ]);
          break;
        case 'days':
          rows.add([_GridCell('日期', 'center'), _GridCell('销售额', 'center')]);
          double total = 0;
          for (var i = 0; i < daily.length; i++) {
            final v = daily[i];
            total += v;
            rows.add([_GridCell('${i + 1}日', 'left'), _GridCell('¥${v.toStringAsFixed(2)}', 'right')]);
          }
          rows.add([_GridCell('总计', 'right'), _GridCell('¥${total.toStringAsFixed(2)}', 'right')]);
          break;
        case 'detail':
          rows.add([_GridCell('日期', 'center'), _GridCell('商品', 'center'), _GridCell('数量', 'center'), _GridCell('金额', 'center')]);
          for (final s in _sales) {
            final orderDate = _date(s['happened_at']);
            final items = ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>();
            if (items.isEmpty) {
              rows.add([
                _GridCell(orderDate, 'left'),
                _GridCell('${s['note'] ?? '（无明细）'}', 'left'),
                _GridCell('', 'left'),
                _GridCell('¥${((s['total'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}', 'right'),
              ]);
              continue;
            }
            for (final it in items) {
              final id = '${it['happened_at'] ?? ''}';
              final d = id.length >= 10 ? id.substring(0, 10) : orderDate;
              rows.add([
                _GridCell(d, 'left'),
                _GridCell('${it['item_name'] ?? ''}', 'left'),
                _GridCell('${it['quantity'] ?? ''}${it['unit'] ?? ''}', 'center'),
                _GridCell('¥${((it['amount'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}', 'right'),
              ]);
            }
          }
          break;
        default: // text：自定义文本（可含变量、可换行）
          for (final ln in _replaceVars(c.text, clientName).split('\n')) {
            rows.add([_GridCell(ln, c.align)]);
          }
      }
    }
    return rows;
  }

  /// 变量：{店铺}{账期}{日期}{出货合计}{收款合计}{期末欠款}{出货笔数}{明细}{旬段表}{1日}…{31日}
  /// 返回渲染后的逐行文本；{明细} 每件商品一行、{旬段表} 逐日汇总文本。
  List<String> _renderContentLines(String content, String clientName) {
    final out = <String>[];
    for (final raw in content.split('\n')) {
      var line = _replaceVars(raw, clientName);
      if (line.contains('{明细}')) {
        final items = _detailLines();
        line = line.replaceAll('{明细}',
            items.isEmpty ? '（本期无出货明细）' : items.join('\n'));
      }
      if (line.contains('{旬段表}')) {
        // 按实际日期逐日展开：1日 ¥x、2日 ¥y …（无数据日=0），末行总计
        final daily = _salesByDayOfMonth();
        double total = 0;
        final parts = <String>[];
        for (var i = 0; i < daily.length; i++) {
          total += daily[i];
          if (daily[i] != 0 || parts.isEmpty) {
            parts.add('${i + 1}日 ¥${daily[i].toStringAsFixed(2)}');
          }
        }
        parts.add('总计 ¥${total.toStringAsFixed(2)}');
        line = line.replaceAll('{旬段表}', parts.join('、'));
      }
      out.add(line);
    }
    return out;
  }

  /// 出货明细行（每件商品一行：日期 商品 数量单位 金额；无明细的单据补备注/占位）——{明细} 变量展开数据源
  List<String> _detailLines() {
    final out = <String>[];
    for (final s in _sales) {
      final orderDate = _date(s['happened_at']);
      final items = ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (items.isEmpty) {
        final note = '${s['note'] ?? ''}'.trim();
        out.add('$orderDate ${note.isEmpty ? '（无明细）' : note} '
            '¥${((s['total'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}');
        continue;
      }
      for (final it in items) {
        final id = '${it['happened_at'] ?? ''}';
        final d = id.length >= 10 ? id.substring(0, 10) : orderDate;
        out.add('$d ${it['item_name']} ${it['quantity']}${it['unit']} '
            '¥${((it['amount'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}');
      }
    }
    return out;
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
                    onChanged: (v) {
                      setState(() => _clientId = v);
                      _load(); // 切换店铺立即按新店铺重新拉取
                    },
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
            // 成品对账单（开箱即用）：样式 chips 切换 → 下方直接渲染模板成品，导出/打印同源
            const SizedBox(height: 12),
            const Text('对账单样式', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (final t in _pubTpls.isEmpty ? [XlsCfg()..name = '标准'] : _pubTpls)
                ChoiceChip(
                  label: Text(t.name, style: const TextStyle(fontSize: 12)),
                  selected: t.name == _selTplName,
                  onSelected: (_) => setState(() => _selTplName = t.name),
                ),
            ]),
            const SizedBox(height: 10),
            Card(
              elevation: 0,
              color: c.card,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: c.divider),
              ),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: _previewTplRows(renderTemplateRows(_curPubTpl, _td(clientNameForTpl))),
              ),
            ),
            if (_pubTpls.any((t) => t.name != _selTplName && t.name == '模板设置'))
              Text('样式不足？请在下方「自定义模板」微调', style: TextStyle(fontSize: 11, color: c.textSub)),
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
            // 出货明细 = 商品明细（每件商品一行，不再按"单"汇总店铺/日期/笔数/总额）
            for (final s in _sales)
              for (final it in ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>())
                Card(
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.sell_outlined, size: 20, color: _c.primary),
                    title: Text('${it['item_name'] ?? ''}'),
                    subtitle: Text(
                      '${_date(s['happened_at'])}'
                      '${_clientId == null && '${s['client_name'] ?? ''}'.isNotEmpty ? ' · ${s['client_name']}' : ''}'
                      ' · ${it['quantity'] ?? ''}${it['unit'] ?? ''} × ¥${(it['sale_price'] as num?)?.toStringAsFixed(2) ?? '-'}',
                    ),
                    trailing: Text('¥${(it['amount'] as num?)?.toStringAsFixed(2) ?? '-'}',
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
            // 导出 Excel（选模板 → 预览 → 导出；模板自定义在「模板设置」）
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _exportTpl,
              icon: const Icon(Icons.table_chart_outlined, size: 18),
              label: const Text('导出 Excel'),
            ),
            const SizedBox(height: 8),
            // 模板设置（独立页：组件/网格/正文模板新增、编辑、排序、预览）
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const StatementTemplatePage())),
              icon: const Icon(Icons.widgets_outlined, size: 18),
              label: const Text('模板设置'),
            ),
            const SizedBox(height: 8),
            // 打印（按当前模板：逐单明细/每日汇总/旬段汇总 → 服务端渲染）
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _printCurrent,
              icon: const Icon(Icons.print_outlined, size: 18),
              label: const Text('打印（按当前模板）'),
            ),
          ],
        ],
      ),
    );
  }

  /// 按当前样式打印（对账单统一打印入口）：渲染当前选中模板行集合 → base64 编码 → 服务端 /print/template 按其排版输出
  Future<void> _printCurrent() async {
    if (!_loaded) {
      toast(context, '请先生成对账单');
      return;
    }
    final clientName = clientNameForTpl.isEmpty ? '全部店铺' : clientNameForTpl;
    final trows = renderTemplateRows(_curPubTpl, _td(clientName));
    final rowsJson = jsonEncode([
      for (final row in trows) [for (final c in row) [c.text, c.align, c.bold, c.bg]],
    ]);
    final rowsB64 = base64Url.encode(utf8.encode(rowsJson));
    final title = Uri.encodeQueryComponent('$clientName 对账单');
    try {
      final base = await Api.instance.getBase();
      final token = await Api.instance.getTokenValue() ?? '';
      final cid = _clientId ?? '';
      await openPrintUrl('$base/api/v1/print/template?title=$title&rows=$rowsB64&token=$token&client_id=$cid');
    } catch (e) {
      toast(context, '打印打开失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
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

/// 对账单排版模板（前端自定义，本机持久化）：标题/表头信息行/明细粒度/明细列
/// mode：detail=逐行明细 | daily=按日汇总 | item=按商品汇总 | period=旬段汇总（1-10/11-20/21-30/31 日 8 列）
/// 网格单元格：文本（可含 {变量} 占位，如 {店铺}、{1日}…{31日}）+ 对齐（left/center/right）
class _GridCell {
  _GridCell([this.text = '', this.align = 'left']);
  String text;
  String align;
  Map<String, dynamic> toJson() => {'t': text, 'a': align};
  _GridCell.fromJson(Map<String, dynamic> j)
      : text = '${j['t'] ?? ''}',
        align = '${j['a'] ?? 'left'}';
}

/// 对账单模板组件（组件式设计器）：按顺序渲染成表格块，预览/导出/打印同源
/// type：title=标题 | fields=信息字段（店铺/账期/日期）| stats=统计（出货/收款/欠款）
///       days=按日金额表（1-31 日逐行，自动当月天数）| detail=出货明细表 | text=自定义文本（可含变量）
class _TmplComp {
  _TmplComp({this.type = 'text', this.text = '', this.align = 'left'});
  String type;
  String text;
  String align; // left | center | right
  Map<String, dynamic> toJson() => {'t': type, 'x': text, 'a': align};
  _TmplComp.fromJson(Map<String, dynamic> j)
      : type = '${j['t'] ?? 'text'}',
        text = '${j['x'] ?? ''}',
        align = '${j['a'] ?? 'left'}';
}

class _XlsCfg {
  _XlsCfg();

  String name = '标准';
  String title = '陶朱对账单';
  /// 模板正文（自由编排，支持变量占位：{店铺}{账期}{日期}{出货合计}{收款合计}{期末欠款}{出货笔数}{明细}{旬段表}{1日}…{31日}）；
  /// 空 = 用下方结构化字段（表头信息行/明细粒度/明细列）生成
  String content = '';
  /// Excel 式网格模板（行×列单元格，每格可放变量 + 对齐；非空时优先于 content/结构化渲染）
  List<List<_GridCell>> grid = [];
  /// 组件式模板（有序组件列表：title/fields/stats/days/detail/text；非空时优先于 grid/content 渲染）
  List<_TmplComp> comps = [];
  bool headClient = true;
  bool headPeriod = true;
  bool headSaleTotal = true;
  bool headPayTotal = true;
  bool headDebt = true;
  String mode = 'detail'; // detail | daily | item | period
  bool colDate = true;
  bool colItem = true;
  bool colQty = true;
  bool colPrice = true;
  bool colAmount = true;

  Map<String, dynamic> toJson() => {
        'name': name,
        'title': title,
        'content': content,
        'grid': [
          for (final row in grid) [for (final c in row) c.toJson()],
        ],
        'comps': [for (final c in comps) c.toJson()],
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
    name = '${j['name'] ?? '标准'}';
    title = '${j['title'] ?? '陶朱对账单'}';
    content = '${j['content'] ?? ''}';
    final rawGrid = j['grid'];
    if (rawGrid is List) {
      grid = [
        for (final row in rawGrid)
          [
            for (final c in (row as List? ?? []))
              if (c is Map) _GridCell.fromJson(Map<String, dynamic>.from(c)),
          ],
      ];
    }
    final rawComps = j['comps'];
    if (rawComps is List) {
      comps = [
        for (final c in rawComps)
          if (c is Map) _TmplComp.fromJson(Map<String, dynamic>.from(c)),
      ];
    }
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