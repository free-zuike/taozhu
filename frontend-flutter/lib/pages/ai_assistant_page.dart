import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api.dart';
import '../theme.dart';
import '../utils/ai_local.dart' show aiPreparePhoto;
import '../widgets/ai_md_text.dart';
import 'router.dart';

/// AI 助手（对话问数）：聊天气泡 + 快捷提问，多轮历史本地持久化
/// （SharedPreferences，重启保留）；调用 POST /ai/chat（业务数据快照注入，需在线）。
class AiAssistantPage extends StatefulWidget {
  const AiAssistantPage({super.key});
  @override
  State<AiAssistantPage> createState() => _AiAssistantPageState();
}

class _AiAssistantPageState extends State<AiAssistantPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  static const _histKey = 'ai_assistant_history';
  final List<Map<String, String>> _messages = []; // {role: user|assistant, content, sources?, toolsJson?, order?, typing?}
  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();
  bool _thinking = false;
  // 打字机：最新一条助手回复逐字显示（对齐参考 App typewriter_text）
  Timer? _typingTimer;
  int _typingMsgIdx = -1;
  int _typingIndex = 0;

  static const _quickQs = [
    '今天卖了多少？',
    '本月毛利多少？',
    '哪个店欠款最多？',
    '哪些货快卖完了？',
    '有什么快过期？',
    '怎么记一笔账？',
  ];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    // 本地缓存先渲染（秒开/离线）；在线时拉服务端历史覆盖（跨设备续聊，服务端为权威）
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_histKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        _messages.addAll(list
            .map((e) => (e as Map).cast<String, String>())
            .where((m) => m['role'] == 'user' || m['role'] == 'assistant'));
      }
    } catch (_) {}
    if (_messages.isEmpty) {
      _messages.add({'role': 'assistant', 'content': _welcome()});
    }
    _saveHistory();
    if (mounted) _scrollToBottom();
    // 在线拉服务端历史（覆盖本地，跨设备续聊）
    if (!kIsWeb && Api.isOffline) return;
    try {
      final d = await Api.instance.get('/ai/chat/history');
      final msgs = ((d['messages'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (msgs.isNotEmpty && mounted) {
        setState(() {
          _messages
            ..clear()
            ..addAll(msgs
                .map((m) => ({
                      'role': '${m['role'] ?? ''}',
                      'content': '${m['content'] ?? ''}',
                    }))
                .where((m) => m['role'] == 'user' || m['role'] == 'assistant'));
        });
        _saveHistory();
        _scrollToBottom();
      }
    } catch (_) {}
  }

  static String _welcome() =>
      '你好，我是 AI 助手。可以问我经营数据，比如：今天卖了多少？哪个店欠款多？哪些货该补了？也可以说「记住：…」让我帮你记下重要事项，或问功能怎么用。';

  Future<void> _saveHistory() async {
    try {
      final p = await SharedPreferences.getInstance();
      final list = _messages.length > 60
          ? _messages.sublist(_messages.length - 60)
          : _messages;
      // 打字机进度字段不持久化（历史恢复后整条显示）
      final clean = list.map((m) => Map<String, String>.from(m)..remove('typing')).toList();
      await p.setString(_histKey, jsonEncode(clean));
    } catch (_) {}
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _thinking) return;
    if (!kIsWeb && Api.isOffline) {
      toast(context, 'AI 助手需联网（当前离线，联网后再问）');
      return;
    }
    _input.clear();
    setState(() {
      _messages.add({'role': 'user', 'content': text});
      _thinking = true;
    });
    _saveHistory();
    _scrollToBottom();
    try {
      final d = await Api.instance.post('/ai/chat', {
        'messages': _messages.map((m) => {'role': m['role'], 'content': m['content']}).toList(),
      });
      // 写操作（落单/记忆）待授权：弹窗确认 → 调 approve，通过后连同结果一起落库
      if (d['need_approval'] == true) {
        setState(() => _thinking = false);
        final decision = await _showApprovalDialog(d);
        if (decision == null || !mounted) return;
        try {
          final r = await Api.instance.post('/ai/chat/approve', {
            'approval_id': d['approval_id'],
            'decision': decision,
            'messages': _messages.map((m) => {'role': m['role'], 'content': m['content']}).toList(),
          });
          setState(() => _thinking = false);
          _applyReply(r);
          if (decision == 'always_allow') toast(context, '已设为总是允许（「我的 → AI 助手 → 工具权限」可改回）');
          if (decision == 'always_deny') toast(context, '已设为总是拒绝（「我的 → AI 助手 → 工具权限」可改回）');
        } catch (e) {
          setState(() => _thinking = false);
          toast(context, e.toString().replaceFirst('Exception: ', ''));
        }
      } else {
        setState(() => _thinking = false);
        _applyReply(d);
      }
    } catch (e) {
      setState(() => _thinking = false);
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _applyReply(Map<dynamic, dynamic> d) {
    final reply = '${d['reply'] ?? ''}'.trim();
    final sources = ((d['sources'] as List?) ?? []).cast<String>();
    final tools = ((d['tools'] as List?) ?? []).cast<Map<String, dynamic>>();
    final order = d['order'] as Map<String, dynamic>?;
    final msg = {
      'role': 'assistant',
      'content': reply.isNotEmpty ? reply : '（模型没有返回内容，请稍后再试）',
      if (sources.isNotEmpty) 'sources': sources.join('、'),
      if (tools.isNotEmpty) 'toolsJson': jsonEncode(tools),
      if (order != null) 'order': jsonEncode(order),
    };
    setState(() {
      _thinking = false;
      _messages.add(msg);
      if (reply.isNotEmpty && reply.length > 24) _startTyping(_messages.length - 1, reply);
    });
    _saveHistory();
    _scrollToBottom();
  }

  /// 打字机：逐字显示最新一条助手回复（对齐参考 App typewriter_text）
  void _startTyping(int idx, String full) {
    _typingTimer?.cancel();
    _typingMsgIdx = idx;
    _typingIndex = 0;
    _typingTimer = Timer.periodic(const Duration(milliseconds: 24), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      _typingIndex += 2;
      setState(() {});
      if (_typingIndex >= full.length) {
        t.cancel();
        _typingTimer = null;
        _typingMsgIdx = -1;
      }
    });
  }

  /// 写工具授权弹窗：允许/拒绝/总是允许/总是拒绝（对齐参考 App 授权门）
  Future<String?> _showApprovalDialog(Map<dynamic, dynamic> d) async {
    final tool = (d['tool'] as Map<String, dynamic>?) ?? {};
    final preview = '${d['preview'] ?? ''}';
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('允许「${tool['label'] ?? 'AI 操作'}」？', style: const TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(preview, style: const TextStyle(fontSize: 13.5, height: 1.5)),
            if ('${tool['description'] ?? ''}'.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('${tool['description']}', style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'deny'), child: const Text('拒绝', style: TextStyle(fontSize: 13))),
          TextButton(onPressed: () => Navigator.pop(ctx, 'always_deny'), child: const Text('总是拒绝', style: TextStyle(fontSize: 13))),
          TextButton(onPressed: () => Navigator.pop(ctx, 'always_allow'), child: const Text('总是允许', style: TextStyle(fontSize: 13))),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'allow'), child: const Text('允许', style: TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  /// 语音提问：录音 → 后端 /ai/stt 转文字 → 填入输入框发送
  Future<void> _voiceAsk() async {
    if (!kIsWeb && Api.isOffline) {
      toast(context, '语音识别需联网');
      return;
    }
    final perm = await Permission.microphone.request();
    if (!perm.isGranted) {
      toast(context, '需要麦克风权限才能语音提问');
      return;
    }
    final rec = AudioRecorder();
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/taozhu_ai_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await rec.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    if (!mounted) {
      await rec.stop();
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('语音提问', style: TextStyle(fontSize: 16)),
        content: const Text('正在录音，说完点击「结束」', style: TextStyle(fontSize: 13.5)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('结束', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
    await rec.stop();
    final bytes = await XFile(path).readAsBytes();
    toast(context, '识别中…');
    try {
      final d = await Api.instance.uploadAudio('/ai/stt', bytes, 'voice.m4a', 'audio/mp4');
      final text = '${d['text'] ?? ''}'.trim();
      if (text.isEmpty) {
        toast(context, '没有听清，请再说一遍');
        return;
      }
      _input.text = text;
      setState(() {});
      _send();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 拍小票识别记账：拍照/相册 → /ai/parse-photo → 生成记账消息发送（走落单授权门）
  Future<void> _photoAsk() async {
    if (!kIsWeb && Api.isOffline) {
      toast(context, 'AI 识别需联网');
      return;
    }
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('拍照', style: TextStyle(fontSize: 14)), onTap: () => Navigator.pop(ctx, ImageSource.camera)),
            ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('从相册选', style: TextStyle(fontSize: 14)), onTap: () => Navigator.pop(ctx, ImageSource.gallery)),
          ],
        ),
      ),
    );
    if (source == null) return;
    final picked = await ImagePicker().pickImage(source: source);
    if (picked == null) return;
    toast(context, '识别中…');
    try {
      final bytes = await picked.readAsBytes();
      final prep = await aiPreparePhoto(bytes, 'image/jpeg');
      final d = await Api.instance.uploadPhoto('/ai/parse-photo?purpose=purchase', prep.bytes, 'photo.jpg', prep.mime);
      final items = ((d['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (items.isEmpty) {
        toast(context, '没识别到商品，请拍清楚些（可拍进货小票）');
        return;
      }
      final client = '${d['client'] ?? ''}';
      final date = '${d['date'] ?? ''}';
      final summary = items
          .map((i) => '${i['name'] ?? ''} ${i['quantity'] ?? ''}${i['unit'] ?? ''}@¥${i['price'] ?? ''}')
          .join('、');
      final msg = '识别到进货小票：$summary。${client.isNotEmpty ? '购货单位 $client。' : ''}${date.isNotEmpty ? '日期 $date。' : ''}请帮我记一笔进货';
      _send(msg);
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 记忆管理弹层（对齐参考 App「本地记忆」：查看/删除/清空）
  Future<void> _manageMemories() async {
    if (!kIsWeb && Api.isOffline) {
      toast(context, '查看记忆需联网');
      return;
    }
    try {
      final d = await Api.instance.get('/ai/memories');
      final memories = ((d['memories'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('我的记忆', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 420,
            height: 360,
            child: memories.isEmpty
                ? const Center(child: Text('还没有记忆。跟助手说「记住：…」就能记下重要事项。', style: TextStyle(fontSize: 13)))
                : ListView.separated(
                    itemCount: memories.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final m = memories[i];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${m['content'] ?? ''}',
                            style: const TextStyle(fontSize: 13.5)),
                        subtitle: Text('${m['created_at'] ?? ''}'.isEmpty
                            ? ''
                            : '${m['created_at']}'.substring(0, 10),
                            style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        trailing: IconButton(
                          tooltip: '忘记',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () async {
                            try {
                              await Api.instance.delete('/ai/memories/${m['id']}');
                              toast(context, '已忘记');
                              if (ctx.mounted) Navigator.pop(ctx);
                              _manageMemories();
                            } catch (e) {
                              toast(context, e.toString().replaceFirst('Exception: ', ''));
                            }
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            if (memories.isNotEmpty)
              TextButton(
                onPressed: () async {
                  try {
                    await Api.instance.delete('/ai/memories');
                    toast(context, '已清空记忆');
                    if (ctx.mounted) Navigator.pop(ctx);
                  } catch (e) {
                    toast(context, e.toString().replaceFirst('Exception: ', ''));
                  }
                },
                child: const Text('清空记忆', style: TextStyle(fontSize: 13)),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      );
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: appBarBackground(context),
        title: const Text('AI 助手', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: '我的记忆',
            icon: const Icon(Icons.bookmark_outline),
            onPressed: _manageMemories,
          ),
          IconButton(
            tooltip: '清空对话',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              // 服务端历史同步清空（跨设备）；离线时仅本地
              if (!kIsWeb && Api.isOffline) {
                toast(context, '需联网清空服务端历史（本地已清）');
              } else {
                try {
                  await Api.instance.delete('/ai/chat/history');
                } catch (_) {}
              }
              setState(() {
                _messages.clear();
                _messages.add({'role': 'assistant', 'content': _welcome()});
              });
              _saveHistory();
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: themePageBackground(context)),
          Column(
            children: [
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length,
                  itemBuilder: (_, i) => _bubble(_messages[i], i),
                ),
              ),
              // 快捷提问
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final q in _quickQs)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ActionChip(
                          label: Text(q, style: const TextStyle(fontSize: 12.5)),
                          visualDensity: VisualDensity.compact,
                          onPressed: _thinking ? null : () => _send(q),
                        ),
                      ),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '语音提问',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.mic_none, size: 20),
                        onPressed: _thinking ? null : _voiceAsk,
                      ),
                      IconButton(
                        tooltip: '拍小票识别记账',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.photo_camera_outlined, size: 20),
                        onPressed: _thinking ? null : _photoAsk,
                      ),
                      Expanded(
                        child: TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 3,
                          textInputAction: TextInputAction.send,
                          // 输入内容变化必须重建，否则发送按钮的可用状态（_input.text 非空判断）
                          // 永远停在初始值 → 自己打字发送不出去（仅快捷提问能发）
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(
                            hintText: '问问经营数据…（语音/拍小票也可以）',
                            isDense: true,
                            filled: true,
                            fillColor: Theme.of(context).colorScheme.surface,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(22),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: '发送',
                        onPressed: (_thinking || _input.text.trim().isEmpty) ? null : () => _send(),
                        icon: _thinking
                            ? const SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.send, size: 20),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bubble(Map<String, String> m, int idx) {
    final isUser = m['role'] == 'user';
    final content = m['content'] ?? '';
    // 打字机：最新一条未打完时只显示前缀
    final isTyping = !isUser && idx == _typingMsgIdx && _typingIndex < content.length;
    final shown = isTyping ? content.substring(0, _typingIndex) : content;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        decoration: BoxDecoration(
          color: isUser ? _c.primary : _c.card,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isUser ? 14 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 14),
          ),
          border: isUser ? null : Border.all(color: _c.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isUser)
              Text(
                content,
                style: const TextStyle(fontSize: 14, height: 1.45, color: Colors.white),
              )
            else
              AiMdText(shown, style: TextStyle(fontSize: 14, height: 1.45, color: Theme.of(context).colorScheme.onSurface)),
            if (!isUser && (m['order'] ?? '').isNotEmpty) _orderCard(m['order']!),
            if (!isUser && (m['toolsJson'] ?? '').isNotEmpty) _toolTimeline(m['toolsJson']!),
            if (!isUser && (m['sources'] ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('📖 依据：${m['sources']}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ),
          ],
        ),
      ),
    );
  }

  /// 工具执行时间线（对齐参考 App agent_execution_timeline：每个工具一行，图标+名称+结果）
  Widget _toolTimeline(String jsonStr) {
    List<Map<String, dynamic>> tools;
    try {
      tools = (jsonDecode(jsonStr) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const SizedBox.shrink();
    }
    final iconFor = <String, IconData>{
      'query_business_data': Icons.bar_chart_outlined,
      'get_business_snapshot': Icons.today_outlined,
      'pick_kb_entry': Icons.menu_book_outlined,
      'record_transaction': Icons.receipt_long_outlined,
      'save_memory': Icons.bookmark_add_outlined,
      'forget_memory': Icons.bookmark_remove_outlined,
    };
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _c.card.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _c.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final t in tools)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(iconFor['${t['name']}'] ?? Icons.smart_toy_outlined, size: 14, color: _c.primary),
                  const SizedBox(width: 6),
                  Text('${t['label'] ?? t['name']}',
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('${t['result'] ?? ''}',
                        style: const TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 一句话落单结果卡片（对齐参考 App 记账结果卡片）
  Widget _orderCard(String jsonStr) {
    Map<String, dynamic> o;
    try {
      o = jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (_) {
      return const SizedBox.shrink();
    }
    final isPurchase = '${o['type'] ?? 'purchase'}' == 'purchase';
    final total = o['total'];
    final client = '${o['client'] ?? ''}';
    final lines = ((o['lines'] as List?) ?? []).cast<Map<String, dynamic>>();
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      width: double.infinity,
      decoration: BoxDecoration(
        color: _c.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _c.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.receipt_long_outlined, size: 15, color: _c.primary),
              const SizedBox(width: 6),
              Text('${isPurchase ? '进货' : '出货'}${client.isNotEmpty ? ' · $client' : ''}${total != null ? ' · ¥$total' : ''}',
                  style: TextStyle(fontSize: 12.5, color: _c.primary, fontWeight: FontWeight.w600)),
            ],
          ),
          for (final l in lines.take(3))
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('${l['name']} ${l['quantity']}${l['unit']} × ¥${l['price']}',
                  style: const TextStyle(fontSize: 11.5)),
            ),
          if (lines.length > 3)
            const Padding(
              padding: EdgeInsets.only(top: 3),
              child: Text('…', style: TextStyle(fontSize: 11.5)),
            ),
          if (total != null)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text('合计 ¥$total（已在账本中）', style: TextStyle(fontSize: 11, color: _c.primary)),
            ),
        ],
      ),
    );
  }
}