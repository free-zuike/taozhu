import 'dart:html' as html;
import 'dart:typed_data';

/// Web：直接触发浏览器下载（Blob + <a download>）。
/// 不用 Web Share API——`Navigator.share()` 在非用户手势/不受支持环境会报 Permission denied。
Future<void> saveBytes(Uint8List bytes, String filename, String mime, String text) async {
  final blob = html.Blob([bytes], mime);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)..download = filename;
  anchor.click();
  html.Url.revokeObjectUrl(url);
}

/// Web：选择本地 .json 文件并读为文本（导入备份用）；取消返回 null
Future<String?> pickTextFile() async {
  final input = html.FileUploadInputElement()..accept = '.json,application/json';
  input.click();
  await input.onChange.first;
  final file = input.files?.first;
  if (file == null) return null;
  return await file.text();
}