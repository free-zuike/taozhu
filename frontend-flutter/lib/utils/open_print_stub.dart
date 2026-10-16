import 'dart:typed_data';
import 'package:url_launcher/url_launcher.dart';

/// 原生端打印：系统浏览器打开打印页（服务端 HTML 自动调 window.print() 调出系统打印
/// 对话框——Android 可连接打印机/另存 PDF；iOS 走 AirPrint）。失败抛错由调用方提示。
Future<void> openPrintImpl(String url) async {
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  if (!ok) throw Exception('无法打开系统浏览器');
}

/// 原生端对账单图片：不直接打开（平台无图片打印 API）——由调用方保存图片后
/// 用系统看图软件打开打印（no-op 保证全平台可编译）。
Future<void> openPrintImageImpl(Uint8List bytes) async {}
