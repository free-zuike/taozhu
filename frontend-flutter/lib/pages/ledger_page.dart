import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../api.dart';
import 'router.dart';
import 'sale_page.dart';
import 'purchase_page.dart';
import 'attachment_panel.dart';

/// 账本：出货 / 进货 / 收款历史，支持编辑与删除（纠错入口）
class LedgerPage extends StatefulWidget {
  const LedgerPage({super.key});
  @override
  State<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends State<LedgerPage> {
  List<Map<String, dynamic>> _sales = [];
  List<Map<String, dynamic>> _purchases = [];
  List<Map<String, dynamic>> _payments = [];
  List<Map<String, dynamic>> _clients = [];
  String? _clientId; // null = 全部店铺
  final _fromCtrl = TextEditingController();
  final _toCtrl = TextEditingController();
  bool _loading = true;
  bool _offline = false; // 本次加载走了本地缓存（无网络）

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _fromCtrl.dispose();
    _toCtrl.dispose();
    super.dispose();
  }

  /// 当前筛选条件下的查询串（空=不限）
  String _query({bool withClient = true}) {
    final params = <String>[];
    if (withClient && _clientId != null) params.add('client_id=$_clientId');
    final from = _fromCtrl.text.trim();
    final to = _toCtrl.text.trim();
    if (from.isNotEmpty) params.add('date_from=$from');
    if (to.isNotEmpty) params.add('date_to=$to');
    return params.isEmpty ? '' : '?${params.join('&')}';
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        Api.instance.getWithFallback('/sales${_query()}'),
        Api.instance.getWithFallback('/purchases${_query(withClient: false)}'),
        Api.instance.getWithFallback('/payments${_query()}'),
        Api.instance.getWithFallback('/clients'),
      ]);
      if (!mounted) return;
      setState(() {
        _offline = results.any((r) => r.offline);
        _sales = ((results[0].data['sales'] as List?) ?? []).cast<Map<String, dynamic>>();
        _purchases = ((results[1].data['purchases'] as List?) ?? []).cast<Map<String, dynamic>>();
        _payments = ((results[2].data['payments'] as List?) ?? []).cast<Map<String, dynamic>>();
        _clients = ((results[3].data['clients'] as List?) ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  String _date(Object? v) {
    final s = '$v';
    return s.length >= 10 ? s.substring(0, 10) : s;
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
      toast(context, '已删除');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _editPurchase(Map<String, dynamic> p) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => PurchasePage(editId: '${p['id']}')))
        .then((_) => _load());
  }

  Future<void> _deletePurchase(Map<String, dynamic> p) async {
    if (!await _confirm('删除进货单', '确定删除 ${_date(p['happened_at'])} 的进货单（¥${p['total']}）吗？')) {
      return;
    }
    try {
      await Api.instance.delete('/purchases/${p['id']}');
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

  /// 导出当前筛选 CSV 文件（系统分享面板）：按商品明细逐行展开——类型/日期/店铺/商品/数量/单位/单价/金额/备注
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
    for (final p in _purchases) {
      final items = (p['items'] as List? ?? []);
      for (final it in items) {
        buf.writeln([
          '进货',
          _csv(_date(p['happened_at'])),
          '',
          _csv(it['item_name']),
          _csv(it['quantity']),
          _csv(it['unit']),
          _csv(it['purchase_price']),
          _csv(it['amount']),
          _csv(p['note']),
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
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('账本'),
          actions: [
            IconButton(
              tooltip: '导出 CSV',
              icon: const Icon(Icons.file_download_outlined),
              onPressed: _exportCsv,
            ),
          ],
          bottom: const TabBar(tabs: [Tab(text: '出货'), Tab(text: '进货'), Tab(text: '收款')]),
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
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      DropdownButtonFormField<String?>(
                        initialValue: _clientId,
                        isDense: true,
                        decoration: const InputDecoration(labelText: '店铺筛选'),
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('全部店铺')),
                          ..._clients
                              .map((c) => DropdownMenuItem<String?>(
                                  value: '${c['id']}', child: Text('${c['name']}')))
                              .toList(),
                        ],
                        onChanged: (v) => setState(() => _clientId = v),
                      ),
                      const SizedBox(height: 8),
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
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _load,
                              child: const Text('筛选'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextButton(
                              onPressed: () => setState(() {
                                _clientId = null;
                                _fromCtrl.clear();
                                _toCtrl.clear();
                              }),
                              child: const Text('重置'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(children: [
                      _buildList('暂无偿付记录', _sales, _saleCard),
                      _buildList('暂无进货记录', _purchases, _purchaseCard),
                      _buildList('暂无收款记录', _payments, _paymentCard),
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
  ) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(40),
              child: Center(child: Text(emptyText, style: const TextStyle(color: Colors.grey))),
            ),
          for (final r in rows) card(r),
        ],
      ),
    );
  }

  Widget _saleCard(Map<String, dynamic> s) {
    final count = (s['items'] as List? ?? []).length;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.storefront, color: Color(0xFF409EFF)),
        title: Text('${s['client_name']}'),
        subtitle: Text(
          '${_date(s['happened_at'])} · $count 项${(s['note'] as String? ?? '').isNotEmpty ? ' · ${s['note']}' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.attachment_outlined, size: 18, color: Color(0xFF909399)),
              tooltip: '附件',
              onPressed: () => showAttachmentPanel(context, 'sale', '${s['id']}', '出货单附件'),
            ),
            Text('¥${s['total']}',
                style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFF56C6C))),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF409EFF)),
              onPressed: () => _editSale(s),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFF56C6C)),
              onPressed: () => _deleteSale(s),
            ),
          ],
        ),
        onTap: () => _editSale(s),
      ),
    );
  }

  Widget _purchaseCard(Map<String, dynamic> p) {
    final count = (p['items'] as List? ?? []).length;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.shopping_cart, color: Color(0xFF67C23A)),
        title: Text('${_date(p['happened_at'])} 进货'),
        subtitle: Text(
          '$count 项${(p['note'] as String? ?? '').isNotEmpty ? ' · ${p['note']}' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.attachment_outlined, size: 18, color: Color(0xFF909399)),
              tooltip: '附件',
              onPressed: () => showAttachmentPanel(context, 'purchase', '${p['id']}', '进货单附件'),
            ),
            Text('¥${p['total']}',
                style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFF56C6C))),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF409EFF)),
              onPressed: () => _editPurchase(p),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFF56C6C)),
              onPressed: () => _deletePurchase(p),
            ),
          ],
        ),
        onTap: () => _editPurchase(p),
      ),
    );
  }

  Widget _paymentCard(Map<String, dynamic> p) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.check_circle_outline, color: Color(0xFF67C23A)),
        title: Text('${p['client_name']}'),
        subtitle: Text(
          '${_date(p['happened_at'])}${(p['method'] as String? ?? '').isNotEmpty ? ' · ${p['method']}' : ''}'
          '${(p['note'] as String? ?? '').isNotEmpty ? ' · ${p['note']}' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.attachment_outlined, size: 18, color: Color(0xFF909399)),
              tooltip: '附件',
              onPressed: () => showAttachmentPanel(context, 'payment', '${p['id']}', '收款凭证'),
            ),
            Text('¥${p['amount']}',
                style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF67C23A))),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF409EFF)),
              onPressed: () => _editPayment(p),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFF56C6C)),
              onPressed: () => _deletePayment(p),
            ),
          ],
        ),
        onTap: () => _editPayment(p),
      ),
    );
  }
}