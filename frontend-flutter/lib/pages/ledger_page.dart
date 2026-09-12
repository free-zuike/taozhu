import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
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
import 'sale_batch_edit_page.dart';

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
  /// 店铺选择弹层本地汇总（原生：笔数/欠款本地计算；Web 直接显示服务端字段）
  Map<String, ({int count, double debt})> _clientStat = {};
  /// 出货单 id → 附件数（「有附件才显示图标」：云端 counts + 本地副本兜底）
  Map<String, int> _saleAttachCount = {};
  /// 收款单 id → 附件数
  Map<String, int> _payAttachCount = {};
  /// 商品 id → 分类名（出货明细行第二行显示分类，替代无实际数据的交易时间）
  Map<String, String> _itemCategory = {};

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

  /// Web 端商品目录（分类映射用）：拉 /items/summary（含 category），失败返回空
  Future<List<Map<String, dynamic>>> _webItems() async {
    try {
      final d = await Api.instance.get('/items/summary');
      return ((d['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// 本地优先加载（同步只由「我的」页/进应用自动同步驱动，页面刷新不再访问网络）：
  /// ① 读本地库镜像（按当前店铺+范围过滤）立即展示——有就秒开，空就显示空态；
  /// ② 同步完成后 SyncService.version 通知会再来 _load 一次（本地数据自动更新）；
  /// ③ Web 无本地库，仍直连服务器读取。
  Future<void> _load() async {
    final firstLocal = await LocalDb.getAllByName('clients');
    final allSales = await LocalDb.getAll('sales');
    final allPays = await LocalDb.getAll('payments');
    // 商品分类映射（明细行第二行显示分类）：原生读本地库镜像，Web 拉简化目录
    final items = kIsWeb
        ? await _webItems()
        : await LocalDb.getAllByName('items');
    _itemCategory = {
      for (final it in items) '${it['id']}': '${it['category'] ?? ''}',
    };
    // 店铺选择弹层的笔数/欠款用本地全量汇总（与后端口径一致：笔数=出货单数+收款单数，欠款=Σ出货-Σ收款）
    _clientStat = _localStats(allSales, allPays);
    var sales = allSales;
    var payments = allPays;
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
        _offline = firstLocal.isEmpty;
      });
    }
    if (kIsWeb) await _loadNetwork(firstLocal);
    // 附件计数（有附件才显示图标）：本地目录扫描 + 云端批量 counts（后台加载，不阻塞列表）
    _loadAttachCounts();
  }

  /// 统计当前可见出货/收款单的附件数：本地副本目录优先兜底，云端批量 counts 精确覆盖
  Future<void> _loadAttachCounts() async {
    final saleIds = _sales.map((s) => '${s['id']}').whereType<String>().where((x) => x.isNotEmpty).toSet().toList();
    final payIds = _payments.map((p) => '${p['id']}').whereType<String>().where((x) => x.isNotEmpty).toSet().toList();
    final counts = <String, Map<String, int>>{'sale': {}, 'payment': {}};
    // ① 本地副本（原生）：attachments/{entity}/{id}/ 目录里有多少文件
    if (!kIsWeb && (saleIds.isNotEmpty || payIds.isNotEmpty)) {
      try {
        final root = await getApplicationDocumentsDirectory();
        for (final e in [(saleIds, 'sale'), (payIds, 'payment')]) {
          for (final id in e.$1) {
            final dir = Directory('${root.path}/attachments/${e.$2}/$id');
            if (dir.existsSync()) {
              final n = dir.listSync().whereType<File>().length;
              if (n > 0) counts[e.$2]![id] = n;
            }
          }
        }
      } catch (_) {}
    }
    // ② 云端批量 counts（一次一个实体；失败静默不打扰）
    Future<void> fetch(String entity, List<String> ids) async {
      if (ids.isEmpty) return;
      try {
        final d = await Api.instance.post('/attachments/counts', {'entity': entity, 'ids': ids});
        final m = (d['counts'] as Map?) ?? {};
        for (final e in m.entries) {
          final n = (e.value as num?)?.toInt() ?? 0;
          if (n > 0) counts[entity]!['${e.key}'] = n;
        }
      } catch (_) {}
    }
    await Future.wait([fetch('sale', saleIds), fetch('payment', payIds)]);
    if (!mounted) return;
    setState(() {
      _saleAttachCount = counts['sale']!;
      _payAttachCount = counts['payment']!;
    });
  }

  /// Web 端直连服务器（无本地库）：拉店铺/出货/收款并刷新视图
  Future<void> _loadNetwork(List<Map<String, dynamic>> firstLocal) async {
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
      // 镜像写库（增量 upsert，不删本地未推送的单；Web 端 LocalDb 空操作）
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
      // 网络失败不打扰（本地数据已展示）；本地无数据时标记离线态
      if (mounted && firstLocal.isEmpty) {
        setState(() => _offline = true);
      }
    }
  }

  /// 本地全量汇总：笔数 = 出货单数 + 收款单数；欠款 = Σ出货总额 − Σ收款金额（与后端口径一致）
  Map<String, ({int count, double debt})> _localStats(
      List<Map<String, dynamic>> sales, List<Map<String, dynamic>> pays) {
    final saleSum = <String, double>{};
    final saleCnt = <String, int>{};
    for (final s in sales) {
      final id = '${s['client_id']}';
      saleSum[id] = (saleSum[id] ?? 0) + ((s['total'] as num?)?.toDouble() ?? 0);
      saleCnt[id] = (saleCnt[id] ?? 0) + 1;
    }
    final paySum = <String, double>{};
    final payCnt = <String, int>{};
    for (final p in pays) {
      final id = '${p['client_id']}';
      paySum[id] = (paySum[id] ?? 0) + ((p['amount'] as num?)?.toDouble() ?? 0);
      payCnt[id] = (payCnt[id] ?? 0) + 1;
    }
    return {
      for (final id in {...saleSum.keys, ...paySum.keys})
        id: (count: (saleCnt[id] ?? 0) + (payCnt[id] ?? 0),
            debt: ((saleSum[id] ?? 0) - (paySum[id] ?? 0)).toDouble()),
    };
  }

  /// 店铺选择弹层的笔数（服务端字段优先，本地镜像缺失时用本地汇总兜底）
  String _statCount(Map<String, dynamic> c) {
    final v = (c['sale_count'] as num?)?.toInt();
    if (v != null) return '${v + ((c['payment_count'] as num?)?.toInt() ?? 0)}';
    return '${_clientStat['${c['id']}']?.count ?? 0}';
  }

  /// 店铺选择弹层的欠款（服务端字段优先，本地镜像缺失时用本地汇总兜底）
  double _statDebt(Map<String, dynamic> c) {
    final v = (c['debt'] as num?)?.toDouble();
    if (v != null) return v;
    return _clientStat['${c['id']}']?.debt ?? 0;
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
              '交易 ${_statCount(c)} 笔 · 欠 ¥${_statDebt(c).toStringAsFixed(2)}',
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

  /// 日期栏 → 批量编辑该日全部明细（逐行改期 / 整体改期）
  Future<void> _openBatchEdit(String date, List<Map<String, dynamic>> lines) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SaleBatchEditPage(date: date, lines: lines)));
    _load();
  }

  /// 删除一条出货流水明细行（该行商品）：只删这一行，同单其他商品不受影响；
  /// 这是该单最后一行的商品时，整单删除（含备注）。
  Future<void> _deleteSaleLine(Map<String, dynamic> l) async {
    final order = l['order'] as Map<String, dynamic>;
    final itemId = '${l['item_id'] ?? ''}';
    final itemName = '${l['item_name'] ?? ''}';
    final qty = '${l['quantity'] ?? ''}';
    final items = (order['items'] as List? ?? []).cast<Map<String, dynamic>>();
    final isLast = itemId.isEmpty || items.length <= 1;
    if (!await _confirm('删除明细行',
        isLast
            ? itemName.isEmpty
                ? '这是该单唯一的记录，删除后将整单删除。确定删除吗？'
                : '这是该单唯一的商品，删除后将整单删除。确定删除「$itemName」吗？'
            : '确定删除「$itemName${qty.isNotEmpty ? ' ×$qty' : ''}」这一行明细吗？同单其他商品不受影响。')) {
      return;
    }
    try {
      if (isLast) {
        await _deleteSaleOrder(order);
      } else {
        // 只删该行：服务器删行级 + 本地镜像同步移除（等不到下次同步也立即生效）
        await Api.instance.delete('/sales/items/$itemId');
        final rest = <Map<String, dynamic>>[
          for (final it in items)
            if ('${it['id']}' != itemId) Map<String, dynamic>.from(it),
        ];
        final payload = Map<String, dynamic>.from(order)
          ..['items'] = rest
          ..['total'] = rest.fold<double>(
              0, (s, it) => s + ((it['amount'] as num?)?.toDouble() ?? 0));
        final dates = [
          for (final it in rest)
            '${it['happened_at'] ?? ''}'.isNotEmpty
                ? '${it['happened_at']}'
                : '${payload['happened_at'] ?? ''}',
        ];
        if (dates.isNotEmpty) {
          final maxD = dates.reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
          if (maxD.isNotEmpty) payload['happened_at'] = maxD;
        }
        await LocalDb.upsertOne('sales', payload);
      }
      toast(context, '已删除');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 删除整单（长按卡片触发）：Web 直连 DELETE + 清本地行；原生 = 本地删行 + 同步队列推送 delete，跨端生效
  Future<void> _deleteSaleOrder(Map<String, dynamic> order) async {
    final orderId = '${order['id']}';
    final name = '${order['client_name'] ?? ''}';
    final ok = await _confirm('删除整单', '确定删除 ${_date(order['happened_at'])} 对 $name 的整张出货单吗？相关历史与附件不受影响。');
    if (!ok) return;
    try {
      if (kIsWeb) {
        await Api.instance.delete('/sales/$orderId');
      } else {
        // 原生：先删本地行（立即生效），再入同步队列（其他设备 pull 到 delete 后同步删除）
        await LocalDb.deleteOne('sales', orderId);
        await SyncService.enqueueChange(
            entityType: 'sale', entitySyncId: orderId, action: 'delete', payload: {});
      }
      toast(context, '已删除整单');
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
                          _buildSaleFlow('今日暂无出货记录'),
                        ]
                      : [
                          _buildSaleFlow('暂无偿付记录'),
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

  /// 交易时间（HH:MM:SS）：有就显示，没有默认 00:00:00
  String _timeOf(String happenedAt) {
    final m = RegExp(r'(\d{1,2}):(\d{2})(?::(\d{2}))?').firstMatch(happenedAt.trim());
    if (m == null) return '00:00:00';
    final hh = m.group(1)!.padLeft(2, '0');
    return '$hh:${m.group(2)}:${m.group(3) ?? '00'}';
  }

  /// 卡片右上 ⋯ 菜单：编辑 / 删除（附件图标直接放行内，分类在「点击交易修改」里改）
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

  /// 出货流水（商品明细铺开）：按明细行日期分组，每行一条商品
  /// （三行卡片：①商品名称+备注 ②交易时间+附件 ③售价·数量·进价）；点行编辑整单，附件图标直达凭证。
  Widget _buildSaleFlow(String emptyText) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    // 展开为明细行：行日期回退单据日期；无明细的单据显示备注/占位
    final lines = <Map<String, dynamic>>[];
    for (final s in _sales) {
      final orderDate = _date(s['happened_at']);
      final orderNote = '${s['note'] ?? ''}'.trim();
      final items = (s['items'] as List? ?? []).cast<Map<String, dynamic>>();
      if (items.isEmpty) {
        lines.add({
          'date': orderDate, 'order': s, 'client_name': '${s['client_name'] ?? ''}',
          'item_name': '（无明细）',
          'quantity': '', 'unit': '', 'amount': ((s['total'] as num?)?.toDouble() ?? 0),
          'item_id': '', 'sale_price': null, 'cost_price': null, 'qty_num': 0,
          'note': orderNote,
          'happened_at': '${s['happened_at'] ?? orderDate}',
        });
      }
      for (final it in items) {
        final id = '${it['happened_at'] ?? ''}';
        lines.add({
          'date': id.length >= 10 ? id.substring(0, 10) : orderDate,
          'order': s,
          'client_name': '${s['client_name'] ?? ''}',
          'item_name': '${it['item_name'] ?? ''}',
          'category': _itemCategory['${it['id'] ?? ''}'] ?? '',
          'quantity': '${it['quantity'] ?? ''}',
          'unit': '${it['unit'] ?? ''}',
          'amount': ((it['amount'] as num?)?.toDouble() ?? 0),
          'item_id': '${it['id'] ?? ''}',
          'sale_price': (it['sale_price'] as num?)?.toDouble(),
          'cost_price': (it['cost_price'] as num?)?.toDouble(),
          'qty_num': (it['quantity'] as num?)?.toDouble() ?? 0,
          'note': it == items.first ? orderNote : '',
          'happened_at': id.isEmpty ? '${s['happened_at'] ?? orderDate}' : id,
        });
      }
    }
    if (lines.isEmpty) {
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
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: c.primary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const SalePage()))
                        .then((_) => _load()),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('＋ 记一笔出货'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    // 按行日期分组（日期相同按店名排序）
    lines.sort((a, b) {
      final x = '${a['date']}'.compareTo('${b['date']}');
      return x != 0 ? x : '${a['client_name']}'.compareTo('${b['client_name']}');
    });
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final l in lines) {
      (grouped['${l['date']}'] ??= []).add(l);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [
          for (final e in grouped.entries) ...[
            // 日期栏 = 该日全部明细的批量编辑入口（逐行改期 / 整体改期）
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _openBatchEdit(e.key, e.value),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 2),
                child: Row(
                  children: [
                    Icon(Icons.edit_calendar_outlined, size: 15, color: c.primary),
                    const SizedBox(width: 4),
                    Text(_weekday(e.key),
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.textMain)),
                    const Spacer(),
                    Text(
                      '${e.value.length} 件 · 合计 ¥${fmtMoney(e.value.fold<double>(0, (s, l) => s + ((l['amount'] as num?)?.toDouble() ?? 0)))}',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.textSub),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right, size: 16, color: c.textSub),
                  ],
                ),
              ),
            ),
            for (final l in e.value) _saleLineTile(c, l),
          ],
        ],
      ),
    );
  }

  /// 出货流水行：三行卡片 —— ①商品名称+备注 ②交易时间+附件（时间在前，有附件才显示图标）③售价×数量·进价
  Widget _saleLineTile(TaozhuColors c, Map<String, dynamic> l) {
    final order = l['order'] as Map<String, dynamic>;
    final clientName = '${l['client_name'] ?? ''}';
    final itemName = '${l['item_name'] ?? ''}';
    final qty = '${l['quantity'] ?? ''}';
    final unit = '${l['unit'] ?? ''}';
    final showStore = _clientId == null && clientName.isNotEmpty; // 全部店铺时带店名
    final salePrice = l['sale_price'] as num?;
    final costPrice = l['cost_price'] as num?;
    final qtyNum = (l['qty_num'] as num?)?.toDouble() ?? 0;
    final note = '${l['note'] ?? ''}'.trim();
    final category = '${l['category'] ?? ''}'.trim();
    final attachCount = _saleAttachCount['${order['id']}'] ?? 0;
    // 单行盈亏 = (售价 − 进价快照) × 数量；仅老板可见（店员成本被后端打码为 0 不参与计算）
    double? profit;
    if (!_isStaff && salePrice != null && costPrice != null && qtyNum > 0) {
      profit = (salePrice.toDouble() - costPrice.toDouble()) * qtyNum;
    }
    final bg = profit == null
        ? c.card
        : (profit >= 0 ? Color.lerp(c.card, c.success, 0.08) : Color.lerp(c.card, c.danger, 0.08));
    final border = profit == null
        ? c.primary.withOpacity(0.2)
        : (profit >= 0 ? c.success.withOpacity(0.4) : c.danger.withOpacity(0.4));
    // 背景折线方向：盈利=从左下角到右上角（上升），亏损=从右上角到左下角（下降）；无盈亏=平线
    final trendUp = profit == null ? null : profit >= 0;
    // 第三行：进价 · 售价 · 数量单位（老板看进价；店员无进价数据只显示售价·数量）
    final priceLine = StringBuffer();
    if (!_isStaff && costPrice != null) priceLine.write('进价 ¥${fmtMoney(costPrice.toDouble())} · ');
    priceLine.write('售价 ¥${fmtMoney(salePrice?.toDouble() ?? 0)}');
    if (qty.isNotEmpty) priceLine.write(' · ×$qty$unit');
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _editSale(order),
      // 长按 = 删除整单（弹确认框；确认删除，取消返回）
      onLongPress: () => _deleteSaleOrder(order),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: border),
        ),
        child: Stack(
          children: [
            // 背景装饰折线：方向随盈亏（升=左下→右上，降=右上→左下），放在背景层不占布局空间
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _CardBgLinePainter(color: c.primary, trendUp: trendUp),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: c.primary.withOpacity(0.12),
                    child: Icon(Icons.storefront, size: 14, color: c.primary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ① 商品名称 + 备注（备注在商品名称后边）
                        Text.rich(
                          TextSpan(children: [
                            TextSpan(
                              text: showStore ? '$clientName · $itemName' : itemName,
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.textMain),
                            ),
                            if (note.isNotEmpty)
                              TextSpan(
                                text: '  $note',
                                style: TextStyle(fontSize: 11, color: c.textSub),
                              ),
                          ]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        // ② 商品分类 + 附件（分类在前，附件在后；有附件才显示图标）
                        Row(
                          children: [
                            Icon(Icons.sell_outlined, size: 12, color: c.textSub),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                category.isEmpty ? '未分类' : category,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, color: c.textSub),
                              ),
                            ),
                            if (attachCount > 0) ...[
                              const SizedBox(width: 8),
                              InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: () async {
                                  await showAttachmentViewer(
                                      context, 'sale', '${order['id']}', '出货单附件');
                                  // 附件增删后立即刷新计数，避免图标残留/缺失（无需手动下拉）
                                  _loadAttachCounts();
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: Icon(Icons.image_outlined, size: 15, color: c.primary),
                                ),
                              ),
                            ],
                          ],
                        ),
                        // ③ 进价 · 售价 · 数量单位（允许换行，进价不被截断）
                        Text(priceLine.toString(),
                            style: TextStyle(fontSize: 12, color: c.textSub)),
                      ],
                    ),
                  ),
                  Text('¥${fmtMoney((l['amount'] as num?)?.toDouble() ?? 0)}',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.danger)),
                ],
              ),
            ),
          ],
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
            // 附件直接可见：有附件才显示图标，点图标全屏查看全部凭证图片（左右滑动切换）
            if ((_payAttachCount['${p['id']}'] ?? 0) > 0)
              IconButton(
                tooltip: '凭证附件',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.image_outlined, size: 20, color: c.success),
                onPressed: () async {
                  await showAttachmentViewer(context, 'payment', '${p['id']}', '收款凭证');
                  _loadAttachCounts();
                },
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

/// 卡片背景装饰折线：方向随盈亏 —— 盈利=从左下角到右上角（上升），亏损=从右上角到左下角（下降），无盈亏=平线
class _CardBgLinePainter extends CustomPainter {
  final Color color;
  final bool? trendUp; // true=上升（左下→右上），false=下降（右上→左下），null=平线
  _CardBgLinePainter({required this.color, this.trendUp});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final h = size.height;
    final w = size.width;
    final paint = Paint()
      ..color = color.withOpacity(0.10)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    if (trendUp == null) {
      // 无盈亏：贴底平线（从左到右）
      path
        ..moveTo(0, h * 0.92)
        ..lineTo(w * 0.3, h * 0.86)
        ..lineTo(w * 0.55, h * 0.9)
        ..lineTo(w * 0.8, h * 0.85)
        ..lineTo(w, h * 0.88);
    } else if (trendUp!) {
      // 上升：从左下角 (0,h) 到右上角 (w,0)
      path
        ..moveTo(0, h)
        ..lineTo(w * 0.25, h * 0.72)
        ..lineTo(w * 0.5, h * 0.62)
        ..lineTo(w * 0.75, h * 0.35)
        ..lineTo(w, 0);
    } else {
      // 下降：从左上角 (0,0) 到右下角 (w,h)
      path
        ..moveTo(0, 0)
        ..lineTo(w * 0.25, h * 0.28)
        ..lineTo(w * 0.5, h * 0.38)
        ..lineTo(w * 0.75, h * 0.65)
        ..lineTo(w, h);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CardBgLinePainter old) =>
      old.color != color || old.trendUp != trendUp;
}