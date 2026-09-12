import 'dart:io';
import 'dart:typed_data';
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

/// 移动/桌面暂不支持界面内选 JSON 文件（后续可接 file_picker），返回 null 由调用方提示
Future<String?> pickTextFile() async => null;