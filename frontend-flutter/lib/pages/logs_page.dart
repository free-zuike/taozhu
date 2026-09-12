import 'package:flutter/material.dart';
import '../log.dart';
import '../theme.dart';
import 'router.dart';

/// 日志页：默认显示全部，可按 错误 / 正常 / Debug 筛选；新的在上。
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});
  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String _filter = 'all'; // all | error | info | debug
  List<LogEntry> _logs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final logs = await readLogs();
    if (!mounted) return;
    setState(() {
      _logs = logs;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('确定清空全部日志吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    await clearLogs();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    final shown = _filter == 'all' ? _logs : _logs.where((e) => e.level == _filter).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志'),
        actions: [
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
            onPressed: _logs.isEmpty ? null : _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          // 级别筛选：默认全部
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                for (final f in [
                  ('all', '全部'),
                  ('error', '错误'),
                  ('info', '正常'),
                  ('debug', 'Debug'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f.$2, style: const TextStyle(fontSize: 13)),
                      selected: _filter == f.$1,
                      selectedColor: c.primary.withOpacity(0.12),
                      side: BorderSide(color: _filter == f.$1 ? c.primary : c.divider),
                      labelStyle: TextStyle(
                        color: _filter == f.$1 ? c.primary : c.textMain,
                        fontWeight: _filter == f.$1 ? FontWeight.w600 : FontWeight.w400,
                      ),
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _filter = f.$1),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : shown.isEmpty
                    ? Center(
                        child: Text(_logs.isEmpty ? '暂无日志' : '该分类暂无日志',
                            style: TextStyle(color: c.textSub)))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: shown.length,
                        itemBuilder: (_, i) => _entry(c, shown[shown.length - 1 - i]), // 新的在上
                      ),
          ),
        ],
      ),
    );
  }

  Widget _entry(TaozhuColors c, LogEntry e) {
    final color = e.level == 'error' ? c.danger : (e.level == 'debug' ? c.textSub : c.textMain);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: e.level == 'error' ? c.danger.withOpacity(0.08) : c.card,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('${e.time} · ${e.tag}', style: TextStyle(fontSize: 11, color: c.textSub)),
              const Spacer(),
              Text(_levelLabel(e.level),
                  style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 2),
          Text(e.msg, style: TextStyle(fontSize: 12.5, color: color, height: 1.4)),
        ],
      ),
    );
  }

  static String _levelLabel(String l) =>
      l == 'error' ? '错误' : (l == 'debug' ? 'Debug' : '正常');
}
