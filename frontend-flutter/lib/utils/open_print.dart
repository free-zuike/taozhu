/// 打印入口：Web 用 window.open 打开打印路由（服务端生成自包含 HTML+自动打印）；
/// 原生端无打印能力（no-op）——条件导入保证全平台可编译。
import 'open_print_stub.dart'
    if (dart.library.html) 'open_print_web.dart';

Future<void> openPrintUrl(String url) => openPrintImpl(url);