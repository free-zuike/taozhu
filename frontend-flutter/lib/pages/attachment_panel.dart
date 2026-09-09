import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../api.dart';
import 'router.dart';

/// 交易附件面板：查看/新增/删除凭证图片。
/// 双存储：手机本地副本（应用文档目录 attachments/…）+ 云端 R2（经后端代理读取），互不丢失。
class AttachmentPanel extends StatefulWidget {
  const AttachmentPanel({super.key, required this.entity, required this.id, required this.title});
  final String entity; // sale | purchase | payment
  final String id;
  final String title;
  @override
  State<AttachmentPanel> createState() => _AttachmentPanelState();
}

class _Item {
  _Item(this.key, this.localPath);
  final String key;
  final String? localPath;
}

class _AttachmentPanelState extends State<AttachmentPanel> {
  List<_Item> _items = [];
  bool _loading = true;
  String _base = '';
  String _token = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _base = await Api.instance.getBase();
    _token = await Api.instance.getTokenValue() ?? '';
    await _load();
  }

  String get _subPath => 'attachments/${widget.entity}/${widget.id}';

  Future<Directory> _dir() async {
    final root = await getApplicationDocumentsDirectory();
    final d = Directory('${root.path}/${_subPath}');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<void> _load() async {
    try {
      final d = await Api.instance.get('/attachments?entity=${widget.entity}&id=${widget.id}');
      final keys = ((d['attachments'] as List?) ?? [])
          .cast<Map<String, dynamic>>()
          .map((x) => '${x['key']}');
      final dir = await _dir();
      final locals = <String, String>{};
      for (final f in dir.listSync()) {
        if (f is File) locals[f.uri.pathSegments.last] = f.path;
      }
      if (!mounted) return;
      setState(() {
        _items = keys.map((key) {
          final name = key.split('/').last;
          return _Item(key, locals[name]);
        }).toList();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _add() async {
    final src = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
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
      ),
    );
    if (src == null) return;
    final picked = await ImagePicker().pickImage(source: src, maxWidth: 1600, imageQuality: 85);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    toast(context, '上传中…');
    try {
      final d = await Api.instance.uploadPhoto(
        '/attachments?entity=${widget.entity}&id=${widget.id}',
        bytes,
        'photo.jpg',
      );
      final key = '${d['key']}';
      // 本地副本（双存储）：断网也能看
      final dir = await _dir();
      final name = key.split('/').last;
      await File('${dir.path}/$name').writeAsBytes(bytes);
      toast(context, '已添加附件');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _delete(_Item it) async {
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
    try {
      await Api.instance.delete('/attachments?key=${it.key}');
      final lp = it.localPath;
      if (lp != null) {
        final f = File(lp);
        if (f.existsSync()) f.deleteSync();
      }
      toast(context, '已删除');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Widget _thumb(_Item it) {
    final local = it.localPath;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (local != null && File(local).existsSync())
          Image.file(File(local), fit: BoxFit.cover)
        else
          Image.network(
            '$_base/api/v1/attachments/${it.key}',
            fit: BoxFit.cover,
            headers: _token.isEmpty ? null : {'Authorization': 'Bearer $_token'},
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image_outlined, color: Color(0xFFC0C4CC)),
            ),
          ),
        Positioned(
          right: 0,
          top: 0,
          child: GestureDetector(
            onTap: () => _delete(it),
            child: Container(
              color: Colors.black.withOpacity(0.45),
              padding: const EdgeInsets.all(4),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return SafeArea(
      child: SizedBox(
        height: h * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.title,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    tooltip: '添加附件',
                    icon: const Icon(Icons.add_photo_alternate_outlined, color: Color(0xFF409EFF)),
                    onPressed: _add,
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _items.isEmpty
                      ? const Center(
                          child: Text('暂无附件，点右上角添加\n（拍照扫描 / 相册选择）',
                              textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
                      : GridView.builder(
                          padding: const EdgeInsets.all(16),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                          ),
                          itemCount: _items.length,
                          itemBuilder: (_, i) => ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: _thumb(_items[i]),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 打开附件面板（底部弹出）
void showAttachmentPanel(BuildContext context, String entity, String id, String title) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => AttachmentPanel(entity: entity, id: id, title: title),
  );
}