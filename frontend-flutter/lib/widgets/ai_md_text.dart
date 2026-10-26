import 'package:flutter/material.dart';

/// AI 助手回复的轻量 Markdown 渲染（对齐参考 App agent_markdown_text 观感）：
/// 标题/列表/行内加粗·斜体·代码/表格行转对齐文本，无需引入 flutter_markdown 依赖。
class AiMdText extends StatelessWidget {
  const AiMdText(this.text, {super.key, this.style, this.maxLines});

  final String text;
  final TextStyle? style;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final base = style ?? const TextStyle(fontSize: 14, height: 1.45);
    final lines = text.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final line in lines) _lineWidget(line, base),
      ],
    );
  }

  Widget _lineWidget(String line, TextStyle base) {
    final t = line.trim();
    if (t.isEmpty) return const SizedBox(height: 4);

    // 标题
    final head = RegExp(r'^(#{1,3})\s+(.*)$').firstMatch(t);
    if (head != null) {
      final level = head.group(1)!.length;
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          head.group(2)!,
          style: base.copyWith(
            fontSize: level == 1 ? 16 : 15,
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
        ),
      );
    }

    // 无序列表
    final bullet = RegExp(r'^[-*•]\s+(.*)$').firstMatch(t);
    if (bullet != null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(right: 6), child: Text('•', style: base)),
          Expanded(child: Text.rich(TextSpan(children: _inline(bullet.group(1)!, base)), style: base)),
        ],
      );
    }

    // 有序列表
    final numList = RegExp(r'^(\d+)[.、]\s+(.*)$').firstMatch(t);
    if (numList != null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(right: 6), child: Text('${numList.group(1)}. ', style: base)),
          Expanded(child: Text.rich(TextSpan(children: _inline(numList.group(2)!, base)), style: base)),
        ],
      );
    }

    // 表格行（|a|b|）→ 去竖线按列对齐展示
    if (t.startsWith('|') && t.endsWith('|') && t.split('|').length > 2) {
      final cells = t.split('|').where((c) => c.trim().isNotEmpty).map((c) => c.trim()).join('    ');
      return Text(cells, style: base.copyWith(fontSize: (base.fontSize ?? 14) - 1));
    }

    // 普通行：行内解析
    return Text.rich(TextSpan(children: _inline(t, base)), style: base);
  }

  /// 行内解析：**加粗**、`代码`、*斜体*（不匹配跨行结构）
  List<TextSpan> _inline(String s, TextStyle base) {
    final spans = <TextSpan>[];
    final re = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`|\*[^*]+\*)');
    var last = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > last) spans.add(TextSpan(text: s.substring(last, m.start)));
      final token = m.group(0)!;
      if (token.startsWith('**')) {
        spans.add(TextSpan(text: token.substring(2, token.length - 2), style: TextStyle(fontWeight: FontWeight.w600)));
      } else if (token.startsWith('`')) {
        spans.add(TextSpan(
          text: token.substring(1, token.length - 1),
          style: TextStyle(fontFamily: 'monospace', fontSize: (base.fontSize ?? 14) - 1, backgroundColor: Colors.black.withValues(alpha: 0.06)),
        ));
      } else {
        spans.add(TextSpan(text: token.substring(1, token.length - 1), style: const TextStyle(fontStyle: FontStyle.italic)));
      }
      last = m.end;
    }
    if (last < s.length) spans.add(TextSpan(text: s.substring(last)));
    return spans.isEmpty ? [TextSpan(text: s)] : spans;
  }
}
