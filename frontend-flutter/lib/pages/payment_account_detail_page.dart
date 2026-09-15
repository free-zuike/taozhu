import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';

/// 账户详情页：某收款方式（账户）的进账流水列表 + 顶部统计。
/// 原生读本地 payments 镜像按 method 过滤（零网络）；Web 直连 /payments?method=
class PaymentAccountDetailPage extends StatefulWidget {
  const PaymentAccountDetailPage({super.key, required this.accountName});
  final String accountName;
  @override
  State<PaymentAccountDetailPage> createState() => _PaymentAccountDetailPageState();
}

class _PaymentAccountDetailPageState extends State<PaymentAccountDetailPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  List<Map<String, dynamic>> _payments = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
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

  /// 本地店铺镜像：client_id → name（同步 payload 不带 client_name，原生本地反查）
  final Map<String, String> _clientNames = {};

  Future<void> _loadClients() async {
    try {
      for (final c in await LocalDb.getAllByName('clients')) {
        _clientNames['${c['id']}'] = '${c['name'] ?? ''}';
      }
    } catch (_) {}
  }

  String _clientNameOf(Map<String, dynamic> p) {
    final direct = '${p['client_name'] ?? ''}'.trim();
    if (direct.isNotEmpty) return direct;
    return _clientNames['${p['client_id'] ?? ''}'] ?? '';
  }

  Future<void> _load() async {
    await _loadClients();
    try {
      List<Map<String, dynamic>> rows;
      if (kIsWeb) {
        final d = await Api.instance
            .get('/payments?method=${Uri.encodeQueryComponent(widget.accountName)}&limit=500');
        rows = ((d['payments'] as List?) ?? []).cast<Map<String, dynamic>>();
      } else {
        final all = await LocalDb.getAll('payments');
        rows = [
          for (final p in all)
            if ('${p['method'] ?? ''}'.trim() == widget.accountName) p,
        ]..sort((a, b) => '${b['happened_at'] ?? ''}'.compareTo('${a['happened_at'] ?? ''}'));
      }
      if (!mounted) return;
      setState(() {
        _payments = rows;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _date(String? iso) {
    if (iso == null || iso.length < 10) return '';
    return iso.substring(0, 10);
  }

  /// 全部进账合计（含平账减免）
  double get _totalIncome =>
      _payments.fold<double>(0, (s, p) => s + ((p['amount'] as num?)?.toDouble() ?? 0) + ((p['waived'] as num?)?.toDouble() ?? 0));

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      appBar: AppBar(title: Text(widget.accountName)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  // 顶部统计卡：进账合计 / 笔数
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: c.card,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: c.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.account_balance_wallet_outlined, color: c.primary, size: 24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('进账合计 ¥${fmtMoney(_totalIncome)}',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                              const SizedBox(height: 2),
                              Text('${_payments.length} 笔收款记录',
                                  style: TextStyle(fontSize: 12, color: c.textSub)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  // 流水列表
                  if (_payments.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        children: [
                          Icon(Icons.receipt_long_outlined, size: 40, color: c.textSub.withValues(alpha: 0.4)),
                          const SizedBox(height: 10),
                          Text('该收款方式暂无进账记录', style: TextStyle(color: c.textSub)),
                        ],
                      ),
                    )
                  else
                    Container(
                      decoration: BoxDecoration(
                        color: c.card,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          for (final (i, p) in _payments.indexed) ...[
                            if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: c.divider),
                            ListTile(
                              dense: true,
                              leading: Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: c.success.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(Icons.south_west, size: 16, color: c.success),
                              ),
                              title: Text(_clientNameOf(p),
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                _date('${p['happened_at'] ?? ''}'),
                                style: TextStyle(fontSize: 12, color: c.textSub),
                              ),
                              trailing: Text(
                                '¥${fmtMoney((p['amount'] as num?)?.toDouble() ?? 0)}',
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600, color: c.success),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
