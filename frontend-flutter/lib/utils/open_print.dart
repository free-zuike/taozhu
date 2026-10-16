/// 打印/图片入口：Web 用 window.open 打开打印路由或对账单图片（图片可打印/保存）；
/// 原生端打开打印路由用系统浏览器，图片走保存分享（no-op）——条件导入保证全平台可编译。
import 'dart:typed_data';
import 'open_print_stub.dart'
    if (dart.library.html) 'open_print_web.dart';

Future<void> openPrintUrl(String url) => openPrintImpl(url);

Future<void> openPrintImageBytes(Uint8List bytes) => openPrintImageImpl(bytes);
