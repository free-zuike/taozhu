import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'db_factory_io.dart' if (dart.library.html) 'db_factory_web.dart' as factory_impl;

/// 本地数据库（sembast，SQLite 文件）——**仅移动/桌面端启用**。
/// Web 端禁用（无网络即无法加载页面，离线无意义）：kIsWeb 时各方法直接空操作，不初始化不报错。
/// 镜像服务端核心数据（clients/items/sales/payments），读优先本地（秒开+离线），网络成功静默写库。
class LocalDb {
  LocalDb._();
  static Database? _db;

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
}