import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart' show ChangeNotifier, kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'theme.dart';
import 'avatar_cache.dart';
import 'local_db.dart';
import 'log.dart';
import 'utils/money.dart';

/// 商品持久删除集合 key（SharedPreferences 独立存储）：本地库只读/写失败时删除标记跨重启保留，
/// 且 pushPending 合并该集合推送服务端（绕过只读队列）。与 items_page 共用。
const kDeletedItemsKey = 'taozhu_deleted_items';

/// 待上传附件队列 key（SharedPreferences JSON 数组 [{entity,id,fileName}]）：
/// 页面添加附件先落本地副本再入队，sync() 编排统一上传（附件上传是同步引擎一部分）。
const kPendingUploadsKey = 'taozhu_pending_uploads';
/// 附件删除墓碑表（本地持久化）：所有删除附件/删行/删单路径写入 {entity, entity_id, file}，
/// pull 全量刷新先把命中墓碑的三元组剔除——对齐参考实现 CouchDB 墓碑语义：
/// 删除永胜、已删引用绝不被快照复活（比内存 pendingDel 更强：覆盖删行/删单这类
/// 没有 attachment 删除变更的路径）；服务器确认删除（in-use 快照已无该三元组）后清除墓碑。
const kDeletedAttachmentsStore = 'deleted_attachments';

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

  /// AI 配置变更通知器：服务器广播 ai_config（其他端改了服务商/能力绑定）→ AI 设置页监听后重新拉取
  static final ChangeNotifier aiConfigChanged = ChangeNotifier();

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
  /// 同时把三元组持久化到本地 attachment_refs store（离线清理页按本地表 basename 判定孤儿，
  /// 对齐参考实现本地 transaction_attachments 范式，不依赖网络）。
  static Future<void> downloadInUseAttachments() async {
    if (kIsWeb) return;
    List<Map<String, dynamic>> inUse;
    try {
      // 在用列表拉取重试 2 次（网络抖动/服务器 R2 扫描慢偶发超时——失败静默会导致本地引用表
      // 与物理副本停在旧值，"本地91/服务器95 差4/重置没用"的直接根因）
      Map<String, dynamic> d = {};
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          d = await Api.instance.get('/attachments/in-use').timeout(const Duration(seconds: 25));
          break;
        } catch (e) {
          if (attempt < 2) {
            await Future.delayed(Duration(seconds: 1 << attempt));
          } else {
            rethrow;
          }
        }
      }
      inUse = ((d['attachments'] as List?) ?? []).cast<Map<String, dynamic>>();
      // 本地删除墓碑（deleted_attachments）：所有删除附件/删行/删单路径写入，
      // pull 全量刷新先把命中墓碑的三元组剔除——删除永胜，绝不被旧快照复活
      // （对齐参考实现 CouchDB 墓碑语义；比内存 pendingDel 覆盖更全：删行删单元
      //  无 attachment 删除变更，只有墓碑能挡住"删行后行级引用被 pull 写回"）
      final tombstones = <String>{};
      try {
        for (final t in await LocalDb.getAll(kDeletedAttachmentsStore)) {
          final e = '${t['entity'] ?? ''}';
          final i = '${t['entity_id'] ?? ''}';
          final f = '${t['file'] ?? ''}';
          if (e.isNotEmpty && i.isNotEmpty && f.isNotEmpty) tombstones.add('$e/$i/${f.split('/').last}');
        }
      } catch (_) {}
      // 持久化在用三元组：本地 attachment_refs store（每次同步全量刷新，删除的引用随之消失）
      // key=服务器真实 file_key（新旧格式都可能：旧格式化含实体段、新格式 md5-only）——
      // 删除时按真实 key 匹配服务器引用行（重构的新格式 key 匹配不到旧格式存量行）
      var refs = inUse
          .map((a) => {
                'id': '${a['entity'] ?? ''}/${a['id'] ?? ''}/${a['file'] ?? ''}',
                'entity': a['entity'] ?? '',
                'entity_id': a['id'] ?? '',
                'file': a['file'] ?? '',
                'key': a['key'] ?? '',
              })
          .where((r) => r['entity'] != '' && r['entity_id'] != '' && r['file'] != '')
          .where((r) => !tombstones.contains('${r['entity']}/${r['entity_id']}/${r['file']}'))
          .toList();
      // 待上传队列中的本地登记（添加附件立即可见，还没传到服务器/已传但 in-use 未回）：
      // 合并刷新不能把它们冲掉，否则图标"添加后灭一次、上传成功才亮"——本地优先应始终亮。
      final pendingUploads = <String>{};
      try {
        final p = await SharedPreferences.getInstance();
        pendingUploads.addAll((p.getStringList(kPendingUploadsKey) ?? [])
            .map((e) => jsonDecode(e))
            .whereType<Map<String, dynamic>>()
            .map((m) => '${m['entity'] ?? ''}/${m['id'] ?? ''}/${'${m['fileName'] ?? ''}'.split('/').last}')
            .toSet());
        if (pendingUploads.isNotEmpty) {
          final locals = await LocalDb.getAll('attachment_refs');
          for (final r in locals) {
            final id3 = '${r['entity'] ?? ''}/${r['entity_id'] ?? ''}/${'${r['file'] ?? ''}'.split('/').last}';
            if (!pendingUploads.contains(id3)) continue;
            if (tombstones.contains(id3)) continue;
            if (!refs.any((x) => '${x['id']}' == id3)) refs.add(r);
          }
        }
      } catch (_) {}
      // 本地引用表对齐（服务器在用的规范化三元组全量刷新）：
      // - 服务器引用 = 权威在册（已由上传成功即清队列 + 变更流 upsert/delete 驱动）；
      // - 本地已有但服务器已无的行随刷新消失（残留引用收敛，修"本地47/服务器32 对不上"）；
      // - 删除方向安全：本地删过但服务器未删的行被墓碑剔除（不复活）；
      // - 待上传队列中的本地登记（上传失败/未上传）由上方 pendingUploads 合并保护（不冲掉）
      try {
        final merged = List<Map<String, dynamic>>.from(refs);
        final ids = { for (final r in merged) '${r['entity']}/${r['entity_id']}/${r['file']}' };
        // 待上传但服务器未回的行保留（上传中/失败的本地登记；宁留勿丢）
        for (final r in await LocalDb.getAll('attachment_refs')) {
          final id3 = '${r['entity'] ?? ''}/${r['entity_id'] ?? ''}/${'${r['file'] ?? ''}'.split('/').last}';
          if (ids.contains(id3)) continue;
          if (pendingUploads.isNotEmpty && pendingUploads.contains(id3)) {
            merged.add(r);
            ids.add(id3);
            continue;
          }
          // 本地仍有物理副本的行也保留：识别即挂载草稿（提交前不入队，0.17.334 终局）靠副本
          // 证明"用户添加过"，不能被服务器快照冲掉——否则提交后上传报"本地副本缺失"、
          // 查看器看不到（用户反馈"添加之后单个交易看不到附件"的直接根因）
          try {
            final f = '${r['file'] ?? ''}'.split('/').last;
            final root = await getApplicationDocumentsDirectory();
            if (f.isNotEmpty && File('${root.path}/attachments/$f').existsSync()) {
              merged.add(r);
              ids.add(id3);
            }
          } catch (_) {}
        }
        await LocalDb.putAll('attachment_refs', merged);
      } catch (_) {}
      // 墓碑清理：服务器 in-use 快照已不含该三元组 = 删除已同步确认（服务器引用行已删），
      // 墓碑使命完成可清除（对齐参考实现 CouchDB 墓碑在复制确认后压缩）；仅清"服务器已无"
      // 的墓碑——服务器仍下发说明删除还没传播完，墓碑继续挡复活
      try {
        final serverIds = <String>{
          for (final a in inUse)
            '${a['entity'] ?? ''}/${a['id'] ?? ''}/${'${a['file'] ?? ''}'.split('/').last}',
        };
        final rows = await LocalDb.getAll(kDeletedAttachmentsStore);
        for (final t in rows) {
          final e = '${t['entity'] ?? ''}';
          final i = '${t['entity_id'] ?? ''}';
          final f = '${t['file'] ?? ''}';
          if (e.isEmpty || i.isEmpty || f.isEmpty) continue;
          if (!serverIds.contains('$e/$i/${f.split('/').last}')) {
            await LocalDb.deleteOne(kDeletedAttachmentsStore, '$e/$i/$f');
          }
        }
      } catch (_) {}
      // in-use 已确认包含的待上传条目 → 从队列移除（上传成功且服务器已落引用行；
      // 未含的保留在队列，下次合并保护继续生效——图标"添加后灭一次"根因修复）
      try {
        final p = await SharedPreferences.getInstance();
        final list = p.getStringList(kPendingUploadsKey) ?? [];
        if (list.isNotEmpty) {
          final inUseIds = refs.map((r) => '${r['entity']}/${r['entity_id']}/${'${r['file'] ?? ''}'.split('/').last}').toSet();
          final next = list.where((e) {
            try {
              final m = jsonDecode(e) as Map<String, dynamic>;
              final id3 = '${m['entity'] ?? ''}/${m['id'] ?? ''}/${'${m['fileName'] ?? ''}'.split('/').last}';
              return !inUseIds.contains(id3);
            } catch (_) {
              return false; // 脏条目丢弃
            }
          }).toList();
          if (next.length != list.length) {
            await p.setStringList(kPendingUploadsKey, next);
          }
        }
      } catch (_) {}
    } catch (e) {
      // 在用列表拉取失败：本地引用表保持旧值（不覆盖为 0），下次同步再刷新；
      // 记日志便于定位"本地84/服务器95 不收敛"类问题（in-use 超时/网络失败都会静默走到这里）
      appLog('sync', '在用附件列表拉取失败（本地引用表未刷新）: ${_friendlyError(e)}', level: 'error');
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
        // 本地副本按内容存公共目录 attachments/{file}（file=md5.jpg；同图多实体共享一份，
        // 对齐参考实现"同图一份物理文件"）；附件引用表仍按实体各一行（每个商品/单据算一个附件）
        final target = File('${root.path}/attachments/$file');
        if (target.existsSync()) return false; // 已有副本（同图共享）
        final key = a['key'] ?? '$entity/$id/$file';
        Object? lastError;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            final bytes = bytesCache[key] ??
                await Api.instance.getRaw('/attachments/$key').timeout(const Duration(seconds: 12));
            if (bytes.isNotEmpty) {
              bytesCache[key] = bytes;
              if (!target.parent.existsSync()) target.parent.createSync(recursive: true);
              await target.writeAsBytes(bytes);
              return true;
            }
          } catch (e) {
            lastError = e;
            if (attempt < 2) await Future.delayed(Duration(seconds: 1 << attempt));
          }
        }
        // 单张失败跳过：下次同步再补；404（云端文件已删/引用残留）→ 顺手清除本地在用引用行，
        // 避免本地表把坏引用当在用（清理页误判）——服务端 in-use 已自愈，下一轮全量刷新不再下发
        appLog('sync', '附件下载失败 $entity/$id/$file: $lastError', level: 'error');
        if ('$lastError'.contains('404')) {
          try {
            await LocalDb.deleteOne('attachment_refs', '$entity/$id/$file');
          } catch (_) {}
        }
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
    // 本地引用表立即登记：图标/计数无需等上传+同步（本地优先：离线添加也立即可见）。
    // 行 id 用 entity/id/fileName（与同步全量刷新 putAll 的 id 拼法一致，幂等覆盖）；
    // key 按新格式内容 key 命名（同图一份；旧库/存量格式由同步以服务器真实 key 刷新覆盖）
    try {
      // 用户删除过该附件又再次添加：删除墓碑作废（新添加生效，不能再挡本次挂载）
      await clearTombstone(entity: entity, id: id, file: fileName);
      await LocalDb.upsertOne('attachment_refs', {
        'id': '${entity.trim()}/${id.trim()}/${fileName.trim()}',
        'entity': entity.trim(),
        'entity_id': id.trim(),
        'file': fileName.trim(),
        'key': 'taozhu/images/attachments/$fileName',
      });
    } catch (_) {}
    version.notifyListeners(); // 账本附件图标计数/列表即时联动（无需等下一次同步）
    // 即时上传：添加附件后立即触发一轮上传（不再等手动同步才传）——
    // 上传实时反馈；失败保留队列，由同步/下次重试兜底（离线可挂图不变）
    if (!_attUploadLock) {
      _attUploadLock = true;
      unawaited(uploadPendingAttachments().whenComplete(() => _attUploadLock = false));
    }
  }

  /// 记录附件删除墓碑（本地持久化）：删除附件/删行/删单后写入 {entity, entity_id, file}，
  /// pull 全量刷新会先剔除墓碑命中的三元组——删除永胜，不会被旧快照复活。
  /// 同实体同文件被用户重新添加（enqueueAttachmentUpload）时清除墓碑（新添加=原删除作废）。
  /// 服务器确认删除（in-use 快照已无该三元组）后由 downloadInUseAttachments 清理墓碑。
  static Future<void> tombstoneDeletedAttachment({
    required String entity,
    required String id,
    required String file,
  }) async {
    try {
      if (kIsWeb) return; // Web 无本地库：直连服务器删除，无本地快照复活窗口
      final f = file.split('/').last;
      if (f.isEmpty) return;
      await LocalDb.upsertOne(kDeletedAttachmentsStore, {
        'id': '$entity/$id/$f',
        'entity': entity,
        'entity_id': id,
        'file': f,
        'deleted_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {}
  }

  /// 上传入队：同步移除同三元组删除墓碑（用户删除后又重新添加 = 删除作废，新添加生效）
  static Future<void> clearTombstone({
    required String entity,
    required String id,
    required String file,
  }) async {
    try {
      await LocalDb.deleteOne(kDeletedAttachmentsStore, '$entity/$id/${file.split('/').last}');
    } catch (_) {}
  }

  /// 删除附件时调用：从待上传队列移除对应条目（否则已删引用会在下次上传时"复活"——
  /// 服务器同内容幂等同 key，删除后队列残留条目再传一遍 = 引用又写回服务器）
  static Future<void> removePendingUpload({
    required String entity,
    required String id,
    required String fileName,
  }) async {
    try {
      final p = await SharedPreferences.getInstance();
      final list = p.getStringList(kPendingUploadsKey) ?? [];
      final entry = jsonEncode({'entity': entity, 'id': id, 'fileName': fileName});
      if (!list.contains(entry)) return;
      final next = list.where((e) => e != entry).toList();
      await p.setStringList(kPendingUploadsKey, next);
    } catch (_) {}
  }

  /// 上传前过滤"实体已从本地库删除"的残留待传条目：行/单被删（删行重录/删单/他端删除已同步）后，
  /// 其附件引用若无本地实体支撑，重传只会让服务器引用"删了又复活"（in-use 自愈再删=无限循环）。
  /// 本地库是权威：本地没有该实体 = 不该再上传。仅返回仍有效的条目（并同步把失效条目清出队列）。
  static Future<List<String>> _filterStalePendingUploads(List<String> entries) async {
    if (kIsWeb) return entries;
    try {
      final saleIds = <String>{};
      final saleLineIds = <String>{};
      final purchaseIds = <String>{};
      final purchaseLineIds = <String>{};
      final payIds = <String>{};
      try {
        for (final s in await LocalDb.getAll('sale_items')) {
          final oid = '${s['sale_id'] ?? ''}';
          final rid = '${s['id'] ?? ''}';
          if (oid.isNotEmpty) saleIds.add(oid);
          if (rid.isNotEmpty) saleLineIds.add(rid);
        }
        for (final p in await LocalDb.getAll('purchase_items')) {
          final oid = '${p['purchase_id'] ?? ''}';
          final rid = '${p['id'] ?? ''}';
          if (oid.isNotEmpty) purchaseIds.add(oid);
          if (rid.isNotEmpty) purchaseLineIds.add(rid);
        }
        for (final p in await LocalDb.getAll('payments')) {
          final pid = '${p['id'] ?? ''}';
          if (pid.isNotEmpty) payIds.add(pid);
        }
      } catch (_) {}
      // 本地库为空（从未同步/全新设备）→ 不做过滤（宁留勿丢：可能实体在服务器尚未拉回）
      if (saleIds.isEmpty && saleLineIds.isEmpty && purchaseIds.isEmpty &&
          purchaseLineIds.isEmpty && payIds.isEmpty) {
        return entries;
      }
      final stale = <String>[];
      final kept = <String>[];
      // 删除墓碑：实体仍在但附件已被删（删附件未删行）的残留条目也不传——否则重传复活引用
      final tomb = <String>{};
      try {
        for (final t in await LocalDb.getAll(kDeletedAttachmentsStore)) {
          final e = '${t['entity'] ?? ''}';
          final i = '${t['entity_id'] ?? ''}';
          final f = '${t['file'] ?? ''}';
          if (e.isNotEmpty && i.isNotEmpty && f.isNotEmpty) tomb.add('$e/$i/${f.split('/').last}');
        }
      } catch (_) {}
      for (final entry in entries) {
        try {
          final m = jsonDecode(entry) as Map<String, dynamic>;
          final e = '${m['entity'] ?? ''}';
          final i = '${m['id'] ?? ''}';
          final f = '${'${m['fileName'] ?? ''}'.split('/').last}';
          final exists = switch (e) {
            'sale' => saleIds.contains(i),
            'sale_item' => saleLineIds.contains(i),
            'purchase' => purchaseIds.contains(i),
            'purchase_item' => purchaseLineIds.contains(i),
            'payment' => payIds.contains(i),
            _ => true, // 未知实体类型：保留
          };
          if (exists && !tomb.contains('$e/$i/$f')) {
            kept.add(entry);
          } else {
            stale.add(entry);
            appLog('sync', '附件队列清理：实体已删除或已有删除墓碑，移除待传 $e/$i/$f', level: 'info');
            try {
              await LocalDb.deleteOne('attachment_refs', '$e/$i/$f');
            } catch (_) {}
          }
        } catch (_) {
          kept.add(entry); // 脏条目保留让原有解析逻辑处理
        }
      }
      if (stale.isNotEmpty) {
        try {
          final p = await SharedPreferences.getInstance();
          await p.setStringList(kPendingUploadsKey, kept);
        } catch (_) {}
      }
      return kept;
    } catch (_) {
      return entries; // 过滤失败时按原样上传（宁留勿丢）
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
    // 实体存在性过滤：对应行/单已从本地库删除（删行重录/删单/他端删除同步后）的残留条目不重传——
    // 否则每次 sync 上传又写回服务器引用，而服务器 in-use 自愈（实体已删引清）再删 = "一直重复推送"
    entries = await _filterStalePendingUploads(entries);
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
        // 本地副本按内容存公共目录 attachments/{file}（同图一份，对齐参考实现）；
        // 旧版按实体目录存的存量副本（attachments/{entity}/{id}/{file}）兼容回退
        var f = File('${root.path}/attachments/$fileName');
        if (!f.existsSync()) {
          final old = File('${root.path}/attachments/$entity/$id/$fileName');
          if (old.existsSync()) f = old;
        }
        if (!f.existsSync()) {
          // 本地副本缺失：不静默丢弃——记日志并保留队列（可能是路径/挂载不一致，待排查；
          // 宁留勿丢：若此时清空整队列，其他待传附件也一并丢失 = "待推送 0 但服务器没收齐"）
          appLog('sync', '附件本地副本缺失，暂不上传：$entity/$id/$fileName（保留队列，待核实）', level: 'error');
          failed.add(entry);
          return;
        }
        final bytes = await f.readAsBytes();
        Object? lastError;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            await Api.instance
                .uploadPhoto('/attachments?entity=$entity&id=$id', bytes, fileName)
                .timeout(const Duration(seconds: 20));
            uploaded++;
            appLog('sync', '附件上传成功：$entity/$id/$fileName', level: 'info');
            // 上传成功立即清队列（对齐参考架构：上传即成功，无 in-use 二次确认）：
            // 服务器引用已落（POST 已写引用表+变更流），本端引用行已在入队时写本地，
            // 不再等待 downloadInUseAttachments 确认——否则成功条目恒留队列，
            // 每次同步重传（"同一条显示很多遍"+本地引用残留 47 vs 服务器 32 根因）
            await removePendingUpload(entity: entity, id: id, fileName: fileName);
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
    // 上传结果不立即清空待上传队列：成功条目保留，由 downloadInUseAttachments 确认
    // in-use 已含该引用后逐条移除（否则合并保护失效，putAll([]) 冲掉已登记行 → 图标闪烁）；
    // 失败条目同样保留重试（宁留勿丢，幂等）。队列清理见 downloadInUseAttachments。
    if (uploaded > 0) appLog('sync', '已上传附件 $uploaded 张（待 in-use 确认后清队列）', level: 'info');
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
      // 全量同步数量含全部实体（含行级商品记录与库存）——与同步面板各 store 合计口径一致，
      // 此前漏 sale_items/purchase_items/stocks 导致"同步日志拉取 N 条"与面板数字对不上
      return clients.length + items.length + categories.length + accounts.length +
          sales.length + purchases.length + payments.length +
          saleItemRows.length + purchaseItemRows.length + stockRows.length;
    } catch (e) {
      _lastSyncFailed = true;
      appLog('sync', '全量同步失败：${_friendlyError(e)}', level: 'error');
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
      final pulledTypes = <String, int>{}; // 拉取明细：实体类型 → 条数（同步日志可读）
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
            // 附件变更（对齐参考架构：附件是一等实体，上传=upsert 变更/删除=delete 变更，
            // 客户端按变更流维护本地引用表，不依赖 in-use 全量快照覆盖）
            if (entityType == 'attachment') {
              final key = '${payload['file_key'] ?? payload['key'] ?? ''}';
              if (key.isNotEmpty) {
                if (action == 'delete') {
                  // 其他端删了附件 → 本地同步删对应副本（引用变更流驱动跨端删除）
                  final root = await getApplicationDocumentsDirectory();
                  // 优先用 payload 携带的 entity/id（新客户端），否则三前缀解析 key（兼容历史根级前缀）
                  final entity = '${payload['entity'] ?? ''}';
                  final eid = '${payload['id'] ?? ''}';
                  final parsed = (entity.isNotEmpty && eid.isNotEmpty)
                      ? {'entity': entity, 'id': eid}
                      : _parseAttachmentKey(key);
                  if (parsed != null) {
                    // 本地待上传队列同步移除（同实体同文件）：其他端已删，本端残留待传条目
                    // 不应再传回去（否则删除被上传复活）
                    try {
                      await removePendingUpload(
                          entity: '${parsed['entity'] ?? ''}',
                          id: '${parsed['id'] ?? ''}',
                          fileName: key.split('/').last);
                    } catch (_) {}
                    final f = File('${root.path}/attachments/${parsed['entity']}/${parsed['id']}/${key.split('/').last}');
                    if (f.existsSync()) f.deleteSync();
                    // 同步删除本地引用行 + 删除墓碑（删除已由他端发起并进入变更流，本地无需墓碑）
                    try {
                      await LocalDb.deleteOne('attachment_refs', '${parsed['entity']}/${parsed['id']}/${key.split('/').last}');
                    } catch (_) {}
                    try {
                      await LocalDb.deleteOne(kDeletedAttachmentsStore, '${parsed['entity']}/${parsed['id']}/${key.split('/').last}');
                    } catch (_) {}
                  }
                } else {
                  // upsert：他端上传附件 → 本地写引用行（下载由 downloadInUseAttachments 补齐）
                  final entity = '${payload['entity'] ?? ''}';
                  final eid = '${payload['id'] ?? ''}';
                  if (entity.isNotEmpty && eid.isNotEmpty) {
                    final file = '${payload['file'] ?? key.split('/').last}';
                    await LocalDb.upsertOne('attachment_refs', {
                      'id': '$entity/$eid/$file',
                      'entity': entity,
                      'entity_id': eid,
                      'file': file,
                      'key': key,
                    });
                  }
                }
              }
              applied = true;
            } else {
              final store = _storeOf(entityType);
              if (store.isEmpty) continue;
              // 行级商品记录（去单据化）：sale_item/purchase_item 双写行级 store + 单据镜像 items
              // （账本/进货历史按行级渲染：只写镜像则跨端增删改残留，全量同步才生效）
              if (entityType == 'sale_item' || entityType == 'purchase_item') {
                final rowStore = entityType == 'sale_item' ? 'sale_items' : 'purchase_items';
                final orderStore = entityType == 'sale_item' ? 'sales' : 'purchases';
                final orderId = '${payload['${entityType == 'sale_item' ? 'sale_id' : 'purchase_id'}'] ?? ''}';
                final rowId = id;
                final order = await LocalDb.getOne(orderStore, orderId);
                if (action == 'delete') {
                  // 删行：行级 store 同步删 + 从单据镜像 items 移除该行；空则删单据（防空壳）
                  await LocalDb.deleteOne(rowStore, rowId);
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
                  // upsert：行级 store 同步写 + 单据镜像合并该行；单据不存在则按订单头建仓（兼容历史整单 pull 已先行建单）
                  await LocalDb.upsertOne(rowStore, payload);
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
                // 整单删除：行级 store 同步删（账本/进货历史按行级渲染，残留会显示到全量同步）
                if (entityType == 'sale' || entityType == 'purchase') {
                  final rowStore = entityType == 'sale' ? 'sale_items' : 'purchase_items';
                  final fk = entityType == 'sale' ? 'sale_id' : 'purchase_id';
                  for (final r in await LocalDb.getAll(rowStore)) {
                    if ('${r[fk] ?? ''}' == id) {
                      final rid = '${r['id'] ?? ''}';
                      if (rid.isNotEmpty) await LocalDb.deleteOne(rowStore, rid);
                    }
                  }
                }
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
                  // 整单 upsert（服务端快照含 items）：行级 store 按快照对齐——
                  // 跨端删行/改行后残留的旧行随快照消失，不必等全量同步
                  if (entityType == 'sale' || entityType == 'purchase') {
                    final rowStore = entityType == 'sale' ? 'sale_items' : 'purchase_items';
                    final fk = entityType == 'sale' ? 'sale_id' : 'purchase_id';
                    final kept = <String>{};
                    for (final raw in ((payload['items'] as List?) ?? [])) {
                      final r = (raw as Map).cast<String, dynamic>();
                      final rid = '${r['id'] ?? ''}';
                      if (rid.isEmpty) continue;
                      kept.add(rid);
                      await LocalDb.upsertOne(rowStore, r);
                    }
                    for (final old in await LocalDb.getAll(rowStore)) {
                      final oid = '${old['id'] ?? ''}';
                      if ('${old[fk] ?? ''}' == id && oid.isNotEmpty && !kept.contains(oid)) {
                        await LocalDb.deleteOne(rowStore, oid);
                      }
                    }
                  }
                  applied = true;
                }
              }
            }
            if (applied) {
              total++;
              // 按实体类型累计（同步完成日志可读：拉取了什么内容）
              (pulledTypes[entityType] ??= 0);
              pulledTypes[entityType] = pulledTypes[entityType]! + 1;
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
      // 拉取明细日志（对齐用户需求：详细推送了什么交易/附件，而非只有"拉取 N 条"）
      if (total > 0) {
        final detail = pulledTypes.entries
            .map((e) => '${e.key} ${e.value} 条')
            .join('、');
        appLog('sync', '增量拉取 $total 条：$detail', level: 'info');
      }
      return total;
    } catch (e) {
      _lastSyncFailed = true;
      appLog('sync', '增量拉取失败：${_friendlyError(e)}', level: 'error');
      return 0;
    } finally {
      _syncing = false;
    }
  }

  /// 推送本地待同步队列（批量 POST /sync/push）；成功移除，失败留队列。
  /// 分批推送（每批 ≤50 条）：Workers 免费计划单请求 CPU 超限会稳定返回 503，
  /// 一次推 300+ 条=死循环（"同步一直在重复上传，全部503/队列越堆越多"根因）。
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
      // 附件删除变更兜底收敛：旧客户端入队的删除变更 payload 只有 md5-only 内容 key（解析不出
      // 实体）→ 服务器按"共用图保护"拒绝（400）；LWW/其他原因被拒也会留队列。此类变更若一直
      // push 失败，pendingDel 过滤会让本地引用表永远少 N 条（同步面板"本地91/服务器95"差 4 的根因）。
      // 放在分批推送前统一处理一次（若放批循环内=每批基于同一 pending 快照重复处理同一条
      // →"附件删除兜底成功"日志刷屏）：服务器 in-use 仍有该 key → 用规范化三元组直连删除；
      // in-use 已无该 key → 服务器已删/无此引用，本地队列残留直接清掉。
      final skipIds = <int>{};
      try {
        final attachDeletes = pending
            .where((x) => '${x['entity_type'] ?? ''}' == 'attachment' && '${x['action'] ?? ''}' == 'delete')
            .toList();
        if (attachDeletes.isNotEmpty) {
          final inUse = await Api.instance.get('/attachments/in-use').timeout(const Duration(seconds: 25));
          final inUseList = ((inUse['attachments'] as List?) ?? []).cast<Map<String, dynamic>>();
          for (final x in attachDeletes) {
            final sid = '${x['entity_sync_id'] ?? ''}';
            // 优先用 payload 携带的 entity/id（新客户端删除带三元组），否则用服务器 in-use 匹配
            final p = (x['payload'] as Map<String, dynamic>?) ?? {};
            var e = '${p['entity'] ?? ''}'.trim();
            var i = '${p['id'] ?? ''}'.trim();
            if (e.isEmpty || i.isEmpty) {
              final match = inUseList
                  .where((a) => '${a['key'] ?? ''}' == sid || '${a['file'] ?? ''}' == sid.split('/').last)
                  .firstOrNull;
              if (match != null) {
                e = '${match['entity'] ?? ''}';
                i = '${match['id'] ?? ''}';
              }
            }
            if (e.isNotEmpty && i.isNotEmpty) {
              try {
                await Api.instance.delete('/attachments?key=$sid&entity=$e&id=$i');
                appLog('sync', '附件删除兜底成功：$sid（$e/$i）', level: 'info');
                final id = x['id'];
                if (id is int) { await LocalDb.removePendingChange(id); skipIds.add(id); }
                continue;
              } catch (_) {}
            }
            // 服务器 in-use 已无该引用（此前已删成功/引用本就不存在）→ 本地队列残留直接清掉
            appLog('sync', '附件删除已在服务器生效，清理本地残留变更：$sid', level: 'info');
            final id = x['id'];
            if (id is int) { await LocalDb.removePendingChange(id); skipIds.add(id); }
          }
        }
      } catch (_) {}
      final pendingLeft = pending
          .where((x) {
        final id0 = x['id'];
        return !(id0 is int && skipIds.contains(id0));
      }).toList();
      final did = await deviceId();
      // 分批：extra（删除标记，数量少、固定时间戳幂等）单独一批，pending 每 50 条一批
      const batchSize = 50;
      final batchStarts = <int>[]; // pendingLeft 每批起始下标（extra 批 = -1）
      final batches = <List<Map<String, dynamic>>>[];
      if (extra.isNotEmpty) { batches.add(extra); batchStarts.add(-1); }
      for (var start = 0; start < pendingLeft.length; start += batchSize) {
        final batchPending = pendingLeft.skip(start).take(batchSize).toList();
        batchStarts.add(start);
        batches.add(batchPending.map((x) {
          final m = Map<String, dynamic>.from(x);
          m.remove('id'); // 队列内部 id 不传服务端
          return m;
        }).toList());
      }
      var totalAccepted = 0;
      for (var bi = 0; bi < batches.length; bi++) {
        final batch = batches[bi];
        final startIdx = batchStarts[bi];
        final isExtraBatch = startIdx < 0;
        final d = await Api.instance.post('/sync/push', {'device_id': did, 'changes': batch});
        if (d == null) return totalAccepted;
        final accepted = d['accepted'] as int? ?? 0;
        totalAccepted += accepted;
        // 推送明细日志：逐条记录（用户要一条变更一条日志，不聚合——"推送 N 条"看不出具体推了什么）
        for (final ch in batch) {
          final t = '${ch['entity_type'] ?? ''}';
          final sid = '${ch['entity_sync_id'] ?? ''}';
          final act = '${ch['action'] ?? 'upsert'}';
          appLog('sync', '推送 $t $sid（$act）', level: 'info');
        }
        appLog('sync', '本轮第 ${bi + 1}/${batches.length} 批推送 ${batch.length} 条，服务器接受 $accepted 条', level: 'info');
        if (isExtraBatch) {
          // 持久删除集合：仅清除"本地库已确实删掉/软删落库"的条目；
          // 本地库只读导致 tombstone 未写入、行仍活跃的条目必须保留（含原时间戳）——
          // 否则重启后 _load 失去过滤依据，已删商品复活（服务端已删也不影响：集合仅本地过滤用）
          if (accepted >= batch.length) {
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
          continue; // extra 批无本地 pending id 可移除
        }
        // 本批被接受的条目按顺序移除（服务端 accepted=应用成功数，顺序与批内一致）
        var removed = 0;
        final removedIds = <int>{};
        for (var k = 0; k < batch.length && removed < accepted; k++) {
          final pid = pendingLeft[startIdx + k];
          final lid = pid['id'];
          if (lid is int && !removedIds.contains(lid)) {
            await LocalDb.removePendingChange(lid);
            removed++;
            removedIds.add(lid);
          }
        }
        // 服务端时间校准：设备时钟偏慢会让 LWW 拒绝本设备写入（删除/改分类在服务端不生效，
        // pull 又拉回旧值）。只对**服务器明确拒绝的条目**（conflict_samples）重刷 updated_at——
        // 不再对整批 pending 重刷：503 整批失败重试若刷新时间戳= LWW 通过→服务端重复应用+
        // 重复审计（用户"审计有重复添加记录"根因）。
        final serverTime = DateTime.tryParse('${d['server_time'] ?? ''}')?.toUtc();
        final offset = serverTime?.difference(DateTime.now().toUtc());
        if (offset != null) {
          final conflictKeys = <String>{};
          for (final s in (d['conflict_samples'] as List?) ?? const <Object>[]) {
            final m = s as Map;
            final et = '${m['entity_type'] ?? ''}';
            final sid = '${m['entity_sync_id'] ?? ''}';
            if (et.isNotEmpty && sid.isNotEmpty) conflictKeys.add('$et:$sid');
          }
          if (conflictKeys.isNotEmpty) {
            for (var k = 0; k < batch.length; k++) {
              final key = '${batch[k]['entity_type'] ?? ''}:${batch[k]['entity_sync_id'] ?? ''}';
              if (!conflictKeys.contains(key)) continue;
              final pid = pendingLeft[startIdx + k];
              final lid = pid['id'];
              final ts = DateTime.tryParse('${batch[k]['updated_at'] ?? ''}');
              if (lid is int && ts != null && !removedIds.contains(lid)) {
                await LocalDb.retimePendingChange(lid, ts.toUtc().add(offset).toIso8601String());
              }
            }
          }
        }
      }
      // 推送成功后顺便拉取一次（其他设备的变更）
      await pullChanges();
      return totalAccepted;
    } catch (e) {
      _lastSyncFailed = true;
      // 推送失败也要有可读日志（用户曾遇"2条没推送但只有403原文"）：记录实体类型与失败原因
      appLog('sync', '推送本地变更失败：${_friendlyError(e)}', level: 'error');
      return 0;
    }
  }

  /// 异常 → 中文可读（复用 api.dart 的友好文案思路：网络/超时/服务端拒绝分开提示）
  static String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('403')) return '服务器拒绝（403）：当前账号无权限执行此操作，请确认账号权限或重新登录';
    if (s.contains('401')) return '登录已过期（401），请重新登录';
    if (s.contains('host lookup') || s.contains('No address associated with hostname')) return '无法连接服务器（域名解析失败），请检查网络或服务器地址';
    if (s.contains('Connection refused')) return '无法连接服务器（连接被拒绝），请检查服务器地址';
    if (s.contains('Timeout')) return '连接服务器超时，请检查网络后重试';
    if (s.contains('SocketException') || s.contains('ClientException')) return '无法连接服务器，请检查网络或服务器地址';
    return s.split('\n').first;
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

  /// App 本地主题变更 → 触发一轮完整同步（_syncTheme 检测 dirty 后推送服务器，广播 WS；
  /// Web 直连不经此钩子）。注册一次，供 ThemeConfig.onThemeLocalChanged 调用。
  static void scheduleThemeSync() {
    if (kIsWeb) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      sync();
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
      // ① 上传待传附件（失败不阻塞主流程，单张静默保留队列下次再传）——记录本次上传张数
      final uploadedAttach = await uploadPendingAttachments();
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
      // 推送 0 条时标注原因（队列空 = 离线录入已由自动同步推送；避免误读为"没推送"）
      final pendingNow = await LocalDb.getPendingChanges();
      appLog('sync', '同步完成：拉取 $pulled 条、推送 $pushed 条、上传附件 $uploadedAttach 张${pushed == 0 && pendingNow.isEmpty ? '（无待推变更，此前已推送）' : ''}', level: 'info');
      // ④ 在用附件本地副本补齐（附件不走同步流；本地副本被清理后离线不可见——违背本地优先）：
      // **await 等待附件下载完，同步中的动画/状态行才消失**（完全同步之后再消失）；
      // 单张失败内部静默跳过，下次同步自动重补，不阻塞主流程
      // 注意：同步只补齐副本，**不自动清理孤儿**（对齐参考实现：孤儿由存储清理页手动
      // 扫描删除；同步自动删曾误删在用副本——"每次同步补齐后又被删"根因）
      await downloadInUseAttachments();
      // ⑤ 资料（显示名/头像版本）同步对齐参考 sync() 编排：实体+附件完成后统一 syncMyProfile
      await syncMyProfile();
      // ⑥ 主题配置随同步上传/拉取（App 不直连写数据库；Web 直连在设置页保存）
      await _syncTheme();
      // ⑥b 金额舍入随同步上传（本地有未同步修改 → 推送服务器，不直连改库；服务端广播 WS payload 其他端应用）
      await _syncRounding();
      // ⑦ 僵尸附件引用清理：引用目标实体不存在（识别取消残留等）→ 删引用行+对应副本文件；
      // 在用副本不清（孤儿文件仍由存储清理页扫描）——0.17.330 曾只加逻辑未挂调用点=从未执行
      await cleanupOrphanLocalAttachments();
    } catch (e) {
      _lastSyncFailed = true;
      appLog('sync', '同步失败: ${e.toString().split('\n').first}', level: 'error');
      // 任一异常都不外抛（bottom_shell 无 await 调用，抛了就成 unhandled error）
    } finally {
      _setStatus(_lastSyncFailed ? 'error' : 'idle');
    }
  }

  /// 主题配置随同步上传/拉取：本地有未同步修改（dirty）→ 上传服务器并清标记；
  /// 否则拉取服务器主题应用（他端/Web 改的跨端一致）。失败静默（本地主题仍生效）。
  static Future<void> _syncTheme() async {
    try {
      if (ThemeConfig.instance.themeDirty) {
        await ThemeConfig.instance.pushTheme();
      } else {
        await ThemeConfig.instance.pullTheme();
      }
    } catch (_) {}
  }

  /// 金额舍入随同步上传：本地有未推送修改（roundingDirty）→ PUT /settings/rounding 推送并清标记。
  /// 本地优先：保存只写本地（Money.apply）+置脏，推送失败静默保留脏标记下次再推，不阻塞、不兜底；服务端广播 WS payload。
  static Future<void> _syncRounding() async {
    if (!Money.roundingDirty) return;
    try {
      await Api.instance.put('/settings/rounding', {
        'carry': Money.carry,
        'digits': Money.digits,
      });
      await Money.clearRoundingDirty();
    } catch (_) {}
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

  /// 清理某实体的本地附件引用（删除单据/商品行时调用）：删本地附件引用表该实体条目 +
  /// 待上传队列同步移除（否则残留队列条目每次同步重传 → 服务器引用复活，
  /// 被 in-use 自愈再删 = "一直重复推送附件"循环）；
  /// 公共副本文件（attachments/{file}）无其他引用时删（同图被其他行共享则保留，
  /// 孤儿文件由同步扫描/「重置本地附件副本」统一清理）。
  static Future<void> cleanupLocalAttachmentsOf(String entityType, String id) async {
    try {
      final refs = await LocalDb.getAll('attachment_refs');
      final removedFiles = <String>{};
      for (final r in refs) {
        if ('${r['entity'] ?? ''}' == entityType && '${r['entity_id'] ?? ''}' == id) {
          await LocalDb.deleteOne('attachment_refs', '${r['entity']}/${r['entity_id']}/${r['file']}');
          final f = '${r['file'] ?? ''}';
          if (f.isNotEmpty) {
            removedFiles.add(f);
            // 本地待上传队列同步移除（同实体同文件）：删除该实体后其附件不得再上传复活
            await removePendingUpload(
                entity: entityType, id: id, fileName: f.split('/').last);
            // 删除墓碑：删行/删单路径同样写墓碑（覆盖"删行后行级引用被 pull 快照写回"窗口）
            await tombstoneDeletedAttachment(
                entity: entityType, id: id, file: f.split('/').last);
          }
        }
      }
      // 平铺副本（attachments/{file}，同图一份）：删引用后若该文件无其他引用 → 删本地副本
      // （此前只删引用行不删文件=删行后副本残留，同步面板"物理副本本地多"根因）
      if (removedFiles.isNotEmpty) {
        final remaining = await LocalDb.getAll('attachment_refs');
        final still = remaining.map((r) => '${r['file'] ?? ''}').toSet();
        final root = await getApplicationDocumentsDirectory();
        for (final f in removedFiles) {
          if (still.contains(f)) continue;
          try {
            final ff = File('${root.path}/attachments/$f');
            if (ff.existsSync()) await ff.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// 同步完成后扫描清理本地孤儿附件副本（对齐参考实现 scanFileOrphanAttachments）：
  /// 数据源=本地 attachment_refs 表（同步时 downloadInUseAttachments 已把服务器在用三元组
  /// {entity, entity_id, file} 持久化到本地）——三元组在表内 = 在用（保留），不在表 = 孤儿（删文件）。
  /// 引用表为空（未同步/拉取失败）→ 不删任何文件（宁留勿误删——没有权威数据源不动本地副本）。
  /// 只删文件不整删目录（在用判定必须文件级；整删目录会在本地镜像 id 与目录不一致时误删在用副本）。
  /// 删除前双重保险：三元组不在表 **且** basename 也不在表（防三元组某字段与下载路径不一致时误删在用）；
  /// 删除动作与保留统计写 appLog（用户日志可直接核对清理了什么）。
  static Future<void> cleanupOrphanLocalAttachments() async {
    try {
      if (kIsWeb) return;
      // 僵尸引用清理：识别/取消残留（引用表有行但目标实体在本地库不存在，如临时单 id）——
      // 先删引用行，随后下方文件扫描会把无引用的副本文件当孤儿删掉（否则"存储清理扫不到"）。
      // 仅本地库已全量同步时执行（防未同步时误删真实在用引用）。
      if (await isFullDone()) {
        try {
          final refRows0 = await LocalDb.getAll('attachment_refs');
          if (refRows0.isNotEmpty) {
            final saleLineIds = <String>{}; final purchaseLineIds = <String>{};
            for (final s in await LocalDb.getAll('sale_items')) saleLineIds.add('${s['id'] ?? ''}');
            for (final p in await LocalDb.getAll('purchase_items')) purchaseLineIds.add('${p['id'] ?? ''}');
            bool valid(String e, String i) {
              switch (e) {
                // 单据级引用豁免：识别图/凭证挂 sale|purchase|payment/{单id} 在未提交时也是合法挂载
                // （本地单尚未落库=目标不存在，但用户还在编辑/未提交）——宁留勿删，防"清理僵尸把
                // 识别图清了"（用户复现：新增商品触发同步→清理删掉未编辑完的识别图）
                case 'sale': return true;
                case 'sale_item': return saleLineIds.contains(i);
                case 'payment': return true;
                case 'purchase': return true;
                case 'purchase_item': return purchaseLineIds.contains(i);
              }
              return true; // 未知实体宁留勿删
            }
            for (final r in refRows0) {
              final e = '${r['entity'] ?? ''}';
              final i = '${r['entity_id'] ?? ''}';
              if (e.isEmpty || i.isEmpty) continue;
              if (valid(e, i)) continue;
              await LocalDb.deleteOne('attachment_refs', '${e}/${i}/${r['file'] ?? ''}');
              appLog('sync', '清理僵尸附件引用：$e/$i（${r['file'] ?? ''}）', level: 'info');
            }
          }
        } catch (_) {}
      }
      final root = await getApplicationDocumentsDirectory();
      final base = Directory('${root.path}/attachments');
      if (!base.existsSync()) return;
      // 本地附件引用表 = 在用权威（同步时 downloadInUseAttachments 已持久化服务器在用三元组）
      final refRows = await LocalDb.getAll('attachment_refs');
      if (refRows.isEmpty) return; // 表空不清理（宁留勿误删）
      final refs = refRows
          .map((r) => '${r['entity'] ?? ''}/${r['entity_id'] ?? ''}/${r['file'] ?? ''}')
          .where((f) => !f.startsWith('/') && !f.contains('//') && f.split('/').length >= 3)
          .toSet();
      final refNames = refRows
          .map((r) => '${r['file'] ?? ''}')
          .where((f) => f.isNotEmpty)
          .toSet();
      if (refs.isEmpty || refNames.isEmpty) return;
      var scanned = 0;
      var removed = 0;
      final removedList = <String>[];
      // 扫描附件公共目录 attachments/{file}（file=md5 文件名，同图一份平铺存储）：
      // basename 不在引用表 = 孤儿 → 删文件（对齐参考实现 cleaner 只删文件；宁留勿误删）
      await for (final f in base.list(followLinks: false)) {
        if (f is! File) continue;
        final fileName = f.uri.pathSegments.last;
        scanned++;
        if (!refNames.contains(fileName)) {
          try { f.deleteSync(); removed++; removedList.add(fileName); } catch (_) {}
        }
      }
      appLog('sync', '本地孤儿附件清理：引用表 ${refs.length} 条，扫描 $scanned 文件，删除 $removed 个${removedList.isEmpty ? '' : '（' + removedList.take(5).join(', ') + '…）'}', level: 'info');
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