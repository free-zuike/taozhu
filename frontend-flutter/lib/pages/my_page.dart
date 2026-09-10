import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../api.dart';
import '../theme.dart';
import '../version.dart';
import 'router.dart';
import 'items_page.dart';
import 'categories_page.dart';
import 'clients_page.dart';
import 'payments_page.dart';
import 'statement_page.dart';
import 'users_page.dart';
import 'stocks_page.dart';
import 'login_page.dart';

class MyPage extends StatefulWidget {
  const MyPage({super.key});
  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  String _base = '';
  int _lowStocks = -1; // 低库存数量（-1=未加载）
  int _pending = 0; // 待同步单据数

  @override
  void initState() {
    super.initState();
    Api.instance.getBase().then((b) {
      if (mounted) setState(() => _base = b);
    });
    _loadLowStocks();
    _loadPending();
  }

  Future<void> _loadLowStocks() async {
    try {
      final d = await Api.instance.get('/stocks?below=1');
      if (!mounted) return;
      setState(() => _lowStocks = ((d['stocks'] as List?) ?? []).length);
    } catch (_) {
      _lowStocks = 0;
    }
  }

  Future<void> _loadPending() async {
    try {
      final list = await Api.instance.pendingList();
      if (mounted) setState(() => _pending = list.length);
    } catch (_) {}
  }

  /// 重放离线待同步单据
  Future<void> _syncPending() async {
    final ok = await Api.instance.syncPending();
    toast(context, ok > 0 ? '已同步 $ok 条待同步单据' : '没有可同步的待办');
    _loadPending();
    _loadLowStocks();
  }

  /// 全库备份导出（JSON 文件分享）
  Future<void> _exportBackup() async {
    try {
      final d = await Api.instance.get('/backup');
      final bytes = Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(d)));
      final name = 'taozhu-backup-${DateTime.now().toIso8601String().split('T').first}.json';
      await Share.shareXFiles(
        [XFile.fromData(bytes, mimeType: 'application/json', name: name)],
        text: '陶朱数据备份',
      );
    } catch (e) {
      toast(context, '备份导出失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
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

  /// 检查更新：走后端代理（Worker 代查 GitHub Release），避免 App/Web 直连 GitHub 被网络干扰
  Future<void> _checkUpdate() async {
    // Web 端特殊处理：页面随部署自动更新，刷新即为最新，无需下载安装
    if (kIsWeb) {
      toast(context, 'Web 版随部署自动更新，刷新页面即为最新版本');
      return;
    }
    final releaseUrl = 'https://github.com/free-zuike/taozhu/releases/latest';
    try {
      final d = await Api.instance.get('/auth/latest-version');
      final ver = '${d['latest'] ?? ''}';
      if (ver.isEmpty) {
        // 后端也未能获取（GitHub 不可达）——手动兜底
        if (!mounted) return;
        final copy = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('检查更新失败'),
            content: Text('暂时无法获取最新版本（GitHub 网络受限）。\n当前版本 v$APP_VERSION\n\n可手动打开 GitHub Release 页查看并下载 APK。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('复制链接')),
            ],
          ),
        );
        if (copy == true) {
          await Clipboard.setData(ClipboardData(text: releaseUrl));
          toast(context, '已复制 GitHub Release 链接');
        }
        return;
      }
      if (!_older(APP_VERSION, ver)) {
        toast(context, '当前已是最新版本 v$APP_VERSION');
        return;
      }
      if (!mounted) return;
      final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('发现新版本'),
          content: Text(isAndroid
              ? '当前 v$APP_VERSION\n最新 v$ver\n\n点击「立即更新」将在应用内下载并安装新版 APK。'
              : '当前 v$APP_VERSION\n最新 v$ver\n\n点击「复制下载链接」后粘贴到浏览器下载。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('取消')),
            if (isAndroid)
              FilledButton(onPressed: () => Navigator.pop(ctx, 'update'), child: const Text('立即更新'))
            else
              FilledButton(onPressed: () => Navigator.pop(ctx, 'copy'), child: const Text('复制下载链接')),
          ],
        ),
      );
      if (action == 'update') {
        await _downloadAndInstall(ver);
      } else if (action == 'copy') {
        await Clipboard.setData(ClipboardData(text: releaseUrl));
        toast(context, '已复制下载链接');
      }
    } catch (e) {
      toast(context, '检查更新失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  /// 应用内下载 APK 并调起系统安装器（仅 Android），带实时进度对话框。
  /// 直链（GitHub）失败时自动换镜像站（gh-proxy 等），避免直连受限。
  Future<void> _downloadAndInstall(String ver) async {
    final urls = [
      'https://github.com/free-zuike/taozhu/releases/download/taozhu-v$ver/flutter-app-$ver.apk',
      'https://gh-proxy.com/https://github.com/free-zuike/taozhu/releases/download/taozhu-v$ver/flutter-app-$ver.apk',
      'https://ghfast.top/https://github.com/free-zuike/taozhu/releases/download/taozhu-v$ver/flutter-app-$ver.apk',
    ];
    var downloaded = 0;
    var total = 0;
    final progress = ValueNotifier<double>(0);
    // 进度对话框：下载全程可见，完成/失败自动关闭
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('正在下载更新'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, v, __) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(value: v >= 1 ? null : v),
              const SizedBox(height: 12),
              Text(
                total > 0 && v < 1
                    ? '${(v * 100).toStringAsFixed(0)}% · ${(downloaded / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB'
                    : v >= 1
                        ? '下载完成，正在调起安装…'
                        : '准备下载…',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/taozhu-update-$ver.apk');
    var ok = false;
    for (final url in urls) {
      downloaded = 0;
      total = 0;
      progress.value = 0;
      final client = http.Client();
      try {
        final res = await client.send(http.Request('GET', Uri.parse(url)));
        // 非 200 或响应明显不是 APK（镜像返回 HTML 错误页）→ 换下一个源
        if (res.statusCode != 200 || (res.contentLength ?? 0) < 1000000) {
          client.close();
          continue;
        }
        total = res.contentLength ?? 0;
        final sink = file.openWrite();
        try {
          await for (final chunk in res.stream) {
            downloaded += chunk.length;
            if (total > 0) progress.value = downloaded / total;
            sink.add(chunk);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        ok = true;
      } catch (_) {
        // 网络/超时：换下一个源
      } finally {
        client.close();
      }
      if (ok) break;
    }
    if (!ok) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      toast(context, '下载失败（直链与镜像均不可达）。可稍后重试，或用浏览器打开 GitHub Release 页下载 APK。');
      return;
    }
    progress.value = 1;
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    toast(context, '下载完成，正在调起安装…');
    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done) {
      toast(context, '调起安装失败：${result.message}');
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
                  leading: const Icon(Icons.store_outlined),
                  title: const Text('店铺管理'),
                  subtitle: const Text('店铺（账本）列表、新增、编辑', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right, color: Color(0xFF909399)),
                  onTap: () => goPage(context, const ClientsPage()),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.payments_outlined),
                  title: const Text('收款结账'),
                  subtitle: const Text('登记收款、查看收款历史', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right, color: Color(0xFF909399)),
                  onTap: () => goPage(context, const PaymentsPage()),
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
                  leading: const Icon(Icons.archive_outlined),
                  title: const Text('数据备份'),
                  subtitle: const Text('导出全部数据 JSON 文件', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right, color: Color(0xFF909399)),
                  onTap: _exportBackup,
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
                if (_pending > 0) ...[
                  ListTile(
                    leading: const Icon(Icons.cloud_upload_outlined, color: Color(0xFFF56C6C)),
                    title: const Text('待同步', style: TextStyle(color: Color(0xFFF56C6C))),
                    subtitle: Text('$_pending 条断网记的单据等待上传', style: const TextStyle(fontSize: 12, color: Color(0xFFF56C6C))),
                    trailing: const Icon(Icons.chevron_right, color: Color(0xFF909399)),
                    onTap: _syncPending,
                  ),
                  const Divider(height: 1, indent: 56),
                ],
                ListTile(
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: const Text('库存'),
                  subtitle: Text(
                    _lowStocks > 0
                        ? '有 $_lowStocks 项库存不足，点击查看'
                        : '进货/出货自动维护，盘点与预警',
                    style: TextStyle(
                        fontSize: 12,
                        color: _lowStocks > 0 ? const Color(0xFFF56C6C) : null),
                  ),
                  trailing: const Icon(Icons.chevron_right, color: Color(0xFF909399)),
                  onTap: () => goPage(context, const StocksPage()),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.save_alt_outlined),
                  title: const Text('备份导出'),
                  subtitle: const Text('导出全库 JSON 存档（仅老板）', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right, color: Color(0xFF909399)),
                  onTap: _exportBackup,
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
