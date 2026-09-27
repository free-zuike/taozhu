import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

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
    // 关闭 Material 默认点击/悬停/焦点高亮（水波纹+灰框叠层）：桌面端 hover/长按不再显示突兀阴影边框
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    scaffoldBackgroundColor: const Color(0xFFF6F7F9), // 不透明：防止手势返回时透出下层页面（背景图案由页面内部层展示）
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
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    scaffoldBackgroundColor: const Color(0xFF17181C), // 不透明：防止手势返回时透出下层页面
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
    _dirtyCache = p.getBool(_kDirty) ?? false;
    notifyListeners();
  }

  Future<void> setPreset(String id) async {
    if (id == _presetId) return;
    _presetId = id;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(_kPreset, id);
    unawaited(_markThemeDirty());
  }

  Future<void> setBgEnabled(bool v) async {
    if (v == _bgEnabled) return;
    _bgEnabled = v;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_kBg, v);
    unawaited(_markThemeDirty());
  }

  Future<void> setSkin(String id) async {
    if (id == _skinId) return;
    _skinId = id;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(_kSkin, id);
    unawaited(_markThemeDirty());
  }

  bool _applyingServer = false; // 服务器应用中不回传，防跨端回环
  static const _kDirty = 'theme_dirty';

  /// 主题有本地未同步修改（随下次同步上传服务器；App 不直连写数据库）
  Future<void> _markThemeDirty() async {
    _dirtyCache = true;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDirty, true);
  }

  bool get themeDirty => _dirtyCache;
  bool _dirtyCache = false;

  /// 同步时上传主题配置到服务器（由 SyncService.sync() 在同步入口调用）
  Future<void> pushTheme() async {
    if (_applyingServer || kIsWeb) return; // Web 直连保存，不走同步队列
    try {
      await Api.instance.put('/settings/theme_config',
          {'preset_id': _presetId, 'skin_id': _skinId, 'bg_enabled': _bgEnabled});
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kDirty, false);
      _dirtyCache = false;
    } catch (_) {}
  }

  /// 拉取服务器主题并应用（同步 pull / 其他端变更 WS 通知 theme_config）
  Future<void> pullTheme() async {
    _applyingServer = true;
    try {
      final d = await Api.instance.get('/settings/theme_config');
      final pid = '${d['preset_id'] ?? ''}';
      final sid = '${d['skin_id'] ?? ''}';
      final bg = d['bg_enabled'] == true;
      var changed = false;
      if (pid.isNotEmpty && pid != _presetId) { _presetId = pid; changed = true; }
      if (sid.isNotEmpty && sid != _skinId) { _skinId = sid; changed = true; }
      if (bg != _bgEnabled) { _bgEnabled = bg; changed = true; }
      if (changed) {
        final p = await SharedPreferences.getInstance();
        await p.setString(_kPreset, _presetId);
        await p.setString(_kSkin, _skinId);
        await p.setBool(_kBg, _bgEnabled);
        notifyListeners();
      }
    } catch (_) {
    } finally {
      _applyingServer = false;
    }
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

/// 页面内部背景层：渐变或图案皮肤（Scaffold 已不透明，页面如需露出背景在 body 底部垫此层）
Widget themePageBackground(BuildContext context) {
  final cfg = ThemeConfig.instance;
  final dark = Theme.of(context).brightness == Brightness.dark;
  if (!cfg.bgEnabled) {
    return ColoredBox(color: dark ? const Color(0xFF17181C) : const Color(0xFFF5F7FA));
  }
  final preset = cfg.preset;
  final skin = skinPatternById(cfg.skinId);
  if (skin == null) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: dark ? const [Color(0xFF17181C), Color(0xFF101216)] : preset.bgGradient,
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
    );
  }
  return CustomPaint(painter: skin.build(preset.lightPrimary, dark), size: Size.infinite);
}

/// AppBar 背景层：图案/渐变（AppBar 透明 + flexibleSpace，顶部露出主题背景而非纯色占位）
Widget appBarBackground(BuildContext context) {
  final cfg = ThemeConfig.instance;
  final dark = Theme.of(context).brightness == Brightness.dark;
  if (!cfg.bgEnabled) return const SizedBox.shrink();
  final preset = cfg.preset;
  final skin = skinPatternById(cfg.skinId);
  if (skin == null) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: dark ? const [Color(0xFF17181C), Color(0xFF101216)] : preset.bgGradient,
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
    );
  }
  return CustomPaint(painter: skin.build(preset.lightPrimary, dark), size: Size.infinite);
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
  SkinPattern('coin', '铜钱', _CoinPainter.new),
  SkinPattern('bamboo', '竹韵', _BambooPainter.new),
  SkinPattern('ledger', '账本', _LedgerPainter.new),
  SkinPattern('flow', '进销', _FlowPainter.new),
  SkinPattern('ripple', '涟漪', _RipplePainter.new),
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

  /// 底渐变：compact=主题色鲜亮版（图案对比强）；全屏=主题色浅版（不抢内容，但换主题色明显变化）
  LinearGradient bottomGradient() {
    if (compact) {
      final top = dark ? const Color(0xFF23262E) : Color.lerp(primary, Colors.white, 0.28)!;
      final bottom = dark ? const Color(0xFF15181F) : Color.lerp(primary, Colors.white, 0.52)!;
      return LinearGradient(colors: [top, bottom], begin: Alignment.topCenter, end: Alignment.bottomCenter);
    }
    final top = dark ? const Color(0xFF1A1C22) : Color.lerp(primary, Colors.white, 0.55)!;
    final bottom = dark ? const Color(0xFF101216) : Color.lerp(primary, Colors.white, 0.42)!;
    return LinearGradient(colors: [top, bottom], begin: Alignment.topCenter, end: Alignment.bottomCenter);
  }

  /// 图案色：暗色=白系半透明；亮色=主题色为主（混白少，随主题色相明显变化）
  Color ink(double opacity, [double whiteMix = 0.38]) =>
      dark ? Colors.white.withOpacity(opacity) : Color.lerp(primary, Colors.white, whiteMix)!.withOpacity(opacity);

  /// 强调色（亮窗/花心等）：随主题色派生（亮色=主题色压暗，暗色=主题色提亮）
  Color accent(double opacity) =>
      dark ? Color.lerp(primary, Colors.white, 0.55)!.withOpacity(opacity) : Color.lerp(primary, Colors.black, 0.22)!.withOpacity(opacity);

  @override
  bool shouldRepaint(covariant _BaseSkinPainter old) =>
      old.primary != primary || old.dark != dark || old.compact != compact;
}

/// 铜钱（陶朱财富）：方孔铜钱散落
class _CoinPainter extends _BaseSkinPainter {
  _CoinPainter(super.primary, super.dark, {super.compact});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..shader = bottomGradient().createShader(Offset.zero & size));
    final rnd = Random(11);
    final coins = compact ? 4 : 3;
    final r = size.width * (compact ? 0.085 : 0.05);
    for (var i = 0; i < coins; i++) {
      final cx = rnd.nextDouble() * size.width;
      final cy = size.height * (compact ? 0.2 + rnd.nextDouble() * 0.6 : 0.12 + rnd.nextDouble() * 0.3);
      final cr = r * (0.8 + rnd.nextDouble() * 0.5);
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = cr * 0.13
        ..color = ink(compact ? 0.62 : 0.4, 0.7);
      canvas.drawCircle(Offset(cx, cy), cr, stroke);
      final hole = cr * 0.34;
      final holePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = cr * 0.09
        ..color = ink(compact ? 0.72 : 0.48, 0.5);
      canvas.drawRect(Rect.fromCenter(center: Offset(cx, cy), width: hole * 2, height: hole * 2), holePaint);
    }
  }
}

/// 竹韵（竹简/君子）：竖竹竿 + 竹节 + 竹叶
class _BambooPainter extends _BaseSkinPainter {
  _BambooPainter(super.primary, super.dark, {super.compact});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..shader = bottomGradient().createShader(Offset.zero & size));
    final rnd = Random(17);
    final stalks = compact ? 3 : 2;
    for (var i = 0; i < stalks; i++) {
      final x = size.width * (0.16 + i * 0.34 + rnd.nextDouble() * 0.05);
      final w = size.width * (compact ? 0.028 : 0.02);
      final topY = size.height * (compact ? 0.16 : 0.1);
      final h = size.height * (compact ? 0.62 : 0.4);
      final paint = Paint()
        ..color = ink(compact ? 0.6 : 0.35, 0.68)
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(x, topY), Offset(x, topY + h), paint);
      final node = Paint()
        ..color = ink(compact ? 0.5 : 0.3, 0.5)
        ..strokeWidth = w * 0.28;
      for (var n = 0; n < 2; n++) {
        final ny = topY + h * (0.38 + n * 0.3);
        canvas.drawLine(Offset(x - w * 0.7, ny), Offset(x + w * 0.7, ny), node);
      }
      final leaf = Paint()..color = ink(compact ? 0.72 : 0.48, 0.5);
      for (var l = 0; l < 3; l++) {
        final lx = x + w * (0.6 + rnd.nextDouble() * 0.5);
        final ly = topY + h * (0.1 + rnd.nextDouble() * 0.3);
        final len = size.width * (compact ? 0.055 : 0.035);
        final dir = rnd.nextBool() ? 1 : -1;
        canvas.drawPath(
          Path()
            ..moveTo(lx, ly)
            ..quadraticBezierTo(lx + len * 0.5 * dir, ly - len * 0.5, lx + len * dir, ly - len * 0.12)
            ..quadraticBezierTo(lx + len * 0.5 * dir, ly + len * 0.18, lx, ly)
            ..close(),
          leaf,
        );
      }
    }
  }
}

/// 账本（记账）：账本轮廓 + 账目表格线
class _LedgerPainter extends _BaseSkinPainter {
  _LedgerPainter(super.primary, super.dark, {super.compact});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..shader = bottomGradient().createShader(Offset.zero & size));
    final n = compact ? 2 : 1;
    for (var i = 0; i < n; i++) {
      final cx = size.width * (compact ? 0.28 + i * 0.44 : 0.5);
      final cy = size.height * (compact ? 0.32 + i * 0.3 : 0.22);
      final w = size.width * (compact ? 0.36 : 0.3);
      final h = w * (compact ? 0.5 : 0.38);
      final frame = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.009
        ..color = ink(compact ? 0.68 : 0.42, 0.55);
      final rect = Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(w * 0.04)), frame);
      final line = Paint()
        ..color = ink(compact ? 0.58 : 0.38, 0.5)
        ..strokeWidth = size.width * 0.007;
      canvas.drawLine(Offset(cx - w * 0.3, cy - h * 0.3), Offset(cx + w * 0.3, cy - h * 0.3), line);
      for (var r = 0; r < 3; r++) {
        final y = cy - h * 0.08 + r * h * 0.2;
        canvas.drawLine(Offset(cx - w * 0.34, y), Offset(cx + w * 0.34, y), line);
      }
      canvas.drawLine(Offset(cx + w * 0.2, cy - h * 0.42), Offset(cx + w * 0.2, cy + h * 0.42), line);
    }
  }
}

/// 进销（进销存流转）：进出双向箭头曲线
class _FlowPainter extends _BaseSkinPainter {
  _FlowPainter(super.primary, super.dark, {super.compact});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..shader = bottomGradient().createShader(Offset.zero & size));
    final cy = size.height * (compact ? 0.5 : 0.26);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * (compact ? 0.03 : 0.02)
      ..strokeCap = StrokeCap.round
      ..color = ink(compact ? 0.7 : 0.45, 0.5);
    final path = Path()
      ..moveTo(size.width * 0.08, cy)
      ..cubicTo(size.width * 0.35, cy - size.height * (compact ? 0.2 : 0.12),
          size.width * 0.65, cy + size.height * (compact ? 0.2 : 0.12), size.width * 0.92, cy);
    canvas.drawPath(path, paint);
    final len = size.width * (compact ? 0.055 : 0.035);
    _arrow(canvas, Offset(size.width * 0.92, cy), len, 0, paint);
    _arrow(canvas, Offset(size.width * 0.08, cy), len, pi, paint);
  }

  void _arrow(Canvas canvas, Offset tip, double len, double angle, Paint paint) {
    final p = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx - len * 0.9 * cos(angle - 0.32), tip.dy - len * 0.9 * sin(angle - 0.32))
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx - len * 0.9 * cos(angle + 0.32), tip.dy - len * 0.9 * sin(angle + 0.32));
    canvas.drawPath(p, paint);
  }
}

/// 涟漪（财富流动）：同心圆环扩散
class _RipplePainter extends _BaseSkinPainter {
  _RipplePainter(super.primary, super.dark, {super.compact});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..shader = bottomGradient().createShader(Offset.zero & size));
    final rnd = Random(29);
    final groups = compact ? 3 : 2;
    for (var g = 0; g < groups; g++) {
      final cx = size.width * (compact ? 0.25 + g * 0.26 : 0.2 + g * 0.32);
      final cy = size.height * (compact ? 0.3 + g * 0.22 : 0.2 + g * 0.14);
      final baseR = size.width * (compact ? 0.05 : 0.03);
      for (var ring = 0; ring < 3; ring++) {
        final r = baseR * (1 + ring * 0.9);
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width * (compact ? 0.009 : 0.006)
          ..color = ink((compact ? 0.52 : 0.32) - ring * 0.1, 0.65);
        canvas.drawCircle(Offset(cx, cy), r, paint);
      }
    }
  }
}
