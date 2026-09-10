import 'package:flutter/material.dart';
import '../theme.dart';

/// 日期选择输入框：点击弹系统日历，避免手写格式错误（记单/对账单/收款等日期统一用）
class DateField extends StatelessWidget {
  final TextEditingController controller;
  final String? label;
  final String? hint;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final IconData? icon;
  final Color? focusColor;

  const DateField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.firstDate,
    this.lastDate,
    this.icon,
    this.focusColor,
  });

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final current = DateTime.tryParse(controller.text.trim());
    final picked = await showDatePicker(
      context: context,
      initialDate: current != null ? current : now,
      firstDate: firstDate ?? DateTime(now.year - 10),
      lastDate: lastDate ?? DateTime(now.year + 5, 12, 31),
    );
    if (picked != null) {
      controller.text = '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    final accent = focusColor ?? c.primary;
    return TextField(
      controller: controller,
      readOnly: true,
      onTap: () => _pick(context),
      style: TextStyle(color: c.textMain),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon, size: 20, color: c.textSub),
        suffixIcon: const Icon(Icons.calendar_today_outlined, size: 16, color: Color(0xFF909399)),
        filled: true,
        fillColor: c.field,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: accent, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }
}