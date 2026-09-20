import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart' show ChangeNotifier, kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'avatar_cache.dart';
import 'local_db.dart';
import 'log.dart';

/// 商品持久删除集合 key（SharedPreferences 独立存储）：本地库只读/写失败时删除标记跨重启保留，
/// 且 pushPending 合并该集合推送服务端（绕过只读队列）。与 items_page 共用。
const kDeletedItemsKey = 'taozhu_deleted_items';

/// 待上传附件队列 key（SharedPreferences JSON 数组 [{entity,id,fileName}]）：
/// 页面添加附件先落本地副本再入队，sync() 编排统一上传（附件上传是同步引擎一部分）。
const kPendingUploadsKey = 'taozhu_pending_uploads';

/// pull apply 失败记录 key（SharedPreferences JSON 数组，上限 50 条）：
/// 单条 apply 失败不阻塞整页游标——记录错误跳过，后续同实体 apply 成功自动清除（对齐 SyncErrorStore）。
const kPullErrorsKey = 'taozhu_pull_errors';

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

  /// 库存变更通知器：库存盘点/调整/记单后触发，库存页与「我的」页低库存红字监听后刷新（无需重启 App）
  static final ChangeNotifier stockChanged = ChangeNotifier();
  /// 触发库存变更通知（stocks_page 保存/盘点成功后调用）
  static void notifyStockChanged() => stockChanged.notifyListeners();

  static String? _deviceId;
  static bool _syncing = false;
  static Timer? _debounce;

  /// 最近一次同步是否失败（full/pull/push 任一异常置 true；sync() 开始时清除，结束后供 UI 如实显示）
  static bool _lastSyncFailed = false;
  static bool get lastSyncFailed => _lastSyncFailed;

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

  /// 重置同步进度（切换账号/清除数据时调用）：清掉"已全量同步"标记与增量游标，
  /// 下次同步强制重新全量拉取（否则新账号只会做增量 pull，游标之前的服务器数据永远拉不到）。
  /// 设备 id 保留（pull 排除本设备回声依赖它）。
  static Future<void> resetSyncState() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_fullDoneKey);
      await p.remove(_cursorKey);
      await p.remove(_lastSyncKey);
    } catch (_) {}
    _lastSyncFailed = false;
    _status = 'idle';
  }

  /// 记录本次同步时间并通知监听者（本地库已被服务端数据刷新）
  static Future<void> _markSynced() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_lastSyncKey, DateTime.now().toIso8601String());
    version.notifyListeners();
  }

  /// 全量/增量同步完成后：补齐"在用"附件的本地副本（附件不走 sync_changes，同步只拉实体不拉图；
  /// 本地副本被清理后离线不可见——违背本地优先。从 /attachments/in-use 拿服务器在用引用的规范化三元组
  /// {entity,id,file}（后端以 attachment_refs 引用表为权威 + R2 扫描兜底），逐张下载。
  /// 已存在跳过；并发 4 + 指数退避重试 3 次；单张失败静默跳过（下次同步再补），不阻塞同步主流程。
  static Future<void> downloadInUseAttachments() async {
    if (kIsWeb) return;
    List<Map<String, dynamic>> inUse;
    try {
      final d = await Api.instance.get('/attachments/in-use').timeout(const Duration(seconds: 10));
      inUse = ((d['attachments'] as List?) ?? []).cast<Map<String, dynamic>>();
    } catch (_) {
      return;
    }
    if (inUse.isEmpty) return;
    try {
      final root = await getApplicationDocumentsDirectory();
      var downloaded = 0;
      // 多行引用同一文件（整单凭证=每行一行同内容引用）：同 key 只拉一次，各目录复用字节
      final bytesCache = <String, List<int>>{};
      Future<bool> one(Map<String, dynamic> a) async {
        final entity = '${a['entity'] ?? ''}';
        final id = '${a['id'] ?? ''}';
        final file = '${a['file'] ?? ''}';
        // 后端已规范化三元组，此处不再做 key 正则解析（此前前后端正则不一致会产生 // 空段路径）
        if (entity.isEmpty || id.isEmpty || file.isEmpty) return false;
        final dir = Directory('${root.path}/attachments/$entity/$id');
        final target = File('${dir.path}/$file');
        if (target.existsSync()) return false; // 已有副本
        final key = a['key'] ?? '$entity/$id/$file';
        Object? lastError;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            final bytes = bytesCache[key] ??
                await Api.instance.getRaw('/attachments/$key').timeout(const Duration(seconds: 12));
            if (bytes.isNotEmpty) {
              bytesCache[key] = bytes;
              if (!dir.existsSync()) dir.createSync(recursive: true);
              await target.writeAsBytes(bytes);
              return true;
            }
          } catch (e) {
            lastError = e;
            if (attempt < 2) await Future.delayed(Duration(seconds: 1 << attempt));
          }
        }
        // 单张失败跳过：下次同步再补
        appLog('sync', '附件下载失败 $entity/$id/$file: $lastError', level: 'error');
        return false;
      }
      // 并发 4 分批下载（对齐参考同步引擎下载策略）
      var idx = 0;
      while (idx < inUse.length) {
        final batch = inUse.skip(idx).take(4).toList();
        final results = await Future.wait(batch.map(one));
        downloaded += results.where((r) => r).length;
        idx += 4;
      }
      if (downloaded > 0) {
        appLog('sync', '已补齐在用附件本地副本 $downloaded 张', level: 'info');
        // 下载完成通知页面重读本地附件（账本图标/缩略图即时显示，不必手动刷新/多次同步）
        version.notifyListeners();
      }
    } catch (_) {}
  }

  /// 附件上传入队：页面添加附件后先落本地副本，再登记待上传（联网后由 sync() 编排统一上传）。
  /// 上传是同步引擎一部分，页面不直连云端；失败条目保留队列，下次同步自动重试。
  /// 即时上传防重入：一批上传进行中时不再重复触发（避免连续添加附件并发轰炸）
  static bool _attUploadLock = false;

  static Future<void> enqueueAttachmentUpload({
    required String entity,
    required String id,
    required String fileName,
  }) async {
    if (kIsWeb) return; // Web 无本地副本，页面直传云端
    try {
      final p = await SharedPreferences.getInstance();
      final list = p.getStringList(kPendingUploadsKey) ?? [];
      final entry = jsonEncode({'entity': entity, 'id': id, 'fileName': fileName});
      if (list.contains(entry)) return;
      list.add(entry);
      await p.setStringList(kPendingUploadsKey, list);
    } catch (_) {}
    // 即时上传：添加附件后立即触发一轮上传（不再等手动同步才传）——
    // 上传实时反馈；失败保留队列，由同步/下次重试兜底（离线可挂图不变）
    if (!_attUploadLock) {
      _attUploadLock = true;
      unawaited(uploadPendingAttachments().whenComplete(() => _attUploadLock = false));
    }
  }

  /// 同步编排第一步：上传待传附件（对齐参考 sync()：push 前先传附件，引用先写云端）。
  /// 并发 4 + 指数退避重试 3 次；单张失败静默保留队列，下次同步再传；不阻塞主流程。
  static Future<int> uploadPendingAttachments() async {
    if (kIsWeb) return 0;
    List<String> entries;
    try {
      final p = await SharedPreferences.getInstance();
      entries = p.getStringList(kPendingUploadsKey) ?? [];
    } catch (_) {
      return 0;
    }
    if (entries.isEmpty) return 0;
    var uploaded = 0;
    final failed = <String>[];
    Future<void> one(String entry) async {
      Map<String, dynamic> item;
      try {
        item = jsonDecode(entry) as Map<String, dynamic>;
      } catch (_) {
        return; // 脏条目直接丢弃
      }
      final entity = '${item['entity'] ?? ''}';
      final id = '${item['id'] ?? ''}';
      final fileName = '${item['fileName'] ?? ''}';
      if (entity.isEmpty || id.isEmpty || fileName.isEmpty) return;
      try {
        final root = await getApplicationDocumentsDirectory();
        final f = File('${root.path}/attachments/$entity/$id/$fileName');
        if (!f.existsSync()) return; // 本地副本已删（图随单据删除）→ 无需上传
        final bytes = await f.readAsBytes();
        Object? lastError;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            await Api.instance
                .uploadPhoto('/attachments?entity=$entity&id=$id', bytes, fileName)
                .timeout(const Duration(seconds: 20));
            uploaded++;
            return;
          } catch (e) {
            lastError = e;
            if (attempt < 2) await Future.delayed(Duration(seconds: 1 << attempt));
          }
        }
        failed.add(entry);
        appLog('sync', '附件上传失败 $entity/$id/$fileName: $lastError', level: 'error');
      } catch (_) {
        failed.add(entry);
      }
    }
    // 并发 4 分批上传
    var idx = 0;
    while (idx < entries.length) {
      final batch = entries.skip(idx).take(4).toList();
      await Future.wait(batch.map(one));
      idx += 4;
    }
    try {
      final p = await SharedPreferences.getInstance();
      if (failed.isEmpty) {
        await p.remove(kPendingUploadsKey);
      } else {
        await p.setStringList(kPendingUploadsKey, failed);
      }
    } catch (_) {}
    if (uploaded > 0) appLog('sync', '已上传附件 $uploaded 张', level: 'info');
    return uploaded;
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
    // 通知监听者（如「我的」页统计卡）：店铺切换后实时刷新，无需退出重进
    selectedClientChanged.notifyListeners();
  }

  /// 当前店铺切换通知器（ledger_page 切换/新建店铺时触发）
  static final ChangeNotifier selectedClientChanged = ChangeNotifier();

  /// 本地待推送变更数（local_changes 队列）
  static Future<int> pendingCount() async {
    if (kIsWeb) return 0;
    try {
      return (await LocalDb.getPendingChanges()).length;
    } catch (_) {
      return 0;
    }
  }

  /// 同步应用失败条数（pull 单条 apply 失败持久化记录）——「我的」页同步状态显示不一致用
  static Future<int> pullErrorCount() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (p.getStringList(kPullErrorsKey) ?? []).length;
    } catch (_) {
      return 0;
    }
  }

  /// 待上传附件数（入队未成功上传、保留队列下次同步重试）——「我的」页同步状态显示不一致用
  static Future<int> pendingUploadCount() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (p.getStringList(kPendingUploadsKey) ?? []).length;
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

  /// 首次全量同步（新设备/重装）：拉全部实体一次到位，比逐条 pull 快。
  /// 本地优先保护：putAll 会先清空本地 store 再写服务器快照——若存在**未推送成功**的本地
  /// upsert（push 失败/离线录入），服务器快照不含这些新记录，清空会抹掉本地数据。
  /// 因此覆盖前先收集本地待推送实体版本，覆盖后按本地版本合并回写（本地未推送=权威）。
  static Future<int> fullSync() async {
    if (kIsWeb) return 0;
    try {
      // 覆盖前收集：本地待推送 upsert 的实体当前本地版本（仅 upsert；delete 语义=本地也要删，无需保护）
      final pendingLocal = await _pendingUpsertRows();
      final d = await Api.instance.get('/sync/full');
      if (d == null) return 0;
      final clients = (d['clients'] as List?) ?? [];
      final items = (d['items'] as List?) ?? [];
      final categories = (d['categories'] as List?) ?? [];
      final accounts = (d['payment_accounts'] as List?) ?? [];
      final sales = (d['sales'] as List?) ?? [];
      final purchases = (d['purchases'] as List?) ?? [];
      final payments = (d['payments'] as List?) ?? [];
      final stockRows = (d['stocks'] as List?) ?? [];
      // 去单据化主结构：行级商品记录（每条商品=一条主记录）
      final saleItemRows = (d['sale_items'] as List?) ?? [];
      final purchaseItemRows = (d['purchase_items'] as List?) ?? [];
      await LocalDb.putAll('clients', clients.cast<Map<String, dynamic>>());
      await LocalDb.putAll('items', items.cast<Map<String, dynamic>>());
      await LocalDb.putAll('categories', categories.cast<Map<String, dynamic>>());
      await LocalDb.putAll('payment_accounts', accounts.cast<Map<String, dynamic>>());
      // 整单镜像仍写（历史/展示兼容），行级主记录另存，页面按行读取
      await LocalDb.putAll('sales', sales.cast<Map<String, dynamic>>());
      await LocalDb.putAll('purchases', purchases.cast<Map<String, dynamic>>());
      await LocalDb.putAll('payments', payments.cast<Map<String, dynamic>>());
      await LocalDb.putAll('sale_items', saleItemRows.cast<Map<String, dynamic>>());
      await LocalDb.putAll('purchase_items', purchaseItemRows.cast<Map<String, dynamic>>());
      await LocalDb.putAll('stocks', stockRows.cast<Map<String, dynamic>>());
      // 合并回写：本地未推送的 upsert（服务器没有/旧值）以本地版本覆盖，离线录入不丢
      for (final e in pendingLocal.entries) {
        if (e.value.isEmpty) continue;
        await LocalDb.upsertList(e.key, e.value);
      }
      final cursor = d['server_cursor'] as int? ?? 0;
      final p = await SharedPreferences.getInstance();
      await p.setInt(_cursorKey, cursor);
      await p.setBool(_fullDoneKey, true);
      await _markSynced();
      // 在用附件本地副本补齐已统一在 sync() 编排末尾执行（全量/增量同一入口）
      // 全量同步数量含全部实体（含分类、收款账户）——同步面板日志/统计口径与实体数一致
      return clients.length + items.length + categories.length + accounts.length +
          sales.length + purchases.length + payments.length;
    } catch (_) {
      _lastSyncFailed = true;
      return 0;
    }
  }

  /// 收集本地待推送 upsert 的实体当前版本（按 store 分组；仅 upsert——delete 无需保护）。
  /// fullSync 覆盖前调用；覆盖后用返回结果合并回写未推送成功的新增/修改。
  static Future<Map<String, List<Map<String, dynamic>>>> _pendingUpsertRows() async {
    final out = <String, List<Map<String, dynamic>>>{};
    try {
      final pending = await LocalDb.getPendingChanges();
      final want = <String, Set<String>>{};
      for (final ch in pending) {
        if ('${ch['action'] ?? 'upsert'}' != 'upsert') continue;
        final store = _storeOf('${ch['entity_type'] ?? ''}');
        if (store.isEmpty) continue;
        final id = '${ch['entity_sync_id'] ?? ''}';
        if (id.isEmpty) continue;
        (want[store] ??= {}).add(id);
      }
      for (final e in want.entries) {
        final rows = <Map<String, dynamic>>[];
        for (final id in e.value) {
          final row = await LocalDb.getOne(e.key, id);
          if (row != null) rows.add(row);
        }
        out[e.key] = rows;
      }
    } catch (_) {}
    return out;
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
      // 值类型是 Future<Set<String>>：putIfAbsent 缓存的是"查询未来的结果"，调用处 double await 解包
      final pendingDelete = <String, Future<Set<String>>>{};
      Future<Set<String>> pendingOf(String t) =>
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
          var applied = false;
          try {
            // 附件删除变更：其他端删了附件 → 本地同步删对应副本（引用变更流驱动跨端删除）
            if (entityType == 'attachment' && action == 'delete') {
              final root = await getApplicationDocumentsDirectory();
              final key = '${payload['file_key'] ?? payload['key'] ?? ''}';
              if (key.isNotEmpty) {
                // 优先用 payload 携带的 entity/id（新客户端），否则三前缀解析 key（兼容历史根级前缀）
                final entity = '${payload['entity'] ?? ''}';
                final eid = '${payload['id'] ?? ''}';
                final parsed = (entity.isNotEmpty && eid.isNotEmpty)
                    ? {'entity': entity, 'id': eid}
                    : _parseAttachmentKey(key);
                if (parsed != null) {
                  final f = File('${root.path}/attachments/${parsed['entity']}/${parsed['id']}/${key.split('/').last}');
                  if (f.existsSync()) f.deleteSync();
                }
              }
              applied = true;
            } else {
              final store = _storeOf(entityType);
              if (store.isEmpty) continue;
              // 行级商品记录（去单据化）：sale_item/purchase_item 合并进对应单据镜像的 items
              if (entityType == 'sale_item' || entityType == 'purchase_item') {
                final orderStore = entityType == 'sale_item' ? 'sales' : 'purchases';
                final orderId = '${payload['${entityType == 'sale_item' ? 'sale_id' : 'purchase_id'}'] ?? ''}';
                final rowId = id;
                final order = await LocalDb.getOne(orderStore, orderId);
                if (action == 'delete') {
                  // 删行：从单据镜像 items 移除该行；空则删单据（防空壳）
                  if (order != null) {
                    final items = ((order['items'] as List?) ?? []).cast<Map<String, dynamic>>();
                    final updated = items.where((it) => '${it['id']}' != rowId).toList();
                    if (updated.isEmpty) {
                      await LocalDb.deleteOne(orderStore, orderId);
                    } else {
                      final merged = Map<String, dynamic>.from(order)..['items'] = updated;
                      await LocalDb.upsertOne(orderStore, merged);
                    }
                  }
                } else {
                  // upsert：单据存在则合并该行，不存在则按订单头建仓（兼容历史整单 pull 已先行建单）
                  final items = ((order?['items'] as List?) ?? []).cast<Map<String, dynamic>>();
                  final others = items.where((it) => '${it['id']}' != rowId).toList();
                  others.add(payload);
                  final merged = Map<String, dynamic>.from(order ?? {})..['items'] = others;
                  if (order == null) {
                    merged['id'] = orderId;
                    merged['client_id'] = payload['client_id'] ?? '';
                    merged['client_name'] = payload['client_name'] ?? '';
                    merged['happened_at'] = payload['happened_at'] ?? '';
                    merged['note'] = payload['note'] ?? '';
                  }
                  await LocalDb.upsertOne(orderStore, merged);
                }
                applied = true;
              } else if (action == 'delete') {
                // 先清本地附件副本再删镜像：行级目录清理需读镜像 items 拿明细行 id，
                // 镜像先删则读不到 → attachments/sale_item/{lineId}/ 漏删残留孤儿副本
                await cleanupLocalAttachmentsOf(entityType, id);
                await LocalDb.deleteOne(store, id);
                applied = true;
              } else {
                // 软删（client/item deleted_at 非空）→ 本地删行（历史单据有快照不丢）
                final deletedAt = payload['deleted_at'];
                if (deletedAt != null && '$deletedAt'.isNotEmpty) {
                  await LocalDb.deleteOne(store, id);
                  applied = true;
                } else {
                  // 本地已软删但推送尚未落地：跳过 upsert，保留本地删除状态
                  if (await (await pendingOf(entityType)).contains(id)) continue;
                  // 本地删除兜底：本地已有该实体且已软删（tombstone），服务端活跃记录不得覆盖——
                  // 本地删除是权威，即使服务端删除未生效（推送被拒/后端旧版），重启也不复活
                  final local = await LocalDb.getOne(store, id);
                  if (local != null && '${local['deleted_at'] ?? ''}'.isNotEmpty) continue;
                  await LocalDb.upsertOne(store, payload);
                  applied = true;
                }
              }
            }
            if (applied) {
              total++;
              // 同实体此前 apply 失败记录自动清除（对齐参考 SyncErrorStore：新 change 应用成功即 resolve）
              await _clearPullError(entityType, id);
            }
          } catch (e) {
            // 单条 apply 失败不阻塞整页：记录错误并跳过，游标照常推进（对齐参考 SyncErrorStore）
            await _recordPullError(entityType, id, e);
          }
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
      _lastSyncFailed = true;
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
      // 本地库只读/队列写不进时，删除标记已存 SharedPreferences（元素格式 `id@固定时间戳`）：
      // 合并为待推送变更（绕只读队列）。updated_at 用固定 ts——同一删除每次推送都是同一时间戳，
      // 服务端 LWW 判定幂等（不再每次产生新变更流 → 修"一直同步/日志刷屏"）
      final extra = <Map<String, dynamic>>[];
      var delEntries = <String>[];
      try {
        final p = await SharedPreferences.getInstance();
        delEntries = p.getStringList(kDeletedItemsKey) ?? [];
        for (final entry in delEntries) {
          final sep = entry.lastIndexOf('@');
          final did = sep > 0 ? entry.substring(0, sep) : entry;
          final ts = sep > 0 ? entry.substring(sep + 1) : DateTime.now().toUtc().toIso8601String();
          extra.add({
            'entity_type': 'item', 'entity_sync_id': did, 'action': 'upsert',
            'updated_at': ts, 'payload': {'id': did, 'deleted_at': ts},
          });
        }
      } catch (_) {}
      if (pending.isEmpty && extra.isEmpty) return 0;
      final did = await deviceId();
      final changes = [
        ...extra,
        ...pending.map((x) {
          final m = Map<String, dynamic>.from(x);
          m.remove('id'); // 队列内部 id 不传服务端
          return m;
        }),
      ];
      final d = await Api.instance.post('/sync/push', {'device_id': did, 'changes': changes});
      if (d == null) return 0;
      final accepted = d['accepted'] as int? ?? 0;
      // 持久删除集合：仅清除"本地库已确实删掉/软删落库"的条目；
      // 本地库只读导致 tombstone 未写入、行仍活跃的条目必须保留（含原时间戳）——
      // 否则重启后 _load 失去过滤依据，已删商品复活（服务端已删也不影响：集合仅本地过滤用）
      if (extra.isNotEmpty && accepted >= changes.length) {
        try {
          final stillLocal = <String>[];
          for (final entry in delEntries) {
            final sep = entry.lastIndexOf('@');
            final id2 = sep > 0 ? entry.substring(0, sep) : entry;
            final local = await LocalDb.getOne('items', id2);
            if (local != null && '${local['deleted_at'] ?? ''}'.isEmpty) stillLocal.add(entry);
          }
          final p = await SharedPreferences.getInstance();
          if (stillLocal.isEmpty) {
            await p.remove(kDeletedItemsKey);
          } else if (stillLocal.length != delEntries.length) {
            await p.setStringList(kDeletedItemsKey, stillLocal);
          }
        } catch (_) {}
      }
      // 服务端时间校准：设备时钟偏慢会让 LWW 拒绝本设备写入（删除/改分类在服务端不生效，
      // pull 又拉回旧值）。用服务器时间给未推送成功的条目重刷 updated_at，下次推送必能胜出。
      final serverTime = DateTime.tryParse('${d['server_time'] ?? ''}')?.toUtc();
      final offset = serverTime?.difference(DateTime.now().toUtc());
      var removed = 0;
      final removedIds = <int>{};
      for (final x in pending) {
        if (removed >= accepted) break;
        final id = x['id'];
        if (id is int) {
          await LocalDb.removePendingChange(id);
          removed++;
          removedIds.add(id);
        }
      }
      if (offset != null) {
        for (final x in pending) {
          final id = x['id'];
          if (id is! int || removedIds.contains(id)) continue;
          final ts = DateTime.tryParse('${x['updated_at'] ?? ''}');
          if (ts == null) continue;
          await LocalDb.retimePendingChange(id, ts.toUtc().add(offset).toIso8601String());
        }
      }
      // 推送成功后顺便拉取一次（其他设备的变更）
      await pullChanges();
      return accepted;
    } catch (_) {
      _lastSyncFailed = true;
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

  /// 用户资料同步（对齐参考架构 syncMyProfile）：拉 /auth/me 把显示名/头像回写本地。
  /// 头像按 avatar_version 比对，有新版才下载（avatar_cache 内部 bump avatarChanged 通知页面）。
  /// 挂 sync() 编排末尾，也由 WS profile_change 事件独立触发；失败静默（保留旧缓存）。
  static Future<bool> syncMyProfile() async {
    if (kIsWeb) return false;
    try {
      final d = await Api.instance.get('/auth/me');
      final u = d['user'] as Map<String, dynamic>?;
      if (u == null) return false;
      final name = '${u['display_name'] ?? u['username'] ?? ''}';
      if (name.isNotEmpty) await Api.instance.setUsername(name);
      await Api.instance.setAccount('${u['username'] ?? ''}');
      final avatarState = await syncAvatarCache(u);
      if (avatarState != null) await Api.instance.setAvatar(avatarState);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 触发一次增量拉取（账户等以服务端全量覆盖保存成功后调用：
  /// 服务端已入变更流，本机镜像需 pull 合并到最新）
  static void schedulePullNow() {
    if (kIsWeb) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      pullChanges();
    });
  }

  /// 启动/回前台同步：首次 full，后续增量 pull + 推送待发（静默）。
  /// 同步中会通知 status 监听者（「我的」页实时显示 同步中/已同步/同步失败）。
  /// 编排对齐参考 sync()：①先上传待传附件（引用先写云端，push 单据时服务端才能带上附件）
  /// ②push 本地变更（LWW 先落服务端，避免 pull 把旧值覆盖本地排队编辑的镜像）
  /// ③全量/增量拉取 ④下载在用附件本地副本 ⑤资料同步。
  static Future<void> sync() async {
    if (kIsWeb) return;
    _lastSyncFailed = false;
    _setStatus('syncing');
    var pulled = 0;
    var pushed = 0;
    try {
      // ① 上传待传附件（失败不阻塞主流程，单张静默保留队列下次再传）
      await uploadPendingAttachments();
      // ② push 本地变更（内部成功后顺带拉取一次其他设备变更）
      pushed = await pushPending();
      // ③ 全量/增量拉取：未全量过、或本地库全空（数据被清但游标残留）→ 强制全量拉齐，
      // 无需用户手动干预
      final done = await isFullDone();
      final localEmpty = done ? (await LocalDb.getAllByName('items')).isEmpty : false;
      if (!done || localEmpty) {
        pulled = await fullSync();
      } else {
        pulled = await pullChanges();
      }
      appLog('sync', '同步完成：拉取 $pulled 条、推送 $pushed 条', level: 'info');
      // ④ 在用附件本地副本补齐（附件不走同步流；本地副本被清理后离线不可见——违背本地优先）：
      // **await 等待附件下载完，同步中的动画/状态行才消失**（完全同步之后再消失）；
      // 单张失败内部静默跳过，下次同步自动重补，不阻塞主流程
      await downloadInUseAttachments();
      // ⑤ 资料（显示名/头像版本）同步对齐参考 sync() 编排：实体+附件完成后统一 syncMyProfile
      await syncMyProfile();
    } catch (e) {
      _lastSyncFailed = true;
      appLog('sync', '同步失败: ${e.toString().split('\n').first}', level: 'error');
      // 任一异常都不外抛（bottom_shell 无 await 调用，抛了就成 unhandled error）
    } finally {
      _setStatus(_lastSyncFailed ? 'error' : 'idle');
    }
  }

  /// 实体类型 → 本地 store 名映射
  static String _storeOf(String entityType) {
    switch (entityType) {
      case 'client': return 'clients';
      case 'item': return 'items';
      case 'category': return 'categories';
      case 'payment_account': return 'payment_accounts';
      case 'sale': return 'sales';
      case 'purchase': return 'purchases';
      case 'payment': return 'payments';
     // 行级商品记录（去单据化）：同 store，行自包含（client_id/happened_at/note/amount 都在行上）
      case 'sale_item': return 'sale_items';
      case 'purchase_item': return 'purchase_items';
      default: return '';
    }
  }

  /// 附件 key → {entity,id}（三前缀兼容，与后端 parseAttachmentKey 同款）：
  /// taozhu/images/attachments/{entity}/{id}/{file} | taozhu/attachments/... | {entity}/{id}/{file}
  /// 历史根级前缀（如 sale/s1/a.jpg）不再匹配失败导致本地副本删不掉。
  static Map<String, String>? _parseAttachmentKey(String key) {
    final m1 = RegExp(r'^taozhu/images/attachments/([a-z_]+)/([^/]+)/[^/]+$').firstMatch(key);
    if (m1 != null) return {'entity': m1.group(1)!, 'id': m1.group(2)!};
    final m2 = RegExp(r'^(?:taozhu/attachments/)?([a-z_]+)/([^/]+)/[^/]+$').firstMatch(key);
    if (m2 != null && const ['sale', 'purchase', 'payment', 'sale_item', 'purchase_item'].contains(m2.group(1))) {
      return {'entity': m2.group(1)!, 'id': m2.group(2)!};
    }
    return null;
  }

  /// 清理本地附件副本（单据级目录 + 明细行级目录）：
  /// 本地副本按 attachments/{entity}/{id}/ 组织；行级 = attachments/sale_item|purchase_item/{lineId}/。
  /// **必须在本地镜像删除之前调用**——明细行级目录定位依赖镜像 items 里的行 id
  /// （sale/purchase 的镜像一旦删除就读不到行）。删除引用流驱动：服务端删 → 其他端 pull 删；本端删 → 删镜像前清副本。
  static Future<void> cleanupLocalAttachmentsOf(String entityType, String id) async {
    try {
      final root = await getApplicationDocumentsDirectory();
      final base = Directory('${root.path}/attachments');
      if (!base.existsSync()) return;
      // 单据级目录
      final orderDir = Directory('${base.path}/$entityType/$id');
      if (orderDir.existsSync()) {
        try { orderDir.deleteSync(recursive: true); } catch (_) {}
      }
      // 行级目录：从本地镜像读取明细行 id（删除前的快照）
      final store = _storeOf(entityType);
      if (store == 'sales' || store == 'purchases') {
        final lineEntity = store == 'sales' ? 'sale_item' : 'purchase_item';
        final local = await LocalDb.getOne(store, id);
        final items = (local?['items'] as List?) ?? [];
        for (final it in items) {
          if (it is! Map) continue;
          final lineId = '${it['id'] ?? ''}';
          if (lineId.isEmpty) continue;
          final lineDir = Directory('${base.path}/$lineEntity/$lineId');
          if (lineDir.existsSync()) {
            try { lineDir.deleteSync(recursive: true); } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  /// 同步完成后扫描清理本地孤儿附件副本：attachments/{entity}/{id}/ 对照本地镜像在用实体
  /// （sale/purchase/payment 单据 + sale_item/purchase_item 明细行），无主目录 = 单据删除残留
  /// 等历史孤儿 → 自动删除。本地附件目录恒等于在用实体集合（面板"全部附件 本地"计数随之归零）；
  /// 补充删除入口即时清理的遗漏（存量孤儿 / 历史版本残留）。
  static Future<void> cleanupOrphanLocalAttachments() async {
    try {
      if (kIsWeb) return;
      final root = await getApplicationDocumentsDirectory();
      final base = Directory('${root.path}/attachments');
      if (!base.existsSync()) return;
      // 在用 id 集合：entity -> Set<id>
      final inUse = <String, Set<String>>{};
      void add(String entity, String id) {
        if (id.isEmpty) return;
        (inUse[entity] ??= {}).add(id);
      }
      Future<void> collect(List<Map<String, dynamic>> orders, String orderEntity, String lineEntity) async {
        for (final o in orders) {
          add(orderEntity, '${o['id'] ?? ''}');
          final items = (o['items'] as List?) ?? [];
          for (final it in items) {
            if (it is Map) add(lineEntity, '${it['id'] ?? ''}');
          }
        }
      }
      await collect(await LocalDb.getAll('sales'), 'sale', 'sale_item');
      await collect(await LocalDb.getAll('purchases'), 'purchase', 'purchase_item');
      await collect(await LocalDb.getAll('payments'), 'payment', 'payment');
      // 扫描 attachments/ 下 entity 目录，清掉不在用集合的 id 目录
      await for (final eDir in base.list(followLinks: false)) {
        if (eDir is! Directory) continue;
        final entity = eDir.uri.pathSegments.last;
        final have = inUse[entity];
        if (have == null) {
          // 未知实体目录（脏残留）整删
          try { eDir.deleteSync(recursive: true); } catch (_) {}
          continue;
        }
        await for (final idDir in eDir.list(followLinks: false)) {
          if (idDir is! Directory) continue;
          final id = idDir.uri.pathSegments.last;
          if (!have.contains(id)) {
            try { idDir.deleteSync(recursive: true); } catch (_) {}
          }
        }
        try { if (eDir.listSync().isEmpty) eDir.deleteSync(); } catch (_) {}
      }
    } catch (_) {}
  }

  /// pull 单条 apply 失败记录（持久化，UI 可追溯）：不阻塞整页游标（对齐参考 SyncErrorStore 语义）。
  static const int _maxPullErrors = 50;

  static Future<void> _recordPullError(String entityType, String id, Object e) async {
    try {
      final p = await SharedPreferences.getInstance();
      final list = p.getStringList(kPullErrorsKey) ?? [];
      list.add(jsonEncode({
        'entity_type': entityType,
        'entity_sync_id': id,
        'error': e.toString().split('\n').first,
        'ts': DateTime.now().toIso8601String(),
      }));
      if (list.length > _maxPullErrors) list.removeRange(0, list.length - _maxPullErrors);
      await p.setStringList(kPullErrorsKey, list);
    } catch (_) {}
    appLog('sync', 'pull apply 失败 $entityType/$id: ${e.toString().split('\n').first}', level: 'error');
  }

  /// 同实体后续 apply 成功 → 清除历史失败记录（对齐参考 SyncErrorStore：新 change 应用成功即 resolve）。
  static Future<void> _clearPullError(String entityType, String id) async {
    try {
      final p = await SharedPreferences.getInstance();
      final list = p.getStringList(kPullErrorsKey) ?? [];
      final kept = list.where((x) {
        try {
          final m = jsonDecode(x) as Map<String, dynamic>;
          return '${m['entity_type']}' != entityType || '${m['entity_sync_id']}' != id;
        } catch (_) {
          return true;
        }
      }).toList();
      if (kept.length != list.length) await p.setStringList(kPullErrorsKey, kept);
    } catch (_) {}
  }
}