import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'db_factory_io.dart' if (dart.library.html) 'db_factory_web.dart' as factory_impl;

/// 本地数据库（sembast，SQLite 文件）——**仅移动/桌面端启用**。
/// Web 端禁用（无网络即无法加载页面，离线无意义）：kIsWeb 时各方法直接空操作，不初始化不报错。
/// 镜像服务端核心数据（clients/items/sales/payments），读优先本地（秒开+离线），网络成功静默写库。
/// v0.17.1.0 起：支持增量 upsert/deleteOne（增量 pull 合并）+ local_changes 待推送队列。
class LocalDb {
  LocalDb._();
  static Database? _db;

  /// 待推送变更队列 store 名（写本地优先时入队，后台批量 push）
  static const pendingStore = 'local_changes';

  static Future<Database?> _open() async {
    if (kIsWeb) return null;
    if (_db != null) return _db!;
    try {
      final dir = await getApplicationDocumentsDirectory();
      _db = await factory_impl.dbFactory!.openDatabase('${dir.path}/taozhu.db');
    } catch (_) {
      _db = null; // 本地库初始化失败不阻塞功能
    }
    return _db;
  }

  /// 整体替换某集合镜像（key = 行 id），rows 为空则清空；Web/失败时静默跳过
  static Future<void> putAll(String storeName, List<Map<String, dynamic>> rows) async {
    final db = await _open();
    if (db == null) return;
    try {
      final store = stringMapStoreFactory.store(storeName);
      await store.delete(db);
      for (final r in rows) {
        final id = '${r['id'] ?? ''}';
        if (id.isEmpty) continue;
        await store.record(id).put(db, r);
      }
    } catch (_) {}
  }

  /// 增量 upsert 多行（按 id 覆盖，不删整表；在线刷新合并用，保留本地未推送的单）
  static Future<void> upsertList(String storeName, List<Map<String, dynamic>> rows) async {
    final db = await _open();
    if (db == null) return;
    try {
      final store = stringMapStoreFactory.store(storeName);
      for (final r in rows) {
        final id = '${r['id'] ?? ''}';
        if (id.isEmpty) continue;
        await store.record(id).put(db, r);
      }
    } catch (_) {}
  }

  /// 增量 upsert 单行（按 id 覆盖；不删整表，增量 pull 合并用）
  static Future<void> upsertOne(String storeName, Map<String, dynamic> row) async {
    final db = await _open();
    if (db == null) return;
    try {
      final id = '${row['id'] ?? ''}';
      if (id.isEmpty) return;
      final store = stringMapStoreFactory.store(storeName);
      await store.record(id).put(db, row);
    } catch (_) {}
  }

  /// 删单行（delete action 合并用；不存在静默跳过）
  static Future<void> deleteOne(String storeName, String id) async {
    final db = await _open();
    if (db == null) return;
    try {
      final store = stringMapStoreFactory.store(storeName);
      await store.record(id).delete(db);
    } catch (_) {}
  }

  /// 读取某集合镜像（按 happened_at 降序；未初始化/Web/空返回 []）
  static Future<List<Map<String, dynamic>>> getAll(String storeName) async {
    final db = await _open();
    if (db == null) return [];
    try {
      final store = stringMapStoreFactory.store(storeName);
      final snap = await store.find(db, finder: Finder(sortOrders: [SortOrder('happened_at', false)]));
      return snap.map((e) => Map<String, dynamic>.from(e.value)).toList();
    } catch (_) {
      return [];
    }
  }

  /// 读取某集合镜像（按 name 排序，店铺/商品列表用）
  static Future<List<Map<String, dynamic>>> getAllByName(String storeName) async {
    final db = await _open();
    if (db == null) return [];
    try {
      final store = stringMapStoreFactory.store(storeName);
      final snap = await store.find(db, finder: Finder(sortOrders: [SortOrder('name', true)]));
      return snap.map((e) => Map<String, dynamic>.from(e.value)).toList();
    } catch (_) {
      return [];
    }
  }

  // ---------- 待推送变更队列（local_changes store，写本地优先时入队） ----------

  /// 入队一条待推送变更（{id, entity_type, entity_sync_id, action, payload, updated_at}）
  static Future<void> addPendingChange(Map<String, dynamic> change) async {
    final db = await _open();
    if (db == null) return;
    try {
      final store = intMapStoreFactory.store(pendingStore);
      final id = change['id'] ?? DateTime.now().microsecondsSinceEpoch;
      await store.record(id as int).put(db, change);
    } catch (_) {}
  }

  /// 读取全部待推送变更（按入队顺序）
  static Future<List<Map<String, dynamic>>> getPendingChanges() async {
    final db = await _open();
    if (db == null) return [];
    try {
      final store = intMapStoreFactory.store(pendingStore);
      final snap = await store.find(db);
      return snap.map((e) => Map<String, dynamic>.from(e.value)).toList();
    } catch (_) {
      return [];
    }
  }

  /// 按入队 id 删除已推送成功的变更
  static Future<void> removePendingChange(int id) async {
    final db = await _open();
    if (db == null) return;
    try {
      final store = intMapStoreFactory.store(pendingStore);
      await store.record(id).delete(db);
    } catch (_) {}
  }

  /// 清空待推送队列（切账号/全量重置时）
  static Future<void> clearPendingChanges() async {
    final db = await _open();
    if (db == null) return;
    try {
      final store = intMapStoreFactory.store(pendingStore);
      await store.delete(db);
    } catch (_) {}
  }

  /// 清空本地库（切换账号/退出时调用，防止账号数据串号）：关库 + 删数据文件
  static Future<void> clearAll() async {
    if (kIsWeb) return;
    try {
      final db = await _open();
      await db?.close();
      _db = null;
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/taozhu.db');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}