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
  /// 同步全局状态（idle/syncing/error）；页面顶部状态行区分 成功✓ / 失败✗ / 同步中转圈
  String _syncStatus = 'idle';
  bool _syncFailed = false;

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
    ('categories_item', '商品分类'),
    ('categories_client', '店铺分类'),
    ('payment_accounts', '收款账户'),
    // 出货/进货按商品明细行数统计（不是单据数：一张单多商品 = 多明细行）
    ('sale_items', '出货商品'),
    ('purchase_items', '进货商品'),
    ('payments', '收款单'),
  ];

  @override
  void initState() {
    super.initState();
    // 进入本页只加载差异展示，不自动同步（进入系统时已自动同步；右上角可手动）
    _syncStatus = SyncService.syncStatus;
    _syncFailed = SyncService.lastSyncFailed;
    SyncService.status.addListener(_onStatus);
    _load();
  }

  @override
  void dispose() {
    SyncService.status.removeListener(_onStatus);
    super.dispose();
  }

  void _onStatus() {
    if (!mounted) return;
    setState(() {
      _syncStatus = SyncService.syncStatus;
      _syncFailed = SyncService.lastSyncFailed;
    });
  }

  Future<void> _load() async {
    // 一次性拉齐本地 + 服务器全部数据后再渲染（并行请求，各自容错）：
    // 避免逐块 setState 导致"未同步图标一条条变已同步"的过程，进页直接看到结果。
    if (mounted) setState(() => _loading = true);
    var local = <String, int>{};
    var pending = 0;
    var deviceId = '';
    var lastSync = '';
    var selectedId = '';
    var selectedName = '';
    var clientLocalSales = 0;
    var clientLocalPayments = 0;
    var localSynced = false;
    String? localError;
    try {
      // 普通实体：读本地库对应 store 计数
      for (final (store, _) in _entities) {
        local[store] = 0;
      }
      final allClients = await LocalDb.getAllByName('clients');
      final allItems = await LocalDb.getAll('items');
      final allCats = await LocalDb.getAll('categories');
      final allSales = await LocalDb.getAll('sales');
      final allPurchases = await LocalDb.getAll('purchases');
      final allPayments = await LocalDb.getAll('payments');
      // 店铺/商品数量
      local['clients'] = allClients.length;
      local['items'] = allItems.length;
      // 分类：商品分类 / 店铺分类分开统计（按 type 过滤）
      local['categories_item'] =
          allCats.where((c) => '${c['type'] ?? ''}' == 'item').length;
      local['categories_client'] =
          allCats.where((c) => '${c['type'] ?? ''}' == 'client').length;
      // 收款账户
      local['payment_accounts'] = (await LocalDb.getAll('payment_accounts')).length;
      // 出货/进货按商品明细行数计算（一张单多商品 = 多行；不是单据数）
      local['sale_items'] = allSales.fold<int>(
          0, (s, x) => s + ((x['items'] as List?)?.length ?? 0));
      local['purchase_items'] = allPurchases.fold<int>(
          0, (s, x) => s + ((x['items'] as List?)?.length ?? 0));
      // 收款单数
      local['payments'] = allPayments.length;
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
          final d = await Api.instance.get('/clients').timeout(const Duration(seconds: 6));
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
      localError = e.toString().replaceFirst('Exception: ', '');
    }
    // 服务器数据：并行拉取，各自容错（失败置 null，页面显示 —）
    Map<String, dynamic>? serverStats;
    Map<String, dynamic>? clientStats;
    Map<String, dynamic>? saleCounts;
    Map<String, dynamic>? payCounts;
    Map<String, dynamic>? saleLineCounts; // 明细行级附件（v0.17.61+ 每行商品独立凭证）
    Map<String, dynamic>? attachTotal;
    await Future.wait([
      _safe(() async {
        serverStats = await Api.instance.get('/sync/stats').timeout(const Duration(seconds: 6));
      }),
      if (selectedId.isNotEmpty) ...[
        _safe(() async {
          clientStats = await Api.instance
              .get('/sync/stats?client_id=$selectedId')
              .timeout(const Duration(seconds: 6));
        }),
        _safe(() async {
          saleCounts = await Api.instance
              .post('/attachments/counts', {'entity': 'sale', 'client_id': selectedId})
              .timeout(const Duration(seconds: 6));
        }),
        _safe(() async {
          payCounts = await Api.instance
              .post('/attachments/counts', {'entity': 'payment', 'client_id': selectedId})
              .timeout(const Duration(seconds: 6));
        }),
        _safe(() async {
          saleLineCounts = await Api.instance
              .post('/attachments/counts', {'entity': 'sale_item', 'client_id': selectedId})
              .timeout(const Duration(seconds: 6));
        }),
      ],
      _safe(() async {
        attachTotal = await Api.instance.get('/attachments/total').timeout(const Duration(seconds: 6));
      }),
    ]);
    // 附件本地副本计数（依赖服务器返回的单据 id）
    var clientLocalAttach = 0;
    var clientServerAttach = 0;
    var localAttachTotal = 0;
    var serverAttachTotal = 0;
    var clientServerSales = 0;
    var clientServerPayments = 0;
    // 闭包捕获的可空变量无法提升类型 → 复制为 final 局部变量再判空
    final sCounts = saleCounts;
    final pCounts = payCounts;
    final tTotal = attachTotal;
    final cStats = clientStats;
    if (sCounts != null && pCounts != null) {
      final saleIds = ((sCounts['ids'] as List?) ?? []).cast<String>();
      final payIds = ((pCounts['ids'] as List?) ?? []).cast<String>();
      clientServerAttach =
          ((sCounts['total'] as num?) ?? 0).toInt() + ((pCounts['total'] as num?) ?? 0).toInt();
      clientLocalAttach =
          await _localAttachCount('sale', saleIds) + await _localAttachCount('payment', payIds);
    }
    // 明细行级附件并入当前店铺统计（服务器 + 本地副本）
    final slCounts = saleLineCounts;
    if (slCounts != null) {
      clientServerAttach += ((slCounts['total'] as num?) ?? 0).toInt();
      final lineIds = ((slCounts['ids'] as List?) ?? []).cast<String>();
      clientLocalAttach += await _localAttachCount('sale_item', lineIds);
    }
    if (tTotal != null) {
      serverAttachTotal = (tTotal['total'] as num?)?.toInt() ?? 0;
      localAttachTotal = await _localAllAttachCount();
    }
    if (cStats != null) {
      clientServerSales = (cStats['sales'] as num?)?.toInt() ?? 0;
      clientServerPayments = (cStats['payments'] as num?)?.toInt() ?? 0;
    }
    final statsLoaded = serverStats != null;
    final clientStatsLoaded = cStats != null;
    final clientAttachLoaded = sCounts != null && pCounts != null;
    final attachTotalLoaded = tTotal != null;
    final errMsg = localError ?? (serverStats == null ? '无法获取服务器数据' : null);
    if (!mounted) return;
    // 一次性渲染完整结果（不再逐块刷新）
    setState(() {
      _localCounts = local;
      _pending = pending;
      _deviceId = deviceId;
      _lastSync = lastSync;
      _selectedClientId = selectedId;
      _selectedClientName = selectedName;
      _clientLocalSales = clientLocalSales;
      _clientLocalPayments = clientLocalPayments;
      _clientLocalAttach = clientLocalAttach;
      _clientServerAttach = clientServerAttach;
      _clientServerSales = clientServerSales;
      _clientServerPayments = clientServerPayments;
      _localAttachTotal = localAttachTotal;
      _serverAttachTotal = serverAttachTotal;
      _localSynced = localSynced;
      _serverStats = serverStats ?? _serverStats;
      _serverStatsLoaded = statsLoaded;
      _clientServerLoaded = clientStatsLoaded;
      _clientAttachLoaded = clientAttachLoaded;
      _attachTotalLoaded = attachTotalLoaded;
      _error = errMsg;
      _loading = false;
    });
  }

  /// 容错包装：任何异常吞掉（调用方用可空变量判断成败）
  Future<void> _safe(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (_) {}
  }

  /// 全部本地附件副本计数（App 文档目录 attachments/ 递归；Web 无本地副本返回 0）。
  /// **直接数附件目录全部文件数**（本地实际存在多少副本就是多少，与服务器 R2 总数对应对比，
  /// 不做在用/孤儿过滤——孤儿归存储清理页决策）。
  Future<int> _localAllAttachCount() async {
    if (kIsWeb) return 0;
    try {
      final root = await getApplicationDocumentsDirectory();
      final dir = Directory('${root.path}/attachments');
      if (!dir.existsSync()) return 0;
      var n = 0;
      try {
        // att/{entity}/{id}/file.jpg 三层结构
        for (final e in dir.listSync()) {
          if (e is! Directory) continue;
          for (final f in e.listSync()) {
            if (f is! Directory) continue;
            n += f.listSync().whereType<File>().length;
          }
        }
      } catch (_) {}
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

  /// 重新全量同步：重置增量游标后强制 fullSync 拉全量（修复"清除数据后增量拉取拉不全"的缺口）。
  /// 下拉整个页面触发（无右上角按钮）。
  Future<void> _fullSyncNow() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      await SyncService.resetSyncState();
      await SyncService.sync().timeout(const Duration(seconds: 60));
    } catch (_) {
    } finally {
      if (!mounted) return;
      setState(() => _syncing = false);
      _load();
      toast(context, '已重新全量同步');
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
        // 无右上角按钮：下拉整个页面 = 重新全量同步（拉全量修复缺口）
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _fullSyncNow,
              edgeOffset: 24,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
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
                  // 同步状态行：成功绿勾 / 失败红叉 / 同步中转圈（图标+颜色区分，避免"一样不明显"）
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        if (_syncStatus == 'syncing')
                          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        else
                          Icon(
                            _syncFailed ? Icons.error_outline : Icons.check_circle_outline,
                            size: 20,
                            color: _syncFailed ? c.danger : c.success,
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _syncStatus == 'syncing'
                                ? '正在同步…'
                                : _syncFailed
                                    ? '上次同步失败（下拉重新全量同步）'
                                    : _lastSync == '从未同步'
                                        ? '等待首次同步'
                                        : '已同步 · $_lastSync',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: _syncFailed ? c.danger : c.textMain,
                            ),
                          ),
                        ),
                        if (_syncStatus == 'syncing')
                          Text('稍等', style: TextStyle(fontSize: 12, color: c.textSub)),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
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
                      child: Text('尚未选择店铺：请先到「交易」页选择店铺后再查看', style: TextStyle(fontSize: 13, color: c.textSub)),
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
                    _row(c, '出货单', _clientServerLoaded ? '服务器 $_clientServerSales 条' : '服务器 —'),
                    _row(c, '收款单', _clientServerLoaded ? '服务器 $_clientServerPayments 条' : '服务器 —'),
                    _row(c, '附件', _clientAttachLoaded ? '服务器 $_clientServerAttach 张' : '服务器 —'),
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
                    // 总计行：7 类实体 + 附件（本地在用附件 vs 服务器全部附件）合计
                    if (_localSynced && _serverStatsLoaded)
                      _diffRow(c, '总计',
                          _entities.fold<int>(0, (s, e) => s + (_localCounts[e.$1] ?? 0)) +
                              (_attachTotalLoaded ? _localAttachTotal : 0),
                          _entities.fold<int>(0, (s, e) => s + ((_serverStats[e.$1] as num?)?.toInt() ?? 0)) +
                              (_attachTotalLoaded ? _serverAttachTotal : 0),
                          isTotal: true),
                  ])
                else
                  _card(c, [
                    for (final (store, label) in _entities)
                      _row(c, label,
                          _serverStatsLoaded
                              ? '服务器 ${(_serverStats[store] as num?)?.toInt() ?? 0} 条'
                              : '服务器 —'),
                    _row(c, '附件', _attachTotalLoaded ? '服务器 $_serverAttachTotal 张' : '服务器 —'),
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
                  child: Text('下拉整个页面 = 重新全量同步（拉全量修复本地缺口）',
                      style: TextStyle(fontSize: 11, color: c.textSub)),
                ),
                ],
                ),
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

  Widget _diffRow(TaozhuColors c, String label, int? local, int? server,
      {bool isTotal = false}) {
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
    return Container(
      decoration: isTotal ? BoxDecoration(border: Border(top: BorderSide(color: c.divider))) : null,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: isTotal ? FontWeight.w700 : FontWeight.w400)),
          ),
          Text('本地 $local',
              style: TextStyle(
                  fontSize: 13,
                  color: c.textMain,
                  fontWeight: isTotal ? FontWeight.w700 : FontWeight.w400)),
          const SizedBox(width: 8),
          Text('服务器 $server',
              style: TextStyle(
                  fontSize: 13,
                  color: c.textMain,
                  fontWeight: isTotal ? FontWeight.w700 : FontWeight.w400)),
          const Spacer(),
          Icon(same ? Icons.check_circle_outline : Icons.sync_problem, size: 18, color: color),
        ],
      ),
    );
  }
}