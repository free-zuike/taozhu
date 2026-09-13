import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import 'router.dart';

/// 修改商品分类（分类为商品级、全局生效）：两级目录选择 → Web PATCH /items / 原生本地+同步队列。
/// 本地库找不到该商品时按名称从服务器拉取写库后再改（消除"本地商品库无此商品"）。
/// 成功返回新的分类名（'' = 未分类），取消返回 null。
/// 账本/进货单笔弹窗共用。
Future<String?> changeCategory(BuildContext context, String itemId,
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
        // 本地优先：不访问网络。全量同步后本地仍无该商品 = 商品已从商品库删除
        //（历史明细里的商品名是快照），改分类无意义——提示准确原因，不再引导反复全量同步
        toast(context, '该商品已从商品库删除（历史明细仍显示原名称），无法修改分类');
        return null;
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

/// 从本地商品目录反查分类名（账本/进货流水行展示分类：商品管理改分类后即时生效，
/// 不再依赖明细行快照）；本地目录缺该商品时返回空串
Future<String> itemCategoryOf(String itemId) async {
  if (itemId.isEmpty) return '';
  try {
    final items = await LocalDb.getAllByName('items');
    return '${items.where((x) => '${x['id']}' == itemId).firstOrNull?['category'] ?? ''}';
  } catch (_) {
    return '';
  }
}