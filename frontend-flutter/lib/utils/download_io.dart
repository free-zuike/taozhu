import 'dart:typed_data';
import 'package:share_plus/share_plus.dart';

/// 移动/桌面：经系统分享面板保存/分享文件
Future<void> saveBytes(Uint8List bytes, String filename, String mime, String text) async {
  await Share.shareXFiles([XFile.fromData(bytes, mimeType: mime, name: filename)], text: text);
}

/// 移动/桌面暂不支持界面内选 JSON 文件（后续可接 file_picker），返回 null 由调用方提示
Future<String?> pickTextFile() async => null;