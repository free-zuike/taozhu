import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import 'router.dart';

/// 操作审计：服务端记录的关键操作留痕（登录/删除交易/修改收款/导入导出备份等，仅老板可看）
/// 本地优先（对齐账本/进货历史范式）：原生端先渲染本地镜像（秒开/离线可见），
/// 网络拉取成功后覆盖写库（服务端权威全集）；删除本地镜像即时移除，不依赖重拉成败。
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
    // 实时刷新：其他端删除审计 → 后端 WS sync 通知 → 本页自动重拉（无需手动刷新）
    SyncService.version.addListener(_onSync);
  }

  @override
  void dispose() {
    SyncService.version.removeListener(_onSync);
    super.dispose();
  }

  void _onSync() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    // 原生本地优先：先渲染本地镜像（秒开/离线可见），网络成功覆盖
    if (!kIsWeb) {
      final local = await LocalDb.getAll('audit_logs');
      if (mounted && local.isNotEmpty) {
        setState(() {
          _logs = local;
          _loading = false;
          _error = null;
        });
      }
    }
    try {
      final d = await Api.instance.get('/audit?limit=200');
      if (!mounted) return;
      final logs = ((d['logs'] as List?) ?? []).cast<Map<String, dynamic>>();
      // 本地镜像 = 服务端权威全集（覆盖写：服务端已删的记录随之从本地消失）
      if (!kIsWeb && logs.isNotEmpty) {
        await LocalDb.putAll('audit_logs', logs);
      }
      setState(() {
        _logs = logs;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      // 网络失败：原生保留本地镜像展示（离线可见）；Web 无本地回退错误态
      if (!kIsWeb) {
        final local = await LocalDb.getAll('audit_logs');
        if (mounted && local.isNotEmpty) {
          setState(() {
            _logs = local;
            _loading = false;
          });
          return;
        }
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  /// 手动删除单条审计记录（确认后调 DELETE /audit/:id，删除后刷新列表）
  Future<void> _deleteLog(Map<String, dynamic> l) async {
    final id = '${l['id'] ?? ''}';
    if (id.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除该条审计？'),
        content: Text('将删除「${l['username'] ?? ''} · ${'${l['detail'] ?? l['action_label'] ?? l['action'] ?? ''}'}」记录。\n删除后不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).extension<TaozhuColors>()!.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await Api.instance.delete('/audit/$id');
      final deleted = (r['deleted'] as num?)?.toInt() ?? 0;
      if (deleted > 0) {
        // 本地优先：镜像删 + 内存移除（即时消失，不依赖重拉成败；_load 仅兜底对齐）
        if (!kIsWeb) await LocalDb.deleteOne('audit_logs', id);
        setState(() => _logs.removeWhere((x) => '${x['id']}' == id));
        toast(context, '已删除');
      } else {
        toast(context, '删除失败：记录不存在或已被删除');
      }
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
      // 请求异常但服务端可能已执行删除（响应丢失）→ 强制重拉对齐，避免"删了还在直到退出重进"
      _load();
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
      appBar: AppBar(
        flexibleSpace: appBarBackground(context)), // 顶部露出主题背景（无标题文字）
      body: Stack(
        children: [
          Positioned.fill(child: themePageBackground(context)),
          RefreshIndicator(
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
                          final actionTxt = ('${l['action_label'] ?? ''}'.isNotEmpty
                              ? '${l['action_label']}'
                              : _actionLabel('${l['action'] ?? ''}'));
                          // 标题：用户名 · 具体留痕（detail 含业务名称，如"删除了店铺品味轩"；
                          // 旧记录无 detail 时回退到 动作+实体 拼接，不显示实体 id 长串）
                          final entityLabel = ('${l['entity_label'] ?? ''}'.isNotEmpty
                              ? '${l['entity_label']}'
                              : '${l['entity_type'] ?? ''}');
                          final verb = ['新增', '修改', '删除', '导出', '导入', '重算'].contains(actionTxt)
                              ? '$actionTxt了'
                              : actionTxt;
                          final detailTxt = '${l['detail'] ?? ''}';
                          final title = '${l['username'] ?? ''}' +
                              (detailTxt.isNotEmpty
                                  ? ' · $detailTxt'
                                  : ' · ${entityLabel.isNotEmpty ? '$verb$entityLabel' : actionTxt}');
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(12)),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: c.primary.withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(actionTxt, style: TextStyle(fontSize: 12, color: c.primary)),
                                    ),
                                    const SizedBox(width: 8),
                                    if ('${l['client_type'] ?? ''}'.isNotEmpty) ...[
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: ('${l['client_type']}' == 'app'
                                                  ? c.primary
                                                  : '${l['client_type']}' == 'miniprogram'
                                                      ? c.warning
                                                      : c.success)
                                              .withOpacity(0.12),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          '${l['client_type']}' == 'app'
                                              ? 'App'
                                              : '${l['client_type']}' == 'miniprogram'
                                                  ? '小程序'
                                                  : 'Web',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: '${l['client_type']}' == 'app'
                                                ? c.primary
                                                : '${l['client_type']}' == 'miniprogram'
                                                    ? c.warning
                                                    : c.success,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                    ],
                                    Expanded(
                                      child: Text(
                                        title,
                                        style: TextStyle(fontSize: 14, color: c.textMain, fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                    // 手动删除单条审计（仅老板，确认后调 DELETE /audit/:id）
                                    IconButton(
                                      tooltip: '删除',
                                      icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFEF4444)),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => _deleteLog(l),
                                    ),
                                  ],
                                ),
                                if ('${l['detail'] ?? ''}'.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4, left: 2),
                                    child: Text('${l['detail']}', style: TextStyle(fontSize: 12, color: c.textSub)),
                                  ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 4, left: 2),
                                  child: Text(_fmtTime(l['created_at']), style: TextStyle(fontSize: 11, color: c.textSub)),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
        ],
      ),
                  );
                }
              }
