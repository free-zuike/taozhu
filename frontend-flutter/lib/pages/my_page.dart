import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../api.dart';
import '../theme.dart';
import '../version.dart';
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

  /// 版本号比较：a < b ?（四段 x.y.z.w）
  static bool _older(String a, String b) {
    final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (var i = 0; i < 4; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x < y;
    }
    return false;
  }

  /// 检查更新：GitHub Release 最新 tag 对比本地版本（公开仓库接口，无需鉴权）
  Future<void> _checkUpdate() async {
    final releaseUrl = 'https://github.com/free-zuike/taozhu/releases/latest';
    try {
      final res = await http.get(
        Uri.parse('https://api.github.com/repos/free-zuike/taozhu/releases/latest'),
        headers: const {'User-Agent': 'taozhu-app'},
      );
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final ver = '${body['tag_name'] ?? ''}'.replaceFirst(RegExp(r'^taozhu-v'), '');
      if (res.statusCode != 200 || ver.isEmpty) {
        toast(context, '无法获取最新版本（网络或接口限制）');
        return;
      }
      if (!_older(APP_VERSION, ver)) {
        toast(context, '当前已是最新版本 v$APP_VERSION');
        return;
      }
      if (!mounted) return;
      final copy = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('发现新版本'),
          content: Text('当前 v$APP_VERSION\n最新 v$ver\n\n点击「复制下载链接」后粘贴到浏览器下载 APK。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('复制下载链接')),
          ],
        ),
      );
      if (copy == true) {
        await Clipboard.setData(ClipboardData(text: releaseUrl));
        toast(context, '已复制下载链接');
      }
    } catch (e) {
      toast(context, '检查更新失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
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
                  leading: const Icon(Icons.system_update_alt_outlined),
                  title: const Text('检查更新'),
                  subtitle: const Text('对比 GitHub Release 最新版本', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right, color: Color(0xFF909399)),
                  onTap: _checkUpdate,
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
          const SizedBox(height: 16),
          Center(
            child: Text('陶朱 v$APP_VERSION',
                style: const TextStyle(color: Color(0xFF909399), fontSize: 12)),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
