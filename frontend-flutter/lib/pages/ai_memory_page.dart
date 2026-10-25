import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';
import 'router.dart';

/// 本地记忆独立页（对齐参考 App agent_memory_page）：记住的事项 查看/遗忘/清空。
/// 数据存服务端 ai_memories（对话里说「记住：…」/「忘记…」维护，授权门默认询问）。
class AiMemoryPage extends StatefulWidget {
  const AiMemoryPage({super.key});
  @override
  State<AiMemoryPage> createState() => _AiMemoryPageState();
}

class _AiMemoryPageState extends State<AiMemoryPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  List<Map<String, dynamic>>? _memories;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await Api.instance.get('/ai/memories');
      if (mounted) setState(() => _memories = ((d['memories'] as List?) ?? []).cast<Map<String, dynamic>>());
    } catch (e) {
      if (mounted) toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _forget(String id) async {
    try {
      await Api.instance.delete('/ai/memories/$id');
      toast(context, '已忘记');
      await _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空记忆', style: TextStyle(fontSize: 16)),
        content: const Text('确定清空全部助手记忆吗？', style: TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(fontSize: 13))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空', style: TextStyle(fontSize: 13))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await Api.instance.delete('/ai/memories');
      toast(context, '已清空');
      await _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final memories = _memories;
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: appBarBackground(context),
        title: const Text('本地记忆', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        actions: [
          if (memories != null && memories.isNotEmpty)
            TextButton(onPressed: _clearAll, child: const Text('清空', style: TextStyle(fontSize: 13))),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: themePageBackground(context)),
          memories == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _c.card,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _c.divider),
                    ),
                    child: const Text(
                      '跟 AI 助手说「记住：XXX」来记住重要事项（默认需确认），每次对话都会带上；说「忘记 XXX」或点右侧图标可遗忘。',
                      style: TextStyle(fontSize: 12.5, height: 1.5),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (memories.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 48),
                      child: Center(child: Text('还没有记忆。', style: TextStyle(fontSize: 13, color: Colors.grey))),
                    )
                  else
                    for (final m in memories)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${m['content']}', style: const TextStyle(fontSize: 13.5)),
                        subtitle: Text('${m['created_at'] ?? ''}'.length >= 10 ? '${m['created_at']}'.substring(0, 10) : '',
                            style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        trailing: IconButton(
                          tooltip: '忘记',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () => _forget('${m['id']}'),
                        ),
                      ),
                ],
              ),
        ],
      ),
    );
  }
}