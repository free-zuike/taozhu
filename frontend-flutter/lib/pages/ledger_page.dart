import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../api.dart';
import '../local_accounts.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import '../widgets/center_sheet.dart';
import '../widgets/year_month_picker.dart';
import 'router.dart';
import 'attachment_viewer.dart';
import 'sale_page.dart';
import 'payments_page.dart';
import 'sale_batch_edit_page.dart';
import 'sale_line_edit.dart';

/// 交易（店铺）：出货 / 收款流水，按店铺+时间范围，支持编辑删除与附件（按日期分组列表）
class LedgerPage extends StatefulWidget {
  const LedgerPage({super.key});
  @override
  State<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends State<LedgerPage> {
  List<Map<String, dynamic>> _sales = [];
  List<Map<String, dynamic>> _payments = [];
  List<Map<String, dynamic>> _clients = [];
  String? _clientId; // 店铺维度：必选，默认第一个；无店铺时自动建「默认店铺」
  bool _isStaff = false; // 店员账号：仅当天出货视角
  bool _loading = true;
  bool _offline = false; // 本次加载走了本地缓存（无网络）
  /// 店铺选择弹层本地汇总（原生：笔数/欠款本地计算；Web 直接显示服务端字段）
  Map<String, ({int count, double debt})> _clientStat = {};
  /// 出货单 id → 附件数（整单级，无明细备注行用）
  Map<String, int> _saleAttachCount = {};
  /// 出货明细行 id → 附件数（行级，每行商品独立凭证）
  Map<String, int> _saleLineAttachCount = {};
  /// 收款单 id → 附件数
  Map<String, int> _payAttachCount = {};
  /// 商品 id → 分类名（出货明细行第二行显示分类，替代无实际数据的交易时间）
  Map<String, String> _itemCategory = {};
  /// 月度结余（四列式卡片；进货为全局支出、进货页可见，本卡不再展示）
  double _mIncome = 0; // 收入 = 收款（实收，未收为 0）
  double _mSold = 0; // 售出 = 出货（当前店铺）
  double _mGross = 0; // 毛利 = 售出 − 成本（当前店铺）
  double _mDebt = 0; // 未回款 = 应收欠款（截止 end 累计出货 − 累计收款）
  double _mBalance = 0; // 结余 = 毛利（售出 − 成本，不含进货）
  bool _mLoaded = false; // 月度结余是否已加载（未加载显示占位符，不闪 0）
  int _selYear = DateTime.now().year; // 月度结余所选年份（头部月份切换）
  int _selMonth = DateTime.now().month; // 所选月份
  /// 列表滚动联动：顶部月份跟随当前可见日期（对齐参考实现的日期头可见性 → 月份标签切换）。
  /// 每个日期分组头一个 GlobalKey，滚动时取视口内最顶部可见的日期头 → 解析年月 → 更新 _selYear/_selMonth。
  final Map<String, GlobalKey> _dateHeaderKeys = {};
  ScrollController? _flowCtrl;
  Timer? _scrollMonthDebounce;
  bool _scrollPicking = false; // 编程滚动中选择月份（别让滚动回调又改回）

  @override
  void initState() {
    super.initState();
    // 列表滚动联动月份：对齐参考实现的"日期头可见性 → 顶部月份标签跟随切换"
    _flowCtrl = ScrollController()..addListener(_onFlowScroll);
    // 店员账号：仅当天出货视角（后端强制当天）
    Api.instance.getRole().then((r) {
      if (mounted) setState(() => _isStaff = r == 'staff');
    });
    // 同步完成后本地库变了 → 重新从本地读（本地优先，网络静默）
    SyncService.version.addListener(_onSync);
    _load();
    // 月度结余：页面加载即网络拉取（Web 直连；App 顺带一次静默刷新，失败保留占位不阻塞）
    _loadMonthly();
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    _flowCtrl?.removeListener(_onFlowScroll);
    _flowCtrl?.dispose();
    _scrollMonthDebounce?.cancel();
    SyncService.version.removeListener(_onSync);
    super.dispose();
  }

  /// 同步通知防抖：WS 推送/多端操作可能连续触发 version 通知，
  /// 合并 500ms 内的多次通知为一次 _load（Web 端每次刷新要拉 6+ 个接口，不防抖会"一直刷新"）
  Timer? _syncDebounce;

  void _onSync() {
    if (!mounted) return;
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _load();
      // 同步完成后后台刷新一次云端附件数（其他设备/Web 上传的附件），
      // 不在页面加载时访问网络（本地优先：离线进交易页零网络请求）
      if (!kIsWeb) _loadAttachCounts(withCloud: true);
    });
  }

  /// 加载所选月份的月度结余：
  /// 售出=当前店铺出货、收入=收款（当前店铺）、毛利=售出−成本（当前店铺）、
  /// 未回款=应收欠款（截止 end 累计出货−累计收款）、结余=毛利（不含进货——进货为全局支出，进货页可见）。
  /// 店员无统计权限跳过；离线保留上次值。
  Future<void> _loadMonthly() async {
    if (_isStaff) return;
    final y = _selYear;
    final m = _selMonth;
    final start = _fmtDate(DateTime(y, m, 1));
    final end = _fmtDate(DateTime(y, m + 1, 0));
    try {
      final cq = _clientId != null ? '&client_id=$_clientId' : '';
      final d = await Api.instance
          .get('/stats/summary?start=$start&end=$end$cq')
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      final sold = (d['sales_total'] as num?)?.toDouble() ?? 0;
      final paid = (d['paid_total'] as num?)?.toDouble() ?? 0;
      final gross = (d['gross_profit'] as num?)?.toDouble() ?? 0;
      final debt = (d['debt'] as num?)?.toDouble() ?? 0;
      setState(() {
        _mSold = sold;
        _mIncome = paid;
        _mGross = gross;
        _mDebt = debt;
        _mBalance = gross; // 结余 = 毛利（售出 − 成本）
        _mLoaded = true;
      });
    } catch (_) {
      // 离线/接口失败：保留上次数据（未加载过则保持占位）
      if (mounted && !_mLoaded) setState(() => _mLoaded = true);
    }
  }

  /// 月份选择弹层（点标题切换年月：只选年月，无需选日）
  Future<void> _pickMonth() async {
    final picked = await showYearMonthPicker(
      context,
      year: _selYear,
      month: _selMonth,
    );
    if (picked == null) return;
    // 编程切换到选中月份后，滚动列表定位到该月首日（滚动联动月份随选中同步）
    _scrollPicking = true;
    setState(() {
      _selYear = picked.year;
      _selMonth = picked.month;
    });
    _loadMonthly(); // 月度结余卡数据跟随选中月份
    _scrollToMonth(picked.year, picked.month);
    Future.delayed(const Duration(milliseconds: 600), () => _scrollPicking = false);
  }

  /// 选中月份后：滚动列表到该月第一条（精确滚动到日期头）
  void _scrollToMonth(int year, int month) {
    final prefix = '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';
    final key = _dateHeaderKeys.entries
        .where((e) => e.key.startsWith(prefix))
        .map((e) => e.value)
        .firstOrNull;
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 400), alignment: 0.0);
    }
  }

  /// 列表滚动 → 顶部月份跟随当前可见日期（对齐参考实现的日期头可见性联动）：
  /// 遍历日期头 keys，取最顶部可见（视口内 dy 最小且已滚过顶）的日期头 → 更新月份标签。
  void _onFlowScroll() {
    if (_scrollPicking) return; // 编程滚动选择月份时不联动（防回跳）
    _scrollMonthDebounce?.cancel();
    _scrollMonthDebounce = Timer(const Duration(milliseconds: 100), _syncMonthFromScroll);
  }

  void _syncMonthFromScroll() {
    if (!mounted || _scrollPicking) return;
    // 找视口内最顶部的日期头：dy 最小且位于列表区域（取已挂载的 key 中 dy 最小者）
    double? bestDy;
    String? bestDate;
    for (final e in _dateHeaderKeys.entries) {
      final ctx = e.value.currentContext;
      final ro = ctx?.findRenderObject();
      if (ro is! RenderBox || !ro.attached) continue;
      final dy = ro.localToGlobal(Offset.zero).dy;
      if (bestDy == null || dy < bestDy) {
        bestDy = dy;
        bestDate = e.key;
      }
    }
    if (bestDate == null || bestDate.length < 7) return;
    final y = int.tryParse(bestDate.substring(0, 4));
    final m = int.tryParse(bestDate.substring(5, 7));
    if (y == null || m == null) return;
    if (y == _selYear && m == _selMonth) return;
    setState(() {
      _selYear = y;
      _selMonth = m;
    });
    // 月份变化 → 月度结余卡数据跟随所选月份（静默刷新，失败保留占位）
    _loadMonthly();
  }

  static String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 时间范围 → (起始, 结束)：仅顶部统计卡用（月度结余/毛利/未回款按所选月份）；
  /// 列表始终显示全部数据（对齐参考实现在同一页看所有交易，用户"切换了月份其他月份都不见了"反馈）
  (String, String)? _rangeDates() {
    return (_fmtDate(DateTime(_selYear, _selMonth, 1)),
        _fmtDate(DateTime(_selYear, _selMonth + 1, 0)));
  }

  String _dateQuery() => ''; // （进货独立 tab，本页不再使用）

  /// 出货/收款查询：店铺必选（列表显示全部时间，不按月过滤）；进货不按店铺
  String _clientQuery() {
    final params = <String>[];
    if (_clientId != null) params.add('client_id=$_clientId');
    return params.isEmpty ? '' : '?${params.join('&')}';
  }

  /// Web 端商品目录（分类映射用）：拉 /items/summary（含 category），失败返回空。
  /// 结果缓存 60s——WS 频繁通知时页面每次刷新都调 _load，商品目录不常变，反复全量拉会拖慢 Web 交易页
  static List<Map<String, dynamic>>? _webItemsCache;
  static DateTime _webItemsCacheAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _webItemsCacheTtl = Duration(seconds: 60);

  Future<List<Map<String, dynamic>>> _webItems() async {
    if (kIsWeb &&
        _webItemsCache != null &&
        DateTime.now().difference(_webItemsCacheAt) < _webItemsCacheTtl) {
      return _webItemsCache!;
    }
    try {
      final d = await Api.instance.get('/items/summary');
      _webItemsCache = ((d['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      _webItemsCacheAt = DateTime.now();
      return _webItemsCache!;
    } catch (_) {
      return _webItemsCache ?? [];
    }
  }

  /// 本地优先加载（同步只由「我的」页/进应用自动同步驱动，页面刷新不再访问网络）：
  /// ① 读本地库镜像（按当前店铺+范围过滤）立即展示——有就秒开，空就显示空态；
  /// ② 同步完成后 SyncService.version 通知会再来 _load 一次（本地数据自动更新）；
  /// ③ Web 无本地库，仍直连服务器读取。
  Future<void> _load() async {
    final firstLocal = await LocalDb.getAllByName('clients');
    // 形式层切换：优先从行级 sale_items store 读取并组装（sale_items → 按 sale_id 分组 → 假整单），
    // 让渲染代码零改动地切到行记录；sales 整单 store 仅 Web/旧数据兜底。
    final rowSales = await LocalDb.getAll('sale_items');
    final allSales = rowSales.isNotEmpty
        ? _assembleFromRows(rowSales)
        : await LocalDb.getAll('sales');
    final allPays = await LocalDb.getAll('payments');
    // 商品分类映射（明细行第二行显示分类）：原生读本地库镜像，Web 拉简化目录
    final items = kIsWeb
        ? await _webItems()
        : await LocalDb.getAllByName('items');
    _itemCategory = {
      for (final it in items) '${it['id']}': '${it['category'] ?? ''}',
    };
    // 店铺选择弹层的笔数/欠款用本地全量汇总（与后端口径一致：笔数=出货单数，欠款=Σ出货-Σ收款）
    _clientStat = _localStats(allSales, allPays);
    var sales = allSales;
    var payments = allPays;
    // 选中店铺校验：当前 id 已被删除/不存在 → 回退第一个存档店铺（否则按已删店铺过滤出现"交易不显示"）
    if (firstLocal.isEmpty) {
      _clientId = null; // 无店铺：显示全部（空态提示建店）
    } else if (_clientId != null && !firstLocal.any((c) => '${c['id']}' == _clientId)) {
      _clientId = '${firstLocal.first['id']}';
      await SyncService.saveSelectedClientId(_clientId!);
    } else if (_clientId == null) {
      // 恢复上次选择的店铺（而非每次默认第一个）
      final saved = await SyncService.selectedClientId();
      _clientId = saved != null && firstLocal.any((c) => '${c['id']}' == saved)
          ? saved
          : '${firstLocal.first['id']}';
      await SyncService.saveSelectedClientId(_clientId!);
    }
    if (_clientId != null) {
      sales = _filterByClient(sales, _clientId!);
      payments = _filterByClient(payments, _clientId!);
    }
    // Web 无本地库（本地渲染恒空）：跳过"先渲染空列表"，直接网络加载并保留旧列表——
    // 否则每次 WS 通知重载都会"空白→填充"跳动；原生保持本地优先渲染
    if (!kIsWeb && mounted) {
      setState(() {
        _clients = firstLocal;
        _sales = sales;
        _payments = payments;
        _loading = false;
        // Web 无本地库（firstLocal 恒空）：不能据此判离线，否则刷新时误闪「离线数据」横幅；
        // 离线与否交给 _loadNetwork 的网络成败决定（true 离线时才显示提示）
        _offline = kIsWeb ? false : firstLocal.isEmpty;
      });
    }
    if (kIsWeb) await _loadNetwork(firstLocal);
    // 附件计数（有附件才显示图标）：本地目录扫描零网络；云端 counts 仅同步完成/Web 直连时刷新
    _loadAttachCounts(withCloud: kIsWeb);
  }

  /// 行记录 → 假整单数组（同 sale_id 归并；行自带头部字段 client_id/client_name/happened_at/note）
  static List<Map<String, dynamic>> _assembleFromRows(List<Map<String, dynamic>> rows) {
    final byOrder = <String, List<Map<String, dynamic>>>{};
    final meta = <String, Map<String, dynamic>>{};
    for (final r in rows) {
      final oid = '${r['sale_id'] ?? ''}';
      if (oid.isEmpty) continue;
      (byOrder[oid] ??= []).add(r);
      meta[oid] = {
        'id': oid, 'client_id': r['client_id'] ?? '', 'client_name': r['client_name'] ?? '',
        'happened_at': r['happened_at'] ?? '', 'note': r['note'] ?? '',
      };
    }
    return byOrder.entries.map((e) {
      final items = e.value;
      final m = meta[e.key]!;
      final total = items.fold<double>(0, (s, it) => s + ((it['amount'] as num?)?.toDouble() ?? 0));
      return {...m, 'total': total, 'items': items};
    }).toList();
  }

  /// 统计当前可见出货明细行/收款单的附件数：本地副本目录优先（原生，零网络），云端批量 counts 精确覆盖。
  /// 出货按明细行（sale_item，每行商品独立凭证）；收款按单据。
  Future<void> _loadAttachCounts({bool withCloud = false}) async {
    final saleLineIds = [
      for (final s in _sales)
        for (final it in ((s['items'] as List?) ?? []) as List)
          '${(it as Map)['id'] ?? ''}',
    ].where((x) => x.isNotEmpty).toSet().toList();
    // 无明细（备注行）整单附件仍按单据级展示
    final saleOrderIds = _sales.map((s) => '${s['id']}').whereType<String>().where((x) => x.isNotEmpty).toSet().toList();
    final payIds = _payments.map((p) => '${p['id']}').whereType<String>().where((x) => x.isNotEmpty).toSet().toList();
    final counts = <String, Map<String, int>>{
      'sale_item': {}, 'sale': {},
      'payment': {},
    };
    // ① 本地副本（原生）：attachments/{entity}/{id}/ 目录里有多少文件
    if (!kIsWeb && (saleLineIds.isNotEmpty || payIds.isNotEmpty || saleOrderIds.isNotEmpty)) {
      try {
        final root = await getApplicationDocumentsDirectory();
        for (final e in [(saleLineIds, 'sale_item'), (saleOrderIds, 'sale'), (payIds, 'payment')]) {
          for (final id in e.$1) {
            final dir = Directory('${root.path}/attachments/${e.$2}/$id');
            if (dir.existsSync()) {
              final n = dir.listSync().whereType<File>().length;
              if (n > 0) counts[e.$2]![id] = n;
            }
          }
        }
      } catch (_) {}
    }
    // ② 云端批量 counts（一次一个实体；仅同步完成后台刷新或 Web 直连时执行，页面加载不发请求）
    if (withCloud || kIsWeb) {
      Future<void> fetch(String entity, List<String> ids) async {
        if (ids.isEmpty) return;
        try {
          final d = await Api.instance.post('/attachments/counts', {'entity': entity, 'ids': ids});
          final m = (d['counts'] as Map?) ?? {};
          for (final e in m.entries) {
            final n = (e.value as num?)?.toInt() ?? 0;
            if (n > 0) counts[entity]!['${e.key}'] = n;
          }
        } catch (_) {}
      }
      await Future.wait([
        fetch('sale_item', saleLineIds),
        fetch('sale', saleOrderIds),
        fetch('payment', payIds),
      ]);
    }
    if (!mounted) return;
    setState(() {
      _saleLineAttachCount = counts['sale_item']!;
      _saleAttachCount = counts['sale']!;
      _payAttachCount = counts['payment']!;
    });
  }

  /// Web 端直连服务器（无本地库）：拉店铺/出货/收款并刷新视图
  Future<void> _loadNetwork(List<Map<String, dynamic>> firstLocal) async {
    try {
      final cr = await Api.instance.get('/clients');
      var clients = ((cr['clients'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (clients.isEmpty) clients = [await Api.instance.post('/clients', {'name': '默认店铺'})];
      if (!mounted) return;
      if (_clientId == null || !clients.any((c) => '${c['id']}' == _clientId)) {
        // 已选店铺不存在（被删）→ 恢复上次选择，否则取第一个
        final saved = await SyncService.selectedClientId();
        _clientId = saved != null && clients.any((c) => '${c['id']}' == saved)
            ? saved
            : '${clients.first['id']}';
        await SyncService.saveSelectedClientId(_clientId!);
      }
      final results = await Future.wait([
        Api.instance.get('/sales${_clientQuery()}'),
        Api.instance.get('/payments${_clientQuery()}'),
      ]);
      if (!mounted) return;
      final netSales = ((results[0]['sales'] as List?) ?? []).cast<Map<String, dynamic>>();
      final netPays = ((results[1]['payments'] as List?) ?? []).cast<Map<String, dynamic>>();
      // 镜像写库（增量 upsert，不删本地未推送的单；Web 端 LocalDb 空操作）
      await Future.wait([
        LocalDb.upsertList('clients', clients),
        LocalDb.upsertList('sales', netSales),
        LocalDb.upsertList('payments', netPays),
      ]);
      if (!mounted) return;
      setState(() {
        _clients = clients;
        _sales = _filterByClient(netSales, _clientId!);
        _payments = _filterByClient(netPays, _clientId!);
        _loading = false;
        _offline = false;
      });
    } catch (_) {
      // 网络失败：Web 无本地库（无法离线展示）→ 复位 loading 显示空态/错误，不显示"离线数据"横幅；
      // 原生已有本地数据展示，静默即可；本地也无数据时标记离线态
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!kIsWeb && firstLocal.isEmpty) _offline = true;
      });
    }
  }

  /// 本地全量汇总：笔数 = 出货单数 + 收款单数；欠款 = Σ出货总额 − Σ收款金额（与后端口径一致）
  Map<String, ({int count, double debt})> _localStats(
      List<Map<String, dynamic>> sales, List<Map<String, dynamic>> pays) {
    final saleSum = <String, double>{};
    final saleCnt = <String, int>{};
    for (final s in sales) {
      final id = '${s['client_id']}';
      saleSum[id] = (saleSum[id] ?? 0) + ((s['total'] as num?)?.toDouble() ?? 0);
      saleCnt[id] = (saleCnt[id] ?? 0) + 1;
    }
    final paySum = <String, double>{};
    for (final p in pays) {
      final id = '${p['client_id']}';
      paySum[id] = (paySum[id] ?? 0) + ((p['amount'] as num?)?.toDouble() ?? 0);
    }
    // 笔数 = 出货单数（收款只是出货的一部分，不计入——与「我的」页本店交易口径一致）；
    // 欠款 = Σ出货 − Σ收款
    return {
      for (final id in {...saleSum.keys, ...paySum.keys})
        id: (count: (saleCnt[id] ?? 0),
            debt: ((saleSum[id] ?? 0) - (paySum[id] ?? 0)).toDouble()),
    };
  }

  /// 店铺选择弹层的笔数（= 出货笔数；收款只是出货的一部分，不计入——与「我的」页本店交易口径一致）
  String _statCount(Map<String, dynamic> c) {
    final v = (c['sale_count'] as num?)?.toInt();
    if (v != null) return '$v';
    return '${_clientStat['${c['id']}']?.count ?? 0}';
  }

  /// 店铺选择弹层的欠款（服务端字段优先，本地镜像缺失时用本地汇总兜底）
  double _statDebt(Map<String, dynamic> c) {
    final v = (c['debt'] as num?)?.toDouble();
    if (v != null) return v;
    return _clientStat['${c['id']}']?.debt ?? 0;
  }

  String _date(Object? v) {
    final s = '$v';
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  /// 本地记录按当前店铺过滤（列表始终显示全部数据可上下滑动，对齐参考实现在同一页看所有交易；
  /// 月份切换只影响顶部统计卡，不再过滤列表——用户"切换了月份其他月份都不见了"反馈）
  List<Map<String, dynamic>> _filterByClient(List<Map<String, dynamic>> rows, String clientId) {
    return rows.where((x) => '${x['client_id']}' == clientId).toList();
  }

  /// 月度结余卡（四列 + 月份切换）：
  /// 售出=出货（当前店铺）/ 收入=收款（当前店铺）/ 未回款=应收欠款（当前店铺）/ 结余=毛利（售出−成本，不含进货——进货为全局支出、进货页可见）。
  /// 头部月份可直接切换（← 年月 →）；网络值优先，本地兜底按所选月份+当前店铺算售出/收款。
  Widget _monthlyCard(TaozhuColors c) {
    // 本地快照（所选月份，当前店铺）：明细日期空→单据日期
    final y = _selYear;
    final m = _selMonth;
    final monthStart = _fmtDate(DateTime(y, m, 1));
    final monthEnd = _fmtDate(DateTime(y, m + 1, 0));
    bool inMonth(String d) => d.isNotEmpty && d.compareTo(monthStart) >= 0 && d.compareTo(monthEnd) <= 0;
    double localSold = 0; // 售出=出货
    for (final s in _sales) {
      if (_clientId != null && '${s['client_id']}' != _clientId) continue;
      final orderDate = _date('${s['happened_at'] ?? ''}');
      final items = ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      for (final it in items) {
        final d = _date('${it['happened_at'] ?? ''}');
        final use = d.isNotEmpty ? d : orderDate;
        if (!inMonth(use)) continue;
        localSold += ((it['amount'] as num?)?.toDouble() ?? 0);
      }
    }
    double localPaid = 0; // 收入=收款
    for (final p in _payments) {
      if (_clientId != null && '${p['client_id']}' != _clientId) continue;
      final d = _date('${p['happened_at'] ?? ''}');
      if (!inMonth(d)) continue;
      localPaid += ((p['amount'] as num?)?.toDouble() ?? 0) + ((p['waived'] as num?)?.toDouble() ?? 0);
    }
    // 本地毛利兜底：售出 − 成本（明细行 sale_price/cost_price）
    double localGross = 0;
    for (final s in _sales) {
      if (_clientId != null && '${s['client_id']}' != _clientId) continue;
      final orderDate = _date('${s['happened_at'] ?? ''}');
      final items = ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      for (final it in items) {
        final d = _date('${it['happened_at'] ?? ''}');
        final use = d.isNotEmpty ? d : orderDate;
        if (!inMonth(use)) continue;
        final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
        localGross += (((it['sale_price'] as num?)?.toDouble() ?? 0) - ((it['cost_price'] as num?)?.toDouble() ?? 0)) * qty;
      }
    }
    // 网络值（精确，含其他设备写入）优先；未加载时本地快照兜底
    final sold = _mLoaded ? _mSold : localSold;
    final income = _mLoaded ? _mIncome : localPaid;
    final gross = _mLoaded ? _mGross : localGross;
    final debt = _mLoaded ? _mDebt : (localSold - localPaid);
    final balance = _mLoaded ? _mBalance : localGross; // 结余 = 毛利（售出 − 成本，不含进货）

    Widget col(String label, double value, Color color) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 11, color: c.textSub)),
            const SizedBox(height: 3),
            Text('¥${fmtMoney(value)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: color)),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 10, 12),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部：月份切换——点击年月弹选择器（对齐参考项目：无左右箭头，点选切换）
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _pickMonth,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.calendar_month_outlined, size: 16, color: c.primary),
                      const SizedBox(width: 4),
                      Text('$y年$m月',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.textMain)),
                      const SizedBox(width: 2),
                      Icon(Icons.expand_more, size: 16, color: c.textSub),
                    ],
                  ),
                ),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              col('售出', sold, c.primary),
              const SizedBox(width: 3),
              col('收入', income, income > 0 ? c.success : c.warning),
              const SizedBox(width: 3),
              col('未回款', debt, debt > 0 ? c.warning : c.textSub),
              const SizedBox(width: 3),
              col('结余', balance, balance >= 0 ? c.success : c.danger),
            ],
          ),
        ],
      ),
    );
  }

  /// 店选弹层：全部店铺（名称 + 交易笔数 + 欠款），底部新增店铺
  Future<void> _showLedgerPicker() async {
    final selected = await showCenterSheet<String>(
      context: context,
      maxHeightFactor: 0.8,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('选择店铺', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                // 按店铺分类分组（食堂/档口等）：分类标题 + 组内店铺（店铺管理在「我的」页，这里只选店）
                ..._clientGroups().entries.map((g) => [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                        child: Text(g.key,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Theme.of(context).extension<TaozhuColors>()!.textSub,
                            )),
                      ),
                      for (final c in g.value)
                        _storeTile(ctx, c),
                    ]).expand((x) => x),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected != null && selected != (_clientId ?? '')) {
      setState(() => _clientId = selected.isEmpty ? null : selected);
      SyncService.saveSelectedClientId(_clientId ?? '');
      _load();
      // 店铺切换后：月度结余收入按新店铺重算（支出=进货全店不变）
      _loadMonthly();
    }
  }

  /// 店铺按分类分组（食堂/档口等；未分类归入"未分类"）
  Map<String, List<Map<String, dynamic>>> _clientGroups() {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final c in _clients) {
      final cn = '${c['category_name'] ?? ''}'.trim();
      (grouped[cn.isEmpty ? '未分类' : cn] ??= []).add(c);
    }
    return grouped;
  }

  Widget _storeTile(BuildContext ctx, Map<String, dynamic> c) {
    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: const Color(0xFF409EFF).withOpacity(0.12),
        child: const Icon(Icons.storefront, size: 18, color: Color(0xFF409EFF)),
      ),
      title: Text('${c['name']}',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      subtitle: _isStaff
          ? null // 店员不显示交易笔数/欠款（经营数据）
          : Text(
              '交易 ${_statCount(c)} 笔 · 欠 ¥${_statDebt(c).toStringAsFixed(2)}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF9CA3AF)
                    : const Color(0x8A000000),
              ),
            ),
      trailing: '${c['id']}' == _clientId
          ? const Icon(Icons.check_circle, color: Color(0xFF409EFF), size: 20)
          : null,
      onTap: () => Navigator.pop(ctx, '${c['id']}'),
    );
  }

  /// 记单场景快速新增店铺（对话框，创建后自动选中）
  Future<void> _addClientQuick() async {
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增店铺'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '店铺名称 *'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('创建')),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) {
      toast(context, '请输入店铺名称');
      return;
    }
    try {
      if (kIsWeb) {
        // Web 无本地库/同步队列：直连服务端
        final d = await Api.instance.post('/clients', {'name': name});
        final id = '${d['id'] ?? ''}';
        if (mounted && id.isNotEmpty) {
          _clientId = id;
          SyncService.saveSelectedClientId(id);
        }
        toast(context, '已创建店铺「$name」');
        _load();
        return;
      }
      // 原生本地优先：本地建档 + 队列推送（店铺是同步实体，离线可用）
      final id = 'c${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';
      final payload = {
        'id': id, 'name': name, 'contact': '', 'phone': '', 'note': '',
        'start_date': '', 'end_date': '', 'month_start_day': 1,
        'category_id': '', 'deleted_at': null,
      };
      await LocalDb.upsertOne('clients', payload);
      await SyncService.enqueueChange(entityType: 'client', entitySyncId: id, payload: payload);
      if (mounted) {
        _clientId = id;
        SyncService.saveSelectedClientId(id);
      }
      toast(context, '已创建店铺「$name」，正在同步');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFF56C6C)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _editSale(Map<String, dynamic> s) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SalePage(editId: '${s['id']}')))
        .then((_) => _load());
  }

  /// 点明细行 → 只编辑当前商品（数量/售价/单位/日期，弹窗即时保存）；
  /// item_id 空（无明细占位/旧数据未带行 id）不再静默跳整单——按商品名从单内定位编辑。
  Future<void> _editSaleLine(Map<String, dynamic> l) async {
    final order = l['order'] as Map<String, dynamic>;
    if ('${l['item_id'] ?? ''}'.isEmpty) {
      // 尝试按商品名在单内定位明细行 id（旧数据兜底）；定位不到才回退整单编辑
      final name = '${l['item_name'] ?? ''}';
      String? found;
      for (final it in ((order['items'] as List?) ?? []).cast<Map<String, dynamic>>()) {
        if ('${it['item_name']}' == name) {
          found = '${it['id'] ?? ''}';
          if (found.isNotEmpty) break;
        }
      }
      if (found != null && found.isNotEmpty) {
        final copy = Map<String, dynamic>.from(l)..['item_id'] = found;
        await editSaleLine(context, copy);
        _load();
        return;
      }
      _editSale(order);
      return;
    }
    await editSaleLine(context, l);
    _load();
  }

  /// 删除单条出货商品行（长按商品行触发）：Web 直连 DELETE /sales/items/:id；
  /// 原生 = 本地镜像删该行 + 行级 delete 入队（去单据化：同步实体是 sale_item 商品行，不再推整单快照）。
  /// 只有无明细（备注占位行）才回退整单删除。
  Future<void> _deleteSaleLine(Map<String, dynamic> l) async {
    final order = l['order'] as Map<String, dynamic>;
    final itemId = '${l['item_id'] ?? ''}';
    final name = '${l['item_name'] ?? ''}'.isNotEmpty ? '「${l['item_name']}」' : '该商品';
    if (itemId.isEmpty) {
      await _deleteSaleOrder(order);
      return;
    }
    final ok = await _confirm('删除商品', '确定删除 $name 这一行吗？仅删除该商品，其他商品保留；库存自动回滚。');
    if (!ok) return;
    try {
      if (kIsWeb) {
        final r = await Api.instance.delete('/sales/items/$itemId');
        // 服务端已级联：删的是最后一行时该条出货记录整体消失（无空壳单）
        if (r is Map && r['order_deleted'] == true) {
          toast(context, '已删除该商品（本条记录已无商品）');
          _load();
          return;
        }
      } else {
        // 原生：本地镜像 items 移除该行
        final items = ((order['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        final updatedItems = items.where((it) => '${it['id']}' != itemId).toList();
        if (updatedItems.isEmpty) {
          // 删的是该条记录最后一商品 → 整条记录删除（不留空壳单，与 Web 级联语义一致）
          await LocalDb.deleteOne('sales', '${order['id']}');
          await SyncService.enqueueChange(
              entityType: 'sale', entitySyncId: '${order['id']}', action: 'delete', payload: {});
          toast(context, '已删除该商品（本条记录已无商品）');
          _load();
          return;
        }
        final payload = Map<String, dynamic>.from(order)..['items'] = updatedItems;
        payload['total'] = updatedItems.fold<double>(
            0, (s, it) => s + ((it['amount'] as num?)?.toDouble() ?? 0));
        final dates = [
          for (final it in updatedItems)
            '${it['happened_at'] ?? ''}'.isNotEmpty
                ? '${it['happened_at']}'
                : '${payload['happened_at'] ?? ''}',
        ];
        if (dates.isNotEmpty) {
          final maxD = dates.reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
          if (maxD.isNotEmpty) payload['happened_at'] = maxD;
        }
        await LocalDb.upsertOne('sales', payload);
        // 去单据化：删除走行级 sale_item delete（服务端删行 + 空则级联整条）
        await SyncService.enqueueChange(
            entityType: 'sale_item', entitySyncId: itemId, action: 'delete', payload: {
          'id': itemId, 'sale_id': '${order['id']}', 'client_id': '${order['client_id'] ?? ''}',
        });
      }
      toast(context, '已删除该商品');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 日期栏 → 该日出货商品明细行列表（无"出货单"概念：每行一条商品，点行=编辑该商品、长按=删除该商品）
  Future<void> _openBatchEdit(String date, List<Map<String, dynamic>> lines) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SaleBatchEditPage(date: date, lines: lines, clientId: _clientId)));
    _load();
  }

  /// 删除某条记录（无明细占位行 <-> 删除该条记录全部；有明细时走行级删除）
  Future<void> _deleteSaleOrder(Map<String, dynamic> order) async {
    final orderId = '${order['id']}';
    final name = '${order['client_name'] ?? ''}';
    final ok = await _confirm('删除记录', '确定删除 ${_date(order['happened_at'])} 对 $name 的这条记录吗？该记录下全部商品一并删除，库存自动回滚。');
    if (!ok) return;
    try {
      if (kIsWeb) {
        await Api.instance.delete('/sales/$orderId');
      } else {
        // 原生：先删本地行（立即生效），再入同步队列（其他设备 pull 到 delete 后同步删除）
        await LocalDb.deleteOne('sales', orderId);
        await SyncService.enqueueChange(
            entityType: 'sale', entitySyncId: orderId, action: 'delete', payload: {});
      }
      toast(context, '已删除该记录');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _editPayment(Map<String, dynamic> p) async {
    final amountCtrl = TextEditingController(text: '${p['amount']}');
    final dateCtrl = TextEditingController(text: _date(p['happened_at']));
    final noteCtrl = TextEditingController(text: '${p['note'] ?? ''}');
    var method = '${p['method'] ?? ''}';
    String? clientId = '${p['client_id']}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑收款'),
        content: StatefulBuilder(
          builder: (ctx, setDlg) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: clientId,
                decoration: const InputDecoration(labelText: '店铺'),
                items: _clients
                    .map((c) => DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}')))
                    .toList(),
                onChanged: (v) => setDlg(() => clientId = v),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '金额（元）'),
              ),
              const SizedBox(height: 8),
              TextField(controller: dateCtrl, decoration: const InputDecoration(labelText: '日期（YYYY-MM-DD）')),
              const SizedBox(height: 8),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () async {
                  final picked = await pickAccount(ctx, current: method);
                  if (picked != null && ctx.mounted) setDlg(() => method = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: '收款方式（账户）'),
                  child: Text(method.isEmpty ? '点击选择' : method,
                      style: TextStyle(color: Theme.of(ctx).brightness == Brightness.dark ? Colors.white : Colors.black)),
                ),
              ),
              const SizedBox(height: 8),
              TextField(controller: noteCtrl, decoration: const InputDecoration(labelText: '备注')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final amount = double.tryParse(amountCtrl.text.trim());
    if (clientId == null) {
      toast(context, '请选择店铺');
      return;
    }
    if (amount == null || amount <= 0) {
      toast(context, '请输入有效金额');
      return;
    }
    try {
      if (kIsWeb) {
        await Api.instance.patch('/payments/${p['id']}', {
          'client_id': clientId,
          'amount': amount,
          'happened_at': dateCtrl.text.trim(),
          'method': method,
          'note': noteCtrl.text.trim(),
        });
        toast(context, '已保存');
        _load();
        return;
      }
      // 原生本地优先：本地镜像更新 + 队列推送（保留原字段，避免丢 waived 等）
      final payload = Map<String, dynamic>.from(p)
        ..['client_id'] = clientId
        ..['amount'] = amount
        ..['happened_at'] = dateCtrl.text.trim()
        ..['method'] = method
        ..['note'] = noteCtrl.text.trim();
      await LocalDb.upsertOne('payments', payload);
      await SyncService.enqueueChange(entityType: 'payment', entitySyncId: '${p['id']}', payload: payload);
      toast(context, '已保存，正在同步');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 收款记录所属店铺名：同步 payload 不含 client_name（本地镜像无此字段），用本地店铺镜像反查
  String _clientNameOf(Map<String, dynamic> p) {
    final direct = '${p['client_name'] ?? ''}'.trim();
    if (direct.isNotEmpty) return direct;
    final id = '${p['client_id'] ?? ''}';
    if (id.isEmpty) return '';
    return _clients.where((c) => '${c['id']}' == id).firstOrNull?['name'] as String? ?? '';
  }

  Future<void> _deletePayment(Map<String, dynamic> p) async {
    if (!await _confirm('撤销收款', '确定撤销 ${_date('${p['happened_at']}')} ${_clientNameOf(p)} 的收款（¥${p['amount']}）吗？')) {
      return;
    }
    try {
      if (kIsWeb) {
        await Api.instance.delete('/payments/${p['id']}');
      } else {
        // 原生本地优先：本地删行 + 队列推送 delete + 立即推送（删除即时生效，防复活）
        await LocalDb.deleteOne('payments', '${p['id']}');
        await SyncService.enqueueChange(
            entityType: 'payment', entitySyncId: '${p['id']}', action: 'delete', payload: {});
        unawaited(SyncService.pushPending());
      }
      toast(context, '已撤销，正在同步');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// CSV 字段转义：含逗号/引号/换行的加引号包裹
  String _csv(Object? v) {
    final s = '$v';
    return s.contains(',') || s.contains('"') || s.contains('\n') ? '"${s.replaceAll('"', '""')}"' : s;
  }

  /// 导出当前筛选 CSV（出货/收款，按店铺+范围）
  Future<void> _exportCsv() async {
    final buf = StringBuffer('\uFEFF');
    buf.writeln('类型,日期,店铺,商品,数量,单位,单价,金额,备注');
    for (final s in _sales) {
      final items = (s['items'] as List? ?? []);
      for (final it in items) {
        buf.writeln([
          '出货',
          _csv(_date(s['happened_at'])),
          _csv(s['client_name']),
          _csv(it['item_name']),
          _csv(it['quantity']),
          _csv(it['unit']),
          _csv(it['sale_price']),
          _csv(it['amount']),
          _csv(s['note']),
        ].join(','));
      }
    }
    for (final p in _payments) {
      buf.writeln([
        '收款',
        _csv(_date(p['happened_at'])),
        _csv(p['client_name']),
        '',
        '',
        '',
        '',
        _csv(p['amount']),
        _csv(p['method']),
      ].join(','));
    }
    final bytes = Uint8List.fromList(utf8.encode(buf.toString()));
    await Share.shareXFiles(
      [XFile.fromData(bytes, mimeType: 'text/csv', name: 'taozhu-店铺.csv')],
      text: '陶朱店铺 CSV',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('交易'),
          actions: [
            IconButton(
              tooltip: '导出 CSV',
              icon: const Icon(Icons.file_download_outlined),
              onPressed: _exportCsv,
            ),
          ],
          bottom: TabBar(
            tabs: _isStaff
                ? const [Tab(text: '出货')]
                : const [Tab(text: '出货'), Tab(text: '收款')],
            labelColor: c.primary,
            unselectedLabelColor: c.textSub,
            labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 14),
            indicator: BoxDecoration(
              color: c.primary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            indicatorSize: TabBarIndicatorSize.label,
          ),
        ),
        body: Column(
          children: [
            if (_offline)
              Container(
                width: double.infinity,
                color: const Color(0xFFE6A23C).withOpacity(0.12),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: const Row(
                  children: [
                    Icon(Icons.wifi_off, size: 16, color: Color(0xFFE6A23C)),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text('离线数据：当前无法连接服务器，显示本地缓存，可能不是最新',
                          style: TextStyle(fontSize: 12, color: Color(0xFFB88230))),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 店铺选择：点击弹出全部店铺弹层（名称+交易笔数+欠款+新增）
                  if (_clients.isNotEmpty)
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _showLedgerPicker,
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: c.field,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: c.primary.withOpacity(0.4)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.store_outlined, size: 20, color: c.primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _clients
                                          .where((c) => '${c['id']}' == _clientId)
                                          .map((c) => '${c['name']}')
                                          .firstOrNull ??
                                      '选择店铺',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: c.textMain,
                                  ),
                                ),
                              ),
                              Icon(Icons.keyboard_arrow_down, color: c.textSub),
                            ],
                          ),
                        ),
                      ),
                    ),
                  // 月度结余卡（三列：支出=进货/收入=出货/结余=出货−进货）：
                  // 点击进入全部月份流式页；店员无统计权限不显示
                  if (!_isStaff) ...[
                    const SizedBox(height: 8),
                    _monthlyCard(c),
                  ],
                  const SizedBox(height: 8),
                  // 列表跟随顶部月份选择器（选几月显示几月），无独立时间筛选
                  if (_isStaff)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('今日送货记录', style: TextStyle(fontSize: 12, color: c.textSub)),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(children: _isStaff
                      ? [
                          _buildSaleFlow('今日暂无出货记录'),
                        ]
                      : [
                          _buildSaleFlow('暂无偿付记录'),
                          _buildList('暂无收款记录', _payments, _paymentCard,
                              (p) => ((p['amount'] as num?)?.toDouble() ?? 0),
                              emptyActionLabel: '＋ 去收款',
                              onEmptyAction: () => Navigator.of(context)
                                  .push(MaterialPageRoute(builder: (_) => const PaymentsPage()))
                                  .then((_) => _load())),
                    ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(
    String emptyText,
    List<Map<String, dynamic>> rows,
    Widget Function(Map<String, dynamic>) card,
    double Function(Map<String, dynamic>) amountOf, {
    String? emptyActionLabel,
    VoidCallback? onEmptyAction,
  }) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    if (rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.all(48),
              child: Column(
                children: [
                  const Icon(Icons.receipt_long_outlined, size: 40, color: Color(0xFFD0D5DD)),
                  const SizedBox(height: 12),
                  Text(emptyText, style: TextStyle(color: c.textSub)),
                  if (emptyActionLabel != null) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: c.primary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: onEmptyAction,
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(emptyActionLabel),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }
    // 按日期分组（流水：日期组头 + 行）
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      final d = _date(r['happened_at']);
      (grouped[d] ??= []).add(r);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [
          for (final e in grouped.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 14, 4, 2),
              child: Row(
                children: [
                  Text(_weekday(e.key),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: c.textMain,
                      )),
                  const Spacer(),
                  Text(
                    '${e.value.length} 笔 · 合计 ¥${fmtMoney(e.value.fold<double>(0, (s, r) => s + amountOf(r)))}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.textSub,
                    ),
                  ),
                ],
              ),
            ),
            for (final r in e.value) card(r),
          ],
        ],
      ),
    );
  }

  /// 日期 → "2026-09-09 周三"
  String _weekday(String date) {
    final d = DateTime.tryParse(date);
    if (d == null) return date;
    const wd = ['一', '二', '三', '四', '五', '六', '日'];
    return '$date 周${wd[d.weekday - 1]}';
  }

  /// 卡片右上 ⋯ 菜单：编辑 / 删除（附件图标直接放行内，分类在「点击交易修改」里改）
  Widget _menu({required VoidCallback edit, required VoidCallback del}) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_vert, size: 18, color: c.textSub),
      onSelected: (v) {
        if (v == 'edit') edit();
        if (v == 'del') del();
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'edit', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.edit_outlined, size: 18), title: Text('编辑'))),
        PopupMenuItem(value: 'del', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.delete_outline, size: 18, color: c.danger), title: Text('删除', style: TextStyle(color: c.danger)))),
      ],
    );
  }

  /// 出货流水（商品明细铺开）：按明细行日期分组，每行一条商品
  /// （三行卡片：①商品名称+备注 ②商品分类+附件 ③进价·售价·数量）；点行编辑该商品，附件图标直达凭证。
  Widget _buildSaleFlow(String emptyText) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    // 展开为明细行：行日期回退单据日期；无明细的单据显示备注/占位
    final lines = <Map<String, dynamic>>[];
    for (final s in _sales) {
      final orderDate = _date(s['happened_at']);
      final orderNote = '${s['note'] ?? ''}'.trim();
      final items = (s['items'] as List? ?? []).cast<Map<String, dynamic>>();
      if (items.isEmpty) {
        lines.add({
          'date': orderDate, 'order': s, 'client_name': '${s['client_name'] ?? ''}',
          'item_name': '（无明细）',
          'quantity': '', 'unit': '', 'amount': ((s['total'] as num?)?.toDouble() ?? 0),
          'item_id': '', 'goods_id': '', 'sale_price': null, 'cost_price': null, 'qty_num': 0,
          'note': orderNote,
          'happened_at': '${s['happened_at'] ?? orderDate}',
        });
      }
      for (final it in items) {
        final id = '${it['happened_at'] ?? ''}';
        // 分类：优先用本地商品目录映射（商品分类修改后即时生效），
        // 明细行自带快照（后端 join 时旧值）仅作本地目录缺该商品时的兜底
        final dirCat = _itemCategory['${it['item_id'] ?? ''}'] ?? '';
        final catInline = '${it['item_category'] ?? it['category'] ?? ''}'.trim();
        // 备注：行级 note 优先，空则回退单据 note（仅首行显示，避免每行重复）
        final lineNote = '${it['note'] ?? ''}'.trim();
        lines.add({
          'date': id.length >= 10 ? id.substring(0, 10) : orderDate,
          'order': s,
          'client_name': '${s['client_name'] ?? ''}',
          'item_name': '${it['item_name'] ?? ''}',
          'category': dirCat.isNotEmpty ? dirCat : catInline,
          'quantity': '${it['quantity'] ?? ''}',
          'unit': '${it['unit'] ?? ''}',
          'amount': ((it['amount'] as num?)?.toDouble() ?? 0),
          'item_id': '${it['id'] ?? ''}',          // 明细行 id（行级编辑/删除端点用）
          'goods_id': '${it['item_id'] ?? ''}',    // 真实商品 id（改分类等商品级操作用）
          'sale_price': (it['sale_price'] as num?)?.toDouble(),
          'cost_price': (it['cost_price'] as num?)?.toDouble(),
          'qty_num': (it['quantity'] as num?)?.toDouble() ?? 0,
          'note': lineNote.isNotEmpty ? lineNote : (it == items.first ? orderNote : ''),
          'happened_at': id.isEmpty ? '${s['happened_at'] ?? orderDate}' : id,
        });
      }
    }
    if (lines.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.all(48),
              child: Column(
                children: [
                  const Icon(Icons.receipt_long_outlined, size: 40, color: Color(0xFFD0D5DD)),
                  const SizedBox(height: 12),
                  Text(emptyText, style: TextStyle(color: c.textSub)),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: c.primary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const SalePage()))
                        .then((_) => _load()),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('＋ 记一笔出货'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    // 按行日期分组（日期相同按店名排序）
    lines.sort((a, b) {
      final x = '${a['date']}'.compareTo('${b['date']}');
      return x != 0 ? x : '${a['client_name']}'.compareTo('${b['client_name']}');
    });
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final l in lines) {
      (grouped['${l['date']}'] ??= []).add(l);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        controller: _flowCtrl,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [
          for (final e in grouped.entries) ...[
            // 日期栏 = 该日全部明细的编辑入口（点行编辑对应商品；不跨日期改期）
            // GlobalKey：滚动联动月份（取视口内最顶部日期头 → 顶部月份跟随切换）
            KeyedSubtree(
              key: _dateHeaderKeys.putIfAbsent(e.key, GlobalKey.new),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _openBatchEdit(e.key, e.value),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 2),
                  child: Row(
                    children: [
                      Icon(Icons.edit_calendar_outlined, size: 15, color: c.primary),
                      const SizedBox(width: 4),
                      Text(_weekday(e.key),
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.textMain)),
                      const Spacer(),
                      Text(
                        '${e.value.length} 件 · 合计 ¥${fmtMoney(e.value.fold<double>(0, (s, l) => s + ((l['amount'] as num?)?.toDouble() ?? 0)))}',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.textSub),
                      ),
                      const SizedBox(width: 2),
                      Icon(Icons.chevron_right, size: 16, color: c.textSub),
                    ],
                  ),
                ),
              ),
            ),
            for (final l in e.value) _saleLineTile(c, l),
          ],
        ],
      ),
    );
  }

  /// 出货流水行：三行卡片 —— ①商品名称+备注 ②商品分类+附件（分类在前，有附件才显示图标）③进价·售价·数量单位
  Widget _saleLineTile(TaozhuColors c, Map<String, dynamic> l) {
    final order = l['order'] as Map<String, dynamic>;
    final clientName = '${l['client_name'] ?? ''}';
    final itemName = '${l['item_name'] ?? ''}';
    final qty = '${l['quantity'] ?? ''}';
    final unit = '${l['unit'] ?? ''}';
    final showStore = _clientId == null && clientName.isNotEmpty; // 全部店铺时带店名
    final salePrice = l['sale_price'] as num?;
    final costPrice = l['cost_price'] as num?;
    final qtyNum = (l['qty_num'] as num?)?.toDouble() ?? 0;
    final note = '${l['note'] ?? ''}'.trim();
    final category = '${l['category'] ?? ''}'.trim();
    // 行级附件：明细行独立凭证；无明细（备注占位行）回退整单附件
    final lineId = '${l['item_id'] ?? ''}';
    final attachCount = lineId.isEmpty
        ? (_saleAttachCount['${order['id']}'] ?? 0)
        : (_saleLineAttachCount[lineId] ?? 0);
    // 单行盈亏 = (售价 − 进价快照) × 数量；仅老板可见（店员成本被后端打码为 0 不参与计算）
    double? profit;
    if (!_isStaff && salePrice != null && costPrice != null && qtyNum > 0) {
      profit = (salePrice.toDouble() - costPrice.toDouble()) * qtyNum;
    }
    final bg = profit == null
        ? c.card
        : (profit >= 0 ? Color.lerp(c.card, c.success, 0.08) : Color.lerp(c.card, c.danger, 0.08));
    final border = profit == null
        ? c.primary.withOpacity(0.2)
        : (profit >= 0 ? c.success.withOpacity(0.4) : c.danger.withOpacity(0.4));
    // 背景折线方向：盈利=从左下角到右上角（上升），亏损=从右上角到左下角（下降）；无盈亏=平线
    final trendUp = profit == null ? null : profit >= 0;
    // 第三行：进价 · 售价 · 数量单位（老板看进价；店员无进价数据只显示售价·数量）
    // 无明细坏行（服务端 item_id 空 JOIN 失败）：不显示"售价¥0.00"，给清晰标记且可长按删除
    final isDirtyLine = itemName.trim().isEmpty;
    final priceLine = StringBuffer();
    if (isDirtyLine) {
      priceLine.write('（无明细 · 长按删除该脏行）');
    } else {
      if (!_isStaff && costPrice != null) priceLine.write('进价 ¥${fmtMoney(costPrice.toDouble())} · ');
      priceLine.write('售价 ¥${fmtMoney(salePrice?.toDouble() ?? 0)}');
      if (qty.isNotEmpty) priceLine.write(' · ×$qty$unit');
    }
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      // 点行 = 只编辑当前商品（数量/售价/单位/日期）；长按 = 删除该商品行（不是整单）
      onTap: () => _editSaleLine(l),
      onLongPress: () => _deleteSaleLine(l),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: border),
        ),
        child: Stack(
          children: [
            // 背景装饰折线：方向随盈亏（升=左下→右上，降=右上→左下），放在背景层不占布局空间
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _CardBgLinePainter(color: c.primary, trendUp: trendUp),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: c.primary.withOpacity(0.12),
                    child: Icon(Icons.storefront, size: 14, color: c.primary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ① 商品名称 + 备注（备注在商品名称后边）
                        Text.rich(
                          TextSpan(children: [
                            TextSpan(
                              text: showStore ? '$clientName · $itemName' : itemName,
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.textMain),
                            ),
                            if (note.isNotEmpty)
                              TextSpan(
                                text: '  $note',
                                style: TextStyle(fontSize: 11, color: c.textSub),
                              ),
                          ]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        // ② 商品分类 + 附件（分类在前，附件常驻入口：点开查看/添加该行独立凭证）
                        Row(
                          children: [
                            Icon(Icons.label_outline, size: 12, color: c.textSub),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                category.isEmpty ? '未分类' : category,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, color: c.textSub),
                              ),
                            ),
                            const SizedBox(width: 8),
                            InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onTap: () async {
                                await showAttachmentViewer(
                                  context,
                                  lineId.isEmpty ? 'sale' : 'sale_item',
                                  lineId.isEmpty ? '${order['id']}' : lineId,
                                  lineId.isEmpty ? '出货单附件' : '出货明细行附件',
                                  // 整单凭证入口：批量挂到该单全部明细行（每行一份）
                                  lineIds: lineId.isEmpty
                                      ? [
                                          for (final it
                                              in ((order['items'] as List?) ?? []))
                                            if (it is Map)
                                              '${it['id'] ?? ''}'
                                        ]
                                      : const [],
                                );
                                // 附件增删后立即刷新计数，避免图标残留/缺失（无需手动下拉）
                                _loadAttachCounts();
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Icon(Icons.image_outlined, size: 15,
                                      color: attachCount > 0 ? c.primary : c.textSub.withOpacity(0.5)),
                                  if (attachCount > 0) ...[
                                    const SizedBox(width: 2),
                                    Text('$attachCount',
                                        style: TextStyle(fontSize: 10, color: c.primary)),
                                  ],
                                ]),
                              ),
                            ),
                          ],
                        ),
                        // ③ 进价 · 售价 · 数量单位（允许换行，进价不被截断）
                        Text(priceLine.toString(),
                            style: TextStyle(fontSize: 12, color: c.textSub)),
                      ],
                    ),
                  ),
                  Text('¥${fmtMoney((l['amount'] as num?)?.toDouble() ?? 0)}',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.danger)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _paymentCard(Map<String, dynamic> p) {
    final method = (p['method'] as String? ?? '').trim();
    final note = (p['note'] as String? ?? '').trim();
    final waived = ((p['waived'] as num?) ?? 0) > 0;
    final meta = [
      if (method.isNotEmpty) method,
      if (waived) '平账 ¥${fmtMoney(p['waived'])}',
      if (note.isNotEmpty) note,
    ].join(' · ');
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      elevation: 0,
      color: c.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.success.withOpacity(0.3)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _editPayment(p),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: c.success.withOpacity(0.12),
              child: Icon(Icons.check_circle_outline, size: 16, color: c.success),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_clientNameOf(p),
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.textMain)),
                if (meta.isNotEmpty)
                  Text(meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: c.textSub)),
              ]),
            ),
            Text('¥${fmtMoney(p['amount'])}',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.success)),
            // 附件直接可见：有附件才显示图标+数量，点图标全屏查看全部凭证图片（左右滑动切换）
            if ((_payAttachCount['${p['id']}'] ?? 0) > 0)
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () async {
                  await showAttachmentViewer(context, 'payment', '${p['id']}', '收款凭证');
                  _loadAttachCounts();
                },
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.image_outlined, size: 20, color: c.success),
                    const SizedBox(width: 2),
                    Text('${_payAttachCount['${p['id']}'] ?? 0}',
                        style: TextStyle(fontSize: 11, color: c.success, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            _menu(
              edit: () => _editPayment(p),
              del: () => _deletePayment(p),
            ),
          ]),
        ),
      ),
    );
  }
}

/// 卡片背景装饰折线：方向随盈亏 —— 盈利=从左下角到右上角（上升），亏损=从右上角到左下角（下降），无盈亏=平线
class _CardBgLinePainter extends CustomPainter {
  final Color color;
  final bool? trendUp; // true=上升（左下→右上），false=下降（右上→左下），null=平线
  _CardBgLinePainter({required this.color, this.trendUp});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final h = size.height;
    final w = size.width;
    final paint = Paint()
      ..color = color.withOpacity(0.10)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    if (trendUp == null) {
      // 无盈亏：贴底平线（从左到右）
      path
        ..moveTo(0, h * 0.92)
        ..lineTo(w * 0.3, h * 0.86)
        ..lineTo(w * 0.55, h * 0.9)
        ..lineTo(w * 0.8, h * 0.85)
        ..lineTo(w, h * 0.88);
    } else if (trendUp!) {
      // 上升：从左下角 (0,h) 到右上角 (w,0)
      path
        ..moveTo(0, h)
        ..lineTo(w * 0.25, h * 0.72)
        ..lineTo(w * 0.5, h * 0.62)
        ..lineTo(w * 0.75, h * 0.35)
        ..lineTo(w, 0);
    } else {
      // 下降：从左上角 (0,0) 到右下角 (w,h)
      path
        ..moveTo(0, 0)
        ..lineTo(w * 0.25, h * 0.28)
        ..lineTo(w * 0.5, h * 0.38)
        ..lineTo(w * 0.75, h * 0.65)
        ..lineTo(w, h);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CardBgLinePainter old) =>
      old.color != color || old.trendUp != trendUp;
}