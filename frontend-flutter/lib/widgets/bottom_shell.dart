import 'package:flutter/material.dart';
import '../pages/home_page.dart';
import '../pages/my_page.dart';
import '../pages/purchase_page.dart';
import '../pages/ledger_page.dart';
import '../pages/stats_page.dart';

/// 底部悬浮胶囊导航壳（对齐移动记账信息架构）：
/// 工作台 / 交易（流水，顶栏店铺胶囊=选账本，含出货·进货·收款）/ 中央「记一笔」/ 统计（洞察）/ 我的
/// 出货/进货记单通过中央 + 添加；店铺（账本）管理在「我的」
class BottomShell extends StatefulWidget {
  const BottomShell({super.key});
  @override
  State<BottomShell> createState() => _BottomShellState();
}

class _BottomShellState extends State<BottomShell> {
  int _index = 0;
  static const _primary = Color(0xFF409EFF);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [HomePage(), LedgerPage(), StatsPage(), MyPage()],
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
              _navItem(1, Icons.bar_chart_outlined, '统计'),
              _centerButton(),
              _navItem(2, Icons.dashboard_outlined, '工作台'),
              _navItem(3, Icons.person_outline, '我的'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(int i, IconData icon, String label) {
    final active = _index == i;
    final color = active ? _primary : const Color(0xFF909399);
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onTap: _showQuickBook,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: _primary,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: _primary.withOpacity(0.4), blurRadius: 10, offset: const Offset(0, 3))],
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
