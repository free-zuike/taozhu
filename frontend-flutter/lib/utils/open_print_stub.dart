import 'package:url_launcher/url_launcher.dart';

/// 原生端打印：系统浏览器打开打印页（服务端 HTML 自动调 window.print() 调出系统打印
/// 对话框——Android 可连接打印机/另存 PDF；iOS 走 AirPrint）。失败抛错由调用方提示。
Future<void> openPrintImpl(String url) async {
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  if (!ok) throw Exception('无法打开系统浏览器');
}
