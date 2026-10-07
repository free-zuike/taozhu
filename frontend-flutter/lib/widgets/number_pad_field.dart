import 'package:flutter/material.dart';

/// 自定义数字键盘输入组件（防系统输入法误输）：
/// 外观与 TextField 一致，点击弹出自定义数字键盘（0-9 + 小数点 + 退格 + 确定），
/// 只允许输入数字与小数点（最多一个小数点），杜绝字母/符号误输入。
class NumberPadField extends StatelessWidget {
  const NumberPadField({
    super.key,
    required this.controller,
    this.label,
    this.hintText,
    this.helperText,
    this.style,
    this.onChanged,
    this.allowDecimal = true,
    this.maxLength,
    this.decoration,
  });

  final TextEditingController controller;
  final String? label;
  final String? hintText;
  final TextStyle? style;
  /// 值变化回调（弹层确定写入时触发一次；与 TextField 语义一致）
  final ValueChanged<String>? onChanged;
  /// 是否允许小数点（金额/数量/单价=true；整数如卡号/份数=false）
  final bool allowDecimal;
  /// 最大字符数（含小数点），超长忽略输入
  final int? maxLength;
  final String? helperText;
  /// 完整输入装饰（页面可传本主题 _fieldDec 保持视觉一致）；缺省用 label/hint/helper 生成
  final InputDecoration? decoration;

  void _openPad(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _NumberPadSheet(
        controller: controller,
        allowDecimal: allowDecimal,
        maxLength: maxLength,
        onChanged: onChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      readOnly: true,
      showCursor: false,
      onTap: () => _openPad(context),
      keyboardType: TextInputType.none,
      style: style,
      decoration: decoration ??
          InputDecoration(
            labelText: label,
            hintText: hintText,
            helperText: helperText,
            suffixIcon: const Icon(Icons.pin_outlined, size: 16),
          ),
    );
  }
}

/// 数字键盘弹层：3×4 布局（1-9 / 0 / 小数点 / 退格）+ 确定
class _NumberPadSheet extends StatefulWidget {
  const _NumberPadSheet({
    required this.controller,
    required this.allowDecimal,
    this.maxLength,
    this.onChanged,
  });

  final TextEditingController controller;
  final bool allowDecimal;
  final int? maxLength;
  /// 确定写入时回调（TextField readOnly 不触发原生 onChanged，须在弹层写入后手动回调）
  final ValueChanged<String>? onChanged;

  @override
  State<_NumberPadSheet> createState() => _NumberPadSheetState();
}

class _NumberPadSheetState extends State<_NumberPadSheet> {
  late final TextEditingController _buf;

  @override
  void initState() {
    super.initState();
    _buf = TextEditingController(text: widget.controller.text);
  }

  @override
  void dispose() {
    _buf.dispose();
    super.dispose();
  }

  void _input(String ch) {
    final max = widget.maxLength;
    if (max != null && _buf.text.length >= max) return;
    if (ch == '.' && (!widget.allowDecimal || _buf.text.contains('.'))) return;
    setState(() => _buf.text += ch);
  }

  void _backspace() {
    if (_buf.text.isEmpty) return;
    setState(() => _buf.text = _buf.text.substring(0, _buf.text.length - 1));
  }

  Widget _key(BuildContext context, String label, {VoidCallback? onTap}) {
    return Expanded(
      child: AspectRatio(
        aspectRatio: 1.5,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onTap,
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF2A2A2E)
                      : const Color(0xFFF2F3F5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(label,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = <List<Widget>>[
      [for (final d in ['1', '2', '3']) _key(context, d, onTap: () => _input(d))],
      [for (final d in ['4', '5', '6']) _key(context, d, onTap: () => _input(d))],
      [for (final d in ['7', '8', '9']) _key(context, d, onTap: () => _input(d))],
      [
        if (widget.allowDecimal) _key(context, '.', onTap: () => _input('.')),
        _key(context, '0', onTap: () => _input('0')),
        _key(context, '⌫', onTap: _backspace),
      ],
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('当前值：${_buf.text.isEmpty ? '（空）' : _buf.text}',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (final r in rows) Row(children: r),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  widget.controller.text = _buf.text;
                  widget.onChanged?.call(_buf.text);
                  Navigator.pop(context);
                },
                child: const Text('确定'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
