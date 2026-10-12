/// AI 记账本地直连（用户要求：参考项目 AI 识别是客户端本地直连服务商，不经过服务器代理）。
/// Key/服务商配置本地存储（SharedPreferences），拍照/文字/语音识别直接调服务商 API
/// （OpenAI 兼容 chat/completions；智谱视觉/语音同协议），结果容错解析成商品草稿。
/// 服务器 /ai/parse-* 仅 Web/小程序（平台域名限制）继续使用。
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 商品草稿（对齐后端 ai-parse DraftItem）
class AiDraftItem {
  final String name;
  final String unit;
  final double quantity;
  final double price;
  AiDraftItem(this.name, this.unit, this.quantity, this.price);
}

/// 整单识别结果（购货单位/日期 + 明细）
class AiInvoice {
  final String client;
  final String date;
  final List<AiDraftItem> items;
  AiInvoice(this.client, this.date, this.items);
}

class AiProvider {
  String id, name;
  bool isBuiltIn;
  String apiKey, baseUrl, textModel, visionModel, audioModel;
  AiProvider({required this.id, required this.name, this.isBuiltIn = false, this.apiKey = '', this.baseUrl = '', this.textModel = '', this.visionModel = '', this.audioModel = ''});

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'is_built_in': isBuiltIn, 'api_key': apiKey,
        'base_url': baseUrl, 'text_model': textModel, 'vision_model': visionModel, 'audio_model': audioModel,
      };
  static AiProvider fromJson(Map<String, dynamic> j) => AiProvider(
        id: '${j['id'] ?? ''}', name: '${j['name'] ?? ''}',
        isBuiltIn: j['is_built_in'] == true || j['isBuiltIn'] == true,
        apiKey: '${j['api_key'] ?? j['apiKey'] ?? ''}',
        baseUrl: '${j['base_url'] ?? j['baseUrl'] ?? ''}',
        textModel: '${j['text_model'] ?? j['textModel'] ?? ''}',
        visionModel: '${j['vision_model'] ?? j['visionModel'] ?? ''}',
        audioModel: '${j['audio_model'] ?? j['audioModel'] ?? ''}',
      );
}

/// AI 配置（本地权威，离线可用）：服务商列表 + 三能力绑定
class AiLocalConfig {
  List<AiProvider> providers = [];
  Map<String, String> binding = {'textProviderId': '', 'visionProviderId': '', 'speechProviderId': ''};
}

const _cfgKey = 'taozhu_ai_local_config';

/// 智谱内置默认
AiProvider _zhipu() => AiProvider(
      id: 'zhipu_glm', name: '智谱GLM', isBuiltIn: true,
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      textModel: 'glm-4-flash', visionModel: 'glm-4v-flash', audioModel: 'glm-4-voice',
    );

Future<AiLocalConfig> aiLoadConfig() async {
  final cfg = AiLocalConfig();
  try {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_cfgKey);
    if (raw != null && raw.isNotEmpty) {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      cfg.providers = ((data['providers'] as List?) ?? [])
          .cast<Map<String, dynamic>>()
          .map(AiProvider.fromJson)
          .toList();
      final b = data['binding'] as Map<String, dynamic>? ?? {};
      cfg.binding = {
        'textProviderId': '${b['textProviderId'] ?? ''}',
        'visionProviderId': '${b['visionProviderId'] ?? ''}',
        'speechProviderId': '${b['speechProviderId'] ?? ''}',
      };
    }
  } catch (_) {}
  // 空配置：至少内置智谱（Key 空，直连会报未配置提示）
  if (cfg.providers.isEmpty) cfg.providers.add(_zhipu());
  return cfg;
}

Future<void> aiSaveConfig(AiLocalConfig cfg) async {
  final p = await SharedPreferences.getInstance();
  await p.setString(_cfgKey, jsonEncode({
    'providers': cfg.providers.map((x) => x.toJson()).toList(),
    'binding': cfg.binding,
  }));
}

AiProvider _providerFor(AiLocalConfig cfg, String cap) {
  final id = cfg.binding[cap] ?? '';
  return cfg.providers.where((p) => p.id == id).firstOrNull ?? cfg.providers.first;
}

String _modelFor(AiProvider p, String cap) => cap == 'text'
    ? (p.textModel.isNotEmpty ? p.textModel : 'glm-4-flash')
    : cap == 'vision'
        ? (p.visionModel.isNotEmpty ? p.visionModel : 'glm-4v-flash')
        : (p.audioModel.isNotEmpty ? p.audioModel : 'glm-4-voice');

/// 直连服务商 chat/completions（OpenAI 兼容；智谱 GLM 同协议）
Future<String> _chatCompletion(AiProvider p, String cap, List<Map<String, dynamic>> messages) async {
  if (p.apiKey.trim().isEmpty) {
    throw Exception('「${p.name}」未配置 Key，请到 AI 识别设置添加');
  }
  final url = '${p.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';
  final resp = await http.post(
    Uri.parse(url),
    headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${p.apiKey.trim()}'},
    body: jsonEncode({
      'model': _modelFor(p, cap),
      'messages': messages,
      'temperature': 0.2,
    }),
  ).timeout(const Duration(seconds: 60));
  if (resp.statusCode != 200) {
    throw Exception('AI 通道 ${resp.statusCode}: ${resp.body.length > 120 ? resp.body.substring(0, 120) : resp.body}');
  }
  final d = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  final content = (d['choices'] as List?)?[0]?['message']?['content'];
  return '${content ?? ''}'.trim();
}

String _pick(Map<String, dynamic> o, List<String> keys) {
  for (final k in keys) {
    final v = o[k];
    if (v != null && '$v'.isNotEmpty) return '$v';
  }
  return '';
}

double _toNum(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) {
    final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(v);
    return m == null ? 0 : double.tryParse(m.group(0)!) ?? 0;
  }
  return 0;
}

AiDraftItem _normalizeOne(Map<String, dynamic> o) => AiDraftItem(
      _pick(o, ['name', '名称', '商品名', '商品', 'item']),
      _pick(o, ['unit', '单位', 'uom']),
      _toNum(_pick(o, ['quantity', '数量', 'qty', 'count', 'amount'])),
      _toNum(_pick(o, ['price', '单价', 'unit_price', '价格', 'amount_price', '进货价', '出货价'])),
    );

String? _extractBalanced(String s) {
  final openIdx = [s.indexOf('{'), s.indexOf('[')]
      .where((i) => i >= 0)
      .fold<int?>(null, (a, b) => a == null ? b : (b < a ? b : a));
  if (openIdx == null) return null;
  final open = s[openIdx];
  final close = open == '{' ? '}' : ']';
  var depth = 0;
  var inStr = false;
  for (var i = openIdx; i < s.length; i++) {
    final ch = s[i];
    if (ch == '"') inStr = !inStr;
    if (inStr) continue;
    if (ch == open) depth++;
    else if (ch == close) {
      depth--;
      if (depth == 0) return s.substring(openIdx, i + 1);
    }
  }
  return null;
}

List<Map<String, dynamic>> _unwrapItems(Object? input) {
  if (input is List) return input.cast<Map<String, dynamic>>();
  if (input is Map) {
    for (final k in ['items', 'data', 'results', 'rows', '商品', '商品清单', 'list']) {
      final v = input[k];
      if (v is List) return v.cast<Map<String, dynamic>>();
    }
  }
  return [];
}

List<AiDraftItem> _normalizeDrafts(String raw) {
  if (raw.isEmpty) return [];
  final text = raw.replaceAll(RegExp(r'```(?:json)?', caseSensitive: false), '').trim();
  Object? parsed;
  for (final guess in [text, _extractBalanced(text) ?? '']) {
    if (guess.isEmpty) continue;
    try {
      parsed = jsonDecode(guess);
      break;
    } catch (_) {}
  }
  return _unwrapItems(parsed).map(_normalizeOne).toList();
}

String _promptFor(String purpose) {
  final priceLabel = purpose == 'purchase' ? '进货单价' : '出货单价';
  return '你是${purpose == 'purchase' ? '进货' : '出货'}记账助手。请从下面这段描述中提取商品清单。'
      '输出严格 JSON，不要 Markdown 代码块，不要额外文字，结构如下：\n'
      '{"client":"购货单位/客户名（描述里提到就填，没有就空字符串）","date":"单据日期 YYYY-MM-DD（描述里提到就填，没有就空字符串）",'
      '"items":[{"name":"商品名称","unit":"单位（斤/公斤/件/包/箱/袋，缺省留空）","quantity":数字,"price":数字（$priceLabel，元）}]}\n'
      '要求：1) 每项一行，数量只填数字（不包含单位）；2) 没提到的字段填 0 或空字符串；'
      '3) 数量/价格是"50斤3元一斤"这种说法时，quantity=50、price=3；4) 多笔用逗号或换行分开；'
      '5) 若描述不是商品清单，输出 {"client":"","date":"","items":[]}。';
}

String _visionPromptFor(String purpose) {
  final priceLabel = purpose == 'purchase' ? '进货单价' : '出货单价';
  final clientLabel = purpose == 'purchase'
      ? '购货单位（单据抬头/供货商名，如单据印"购货单位：一席"就填"一席"；没有就空字符串）'
      : '购货单位（单据上的客户/店铺名，如抬头"购货单位：一席"就填"一席"；没有就空字符串）';
  return '请识别这张图中的单据（如购货单、小票、价签、进货单或白条）。输出严格 JSON，不要 Markdown 代码块，不要额外文字，结构如下：\n'
      '{"client":"$clientLabel","date":"单据日期 YYYY-MM-DD，没有就空字符串","items":['
      '{"name":"商品名称（逐行抄录单据上的商品名，含规格/牌号；模糊看不清也写最接近的名称，禁止省略或留空）",'
      '"unit":"单位（斤/公斤/件/包/箱/袋，若图上有单位就照抄）","quantity":数字,"price":数字（$priceLabel，元）}]}\n'
      '要求：1) 每项一行，商品名称必填不能省略，数量只填数字（不包含单位）；2) 看不清的字段填 0 或空字符串；'
      '3) 若图片不是单据清单，输出 {"client":"","date":"","items":[]}。';
}

/// 文字记账：描述 → 草稿明细
Future<AiInvoice> aiParseText(String text, {String purpose = 'sale'}) async {
  final cfg = await aiLoadConfig();
  final p = _providerFor(cfg, 'textProviderId');
  final raw = await _chatCompletion(p, 'text', [
    {'role': 'user', 'content': '${_promptFor(purpose)}\n\n描述：$text'},
  ]);
  return _normalizeInvoice(raw);
}

/// 拍照识别：图片字节 → 草稿明细（视觉模型）
Future<AiInvoice> aiParsePhoto(Uint8List bytes, String mime, {String purpose = 'sale'}) async {
  final cfg = await aiLoadConfig();
  final p = _providerFor(cfg, 'visionProviderId');
  final b64 = base64Encode(bytes);
  final raw = await _chatCompletion(p, 'vision', [
    {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': _visionPromptFor(purpose)},
        {'type': 'image_url', 'image_url': {'url': 'data:$mime;base64,$b64'}},
      ],
    },
  ]);
  return _normalizeInvoice(raw);
}

/// 语音记账：音频字节 → 语音转文字（智谱 audio 接口）→ 草稿明细
Future<AiInvoice> aiParseVoice(Uint8List bytes, String mime, {String purpose = 'sale'}) async {
  final cfg = await aiLoadConfig();
  final p = _providerFor(cfg, 'speechProviderId');
  final url = '${p.baseUrl.replaceAll(RegExp(r'/+$'), '')}/audio/asr';
  final req = http.MultipartRequest('POST', Uri.parse(url))
    ..headers['Authorization'] = 'Bearer ${p.apiKey.trim()}'
    ..headers['model'] = _modelFor(p, 'speech')
    ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: 'voice.m4a', contentType: http.MediaType.parse(mime)));
  final resp = await req.send().timeout(const Duration(seconds: 60));
  final body = await resp.stream.bytesToString();
  if (resp.statusCode != 200) throw Exception('AI 语音通道 ${resp.statusCode}: ${body.length > 120 ? body.substring(0, 120) : body}');
  // 智谱 asr 返回 {text: "..."}
  final d = jsonDecode(body) as Map<String, dynamic>;
  final text = '${d['text'] ?? ''}'.trim();
  if (text.isEmpty) throw Exception('语音未识别出文字');
  final tp = _providerFor(cfg, 'textProviderId');
  final raw = await _chatCompletion(tp, 'text', [
    {'role': 'user', 'content': '${_promptFor(purpose)}\n\n描述：$text'},
  ]);
  return _normalizeInvoice(raw);
}

AiInvoice _normalizeInvoice(String raw) {
  final drafts = _normalizeDrafts(raw);
  var client = '';
  var date = '';
  // 从原始 JSON 尝试提取 client/date（顶层或 items 首项）
  final text = raw.replaceAll(RegExp(r'```(?:json)?', caseSensitive: false), '').trim();
  Object? parsed;
  for (final guess in [text, _extractBalanced(text) ?? '']) {
    if (guess.isEmpty) continue;
    try {
      parsed = jsonDecode(guess);
      break;
    } catch (_) {}
  }
  final tryPick = (Object? o) {
    if (o is Map) {
      if (client.isEmpty) client = _pick(o, ['client', '购货单位', '供货商', '单位名称', '客户', '单位']).trim();
      if (date.isEmpty) date = _pick(o, ['date', '单据日期', '日期', 'happened_at', 'time']).trim();
    }
  };
  if (parsed is Map) {
    tryPick(parsed);
    final inner = parsed['items'];
    if (inner is List && inner.isNotEmpty) tryPick(inner.first);
  } else if (parsed is List) {
    for (final it in parsed) {
      tryPick(it);
    }
  }
  return AiInvoice(client, date, drafts);
}

/// 单项能力连通测试（本地直连）：文字/视觉/语音
Future<String> aiTestCapability(String cap) async {
  final cfg = await aiLoadConfig();
  if (cap == 'vision') {
    // 内置 1x1 白图测试视觉通道
    final tiny = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');
    final p = _providerFor(cfg, 'visionProviderId');
    final raw = await _chatCompletion(p, 'vision', [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '这是什么？一句话回答'},
          {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,$tiny'}},
        ],
      },
    ]);
    return raw;
  }
  if (cap == 'speech') {
    throw Exception('语音测试需录音，请在记单页实测');
  }
  final p = _providerFor(cfg, 'textProviderId');
  return await _chatCompletion(p, 'text', [
    {'role': 'user', 'content': '回复"OK"两个字'},
  ]);
}
