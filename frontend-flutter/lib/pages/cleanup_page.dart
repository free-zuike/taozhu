import 'dart:io';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import '../theme.dart';
import 'router.dart';

/// 存储清理：列出更新安装包/临时文件（Android 走系统 DownloadManager，桌面扫下载目录），
/// 勾选删除；**APK（Android）点击即可安装**。后续可扩展"无效附件"等清理类型。
class CleanupPage extends StatefulWidget {
  const CleanupPage({super.key});
  @override
  State<CleanupPage> createState() => _CleanupPageState();
}

class _CacheFile {
  final String name;
  final String path; // 文件路径（Android DownloadManager 返回；空=不可安装）
  final String kind; // apk/zip/attach/avatar/dbbak/other
  int size; // 字节；0=未知
  bool selected = false;
  _CacheFile(this.name, this.size, [this.path = ''])
      : kind = _kindOf(name, path);

  /// 文件类型：apk=安装包 / zip=压缩包 / attach=附件副本（图片文件）/ avatar=头像缓存 / dbbak=库重建备份 / other=临时文件
  static String _kindOf(String name, String path) {
    final n = name.toLowerCase();
    if (n.endsWith('.apk')) return 'apk';
    if (n.endsWith('.zip')) return 'zip';
    if (n == 'avatar.jpg') return 'avatar';
    if (n.startsWith('taozhu_ro_') && n.endsWith('.db')) return 'dbbak';
    if (path.contains('/attachments/')) return 'attach'; // 附件文件路径形如 .../attachments/sale/s1/xxx.jpg
    return 'other';
  }
}

class _CleanupPageState extends State<CleanupPage> {
  static const _dlChannel = MethodChannel('taozhu/download');
  List<_CacheFile> _files = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int get _selectedCount => _files.where((f) => f.selected).length;
  bool get _allSelected => _files.isNotEmpty && _files.every((f) => f.selected);

  /// 附件行缩略图（40×40 圆角，加载失败显示占位图标）
  Widget _thumb(_CacheFile f) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 40,
        height: 40,
        child: Image.file(
          File(f.path),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: c.primary.withOpacity(0.08),
            child: Icon(Icons.broken_image_outlined, size: 20, color: c.textSub),
          ),
        ),
      ),
    );
  }

  /// 查看附件图片：单张查看（f.path 是该图片文件）；同单元其余图片可左右滑动
  Future<void> _viewAttach(_CacheFile f) async {
    final file = File(f.path);
    if (!await file.exists()) {
      toast(context, '图片不存在（可能已清理）');
      return;
    }
    // 同目录图片（同一附件单元）一并预览
    final dir = file.parent;
    final files = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .where((x) => RegExp(r'\.(jpg|jpeg|png|webp|gif)$', caseSensitive: false).hasMatch(x.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) {
      toast(context, '未找到图片文件');
      return;
    }
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _LocalPhotoViewer(files: files, initialPath: f.path),
      ),
    );
  }

  /// 点击安装包（Android APK）：调起系统安装器；其他文件提示
  Future<void> _installFile(_CacheFile f) async {
    final isApk = f.name.toLowerCase().endsWith('.apk');
    if (!isApk || f.path.isEmpty || kIsWeb) {
      toast(context, isApk ? '该文件暂无可安装路径' : '非安装包（桌面版请手动解压 zip 使用）');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('安装此 APK？'),
        content: Text(f.name),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('安装')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final result = await OpenFilex.open(f.path);
      if (result.type != ResultType.done) {
        toast(context, '调起安装失败：${result.message}');
      }
    } catch (e) {
      toast(context, '安装失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final files = <_CacheFile>[];
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        // Android：系统 DownloadManager 记录 + 应用下载目录（getDownloadsDirectory 在 Android 不可靠）
        final list = await _dlChannel.invokeMethod<List>('listCache') ?? const [];
        for (final item in list.cast<Map>()) {
          files.add(_CacheFile('${item['name'] ?? ''}', ((item['size'] as num?) ?? 0).toInt(), '${item['path'] ?? ''}'));
        }
      } else if (!kIsWeb) {
        // 桌面：下载目录 + 临时目录
        Future<void> scan(Directory? dir) async {
          if (dir == null || !await dir.exists()) return;
          await for (final f in dir.list(followLinks: false)) {
            if (f is! File) continue;
            final name = f.uri.pathSegments.last;
            if (name.startsWith('taozhu-')) {
              files.add(_CacheFile(name, await f.length(), f.path));
            }
          }
        }

        await scan(await getDownloadsDirectory());
        await scan(await getTemporaryDirectory());
      }
      // 附件本地副本（attachments/{entity}/{id}/ 目录）：随账号下载的图片缓存。
      // 退出登录/切换账号会清空，但历史遗留/未清理的副本可在这里**逐张**查看与删除
      // （每张图片单独一行，行首缩略图，不再按单元合并成"N 张"）。
      if (!kIsWeb) {
        final root = await getApplicationDocumentsDirectory();
        final att = Directory('${root.path}/attachments');
        if (await att.exists()) {
          await for (final entity in att.list(followLinks: false)) {
            if (entity is! Directory) continue;
            await for (final id in entity.list(followLinks: false)) {
              if (id is! Directory) continue;
              await for (final f in id.list(followLinks: false)) {
                if (f is! File) continue;
                final rel = '${entity.uri.pathSegments.last}/${id.uri.pathSegments.last}/${f.uri.pathSegments.last}';
                files.add(_CacheFile(rel, await f.length(), f.path));
              }
            }
          }
        }
        // 库重建备份（taozhu_ro_*.db，只读自愈时改名的旧库文件）：同步成功后纯冗余，可清理
        try {
          await for (final f in root.list(followLinks: false)) {
            if (f is! File) continue;
            final name = f.uri.pathSegments.last;
            if (name.startsWith('taozhu_ro_') && name.endsWith('.db')) {
              files.add(_CacheFile(name, await f.length(), f.path));
            }
          }
        } catch (_) {}
      }
    } catch (e) {
      toast(context, '扫描失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedCount == 0) return;
    final total = _files.where((f) => f.selected).fold<int>(0, (s, f) => s + f.size);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除已选文件'),
        content: Text('将删除 $_selectedCount 个文件（约 ${_fmtSize(total)}）：\n${_files.where((f) => f.selected).take(4).map((f) => f.name).join('\n')}${_selectedCount > 4 ? '\n…等' : ''}\n\n删除后不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).extension<TaozhuColors>()!.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      // 通用：附件副本（kind=attach）/ 头像缓存（avatar）/ 库重建备份（dbbak）——
      // path 是真实文件路径，直接按文件删除（逐张独立删除）
      final fileDeletes = _files
          .where((f) => f.selected && (f.kind == 'attach' || f.kind == 'avatar' || f.kind == 'dbbak') && f.path.isNotEmpty)
          .map((f) => f.path)
          .toList();
      var fileDelCount = 0;
      for (final p in fileDeletes) {
        try {
          final f = File(p);
          if (await f.exists()) {
            await f.delete();
            fileDelCount++;
          }
        } catch (_) {}
      }
      // 安装包/压缩包/临时文件：按名删除（下载目录/临时目录）
      final names = _files
          .where((f) => f.selected && (f.kind == 'apk' || f.kind == 'zip' || f.kind == 'other'))
          .map((f) => f.name)
          .toList();
      // 全选了且仅附件类 → 不再走系统下载器
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android && names.isNotEmpty) {
        // Android 走系统下载器：删文件 + 移除下载记录（通知栏通知一并消失）
        final n = await _dlChannel.invokeMethod<int>('deleteFiles', {'names': names}) ?? 0;
        toast(context, fileDelCount > 0 ? '已删除 $fileDelCount 个附件/缓存 + $n 个文件' : '已删除 $n 个文件');
      } else if (!kIsWeb && names.isNotEmpty) {
        // 桌面：直接按名删除（下载目录/临时目录）
        var n = 0;
        Future<void> delIn(Directory? dir) async {
          if (dir == null || !await dir.exists()) return;
          await for (final f in dir.list(followLinks: false)) {
            if (f is! File) continue;
            if (names.contains(f.uri.pathSegments.last)) {
              await f.delete();
              n++;
            }
          }
        }

        await delIn(await getDownloadsDirectory());
        await delIn(await getTemporaryDirectory());
        toast(context, fileDelCount > 0 ? '已删除 $fileDelCount 个附件/缓存 + $n 个文件' : '已删除 $n 个文件');
      }
      // 仅选了附件/缓存类（无 apk/zip/other）或 Web：不触发下载器/下载目录逻辑
      if (fileDelCount > 0 && names.isEmpty) {
        toast(context, '已删除 $fileDelCount 个附件/缓存文件');
      }
      await _load();
    } catch (e) {
      toast(context, '删除失败：${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _fmtSize(int bytes) {
    if (bytes <= 0) return '未知大小';
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  int get _totalSize => _files.fold<int>(0, (s, f) => s + f.size);

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(title: const Text('存储清理')),
      body: Column(
        children: [
          // 统计卡
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _files.isEmpty ? '没有可清理的文件' : '共 ${_files.length} 项 · 约 ${_fmtSize(_totalSize)}',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    kIsWeb
                        ? 'Web 版无本地文件'
                        : '更新安装包（APK/Zip）、附件副本（逐张图片）、头像缓存、库重建备份与临时文件',
                    style: TextStyle(fontSize: 12, color: c.textSub),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _files.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.cleaning_services_outlined, size: 40, color: c.textSub.withOpacity(0.4)),
                            const SizedBox(height: 12),
                            Text('没有需要清理的文件', style: TextStyle(color: c.textSub)),
                          ],
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                        children: [
                          for (final g in const [
                            ('apk', '安装包（APK）', Icons.android),
                            ('zip', '压缩包（Zip）', Icons.archive_outlined),
                            ('attach', '附件副本（本地缓存）', Icons.image_outlined),
                            ('avatar', '头像缓存', Icons.account_circle_outlined),
                            ('dbbak', '库重建备份', Icons.storage_outlined),
                            ('other', '临时文件', Icons.description_outlined),
                          ])
                            if (_files.any((f) => f.kind == g.$1)) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
                                child: Row(
                                  children: [
                                    Icon(g.$3, size: 16, color: c.textSub),
                                    const SizedBox(width: 6),
                                    Text(g.$2, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textSub)),
                                    const Spacer(),
                                    // 本组内已选数（方便全选/删除前核对）
                                    Text('本组 ${_files.where((f) => f.kind == g.$1 && f.selected).length} 项已选',
                                        style: TextStyle(fontSize: 11, color: c.textSub)),
                                  ],
                                ),
                              ),
                              Container(
                                decoration: BoxDecoration(
                                  color: c.card,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Column(
                                  children: [
                                    for (final f in _files.where((f) => f.kind == g.$1))
                                      // 整行点击=勾选删除；APK 行尾独立「安装」按钮（CheckboxListTile 无 trailing，用 ListTile+Checkbox 组合）
                                      ListTile(
                                        dense: true,
                                        // 附件副本：直接显示图片缩略图（不再笼统显示"N 张"）
                                        leading: f.kind == 'attach'
                                            ? _thumb(f)
                                            : Icon(f.kind == 'apk' ? Icons.android : (f.kind == 'zip' ? Icons.archive_outlined : (f.kind == 'avatar' ? Icons.account_circle_outlined : (f.kind == 'dbbak' ? Icons.storage_outlined : Icons.insert_drive_file_outlined))),
                                            color: f.kind == 'apk' ? c.success : c.primary),
                                        title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                        subtitle: Text(
                                          switch (f.kind) {
                                            'apk' => '${_fmtSize(f.size)} · APK 安装包',
                                            'zip' => '${_fmtSize(f.size)} · 压缩包',
                                            'attach' => '${_fmtSize(f.size)} · 附件图片',
                                            'avatar' => '${_fmtSize(f.size)} · 头像缓存',
                                            'dbbak' => '${_fmtSize(f.size)} · 本地库重建备份',
                                            _ => '${_fmtSize(f.size)} · 临时文件',
                                          },
                                          style: TextStyle(fontSize: 12, color: c.textSub),
                                        ),
                                        onTap: () => setState(() => f.selected = !f.selected),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (f.kind == 'apk')
                                              IconButton(
                                                tooltip: '安装',
                                                icon: const Icon(Icons.system_update_alt_outlined, size: 20),
                                                color: c.primary,
                                                onPressed: () => _installFile(f),
                                              ),
                                            // 附件副本：查看图片（本地全屏预览）
                                            if (f.kind == 'attach')
                                              IconButton(
                                                tooltip: '查看图片',
                                                icon: const Icon(Icons.photo_outlined, size: 20),
                                                color: c.primary,
                                                onPressed: () => _viewAttach(f),
                                              ),
                                            Checkbox(
                                              value: f.selected,
                                              onChanged: (v) => setState(() => f.selected = v ?? false),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                        ],
                      ),
          ),
          // 底部操作栏
          if (_files.isNotEmpty && !_loading)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                final sel = !_allSelected;
                                for (final f in _files) {
                                  f.selected = sel;
                                }
                              }),
                      child: Text(_allSelected ? '取消全选' : '全选'),
                    ),
                    const Spacer(),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: c.danger,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _busy || _selectedCount == 0 ? null : _deleteSelected,
                      child: Text(_busy ? '删除中…' : '删除已选（$_selectedCount）'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 本地附件图片全屏查看器：黑底 PageView，顶部显示 第 x/N 张，可左右滑动
class _LocalPhotoViewer extends StatefulWidget {
  const _LocalPhotoViewer({required this.files, this.initialPath});
  final List<File> files;
  final String? initialPath; // 打开时定位到该图片（可选）
  @override
  State<_LocalPhotoViewer> createState() => _LocalPhotoViewerState();
}

class _LocalPhotoViewerState extends State<_LocalPhotoViewer> {
  late int _index;
  late final PageController _pageCtrl;

  @override
  void initState() {
    super.initState();
    _index = 0;
    if (widget.initialPath != null) {
      final i = widget.files.indexWhere((f) => f.path == widget.initialPath);
      if (i >= 0) _index = i;
    }
    _pageCtrl = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1}/${widget.files.length}',
            style: const TextStyle(fontSize: 15)),
      ),
      body: PageView.builder(
        controller: _pageCtrl,
        itemCount: widget.files.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => Center(
          child: Image.file(
            widget.files[i],
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined,
                color: Color(0xFF9CA3AF), size: 40),
          ),
        ),
      ),
    );
  }
}