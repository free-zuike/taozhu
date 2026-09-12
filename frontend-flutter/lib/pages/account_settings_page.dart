import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../api.dart';
import '../avatar_cache.dart';
import '../log.dart';
import '../theme.dart';
import '../widgets/user_avatar.dart';
import 'router.dart';

/// 账号设置（自助）：头像 / 用户名 / 密码 / 两步验证（TOTP）/ 服务器地址。
/// 老板与店员都能改自己的资料；服务器地址仅 App/桌面端可改（Web 自动用访问域名）。
/// embed=true 时只渲染内容（供「成员」页 Tab 嵌入，不带自己的 AppBar）。
class AccountSettingsPage extends StatefulWidget {
  const AccountSettingsPage({super.key, this.embed = false});
  final bool embed;
  @override
  State<AccountSettingsPage> createState() => _AccountSettingsPageState();
}

class _AccountSettingsPageState extends State<AccountSettingsPage> {
  String _username = ''; // 显示名（可改）
  String _account = ''; // 登录账号（不可改）
  String _role = '';
  String _base = '';
  String _avatarUrl = '';
  String _avatarToken = '';
  String _avatarLocalPath = ''; // 本地头像副本（离线也显示）
  bool _avatar = false;
  bool _totpOn = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // 本地数据先渲染（秒开，不依赖网络）
    _username = await Api.instance.getUsername();
    _account = await Api.instance.getAccount();
    _role = await Api.instance.getRole();
    _base = await Api.instance.getBase();
    _avatar = await Api.instance.hasAvatar();
    _avatarLocalPath = (await avatarLocalFile())?.path ?? '';
    // 时间戳缓存破坏：改头像后 Image.network 立即显示新图
    _avatarUrl = '${await Api.instance.avatarUrl()}?t=${DateTime.now().millisecondsSinceEpoch}';
    _avatarToken = await Api.instance.getTokenValue() ?? '';
    if (mounted) setState(() => _loading = false);
    // 后台验证更新：有更新直接应用，没变化跳过；无网络只记日志不打扰
    await _refresh();
  }

  /// 后台验证：以 /auth/me 为准刷新（有更新直接应用；失败保留本地缓存，仅记日志）
  Future<void> _refresh() async {
    try {
      final d = await Api.instance.get('/auth/me');
      final u = d['user'] as Map?;
      if (u == null) return;
      final name = '${u['display_name'] ?? u['username'] ?? ''}';
      final hasAvatar = u['avatar'] != null;
      final totpOn = (u['totp_enabled'] as num? ?? 0) == 1;
      await Api.instance.setUsername(name);
      await Api.instance.setAccount('${u['username'] ?? ''}');
      await Api.instance.setAvatar(hasAvatar);
      // 头像缓存后台校验：服务器有→下载覆盖本地；无→清本地；离线→保留旧缓存
      final avatarSync = await syncAvatarCache();
      if (avatarSync != null) {
        await Api.instance.setAvatar(avatarSync);
      }
      final localPath = (await avatarLocalFile())?.path ?? '';
      if (!mounted) return;
      setState(() {
        _username = name;
        _account = '${u['username'] ?? ''}';
        _role = '${u['role'] ?? _role}';
        _avatar = avatarSync ?? hasAvatar;
        _avatarLocalPath = localPath;
        _totpOn = totpOn;
      });
    } catch (e) {
      // 无网络/服务异常：本地数据已展示，仅记日志（用户可在错误日志页查看）
      appLog('net', '账号资料后台刷新失败: ${e.toString().split('\n').first}', level: 'error');
    }
  }

  Future<void> _changeAvatar() async {
    final src = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined, color: Color(0xFF409EFF)),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: Color(0xFF67C23A)),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (src == null) return;
    final picked = await ImagePicker().pickImage(source: src, maxWidth: 800, imageQuality: 85);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    toast(context, '上传中…');
    try {
      await Api.instance.uploadPhoto('/auth/avatar', bytes, 'avatar.jpg');
      // 本地副本：离线也能显示
      await saveAvatarLocal(bytes);
      await Api.instance.setAvatar(true);
      final localPath = (await avatarLocalFile())?.path ?? '';
      if (mounted) {
        setState(() {
          _avatar = true;
          _avatarLocalPath = localPath;
        });
      }
      toast(context, '头像已更新');
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _changeUsername() async {
    final ctrl = TextEditingController(text: _username);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改用户名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '用户名（显示用，1-30 字）'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty || name.length > 30) {
      toast(context, '用户名长度需在 1-30 个字符');
      return;
    }
    try {
      await Api.instance.patch('/auth/profile', {'display_name': name});
      await Api.instance.setUsername(name);
      if (mounted) setState(() => _username = name);
      toast(context, '用户名已修改');
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _changePassword() async {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldCtrl,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: '当前密码'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: newCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: '新密码（至少 6 位）'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    if (newCtrl.text.length < 6) {
      toast(context, '新密码至少 6 位');
      return;
    }
    try {
      await Api.instance.patch('/auth/profile', {
        'old_password': oldCtrl.text,
        'password': newCtrl.text,
      });
      toast(context, '密码已修改');
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _toggleTotp() async {
    if (!_totpOn) {
      Map<String, dynamic> d;
      try {
        d = await Api.instance.get('/auth/totp/setup');
      } catch (e) {
        toast(context, e.toString().replaceFirst('Exception: ', ''));
        return;
      }
      final secret = '${d['secret'] ?? ''}';
      final uri = '${d['otpauth'] ?? ''}';
      final codeCtrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('开启两步验证'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 二维码：验证器 App 扫码添加；下方链接/密钥可手动输入
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(data: uri, size: 180),
                  ),
                ),
                const SizedBox(height: 10),
                const Text('用验证器 App（如 Google Authenticator / 微软验证器）扫码，或手动输入密钥：',
                    style: TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                SelectableText(uri, style: const TextStyle(fontSize: 12, color: Color(0xFF409EFF))),
                const SizedBox(height: 6),
                SelectableText('密钥：$secret', style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () => Clipboard.setData(ClipboardData(text: uri)),
                  child: const Text('复制链接'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: codeCtrl,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(labelText: '输入验证码'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('开启')),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await Api.instance.post('/auth/totp/confirm', {'code': codeCtrl.text.trim()});
        if (mounted) setState(() => _totpOn = true);
        toast(context, '两步验证已开启');
      } catch (e) {
        toast(context, e.toString().replaceFirst('Exception: ', ''));
      }
    } else {
      final codeCtrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('关闭两步验证'),
          content: TextField(
            controller: codeCtrl,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofocus: true,
            decoration: const InputDecoration(labelText: '输入验证器里的验证码'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('关闭')),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await Api.instance.post('/auth/totp/disable', {'code': codeCtrl.text.trim()});
        if (mounted) setState(() => _totpOn = false);
        toast(context, '两步验证已关闭');
      } catch (e) {
        toast(context, e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  Future<void> _editBase() async {
    if (kIsWeb) {
      toast(context, 'Web 版使用当前访问域名，无需修改');
      return;
    }
    final ctrl = TextEditingController(text: _base);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('服务器地址'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: '如 https://您的域名'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final v = ctrl.text.trim();
    if (v.isEmpty) {
      toast(context, '地址不能为空');
      return;
    }
    await Api.instance.setBase(v);
    if (mounted) setState(() => _base = v);
    toast(context, '已保存，重启应用后生效');
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _headerCard(c),
              const SizedBox(height: 18),
              _groupTitle(c, '账号'),
              _card(c, [
                _tile(c, Icons.alternate_email_outlined, '登录账号', _account.isEmpty ? '—' : _account, null),
                _tile(c, Icons.badge_outlined, '用户名', _username.isEmpty ? '—' : _username, _changeUsername),
                _tile(c, Icons.lock_reset_outlined, '修改密码', '需验证当前密码', _changePassword),
                _tile(c,
                    _totpOn ? Icons.verified_user_outlined : Icons.security_outlined,
                    '两步验证', _totpOn ? '已开启（登录需验证码）' : '未开启（建议开启）', _toggleTotp,
                    warn: _totpOn),
              ]),
              const SizedBox(height: 18),
              _groupTitle(c, '服务器'),
              _card(c, [
                _tile(c, Icons.dns_outlined, '服务器地址',
                    kIsWeb ? Uri.base.origin : (_base.isEmpty ? '未设置' : _base),
                    _editBase),
              ]),
              const SizedBox(height: 24),
            ],
          );
    if (widget.embed) return body; // 「成员」页 Tab 嵌入（无 AppBar）
    return Scaffold(appBar: AppBar(title: const Text('账号设置')), body: body);
  }

  Widget _headerCard(TaozhuColors c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          GestureDetector(
            onTap: _changeAvatar,
            child: _avatarWidget(c, 56),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_username.isEmpty ? (_role == 'staff' ? '店员账号' : '老板账号') : _username,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.textMain)),
                const SizedBox(height: 3),
                Text('点击头像或右上角信息可修改', style: TextStyle(fontSize: 12, color: c.textSub)),
              ],
            ),
          ),
          IconButton(
            tooltip: '修改头像',
            icon: Icon(Icons.photo_camera_outlined, color: c.primary),
            onPressed: _changeAvatar,
          ),
        ],
      ),
    );
  }

  Widget _avatarWidget(TaozhuColors c, double size) {
    return UserAvatar(
      size: size,
      name: _username,
      localPath: _avatarLocalPath.isEmpty ? null : _avatarLocalPath,
      hasAvatar: _avatar && _avatarUrl.isNotEmpty,
      url: _avatarUrl,
      token: _avatarToken,
    );
  }

  Widget _groupTitle(TaozhuColors c, String t) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textSub)),
    );
  }

  Widget _card(TaozhuColors c, List<Widget> tiles) {
    return Container(
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          for (int i = 0; i < tiles.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 56, color: c.divider),
            tiles[i],
          ],
        ],
      ),
    );
  }

  Widget _tile(TaozhuColors c, IconData icon, String title, String subtitle, VoidCallback? onTap,
      {bool warn = false}) {
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: c.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 20, color: warn ? c.success : c.primary),
      ),
      title: Text(title, style: TextStyle(fontSize: 15, color: c.textMain)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: warn ? c.success : c.textSub)),
      trailing: onTap == null ? null : const Icon(Icons.chevron_right, color: Color(0xFF909399)),
      onTap: onTap,
    );
  }
}
