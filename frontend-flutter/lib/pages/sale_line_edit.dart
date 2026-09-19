import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../log.dart';
import '../sync_service.dart';
import '../theme.dart';
import 'attachment_viewer.dart';
import 'change_category.dart';
import 'router.dart';

// 单商品编辑（账本页点明细行 / 日期栏编辑页点行共用）：
/// 弹窗修改 数量/单位/售价/日期/分类/备注（分类为商品级，全局生效），保存后返回该单最新 payload；
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
  final origCountQty = (line['count_qty'] as num?)?.toDouble();
  final countCtrl = TextEditingController(
      text: origCountQty != null && origCountQty > 0 ? origCountQty.toString() : '');
  final priceCtrl = TextEditingController(
      text: salePrice > 0 ? salePrice.toString() : '');
  final happenedAt = '${line['happened_at'] ?? ''}';
  final dateCtrl = TextEditingController(
      text: happenedAt.length >= 10 ? happenedAt.substring(0, 10) : '');
  var category = '${line['category'] ?? ''}';
  final noteCtrl = TextEditingController(text: '${line['note'] ?? ''}');
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
                controller: countCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: '折合计数（可选）',
                  helperText: '本单相当于多少个计数单位（如卖 3 斤 → 填 2 个），库存/备货按它统计；留空=按原单位',
                ),
              ),
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
                  Icon(Icons.label_outline, size: 16, color: c.textSub),
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
                      // 改分类用真实商品 id（goods_id，即 sale_items.item_id）；itemId 是明细行 id 用于行编辑端点
                      final goodsId = '${line['goods_id'] ?? line['item_id'] ?? ''}';
                      if (goodsId.isEmpty) return;
                      final cat = await changeCategory(context, goodsId,
                          itemName: '${line['item_name'] ?? ''}');
                      if (cat != null && ctx.mounted) setDlg(() => category = cat);
                    },
                    child: const Text('修改分类'),
                  ),
                ],
              ),
              // 行级附件（该条商品独立凭证）：查看/添加不阻塞编辑保存
              Row(
                children: [
                  Icon(Icons.image_outlined, size: 16, color: c.textSub),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '该条凭证附件',
                      style: TextStyle(fontSize: 13, color: c.textMain),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await showAttachmentViewer(context, 'sale_item', '$itemId', '出货明细行附件');
                      if (ctx.mounted) setDlg(() {});
                    },
                    child: const Text('查看/添加'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(labelText: '备注（该条商品，可留空）'),
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
  final countParsed = double.tryParse(countCtrl.text.trim());
  final countQty = (countParsed != null && countParsed > 0) ? countParsed : null;
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
  final origNote = '${line['note'] ?? ''}';
  final note = noteCtrl.text.trim();
  final unchanged =
      (origQty != null && qty == origQty) && unit == origUnit && price == salePrice && date == origDate && note == origNote &&
      ((origCountQty == null || origCountQty <= 0) ? countQty == null : (countQty != null && countQty == origCountQty));
  if (unchanged) return null;

  try {
    if (kIsWeb) {
      await Api.instance.patch('/sales/items/$itemId', {
        'quantity': qty,
        'unit': unit,
        'count_qty': countQty,
        'sale_price': price,
        'happened_at': date,
        'note': note,
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
        itMap['count_qty'] = countQty;
        itMap['sale_price'] = price;
        itMap['amount'] = (qty * price * 100).round() / 100;
        itMap['happened_at'] = date;
        itMap['note'] = note;
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
    // 行级 store 同步更新（账本读行级 sale_items 组装：只写整单则单改日期/数量后本地列表不变）
    final edited = updatedItems.where((it) => '${it['id']}' == itemId).firstOrNull;
    if (edited != null) {
      await LocalDb.upsertOne('sale_items', Map<String, dynamic>.from(edited));
    }
    await SyncService.enqueueChange(
        entityType: 'sale', entitySyncId: '${order['id']}', action: 'upsert', payload: payload);
    toast(context, '已保存');
    return payload;
  } catch (e) {
    toast(context, e.toString().replaceFirst('Exception: ', ''));
    return null;
  }
}
