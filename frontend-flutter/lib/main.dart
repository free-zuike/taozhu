import 'package:flutter/material.dart';
import 'api.dart';
import 'pages/login_page.dart';
import 'widgets/bottom_shell.dart';

void main() => runApp(const TaoZhuApp());

class TaoZhuApp extends StatelessWidget {
  const TaoZhuApp({super.key});

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF409EFF);
    return MaterialApp(
      title: '陶朱',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: primary,
          primary: primary,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.white, elevation: 0.5, centerTitle: true),
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
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
  }
}
