import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../local_accounts.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'router.dart';

/// 收款账户页（参考 beecount 账户页）：顶部总览卡（账户数/常用账户）+ 账户列表。
/// 每个账户带类型图标与说明，点击编辑、长按/按钮删除、底部新增。数据服务端同步实体。
class PaymentAccountsPage extends StatefulWidget {
  const PaymentAccountsPage({super.key});
  @override
  State<PaymentAccountsPage> createState() => _PaymentAccountsPageState();
}

class _AccountRow {
  final String id;
  final String name;
  _AccountRow(this.id, this.name);
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

  Future<void> _load() async {
    // 本地镜像秒开；服务器同步由 SyncService 增量驱动
    try {
      final local = await LocalDb.getAll('payment_accounts');
      if (local.isNotEmpty && mounted) {
        local.sort((a, b) =>
            ((a['sort'] as num?)?.toInt() ?? 0).compareTo((b['sort'] as num?)?.toInt() ?? 0));
        setState(() {
          _accounts = [for (final a in local) _AccountRow('${a['id']}', '${a['name'] ?? ''}')];
          _loading = false;
        });
      } else {
        // 无本地镜像：直连服务器（首装/Web）
        final d = await Api.instance.get('/payment-accounts');
        final rows = ((d['accounts'] as List?) ?? [])
            .cast<Map<String, dynamic>>()
            .map((a) => _AccountRow('${a['id']}', '${a['name'] ?? ''}'))
            .toList();
        await LocalDb.putAll('payment_accounts', [
          for (final r in rows) {'id': r.id, 'name': r.name, 'sort': 0},
        ]);
        if (mounted) {
          setState(() {
            _accounts = rows;
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

  /// 账户用途说明（参考 beecount：每账户一行说明）
  String _hintOf(String name) {
    final n = name.trim();
    if (n.contains('现金')) return '线下现金收款';
    if (n.contains('微信')) return '微信扫码 / 转账';
    if (n.contains('支付宝')) return '支付宝收款';
    if (n.contains('银行卡') || n.contains('银行')) return '银行转账 / 对公';
    if (n.contains('转账')) return '其他转账方式';
    return '自定义收款方式';
  }

  Future<void> _add() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增收款账户'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: '账户名称（如 现金/微信/支付宝…）')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('添加')),
        ],
      ),
    );
    if (ok != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty) {
      toast(context, '请输入账户名称');
      return;
    }
    if (_accounts.any((a) => a.name == name)) {
      toast(context, '该账户已存在');
      return;
    }
    await _save([..._accounts.map((a) => a.name), name]);
  }

  Future<void> _rename(_AccountRow row) async {
    final ctrl = TextEditingController(text: row.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名账户'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: '账户名称')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty || name == row.name) return;
    if (_accounts.any((a) => a.name == name)) {
      toast(context, '该账户已存在');
      return;
    }
    await _save([for (final a in _accounts) a.name == row.name ? name : a.name]);
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
    await _save([for (final a in _accounts) if (a.id != row.id) a.name]);
  }

  /// 全量覆盖服务端账户列表，成功后刷新镜像
  Future<void> _save(List<String> names) async {
    if (names.isEmpty) {
      toast(context, '至少保留一个账户');
      return;
    }
    setState(() => _busy = true);
    try {
      await LocalAccounts.save(names);
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
                  // 总览卡：账户数 + 提示（参考 beecount 顶部汇总）
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
                            color: c.primary.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.account_balance_wallet_outlined, color: c.primary, size: 24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${_accounts.length} 个收款账户',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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
                  // 账户列表（beecount 式：图标 + 名称 + 说明）
                  Container(
                    decoration: BoxDecoration(
                      color: c.card,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        for (final (i, a) in _accounts.indexed) ...[
                          if (i > 0) Divider(height: 1, indent: 56, color: c.divider),
                          ListTile(
                            leading: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: _iconOf(a.name).$2.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(_iconOf(a.name).$1, size: 20, color: _iconOf(a.name).$2),
                            ),
                            title: Text(a.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                            subtitle: Text(_hintOf(a.name), style: TextStyle(fontSize: 12, color: c.textSub)),
                            onTap: () => _rename(a),
                            trailing: IconButton(
                              icon: Icon(Icons.delete_outline, size: 20, color: c.danger),
                              tooltip: '删除',
                              onPressed: () => _remove(a),
                            ),
                          ),
                        ],
                        if (_accounts.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              children: [
                                Icon(Icons.account_balance_wallet_outlined, size: 40, color: c.textSub.withOpacity(0.4)),
                                const SizedBox(height: 10),
                                Text('暂无账户，点右上角 ＋ 添加', style: TextStyle(color: c.textSub)),
                              ],
                            ),
                          ),
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