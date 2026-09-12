import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show ChangeNotifier, kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'local_db.dart';
import 'log.dart';

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
  static const _selectedClientKey = 'taozhu_selected_client_id';

  /// 同步版本号：任何 full/pull/push 完成后 +1。页面监听它，版本变化后从本地库重读展示。
  static final ChangeNotifier version = ChangeNotifier();

  /// 同步状态通知器（idle=空闲 / syncing=同步中）：「我的」页进入应用时实时显示同步进度
  static final ChangeNotifier status = ChangeNotifier();
  static String _status = 'idle';
  static String get syncStatus => _status;
  static void _setStatus(String s) {
    if (_status == s) return;
    _status = s;
    status.notifyListeners();
  }

  static String? _deviceId;
  static bool _syncing = false;
  static Timer? _debounce;

  /// 设备 ID（首次生成随机 UUID，持久化；pull/push 用）
  static Future<String> deviceId() async {
    if (_deviceId != null) return _deviceId!;
    try {
      final p = await SharedPreferences.getInstance();
      var id = p.getString(_deviceIdKey);
      if (id == null || id.isEmpty) {
        id = _genUuid();
        await p.setString(_deviceIdKey, id);
      }
      _deviceId = id;
      return id;
    } catch (_) {
      // 本地存储异常也不能让同步流程抛（转圈永不释放的根因之一）
      final fallback = _genUuid();
      _deviceId = fallback;
      return fallback;
    }
  }

  /// 生成简易 UUID（时间戳 padLeft(16) + 16 位随机，保证正好 32 字符不越界）
  static String _genUuid() {
    final r = Random();
    final hex = DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(16, '0');
    final rand = List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
    return '$hex$rand';
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
    try {
      final p = await SharedPreferences.getInstance();
      return p.getString(_lastSyncKey);
    } catch (_) {
      return null;
    }
  }

  /// 当前选择的店铺 id（账本页选中后持久化；同步面板按店铺隔离同步时读取）
  static Future<String?> selectedClientId() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getString(_selectedClientKey);
    } catch (_) {
      return null;
    }
  }

  /// 记录当前选择的店铺（账本页切换/新建店铺时调用）
  static Future<void> saveSelectedClientId(String id) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_selectedClientKey, id);
    } catch (_) {}
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
      // 本地待推送删除的实体（删除尚未落地前，pull 不得把它们恢复，否则"删了又出现"）
      final pendingDelete = <String, Set<String>>{};
      Future<Set<String>> pendingOf(String t) async =>
          pendingDelete.putIfAbsent(t, () => pendingDeletedIds(t));
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
              // 本地已软删但推送尚未落地：跳过 upsert，保留本地删除状态
              if (await (await pendingOf(entityType)).contains(id)) continue;
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
      // 空拉取也是一次成功同步：流程正常结束（未走 catch）即刷新"上次同步时间"，避免时间停在有数据变更的那次
      await _markSynced();
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

  /// 启动/回前台同步：首次 full，后续增量 pull + 推送待发（静默）。
  /// 同步中会通知 status 监听者（「我的」页实时显示 同步中/已同步）。
  static Future<void> sync() async {
    if (kIsWeb) return;
    _setStatus('syncing');
    var pulled = 0;
    var pushed = 0;
    try {
      final done = await isFullDone();
      if (!done) {
        pulled = await fullSync();
      } else {
        pulled = await pullChanges();
      }
      pushed = await pushPending();
      appLog('sync', '同步完成：拉取 $pulled 条、推送 $pushed 条', level: 'info');
    } catch (_) {
      // 任一异常都不外抛（bottom_shell 无 await 调用，抛了就成 unhandled error）
    } finally {
      _setStatus('idle');
    }
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