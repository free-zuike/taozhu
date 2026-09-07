import 'package:flutter/material.dart';
import '../api.dart';
import 'router.dart';
import 'items_page.dart';
import 'categories_page.dart';
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
          const Text('功能', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
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
