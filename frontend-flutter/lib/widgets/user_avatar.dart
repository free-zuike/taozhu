import 'dart:io';
import 'package:flutter/material.dart';

/// 头像：有图显示图片（本地/网络），无图显示「用户名首字」矢量头像（按名字取稳定底色）。
/// 有图但加载异常时也回落首字头像，避免空白占位。
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.size,
    this.name = '',
    this.localPath,
    this.hasAvatar = false,
    this.url,
    this.token,
  });

  final double size;
  final String name;
  final String? localPath;
  final bool hasAvatar;
  final String? url;
  final String? token;

  /// 柔和底色盘：按名字稳定哈希取色（同一名字始终同色）
  static const _palette = [
    Color(0xFF5B8FF9),
    Color(0xFF5AA86B),
    Color(0xFFC37EB8),
    Color(0xFFE19A4D),
    Color(0xFF4FA3A6),
    Color(0xFFB06AB3),
  ];

  /// 跨进程稳定的字符串哈希（Dart 自带 hashCode 每次运行会变）
  static int _stableHash(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }

  String get _initial {
    final n = name.trim();
    if (n.isEmpty) return '?';
    return String.fromCharCodes(n.runes.take(1)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final local = (localPath == null || localPath!.isEmpty) ? null : File(localPath!);
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: _palette[_stableHash(name) % _palette.length],
      child: Text(
        _initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    Widget child = fallback;
    if (local != null) {
      child = Image.file(
        local,
        fit: BoxFit.cover,
        // 本地副本异常时回落首字头像
        errorBuilder: (_, __, ___) => fallback,
      );
    } else if (hasAvatar && url != null && url!.isNotEmpty) {
      child = Image.network(
        url!,
        fit: BoxFit.cover,
        headers: (token == null || token!.isEmpty) ? null : {'Authorization': 'Bearer $token'},
        // 加载中先显示首字占位，避免头像「短暂消失」
        loadingBuilder: (_, child, progress) => progress == null ? child : fallback,
        errorBuilder: (_, __, ___) => fallback,
      );
    }
    return ClipOval(
      child: SizedBox(width: size, height: size, child: child),
    );
  }
}