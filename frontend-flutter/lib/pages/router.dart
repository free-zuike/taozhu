import 'package:flutter/material.dart';

/// 打开二级页（push 压栈：系统返回键回上一页）
void goPage(BuildContext context, Widget page) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
}

/// 统一提示浮层：深色圆角窄胶囊，水平居中、宽度自适应，底部抬高避开导航，连续提示不排队
void toast(BuildContext context, String msg, {Duration duration = const Duration(seconds: 2)}) {
  final screenW = MediaQuery.of(context).size.width;
  // 窄条居中：小屏最多留 24 边距，大屏封顶 340（不占满宽度）
  final w = screenW > 480 ? 340.0 : (screenW - 48).clamp(120.0, screenW - 48);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(
        msg,
        style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.3),
        textAlign: TextAlign.center,
      ),
      duration: duration,
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xE62C2C2E),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      width: w,
      margin: const EdgeInsets.only(bottom: 88),
    ));
}
