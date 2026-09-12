import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import 'router.dart';

/// 同步面板：显示本机（App 本地库）与服务器（Web 数据源）的数据差异 + 同步状态 + 行为差异说明。
/// App 本地库是增量同步的读侧镜像；Web 直接读服务器——两者数量不一致即同步缺口。
/// 进入系统（BottomShell）已自动同步；本页只展示差异，右上角按钮手动同步。
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
  String _selectedClientId = '';
  String _selectedClientName = '';
  String? _error;

  // 当前店铺同步状况（本地 vs 服务器，出货/收款/附件）
  int _clientLocalSales = 0;
  int _clientLocalPayments = 0;
  int _clientLocalAttach = 0;
  int _clientServerSales = 0;
  int _clientServerPayments = 0;
  int _clientServerAttach = 0;

  // 全部数据附件（本地副本总数 vs 服务器 R2 总数）
  int _localAttachTotal = 0;
  int _serverAttachTotal = 0;

  // 验证状态：未验证（本地未同步 / 服务器未拉取成功）时差异行显示 —，避免"0=0 假正常"
  bool _localSynced = false; // App 本地库是否已完成首次全量同步
  bool _serverStatsLoaded = false; // 服务器总统计是否成功拉取
  bool _clientServerLoaded = false; // 当前店铺服务器计数是否成功拉取
  bool _clientAttachLoaded = false; // 当前店铺附件数是否成功拉取
  bool _attachTotalLoaded = false; // 全部附件总数是否成功拉取

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
    // 进入本页只加载差异展示，不自动同步（进入系统时已自动同步；右上角可手动）
    _load();
  }

  Future<void> _load() async {
    // 本地数据立即可得，先渲染（不再被服务器请求阻塞转圈）
    // 任何一步异常都必须释放 _loading（finally），否则页面永久转圈
    var local = <String, int>{};
    var pending = 0;
    var deviceId = '';
    var lastSync = '';
    var selectedId = '';
    var selectedName = '';
    var clientLocalSales = 0;
    var clientLocalPayments = 0;
    var localSynced = false;
    try {
      local = <String, int>{};
      for (final (store, _) in _entities) {
        local[store] = (await LocalDb.getAll(store)).length;
      }
      pending = await SyncService.pendingCount();
      deviceId = await SyncService.deviceId();
      lastSync = (await SyncService.lastSyncAt()) ?? '';
      localSynced = await SyncService.isFullDone(); // App 本地库是否已有首次全量数据（Web 恒 false）
      // 当前选择的店铺（账本页持久化；按店铺隔离同步的入口）
      selectedId = (await SyncService.selectedClientId()) ?? '';
      var clients = await LocalDb.getAllByName('clients');
      if (kIsWeb || clients.isEmpty) {
        // Web 无本地库（或 App 首次同步前）：从服务器拉店铺列表解析名称；
        // 从未选过店铺 → 默认第一个并保存（与账本页行为一致），修复 Web「永远未选择店铺」
        try {
          final d = await Api.instance.get('/clients');
          final netClients = ((d['clients'] as List?) ?? []).cast<Map<String, dynamic>>();
          if (netClients.isNotEmpty) {
            clients = netClients;
            if (selectedId.isEmpty) {
              selectedId = '${netClients.first['id']}';
              await SyncService.saveSelectedClientId(selectedId);
            }
          }
        } catch (_) {}
      }
      if (selectedId.isNotEmpty) {
        selectedName = clients
                .where((c) => '${c['id']}' == selectedId)
                .map((c) => '${c['name']}')
                .firstOrNull ??
            '';
        // 当前店铺本地出货/收款计数（按 client_id 过滤本地镜像）
        final sales = await LocalDb.getAll('sales');
        final payments = await LocalDb.getAll('payments');
        clientLocalSales = sales.where((s) => '${s['client_id']}' == selectedId).length;
        clientLocalPayments = payments.where((p) => '${p['client_id']}' == selectedId).length;
      }
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
          _selectedClientId = selectedId;
          _selectedClientName = selectedName;
          _clientLocalSales = clientLocalSales;
          _clientLocalPayments = clientLocalPayments;
          _localSynced = localSynced;
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
        _serverStatsLoaded = true;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
    // 当前店铺的服务器计数（与本地差异行同款）+ 附件数（出货/收款凭证图片）
    if (selectedId.isNotEmpty) {
      try {
        final d = await Api.instance.get('/sync/stats?client_id=$selectedId');
        if (!mounted) return;
        setState(() {
          _clientServerSales = (d['sales'] as num?)?.toInt() ?? 0;
          _clientServerPayments = (d['payments'] as num?)?.toInt() ?? 0;
          _clientServerLoaded = true;
        });
      } catch (_) {
        // 店铺维度统计失败不影响整页（差异行显示 0）
      }
      try {
        // 服务器按店铺汇总附件数（R2），并返回该店全部单据 id 供本地副本对账
        final saleRes = await Api.instance.post('/attachments/counts', {'entity': 'sale', 'client_id': selectedId});
        final payRes = await Api.instance.post('/attachments/counts', {'entity': 'payment', 'client_id': selectedId});
        final saleIds = ((saleRes['ids'] as List?) ?? []).cast<String>();
        final payIds = ((payRes['ids'] as List?) ?? []).cast<String>();
        final serverAttach = ((saleRes['total'] as num?) ?? 0).toInt() + ((payRes['total'] as num?) ?? 0).toInt();
        final localAttach =
            await _localAttachCount('sale', saleIds) + await _localAttachCount('payment', payIds);
        if (!mounted) return;
        setState(() {
          _clientServerAttach = serverAttach;
          _clientLocalAttach = localAttach;
          _clientAttachLoaded = true;
        });
      } catch (_) {
        // 附件统计失败不影响整页（差异行显示 0）
      }
    }
    // 全部数据：附件总数（本地副本 vs 服务器 R2，分页统计）
    try {
      final d = await Api.instance.get('/attachments/total');
      final serverAttachTotal = (d['total'] as num?)?.toInt() ?? 0;
      final localAttachTotal = await _localAllAttachCount();
      if (!mounted) return;
      setState(() {
        _serverAttachTotal = serverAttachTotal;
        _localAttachTotal = localAttachTotal;
        _attachTotalLoaded = true;
      });
    } catch (_) {
      // 附件总数统计失败不影响整页
    }
  }

  /// 全部本地附件副本计数（App 文档目录 attachments/ 递归；Web 无本地副本返回 0）
  Future<int> _localAllAttachCount() async {
    if (kIsWeb) return 0;
    try {
      final root = await getApplicationDocumentsDirectory();
      final dir = Directory('${root.path}/attachments');
      if (!dir.existsSync()) return 0;
      var n = 0;
      for (final e in dir.listSync()) {
        if (e is Directory) {
          for (final f in e.listSync()) {
            if (f is Directory) n += f.listSync().whereType<File>().length;
          }
        }
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  /// 本地附件副本计数（App 文档目录 attachments/{entity}/{id}/；Web 无本地副本返回 0）
  Future<int> _localAttachCount(String entity, List<String> ids) async {
    if (kIsWeb || ids.isEmpty) return 0;
    try {
      final root = await getApplicationDocumentsDirectory();
      var n = 0;
      for (final id in ids) {
        final dir = Directory('${root.path}/attachments/$entity/$id');
        if (dir.existsSync()) {
          n += dir.listSync().whereType<File>().length;
        }
      }
      return n;
    } catch (_) {
      return 0;
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
            tooltip: '同步全部数据',
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
                // 当前选择的店铺同步状况（本地 vs 服务器，同款差异行）
                Row(
                  children: [
                    Text('当前店铺同步状况', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: c.textMain)),
                    const Spacer(),
                    Text(_selectedClientName.isEmpty ? '未选择店铺' : _selectedClientName,
                        style: TextStyle(fontSize: 12, color: c.primary)),
                  ],
                ),
                const SizedBox(height: 8),
                if (_selectedClientId.isEmpty)
                  _card(c, [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      child: Text('尚未选择店铺：请先到「交易（账本）」页选择店铺后再查看', style: TextStyle(fontSize: 13, color: c.textSub)),
                    ),
                  ])
                else if (!kIsWeb)
                  _card(c, [
                    _diffRow(c, '出货单',
                        _localSynced ? _clientLocalSales : null,
                        _clientServerLoaded ? _clientServerSales : null),
                    _diffRow(c, '收款单',
                        _localSynced ? _clientLocalPayments : null,
                        _clientServerLoaded ? _clientServerPayments : null),
                    _diffRow(c, '附件',
                        _localSynced ? _clientLocalAttach : null,
                        _clientAttachLoaded ? _clientServerAttach : null),
                  ])
                else
                  _card(c, [
                    _row(c, '出货单', '服务器 $_clientServerSales 条'),
                    _row(c, '收款单', '服务器 $_clientServerPayments 条'),
                    _row(c, '附件', '服务器 $_clientServerAttach 张'),
                  ]),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text('全部数据差异（本地 vs 服务器）', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: c.textMain)),
                    const Spacer(),
                    if (kIsWeb) Text('Web 无本地数据', style: TextStyle(fontSize: 12, color: c.textSub)),
                  ],
                ),
                const SizedBox(height: 8),
                if (!kIsWeb)
                  _card(c, [
                    for (final (store, label) in _entities)
                      _diffRow(c, label,
                          _localSynced ? (_localCounts[store] ?? 0) : null,
                          _serverStatsLoaded ? ((_serverStats[store] as num?)?.toInt() ?? 0) : null),
                    _diffRow(c, '附件',
                        _localSynced ? _localAttachTotal : null,
                        _attachTotalLoaded ? _serverAttachTotal : null),
                  ])
                else
                  _card(c, [
                    for (final (store, label) in _entities)
                      _row(c, label, '服务器 ${(_serverStats[store] as num?)?.toInt() ?? 0} 条'),
                    _row(c, '附件', '服务器 $_serverAttachTotal 张'),
                  ]),
                if (!kIsWeb && !_localSynced)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('本地库尚未完成首次同步，本地列显示 —（进入应用会自动同步）',
                        style: TextStyle(fontSize: 11, color: c.warning)),
                  ),
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
                  child: Text('进入系统时已自动同步；右上角按钮可随时手动同步',
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

  Widget _diffRow(TaozhuColors c, String label, int? local, int? server) {
    // 未验证（本地未同步 / 服务器未拉取成功）→ 显示 —，不把 0=0 显示成"正常"
    if (local == null || server == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            SizedBox(width: 90, child: Text(label, style: const TextStyle(fontSize: 13))),
            Text(local == null ? '本地 —' : '本地 $local', style: TextStyle(fontSize: 13, color: c.textSub)),
            const SizedBox(width: 8),
            Text(server == null ? '服务器 —' : '服务器 $server', style: TextStyle(fontSize: 13, color: c.textSub)),
            const Spacer(),
            Icon(Icons.remove_circle_outline, size: 18, color: c.textSub),
          ],
        ),
      );
    }
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