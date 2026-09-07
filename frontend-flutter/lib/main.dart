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
  themeNotifier.value = p.getString('theme_mode') == 'dark' ? ThemeMode.dark : ThemeMode.light;
  runApp(const TaoZhuApp());
}

class TaoZhuApp extends StatelessWidget {
  const TaoZhuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, mode, _) => MaterialApp(
        title: '陶朱',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: _lightTheme(),
        darkTheme: _darkTheme(),
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
      ),
    );
  }

  ThemeData _lightTheme() {
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
    );
  }

  ThemeData _darkTheme() {
    const primary = Color(0xFF409EFF);
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: primary, brightness: Brightness.dark),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFF121212),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1E1E1E), elevation: 0.5, centerTitle: true),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
      cardTheme: CardThemeData(
        color: const Color(0xFF1E1E1E),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
