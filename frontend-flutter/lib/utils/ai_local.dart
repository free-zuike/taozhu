/// AI 记账本地直连（用户要求：参考项目 AI 识别是客户端本地直连服务商，不经过服务器代理）。
/// Key/服务商配置本地存储（SharedPreferences），拍照/文字/语音识别直接调服务商 API
/// （OpenAI 兼容 chat/completions；智谱视觉/语音同协议），结果容错解析成商品草稿。
/// 服务器 /ai/parse-* 仅 Web/小程序（平台域名限制）继续使用。
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../log.dart';

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
  try {
    final cfg = await aiLoadConfig();
    final p = _providerFor(cfg, 'textProviderId');
    appLog('ai', '文字记账识别开始：${p.name}/${_modelFor(p, 'text')}（${text.length} 字）');
    final raw = await _chatCompletion(p, 'text', [
      {'role': 'user', 'content': '${_promptFor(purpose)}\n\n描述：$text'},
    ]);
    final inv = _normalizeInvoice(raw);
    appLog('ai', '文字记账识别完成：${inv.items.length} 项、店铺「${inv.client}」');
    return inv;
  } catch (e) {
    appLog('ai', '文字记账识别失败：${e.toString().split('\n').first}', level: 'error');
    rethrow;
  }
}

/// 拍照识别：图片字节 → 草稿明细（视觉模型）
Future<AiInvoice> aiParsePhoto(Uint8List bytes, String mime, {String purpose = 'sale'}) async {
  try {
    final cfg = await aiLoadConfig();
    final p = _providerFor(cfg, 'visionProviderId');
    appLog('ai', '图片识别开始：${p.name}/${_modelFor(p, 'vision')}（${bytes.length} 字节 $mime）');
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
    final inv = _normalizeInvoice(raw);
    appLog('ai', '图片识别完成：${inv.items.length} 项、店铺「${inv.client}」');
    return inv;
  } catch (e) {
    appLog('ai', '图片识别失败：${e.toString().split('\n').first}', level: 'error');
    rethrow;
  }
}

/// 语音记账：音频字节 → 语音转文字（智谱 audio 接口）→ 草稿明细
Future<AiInvoice> aiParseVoice(Uint8List bytes, String mime, {String purpose = 'sale'}) async {
  try {
    final cfg = await aiLoadConfig();
    final p = _providerFor(cfg, 'speechProviderId');
    appLog('ai', '语音识别开始：${p.name}/${_modelFor(p, 'speech')}（${bytes.length} 字节 $mime）');
    final url = '${p.baseUrl.replaceAll(RegExp(r'/+$'), '')}/audio/asr';
    final req = http.MultipartRequest('POST', Uri.parse(url))
      ..headers['Authorization'] = 'Bearer ${p.apiKey.trim()}'
      ..headers['model'] = _modelFor(p, 'speech')
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: 'voice.m4a', contentType: http.MediaType.parse(mime)));
    final resp = await req.send().timeout(const Duration(seconds: 60));
    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200) {
      final err = 'AI 语音通道 ${resp.statusCode}: ${body.length > 120 ? body.substring(0, 120) : body}';
      appLog('ai', '语音转文字失败：$err', level: 'error');
      throw Exception(err);
    }
    final d = jsonDecode(body) as Map<String, dynamic>;
    final text = '${d['text'] ?? ''}'.trim();
    if (text.isEmpty) throw Exception('语音未识别出文字');
    final tp = _providerFor(cfg, 'textProviderId');
    final raw = await _chatCompletion(tp, 'text', [
      {'role': 'user', 'content': '${_promptFor(purpose)}\n\n描述：$text'},
    ]);
    final inv = _normalizeInvoice(raw);
    appLog('ai', '语音识别完成：转文字 ${text.length} 字、${inv.items.length} 项');
    return inv;
  } catch (e) {
    appLog('ai', '语音识别失败：${e.toString().split('\n').first}', level: 'error');
    rethrow;
  }
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
      final m = Map<String, dynamic>.from(o);
      if (client.isEmpty) client = _pick(m, ['client', '购货单位', '供货商', '单位名称', '客户', '单位']).trim();
      if (date.isEmpty) date = _pick(m, ['date', '单据日期', '日期', 'happened_at', 'time']).trim();
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

/// 单项能力连通测试（本地直连）：文字/视觉/语音都真实调用服务商，有问题如实报
Future<String> aiTestCapability(String cap) async {
  final cfg = await aiLoadConfig();
  if (cap == 'vision') {
    // 512x512 带内容 JPEG 测试视觉通道（PNG 被部分服务商 1210 拒；JPEG 兼容最好）
    final tiny = base64Decode(
        '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAUDBAQEAwUEBAQFBQUGBwwIBwcHBw8LCwkMEQ8SEhEPERETFhwXExQaFRERGCEYGh0dHx8fExciJCIeJBweHx7/2wBDAQUFBQcGBw4ICA4eFBEUHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh7/wAARCAIAAgADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD7LooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiig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');
    final p = _providerFor(cfg, 'visionProviderId');
    if (p.apiKey.trim().isEmpty) throw Exception('「${p.name}」未配置 Key，无法测试');
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
    // 真实语音测试：生成 0.25s 静音 WAV 真发服务商 asr（Key 无效/通道错误如实报，不假通过）
    final p = _providerFor(cfg, 'speechProviderId');
    if (p.apiKey.trim().isEmpty) throw Exception('「${p.name}」未配置 Key，无法测试语音');
    final url = '${p.baseUrl.replaceAll(RegExp(r'/+$'), '')}/audio/asr';
    final req = http.MultipartRequest('POST', Uri.parse(url))
      ..headers['Authorization'] = 'Bearer ${p.apiKey.trim()}'
      ..headers['model'] = _modelFor(p, 'speech')
      ..files.add(http.MultipartFile.fromBytes('file', _silenceWav(), filename: 'test.wav',
          contentType: http.MediaType.parse('audio/wav')));
    final resp = await req.send().timeout(const Duration(seconds: 60));
    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200) {
      throw Exception('AI 语音通道 ${resp.statusCode}: ${body.length > 120 ? body.substring(0, 120) : body}');
    }
    return '语音转文字通道连通（已真实发送测试音频）';
  }
  final p = _providerFor(cfg, 'textProviderId');
  if (p.apiKey.trim().isEmpty) throw Exception('「${p.name}」未配置 Key，无法测试');
  return await _chatCompletion(p, 'text', [
    {'role': 'user', 'content': '回复"OK"两个字'},
  ]);
}

/// 0.25s 8000Hz 16bit 单声道静音 WAV（语音测试素材，真实请求服务商）
Uint8List _silenceWav() {
  const sr = 8000;
  final n = (sr * 0.25).round();
  final dataLen = n * 2;
  final b = Uint8List(44 + dataLen);
  final dv = ByteData.view(b.buffer);
  dv.setUint32(0, 0x52494646, Endian.little); // RIFF
  dv.setUint32(4, 36 + dataLen, Endian.little);
  dv.setUint32(8, 0x57415645, Endian.little); // WAVE
  dv.setUint32(12, 0x666d7420, Endian.little); // fmt
  dv.setUint32(16, 16, Endian.little);
  dv.setUint16(20, 1, Endian.little); // PCM
  dv.setUint16(22, 1, Endian.little); // mono
  dv.setUint32(24, sr, Endian.little);
  dv.setUint32(28, sr * 2, Endian.little);
  dv.setUint16(32, 2, Endian.little);
  dv.setUint16(34, 16, Endian.little);
  dv.setUint32(36, 0x64617461, Endian.little); // data
  dv.setUint32(40, dataLen, Endian.little);
  return b;
}
