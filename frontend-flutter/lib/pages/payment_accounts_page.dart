import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../local_accounts.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'payment_account_detail_page.dart';
import 'router.dart';

/// 收款账户页（参考账户页形态）：顶部总览卡（账户数/常用账户）+ 账户列表。
/// 每个账户带类型图标与说明，点击编辑、长按/按钮删除、底部新增。数据服务端同步实体。
class PaymentAccountsPage extends StatefulWidget {
  const PaymentAccountsPage({super.key});
  @override
  State<PaymentAccountsPage> createState() => _PaymentAccountsPageState();
}

class _AccountRow {
  final String id;
  final String name;
  /// 开户行（银行卡等；可空）
  final String bankName;
  /// 卡号后四位（可空；同类型多卡靠它区分）
  final String cardLastFour;
  /// 该账户进账总额（全部历史，按收款方式聚合，含平账减免）
  final double income;
  /// 该账户收款笔数
  final int count;
  /// 该账户本月进账/笔数（当月 happened_at）
  final double monthIncome;
  final int monthCount;
  _AccountRow(
    this.id,
    this.name, {
    this.bankName = '',
    this.cardLastFour = '',
    this.income = 0,
    this.count = 0,
    this.monthIncome = 0,
    this.monthCount = 0,
  });
}

class _PaymentAccountsPageState extends State<PaymentAccountsPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  List<_AccountRow> _accounts = [];
  bool _loading = true;
  bool _busy = false;

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

  /// 收款方式 → (进账总额, 笔数, 本月进账, 本月笔数)：原生从本地 payments 镜像聚合（零网络），Web 直连 stats
  Future<Map<String, (double, int, double, int)>> _incomeStats() async {
    if (kIsWeb) {
      try {
        final d = await Api.instance.get('/payment-accounts/stats');
        return {
          for (final s in ((d['stats'] as List?) ?? []).cast<Map<String, dynamic>>())
            '${s['method'] ?? ''}': (
              (s['total'] as num?)?.toDouble() ?? 0,
              (s['count'] as num?)?.toInt() ?? 0,
              (s['month_total'] as num?)?.toDouble() ?? 0,
              (s['month_count'] as num?)?.toInt() ?? 0,
            ),
        };
      } catch (_) {
        return {};
      }
    }
    try {
      final now = DateTime.now();
      final ym = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      final pays = await LocalDb.getAll('payments');
      final m = <String, (double, int, double, int)>{};
      for (final p in pays) {
        final method = '${p['method'] ?? ''}'.trim();
        if (method.isEmpty) continue;
        final (amt, cnt, mAmt, mCnt) = m[method] ?? (0.0, 0, 0.0, 0);
        final amt2 = ((p['amount'] as num?)?.toDouble() ?? 0) + ((p['waived'] as num?)?.toDouble() ?? 0);
        final isMonth = '${p['happened_at'] ?? ''}'.startsWith(ym);
        m[method] = (
          amt + amt2,
          cnt + 1,
          mAmt + (isMonth ? amt2 : 0),
          mCnt + (isMonth ? 1 : 0),
        );
      }
      return m;
    } catch (_) {
      return {};
    }
  }

  Future<void> _load() async {
    // 本地镜像秒开；服务器同步由 SyncService 增量驱动
    try {
      final local = await LocalDb.getAll('payment_accounts');
      if (local.isNotEmpty && mounted) {
        local.sort((a, b) =>
            ((a['sort'] as num?)?.toInt() ?? 0).compareTo((b['sort'] as num?)?.toInt() ?? 0));
        final stats = await _incomeStats();
        setState(() {
          _accounts = [
            for (final a in local)
              _AccountRow(
                '${a['id']}', '${a['name'] ?? ''}',
                bankName: '${a['bank_name'] ?? ''}',
                cardLastFour: '${a['card_last_four'] ?? ''}',
                income: stats['${a['name'] ?? ''}']?.$1 ?? 0,
                count: stats['${a['name'] ?? ''}']?.$2 ?? 0,
                monthIncome: stats['${a['name'] ?? ''}']?.$3 ?? 0,
                monthCount: stats['${a['name'] ?? ''}']?.$4 ?? 0,
              ),
          ];
          _loading = false;
        });
      } else {
        // 无本地镜像：直连服务器（首装/Web）
        final d = await Api.instance.get('/payment-accounts');
        final rows = ((d['accounts'] as List?) ?? [])
            .cast<Map<String, dynamic>>();
        final stats = await _incomeStats();
        await LocalDb.putAll('payment_accounts', [
          for (final r in rows)
            {'id': r['id'], 'name': r['name'], 'bank_name': r['bank_name'] ?? '', 'card_last_four': r['card_last_four'] ?? '', 'sort': 0},
        ]);
        if (mounted) {
          setState(() {
            _accounts = [
              for (final r in rows)
                _AccountRow(
                  '${r['id']}', '${r['name'] ?? ''}',
                  bankName: '${r['bank_name'] ?? ''}',
                  cardLastFour: '${r['card_last_four'] ?? ''}',
                  income: stats['${r['name'] ?? ''}']?.$1 ?? 0,
                  count: stats['${r['name'] ?? ''}']?.$2 ?? 0,
                  monthIncome: stats['${r['name'] ?? ''}']?.$3 ?? 0,
                  monthCount: stats['${r['name'] ?? ''}']?.$4 ?? 0,
                ),
            ];
            _loading = false;
          });
        }
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 账户类型图标（常见收款方式给专属图标，其余用钱包）
  (IconData, Color) _iconOf(String name) {
    final n = name.trim();
    if (n.contains('现金')) return (Icons.payments_outlined, const Color(0xFF67C23A));
    if (n.contains('微信')) return (Icons.forum_outlined, const Color(0xFF07C160));
    if (n.contains('支付宝')) return (Icons.account_balance_wallet_outlined, const Color(0xFF1677FF));
    if (n.contains('银行卡') || n.contains('银行') || n.contains('卡')) return (Icons.credit_card_outlined, const Color(0xFFF59A23));
    if (n.contains('转账') || n.contains('转')) return (Icons.swap_horiz_outlined, const Color(0xFF9B59B6));
    return (Icons.account_balance_wallet_outlined, const Color(0xFF409EFF));
  }

  /// 账户归类（与 _iconOf 同一套子串判定，用于分组）：现金/微信/支付宝/银行卡/转账/其他
  String _groupOf(String name) {
    final n = name.trim();
    if (n.contains('现金')) return '现金';
    if (n.contains('微信')) return '微信';
    if (n.contains('支付宝')) return '支付宝';
    if (n.contains('银行卡') || n.contains('银行') || n.contains('卡')) return '银行卡';
    if (n.contains('转账') || n.contains('转')) return '转账';
    return '其他';
  }

  /// 分组展示顺序（现金/微信/支付宝/银行卡/转账/其他）
  static const _groupOrder = ['现金', '微信', '支付宝', '银行卡', '转账', '其他'];

  /// 渐变账户卡片（对标参考项目 _AccountCard）：
  /// 类型色渐变底 + 圆图标 + 名称/开户行尾号 + 三格统计（进账/笔数/本月），点卡片进详情、右上编辑/删除
  Widget _accountCard(_AccountRow a) {
    final c = _c;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (icon, color) = _iconOf(a.name);
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PaymentAccountDetailPage(accountName: a.name))),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: dark
                ? [color.withValues(alpha: 0.25), color.withValues(alpha: 0.12)]
                : [color, color.withValues(alpha: 0.8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: dark
              ? null
              : [
                  BoxShadow(
                    color: color.withValues(alpha: 0.15),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部行：圆图标 + 名称(+卡号) + 编辑/删除
                Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Center(child: Icon(icon, size: 18, color: Colors.white)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(a.name,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          if (a.bankName.isNotEmpty || a.cardLastFour.isNotEmpty)
                            Text(
                              [
                                if (a.bankName.isNotEmpty) a.bankName,
                                if (a.cardLastFour.isNotEmpty) '尾号${a.cardLastFour}',
                              ].join(' · '),
                              style: TextStyle(
                                  fontSize: 11, color: Colors.white.withValues(alpha: 0.85)),
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: () => _rename(a),
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.edit, color: Colors.white, size: 14),
                      ),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: () => _remove(a),
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.delete_outline, color: Colors.white, size: 14),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 三格统计：进账 / 笔数 / 本月进账
                Row(
                  children: [
                    Expanded(
                      child: _cardStat('进账', '¥${fmtMoney(a.income)}'),
                    ),
                    Container(width: 1, height: 26, color: Colors.white.withValues(alpha: 0.2)),
                    Expanded(
                      child: _cardStat('笔数', '${a.count}'),
                    ),
                    Container(width: 1, height: 26, color: Colors.white.withValues(alpha: 0.2)),
                    Expanded(
                      child: _cardStat('本月进账', '¥${fmtMoney(a.monthIncome)}'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 卡片内单格统计（label 小字 + value 大字，白色系）
  Widget _cardStat(String label, String value) {
    return Column(
      children: [
        Text(label,
            style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.85))),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(value,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
        ),
      ],
    );
  }

  Future<void> _add() async {
    final nameCtrl = TextEditingController();
    final bankCtrl = TextEditingController();
    final cardCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增收款账户'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, autofocus: true, decoration: const InputDecoration(labelText: '账户名称（现金/微信/支付宝/银行卡…）')),
            const SizedBox(height: 10),
            TextField(controller: bankCtrl, decoration: const InputDecoration(labelText: '开户行（银行卡填，可留空）')),
            const SizedBox(height: 10),
            TextField(controller: cardCtrl, keyboardType: TextInputType.number, maxLength: 4,
                decoration: const InputDecoration(labelText: '卡号后四位（同类型多卡用于区分，可留空）', counterText: '')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('添加')),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) {
      toast(context, '请输入账户名称');
      return;
    }
    if (_accounts.any((a) => a.name == name)) {
      toast(context, '该账户已存在');
      return;
    }
    await _save([
      for (final a in _accounts) {'name': a.name, 'bank_name': a.bankName, 'card_last_four': a.cardLastFour},
      {'name': name, 'bank_name': bankCtrl.text.trim(), 'card_last_four': cardCtrl.text.trim()},
    ]);
  }

  Future<void> _rename(_AccountRow row) async {
    final nameCtrl = TextEditingController(text: row.name);
    final bankCtrl = TextEditingController(text: row.bankName);
    final cardCtrl = TextEditingController(text: row.cardLastFour);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑账户'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, autofocus: true, decoration: const InputDecoration(labelText: '账户名称')),
            const SizedBox(height: 10),
            TextField(controller: bankCtrl, decoration: const InputDecoration(labelText: '开户行（银行卡填，可留空）')),
            const SizedBox(height: 10),
            TextField(controller: cardCtrl, keyboardType: TextInputType.number, maxLength: 4,
                decoration: const InputDecoration(labelText: '卡号后四位（可留空）', counterText: '')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) {
      toast(context, '请输入账户名称');
      return;
    }
    if (name != row.name && _accounts.any((a) => a.name == name)) {
      toast(context, '该账户已存在');
      return;
    }
    await _save([
      for (final a in _accounts)
        if (a.id == row.id)
          {'name': name, 'bank_name': bankCtrl.text.trim(), 'card_last_four': cardCtrl.text.trim()}
        else
          {'name': a.name, 'bank_name': a.bankName, 'card_last_four': a.cardLastFour},
    ]);
  }

  Future<void> _remove(_AccountRow row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账户'),
        content: Text('确定删除「${row.name}」吗？\n历史收款记录不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _c.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _save([
      for (final a in _accounts)
        if (a.id != row.id) {'name': a.name, 'bank_name': a.bankName, 'card_last_four': a.cardLastFour},
    ]);
  }

  /// 全量覆盖服务端账户列表（含开户行/卡号），成功后刷新镜像
  Future<void> _save(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) {
      toast(context, '至少保留一个账户');
      return;
    }
    setState(() => _busy = true);
    try {
      await LocalAccounts.save(items);
      await _load();
      toast(context, '已保存，正在同步');
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      appBar: AppBar(
        title: const Text('收款账户'),
        actions: [
          IconButton(tooltip: '新增账户', icon: const Icon(Icons.add), onPressed: _busy ? null : _add),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  // 总览卡：账户数 + 全部账户累计进账
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
                              Text('${_accounts.length} 个收款账户 · 累计进账 ¥${fmtMoney(_accounts.fold<double>(0, (s, a) => s + a.income))}',
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                              const SizedBox(height: 2),
                              Text('登记收款时下拉选择；点账户可改名，右侧删除',
                                  style: TextStyle(fontSize: 12, color: c.textSub)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  // 账户分组卡片（对标参考项目资产分类：类型标题 + 渐变卡 + 三格统计）
                  for (final g in _groupOrder)
                    if (_accounts.any((a) => _groupOf(a.name) == g)) ...[
                      Padding(
                        padding: const EdgeInsets.only(left: 4, right: 4, top: 6, bottom: 6),
                        child: Row(
                          children: [
                            Icon(_iconOf(g == '银行卡' ? '银行卡' : g).$1,
                                size: 15, color: _iconOf(g).$2),
                            const SizedBox(width: 6),
                            Text(g,
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700)),
                            const Spacer(),
                            Text(
                              '进账 ¥${fmtMoney(_accounts.where((a) => _groupOf(a.name) == g).fold<double>(0, (s, a) => s + a.income))}',
                              style: TextStyle(fontSize: 12, color: c.textSub),
                            ),
                          ],
                        ),
                      ),
                      for (final a in _accounts.where((x) => _groupOf(x.name) == g))
                        _accountCard(a),
                      const SizedBox(height: 6),
                    ],
                  if (_accounts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        children: [
                          Icon(Icons.account_balance_wallet_outlined, size: 40, color: c.textSub.withValues(alpha: 0.4)),
                          const SizedBox(height: 10),
                          Text('暂无账户，点右上角 ＋ 添加', style: TextStyle(color: c.textSub)),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text('收款账户为服务器同步数据：App/Web/小程序共用，改后在收款页下拉中生效。',
                      style: TextStyle(fontSize: 11, color: c.textSub)),
                ],
              ),
            ),
    );
  }
}