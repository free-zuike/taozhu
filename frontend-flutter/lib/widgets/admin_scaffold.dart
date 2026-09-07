import 'package:flutter/material.dart';

/// 管理后台框架（对齐第一版 Web：Element Plus 风格）
/// 左侧深色菜单 + 白顶栏标题 + 浅灰内容区；宽屏左侧栏固定，窄屏折叠为抽屉。
class AdminScaffold extends StatelessWidget {
  final int selectedIndex;
  final String title;
  final Widget body;
  final void Function(int index) onSelect;

  const AdminScaffold({
    super.key,
    required this.selectedIndex,
    required this.title,
    required this.body,
    required this.onSelect,
  });

  static const Color bg = Color(0xFFF5F7FA);
  static const Color primary = Color(0xFF409EFF);
  static const Color sidebarBg = Color(0xFF1F2D3D);

  static const List<(String, IconData)> menuItems = [
    ('工作台', Icons.dashboard_outlined),
    ('出货记单', Icons.shopping_cart_outlined),
    ('进货记单', Icons.inventory_2_outlined),
    ('商品管理', Icons.category_outlined),
    ('饭店管理', Icons.store_outlined),
    ('收款结账', Icons.account_balance_wallet_outlined),
    ('统计', Icons.trending_up),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth > 700;
          return Row(
            children: [
              if (wide) _sidebar(context, wide: true),
              Expanded(
                child: Column(
                  children: [
                    _header(context, wide),
                    Expanded(child: body),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sidebar(BuildContext context, {required bool wide}) {
    final children = [
      Container(
        height: 56,
        alignment: Alignment.center,
        color: const Color(0xFF18232F),
        child: const Text('陶朱',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
      ),
      for (int i = 0; i < menuItems.length; i++)
        InkWell(
          onTap: () => onSelect(i),
          child: Container(
            color: i == selectedIndex ? const Color(0xFF263445) : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              children: [
                Icon(menuItems[i].$2,
                    size: 18, color: i == selectedIndex ? primary : const Color(0xFFC0C4CC)),
                const SizedBox(width: 12),
                Text(menuItems[i].$1,
                    style: TextStyle(
                        color: i == selectedIndex ? Colors.white : const Color(0xFFC0C4CC),
                        fontSize: 14)),
              ],
            ),
          ),
        ),
    ];

    return Container(
      width: 200,
      color: sidebarBg,
      child: wide
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)
          : Drawer(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)),
    );
  }

  Widget _header(BuildContext context, bool wide) {
    return Container(
      height: 56,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (!wide)
            IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(context).openDrawer()),
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}