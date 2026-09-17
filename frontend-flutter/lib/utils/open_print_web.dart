import 'dart:html' as html;

/// Web 端打印：新窗口打开打印路由（服务端 HTML 自动触发 window.print）
Future<void> openPrintImpl(String url) async {
  html.window.open(url, '_blank');
}