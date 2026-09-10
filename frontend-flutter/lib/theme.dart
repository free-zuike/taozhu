import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局主题模式（跟随系统 / 白天 / 黑夜），MaterialApp 监听切换
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);

/// 切换主题模式并持久化（'system' | 'light' | 'dark'）
Future<void> setThemeMode(ThemeMode mode) async {
  themeNotifier.value = mode;
  final p = await SharedPreferences.getInstance();
  final key = mode == ThemeMode.dark ? 'dark' : (mode == ThemeMode.light ? 'light' : 'system');
  await p.setString('theme_mode', key);
}

/// 启动时恢复上次主题模式（默认跟随系统）
ThemeMode restoreThemeMode(String? saved) {
  if (saved == 'dark') return ThemeMode.dark;
  if (saved == 'light') return ThemeMode.light;
  return ThemeMode.system;
}

/// 主题语义色：页面统一从 `Theme.of(context).extension<TaozhuColors>()` 取色，
/// 不写死——后续换主题/加配色只需改这里（亮/暗两套色板）。
@immutable
class TaozhuColors extends ThemeExtension<TaozhuColors> {
  final Color primary; // 主色（品牌蓝）
  final Color card; // 卡片/区块底
  final Color field; // 输入框填充
  final Color textMain; // 主文本
  final Color textSub; // 次级文本
  final Color danger; // 错误/删除/出货金额
  final Color success; // 成功/收款
  final Color warning; // 预警
  final Color divider; // 分割线

  const TaozhuColors({
    required this.primary,
    required this.card,
    required this.field,
    required this.textMain,
    required this.textSub,
    required this.danger,
    required this.success,
    required this.warning,
    required this.divider,
  });

  static const light = TaozhuColors(
    primary: Color(0xFF409EFF),
    card: Colors.white,
    field: Color(0xFFF5F7FA),
    textMain: Color(0xFF111827),
    textSub: Color(0xFF909399),
    danger: Color(0xFFEF4444),
    success: Color(0xFF22C55E),
    warning: Color(0xFFF59E0B),
    divider: Color(0x0F000000),
  );

  static const dark = TaozhuColors(
    primary: Color(0xFF60A5FA),
    card: Color(0xFF1C1C1E),
    field: Color(0xFF2C2C2E),
    textMain: Colors.white,
    textSub: Color(0xFF9CA3AF),
    danger: Color(0xFFF87171),
    success: Color(0xFF34D399),
    warning: Color(0xFFFBBF24),
    divider: Color(0x1FFFFFFF),
  );

  @override
  TaozhuColors copyWith({
    Color? primary,
    Color? card,
    Color? field,
    Color? textMain,
    Color? textSub,
    Color? danger,
    Color? success,
    Color? warning,
    Color? divider,
  }) {
    return TaozhuColors(
      primary: primary ?? this.primary,
      card: card ?? this.card,
      field: field ?? this.field,
      textMain: textMain ?? this.textMain,
      textSub: textSub ?? this.textSub,
      danger: danger ?? this.danger,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      divider: divider ?? this.divider,
    );
  }

  @override
  TaozhuColors lerp(ThemeExtension<TaozhuColors>? other, double t) {
    if (other is! TaozhuColors) return this;
    return TaozhuColors(
      primary: Color.lerp(primary, other.primary, t)!,
      card: Color.lerp(card, other.card, t)!,
      field: Color.lerp(field, other.field, t)!,
      textMain: Color.lerp(textMain, other.textMain, t)!,
      textSub: Color.lerp(textSub, other.textSub, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
    );
  }
}

/// 亮色主题
ThemeData buildLightTheme() {
  const primary = Color(0xFF409EFF);
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: primary, primary: primary),
    useMaterial3: true,
    scaffoldBackgroundColor: const Color(0xFFF5F7FA),
    appBarTheme: const AppBarTheme(backgroundColor: Colors.white, elevation: 0.5, centerTitle: true),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    extensions: [TaozhuColors.light],
  );
}

/// 暗色主题
ThemeData buildDarkTheme() {
  const primary = Color(0xFF60A5FA);
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: primary, brightness: Brightness.dark, primary: primary),
    useMaterial3: true,
    scaffoldBackgroundColor: const Color(0xFF121212),
    appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1E1E1E), elevation: 0.5, centerTitle: true),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    cardTheme: CardThemeData(
      color: const Color(0xFF1E1E1E),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    extensions: [TaozhuColors.dark],
  );
}
