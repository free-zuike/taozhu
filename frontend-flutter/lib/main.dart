import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'system_proxy.dart';
import 'theme.dart';
import 'utils/money.dart';
import 'pages/login_page.dart';
import 'widgets/bottom_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 跟随系统代理：所有 HTTP 请求统一走系统代理（Windows 读注册表/Android 读系统属性），
  // 启动即读 + 每 30s 重读（跟随代理软件开关变化）。Web 端浏览器自带代理，不注册。
  if (!kIsWeb) {
    SystemProxy.install();
    unawaited(SystemProxy.refresh());
    Timer.periodic(const Duration(seconds: 30), (_) => unawaited(SystemProxy.refresh()));
  }
  final p = await SharedPreferences.getInstance();
  themeNotifier.value = restoreThemeMode(p.getString('theme_mode'));
  await ThemeConfig.instance.init();
  // App 显式设置状态栏/底部导航条样式（否则系统按默认叠加半透明 scrim=页面顶部"蒙版"）；
  // 无 AppBar 页面由这里兜底，有 AppBar 页面由 AppBarTheme.systemOverlayStyle 覆盖
  void applySystemUi(ThemeMode mode) {
    final dark = mode == ThemeMode.dark ||
        (mode == ThemeMode.system &&
            WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: dark ? const Color(0xFF101216) : const Color(0xFFF6F7F9),
      systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    ));
  }
  applySystemUi(themeNotifier.value);
  themeNotifier.addListener(() => applySystemUi(themeNotifier.value));
  // 本地优先：启动即读本地缓存设置金额舍入口径（已登录用户重启不经过登录页，
  // 此前 ensure 只在登录时调用 → 静态值恒为默认 2 位——"显示默认 2 位"根因）。
  // 只读缓存不拉网络（不跳动）；联网后由实时 WS rounding 事件刷新。
  Money.loadFromPrefs(p);
  runApp(const TaoZhuApp());
}

class TaoZhuApp extends StatefulWidget {
  const TaoZhuApp({super.key});
  @override
  State<TaoZhuApp> createState() => _TaoZhuAppState();
}

class _TaoZhuAppState extends State<TaoZhuApp> {
  // 一次性创建（不在 build 里新建 Future）：主题变化触发 MaterialApp 重建时
  // FutureBuilder 不重置 → 导航栈/当前页面保留（否则整棵树换 loading 跳回首页）
  late final Future<bool> _tokenFuture = Api.instance.hasToken();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([themeNotifier, ThemeConfig.instance]),
      builder: (context, _) {
        final mode = themeNotifier.value;
        final preset = ThemeConfig.instance.preset;
        // 状态栏/底部系统导航条跟随主题：statusBar 透明（去掉系统默认半透明 scrim=用户
        // "上边一层半透明的蒙版看不清楚"根因，背景图案透出）、图标明暗跟随、底部系统导航条同主题深色
        final dark = mode == ThemeMode.dark ||
            (mode == ThemeMode.system &&
                View.of(context).platformDispatcher.platformBrightness == Brightness.dark);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
            statusBarBrightness: dark ? Brightness.dark : Brightness.light,
            systemNavigationBarColor: dark ? const Color(0xFF101216) : const Color(0xFFF6F7F9),
            systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          ),
          child: MaterialApp(
          title: '陶朱',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: buildLightTheme(preset.lightPrimary),
          darkTheme: buildDarkTheme(preset.darkPrimary),
          // 移除全局背景包装（MaterialApp.builder 渐变层=用户"4 tab 都看到像渐变的蒙版"根因：
          // 页面 Scaffold 未覆盖处透出这层渐变）；每页 body 已自铺 themePageBackground
          // 中文化（DatePicker 等系统组件）+ i18n 基础（zh/en）
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          locale: const Locale('zh', 'CN'),
          home: FutureBuilder<bool>(
            future: _tokenFuture,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Scaffold(body: Center(child: CircularProgressIndicator()));
              }
              return snap.data == true ? const BottomShell() : const LoginPage();
            },
          ),
          ),
        );
      },
    );
  }
}
