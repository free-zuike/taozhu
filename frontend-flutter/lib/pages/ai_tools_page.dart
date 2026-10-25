import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';
import 'router.dart';

/// 工具权限（对齐参考 App Agent 权限页）：写工具（落单/记忆）三档 ask/allow/deny，
/// 读工具固定放行；恢复默认。策略存服务端 ai_tool_permissions（跨设备一致）。
class AiToolsPage extends StatefulWidget {
  const AiToolsPage({super.key});
  @override
  State<AiToolsPage> createState() => _AiToolsPageState();
}

class _AiToolsPageState extends State<AiToolsPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  List<Map<String, dynamic>>? _tools;
  final Set<String> _writing = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await Api.instance.get('/ai/tools');
      if (mounted) setState(() => _tools = ((d['tools'] as List?) ?? []).cast<Map<String, dynamic>>());
    } catch (e) {
      if (mounted) toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  static const _policyLabel = {'ask': '每次询问', 'allow': '总是允许', 'deny': '总是拒绝'};

  Future<void> _pickPolicy(Map<String, dynamic> t) async {
    final current = '${t['policy']}';
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${t['label']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('${t['description']}', style: const TextStyle(fontSize: 12.5, color: Colors.grey)),
              const SizedBox(height: 16),
              for (final entry in _policyLabel.entries)
                ListTile(
                  dense: true,
                  title: Text(entry.value, style: const TextStyle(fontSize: 14)),
                  trailing: entry.key == current ? const Icon(Icons.check, size: 18) : null,
                  onTap: () => Navigator.pop(ctx, entry.key),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || selected == current || !mounted) return;
    setState(() => _writing.add('${t['name']}'));
    try {
      await Api.instance.put('/ai/tools/${t['name']}', {'policy': selected});
      toast(context, '已设为「${_policyLabel[selected]}」');
      await _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _writing.remove('${t['name']}'));
    }
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复默认', style: TextStyle(fontSize: 16)),
        content: const Text('所有工具回到缺省策略：读工具放行，写工具（落单/记忆）每次询问。', style: TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(fontSize: 13))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('恢复', style: TextStyle(fontSize: 13))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await Api.instance.post('/ai/tools/reset', {});
      toast(context, '已恢复默认');
      await _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tools = _tools;
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: appBarBackground(context),
        title: const Text('工具权限', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        actions: [
          TextButton(onPressed: _tools == null ? null : _reset, child: const Text('恢复默认', style: TextStyle(fontSize: 13))),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: themePageBackground(context)),
          tools == null
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
                      'AI 会用到以下工具。查询类只读不询问；写操作（一句话记账、修改记忆）默认每次询问，也可设为总是允许/拒绝。',
                      style: TextStyle(fontSize: 12.5, height: 1.5),
                    ),
                  ),
                  const SizedBox(height: 14),
                  for (final t in tools) ...[
                    _toolTile(t),
                    const Divider(height: 1),
                  ],
                ],
              ),
        ],
      ),
    );
  }

  Widget _toolTile(Map<String, dynamic> t) {
    final isWrite = '${t['permission']}' == 'write';
    final policy = '${t['policy']}';
    final color = isWrite
        ? (policy == 'allow' ? _c.success : policy == 'deny' ? _c.danger : _c.warning)
        : _c.success;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${t['label']}', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500)),
      subtitle: Text('${t['description']}', style: const TextStyle(fontSize: 12, color: Colors.grey), maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: _writing.contains('${t['name']}')
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : InkWell(
              onTap: () => _pickPolicy(t),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                child: Text(_policyLabel[policy] ?? policy,
                    style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
              ),
            ),
    );
  }
}