import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import '../widgets/center_sheet.dart';
import '../widgets/number_pad_field.dart';
import 'router.dart';

/// 库存：按 商品+单位 查看/预警/调整（进货自动入库、出货自动扣减，见单据页）
class StocksPage extends StatefulWidget {
  const StocksPage({super.key});
  @override
  State<StocksPage> createState() => _StocksPageState();
}

class _StocksPageState extends State<StocksPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  List<Map<String, dynamic>> _stocks = [];
  bool _canSeeCost = true; // 店员不可见成本核算（后端 cost_price 打码）
  bool _loading = true;
  bool _belowOnly = false; // 只看预警（低于阈值）
  /// 临期映射（key: item_id\u0000unit → 最早到期日；来自 /stocks/alerts）
  Map<String, String> _expiryMap = {};
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    // 本地优先：页面加载只读本地库镜像（零网络）；同步完成后（version 通知）再刷新。
    // 库存以服务端为准（盘点/多端变动），但本地有 fullSync 写入的 stocks 镜像，先秒开再静默校准。
    // 每次进入主动校准一次（不等 version 通知）——否则本地镜像陈旧=用户"每次点进去没数据/旧数据"。
    // 校准拉 /stocks 写本地镜像，页面即刻显示最新库存（此请求轻量，库存行数=商品×单位）
    SyncService.version.addListener(_onSync);
    _load();
    _load(network: true);
  }

  @override
  void dispose() {
    SyncService.version.removeListener(_onSync);
    _searchTimer?.cancel();
    super.dispose();
  }

  void _onSync() {
    if (mounted) _load(network: true);
  }

  Future<void> _load({bool network = false, String q = '', bool below = false}) async {
    // 原生：库存=本地计算（Σ进货−Σ出货，用户"库存应该是计算出来的不是写入数据库"——
    // 服务端 stocks 表写库残留=没进货却显示正数根因）；min_stock 阈值配置保留
    if (!kIsWeb) {
      try {
        var local = await _computedStocks();
        if (q.isNotEmpty) {
          local = local.where((s) => '${s['item_name'] ?? ''}'.contains(q)).toList();
        }
        if (below) {
          local = local.where(_isLow).toList();
        }
        local.sort((a, b) => '${a['item_name'] ?? ''}'.compareTo('${b['item_name'] ?? ''}'));
        if (mounted) {
          setState(() {
            _stocks = _mergeByItem(local);
            _loading = false;
          });
        }
        if (!network) return; // 页面加载不加网络；同步完成（version 通知）传 network:true 才校准
      } catch (_) {
        setState(() => _loading = false);
      }
    }
    // ① 缓存兜底秒开（Web/原生无本地镜像时先展示上次数据，不再无限转圈）
    if (!below && q.isEmpty) {
      final cached = await Api.instance.getCachedRaw('/stocks');
      if (cached != null && mounted) {
        _canSeeCost = cached['can_see_cost'] != false;
        setState(() {
          _stocks = _mergeByItem(((cached['stocks'] as List?) ?? []).cast<Map<String, dynamic>>());
          _loading = false;
        });
      }
    }
    // ② 网络刷新 + 写缓存：仅同步完成/下拉/Web 直连时执行，页面加载不发请求（本地优先）
    if (!network && !kIsWeb) return;
    try {
      final params = <String>[];
      if (q.isNotEmpty) params.add('q=${Uri.encodeQueryComponent(q)}');
      if (below) params.add('below=1');
      final query = params.isEmpty ? '' : '?${params.join('&')}';
      final d = await Api.instance.get('/stocks$query');
      if (!below && q.isEmpty) await Api.instance.setCache('/stocks', d);
      // 临期映射（批次到期 ≤7 天；同商品+单位取最早到期日）
      try {
        final a = await Api.instance.get('/stocks/alerts?days=7');
        final expMap = <String, String>{};
        for (final e in ((a['expiring'] as List?) ?? []).cast<Map<String, dynamic>>()) {
          expMap['${e['item_id']}\u0000${e['unit']}'] = '${e['expiry_date'] ?? ''}';
        }
        _expiryMap = expMap;
      } catch (_) {}
      // 网络结果同时回写本地镜像（下次离线秒开）
      if (!kIsWeb) {
        try {
          await LocalDb.putAll('stocks', ((d['stocks'] as List?) ?? []).cast<Map<String, dynamic>>());
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _stocks = _mergeByItem(((d['stocks'] as List?) ?? []).cast<Map<String, dynamic>>());
        _canSeeCost = d['can_see_cost'] != false;
        _loading = false;
      });
    } catch (_) {
      // 离线：本地镜像/缓存已展示，错误已记日志，不再弹提示
      setState(() => _loading = false);
    }
  }

  /// 库存本地计算（用户"库存应该是计算出来的不是写入数据库"）：Σ进货 − Σ出货 − Σ损耗 ± Σ盘点调整（按商品×单位），
  /// 不依赖服务端 stocks 表数量；min_stock 阈值配置保留（stocks 表里用户设的）。
  /// 聚合口径对齐服务端 /stocks：单位用商品计数单位 count_unit（若有，否则原单位），
  /// 数量用折合 count_qty（>0 时，否则原数量）——交易页折合由商品管理 per 统一后两端一致。
  Future<List<Map<String, dynamic>>> _computedStocks() async {
    final buys = await LocalDb.getAll('purchase_items');
    final sells = await LocalDb.getAll('sale_items');
    final losses = await LocalDb.getAll('loss_records');
    final adjustments = await LocalDb.getAll('stock_adjustments');
    final cfg = <String, Map<String, dynamic>>{};
    try {
      for (final s in await LocalDb.getAll('stocks')) {
        cfg['${s['item_id']}|${s['unit']}'] = s;
      }
    } catch (_) {}
    final items = await LocalDb.getAllByName('items');
    final cuOf = {for (final i in items) '${i['id']}': '${i['count_unit'] ?? ''}'};
    final agg = <String, double>{};
    final rawUnitOf = <String, String>{}; // 聚合 key → 原单位（阈值配置按原单位行存，找不到计数单位行时回退）
    void add(List<Map<String, dynamic>> rows, double sign) {
      for (final r in rows) {
        final itemId = '${r['item_id'] ?? ''}';
        final rawUnit = '${r['unit'] ?? ''}';
        if (itemId.isEmpty || rawUnit.isEmpty) continue;
        final cu = cuOf[itemId] ?? '';
        final unit = cu.isNotEmpty ? cu : rawUnit;
        final qty = (r['quantity'] as num?)?.toDouble() ?? 0;
        final cq = (r['count_qty'] as num?)?.toDouble() ?? 0;
        final eff = cq > 0 ? cq : qty;
        final key = '$itemId|$unit';
        agg[key] = (agg[key] ?? 0) + sign * eff;
        rawUnitOf[key] = rawUnit;
      }
    }
    add(buys, 1);
    add(sells, -1);
    add(losses, -1);
    add(adjustments, 1); // 盘点调整 qty 带符号：盘盈(+) / 盘亏(−) 直接累加
    final nameOf = {for (final i in items) '${i['id']}': '${i['name'] ?? ''}'};
    final out = <Map<String, dynamic>>[];
    for (final e in agg.entries) {
      final itemId = e.key.split('|').first;
      final c = cfg[e.key] ?? cfg['$itemId|${rawUnitOf[e.key] ?? ''}'];
      out.add({
        'item_id': itemId,
        'unit': e.key.split('|').last,
        'item_name': nameOf[itemId] ?? '',
        'quantity': e.value,
        'min_stock': (c?['min_stock'] as num?)?.toDouble() ?? 0,
      });
    }
    return out;
  }

  /// 低库存统一判定（用户"剩余0阈值0有些红有些绿"不一致）：剩余 ≤ 阈值 → 预警红
  static bool _isLow(Map<String, dynamic> s) {
    final q = (s['quantity'] as num?)?.toDouble() ?? 0;
    final m = (s['min_stock'] as num?)?.toDouble() ?? 0;
    return q <= m;
  }

  Future<void> _refresh() async {
    if (kIsWeb) {
      await _load(network: true, q: '', below: _belowOnly);
    } else {
      // 原生下拉刷新：优先本地镜像，再静默网络校准（同步动作仍走同步状态页，此处仅展示刷新）
      await _load(network: true, q: '', below: _belowOnly);
    }
  }

  /// 盘点阈值默认值：已有手设阈值（>0）保留；未设置且库存≥1 时自动带出建议值
  /// （后端 suggest_min = 近 30 天平均每笔出货量 × 40%，无出货记录为 0）；既不设也无建议 → 0
  static String _defaultMin(Map<String, dynamic>? cur) {
    final hand = (cur?['min_stock'] as num?)?.toDouble() ?? 0;
    if (hand > 0) return hand.toString();
    final suggest = (cur?['suggest_min'] as num?)?.toDouble() ?? 0;
    if (suggest > 0) return suggest.toString();
    return '0';
  }

  /// 单行编辑：仅预警阈值（库存=本地计算 Σ进货−Σ出货，不再手动填写数量）
  Future<void> _edit(Map<String, dynamic> s) async {
    final minCtrl = TextEditingController(text: '${s['min_stock']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${s['item_name']}（${s['unit']}）'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text('当前库存：${fmtQty(s['quantity'] as num?)} ${s['unit']}（按进货−出货自动计算）',
                  style: const TextStyle(fontSize: 13)),
            ),
            const SizedBox(height: 8),
            NumberPadField(
              controller: minCtrl,
              label: '低库存预警阈值',
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final min = double.tryParse(minCtrl.text.trim());
    if (min == null || min < 0) {
      toast(context, '阈值须为非负数字');
      return;
    }
    try {
      if ('${s['id']}'.isNotEmpty) {
        await Api.instance.patch('/stocks/${s['id']}', {'min_stock': min});
      } else {
        // 未配置过阈值的商品（计算型列表无 stocks 行）→ 批量端点按商品+单位创建阈值
        await Api.instance.put('/stocks', {
          'rows': [
            {'item_id': s['item_id'], 'unit': s['unit'], 'min_stock': min},
          ],
        });
      }
      toast(context, '已保存');
      SyncService.notifyStockChanged(); // 我的页低库存红字实时刷新
      _refresh();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 报损（损耗）：老板操作、需在线——从 FIFO 最早进货批次扣减，单独记损耗流水（不计入出货毛利）。
  /// 单位下拉取该商品全部单位（主卡 + 折叠行），默认主单位（出货单位）。
  Future<void> _reportLoss(Map<String, dynamic> s) async {
    final units = <String>{'${s['unit'] ?? ''}'};
    for (final o in ((s['_others'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      final u = '${o['unit'] ?? ''}';
      if (u.isNotEmpty) units.add(u);
    }
    final unitList = units.where((u) => u.isNotEmpty).toList();
    if (unitList.isEmpty) {
      toast(context, '缺少单位信息，无法报损');
      return;
    }
    if (!kIsWeb && Api.isOffline) {
      toast(context, '报损需联网（当前离线，联网后再报损）');
      return;
    }
    final qtyCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    var selUnit = unitList.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text('报损：${s['item_name']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text('当前库存：${fmtQty(s['quantity'] as num?)} ${s['unit']}'
                    '（从最早进货批次扣减，损耗不计入毛利）',
                    style: const TextStyle(fontSize: 13)),
              ),
              if (unitList.length > 1) ...[
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: selUnit,
                  decoration: const InputDecoration(labelText: '单位', isDense: true),
                  items: [for (final u in unitList) DropdownMenuItem(value: u, child: Text(u))],
                  onChanged: (v) => setDlg(() => selUnit = v ?? selUnit),
                ),
              ],
              const SizedBox(height: 10),
              NumberPadField(controller: qtyCtrl, label: '损耗数量'),
              const SizedBox(height: 10),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(labelText: '备注（可选，如：菜叶损坏）', isDense: true),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认报损')),
          ],
        ),
      ),
    );
    final qty = double.tryParse(qtyCtrl.text.trim()) ?? 0;
    final note = noteCtrl.text.trim();
    qtyCtrl.dispose();
    noteCtrl.dispose();
    if (ok != true || !mounted) return;
    if (qty <= 0) {
      toast(context, '损耗数量须大于 0');
      return;
    }
    try {
      await Api.instance.post('/stocks/loss', {
        'item_id': s['item_id'],
        'unit': selUnit,
        'qty': qty,
        'note': note,
      });
      toast(context, '已报损 ${fmtQty(qty)}$selUnit');
      SyncService.notifyStockChanged(); // 我的页低库存红字实时刷新
      _refresh();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 损耗记录：GET /stocks/loss 列表 + 区间汇总（金额/单价仅老板可见，店员打码对齐成本）
  Future<void> _lossList() async {
    try {
      final d = await Api.instance.get('/stocks/loss');
      final rows = ((d['rows'] as List?) ?? []).cast<Map<String, dynamic>>();
      final costVisible = rows.isEmpty || rows.first['cost_visible'] != false;
      final totalQty = (d['total_qty'] as num?)?.toDouble() ?? 0;
      final totalAmount = (d['total_amount'] as num?)?.toDouble() ?? 0;
      if (!mounted) return;
      await showCenterSheet<void>(
        context: context,
        maxHeightFactor: 0.85,
        builder: (ctx) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('损耗记录', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                  Text('共 ${rows.length} 笔 · 合计 ${fmtQty(totalQty)}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            if (costVisible)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text('损耗金额合计 ¥${fmtMoney(totalAmount)}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            if (rows.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('暂无损耗记录（库存页行内可点「报损」）', style: TextStyle(fontSize: 13))),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${r['item_name']}（${r['unit']}）',
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                Text('${r['happened_at'] ?? ''}${'${r['note'] ?? ''}'.isNotEmpty ? ' · ${r['note']}' : ''}',
                                    maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
                              ],
                            ),
                          ),
                          Text(
                            '−${fmtQty(r['qty'] as num?)}'
                            '${costVisible ? ' · ¥${fmtMoney((r['amount'] as num?)?.toDouble() ?? 0)}' : ''}',
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFFDC2626)),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  bool _counting = false; // 盘点提交防连点（一次只允许一单）

  /// 盘点弹层：列出所有商品价格单位，填「实际数量」——与账面差异=盘盈(+)/盘亏(−)，
  /// 提交后服务端按 FIFO 批次调整库存并记调整流水（可追溯）；可顺手同步设预警阈值。
  /// 需在线（调整走服务端批次账）；防连点。
  Future<void> _count() async {
    if (_counting) return;
    if (!kIsWeb && Api.isOffline) {
      toast(context, '盘点需联网（当前离线，联网后再盘点）');
      return;
    }
    try {
      final items = await Api.instance.get('/items');
      final stocks = await Api.instance.get('/stocks');
      final itemRows = ((items['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      final stockMap = <String, Map<String, dynamic>>{};
      for (final s in ((stocks['stocks'] as List?) ?? []).cast<Map<String, dynamic>>()) {
        stockMap['${s['item_id']}/${s['unit']}'] = s;
      }
      // 展开 商品×单位
      final rows = <Map<String, dynamic>>[];
      for (final it in itemRows) {
        for (final p in ((it['prices'] as List?) ?? []).cast<Map<String, dynamic>>()) {
          final key = '${it['id']}/${p['unit']}';
          final cur = stockMap[key];
          rows.add({
            'item_id': it['id'],
            'item_name': it['name'],
            'unit': p['unit'],
            'quantity': (cur?['quantity'] as num?)?.toDouble() ?? 0,
            'min_stock': (cur?['min_stock'] as num?)?.toDouble() ?? 0,
            // 阈值：已有手设值保留；未设置（0）且库存≥1 时自动带出建议值（近30天平均出货×40%）
            'min_default': _defaultMin(cur),
          });
        }
      }
      if (rows.isEmpty) {
        toast(context, '暂无商品，请先添加商品与价格');
        return;
      }
      // 实际数量输入（空=不盘点该行）+ 阈值输入（预填现有/建议值）
      final qtyCtrls = rows.map((_) => TextEditingController()).toList();
      final minCtrls = rows.map((r) => TextEditingController(text: '${r['min_default']}')).toList();
      final saved = await showCenterSheet<bool>(
        context: context,
        maxHeightFactor: 0.9,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDlg) {
            // 汇总预览：盘盈/盘亏项数
            var surplus = 0, shortage = 0;
            for (var i = 0; i < rows.length; i++) {
              final v = double.tryParse(qtyCtrls[i].text.trim());
              if (v == null) continue;
              final book = rows[i]['quantity'] as double;
              if (v > book + 0.001) surplus++;
              else if (v < book - 0.001) shortage++;
            }
            return Column(
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('库存盘点', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                ),
                Text(
                  '填实际数量，差异自动调整（盘盈+/盘亏−）；阈值列可顺手修改',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final book = rows[i]['quantity'] as double;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('${rows[i]['item_name']}（${rows[i]['unit']}）',
                                      style: const TextStyle(fontSize: 13)),
                                  ValueListenableBuilder<TextEditingValue>(
                                    valueListenable: qtyCtrls[i],
                                    builder: (_, v, __) {
                                      final x = double.tryParse(v.text.trim());
                                      if (x == null) {
                                        return Text('账面 ${fmtQty(book)}',
                                            style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline));
                                      }
                                      final diff = x - book;
                                      final color = diff > 0.001 ? const Color(0xFF16A34A) : (diff < -0.001 ? const Color(0xFFDC2626) : Theme.of(context).colorScheme.outline);
                                      return Text(
                                        '账面 ${fmtQty(book)}${(diff).abs() > 0.001 ? ' · 差异 ${diff > 0 ? '+' : ''}${fmtQty(diff)}' : '（一致）'}',
                                        style: TextStyle(fontSize: 11, color: color),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 74,
                              child: NumberPadField(
                                controller: qtyCtrls[i],
                                label: '实际数',
                                decoration: const InputDecoration(labelText: '实际', isDense: true),
                              ),
                            ),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 74,
                              child: NumberPadField(
                                controller: minCtrls[i],
                                label: '阈值',
                                decoration: const InputDecoration(labelText: '阈值', isDense: true),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          surplus + shortage > 0
                              ? '${surplus > 0 ? '盘盈 $surplus 项 ' : ''}${shortage > 0 ? '盘亏 $shortage 项' : ''}'
                              : '无差异（可仅调阈值）',
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(minimumSize: const Size(150, 46)),
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('保存盘点'),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      );
      if (saved != true) {
        for (final c in qtyCtrls) { c.dispose(); }
        for (final c in minCtrls) { c.dispose(); }
        return;
      }
      // 收集：差异≠0 的实际数 → 盘点调整；阈值变化 → 阈值批量
      final adjustRows = <Map<String, dynamic>>[];
      final thresholdRows = <Map<String, dynamic>>[];
      for (var i = 0; i < rows.length; i++) {
        final v = double.tryParse(qtyCtrls[i].text.trim());
        final book = rows[i]['quantity'] as double;
        if (v != null && v >= 0 && (v - book).abs() > 0.001) {
          adjustRows.add({'item_id': rows[i]['item_id'], 'unit': rows[i]['unit'], 'actual_qty': v});
        }
        final min = double.tryParse(minCtrls[i].text.trim());
        if (min != null && min >= 0 && (min - (rows[i]['min_stock'] as double)).abs() > 0.001) {
          thresholdRows.add({'item_id': rows[i]['item_id'], 'unit': rows[i]['unit'], 'min_stock': min});
        }
      }
      for (final c in qtyCtrls) { c.dispose(); }
      for (final c in minCtrls) { c.dispose(); }
      if (adjustRows.isEmpty && thresholdRows.isEmpty) {
        toast(context, '没有变化，无需保存');
        return;
      }
      setState(() => _counting = true);
      try {
        String? adjMsg;
        if (adjustRows.isNotEmpty) {
          final r = await Api.instance.post('/stocks/adjust', {
            'id': 'c${DateTime.now().millisecondsSinceEpoch}${_countingNonce()}',
            'rows': adjustRows,
            'happened_at': DateTime.now().toIso8601String().substring(0, 10),
          });
          final surplus = (r['surplus'] as num?)?.toDouble() ?? 0;
          final shortage = (r['shortage'] as num?)?.toDouble() ?? 0;
          adjMsg = '调整 ${r['adjusted'] ?? adjustRows.length} 项'
              '${surplus > 0 ? '，盘盈 ${fmtQty(surplus)}' : ''}'
              '${shortage > 0 ? '，盘亏 ${fmtQty(shortage)}' : ''}';
        }
        if (thresholdRows.isNotEmpty) {
          await Api.instance.put('/stocks', {'rows': thresholdRows});
        }
        toast(context, '已保存${adjMsg != null ? '：$adjMsg' : ''}（阈值 ${thresholdRows.length} 项）');
        SyncService.notifyStockChanged(); // 我的页低库存红字实时刷新
        _refresh();
      } catch (e) {
        toast(context, e.toString().replaceFirst('Exception: ', ''));
      } finally {
        setState(() => _counting = false);
      }
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  int _countingNonce() => (DateTime.now().microsecondsSinceEpoch % 900000) + 100000;

  /// 盘点调整记录：GET /stocks/adjustments 列表 + 盘盈/盘亏汇总（金额/单价仅老板可见）
  Future<void> _adjustmentsList() async {
    try {
      final d = await Api.instance.get('/stocks/adjustments');
      final rows = ((d['rows'] as List?) ?? []).cast<Map<String, dynamic>>();
      final costVisible = rows.isEmpty || rows.first['cost_visible'] != false;
      final surplusQty = (d['surplus_qty'] as num?)?.toDouble() ?? 0;
      final shortageQty = (d['shortage_qty'] as num?)?.toDouble() ?? 0;
      final surplusAmount = (d['surplus_amount'] as num?)?.toDouble() ?? 0;
      final shortageAmount = (d['shortage_amount'] as num?)?.toDouble() ?? 0;
      if (!mounted) return;
      await showCenterSheet<void>(
        context: context,
        maxHeightFactor: 0.85,
        builder: (ctx) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('盘点调整记录', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                  Text('共 ${rows.length} 笔', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                '盘盈 ${fmtQty(surplusQty)}${costVisible && surplusAmount > 0 ? '（¥${fmtMoney(surplusAmount)}）' : ''}'
                ' · 盘亏 ${fmtQty(shortageQty)}${costVisible && shortageAmount > 0 ? '（¥${fmtMoney(shortageAmount)}）' : ''}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            if (rows.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('暂无盘点调整（库存页右上角「盘点」按实际数量校对）', style: TextStyle(fontSize: 13))),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final qty = (r['qty'] as num?)?.toDouble() ?? 0;
                    final isSurplus = qty > 0;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${r['item_name']}（${r['unit']}）',
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                Text('${r['happened_at'] ?? ''}${'${r['note'] ?? ''}'.isNotEmpty ? ' · ${r['note']}' : ''}',
                                    maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
                              ],
                            ),
                          ),
                          Text(
                            '${isSurplus ? '+' : '−'}${fmtQty(qty.abs())}'
                            '${costVisible && ((r['amount'] as num?)?.toDouble() ?? 0) != 0 ? ' · ¥${fmtMoney((r['amount'] as num?)?.toDouble() ?? 0)}' : ''}',
                            style: TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w700,
                              color: isSurplus ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

    /// 数量显示：整数不显示小数（后端已舍入两位），小数最多两位去尾 0（防 1.7000000000000002 斤）
  static String fmtQty(num? v) {
    final n = (v ?? 0).toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  /// 按商品合并展示：同商品多单位行收敛到一张卡片，主数量用"出货单位"行
  /// （unit == 商品计数单位 count_unit；未配计数单位则取该商品第一行），
  /// 其余单位行折叠为副文本，既不重复也不丢数据。
  static List<Map<String, dynamic>> _mergeByItem(List<Map<String, dynamic>> rows) {
    final byItem = <String, List<Map<String, dynamic>>>{};
    for (final s in rows) {
      byItem.putIfAbsent('${s['item_id'] ?? ''}', () => []).add(s);
    }
    final out = <Map<String, dynamic>>[];
    for (final list in byItem.values) {
      if (list.isEmpty) continue;
      String mainUnit = '';
      for (final s in list) {
        final cu = '${s['count_unit'] ?? ''}';
        if (cu.isNotEmpty && '${s['unit']}' == cu) { mainUnit = '${s['unit']}'; break; }
      }
      var main = mainUnit.isEmpty
          ? list.first
          : list.firstWhere((s) => '${s['unit']}' == mainUnit, orElse: () => list.first);
      final others = list.where((s) => s != main).toList();
      if (others.isNotEmpty) {
        main = Map<String, dynamic>.from(main);
        main['_others'] = others;
      }
      out.add(main);
    }
    out.sort((a, b) => '${a['item_name'] ?? ''}'.compareTo('${b['item_name'] ?? ''}'));
    return out;
  }

  /// 点商品卡：查看该商品进货/出货明细（数量来源追溯）+ 调整库存在弹层内。
  /// **本地获取**（用户"点击后显示特别慢应该通过本地获取"）：按 item_id 本地聚合进货/出货行；
  /// 出货行补店铺名（用户"出货记录应该添加出货店铺"）
  Future<void> _viewTrace(Map<String, dynamic> s) async {
    var rows = <Map<String, dynamic>>[];
    try {
      final buys = await LocalDb.getAll('purchase_items');
      final sells = await LocalDb.getAll('sale_items');
      final clients = await LocalDb.getAllByName('clients');
      final cName = {for (final c in clients) '${c['id']}': '${c['name'] ?? ''}'};
      for (final b in buys) {
        if ('${b['item_id'] ?? ''}' != '${s['item_id']}') continue;
        rows.add({
          'kind': 'in', 'happened_at': '${b['happened_at'] ?? ''}', 'unit': '${b['unit'] ?? ''}',
          'quantity': b['quantity'], 'count_qty': b['count_qty'], 'client': '',
        });
      }
      for (final x in sells) {
        if ('${x['item_id'] ?? ''}' != '${s['item_id']}') continue;
        rows.add({
          'kind': 'out', 'happened_at': '${x['happened_at'] ?? ''}', 'unit': '${x['unit'] ?? ''}',
          'quantity': x['quantity'], 'count_qty': x['count_qty'],
          'client': cName['${x['client_id'] ?? ''}'] ?? '',
        });
      }
      rows.sort((a, b) => '${a['happened_at']}'.compareTo('${b['happened_at']}'));
    } catch (_) {
      rows = [];
    }
    if (!mounted) return;
    await showCenterSheet<bool>(
      context: context,
      maxHeightFactor: 0.85,
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text('${s['item_name']} · 进货/出货来源',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: () { Navigator.pop(ctx); _edit(s); },
                  child: const Text('调整库存', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('暂无进货/出货记录（数量可能来自盘点初始化）', style: TextStyle(fontSize: 13))),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: rows.length,
                itemBuilder: (_, i) {
                  final r = rows[i];
                  final isIn = '${r['kind']}' == 'in';
                  final qty = (r['quantity'] as num?)?.toDouble() ?? 0;
                  final cq = (r['count_qty'] as num?)?.toDouble() ?? 0;
                  final eff = (r['eff_qty'] as num?)?.toDouble() ?? qty;
                  final conv = (cq > 0 && cq != qty && qty > 0);
                  final convertUnit = '${s['count_unit'] ?? ''}'.isNotEmpty ? '${s['count_unit']}' : '${r['unit']}';
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Row(
                      children: [
                        Container(
                          width: 46,
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: (isIn ? const Color(0xFF22C55E) : const Color(0xFFEF4444)).withOpacity(0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            isIn ? '进货' : '出货',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                                color: isIn ? const Color(0xFF16A34A) : const Color(0xFFDC2626)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${r['happened_at'] ?? ''}',
                                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
                              if (!isIn && '${r['client'] ?? ''}'.isNotEmpty)
                                Text('店铺：${r['client']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                              if ('${r['note'] ?? ''}'.isNotEmpty)
                                Text('${r['note']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12)),
                            ],
                          ),
                        ),
                        Text(
                          '${isIn ? '+' : '−'}${fmtQty(qty)}${r['unit']}'
                          '${conv ? '（折 ${fmtQty(eff)}$convertUnit）' : ''}',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: isIn ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: appBarBackground(context), // 顶部露出主题背景（无标题文字）
        actions: [
          IconButton(tooltip: '盘点', icon: const Icon(Icons.edit_note_outlined), onPressed: _count),
          IconButton(
            tooltip: '损耗记录',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: _lossList,
          ),
          IconButton(
            tooltip: '盘点调整',
            icon: const Icon(Icons.balance_outlined),
            onPressed: _adjustmentsList,
          ),
          IconButton(
            tooltip: '只看预警',
            icon: Icon(Icons.notification_important_outlined,
                color: _belowOnly ? _c.danger : null),
            onPressed: () => setState(() {
              _belowOnly = !_belowOnly;
              _refresh();
            }),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: themePageBackground(context)),
          Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: '搜索商品',
                isDense: true,
              ),
              onChanged: (v) {
                _searchTimer?.cancel();
                _searchTimer = Timer(const Duration(milliseconds: 350), () {
                  _load(q: v.trim(), below: _belowOnly);
                });
              },
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_stocks.isNotEmpty && _canSeeCost)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                Text('库存金额合计（按剩余批次成本）',
                                    style: TextStyle(fontSize: 12, color: _c.textSub)),
                                const Spacer(),
                                Text(
                                  '¥${fmtMoney(_stocks.fold<double>(0, (sum, x) {
                                    var v = (((x['quantity'] as num?)?.toDouble() ?? 0) * ((x['cost_price'] as num?)?.toDouble() ?? 0));
                                    for (final o in ((x['_others'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
                                      v += ((o['quantity'] as num?)?.toDouble() ?? 0) * ((o['cost_price'] as num?)?.toDouble() ?? 0);
                                    }
                                    return sum + v;
                                  }))}',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _c.success),
                                ),
                              ],
                            ),
                          ),
                        if (_stocks.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Center(child: Text('暂无库存记录\n进货后自动入库，可点右上角盘点初始化', textAlign: TextAlign.center, style: TextStyle(color: _c.textSub))),
                          ),
                        for (final s in _stocks)
                          _stockCard(s),
                      ],
                    ),
                  ),
          ),
        ],
      ),
        ],
      ),
    );
  }

  /// 单商品库存卡：主单位为出货单位（count_unit），其余单位折叠为副文本；点卡片看进/出来源
  Widget _stockCard(Map<String, dynamic> s) {
    final others = (s['_others'] as List?)?.cast<Map<String, dynamic>>() ?? const <Map<String, dynamic>>[];
    final othersText = others.isNotEmpty
        ? '\n另有 ${others.map((o) => '${fmtQty(o['quantity'] as num?)} ${o['unit']}').join('、')}'
        : '';
    final low = _isLow(s);
    final exp = _expiryMap['${s['item_id']}\u0000${s['unit']}'];
    final expText = (exp != null && exp.isNotEmpty) ? '\n⚠ $exp 到期（临期）' : '';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      elevation: 0,
      color: low ? _c.danger.withOpacity(0.1) : _c.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: low ? _c.danger.withOpacity(0.5) : _c.divider),
      ),
      child: ListTile(
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: (low ? _c.danger : _c.success).withOpacity(0.12),
          child: Icon(
            low ? Icons.warning_amber_outlined : Icons.inventory_2_outlined,
            size: 16,
            color: low ? _c.danger : _c.success,
          ),
        ),
        title: Text('${s['item_name']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        subtitle: Text('还剩 ${fmtQty(s['quantity'] as num?)} ${s['unit']} · 阈值 ${fmtQty(s['min_stock'] as num?)} ${s['unit']}$othersText$expText',
            style: TextStyle(fontSize: 12, color: _c.textSub)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${fmtQty(s['quantity'] as num?)} ${s['unit']}',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: low ? _c.danger : _c.success,
              ),
            ),
            const SizedBox(width: 2),
            IconButton(
              tooltip: '报损',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              color: _c.danger.withOpacity(0.8),
              onPressed: () => _reportLoss(s),
            ),
          ],
        ),
        onTap: () => _viewTrace(s),
      ),
    );
  }
}