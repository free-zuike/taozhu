import 'package:flutter/material.dart';
import 'api.dart';
import 'pages/login_page.dart';
import 'pages/home_page.dart';

void main() => runApp(const TaoZhuApp());

class TaoZhuApp extends StatelessWidget {
  const TaoZhuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '陶朱',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
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