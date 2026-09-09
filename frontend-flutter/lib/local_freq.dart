import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地记单频率：price_id → 使用次数（仅存本机，不上传、不写服务端）
/// 用于记单页把常用商品排在前面，减少每次翻找
class Freq {
  Freq._();
  static const _key = 'taozhu_price_freq';

  static Future<Map<String, int>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, (v as num?)?.toInt() ?? 0));
    } catch (_) {
      return {};
    }
  }

  /// 单据提交成功后对涉及的价格计一次使用
  static Future<void> bump(Iterable<String> priceIds) async {
    final freq = await load();
    for (final id in priceIds) {
      if (id.isEmpty) continue;
      freq[id] = (freq[id] ?? 0) + 1;
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(freq));
  }
}