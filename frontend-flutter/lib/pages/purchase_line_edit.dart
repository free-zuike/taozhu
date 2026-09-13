import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import 'attachment_viewer.dart';
import 'router.dart';

/// 单商品编辑（进货记录页点明细行）：弹窗修改 数量/单位/进价/日期，
/// 保存后返回该单最新 payload；取消/未修改/出错返回 null。
/// - Web：PATCH /purchases/items/:id（行级编辑端点，服务端联动金额与单据日期）后 GET 单据刷新；
/// - 原生：更新本地库镜像 + 入同步队列（离线可保存，服务端以整单快照应用）。
Future<Map<String, dynamic>?> editPurchaseLine(
    BuildContext context, Map<String, dynamic> order, Map<String, dynamic> line) async {
  final itemId = '${line['id'] ?? ''}';
  if (itemId.isEmpty) return null; // 无明细 id 不在此编辑，调用方回退整单编辑

  final qtyCtrl = TextEditingController(text: '${line['quantity'] ?? ''}');
  final unitCtrl = TextEditingController(text: '${line['unit'] ?? ''}');
  final pp = (line['purchase_price'] as num?)?.toDouble() ?? 0;
  final priceCtrl = TextEditingController(
      text: pp > 0 ? pp.toString() : '');
  final happenedAt = '${line['happened_at'] ?? ''}';
  final dateCtrl = TextEditingController(
      text: happenedAt.length >= 10 ? happenedAt.substring(0, 10) : '');

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
                decoration: const InputDecoration(labelText: '进价（元）'),
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
                    icon: const Icon(Icons.calendar_month_outlined, size: 20),
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
              // 行级附件（该条商品独立凭证）：查看/添加不阻塞编辑保存
              Row(
                children: [
                  Icon(Icons.image_outlined, size: 16, color: Theme.of(ctx).extension<TaozhuColors>()!.textSub),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('该条凭证附件',
                        style: TextStyle(fontSize: 13, color: Theme.of(ctx).extension<TaozhuColors>()!.textMain)),
                  ),
                  TextButton(
                    onPressed: () async {
                      await showAttachmentViewer(context, 'purchase_item', '$itemId', '进货明细行附件');
                      if (ctx.mounted) setDlg(() {});
                    },
                    child: const Text('查看/添加'),
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
  // 进价 ≤ 0 或留空视为不改价（与服务端行级编辑口径一致：purchase_price > 0 才生效，否则沿用原价）
  final priceParsed = double.tryParse(priceCtrl.text.trim());
  final price = (priceParsed != null && priceParsed > 0) ? priceParsed : pp;
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
      (origQty != null && qty == origQty) && unit == origUnit && price == pp && date == origDate;
  if (unchanged) return null;

  try {
    if (kIsWeb) {
      await Api.instance.patch('/purchases/items/$itemId', {
        'quantity': qty,
        'unit': unit,
        'purchase_price': price,
        'happened_at': date,
      });
      // 行级编辑后服务端已联动总额/单据日期：重新拉取该单最新快照
      final d = await Api.instance.get('/purchases/${order['id']}');
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
        itMap['purchase_price'] = price;
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
    await LocalDb.upsertOne('purchases', payload);
    await SyncService.enqueueChange(
        entityType: 'purchase', entitySyncId: '${order['id']}', action: 'upsert', payload: payload);
    toast(context, '已保存');
    return payload;
  } catch (e) {
    toast(context, e.toString().replaceFirst('Exception: ', ''));
    return null;
  }
}
