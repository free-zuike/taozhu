import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart'
    if (dart.library.html) 'package:sembast/sembast_web.dart' as platform;

/// 本地数据库（sembast）：App=SQLite 文件，Web=IndexedDB。
/// 镜像服务端核心数据（clients/items/sales/payments），读优先本地（秒开+离线），网络成功静默写库。
class LocalDb {
  LocalDb._();
  static Database? _db;

  static Future<Database> _open() async {
    if (_db != null) return _db!;
    late Database db;
    if (kIsWeb) {
      db = await platform.databaseFactoryWeb.openDatabase('taozhu.db');
    } else {
      final dir = await getApplicationDocumentsDirectory();
      db = await platform.databaseFactoryIo.openDatabase('${dir.path}/taozhu.db');
    }
    _db = db;
    return db;
  }

  /// 整体替换某集合镜像（key = 行 id），rows 为空则清空
  static Future<void> putAll(String storeName, List<Map<String, dynamic>> rows) async {
    final db = await _open();
    final store = stringMapStoreFactory.store(storeName);
    final tx = await db.transaction();
    try {
      await store.delete(tx);
      for (final r in rows) {
        final id = '${r['id'] ?? ''}';
        if (id.isEmpty) continue;
        await store.record(id).put(tx, r);
      }
    } finally {
      await tx.close();
    }
  }

  /// 读取某集合镜像（未初始化/空返回 []）
  static Future<List<Map<String, dynamic>>> getAll(String storeName) async {
    try {
      final db = await _open();
      final store = stringMapStoreFactory.store(storeName);
      final snap = await store.find(db, finder: Finder(sortOrders: [SortOrder('happened_at', false)]));
      return snap.map((e) => Map<String, dynamic>.from(e.value)).toList();
    } catch (_) {
      return [];
    }
  }

  /// 读取某集合镜像（按 name 排序，店铺/商品列表用）
  static Future<List<Map<String, dynamic>>> getAllByName(String storeName) async {
    try {
      final db = await _open();
      final store = stringMapStoreFactory.store(storeName);
      final snap = await store.find(db, finder: Finder(sortOrders: [SortOrder('name', true)]));
      return snap.map((e) => Map<String, dynamic>.from(e.value)).toList();
    } catch (_) {
      return [];
    }
  }
}