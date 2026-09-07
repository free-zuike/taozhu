import 'package:flutter/material.dart';
import '../api.dart';
import 'home_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _baseCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _initialized = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final d = await Api.instance.get('/auth/bootstrap/status');
      setState(() => _initialized = d['initialized'] == true);
    } catch (_) {
      setState(() => _initialized = true);
    }
    _baseCtrl.text = await Api.instance.getBase();
  }

  Future<void> _submit() async {
    if (_userCtrl.text.trim().isEmpty || _passCtrl.text.isEmpty) {
      _toast('请输入登录名和密码');
      return;
    }
    setState(() => _busy = true);
    try {
      await Api.instance.setBase(_baseCtrl.text);
      final d = _initialized
          ? await Api.instance.post('/auth/login', {
              'username': _userCtrl.text.trim(),
              'password': _passCtrl.text,
            })
          : await Api.instance.post('/auth/bootstrap', {
              'username': _userCtrl.text.trim(),
              'password': _passCtrl.text,
            });
      await Api.instance.setToken(d['token'] as String);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('陶朱', style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('v0.1.0.0', style: TextStyle(color: Colors.grey, fontSize: 14)),
              const SizedBox(height: 32),
              TextField(
                controller: _baseCtrl,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: '留空=当前网页；App 填 https://xxx.workers.dev',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _userCtrl,
                decoration: const InputDecoration(labelText: '登录名', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码', border: OutlineInputBorder()),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Text(_busy ? '登录中…' : (_initialized ? '登录' : '创建账号并登录')),
                ),
              ),
              if (!_initialized) ...[
                const SizedBox(height: 12),
                const Text('首次使用：以上为老板账号，创建后即可登录', style: TextStyle(color: Colors.orange, fontSize: 13)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}