import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'db_factory_io.dart' if (dart.library.html) 'db_factory_web.dart' as factory_impl;
import 'log.dart';
import 'sync_service.dart';

/// 本地数据库（sembast，SQLite 文件）——**仅移动/桌面端启用**。
/// Web 端禁用（无网络即无法加载页面，离线无意义）：kIsWeb 时各方法直接空操作，不初始化不报错。
/// 镜像服务端核心数据（clients/items/sales/payments），读优先本地（秒开+离线），网络成功静默写库。
/// v0.17.1.0 起：支持增量 upsert/deleteOne（增量 pull 合并）+ local_changes 待推送队列。
class LocalDb {
  LocalDb._();
  static Database? _db;

  /// 连续写失败计数（只读/损坏库自愈：≥3 次 → 删除重建 + 全量同步恢复）
  static int _writeFailures = 0;

  /// 数据库操作串行队列：所有读写按入队顺序逐个执行。
  /// 页面 _load（同步通知触发）与删除/同步写入并发访问同一 sembast 连接，
  /// 是 'Bad state: read only' 等冲突的根因之一——串行化后从代码层面杜绝并发。
  static Future<void> _opQueue = Future.value();

  /// 将一次数据库操作串行入队执行（前一个完成才跑下一个；错误不外泄到队列链，
  /// 由调用方自行捕获——各方法内部已有 try/catch 兜底）
  static Future<T> _serial<T>(Future<T> Function() op) {
    final result = _opQueue.then((_) => op());
    _opQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

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
  static Future<void> putAll(String storeName, List<Map<String, dynamic>> rows) {
    return _serial(() async {
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
      } catch (e) {
        appLog('db', 'putAll($storeName) 失败: ${e.toString().split('\n').first}', level: 'error');
      }
    });
  }

  /// 增量 upsert 多行（按 id 覆盖，不删整表；在线刷新合并用，保留本地未推送的单）
  static Future<void> upsertList(String storeName, List<Map<String, dynamic>> rows) {
    return _serial(() async {
      final db = await _open();
      if (db == null) return;
      try {
        final store = stringMapStoreFactory.store(storeName);
        for (final r in rows) {
          final id = '${r['id'] ?? ''}';
          if (id.isEmpty) continue;
          await store.record(id).put(db, r);
        }
      } catch (e) {
        appLog('db', 'upsertList($storeName) 失败: ${e.toString().split('\n').first}', level: 'error');
      }
    });
  }

  /// 增量 upsert 单行（按 id 覆盖；不删整表，增量 pull 合并用；写失败自动重建连接重试一次）
  static Future<void> upsertOne(String storeName, Map<String, dynamic> row) {
    return _serial(() async {
      var db = await _open();
      if (db == null) return;
      final id = '${row['id'] ?? ''}';
      if (id.isEmpty) return;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final store = stringMapStoreFactory.store(storeName);
          await store.record(id).put(db!, row);
          return;
        } catch (e) {
          if (attempt == 0) {
            appLog('db', 'upsertOne($storeName,$id) 失败(${e.toString().split('\n').first})，重建连接重试', level: 'error');
            await _reopen();
            db = await _open();
            if (db == null) return;
          } else {
            appLog('db', 'upsertOne($storeName,$id) 重试仍失败: ${e.toString().split('\n').first}', level: 'error');
            await _onWriteFailure(e);
          }
        }
      }
    });
  }

  /// 写失败自愈：关闭并重建数据库连接（只读/坏连接等异常时重开后再试）
  static Future<void> _reopen() async {
    try {
      await _db?.close();
    } catch (_) {}
    _db = null;
    await _open();
  }

  /// 写失败后的自愈决策：'read only'（数据库被以只读打开）是持续状态，立即重建库文件；
  /// 其他偶发错误累计 3 次才重建（避免网络抖动等瞬时失败误删库）。诊断日志带错误类型。
  static Future<void> _onWriteFailure(Object e) async {
    final msg = e.toString();
    _writeFailures++;
    if (msg.contains('read only') || msg.contains('read-only') || _writeFailures >= 3) {
      appLog('db', '本地库持续写失败（${msg.split('\n').first}，累计 ${_writeFailures} 次），重建库文件+全量同步恢复', level: 'error');
      await _rebuildDatabase();
    }
  }

  /// 本地库持续写失败（只读/损坏）→ 删除（删不掉则改名绕开）重建数据库文件并触发全量同步恢复。
  /// 若应用数据目录本身不可写（存储权限/分区异常），记录明确根因日志。
  static Future<void> _rebuildDatabase() async {
    _writeFailures = 0;
    try {
      await _db?.close();
    } catch (_) {}
    _db = null;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/taozhu.db');
      var rebuilt = false;
      // 优先改名备份（离线同步失败时原数据不丢，文件仍在 .bak 可恢复）；改名失败才尝试删除
      try {
        final bak = File('${dir.path}/taozhu_ro_${DateTime.now().millisecondsSinceEpoch}.db');
        if (await f.exists()) await f.rename(bak.path);
        rebuilt = true;
      } catch (_) {
        try {
          if (await f.exists()) await f.delete();
          rebuilt = true;
        } catch (e2) {
          appLog('db', '本地库重建失败（文件只读且无法改名/删除）: ${e2.toString().split('\n').first}', level: 'error');
        }
      }
      if (rebuilt) {
        // 诊断：验证应用数据目录是否可写（区分"库文件只读"与"整个目录只读"）
        var dirWritable = false;
        try {
          final probe = File('${dir.path}/.taozhu_probe');
          await probe.writeAsString('ok');
          await probe.delete();
          dirWritable = true;
        } catch (_) {}
        appLog('db', '本地库已重建${dirWritable ? '，目录可写' : '，目录仍不可写（存储权限/分区异常，建议清理应用数据重装）'}，触发全量同步恢复', level: 'error');
      }
    } catch (_) {}
    try {
      await SyncService.resetSyncState();
      unawaited(SyncService.sync());
    } catch (_) {}
  }

  /// 删单行（delete action 合并用；不存在静默跳过；写失败自动重建连接重试一次）
  static Future<void> deleteOne(String storeName, String id) {
    return _serial(() async {
      var db = await _open();
      if (db == null) return;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final store = stringMapStoreFactory.store(storeName);
          await store.record(id).delete(db!);
          return;
        } catch (e) {
          if (attempt == 0) {
            appLog('db', 'deleteOne($storeName,$id) 失败(${e.toString().split('\n').first})，重建连接重试', level: 'error');
            await _reopen();
            db = await _open();
            if (db == null) return;
          } else {
            appLog('db', 'deleteOne($storeName,$id) 重试仍失败: ${e.toString().split('\n').first}', level: 'error');
            await _onWriteFailure(e);
          }
        }
      }
    });
  }

  /// 读单行（增量 pull 判"本地已软删"用；不存在/异常返回 null）
  static Future<Map<String, dynamic>?> getOne(String storeName, String id) {
    return _serial(() async {
      final db = await _open();
      if (db == null) return null;
      try {
        final store = stringMapStoreFactory.store(storeName);
        final snap = await store.find(db, finder: Finder(filter: Filter.byKey(id), limit: 1));
        return snap.isEmpty ? null : Map<String, dynamic>.from(snap.first.value);
      } catch (_) {
        return null;
      }
    });
  }

  /// 读取某集合镜像（按 happened_at 降序；未初始化/Web/空返回 []）
  static Future<List<Map<String, dynamic>>> getAll(String storeName) {
    return _serial(() async {
      final db = await _open();
      if (db == null) return <Map<String, dynamic>>[];
      try {
        final store = stringMapStoreFactory.store(storeName);
        final snap = await store.find(db, finder: Finder(sortOrders: [SortOrder('happened_at', false)]));
        return snap.map((e) => Map<String, dynamic>.from(e.value)).toList();
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    });
  }

  /// 读取某集合镜像（按 name 排序，店铺/商品列表用）
  static Future<List<Map<String, dynamic>>> getAllByName(String storeName) {
    return _serial(() async {
      final db = await _open();
      if (db == null) return <Map<String, dynamic>>[];
      try {
        final store = stringMapStoreFactory.store(storeName);
        final snap = await store.find(db, finder: Finder(sortOrders: [SortOrder('name', true)]));
        return snap.map((e) => Map<String, dynamic>.from(e.value)).toList();
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    });
  }

  // ---------- 待推送变更队列（local_changes store，写本地优先时入队） ----------

  /// 入队一条待推送变更（{id, entity_type, entity_sync_id, action, payload, updated_at}；写失败自动重建连接重试一次）
  static Future<void> addPendingChange(Map<String, dynamic> change) {
    return _serial(() async {
      var db = await _open();
      if (db == null) return;
      final id = change['id'] ?? DateTime.now().microsecondsSinceEpoch;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final store = intMapStoreFactory.store(pendingStore);
          await store.record(id as int).put(db!, change);
          return;
        } catch (e) {
          if (attempt == 0) {
            appLog('db', 'addPendingChange 失败(${e.toString().split('\n').first})，重建连接重试', level: 'error');
            await _reopen();
            db = await _open();
            if (db == null) return;
          } else {
            appLog('db', 'addPendingChange 重试仍失败: ${e.toString().split('\n').first}', level: 'error');
            await _onWriteFailure(e);
          }
        }
      }
    });
  }

  /// 读取全部待推送变更（按入队顺序）
  static Future<List<Map<String, dynamic>>> getPendingChanges() {
    return _serial(() async {
      final db = await _open();
      if (db == null) return <Map<String, dynamic>>[];
      try {
        final store = intMapStoreFactory.store(pendingStore);
        final snap = await store.find(db);
        return snap.map((e) => Map<String, dynamic>.from(e.value)).toList();
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    });
  }

  /// 按入队 id 删除已推送成功的变更
  static Future<void> removePendingChange(int id) {
    return _serial(() async {
      final db = await _open();
      if (db == null) return;
      try {
        final store = intMapStoreFactory.store(pendingStore);
        await store.record(id).delete(db);
      } catch (e) {
        appLog('db', 'removePendingChange($id) 失败: ${e.toString().split('\n').first}', level: 'error');
      }
    });
  }

  /// 更新待推送变更的 updated_at（服务端时间校准：设备时钟偏慢导致 LWW 拒绝时，
  /// 用服务器时间重刷被拒条目的时间戳，保证下次推送能胜出）
  static Future<void> retimePendingChange(int id, String updatedAt) {
    return _serial(() async {
      final db = await _open();
      if (db == null) return;
      try {
        final store = intMapStoreFactory.store(pendingStore);
        final snap = await store.record(id).get(db);
        if (snap == null) return;
        await store.record(id).put(db, {...snap, 'updated_at': updatedAt});
      } catch (e) {
        appLog('db', 'retimePendingChange($id) 失败: ${e.toString().split('\n').first}', level: 'error');
      }
    });
  }

  /// 清空待推送队列（切账号/全量重置时）
  static Future<void> clearPendingChanges() {
    return _serial(() async {
      final db = await _open();
      if (db == null) return;
      try {
        final store = intMapStoreFactory.store(pendingStore);
        await store.delete(db);
      } catch (_) {}
    });
  }

  /// 清空本地库（切换账号/退出时调用，防止账号数据串号）：关库 + 删数据文件
  static Future<void> clearAll() {
    return _serial(() async {
      if (kIsWeb) return;
      try {
        final db = await _open();
        await db?.close();
        _db = null;
        final dir = await getApplicationDocumentsDirectory();
        final f = File('${dir.path}/taozhu.db');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    });
  }
}