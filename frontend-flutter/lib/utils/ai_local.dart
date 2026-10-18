/// AI 记账本地直连（用户要求：参考项目 AI 识别是客户端本地直连服务商，不经过服务器代理）。
/// Key/服务商配置本地存储（SharedPreferences），拍照/文字/语音识别直接调服务商 API
/// （OpenAI 兼容 chat/completions；智谱视觉/语音同协议），结果容错解析成商品草稿。
/// 服务器 /ai/parse-* 仅 Web/小程序（平台域名限制）继续使用。
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
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
      textModel: 'glm-4-flash', visionModel: 'glm-4v-flash', audioModel: 'glm-asr-2512',
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

String _modelFor(AiProvider p, String cap) {
  if (cap == 'text') return p.textModel.isNotEmpty ? p.textModel : 'glm-4-flash';
  if (cap == 'vision') return p.visionModel.isNotEmpty ? p.visionModel : 'glm-4v-flash';
  // 语音：智谱 ASR 模型已换代 glm-asr-2512；存量配置里的 glm-4-voice 自动映射（否则接口 500）
  var m = p.audioModel.isNotEmpty ? p.audioModel : 'glm-asr-2512';
  if (m == 'glm-4-voice' && p.baseUrl.contains('open.bigmodel.cn')) m = 'glm-asr-2512';
  return m;
}

/// 直连服务商 chat/completions（OpenAI 兼容；智谱 GLM 同协议）。
/// 自适应参数剥离（对齐服务器 ai-parse 与参考项目）：不同模型对参数约束不同
/// （推理模型锁 temperature、部分模型拒 max_tokens 等）——报错指明哪个参数非法
/// （结构化 error.param 或文案点名）就剥掉该参数重试，最多 3 次。智谱 1210"参数有误"由此兜底。
const _requiredKeys = {'model', 'messages', 'stream'};
const _maxParamStrips = 3;

String? _rejectedParam(Map<String, dynamic> payload, int statusCode, String body) {
  if (statusCode < 400) return null;
  try {
    final parsed = jsonDecode(body);
    if (parsed is Map) {
      final err = parsed['error'];
      if (err is Map) {
        final param = err['param'];
        if (param is String && payload.containsKey(param) && !_requiredKeys.contains(param)) {
          return param;
        }
      }
    }
  } catch (_) {}
  final low = body.toLowerCase();
  for (final k in payload.keys) {
    if (!_requiredKeys.contains(k) && low.contains(k.toLowerCase())) return k;
  }
  return null;
}

Future<String> _chatCompletion(AiProvider p, String cap, List<Map<String, dynamic>> messages) async {
  if (p.apiKey.trim().isEmpty) {
    throw Exception('「${p.name}」未配置 Key，请到 AI 识别设置添加');
  }
  final url = '${p.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';
  final body = <String, dynamic>{
    'model': _modelFor(p, cap),
    'messages': messages,
    // 视觉模型（glm-4v 系）参数面窄：temperature 若被拒由自适应剥离重试（对齐服务器/参考项目）
    'temperature': 0.1,
  };
  for (var i = 0; i <= _maxParamStrips; i++) {
    final resp = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${p.apiKey.trim()}'},
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 60));
    if (resp.statusCode == 200) {
      final d = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final content = (d['choices'] as List?)?[0]?['message']?['content'];
      return '${content ?? ''}'.trim();
    }
    final errBody = utf8.decode(resp.bodyBytes);
    // 诊断：记录直连请求的关键信息（模型/地址/请求体规模/智谱完整响应）——Web 同代码走服务器正常、
    // App 本地直连报错时凭此定位（模型名/图片参数/网络分发等）
    appLog('ai', 'AI 直连失败 [${p.name}/${_modelFor(p, cap)}] ${p.baseUrl} reqBytes=${jsonEncode(body).length}'
        ' → HTTP ${resp.statusCode}: $errBody', level: 'error');
    final brief = 'AI 通道 ${resp.statusCode}（${p.name}/${_modelFor(p, cap)}）:'
        ' ${errBody.length > 600 ? errBody.substring(0, 600) : errBody}';
    if (i == _maxParamStrips) {
      throw Exception(brief);
    }
    final param = _rejectedParam(body, resp.statusCode, errBody);
    if (param == null) {
      throw Exception(brief);
    }
    body.remove(param);
  }
  throw Exception('AI 通道请求失败（已按上游提示剥离参数重试仍失败）');
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
      '3) 单据可能有很多行，请逐行完整抄录、不得遗漏任何一行——特别注意单据底部/纸边缘的最后一行，不要因模糊或裁切省略；'
      '4) 若图片不是单据清单，输出 {"client":"","date":"","items":[]}。';
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

/// 按文件魔数识别真实图片格式（不信调用方 mime，防 HEIC/PNG 标错触发智谱 1210"图片输入格式/解析错误"）。
/// 支持 JPEG/PNG/WEBP/GIF；HEIC（ISO BMFF）识别为不支持返回 null。
String? _sniffImageMime(Uint8List bytes) {
  if (bytes.length < 12) return null;
  if (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) return 'image/jpeg';
  if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4e && bytes[3] == 0x47 &&
      bytes[4] == 0x0d && bytes[5] == 0x0a && bytes[6] == 0x1a && bytes[7] == 0x0a) return 'image/png';
  if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
      bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) return 'image/webp';
  if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) return 'image/gif';
  // HEIC：ISO BMFF（....ftyp + 品牌 heic/heix/hevc/mif1）——无法解析，返回 null 走提示
  if (bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70) return null;
  return null;
}

/// AI 拍照识别前处理：魔数嗅探真实格式 + 压缩重编码 JPEG。
/// 智谱 glm-4v 对图片字节数有上限（实测 ~500KB 内安全，几 MB 直接 1210"图片输入格式/解析错误"），
/// 真实单据照片 2-6MB 必超——统一重编码 JPEG 压到安全线内。
/// 压缩放宽（识别少一行优化）：resize 阈值从 1536 提到 2048——竖长条小票（如 1080×4000）宽度
/// 从 384px 提到 ~512px，底部行字不再过小导致模型漏读最后一行；小图（≤1MB 且边长 ≤2048）
/// 只重编码不缩分辨率，保留细节。质量 82 起步，超智谱安全线逐档降质兜底（仍超 1MB 再降）。
/// HEIC/无法解码抛中文提示。返回 {bytes, mime}：压缩后更小才用 JPEG；否则原字节 + 修正后的真实 mime。
Future<({Uint8List bytes, String mime})> aiPreparePhoto(Uint8List bytes, String fallbackMime) async {
  final real = _sniffImageMime(bytes) ??
      (fallbackMime.startsWith('image/') ? fallbackMime : '');
  if (real.isEmpty) {
    throw Exception('图片格式不支持：请用 JPG/PNG 图片（iPhone 的 HEIC 请先转成 JPG）');
  }
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw Exception('图片无法解析，请换一张（iPhone 的 HEIC 请先转成 JPG）');
    }
    img.Image out = decoded;
    if (decoded.width > 2048 || decoded.height > 2048 || bytes.length > 1024 * 1024) {
      final scale = decoded.width >= decoded.height
          ? 2048 / decoded.width
          : 2048 / decoded.height;
      out = img.copyResize(
        decoded,
        width: (decoded.width * scale).round().clamp(1, 2048),
        height: (decoded.height * scale).round().clamp(1, 2048),
        interpolation: img.Interpolation.linear,
      );
    }
    var jpg = img.encodeJpg(out, quality: 82);
    // 极少数照片重编码后仍超智谱安全线（约 512KB，如高噪点/深色截图）→ 逐档降质量兜底
    if (jpg.length > 512 * 1024) {
      jpg = img.encodeJpg(out, quality: 70);
    }
    if (jpg.length > 1024 * 1024) {
      jpg = img.encodeJpg(out, quality: 55);
    }
    if (jpg.length < bytes.length) {
      return (bytes: Uint8List.fromList(jpg), mime: 'image/jpeg');
    }
    return (bytes: bytes, mime: real);
  } on img.ImageException {
    throw Exception('图片无法解析，请换一张（iPhone 的 HEIC 请先转成 JPG）');
  } catch (_) {
    throw Exception('图片无法解析，请换一张（iPhone 的 HEIC 请先转成 JPG）');
  }
}

/// 拍照识别：图片字节 → 草稿明细（视觉模型）
Future<AiInvoice> aiParsePhoto(Uint8List bytes, String mime, {String purpose = 'sale'}) async {
  try {
    final cfg = await aiLoadConfig();
    final p = _providerFor(cfg, 'visionProviderId');
    appLog('ai', '图片识别开始：${p.name}/${_modelFor(p, 'vision')}（${bytes.length} 字节 $mime）');
    final b64 = base64Encode(bytes);
    // 视觉请求格式对齐参考实现（system 指令 + user 内 text 在前、image_url 在后）：
    // 智谱 glm-4v 对 content 顺序敏感，image_url 在前=1210"图片输入格式/解析错误"（实测全图报错）
    final raw = await _chatCompletion(p, 'vision', [
      {'role': 'system', 'content': _visionPromptFor(purpose)},
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '请识别这张图片中的单据（购货单/小票/价签/进货单）。'},
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

/// 语音转文字端点：智谱官方 ASR 接口为 /audio/transcriptions（模型 glm-asr-2512；
/// 旧路径 /audio/asr 已失效=语音测试 500 根因）；其他 OpenAI 兼容服务商配 /audio/transcriptions
String _speechSttUrl(String baseUrl) {
  final b = baseUrl.replaceAll(RegExp(r'/+$'), '');
  if (b.endsWith('/audio/asr') || b.endsWith('/audio/transcriptions')) return b;
  return '$b/audio/transcriptions';
}

/// 语音记账：音频字节 → 语音转文字 → 草稿明细
Future<AiInvoice> aiParseVoice(Uint8List bytes, String mime, {String purpose = 'sale'}) async {
  try {
    final cfg = await aiLoadConfig();
    final p = _providerFor(cfg, 'speechProviderId');
    appLog('ai', '语音识别开始：${p.name}/${_modelFor(p, 'speech')}（${bytes.length} 字节 $mime）');
    final url = _speechSttUrl(p.baseUrl);
    final req = http.MultipartRequest('POST', Uri.parse(url))
      ..headers['Authorization'] = 'Bearer ${p.apiKey.trim()}'
      ..headers['model'] = _modelFor(p, 'speech')
      // OpenAI 兼容语音接口（硅基流动等）要求 model 在表单字段；智谱读 header——两端都放兼容两家
      ..fields['model'] = _modelFor(p, 'speech')
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
    // 对齐参考实现：完整 data URL 字符串常量直接给 image_url.url（不 base64Decode——
    // Uint8List 字符串插值输出 [102,55,...] 乱码文本，非合法 base64=智谱 1210"图片输入格式/解析错误"根因）
    final tiny =
        '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAUDBAQEAwUEBAQFBQUGBwwIBwcHBw8LCwkMEQ8SEhEPERETFhwXExQaFRERGCEYGh0dHx8fExciJCIeJBweHx7/2wBDAQUFBQcGBw4ICA4eFBEUHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh7/wAARCAIAAgADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD7LooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoor4vr2snyf+0uf3+Xlt0vvfzXY8/HY76py+7e9+ttj7Qor4vor2v8AVD/p9/5L/wDbHB/bn/Tv8f8AgH2hRXxfRR/qh/0+/wDJf/tg/tz/AKd/j/wD7Qor4voo/wBUP+n3/kv/ANsH9uf9O/x/4B9oUV8X0Uf6of8AT7/yX/7YP7c/6d/j/wAA+0KK+L6KP9UP+n3/AJL/APbB/bn/AE7/AB/4B9oUV8X0Uf6of9Pv/Jf/ALYP7c/6d/j/AMA+0KK+L6KP9UP+n3/kv/2wf25/07/H/gH2hRXxfRR/qh/0+/8AJf8A7YP7c/6d/j/wD7Qor4voo/1Q/wCn3/kv/wBsH9uf9O/x/wCAfaFFfF9FH+qH/T7/AMl/+2D+3P8Ap3+P/APtCivi+ij/AFQ/6ff+S/8A2wf25/07/H/gH2hRXxfRR/qh/wBPv/Jf/tg/tz/p3+P/AAD7Qor4voo/1Q/6ff8Akv8A9sH9uf8ATv8AH/gH2hRXxfRR/qh/0+/8l/8Atg/tz/p3+P8AwD7Qor4voo/1Q/6ff+S//bB/bn/Tv8f+AfaFFfF9FH+qH/T7/wAl/wDtg/tz/p3+P/APtCivi+ij/VD/AKff+S//AGwf25/07/H/AIB9oUV8X0Uf6of9Pv8AyX/7YP7c/wCnf4/8A+0KK+L6KP8AVD/p9/5L/wDbB/bn/Tv8f+AfaFFfF9FH+qH/AE+/8l/+2D+3P+nf4/8AAPtCivi+ij/VD/p9/wCS/wD2wf25/wBO/wAf+AfaFFfF9FH+qH/T7/yX/wC2D+3P+nf4/wDAPtCivi+ij/VD/p9/5L/9sH9uf9O/x/4B9oUV8X0Uf6of9Pv/ACX/AO2D+3P+nf4/8A+0KK+L6KP9UP8Ap9/5L/8AbB/bn/Tv8f8AgH2hRXxfRR/qh/0+/wDJf/tg/tz/AKd/j/wD7Qor4vr628B/8iNoH/YMtv8A0UteRm+S/wBnQjLn5rvtb9WduBzD61Jrltbz/wCAbVFFFeEekFFFFABRRRQAUUUUAFfF9faFfF9facIf8vv+3f8A248DPP8Al38/0CiiivtDwAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAK+tvAf/IjaB/2DLb/ANFLXyTX1t4D/wCRG0D/ALBlt/6KWvkeLf4NP1f5Ht5J/El6G1RRRXwp9GFFFFABRRRQAUUUUAFfF9faFfF9facIf8vv+3f/AG48DPP+Xfz/AECiiivtDwAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAK+tvAf8AyI2gf9gy2/8ARS18k19beA/+RG0D/sGW3/opa+R4t/g0/V/ke3kn8SXobVFFFfCn0YUUUUAFFFFABRRRQAV8X19oV8X19pwh/wAvv+3f/bjwM8/5d/P9Aooor7Q8AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACvrbwH/wAiNoH/AGDLb/0UtfJNfW3gP/kRtA/7Blt/6KWvkeLf4NP1f5Ht5J/El6G1RRRXwp9GFFFFABRRRQAUUUUAFfF9faFfF9facIf8vv8At3/248DPP+Xfz/QKKKK+0PACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAr628B/8iNoH/YMtv/RS18k19beA/wDkRtA/7Blt/wCilr5Hi3+DT9X+R7eSfxJehtUUUV8KfRhRRRQAUUUUAFFFFABXxfX2hXxfX2nCH/L7/t3/ANuPAzz/AJd/P9Aooor7Q8AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACvrbwH/yI2gf9gy2/wDRS18k19beA/8AkRtA/wCwZbf+ilr5Hi3+DT9X+R7eSfxJehtUUUV8KfRhRRRQAUUUUAFFFFABXxfX2hXxfX2nCH/L7/t3/wBuPAzz/l38/wBAooor7Q8AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACvrbwH/AMiNoH/YMtv/AEUtfJNfW3gP/kRtA/7Blt/6KWvkeLf4NP1f5Ht5J/El6G1RRRXwp9GFFFFABRRRQAUUUUAFfF9faFfF9facIf8AL7/t3/248DPP+Xfz/QKKKK+0PACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACirem6bfalKYrG2kmYdSOAvXqTwOh611Wk+A5HVJNTu/Kzy0UIyQMf3jwDn2I4618/nHFOU5NdYyslL+Vay8vdV3r3dl5nfg8rxeM/gwbXfZfeziqkt4ZriVYYIpJZG+6iKWJ79BXqtj4Y0O0wVsI5XCbS02Xz74PGeOwFa8aJHGscaKiKAqqowAB0AFfnOP8AGLCwusHhpS85NR/Bc1/vXyPo6HB9V61qiXor/wCR5Ha+H9buZCkemXKkDP7xPLH5tgfhVn/hEfEP/QP/API0f/xVeq0V83V8YM2cv3dGml5qT/HmX5How4PwiXvTk38l+jPKv+ER8Q/9A/8A8jR//FVUuNB1qCVon0u7LL1KRlx+a5Br2CinR8Yc2Uv3tGm15cy/OT/IJ8H4Rr3ZyX3P9EeHyI8cjRyIyOpKsrDBBHUEU2vbriGG4iaGeKOWNvvI6hge/Q1jX/hPQ7ve32T7PI+PngYrjGOi/d7elfTZf4w4Ko0sZh5Q84tSXTXXlffa/wAzzMRwfWjrRqJ+un+f6HlVFdhq3gW7hUyabcLcjJ/dPhHAzxg9D79OlctfWd1Y3Bgu4JIZB2YYyM4yPUcHkcV+j5RxJlecRvg6yk+20l6xdn87WPnMXluKwbtWg159Pv2IKKKK9w4gooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAr628B/8AIjaB/wBgy2/9FLXyTX1t4D/5EbQP+wZbf+ilr5Hi3+DT9X+R7eSfxJehtUUUV8KfRhRRRQAUUUUAFFFFABXxfX2hXxfX2nCH/L7/ALd/9uPAzz/l38/0CiiivtDwAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK1/Dnh+91qRjDtigQgPM+cfQepxzj8yMiuPH4/DZfQliMVNQhHdv+vwNaGHqYioqdJXbM+xs7q+uBBaQSTSHsozgZxk+g5HJ4rt9B8EQJGk+ru0khGTAhwq9eCw5PbpjkdxXTaNpNjpNuYbKHZuxvcnLOQMZJ/oOOTxV6v5+4o8UMbj5SoZa3Sp/zfbfz+z8tfPofoGV8L0aCU8T70u3Rf5/PTyI7eGG3iWGCKOKNfuoihQO/QVJRRX5XKUpycpO7Z9UkkrIKKKKkYUUUUAFFFFABRRRQAVBfWdrfW5gu4I5oz2YZwcYyPQ8nkc1PRV0qs6U1Om2pLZrRr5kyjGacZK6OE8QeCCqtPo7s5z/AMe7kdyfusfTjg+h57VxlxDNbytDPFJFIv3kdSpHfoa9urK8QaDY6zEfPTZcKhWOdeq9+R3HsfU4xnNfrnCvilicLKOHzb36f8/2l6/zL/yb10R8lmvC1OqnUwnuy7dH6dn+HoeRUVoa5o97o9ysF2q4YZSRCSj+uD7en+IrPr98wmLo4yjGvQkpQlqmtmfBVaU6M3CorNdAoooroMwooooAKKKKACiiigAooooAKKKKACiiigAooooAK+tvAf8AyI2gf9gy2/8ARS18k19beA/+RG0D/sGW3/opa+R4t/g0/V/ke3kn8SXobVFFFfCn0YUUUUAFFFFABRRRQAV8X19oV8X19pwh/wAvv+3f/bjwM8/5d/P9Aooor7Q8AKKKKACiiigAooooAKKKKACiiigAooooAKKK1/CuivrWo+SWaOCMbpnA7Z6Dtk+/oTzjFcePx9DL8NPFYiXLCCu3/X4GuHoVMRUVKmrtknhXw/PrVzk7orOM/vZfX/ZX3/l+QPqNnbQWdtHbW0SxQxjCqO3+fWiztoLO2jtraJYoYxhVHb/PrU1fyzxhxhieI8Td+7Rj8Mf1feT/AA2XVv8AU8nyenl1PvN7v9F5fmFFFFfHHsBRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQBU1bT7XU7J7S7j3RtyCOqnswPY15V4g0e60a9ME43RtkxSgcOP6H1Hb8ifYKqatp9rqdk9pdx7o25BHVT2YHsa+64K41r8PV/Z1LyoSfvR7f3o+fdbNedmvCzrJYZhDmjpUWz7+T/AK0PGKKva7pk2k6nJZTHftwUcKQHU9CP5fUEVRr+osLiaWLowr0ZXhJJp909j8vq0p0puE1ZrRhRRRW5AUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAV9beA/+RG0D/sGW3/opa+Sa+tvAf/IjaB/2DLb/ANFLXyPFv8Gn6v8AI9vJP4kvQ2qKKK+FPowooooAKKKKACiiigAr4vr7Qr4vr7ThD/l9/wBu/wDtx4Gef8u/n+gUUUV9oeAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAT6faTX17DaQLmSVwq8HA9zjsOp9q9d0LTIdJ0yOyhO/bku5UAux6k/wAvoAK5n4a6QiWzavPGpkkJWAkZ2qOGI57nI6Z49DXaV/OXihxRLH415bQl+7pP3vOfX/wHb1v5H6LwvlaoUfrM170tvJf8Hf0sFFFFflJ9WFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAZHirRU1rTvJDLHPGd0Lkd8dD3wfb0B5xivJpEeORo5EZHUlWVhggjqCK9wrz34k6Qltcx6nbxqkc52zADH7zrnr3Geg7Z6mv2Twq4olQr/2TXl7s9YeUt2v+3unntufG8VZWp0/rdNar4vNdH8vy9Dj6KKK/fz4EKKKKACiiigAooooAKKKKACiiigAooooAK+tvAf/ACI2gf8AYMtv/RS18k19beA/+RG0D/sGW3/opa+R4t/g0/V/ke3kn8SXobVFFFfCn0YUUUUAFFFFABRRRQAV8X19oV8X19pwh/y+/wC3f/bjwM8/5d/P9Aooor7Q8AKKKKACiiigAooooAKKKKACiiigAq3pFjJqWpwWMRw0r4J/ujqT2zgAnFVK7X4Yaery3OpyR58v91ExwQCeW9wcY59GNfP8U5x/Y2U1sYn7yVo/4npHTrq7vyTO/K8H9cxcKPRvX0W53NvDHb28cEK7Y40CIM5wAMAVJRRX8fSlKcnKTu2fsCSSsgoooqRhRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABVTV7GPUtMnsZThZUwD/dPUHtnBAOKt0VrQr1MPVjWpO0otNPs1qn95FSEakXCSunozxG4hkt7iSCZdskblHGc4IOCKjrp/iNp62mtLdRR7Y7pNxxjG8cNgD/AICeepJrmK/snI80hm2X0cbD7aT9Hs18ndH45jsK8JiJ0X0f4dPwCiiivVOUKKKKACiiigAooooAKKKKACiiigAr628B/wDIjaB/2DLb/wBFLXyTX1t4D/5EbQP+wZbf+ilr5Hi3+DT9X+R7eSfxJehtUUUV8KfRhRRRQAUUUUAFFFFABXxfX2hXxfX2nCH/AC+/7d/9uPAzz/l38/0CiiivtDwAooooAKKKKACiiigAooooAKKKKACvWfBVp9k8NWalYw8ieaxUddxyM++CB+FeVW8MlxcRwQrukkcIgzjJJwBXtkaJHGscaKiKAqqowAB0AFfjPjFj+TC4fBp/FJyf/bqsvv5n93kfZcH0L1alZ9El9/8Aww6iiivwI++CiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooA5j4k2nn+HxcBY91vKrFiOdp+UgfiV/KvNK9l1y2N5o15bLEsryQsEVsctj5evHXHNeNV/RfhFj/bZVVwzetOf4SV1+KkfnXF2H5MVGqvtL8V/wLBRRRX6wfKBRRRQAUUUUAFFFFABRRRQAUUUUAFfW3gP/AJEbQP8AsGW3/opa+Sa+tvAf/IjaB/2DLb/0UtfI8W/wafq/yPbyT+JL0NqiiivhT6MKKKKACiiigAooooAK+L6+0K+L6+04Q/5ff9u/+3HgZ5/y7+f6BRRRX2h4AUUUUAFFFFABRRRQAUUUUAFFFFAGp4Uge58SWEaFQRMsnzei/Mf0Br16vKvAX/I2WX/bT/0W1eq1/OvjBVk82o0+ipp/fKV/yR+h8IQSwk5dXL8kv8wooor8mPrQooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACvE7yB7W8mtZCpeGRo2K9CQcHFe2V434h/5D+o/wDX1L/6Ga/aPBurJYnFU+jjF/c3b82fF8YwTp0pdU3+Nv8AIo0UUV+9nwYUUUUAFFFFABRRRQAUUUUAFFFFABX1t4D/AORG0D/sGW3/AKKWvkmvrbwH/wAiNoH/AGDLb/0UtfI8W/wafq/yPbyT+JL0NqiiivhT6MKKKKACiiigAooooAK+L6+0K+L6+04Q/wCX3/bv/tx4Gef8u/n+gUUUV9oeAFFFFABRRRQAUUUUAFFFFABRRRQBu+Av+Rssv+2n/otq9Vrx/wALzSQeItPeJtrG4RCcZ4Y7SPyJr2Cv528YaMlm1Gr0dO33Sk/1R+h8HzTwk49pfml/kFFFFfkp9aFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAV434h/5D+o/9fUv/oZr2SvEbiaS4uJJ5m3SSOXc4xkk5Jr9p8G6MniMVV6JRX3tv9GfF8ZTSp0o92/wt/mR0UUV+9HwYUUUUAFFFFABRRRQAUUUUAFFFFABX1t4D/5EbQP+wZbf+ilr5Jr628B/8iNoH/YMtv8A0UtfI8W/wafq/wAj28k/iS9Daooor4U+jCiiigAooooAKKKKACvi+vtCvi+vtOEP+X3/AG7/AO3HgZ5/y7+f6BRRRX2h4AUUUUAFFFFABRRRQAUUUUAFFFFADo3eORZI3ZHUhlZTggjoQa9st5o7i3jnhbdHIgdDjGQRkGvEa9V8C3f2vw1bbpN8kOYX+XGMH5R/3yVr8d8YcvdTBYfGJfBJxfpJX107xtv18z7Dg/EctapRfVX+7/h/wN2iiiv5+P0AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigDP8SXItNBvpzK0RELBHXOQxGFxjpyRzXjtej/Ey78nRYrRZNr3Eoyu3O5F5PPbnb/nNecV/R/hJl7oZRPEyWtSbt6R07d+buvnc/OOLcR7TGRpr7K/F6/lYKKKK/VD5YKKKKACiiigAooooAKKKKACiiigAr628B/8iNoH/YMtv/RS18k19beA/wDkRtA/7Blt/wCilr5Hi3+DT9X+R7eSfxJehtUUUV8KfRhRRRQAUUUUAFFFFABXxfX2hXxfX2nCH/L7/t3/ANuPAzz/AJd/P9Aooor7Q8AKKKKACiiigAooooAKKKKACiiigArsPhlqIhv5tNkZsXA3xcnAZQcjHuO/+yK4+p9Pu5rG9hu4GxJE4ZeTg+xx2PQ+1eJxJlEc4yutg3vJaeUlrH8Ur+R25bi3g8VCsuj19Ov4HtdFQafdw31lDdwNmOVAy8jI9jjuOh96nr+OqtKdKbpzVpJ2a7Nbn7DGSnFSi7phRRRUFBRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRWf4h1JNK0ie8baXUbYlP8TnoMZGfU47A10YTC1cXXhh6KvKTSS83oZ1asaMHUm7JK7PP/iBqIvteeKNmMVqPKHJwWz8xx25499ornadI7ySNJI7O7EszMckk9STTa/snJ8tp5XgaWDp7QSXq+r+buz8bxmJliq860t5O4UUUV6RzhRRRQAUUUUAFFFFABRRRQAUUUUAFfW3gP/kRtA/7Blt/6KWvkmvrbwH/AMiNoH/YMtv/AEUtfI8W/wAGn6v8j28k/iS9Daooor4U+jCiiigAooooAKKKKACvi+vtCvi+vtOEP+X3/bv/ALceBnn/AC7+f6BRRRX2h4AUUUUAFFFFABRRRQAUUUUAFFFFABRRRQB2/wANdYCs2jzs2WJe34J7ZZfbpkf8C9RXd14jbzSW9xHPC22SNw6HGcEHINes+F9Yj1nTFnzGtwnyzxqfunseex6j8snBr+e/FLhWWFxP9rYeP7ufx+Uu/pL/ANK66pH6Dwtmqq0/qlR+9HbzXb1X5ehq0UUV+QH14UUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAV5t8Q9YF9qIsIGbyLUkPwRukzg/XHQHH97sa6nxpr39j2QjtnjN7NwgPJRecvj9Bnv64Iry2v23wq4Vk5/2xiY6LSn59HL5bL59kfE8VZqlH6nTev2v0X6v5BRRRX7sfChRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABX1t4D/wCRG0D/ALBlt/6KWvkmvrbwH/yI2gf9gy2/9FLXyPFv8Gn6v8j28k/iS9Daooor4U+jCiiigAooooAKKKKACvi+vtCvi+vtOEP+X3/bv/tx4Gef8u/n+gUUUV9oeAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFaHh/VZ9H1FbuBVcY2SI38akjIz26Dn2/Cs+iufF4SjjKMqFePNCSs0+qNKVWdGaqQdmtj2fSdQtdTsku7STdG3BB6qe6kdjVuvH/D+sXWjXongO6NsCWInhx/Q+h7fmD6rpOoWup2SXdpJujbgg9VPdSOxr+XuNeCq/D1f2lO8qEn7su392Xn2ezXndL9PyXOoZhDllpUW67+a/rQt0UUV8Ke6FFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABWb4g1i10ayM853SNkRRA8uf6D1Pb8gTxBrFro1kZ5zukbIiiB5c/0Hqe35A+VatqF1qd693dybpG4AHRR2UDsK/ReBeBqmfVVicSnHDxfzm10Xl3fyWu3zmeZ5HAR9lS1qP8ADzf6L+m3U72fUb+W9uSpllOTtGAOMAD6AAVWoor+mqNGnQpxpU1aMUkktklokvQ/NJzlOTlJ3bCiiitCQooooAKKKKACiiigAooooAKKKKACiiigAr628B/8iNoH/YMtv/RS18k19beA/wDkRtA/7Blt/wCilr5Hi3+DT9X+R7eSfxJehtUUUV8KfRhRRRQAUUUUAFFFFABXxfX2hXxfX2nCH/L7/t3/ANuPAzz/AJd/P9Aooor7Q8AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACr2jatfaTcGaym2bsb0IyrgHOCP6jnk81RorDE4Wji6UqNeClB7pq6fyLpVZ0pqcHZrqj1vw54gstajYQ7op0ALwvjP1HqM8Z/MDIrXrw+N3jkWSN2R1IZWU4II6EGuu0HxvPbRpb6nE1xGowJkP7zv1zw3YZ4/E1+D8UeFVehKVfKffj/I/iXo38Xpv01Pu8r4qpzSp4vR/zdH6rp+XoehUVU03UrHUojLY3McyjqBwV69QeR0PWrdfkFehVw9R0q0XGS3TVmvVPU+vhUjUipQd0+qCiiisiwooooAKKKKACiiigAoorP1jWdO0qPdeXCq+MrEvLt1xgfgRk4HvXRhcJXxdVUcPByk9kld/gZ1asKMXOo0kurNCuf8AFHie10fdbRjz70pkIPuoe24/rgc/TINct4g8ZXt8rQWCtZwZ++GPmtgnuPu544Hp1xXLV+y8K+FU3KOJzjRf8+11/wATW3ovvWx8bmvFUUnTwe/83+S/V/cWdSvrvUbk3N7O00pAXJAGAOwA4FVqKK/cqNGnQpqnSioxWiSVkl2SWx8POcpycpO7YUUUVoSFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABX1t4D/5EbQP+wZbf+ilr5Jr628B/wDIjaB/2DLb/wBFLXyPFv8ABp+r/I9vJP4kvQ2qKKK+FPowooooAKKKKACiiigAr4vr7Qr4vr7ThD/l9/27/wC3HgZ5/wAu/n+gUUUV9oeAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUASW801vKs0EskUi/ddGKkduoro9J8a6paKkV0sd7Gvd/lkxjAG4fnkgk881zFFeVmmR5fm0OTG0VP1Wq9GtV8mdWFx2IwjvRm1+X3bHpdj430efAuBPatsyxZNy59AVyT9cDpW1Z6rpl40a21/bSvIMqgkG88Z+716dq8aor88x/hFlVa7w1WdN/KS/Gz/wDJj6GhxdioaVYqX4P/AC/A9yorxO1ubm1kMlrcSwORtLRuVJHpkVY/tnV/+grff+BD/wCNfOVfBvEqX7vFRa84tfhd/mejDjGm171Jp+t/0R7JRXjf9s6v/wBBW+/8CH/xqrcTTXErTTyySyN953YsT26mnR8GsQ5fvcUkvKLf5tfmE+MqaXu0m/nb9GevXmt6RaLIZ9RtlMZ2ugcM4OcY2jJ/SsS/8c6XDvW0hnunGNpxsRumeTyPy7fjXnFFfTZf4SZRQaliZzqPtflXTtr/AOTbPvqeZiOLcZU0pxUfxf46fgdFq3jDV75THE62cRJ4hyHIzkZbrxjtjPNc/I7ySNJI7O7EszMckk9STTaK/QstyfA5XT9ng6SgvJav1e7+bPnsTjK+KlzVpuT8wooor0jnCiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACvrbwH/yI2gf9gy2/wDRS18k19beA/8AkRtA/wCwZbf+ilr5Hi3+DT9X+R7eSfxJehtUUUV8KfRhRRRQAUUUUAFFFFABXxfX2hXxfX2nCH/L7/t3/wBuPAzz/l38/wBAooor7Q8AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACvrbwH/AMiNoH/YMtv/AEUtfJNfW3gP/kRtA/7Blt/6KWvkeLf4NP1f5Ht5J/El6G1RRRXwp9GFFFFABRRRQAUUUUAFfF9faFfF9facIf8AL7/t3/248DPP+Xfz/QKKKK+0PACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAr628B/8AIjaB/wBgy2/9FLXyTX1t4D/5EbQP+wZbf+ilr5Hi3+DT9X+R7eSfxJehtUUUV8KfRhRRRQAUUUUAFFFFABXxfX2hXxfX2nCH/L7/ALd/9uPAzz/l38/0CiiivtDwAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAK+tvAf/IjaB/2DLb/0UtfJNfW3gP8A5EbQP+wZbf8Aopa+R4t/g0/V/ke3kn8SXobVFFFfCn0YUUUUAFFFFABRRRQAV8X19oV8X19pwh/y+/7d/wDbjwM8/wCXfz/QKKKK+0PACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAr628B/8iNoH/YMtv8A0UtfJNfW3gP/AJEbQP8AsGW3/opa+R4t/g0/V/ke3kn8SXobVFFFfCn0YUUUUAFFFFABRRRQAV8X19oV8X19pwh/y+/7d/8AbjwM8/5d/P8AQKKKK+0PACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAr628B/wDIjaB/2DLb/wBFLXyTX1t4D/5EbQP+wZbf+ilr5Hi3+DT9X+R7eSfxJehtUUUV8KfRhRRRQAUUUUAFFFFABXxfX2hXxfX2nCH/AC+/7d/9uPAzz/l38/0CiiivtDwAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAK+tvAf/ACI2gf8AYMtv/RS18k19beA/+RG0D/sGW3/opa+R4t/g0/V/ke3kn8SXobVFFFfCn0YUUUUAFFFFABRRRQAV8X19oVi/8Il4V/6FnRf/AAAi/wDia93JM3hl3PzRb5rfhf8AzPNzDAyxXLZ2tf8AQ+SaK+tv+ES8K/8AQs6L/wCAEX/xNH/CJeFf+hZ0X/wAi/8Aia97/W2j/wA+396PO/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jor62/4RLwr/wBCzov/AIARf/E0f8Il4V/6FnRf/ACL/wCJo/1to/8APt/eg/sSp/Mj5Jr628B/8iNoH/YMtv8A0UtH/CJeFf8AoWdF/wDACL/4mte3hit4I4IIkihjUJHGihVRQMAADgADtXi51nMMwhGMYtWZ34DASwsm273H0UUV88eoFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQB//9k=';
    final p = _providerFor(cfg, 'visionProviderId');
    if (p.apiKey.trim().isEmpty) throw Exception('「${p.name}」未配置 Key，无法测试');
    final raw = await _chatCompletion(p, 'vision', [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '这是什么？一句话回答'},
          {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,$tiny'}},
        ],
      },
    ]);
    return raw;
  }
  if (cap == 'speech') {
    // 真实语音测试：生成 0.25s 静音 WAV 真发服务商 stt（Key 无效/通道错误如实报，不假通过）
    final p = _providerFor(cfg, 'speechProviderId');
    if (p.apiKey.trim().isEmpty) throw Exception('「${p.name}」未配置 Key，无法测试语音');
    final url = _speechSttUrl(p.baseUrl);
    final req = http.MultipartRequest('POST', Uri.parse(url))
      ..headers['Authorization'] = 'Bearer ${p.apiKey.trim()}'
      ..headers['model'] = _modelFor(p, 'speech')
      // OpenAI 兼容语音接口（硅基流动等）要求 model 在表单字段；智谱读 header——两端都放兼容两家
      ..fields['model'] = _modelFor(p, 'speech')
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

/// 0.5s 8000Hz 16bit 单声道 440Hz 正弦音 WAV（语音测试素材，真实请求服务商）。
/// 不用纯静音：部分 ASR 对无内容音频会报错/返回空，有内容音调更接近真实请求、结果可预期。
Uint8List _silenceWav() {
  const sr = 8000;
  final n = sr ~/ 2; // 0.5 秒
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
  for (var i = 0; i < n; i++) {
    final v = (32767 * 0.4 * (i * 2 * 3.141592653589793 * 440 / sr).sin()).round();
    dv.setInt16(44 + i * 2, v, Endian.little);
  }
  return b;
}
