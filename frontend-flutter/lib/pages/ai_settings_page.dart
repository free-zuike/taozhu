import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';
import 'router.dart';

/// AI 识别设置（仅老板）：API 地址 / Key / 模型，供 AI 记账识别使用（智谱/OpenAI 兼容）。
/// 数据存后端 settings 表（/settings/ai），Key 不入前端缓存（GET 不回显明文，仅 has_key）。
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});
  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  bool _loading = true;
  bool _hasKey = false;
  bool _saving = false;

  // 回显值（不可变部分）：Key 占位提示 `已设置 ****` / 未设置
  final _apiKeyCtrl = TextEditingController();
  final _baseUrlCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _textModelCtrl = TextEditingController();
  final _audioModelCtrl = TextEditingController();

  String _baseUrl = '';
  String _model = '';
  String _textModel = '';
  String _audioModel = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _baseUrlCtrl.dispose();
    _modelCtrl.dispose();
    _textModelCtrl.dispose();
    _audioModelCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await Api.instance.get('/settings/ai');
      if (!mounted) return;
      setState(() {
        _hasKey = (d['has_key'] as bool?) ?? false;
        _baseUrl = '${d['base_url'] ?? ''}';
        _model = '${d['model'] ?? ''}';
        _textModel = '${d['text_model'] ?? ''}';
        _audioModel = '${d['audio_model'] ?? ''}';
        _baseUrlCtrl.text = _baseUrl;
        _modelCtrl.text = _model;
        _textModelCtrl.text = _textModel;
        _audioModelCtrl.text = _audioModel;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _save() async {
    // 清空 Key 输入 = 清除 Key（保持原值逻辑：不传 api_key 字段则不修改；传空串=清除）
    final body = <String, dynamic>{};
    final key = _apiKeyCtrl.text.trim();
    if (key.isNotEmpty) body['api_key'] = key;
    if (_hasKey && key.isEmpty) body['api_key'] = '';
    if (_baseUrlCtrl.text.trim() != _baseUrl) body['base_url'] = _baseUrlCtrl.text.trim();
    if (_modelCtrl.text.trim() != _model) body['model'] = _modelCtrl.text.trim();
    if (_textModelCtrl.text.trim() != _textModel) body['text_model'] = _textModelCtrl.text.trim();
    if (_audioModelCtrl.text.trim() != _audioModel) body['audio_model'] = _audioModelCtrl.text.trim();
    if (body.isEmpty) {
      toast(context, '没有需要保存的修改');
      return;
    }
    setState(() => _saving = true);
    try {
      final d = await Api.instance.put('/settings/ai', body);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _hasKey = (d['has_key'] as bool?) ?? false;
        _baseUrl = '${d['base_url'] ?? ''}';
      });
      toast(context, 'AI 配置已保存');
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
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
                const SizedBox(height: 18),
                _groupTitle(c, 'API 配置'),
                _card(c, [
                  _fieldTile(c, Icons.key_outlined, 'API Key', _apiKeyCtrl,
                      hint: _hasKey ? '已设置（填新值可更换；清空并保存=删除 Key）' : '如智谱 API Key（sk-…）',
                      obscure: true),
                  _fieldTile(c, Icons.dns_outlined, 'API 地址', _baseUrlCtrl,
                      hint: '默认智谱：https://open.bigmodel.cn/api/paas/v4，兼容 OpenAI 服务商可填自己的'),
                ]),
                const SizedBox(height: 18),
                _groupTitle(c, '模型（分能力）'),
                _card(c, [
                  _fieldTile(c, Icons.image_outlined, '图片识别模型', _modelCtrl,
                      hint: '拍照识别单据：默认 glm-4v-flash'),
                  _fieldTile(c, Icons.text_fields_outlined, '文字记账模型', _textModelCtrl,
                      hint: '一句话文字记账：默认 glm-4-flash'),
                  _fieldTile(c, Icons.mic_outlined, '语音记账模型', _audioModelCtrl,
                      hint: '语音转文字：默认 glm-4-voice'),
                ]),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? '保存中…' : '保存 AI 配置'),
                ),
                const SizedBox(height: 12),
                Text(
                  '说明：AI 记账/识别为联网增强功能，需要网络并消耗您在模型服务商的额度；Key 仅保存在您的服务器，不会上传到本地以外。支持智谱 GLM 与硅基流动等 OpenAI 兼容服务（填对应地址+Key+模型名）。',
                  style: TextStyle(fontSize: 12, color: c.textSub),
                ),
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

  Widget _fieldTile(TaozhuColors c, IconData icon, String title, TextEditingController ctrl,
      {String? hint, bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: c.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 20, color: c.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: ctrl,
              obscureText: obscure,
              decoration: InputDecoration(
                labelText: title,
                hintText: hint,
                isDense: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}