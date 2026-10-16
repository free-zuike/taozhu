import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

/// Web 端打印：隐藏 iframe 加载打印路由（服务端 HTML 加载后自动 window.print()）。
/// 不跳新 tab——打印预览关闭后自动回到原界面，避免"跳转到打印页后原界面无法点击"。
Future<void> openPrintImpl(String url) async {
  html.document.getElementById('taozhu-print-frame')?.remove();
  final frame = html.IFrameElement()
    ..id = 'taozhu-print-frame'
    ..style.display = 'none'
    ..src = url;
  html.document.body?.append(frame);
  // 打印页 load 后由服务端 HTML 内联脚本自动触发 window.print()（打印 iframe 内容）；
  // 打印对话框关闭后延迟移除 iframe 防残留（30s 兜底）
  Timer(const Duration(seconds: 30), () {
    html.document.getElementById('taozhu-print-frame')?.remove();
  });
}

/// Web 端对账单图片：新窗口打开 PNG（浏览器可直接打印/右键保存；比 iframe 内
/// 自动 window.print() 稳定——部分浏览器拦截 iframe 里的打印调用导致"打印弹不出来"）。
Future<void> openPrintImageImpl(Uint8List bytes) async {
  final url = 'data:image/png;base64,${base64Encode(bytes)}';
  html.window.open(url, '_blank');
}
