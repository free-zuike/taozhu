import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show ChangeNotifier, kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'local_db.dart';

/// 同步服务（增量式）：本地库增量 upsert/delete + 变更队列批量推送。
///
/// 流程：
/// - 启动/回前台 → fullSync（首次）或 pullChanges（增量），合并到本地库
/// - 写本地优先 → 入 local_changes 队列 → debounce 250ms 触发 pushPending
/// - push 成功移除队列；失败留队列下次重试
/// - 任一同步动作完成后 bump version（页面监听后重读本地库，实现"本地优先 + 后台静默刷新"）
///
/// Web 端禁用（本地库无意义）；移动/桌面端启用。
class SyncService {
  SyncService._();
  static const _cursorKey = 'taozhu_sync_cursor';
  static const _deviceIdKey = 'taozhu_device_id';
  static const _fullDoneKey = 'taozhu_sync_full_done';
  static const _lastSyncKey = 'taozhu_sync_last_at';

  /// 同步版本号：任何 full/pull/push 完成后 +1。页面监听它，版本变化后从本地库重读展示。
  static final ChangeNotifier version = ChangeNotifier();

  static String? _deviceId;
  static bool _syncing = false;
  static Timer? _debounce;

  /// 设备 ID（首次生成随机 UUID，持久化；pull/push 用）
  static Future<String> deviceId() async {
    if (_deviceId != null) return _deviceId!;
    final p = await SharedPreferences.getInstance();
    var id = p.getString(_deviceIdKey);
    if (id == null || id.isEmpty) {
      id = _genUuid();
      await p.setString(_deviceIdKey, id);
    }
    _deviceId = id;
    return id;
  }

  /// 生成简易 UUID（时间戳+随机，足够设备标识唯一性）
  static String _genUuid() {
    final r = Random();
    final hex = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final rand = List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
    return '$hex${rand.substring(0, 16)}'.substring(0, 32);
  }

  /// 是否已完成首次全量同步
  static Future<bool> isFullDone() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_fullDoneKey) ?? false;
  }

  /// 记录本次同步时间并通知监听者（本地库已被服务端数据刷新）
  static Future<void> _markSynced() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_lastSyncKey, DateTime.now().toIso8601String());
    version.notifyListeners();
  }

  /// 上次成功同步时间（null=从未同步过）
  static Future<String?> lastSyncAt() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_lastSyncKey);
  }

  /// 本地待推送变更数（local_changes 队列）
  static Future<int> pendingCount() async {
    if (kIsWeb) return 0;
    try {
      return (await LocalDb.getPendingChanges()).length;
    } catch (_) {
      return 0;
    }
  }

  /// 队列里待推送的"删除"实体 id 集合（delete action 或 upsert 带非空 deleted_at）：
  /// 推送落地前，列表页网络刷新要用它过滤，防止"刚删的又出现"（服务端还没收到删除）。
  static Future<Set<String>> pendingDeletedIds(String entityType) async {
    if (kIsWeb) return {};
    try {
      final pending = await LocalDb.getPendingChanges();
      return pending
          .where((c) => '${c['entity_type']}' == entityType)
          .where((c) {
            if ('${c['action']}' == 'delete') return true;
            final payload = c['payload'];
            if (payload is Map) {
              final dt = payload['deleted_at'];
              return dt != null && '$dt'.isNotEmpty;
            }
            return false;
          })
          .map((c) => '${c['entity_sync_id']}')
          .toSet();
    } catch (_) {
      return {};
    }
  }

  /// 首次全量同步（新设备/重装）：拉全部实体一次到位，比逐条 pull 快
  static Future<int> fullSync() async {
    if (kIsWeb) return 0;
    try {
      final d = await Api.instance.get('/sync/full');
      if (d == null) return 0;
      final clients = (d['clients'] as List?) ?? [];
      final items = (d['items'] as List?) ?? [];
      final categories = (d['categories'] as List?) ?? [];
      final sales = (d['sales'] as List?) ?? [];
      final purchases = (d['purchases'] as List?) ?? [];
      final payments = (d['payments'] as List?) ?? [];
      await LocalDb.putAll('clients', clients.cast<Map<String, dynamic>>());
      await LocalDb.putAll('items', items.cast<Map<String, dynamic>>());
      await LocalDb.putAll('categories', categories.cast<Map<String, dynamic>>());
      await LocalDb.putAll('sales', sales.cast<Map<String, dynamic>>());
      await LocalDb.putAll('purchases', purchases.cast<Map<String, dynamic>>());
      await LocalDb.putAll('payments', payments.cast<Map<String, dynamic>>());
      final cursor = d['server_cursor'] as int? ?? 0;
      final p = await SharedPreferences.getInstance();
      await p.setInt(_cursorKey, cursor);
      await p.setBool(_fullDoneKey, true);
      await _markSynced();
      return clients.length + items.length + sales.length + purchases.length + payments.length;
    } catch (_) {
      return 0;
    }
  }

  /// 增量拉取（按游标；排除自己设备回声）：upsert/delete 合并到本地库
  static Future<int> pullChanges() async {
    if (kIsWeb) return 0;
    if (_syncing) return 0;
    _syncing = true;
    try {
      final p = await SharedPreferences.getInstance();
      var since = p.getInt(_cursorKey) ?? 0;
      final did = await deviceId();
      var total = 0;
      var hasMore = true;
      while (hasMore) {
        final d = await Api.instance.get('/sync/pull?since=$since&limit=500&device_id=$did');
        if (d == null) break;
        final changes = (d['changes'] as List?) ?? [];
        for (final raw in changes) {
          final ch = raw as Map<String, dynamic>;
          final entityType = '${ch['entity_type'] ?? ''}';
          final id = '${ch['entity_sync_id'] ?? ''}';
          final action = '${ch['action'] ?? 'upsert'}';
          final payload = ch['payload'] as Map<String, dynamic>? ?? {};
          final store = _storeOf(entityType);
          if (store.isEmpty) continue;
          if (action == 'delete') {
            await LocalDb.deleteOne(store, id);
          } else {
            // 软删（client/item deleted_at 非空）→ 本地删行（历史单据有快照不丢）
            final deletedAt = payload['deleted_at'];
            if (deletedAt != null && '$deletedAt'.isNotEmpty) {
              await LocalDb.deleteOne(store, id);
            } else {
              await LocalDb.upsertOne(store, payload);
            }
          }
          total++;
        }
        final newCursor = d['server_cursor'] as int? ?? since;
        // 推进本地游标再拉下一页；游标无进展立即退出，防止服务端异常导致死循环
        if (newCursor <= since) break;
        since = newCursor;
        await p.setInt(_cursorKey, since);
        hasMore = d['has_more'] == true;
        if (changes.isEmpty) break;
      }
      if (total > 0 || since == 0) await _markSynced();
      return total;
    } catch (_) {
      return 0;
    } finally {
      _syncing = false;
    }
  }

  /// 推送本地待同步队列（批量 POST /sync/push）；成功移除，失败留队列
  static Future<int> pushPending() async {
    if (kIsWeb) return 0;
    try {
      final pending = await LocalDb.getPendingChanges();
      if (pending.isEmpty) return 0;
      final did = await deviceId();
      final changes = pending.map((x) {
        final m = Map<String, dynamic>.from(x);
        m.remove('id'); // 队列内部 id 不传服务端
        return m;
      }).toList();
      final d = await Api.instance.post('/sync/push', {'device_id': did, 'changes': changes});
      if (d == null) return 0;
      final accepted = d['accepted'] as int? ?? 0;
      // 接受的按入队顺序移除（服务端 LWW 拒绝的留队列下次重试或由用户新写覆盖）
      var removed = 0;
      for (final x in pending) {
        if (removed >= accepted) break;
        final id = x['id'];
        if (id is int) {
          await LocalDb.removePendingChange(id);
          removed++;
        }
      }
      // 推送成功后顺便拉取一次（其他设备的变更）
      await pullChanges();
      return accepted;
    } catch (_) {
      return 0;
    }
  }

  /// 入队一条本地变更（写本地优先时调用；触发 debounce 推送）
  static Future<void> enqueueChange({
    required String entityType,
    required String entitySyncId,
    String action = 'upsert',
    required Map<String, dynamic> payload,
  }) async {
    if (kIsWeb) return;
    await LocalDb.addPendingChange({
      'id': DateTime.now().microsecondsSinceEpoch,
      'entity_type': entityType,
      'entity_sync_id': entitySyncId,
      'action': action,
      'payload': payload,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    _schedulePush();
  }

  /// debounce 250ms 触发推送（写后批量，避免逐条请求）
  static void _schedulePush() {
    if (kIsWeb) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      pushPending();
    });
  }

  /// 启动/回前台同步：首次 full，后续增量 pull + 推送待发
  static Future<void> sync() async {
    if (kIsWeb) return;
    final done = await isFullDone();
    if (!done) {
      await fullSync();
    } else {
      await pullChanges();
    }
    await pushPending();
  }

  /// 实体类型 → 本地 store 名映射
  static String _storeOf(String entityType) {
    switch (entityType) {
      case 'client': return 'clients';
      case 'item': return 'items';
      case 'category': return 'categories';
      case 'sale': return 'sales';
      case 'purchase': return 'purchases';
      case 'payment': return 'payments';
      default: return '';
    }
  }
}