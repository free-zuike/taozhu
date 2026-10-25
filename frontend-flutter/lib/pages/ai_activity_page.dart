import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';
import 'router.dart';

/// 最近活动（对齐参考 App Agent 活动页）：每次对话 = 一条运行记录（意图/时间/状态）
/// + 工具调用明细（Query/记忆/落单，含耗时）；数据存服务端 ai_runs/ai_tool_calls。
class AiActivityPage extends StatefulWidget {
  const AiActivityPage({super.key});
  @override
  State<AiActivityPage> createState() => _AiActivityPageState();
}

class _AiActivityPageState extends State<AiActivityPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  List<Map<String, dynamic>>? _activity;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await Api.instance.get('/ai/activity');
      if (mounted) setState(() => _activity = ((d['activity'] as List?) ?? []).cast<Map<String, dynamic>>());
    } catch (e) {
      if (mounted) toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  static String _shortTime(String iso) {
    if (iso.length < 16) return iso;
    return iso.substring(5, 16).replaceAll('T', ' ');
  }

  static const _kindLabel = {'query': '问数', 'kb': '用法', 'record': '落单', 'chat': '对话'};

  @override
  Widget build(BuildContext context) {
    final activity = _activity;
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: appBarBackground(context),
        title: const Text('最近活动', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: themePageBackground(context)),
          activity == null
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (activity.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 48),
                        child: Center(child: Text('还没有活动记录。和 AI 助手聊几句（问数/落单/记忆）后这里会展示执行过程。', style: TextStyle(fontSize: 12.5, color: Colors.grey))),
                      )
                    else
                      for (final a in activity) _runCard(a),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _runCard(Map<String, dynamic> a) {
    final run = (a['run'] ?? {}) as Map<String, dynamic>;
    final calls = ((a['tool_calls'] ?? []) as List).cast<Map<String, dynamic>>();
    final status = '${run['status'] ?? 'ok'}';
    final color = status == 'error' ? _c.danger : _c.success;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _c.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _c.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                child: Text(_kindLabel['${run['intent']}'] ?? '${run['intent']}',
                    style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(_shortTime('${run['started_at'] ?? ''}'), style: const TextStyle(fontSize: 12, color: Colors.grey))),
              if ('${run['summary'] ?? ''}'.isNotEmpty)
                Text('${run['summary']}'.length > 18 ? '${'${run['summary']}'.substring(0, 18)}…' : '${run['summary']}',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          if (calls.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final c2 in calls)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(c2['status'] == 'error' ? Icons.error_outline : Icons.check_circle_outline, size: 14, color: c2['status'] == 'error' ? _c.danger : _c.success),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${c2['tool_name']} · ${'${c2['result'] ?? ''}'.length > 40 ? '${'${c2['result']}'.substring(0, 40)}…' : '${c2['result'] ?? ''}'}',
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                    ),
                    if ((c2['duration_ms'] ?? 0) > 0)
                      Text('${c2['duration_ms']}ms', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}