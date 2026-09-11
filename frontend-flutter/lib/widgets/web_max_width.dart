import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Web 大屏时约束内容最大宽度居中（App 端不受影响，保持手机排版密度）
Widget webMaxWidth(Widget child, {double maxWidth = 640}) {
  if (!kIsWeb) return child;
  return Center(
    child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
  );
}