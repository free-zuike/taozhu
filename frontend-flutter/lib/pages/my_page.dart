import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';
import 'router.dart';
import 'items_page.dart';
import 'categories_page.dart';
import 'ledger_page.dart';
import 'statement_page.dart';
import 'users_page.dart';
import 'login_page.dart';

class MyPage extends StatefulWidget {
  const MyPage({super.key});
  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  String _base = '';

  @override
  void initState() {
    super.initState();
    Api.instance.getBase().then((b) {
      if (mounted) setState(() => _base = b);
    });
  }

  Future<void> _logout() async {
    await Api.instance.clearToken();
    if (!mounted) return;
    Navigator.of(context)
        .pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginPage()), (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.dns_outlined, color: Color(0xFF409EFF)),
              title: const Text('服务器地址', style: TextStyle(fontSize: 13, color: Color(0xFF909399))),
              subtitle: Text(_base.isEmpty ? '未设置' : _base),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.dark_mode_outlined),
              title: const Text('深色模式'),
              subtitle: const Text('夜间/白天主题切换', style: TextStyle(fontSize: 12)),
              value: themeNotifier.value == ThemeMode.dark,
              onChanged: (v) => setThemeMode(v ? ThemeMode.dark : ThemeMode.light),
            ),
          ),
          const SizedBox(height: 12),
          const Text('功能', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('账本'),
                  subtitle: const Text('出货 / 进货 / 收款历史，可修改、删除', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right, color: Color(0xFF909399)),
                  onTap: () => goPage(context, const LedgerPage()),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('对账单'),
                  subtitle: const Text('按店铺+周期生成对账明细，一键复制发送', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right, color: Color(0xFF909399)),
                  onTap: () => goPage(context, const StatementPage()),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.people_outline),
                  title: const Text('账号管理'),
                  subtitle: const Text('店员/老板账号（仅老板可操作）', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right, color: Color(0xFF909399)),
                  onTap: () => goPage(context, const UsersPage()),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: const Text('商品管理'),
                  trailing: const Icon(Icons.chevron_right, color: Color(0xFF909399)),
                  onTap: () => goPage(context, const ItemsPage()),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.label_outline),
                  title: const Text('分类管理'),
                  subtitle: const Text('商品分类 / 店铺分类（两级）', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right, color: Color(0xFF909399)),
                  onTap: () => goPage(context, const CategoriesPage()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: const Color(0xFFF56C6C),
              side: const BorderSide(color: Color(0xFFF56C6C)),
            ),
            onPressed: _logout,
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
  }
}
