import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import 'router.dart';

/// 回收站：作废/红冲单据的快照列表、恢复入账、彻底删除（仅老板）。
/// 作废入口在单据列表的删除操作，删除时 ?reason= 会一并写入这里。
class TrashPage extends StatefulWidget {
  const TrashPage({super.key});
  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  List<Map<String, dynamic>>? _items;
  bool _busy = false;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 先对账本机"已恢复/已彻底删除"的待同步快照（有 pending 才发请求，失败不阻塞展示）
    if (!kIsWeb) {
      try { await SyncService.reconcileTrash(); } catch (_) {}
    }
    // 本机快照（离线删除时生成的归档；本地优先，离线也能看/恢复）
    var local = <Map<String, dynamic>>[];
    if (!kIsWeb) {
      try {
        local = (await LocalDb.getAll('voided_orders'))
            .where((x) => '${x['state'] ?? ''}' == 'archived')
            .map((x) => {...x, '_local': true})
            .toList();
      } catch (_) {}
    }
    // 服务端归档（联网时合并；离线时只显示本机快照）
    List<Map<String, dynamic>> server = [];
    var offline = false;
    try {
      final d = await Api.instance.get('/trash?limit=200');
      server = ((d['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    } catch (_) {
      offline = true;
    }
    // 去重：同 id 的本机快照优先；本机已恢复/已清除的单据不显示服务端旧归档
    final localIds = {for (final r in local) '${r['id']}'};
    final hidden = <String>{};
    if (!kIsWeb) {
      try {
        for (final r in await LocalDb.getAll('voided_orders')) {
          if ('${r['state'] ?? ''}' == 'archived') continue;
          final p = (r['payload'] as Map?) ?? const {};
          hidden.add('${r['id']}');
          hidden.add('${r['entity_type']}:${p['id']}');
        }
      } catch (_) {}
    }
    final merged = <Map<String, dynamic>>[
      ...local,
      ...server.where((s) =>
          !localIds.contains('${s['id']}') &&
          !hidden.contains('${s['id']}') &&
          !hidden.contains('${s['entity_type']}:${s['entity_id'] ?? ''}')),
    ]..sort((a, b) => '${b['voided_at'] ?? ''}'.compareTo('${a['voided_at'] ?? ''}'));
    if (!mounted) return;
    setState(() {
      _items = merged;
      _offline = offline;
    });
  }

  static const _typeLabel = {'sale': '出货', 'purchase': '进货', 'payment': '收款'};

  static String _shortTime(dynamic iso) {
    final s = '${iso ?? ''}';
    return s.length >= 16 ? s.substring(5, 16).replaceAll('T', ' ') : s;
  }

  Future<void> _restore(Map<String, dynamic> row) async {
    final type = '${row['entity_type'] ?? ''}';
    final label = _typeLabel[type] ?? '单据';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复单据'),
        content: Text('将把这张$label恢复到账本，'
            '库存、欠款与同步会一起更新。确认继续？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('恢复')),
        ],
      ),
    );
    if (ok != true || _busy) return;
    setState(() => _busy = true);
    final isLocal = row['_local'] == true;
    try {
      if (isLocal) {
        // 本地优先：立即按快照恢复（离线可用），在线时顺手让服务端回放（进货批次账以服务端为准）
        await SyncService.restoreLocalVoid('${row['id']}');
        var serverOk = false;
        try {
          await Api.instance.post('/trash/${row['id']}/restore');
          serverOk = true;
        } catch (_) { /* 离线/服务端尚无归档 → 保留 pending，联网后对账 */ }
        if (serverOk) await SyncService.removeLocalVoid('${row['id']}');
        if (mounted) toast(context, serverOk ? '已恢复到账本' : '已恢复（本机，联网后自动确认）');
      } else {
        await Api.instance.post('/trash/${row['id']}/restore');
        if (mounted) toast(context, '已恢复到账本');
      }
      await _load();
    } catch (e) {
      if (mounted) toast(context, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purge(Map<String, dynamic> row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('彻底删除'),
        content: const Text('删除后无法再恢复这张单据，确认继续？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || _busy) return;
    setState(() => _busy = true);
    final isLocal = row['_local'] == true;
    try {
      if (isLocal) {
        // 本地优先：立即从本机列表移除（标记待清理），在线时顺手清服务端归档
        await SyncService.purgeLocalVoid('${row['id']}');
        var serverOk = false;
        try {
          await Api.instance.delete('/trash/${row['id']}');
          serverOk = true;
        } catch (_) { /* 离线/服务端尚无归档 → 联网后对账（含 no_archive 硬删） */ }
        if (serverOk) await SyncService.removeLocalVoid('${row['id']}');
        if (mounted) toast(context, serverOk ? '已从回收站清除' : '已清除（本机，联网后自动清理云端）');
      } else {
        await Api.instance.delete('/trash/${row['id']}');
        if (mounted) toast(context, '已从回收站清除');
      }
      await _load();
    } catch (e) {
      if (mounted) toast(context, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: appBarBackground(context),
        title: const Text('回收站', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: themePageBackground(context)),
          items == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text('删除出货 / 进货 / 收款时会先归档到这里，作废行不会进入统计、欠款与流水导出。',
                            style: TextStyle(fontSize: 12.5, color: Colors.grey)),
                      ),
                      if (_offline)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: Text('当前离线：显示本机归档。联网后自动对账其他设备的回收站记录。',
                              style: TextStyle(fontSize: 12.5, color: Colors.orange)),
                        ),
                      if (items.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 48),
                          child: Center(child: Text('回收站是空的', style: TextStyle(fontSize: 13, color: Colors.grey))),
                        )
                      else
                        for (final row in items) _card(row),
                    ],
                  ),
                ),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> row) {
    final type = '${row['entity_type'] ?? ''}';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _c.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _c.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: _c.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                child: Text(_typeLabel[type] ?? type,
                    style: TextStyle(fontSize: 11, color: _c.primary, fontWeight: FontWeight.w600)),
              ),
              if (row['_local'] == true) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(6)),
                  child: const Text('本机',
                      style: TextStyle(fontSize: 10, color: Colors.orange, fontWeight: FontWeight.w600)),
                ),
              ],
              const SizedBox(width: 8),
              Expanded(
                child: Text('${_shortTime(row['voided_at'])} · ${row['voided_by'] ?? ''} · 金额 ¥${row['total'] ?? 0}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            ],
          ),
          if ('${row['reason'] ?? ''}'.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('原因：${row['reason']}', style: const TextStyle(fontSize: 12.5)),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: _busy ? null : () => _purge(row),
                icon: const Icon(Icons.delete_forever_outlined, size: 16),
                label: const Text('彻底删除', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _busy ? null : () => _restore(row),
                icon: const Icon(Icons.restore_outlined, size: 16),
                label: const Text('恢复', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
