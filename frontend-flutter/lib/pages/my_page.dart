import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import '../api.dart';
import '../local_db.dart';
import '../log.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/download.dart';
import '../version.dart';
import 'router.dart';
import 'items_page.dart';
import 'categories_page.dart';
import 'clients_page.dart';
import 'payments_page.dart';
import 'statement_page.dart';
import 'sync_panel_page.dart';
import 'users_page.dart';
import 'stocks_page.dart';
import 'cleanup_page.dart';
import 'login_page.dart';
import 'account_settings_page.dart';

class MyPage extends StatefulWidget {
  const MyPage({super.key});
  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  /// Android 系统下载器通道（MainActivity 注入，见 build-flutter.yml ②f）
  static const _dlChannel = MethodChannel('taozhu/download');
  /// 更新下载进行中（防止重复下载）
  static bool _downloading = false;
  String _base = '';
  String _role = ''; // admin=老板 / staff=店员（登录/启动时读取）
  String _username = ''; // 当前账号登录名（/auth/me 刷新）
  String _avatarUrl = '';
  String _avatarToken = '';
  bool _avatar = false; // 是否已设置头像
  int _lowStocks = -1; // 低库存数量（-1=未加载）
  int _pending = 0; // 待同步单据数（合并旧 Api 队列 + 新 SyncService 队列）
  String _lastSync = ''; // 上次同步时间（人类可读）

  @override
  void initState() {
    super.initState();
    Api.instance.getBase().then((b) {
      if (mounted) setState(() => _base = b);
    });
    Api.instance.getRole().then((r) {
      if (mounted) setState(() => _role = r);
    });
    _loadProfile();
    _loadLowStocks();
    _loadPending();
    _autoSync();
  }

  /// 以 /auth/me 刷新用户名/头像状态（登录后、改资料后调用）
  Future<void> _loadProfile() async {
    _username = await Api.instance.getUsername();
    _avatar = await Api.instance.hasAvatar();
    // 时间戳缓存破坏：改头像后 Image.network 立即显示新图
    _avatarUrl = '${await Api.instance.avatarUrl()}?t=${DateTime.now().millisecondsSinceEpoch}';
    _avatarToken = await Api.instance.getTokenValue() ?? '';
    try {
      final d = await Api.instance.get('/auth/me');
      final u = d['user'] as Map?;
      if (u == null) return;
      await Api.instance.setUsername('${u['username'] ?? ''}');
      await Api.instance.setAvatar(u['avatar'] != null);
      if (!mounted) return;
      setState(() {
        _username = '${u['username'] ?? ''}';
        _avatar = u['avatar'] != null;
      });
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  /// 自动同步离线待同步单据（静默：成功不打扰，失败留队列下次再试）
  Future<void> _autoSync() async {
    await Api.instance.syncPending();
    if (mounted) {
      _loadPending();
      _loadLowStocks();
    }
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
      // 两个队列合并：旧 Api.pendingList（SharedPreferences）+ 新 SyncService（LocalDb.local_changes）
      final legacy = await Api.instance.pendingList();
      final changes = await LocalDb.getPendingChanges();
      final lastSync = await SyncService.lastSyncAt();
      if (!mounted) return;
      setState(() {
        _pending = legacy.length + changes.length;
        if (lastSync != null && lastSync.isNotEmpty) _lastSync = _fmtSyncTime(lastSync);
      });
    } catch (_) {}
  }

  /// ISO 时间 → 人类可读（如 9月11日 19:05）
  static String _fmtSyncTime(String iso) {
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return iso;
    return '${t.month}月${t.day}日 ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  /// 重放离线待同步单据（两个队列依次推）
  Future<void> _syncPending() async {
    var ok = 0;
    try {
      ok += await Api.instance.syncPending();
    } catch (_) {}
    try {
      ok += await SyncService.pushPending();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _lastSync = '刚刚');
    toast(context, ok > 0 ? '已同步 $ok 条待同步单据' : '没有可同步的待办');
    _loadPending();
    _loadLowStocks();
  }

  /// 全库备份导出：Web 直接下载文件；移动/桌面弹系统分享保存
  Future<void> _exportBackup() async {
    try {
      final d = await Api.instance.get('/backup');
      final bytes = Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(d)));
      final name = 'taozhu-backup-${DateTime.now().toIso8601String().split('T').first}.json';
      await saveBytes(bytes, name, 'application/json', '陶朱数据备份');
      if (kIsWeb) toast(context, '备份已导出');
    } catch (e) {
      toast(context, '备份导出失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  /// 从备份 JSON 合并导入（仅老板）：相同 ID 跳过，只新增本地没有的记录
  Future<void> _importBackup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入备份'),
        content: const Text('将备份文件中的记录合并到当前账本：\n· 相同 ID 的记录跳过（不覆盖现有数据）\n· 只新增备份里有、本地没有的记录\n\n建议导入前先导出留底。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('选择文件并导入')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final text = await pickTextFile();
      if (text == null || text.trim().isEmpty) {
        if (!kIsWeb) toast(context, '当前平台暂不支持导入，请用 Web 端导入');
        return;
      }
      final raw = jsonDecode(text);
      if (raw is! Map || raw['data'] is! Map) {
        toast(context, '不是有效的备份文件');
        return;
      }
      final data = (raw['data'] as Map).cast<String, dynamic>();
      final r = await Api.instance.post('/backup/import', {'data': data});
      final report = (r['report'] as Map?) ?? {};
      final total = ((r['total_inserted'] as num?) ?? 0).toInt();
      if (!mounted) return;
      final detail = report.entries.map((e) {
        final v = (e.value as Map?) ?? const {};
        return '${e.key}: 新增 ${v['inserted']} · 跳过 ${v['skipped']}';
      }).join('\n');
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入完成'),
          content: Text('共新增 $total 条记录：\n$detail'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('好'))],
        ),
      );
    } catch (e) {
      toast(context, '导入失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _logout() async {
    await _clearAccountData();
    if (!mounted) return;
    Navigator.of(context)
        .pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginPage()), (r) => false);
  }

  /// 切换账号：清空当前账号本地数据（token/缓存/离线队列/本地库）后回登录页，防账号数据串号
  Future<void> _switchAccount() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换账号'),
        content: const Text('将清除当前账号的本地缓存与离线数据（不会影响服务器数据），返回登录页。\n\n换账号登录后数据互相隔离。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('切换账号')),
        ],
      ),
    );
    if (ok != true) return;
    await _logout();
  }

  /// 清除当前账号本地数据：token/角色/接口缓存/离线队列 + 本地数据库
  Future<void> _clearAccountData() async {
    await Api.instance.clearLocalData();
    await LocalDb.clearAll();
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
    // 更新下载进行中：不重复弹更新/重复下载
    if (_downloading) {
      toast(context, '更新正在后台下载中，下拉通知栏可查看进度');
      return;
    }
    // Web 端特殊处理：版本由部署方控制，刷新不升级（fork 实例需重新部署）。仅如实提示版本号
    if (kIsWeb) {
      try {
        final d = await Api.instance.get('/auth/latest-version');
        final ver = '${d['latest'] ?? ''}';
        toast(context, ver.isEmpty
            ? '当前部署版本 v$APP_VERSION'
            : _older(APP_VERSION, ver)
                ? '官方最新 v$ver（当前部署 v$APP_VERSION）：此部署未包含新版，需在服务器重新部署后刷新'
                : '当前已是最新版本 v$APP_VERSION');
      } catch (_) {
        toast(context, '检查更新失败，请稍后再试');
      }
      return;
    }
    final releaseUrl = 'https://github.com/free-zuike/taozhu/releases/latest';
    try {
      final d = await Api.instance.get('/auth/latest-version');
      final ver = '${d['latest'] ?? ''}';
      final ready = d['ready'] != false; // null/true 均视为就绪（备源无法确认资产）
      if (ver.isEmpty) {
        // 后端也未能获取（GitHub 不可达）——手动兜底
        if (!mounted) return;
        final copy = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('检查更新失败'),
            content: Text('暂时无法获取最新版本（更新源网络受限）。\n当前版本 v$APP_VERSION\n\n可手动打开 GitHub Release 页查看并下载 APK。'),
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
      if (!ready) {
        // 语义：没有安装文件就不提示新版本。source=backup 说明 GitHub 探测超时走了备源（无法确认安装包）——
        // 提示"更新源连接问题"（如开启代理导致），而非误导性的"安装文件未就绪"
        if (!mounted) return;
        final fromBackup = '${d['source'] ?? ''}' == 'backup';
        toast(context, fromBackup
            ? '暂时无法连接更新源（GitHub），请稍后重试；如开启了代理可尝试关闭后直连'
            : '官方有 v$ver，但安装文件尚未就绪，暂无可用更新');
        return;
      }
      if (!mounted) return;
      final notes = '${d['notes'] ?? ''}'.trim();
      final isAndroid = defaultTargetPlatform == TargetPlatform.android;
      final isDesktop = defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux;
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final c = Theme.of(ctx).extension<TaozhuColors>()!;
          return AlertDialog(
            title: const Text('发现新版本'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('当前 v$APP_VERSION → 最新 v$ver',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (notes.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Text('更新内容', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(notes,
                        style: TextStyle(fontSize: 12, color: c.textSub, height: 1.5)),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    isAndroid
                        ? '点击「立即更新」后在后台下载：下拉通知栏可见进度，完成或失败都会在这里提示，可继续使用或退出应用。'
                        : isDesktop
                            ? '点击「立即更新」将在应用内下载安装包（含进度），完成后引导解压覆盖安装。'
                            : '点击「复制下载链接」后粘贴到浏览器下载。',
                    style: TextStyle(fontSize: 12, color: c.textSub),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('取消')),
              if (isAndroid || isDesktop)
                FilledButton(onPressed: () => Navigator.pop(ctx, 'update'), child: const Text('立即更新'))
              else
                FilledButton(onPressed: () => Navigator.pop(ctx, 'copy'), child: const Text('复制下载链接')),
            ],
          );
        },
      );
      if (action == 'update') {
        if (isAndroid) {
          await _downloadAndInstall(ver);
        } else if (isDesktop) {
          await _downloadDesktop(ver);
        }
      } else if (action == 'copy') {
        await Clipboard.setData(ClipboardData(text: releaseUrl));
        toast(context, '已复制下载链接');
      }
    } catch (e) {
      toast(context, '检查更新失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  /// 构建中就绪自动重试：每 30 秒查一次，安装包就绪后提醒（最多约 2 分钟）
  Future<void> _waitForReady(String ver) async {
    for (var i = 0; i < 4; i++) {
      await Future.delayed(const Duration(seconds: 30));
      if (!mounted) return;
      try {
        final d = await Api.instance.get('/auth/latest-version');
        if ('${d['latest'] ?? ''}' == ver && d['ready'] != false) {
          toast(context, 'v$ver 安装包已就绪，可以更新了');
          return;
        }
      } catch (_) {}
    }
  }

  /// Android：应用内更新走系统下载器（DownloadManager）——
  /// 后台下载、通知栏（下滑栏）实时进度、退出应用仍继续，完成后引导安装。
  /// 多镜像源列表：下载前轻量探测可用源，选最快可用交给系统下载器；
  /// 下载失败自动换下一个源；**用户手动取消（CANCELED）立即停止，不换源重试**。
  Future<void> _downloadAndInstall(String ver) async {
    _downloading = true;
    final fileName = 'taozhu-update-$ver.apk';
    const prefixes = [
      '',
      'https://ghproxy.com/',
      'https://mirror.ghproxy.com/',
      'https://gh.ddlc.top/',
      'https://github.moeyy.xyz/',
      'https://gh-proxy.com/',
      'https://ghfast.top/',
    ];
    final base = 'https://github.com/free-zuike/taozhu/releases/download/taozhu-v$ver/flutter-app-$ver.apk';
    final urls = [for (final p in prefixes) '$p$base'];
    try {
      // 下载前并行轻量探测（HEAD Range 0-0），过滤不可达源，避免直接失败
      final usable = await _probeSources(urls);
      if (usable.isEmpty) {
        toast(context, '所有下载源均不可达，请稍后重试或从 GitHub Release 页手动下载');
        return;
      }
      var urlIdx = 0;
      while (urlIdx < usable.length) {
        final id = await _dlChannel
            .invokeMethod<int>('enqueue', {'url': usable[urlIdx], 'fileName': fileName});
        if (id == null) {
          urlIdx++;
          continue;
        }
        if (!mounted) return;
        toast(context,
            urlIdx == 0 ? '已在后台开始下载，下拉通知栏查看进度' : '该下载源失败，已自动切换下一个源…');
        var failed = false;
        // 轮询系统下载状态（每 3 秒，上限 15 分钟；通知栏本身也在实时显示进度）
        for (var i = 0; i < 300; i++) {
          await Future.delayed(const Duration(seconds: 3));
          if (!mounted) return;
          final Map st;
          try {
            st = await _dlChannel.invokeMethod<Map>('status', {'id': id}) ?? const {};
          } catch (_) {
            continue;
          }
          final status = (st['status'] as int?) ?? -1;
          if (status == 8) {
            // DownloadManager.STATUS_SUCCESSFUL
            await _installFromDownloads(fileName);
            return;
          }
          if (status == -1 || status == 12) {
            // -1 = 下载记录已消失（通知栏取消，DownloadManager 移除记录）｜
            // 12 = DownloadManager.STATUS_CANCELED。用户手动取消 → 立即停止，不换源
            toast(context, '已取消下载');
            return;
          }
          if (status == 16) {
            // DownloadManager.STATUS_FAILED → 换下一个可用源重试
            failed = true;
            break;
          }
        }
        if (failed) {
          urlIdx++;
          continue;
        }
        // 超时（大文件/慢网）：下载仍由系统继续，用户可从通知栏查看
        return;
      }
      toast(context, '下载失败（所有可用源均失败），请稍后重试或从 GitHub Release 页手动下载');
    } catch (e) {
      toast(context, '启动下载失败：${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      _downloading = false;
    }
  }

  /// 并行轻量探测下载源可用性（HEAD + Range，接受 200/206 且 Content-Length>0），
  /// 按响应耗时升序返回（最快源优先，避免固定顺序导致"第一次不是最快的"）。
  Future<List<String>> _probeSources(List<String> urls) async {
    final results = await Future.wait(urls.map((u) async {
      final t0 = DateTime.now();
      try {
        final client = http.Client();
        try {
          final req = http.Request('HEAD', Uri.parse(u));
          req.headers['Range'] = 'bytes=0-0';
          req.headers['User-Agent'] = 'Mozilla/5.0';
          final res = await client.send(req).timeout(const Duration(seconds: 8));
          final len = res.contentLength ?? -1;
          if (res.statusCode == 200 || res.statusCode == 206) {
            if (len > 0 || res.statusCode == 200) {
              return (u, DateTime.now().difference(t0).inMilliseconds);
            }
          }
          return null;
        } finally {
          client.close();
        }
      } catch (_) {
        return null;
      }
    }));
    final usable = <(String, int)>[];
    for (final r in results) {
      if (r != null) usable.add(r);
    }
    usable.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final r in usable) r.$1];
  }

  /// 下载完成后引导安装（文件在应用下载目录，由系统 DownloadManager 写入）
  Future<void> _installFromDownloads(String fileName) async {
    if (!mounted) return;
    final install = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('更新下载完成'),
        content: Text('安装包已就绪（$fileName）。\n立即安装？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('稍后')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('立即安装')),
        ],
      ),
    );
    if (install != true) return;
    try {
      final dir = await getDownloadsDirectory();
      final file = File('${dir?.path}/$fileName');
      if (!file.existsSync()) {
        toast(context, '未找到安装包，请从通知栏或下载目录打开');
        return;
      }
      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done) {
        toast(context, '调起安装失败：${result.message}');
      }
    } catch (e) {
      toast(context, '安装失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  /// 桌面端（Windows/macOS/Linux）：应用内下载对应系统安装包（前台进度条），
  /// 直链失败自动换镜像，保存到下载目录后引导解压覆盖安装。
  Future<void> _downloadDesktop(String ver) async {
    final fileName = switch (defaultTargetPlatform) {
      TargetPlatform.windows => 'taozhu-windows-$ver.zip',
      TargetPlatform.macOS => 'taozhu-macos-$ver.zip',
      TargetPlatform.linux => 'taozhu-linux-$ver.zip',
      _ => '',
    };
    if (fileName.isEmpty) {
      toast(context, '当前平台暂不支持应用内下载');
      return;
    }
    final urls = [
      'https://github.com/free-zuike/taozhu/releases/download/taozhu-v$ver/$fileName',
      'https://gh-proxy.com/https://github.com/free-zuike/taozhu/releases/download/taozhu-v$ver/$fileName',
      'https://ghfast.top/https://github.com/free-zuike/taozhu/releases/download/taozhu-v$ver/$fileName',
    ];
    var downloaded = 0;
    var total = 0;
    final progress = ValueNotifier<double>(0);
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
                        ? '下载完成…'
                        : '准备下载…',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
    try {
      final dir = await getDownloadsDirectory();
      final file = File('${dir?.path}/$fileName');
      var ok = false;
      for (final url in urls) {
        downloaded = 0;
        total = 0;
        progress.value = 0;
        final client = http.Client();
        try {
          final res = await client.send(http.Request('GET', Uri.parse(url)));
          // 非 200 或响应明显不是安装包（镜像返回 HTML 错误页）→ 换下一个源
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
        toast(context, '下载失败（直链与镜像均不可达），可稍后重试');
        return;
      }
      progress.value = 1;
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (!mounted) return;
      final act = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('下载完成'),
          content: Text('安装包已保存到下载目录：\n$fileName\n\n桌面版更新需手动操作：解压后覆盖替换旧程序即可。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'open'), child: const Text('打开文件夹')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'ok'), child: const Text('好')),
          ],
        ),
      );
      if (act == 'open') await _revealFile(file);
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      toast(context, '下载失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  /// 清理更新下载缓存：删除下载目录/临时目录中的旧安装包（APK/zip），释放空间
  /// 查看错误日志（弹层：最近记录 + 清空）
  Future<void> _showLogs() async {
    final logs = await readLogs();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('错误日志'),
        content: SizedBox(
          width: double.maxFinite,
          height: 320,
          child: logs.isEmpty
              ? const Center(child: Text('暂无日志', style: TextStyle(color: Color(0xFF909399))))
              : ListView(
                  children: [
                    for (final l in logs.reversed)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(l, style: const TextStyle(fontSize: 12, height: 1.4)),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await clearLogs();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('清空'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 在系统文件管理器中显示该文件（Windows explorer / macOS 访达 / Linux xdg-open）
  Future<void> _revealFile(File f) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.windows) {
        await Process.run('explorer', ['/select,', f.path]);
      } else if (defaultTargetPlatform == TargetPlatform.macOS) {
        await Process.run('open', ['-R', f.path]);
      } else {
        await Process.run('xdg-open', [f.parent.path]);
      }
    } catch (_) {
      toast(context, '已保存到下载目录，可手动打开');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _userCard(),
          const SizedBox(height: 18),
          // 账号与同步（账号卡下方、经营上方）：同步状态 + 待同步 + 账号设置
          _card([
            _item(Icons.sync_alt, c.primary, '同步状态',
                '本地与服务器数据差异、上次同步时间（右上角可手动同步）',
                () => goPage(context, const SyncPanelPage())),
            if (_pending > 0)
              _item(Icons.cloud_upload_outlined, c.danger, '待同步',
                  '$_pending 条单据等待上传${_lastSync.isEmpty ? '' : '（上次：$_lastSync）'}',
                  _syncPending,
                  warn: true),
            if (_pending == 0 && !kIsWeb && _lastSync.isNotEmpty)
              _item(Icons.cloud_done_outlined, c.primary, '已同步', '上次同步：$_lastSync', () {}),
            _item(Icons.manage_accounts_outlined, c.primary, '账号设置',
                '头像、用户名、密码、两步验证、服务器地址',
                () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const AccountSettingsPage()))
                    .then((_) => _loadProfile())),
          ]),
          const SizedBox(height: 18),
          // 店员账号：仅送货视角，隐藏经营类功能（收款/对账/店铺管理）
          if (_role != 'staff') ...[
            _groupTitle('经营'),
            _card([
              _item(Icons.store_outlined, c.primary, '店铺管理', '店铺（账本）列表、新增、编辑',
                  () => goPage(context, const ClientsPage())),
              _item(Icons.payments_outlined, c.success, '收款结账', '登记收款、查看收款历史',
                  () => goPage(context, const PaymentsPage())),
              _item(Icons.description_outlined, c.warning, '对账单', '按店铺+周期生成对账明细，一键复制发送',
                  () => goPage(context, const StatementPage())),
            ]),
            const SizedBox(height: 18),
          ],
          _groupTitle('商品与库存'),
          _card([
            _item(Icons.inventory_2_outlined, c.primary, '库存',
                _lowStocks > 0 ? '有 $_lowStocks 项库存不足，点击查看' : '进货/出货自动维护，盘点与预警',
                () => goPage(context, const StocksPage()),
                warn: _lowStocks > 0),
            _item(Icons.sell_outlined, c.primary, '商品管理', '商品与多单位价格', () => goPage(context, const ItemsPage())),
            _item(Icons.label_outline, c.primary, '分类管理', '商品分类 / 店铺分类（两级）',
                () => goPage(context, const CategoriesPage())),
          ]),
          const SizedBox(height: 18),
          _groupTitle('系统'),
          _card([
            if (_role != 'staff')
              _item(Icons.people_outline, c.primary, '账号管理', '店员/老板账号（仅老板可操作）',
                  () => goPage(context, const UsersPage())),
            if (_role != 'staff')
              _item(Icons.save_alt_outlined, c.primary, '备份导出', '导出全库 JSON 存档（仅老板）', _exportBackup),
            if (_role != 'staff')
              _item(Icons.restore_outlined, c.primary, '导入备份', '从备份 JSON 恢复（合并，不覆盖现有）', _importBackup),
            _item(Icons.system_update_alt_outlined, c.primary, '检查更新',
                kIsWeb ? 'Web 版随部署更新' : '对比最新版本，应用内下载安装', _checkUpdate),
            _item(Icons.cleaning_services_outlined, c.primary, '存储清理', '查看并删除安装包/临时文件，释放空间',
                () => goPage(context, const CleanupPage())),
            _item(Icons.receipt_long_outlined, c.primary, '错误日志', '查看最近的操作错误记录（不再弹到页面）', _showLogs),
          ]),
          const SizedBox(height: 18),
          _card([
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('主题', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _themeChip(ThemeMode.system, '跟随系统'),
                      _themeChip(ThemeMode.light, '白天'),
                      _themeChip(ThemeMode.dark, '黑夜'),
                    ],
                  ),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    foregroundColor: c.danger,
                    side: BorderSide(color: c.danger),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _logout,
                  child: const Text('退出登录'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    backgroundColor: c.primary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _switchAccount,
                  child: const Text('切换账号'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Center(
            child: Text('陶朱 v$APP_VERSION',
                style: TextStyle(color: c.textSub, fontSize: 12)),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  /// 顶部用户卡：头像 + 用户名/角色 + 服务器地址
  Widget _userCard() {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: c.primary.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            clipBehavior: Clip.antiAlias,
            child: _avatar && _avatarUrl.isNotEmpty
                ? Image.network(
                    _avatarUrl,
                    fit: BoxFit.cover,
                    headers: _avatarToken.isEmpty ? null : {'Authorization': 'Bearer $_avatarToken'},
                    errorBuilder: (_, __, ___) => Icon(Icons.person_outline, size: 30, color: c.primary),
                  )
                : Icon(Icons.person_outline, size: 30, color: c.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _username.isEmpty
                      ? (_role == 'staff' ? '店员账号' : '老板账号')
                      : _username,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.textMain),
                ),
                const SizedBox(height: 3),
                Text(
                  '${_role == 'staff' ? '店员' : '老板'} · ${_base.isEmpty ? '未设置服务器地址' : _base}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: c.textSub),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupTitle(String t) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textSub)),
    );
  }

  /// 分组圆角卡（内嵌多个功能项，自动加分隔线）
  Widget _card(List<Widget> tiles) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(16),
      ),
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

  /// 主题选择胶囊（紧凑，Web/App 通用）
  Widget _themeChip(ThemeMode mode, String label) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    final active = themeNotifier.value == mode;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 13)),
      selected: active,
      selectedColor: c.primary.withOpacity(0.12),
      side: BorderSide(color: active ? c.primary : c.divider),
      labelStyle: TextStyle(
          color: active ? c.primary : c.textMain,
          fontWeight: active ? FontWeight.w600 : FontWeight.w400),
      visualDensity: VisualDensity.compact,
      onSelected: (_) => setThemeMode(mode),
    );
  }

  Widget _item(IconData icon, Color color, String title, String subtitle, VoidCallback onTap,
      {bool warn = false}) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 20, color: color),
      ),
      title: Text(title,
          style: TextStyle(fontSize: 15, color: warn ? c.danger : c.textMain,
              fontWeight: warn ? FontWeight.w600 : null)),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 12, color: warn ? c.danger : c.textSub)),
      trailing: Icon(Icons.chevron_right, color: c.textSub),
      onTap: onTap,
    );
  }
}
