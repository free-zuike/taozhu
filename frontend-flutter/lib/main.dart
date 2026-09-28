import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'theme.dart';
import 'pages/login_page.dart';
import 'widgets/bottom_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final p = await SharedPreferences.getInstance();
  themeNotifier.value = restoreThemeMode(p.getString('theme_mode'));
  await ThemeConfig.instance.init();
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
        return MaterialApp(
          title: '陶朱',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: buildLightTheme(preset.lightPrimary),
          darkTheme: buildDarkTheme(preset.darkPrimary),
          builder: themeBackgroundWrap,
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
        );
      },
    );
  }
}
