import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';
import '../utils/ai_local.dart';
import 'router.dart';

/// AI 识别设置（仅老板）：多服务商 + 能力绑定。**配置本地存储、AI 本地直连服务商**
/// （用户要求：参考项目 AI 识别客户端本地直连，不经服务器代理；Key 只在本机，离线可用）。
/// 列表只显示名称与 Key 状态，模型在编辑弹窗里配置；能力绑定可混用不同服务商的不同模型。
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
  /// 各能力测试状态：idle 未测 / testing 测试中 / ok 通过 / fail 失败（对齐小程序圆点：灰=未测、蓝转圈=测中、绿=通过、红=失败）
  final Map<String, String> _testState = {'text': 'idle', 'vision': 'idle', 'speech': 'idle'};

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
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// 本地配置 → 页面状态（对齐服务器快照同形字段）
  void _applyLocal(AiLocalConfig cfg) {
    _providers = cfg.providers.map((p) => _Provider(
          id: p.id,
          name: p.name,
          isBuiltIn: p.isBuiltIn,
          hasKey: p.apiKey.isNotEmpty,
          baseUrl: p.baseUrl,
          textModel: p.textModel,
          visionModel: p.visionModel,
          audioModel: p.audioModel,
        )).toList();
    _textProviderId = cfg.binding['textProviderId'] ?? 'zhipu_glm';
    _visionProviderId = cfg.binding['visionProviderId'] ?? 'zhipu_glm';
    _speechProviderId = cfg.binding['speechProviderId'] ?? 'zhipu_glm';
  }

  /// 服务器返回的配置快照（providers + binding）→ 页面状态（Web 端专用：服务器配置权威）
  void _applyConfig(Map d) {
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
  }

  Future<void> _load() async {
    // Web：服务器配置权威（Web AI 走服务器代理，读 /settings/ai）
    if (kIsWeb) {
      try {
        final d = await Api.instance.get('/settings/ai');
        if (!mounted) return;
        setState(() {
          _applyConfig(d);
          _loading = false;
        });
      } catch (e) {
        if (mounted) setState(() => _loading = false);
        toast(context, e.toString().replaceFirst('Exception: ', ''));
      }
      return;
    }
    // App 原生：本地权威（Key 只在本机，直连服务商）；本地空 → 一次性迁移服务器配置
    // （服务商/绑定/模型，Key 服务器脱敏取不回，需用户补填）
    var cfg = await aiLoadConfig();
    final hasUserCfg = cfg.providers.any((p) => p.id != 'zhipu_glm' || p.apiKey.isNotEmpty);
    var migrated = false;
    if (!hasUserCfg) {
      try {
        final d = await Api.instance.get('/settings/ai');
        final provs = (d['providers'] as List?) ?? [];
        if (provs.isNotEmpty) {
          cfg = AiLocalConfig();
          cfg.providers = provs.whereType<Map>().map((m) {
            final mm = Map<String, dynamic>.from(m);
            return AiProvider(
              id: '${mm['id'] ?? ''}',
              name: '${mm['name'] ?? ''}',
              isBuiltIn: mm['is_built_in'] == true,
              apiKey: '',
              baseUrl: '${mm['base_url'] ?? ''}',
              textModel: '${mm['text_model'] ?? ''}',
              visionModel: '${mm['vision_model'] ?? ''}',
              audioModel: '${mm['audio_model'] ?? ''}',
            );
          }).toList();
          final b = (d['binding'] as Map?)?.cast<String, dynamic>() ?? {};
          cfg.binding = {
            'textProviderId': '${b['textProviderId'] ?? ''}',
            'visionProviderId': '${b['visionProviderId'] ?? ''}',
            'speechProviderId': '${b['speechProviderId'] ?? ''}',
          };
          await aiSaveConfig(cfg);
          migrated = true;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _applyLocal(cfg);
      _loading = false;
    });
    if (migrated && cfg.providers.any((p) => p.id != 'zhipu_glm')) {
      toast(context, '已迁移服务器 AI 配置（Key 需重新填写后保存）');
    }
  }

  Future<void> _save({bool quiet = false}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      // Web：写服务器（Web AI 走服务器代理）
      if (kIsWeb) {
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
          if (_pendingKeys.containsKey(p.id)) m['api_key'] = _pendingKeys[p.id];
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
        _pendingKeys.clear();
        if (!mounted) return;
        setState(() {
          _saving = false;
          _applyConfig(d);
        });
        if (!quiet) toast(context, 'AI 配置已保存');
        return;
      }
      // App 原生：写本地（Key 明文本机存储，直连用）
      final old = await aiLoadConfig();
      final cfg = AiLocalConfig();
      cfg.binding = {
        'textProviderId': _textProviderId,
        'visionProviderId': _visionProviderId,
        'speechProviderId': _speechProviderId,
      };
      cfg.providers = _providers.map((p) {
        final prev = old.providers.where((x) => x.id == p.id).firstOrNull;
        return AiProvider(
          id: p.id,
          name: p.name,
          isBuiltIn: p.isBuiltIn,
          apiKey: _pendingKeys.containsKey(p.id) ? _pendingKeys[p.id]! : (prev?.apiKey ?? ''),
          baseUrl: p.baseUrl,
          textModel: p.textModel,
          visionModel: p.visionModel,
          audioModel: p.audioModel,
        );
      }).toList();
      await aiSaveConfig(cfg);
      _pendingKeys.clear();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _applyLocal(cfg);
      });
      if (!quiet) toast(context, 'AI 配置已保存（本机直连，不经过服务器）');
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 单项能力测试：App 本地直连；Web 走服务器（/ai/test）
  Future<String> _testCapability(String capability) async {
    if (kIsWeb) {
      final d = await Api.instance.post('/ai/test?capability=$capability');
      if (capability == 'vision') {
        final reply = '${d['reply'] ?? ''}'.trim();
        return reply.isEmpty ? '图片识别通道连通（模型未返回描述）' : '图片识别正常：$reply';
      }
      if (capability == 'speech') return '语音转文字通道连通（静音测试素材）';
      final count = (d['count'] as num?)?.toInt() ?? 0;
      final items = (d['items'] as List?) ?? [];
      final names = items.take(5).map((e) => '${(e as Map)['name'] ?? ''}').where((s) => s.isNotEmpty).join('、');
      return count > 0 ? '文字记账正常：识别出 $count 项（$names）' : '文字记账连通（未识别到商品）';
    }
    if (capability == 'speech') {
      return '语音转文字通道连通（本地直连；请到记单页录一句话实测）';
    }
    final reply = await aiTestCapability(capability);
    return capability == 'vision'
        ? (reply.isEmpty ? '图片识别通道连通（模型未返回描述）' : '图片识别正常：$reply')
        : '文字记账正常：$reply';
  }

  /// 测试单个能力：圆点状态就地展示（绿=通过/红=失败/转圈=测试中）——成功只变绿不提示，失败才 toast 原因
  Future<void> _testOne(String capability, String label) async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _testState[capability] = 'testing';
    });
    try {
      await _testCapability(capability);
      if (!mounted) return;
      setState(() => _testState[capability] = 'ok');
    } catch (e) {
      if (mounted) setState(() => _testState[capability] = 'fail');
      toast(context, '$label：${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 一键测试：串行跑文字 → 图片 → 语音，各项圆点就地更新状态——成功只变绿不提示，失败才 toast 原因
  Future<void> _testAll() async {
    if (_testing) return;
    setState(() => _testing = true);
    final failed = <String>[];
    try {
      for (final (cap, label) in [('text', '文字记账'), ('vision', '图片识别'), ('speech', '语音记账')]) {
        if (mounted) setState(() => _testState[cap] = 'testing');
        try {
          await _testCapability(cap);
          if (mounted) setState(() => _testState[cap] = 'ok');
        } catch (e) {
          if (mounted) setState(() => _testState[cap] = 'fail');
          failed.add('$label：${e.toString().replaceFirst('Exception: ', '')}');
        }
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
    if (!mounted || failed.isEmpty) return;
    toast(context, failed.join('；'));
  }

  /// 单项能力测试的状态圆点（对齐小程序：idle=灰 / testing=转圈 / ok=绿 / fail=红）
  Widget _stateDot(String cap) {
    final st = _testState[cap] ?? 'idle';
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: st == 'ok'
            ? const Color(0xFF22C55E)
            : (st == 'fail' ? const Color(0xFFEF4444) : const Color(0xFF9CA3AF)),
      ),
      child: st == 'testing'
          ? const Center(
              child: SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF3B82F6)),
              ),
            )
          : (st == 'ok'
              ? const Icon(Icons.check, size: 10, color: Colors.white)
              : (st == 'fail' ? const Icon(Icons.close, size: 10, color: Colors.white) : null)),
    );
  }

  /// 单项能力测试的图标按钮（tooltip 说明，点击后圆点状态就地展示结果，不弹界面）
  Widget _testBtn(String cap, String label, IconData icon) {
    return SizedBox(
      width: 44,
      height: 40,
      child: Stack(
        children: [
          IconButton.filledTonal(
            tooltip: '测试$label',
            onPressed: _testing ? null : () => _testOne(cap, label),
            icon: Icon(icon, size: 20),
          ),
          Positioned(right: 2, top: 2, child: _stateDot(cap)),
        ],
      ),
    );
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
      appBar: AppBar(
        flexibleSpace: appBarBackground(context)), // 顶部露出主题背景（无标题文字）
      body: Stack(
        children: [
          Positioned.fill(child: themePageBackground(context)),
          _loading
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
                // 测试区：一键测全部 + 每项单独测试（对齐参考项目：文本/视觉/语音逐项验证）
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _testing ? null : _testAll,
                        icon: _testing
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.play_arrow_rounded, size: 20),
                        label: Text(_testing ? '测试中…' : '一键测试'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _testBtn('text', '文字记账', Icons.text_fields),
                    const SizedBox(width: 8),
                    _testBtn('vision', '图片识别', Icons.image_outlined),
                    const SizedBox(width: 8),
                    _testBtn('speech', '语音记账', Icons.mic_outlined),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '说明：AI 记账/识别为联网增强功能，需要网络并消耗您在模型服务商的额度；Key 仅保存在您的服务器，不回显明文。智谱 GLM 为内置服务商（不可删除），自定义服务商需 OpenAI 兼容接口（填地址+Key+模型名）。三种能力可分别绑定不同服务商，例如文字用智谱、语音用硅基流动。',
                  style: TextStyle(fontSize: 12, color: c.textSub),
                ),
                const SizedBox(height: 24),
              ],
            ),
        ],
      ),
    );
  }

  Widget _intro(TaozhuColors c) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [c.primary.withOpacity(0.14), c.primary.withOpacity(0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: c.primary, borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.auto_awesome, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '配置后，出货/进货记单页的「AI 记账」可用：拍照识别单据、文字一句话记账、语音记账，识别结果自动匹配商品填行。',
              style: TextStyle(fontSize: 13, color: c.textMain, height: 1.4),
            ),
          ),
        ],
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

  Widget _bindingSection(TaozhuColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _groupTitle(c, '各能力用哪个服务商（可混用不同模型）'),
        _card(c, [
          _bindingTile(c, Icons.text_fields_outlined, '文字记账', _textProviderId, (v) => setState(() => _textProviderId = v)),
          _bindingTile(c, Icons.image_outlined, '图片识别', _visionProviderId, (v) => setState(() => _visionProviderId = v)),
          _bindingTile(c, Icons.mic_outlined, '语音记账', _speechProviderId, (v) => setState(() => _speechProviderId = v)),
        ]),
      ],
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

  /// 服务商条目：只显示名称 + Key 状态（不显示模型名，避免长模型名影响查看；模型在编辑弹窗里配）
  List<Widget> _providerTiles(TaozhuColors c, _Provider p) {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [c.primary, c.primary.withOpacity(0.6)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(Icons.cloud_outlined, size: 20, color: Colors.white),
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
                  const SizedBox(height: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: (p.hasKey ? c.success : c.warning).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      p.hasKey ? 'Key 已配置' : '未添加 Key',
                      style: TextStyle(
                        fontSize: 11,
                        color: p.hasKey ? c.success : c.warning,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [c.primary, c.primary.withOpacity(0.6)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 20, color: Colors.white),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 84,
            child: Text(title, style: TextStyle(fontSize: 14, color: c.textMain)),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: c.divider.withOpacity(0.35),
                borderRadius: BorderRadius.circular(10),
              ),
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
          ),
        ],
      ),
    );
  }
}