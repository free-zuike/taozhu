import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api.dart';
import '../theme.dart';
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
  final List<Map<String, String>> _messages = []; // {role: user|assistant, content}
  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();
  bool _thinking = false;

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
      await p.setString(_histKey, jsonEncode(list));
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
      final reply = '${d['reply'] ?? ''}'.trim();
      final sources = ((d['sources'] as List?) ?? []).cast<String>();
      setState(() {
        _thinking = false;
        if (reply.isNotEmpty) {
          _messages.add({
            'role': 'assistant',
            'content': reply,
            if (sources.isNotEmpty) 'sources': sources.join('、'),
          });
        } else {
          _messages.add({'role': 'assistant', 'content': '（模型没有返回内容，请稍后再试）'});
        }
      });
      _saveHistory();
      _scrollToBottom();
    } catch (e) {
      setState(() => _thinking = false);
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
                  itemBuilder: (_, i) => _bubble(_messages[i]),
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
                            hintText: '问问经营数据…（需在线）',
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

  Widget _bubble(Map<String, String> m) {
    final isUser = m['role'] == 'user';
    final content = m['content'] ?? '';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
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
            Text(
              content,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: isUser ? Colors.white : Theme.of(context).colorScheme.onSurface,
              ),
            ),
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
}