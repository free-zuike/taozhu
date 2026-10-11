import 'dart:io';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 移动/桌面：先写真实临时文件再经系统分享面板分享。
/// 注意：直接 `XFile.fromData` 分享时，Android 等系统会收到随机 UUID 文件名
/// （如 xxx-xxxx-xxxx-xxxxxxxxxxxxx.xlsx），落盘为真实文件后文件名才能保留
/// （对账单/备份等导出依赖文件名）。
Future<void> saveBytes(Uint8List bytes, String filename, String mime, String text) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$filename');
  await file.writeAsBytes(bytes, flush: true);
  await Share.shareXFiles([XFile(file.path, mimeType: mime, name: filename)], text: text);
}

/// 移动/桌面选择文件并读取文本（CSV/JSON 导入用）：调系统文件选择器（file_selector 官方库），
/// 读取所选文件内容（UTF-8）。用户取消/读取失败返回 null 由调用方提示。
/// （用户"要的是文件啊"——原生端用系统文件选择器真实选文件，对齐 Web）
Future<String?> pickTextFile() async {
  try {
    const typeGroup = XTypeGroup(label: 'CSV/JSON/文本', extensions: ['csv', 'json', 'txt']);
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return null;
    final text = (await file.readAsString()).replaceFirst('\uFEFF', '').trim();
    return text.isEmpty ? null : text;
  } catch (_) {
    return null;
  }
}