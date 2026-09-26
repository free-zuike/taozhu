import 'package:flutter/material.dart';
import '../api.dart';
import '../sync_service.dart';
import '../theme.dart';
import 'router.dart';

/// AI 识别设置（仅老板）：多服务商 + 能力绑定（对齐参考项目架构）。
/// 两个 Tab：①服务商（智谱 GLM 内置不可删，可添加/编辑/删除 OpenAI 兼容自定义服务商；
///           列表只显示名称与 Key 状态，模型在编辑弹窗里配置）
///          ②能力绑定（文字记账/图片识别/语音记账各选一个服务商，可混用不同服务商的不同模型）。
/// 服务器广播 ai_config（其他端改了配置）→ 本页监听 SyncService.aiConfigChanged 自动重新拉取。
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});
  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _Provider {
  _Provider({
    required this.id,
    required this.name,
    required this.isBuiltIn,
    required this.hasKey,
    required this.baseUrl,
    required this.textModel,
    required this.visionModel,
    required this.audioModel,
  });
  final String id;
  final String name;
  final bool isBuiltIn;
  bool hasKey;
  final String baseUrl;
  final String textModel;
  final String visionModel;
  final String audioModel;
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  String _tab = 'providers'; // 'providers' | 'binding'

  List<_Provider> _providers = [];
  String _textProviderId = 'zhipu_glm';
  String _visionProviderId = 'zhipu_glm';
  String _speechProviderId = 'zhipu_glm';

  // 本次会话中用户填过的新 Key（PUT 时传给后端覆盖旧值）；'' = 清空
  final Map<String, String> _pendingKeys = {};

  @override
  void initState() {
    super.initState();
    _load();
    // 服务器广播 ai_config（其他端改了服务商/能力绑定）→ 自动重新拉取，无需退出重进
    SyncService.aiConfigChanged.addListener(_load);
  }

  @override
  void dispose() {
    SyncService.aiConfigChanged.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await Api.instance.get('/settings/ai');
      if (!mounted) return;
      setState(() {
        _providers = ((d['providers'] as List?) ?? [])
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .map((m) => _Provider(
                  id: '${m['id'] ?? ''}',
                  name: '${m['name'] ?? ''}',
                  isBuiltIn: (m['is_built_in'] as bool?) ?? false,
                  hasKey: (m['has_key'] as bool?) ?? false,
                  baseUrl: '${m['base_url'] ?? ''}',
                  textModel: '${m['text_model'] ?? ''}',
                  visionModel: '${m['vision_model'] ?? ''}',
                  audioModel: '${m['audio_model'] ?? ''}',
                ))
            .toList();
        final b = (d['binding'] as Map?)?.cast<String, dynamic>() ?? {};
        _textProviderId = '${b['textProviderId'] ?? 'zhipu_glm'}';
        _visionProviderId = '${b['visionProviderId'] ?? 'zhipu_glm'}';
        _speechProviderId = '${b['speechProviderId'] ?? 'zhipu_glm'}';
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _save({bool quiet = false}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final providersPayload = _providers.map((p) {
        final m = <String, dynamic>{
          'id': p.id,
          'name': p.name,
          'is_built_in': p.isBuiltIn,
          'base_url': p.baseUrl,
          'text_model': p.textModel,
          'vision_model': p.visionModel,
          'audio_model': p.audioModel,
        };
        // 本次会话编辑过 Key 的服务商才带上（undefined=后端保留旧值；''=清空；非空=覆盖）
        if (_pendingKeys.containsKey(p.id)) {
          m['api_key'] = _pendingKeys[p.id];
        }
        return m;
      }).toList();
      final d = await Api.instance.put('/settings/ai', {
        'providers': providersPayload,
        'binding': {
          'textProviderId': _textProviderId,
          'visionProviderId': _visionProviderId,
          'speechProviderId': _speechProviderId,
        },
      });
      if (!mounted) return;
      setState(() {
        _saving = false;
        _pendingKeys.clear();
        _providers = ((d['providers'] as List?) ?? [])
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .map((m) => _Provider(
                  id: '${m['id'] ?? ''}',
                  name: '${m['name'] ?? ''}',
                  isBuiltIn: (m['is_built_in'] as bool?) ?? false,
                  hasKey: (m['has_key'] as bool?) ?? false,
                  baseUrl: '${m['base_url'] ?? ''}',
                  textModel: '${m['text_model'] ?? ''}',
                  visionModel: '${m['vision_model'] ?? ''}',
                  audioModel: '${m['audio_model'] ?? ''}',
                ))
            .toList();
      });
      if (!quiet) toast(context, 'AI 配置已保存');
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 连通性测试：后端用文字记账能力跑一条固定话术，验证 Key/地址/模型可用
  Future<void> _testAi() async {
    if (_testing) return;
    setState(() => _testing = true);
    try {
      final d = await Api.instance.post('/ai/test');
      final count = (d['count'] as num?)?.toInt() ?? 0;
      final items = (d['items'] as List?) ?? [];
      final names = items.take(5).map((e) => '${(e as Map)['name'] ?? ''}').where((s) => s.isNotEmpty).join('、');
      toast(context, count > 0 ? 'AI 测试成功：识别出 $count 项商品（$names）' : 'AI 测试成功：返回为空，请检查模型是否支持该能力');
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _editProvider(_Provider p) async {
    final nameCtrl = TextEditingController(text: p.name);
    final baseUrlCtrl = TextEditingController(text: p.baseUrl);
    final textModelCtrl = TextEditingController(text: p.textModel);
    final visionModelCtrl = TextEditingController(text: p.visionModel);
    final audioModelCtrl = TextEditingController(text: p.audioModel);
    final keyCtrl = TextEditingController();
    bool clearKey = false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(p.isBuiltIn ? p.name : '编辑服务商'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!p.isBuiltIn)
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: '服务商名称（如：硅基流动）'),
                  ),
                TextField(
                  controller: baseUrlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(labelText: 'API 地址', hintText: '如 https://open.bigmodel.cn/api/paas/v4'),
                ),
                TextField(
                  controller: keyCtrl,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: p.hasKey ? '已设置（留空=不修改）' : '如 sk-…',
                  ),
                ),
                if (p.hasKey)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('清空该服务商的 Key', style: TextStyle(fontSize: 13)),
                    value: clearKey,
                    onChanged: (v) => setDialogState(() => clearKey = v ?? false),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: visionModelCtrl,
                  decoration: const InputDecoration(labelText: '图片识别模型', hintText: '如 glm-4v-flash（视觉）'),
                ),
                TextField(
                  controller: textModelCtrl,
                  decoration: const InputDecoration(labelText: '文字记账模型', hintText: '如 glm-4-flash（文本）'),
                ),
                TextField(
                  controller: audioModelCtrl,
                  decoration: const InputDecoration(labelText: '语音记账模型', hintText: '如 glm-4-voice（语音转文字）'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final idx = _providers.indexWhere((x) => x.id == p.id);
    if (idx < 0) return;
    final baseUrl = baseUrlCtrl.text.trim();
    if (baseUrl.isEmpty) {
      toast(context, 'API 地址不能为空');
      return;
    }
    setState(() {
      final prov = _providers[idx];
      final updated = _Provider(
        id: prov.id,
        name: p.isBuiltIn ? prov.name : (nameCtrl.text.trim().isEmpty ? prov.name : nameCtrl.text.trim()),
        isBuiltIn: prov.isBuiltIn,
        hasKey: clearKey ? false : (keyCtrl.text.trim().isNotEmpty ? true : prov.hasKey),
        baseUrl: baseUrl,
        textModel: textModelCtrl.text.trim(),
        visionModel: visionModelCtrl.text.trim(),
        audioModel: audioModelCtrl.text.trim(),
      );
      _providers[idx] = updated;
      // 保存时把新 Key 传给后端（undefined=保留 / 非空=覆盖）；勾选清空=传空串（后端清空）
      _pendingKeys[updated.id] = clearKey ? '' : keyCtrl.text.trim();
    });
    await _save();
  }

  Future<void> _addProvider() async {
    final nameCtrl = TextEditingController();
    final baseUrlCtrl = TextEditingController(text: 'https://open.bigmodel.cn/api/paas/v4');
    final keyCtrl = TextEditingController();
    final visionModelCtrl = TextEditingController(text: 'glm-4v-flash');
    final textModelCtrl = TextEditingController(text: 'glm-4-flash');
    final audioModelCtrl = TextEditingController(text: 'glm-4-voice');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加服务商'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '服务商名称（如：硅基流动 / DeepSeek）'),
              ),
              TextField(
                controller: baseUrlCtrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'API 地址（OpenAI 兼容）'),
              ),
              TextField(
                controller: keyCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'API Key'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: visionModelCtrl,
                decoration: const InputDecoration(labelText: '图片识别模型', hintText: '留空=不支持该能力'),
              ),
              TextField(
                controller: textModelCtrl,
                decoration: const InputDecoration(labelText: '文字记账模型', hintText: '留空=不支持该能力'),
              ),
              TextField(
                controller: audioModelCtrl,
                decoration: const InputDecoration(labelText: '语音记账模型', hintText: '留空=不支持该能力'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('添加')),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    final baseUrl = baseUrlCtrl.text.trim();
    if (name.isEmpty || baseUrl.isEmpty) {
      toast(context, '名称与 API 地址必填');
      return;
    }
    final id = 'custom_${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _providers.add(_Provider(
        id: id,
        name: name,
        isBuiltIn: false,
        hasKey: keyCtrl.text.trim().isNotEmpty,
        baseUrl: baseUrl,
        textModel: textModelCtrl.text.trim(),
        visionModel: visionModelCtrl.text.trim(),
        audioModel: audioModelCtrl.text.trim(),
      ));
      _pendingKeys[id] = keyCtrl.text.trim();
    });
    await _save();
  }

  Future<void> _deleteProvider(_Provider p) async {
    if (p.isBuiltIn) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除服务商'),
        content: Text('确定删除「${p.name}」吗？绑定了该服务商的能力会回退到智谱 GLM。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _providers.removeWhere((x) => x.id == p.id);
      if (_textProviderId == p.id) _textProviderId = 'zhipu_glm';
      if (_visionProviderId == p.id) _visionProviderId = 'zhipu_glm';
      if (_speechProviderId == p.id) _speechProviderId = 'zhipu_glm';
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 识别设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _intro(c),
                const SizedBox(height: 16),
                // Tab 切换：服务商 / 能力绑定（分开显示，服务商多了不遮挡绑定）
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'providers', label: Text('服务商')),
                    ButtonSegment(value: 'binding', label: Text('能力绑定')),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (s) => setState(() => _tab = s.first),
                ),
                const SizedBox(height: 16),
                if (_tab == 'providers') _providersSection(c) else _bindingSection(c),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _saving ? null : () => _save(),
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? '保存中…' : '保存 AI 配置'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _testing ? null : _testAi,
                  icon: _testing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.wifi_tethering, size: 20),
                  label: Text(_testing ? '测试中…' : '测试 AI 配置（发一句话验证连通）'),
                ),
                const SizedBox(height: 12),
                Text(
                  '说明：AI 记账/识别为联网增强功能，需要网络并消耗您在模型服务商的额度；Key 仅保存在您的服务器，不回显明文。智谱 GLM 为内置服务商（不可删除），自定义服务商需 OpenAI 兼容接口（填地址+Key+模型名）。三种能力可分别绑定不同服务商，例如文字用智谱、语音用硅基流动。',
                  style: TextStyle(fontSize: 12, color: c.textSub),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _intro(TaozhuColors c) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '配置后，出货/进货记单页的「AI 记账」可用：拍照识别单据、文字一句话记账、语音记账，识别结果自动匹配商品填行。',
        style: TextStyle(fontSize: 13, color: c.textMain),
      ),
    );
  }

  Widget _providersSection(TaozhuColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _groupTitle(c, '服务商（智谱内置 + 自定义 OpenAI 兼容）'),
        _card(c, [
          for (final p in _providers) ..._providerTiles(c, p),
        ]),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _addProvider,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加服务商（硅基流动 / DeepSeek 等）'),
          ),
        ),
      ],
    );
  }

  List<Widget> _bindingSection(TaozhuColors c) {
    return [
      _groupTitle(c, '各能力用哪个服务商（可混用不同模型）'),
      _card(c, [
        _bindingTile(c, Icons.text_fields_outlined, '文字记账', _textProviderId, (v) => setState(() => _textProviderId = v)),
        _bindingTile(c, Icons.image_outlined, '图片识别', _visionProviderId, (v) => setState(() => _visionProviderId = v)),
        _bindingTile(c, Icons.mic_outlined, '语音记账', _speechProviderId, (v) => setState(() => _speechProviderId = v)),
      ]),
    ];
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

  /// 服务商条目：只显示名称 + Key 状态（不显示模型名，避免长模型名影响查看；模型在编辑弹窗里配）
  List<Widget> _providerTiles(TaozhuColors c, _Provider p) {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: c.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
              child: Icon(Icons.cloud_outlined, size: 20, color: c.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(p.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.textMain)),
                      if (p.isBuiltIn) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(color: c.divider, borderRadius: BorderRadius.circular(6)),
                          child: Text('内置', style: TextStyle(fontSize: 10, color: c.textSub)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    p.hasKey ? 'Key 已配置' : '未添加 Key',
                    style: TextStyle(fontSize: 12, color: p.hasKey ? c.success : c.warning),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => _editProvider(p),
            ),
            if (!p.isBuiltIn)
              IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline, size: 20, color: Color(0xFFF56C6C)),
                onPressed: () => _deleteProvider(p),
              ),
          ],
        ),
      ),
    ];
  }

  Widget _bindingTile(TaozhuColors c, IconData icon, String title, String providerId, ValueChanged<String> onChanged) {
    String providerName(String id) {
      for (final p in _providers) {
        if (p.id == id) return p.name;
      }
      return _providers.isEmpty ? '' : _providers.first.name;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: c.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 20, color: c.primary),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 84,
            child: Text(title, style: TextStyle(fontSize: 14, color: c.textMain)),
          ),
          Expanded(
            child: DropdownButton<String>(
              value: providerId,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: _providers
                  .map((p) => DropdownMenuItem(
                        value: p.id,
                        child: Text(p.hasKey ? p.name : '${p.name}（未添加 Key）', overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}