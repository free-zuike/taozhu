import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';
import 'router.dart';

/// 操作审计：服务端记录的关键操作留痕（登录/删除交易/修改收款/导入导出备份等，仅老板可看）
class AuditPage extends StatefulWidget {
  const AuditPage({super.key});
  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  List<Map<String, dynamic>> _logs = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await Api.instance.get('/audit?limit=200');
      if (!mounted) return;
      setState(() {
        _logs = ((d['logs'] as List?) ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  String _fmtTime(Object? v) {
    final t = DateTime.tryParse('$v')?.toLocal();
    if (t == null) return '$v';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  String _actionLabel(String a) {
    switch (a) {
      case 'login': return '登录';
      case 'create': return '新增';
      case 'delete': return '删除';
      case 'update': return '修改';
      case 'export': return '导出';
      case 'import': return '导入';
      case 'rebuild': return '重算';
      default: return a;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(title: const Text('操作审计')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : _error != null
                ? ListView(children: [
                    const SizedBox(height: 80),
                    Center(child: Text(_error!, style: const TextStyle(fontSize: 14))),
                  ])
                : _logs.isEmpty
                    ? ListView(children: [
                        const SizedBox(height: 80),
                        Center(child: Text('暂无操作记录', style: TextStyle(color: c.textSub))),
                      ])
                    : ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: _logs.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (ctx, i) {
                          final l = _logs[i];
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(12)),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: c.primary.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                      ('${l['action_label'] ?? ''}'.isNotEmpty
                                          ? '${l['action_label']}'
                                          : _actionLabel('${l['action'] ?? ''}')),
                                      style: TextStyle(fontSize: 12, color: c.primary)),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                          ('${l['entity_label'] ?? ''}'.isNotEmpty
                                              ? '${l['entity_label']}'
                                              : '${l['entity_type'] ?? ''}') +
                                              ('${l['entity_id'] ?? ''}'.isNotEmpty ? ' ${l['entity_id']}' : ''),
                                          style: TextStyle(fontSize: 14, color: c.textMain, fontWeight: FontWeight.w600)),
                                      if ('${l['detail'] ?? ''}'.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 2),
                                          child: Text('${l['detail']}', style: TextStyle(fontSize: 12, color: c.textSub)),
                                        ),
                                      Padding(
                                        padding: const EdgeInsets.only(top: 3),
                                        child: Text(
                                          '${l['username'] ?? ''} · ${_fmtTime(l['created_at'])}',
                                          style: TextStyle(fontSize: 11, color: c.textSub),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
      ),
    );
  }
}