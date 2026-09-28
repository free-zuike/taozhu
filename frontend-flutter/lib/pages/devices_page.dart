/// 设备管理：登录设备列表（名称/平台/最后活跃），可删除（下次该设备登录重新记录）
import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';
import 'router.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});
  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await Api.instance.get('/devices');
      final devices = ((d['devices'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (mounted) {
        setState(() {
          _devices = devices;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        toast(context, e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  Future<void> _remove(Map<String, dynamic> dev) async {
    final name = '${dev['device_name'] ?? ''}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除设备'),
        content: Text('删除「$name」后，该设备下次登录会重新记录。确定删除？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await Api.instance.delete('/devices/${dev['id']}');
      if (mounted) {
        setState(() {
          _devices.removeWhere((x) => x['id'] == dev['id']);
          _busy = false;
        });
        toast(context, '已删除「$name」');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  String _shortTime(String iso) {
    if (iso.length >= 16) return '${iso.substring(0, 10)} ${iso.substring(11, 16)}';
    return iso;
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(flexibleSpace: appBarBackground(context)), // 顶部露出主题背景（无标题文字）
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : _devices.isEmpty
                ? ListView(
                    children: [
                      const SizedBox(height: 80),
                      Center(child: Text('暂无登录设备', style: TextStyle(color: c.textSub))),
                      const SizedBox(height: 8),
                      Center(
                        child: Text('登录过的设备会显示在这里', style: TextStyle(fontSize: 12, color: c.textSub)),
                      ),
                    ],
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Table(
                          defaultColumnWidth: const FixedColumnWidth(120),
                          border: TableBorder.all(color: c.divider.withValues(alpha: 0.4), width: 0.6),
                          children: [
                            // 表头
                            TableRow(
                              decoration: BoxDecoration(color: c.primary.withValues(alpha: 0.08)),
                              children: [
                                for (final h in ['设备', '平台', 'IP', '版本', '最近活跃', ''])
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    child: Text(h,
                                        style: TextStyle(
                                            fontSize: 13, fontWeight: FontWeight.w700, color: c.textMain)),
                                  ),
                              ],
                            ),
                            for (final dev in _devices)
                              TableRow(
                                decoration: BoxDecoration(color: c.card.withValues(alpha: 0.6)),
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    child: Text('${dev['device_name'] ?? ''}',
                                        style: TextStyle(
                                            fontSize: 13, fontWeight: FontWeight.w600, color: c.textMain)),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    child: Text('${dev['platform'] ?? ''}', style: TextStyle(fontSize: 12, color: c.textSub)),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    child: Text('${dev['ip'] ?? ''}', style: TextStyle(fontSize: 12, color: c.textSub)),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    child: Text('${dev['version'] ?? ''}'.isNotEmpty ? 'v${dev['version']}' : '',
                                        style: TextStyle(fontSize: 12, color: c.textSub)),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    child: Text(_shortTime('${dev['last_active_at'] ?? ''}'),
                                        style: TextStyle(fontSize: 12, color: c.textSub)),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(6),
                                      onTap: _busy ? null : () => _remove(dev),
                                      child: Padding(
                                        padding: const EdgeInsets.all(4),
                                        child: Icon(Icons.delete_outline, size: 18, color: const Color(0xFFEF4444)),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}