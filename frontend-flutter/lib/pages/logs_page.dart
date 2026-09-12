import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../log.dart';
import '../theme.dart';
import 'router.dart';

/// 日志页：默认全部，可按 错误 / 正常 / Debug 筛选（chips 显示各类条数）；
/// 每条固定高度截断显示，点击查看完整内容，可复制或分享。
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

  int get _countError => _logs.where((e) => e.level == 'error').length;
  int get _countInfo => _logs.where((e) => e.level == 'info').length;
  int get _countDebug => _logs.where((e) => e.level == 'debug').length;

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

  /// 查看完整日志：展开全文 + 复制 / 分享
  Future<void> _showDetail(LogEntry e) async {
    final text = '[${e.time}] [${e.level}] [${e.tag}] ${e.msg}';
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('日志详情'),
        content: SingleChildScrollView(
          child: SelectableText(text, style: const TextStyle(fontSize: 12.5, height: 1.5)),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) Navigator.pop(ctx, 'copy');
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'share'),
            child: const Text('分享'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'ok'), child: const Text('关闭')),
        ],
      ),
    );
    if (action == 'copy') {
      toast(context, '已复制');
    } else if (action == 'share') {
      await Share.share(text);
    }
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
          // 级别筛选：默认全部；chips 上显示各类条数
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                for (final f in [
                  ('all', '全部', _logs.length),
                  ('error', '错误', _countError),
                  ('info', '正常', _countInfo),
                  ('debug', 'Debug', _countDebug),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('${f.$2} ${f.$3}', style: const TextStyle(fontSize: 12.5)),
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

  /// 每条日志固定高度 + 截断，点击查看完整内容
  Widget _entry(TaozhuColors c, LogEntry e) {
    final color = e.level == 'error' ? c.danger : (e.level == 'debug' ? c.textSub : c.textMain);
    return InkWell(
      onTap: () => _showDetail(e),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        height: 64,
        decoration: BoxDecoration(
          color: e.level == 'error' ? c.danger.withOpacity(0.08) : c.card,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Text('${e.time} · ${e.tag}', style: TextStyle(fontSize: 11, color: c.textSub)),
                const Spacer(),
                Text(_levelLabel(e.level),
                    style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              e.msg,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: color, height: 1.3),
            ),
          ],
        ),
      ),
    );
  }

  static String _levelLabel(String l) =>
      l == 'error' ? '错误' : (l == 'debug' ? 'Debug' : '正常');
}
