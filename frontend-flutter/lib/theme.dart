import 'dart:math';

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
    scaffoldBackgroundColor: Colors.transparent, // 全局背景（渐变/图案）由 MaterialApp.builder 提供
    // AppBar 透明：顶部状态栏+标题区透出背景图案（对齐"头部皮肤"形态，列表在 AppBar 之下滚动不穿透）
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      foregroundColor: primary,
    ),
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
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      foregroundColor: primary,
    ),
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
  static const _kSkin = 'theme_skin_id';

  String _presetId = 'default';
  bool _bgEnabled = true;
  String _skinId = ''; // ''=渐变背景；'none'=纯色；其余=kSkinPatterns 的 id

  String get presetId => _presetId;
  ThemePreset get preset => themePresetById(_presetId);
  bool get bgEnabled => _bgEnabled;
  String get skinId => _skinId;

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _presetId = p.getString(_kPreset) ?? 'default';
    _bgEnabled = p.getBool(_kBg) ?? true;
    _skinId = p.getString(_kSkin) ?? '';
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

  Future<void> setSkin(String id) async {
    if (id == _skinId) return;
    _skinId = id;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(_kSkin, id);
  }
}

/// 全局背景包装：MaterialApp.builder 使用——Scaffold 透明，背景（渐变/图案皮肤）透出
Widget themeBackgroundWrap(BuildContext context, Widget? child) {
  if (child == null) return const SizedBox.shrink();
  final cfg = ThemeConfig.instance;
  final dark = Theme.of(context).brightness == Brightness.dark;
  if (!cfg.bgEnabled) {
    // 纯色底（无背景功能时兜底，避免透明透黑）
    return Container(color: dark ? const Color(0xFF121212) : const Color(0xFFF5F7FA), child: child);
  }
  final preset = cfg.preset;
  final skin = skinPatternById(cfg.skinId);
  final colors = dark ? const [Color(0xFF17181C), Color(0xFF101216)] : preset.bgGradient;
  if (skin == null) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors, begin: Alignment.topCenter, end: Alignment.bottomCenter),
      ),
      child: child,
    );
  }
  // 图案皮肤：渐变底 + 图案层（painter 内部画底）
  return CustomPaint(
    painter: skin.build(preset.lightPrimary, dark),
    child: child,
  );
}

// ============ 背景图案皮肤（参考"主题背景"范式：图案随主题色派生，非照片） ============

/// 一款背景图案：id/名称/CustomPainter 工厂（画笔从主题主色派生配色）。
/// compact=true 用于缩略图/预览：底色鲜艳（对齐"头部皮肤=主题色底"）、图案对比强，一眼看清图形。
class SkinPattern {
  const SkinPattern(this.id, this.name, this.build);
  final String id;
  final String name;
  final CustomPainter Function(Color primary, bool dark, {bool compact}) build;
}

/// 预置图案：城市 / 波浪 / 云朵 / 樱花 / 星辰
const List<SkinPattern> kSkinPatterns = [
  SkinPattern('skyline', '城市', _SkylinePainter.new),
  SkinPattern('wave', '波浪', _WavePainter.new),
  SkinPattern('clouds', '云朵', _CloudsPainter.new),
  SkinPattern('sakura', '樱花', _SakuraPainter.new),
  SkinPattern('stars', '星辰', _StarsPainter.new),
];

/// 按 id 取图案；不存在返回 null（null=渐变/纯色背景）
SkinPattern? skinPatternById(String id) {
  for (final s in kSkinPatterns) {
    if (s.id == id) return s;
  }
  return null;
}

abstract class _BaseSkinPainter extends CustomPainter {
  _BaseSkinPainter(this.primary, this.dark, {this.compact = false});
  final Color primary;
  final bool dark;
  final bool compact;

  /// 底渐变：compact=主题色鲜亮版（图案对比强）；全屏=浅主题色（背景不抢内容）
  LinearGradient bottomGradient() {
    if (compact) {
      final top = dark ? const Color(0xFF23262E) : Color.lerp(primary, Colors.white, 0.28)!;
      final bottom = dark ? const Color(0xFF15181F) : Color.lerp(primary, Colors.white, 0.52)!;
      return LinearGradient(colors: [top, bottom], begin: Alignment.topCenter, end: Alignment.bottomCenter);
    }
    final top = dark ? const Color(0xFF1A1C22) : Color.lerp(primary, Colors.white, 0.80)!;
    final bottom = dark ? const Color(0xFF101216) : Color.lerp(primary, Colors.white, 0.60)!;
    return LinearGradient(colors: [top, bottom], begin: Alignment.topCenter, end: Alignment.bottomCenter);
  }

  /// 图案色：暗色=白系半透明；亮色=白混主题色（compact 默认更"白"对比强）
  Color ink(double opacity, [double whiteMix = 0.72]) =>
      dark ? Colors.white.withOpacity(opacity) : Color.lerp(primary, Colors.white, whiteMix)!.withOpacity(opacity);

  /// 强调色（亮窗/花心等）：亮色=琥珀金，暗色=亮金
  Color accent(double opacity) =>
      dark ? const Color(0xFFFFD76A).withOpacity(opacity) : const Color(0xFFE0A62E).withOpacity(opacity);

  @override
  bool shouldRepaint(covariant _BaseSkinPainter old) =>
      old.primary != primary || old.dark != dark || old.compact != compact;
}

/// 城市：渐变底 + 月亮光晕 + 远近两层楼群 + 随机亮窗
class _SkylinePainter extends _BaseSkinPainter {
  _SkylinePainter(super.primary, super.dark, {super.compact});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..shader = bottomGradient().createShader(Offset.zero & size));
    final rnd = Random(7);
    if (compact) {
      // 缩略图：图案铺满、对比强（月亮+双楼群一眼可见）
      canvas.drawCircle(Offset(size.width * 0.82, size.height * 0.18), size.height * 0.12, Paint()..color = ink(0.18, 0.98));
      canvas.drawCircle(Offset(size.width * 0.82, size.height * 0.18), size.height * 0.06, Paint()..color = ink(0.7, 1));
      _buildings(canvas, size, rnd, size.height * 0.68, 0.55, size.height * 0.24);
      _buildings(canvas, size, rnd, size.height * 0.88, 0.75, size.height * 0.3);
      canvas.drawRect(Rect.fromLTWH(0, size.height * 0.93, size.width, size.height * 0.07), Paint()..color = ink(0.6, 0.62));
      return;
    }
    // 全屏：图案集中在顶部约 55%（对齐头部皮肤，内容区下方保持浅色）
    canvas.drawCircle(Offset(size.width * 0.8, size.height * 0.1), size.height * 0.1, Paint()..color = ink(0.12, 0.98));
    canvas.drawCircle(Offset(size.width * 0.8, size.height * 0.1), size.height * 0.045, Paint()..color = ink(0.45, 1));
    _buildings(canvas, size, rnd, size.height * 0.34, 0.34, size.height * 0.16);
    _buildings(canvas, size, rnd, size.height * 0.48, 0.5, size.height * 0.2);
    canvas.drawRect(Rect.fromLTWH(0, size.height * 0.54, size.width, size.height * 0.46),
        Paint()..shader = bottomGradient().createShader(Offset(0, size.height * 0.54) & Size(size.width, size.height * 0.46)));
  }

  void _buildings(Canvas canvas, Size size, Random rnd, double baseY, double opacity, double maxH) {
    final paint = Paint()..color = ink(opacity, 0.62);
    final win = Paint()..color = accent(dark ? 0.9 : 0.95);
    double x = -size.width * 0.05;
    while (x < size.width * 1.05) {
      final w = size.width * (0.05 + rnd.nextDouble() * 0.07);
      final h = maxH * (0.4 + rnd.nextDouble() * 1.0);
      canvas.drawRect(Rect.fromLTWH(x, baseY - h, w, h), paint);
      // 亮窗：两列随机
      for (var col = 0; col < 2; col++) {
        final wx = x + w * 0.25 + col * w * 0.4;
        for (var row = 0; row < 6; row++) {
          if (rnd.nextDouble() < 0.42) {
            final wy = baseY - h + h * 0.15 + row * h * 0.14;
            canvas.drawRect(Rect.fromLTWH(wx, wy, w * 0.08, h * 0.045), win);
          }
        }
      }
      x += w * (1 + rnd.nextDouble() * 0.35);
    }
  }
}

/// 波浪：多层正弦波纹（远近错落）+ 底部色带
class _WavePainter extends _BaseSkinPainter {
  _WavePainter(super.primary, super.dark, {super.compact});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..shader = bottomGradient().createShader(Offset.zero & size));
    final layers = compact ? <(double, double, double)>[(0.52, 0.18, 0.5), (0.72, 0.13, 0.66), (0.9, 0.09, 0.82)]
        : <(double, double, double)>[(0.38, 0.13, 0.26), (0.56, 0.1, 0.38), (0.72, 0.07, 0.5)];
    final path = Path();
    for (final (baseY, amp, op) in layers) {
      path.reset();
      final wl = size.width / 2.2;
      path.moveTo(0, size.height * baseY);
      for (double x = 0; x <= size.width; x += 4) {
        path.lineTo(x, size.height * baseY + size.height * amp * sin((x / wl) * pi * 2));
      }
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
      path.close();
      canvas.drawPath(path, Paint()..color = ink(op, 0.6));
    }
    // 波峰高光线
    canvas.drawLine(
        Offset(0, size.height * (compact ? 0.52 : 0.38)),
        Offset(size.width, size.height * (compact ? 0.52 : 0.38) + size.height * 0.02),
        Paint()..color = ink(0.5, 0.95)..strokeWidth = 2);
  }
}

/// 云朵：数朵低透明椭圆云（随机位置）缀在渐变底上
class _CloudsPainter extends _BaseSkinPainter {
  _CloudsPainter(super.primary, super.dark, {super.compact});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..shader = bottomGradient().createShader(Offset.zero & size));
    final rnd = Random(21);
    final n = compact ? 6 : 5;
    for (var i = 0; i < n; i++) {
      final cx = rnd.nextDouble() * size.width;
      final cy = size.height * (compact ? 0.14 + rnd.nextDouble() * 0.7 : 0.08 + rnd.nextDouble() * 0.45);
      final s = size.width * (compact ? 0.13 + rnd.nextDouble() * 0.08 : 0.08 + rnd.nextDouble() * 0.06);
      final p = Paint()..color = ink(compact ? 0.42 + rnd.nextDouble() * 0.16 : 0.22 + rnd.nextDouble() * 0.1, 0.96);
      canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy), width: s * 1.6, height: s * 0.6), p);
      canvas.drawOval(Rect.fromCenter(center: Offset(cx - s * 0.35, cy + s * 0.1), width: s * 1.0, height: s * 0.45), p);
      canvas.drawOval(Rect.fromCenter(center: Offset(cx + s * 0.38, cy + s * 0.12), width: s * 0.9, height: s * 0.4), p);
    }
  }
}

/// 樱花：主题色小花（五瓣圆点）+ 花蕊，随机散布
class _SakuraPainter extends _BaseSkinPainter {
  _SakuraPainter(super.primary, super.dark, {super.compact});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..shader = bottomGradient().createShader(Offset.zero & size));
    final rnd = Random(52);
    final n = compact ? 24 : 20;
    for (var i = 0; i < n; i++) {
      final cx = rnd.nextDouble() * size.width;
      final cy = size.height * (compact ? 0.3 + rnd.nextDouble() * 0.62 : 0.35 + rnd.nextDouble() * 0.5);
      final r = size.width * (compact ? 0.013 + rnd.nextDouble() * 0.014 : 0.009 + rnd.nextDouble() * 0.011);
      final petal = Paint()..color = ink(compact ? 0.5 + rnd.nextDouble() * 0.16 : 0.3 + rnd.nextDouble() * 0.12, 0.78);
      final center = Paint()..color = accent(0.85);
      for (var k = 0; k < 5; k++) {
        final a = k * 2 * pi / 5;
        canvas.drawCircle(Offset(cx + cos(a) * r * 0.8, cy + sin(a) * r * 0.8), r * 0.55, petal);
      }
      canvas.drawCircle(Offset(cx, cy), r * 0.32, center);
    }
  }
}

/// 星辰：深色渐变 + 大小星点（十字星光大星）
class _StarsPainter extends _BaseSkinPainter {
  _StarsPainter(super.primary, super.dark, {super.compact});
  @override
  void paint(Canvas canvas, Size size) {
    final top = dark ? const Color(0xFF14161C) : Color.lerp(primary, Colors.white, 0.62)!;
    final bottom = dark ? const Color(0xFF0C0E12) : Color.lerp(primary, Colors.white, 0.38)!;
    canvas.drawRect(Offset.zero & size,
        Paint()..shader = LinearGradient(colors: [top, bottom], begin: Alignment.topCenter, end: Alignment.bottomCenter).createShader(Offset.zero & size));
    final rnd = Random(9);
    final n = compact ? 52 : 40;
    for (var i = 0; i < n; i++) {
      final cx = rnd.nextDouble() * size.width;
      final cy = rnd.nextDouble() * size.height * 0.85;
      final r = size.width * (compact ? 0.005 + rnd.nextDouble() * 0.011 : 0.004 + rnd.nextDouble() * 0.008);
      canvas.drawCircle(Offset(cx, cy), r, Paint()..color = ink(compact ? 0.5 + rnd.nextDouble() * 0.3 : 0.3 + rnd.nextDouble() * 0.25, 0.98));
    }
    // 大星（十字星光）
    final big = compact ? [(0.18, 0.2), (0.72, 0.12), (0.85, 0.42), (0.4, 0.68)] : [(0.18, 0.2), (0.72, 0.12), (0.85, 0.42)];
    for (final (fx, fy) in big) {
      final c = Offset(size.width * fx, size.height * fy);
      final inkC = Paint()..color = ink(compact ? 0.85 : 0.6, 1);
      final cr = size.width * (compact ? 0.018 : 0.014);
      canvas.drawCircle(c, cr, inkC);
      canvas.drawLine(c - Offset(size.width * 0.04, 0), c + Offset(size.width * 0.04, 0), inkC..strokeWidth = 2);
      canvas.drawLine(c - Offset(0, size.width * 0.04), c + Offset(0, size.width * 0.04), inkC..strokeWidth = 2);
    }
  }
}
