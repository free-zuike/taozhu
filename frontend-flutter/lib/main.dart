import 'package:flutter/material.dart';
import 'api.dart';
import 'pages/login_page.dart';
import 'pages/home_page.dart';

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
        appBarTheme: const AppBarTheme(backgroundColor: Colors.white, elevation: 0.5),
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
      ),
      home: FutureBuilder<bool>(
        future: Api.instance.hasToken(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return snap.data == true ? const HomePage() : const LoginPage();
        },
      ),
    );
  }
}