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
      appBar: AppBar(
        toolbarHeight: 140, // 顶部图案区加高（大面积露出背景图案）
        flexibleSpace: appBarBackground(context)), // 顶部露出主题背景（无标题文字）
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
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _devices.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (ctx, i) {
                      final dev = _devices[i];
                      final platform = '${dev['platform'] ?? ''}';
                      final icon = platform == 'Web'
                          ? Icons.language
                          : platform == '小程序'
                              ? Icons.phone_iphone
                              : Icons.smartphone;
                      final ip = '${dev['ip'] ?? ''}';
                      final ver = '${dev['version'] ?? ''}';
                      return Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12), side: BorderSide(color: c.divider)),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                      color: c.primary.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(10)),
                                  child: Icon(icon, size: 22, color: c.primary),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('${dev['device_name'] ?? ''}',
                                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.textMain),
                                          maxLines: 1, overflow: TextOverflow.ellipsis),
                                      const SizedBox(height: 2),
                                      Text(platform,
                                          style: TextStyle(fontSize: 11, color: c.textSub)),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: '删除设备',
                                  icon: const Icon(Icons.delete_outline, color: Color(0xFFEF4444)),
                                  onPressed: _busy ? null : () => _remove(dev),
                                ),
                              ]),
                              const SizedBox(height: 6),
                              Container(height: 1, color: c.divider),
                              const SizedBox(height: 10),
                              // 三格信息：IP / 版本 / 最近活跃（对齐店铺卡布局）
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(children: [
                                      Text(ip.isEmpty ? '--' : ip,
                                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: ip.isEmpty ? c.textSub : c.textMain)),
                                      const SizedBox(height: 2),
                                      Text('IP', style: TextStyle(fontSize: 11, color: c.textSub)),
                                    ]),
                                  ),
                                  Container(width: 1, height: 28, color: c.divider),
                                  Expanded(
                                    child: Column(children: [
                                      Text(ver.isEmpty ? '--' : 'v$ver',
                                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: ver.isEmpty ? c.textSub : c.textMain)),
                                      const SizedBox(height: 2),
                                      Text('版本', style: TextStyle(fontSize: 11, color: c.textSub)),
                                    ]),
                                  ),
                                  Container(width: 1, height: 28, color: c.divider),
                                  Expanded(
                                    child: Column(children: [
                                      Text(_shortTime('${dev['last_active_at'] ?? ''}'),
                                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.textMain)),
                                      const SizedBox(height: 2),
                                      Text('最近活跃', style: TextStyle(fontSize: 11, color: c.textSub)),
                                    ]),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}