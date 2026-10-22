import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../api.dart';
import '../local_db.dart';
import '../theme.dart';
import '../utils/download.dart';
import 'router.dart';

/// 数据备份：导出全库 JSON 存档 / 从备份文件合并恢复（同一页两个选项，类似账号设置）。
class BackupPage extends StatefulWidget {
  const BackupPage({super.key});
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;

  /// 自动备份时间（北京时间 HH:MM，用户自选）：到点自动备份全库 JSON 到云端（走存储工厂）
  String _autoTime = '03:05';
  /// 自动备份保留份数（用户可配 1-90，默认 14）：超出按最旧删除
  int _autoKeep = 14;
  /// 云端备份历史（新→旧）：自动从存储端读取，可直接恢复，无需下载
  List<Map<String, dynamic>> _backups = [];
  /// 最近一次备份距今天数（null=从未备份/读取失败）
  int? _lastBackupDays;
  /// 最近一次备份显示文本（今天/昨天 HH:MM / MM-DD HH:MM）
  String _lastBackupLabel = '';

  @override
  void initState() {
    super.initState();
    _loadAutoTime();
    _loadBackups();
  }

  Future<void> _loadAutoTime() async {
    try {
      final d = await Api.instance.get('/backup/auto');
      if (!mounted) return;
      setState(() {
        if ('${d['time'] ?? ''}'.isNotEmpty) _autoTime = '${d['time']}';
        final keep = (d['keep'] as num?)?.toInt();
        if (keep != null && keep >= 1 && keep <= 90) _autoKeep = keep;
      });
    } catch (_) {
      // 读取失败保持默认，不阻塞页面
    }
  }

  Future<void> _pickAutoTime() async {
    final parts = _autoTime.split(':');
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.tryParse(parts.first) ?? 3,
        minute: int.tryParse(parts.length > 1 ? parts[1] : '5') ?? 5,
      ),
      helpText: '选择每日自动备份时间（北京时间）',
    );
    if (t == null || !mounted) return;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    try {
      await Api.instance.put('/backup/auto', {'time': '$hh:$mm'});
      if (mounted) setState(() => _autoTime = '$hh:$mm');
      toast(context, '已设置：每天 $hh:$mm 自动备份到云端');
    } catch (e) {
      toast(context, '保存失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  /// 设置自动备份保留份数（1-90）：云端只保留最近 N 份，超出删最旧
  Future<void> _pickAutoKeep() async {
    final ctrl = TextEditingController(text: '$_autoKeep');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自动备份保留份数'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '1-90（默认 14）'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final keep = int.tryParse(ctrl.text.trim());
    if (keep == null || keep < 1 || keep > 90) {
      toast(context, '请输入 1-90 的份数');
      return;
    }
    try {
      await Api.instance.put('/backup/auto', {'keep': keep});
      if (mounted) setState(() => _autoKeep = keep);
      toast(context, '已设置：云端保留最近 $keep 份备份');
    } catch (e) {
      toast(context, '保存失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  /// 全库备份导出：**本地优先**——直接从本地库导出全量 JSON（本地库是数据主体，离线可用，
  /// 不经服务器）；Web 直接下载文件，移动/桌面弹系统分享保存。
  /// 附件本体内嵌 base64（备份要带图：换设备/换环境恢复附件不丢）——本地公共副本
  /// attachments/{file}（同图一份 md5 命名）按 attachment_refs 的 key 配对读取；
  /// 附件总量超 25MB 保护（本地 JSON 过大保存/导入体验差），超限整体跳过附件并提示。
  Future<void> _exportBackup() async {
    try {
      final data = <String, List<dynamic>>{};
      for (final store in [
        'clients', 'items', 'item_prices', 'categories', 'payment_accounts',
        'price_groups', 'stocks', 'sale_items', 'purchase_items', 'payments', 'attachment_refs',
      ]) {
        try {
          data[store] = await LocalDb.getAll(store);
        } catch (_) {}
      }
      const maxEmbedBytes = 25 * 1024 * 1024;
      var skipped = 0;
      var overflow = false;
      final refs = await LocalDb.getAll('attachment_refs');
      final atts = <Map<String, dynamic>>[];
      final seen = <String>{};
      if (refs.isNotEmpty) {
        final root = await getApplicationDocumentsDirectory();
        var total = 0;
        for (final r in refs) {
          final key = '${r['key'] ?? ''}';
          final file = '${r['file'] ?? ''}';
          if (key.isEmpty || file.isEmpty || !seen.add(key)) continue;
          try {
            final ff = File('${root.path}/attachments/$file');
            if (!await ff.exists()) {
              skipped++;
              continue;
            }
            final bytes = await ff.readAsBytes();
            total += bytes.length;
            if (total > maxEmbedBytes) {
              atts.clear();
              overflow = true;
              break;
            }
            atts.add(<String, dynamic>{
              'key': key, 'data': base64Encode(bytes), 'size': bytes.length,
            });
          } catch (_) {
            skipped++;
          }
        }
      }
      if (atts.isNotEmpty) data['__attachments'] = atts;
      final d = {'exported_at': DateTime.now().toIso8601String(), 'data': data};
      final bytes = Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(d)));
      final name = 'taozhu-backup-${DateTime.now().toIso8601String().split('T').first}.json';
      await saveBytes(bytes, name, 'application/json', '陶朱数据备份');
      if (kIsWeb) {
        toast(context, overflow
            ? '已导出（附件共超过 25MB 未包含，建议用云端备份）'
            : skipped > 0
                ? '已导出（$skipped 个附件本地无副本未包含）'
                : '备份已导出（含附件）');
      }
    } catch (e) {
      toast(context, '备份导出失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  /// 从备份 JSON 合并导入（仅老板）：相同 ID 跳过，只新增本地没有的记录
  Future<void> _importBackup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入备份'),
        content: const Text('将备份文件中的记录合并到当前数据：\n· 相同 ID 的记录跳过（不覆盖现有数据）\n· 只新增备份里有、本地没有的记录\n\n建议导入前先导出留底。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('选择文件并导入')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final text = await pickTextFile();
      if (text == null || text.trim().isEmpty) {
        if (!kIsWeb) toast(context, '当前平台暂不支持导入，请用 Web 端导入');
        return;
      }
      final raw = jsonDecode(text);
      if (raw is! Map || raw['data'] is! Map) {
        toast(context, '不是有效的备份文件');
        return;
      }
      final data = (raw['data'] as Map).cast<String, dynamic>();
      final r = await Api.instance.post('/backup/import', {'data': data});
      final report = (r['report'] as Map?) ?? {};
      final total = ((r['total_inserted'] as num?) ?? 0).toInt();
      if (!mounted) return;
      final detail = report.entries.map((e) {
        final v = (e.value as Map?) ?? const {};
        return '${e.key}: 新增 ${v['inserted']} · 跳过 ${v['skipped']}';
      }).join('\n');
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入完成'),
          content: Text('共新增 $total 条记录：\n$detail'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('好'))],
        ),
      );
    } catch (e) {
      toast(context, '导入失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  /// 立即手动备份全库到云端（走存储工厂；历史可直接恢复）
  Future<void> _backupNow() async {
    try {
      final r = await Api.instance.post('/backup/now', {});
      final status = '${r['status'] ?? 'succeeded'}';
      final msg = '${r['message'] ?? ''}';
      if (status == 'failed') {
        toast(context, '备份失败：${msg.isEmpty ? '未知错误' : msg}');
      } else if (status == 'partial') {
        toast(context, '备份部分成功：$msg');
      } else {
        toast(context, '备份成功：${msg.isEmpty ? '已备份到云端' : msg}');
      }
      _loadBackups();
    } catch (e) {
      toast(context, '备份失败（可能超时），请重试或检查云端存储');
    }
  }

  /// 云端备份历史（新→旧）：自动读取存储端，无需下载文件；同时算最近备份状态（状态卡/我的页入口用）
  Future<void> _loadBackups() async {
    try {
      final d = await Api.instance.get('/backup/files');
      final list = ((d['files'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (mounted) setState(() {
        _backups = list;
        _applyLastBackup(list);
      });
    } catch (_) {}
  }

  /// 从历史最新一条算"距今天数 + 显示文本"（created_at 为 UTC ISO，转本地时区按自然日差）
  void _applyLastBackup(List<Map<String, dynamic>> list) {
    if (list.isEmpty) {
      _lastBackupDays = null;
      _lastBackupLabel = '';
      return;
    }
    final created = DateTime.tryParse('${list.first['created_at'] ?? ''}');
    if (created == null) {
      _lastBackupDays = null;
      _lastBackupLabel = '';
      return;
    }
    final local = created.toLocal();
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(local.year, local.month, local.day))
        .inDays;
    _lastBackupDays = days < 0 ? 0 : days;
    final hm = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (days <= 0) {
      _lastBackupLabel = '今天 $hm';
    } else if (days == 1) {
      _lastBackupLabel = '昨天 $hm';
    } else {
      _lastBackupLabel =
          '${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} $hm';
    }
  }

  /// 从云端历史备份恢复（服务端直接读取合并导入，不覆盖现有数据）
  Future<void> _restoreBackup(Map<String, dynamic> b) async {
    // 存储 key 用文件名（name），显示名（name_display）是格式化时间，不能作恢复标识
    final name = '${b['name'] ?? ''}';
    final shown = '${b['name_display'] ?? name}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复备份'),
        content: Text('从云端历史备份「$shown」恢复？\n\n将备份中的记录合并到当前数据：\n· 相同 ID 的记录跳过（不覆盖现有数据）\n· 只新增备份里有、当前没有的记录\n· 附件随归档包一并恢复\n\n建议恢复前先「立即备份/导出」留底。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('恢复')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await Api.instance.post('/backup/files/$name/restore', {});
      final total = ((r['total_inserted'] as num?) ?? 0).toInt();
      toast(context, '恢复完成：共新增 $total 条记录');
      _loadBackups();
    } catch (e) {
      toast(context, '恢复失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: appBarBackground(context)), // 顶部露出主题背景（无标题文字）
      body: Stack(
        children: [
          Positioned.fill(child: themePageBackground(context)),
          ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _backupStatusCard(c),
          _groupTitle(c, '备份'),
          _card(c, [
            _tile(c, Icons.cloud_upload_outlined, '立即备份', '手动备份全库到云端（历史可直接恢复），保留最近 $_autoKeep 份', _backupNow),
            _tile(c, Icons.save_alt_outlined, '导出备份', '导出全库 JSON 存档（建议定期导出留底）', _exportBackup),
            _tile(c, Icons.restore_outlined, '导入备份', '从备份 JSON 合并恢复（不覆盖现有数据）', _importBackup),
          ]),
          const SizedBox(height: 18),
          _groupTitle(c, '自动备份'),
          _card(c, [
            _tile(c, Icons.schedule_outlined, '自动备份时间', '每天 $_autoTime（北京时间）自动备份全库到云端', _pickAutoTime),
            _tile(c, Icons.inventory_2_outlined, '保留备份份数', '云端只保留最近 $_autoKeep 份，超出自动删除最旧', _pickAutoKeep),
          ]),
          if (_backups.isNotEmpty) ...[
            const SizedBox(height: 18),
            _groupTitle(c, '备份历史（云端）'),
            _card(c, [
              for (final b in _backups)
                ListTile(
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(color: c.success.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                    child: Icon(Icons.cloud_done_outlined, size: 20, color: c.success),
                  ),
                  title: Text('${b['name_display'] ?? b['name'] ?? ''}', style: TextStyle(fontSize: 13, color: c.textMain)),
                  subtitle: Text(_fmtSize((b['size'] as num?)?.toInt() ?? 0),
                      style: TextStyle(fontSize: 12, color: c.textSub)),
                  trailing: TextButton(
                    onPressed: () => _restoreBackup(b),
                    child: Text('恢复', style: TextStyle(fontSize: 13, color: c.success)),
                  ),
                ),
            ]),
          ],
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '导出会把全部店铺、商品、出货、收款等数据保存为一个 JSON 文件；'
              '导入只新增备份里有而当前没有的记录，不会覆盖或删除现有数据。',
              style: TextStyle(fontSize: 12, color: c.textSub, height: 1.6),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
        ],
      ),
    );
  }

  /// 备份状态卡：上次备份时间一目了然；从未备份=中性提示，超 7 天未备份=红色警示
  Widget _backupStatusCard(TaozhuColors c) {
    final days = _lastBackupDays;
    IconData icon;
    Color color;
    String title;
    String sub;
    if (days == null) {
      icon = Icons.cloud_off_outlined;
      color = c.textSub;
      title = '从未备份';
      sub = '点「立即备份」把全库数据存到云端，历史可直接恢复';
    } else if (days > 7) {
      icon = Icons.warning_amber_outlined;
      color = c.danger;
      title = '已 $days 天未备份';
      sub = '建议立即备份，或开启每日自动备份';
    } else {
      icon = Icons.cloud_done_outlined;
      color = c.success;
      title = '上次备份：$_lastBackupLabel';
      sub = days <= 1 ? '数据已云端留底' : '距今 $days 天 · 数据已云端留底';
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 26, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: c.textMain)),
                const SizedBox(height: 3),
                Text(sub, style: TextStyle(fontSize: 12, color: color)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupTitle(TaozhuColors c, String t) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textSub)),
    );
  }

  /// 备份文件大小格式化（B / KB / MB）
  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  Widget _card(TaozhuColors c, List<Widget> tiles) {
    return Container(
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          for (int i = 0; i < tiles.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 56, color: c.divider),
            tiles[i],
          ],
        ],
      ),
    );
  }

  Widget _tile(TaozhuColors c, IconData icon, String title, String subtitle, VoidCallback onTap) {
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: c.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 20, color: c.primary),
      ),
      title: Text(title, style: TextStyle(fontSize: 15, color: c.textMain)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: c.textSub)),
      trailing: const Icon(Icons.chevron_right, color: Color(0xFF909399)),
      onTap: onTap,
    );
  }
}
