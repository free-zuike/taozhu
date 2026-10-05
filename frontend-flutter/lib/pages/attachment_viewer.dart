import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../api.dart';
import '../local_db.dart';
import '../log.dart';
import '../sync_service.dart';
import '../widgets/center_sheet.dart';
import 'router.dart';

/// 附件全屏查看器：点图标直接全屏显示该单据的全部附件，左/右滑切换；
/// 顶部显示"第 x/N 张"，可添加附件、删除当前；空态显示"暂无附件 + 添加"。
/// 批量模式（lineIds 非空，仅单据级入口 sale/purchase 使用）：上传一张凭证图实际
/// 是批量按单条存入该单每个明细行（每行各自行级引用），展示合并各行并按同内容去重；
/// 不产生独立的单据级份（历史存量单据级图仍合并展示）。
Future<void> showAttachmentViewer(
  BuildContext context,
  String entity,
  String id,
  String title, {
  List<String> lineIds = const [],
}) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => AttachmentViewer(
          entity: entity, id: id, title: title, lineIds: lineIds),
    ),
  );
}

class AttachmentViewer extends StatefulWidget {
  const AttachmentViewer({
    super.key,
    required this.entity,
    required this.id,
    required this.title,
    this.lineIds = const [],
  });
  final String entity; // sale | purchase | payment
  final String id;
  final String title;
  /// 批量模式：该单据全部明细行 id（记单页/整单凭证入口传入）。
  /// 非空时上传批量存入每行、展示合并各行、删除一并清理全部份。
  final List<String> lineIds;
  @override
  State<AttachmentViewer> createState() => _AttachmentViewerState();
}

class _Item {
  _Item(this.key, this.localPath, [this.allKeys = const []]);
  final String key;
  final String? localPath;
  /// 该凭证关联的全部云端 key（批量模式下 = 单据历史份 + 各行份），删除时一并清理。
  final List<String> allKeys;
}

class _AttachmentViewerState extends State<AttachmentViewer> {
  List<_Item> _items = [];
  bool _loading = true;
  int _index = 0;
  String _base = '';
  String _token = '';
  final _pageCtrl = PageController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _base = await Api.instance.getBase();
    _token = await Api.instance.getTokenValue() ?? '';
    await _load();
  }

  /// 批量模式下对应的行级实体名（sale→sale_item / purchase→purchase_item）
  String get _lineEntity =>
      widget.entity == 'sale' ? 'sale_item' : 'purchase_item';

  /// 批量模式（单据级入口传入该单明细行列表）
  bool get _bulk => widget.lineIds.isNotEmpty;

  /// 云端某实体的附件 key 列表（Web 直连）
  Future<List<String>> _cloudKeys(String entity, String id) async {
    final d = await Api.instance.get('/attachments?entity=$entity&id=$id');
    return ((d['attachments'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .map((x) => '${x['key']}')
        .toList();
  }

  Future<void> _load() async {
    // **打开附件查看器：App 零网络**——只读本地副本目录（离线也能查看本地已有副本）。
    // 附件副本由「同步状态页」同步统一下载（downloadInUseAttachments），此处不下载、不请求云端。
    if (kIsWeb) {
      // Web 无本地文件系统：只能云端直连（Web 固有形态，页面即云端界面）
      try {
        final keys = <String>[];
        if (_bulk) {
          // 批量模式：合并单据（历史存量）+ 各行前缀，同名（同 md5 内容）去重合并
          keys.addAll(await _cloudKeys(widget.entity, widget.id));
          for (final lid in widget.lineIds) {
            keys.addAll(await _cloudKeys(_lineEntity, lid));
          }
        } else {
          keys.addAll(await _cloudKeys(widget.entity, widget.id));
        }
        final byFile = <String, List<String>>{};
        for (final key in keys) {
          byFile.putIfAbsent(key.split('/').last, () => []).add(key);
        }
        if (!mounted) return;
        setState(() {
          _items = [
            for (final e in byFile.entries)
              _Item(e.value.first, null, e.value),
          ];
          _resetIndex();
          _loading = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _loading = false);
      }
      return;
    }
    // 原生/桌面：本地公共副本目录（同步时下载一份）+ 本地引用表（每实体一行）零网络。
    final root = await getApplicationDocumentsDirectory();
    final locals = <String, String>{};
    final keysByFile = <String, List<String>>{};
    // 新结构：本地公共副本目录 attachments/{file}（同图一份）+ 本地引用表（每实体一行）——
    // 该实体（+批量行）引用的文件即它的附件，公共目录有副本则本地预览
    try {
      final adir = Directory('${root.path}/attachments');
      if (adir.existsSync()) {
        for (final f in adir.listSync()) {
          if (f is! File) continue;
          locals.putIfAbsent(f.uri.pathSegments.last, () => f.path);
        }
      }
    } catch (_) {}
    try {
      final refs = await LocalDb.getAll('attachment_refs');
      final myFiles = <String>[];
      for (final r in refs) {
        if (_bulk) {
          // 批量模式合并展示：单据级引用（历史存量/Web 直传/编辑页凭证入口）+ 各明细行级引用——
          // 只查行级会漏掉单据级附件（账本图标亮、点开"暂无附件"根因），与 Web 版/删除逻辑一致
          if (('${r['entity'] ?? ''}' == _lineEntity &&
                  widget.lineIds.contains('${r['entity_id'] ?? ''}')) ||
              ('${r['entity'] ?? ''}' == widget.entity &&
                  '${r['entity_id'] ?? ''}' == widget.id)) {
            myFiles.add('${r['file'] ?? ''}');
          }
        } else if ('${r['entity'] ?? ''}' == widget.entity &&
            '${r['entity_id'] ?? ''}' == widget.id) {
          myFiles.add('${r['file'] ?? ''}');
        }
      }
      for (final name in myFiles.toSet()) {
        // 优先用服务器真实 key（旧格式含实体段删除才匹配得上），没有（老库引用行）才按新格式重构
        final rk = refs
            .where((r) => '${r['file'] ?? ''}' == name)
            .map((r) => '${r['key'] ?? ''}')
            .where((k) => k.isNotEmpty)
            .toList();
        final keys = rk.isNotEmpty ? rk : <String>['taozhu/images/attachments/$name'];
        for (final k in keys) {
          keysByFile.putIfAbsent(name, () => []).add(k);
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _items = [
        for (final e in keysByFile.entries)
          _Item(e.value.first, locals[e.key], e.value),
      ];
      _resetIndex();
      _loading = false;
    });
  }

  /// 修正当前索引到合法范围（列表重建后调用）
  void _resetIndex() {
    if (_items.isEmpty) {
      _index = 0;
    } else if (_index >= _items.length) {
      _index = _items.length - 1;
    } else if (_index < 0) {
      _index = 0;
    }
  }

  Future<void> _add() async {
    final src = await showCenterSheet<ImageSource>(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined, color: Color(0xFF409EFF)),
            title: const Text('拍照（扫描凭证）'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined, color: Color(0xFF67C23A)),
            title: const Text('从相册选择（手动添加）'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
    if (src == null) return;
    final picked = await ImagePicker().pickImage(source: src, maxWidth: 1600, imageQuality: 85);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    // 本地 MD5 去重：该实体（批量=全部行）引用表已存在同内容图则跳过——按引用表判定而非
    // 公共目录文件（同图一份后公共目录文件可能来自其他实体，文件存在≠本实体已挂载）
    final h = md5.convert(bytes).toString();
    if (!kIsWeb) {
      try {
        final refs = await LocalDb.getAll('attachment_refs');
        final dup = refs.any((r) {
          final re = '${r['entity'] ?? ''}';
          final rid = '${r['entity_id'] ?? ''}';
          final rf = '${r['file'] ?? ''}'.split('/').last;
          final mine = _bulk
              ? (re == _lineEntity && widget.lineIds.contains(rid)) ||
                    (re == widget.entity && rid == widget.id)
              : (re == widget.entity && rid == widget.id);
          return mine && (rf == '$h.jpg');
        });
        if (dup && !_bulk) {
          toast(context, '该图片已存在，跳过重复添加');
          return;
        }
      } catch (_) {}
    }
    toast(context, kIsWeb ? '上传中…' : '添加中…');
    try {
      if (kIsWeb) {
        if (_bulk) {
          // Web 批量：一张凭证图批量存入该单每个明细行（行级），无独立单据级份
          for (final lid in widget.lineIds) {
            await Api.instance.uploadPhoto(
              '/attachments?entity=$_lineEntity&id=$lid',
              bytes,
              'photo.jpg',
            );
          }
          toast(context, '已添加附件（已关联全部商品）');
        } else {
          // Web 无本地副本/同步队列：直传云端（Web 固有形态）
          await Api.instance.uploadPhoto(
            '/attachments?entity=${widget.entity}&id=${widget.id}',
            bytes,
            'photo.jpg',
          );
          toast(context, '已添加附件');
        }
      } else {
        // 本地优先：先落公共目录副本（同内容一份，对齐参考实现）——附件上传是同步流程一部分，
        // 页面不直连云端；联网后由同步统一上传（失败自动重试）
        final root = await getApplicationDocumentsDirectory();
        final adir = Directory('${root.path}/attachments');
        if (!adir.existsSync()) adir.createSync(recursive: true);
        final af = File('${adir.path}/$h.jpg');
        if (!af.existsSync()) await af.writeAsBytes(bytes);
        if (_bulk) {
          // 批量模式：同图一份物理文件，每行入队（服务器同内容幂等同 key + 引用表每行一行）
          var added = 0;
          for (final lid in widget.lineIds) {
            await SyncService.enqueueAttachmentUpload(
                entity: _lineEntity, id: lid, fileName: '$h.jpg');
            added++;
          }
          toast(context, added > 0
              ? '已添加附件（已关联全部商品，联网后自动上传）'
              : '全部商品均已存在该图片，跳过重复添加');
        } else {
          await SyncService.enqueueAttachmentUpload(
            entity: widget.entity, id: widget.id, fileName: '$h.jpg',
          );
          toast(context, '已添加附件（联网后自动上传）');
        }
      }
      await _load();
      appLog('op', '附件 添加：${widget.entity}/${widget.id}${_bulk ? '（批量 ${widget.lineIds.length} 行）' : ''}', level: 'info');
      SyncService.version.notifyListeners(); // 账本附件图标计数/列表即时联动
      if (mounted && _items.isNotEmpty) {
        _index = _items.length - 1;
        setState(() {});
        // 空态（暂无附件）→ 上传后 PageView 才首次挂载，直接 jumpToPage 会抛 "Bad state: No element"
        if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(_index);
      }
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 保存当前附件到本地：Android 存系统相册（MediaStore，10+ 免权限 / 9- 需存储权限）；
  /// 桌面存下载目录。Web 浏览器可长按图片保存，不提供按钮。
  Future<void> _saveCurrent() async {
    if (_items.isEmpty || kIsWeb) return;
    final it = _items[_index];
    // 取图片字节：本地副本优先，无副本网络拉取（保存需要完整字节）
    List<int> bytes = <int>[];
    try {
      final local = it.localPath;
      if (local != null && File(local).existsSync()) {
        bytes = await File(local).readAsBytes();
      } else {
        final key = it.allKeys.isNotEmpty ? it.allKeys.first : it.key;
        final fullKey = key.startsWith('taozhu/')
            ? key
            : 'taozhu/images/attachments/${widget.entity}/${widget.id}/${key}';
        bytes = await Api.instance.getRaw('/attachments/$fullKey');
      }
    } catch (e) {
      toast(context, '获取图片失败：${e.toString().replaceFirst('Exception: ', '')}');
      return;
    }
    if (bytes.isEmpty) {
      toast(context, '图片内容为空，无法保存');
      return;
    }
    final fileName = 'taozhu_${DateTime.now().millisecondsSinceEpoch}.jpg';
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Android 9-（SDK<29）写公共相册需存储权限；10+ MediaStore 免权限（原生端处理）
        final ver = Platform.operatingSystemVersion;
        final m = RegExp(r'SDK (\d+)').firstMatch(ver);
        final sdk = m != null ? int.tryParse(m.group(1)!) ?? 34 : 34;
        if (sdk < 29) {
          final st = await Permission.storage.request();
          if (!st.isGranted) {
            toast(context, '需要存储权限才能保存到相册，请在系统设置中开启');
            return;
          }
        }
        const ch = MethodChannel('taozhu/download');
        await ch.invokeMethod<Object>('saveImage', {'bytes': Uint8List.fromList(bytes), 'fileName': fileName});
        toast(context, '已保存到系统相册（Pictures/陶朱）');
      } else {
        // 桌面：写下载目录
        final dir = await getDownloadsDirectory();
        if (dir == null) {
          toast(context, '无法获取下载目录');
          return;
        }
        await File('${dir.path}/$fileName').writeAsBytes(bytes);
        toast(context, '已保存到下载目录：$fileName');
      }
    } catch (e) {
      toast(context, '保存失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _deleteCurrent() async {
    if (_items.isEmpty) return;
    final it = _items[_index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除附件'),
        content: const Text('确定删除该附件吗？（本地与云端副本一并删除）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFF56C6C)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 附件删除走变更流（引用变更流驱动：本地删副本 → enqueueChange attachment 删除 → push → 云端删引用+GC → 其他端 pull 同步删副本）：
    // Web 无本地库/同步队列 → 直连云端删除（Web 固有形态，enqueueChange 在 kIsWeb 是 no-op 会导致删不掉）。
    // 待删除的全部云端 key：批量模式 = 单据历史份 + 各行份（allKeys 由 _load 汇总）；
    // 单份模式 = 当前显示的 key（本地优先展示时 key 可能只是文件名占位，需还原完整 key）
    final keys = (_bulk && it.allKeys.isNotEmpty)
        ? it.allKeys
        : <String>[
            it.key.startsWith('taozhu/')
                ? it.key
                : 'taozhu/images/attachments/${widget.entity}/${widget.id}/${it.key}',
          ];
    // key → (entity, id, file)（三前缀兼容，定位本地副本）
    (String, String, String)? parse(String key) {
      final m = RegExp(
              r'^(?:taozhu/images/attachments/|taozhu/attachments/)?([a-z_]+)/([^/]+)/([^/]+)$')
          .firstMatch(key);
      if (m != null) return (m.group(1)!, m.group(2)!, m.group(3)!);
      return null;
    }

    // 本地删除：删该实体引用行；公共副本文件不删（同图可能被其他实体引用，宁留勿删，
    // 由「重置本地附件副本」/孤儿逻辑统一清理——删除引用后同步会从在用列表移除）。
    // 批量模式引用行在每明细行（sale_item/lid）+ 历史单据级（sale/S），全范围删。
    var localDeleted = false;
    if (!kIsWeb) {
      try {
        final refs = await LocalDb.getAll('attachment_refs');
        for (final r in refs) {
          final re = '${r['entity'] ?? ''}';
          final rid = '${r['entity_id'] ?? ''}';
          final mine = _bulk
              ? (re == widget.entity && rid == widget.id) ||
                    (re == _lineEntity && widget.lineIds.contains(rid))
              : (re == widget.entity && rid == widget.id);
          if (!mine) continue;
          final file = '${r['file'] ?? ''}';
          if (keys.any((k) => k == file || k.split('/').last == file)) {
            await LocalDb.deleteOne('attachment_refs', '$re/$rid/$file');
            localDeleted = true;
          }
        }
      } catch (_) {}
    }
    if (kIsWeb) {
      try {
        // Web 直连删除：旧格式 key 解析出精确实体 → 仅该实体一对；新格式内容 key（md5-only
        // 解析不出实体）批量模式逐行（sale_item/lid）+ 单据历史级（sale/S）各删一条，
        // 带 entity/id 参数——后端无实体信息会拒绝防误删共享图
        for (final key in keys) {
          final parsed = parse(key);
          final targets = parsed != null
              ? <(String, String)>[(parsed.$1, parsed.$2)]
              : _bulk
                  ? [
                      for (final lid in widget.lineIds) (_lineEntity, lid),
                      (widget.entity, widget.id),
                    ]
                  : <(String, String)>[(widget.entity, widget.id)];
          for (final t in targets) {
            await Api.instance.delete('/attachments?key=$key&entity=${t.$1}&id=${t.$2}');
          }
        }
      } catch (e) {
        toast(context, e.toString().replaceFirst('Exception: ', ''));
        return;
      }
    } else {
      for (final key in keys) {
        final parsed = parse(key);
        // 目标实体集合：旧格式 key 解析出精确实体（sale_item/lid）→ 仅该实体一对；
        // 新格式内容 key（md5-only）解析不出 → 批量模式逐行（sale_item/lid）+ 单据历史级（sale/S），
        // 服务器按 file_key+entity+entity_id 精确删行（共用图其他单引用不受影响）
        final targets = parsed != null
            ? <(String, String)>[(parsed.$1, parsed.$2)]
            : _bulk
                ? [
                    for (final lid in widget.lineIds) (_lineEntity, lid),
                    (widget.entity, widget.id),
                  ]
                : <(String, String)>[(widget.entity, widget.id)];
        for (final t in targets) {
          try {
            await SyncService.enqueueChange(
              entityType: 'attachment',
              entitySyncId: key,
              action: 'delete',
              // entity/id 随变更下发：其他端 pull 时优先用三元组定位本地副本，兼容历史 key 前缀。
              // 新格式内容 key（md5-only 解析不出实体）→ 用目标实体（行级/单据级，防共用图误删）
              payload: {
                'file_key': key,
                'entity': t.$1,
                'id': t.$2,
              },
            );
          } catch (_) {
            // 入队失败（本地只读等）：直连兜底删除云端；其余交由同步流程重试
            try {
              await Api.instance.delete('/attachments?key=$key&entity=${t.$1}&id=${t.$2}');
            } catch (_) {}
          }
          // 同实体同文件若还在待上传队列（添加未同步过），一并移除——否则残留队列条目
          // 会在下次上传时把已删引用重新传回服务器（"删了又出现"的另一个来源）
          await SyncService.removePendingUpload(
            entity: t.$1, id: t.$2, fileName: key.split('/').last);
        }
      }
    }
    toast(context, kIsWeb
        ? '已删除'
        : (localDeleted ? '已删除（稍后同步删除云端）' : '已删除（本地无副本）'));
    appLog('op', '附件 删除：${widget.entity}/${widget.id} ${keys.length} 张', level: 'info');
    SyncService.version.notifyListeners(); // 账本附件图标计数/列表即时联动
    final prev = _index;
    await _load();
    if (mounted && _items.isNotEmpty) {
      final target = prev >= _items.length ? _items.length - 1 : prev;
      _index = target;
      setState(() {});
      if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          _items.isEmpty ? widget.title : '${widget.title} · ${_index + 1}/${_items.length}',
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          IconButton(
            tooltip: '添加附件',
            icon: const Icon(Icons.add_photo_alternate_outlined, color: Color(0xFF409EFF)),
            onPressed: _add,
          ),
          if (!kIsWeb && _items.isNotEmpty)
            IconButton(
              tooltip: '保存到本地',
              icon: const Icon(Icons.download_outlined, color: Color(0xFF409EFF)),
              onPressed: _saveCurrent,
            ),
          if (_items.isNotEmpty)
            IconButton(
              tooltip: '删除当前附件',
              icon: const Icon(Icons.delete_outline, color: Color(0xFFF56C6C)),
              onPressed: _deleteCurrent,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.image_outlined, size: 48, color: Color(0xFF9CA3AF)),
                      const SizedBox(height: 10),
                      const Text('暂无附件', style: TextStyle(color: Color(0xFF9CA3AF))),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF409EFF)),
                        onPressed: _add,
                        icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                        label: const Text('添加附件'),
                      ),
                    ],
                  ),
                )
              : PageView.builder(
                  controller: _pageCtrl,
                  itemCount: _items.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (_, i) => _page(_items[i]),
                ),
    );
  }

  /// 单张图片：**本地副本优先，本地没有就不显示网络兜底**——
  /// App/桌面端附件副本只由同步状态页同步下载（本地优先铁律"同步从同步状态获取"）；
  /// 本地无副本 → 提示去同步，避免"联网能看到、离线看不到"的错觉。
  /// Web 端无本地库/文件系统，直连云端展示是 Web 固有形态（保留）。
  Widget _page(_Item it) {
    final local = it.localPath;
    final hasLocal = local != null && File(local).existsSync();
    final Widget content = hasLocal
        ? Image.file(File(local), fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: Color(0xFF9CA3AF), size: 40))
        : kIsWeb
            ? Image.network(
                '$_base/api/v1/attachments/${it.key}',
                fit: BoxFit.contain,
                headers: _token.isEmpty ? null : {'Authorization': 'Bearer $_token'},
                loadingBuilder: (_, child, progress) => progress == null
                    ? child
                    : const Center(
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        ),
                      ),
                errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: Color(0xFF9CA3AF), size: 40),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.cloud_download_outlined, size: 44, color: Color(0xFF6B7280)),
                  const SizedBox(height: 12),
                  const Text('本地无此附件副本', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 15)),
                  const SizedBox(height: 6),
                  const Text('请在「我的 → 同步状态」同步后查看',
                      style: TextStyle(color: Color(0xFF6B7280), fontSize: 12), textAlign: TextAlign.center),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF409EFF)),
                    onPressed: () {
                      SyncService.sync();
                      toast(context, '已开始同步，完成后自动下载附件副本');
                    },
                    child: const Text('立即同步'),
                  ),
                ],
              );
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: content,
    );
  }
}
