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

class TaoZhuApp extends StatelessWidget {
  const TaoZhuApp({super.key});

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
            future: Api.instance.hasToken(),
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
