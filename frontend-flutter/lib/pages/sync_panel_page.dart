import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import 'router.dart';

/// 同步面板：显示本机（App 本地库）与服务器（Web 数据源）的数据差异 + 同步状态 + 行为差异说明。
/// App 本地库是 增量同步的读侧镜像；Web 直接读服务器——两者数量不一致即同步缺口。
class SyncPanelPage extends StatefulWidget {
  const SyncPanelPage({super.key});
  @override
  State<SyncPanelPage> createState() => _SyncPanelPageState();
}

class _SyncPanelPageState extends State<SyncPanelPage> {
  bool _loading = true;
  bool _syncing = false;
  Map<String, dynamic> _serverStats = {};
  Map<String, int> _localCounts = {};
  int _pending = 0;
  String _deviceId = '';
  String _lastSync = '';
  String? _error;

  static const _entities = [
    ('clients', '店铺'),
    ('items', '商品'),
    ('categories', '分类'),
    ('sales', '出货单'),
    ('purchases', '进货单'),
    ('payments', '收款单'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 本地数据立即可得，先渲染（不再被服务器请求阻塞转圈）
    // 任何一步异常都必须释放 _loading（finally），否则页面永久转圈
    var local = <String, int>{};
    var pending = 0;
    var deviceId = '';
    var lastSync = '';
    try {
      local = <String, int>{};
      for (final (store, _) in _entities) {
        local[store] = (await LocalDb.getAll(store)).length;
      }
      pending = await SyncService.pendingCount();
      deviceId = await SyncService.deviceId();
      lastSync = (await SyncService.lastSyncAt()) ?? '';
    } catch (e) {
      if (mounted) {
        _error = e.toString().replaceFirst('Exception: ', '');
      }
    } finally {
      if (mounted) {
        setState(() {
          _localCounts = local;
          _pending = pending;
          _deviceId = deviceId;
          _lastSync = lastSync;
          _loading = false;
        });
      }
    }
    // 服务器统计异步到达后更新（慢/失败不影响已展示的本地数据）
    try {
      final d = await Api.instance.get('/sync/stats');
      if (!mounted) return;
      setState(() {
        _serverStats = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      await SyncService.sync().timeout(const Duration(seconds: 30));
    } catch (_) {
      // 同步超时/异常也结束转圈（服务端卡死不阻塞 UI）
    } finally {
      if (!mounted) return;
      setState(() => _syncing = false);
      _load();
      toast(context, '已触发同步');
    }
  }

  String _fmtTime(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '从未同步';
    final local = t.toLocal();
    return '${local.month}月${local.day}日 ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    // 同步中或首次加载转圈；本地有数据时同步虽未完成仍可展示旧计数
    return Scaffold(
      appBar: AppBar(
        title: const Text('同步状态'),
        actions: [
          IconButton(
            tooltip: '立即同步',
            icon: _syncing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            onPressed: _syncing ? null : _syncNow,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                if (_error != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: c.danger.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      children: [
                        Icon(Icons.cloud_off, color: c.danger),
                        const SizedBox(width: 8),
                        Expanded(child: Text('无法获取服务器数据：$_error', style: TextStyle(color: c.danger, fontSize: 13))),
                      ],
                    ),
                  ),
                _card(c, [
                  _row(c, '当前设备', _deviceId.isEmpty ? '—' : _deviceId.substring(0, 8)),
                  _row(c, '上次成功同步', _fmtTime(_lastSync)),
                  _row(c, '待推送变更', kIsWeb ? '—（Web 无本地队列）' : '$_pending 条'),
                  _row(c, '数据源',
                      kIsWeb ? 'Web：直连服务器（无本地缓存）' : 'App：本地库优先 + 后台同步，与服务器差异见下表'),
                ]),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text('数据差异（本地 vs 服务器）', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: c.textMain)),
                    const Spacer(),
                    if (kIsWeb) Text('Web 无本地数据', style: TextStyle(fontSize: 12, color: c.textSub)),
                  ],
                ),
                const SizedBox(height: 8),
                if (!kIsWeb)
                  _card(c, [
                    for (final (store, label) in _entities)
                      _diffRow(c, label, _localCounts[store] ?? 0, (_serverStats[store] as num?)?.toInt() ?? 0),
                  ])
                else
                  _card(c, [
                    for (final (store, label) in _entities)
                      _row(c, label, '服务器 ${(_serverStats[store] as num?)?.toInt() ?? 0} 条'),
                  ]),
                const SizedBox(height: 14),
                Text('Web 与 App 行为差异', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: c.textMain)),
                const SizedBox(height: 8),
                _card(c, [
                  for (final e in [
                    ('Web（浏览器）', '直连服务器实时读写；离线无法打开数据（无本地库）'),
                    ('App（手机/桌面）', '本地库镜像 + 增量同步：页面秒开（读本地），断网可记单，网络恢复自动推送'),
                    ('为什么要同步', 'App 的本地库是服务器数据的缓存镜像——每次写操作先落本地再推服务器（LWW 冲突解决），其他设备/Web 上的新变更通过增量拉取合并回来'),
                    ('差异怎么产生', '刚才新记的单还没推上去、或另一台设备/Web 上的新变更还没拉下来——本地数量会暂时少于服务器；绿色=已一致'),
                    ('什么时候会自动同步', '打开 App、回到前台、记完一笔后约 1 秒内（250ms 防抖批量推送）'),
                  ])
                    _row(c, e.$1, e.$2),
                ]),
                const SizedBox(height: 8),
                Center(
                  child: Text('本地数据可能滞后（网络较差时），以服务器为准；下拉或点右上角同步刷新',
                      style: TextStyle(fontSize: 11, color: c.textSub)),
                ),
              ],
            ),
    );
  }

  Widget _card(TaozhuColors c, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(16)),
      child: Column(children: children),
    );
  }

  Widget _row(TaozhuColors c, String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(k, style: TextStyle(fontSize: 13, color: c.textSub))),
          Expanded(child: Text(v, style: TextStyle(fontSize: 13, color: c.textMain))),
        ],
      ),
    );
  }

  Widget _diffRow(TaozhuColors c, String label, int local, int server) {
    final same = local == server;
    final color = same ? c.success : c.warning;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          SizedBox(width: 90, child: Text(label, style: const TextStyle(fontSize: 13))),
          Text('本地 $local', style: TextStyle(fontSize: 13, color: c.textMain)),
          const SizedBox(width: 8),
          Text('服务器 $server', style: TextStyle(fontSize: 13, color: c.textMain)),
          const Spacer(),
          Icon(same ? Icons.check_circle_outline : Icons.sync_problem, size: 18, color: color),
        ],
      ),
    );
  }
}