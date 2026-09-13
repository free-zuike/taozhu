import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../log.dart';
import '../sync_service.dart';
import '../theme.dart';
import 'router.dart';

/// 单商品编辑（账本页点明细行 / 日期栏编辑页点行共用）：
/// 弹窗修改 数量/单位/售价/日期/分类（分类为商品级，全局生效），保存后返回该单最新 payload；
/// 取消/未修改/出错返回 null。
/// - Web：PATCH /sales/items/:id（行级编辑端点，服务端联动金额与单据日期）后 GET 单据刷新；
/// - 原生：更新本地库镜像 + 入同步队列（离线可保存，服务端以整单快照应用）。
Future<Map<String, dynamic>?> editSaleLine(
    BuildContext context, Map<String, dynamic> line) async {
  final order = line['order'] as Map<String, dynamic>;
  final itemId = '${line['item_id'] ?? ''}';
  if (itemId.isEmpty) return null; // 无明细（备注占位行）不在此编辑，调用方回退整单编辑

  final qtyCtrl = TextEditingController(text: '${line['quantity'] ?? ''}');
  final unitCtrl = TextEditingController(text: '${line['unit'] ?? ''}');
  final salePrice = (line['sale_price'] as num?)?.toDouble() ?? 0;
  final priceCtrl = TextEditingController(
      text: salePrice > 0 ? salePrice.toString() : '');
  final happenedAt = '${line['happened_at'] ?? ''}';
  final dateCtrl = TextEditingController(
      text: happenedAt.length >= 10 ? happenedAt.substring(0, 10) : '');
  var category = '${line['category'] ?? ''}';
  final c = Theme.of(context).extension<TaozhuColors>()!;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('编辑「${line['item_name'] ?? ''}」'),
      content: StatefulBuilder(
        builder: (ctx, setDlg) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: qtyCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '数量'),
              ),
              const SizedBox(height: 8),
              TextField(controller: unitCtrl, decoration: const InputDecoration(labelText: '单位（斤/件/箱…）')),
              const SizedBox(height: 8),
              TextField(
                controller: priceCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '售价（元）'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: dateCtrl,
                      decoration: const InputDecoration(labelText: '日期（YYYY-MM-DD）'),
                    ),
                  ),
                  IconButton(
                    tooltip: '选择日期',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.calendar_month_outlined, size: 20, color: c.primary),
                    onPressed: () async {
                      final now = DateTime.now();
                      final cur = DateTime.tryParse(dateCtrl.text.trim()) ?? now;
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: cur,
                        firstDate: DateTime(now.year - 3),
                        lastDate: DateTime(now.year + 3, 12, 31),
                      );
                      if (picked == null) return;
                      dateCtrl.text = '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                      setDlg(() {});
                    },
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // 商品分类（商品级，全局生效）：点击「修改分类」选择后即时保存
              Row(
                children: [
                  Icon(Icons.sell_outlined, size: 16, color: c.textSub),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      category.isEmpty ? '未分类' : category,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: c.textMain),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final cat = await _changeCategory(context, itemId,
                          itemName: '${line['item_name'] ?? ''}');
                      if (cat != null && ctx.mounted) setDlg(() => category = cat);
                    },
                    child: const Text('修改分类'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return null;

  // 校验与取值（缺省沿用原值，避免误清空破坏数据）
  final qty = double.tryParse(qtyCtrl.text.trim());
  if (qty == null || qty <= 0) {
    toast(context, '请输入有效的数量');
    return null;
  }
  final unit = unitCtrl.text.trim().isEmpty ? '${line['unit'] ?? ''}' : unitCtrl.text.trim();
  // 售价 ≤ 0 或留空视为不改价（与服务端行级编辑口径一致：sale_price > 0 才生效，否则沿用原价）
  final priceParsed = double.tryParse(priceCtrl.text.trim());
  final price = (priceParsed != null && priceParsed > 0) ? priceParsed : salePrice;
  var date = dateCtrl.text.trim();
  if (date.isEmpty) {
    date = happenedAt.length >= 10 ? happenedAt.substring(0, 10) : '';
  } else if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
    toast(context, '日期格式应为 YYYY-MM-DD');
    return null;
  }
  // 未修改任何字段：不写库直接返回
  final origQty = double.tryParse('${line['quantity'] ?? ''}');
  final origUnit = '${line['unit'] ?? ''}';
  final origDate = happenedAt.length >= 10 ? happenedAt.substring(0, 10) : '';
  final unchanged =
      (origQty != null && qty == origQty) && unit == origUnit && price == salePrice && date == origDate;
  if (unchanged) return null;

  try {
    if (kIsWeb) {
      await Api.instance.patch('/sales/items/$itemId', {
        'quantity': qty,
        'unit': unit,
        'sale_price': price,
        'happened_at': date,
      });
      // 行级编辑后服务端已联动总额/单据日期：重新拉取该单最新快照
      final d = await Api.instance.get('/sales/${order['id']}');
      toast(context, '已保存');
      return d as Map<String, dynamic>?;
    }
    // 原生：本地库镜像 + 同步队列（整单快照 upsert，服务端整体替换明细）
    final items = ((order['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    final updatedItems = <Map<String, dynamic>>[];
    for (final it in items) {
      final itMap = Map<String, dynamic>.from(it);
      if ('${it['id']}' == itemId) {
        itMap['quantity'] = qty;
        itMap['unit'] = unit;
        itMap['sale_price'] = price;
        itMap['amount'] = (qty * price * 100).round() / 100;
        itMap['happened_at'] = date;
      }
      updatedItems.add(itMap);
    }
    final payload = Map<String, dynamic>.from(order)..['items'] = updatedItems;
    payload['total'] = updatedItems.fold<double>(
        0, (s, it) => s + ((it['amount'] as num?)?.toDouble() ?? 0));
    // 单据日期 = 明细最大日期（与记单页/改期口径一致）
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
    await SyncService.enqueueChange(
        entityType: 'sale', entitySyncId: '${order['id']}', action: 'upsert', payload: payload);
    toast(context, '已保存');
    return payload;
  } catch (e) {
    toast(context, e.toString().replaceFirst('Exception: ', ''));
    return null;
  }
}

/// 修改商品分类（分类为商品级、全局生效）：两级目录选择 → Web PATCH /items / 原生本地+同步队列。
/// 本地库找不到该商品时按名称从服务器拉取写库后再改（消除"本地商品库无此商品"）。
/// 成功返回新的分类名（'' = 未分类），取消返回 null。
Future<String?> _changeCategory(BuildContext context, String itemId,
    {String itemName = ''}) async {
  // 商品分类目录（两级）：原生优先读本地镜像；Web/本地为空时拉网络
  var cats = await LocalDb.getAll('categories');
  cats = cats.where((x) => '${x['type'] ?? ''}' == 'item').toList()
    ..sort((a, b) => ((a['sort'] as num?)?.toInt() ?? 0).compareTo((b['sort'] as num?)?.toInt() ?? 0));
  if (cats.isEmpty || kIsWeb) {
    try {
      final d = await Api.instance.get('/categories?type=item');
      cats = ((d['categories'] as List?) ?? []).cast<Map<String, dynamic>>();
    } catch (_) {}
  }
  final parents = cats.where((x) => (x['parent_id'] as String? ?? '').isEmpty).toList();
  final childOf = (String pid) => cats.where((x) => '${x['parent_id']}' == pid).toList();
  final selected = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('选择商品分类'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, ''),
          child: const Text('无分类', style: TextStyle(fontSize: 15)),
        ),
        for (final p in parents) ...[
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '${p['id']}'),
            child: Text('${p['name']}',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          for (final ch in childOf('${p['id']}'))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '${ch['id']}'),
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text('${ch['name']}', style: const TextStyle(fontSize: 15)),
              ),
            ),
        ],
        const SizedBox(height: 8),
      ],
    ),
  );
  if (selected == null) return null;
  final catName = selected.isEmpty
      ? ''
      : '${cats.where((x) => '${x['id']}' == selected).firstOrNull?['name'] ?? ''}';
  try {
    if (kIsWeb) {
      await Api.instance.patch('/items/$itemId', {
        'category': catName,
        'category_id': selected.isEmpty ? null : selected,
      });
    } else {
      var stored = (await LocalDb.getAllByName('items'))
          .where((x) => '${x['id']}' == itemId).firstOrNull;
      if (stored == null) {
        // 本地库没有：优先按 itemId 从服务器单查拉取该商品写库（根治"本地商品库无此商品"）
        try {
          final dd = await Api.instance.get('/items/$itemId');
          final it = dd['item'];
          if (it is Map<String, dynamic>) {
            stored = Map<String, dynamic>.from(it);
            await LocalDb.upsertOne('items', stored);
          }
        } catch (e) {
          appLog('sync', '分类兜底按 id 拉取失败 item=$itemId: ${e.toString().split('\n').first}', level: 'error');
        }
        // 次选：按名称搜索（id 查询失败时）
        if (stored == null && itemName.isNotEmpty) {
          try {
            final dd = await Api.instance.get('/items?q=${Uri.encodeQueryComponent(itemName)}');
            stored = ((dd['items'] as List?) ?? []).cast<Map<String, dynamic>>()
                .where((x) => '${x['id']}' == itemId).firstOrNull;
            if (stored != null) await LocalDb.upsertOne('items', Map<String, dynamic>.from(stored));
          } catch (e) {
            appLog('sync', '分类兜底按名称拉取失败 item=$itemId ($itemName): ${e.toString().split('\n').first}', level: 'error');
          }
        }
        if (stored == null) {
          toast(context, '本地商品库无此商品，请先在 Web 端确认该商品存在');
          return null;
        }
      }
      final updated = Map<String, dynamic>.from(stored)
        ..['category'] = catName
        ..['category_id'] = selected.isEmpty ? null : selected;
      await LocalDb.upsertOne('items', updated);
      await SyncService.enqueueChange(
          entityType: 'item', entitySyncId: itemId, action: 'upsert', payload: updated);
    }
    toast(context, '已更新分类');
    return catName;
  } catch (e) {
    toast(context, e.toString().replaceFirst('Exception: ', ''));
    return null;
  }
}
