import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';
import 'router.dart';

/// 账号管理（仅老板，后端 adminOnly；店员打开会收到 403 提示）
class UsersPage extends StatefulWidget {
  const UsersPage({super.key});
  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await Api.instance.get('/users');
      if (!mounted) return;
      setState(() {
        _users = ((d['users'] as List?) ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _addOrEdit([Map<String, dynamic>? u]) async {
    final usernameCtrl = TextEditingController(text: u?['username'] as String? ?? '');
    final pwdCtrl = TextEditingController();
    String role = '${u?['role'] ?? 'staff'}' == 'admin' ? 'admin' : 'staff';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(u == null ? '新增账号' : '编辑账号'),
        content: StatefulBuilder(
          builder: (ctx, setDlg) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: usernameCtrl, decoration: const InputDecoration(labelText: '登录名 *')),
              const SizedBox(height: 8),
              TextField(
                controller: pwdCtrl,
                obscureText: true,
                decoration: InputDecoration(
                    labelText: u == null ? '密码 *（至少 6 位）' : '新密码（留空不改）'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: role,
                decoration: const InputDecoration(labelText: '角色'),
                items: const [
                  DropdownMenuItem(value: 'staff', child: Text('店员')),
                  DropdownMenuItem(value: 'admin', child: Text('老板')),
                ],
                onChanged: (v) => setDlg(() => role = v ?? 'staff'),
              ),
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
    final username = usernameCtrl.text.trim();
    final password = pwdCtrl.text.trim();
    if (username.isEmpty) {
      toast(context, '请填写登录名');
      return;
    }
    if (password.isNotEmpty && password.length < 6) {
      toast(context, '密码至少 6 位');
      return;
    }
    if (u == null && password.isEmpty) {
      toast(context, '请填写密码（至少 6 位）');
      return;
    }
    try {
      if (u == null) {
        await Api.instance.post('/users', {'username': username, 'password': password, 'role': role});
      } else {
        await Api.instance.patch('/users/${u['id']}', {
          'username': username,
          if (password.isNotEmpty) 'password': password,
          'role': role,
        });
      }
      toast(context, '已保存');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _delete(Map<String, dynamic> u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账号'),
        content: Text('确定删除「${u['username']}」吗？'),
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
    try {
      await Api.instance.delete('/users/${u['id']}');
      toast(context, '已删除');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      appBar: AppBar(
        title: const Text('账号管理'),
        actions: [
          IconButton(onPressed: () => _addOrEdit(), icon: const Icon(Icons.add)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final u in _users)
                    Card(
                      child: ListTile(
                        leading: Icon(
                          '${u['role']}' == 'admin' ? Icons.verified_user : Icons.person_outline,
                          color: '${u['role']}' == 'admin'
                              ? c.danger
                              : c.primary,
                        ),
                        title: Text('${u['display_name'] ?? u['username']}'),
                        subtitle: Text('${'${u['role']}' == 'admin' ? '老板' : '店员'} · 登录 ${u['username']}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(Icons.edit_outlined, size: 20, color: c.primary),
                              onPressed: () => _addOrEdit(u),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline, size: 20, color: c.danger),
                              onPressed: () => _delete(u),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_users.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(child: Text('暂无账号', style: TextStyle(color: c.textSub))),
                    ),
                ],
              ),
            ),
    );
  }
}