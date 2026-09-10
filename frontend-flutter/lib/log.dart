import 'package:shared_preferences/shared_preferences.dart';

const _logKey = 'taozhu_logs';
const _maxLogs = 200;

/// 应用内日志（滚动上限 200 条）：错误记录进日志，页面只显示友好提示
Future<void> appLog(String tag, String msg) async {
  try {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_logKey) ?? [];
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    list.add('[$ts][$tag] $msg');
    if (list.length > _maxLogs) list.removeRange(0, list.length - _maxLogs);
    await p.setStringList(_logKey, list);
  } catch (_) {}
}

Future<List<String>> readLogs() async {
  try {
    final p = await SharedPreferences.getInstance();
    return p.getStringList(_logKey) ?? [];
  } catch (_) {
    return [];
  }
}

Future<void> clearLogs() async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_logKey, []);
  } catch (_) {}
}