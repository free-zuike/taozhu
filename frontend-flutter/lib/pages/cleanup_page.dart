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
  int size; // 字节；0=未知
  bool selected = false;
  _CacheFile(this.name, this.size, [this.path = '']);

  /// 文件类型：apk=安装包 / zip=压缩包 / attach=附件副本（本地缓存目录）/ other=其他临时文件
  String get kind {
    final n = name.toLowerCase();
    if (n.endsWith('.apk')) return 'apk';
    if (n.endsWith('.zip')) return 'zip';
    if (n.contains('/')) return 'attach'; // 附件单元名形如 sale/s1（entity/id）
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

  /// 查看附件副本单元内全部图片（本地全屏预览，黑底左右滑动）
  Future<void> _viewAttach(_CacheFile f) async {
    final dir = Directory(f.path);
    if (!await dir.exists()) {
      toast(context, '附件目录不存在（可能已清理）');
      return;
    }
    final files = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .where((x) => RegExp(r'\.(jpg|jpeg|png|webp|gif)$', caseSensitive: false).hasMatch(x.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) {
      toast(context, '该附件单元无图片文件');
      return;
    }
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _LocalPhotoViewer(files: files),
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
      // 退出登录/切换账号会清空，但历史遗留/未清理的副本可在这里按单元删除
      if (!kIsWeb) {
        final root = await getApplicationDocumentsDirectory();
        final att = Directory('${root.path}/attachments');
        if (await att.exists()) {
          await for (final entity in att.list(followLinks: false)) {
            if (entity is! Directory) continue;
            await for (final id in entity.list(followLinks: false)) {
              if (id is! Directory) continue;
              var size = 0;
              var count = 0;
              await for (final f in id.list(followLinks: false)) {
                if (f is File) {
                  size += await f.length();
                  count++;
                }
              }
              if (count > 0) {
                final rel = '${entity.uri.pathSegments.last}/${id.uri.pathSegments.last}';
                files.add(_CacheFile('$rel ($count 张)', size, id.path));
              }
            }
          }
        }
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
      // 通用：附件副本（kind=attach）按完整目录删除（path 即 attachments/{entity}/{id}/）
      final attachDirs = _files
          .where((f) => f.kind == 'attach' && f.selected && f.path.isNotEmpty)
          .map((f) => f.path)
          .toList();
      for (final dir in attachDirs) {
        try {
          final d = Directory(dir);
          if (await d.exists()) await d.delete(recursive: true);
        } catch (_) {}
      }
      final names = _files.where((f) => f.selected && f.kind != 'attach').map((f) => f.name).toList();
      // 全选了且仅附件 → 不再走系统下载器
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android && names.isNotEmpty) {
        // Android 走系统下载器：删文件 + 移除下载记录（通知栏通知一并消失）
        final n = await _dlChannel.invokeMethod<int>('deleteFiles', {'names': names}) ?? 0;
        toast(context, attachDirs.isNotEmpty ? '已删除 ${attachDirs.length} 个附件副本 + $n 个文件' : '已删除 $n 个文件');
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
        toast(context, '已删除 $n 个文件');
      }
      // 仅选了附件副本（无 apk/zip/other）或 Web：不触发下载器/下载目录逻辑
      if (attachDirs.isNotEmpty && names.isEmpty) {
        toast(context, '已删除 ${attachDirs.length} 个附件副本');
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
                        : '更新安装包（APK/Zip）与临时文件；后续可扩展清理无效附件等',
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
                                        leading: Icon(f.kind == 'apk' ? Icons.android : (f.kind == 'zip' ? Icons.archive_outlined : Icons.insert_drive_file_outlined),
                                            color: f.kind == 'apk' ? c.success : c.primary),
                                        title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                        subtitle: Text(
                                          switch (f.kind) {
                                            'apk' => '${_fmtSize(f.size)} · APK 安装包',
                                            'zip' => '${_fmtSize(f.size)} · 压缩包',
                                            'attach' => '${_fmtSize(f.size)} · 附件本地副本',
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
                                            // 附件副本：查看单元内图片（本地全屏预览）
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
  const _LocalPhotoViewer({required this.files});
  final List<File> files;
  @override
  State<_LocalPhotoViewer> createState() => _LocalPhotoViewerState();
}

class _LocalPhotoViewerState extends State<_LocalPhotoViewer> {
  int _index = 0;
  final _pageCtrl = PageController();

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