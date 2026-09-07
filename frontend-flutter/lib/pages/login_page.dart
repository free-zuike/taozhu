import 'package:flutter/material.dart';
import '../api.dart';
import '../version.dart';
import '../widgets/bottom_shell.dart';

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
    if (_baseCtrl.text.trim().isEmpty) {
      _toast('请先填写服务器地址（必填）：您自己的服务器，如 https://您的域名');
      return;
    }
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
      Navigator.of(context)
          .pushReplacement(MaterialPageRoute(builder: (_) => const BottomShell()));
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
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('陶朱',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
                    const Text('v$APP_VERSION',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xFF909399), fontSize: 13)),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _baseCtrl,
                      decoration: const InputDecoration(
                        labelText: '服务器地址',
                        hintText: '必填：您的服务器地址，如 https://xxx.com',
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _userCtrl,
                      decoration: const InputDecoration(labelText: '登录名'),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _passCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '密码'),
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                      onPressed: _busy ? null : _submit,
                      child: Text(_busy ? '登录中…' : (_initialized ? '登录' : '创建账号并登录')),
                    ),
                    if (!_initialized) ...[
                      const SizedBox(height: 12),
                      const Text('首次使用：以上为老板账号，创建后即可登录',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFFE6A23C), fontSize: 13)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}