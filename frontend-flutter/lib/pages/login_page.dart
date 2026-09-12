import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';
import '../version.dart';
import '../widgets/bottom_shell.dart';
import 'router.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _baseCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _initialized = true;
  bool _busy = false;
  bool _needTotp = false; // 该账号已开启两步验证，等待输入验证码

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
    _baseCtrl.text = kIsWeb ? Uri.base.origin : await Api.instance.getBase();
  }

  Future<void> _submit() async {
    // Web：自动使用当前访问的域名作为服务器地址（自部署/fork 都正确）；App/桌面手动填写
    final base = kIsWeb ? Uri.base.origin : _baseCtrl.text.trim();
    if (base.isEmpty) {
      _toast('请先填写服务器地址（必填）：您自己的服务器，如 https://您的域名');
      return;
    }
    if (_userCtrl.text.trim().isEmpty || _passCtrl.text.isEmpty) {
      _toast('请输入登录名和密码');
      return;
    }
    setState(() => _busy = true);
    try {
      await Api.instance.setBase(base);
      final d = _initialized
          ? await Api.instance.post('/auth/login', {
              'username': _userCtrl.text.trim(),
              'password': _passCtrl.text,
              if (_needTotp) 'code': _codeCtrl.text.trim(),
            })
          : await Api.instance.post('/auth/bootstrap', {
              'username': _userCtrl.text.trim(),
              'password': _passCtrl.text,
            });
      // 两步验证：密码正确但缺验证码 → 显示验证码输入框，再次提交
      if (d['need_totp'] == true) {
        if (mounted) setState(() => _needTotp = true);
        _toast('该账号已开启两步验证，请输入验证码');
        return;
      }
      await Api.instance.setToken(d['token'] as String);
      await Api.instance.setRole('${(d['user'] as Map?)?['role'] ?? ''}');
      // 登录名/头像状态以 /auth/me 为准（登录响应不含头像）
      try {
        final me = await Api.instance.get('/auth/me');
        final mu = me['user'] as Map?;
        if (mu != null) {
          await Api.instance.setUsername('${mu['username'] ?? ''}');
          await Api.instance.setAvatar(mu['avatar'] != null);
        }
      } catch (_) {}
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
    toast(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(20),
                boxShadow: dark
                    ? null
                    : [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 24, offset: const Offset(0, 8))],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 品牌区
                  Center(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: c.primary.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Icon(Icons.storefront, size: 34, color: c.primary),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('陶朱',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: c.textMain)),
                  const SizedBox(height: 6),
                  Text('出货 · 进货 · 收款 · 库存',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.textSub, fontSize: 13)),
                  const SizedBox(height: 28),
                  if (kIsWeb) ...[
                    // Web：自动使用当前访问的域名，无需填写
                    Text('当前服务器：${Uri.base.origin}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.textSub, fontSize: 12)),
                    const SizedBox(height: 14),
                  ] else ...[
                    _field(_baseCtrl, Icons.dns_outlined, '服务器地址', '您的服务器地址，如 https://xxx.com'),
                    const SizedBox(height: 14),
                  ],
                  _field(_userCtrl, Icons.person_outline, '登录名', null),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passCtrl,
                    obscureText: true,
                    style: TextStyle(color: c.textMain),
                    decoration: _dec(Icons.lock_outline, '密码', null),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_needTotp) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _codeCtrl,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      style: TextStyle(color: c.textMain),
                      decoration: _dec(Icons.security_outlined, '两步验证码', '验证器 App 里的 6 位数字'),
                      onSubmitted: (_) => _submit(),
                    ),
                  ],
                  const SizedBox(height: 26),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: c.primary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    onPressed: _busy ? null : _submit,
                    child: Text(_busy
                        ? '登录中…'
                        : _needTotp
                            ? '验证并登录'
                            : (_initialized ? '登录' : '创建账号并登录')),
                  ),
                  if (!_initialized) ...[
                    const SizedBox(height: 12),
                    Text('首次使用：以上为老板账号，创建后即可登录',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.warning, fontSize: 13)),
                  ],
                  const SizedBox(height: 16),
                  Text('v$APP_VERSION',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.textSub, fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _dec(IconData icon, String label, String? hint) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, size: 20, color: c.textSub),
      filled: true,
      fillColor: c.field,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.primary, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }

  Widget _field(TextEditingController ctrl, IconData icon, String label, String? hint) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return TextField(
      controller: ctrl,
      style: TextStyle(color: c.textMain),
      decoration: _dec(icon, label, hint),
    );
  }
}