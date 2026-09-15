import 'dart:io';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import '../api.dart';
import '../avatar_cache.dart';
import '../local_accounts.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import '../utils/update_sources.dart';
import '../version.dart';
import 'router.dart';
import 'items_page.dart';
import 'categories_page.dart';
import 'clients_page.dart';
import 'payments_page.dart';
import 'statement_page.dart';
import 'sync_panel_page.dart';
import 'stocks_page.dart';
import 'cleanup_page.dart';
import 'login_page.dart';
import 'members_page.dart';
import 'logs_page.dart';
import 'backup_page.dart';
import 'payment_accounts_page.dart';
import 'update_sources_page.dart';
import '../widgets/user_avatar.dart';
import '../widgets/center_sheet.dart';

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
  String _username = ''; // 当前账号显示名（/auth/me 刷新）
  String _avatarUrl = '';
  String _avatarToken = '';
  String _avatarLocalPath = ''; // 本地头像副本（离线也显示）
  bool _avatar = false; // 是否已设置头像
  bool _syncing = false; // SyncService 同步进行中（进入应用自动同步时实时显示）
  bool _syncError = false; // 最近一次同步失败（网络/服务器异常；不再静默谎报"已同步"）
  String _webSyncState = ''; // Web 端服务器连通检查：''=检查中 / ok / error
  int _lowStocks = -1; // 低库存数量（-1=未加载）
  int _pending = 0; // 待同步单据数（合并旧 Api 队列 + 新 SyncService 队列）
  String _lastSync = ''; // 上次同步时间（人类可读）
  // 统计卡（本地核算，仅老板可见）：记账天数 / 当前店铺总笔数 / 总账本结余（全部店铺出货−收款）
  int _bookDays = 0;
  int _curClientCount = 0;
  double _totalBalance = 0;
  /// 最近一次按钮点击时间戳（防连点：500ms 内忽略重复触发）
  int _lastTapAt = 0;
  /// 检查更新请求进行中（防止连点重复发请求/弹多个更新窗）
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    Api.instance.getBase().then((b) {
      if (mounted) setState(() => _base = b);
    });
    Api.instance.getRole().then((r) {
      if (mounted) setState(() => _role = r);
    });
    // 进入应用即监听同步状态：同步开始/结束实时刷新「同步状态」子标题，无需进面板才看到。
    // 启动同步由 BottomShell 发起，可能已在进行中 → 先读当前状态，避免错过"同步中"通知
    _syncing = SyncService.syncStatus == 'syncing';
    SyncService.version.addListener(_onSyncChanged);
    SyncService.status.addListener(_onSyncStatus);
    // 库存变更（盘点/调整/记单）后实时刷新低库存红字，无需重启 App
    SyncService.stockChanged.addListener(_onSyncChanged);
    // 店铺切换后实时刷新统计卡（本店交易笔数），无需退出重进
    SyncService.selectedClientChanged.addListener(_onSelectedClientChanged);
    // 头像跨端同步：其他端改头像（WS profile_change → syncMyProfile 下载新版）后实时刷新
    avatarChanged.addListener(_onAvatarChanged);
    _loadProfile();
    _loadLowStocks();
    _loadPending();
    _loadStats();
    if (kIsWeb) _checkWebSync();
  }

  @override
  void dispose() {
    SyncService.version.removeListener(_onSyncChanged);
    SyncService.status.removeListener(_onSyncStatus);
    SyncService.stockChanged.removeListener(_onSyncChanged);
    SyncService.selectedClientChanged.removeListener(_onSelectedClientChanged);
    avatarChanged.removeListener(_onAvatarChanged);
    super.dispose();
  }

  /// 头像本地副本变更（跨端同步下载新版/清除）后重读显示
  void _onAvatarChanged() {
    if (!mounted) return;
    avatarLocalFile().then((f) {
      Api.instance.hasAvatar().then((has) {
        if (!mounted) return;
        setState(() {
          _avatarLocalPath = f?.path ?? '';
          _avatar = f != null || has;
          // 缓存破坏：强制 Image.network 分支取新图
          _avatarUrl = '';
        });
        Api.instance.avatarUrl().then((u) {
          if (mounted) setState(() => _avatarUrl = '$u?t=${DateTime.now().millisecondsSinceEpoch}');
        });
      });
    });
  }

  void _onSyncStatus() {
    if (!mounted) return;
    setState(() {
      _syncing = SyncService.syncStatus == 'syncing';
      _syncError = SyncService.syncStatus == 'error';
    });
  }

  /// 同步完成（版本号变化）后刷新待同步数/上次同步时间/低库存/统计卡
  void _onSyncChanged() {
    _loadPending();
    _loadLowStocks();
    _loadStats();
  }

  /// 店铺切换后刷新统计卡（本店交易笔数随当前选中店铺变化）
  void _onSelectedClientChanged() {
    _loadStats();
  }

  /// Web 端进入即检查服务器连通（Web 无本地库，同步=直连服务器实时读取）
  Future<void> _checkWebSync() async {
    try {
      await Api.instance.get('/sync/stats');
      if (mounted) setState(() => _webSyncState = 'ok');
    } catch (_) {
      if (mounted) setState(() => _webSyncState = 'error');
    }
  }

  /// 同步状态子标题：进应用时实时显示（同步中 / 待同步 / 已同步），不再等进面板刷新
  String _syncSubtitle() {
    if (kIsWeb) {
      switch (_webSyncState) {
        case 'ok':
          return '已同步 · Web 直连服务器实时读取';
        case 'error':
          return '无法连接服务器（详见错误日志）';
        default:
          return '正在检查服务器…';
      }
    }
    if (_syncing) return '正在同步…';
    if (_syncError) return '同步失败，请检查网络或服务器（详见日志）';
    if (_pending > 0) return '$_pending 条待同步${_lastSync.isEmpty ? '' : ' · 上次 $_lastSync'}';
    if (_lastSync.isNotEmpty) return '已同步 · 上次 $_lastSync';
    return '尚未同步（进入应用会自动同步）';
  }

  /// 以 /auth/me 刷新显示名/头像（登录后、改资料后调用；离线保留本地缓存）
  Future<void> _loadProfile() async {
    _username = await Api.instance.getUsername();
    _avatar = await Api.instance.hasAvatar();
    _avatarLocalPath = (await avatarLocalFile())?.path ?? '';
    // 时间戳缓存破坏：改头像后 Image.network 立即显示新图
    _avatarUrl = '${await Api.instance.avatarUrl()}?t=${DateTime.now().millisecondsSinceEpoch}';
    _avatarToken = await Api.instance.getTokenValue() ?? '';
    try {
      final d = await Api.instance.get('/auth/me');
      final u = d['user'] as Map?;
      if (u == null) return;
      // 显示名（默认取登录账号 @ 前部分）；登录账号本身不可改
      final name = '${u['display_name'] ?? u['username'] ?? ''}';
      await Api.instance.setUsername(name);
      await Api.instance.setAccount('${u['username'] ?? ''}');
      await Api.instance.setAvatar(u['avatar'] != null);
      // 头像缓存后台校验（版本驱动：传入已拉取的 profile，避免重复请求 /auth/me）：
      // 服务器有新版→下载覆盖本地；无→清本地；离线→保留旧缓存
      final avatarSync = await syncAvatarCache(u.cast<String, dynamic>());
      if (avatarSync != null) {
        await Api.instance.setAvatar(avatarSync);
      }
      final localPath = (await avatarLocalFile())?.path ?? '';
      if (!mounted) return;
      setState(() {
        _username = name;
        _avatar = avatarSync ?? (u['avatar'] != null);
        _avatarLocalPath = localPath;
      });
    } catch (_) {
      if (mounted) setState(() {});
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

  /// 本地核算统计卡（仅老板）：记账天数（最早一笔记账至今）/ 当前店铺总笔数 / 店铺结余。
  /// 店铺结余 = 当前店铺收款 − 进货（全店通用）＝结账后的盈利（与交易页月度结余口径一致）。
  /// Web 无本地库：跳过（显示 0，由老板在 App/统计页查看）。
  Future<void> _loadStats() async {
    if (kIsWeb) return;
    try {
      final sales = await LocalDb.getAll('sales');
      final pays = await LocalDb.getAll('payments');
      if (!mounted) return;
      // 记账天数：取三种单据最早的日期到今天
      var first = '';
      String minD(String a, String b) {
        if (a.isEmpty) return b;
        if (b.isEmpty) return a;
        return a.compareTo(b) <= 0 ? a : b;
      }
      for (final s in sales) first = minD(first, '${s['happened_at'] ?? ''}');
      for (final p in pays) first = minD(first, '${p['happened_at'] ?? ''}');
      try {
        final buys = await LocalDb.getAll('purchases');
        for (final b in buys) first = minD(first, '${b['happened_at'] ?? ''}');
      } catch (_) {}
      var days = 0;
      final f = DateTime.tryParse(first);
      if (f != null) {
        final now = DateTime.now();
        days = DateTime(now.year, now.month, now.day)
                .difference(DateTime(f.year, f.month, f.day))
                .inDays +
            1;
        if (days < 1) days = 1;
      }
      // 当前店铺本店交易笔数 = 出货笔数（交易是出货，收款只是出货的一部分——不含收款）
      final selId = await SyncService.selectedClientId();
      final curCount = (selId == null || selId.isEmpty)
          ? 0
          : sales.where((s) => '${s['client_id']}' == selId).length;
      // 店铺结余 = 当前店铺收款（含减免=平账） − 进货（全店通用）＝结账后的盈利
      final paidTotal = pays
          .where((p) => selId == null || '${p['client_id']}' == selId)
          .fold<double>(0,
              (s, x) => s + ((x['amount'] as num?)?.toDouble() ?? 0) + ((x['waived'] as num?)?.toDouble() ?? 0));
      var purchaseTotal = 0.0;
      try {
        final buys = await LocalDb.getAll('purchases');
        purchaseTotal = buys.fold<double>(0, (s, x) => s + ((x['total'] as num?)?.toDouble() ?? 0));
      } catch (_) {}
      setState(() {
        _bookDays = days;
        _curClientCount = curCount;
        _totalBalance = paidTotal - purchaseTotal;
      });
    } catch (_) {}
  }

  /// ISO 时间 → 人类可读（如 9月11日 19:05）
  static String _fmtSyncTime(String iso) {
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return iso;
    return '${t.month}月${t.day}日 ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  /// 更新说明逐行渲染（GitHub release body 是 markdown，逐行清洗展示）：
  /// ① 先按原始换行拆行；② 每行内再用中文分号「；」/英文「;」拆成多条（commit 用①…②…揉一行，
  /// 拆开后一条更新占一行）；③ 列表项加 • 前缀、标题加粗，清洗 markdown 符号；空行留间隔。
  static List<Widget> _renderNotes(String notes, TaozhuColors c) {
    final widgets = <Widget>[];
    // 拆出行：先按换行，再按分号拆（避免"一条更新"挤在一行）
    final lines = notes
        .split('\n')
        .expand((l) => l.split(RegExp(r'[；;]')))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    for (final line in lines) {
      // 清洗 markdown 符号：加粗/链接/行内代码等
      String text = line
          .replaceAll(RegExp(r'\*\*(.+?)\*\*'), r'$1')
          .replaceAll(RegExp(r'\*(.+?)\*'), r'$1')
          .replaceAll(RegExp(r'`(.+?)`'), r'$1')
          .replaceAll(RegExp(r'\[(.+?)\]\(.+?\)'), r'$1')
          .replaceAll(RegExp(r'^#+\s*'), '')
          .replaceAll(RegExp(r'^[-*\d.\s]+'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (text.isEmpty) continue;
      final isTitle = RegExp(r'^#+\s').hasMatch(line);
      final isList = line.startsWith('-') || line.startsWith('*') || line.startsWith('·');
      widgets.add(Padding(
        padding: EdgeInsets.only(left: isList ? 8 : 0, top: 2, bottom: 2),
        child: Text(
          isList ? '• $text' : text,
          style: TextStyle(
            fontSize: isTitle ? 13 : 12,
            color: isTitle ? c.textMain : c.textSub,
            fontWeight: isTitle ? FontWeight.w700 : FontWeight.w400,
            height: 1.4,
          ),
        ),
      ));
    }
    return widgets;
  }

  /// 备份导出/导入已迁移到「数据备份」页（BackupPage）
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

  /// 清除当前账号本地数据：token/角色/接口缓存/离线队列 + 本地数据库 + 附件本地副本
  Future<void> _clearAccountData() async {
    await Api.instance.clearLocalData();
    await LocalDb.clearAll();
    await _clearLocalAttachments(); // 附件本地副本（防止退出后残留、换账号串号显示）
    // 关键：本地库清空后同步进度必须一并重置，否则新账号登录只做增量 pull，
    // 游标之前的服务器数据（大部分历史）永远拉不到，造成"假同步、数据拉不全"
    await SyncService.resetSyncState();
  }

  /// 清空本地附件副本目录（attachments/{entity}/{id}/）：退出/切换账号时调用，
  /// 防止旧账号附件残留（附件查看器本地副本优先会直接显示，且清理页此前扫不到）
  Future<void> _clearLocalAttachments() async {
    if (kIsWeb) return;
    try {
      final root = await getApplicationDocumentsDirectory();
      final dir = Directory('${root.path}/attachments');
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {}
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
    // 检查请求进行中：忽略重复点击
    if (_checkingUpdate) return;
    _checkingUpdate = true;
    try {
      await _checkUpdate0();
    } finally {
      _checkingUpdate = false;
    }
  }

  Future<void> _checkUpdate0() async {
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
    // 首查失败自动重试（有新版时 GitHub 探测偶发失败，多点几次能出——把"人手多点"改成自动）
    var d = <String, dynamic>{};
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        d = await Api.instance.get('/auth/latest-version');
        if ('${d['latest'] ?? ''}'.isNotEmpty) break;
      } catch (_) {}
      if (attempt < 2) await Future.delayed(const Duration(milliseconds: 600));
    }
    try {
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
                    // 更新说明逐行渲染：识别标题/列表项/普通文本，去掉 markdown 符号（好看易读）
                    ..._renderNotes(notes, c),
                  ] else ...[
                    const SizedBox(height: 10),
                    const Text('更新内容', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text('（更新日志暂未获取到，可更新后查看版本说明）',
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
              if (isAndroid || isDesktop) ...[
                TextButton(onPressed: () => Navigator.pop(ctx, 'pick'), child: const Text('选择下载源')),
                FilledButton(onPressed: () => Navigator.pop(ctx, 'update'), child: const Text('立即更新')),
              ] else
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
      } else if (action == 'pick') {
        await _pickSource(ver);
      } else if (action == 'copy') {
        await Clipboard.setData(ClipboardData(text: releaseUrl));
        toast(context, '已复制下载链接');
      }
    } catch (e) {
      toast(context, '检查更新失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  /// 手动选择本次更新的下载源：点击立即弹窗（中间弹出），内部异步并行探测候选源
  /// （官方直连 + 已启用镜像），逐个填充可达性与耗时；点选后只用该源下载（failed 时不轮换其他源）。
  Future<void> _pickSource(String ver) async {
    final custom = await loadUpdateSources();
    final specified = specifiedSource;
    final prefixes = [
      if (specified.isNotEmpty) specified, // 指定的镜像优先（官方直连在国内网络多数不可达）
      '',
      for (final s in custom)
        if (s['enabled'] == true && '${s['url'] ?? ''}' != specified) '${s['url'] ?? ''}',
    ];
    // 结果容器（弹窗内共享）：null=探测中，否则为耗时 ms
    final results = <(String, int?)>[];
    // 先弹窗（0 延迟），再后台探测逐个填充——避免此前"等到全部探测完才显示"的 2 秒白屏
    final picked = await showCenterSheet<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          // 首次构建时启动探测（不阻塞弹窗出现）
          if (results.isEmpty) {
            Future.microtask(() async {
              final r = await Future.wait(prefixes.map((p) async {
                final ms = await probeDownloadSource(p);
                return (p, ms);
              }));
              if (ctx.mounted) {
                setSheet(() => results.addAll(r.where((x) => !results.contains(x))));
              }
            });
          }
          final c = Theme.of(ctx).extension<TaozhuColors>()!;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text('选择下载源（已探测可达性）',
                    style: TextStyle(fontWeight: FontWeight.w600, color: c.textMain)),
              ),
              Flexible(
                child: results.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final (p, ms) in results)
                            ListTile(
                              enabled: ms != null,
                              leading: Icon(ms == null ? Icons.block : Icons.check_circle, size: 20,
                                  color: ms == null ? c.danger : c.success),
                              title: Text(p.isEmpty ? 'GitHub 官方直连' : p,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(ms == null ? '不可达（网络受限）' : '可达 · ${ms}ms'),
                              onTap: ms == null ? null : () => Navigator.pop(ctx, p),
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: 6),
            ],
          );
        },
      ),
    );
    if (picked != null) await _downloadAndInstall(ver, forcedPrefix: picked);
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
  /// 源列表 = 官方 GitHub 直连（第一优先）+ 用户手动启用的自定义镜像（「下载源管理」页配置）；
  /// [forcedPrefix] 非空 = 手动指定本次只用该源（「选择下载源」后调用），失败不轮换；
  /// 下载前轻量探测可用源（Content-Length ≥ 1MB 防拦截页误判），选最快可用交给系统下载器；
  /// 下载失败自动换下一个源；下载完成会校验安装包大小，异常（代理拦截页）删除并换源重试；
  /// 用户手动取消（CANCELED）立即停止，不换源重试。
  Future<void> _downloadAndInstall(String ver, {String? forcedPrefix}) async {
    _downloading = true;
    final fileName = 'taozhu-update-$ver.apk';
    final custom = await loadUpdateSources();
    final specified = specifiedSource;
    final prefixes = forcedPrefix != null
        ? [forcedPrefix]
        : [
            if (specified.isNotEmpty) specified, // 指定的镜像优先（官方直连差）
            '', // 官方 GitHub 直连
            for (final s in custom)
              if (s['enabled'] == true && '${s['url'] ?? ''}' != specified) '${s['url'] ?? ''}',
          ];
    // 拆包下载：按设备 ABI 选对应 APK（arm64-v8a / armeabi-v7a / x86_64）；查不到 ABI 时回退 universal 命名
    String apkName;
    try {
      final abi = await _dlChannel.invokeMethod<String>('abi');
      apkName = (abi == null || abi.isEmpty)
          ? 'taozhu-app-$ver.apk'
          : 'taozhu-app-$ver-$abi.apk';
    } catch (_) {
      apkName = 'taozhu-app-$ver.apk';
    }
    final base = 'https://github.com/free-zuike/taozhu/releases/download/taozhu-v$ver/$apkName';
    try {
      // 下载前并行轻量探测（HEAD Range 0-0），过滤不可达源，避免直接失败；
      // 置顶源（用户指定镜像）可达时固定第一优先
      final usable = await _probeSources(prefixes, pinned: forcedPrefix ?? specified);
      if (usable.isEmpty) {
        toast(context, '所有下载源均不可达，请稍后重试或从 GitHub Release 页手动下载');
        return;
      }
      var urlIdx = 0;
      while (urlIdx < usable.length) {
        final id = await _dlChannel
            .invokeMethod<int>('enqueue', {'url': '${usable[urlIdx]}$base', 'fileName': fileName});
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
            // DownloadManager.STATUS_SUCCESSFUL —— 但代理/镜像可能把拦截页当 200 下完：
            // 先校验文件大小，小于安装包最小可信值 = 下载到的是假文件 → 删除并换下一个源
            final dir = await getDownloadsDirectory();
            final file = File('${dir?.path}/$fileName');
            int size = 0;
            try {
              if (file.existsSync()) size = await file.length();
            } catch (_) {}
            if (size < minTrustedBytes) {
              try {
                if (file.existsSync()) await file.delete();
              } catch (_) {}
              failed = true;
              break;
            }
            await _installFromDownloads(fileName, size);
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

  /// 并行轻量探测下载源可用性（HEAD + Range，Content-Length 需 ≥ 1MB 防拦截页误判），
  /// 按响应耗时升序返回（最快源优先，避免固定顺序导致"第一次不是最快的"）。
  /// 入参为下载前缀列表（'' = 官方直连），探测函数内部拼完整资产 URL。
  /// [pinned] 非空 = 置顶源（「下载源管理」指定的镜像）：可达时固定第一位，不被耗时排序挤掉。
  Future<List<String>> _probeSources(List<String> prefixes, {String pinned = ''}) async {
    final results = await Future.wait(prefixes.map((p) async {
      final ms = await probeDownloadSource(p);
      return ms == null ? null : (p, ms);
    }));
    final usable = <(String, int)>[];
    for (final r in results) {
      if (r != null) usable.add(r);
    }
    usable.sort((a, b) => a.$2.compareTo(b.$2));
    final list = [for (final r in usable) r.$1];
    // 置顶源可达 → 移到第一位（用户指定镜像时优先用它下载，失败再自动换源）
    if (pinned.isNotEmpty && list.contains(pinned)) {
      list.remove(pinned);
      list.insert(0, pinned);
    }
    return list;
  }

  /// 下载完成后引导安装（文件在应用下载目录，由系统 DownloadManager 写入；size 已通过 ≥1MB 校验）
  Future<void> _installFromDownloads(String fileName, int size) async {
    if (!mounted) return;
    final install = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('更新下载完成'),
        content: Text('安装包已就绪（$fileName · ${(size / 1048576).toStringAsFixed(1)}MB）。\n立即安装？'),
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
          const SizedBox(height: 12),
          // 统计卡（仅老板）：记账天数 / 当前店铺总笔数 / 总账本结余（本地核算，秒开）
          if (_role != 'staff' && !kIsWeb)
            _statsCard(),
          if (_role != 'staff' && !kIsWeb) const SizedBox(height: 18),
          // 账号与同步（账号卡下方、经营上方）：同步状态 + 成员（账号设置+账号管理，移到同步下方）
          _card([
            _item(Icons.sync_alt, c.primary, '同步状态', _syncSubtitle(),
                () => goPage(context, const SyncPanelPage())),
            _item(Icons.people_outline, c.primary, '成员', '账号设置 · 店员/老板账号',
                () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const MembersPage()))
                    .then((_) => _loadProfile())),
          ]),
          const SizedBox(height: 18),
          // 店员账号：仅送货视角，隐藏经营类功能（收款/对账/店铺管理）
          if (_role != 'staff') ...[
            _groupTitle('经营'),
            _card([
              _item(Icons.store_outlined, c.primary, '店铺管理', '店铺列表、新增、编辑',
                  () => goPage(context, const ClientsPage())),
              _item(Icons.payments_outlined, c.success, '收款结账', '登记收款、查看收款历史',
                  () => goPage(context, const PaymentsPage())),
              _item(Icons.account_balance_wallet_outlined, c.primary, '收款账户', '收款方式预设：现金/微信/支付宝…（独立页管理）',
                  () => goPage(context, const PaymentAccountsPage())),
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
              _item(Icons.backup_outlined, c.primary, '数据备份', '导出全库存档 / 从备份合并恢复',
                  () => goPage(context, const BackupPage())),
            _item(Icons.system_update_alt_outlined, c.primary, '检查更新',
                kIsWeb ? 'Web 版随部署更新' : '对比最新版本，应用内下载安装', _checkUpdate),
            _item(Icons.dns_outlined, c.primary, '下载源管理', '官方 GitHub 直连 + 自定义镜像（手动测试启用）',
                () => goPage(context, const UpdateSourcesPage())),
            _item(Icons.cleaning_services_outlined, c.primary, '存储清理', '查看并删除安装包/临时文件，释放空间',
                () => goPage(context, const CleanupPage())),
            _item(Icons.receipt_long_outlined, c.primary, '日志',
                '操作记录与错误（全部 / 错误 / 正常 / Debug）',
                () => goPage(context, const LogsPage())),
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

  /// 统计卡：记账天数 / 当前店铺总笔数 / 总账本结余（本地核算，三格并排）
  Widget _statsCard() {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    Widget cell(String label, String value, {Color? color}) {
      return Expanded(
        child: Column(
          children: [
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w800, color: color ?? c.textMain)),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 11, color: c.textSub)),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          cell('记账天数', '$_bookDays'),
          _vsep(c),
          cell('本店交易', '$_curClientCount'),
          _vsep(c),
          cell('店铺结余', '¥${fmtMoney(_totalBalance)}',
              color: _totalBalance >= 0 ? c.success : c.danger),
        ],
      ),
    );
  }

  Widget _vsep(TaozhuColors c) => Container(width: 1, height: 30, color: c.divider);

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
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: c.primary.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: UserAvatar(
              size: 52,
              name: _username,
              localPath: _avatarLocalPath.isEmpty ? null : _avatarLocalPath,
              hasAvatar: _avatar && _avatarUrl.isNotEmpty,
              url: _avatarUrl,
              token: _avatarToken,
            ),
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
      // 防连点：500ms 内重复点击忽略（避免连续 push 页面/重复触发网络请求）
      onTap: () {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastTapAt < 500) return;
        _lastTapAt = now;
        onTap();
      },
    );
  }
}
