import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'router.dart';
import 'clients_page.dart';
import 'sale_page.dart';
import 'payments_page.dart';
import 'attachment_viewer.dart';

/// 交易（账本=店铺）：出货 / 收款流水，按店铺+时间范围，支持编辑删除与附件（按日期分组列表）
class LedgerPage extends StatefulWidget {
  const LedgerPage({super.key});
  @override
  State<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends State<LedgerPage> {
  List<Map<String, dynamic>> _sales = [];
  List<Map<String, dynamic>> _payments = [];
  List<Map<String, dynamic>> _clients = [];
  String? _clientId; // 账本（店铺）维度：必选，默认第一个；无店铺时自动建「默认店铺」
  String _range = 'month'; // month | 2m | 3m | all
  bool _isStaff = false; // 店员账号：仅当天出货视角
  bool _loading = true;
  bool _offline = false; // 本次加载走了本地缓存（无网络）

  @override
  void initState() {
    super.initState();
    // 店员账号：仅当天出货视角（后端强制当天）
    Api.instance.getRole().then((r) {
      if (mounted) setState(() => _isStaff = r == 'staff');
    });
    // 同步完成后本地库变了 → 重新从本地读（本地优先，网络静默）
    SyncService.version.addListener(_onSync);
    _load();
  }

  @override
  void dispose() {
    SyncService.version.removeListener(_onSync);
    super.dispose();
  }

  void _onSync() {
    if (mounted) _load();
  }

  static String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 时间范围 → (起始, 结束)；all 返回 null（不限日期）
  (String, String)? _rangeDates() {
    final now = DateTime.now();
    switch (_range) {
      case '2m':
        return (_fmtDate(DateTime(now.year, now.month - 2, now.day)), _fmtDate(now));
      case '3m':
        return (_fmtDate(DateTime(now.year, now.month - 3, now.day)), _fmtDate(now));
      case 'all':
        return null;
      default:
        return (_fmtDate(DateTime(now.year, now.month, 1)), _fmtDate(now));
    }
  }

  String _dateQuery() => ''; // （进货独立 tab，本页不再使用）

  /// 出货/收款查询：账本（店铺）必选 + 时间范围；进货不按店铺（仅时间范围）
  String _clientQuery() {
    final r = _rangeDates();
    final params = <String>[];
    if (_clientId != null) params.add('client_id=$_clientId');
    if (r != null) {
      params.add('date_from=${r.$1}');
      params.add('date_to=${r.$2}');
    }
    return params.isEmpty ? '' : '?${params.join('&')}';
  }

  /// 本地优先加载：① 读本地库镜像（按当前店铺+范围过滤）立即展示——有就秒开，空就显示空态；
  /// ② 触发后台同步（SyncService 完成后 version 通知会再来 _load 一次）；③ 网络刷新静默合并写库。
  /// 页面不因网络慢而空白/转圈。
  Future<void> _load() async {
    final firstLocal = await LocalDb.getAllByName('clients');
    var sales = await LocalDb.getAll('sales');
    var payments = await LocalDb.getAll('payments');
    if (_clientId == null && firstLocal.isNotEmpty) {
      // 恢复上次选择的店铺（而非每次默认第一个）；店铺被删则回落第一个
      final saved = await SyncService.selectedClientId();
      _clientId = saved != null && firstLocal.any((c) => '${c['id']}' == saved)
          ? saved
          : '${firstLocal.first['id']}';
      await SyncService.saveSelectedClientId(_clientId!);
    }
    if (_clientId != null) {
      sales = _filterByClient(sales, _clientId!);
      payments = _filterByClient(payments, _clientId!);
    }
    if (mounted) {
      setState(() {
        _clients = firstLocal;
        _sales = sales;
        _payments = payments;
        _loading = false;
        _offline = false;
      });
    }
    // 网络刷新（静默）：慢/失败不阻塞展示，失败时本地数据已展示
    try {
      final cr = await Api.instance.get('/clients');
      var clients = ((cr['clients'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (clients.isEmpty) clients = [await Api.instance.post('/clients', {'name': '默认店铺'})];
      if (!mounted) return;
      if (_clientId == null || !clients.any((c) => '${c['id']}' == _clientId)) {
        // 已选店铺不存在（被删）→ 恢复上次选择，否则取第一个
        final saved = await SyncService.selectedClientId();
        _clientId = saved != null && clients.any((c) => '${c['id']}' == saved)
            ? saved
            : '${clients.first['id']}';
        await SyncService.saveSelectedClientId(_clientId!);
      }
      final results = await Future.wait([
        Api.instance.get('/sales${_clientQuery()}'),
        Api.instance.get('/payments${_clientQuery()}'),
      ]);
      if (!mounted) return;
      final netSales = ((results[0]['sales'] as List?) ?? []).cast<Map<String, dynamic>>();
      final netPays = ((results[1]['payments'] as List?) ?? []).cast<Map<String, dynamic>>();
      // 镜像写库（增量 upsert，不删本地未推送的单）
      await Future.wait([
        LocalDb.upsertList('clients', clients),
        LocalDb.upsertList('sales', netSales),
        LocalDb.upsertList('payments', netPays),
      ]);
      if (!mounted) return;
      setState(() {
        _clients = clients;
        _sales = _filterByClient(netSales, _clientId!);
        _payments = _filterByClient(netPays, _clientId!);
        _loading = false;
        _offline = false;
      });
    } catch (_) {
      // 网络失败不打扰（本地数据已展示）；本地无数据时标记离线态（不弹提示，错误已记日志）
      if (mounted && firstLocal.isEmpty) {
        setState(() => _offline = true);
      }
    }
  }

  /// 明细行日期与该单日期不同时的前缀标注（如 "9/12 白菜 ×2斤"）
  String _itemDateLabel(Map<String, dynamic> order, Map<String, dynamic> it) {
    final od = _date(order['happened_at']);
    final id = '${it['happened_at'] ?? ''}';
    if (id.length >= 10 && id.substring(0, 10) != od) {
      final d = id.substring(5, 10).replaceAll('-', '/');
      return '$d ';
    }
    return '';
  }

  String _date(Object? v) {
    final s = '$v';
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  /// 本地记录按当前店铺 + 时间范围过滤（与网络接口一致；范围空则不筛日期）
  List<Map<String, dynamic>> _filterByClient(List<Map<String, dynamic>> rows, String clientId) {
    final r = _rangeDates();
    return rows.where((x) {
      if ('${x['client_id']}' != clientId) return false;
      if (r != null) {
        final d = _date(x['happened_at']);
        if (d.isEmpty) return false;
        if (d.compareTo(r.$1) < 0 || d.compareTo(r.$2) > 0) return false;
      }
      return true;
    }).toList();
  }

  /// 账本选择弹层：全部店铺（名称 + 交易笔数 + 欠款），底部管理店铺
  Future<void> _showLedgerPicker() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('选择店铺（账本）', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  // 按店铺分类分组（食堂/档口等）：分类标题 + 组内店铺
                  ..._clientGroups().entries.map((g) => [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                          child: Text(g.key,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Theme.of(context).extension<TaozhuColors>()!.textSub,
                              )),
                        ),
                        for (final c in g.value)
                          _storeTile(ctx, c),
                      ]).expand((x) => x),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add_business_outlined, color: Color(0xFF409EFF)),
              title: const Text('新增店铺'),
              onTap: () {
                Navigator.pop(ctx);
                _addClientQuick();
              },
            ),
            ListTile(
              leading: const Icon(Icons.manage_search_outlined, color: Color(0xFF409EFF)),
              title: const Text('管理店铺（账本）'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const ClientsPage()))
                    .then((_) => _load());
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected != null && selected != _clientId) {
      setState(() => _clientId = selected);
      SyncService.saveSelectedClientId(selected);
      _load();
    }
  }

  /// 店铺按分类分组（食堂/档口等；未分类归入"未分类"）
  Map<String, List<Map<String, dynamic>>> _clientGroups() {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final c in _clients) {
      final cn = '${c['category_name'] ?? ''}'.trim();
      (grouped[cn.isEmpty ? '未分类' : cn] ??= []).add(c);
    }
    return grouped;
  }

  Widget _storeTile(BuildContext ctx, Map<String, dynamic> c) {
    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: const Color(0xFF409EFF).withOpacity(0.12),
        child: const Icon(Icons.storefront, size: 18, color: Color(0xFF409EFF)),
      ),
      title: Text('${c['name']}',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      subtitle: _isStaff
          ? null // 店员不显示交易笔数/欠款（经营数据）
          : Text(
              '交易 ${(((c['sale_count'] as num?) ?? 0) + ((c['payment_count'] as num?) ?? 0))} 笔 · 欠 ¥${((c['debt'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF9CA3AF)
                    : const Color(0x8A000000),
              ),
            ),
      trailing: '${c['id']}' == _clientId
          ? const Icon(Icons.check_circle, color: Color(0xFF409EFF), size: 20)
          : null,
      onTap: () => Navigator.pop(ctx, '${c['id']}'),
    );
  }

  /// 记单场景快速新增店铺（对话框，创建后自动选中）
  Future<void> _addClientQuick() async {
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增店铺'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '店铺名称 *'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('创建')),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) {
      toast(context, '请输入店铺名称');
      return;
    }
    try {
      final d = await Api.instance.post('/clients', {'name': name});
      final id = '${d['id'] ?? ''}';
      if (mounted) {
        if (id.isNotEmpty) {
          _clientId = id;
          SyncService.saveSelectedClientId(id);
        }
        toast(context, '已创建店铺「$name」');
        _load();
      }
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFF56C6C)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _editSale(Map<String, dynamic> s) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SalePage(editId: '${s['id']}')))
        .then((_) => _load());
  }

  Future<void> _deleteSale(Map<String, dynamic> s) async {
    if (!await _confirm('删除出货单', '确定删除 ${_date(s['happened_at'])} 对 ${s['client_name']} 的出货单（¥${s['total']}）吗？')) {
      return;
    }
    try {
      await Api.instance.delete('/sales/${s['id']}');
      // 同步删本地库镜像行（否则残留 → 下次打开"删不掉"，本地与 Web 不一致）
      await LocalDb.deleteOne('sales', '${s['id']}');
      toast(context, '已删除');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _editPayment(Map<String, dynamic> p) async {
    final amountCtrl = TextEditingController(text: '${p['amount']}');
    final dateCtrl = TextEditingController(text: _date(p['happened_at']));
    final methodCtrl = TextEditingController(text: '${p['method'] ?? ''}');
    final noteCtrl = TextEditingController(text: '${p['note'] ?? ''}');
    String? clientId = '${p['client_id']}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑收款'),
        content: StatefulBuilder(
          builder: (ctx, setDlg) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: clientId,
                decoration: const InputDecoration(labelText: '店铺'),
                items: _clients
                    .map((c) => DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}')))
                    .toList(),
                onChanged: (v) => setDlg(() => clientId = v),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '金额（元）'),
              ),
              const SizedBox(height: 8),
              TextField(controller: dateCtrl, decoration: const InputDecoration(labelText: '日期（YYYY-MM-DD）')),
              const SizedBox(height: 8),
              TextField(
                  controller: methodCtrl,
                  decoration: const InputDecoration(labelText: '收款方式（现金/微信/转账…）')),
              const SizedBox(height: 8),
              TextField(controller: noteCtrl, decoration: const InputDecoration(labelText: '备注')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final amount = double.tryParse(amountCtrl.text.trim());
    if (clientId == null) {
      toast(context, '请选择店铺');
      return;
    }
    if (amount == null || amount <= 0) {
      toast(context, '请输入有效金额');
      return;
    }
    try {
      await Api.instance.patch('/payments/${p['id']}', {
        'client_id': clientId,
        'amount': amount,
        'happened_at': dateCtrl.text.trim(),
        'method': methodCtrl.text.trim(),
        'note': noteCtrl.text.trim(),
      });
      toast(context, '已保存');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _deletePayment(Map<String, dynamic> p) async {
    if (!await _confirm('撤销收款', '确定撤销 ${_date(p['happened_at'])} ${p['client_name']} 的收款（¥${p['amount']}）吗？')) {
      return;
    }
    try {
      await Api.instance.delete('/payments/${p['id']}');
      // 同步删本地库镜像行（否则残留 → 下次打开"删不掉"，本地与 Web 不一致）
      await LocalDb.deleteOne('payments', '${p['id']}');
      toast(context, '已撤销');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// CSV 字段转义：含逗号/引号/换行的加引号包裹
  String _csv(Object? v) {
    final s = '$v';
    return s.contains(',') || s.contains('"') || s.contains('\n') ? '"${s.replaceAll('"', '""')}"' : s;
  }

  /// 导出当前筛选 CSV（出货/收款，按账本+范围）
  Future<void> _exportCsv() async {
    final buf = StringBuffer('\uFEFF');
    buf.writeln('类型,日期,店铺,商品,数量,单位,单价,金额,备注');
    for (final s in _sales) {
      final items = (s['items'] as List? ?? []);
      for (final it in items) {
        buf.writeln([
          '出货',
          _csv(_date(s['happened_at'])),
          _csv(s['client_name']),
          _csv(it['item_name']),
          _csv(it['quantity']),
          _csv(it['unit']),
          _csv(it['sale_price']),
          _csv(it['amount']),
          _csv(s['note']),
        ].join(','));
      }
    }
    for (final p in _payments) {
      buf.writeln([
        '收款',
        _csv(_date(p['happened_at'])),
        _csv(p['client_name']),
        '',
        '',
        '',
        '',
        _csv(p['amount']),
        _csv(p['method']),
      ].join(','));
    }
    final bytes = Uint8List.fromList(utf8.encode(buf.toString()));
    await Share.shareXFiles(
      [XFile.fromData(bytes, mimeType: 'text/csv', name: 'taozhu-账本.csv')],
      text: '陶朱账本 CSV',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('交易'),
          actions: [
            IconButton(
              tooltip: '导出 CSV',
              icon: const Icon(Icons.file_download_outlined),
              onPressed: _exportCsv,
            ),
          ],
          bottom: TabBar(
            tabs: _isStaff
                ? const [Tab(text: '出货')]
                : const [Tab(text: '出货'), Tab(text: '收款')],
            labelColor: c.primary,
            unselectedLabelColor: c.textSub,
            labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 14),
            indicator: BoxDecoration(
              color: c.primary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            indicatorSize: TabBarIndicatorSize.label,
          ),
        ),
        body: Column(
          children: [
            if (_offline)
              Container(
                width: double.infinity,
                color: const Color(0xFFE6A23C).withOpacity(0.12),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: const Row(
                  children: [
                    Icon(Icons.wifi_off, size: 16, color: Color(0xFFE6A23C)),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text('离线数据：当前无法连接服务器，显示本地缓存，可能不是最新',
                          style: TextStyle(fontSize: 12, color: Color(0xFFB88230))),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 账本（店铺）选择：点击弹出全部账本弹层（名称+交易笔数+欠款+管理）
                  if (_clients.isNotEmpty)
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _showLedgerPicker,
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: c.field,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: c.primary.withOpacity(0.4)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.store_outlined, size: 20, color: c.primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _clients
                                          .where((c) => '${c['id']}' == _clientId)
                                          .map((c) => '${c['name']}')
                                          .firstOrNull ??
                                      '选择店铺',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: c.textMain,
                                  ),
                                ),
                              ),
                              Icon(Icons.keyboard_arrow_down, color: c.textSub),
                            ],
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  // 时间范围：当月 / 最近2个月 / 最近3个月 / 全部（Wrap 自动换行，文字完整显示）
                  // 店员账号：仅当天出货（后端强制），隐藏范围选择
                  if (!_isStaff)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final r in const [
                          ('month', '当月'),
                          ('2m', '最近2个月'),
                          ('3m', '最近3个月'),
                          ('all', '全部流水'),
                        ])
                          ChoiceChip(
                            label: Text(r.$2, style: const TextStyle(fontSize: 13)),
                            visualDensity: VisualDensity.compact,
                            selected: _range == r.$1,
                            onSelected: (_) {
                              setState(() => _range = r.$1);
                              _load();
                            },
                          ),
                      ],
                    ),
                  if (_isStaff)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('今日送货记录', style: TextStyle(fontSize: 12, color: c.textSub)),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(children: _isStaff
                      ? [
                          _buildList('今日暂无出货记录', _sales, _saleCard,
                              (s) => ((s['total'] as num?)?.toDouble() ?? 0),
                              emptyActionLabel: '＋ 记一笔出货',
                              onEmptyAction: () => Navigator.of(context)
                                  .push(MaterialPageRoute(builder: (_) => const SalePage()))
                                  .then((_) => _load())),
                        ]
                      : [
                          _buildList('暂无偿付记录', _sales, _saleCard,
                              (s) => ((s['total'] as num?)?.toDouble() ?? 0),
                              emptyActionLabel: '＋ 记一笔出货',
                              onEmptyAction: () => Navigator.of(context)
                                  .push(MaterialPageRoute(builder: (_) => const SalePage()))
                                  .then((_) => _load())),
                          _buildList('暂无收款记录', _payments, _paymentCard,
                              (p) => ((p['amount'] as num?)?.toDouble() ?? 0),
                              emptyActionLabel: '＋ 去收款',
                              onEmptyAction: () => Navigator.of(context)
                                  .push(MaterialPageRoute(builder: (_) => const PaymentsPage()))
                                  .then((_) => _load())),
                    ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(
    String emptyText,
    List<Map<String, dynamic>> rows,
    Widget Function(Map<String, dynamic>) card,
    double Function(Map<String, dynamic>) amountOf, {
    String? emptyActionLabel,
    VoidCallback? onEmptyAction,
  }) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    if (rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.all(48),
              child: Column(
                children: [
                  const Icon(Icons.receipt_long_outlined, size: 40, color: Color(0xFFD0D5DD)),
                  const SizedBox(height: 12),
                  Text(emptyText, style: TextStyle(color: c.textSub)),
                  if (emptyActionLabel != null) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: c.primary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: onEmptyAction,
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(emptyActionLabel),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }
    // 按日期分组（流水：日期组头 + 行）
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      final d = _date(r['happened_at']);
      (grouped[d] ??= []).add(r);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [
          for (final e in grouped.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 14, 4, 2),
              child: Row(
                children: [
                  Text(_weekday(e.key),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: c.textMain,
                      )),
                  const Spacer(),
                  Text(
                    '${e.value.length} 笔 · 合计 ¥${fmtMoney(e.value.fold<double>(0, (s, r) => s + amountOf(r)))}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.textSub,
                    ),
                  ),
                ],
              ),
            ),
            for (final r in e.value) card(r),
          ],
        ],
      ),
    );
  }

  /// 日期 → "2026-09-09 周三"
  String _weekday(String date) {
    final d = DateTime.tryParse(date);
    if (d == null) return date;
    const wd = ['一', '二', '三', '四', '五', '六', '日'];
    return '$date 周${wd[d.weekday - 1]}';
  }

  /// 卡片右上 ⋯ 菜单：编辑 / 删除（附件已改为列表上的直接图标）
  Widget _menu({required VoidCallback edit, required VoidCallback del}) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_vert, size: 18, color: c.textSub),
      onSelected: (v) {
        if (v == 'edit') edit();
        if (v == 'del') del();
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'edit', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.edit_outlined, size: 18), title: Text('编辑'))),
        PopupMenuItem(value: 'del', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.delete_outline, size: 18, color: c.danger), title: Text('删除', style: TextStyle(color: c.danger)))),
      ],
    );
  }

  Widget _saleCard(Map<String, dynamic> s) {
    final items = (s['items'] as List? ?? []).cast<Map<String, dynamic>>();
    final note = (s['note'] as String? ?? '').trim();
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      elevation: 0,
      color: c.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.primary.withOpacity(0.3)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _editSale(s),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: c.primary.withOpacity(0.12),
                child: Icon(Icons.storefront, size: 16, color: c.primary),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${s['client_name']}',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.textMain)),
              ),
              Text('¥${fmtMoney(s['total'])}',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.danger)),
              // 附件直接可见：点图标全屏查看全部凭证图片（左右滑动切换）
              IconButton(
                tooltip: '凭证附件',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.image_outlined, size: 20, color: c.primary),
                onPressed: () => showAttachmentViewer(context, 'sale', '${s['id']}', '出货单附件'),
              ),
              _menu(
                edit: () => _editSale(s),
                del: () => _deleteSale(s),
              ),
            ]),
            // 商品明细直接展开（全部显示，点卡片才进编辑）；行日期与该单不同时标注
            for (final it in items)
              Padding(
                padding: const EdgeInsets.only(left: 40, top: 2),
                child: Row(children: [
                  Expanded(
                    child: Text('${_itemDateLabel(s, it)}${it['item_name']} ×${it['quantity']}${it['unit']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: c.textSub)),
                  ),
                  Text('¥${fmtMoney(it['amount'])}',
                      style: TextStyle(fontSize: 13, color: c.textSub.withOpacity(0.7))),
                ]),
              ),
            if (note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 40, top: 2),
                child: Text('备注：$note',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.textSub)),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _paymentCard(Map<String, dynamic> p) {
    final method = (p['method'] as String? ?? '').trim();
    final note = (p['note'] as String? ?? '').trim();
    final waived = ((p['waived'] as num?) ?? 0) > 0;
    final meta = [
      if (method.isNotEmpty) method,
      if (waived) '平账 ¥${fmtMoney(p['waived'])}',
      if (note.isNotEmpty) note,
    ].join(' · ');
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      elevation: 0,
      color: c.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.success.withOpacity(0.3)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _editPayment(p),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: c.success.withOpacity(0.12),
              child: Icon(Icons.check_circle_outline, size: 16, color: c.success),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${p['client_name']}',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.textMain)),
                if (meta.isNotEmpty)
                  Text(meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: c.textSub)),
              ]),
            ),
            Text('¥${fmtMoney(p['amount'])}',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.success)),
            // 附件直接可见：点图标全屏查看全部凭证图片（左右滑动切换）
            IconButton(
              tooltip: '凭证附件',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.image_outlined, size: 20, color: c.success),
              onPressed: () => showAttachmentViewer(context, 'payment', '${p['id']}', '收款凭证'),
            ),
            _menu(
              edit: () => _editPayment(p),
              del: () => _deletePayment(p),
            ),
          ]),
        ),
      ),
    );
  }
}