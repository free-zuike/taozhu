import 'package:flutter/material.dart';

/// 打开二级页（push 压栈：系统返回键回上一页）
void goPage(BuildContext context, Widget page) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
}

/// 统一提示浮层：恒深色圆角胶囊（亮/暗主题一致），底部抬高避开导航，连续提示不排队
void toast(BuildContext context, String msg, {Duration duration = const Duration(seconds: 2)}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white, fontSize: 14)),
      duration: duration,
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xE62C2C2E),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 88),
    ));
}
