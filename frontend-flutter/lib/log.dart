import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

const _logKey = 'taozhu_logs';
const _maxLogs = 300;

/// 一条应用日志
class LogEntry {
  LogEntry({required this.time, required this.level, required this.tag, required this.msg});
  final String time; // HH:mm:ss
  final String level; // error | info | debug
  final String tag;
  final String msg;
}

/// 写一条日志（滚动上限 300 条）。level: error=错误 / info=正常 / debug=调试。
Future<void> appLog(String tag, String msg, {String level = 'info'}) async {
  try {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_logKey) ?? [];
    list.add(jsonEncode({
      't': DateTime.now().toIso8601String(),
      'l': level,
      'g': tag,
      'm': msg,
    }));
    if (list.length > _maxLogs) list.removeRange(0, list.length - _maxLogs);
    await p.setStringList(_logKey, list);
  } catch (_) {}
}

/// 读取全部日志（兼容旧格式字符串 [HH:mm:ss][tag] msg → info 级）
Future<List<LogEntry>> readLogs() async {
  try {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList(_logKey) ?? [];
    final out = <LogEntry>[];
    for (final s in raw) {
      try {
        final d = jsonDecode(s);
        if (d is Map && d['t'] is String && d['m'] is String) {
          final t = DateTime.tryParse(d['t'] as String);
          final level = d['l'] == 'error' || d['l'] == 'debug' ? d['l'] as String : 'info';
          out.add(LogEntry(
            time: t == null ? '--:--:--' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}',
            level: level,
            tag: '${d['g'] ?? ''}',
            msg: d['m'] as String,
          ));
          continue;
        }
      } catch (_) {}
      // 旧格式兜底
      final m = RegExp(r'^\[(\d{2}:\d{2}:\d{2})\]\[([^\]]*)\] (.*)$').firstMatch(s);
      if (m != null) {
        out.add(LogEntry(time: m.group(1)!, level: 'info', tag: m.group(2)!, msg: m.group(3)!));
      } else {
        out.add(LogEntry(time: '--:--:--', level: 'info', tag: '', msg: s));
      }
    }
    return out;
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
