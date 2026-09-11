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
      final names = _files.where((f) => f.selected).map((f) => f.name).toList();
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        // Android 走系统下载器：删文件 + 移除下载记录（通知栏通知一并消失）
        final n = await _dlChannel.invokeMethod<int>('deleteFiles', {'names': names}) ?? 0;
        toast(context, '已删除 $n 个文件');
      } else if (!kIsWeb) {
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
                          Container(
                            decoration: BoxDecoration(
                              color: c.card,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              children: [
                                for (final f in _files)
                                  // InkWell 整行点击=安装（APK）；右侧 checkbox 仍用于勾选删除
                                  InkWell(
                                    onTap: () => _installFile(f),
                                    child: CheckboxListTile(
                                      dense: true,
                                      value: f.selected,
                                      secondary: Icon(Icons.insert_drive_file_outlined, color: c.primary),
                                      title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                      subtitle: Text(
                                        f.name.toLowerCase().endsWith('.apk') && f.path.isNotEmpty
                                            ? '${_fmtSize(f.size)} · 点击安装'
                                            : _fmtSize(f.size),
                                        style: TextStyle(fontSize: 12, color: c.textSub),
                                      ),
                                      onChanged: (v) => setState(() => f.selected = v ?? false),
                                    ),
                                  ),
                              ],
                            ),
                          ),
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