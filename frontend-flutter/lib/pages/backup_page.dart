import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api.dart';
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

  /// 全库备份导出：Web 直接下载文件；移动/桌面弹系统分享保存
  Future<void> _exportBackup() async {
    try {
      final d = await Api.instance.get('/backup');
      final bytes = Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(d)));
      final name = 'taozhu-backup-${DateTime.now().toIso8601String().split('T').first}.json';
      await saveBytes(bytes, name, 'application/json', '陶朱数据备份');
      if (kIsWeb) toast(context, '备份已导出');
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
        content: const Text('将备份文件中的记录合并到当前账本：\n· 相同 ID 的记录跳过（不覆盖现有数据）\n· 只新增备份里有、本地没有的记录\n\n建议导入前先导出留底。'),
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

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      appBar: AppBar(title: const Text('数据备份')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _groupTitle(c, '备份'),
          _card(c, [
            _tile(c, Icons.save_alt_outlined, '导出备份', '导出全库 JSON 存档（建议定期导出留底）', _exportBackup),
            _tile(c, Icons.restore_outlined, '导入备份', '从备份 JSON 合并恢复（不覆盖现有数据）', _importBackup),
          ]),
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
    );
  }

  Widget _groupTitle(TaozhuColors c, String t) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textSub)),
    );
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
