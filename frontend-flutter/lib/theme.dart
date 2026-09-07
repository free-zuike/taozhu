import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局主题模式（亮/暗），MaterialApp 监听切换
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

Future<void> setThemeMode(ThemeMode mode) async {
  themeNotifier.value = mode;
  final p = await SharedPreferences.getInstance();
  await p.setString('theme_mode', mode == ThemeMode.dark ? 'dark' : 'light');
}
