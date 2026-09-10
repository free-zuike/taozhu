import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';
import '../pages/sale_page.dart';
import '../pages/my_page.dart';
import '../pages/purchase_page.dart';
import '../pages/purchase_history_page.dart';
import '../pages/ledger_page.dart';
import '../pages/stats_page.dart';

/// 底部悬浮胶囊导航（对齐移动记账信息架构）：
/// 交易（流水，账本=店铺胶囊筛选，出货·收款）/ 统计 / 中央「记一笔」/ 进货（记录，独立不分店）/ 我的
class BottomShell extends StatefulWidget {
  const BottomShell({super.key});
  @override
  State<BottomShell> createState() => _BottomShellState();
}

class _BottomShellState extends State<BottomShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _isStaff = false; // 店员：无统计权限，隐藏统计 tab

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Api.instance.getRole().then((r) {
      if (mounted) setState(() => _isStaff = r == 'staff');
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 回到前台时自动重放离线待同步单据（静默：成功不打扰）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Api.instance.syncPending();
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: _isStaff
            ? const [LedgerPage(), PurchaseHistoryPage(), MyPage()]
            : const [LedgerPage(), StatsPage(), PurchaseHistoryPage(), MyPage()],
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF1E1E1E) : Colors.white.withOpacity(0.96),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(dark ? 0.25 : 0.08), blurRadius: 16, offset: const Offset(0, 4)),
            ],
          ),
          child: Row(
            children: [
              _navItem(0, Icons.receipt_long_outlined, '交易'),
              if (!_isStaff) _navItem(1, Icons.bar_chart_outlined, '统计'),
              _centerButton(),
              _navItem(_isStaff ? 1 : 2, Icons.shopping_cart_outlined, '进货'),
              _navItem(_isStaff ? 2 : 3, Icons.person_outline, '我的'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(int i, IconData icon, String label) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    final active = _index == i;
    final color = active ? c.primary : c.textSub;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => setState(() => _index = i),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(fontSize: 11, color: color, fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
          ],
        ),
      ),
    );
  }

  Widget _centerButton() {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onTap: _showQuickBook,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: c.primary,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: c.primary.withOpacity(0.4), blurRadius: 10, offset: const Offset(0, 3))],
          ),
          child: const Icon(Icons.add, color: Colors.white, size: 30),
        ),
      ),
    );
  }

  void _showQuickBook() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('记一笔', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            ),
            ListTile(
              leading: const Icon(Icons.storefront, color: Color(0xFF409EFF)),
              title: const Text('出货记单'),
              subtitle: const Text('给店铺送货'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SalePage()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.shopping_cart, color: Color(0xFF67C23A)),
              title: const Text('进货记单'),
              subtitle: const Text('从供应商进货'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PurchasePage()));
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
