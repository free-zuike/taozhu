import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../realtime_sync.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../version.dart';
import 'center_sheet.dart';
import 'force_update_dialog.dart';
import '../pages/sale_page.dart';
import '../pages/my_page.dart';
import '../pages/purchase_page.dart';
import '../pages/purchase_history_page.dart';
import '../pages/ledger_page.dart';
import '../pages/stats_page.dart';

/// 底部悬浮胶囊导航（对齐移动记账信息架构）：
/// 交易（流水，账本=店铺胶囊筛选，出货·收款）/ 统计 / 中央「记一笔」/ 进货（记录，独立不分店）/ 我的
class BottomShell extends StatefulWidget {
  const BottomShell({super.key});
  @override
  State<BottomShell> createState() => _BottomShellState();
}

class _BottomShellState extends State<BottomShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _isStaff = false; // 店员：无统计权限，隐藏统计 tab

  // 懒构建：只有切到的 tab 才实例化（避免 IndexedStack 预构建全部页面 →
  // 启动瞬间 4 个页面同时 initState 并发发网络请求导致"重复请求 + 挂起"）。
  // 已构建的 tab 保留状态（IndexedStack 持有），切回不重载。
  final List<Widget> _pages = const [
    LedgerPage(),
    StatsPage(),
    PurchaseHistoryPage(),
    MyPage(),
  ];
  late final List<bool> _built = [true, false, false, false];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 服务端 426 强制更新门禁 → 弹不可关闭的更新窗（Web 部署即新不注册）
    if (!kIsWeb) {
      Api.onForceUpdate = (latest) {
        if (mounted) showForceUpdateDialog(context, latest);
      };
    }
    Api.instance.getRole().then((r) {
      if (mounted) setState(() => _isStaff = r == 'staff');
    });
    // 启动同步：首次 full，后续增量 pull + 推送待发（静默）
    SyncService.sync();
    // 实时同步：保持 WebSocket 连接，服务端有变更立即拉取（断线自动重连）
    RealtimeSync.instance.start();
    // 强制更新检查：启动延迟静默查 latest-version 的 min_supported，当前版本低于最低支持 →
    // 弹不可关闭的更新窗（更新检查属网络动作，网络失败/Web 静默跳过，不违背本地优先）
    _checkForceUpdate();
  }

  /// 切换 tab：首次切到才构建页面（懒加载防启动并发请求）
  void _selectTab(int i) {
    setState(() {
      _built[i] = true;
      _index = i;
    });
  }

  /// 启动强制更新检查：仅当服务端声明了 min_supported 且当前版本低于它时弹窗
  Future<void> _checkForceUpdate() async {
    if (kIsWeb) return;
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    try {
      final d = await Api.instance.get('/auth/latest-version');
      final min = '${d['min_supported'] ?? ''}';
      final latest = '${d['latest'] ?? ''}';
      if (min.isNotEmpty && versionBelow(APP_VERSION, min)) {
        await showForceUpdateDialog(context, latest);
      }
    } catch (_) {
      // 网络失败静默：同步/检查更新路径仍会再次触发
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    RealtimeSync.instance.stop();
    super.dispose();
  }

  /// 回到前台：不主动触发同步（对齐参考实现：同步由 连接建立 autoSync + WS 事件 驱动，
  /// 回前台时 WS 重连自动补一次全量，避免每次回前台都全量拉取导致日志刷屏/耗时变长）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 保持 WidgetsBindingObserver 以便 dispose 时移除监听；同步时机由 RealtimeSync 统一管理
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        // 懒构建：未切到的 tab 先不放（占位），切到时才实例化——避免启动时全部页面并发 initState 发请求
        children: [
          for (var i = 0; i < _pages.length; i++)
            _built[i] ? _pages[i] : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF1E1E1E) : Colors.white.withOpacity(0.96),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(dark ? 0.25 : 0.08), blurRadius: 16, offset: const Offset(0, 4)),
            ],
          ),
          child: Row(
            children: [
              _navItem(0, Icons.receipt_long_outlined, '交易'),
              if (!_isStaff) _navItem(1, Icons.bar_chart_outlined, '统计'),
              _centerButton(),
              // 进货/我的固定指向页数组索引 2/3（staff 时统计 tab 隐藏但索引不变）
              _navItem(2, Icons.shopping_cart_outlined, '进货'),
              _navItem(3, Icons.person_outline, '我的'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(int i, IconData icon, String label) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    final active = _index == i;
    final color = active ? c.primary : c.textSub;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _selectTab(i),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(fontSize: 11, color: color, fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
          ],
        ),
      ),
    );
  }

  Widget _centerButton() {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onTap: _showQuickBook,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: c.primary,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: c.primary.withOpacity(0.4), blurRadius: 10, offset: const Offset(0, 3))],
          ),
          child: const Icon(Icons.add, color: Colors.white, size: 30),
        ),
      ),
    );
  }

  void _showQuickBook() {
    showCenterSheet<void>(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('记一笔', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
          ),
          ListTile(
            leading: const Icon(Icons.storefront, color: Color(0xFF409EFF)),
            title: const Text('出货记单'),
            subtitle: const Text('给店铺送货'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SalePage()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.shopping_cart, color: Color(0xFF67C23A)),
            title: const Text('进货记单'),
            subtitle: const Text('从供应商进货'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PurchasePage()));
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
