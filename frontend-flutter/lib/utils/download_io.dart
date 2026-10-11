import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
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

/// 移动/桌面选择文件并读取文本（CSV/JSON 导入用）：调系统文件选择器（file_picker），
/// 读取所选文件内容（UTF-8；兼容 BOM）。用户取消/读取失败返回 null 由调用方提示。
/// （用户"要的是文件啊"——原生端此前无文件选择，改用 file_picker 真实选文件，对齐 Web）
Future<String?> pickTextFile() async {
  try {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'json', 'txt'],
      withData: true, // 直接拿字节（Android/iOS 无需持久化临时文件）
    );
    final file = result?.files.firstOrNull;
    if (file == null) return null;
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    final text = utf8.decode(bytes, allowMalformed: true).replaceFirst('\uFEFF', '').trim();
    return text.isEmpty ? null : text;
  } catch (_) {
    return null;
  }
}