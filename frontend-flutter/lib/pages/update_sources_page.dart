import 'package:flutter/material.dart';
import '../theme.dart';
import '../utils/update_sources.dart';
import 'router.dart';

/// 下载源管理：官方 GitHub 源固定置顶（始终启用）；
/// 第三方/自定义镜像默认停用，逐个「测试」验证可达（Content-Length ≥ 1MB 防拦截页误判）后再手动启用，
/// 支持添加 / 修改 / 删除；配置存服务器跨端同步（Web 设置 App 可读）；自动更新时官方源失败才会轮换到已启用的自定义源。
class UpdateSourcesPage extends StatefulWidget {
  const UpdateSourcesPage({super.key});
  @override
  State<UpdateSourcesPage> createState() => _UpdateSourcesPageState();
}

class _UpdateSourcesPageState extends State<UpdateSourcesPage> {
  List<Map<String, dynamic>> _sources = [];
  /// url → 最近一次测试结果（不存在=未测试）
  final Map<String, ({bool ok, int ms})> _testResult = {};
  final Set<String> _testing = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await loadUpdateSources();
    if (mounted) setState(() => _sources = list);
  }

  Future<void> _persist() async {
    await saveUpdateSources(_sources);
    if (mounted) setState(() {});
  }

  /// 探测一个前缀源（Web 走服务器、原生本地直连；失败也记录结果，让用户看到「不可达」）
  Future<void> _test(String prefix) async {
    if (_testing.contains(prefix)) return;
    setState(() {
      _testing.add(prefix);
      _testResult.remove(prefix);
    });
    final ms = await probeDownloadSource(prefix);
    if (!mounted) return;
    setState(() {
      _testing.remove(prefix);
      _testResult[prefix] = ms == null ? (ok: false, ms: 0) : (ok: true, ms: ms);
    });
  }

  static String _normalize(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return '';
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    if (!u.endsWith('/')) u = '$u/';
    return u;
  }

  Future<void> _inputDialog({
    required String title,
    required TextEditingController ctrl,
    required void Function(String url) onSave,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.url,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '镜像前缀（https://ghproxy.com/ 等）',
            hintText: 'https://',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final url = _normalize(ctrl.text);
    if (url.isEmpty) {
      toast(context, '请输入下载源地址');
      return;
    }
    if (_sources.any((x) => '${x['url']}' == url)) {
      toast(context, '该下载源已存在');
      return;
    }
    onSave(url);
  }

  Future<void> _add(String url) async {
    // 新增默认停用：先测试确认可达，再由用户手动启用
    setState(() => _sources.add({'url': url, 'enabled': false}));
    await _persist();
    toast(context, '已添加（停用）——可先「测试」，确认可达后再启用');
  }

  Future<void> _edit(Map<String, dynamic> s, String url) async {
    final oldUrl = '${s['url']}';
    s['url'] = url;
    if (oldUrl != url) _testResult.remove(oldUrl);
    await _persist();
    toast(context, '已保存');
  }

  Future<void> _remove(Map<String, dynamic> s) async {
    _sources.remove(s);
    _testResult.remove('${s['url']}');
    await _persist();
    toast(context, '已删除');
  }

  Widget _officialTile(TaozhuColors c) {
    const prefix = '';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.primary.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.verified_outlined, size: 18, color: c.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('GitHub 官方源',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textMain)),
                Text('始终启用 · 自动更新默认直连', style: TextStyle(fontSize: 11, color: c.textSub)),
              ],
            ),
          ),
          TextButton(
            onPressed: _testing.contains(prefix) ? null : () => _test(prefix),
            child: const Text('测试'),
          ),
        ],
      ),
    );
  }

  Widget _sourceTile(TaozhuColors c, Map<String, dynamic> s) {
    final url = '${s['url']}';
    final enabled = s['enabled'] == true;
    final result = _testResult[url];
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.fromLTRB(6, 8, 4, 8),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: enabled ? c.primary.withOpacity(0.35) : c.divider),
      ),
      child: Row(
        children: [
          Switch(
            value: enabled,
            onChanged: (v) async {
              s['enabled'] = v;
              await _persist();
            },
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: c.textMain)),
                if (_testing.contains(url))
                  Text('测试中…', style: TextStyle(fontSize: 11, color: c.textSub))
                else if (result != null)
                  Text(
                    result.ok ? '可达 · ${result.ms}ms' : '不可达（网络受限或镜像失效）',
                    style: TextStyle(fontSize: 11, color: result.ok ? c.success : c.danger),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: _testing.contains(url) ? null : () => _test(url),
            child: const Text('测试'),
          ),
          IconButton(
            tooltip: '修改',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.edit_outlined, size: 18, color: c.textSub),
            onPressed: () => _inputDialog(
              title: '修改下载源',
              ctrl: TextEditingController(text: url),
              onSave: (u) => _edit(s, u),
            ),
          ),
          IconButton(
            tooltip: '删除',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.delete_outline, size: 18, color: c.danger),
            onPressed: () => _remove(s),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(title: const Text('下载源管理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
            child: Text(
              '自动更新默认直连 GitHub 官方源；第三方镜像默认停用，请先「测试」确认可达（安装包 ≥ 1MB 才算可用，防止代理拦截页被当成安装包）后再启用。官方源失败时才会轮换到已启用的镜像。',
              style: TextStyle(fontSize: 12, color: c.textSub, height: 1.5),
            ),
          ),
          _officialTile(c),
          for (final s in _sources) _sourceTile(c, s),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _inputDialog(
              title: '添加下载源',
              ctrl: TextEditingController(),
              onSave: _add,
            ),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加下载源'),
          ),
        ],
      ),
    );
  }
}
