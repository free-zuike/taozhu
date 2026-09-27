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

  static TaozhuColors light(Color primary) => TaozhuColors(
        primary: primary,
        card: Colors.white,
        field: const Color(0xFFF5F7FA),
        textMain: const Color(0xFF111827),
        textSub: const Color(0xFF909399),
        danger: const Color(0xFFEF4444),
        success: const Color(0xFF22C55E),
        warning: const Color(0xFFF59E0B),
        divider: const Color(0x0F000000),
      );

  static TaozhuColors dark(Color primary) => TaozhuColors(
        primary: primary,
        card: const Color(0xFF1C1C1E),
        field: const Color(0xFF2C2C2E),
        textMain: Colors.white,
        textSub: const Color(0xFF9CA3AF),
        danger: const Color(0xFFF87171),
        success: const Color(0xFF34D399),
        warning: const Color(0xFFFBBF24),
        divider: const Color(0x1FFFFFFF),
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

/// 亮色主题（primary=当前配色主题的主色）
ThemeData buildLightTheme(Color primary) {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: primary, primary: primary),
    useMaterial3: true,
    scaffoldBackgroundColor: Colors.transparent, // 全局背景渐变由 MaterialApp.builder 提供
    appBarTheme: const AppBarTheme(backgroundColor: Colors.white, elevation: 0.5, centerTitle: true),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    extensions: [TaozhuColors.light(primary)],
  );
}

/// 暗色主题
ThemeData buildDarkTheme(Color primary) {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: primary, brightness: Brightness.dark, primary: primary),
    useMaterial3: true,
    scaffoldBackgroundColor: Colors.transparent,
    appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1E1E1E), elevation: 0.5, centerTitle: true),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    cardTheme: CardThemeData(
      color: const Color(0xFF1E1E1E),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    extensions: [TaozhuColors.dark(primary)],
  );
}

// ============ 静态主题（配色 + 背景） ============

/// 一套配色主题：主色（亮/暗各一档）+ 亮色下的背景渐变（"静态背景"效果）
class ThemePreset {
  const ThemePreset({
    required this.id,
    required this.name,
    required this.lightPrimary,
    required this.darkPrimary,
    required this.bgGradient,
  });
  final String id;
  final String name;
  final Color lightPrimary;
  final Color darkPrimary;
  final List<Color> bgGradient;
}

/// 预置静态主题：默认蓝 / 陶朱红 / 富贵金 / 墨绿 / 藏青
const List<ThemePreset> kThemePresets = [
  ThemePreset(
    id: 'default',
    name: '默认蓝',
    lightPrimary: Color(0xFF409EFF),
    darkPrimary: Color(0xFF60A5FA),
    bgGradient: [Color(0xFFF4F9FF), Color(0xFFE6F0FB)],
  ),
  ThemePreset(
    id: 'zhuhong',
    name: '陶朱红',
    lightPrimary: Color(0xFFC04633),
    darkPrimary: Color(0xFFE0705A),
    bgGradient: [Color(0xFFFDF3F1), Color(0xFFF8E4DE)],
  ),
  ThemePreset(
    id: 'gold',
    name: '富贵金',
    lightPrimary: Color(0xFFB8860B),
    darkPrimary: Color(0xFFD9A62E),
    bgGradient: [Color(0xFFFDF7E6), Color(0xFFF7EDD2)],
  ),
  ThemePreset(
    id: 'green',
    name: '墨绿',
    lightPrimary: Color(0xFF2F7D63),
    darkPrimary: Color(0xFF3FA37F),
    bgGradient: [Color(0xFFECF8F2), Color(0xFFE0EFE7)],
  ),
  ThemePreset(
    id: 'navy',
    name: '藏青',
    lightPrimary: Color(0xFF2B5FD9),
    darkPrimary: Color(0xFF5B82EE),
    bgGradient: [Color(0xFFEEF2FD), Color(0xFFE3E9FA)],
  ),
];

ThemePreset themePresetById(String id) =>
    kThemePresets.firstWhere((p) => p.id == id, orElse: () => kThemePresets.first);

/// 全局主题配置（配色 preset + 背景开关），改后即时生效并持久化
class ThemeConfig extends ChangeNotifier {
  ThemeConfig._();
  static final ThemeConfig instance = ThemeConfig._();
  static const _kPreset = 'theme_preset_id';
  static const _kBg = 'theme_bg_enabled';

  String _presetId = 'default';
  bool _bgEnabled = true;

  String get presetId => _presetId;
  ThemePreset get preset => themePresetById(_presetId);
  bool get bgEnabled => _bgEnabled;

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _presetId = p.getString(_kPreset) ?? 'default';
    _bgEnabled = p.getBool(_kBg) ?? true;
    notifyListeners();
  }

  Future<void> setPreset(String id) async {
    if (id == _presetId) return;
    _presetId = id;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(_kPreset, id);
  }

  Future<void> setBgEnabled(bool v) async {
    if (v == _bgEnabled) return;
    _bgEnabled = v;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_kBg, v);
  }
}

/// 全局背景包装：MaterialApp.builder 使用——Scaffold 透明，背景渐变透出（"静态背景"）
Widget themeBackgroundWrap(BuildContext context, Widget? child) {
  if (child == null) return const SizedBox.shrink();
  final cfg = ThemeConfig.instance;
  if (!cfg.bgEnabled) return child;
  final dark = Theme.of(context).brightness == Brightness.dark;
  final colors = dark ? const [Color(0xFF17181C), Color(0xFF101216)] : cfg.preset.bgGradient;
  return Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(colors: colors, begin: Alignment.topCenter, end: Alignment.bottomCenter),
    ),
    child: child,
  );
}
