import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../log.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import '../widgets/year_month_picker.dart';
import 'router.dart';
import 'purchase_page.dart';
import 'purchase_line_edit.dart';
import 'attachment_viewer.dart';

/// 进货记录：按日期分组的进货流水（不分店），卡片明细直接展开，可编辑/删除/附件
class PurchaseHistoryPage extends StatefulWidget {
  const PurchaseHistoryPage({super.key});
  @override
  State<PurchaseHistoryPage> createState() => _PurchaseHistoryPageState();
}

class _PurchaseHistoryPageState extends State<PurchaseHistoryPage> {
  List<Map<String, dynamic>> _purchases = [];
  bool _loading = true;
  bool _offline = false;
  /// 商品 id → 分类名（流水行分类显示：优先查询商品设置分类，明细行快照仅兜底）
  Map<String, String> _itemCategory = {};
  /// 所选月份（头部月份切换器，列表联动显示该月进货）
  int _selYear = DateTime.now().year;
  int _selMonth = DateTime.now().month;
  /// 用户是否手动切换过月份（手动后不再自动跳最后记录月份；默认自动=最后一条有记录的月份）
  bool _userPickedMonth = false;
  /// 当月进货总额（仅支出统计：进货页无收入/结余）
  double _monthExpense = 0;
  int _monthCount = 0;
  int _monthItems = 0;
  /// 月份只由顶部月份选择器控制（pickMonth）——滚动不再联动切月（对齐交易页 0.17.317；
  /// 原实现列表滚动时顶部月份跟随日期头并重算统计=滑动变月，用户否决）
  late final ScrollController _listCtrl = ScrollController();
  /// 日期头 GlobalKey：仅月份选择器跳转定位用（_scrollToMonth），不再滚动联动
  final Map<String, GlobalKey> _dateHeaderKeys = {};
  /// 附件计数：明细行（purchase_item）与单据（purchase）各一份；行级查空回退单据
  final Map<String, int> _buyLineAttachCount = {};
  final Map<String, int> _buyAttachCount = {};

  @override
  void initState() {
    super.initState();
    SyncService.version.addListener(_onSync);
    _load();
  }

  @override
  void dispose() {
    SyncService.version.removeListener(_onSync);
    _listCtrl.dispose();
    super.dispose();
  }

  void _onSync() {
    if (mounted) _load();
  }

  String _dateQuery() {
    final from = _fmt(DateTime(_selYear, _selMonth, 1));
    final to = _fmt(DateTime(_selYear, _selMonth + 1, 0));
    return 'date_from=$from&date_to=$to';
  }

  /// 切换月份（±1 月）：列表联动
  void _shiftMonth(int delta) {
    _userPickedMonth = true; // 手动切换后不自动跳最后记录月份
    final y = _selYear;
    final m = _selMonth + delta;
    if (m < 1) {
      _selYear = y - 1;
      _selMonth = 12;
    } else if (m > 12) {
      _selYear = y + 1;
      _selMonth = 1;
    } else {
      _selMonth = m;
    }
    _load();
  }

  /// 月份选择弹层（只选年月，无需选日）——选择后滚动到该月首个日期头，列表不重载
  Future<void> _pickMonth() async {
    final picked = await showYearMonthPicker(
      context,
      year: _selYear,
      month: _selMonth,
    );
    if (picked == null) return;
    _userPickedMonth = true; // 手动切换后不自动跳最后记录月份
    setState(() {
      _selYear = picked.year;
      _selMonth = picked.month;
      _filterByRange(_purchases); // 重算当月统计（列表全量不变）
    });
    _scrollToMonth();
  }

  /// 滚动到所选月份第一个日期头（月份选择器跳转；无该月数据则停留在原位）
  void _scrollToMonth() {
    final prefix = '${_selYear}-${_selMonth.toString().padLeft(2, '0')}';
    final key = _dateHeaderKeys.entries
        .where((e) => e.key.startsWith(prefix))
        .map((e) => e.value)
        .firstOrNull;
    final ctx = key?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 250), alignment: 0);
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    try {
    // ① 本地库秒开（含空态；不再等网络转圈）—— 形式层切换：优先行级 purchase_items store
    final rowPurchases = await LocalDb.getAll('purchase_items');
    final local = rowPurchases.isNotEmpty
        ? _assembleFromRows(rowPurchases)
        : await LocalDb.getAll('purchases');
    // 商品目录分类映射：流水行分类优先查询商品设置分类（改动即时生效），明细快照仅兜底
    final catMap = <String, String>{};
    try {
      for (final x in await LocalDb.getAllByName('items')) {
        catMap['${x['id']}'] = '${x['category'] ?? ''}';
      }
    } catch (_) {}
    // 附件计数：渲染前先把本地引用表计数算好（零网络、首帧图标即有，杜绝"先无后有"闪烁）——
    // 传本次加载的 local（冷启动首次 _purchases 未就绪也能按本次列表统计）；
    // 云端 counts 由渲染后的 withCloud 调用覆盖（Web 上传/其他端新增的附件本地表没同步到）
    if (!kIsWeb) await _loadAttachCounts(purchases: local);
    _jumpToLatestMonth(local); // 默认月份 = 最后一条有记录的月份（用户未手动切月时）
    // Web 端 LocalDb 恒空：跳过空渲染，避免删除/同步通知时列表"空白→填充"跳动；仅本地有数据才先渲染
    if ((!kIsWeb || local.isNotEmpty) && mounted) {
      setState(() {
        _filterByRange(local); // 计算当月统计（总额/天数/件数），返回值忽略
        _purchases = local; // 列表全量展示：跨月滚动，月份联动只跟随显示不重载（避免跳月丢数据）
        _itemCategory = catMap;
        _loading = false;
      });
    }
    // 原生本地化：列表页刷新只读本地，同步只由「我的」页/进应用自动同步驱动。
    if (kIsWeb) {
      // ② Web（无本地库）：直连服务器刷新（静默；失败保留本地展示）——全量拉取（列表跨月滚动）
      try {
        final d = await Api.instance.get('/purchases?limit=1000');
        if (!mounted) return;
        final rows = ((d['purchases'] as List?) ?? []).cast<Map<String, dynamic>>();
        await LocalDb.upsertList('purchases', rows);
        if (!mounted) return;
        _jumpToLatestMonth(rows); // 默认月份 = 最后一条有记录的月份（用户未手动切月时）
        setState(() {
          _filterByRange(rows);
          _purchases = rows;
          _itemCategory = catMap;
          _loading = false;
          _offline = false;
        });
      } catch (_) {
        // 离线：本地缓存已展示，错误已记日志，不再弹提示
        if (!mounted) return;
        setState(() {
          _loading = false;
          _offline = local.isEmpty;
        });
      }
    }
    unawaited(_loadAttachCounts(withCloud: true));
    } catch (e) {
      // 任何加载异常复位 loading，不再转圈
      debugPrint('进货历史加载异常: ${e.toString().split('\n').first}');
    } finally {
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  /// 附件计数（对齐出货账本 ledger_page）：本地副本目录优先（原生，零网络），云端 counts 覆盖。
  /// 进货按明细行 purchase_item；识别原图只挂首个商品行，其他行行级查空回退单据 purchase。
  /// purchases 缺省用当前 State 数据；渲染前调用需传本次加载结果（冷启动首次 State 为空）。
  Future<void> _loadAttachCounts({
    bool withCloud = false,
    List<Map<String, dynamic>>? purchases,
  }) async {
    final src = purchases ?? _purchases;
    final lineIds = <String>[];
    final orderIds = <String>[];
    for (final p in src) {
      final oid = '${p['id'] ?? ''}';
      if (oid.isNotEmpty) orderIds.add(oid);
      for (final it in ((p['items'] as List?) ?? [])) {
        if (it is Map) {
          final lid = '${it['id'] ?? ''}';
          if (lid.isNotEmpty) lineIds.add(lid);
        }
      }
    }
    if (lineIds.isEmpty && orderIds.isEmpty) return;
    if (!kIsWeb) {
      // ① 本地副本（原生）：按本地附件引用表计数（每实体一条引用=一个附件；同图共享一份文件，
      //    文件存公共目录 attachments/{file}，不再按实体目录逐行复制）
      try {
        final refs = await LocalDb.getAll('attachment_refs');
        for (final r in refs) {
          final ent = '${r['entity'] ?? ''}';
          final eid = '${r['entity_id'] ?? ''}';
          if (ent.isEmpty || eid.isEmpty) continue;
          final ids = ent == 'purchase_item' ? lineIds : (ent == 'purchase' ? orderIds : <String>[]);
          if (ids.contains(eid)) {
            if (!mounted) return;
            setState(() {
              final map = ent == 'purchase_item' ? _buyLineAttachCount : _buyAttachCount;
              map[eid] = (map[eid] ?? 0) + 1;
            });
          }
        }
      } catch (_) {}
    }
    // ② 云端批量 counts（Web 直连或显式 withCloud 时精确覆盖；紧凑超时防弱网拖慢图标）
    Future<void> fetchCounts(String entity, List<String> ids, Map<String, int> into) async {
      if (ids.isEmpty || (!withCloud && !kIsWeb)) return;
      try {
        final d = await Api.instance
            .post('/attachments/counts', {'entity': entity, 'ids': ids})
            .timeout(const Duration(seconds: 3));
        final m = (d['counts'] as Map?) ?? {};
        if (!mounted) return;
        setState(() {
          for (final e in m.entries) {
            final n = (e.value as num?)?.toInt() ?? 0;
            if (n > 0) into['${e.key}'] = n;
          }
        });
      } catch (_) {}
    }
    await fetchCounts('purchase_item', lineIds, _buyLineAttachCount);
    await fetchCounts('purchase', orderIds, _buyAttachCount);
  }

  /// 行记录 → 假整单数组（同 purchase_id 归并；行自带头部字段 happened_at/note）
  static List<Map<String, dynamic>> _assembleFromRows(List<Map<String, dynamic>> rows) {
    final byOrder = <String, List<Map<String, dynamic>>>{};
    final meta = <String, Map<String, dynamic>>{};
    for (final r in rows) {
      final oid = '${r['purchase_id'] ?? ''}';
      if (oid.isEmpty) continue;
      (byOrder[oid] ??= []).add(r);
      // 整单日期 = 行最大日期（改行/单日期后按最新日期归组与过滤，与服务器聚合一致）
      final prev = meta[oid];
      final h = '${r['happened_at'] ?? ''}';
      final ph = '${prev?['happened_at'] ?? ''}';
      final note = '${r['note'] ?? ''}';
      final pn = '${prev?['note'] ?? ''}';
      meta[oid] = {
        'id': oid,
        'happened_at': ph.compareTo(h) >= 0 ? ph : h,
        'note': pn.isNotEmpty ? pn : note,
      };
    }
    return byOrder.entries.map((e) {
      // 行序=提交/插入顺序（sort 字段，服务端 PATCH 按数组序写索引）；旧数据无 sort=0 回退 id（时间）序
      final items = e.value..sort((a, b) {
        final sa = (a['sort'] as num?)?.toInt() ?? 0;
        final sb = (b['sort'] as num?)?.toInt() ?? 0;
        if (sa != sb) return sa.compareTo(sb);
        return '${a['id'] ?? ''}'.compareTo('${b['id'] ?? ''}');
      });
      final m = meta[e.key]!;
      final total = items.fold<double>(0, (s, it) => s + ((it['amount'] as num?)?.toDouble() ?? 0));
      return {...m, 'total': total, 'items': items};
    }).toList();
  }

  /// 默认月份 = 最后一条有记录的月份：用户未手动切月时，加载后跳到最新记录所在月份
  /// （当前月无数据时用户看到的不应是空统计，而是最近有记录月份；之后可手动切月）
  void _jumpToLatestMonth(List<Map<String, dynamic>> rows) {
    if (_userPickedMonth) return;
    String? latest;
    for (final p in rows) {
      final od = _date(p['happened_at']);
      final items = ((p['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      for (final it in items) {
        final id = '${it['happened_at'] ?? ''}';
        final d = id.length >= 10 ? id.substring(0, 10) : od;
        if (d.isNotEmpty && (latest == null || d.compareTo(latest) > 0)) latest = d;
      }
      if (items.isEmpty && od.isNotEmpty && (latest == null || od.compareTo(latest) > 0)) latest = od;
    }
    if (latest != null && latest.length >= 7) {
      final ny = int.tryParse(latest.substring(0, 4));
      final nm = int.tryParse(latest.substring(5, 7));
      if (ny != null && nm != null && (ny != _selYear || nm != _selMonth)) {
        _selYear = ny;
        _selMonth = nm;
      }
    }
  }

  /// 当月进货统计（行级口径：金额/天数/件数都按行日期归月度——单改商品日期到当月即计入，不被整单日期遮蔽）
  List<Map<String, dynamic>> _filterByRange(List<Map<String, dynamic>> rows) {
    final from = _fmt(DateTime(_selYear, _selMonth, 1));
    final to = _fmt(DateTime(_selYear, _selMonth + 1, 0));
    final daySet = <String>{};
    double expense = 0;
    var itemCount = 0;
    for (final p in rows) {
      final orderDate = _date(p['happened_at']);
      final items = ((p['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (items.isEmpty) {
        if (orderDate.isNotEmpty && orderDate.compareTo(from) >= 0 && orderDate.compareTo(to) <= 0) {
          daySet.add(orderDate);
          // 每笔先舍入再累加（与单笔显示一致）
          expense += Money.round((p['total'] as num?)?.toDouble() ?? 0);
          itemCount += 1;
        }
        continue;
      }
      for (final it in items) {
        final id = '${it['happened_at'] ?? ''}';
        final d = id.length >= 10 ? id.substring(0, 10) : orderDate;
        if (d.isEmpty || d.compareTo(from) < 0 || d.compareTo(to) > 0) continue;
        daySet.add(d);
        // 每笔先舍入再累加（与单笔显示一致）
        expense += Money.round((it['amount'] as num?)?.toDouble() ?? 0);
        itemCount += 1;
      }
    }
    _monthExpense = expense;
    _monthCount = daySet.length;
    _monthItems = itemCount;
    return rows;
  }

  String _date(Object? v) {
    final s = '$v';
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  Future<void> _editPurchase(Map<String, dynamic> p) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PurchasePage(editId: '${p['id']}')));
    _load();
  }

  /// 点明细行 → 只编辑当前商品（数量/进价/单位/日期，弹窗即时保存）
  Future<void> _editPurchaseLine(Map<String, dynamic> p, Map<String, dynamic> it) async {
    await editPurchaseLine(context, p, it);
    _load();
  }

  /// 日期栏 → 该日进货商品明细行列表（无"进货单"概念：每行一条商品，点行=编辑该商品、长按=删除该商品）
  /// 日期栏 → 直接进入进货记单页批量直编：该日全部商品行平铺（行内直接改数量/进价/备注、
  /// 可批量加附件、可改日期），保存按行走行级 diff；不再经"行列表+单点编辑"界面
  Future<void> _openBatchEdit(String date, List<Map<String, dynamic>> lines) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PurchasePage(initDate: date, dateRows: lines)));
    _load();
  }

  Future<void> _deletePurchase(Map<String, dynamic> p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除记录'),
        content: Text('删除 ${_date(p['happened_at'])} 的这条进货记录？该记录下全部商品一并删除，库存将自动回滚。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (kIsWeb) {
        await Api.instance.delete('/purchases/${p['id']}');
      } else {
        // 原生本地优先：先清附件副本（需镜像 items 定位行级目录）再本地删行 + 队列推送
        await SyncService.cleanupLocalAttachmentsOf('purchase', '${p['id']}');
        await _deletePurchaseRowsOf('${p['id']}', ((p['items'] as List?) ?? []).cast<Map<String, dynamic>>());
        await LocalDb.deleteOne('purchases', '${p['id']}');
        await SyncService.enqueueChange(
            entityType: 'purchase', entitySyncId: '${p['id']}', action: 'delete', payload: {});
        unawaited(SyncService.pushPending());
      }
      toast(context, '已删除，库存已回滚');
      appLog('op', '进货 删除记录：${_date(p['happened_at'])}');
      SyncService.version.notifyListeners();
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 整单删除：行级 store 同步删（进货历史按行级渲染，只删整单镜像则删除后仍显示到全量同步）
  Future<void> _deletePurchaseRowsOf(String orderId, List<Map<String, dynamic>> items) async {
    for (final it in items) {
      final rid = '${it['id'] ?? ''}';
      if (rid.isNotEmpty) await LocalDb.deleteOne('purchase_items', rid);
    }
  }

  /// 删除单条进货商品行（长按商品行触发）：Web 直连 DELETE /purchases/items/:id；
  /// 原生 = 本地镜像删该行 + 整单快照 upsert 入队（服务端整体替换，库存/日期重算）。
  /// 只有无明细（备注占位行）才回退整单删除。
  Future<void> _deletePurchaseLine(Map<String, dynamic> l) async {
    final order = l['order'] as Map<String, dynamic>;
    final rowId = '${l['row_id'] ?? ''}';
    final name = '${l['item_name'] ?? ''}'.isNotEmpty ? '「${l['item_name']}」' : '该商品';
    if (rowId.isEmpty) {
      await _deletePurchase(order);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除商品'),
        content: Text('确定删除进货单中的 $name 这一行吗？仅删除该商品，单内其他商品保留；库存自动回滚。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (kIsWeb) {
        final r = await Api.instance.delete('/purchases/items/$rowId');
        // 服务端已级联：删的是最后一行时该条进货记录整体消失（无空壳）
        if (r is Map && r['order_deleted'] == true) {
          toast(context, '已删除该商品（本条记录已无商品）');
          _load();
          return;
        }
      } else {
        // 原生：本地镜像 items 移除该行
        final items = ((order['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        final updatedItems = items.where((it) => '${it['id']}' != rowId).toList();
        if (updatedItems.isEmpty) {
          // 删的是该条记录最后一商品 → 整条记录删除（不留空壳，与 Web 级联语义一致）
          await SyncService.cleanupLocalAttachmentsOf('purchase_item', rowId);
          await SyncService.cleanupLocalAttachmentsOf('purchase', '${order['id']}');
          await _deletePurchaseRowsOf('${order['id']}', items);
          await LocalDb.deleteOne('purchases', '${order['id']}');
          await SyncService.enqueueChange(
              entityType: 'purchase', entitySyncId: '${order['id']}', action: 'delete', payload: {});
          toast(context, '已删除该商品（本条记录已无商品）');
          _load();
          return;
        }
        // 非末行：该行凭证附件副本一并清（attachments/purchase_item/{rowId}/），再镜像移除该行
        await SyncService.cleanupLocalAttachmentsOf('purchase_item', rowId);
        // 行级 store 同步删（进货历史按行级渲染：只改整单镜像则删除后仍显示到全量同步）
        await LocalDb.deleteOne('purchase_items', rowId);
        final payload = Map<String, dynamic>.from(order)..['items'] = updatedItems;
        payload['total'] = updatedItems.fold<double>(
            0, (s, it) => s + ((it['amount'] as num?)?.toDouble() ?? 0));
        await LocalDb.upsertOne('purchases', payload);
        // 去单据化：删除走行级 purchase_item delete（服务端删行 + 空则级联整条）
        await SyncService.enqueueChange(
            entityType: 'purchase_item', entitySyncId: rowId, action: 'delete', payload: {
          'id': rowId, 'purchase_id': '${order['id']}',
        });
        unawaited(SyncService.pushPending());
      }
      toast(context, '已删除该商品');
      appLog('op', '进货 删除商品行：$name');
      SyncService.version.notifyListeners();
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  String _weekday(String date) {
    final d = DateTime.tryParse(date);
    if (d == null) return date;
    const wd = ['一', '二', '三', '四', '五', '六', '日'];
    return '$date 周${wd[d.weekday - 1]}';
  }

  /// 进货流水行：三行卡片 —— ①商品名称+备注 ②商品分类+行级附件（常驻入口）③数量·进价·金额
  Widget _lineTile(TaozhuColors c, Map<String, dynamic> l) {
    final order = l['order'] as Map<String, dynamic>;
    final itemName = '${l['item_name'] ?? ''}';
    final qty = '${l['quantity'] ?? ''}';
    final unit = '${l['unit'] ?? ''}';
    final note = '${l['note'] ?? ''}'.trim();
    final category = '${l['category'] ?? ''}'.trim();
    final rowId = '${l['row_id'] ?? ''}';
    final pp = (l['purchase_price'] as num?)?.toDouble() ?? 0;
    // 行级附件：明细行独立凭证；行级查空回退该单（识别原图只挂首个商品行，其他行共用同一张图）
    final lineAttach = rowId.isEmpty ? 0 : (_buyLineAttachCount[rowId] ?? 0);
    final attachCount = lineAttach > 0
        ? lineAttach
        : (_buyAttachCount['${order['id']}'] ?? 0);
    final priceLine = StringBuffer();
    if (pp > 0) priceLine.write('进价 ¥${fmtPrice(pp)} · ');
    priceLine.write('数量 ×$qty$unit');
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      // 点行 = 只编辑当前商品（数量/进价/单位/日期）；长按 = 删除该商品行（不是整单）
      onTap: () {
        final line = Map<String, dynamic>.from(l)..['id'] = rowId;
        if (rowId.isEmpty) {
          _editPurchase(order);
        } else {
          _editPurchaseLine(order, line);
        }
      },
      onLongPress: () => _deletePurchaseLine(l),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.success.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: c.success.withOpacity(0.12),
              child: Icon(Icons.shopping_cart, size: 14, color: c.success),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ① 商品名称 + 备注
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: itemName.isEmpty ? '（无明细）' : itemName,
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
                  // ② 商品分类 + 行级附件（常驻入口：点开查看/添加该行独立凭证）
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
                          // 行级有独立附件看行级；行级空回退该单（识别原图挂首个商品行，后端
                          // GET entity=purchase 会叠加该单全部行级附件，此处能看到同一张图）
                          final isLine = lineAttach > 0;
                          await showAttachmentViewer(
                              context,
                              isLine ? 'purchase_item' : 'purchase',
                              isLine ? rowId : '${order['id']}',
                              isLine ? '进货明细行附件' : '进货单附件',
                              // 整单凭证入口：批量挂到该单全部明细行（每行一份）
                              lineIds: isLine
                                  ? const []
                                  : [
                                      for (final it
                                          in ((order['items'] as List?) ?? []))
                                        if (it is Map &&
                                            '${it['id'] ?? ''}'.isNotEmpty)
                                          '${it['id'] ?? ''}'
                                    ],
                            );
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
                  // ③ 进价 · 数量单位（允许换行）
                  Text(priceLine.toString(),
                      style: TextStyle(fontSize: 12, color: c.textSub)),
                ],
              ),
            ),
            Text('¥${fmtMoney((l['amount'] as num?)?.toDouble() ?? 0)}',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.danger)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 14, color: c.textSub),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
    
      // 去掉空 AppBar（统计卡直接顶到安全区下，对齐小程序：不再有统计栏上方的空背景条）
      // 背景层放 Stack 最外层全屏覆盖（含状态栏区域）：顶部那条跟随主题背景而非 Scaffold 固定白/黑
      //（对齐 stats_page 结构——SafeArea 只垫内容，不垫背景）
      body: Stack(
        children: [
          Positioned.fill(child: themePageBackground(context)),
          SafeArea(
            bottom: false,
            child: Column(
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
                    child: Text('无法连接服务器，请检查网络后重试',
                        style: TextStyle(fontSize: 12, color: Color(0xFFB88230))),
                  ),
                ],
              ),
            ),
          // 月份切换器 + 支出统计（选几月显示几月，进货页仅支出无收入/结余）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 月份 + 进货统计同一行（对齐交易页形态：左月份切换，右三列统计）
                Row(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _pickMonth,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // 年月两层：上边年份、下边月份（对齐交易页形态）
                            Text('$_selYear年',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.textSub)),
                            const SizedBox(height: 1),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('$_selMonth月',
                                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: c.primary)),
                                const SizedBox(width: 2),
                                Icon(Icons.expand_more, size: 16, color: c.textSub),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text('点击切换', style: TextStyle(fontSize: 10, color: c.textSub)),
                          ],
                        ),
                      ),
                    ),
                    Container(width: 1, height: 40, color: c.divider),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('¥${fmtMoney(_monthExpense)}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: c.danger)),
                                    const SizedBox(height: 2),
                                    Text('进货金额', style: TextStyle(fontSize: 10, color: c.textSub)),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('$_monthCount',
                                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.textMain)),
                                    const SizedBox(height: 2),
                                    Text('天数', style: TextStyle(fontSize: 10, color: c.textSub)),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('$_monthItems',
                                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.textMain)),
                                    const SizedBox(height: 2),
                                    Text('商品件数', style: TextStyle(fontSize: 10, color: c.textSub)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _buildList(),
          ),
        ],
      ),
      ),
      ],
      ),
    );
  }

  /// 进货流水行（商品明细铺开）：按明细行日期分组，每行一条商品。
  /// 点行编辑该商品；长按=删除整单；行内附件=该条商品独立凭证。
  Widget _buildList() {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    if (_purchases.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.all(48),
              child: Column(
                children: [
                  const Icon(Icons.shopping_cart_outlined, size: 40, color: Color(0xFFD0D5DD)),
                  const SizedBox(height: 12),
                  Text('暂无进货记录', style: TextStyle(color: c.textSub)),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: c.success,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const PurchasePage()))
                        .then((_) => _load()),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('＋ 记一笔进货'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    // 展开为明细行：行日期回退单据日期；无明细的单据显示备注/占位行
    final lines = <Map<String, dynamic>>[];
    for (final p in _purchases) {
      final orderDate = _date(p['happened_at']);
      final orderNote = '${p['note'] ?? ''}'.trim();
      final items = ((p['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (items.isEmpty) {
        lines.add({
          'date': orderDate, 'order': p,
          'item_name': '（无明细）', 'note': orderNote, 'category': '',
          'quantity': '', 'unit': '', 'amount': ((p['total'] as num?)?.toDouble() ?? 0),
          'id': '', 'row_id': '', 'purchase_price': 0,
          'happened_at': '${p['happened_at'] ?? orderDate}',
        });
      }
      for (final it in items) {
        final id = '${it['happened_at'] ?? ''}';
        final itemId = '${it['item_id'] ?? ''}';
        // 分类：优先查询商品设置分类（目录映射，改分类即时生效），明细快照仅兜底
        final dirCat = _itemCategory[itemId] ?? '';
        final catInline = '${it['item_category'] ?? ''}'.trim();
        // 备注：行级 note 优先，空则回退单据 note（仅首行显示，避免每行重复）
        final lineNote = '${it['note'] ?? ''}'.trim();
        lines.add({
          'date': id.length >= 10 ? id.substring(0, 10) : orderDate,
          'order': p,
          'item_name': '${it['item_name'] ?? ''}',
          'item_id': itemId,  // 真实商品 id（改分类等商品级操作用）
          'note': lineNote.isNotEmpty ? lineNote : (it == items.first ? orderNote : ''),
          'category': dirCat.isNotEmpty ? dirCat : catInline,
          'quantity': '${it['quantity'] ?? ''}',
          'unit': '${it['unit'] ?? ''}',
          'amount': ((it['amount'] as num?)?.toDouble() ?? 0),
          'id': '${it['id'] ?? ''}',       // 明细行 id（行级附件/编辑用）
          'row_id': '${it['id'] ?? ''}',   // 同 id，行级附件回退判断用
          'purchase_price': (it['purchase_price'] as num?)?.toDouble() ?? 0,
          'happened_at': '${it['happened_at'] ?? p['happened_at'] ?? orderDate}',
        });
      }
    }
    // 按行日期分组（按日期降序：最新日期在最上方，向下滚动看更早）
    final sortedLines = lines.toList()
      ..sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final l in sortedLines) {
      (grouped['${l['date']}'] ??= []).add(l);
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _syncMonthWithScroll,
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
        controller: _listCtrl,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [
          for (final e in grouped.entries) ...[
            // 日期栏 = 该日进货商品明细行列表（点击=进入批量修改/批量附件；列表滑动月份联动）
            KeyedSubtree(
              key: _dateHeaderKeys.putIfAbsent('${e.key}', GlobalKey.new),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _openBatchEdit(e.key, e.value),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 14, 4, 2),
                  child: Row(
                    children: [
                      Icon(Icons.edit_calendar_outlined, size: 15, color: c.primary),
                      const SizedBox(width: 4),
                      Text(_weekday(e.key),
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: c.textMain)),
                      const Spacer(),
                      Text(
                        // 合计按"每笔舍入后累加"（与单笔显示一致）：digits=0/1 时原始浮点累加再舍入会与每笔金额对不上
                        '${e.value.length} 条 · 合计 ¥${fmtMoney(e.value.fold<double>(0, (s, l) => s + Money.round((l['amount'] as num?)?.toDouble() ?? 0)))}',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: c.textSub),
                      ),
                      const SizedBox(width: 2),
                      Icon(Icons.chevron_right, size: 16, color: c.textSub),
                    ],
                  ),
                ),
              ),
            ),
            for (final l in e.value) _lineTile(c, l),
          ],
        ],
      ),
    ),
    );
  }

  /// 进货列表与顶部统计联动：滚动时按视口内最顶部日期头切统计月份（对齐出货 ledger 联动）
  bool _syncMonthWithScroll(ScrollNotification n) {
    if (n is ScrollStartNotification || n is ScrollUpdateNotification || n is ScrollEndNotification) {
      double? bestTop;
      String? bestDate;
      for (final e in _dateHeaderKeys.entries) {
        final ctx = e.value.currentContext;
        if (ctx == null) continue;
        final box = ctx.findRenderObject();
        if (box is! RenderBox) continue;
        final top = box.localToGlobal(Offset.zero).dy;
        if (top > -40 && top < 120 && (bestTop == null || top < bestTop)) {
          bestTop = top;
          bestDate = e.key;
        }
      }
      if (bestDate == null || bestDate.length < 7) return false;
      final y = int.tryParse(bestDate.substring(0, 4));
      final m = int.tryParse(bestDate.substring(5, 7));
      if (y == null || m == null) return false;
      if (y != _selYear || m != _selMonth) {
        _selYear = y;
        _selMonth = m;
        _filterByRange(_purchases); // 重算当月统计（列表全量不变）
      }
    }
    return false;
  }
}
